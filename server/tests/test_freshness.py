"""freshness.py: source_status bookkeeping and /api/status/sources."""

from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app import freshness
from app.timeutil import utcnow


@pytest.fixture(autouse=True)
def isolated_registry(monkeypatch):
    monkeypatch.setattr(freshness, "_SOURCES", {})
    freshness.register_source("caldav", "iCloud (CalDAV)", stale_after=timedelta(minutes=45))


def states(client: TestClient) -> dict[str, str]:
    return {s["source"]: s["state"] for s in client.get("/api/status/sources").json()}


def test_registered_source_starts_as_never(client: TestClient):
    [status] = client.get("/api/status/sources").json()
    assert status["source"] == "caldav"
    assert status["label"] == "iCloud (CalDAV)"
    assert status["state"] == "never"
    assert status["stale_after_seconds"] == 45 * 60


def test_success_then_error_then_success(client: TestClient, session: Session):
    freshness.mark_success(session, "caldav")
    assert states(client)["caldav"] == "ok"

    freshness.mark_error(session, "caldav", "401 Unauthorized")
    status = client.get("/api/status/sources").json()[0]
    assert status["state"] == "error"
    assert status["last_error"] == "401 Unauthorized"

    freshness.mark_success(session, "caldav")
    assert states(client)["caldav"] == "ok"


def test_old_success_is_stale(client: TestClient, session: Session):
    freshness.mark_success(session, "caldav", at=utcnow() - timedelta(hours=2))
    assert states(client)["caldav"] == "stale"


def test_unregistered_source_that_reported_is_listed(client: TestClient, session: Session):
    freshness.mark_success(session, "eventkit")
    assert states(client) == {"caldav": "never", "eventkit": "ok"}


def test_success_clears_the_previous_error(client: TestClient, session: Session):
    freshness.mark_error(session, "probe", "not configured")
    freshness.mark_success(session, "probe")

    row = next(s for s in client.get("/api/status/sources").json() if s["source"] == "probe")
    assert row["state"] == "ok"
    assert row["last_error"] is None
