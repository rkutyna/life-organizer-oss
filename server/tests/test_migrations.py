"""Alembic: `upgrade head` builds a fresh database, `downgrade base` empties it.

`test_models_match_migrations` fails when a model changed without a migration.
"""

from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect

SERVER_DIR = Path(__file__).resolve().parent.parent


def alembic_config(database_url: str) -> Config:
    config = Config(str(SERVER_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(SERVER_DIR / "migrations"))
    config.set_main_option("sqlalchemy.url", database_url)
    return config


def test_upgrade_head_on_fresh_database(tmp_path: Path):
    url = f"sqlite:///{tmp_path / 'fresh.db'}"
    config = alembic_config(url)

    command.upgrade(config, "head")
    tables = set(inspect(create_engine(url)).get_table_names())
    assert {
        "change_log",
        "source_status",
        "core_config",
        "core_sessions",
        "core_api_tokens",
        "core_provider_accounts",
        "alembic_version",
    } <= tables

    command.downgrade(config, "base")
    assert set(inspect(create_engine(url)).get_table_names()) == {"alembic_version"}


def test_models_match_migrations(tmp_path: Path):
    config = alembic_config(f"sqlite:///{tmp_path / 'check.db'}")
    command.upgrade(config, "head")
    command.check(config)  # raises if autogenerate would emit anything
