"""POST /api/ingest/calendar: the Mac helper's EventKit snapshot.

Mounted at /api/ingest behind the `ingest` scope (app.main). Each push is a full snapshot of
the calendar list and of the events in its window:
- the whole EventKit calendar list is replaced;
- EventKit rows whose occurrence falls in the window (or that run into it from before) are
  replaced by the pushed events. Rows outside the window are left alone.

The helper reads every account the Mac's Calendar app has, so its rows overlap the accounts the
server polls itself; the calendar provider deduplicates them (dedup.py). Rows are mirrored data,
written directly and not through app.audit.
"""

from datetime import datetime, timedelta
from typing import Literal

from fastapi import APIRouter
from pydantic import BaseModel, Field, field_validator, model_validator
from sqlalchemy import delete, or_
from sqlalchemy.orm import Session

from app import freshness
from app.deps import SessionDep
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.modules.calendar_ext.normalize import all_day_date, midnight, normalize_color
from app.timeutil import local_tz, utcnow

SOURCE = "eventkit"
FRESHNESS_LABEL = "Mac helper (Apple Calendar)"
FRESHNESS_STALE_AFTER = timedelta(hours=2)

freshness.register_source(SOURCE, FRESHNESS_LABEL, stale_after=FRESHNESS_STALE_AFTER)

router = APIRouter()


def _with_zone(value: datetime) -> datetime:
    """A naive time is taken as the server's local time. An aware one keeps its own offset,
    which matters for all-day values (their day is the date as the helper sent it)."""
    return value if value.tzinfo is not None else value.replace(tzinfo=local_tz())


class WindowIn(BaseModel):
    start: datetime
    end: datetime

    @field_validator("start", "end")
    @classmethod
    def zoned(cls, value: datetime) -> datetime:
        return _with_zone(value)


class EventKitCalendarIn(BaseModel):
    id: str = Field(min_length=1, max_length=1000, description="EventKit calendarIdentifier")
    title: str = ""
    color: str | None = None
    account: str | None = Field(default=None, description="The account's name on the Mac")
    account_type: str | None = Field(
        default=None, description="EventKit source type: caldav, mobileme, local, exchange, ..."
    )


class EventKitEventIn(BaseModel):
    uid: str = Field(min_length=1, max_length=1000)
    calendar_id: str
    title: str = ""
    start: datetime
    end: datetime
    all_day: bool
    location: str | None = None
    url: str | None = None
    occurrence_start: datetime
    status: str = "none"

    @field_validator("start", "end", "occurrence_start")
    @classmethod
    def zoned(cls, value: datetime) -> datetime:
        return _with_zone(value)


class CalendarPushIn(BaseModel):
    source: Literal["eventkit"] = "eventkit"
    window: WindowIn
    calendars: list[EventKitCalendarIn]
    events: list[EventKitEventIn]

    @model_validator(mode="after")
    def window_is_forward(self) -> "CalendarPushIn":
        if self.window.end <= self.window.start:
            raise ValueError("window.end must be after window.start")
        return self


class CalendarPushOut(BaseModel):
    calendars: int
    events: int


@router.post("/calendar", response_model=CalendarPushOut)
def push_calendar(payload: CalendarPushIn, session: SessionDep) -> CalendarPushOut:
    """Replace the helper's calendars and the window's helper events with this snapshot."""
    now = utcnow()
    try:
        counts = replace_eventkit(session, payload, now)
        freshness.mark_success(session, SOURCE, at=now)  # commits
    except Exception as exc:
        session.rollback()
        freshness.mark_error(session, SOURCE, str(exc) or type(exc).__name__)
        raise
    return counts


def replace_eventkit(session: Session, payload: CalendarPushIn, now: datetime) -> CalendarPushOut:
    """Write the snapshot without committing. The caller commits (mark_success does)."""
    window_start, window_end = payload.window.start, payload.window.end
    session.execute(
        delete(ExternalEvent).where(
            ExternalEvent.source == SOURCE,
            ExternalEvent.occurrence_start < window_end,
            or_(ExternalEvent.occurrence_start >= window_start, ExternalEvent.end > window_start),
        )
    )
    session.execute(delete(ExternalCalendar).where(ExternalCalendar.source == SOURCE))

    calendars: dict[str, EventKitCalendarIn] = {}
    for cal in payload.calendars:
        calendars[cal.id] = cal  # a repeated id keeps its last entry
    for cal in calendars.values():
        session.add(
            ExternalCalendar(
                source=SOURCE,
                ext_id=cal.id,
                title=cal.title,
                color=normalize_color(cal.color),
                account=cal.account or "",
                account_type=cal.account_type,
            )
        )

    for event in payload.events:
        cal = calendars.get(event.calendar_id)
        start, end, occurrence = event.start, event.end, event.occurrence_start
        if event.all_day:
            first_day = all_day_date(start)
            last_day = all_day_date(end)
            if last_day <= first_day:
                last_day = first_day + timedelta(days=1)
            start, end = midnight(first_day), midnight(last_day)
            occurrence = midnight(all_day_date(occurrence))
        session.add(
            ExternalEvent(
                source=SOURCE,
                uid=event.uid,
                occurrence_start=occurrence,
                calendar_ext_id=event.calendar_id,
                calendar_title=cal.title if cal else "",
                account=(cal.account or "") if cal else "",
                account_type=cal.account_type if cal else None,
                title=event.title,
                start=start,
                end=end,
                all_day=event.all_day,
                location=event.location or None,
                url=event.url or None,
                status=event.status or "none",
                received_at=now,
            )
        )
    session.flush()
    return CalendarPushOut(calendars=len(calendars), events=len(payload.events))
