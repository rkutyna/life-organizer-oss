"""app.demo_seed: a fresh database gets the demo login and every module's demo data, once."""

from pathlib import Path

import pytest
from alembic import command
from fastapi.testclient import TestClient

from app import config
from app.config import Settings
from app.demo_seed import main
from app.main import create_app
from tests.test_migrations import alembic_config

PASSWORD = "demo password 1"


@pytest.fixture
def demo_db(tmp_path: Path, monkeypatch) -> str:
    url = f"sqlite:///{tmp_path / 'demo.db'}"
    command.upgrade(alembic_config(url), "head")
    monkeypatch.setenv("DATABASE_URL", url)
    config.get_settings.cache_clear()
    yield url
    config.get_settings.cache_clear()


def test_demo_seed_fills_a_fresh_install_and_refuses_twice(demo_db: str, tmp_path: Path):
    assert main(["--password", PASSWORD]) == 0
    assert main(["--password", PASSWORD]) == 1

    app = create_app(
        Settings(_env_file=None, database_url=demo_db, scheduler_enabled=False, web_dist=tmp_path)
    )
    with TestClient(app, headers={"X-Requested-With": "organizer"}) as client:
        assert client.post("/api/auth/login", json={"password": PASSWORD}).status_code == 200
        accounts = client.get("/api/settings/accounts").json()
        assert {a["label"] for a in accounts} >= {"Demo calendars", "Demo mail"}
        assert all(a["status"] == "ok" for a in accounts)
        groups = client.get("/api/calendar_ext/calendars").json()
        assert any(g["label"] == "Demo calendars" for g in groups)
        messages = client.get("/api/mail/messages").json()
        assert messages
