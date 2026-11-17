"""POST /api/ingest/calendar: the ingest scope, replace-within-window, the list and freshness."""

from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.modules.calendar_ext.tests.support import ek_calendar, ek_event, push_body

URL = "/api/ingest/calendar"
NY = ZoneInfo("America/New_York")
MARCH = {"start": "2026-03-01T00:00:00-05:00", "end": "2026-04-01T00:00:00-04:00"}
APRIL = {"start": "2026-04-01T00:00:00-04:00", "end": "2026-05-01T00:00:00-04:00"}
MARCH_TO_APRIL = {"start": "2026-03-01T00:00:00-05:00", "end": "2026-05-01T00:00:00-04:00"}


@pytest.fixture
def helper(token_client) -> TestClient:
    return token_client(["ingest"], author="helper")


def push(helper: TestClient, body: dict):
    return helper.post(URL, json=body)


def eventkit_titles(session: Session) -> list[str]:
    session.expire_all()
    rows = session.scalars(
        select(ExternalEvent.title)
        .where(ExternalEvent.source == "eventkit")
        .order_by(ExternalEvent.title)
    )
    return list(rows)


def test_push_needs_the_ingest_scope(client: TestClient, token_client, helper: TestClient):
    body = push_body(MARCH, [], [])

    assert client.post(URL, json=body).status_code == 403  # a browser has no ingest scope
    assert token_client(["api"]).post(URL, json=body).status_code == 403
    assert push(helper, body).status_code == 200


def test_replace_keeps_rows_outside_the_window(helper: TestClient, session: Session):
    cal = ek_calendar("c1", "Work")
    march = ek_event(
        "e-march", "c1", "March", "2026-03-10T09:00:00-04:00", "2026-03-10T10:00:00-04:00"
    )
    april = ek_event(
        "e-april", "c1", "April", "2026-04-10T09:00:00-04:00", "2026-04-10T10:00:00-04:00"
    )
    assert push(helper, push_body(MARCH, [cal], [march])).status_code == 200

    # A push for April does not touch March: its window does not cover March.
    assert push(helper, push_body(APRIL, [cal], [april])).status_code == 200
    assert eventkit_titles(session) == ["April", "March"]

    # A push covering both replaces both windows' rows with what it sends.
    moved = ek_event(
        "e-march", "c1", "March moved", "2026-03-11T09:00:00-04:00", "2026-03-11T10:00:00-04:00"
    )
    assert push(helper, push_body(MARCH_TO_APRIL, [cal], [moved])).status_code == 200
    assert eventkit_titles(session) == ["March moved"]


def test_an_occurrence_that_starts_before_the_window_and_runs_into_it_is_replaced(
    helper: TestClient, session: Session
):
    cal = ek_calendar("c1", "Work")
    trip = ek_event(
        "e-trip", "c1", "Trip", "2026-02-28T09:00:00-05:00", "2026-03-02T17:00:00-05:00"
    )
    assert push(helper, push_body(MARCH, [cal], [trip])).status_code == 200
    assert eventkit_titles(session) == ["Trip"]

    assert push(helper, push_body(MARCH, [cal], [])).status_code == 200
    assert eventkit_titles(session) == []


def test_the_calendar_list_is_replaced_by_each_push(helper: TestClient, session: Session):
    first = [
        ek_calendar("c1", "Work"),
        ek_calendar("c2", "Family", account="On My Mac", account_type="local"),
    ]
    assert push(helper, push_body(MARCH, first, [])).status_code == 200
    assert push(helper, push_body(MARCH, [ek_calendar("c1", "Work")], [])).status_code == 200

    session.expire_all()
    titles = list(session.scalars(select(ExternalCalendar.title)))
    assert titles == ["Work"]


def test_all_day_rows_are_stored_as_local_midnight_of_the_day_the_helper_sent(
    helper: TestClient, session: Session
):
    # The helper sends local midnight with its own offset (here +09:00). The day is the
    # wall-clock date it sent, so the row lands on April 15 in the server's zone.
    cal = ek_calendar("c1", "Work")
    day = ek_event(
        "e-day",
        "c1",
        "Conference day",
        "2026-04-15T00:00:00+09:00",
        "2026-04-16T00:00:00+09:00",
        all_day=True,
    )
    assert push(helper, push_body(APRIL, [cal], [day])).status_code == 200

    row = session.scalars(select(ExternalEvent).where(ExternalEvent.uid == "e-day")).one()
    assert row.all_day is True
    assert row.account_id is None
    assert row.start.astimezone(NY).timetuple()[:5] == (2026, 4, 15, 0, 0)
    assert row.end.astimezone(NY).timetuple()[:5] == (2026, 4, 16, 0, 0)


def test_a_successful_push_marks_the_helper_fresh(client: TestClient, helper: TestClient):
    assert push(helper, push_body(MARCH, [ek_calendar("c1", "Work")], [])).status_code == 200

    sources = {s["source"]: s for s in client.get("/api/status/sources").json()}
    assert sources["eventkit"]["state"] == "ok"
    assert sources["eventkit"]["label"] == "Mac helper (Apple Calendar)"
    assert sources["eventkit"]["stale_after_seconds"] == 2 * 60 * 60


def test_bad_windows_and_sources_are_rejected(helper: TestClient):
    backwards = {"start": MARCH["end"], "end": MARCH["start"]}
    assert push(helper, push_body(backwards, [], [])).status_code == 422
    other_source = push_body(MARCH, [], [])
    other_source["source"] = "caldav"
    assert push(helper, other_source).status_code == 422


def test_naive_times_are_read_in_the_server_zone(helper: TestClient, session: Session):
    cal = ek_calendar("c1", "Work")
    window = {"start": "2026-03-01T00:00:00", "end": "2026-04-01T00:00:00"}
    event = ek_event("e-naive", "c1", "Naive", "2026-03-10T09:00:00", "2026-03-10T10:00:00")
    assert push(helper, push_body(window, [cal], [event])).status_code == 200

    row = session.scalars(select(ExternalEvent).where(ExternalEvent.uid == "e-naive")).one()
    assert row.start.astimezone(NY).timetuple()[:5] == (2026, 3, 10, 9, 0)
