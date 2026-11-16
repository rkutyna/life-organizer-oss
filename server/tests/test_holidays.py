"""The built-in holidays source: the owner's country, or nothing."""

from datetime import date, datetime

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.holidays_provider import holiday_items, supported_countries
from app.timeutil import local_tz


def nov_2026(session: Session):
    tz = local_tz()
    return holiday_items(
        session, datetime(2026, 11, 1, tzinfo=tz), datetime(2026, 12, 1, tzinfo=tz)
    )


def test_us_november_2026(client: TestClient, session: Session):
    items = nov_2026(session)

    by_day = {i.start: i for i in items}
    assert set(by_day) == {date(2026, 11, 11), date(2026, 11, 26)}
    thanksgiving = by_day[date(2026, 11, 26)]
    assert thanksgiving.id == "holidays:2026-11-26"
    assert thanksgiving.title == "Thanksgiving Day"
    assert thanksgiving.all_day and thanksgiving.read_only
    assert thanksgiving.end == date(2026, 11, 27)


def test_observed_day_is_included(client: TestClient, session: Session):
    # July 4, 2026 is a Saturday; the day off is Friday July 3.
    tz = local_tz()
    items = holiday_items(session, datetime(2026, 7, 1, tzinfo=tz), datetime(2026, 7, 8, tzinfo=tz))

    observed = [i for i in items if i.meta["observed"]]
    assert [i.start for i in observed] == [date(2026, 7, 3)]


def test_no_country_means_no_holidays(client: TestClient, session: Session):
    assert client.patch("/api/settings", json={"holiday_country": None}).status_code == 200
    session.expire_all()
    assert nov_2026(session) == []


def test_before_setup_there_are_no_holidays(app, session: Session):
    assert nov_2026(session) == []


def test_another_country(client: TestClient, session: Session):
    client.patch("/api/settings", json={"holiday_country": "GB"})
    session.expire_all()
    tz = local_tz()
    items = holiday_items(
        session, datetime(2026, 12, 20, tzinfo=tz), datetime(2027, 1, 5, tzinfo=tz)
    )
    assert {i.start for i in items} >= {date(2026, 12, 25), date(2026, 12, 28), date(2027, 1, 1)}


def test_supported_countries_have_names():
    countries = supported_countries()
    assert countries["US"] == "United States"
    assert "GB" in countries and "DE" in countries


def test_holidays_through_calendar_api(client: TestClient):
    response = client.get(
        "/api/calendar",
        params={"start": "2026-11-01", "end": "2026-12-01", "sources": "holidays"},
    )
    items = response.json()["items"]
    assert [i["start"] for i in items] == ["2026-11-11", "2026-11-26"]
    assert all(i["source"] == "holidays" for i in items)
