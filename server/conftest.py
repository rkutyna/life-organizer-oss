"""Shared pytest fixtures for core tests (tests/) and module tests (app/modules/*/tests/).

    def test_something(client, session):
        client.post("/api/jobs/companies", json={"name": "Acme"})   # signed-in browser
        session.scalars(select(Company))                              # direct DB reads

`client` has already run setup and is signed in, with the CSRF header on every request.
`anon` is a fresh browser with no session. `token_client(scopes, author)` makes an API token
and returns a client that sends it as a Bearer token.

Each test gets a fresh SQLite file. Tables are created from the models here (tests only);
real databases are always built by Alembic.
"""

from collections.abc import Callable, Iterator
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.config import Settings
from app.db import Base
from app.discovery import import_all_models
from app.main import create_app
from app.timeutil import set_timezone

PASSWORD = "correct horse battery"
SECRET_KEY = "test-secret-key-that-is-long-enough-0123456789"
CSRF = {"X-Requested-With": "organizer"}
SETUP = {
    "display_name": "Test Owner",
    "password": PASSWORD,
    "timezone": "America/New_York",
    "holiday_country": "US",
}


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        _env_file=None,
        database_url=f"sqlite:///{tmp_path / 'test.db'}",
        organizer_secret_key=SECRET_KEY,
        scheduler_enabled=False,
        web_dist=tmp_path / "no-web-build",
    )


@pytest.fixture
def app(settings: Settings) -> Iterator[FastAPI]:
    application = create_app(settings)
    import_all_models()
    Base.metadata.create_all(application.state.engine)
    yield application
    set_timezone(None)  # setup sets the process-wide zone; do not leak it into other tests


@pytest.fixture
def anon(app: FastAPI) -> Iterator[TestClient]:
    with TestClient(app, headers=CSRF) as test_client:
        yield test_client


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    with TestClient(app, headers=CSRF) as test_client:
        response = test_client.post("/api/auth/setup", json=SETUP)
        assert response.status_code == 200, response.text
        yield test_client


@pytest.fixture
def token_client(app: FastAPI, client: TestClient) -> Callable[..., TestClient]:
    """A factory: token_client(["api"], author="claude") -> a client using a new API token."""

    def make(scopes: list[str], author: str = "claude") -> TestClient:
        response = client.post(
            "/api/settings/tokens", json={"name": "test", "author": author, "scopes": scopes}
        )
        assert response.status_code == 201, response.text
        secret = response.json()["secret"]
        return TestClient(app, headers={"Authorization": f"Bearer {secret}"})

    return make


@pytest.fixture
def session(app: FastAPI) -> Iterator[Session]:
    with app.state.session_factory() as db_session:
        yield db_session
