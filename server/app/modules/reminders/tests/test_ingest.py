"""POST /api/ingest/reminders: the ingest scope, replace semantics, stable ids and freshness."""

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.modules.reminders.models import Reminder
from app.modules.reminders.tests.support import (
    ERRANDS,
    GROCERIES,
    OPS,
    PUSH,
    SHARED,
    a_reminder,
    push,
    push_body,
)


def titles(client: TestClient, **params) -> list[str]:
    response = client.get("/api/reminders", params=params)
    assert response.status_code == 200, response.text
    return [r["title"] for r in response.json()]


def test_ingest_needs_the_ingest_scope(client: TestClient, token_client, helper: TestClient):
    body = push_body([GROCERIES], [])
    assert client.post(PUSH, json=body).status_code == 403  # a browser has no ingest scope
    assert token_client(["api"]).post(PUSH, json=body).status_code == 403
    assert token_client(["api"]).get(OPS).status_code == 403
    assert TestClient(client.app).post(PUSH, json=body).status_code == 401
    assert helper.post(PUSH, json=body).status_code == 200


def test_snapshot_replaces_lists_and_reminders(client, helper, session: Session):
    push(
        helper,
        push_body(
            [GROCERIES, ERRANDS],
            [
                a_reminder("r1", "L-groceries", "Oat milk"),
                a_reminder("r2", "L-errands", "Return library book", due_date="2026-10-21"),
            ],
            default_list_id="L-errands",
        ),
    )
    lists = client.get("/api/reminders/lists").json()
    assert [(lst["id"], lst["title"], lst["is_default"], lst["source"]) for lst in lists] == [
        ("L-groceries", "Groceries", False, "apple"),
        ("L-errands", "Errands", True, "apple"),
    ]
    assert all(lst["supports_time"] and lst["supports_priority"] for lst in lists)
    assert titles(client) == ["Return library book", "Oat milk"]

    push(helper, push_body([GROCERIES], [a_reminder("r2", "L-groceries", "Moved")]))
    assert [lst["title"] for lst in client.get("/api/reminders/lists").json()] == ["Groceries"]
    assert titles(client) == ["Moved"]
    assert len(session.scalars(select(Reminder)).all()) == 1


def test_a_reminder_keeps_its_id_across_pushes(client, helper):
    push(helper, push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs")]))
    first = client.get("/api/reminders").json()[0]["id"]
    push(helper, push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs x12")]))
    again = client.get("/api/reminders").json()[0]
    assert (again["id"], again["title"]) == (first, "Eggs x12")


def test_an_external_id_that_arrives_late_keeps_the_row(client, helper):
    push(
        helper, push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs", external_id=None)])
    )
    first = client.get("/api/reminders").json()[0]
    assert first["external_id"] is None
    push(helper, push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs")]))
    again = client.get("/api/reminders").json()[0]
    assert (again["id"], again["external_id"]) == (first["id"], "ext-r1")


def test_filters_list_completed_and_dated(client, helper):
    push(
        helper,
        push_body(
            [GROCERIES, ERRANDS],
            [
                a_reminder("r1", "L-groceries", "Oat milk"),
                a_reminder("r2", "L-errands", "Post office", due_date="2026-10-22"),
                a_reminder(
                    "r3",
                    "L-errands",
                    "Dry cleaning",
                    completed=True,
                    completed_at="2026-10-18T10:00:00-04:00",
                ),
            ],
        ),
    )
    assert titles(client) == ["Post office", "Oat milk"]
    assert titles(client, include_completed=True) == ["Post office", "Oat milk", "Dry cleaning"]
    assert titles(client, list="L-errands") == ["Post office"]
    assert titles(client, dated=True) == ["Post office"]
    assert titles(client, dated=False) == ["Oat milk"]
    lists = {lst["id"]: lst["open_count"] for lst in client.get("/api/reminders/lists").json()}
    assert lists == {"L-groceries": 1, "L-errands": 1}


def test_values_are_stored_as_sent(client, helper):
    push(
        helper,
        push_body(
            [ERRANDS, SHARED],
            [
                a_reminder(
                    "r1",
                    "L-errands",
                    "Pick up parcel",
                    notes="Counter 3",
                    due_date="2026-10-22",
                    due_time="17:30",
                    priority=1,
                )
            ],
        ),
    )
    r = client.get("/api/reminders").json()[0]
    assert (r["notes"], r["due_date"], r["due_time"], r["priority"]) == (
        "Counter 3",
        "2026-10-22",
        "17:30:00",
        1,
    )
    assert (r["list_title"], r["list_color"], r["in_provider"], r["source"]) == (
        "Errands",
        "#007AFF",
        True,
        "apple",
    )
    assert r["sync"]["state"] == "synced"
    shared = [lst for lst in client.get("/api/reminders/lists").json() if lst["id"] == "L-shared"]
    assert shared[0]["writable"] is False


def test_a_push_marks_the_helper_fresh(client, helper):
    push(helper, push_body([GROCERIES], []))
    sources = {s["source"]: s for s in client.get("/api/status/sources").json()}
    assert sources["reminders"]["label"] == "Mac helper (Apple Reminders)"
    assert sources["reminders"]["state"] == "ok"
    status = client.get("/api/reminders/status").json()
    assert status["helper"]["state"] == "ok"
    assert status["google"] == []


def test_a_bad_push_is_refused_and_keeps_the_mirror(client, helper):
    push(helper, push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs")]))
    bad = push_body([GROCERIES], [a_reminder("r1", "L-groceries", "Eggs", priority=7)])
    assert helper.post(PUSH, json=bad).status_code == 422
    assert titles(client) == ["Eggs"]
