"""Google Tasks: the poll, and the server applying ops at once under the loop and conflict
rules. Google is a FakeTasks behind httpx.MockTransport."""

from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.audit import ChangeLog
from app.config import Settings
from app.modules.reminders import google_tasks
from app.modules.reminders.google_sync import sync_all
from app.modules.reminders.models import Reminder, ReminderList, ReminderOp
from app.modules.reminders.tests.support import (
    GROCERIES,
    OPS,
    FakeTasks,
    a_reminder,
    google_account,
    helper_ops,
    push,
    push_body,
)
from app.providers import google
from app.providers.models import ProviderAccount
from app.timeutil import utcnow

LATER = "2030-01-01T00:00:00.000Z"  # a change made at Google after any op here was queued


@pytest.fixture
def account(session: Session, settings: Settings) -> ProviderAccount:
    return google_account(session, settings)


@pytest.fixture
def mirrored(client: TestClient, fake_tasks: FakeTasks, account: ProviderAccount) -> FakeTasks:
    fake_tasks.lists = {"gl-home": "Home", "gl-work": "Work"}
    fake_tasks.add("gl-home", "t-milk", "Milk", notes="Oat", due="2026-10-22T00:00:00.000Z")
    fake_tasks.add("gl-home", "t-bins", "Put the bins out")
    fake_tasks.add(
        "gl-work",
        "t-old",
        "Finished long ago",
        status="completed",
        completed=_iso(utcnow() - timedelta(days=45)),
    )
    fake_tasks.add(
        "gl-work",
        "t-done",
        "Finished yesterday",
        status="completed",
        completed=_iso(utcnow() - timedelta(days=1)),
        hidden=True,
    )
    response = client.post("/api/reminders/sync")
    assert response.status_code == 200, response.text
    assert response.json()[0]["ok"] is True, response.json()
    fake_tasks.calls.clear()
    return fake_tasks


def by_title(client: TestClient) -> dict[str, dict]:
    rows = client.get("/api/reminders", params={"include_completed": True}).json()
    return {r["title"]: r for r in rows}


def patch_calls(fake: FakeTasks) -> list[tuple[str, str, object]]:
    return [call for call in fake.calls if call[0] in ("PATCH", "POST")]


# --------------------------------------------------------------------------- the poll


def test_the_poll_mirrors_lists_and_tasks(client, mirrored, account):
    lists = client.get("/api/reminders/lists").json()
    assert [(lst["title"], lst["source"], lst["account"], lst["account_id"]) for lst in lists] == [
        ("Home", "google", "someone@example.com", account.id),
        ("Work", "google", "someone@example.com", account.id),
    ]
    assert lists[0]["is_default"] is True  # Google's first list
    assert not lists[0]["supports_time"] and not lists[0]["supports_priority"]
    assert lists[0]["color"].startswith("#")

    rows = by_title(client)
    assert set(rows) == {"Milk", "Put the bins out", "Finished yesterday"}
    milk = rows["Milk"]
    assert (milk["due_date"], milk["due_time"], milk["notes"], milk["source"]) == (
        "2026-10-22",
        None,
        "Oat",
        "google",
    )
    assert (milk["external_id"], milk["in_provider"], milk["sync"]["state"]) == (
        "t-milk",
        True,
        "synced",
    )
    assert rows["Finished yesterday"]["completed"] is True

    status = client.get("/api/reminders/status").json()
    [entry] = status["google"]
    assert (entry["account_id"], entry["freshness"]["state"]) == (account.id, "ok")
    assert entry["freshness"]["label"] == "someone@example.com tasks"


def test_a_second_poll_keeps_ids_and_drops_what_is_gone(client, mirrored):
    first = by_title(client)
    del mirrored.tasks["gl-home"]["t-bins"]
    mirrored.tasks["gl-home"]["t-milk"]["title"] = "Milk x2"
    client.post("/api/reminders/sync")
    again = by_title(client)
    assert "Put the bins out" not in again
    assert again["Milk x2"]["id"] == first["Milk"]["id"]


def test_the_helper_push_and_the_poll_do_not_touch_each_other(client, mirrored, helper):
    push(helper, push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs")]))
    client.post("/api/reminders/sync")
    titles = set(by_title(client))
    assert {"Eggs", "Milk"} <= titles
    push(helper, push_body([GROCERIES], []))
    assert "Milk" in by_title(client)


def test_a_failing_poll_is_recorded_on_the_account(client, fake_tasks, account, session):
    fake_tasks.fail = {"GET /users/@me/lists": 500}
    [outcome] = client.post("/api/reminders/sync").json()
    assert outcome["ok"] is False and "500" in outcome["error"]
    [entry] = client.get("/api/reminders/status").json()["google"]
    assert entry["freshness"]["state"] == "error"
    session.refresh(account)
    assert account.last_error and account.last_error.startswith("Tasks:")


def test_a_removed_account_loses_its_rows(client, mirrored, account, session, settings):
    session.delete(session.get(ProviderAccount, account.id))
    session.commit()
    sync_all(session, settings)
    assert session.scalars(select(Reminder)).all() == []
    assert session.scalars(select(ReminderList)).all() == []
    assert client.get("/api/reminders/status").json()["google"] == []


def test_an_account_without_the_tasks_scope_is_not_read(client, fake_tasks, session, settings):
    google_account(session, settings, email="other@example.com", tasks=False)
    assert client.post("/api/reminders/sync").json() == []
    assert fake_tasks.calls == []


# --------------------------------------------------------------------------- applying ops


def test_create_is_applied_at_once(client, mirrored, session):
    lists = {lst["title"]: lst["id"] for lst in client.get("/api/reminders/lists").json()}
    response = client.post(
        "/api/reminders",
        json={"title": "Call the dentist", "due_date": "2026-10-24", "list_id": lists["Work"]},
    )
    assert response.status_code == 201, response.text
    new = response.json()
    assert (new["in_provider"], new["external_id"], new["sync"]["state"]) == (
        True,
        "new-1",
        "synced",
    )
    assert (new["due_date"], new["list_title"]) == ("2026-10-24", "Work")
    assert patch_calls(mirrored) == [
        (
            "POST",
            "/lists/gl-work/tasks",
            {"title": "Call the dentist", "notes": "", "due": "2026-10-24T00:00:00.000Z"},
        )
    ]
    op = session.scalars(select(ReminderOp)).one()
    assert (op.applier, op.state, op.created_by, op.ext_id) == ("server", "applied", "me", "new-1")
    authors = session.scalars(
        select(ChangeLog.author).where(ChangeLog.table_name == "reminders_ops")
    ).all()
    assert set(authors) == {"me", "system"}

    client.post("/api/reminders/sync")  # the next poll keeps the same row
    assert by_title(client)["Call the dentist"]["id"] == new["id"]


def test_google_lists_refuse_a_time_and_a_priority(client, mirrored, session):
    home = client.get("/api/reminders/lists").json()[0]["id"]
    timed = client.post(
        "/api/reminders",
        json={"title": "Call", "list_id": home, "due_date": "2026-10-24", "due_time": "09:00"},
    )
    assert timed.status_code == 422
    assert "no time" in timed.json()["detail"]
    ranked = client.post("/api/reminders", json={"title": "Call", "list_id": home, "priority": 1})
    assert ranked.status_code == 422
    milk = by_title(client)["Milk"]
    assert (
        client.patch(f"/api/reminders/{milk['id']}", json={"due_time": "09:00"}).status_code == 422
    )
    assert client.patch(f"/api/reminders/{milk['id']}", json={"priority": 2}).status_code == 422
    assert session.scalars(select(ReminderOp)).all() == []
    assert mirrored.calls == []


def test_complete_and_uncomplete(client, mirrored):
    milk = by_title(client)["Milk"]
    done = client.post(f"/api/reminders/{milk['id']}/complete").json()
    assert (done["completed"], done["sync"]["state"]) == (True, "synced")
    assert mirrored.tasks["gl-home"]["t-milk"]["status"] == "completed"
    undone = client.post(f"/api/reminders/{milk['id']}/uncomplete").json()
    assert (undone["completed"], undone["sync"]["state"]) == (False, "synced")
    task = mirrored.tasks["gl-home"]["t-milk"]
    assert task["status"] == "needsAction" and "completed" not in task


def test_update_patches_only_what_changed(client, mirrored):
    milk = by_title(client)["Milk"]
    out = client.patch(
        f"/api/reminders/{milk['id']}", json={"title": "Oat milk", "due_date": None}
    ).json()
    assert (out["title"], out["due_date"], out["sync"]["state"]) == ("Oat milk", None, "synced")
    assert patch_calls(mirrored) == [
        ("PATCH", "/lists/gl-home/tasks/t-milk", {"title": "Oat milk", "due": None})
    ]


def test_a_field_changed_at_google_later_wins(client, mirrored, session):
    milk = by_title(client)["Milk"]
    task = mirrored.tasks["gl-home"]["t-milk"]
    task.update(title="Milk x2", updated=LATER)  # edited on the phone; not polled yet
    out = client.patch(
        f"/api/reminders/{milk['id']}", json={"title": "Oat milk", "notes": "2 cartons"}
    ).json()
    assert (out["title"], out["notes"]) == ("Milk x2", "2 cartons")  # fields merge
    assert patch_calls(mirrored) == [
        ("PATCH", "/lists/gl-home/tasks/t-milk", {"notes": "2 cartons"})
    ]
    op = session.scalars(select(ReminderOp)).one()
    assert op.conflicts == [
        {
            "field": "title",
            "kept": "provider",
            "provider_value": "Milk x2",
            "organizer_value": "Oat milk",
        }
    ]


def test_an_older_change_at_google_loses_to_the_organizer(client, mirrored, session):
    milk = by_title(client)["Milk"]
    mirrored.tasks["gl-home"]["t-milk"]["title"] = "Milk x2"  # updated stays in the past
    out = client.patch(f"/api/reminders/{milk['id']}", json={"title": "Oat milk"}).json()
    assert out["title"] == "Oat milk"
    op = session.scalars(select(ReminderOp)).one()
    assert op.conflicts[0]["kept"] == "organizer"


def test_a_completion_at_google_beats_a_later_uncomplete(client, mirrored):
    done = by_title(client)["Finished yesterday"]
    mirrored.tasks["gl-work"]["t-done"]["completed"] = LATER  # completed again on the phone
    out = client.post(f"/api/reminders/{done['id']}/uncomplete").json()
    assert out["completed"] is True
    assert mirrored.tasks["gl-work"]["t-done"]["status"] == "completed"


def test_a_move_within_the_account(client, mirrored, helper):
    lists = {lst["title"]: lst["id"] for lst in client.get("/api/reminders/lists").json()}
    milk = by_title(client)["Milk"]
    moved = client.patch(f"/api/reminders/{milk['id']}", json={"list_id": lists["Work"]}).json()
    assert (moved["list_title"], moved["sync"]["state"]) == ("Work", "synced")
    assert "t-milk" in mirrored.tasks["gl-work"]

    push(helper, push_body([GROCERIES], []))
    refused = client.patch(f"/api/reminders/{milk['id']}", json={"list_id": "L-groceries"})
    assert refused.status_code == 422
    assert "same account" in refused.json()["detail"]


def test_a_network_error_leaves_the_op_pending_until_the_next_poll(client, mirrored, session):
    milk = by_title(client)["Milk"]
    mirrored.raise_network = True
    out = client.post(f"/api/reminders/{milk['id']}/complete").json()
    assert (out["completed"], out["sync"]["state"]) == (True, "syncing")
    op = session.scalars(select(ReminderOp)).one()
    assert (op.state, op.attempts) == ("pending", 1)

    mirrored.raise_network = False
    client.post("/api/reminders/sync")
    session.refresh(op)
    assert op.state == "applied"
    assert by_title(client)["Milk"]["sync"]["state"] == "synced"


def test_retries_give_up_after_max_attempts(client, mirrored, session, settings):
    milk = by_title(client)["Milk"]
    mirrored.fail = {"GET /lists/gl-home/tasks/t-milk": 503}
    client.post(f"/api/reminders/{milk['id']}/complete")
    for _ in range(google_tasks.MAX_ATTEMPTS):
        google_tasks.apply_pending(session, settings)
    op = session.scalars(select(ReminderOp)).one()
    assert op.state == "failed" and "gave up" in (op.error or "")


def test_a_refusal_fails_the_op_and_retry_applies_it(client, mirrored, session):
    milk = by_title(client)["Milk"]
    mirrored.fail = {"PATCH .*": 400}
    out = client.post(f"/api/reminders/{milk['id']}/complete").json()
    assert out["sync"]["state"] == "failed"
    assert "400" in out["sync"]["error"]
    [op] = out["sync"]["pending_ops"]

    mirrored.fail = {}
    retried = client.post(f"/api/reminders/ops/{op['id']}/retry").json()
    assert retried["state"] == "applied"
    assert by_title(client)["Milk"]["sync"]["state"] == "synced"


def test_a_task_deleted_at_google_fails_the_op(client, mirrored):
    milk = by_title(client)["Milk"]
    del mirrored.tasks["gl-home"]["t-milk"]
    out = client.post(f"/api/reminders/{milk['id']}/complete").json()
    assert out["sync"]["error"] == "the reminder is gone from Google Tasks"


def test_a_refused_grant_fails_the_op(client, mirrored, monkeypatch):
    def refuse(session, settings, account):
        raise google.GoogleAuthError("invalid_grant")

    monkeypatch.setattr(google, "access_token", refuse)
    milk = by_title(client)["Milk"]
    out = client.post(f"/api/reminders/{milk['id']}/complete").json()
    assert out["sync"]["state"] == "failed"
    assert "reconnect" in out["sync"]["error"]


def test_google_ops_never_reach_the_helper(client, mirrored, helper, session):
    milk = by_title(client)["Milk"]
    mirrored.raise_network = True
    client.post(f"/api/reminders/{milk['id']}/complete")
    assert helper_ops(helper) == []
    op = session.scalars(select(ReminderOp)).one()
    assert helper.post(f"{OPS}/{op.id}/ack", json={"ok": True}).status_code == 404


def test_a_disabled_account_hides_its_reminders(client, mirrored, account, session):
    account.enabled = False
    session.commit()
    assert client.get("/api/reminders").json() == []
    assert client.get("/api/reminders/lists").json() == []


def _iso(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%S.000Z")
