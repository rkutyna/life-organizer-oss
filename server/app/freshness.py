"""Freshness of mirrored sources: when each one last synced, and whether it is stale.

Every mirrored source (EventKit push, CalDAV poll, Google sync, IMAP poll, ...)
registers once at import time and reports each sync:

    from app import freshness

    freshness.register_source("caldav", "iCloud (CalDAV)", stale_after=timedelta(minutes=45))

    try:
        ...store the new snapshot...
        freshness.mark_success(session, "caldav")      # commits the session
    except Exception as exc:
        session.rollback()
        freshness.mark_error(session, "caldav", str(exc))  # commits
        raise

`GET /api/status/sources` lists every registered source with its state.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

from fastapi import APIRouter
from pydantic import BaseModel
from sqlalchemy import String, Text, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.db import Base
from app.deps import SessionDep
from app.timeutil import utcnow

FreshnessState = Literal["ok", "stale", "error", "never"]


class SourceStatus(Base):
    """Last sync result per mirrored source. Bookkeeping, not an owned record."""

    __tablename__ = "source_status"

    source: Mapped[str] = mapped_column(String(64), primary_key=True)
    last_success_at: Mapped[datetime | None]
    last_attempt_at: Mapped[datetime | None]
    last_error: Mapped[str | None] = mapped_column(Text)
    last_error_at: Mapped[datetime | None]


@dataclass(frozen=True)
class FreshnessSource:
    key: str
    label: str
    stale_after: timedelta


_SOURCES: dict[str, FreshnessSource] = {}


def register_source(key: str, label: str, stale_after: timedelta = timedelta(hours=1)) -> None:
    """Declare a mirrored source so the status endpoint lists it, even before its first sync."""
    _SOURCES[key] = FreshnessSource(key=key, label=label, stale_after=stale_after)


def registered_sources() -> dict[str, FreshnessSource]:
    return dict(_SOURCES)


def forget_source(session: Session, key: str) -> None:
    """Drop a source that no longer exists (e.g. a removed account) and its status row.

    Does not commit."""
    _SOURCES.pop(key, None)
    row = session.get(SourceStatus, key)
    if row is not None:
        session.delete(row)


def mark_success(session: Session, source: str, at: datetime | None = None) -> None:
    """Record a successful sync of `source` and commit the session."""
    when = at or utcnow()
    row = _row(session, source)
    row.last_success_at = when
    row.last_attempt_at = when
    # A recovered source must not keep showing its old error (e.g. "not configured").
    row.last_error = None
    row.last_error_at = None
    session.commit()


def mark_error(session: Session, source: str, message: str) -> None:
    """Record a failed sync of `source` and commit the session."""
    when = utcnow()
    row = _row(session, source)
    row.last_attempt_at = when
    row.last_error = message[:2000]
    row.last_error_at = when
    session.commit()


class SourceStatusOut(BaseModel):
    source: str
    label: str
    state: FreshnessState
    last_success_at: datetime | None
    last_attempt_at: datetime | None
    last_error: str | None
    last_error_at: datetime | None
    stale_after_seconds: int


def source_status(session: Session, source: str) -> SourceStatusOut:
    """Current freshness of one source (registered or not)."""
    registered = _SOURCES.get(source) or FreshnessSource(source, source, timedelta(hours=1))
    row = session.get(SourceStatus, source)
    return _to_out(registered, row)


def all_statuses(session: Session) -> list[SourceStatusOut]:
    """Every registered source plus any source that has reported without registering."""
    rows = {row.source: row for row in session.scalars(select(SourceStatus))}
    keys = list(_SOURCES) + sorted(k for k in rows if k not in _SOURCES)
    out = []
    for key in keys:
        registered = _SOURCES.get(key) or FreshnessSource(key, key, timedelta(hours=1))
        out.append(_to_out(registered, rows.get(key)))
    return out


def _to_out(source: FreshnessSource, row: SourceStatus | None) -> SourceStatusOut:
    state: FreshnessState
    if row is None or row.last_success_at is None:
        state = "error" if row is not None and row.last_error_at else "never"
    elif row.last_error_at and row.last_error_at > row.last_success_at:
        state = "error"
    elif utcnow() - row.last_success_at > source.stale_after:
        state = "stale"
    else:
        state = "ok"
    return SourceStatusOut(
        source=source.key,
        label=source.label,
        state=state,
        last_success_at=row.last_success_at if row else None,
        last_attempt_at=row.last_attempt_at if row else None,
        last_error=row.last_error if row else None,
        last_error_at=row.last_error_at if row else None,
        stale_after_seconds=int(source.stale_after.total_seconds()),
    )


def _row(session: Session, source: str) -> SourceStatus:
    row = session.get(SourceStatus, source)
    if row is None:
        row = SourceStatus(source=source)
        session.add(row)
    return row


router = APIRouter(prefix="/api/status", tags=["status"])


@router.get("/sources", response_model=list[SourceStatusOut])
def list_source_status(session: SessionDep) -> list[SourceStatusOut]:
    """Freshness of every mirrored source."""
    return all_statuses(session)
