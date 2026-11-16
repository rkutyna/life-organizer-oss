"""Alembic environment. Uses the app's settings and the full model metadata.

Generate a migration after changing models:

    uv run alembic revision --autogenerate -m "add jobs tables"
    uv run alembic upgrade head
    uv run alembic check        # fails if models and migrations disagree
"""

from logging.config import fileConfig

from alembic import context

from app.config import get_settings
from app.db import Base, UTCDateTime, make_engine
from app.discovery import import_all_models

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name, disable_existing_loggers=False)

import_all_models()
target_metadata = Base.metadata


def database_url() -> str:
    # Tests set sqlalchemy.url on the Config; everything else uses DATABASE_URL.
    return config.get_main_option("sqlalchemy.url") or get_settings().database_url


def render_item(type_, obj, autogen_context):
    """Write UTCDateTime as plain sa.DateTime() so migrations never import app code."""
    if type_ == "type" and isinstance(obj, UTCDateTime):
        return "sa.DateTime()"
    return False


def include_object(obj, name, type_, reflected, compare_to):
    """Leave out the test-only models (tables named test_*) the test suite defines."""
    table = obj if type_ == "table" else getattr(obj, "table", None)
    return not (table is not None and table.name.startswith("test_"))


def run_migrations_offline() -> None:
    context.configure(
        url=database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        render_as_batch=True,
        render_item=render_item,
        include_object=include_object,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = make_engine(database_url())
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            render_as_batch=True,  # SQLite needs batch mode for ALTER
            render_item=render_item,
            include_object=include_object,
        )
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
