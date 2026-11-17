"""calendar() and calendar_sources(): range rendering, source filter, the trimmed items, and the
api token on every call."""

from __future__ import annotations

import asyncio
import datetime as dt
from zoneinfo import ZoneInfo

from support import API_TOKEN, FakeOrganizer, query

from organizer_mcp import server

ITEM = {
    "id": "holidays:2026-11-26",
    "source": "holidays",
    "source_label": "Holidays",
    "title": "Example Day",
    "start": "2026-11-26",
    "end": "2026-11-27",
    "all_day": True,
    "color": "#3b6fd8",
    "status": None,
    "detail_url": None,
    "read_only": True,
    "meta": {"country": "XX"},
}
EMPTY = {"start": "x", "end": "y", "items": [], "errors": []}


def test_dates_mean_local_midnight_and_sources_join(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/calendar", EMPTY)
    server.calendar(dt.date(2026, 10, 18), dt.date(2026, 10, 25), sources=["work", "holidays"])
    request = organizer.only("GET", "/api/calendar")
    assert query(request) == {
        "start": ["2026-10-18T00:00:00"],
        "end": ["2026-10-25T00:00:00"],
        "sources": ["work,holidays"],
    }
    assert request.headers["authorization"] == f"Bearer {API_TOKEN}"


def test_aware_datetimes_keep_their_offset(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/calendar", EMPTY)
    zone = ZoneInfo("America/New_York")
    server.calendar(dt.datetime(2026, 10, 18, 9, 30, tzinfo=zone), dt.datetime(2026, 10, 18, 17, 0))
    params = query(organizer.only("GET", "/api/calendar"))
    assert params["start"] == ["2026-10-18T09:30:00-04:00"]
    assert params["end"] == ["2026-10-18T17:00:00"]
    assert "sources" not in params


def test_items_are_trimmed_and_errors_are_kept(organizer: FakeOrganizer) -> None:
    organizer.reply(
        "GET",
        "/api/calendar",
        {
            "start": "2026-11-23T00:00:00",
            "end": "2026-11-30T00:00:00",
            "items": [ITEM],
            "errors": [{"source": "work", "message": "server down"}],
        },
    )
    result = server.calendar(dt.date(2026, 11, 23), dt.date(2026, 11, 30))
    assert result["items"] == [
        {
            "id": "holidays:2026-11-26",
            "source": "holidays",
            "title": "Example Day",
            "start": "2026-11-26",
            "end": "2026-11-27",
            "all_day": True,
            "status": None,
            "detail_url": None,
            "read_only": True,
        }
    ]
    assert result["errors"] == [{"source": "work", "message": "server down"}]


def test_string_inputs_from_claude_keep_their_offset(organizer: FakeOrganizer) -> None:
    # Strings arrive through the protocol layer. A bare date means local midnight, and a midnight
    # datetime keeps its offset (a date-first union would drop it).
    organizer.reply("GET", "/api/calendar", EMPTY)
    asyncio.run(
        server.app.call_tool(
            "calendar", {"start": "2026-10-18", "end": "2026-10-25T00:00:00-04:00"}
        )
    )
    params = query(organizer.only("GET", "/api/calendar"))
    assert params["start"] == ["2026-10-18T00:00:00"]
    assert params["end"] == ["2026-10-25T00:00:00-04:00"]


def test_sources_keep_key_label_and_freshness(organizer: FakeOrganizer) -> None:
    organizer.reply(
        "GET",
        "/api/calendar/sources",
        [
            {
                "key": "holidays",
                "label": "Holidays",
                "color": "#888",
                "live": True,
                "freshness": None,
            },
            {
                "key": "work",
                "label": "Work",
                "color": "#3b6fd8",
                "live": False,
                "freshness": {
                    "source": "caldav:1",
                    "label": "Work",
                    "state": "stale",
                    "last_success_at": "2026-11-15T08:00:00Z",
                    "last_attempt_at": "2026-11-16T08:00:00Z",
                    "last_error": "timed out",
                    "last_error_at": "2026-11-16T08:00:00Z",
                    "stale_after_seconds": 3600,
                },
            },
        ],
    )
    result = server.calendar_sources()
    assert result == [
        {"key": "holidays", "label": "Holidays", "live": True, "freshness": None},
        {
            "key": "work",
            "label": "Work",
            "live": False,
            "freshness": {
                "state": "stale",
                "last_success_at": "2026-11-15T08:00:00Z",
                "last_attempt_at": "2026-11-16T08:00:00Z",
                "last_error": "timed out",
                "last_error_at": "2026-11-16T08:00:00Z",
            },
        },
    ]
    request = organizer.only("GET", "/api/calendar/sources")
    assert request.headers["authorization"] == f"Bearer {API_TOKEN}"
