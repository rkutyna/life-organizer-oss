"""Conversions shared by the helper's push, the CalDAV poll and the Google poll.

All-day handling: a source names an all-day event by a calendar date. The helper sends an ISO
datetime at local midnight with the Mac's own UTC offset, so the wall-clock date is the date
part of the value as sent. Every all-day row is stored as midnight of that date in the
configured time zone, so every copy of one event shares one stored instant and deduplicates.
"""

import re
from datetime import UTC, date, datetime, time

from app.timeutil import combine_local, to_local

_HEX_COLOR = re.compile(r"#?([0-9A-Fa-f]{6})(?:[0-9A-Fa-f]{2})?")


def normalize_color(value: str | None) -> str | None:
    """`#RRGGBB` in upper case. `#RRGGBBAA` loses its alpha. Anything else is None."""
    if not value:
        return None
    match = _HEX_COLOR.fullmatch(value.strip())
    return f"#{match.group(1).upper()}" if match else None


def all_day_date(value: datetime | date) -> date:
    """The calendar day an all-day value names, as the source wrote it."""
    return value.date() if isinstance(value, datetime) else value


def midnight(day: date) -> datetime:
    """Start of `day` in the configured time zone, as an aware datetime (stored as UTC)."""
    return combine_local(day, time.min)


def aware_utc(value: datetime) -> datetime:
    """A timed value as an aware UTC datetime. A floating time (no zone) is local time."""
    return to_local(value).astimezone(UTC)
