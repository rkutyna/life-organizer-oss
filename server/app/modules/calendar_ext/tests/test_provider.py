"""The `calendar_ext` source end to end: per-calendar keys and colors, all-day handling, dedup by
freshness, disabled accounts, and the calendars list grouped by account."""

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.calendar_ext.caldav_sync import RemoteCalendar, sync_account
from app.modules.calendar_ext.calendar_provider import COLOR
from app.modules.calendar_ext.tests.support import (
    FakeCalDAV,
    caldav_account,
    ek_calendar,
    ek_event,
    push_body,
    vcalendar,
    vevent,
)
from app.timeutil import utcnow

RANGE = {"start": "2026-04-01", "end": "2026-05-01", "sources": "calendar_ext"}
APRIL = {"start": "2026-04-01T00:00:00-04:00", "end": "2026-05-01T00:00:00-04:00"}
WORK_URL = "https://caldav.example.com/calendars/work/"
STANDUP_ICS = vevent(
    "standup@example.com",
    "Standup (server)",
    "DTSTART;TZID=America/New_York:20260415T090000",
    "DTEND;TZID=America/New_York:20260415T093000",
)
STANDUP_EK = ek_event(
    "standup@example.com",
    "c1",
    "Standup (helper)",
    "2026-04-15T09:00:00-04:00",
    "2026-04-15T09:30:00-04:00",
)


@pytest.fixture
def helper(token_client) -> TestClient:
    return token_client(["ingest"], author="helper")


def items(client: TestClient) -> list[dict]:
    response = client.get("/api/calendar", params=RANGE)
    assert response.status_code == 200, response.text
    return response.json()["items"]


def titles(client: TestClient) -> list[str]:
    return sorted(item["title"] for item in items(client))


def sync_work(session: Session, settings: Settings, account, *, now: datetime | None = None):
    fake = FakeCalDAV(
        remote_calendars=[RemoteCalendar(ext_id=WORK_URL, title="Work", color="#228833")],
        texts={WORK_URL: [vcalendar(STANDUP_ICS)]},
    )
    sync_account(session, settings, account, source=fake, now=now or utcnow())


def test_helper_items_keep_their_calendar_color_and_key(client: TestClient, helper: TestClient):
    body = push_body(
        APRIL,
        [ek_calendar("c1", "Work", color="#3366CC"), ek_calendar("c2", "Family", color=None)],
        [
            ek_event(
                "e1",
                "c1",
                "Standup",
                "2026-04-15T09:00:00-04:00",
                "2026-04-15T09:30:00-04:00",
                location="Room A",
                url="https://example.com/standup",
            ),
            ek_event("e2", "c2", "Lunch", "2026-04-18T12:00:00-04:00", "2026-04-18T13:00:00-04:00"),
        ],
    )
    assert helper.post("/api/ingest/calendar", json=body).status_code == 200

    found = {item["title"]: item for item in items(client)}
    standup = found["Standup"]
    assert standup["color"] == "#3366CC"
    assert found["Lunch"]["color"] == COLOR
    assert standup["source"] == "calendar_ext"
    assert standup["source_label"] == "Work"
    assert standup["read_only"] is True
    assert standup["detail_url"] == "https://example.com/standup"
    assert standup["meta"]["calendar"] == "Work"
    assert standup["meta"]["location"] == "Room A"
    assert standup["meta"]["origin"] == "eventkit"
    assert standup["meta"]["calendar_key"] != found["Lunch"]["meta"]["calendar_key"]


def test_all_day_items_are_dates_and_timed_items_keep_their_offsets(
    client: TestClient, helper: TestClient
):
    body = push_body(
        APRIL,
        [ek_calendar("c1", "Work")],
        [
            ek_event(
                "e-day",
                "c1",
                "Conference",
                "2026-04-15T00:00:00+09:00",
                "2026-04-16T00:00:00+09:00",
                all_day=True,
            ),
            STANDUP_EK,
        ],
    )
    assert helper.post("/api/ingest/calendar", json=body).status_code == 200

    found = {item["title"]: item for item in items(client)}
    assert (found["Conference"]["start"], found["Conference"]["end"]) == (
        "2026-04-15",
        "2026-04-16",
    )
    assert found["Conference"]["all_day"] is True
    assert found["Standup (helper)"]["start"] == "2026-04-15T09:00:00-04:00"


def test_dedup_follows_each_streams_freshness(
    client: TestClient, helper: TestClient, session: Session, settings: Settings
):
    account = caldav_account(session, settings)
    sync_work(session, settings, account)
    body = push_body(APRIL, [ek_calendar("c1", "Work")], [STANDUP_EK])
    assert helper.post("/api/ingest/calendar", json=body).status_code == 200

    # Both fresh: the helper's copy wins.
    assert titles(client) == ["Standup (helper)"]
    [item] = items(client)
    key, item_id = item["meta"]["calendar_key"], item["id"]

    # Helper stale, server fresh: the server's copy, with the same id and calendar key.
    freshness.mark_success(session, "eventkit", at=utcnow() - timedelta(hours=3))
    [item] = items(client)
    assert item["title"] == "Standup (server)"
    assert (item["meta"]["calendar_key"], item["id"]) == (key, item_id)
    assert item["color"] == "#228833"
    assert item["meta"]["account"] == "iCloud"

    # Both stale: still one copy, the server's.
    freshness.mark_success(session, f"calendar:{account.id}", at=utcnow() - timedelta(hours=2))
    assert titles(client) == ["Standup (server)"]


def test_a_disabled_account_hides_its_events_and_the_helper_fills_in(
    client: TestClient, helper: TestClient, session: Session, settings: Settings
):
    account = caldav_account(session, settings)
    sync_work(session, settings, account)
    body = push_body(APRIL, [ek_calendar("c1", "Work")], [STANDUP_EK])
    assert helper.post("/api/ingest/calendar", json=body).status_code == 200
    freshness.mark_success(session, "eventkit", at=utcnow() - timedelta(hours=3))
    assert titles(client) == ["Standup (server)"]

    disabled = client.patch(f"/api/settings/accounts/{account.id}", json={"enabled": False})
    assert disabled.status_code == 200

    assert titles(client) == ["Standup (helper)"]
    assert client.get("/api/calendar_ext/calendars").json()[0]["label"] == "On this Mac"


def test_calendars_are_grouped_by_account_with_freshness(
    client: TestClient, helper: TestClient, session: Session, settings: Settings
):
    account = caldav_account(session, settings, label="Personal")
    sync_work(session, settings, account, now=datetime(2026, 4, 15, 12, tzinfo=UTC))
    body = push_body(
        APRIL,
        [
            ek_calendar("c1", "Work"),  # the same iCloud calendar: folded into the account
            ek_calendar("c2", "Notes", account="On My Mac", account_type="local", color="#AA0000"),
        ],
        [],
    )
    assert helper.post("/api/ingest/calendar", json=body).status_code == 200

    groups = client.get("/api/calendar_ext/calendars").json()

    assert [(g["label"], g["kind"], g["account_id"]) for g in groups] == [
        ("Personal", "caldav", account.id),
        ("On this Mac", "eventkit", None),
    ]
    personal, mac = groups
    assert [(c["title"], c["color"]) for c in personal["calendars"]] == [("Work", "#228833")]
    assert personal["freshness"]["source"] == f"calendar:{account.id}"
    assert personal["freshness"]["state"] == "stale"
    assert [(c["title"], c["color"]) for c in mac["calendars"]] == [("Notes", "#AA0000")]
    assert mac["freshness"]["state"] == "ok"


def test_no_data_gives_no_items_and_no_groups(client: TestClient):
    assert items(client) == []
    assert client.get("/api/calendar_ext/calendars").json() == []


def test_the_source_is_listed_as_mirrored(client: TestClient):
    sources = {s["key"]: s for s in client.get("/api/calendar/sources").json()}
    assert sources["calendar_ext"]["live"] is False
