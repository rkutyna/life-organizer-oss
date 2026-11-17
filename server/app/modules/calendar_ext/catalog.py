"""The calendars this module shows, grouped by account, each with a stable key and a color.

A calendar's key comes from its account name and title, so the helper's copy of an iCloud
calendar and the server's copy share one key (and one entry in the Calendars menu): an event
keeps its calendar, and its show/hide state, whichever stream supplies it. Items carry the key
in `meta.calendar_key`.
"""

import hashlib
from dataclasses import dataclass, field

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.modules.calendar_ext.calendar_accounts import CalendarAccount
from app.modules.calendar_ext.dedup import account_key
from app.modules.calendar_ext.ingest import SOURCE as EVENTKIT
from app.modules.calendar_ext.models import ExternalCalendar

DEFAULT_COLOR = "#7A7A85"  # a calendar with no color of its own
HELPER_LABEL = "On this Mac"


def calendar_key(account: str, title: str) -> str:
    digest = hashlib.sha256(f"{account_key(account)}\x1f{title}".encode()).hexdigest()
    return f"cal_{digest[:16]}"


@dataclass
class CalendarEntry:
    key: str
    title: str
    color: str


@dataclass
class CalendarGroup:
    """One connected account, or the Mac helper (account_id None)."""

    account_id: int | None
    label: str
    kind: str  # "caldav", "google" or "eventkit"
    freshness_key: str
    calendars: list[CalendarEntry] = field(default_factory=list)


@dataclass
class Catalog:
    groups: list[CalendarGroup]
    by_key: dict[str, CalendarEntry]
    # account id -> its label, for item details
    account_labels: dict[int, str]

    def entry(self, account: str, title: str) -> CalendarEntry:
        key = calendar_key(account, title)
        found = self.by_key.get(key)
        return found or CalendarEntry(key=key, title=title, color=DEFAULT_COLOR)


def build(session: Session, enabled: list[CalendarAccount]) -> Catalog:
    """Every shown calendar: enabled accounts' calendars, then the helper's own."""
    enabled_ids = [cal.id for cal in enabled]
    visible = or_(ExternalCalendar.account_id.in_(enabled_ids), ExternalCalendar.source == EVENTKIT)
    rows = list(
        session.scalars(
            select(ExternalCalendar)
            .where(visible)
            .order_by(ExternalCalendar.title, ExternalCalendar.id)
        )
    )
    by_key: dict[str, CalendarEntry] = {}
    groups: list[CalendarGroup] = []
    for cal in enabled:
        group = CalendarGroup(cal.id, cal.label, cal.source, cal.freshness_key)
        for row in rows:
            if row.account_id != cal.id:
                continue
            key = calendar_key(row.account, row.title)
            if key in by_key:
                continue
            entry = CalendarEntry(key, row.title, row.color or DEFAULT_COLOR)
            by_key[key] = entry
            group.calendars.append(entry)
        groups.append(group)

    helper = CalendarGroup(None, HELPER_LABEL, EVENTKIT, EVENTKIT)
    for row in rows:
        if row.source != EVENTKIT:
            continue
        key = calendar_key(row.account, row.title)
        existing = by_key.get(key)
        if existing is not None:
            if existing.color == DEFAULT_COLOR and row.color:
                existing.color = row.color
            continue
        entry = CalendarEntry(key, row.title, row.color or DEFAULT_COLOR)
        by_key[key] = entry
        helper.calendars.append(entry)
    if helper.calendars:
        groups.append(helper)

    return Catalog(groups, by_key, {cal.id: cal.label for cal in enabled})
