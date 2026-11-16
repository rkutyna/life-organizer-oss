"""Time helpers. Use these instead of `datetime.now()` so time zones stay consistent.

- Stored timestamps (created_at, done_at, change_log.ts, ...) are UTC.
- Dates and times a person picks (a due date, an interview's time) are wall-clock values in the
  configured time zone, stored without a zone.

The time zone is the one chosen at setup (stored in the database). `app.auth.service` calls
`set_timezone` at startup and whenever it changes; until then `DEFAULT_TIMEZONE` applies.
"""

from datetime import UTC, date, datetime, time
from zoneinfo import ZoneInfo

from app.config import get_settings

_tz: ZoneInfo | None = None


def set_timezone(name: str | None) -> None:
    """Use `name` as the local time zone from now on (None: back to the default)."""
    global _tz
    _tz = ZoneInfo(name) if name else None


def local_tz() -> ZoneInfo:
    return _tz or ZoneInfo(get_settings().default_timezone)


def utcnow() -> datetime:
    """Aware UTC now. Use for every stored timestamp."""
    return datetime.now(UTC)


def now_local() -> datetime:
    """Aware now in the configured time zone."""
    return datetime.now(local_tz())


def today_local() -> date:
    """Today's date in the configured time zone."""
    return now_local().date()


def to_local(value: datetime) -> datetime:
    """Convert an aware datetime to the configured zone. Naive input is taken as local."""
    if value.tzinfo is None:
        return value.replace(tzinfo=local_tz())
    return value.astimezone(local_tz())


def combine_local(day: date, at: time) -> datetime:
    """A wall-clock date + time as an aware local datetime."""
    return datetime.combine(day, at, tzinfo=local_tz())
