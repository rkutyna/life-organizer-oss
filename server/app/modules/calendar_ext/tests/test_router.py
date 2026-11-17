"""Connecting a CalDAV account (iCloud preset or any server), and sync now."""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.modules.calendar_ext import caldav_sync
from app.modules.calendar_ext.caldav_sync import LoginFailed, RemoteCalendar
from app.modules.calendar_ext.models import ExternalEvent
from app.modules.calendar_ext.tests.support import FakeCalDAV, vcalendar, vevent
from app.providers import service as accounts

URL = "/api/calendar_ext/accounts/caldav"
WORK_URL = "https://caldav.example.com/calendars/work/"
ICLOUD = {"preset": "icloud", "username": "someone@example.com", "password": "abcd-efgh-ijkl"}
GENERIC = {
    "preset": "caldav",
    "url": "https://dav.example.com/dav/",
    "username": "someone",
    "password": "synthetic-password",
}
EVENT = vevent(
    "e1@example.com",
    "Planning",
    "DTSTART;TZID=America/New_York:20260415T090000",
    "DTEND;TZID=America/New_York:20260415T100000",
)


@pytest.fixture
def connections(monkeypatch) -> list[tuple]:
    """Every connect() call; the fake refuses the password "wrong"."""
    seen: list[tuple] = []

    def fake_connect(url, username, password):
        seen.append((url, username, password))
        if password == "wrong":
            return FakeCalDAV(fail_with=LoginFailed("refused"))
        if "down" in url:
            return FakeCalDAV(fail_with=ConnectionRefusedError("refused"))
        return FakeCalDAV(
            remote_calendars=[RemoteCalendar(WORK_URL, "Work", "#3366CC")],
            texts={WORK_URL: [vcalendar(EVENT)]},
        )

    monkeypatch.setattr(caldav_sync, "connect", fake_connect)
    return seen


def test_icloud_tests_the_login_saves_the_account_and_syncs_it(
    client: TestClient, session: Session, settings: Settings, connections
):
    response = client.post(URL, json=ICLOUD)

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["label"] == "iCloud" and body["calendars"] == 1
    assert connections[0] == ("https://caldav.icloud.com", "someone@example.com", "abcd-efgh-ijkl")

    [account] = accounts.accounts(session, "caldav")
    assert accounts.config(account) == {
        "preset": "icloud",
        "url": "https://caldav.icloud.com",
        "username": "someone@example.com",
    }
    assert accounts.credentials(settings, account) == {"password": "abcd-efgh-ijkl"}
    assert "abcd-efgh-ijkl" not in response.text
    # The first sync ran in the background.
    assert [e.title for e in session.scalars(select(ExternalEvent))] == ["Planning"]
    labels = {s["source"]: s["label"] for s in client.get("/api/status/sources").json()}
    assert labels[f"calendar:{account.id}"] == "iCloud calendars"


def test_a_generic_server_is_labelled_by_its_host_unless_named(
    client: TestClient, session: Session, connections
):
    assert client.post(URL, json=GENERIC).json()["label"] == "dav.example.com"
    other = {**GENERIC, "username": "someone-else", "label": "Team calendars"}
    assert client.post(URL, json=other).json()["label"] == "Team calendars"
    assert connections[0][0] == "https://dav.example.com/dav/"


def test_a_refused_login_saves_nothing_and_says_why(
    client: TestClient, session: Session, connections
):
    icloud = client.post(URL, json={**ICLOUD, "password": "wrong"})
    generic = client.post(URL, json={**GENERIC, "password": "wrong"})

    assert icloud.status_code == 400
    assert "app-specific password" in icloud.json()["detail"]
    assert generic.status_code == 400
    assert generic.json()["detail"] == "The server refused the username or password."
    assert accounts.accounts(session, "caldav") == []


def test_an_unreachable_server_is_reported_plainly(client: TestClient, connections):
    response = client.post(URL, json={**GENERIC, "url": "https://down.example.com/"})

    assert response.status_code == 400
    assert response.json()["detail"].startswith("Could not reach down.example.com.")


def test_a_server_that_is_not_caldav_is_reported_without_the_password(
    client: TestClient, monkeypatch
):
    def odd_server(url, username, password):
        return FakeCalDAV(fail_with=ValueError(f"unexpected answer for {password}"))

    monkeypatch.setattr(caldav_sync, "connect", odd_server)
    response = client.post(URL, json=GENERIC)

    assert response.status_code == 400
    detail = response.json()["detail"]
    assert detail.startswith("dav.example.com did not answer as a CalDAV server")
    assert "synthetic-password" not in detail


@pytest.mark.parametrize(
    "url",
    [None, "", "dav.example.com", "ftp://dav.example.com/", "https://user:secret@example.com/"],
)
def test_a_bad_server_address_is_refused_before_connecting(client: TestClient, connections, url):
    response = client.post(URL, json={**GENERIC, "url": url})

    assert response.status_code == 400
    assert connections == []


def test_the_same_account_cannot_be_connected_twice(client: TestClient, connections):
    assert client.post(URL, json=ICLOUD).status_code == 201
    again = client.post(URL, json={**ICLOUD, "username": "SOMEONE@example.com"})
    assert again.status_code == 409


def test_connecting_is_browser_only(token_client, connections):
    assert token_client(["api"]).post(URL, json=ICLOUD).status_code == 403
    assert connections == []


def test_sync_now_reports_each_account(client: TestClient, connections):
    created = client.post(URL, json=ICLOUD).json()

    outcomes = client.post("/api/calendar_ext/sync").json()

    assert outcomes == [{"account_id": created["id"], "ok": True, "events": 1, "error": None}]


def test_plain_http_is_refused_except_on_this_machine(client, connections):
    body = {"preset": "caldav", "username": "demo", "password": "secret-pass"}
    refused = client.post(URL, json={**body, "url": "http://dav.example.com/cal/"})
    assert refused.status_code == 400 and "https://" in refused.json()["detail"]
    assert connections == []
    local = client.post(URL, json={**body, "url": "http://localhost:5232/demo/"})
    assert local.status_code == 201
