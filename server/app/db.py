"""Database: declarative `Base`, the `OwnedMixin` for organizer-owned tables, engine and sessions.

Conventions every model follows:

- Subclass `Base` and use typed columns: `name: Mapped[str] = mapped_column(String(200))`.
- `Mapped[datetime]` is stored as UTC and comes back as an aware UTC datetime (see
  `UTCDateTime`). Pass aware datetimes only (`app.timeutil.utcnow()`); naive ones raise.
- Table names are `<module>_<plural>`, e.g. `reminders_items`, `jobs_applications`.
- An organizer-owned table also mixes in `OwnedMixin` and is written only through
  `app.audit` (create/update/delete). Mirrored caches do not use `OwnedMixin`.

Soft delete: `audit.delete()` sets `deleted_at` instead of removing the row, so a delete can
be reverted. ORM queries hide soft-deleted rows automatically (see `_hide_soft_deleted`
below); you never need `.where(Model.deleted_at.is_(None))`. To see deleted rows, pass
`execution_options={"include_deleted": True}`.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import DateTime, Engine, MetaData, String, create_engine, event
from sqlalchemy.engine import make_url
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    ORMExecuteState,
    Session,
    mapped_column,
    sessionmaker,
    with_loader_criteria,
)
from sqlalchemy.types import TypeDecorator

from app.timeutil import utcnow


class UTCDateTime(TypeDecorator[datetime]):
    """Stores aware datetimes as naive UTC; returns them as aware UTC."""

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("naive datetime given to a UTCDateTime column; use timeutil.utcnow()")
        return value.astimezone(UTC).replace(tzinfo=None)

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        return value.replace(tzinfo=UTC)


# Stable constraint names, so Alembic batch migrations on SQLite can find them.
NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    type_annotation_map = {datetime: UTCDateTime}


class OwnedMixin:
    """Columns every organizer-owned table carries. Set by `app.audit`, never by hand."""

    created_at: Mapped[datetime] = mapped_column(default=utcnow)
    created_by: Mapped[str] = mapped_column(String(16), default="system")
    updated_at: Mapped[datetime] = mapped_column(default=utcnow, onupdate=utcnow)
    deleted_at: Mapped[datetime | None] = mapped_column(default=None, index=True)


@event.listens_for(Session, "do_orm_execute")
def _hide_soft_deleted(state: ORMExecuteState) -> None:
    """Add `deleted_at IS NULL` for every OwnedMixin entity in ORM SELECTs."""
    if (
        state.is_select
        and not state.is_column_load
        and not state.is_relationship_load
        and not state.execution_options.get("include_deleted", False)
    ):
        state.statement = state.statement.options(
            with_loader_criteria(
                OwnedMixin,
                lambda cls: cls.deleted_at.is_(None),
                include_aliases=True,
            )
        )


def make_engine(database_url: str) -> Engine:
    """Engine for the given URL. SQLite gets WAL, foreign keys and a busy timeout."""
    url = make_url(database_url)
    if url.get_backend_name() != "sqlite":
        return create_engine(database_url)

    if url.database and url.database != ":memory:":
        Path(url.database).parent.mkdir(parents=True, exist_ok=True)
    engine = create_engine(database_url, connect_args={"check_same_thread": False})

    @event.listens_for(engine, "connect")
    def _sqlite_pragmas(dbapi_connection, _record) -> None:
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.execute("PRAGMA busy_timeout=5000")
        cursor.close()

    return engine


def make_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine)


@contextmanager
def session_scope(factory: sessionmaker[Session]) -> Iterator[Session]:
    """A session for scripts and background jobs. Rolls back on error, always closes.

    Writes still go through `app.audit`, which commits.
    """
    session = factory()
    try:
        yield session
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
