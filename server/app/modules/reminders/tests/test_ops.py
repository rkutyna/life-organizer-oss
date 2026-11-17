"""Apple ops: queueing through app.audit, the helper's poll and ack, the overlay, sync states,
conflicts and the authors on every change."""

from datetime import timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.audit import ChangeLog
from app.modules.reminders.models import HelperContact, Reminder, ReminderOp
from app.modules.reminders.tests.support import (
    ERRANDS,
    GROCERIES,
    OPS,
    SHARED,
    a_reminder,
    ack,
    helper_ops,
    push,
    push_body,
)
from app.timeutil import utcnow


def seed(client: TestClient, helper: TestClient, *reminders: dict) -> list[dict]:
    push(
        helper,
        push_body([GROCERIES, ERRANDS, SHARED], list(reminders), default_list_id="L-groceries"),
    )
    return client.get("/api/reminders", params={"include_completed": True}).json()


def op_authors(session: Session) -> list[tuple[str, str, str | None]]:
    rows = session.scalars(
        select(ChangeLog).where(ChangeLog.table_name == "reminders_ops").order_by(ChangeLog.id)
    )
    return [(row.author, row.op, row.field) for row in rows]


# --------------------------------------------------------------------------- lifecycle


def test_complete_round_trip(client, helper, session: Session):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))

    done = client.post(f"/api/reminders/{r['id']}/complete").json()
    assert done["completed"] is True  # shown at once
    assert done["sync"]["state"] == "syncing"
    assert done["sync"]["pending_fields"] == ["completed"]
    [pending] = done["sync"]["pending_ops"]
    assert (pending["kind"], pending["state"], pending["created_by"], pending["applier"]) == (
        "complete",
        "pending",
        "me",
        "helper",
    )

    [op] = helper_ops(helper)
    assert (op["kind"], op["external_id"], op["local_id"]) == ("complete", "ext-r1", "r1")
    assert op["base"] == {"completed": False}

    acked = ack(helper, op["id"])
    assert acked["state"] == "applied"
    mid = client.get(f"/api/reminders/{r['id']}").json()
    assert (mid["completed"], mid["sync"]["state"]) == (True, "syncing")
    assert helper_ops(helper) == []

    seed(
        client,
        helper,
        a_reminder(
            "r1", "L-groceries", "Oat milk", completed=True, completed_at="2026-10-19T12:00:00Z"
        ),
    )
    after = client.get(f"/api/reminders/{r['id']}").json()
    assert (after["completed"], after["sync"]["state"]) == (True, "synced")

    assert op_authors(session) == [
        ("me", "create", None),
        ("helper", "update", "state"),
        ("helper", "update", "applied_at"),
    ]


def test_completing_twice_queues_one_op(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.post(f"/api/reminders/{r['id']}/complete")
    again = client.post(f"/api/reminders/{r['id']}/complete").json()
    assert len(again["sync"]["pending_ops"]) == 1
    [done] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk", completed=True))
    client.post(f"/api/reminders/{done['id']}/complete")
    assert len(helper_ops(helper)) == 1


def test_uncomplete_queues_with_its_base(client, helper):
    [r] = seed(
        client,
        helper,
        a_reminder(
            "r1", "L-groceries", "Oat milk", completed=True, completed_at="2026-10-18T09:00:00Z"
        ),
    )
    out = client.post(f"/api/reminders/{r['id']}/uncomplete").json()
    assert (out["completed"], out["completed_at"]) == (False, None)
    [op] = helper_ops(helper)
    assert (op["kind"], op["base"]) == ("uncomplete", {"completed": True})


def test_patch_queues_only_what_changes_with_due_as_one_field(client, helper):
    [r] = seed(
        client,
        helper,
        a_reminder("r1", "L-errands", "Post office", due_date="2026-10-22", due_time="09:00"),
    )
    same = client.patch(f"/api/reminders/{r['id']}", json={"title": "Post office"}).json()
    assert same["sync"]["state"] == "synced"
    assert helper_ops(helper) == []

    out = client.patch(
        f"/api/reminders/{r['id']}", json={"title": "Post office (parcel)", "due_time": "10:30"}
    ).json()
    assert (out["title"], out["due_date"], out["due_time"]) == (
        "Post office (parcel)",
        "2026-10-22",
        "10:30:00",
    )
    assert out["sync"]["pending_fields"] == ["title", "due"]
    [op] = helper_ops(helper)
    assert op["fields"] == {
        "title": "Post office (parcel)",
        "due_date": "2026-10-22",
        "due_time": "10:30",
    }
    assert op["base"] == {"title": "Post office", "due_date": "2026-10-22", "due_time": "09:00"}

    cleared = client.patch(f"/api/reminders/{r['id']}", json={"due_date": None}).json()
    assert (cleared["due_date"], cleared["due_time"]) == (None, None)
    ops = helper_ops(helper)
    # The second op's base is the first op's result: queued changes stack in order.
    assert ops[1]["fields"] == {"due_date": None, "due_time": None}
    assert ops[1]["base"] == {"due_date": "2026-10-22", "due_time": "10:30"}


def test_patch_validation(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    url = f"/api/reminders/{r['id']}"
    assert client.patch(url, json={"due_time": "10:00"}).status_code == 422
    assert client.patch(url, json={"title": "  "}).status_code == 422
    assert client.patch(url, json={"notes": None}).status_code == 422
    assert client.patch(url, json={"list_id": None}).status_code == 422
    assert client.patch(url, json={"list_id": "L-shared"}).status_code == 422
    assert client.patch(url, json={"list_id": "L-unknown"}).status_code == 422
    assert client.patch(url, json={"priority": 4}).status_code == 422
    moved = client.patch(url, json={"list_id": "L-errands"}).json()
    assert (moved["list_id"], moved["list_title"]) == ("L-errands", "Errands")
    assert helper_ops(helper)[0]["fields"] == {"list_id": "L-errands"}
    assert client.get("/api/reminders/9999").status_code == 404


def test_create_keeps_its_id_from_queue_to_mirror(client, helper, token_client, session):
    seed(client, helper)
    claude = token_client(["api"], author="claude")
    created = claude.post(
        "/api/reminders", json={"title": "Buy stamps", "due_date": "2026-10-23", "priority": 2}
    )
    assert created.status_code == 201, created.text
    new = created.json()
    assert (new["in_provider"], new["external_id"], new["list_id"]) == (
        False,
        None,
        "L-groceries",
    )
    assert new["sync"]["state"] == "syncing"

    [op] = helper_ops(helper)
    assert op["kind"] == "create"
    assert op["fields"] == {
        "title": "Buy stamps",
        "notes": "",
        "due_date": "2026-10-23",
        "due_time": None,
        "priority": 2,
        "list_id": "L-groceries",
    }
    ack(helper, op["id"], external_id="ext-new", local_id="new")
    seed(
        client,
        helper,
        a_reminder("new", "L-groceries", "Buy stamps", due_date="2026-10-23", priority=2),
    )

    mirrored = client.get(f"/api/reminders/{new['id']}").json()
    assert (mirrored["in_provider"], mirrored["external_id"]) == (True, "ext-new")
    assert mirrored["sync"]["state"] == "synced"
    assert [r["id"] for r in client.get("/api/reminders").json()] == [new["id"]]
    assert op_authors(session)[0] == ("claude", "create", None)


def test_create_with_no_list_at_all_is_refused(client):
    response = client.post("/api/reminders", json={"title": "Buy stamps"})
    assert response.status_code == 422
    assert "no reminders list" in response.json()["detail"]


def test_a_push_between_create_and_ack_folds_into_the_placeholder(client, helper):
    seed(client, helper)
    new = client.post("/api/reminders", json={"title": "Buy stamps"}).json()
    [op] = helper_ops(helper)
    seed(client, helper, a_reminder("new", "L-groceries", "Buy stamps"))
    assert len(client.get("/api/reminders").json()) == 2
    ack(helper, op["id"], external_id="ext-new", local_id="new")
    rows = client.get("/api/reminders").json()
    assert [(r["id"], r["in_provider"]) for r in rows] == [(new["id"], True)]


def test_failed_create_retry_and_withdraw(client, helper, session):
    seed(client, helper)
    new = client.post("/api/reminders", json={"title": "Buy stamps"}).json()
    [op] = helper_ops(helper)
    failed = ack(helper, op["id"], ok=False, error="list is read-only")
    assert (failed["state"], failed["error"]) == ("failed", "list is read-only")

    shown = client.get(f"/api/reminders/{new['id']}").json()
    assert (shown["sync"]["state"], shown["sync"]["error"]) == ("failed", "list is read-only")
    seed(client, helper)  # a push without it keeps a placeholder whose create failed
    assert client.get(f"/api/reminders/{new['id']}").status_code == 200
    assert client.post(f"/api/reminders/{new['id']}/complete").status_code == 409

    assert client.post(f"/api/reminders/ops/{op['id']}/retry").json()["state"] == "pending"
    assert [o["id"] for o in helper_ops(helper)] == [op["id"]]

    assert client.delete(f"/api/reminders/ops/{op['id']}").status_code == 204
    assert client.get(f"/api/reminders/{new['id']}").status_code == 404
    assert helper_ops(helper) == []
    assert ("me", "delete", None) in op_authors(session)


def test_withdrawing_an_applied_op_is_refused(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.post(f"/api/reminders/{r['id']}/complete")
    [op] = helper_ops(helper)
    ack(helper, op["id"])
    assert client.delete(f"/api/reminders/ops/{op['id']}").status_code == 409
    assert client.post(f"/api/reminders/ops/{op['id']}/retry").status_code == 409


def test_ack_is_idempotent_and_a_withdrawn_op_is_404(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.post(f"/api/reminders/{r['id']}/complete")
    [op] = helper_ops(helper)
    ack(helper, op["id"])
    again = ack(helper, op["id"], ok=False, error="late duplicate")
    assert (again["state"], again["error"]) == ("applied", None)

    client.post(f"/api/reminders/{r['id']}/uncomplete")
    [second] = helper_ops(helper)
    client.delete(f"/api/reminders/ops/{second['id']}")
    late = helper.post(f"{OPS}/{second['id']}/ack", json={"ok": True})
    assert late.status_code == 404


def test_a_reminder_deleted_in_reminders_fails_its_pending_ops(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.post(f"/api/reminders/{r['id']}/complete")
    seed(client, helper)  # gone from Apple Reminders
    assert client.get(f"/api/reminders/{r['id']}").status_code == 404
    [op] = client.get("/api/reminders/ops", params={"state": "failed"}).json()
    assert op["error"] == "the reminder is gone from Apple Reminders"
    assert helper_ops(helper) == []


# --------------------------------------------------------------------------- conflicts


def test_a_conflict_the_provider_won_shows_its_value(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.patch(f"/api/reminders/{r['id']}", json={"title": "Oat milk (2)", "priority": 1})
    [op] = helper_ops(helper)
    acked = ack(
        helper,
        op["id"],
        conflicts=[
            {
                "field": "title",
                "kept": "provider",
                "provider_value": "Oat milk x3",
                "organizer_value": "Oat milk (2)",
            }
        ],
    )
    assert acked["conflicts"][0]["kept"] == "provider"
    mid = client.get(f"/api/reminders/{r['id']}").json()
    assert (mid["title"], mid["priority"]) == ("Oat milk", 1)
    seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk x3", priority=1))
    after = client.get(f"/api/reminders/{r['id']}").json()
    assert (after["title"], after["priority"], after["sync"]["state"]) == (
        "Oat milk x3",
        1,
        "synced",
    )


# --------------------------------------------------------------------------- sync states


def test_waiting_for_the_device(client, helper, session: Session):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.post(f"/api/reminders/{r['id']}/complete")
    op = session.scalars(select(ReminderOp)).one()

    op.created_at = utcnow() - timedelta(minutes=5)
    session.commit()
    shown = client.get(f"/api/reminders/{r['id']}").json()
    assert shown["sync"]["state"] == "waiting_for_device"
    assert client.get("/api/reminders/status").json()["waiting_for_device"] is True

    helper_ops(helper)
    assert client.get(f"/api/reminders/{r['id']}").json()["sync"]["state"] == "syncing"
    status = client.get("/api/reminders/status").json()
    assert (status["helper_polling"], status["pending_ops"], status["waiting_for_device"]) == (
        True,
        1,
        False,
    )

    contact = session.get(HelperContact, "ops_poll")
    assert contact is not None
    contact.at = utcnow() - timedelta(minutes=10)
    session.commit()
    assert client.get(f"/api/reminders/{r['id']}").json()["sync"]["state"] == "waiting_for_device"


def test_a_fresh_op_is_syncing_even_with_the_helper_away(client, helper):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    out = client.post(f"/api/reminders/{r['id']}/complete").json()
    assert out["sync"]["state"] == "syncing"
    assert out["sync"]["waiting_since"] is not None


def test_mirrored_rows_are_not_audited(client, helper, session):
    seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    assert session.scalars(select(ChangeLog)).all() == []
    assert len(session.scalars(select(Reminder)).all()) == 1


def test_a_revert_of_a_queued_op_withdraws_it(client, helper, session):
    [r] = seed(client, helper, a_reminder("r1", "L-groceries", "Oat milk"))
    client.post(f"/api/reminders/{r['id']}/complete")
    change = session.scalars(select(ChangeLog).where(ChangeLog.table_name == "reminders_ops")).one()
    assert client.post(f"/api/history/{change.id}/revert").status_code == 200
    assert helper_ops(helper) == []
    assert client.get(f"/api/reminders/{r['id']}").json()["completed"] is False
