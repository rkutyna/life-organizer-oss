"""Reminders on /api/calendar: dated and incomplete only, read-only, in their list's color,
linked to the reminders page, with queued changes shown."""

from datetime import date

from fastapi.testclient import TestClient

from app.modules.reminders.tests.support import ERRANDS, GROCERIES, a_reminder, push, push_body


def items(client: TestClient) -> list[dict]:
    response = client.get(
        "/api/calendar",
        params={
            "start": str(date(2026, 10, 19)),
            "end": str(date(2026, 10, 26)),
            "sources": "reminders",
        },
    )
    assert response.status_code == 200, response.text
    return response.json()["items"]


def seed(helper: TestClient) -> None:
    push(
        helper,
        push_body(
            [GROCERIES, ERRANDS],
            [
                a_reminder("r1", "L-errands", "Post office", due_date="2026-10-21"),
                a_reminder("r2", "L-groceries", "Market", due_date="2026-10-22", due_time="10:15"),
                a_reminder("r3", "L-groceries", "Undated"),
                a_reminder(
                    "r4", "L-errands", "Done already", due_date="2026-10-21", completed=True
                ),
                a_reminder("r5", "L-errands", "Out of range", due_date="2026-11-30"),
            ],
        ),
    )


def test_dated_open_reminders_are_on_the_calendar(client, helper):
    seed(helper)
    found = items(client)
    assert [i["title"] for i in found] == ["Post office", "Market"]
    post, market = found
    assert (post["all_day"], post["start"], post["end"]) == (True, "2026-10-21", "2026-10-22")
    assert (market["all_day"], market["start"], market["end"]) == (
        False,
        "2026-10-22T10:15:00-04:00",
        "2026-10-22T10:45:00-04:00",
    )
    assert post["read_only"] is True
    assert post["source"] == "reminders" and post["source_label"] == "Reminders"
    assert post["color"] == "#007AFF"  # the list's own color
    assert post["detail_url"] == f"/reminders?reminder={post['meta']['reminder_id']}"
    assert (post["meta"]["list"], post["meta"]["provider"]) == ("Errands", "apple")


def test_queued_changes_show_on_the_calendar(client, helper):
    seed(helper)
    post, market = items(client)
    client.post(f"/api/reminders/{post['meta']['reminder_id']}/complete")
    client.patch(f"/api/reminders/{market['meta']['reminder_id']}", json={"due_date": "2026-10-23"})
    [moved] = items(client)
    assert (moved["title"], moved["start"][:10], moved["meta"]["sync_state"]) == (
        "Market",
        "2026-10-23",
        "syncing",
    )


def test_the_calendar_source(client, helper):
    seed(helper)
    sources = {s["key"]: s for s in client.get("/api/calendar/sources").json()}
    assert sources["reminders"]["label"] == "Reminders"
    assert sources["reminders"]["freshness"] is None  # per source on the reminders page
