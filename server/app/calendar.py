"""The unified calendar: the `CalendarItem` schema, the provider registry and `/api/calendar`.

A module puts things on the calendar by registering a provider in its
`calendar_provider.py` (imported automatically at startup):

    from app.calendar import CalendarItem, local_date_bounds, register_provider

    SOURCE_KEY = "interviews"
    SOURCE_LABEL = "Interviews"
    COLOR = "#3b6fd8"

    def interview_items(session: Session, start: datetime, end: datetime) -> list[CalendarItem]:
        ...return items that overlap [start, end)...

    register_provider(SOURCE_KEY, SOURCE_LABEL, COLOR, interview_items)

A provider receives an open session and an aware, local-time, half-open range
[start, end). It returns `CalendarItem`s whose `id` is `"<source>:<native id>"`. All-day
items use `date` values with an exclusive `end` (a one-day item on Nov 26 has
start=2026-11-26, end=2026-11-27); timed items use aware datetimes.

Mirrored sources pass `freshness_source="<source_status key>"` so the calendar can show
their "as of"; owned and computed sources are live and leave it out.
"""

import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from app import freshness
from app.deps import SessionDep
from app.timeutil import local_tz, to_local

log = logging.getLogger(__name__)

MAX_RANGE = timedelta(days=740)


class CalendarItem(BaseModel):
    """One thing on the calendar. Every provider returns these."""

    # Fields with defaults are still always present in responses (and required in the
    # generated TypeScript type).
    model_config = ConfigDict(json_schema_serialization_defaults_required=True)

    id: str = Field(description='"<source>:<native id>", unique across the calendar')
    source: str = Field(description="Provider key, e.g. 'holidays', 'interviews'")
    source_label: str
    title: str
    start: datetime | date = Field(description="Aware datetime, or a date when all_day")
    end: datetime | date = Field(description="Exclusive end; for all-day items the next day")
    all_day: bool
    color: str = Field(description="CSS color for this item (hex)")
    status: str | None = Field(default=None, description="Source-specific, e.g. open/done")
    detail_url: str | None = Field(
        description="Where to see the item: an app path for owned items, a URL for mirrored"
    )
    read_only: bool
    meta: dict[str, Any] = Field(default_factory=dict, description="Source-specific extras")


class ProviderError(BaseModel):
    source: str
    message: str


ProviderFn = Callable[[Session, datetime, datetime], list[CalendarItem]]


@dataclass(frozen=True)
class CalendarSource:
    key: str
    label: str
    color: str
    fn: ProviderFn
    freshness_source: str | None = None


_PROVIDERS: dict[str, CalendarSource] = {}


def register_provider(
    source_key: str,
    label: str,
    color: str,
    fn: ProviderFn,
    *,
    freshness_source: str | None = None,
) -> None:
    """Add a calendar source. Re-registering the same key replaces it."""
    _PROVIDERS[source_key] = CalendarSource(source_key, label, color, fn, freshness_source)


def registered_providers() -> dict[str, CalendarSource]:
    return dict(_PROVIDERS)


def local_date_bounds(start: datetime, end: datetime) -> tuple[date, date]:
    """The local dates touched by [start, end), as a half-open [first_day, stop_day)."""
    start_local, end_local = to_local(start), to_local(end)
    stop = end_local.date()
    if end_local.time() != time.min:
        stop += timedelta(days=1)
    return start_local.date(), stop


def sort_key(item: CalendarItem) -> tuple[datetime, bool, str]:
    """All-day items first within a day, then by start, then title."""
    start = item.start
    if not isinstance(start, datetime):
        start = datetime.combine(start, time.min, tzinfo=local_tz())
    return (start, not item.all_day, item.title)


def collect(
    session: Session,
    start: datetime,
    end: datetime,
    sources: list[str] | None = None,
) -> tuple[list[CalendarItem], list[ProviderError]]:
    """Run every (selected) provider over [start, end) and merge the results."""
    start, end = to_local(start), to_local(end)
    items: list[CalendarItem] = []
    errors: list[ProviderError] = []
    for key, source in _PROVIDERS.items():
        if sources is not None and key not in sources:
            continue
        try:
            items.extend(source.fn(session, start, end))
        except Exception as exc:  # one broken source must not blank the calendar
            log.exception("calendar provider %s failed", key)
            session.rollback()
            errors.append(ProviderError(source=key, message=str(exc) or type(exc).__name__))
    items.sort(key=sort_key)
    return items, errors


# --------------------------------------------------------------------------- API


class CalendarResponse(BaseModel):
    start: datetime
    end: datetime
    items: list[CalendarItem]
    errors: list[ProviderError]


class CalendarSourceOut(BaseModel):
    key: str
    label: str
    color: str
    live: bool = Field(description="True when computed from owned data (always current)")
    freshness: freshness.SourceStatusOut | None


router = APIRouter(prefix="/api/calendar", tags=["calendar"])


@router.get("", response_model=CalendarResponse)
def get_calendar(
    session: SessionDep,
    start: datetime = Query(description="Range start (ISO date or datetime)"),
    end: datetime = Query(description="Range end, exclusive"),
    sources: str | None = Query(None, description="Comma-separated source keys; default all"),
) -> CalendarResponse:
    """Every source's items overlapping [start, end), merged and sorted."""
    start, end = to_local(start), to_local(end)
    if end <= start:
        raise HTTPException(400, "end must be after start")
    if end - start > MAX_RANGE:
        raise HTTPException(400, "range too large (max ~2 years)")
    wanted = [s for s in sources.split(",") if s] if sources else None
    items, errors = collect(session, start, end, wanted)
    return CalendarResponse(start=start, end=end, items=items, errors=errors)


@router.get("/sources", response_model=list[CalendarSourceOut])
def list_sources(session: SessionDep) -> list[CalendarSourceOut]:
    """Every calendar source with its color and freshness."""
    return [
        CalendarSourceOut(
            key=s.key,
            label=s.label,
            color=s.color,
            live=s.freshness_source is None,
            freshness=(
                freshness.source_status(session, s.freshness_source) if s.freshness_source else None
            ),
        )
        for s in _PROVIDERS.values()
    ]
