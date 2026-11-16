"""calendar.py: provider registry, aggregation across providers, sources and freshness."""

from datetime import date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app import calendar, freshness
from app.calendar import CalendarItem, local_date_bounds, register_provider
from app.timeutil import local_tz


def item(source: str, native_id: str, start, end, all_day=False, title="x") -> CalendarItem:
    return CalendarItem(
        id=f"{source}:{native_id}",
        source=source,
        source_label=source.title(),
        title=title,
        start=start,
        end=end,
        all_day=all_day,
        color="#000000",
        detail_url=None,
        read_only=True,
    )


@pytest.fixture
def providers(monkeypatch):
    """Replace the registry with two fake providers (one all-day, one timed)."""
    monkeypatch.setattr(calendar, "_PROVIDERS", {})
    tz = local_tz()
    calls = []

    def alpha(session: Session, start: datetime, end: datetime) -> list[CalendarItem]:
        calls.append(("alpha", start, end))
        return [
            item(
                "alpha",
                "2",
                datetime(2026, 3, 10, 9, tzinfo=tz),
                datetime(2026, 3, 10, 10, tzinfo=tz),
            ),
            item("alpha", "1", date(2026, 3, 12), date(2026, 3, 13), all_day=True),
        ]

    def beta(session: Session, start: datetime, end: datetime) -> list[CalendarItem]:
        calls.append(("beta", start, end))
        return [
            item("beta", "a", date(2026, 3, 10), date(2026, 3, 11), all_day=True),
            item(
                "beta",
                "b",
                datetime(2026, 3, 10, 8, tzinfo=tz),
                datetime(2026, 3, 10, 8, 30, tzinfo=tz),
            ),
        ]

    register_provider("alpha", "Alpha", "#111111", alpha)
    register_provider("beta", "Beta", "#222222", beta, freshness_source="beta_sync")
    return calls


def test_calendar_merges_providers_sorted(client: TestClient, providers):
    response = client.get("/api/calendar", params={"start": "2026-03-01", "end": "2026-04-01"})

    assert response.status_code == 200
    body = response.json()
    assert [i["id"] for i in body["items"]] == ["beta:a", "beta:b", "alpha:2", "alpha:1"]
    assert body["errors"] == []
    # Providers receive aware, local-time bounds.
    _, start, end = providers[0]
    assert start.tzinfo is not None and start.utcoffset() == timedelta(hours=-5)
    assert (start.date(), end.date()) == (date(2026, 3, 1), date(2026, 4, 1))


def test_calendar_source_filter(client: TestClient, providers):
    response = client.get(
        "/api/calendar", params={"start": "2026-03-01", "end": "2026-04-01", "sources": "beta"}
    )
    assert {i["source"] for i in response.json()["items"]} == {"beta"}
    assert [name for name, *_ in providers] == ["beta"]


def test_broken_provider_reports_error_without_blanking(client: TestClient, providers):
    def broken(session, start, end):
        raise RuntimeError("source down")

    register_provider("broken", "Broken", "#333333", broken)
    body = client.get("/api/calendar", params={"start": "2026-03-01", "end": "2026-04-01"}).json()

    assert len(body["items"]) == 4
    assert body["errors"] == [{"source": "broken", "message": "source down"}]


def test_calendar_rejects_bad_ranges(client: TestClient, providers):
    backwards = client.get("/api/calendar", params={"start": "2026-03-02", "end": "2026-03-01"})
    assert backwards.status_code == 400
    huge = client.get("/api/calendar", params={"start": "2020-01-01", "end": "2026-01-01"})
    assert huge.status_code == 400


def test_sources_list_colors_and_freshness(client: TestClient, session: Session, providers):
    freshness.mark_success(session, "beta_sync")

    sources = {s["key"]: s for s in client.get("/api/calendar/sources").json()}

    assert sources["alpha"] == {
        "key": "alpha",
        "label": "Alpha",
        "color": "#111111",
        "live": True,
        "freshness": None,
    }
    assert sources["beta"]["live"] is False
    assert sources["beta"]["freshness"]["state"] == "ok"
    assert sources["beta"]["freshness"]["last_success_at"] is not None


def test_local_date_bounds():
    tz = local_tz()
    assert local_date_bounds(datetime(2026, 3, 1, tzinfo=tz), datetime(2026, 3, 8, tzinfo=tz)) == (
        date(2026, 3, 1),
        date(2026, 3, 8),
    )
    # A range ending mid-day includes that day.
    assert local_date_bounds(
        datetime(2026, 3, 1, tzinfo=tz), datetime(2026, 3, 8, 12, tzinfo=tz)
    ) == (date(2026, 3, 1), date(2026, 3, 9))
