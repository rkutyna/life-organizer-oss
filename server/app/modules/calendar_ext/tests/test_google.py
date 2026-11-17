"""The Google Calendar poll against an httpx.MockTransport; Google is never contacted."""

from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import httpx
import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.calendar_ext import google_sync, sync
from app.modules.calendar_ext.calendar_accounts import calendar_accounts
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.modules.calendar_ext.tests.support import GOOGLE_USER, google_account
from app.providers import google
from app.timeutil import set_timezone

NY = ZoneInfo("America/New_York")
NOW = datetime(2026, 4, 15, 12, tzinfo=UTC)
PRIMARY = GOOGLE_USER
SHARED = "team#shared@example.com"

CALENDAR_LIST = [
    {"id": PRIMARY, "summary": PRIMARY, "backgroundColor": "#9fe1e7", "accessRole": "owner"},
    {
        "id": SHARED,
        "summary": "Team",
        "summaryOverride": "Team (shared)",
        "backgroundColor": "#f83a22",
        "accessRole": "freeBusyReader",
    },
    {"id": "gone@example.com", "summary": "Gone", "deleted": True},
]
PRIMARY_EVENTS = [
    {
        "id": "abc_20260415T130000Z",
        "iCalUID": "weekly@example.com",
        "status": "confirmed",
        "summary": "Weekly sync",
        "location": "Room B",
        "htmlLink": "https://calendar.example.com/event?eid=abc",
        "start": {"dateTime": "2026-04-15T09:00:00-04:00", "timeZone": "America/New_York"},
        "end": {"dateTime": "2026-04-15T09:30:00-04:00"},
        "recurringEventId": "abc",
        "originalStartTime": {"dateTime": "2026-04-15T08:00:00-04:00"},
    },
    {
        "id": "trip",
        "iCalUID": "trip@example.com",
        "status": "tentative",
        "summary": "Trip",
        "start": {"date": "2026-04-20"},
        "end": {"date": "2026-04-23"},
    },
    {"id": "untitled", "iCalUID": "untitled@example.com", "start": {"date": "2026-04-24"}},
    {"id": "dropped", "status": "cancelled", "start": {"date": "2026-04-25"}},
]
SHARED_EVENTS = [
    {
        "id": "busy1",
        "iCalUID": "busy1@example.com",
        "start": {"dateTime": "2026-04-16T14:00:00Z"},
        "end": {"dateTime": "2026-04-16T15:00:00Z"},
    }
]


@pytest.fixture(autouse=True)
def new_york():
    set_timezone("America/New_York")
    yield
    set_timezone(None)


class FakeGoogle:
    """A Google Calendar API stand-in, serving pages of two items at most."""

    def __init__(self, fail_status: int | None = None) -> None:
        self.requests: list[httpx.Request] = []
        self.fail_status = fail_status

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        assert request.headers["authorization"] == "Bearer synthetic-access-token"
        if self.fail_status:
            body = {"error": {"message": "Request had insufficient scopes."}}
            return httpx.Response(self.fail_status, json=body)
        path = request.url.path
        if path.endswith("/users/me/calendarList"):
            return httpx.Response(200, json={"items": CALENDAR_LIST})
        if path.endswith(f"/calendars/{PRIMARY}/events"):
            return self._paged(request, PRIMARY_EVENTS)
        if path.endswith("/calendars/team#shared@example.com/events"):
            return self._paged(request, SHARED_EVENTS)
        return httpx.Response(404, json={"error": {"message": "Not Found"}})

    @staticmethod
    def _paged(request: httpx.Request, items: list[dict]) -> httpx.Response:
        page = int(request.url.params.get("pageToken") or 0)
        chunk = items[page * 2 : page * 2 + 2]
        body: dict = {"items": chunk}
        if page * 2 + 2 < len(items):
            body["nextPageToken"] = str(page + 1)
        return httpx.Response(200, json=body)


@pytest.fixture
def fake_google(monkeypatch) -> FakeGoogle:
    fake = FakeGoogle()
    monkeypatch.setattr(
        google, "access_token", lambda session, settings, account: "synthetic-access-token"
    )
    monkeypatch.setattr(
        google, "make_client", lambda: httpx.Client(transport=httpx.MockTransport(fake))
    )
    return fake


def rows(session: Session) -> dict[str, ExternalEvent]:
    return {r.uid: r for r in session.scalars(select(ExternalEvent))}


def test_reads_every_listed_calendar_with_googles_colors(
    session: Session, settings: Settings, fake_google: FakeGoogle
):
    account = google_account(session, settings)

    result = google_sync.sync_account(session, settings, account, now=NOW)

    assert (result.calendars, result.events) == (2, 4)
    calendars = {c.ext_id: c for c in session.scalars(select(ExternalCalendar))}
    assert set(calendars) == {PRIMARY, SHARED}
    assert calendars[PRIMARY].color == "#9FE1E7"
    assert calendars[SHARED].title == "Team (shared)"
    assert all(c.account == GOOGLE_USER and c.account_id == account.id for c in calendars.values())
    assert freshness.source_status(session, f"calendar:{account.id}").last_success_at == NOW


def test_events_are_single_occurrences_over_the_window(
    session: Session, settings: Settings, fake_google: FakeGoogle
):
    account = google_account(session, settings)
    google_sync.sync_account(session, settings, account, now=NOW)

    events_requests = [r for r in fake_google.requests if r.url.path.endswith("/events")]
    params = events_requests[0].url.params
    assert params["singleEvents"] == "true"
    assert params["timeMin"].startswith("2025-04-15T00:00:00")
    assert params["timeMax"].startswith("2027-04-16T00:00:00")
    assert any(r.url.params.get("pageToken") == "1" for r in events_requests)

    found = rows(session)
    weekly = found["weekly@example.com"]
    assert weekly.start.astimezone(NY).timetuple()[:5] == (2026, 4, 15, 9, 0)
    # A moved instance keeps its original slot for dedup.
    assert weekly.occurrence_start.astimezone(NY).timetuple()[:5] == (2026, 4, 15, 8, 0)
    assert (weekly.location, weekly.status) == ("Room B", "confirmed")
    assert weekly.url == "https://calendar.example.com/event?eid=abc"

    trip = found["trip@example.com"]
    assert trip.all_day and trip.status == "tentative"
    assert trip.start.astimezone(NY).timetuple()[:4] == (2026, 4, 20, 0)
    assert trip.end.astimezone(NY).timetuple()[:4] == (2026, 4, 23, 0)

    assert found["untitled@example.com"].title == "(No title)"
    assert found["busy1@example.com"].title == "Busy"  # a free/busy-only calendar
    assert "dropped" not in {r.uid for r in found.values()}


def test_an_api_error_keeps_the_previous_rows_and_is_recorded(
    session: Session, settings: Settings, fake_google: FakeGoogle
):
    account = google_account(session, settings)
    google_sync.sync_account(session, settings, account, now=NOW)
    before = len(rows(session))

    fake_google.fail_status = 403
    with pytest.raises(google_sync.GoogleCalendarError, match="insufficient scopes"):
        google_sync.sync_account(session, settings, account, now=NOW)

    assert len(rows(session)) == before
    status = freshness.source_status(session, f"calendar:{account.id}")
    assert status.state == "error"
    assert "403" in (status.last_error or "")


def test_a_refused_grant_asks_for_a_reconnect(session: Session, settings: Settings, monkeypatch):
    account = google_account(session, settings)

    def refused(session, settings, account):
        raise google.GoogleAuthError("invalid_grant")

    monkeypatch.setattr(google, "access_token", refused)

    with pytest.raises(google.GoogleAuthError):
        google_sync.sync_account(session, settings, account, now=NOW)

    error = freshness.source_status(session, f"calendar:{account.id}").last_error or ""
    assert "reconnect" in error


def test_only_accounts_that_granted_calendar_are_read(
    session: Session, settings: Settings, fake_google: FakeGoogle
):
    reader = google_account(session, settings)
    google_account(session, settings, email="mail.only@example.com", calendar=False)

    outcomes = sync.sync_all(session, settings)

    assert [(o.account_id, o.ok) for o in outcomes] == [(reader.id, True)]
    assert [c.name for c in calendar_accounts(session)] == [GOOGLE_USER]
