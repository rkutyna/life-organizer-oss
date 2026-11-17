"""Regression tests for the op queue's integrity: ids that are never reused, ops that only ever
reach the reminder they were queued for, Google creates that never run twice, History reverts
that cannot re-apply an op, polls that cannot undo a newer write, the server instance id, the
size bounds and snapshots that stay within their own lists."""

from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.audit import ChangeLog
from app.config import Settings
from app.modules.reminders import google_tasks, ingest, sync
from app.modules.reminders.models import Reminder, ReminderOp
from app.modules.reminders.tests.support import (
    ERRANDS,
    GROCERIES,
    OPS,
    PUSH,
    FakeTasks,
    a_list,
    a_reminder,
    ack,
    google_account,
    helper_ops,
    push,
    push_body,
)
from app.providers.models import ProviderAccount
from app.timeutil import utcnow


def iso(value) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def by_title(client: TestClient) -> dict[str, dict]:
    rows = client.get("/api/reminders", params={"include_completed": True}).json()
    return {r["title"]: r for r in rows}


def seed(helper: TestClient, *reminders: dict) -> None:
    push(helper, push_body([GROCERIES, ERRANDS], list(reminders), default_list_id="L-groceries"))


@pytest.fixture
def account(session: Session, settings: Settings) -> ProviderAccount:
    return google_account(session, settings)


@pytest.fixture
def mirrored(client: TestClient, fake_tasks: FakeTasks, account: ProviderAccount) -> FakeTasks:
    fake_tasks.clock = iso(utcnow())  # tasks Google writes now carry the real time
    fake_tasks.lists = {"gl-home": "Home", "gl-work": "Work"}
    fake_tasks.add("gl-home", "t-milk", "Milk")
    response = client.post("/api/reminders/sync")
    assert response.json()[0]["ok"] is True, response.json()
    fake_tasks.calls.clear()
    fake_tasks.queries.clear()
    return fake_tasks


def google_titles(fake: FakeTasks, list_id: str = "gl-home") -> list[str]:
    return sorted(t["title"] for t in fake.tasks[list_id].values())


def creates(fake: FakeTasks) -> list:
    return [c for c in fake.calls if c[0] == "POST" and c[1].endswith("/tasks")]


# --------------------------------------------------------------------------- 1. ids and targets


def test_ids_are_never_reused():
    assert Reminder.__table__.dialect_options["sqlite"]["autoincrement"] is True
    assert ReminderOp.__table__.dialect_options["sqlite"]["autoincrement"] is True


def test_a_deleted_reminders_failed_op_never_reaches_a_new_one(client, helper):
    seed(
        helper,
        a_reminder("r1", "L-groceries", "Milk"),
        a_reminder("r2", "L-groceries", "Call the bank"),
    )
    bank = by_title(client)["Call the bank"]
    client.post(f"/api/reminders/{bank['id']}/complete")
    seed(helper, a_reminder("r1", "L-groceries", "Milk"))  # deleted on the Mac
    seed(
        helper,
        a_reminder("r1", "L-groceries", "Milk"),
        a_reminder("r3", "L-groceries", "Renew passport"),
    )
    passport = by_title(client)["Renew passport"]
    assert passport["id"] != bank["id"]
    assert passport["sync"]["state"] == "synced"

    [op] = client.get("/api/reminders/ops", params={"state": "failed"}).json()
    assert op["reminder_id"] == bank["id"]
    assert client.post(f"/api/reminders/ops/{op['id']}/retry").status_code == 409
    assert helper_ops(helper) == []


def test_an_op_is_stored_with_its_target(client, helper, session):
    seed(helper, a_reminder("r1", "L-groceries", "Milk"))
    milk = by_title(client)["Milk"]
    client.post(f"/api/reminders/{milk['id']}/complete")
    op = session.scalars(select(ReminderOp)).one()
    assert (op.source, op.account_id, op.ext_id, op.local_id) == ("apple", None, "ext-r1", "r1")


def test_an_op_whose_row_is_another_reminder_is_failed_not_applied(client, helper, session):
    """Should a row ever carry another reminder (an id reused before the upgrade), its old ops
    are neither sent to the helper nor retried, nor shown on it."""
    seed(helper, a_reminder("r1", "L-groceries", "Milk"))
    milk = by_title(client)["Milk"]
    client.post(f"/api/reminders/{milk['id']}/complete")
    op = session.scalars(select(ReminderOp)).one()
    row = session.get(Reminder, milk["id"])
    row.ext_id, row.local_id, row.title = "ext-r9", "r9", "Something else"
    session.commit()

    assert client.get(f"/api/reminders/{milk['id']}").json()["sync"]["state"] == "synced"
    assert helper_ops(helper) == []
    session.refresh(op)
    assert (op.state, op.error) == ("failed", sync.STALE_TARGET)
    assert client.post(f"/api/reminders/ops/{op.id}/retry").status_code == 409


def test_a_late_external_id_keeps_the_ops_target(client, helper):
    seed(helper, a_reminder("r1", "L-groceries", "Milk", external_id=None))
    milk = by_title(client)["Milk"]
    client.post(f"/api/reminders/{milk['id']}/complete")
    seed(helper, a_reminder("r1", "L-groceries", "Milk", external_id="ext-late"))
    [op] = helper_ops(helper)
    assert (op["external_id"], op["local_id"]) == ("ext-late", "r1")


def test_ops_queued_on_a_placeholder_follow_its_create(client, helper):
    seed(helper)
    new = client.post("/api/reminders", json={"title": "Buy stamps"}).json()
    client.post(f"/api/reminders/{new['id']}/complete")
    create, complete = helper_ops(helper)
    ack(helper, create["id"], external_id="ext-new", local_id="new")
    [op] = helper_ops(helper)
    assert (op["id"], op["external_id"], op["local_id"]) == (complete["id"], "ext-new", "new")


def test_a_google_move_keeps_later_ops_on_the_task(client, mirrored, session):
    milk = by_title(client)["Milk"]
    original = mirrored.handler

    def new_id_on_move(request):
        response = original(request)
        if request.url.path.endswith("/move"):
            task = mirrored.tasks["gl-work"].pop("t-milk")
            task["id"] = "t-milk-2"
            mirrored.tasks["gl-work"]["t-milk-2"] = task
            return httpx.Response(200, json=task)
        return response

    mirrored.handler = new_id_on_move
    mirrored.fail = {"PATCH /lists/gl-work/tasks/t-milk-2": 503}
    assert client.patch(f"/api/reminders/{milk['id']}", json={"list_id": "gl-work"}).status_code
    client.patch(f"/api/reminders/{milk['id']}", json={"title": "Oat milk"})
    pending = session.scalars(select(ReminderOp).where(ReminderOp.state == "pending")).one()
    assert pending.ext_id == "t-milk-2"
    mirrored.fail = {}
    client.post("/api/reminders/sync")
    assert mirrored.tasks["gl-work"]["t-milk-2"]["title"] == "Oat milk"


# --------------------------------------------------------------------------- 2. Google creates


def test_a_create_whose_answer_was_lost_is_not_made_twice(client, mirrored):
    original = mirrored.handler
    lost = {"once": True}

    def times_out_after_saving(request):
        response = original(request)
        if request.method == "POST" and lost["once"]:
            lost["once"] = False
            raise httpx.ReadTimeout("timed out after Google saved it", request=request)
        return response

    mirrored.handler = times_out_after_saving
    new = client.post("/api/reminders", json={"title": "Pay rent", "list_id": "gl-home"}).json()
    assert new["sync"]["state"] == "syncing"
    client.post("/api/reminders/sync")
    assert google_titles(mirrored) == ["Milk", "Pay rent"]
    assert len(creates(mirrored)) == 1
    shown = by_title(client)["Pay rent"]
    assert (shown["id"], shown["sync"]["state"]) == (new["id"], "synced")


def test_a_503_after_saving_is_not_made_twice_even_after_a_poll(client, mirrored, monkeypatch):
    original = mirrored.handler
    state = {"post": 0}

    def saves_then_503(request):
        response = original(request)
        if request.method == "POST":
            state["post"] += 1
            if state["post"] == 1:
                return httpx.Response(503, json={"error": {"message": "backend"}})
        return response

    mirrored.handler = saves_then_503
    new = client.post("/api/reminders", json={"title": "Pay rent", "list_id": "gl-home"}).json()
    # A poll carries the task before the retry: it comes in as a row of its own ...
    apply_pending = google_tasks.apply_pending
    monkeypatch.setattr(google_tasks, "apply_pending", lambda *a, **k: None)
    client.post("/api/reminders/sync")
    monkeypatch.setattr(google_tasks, "apply_pending", apply_pending)
    # ... and the retry adopts it and folds that row into the placeholder.
    client.post("/api/reminders/sync")
    assert google_titles(mirrored) == ["Milk", "Pay rent"]
    rows = [r for r in client.get("/api/reminders").json() if r["title"] == "Pay rent"]
    assert [(r["id"], r["sync"]["state"]) for r in rows] == [(new["id"], "synced")]


def test_a_retry_after_giving_up_does_not_create_twice(client, mirrored, session):
    mirrored.fail = {"POST /lists/gl-home/tasks": 503}
    original = mirrored.handler

    def saves_anyway(request):
        if request.method == "POST":
            mirrored.fail = {}
            original(request)
            mirrored.fail = {"POST /lists/gl-home/tasks": 503}
        return original(request)

    mirrored.handler = saves_anyway
    new = client.post("/api/reminders", json={"title": "Pay rent", "list_id": "gl-home"}).json()
    op = session.scalars(select(ReminderOp).where(ReminderOp.kind == "create")).one()
    audit.update(session, op, {"state": "failed", "error": "gave up"}, "system")
    mirrored.handler = original
    mirrored.fail = {}
    assert client.post(f"/api/reminders/ops/{op.id}/retry").json()["state"] == "applied"
    assert google_titles(mirrored) == ["Milk", "Pay rent"]
    assert client.get(f"/api/reminders/{new['id']}").json()["external_id"] == "new-1"


def test_an_identical_task_known_before_the_create_is_not_adopted(client, mirrored):
    mirrored.add("gl-home", "t-rent", "Pay rent", updated=iso(utcnow()))
    client.post("/api/reminders/sync")
    client.post("/api/reminders", json={"title": "Pay rent", "list_id": "gl-home"})
    assert google_titles(mirrored) == ["Milk", "Pay rent", "Pay rent"]


def test_two_identical_creates_make_two_tasks(client, mirrored):
    client.post("/api/reminders", json={"title": "Water plants", "list_id": "gl-home"})
    client.post("/api/reminders", json={"title": "Water plants", "list_id": "gl-home"})
    assert google_titles(mirrored).count("Water plants") == 2


# --------------------------------------------------------------------------- 3. History reverts


def test_reverting_an_applied_ops_state_is_refused(client, mirrored, session, token_client):
    claude = token_client(["api"], author="claude")
    client.post("/api/reminders", json={"title": "Call mum", "list_id": "gl-home"})
    for field in ("state", "applied_at", "ext_id"):
        change = session.scalars(
            select(ChangeLog).where(
                ChangeLog.table_name == "reminders_ops", ChangeLog.field == field
            )
        ).one()
        assert claude.post(f"/api/history/{change.id}/revert").status_code == 409, field
    client.post("/api/reminders/sync")
    assert google_titles(mirrored) == ["Call mum", "Milk"]
    assert session.scalars(select(ReminderOp)).one().state == "applied"


def test_restoring_a_withdrawn_op_whose_reminder_is_gone_is_refused(client, helper, session):
    seed(helper)
    new = client.post("/api/reminders", json={"title": "Buy stamps"}).json()
    [op] = helper_ops(helper)
    client.delete(f"/api/reminders/ops/{op['id']}")  # also removes the placeholder
    assert client.get(f"/api/reminders/{new['id']}").status_code == 404
    change = session.scalars(
        select(ChangeLog).where(ChangeLog.table_name == "reminders_ops", ChangeLog.op == "delete")
    ).one()
    assert client.post(f"/api/history/{change.id}/revert").status_code == 409
    assert helper_ops(helper) == []


# --------------------------------------------------------------------------- 4. stale polls


def test_a_poll_read_before_a_create_keeps_it(client, mirrored, session, account):
    started = utcnow()
    stale_lists = [
        sync.IncomingList("gl-home", "Home", None, "x", "google", True),
        sync.IncomingList("gl-work", "Work", None, "x", "google", True),
    ]
    stale = [google_tasks.incoming(mirrored.tasks["gl-home"]["t-milk"], "gl-home")]
    new = client.post("/api/reminders", json={"title": "Pay rent", "list_id": "gl-home"}).json()
    client.patch(f"/api/reminders/{by_title(client)['Milk']['id']}", json={"title": "Oat milk"})
    with audit.transaction(session):
        sync.replace_snapshot(
            session, sync.Scope("google", account.id), stale_lists, stale, "gl-home", started
        )
    assert client.get(f"/api/reminders/{new['id']}").status_code == 200
    assert "Oat milk" in by_title(client)  # the stale "Milk" did not overwrite it
    client.post("/api/reminders/sync")
    assert by_title(client)["Pay rent"]["id"] == new["id"]


# --------------------------------------------------------------------------- 5. instance id


def test_the_ops_poll_names_a_stable_instance(helper):
    first = helper.get(OPS).json()["instance_id"]
    assert len(first) >= 16
    assert helper.get(OPS).json()["instance_id"] == first


def test_an_ack_for_another_instance_is_refused(client, helper):
    seed(helper, a_reminder("r1", "L-groceries", "Milk"))
    client.post(f"/api/reminders/{by_title(client)['Milk']['id']}/complete")
    body = helper.get(OPS).json()
    op_id = body["ops"][0]["id"]
    other = helper.post(f"{OPS}/{op_id}/ack", json={"ok": True, "instance_id": "another"})
    assert other.status_code == 409
    mine = helper.post(f"{OPS}/{op_id}/ack", json={"ok": True, "instance_id": body["instance_id"]})
    assert mine.json()["state"] == "applied"


def test_a_create_ack_naming_an_existing_reminder_does_not_take_it_over(client, helper):
    seed(helper, a_reminder("a1", "L-groceries", "Existing"))
    existing = by_title(client)["Existing"]
    new = client.post("/api/reminders", json={"title": "New one"}).json()
    [op] = helper_ops(helper)
    result = ack(helper, op["id"], external_id="ext-a1", local_id="a1")
    assert result["state"] == "failed"
    assert "existing reminder" in result["error"]
    kept = client.get(f"/api/reminders/{existing['id']}").json()
    assert (kept["title"], kept["external_id"]) == ("Existing", "ext-a1")
    assert client.get(f"/api/reminders/{new['id']}").json()["external_id"] is None


# --------------------------------------------------------------------------- 6. the page cap


def test_the_poll_asks_only_for_recent_completions(client, mirrored):
    client.post("/api/reminders/sync")
    task_queries = [
        q
        for (method, path, _), q in zip(mirrored.calls, mirrored.queries, strict=True)
        if method == "GET" and path.endswith("/tasks")
    ]
    assert task_queries and all("completedMin" in q for q in task_queries)
    cutoff = utcnow() - timedelta(days=sync.COMPLETED_DAYS)
    assert task_queries[0]["completedMin"][:10] == cutoff.strftime("%Y-%m-%d")


def test_a_list_past_the_page_cap_fails_the_poll_and_keeps_the_mirror(
    client, mirrored, monkeypatch
):
    original = mirrored.handler

    def endless(request):
        path = request.url.path.removeprefix("/tasks/v1")
        if request.method == "GET" and path == "/lists/gl-home/tasks":
            page = int(request.url.params.get("pageToken", "0"))
            items = [mirrored.tasks["gl-home"]["t-milk"]] if page == 0 else []
            return httpx.Response(200, json={"items": items, "nextPageToken": str(page + 1)})
        return original(request)

    mirrored.handler = endless
    monkeypatch.setattr(google_tasks, "MAX_PAGES", 2)
    [outcome] = client.post("/api/reminders/sync").json()
    assert outcome["ok"] is False
    assert "more than" in outcome["error"]
    assert "Milk" in by_title(client)


# --------------------------------------------------------------------------- 7. size bounds


def test_a_snapshot_with_huge_notes_is_refused(helper):
    big = "n" * (ingest.MAX_NOTES + 1)
    body = push_body([GROCERIES], [a_reminder("b1", "L-groceries", "t", notes=big)])
    assert helper.post(PUSH, json=body).status_code == 422


def test_a_snapshot_with_too_many_lists_or_reminders_is_refused(helper):
    lists = [a_list(f"L-{i}", "x") for i in range(ingest.MAX_LISTS + 1)]
    assert helper.post(PUSH, json=push_body(lists, [])).status_code == 422
    many = [{"local_id": str(i), "list_id": "L-groceries"} for i in range(ingest.MAX_REMINDERS + 1)]
    assert helper.post(PUSH, json=push_body([GROCERIES], many)).status_code == 422


def test_an_ack_with_too_many_conflicts_is_refused(client, helper):
    seed(helper, a_reminder("r1", "L-groceries", "Milk"))
    client.post(f"/api/reminders/{by_title(client)['Milk']['id']}/complete")
    [op] = helper_ops(helper)
    conflict = {"field": "title", "kept": "provider"}
    body = {"ok": True, "conflicts": [conflict] * (ingest.MAX_CONFLICTS + 1)}
    assert helper.post(f"{OPS}/{op['id']}/ack", json=body).status_code == 422


def test_create_and_update_cap_notes(client, helper):
    seed(helper, a_reminder("r1", "L-groceries", "Milk"))
    big = "n" * (ingest.MAX_NOTES + 1)
    assert client.post("/api/reminders", json={"title": "x", "notes": big}).status_code == 422
    milk = by_title(client)["Milk"]
    assert client.patch(f"/api/reminders/{milk['id']}", json={"notes": big}).status_code == 422


# --------------------------------------------------------------------------- 8. own lists


def test_an_apple_snapshot_cannot_file_reminders_under_a_google_list(client, mirrored, helper):
    result = push(
        helper,
        push_body(
            [GROCERIES],
            [
                a_reminder("x1", "gl-home", "Injected"),
                a_reminder("x2", "L-groceries", "Fine"),
            ],
        ),
    )
    assert result["reminders"] == 1
    titles = by_title(client)
    assert "Injected" not in titles
    assert titles["Fine"]["source"] == "apple"
    home = client.get("/api/reminders", params={"list": "gl-home"}).json()
    assert {r["source"] for r in home} == {"google"}
