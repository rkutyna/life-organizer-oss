"""Mirrored calendars and events: from connected accounts (CalDAV, Google) and the Mac helper.

These rows are mirrored, not owned. They have no OwnedMixin and no audit trail: each sync
replaces the rows it covers, and the organizer never edits them.

`source` is "caldav", "google" or "eventkit" (the Mac helper's push). Rows from a connected
account carry its `account_id`; the foreign key cascades, so removing the account removes its
rows. Helper rows have no account.

`account` is the name the Mac's Calendar app shows for the account ("iCloud", a Google address,
...). Dedup matches a helper row to a server-side copy by it (dedup.py).

Times are stored as UTC. An all-day row stores local midnight of its day, so every source
agrees on one instant per day (normalize.py).
"""

from datetime import datetime

from sqlalchemy import Boolean, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

SOURCES = ("caldav", "google", "eventkit")


class ExternalCalendar(Base):
    """A calendar as one stream sees it."""

    __tablename__ = "calendar_ext_calendars"

    id: Mapped[int] = mapped_column(primary_key=True)
    source: Mapped[str] = mapped_column(String(16))
    account_id: Mapped[int | None] = mapped_column(
        ForeignKey("core_provider_accounts.id", ondelete="CASCADE"), index=True
    )
    # The CalDAV calendar URL, the Google calendar id, or the EventKit calendarIdentifier.
    ext_id: Mapped[str] = mapped_column(String(1000))
    title: Mapped[str] = mapped_column(String(500))
    color: Mapped[str | None] = mapped_column(String(7))
    account: Mapped[str] = mapped_column(String(500), default="")
    # EventKit source type: caldav, mobileme, local, exchange, ...; "caldav" for CalDAV and
    # Google rows, which is what the Mac reports for those accounts.
    account_type: Mapped[str | None] = mapped_column(String(32))


class ExternalEvent(Base):
    """One occurrence of an event, from one stream."""

    __tablename__ = "calendar_ext_events"
    __table_args__ = (Index("ix_calendar_ext_events_source_start", "source", "start"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    source: Mapped[str] = mapped_column(String(16))
    account_id: Mapped[int | None] = mapped_column(
        ForeignKey("core_provider_accounts.id", ondelete="CASCADE"), index=True
    )
    # Event UID (iCalendar UID; Google's iCalUID), and the instant of this occurrence's
    # original start (for dedup).
    uid: Mapped[str] = mapped_column(String(1000))
    occurrence_start: Mapped[datetime]
    calendar_ext_id: Mapped[str] = mapped_column(String(1000))
    calendar_title: Mapped[str] = mapped_column(String(500))
    account: Mapped[str] = mapped_column(String(500), default="")
    account_type: Mapped[str | None] = mapped_column(String(32))
    title: Mapped[str] = mapped_column(Text, default="")
    start: Mapped[datetime]
    end: Mapped[datetime]
    all_day: Mapped[bool] = mapped_column(Boolean, default=False)
    location: Mapped[str | None] = mapped_column(Text)
    # A link to the event: the event's own URL property, or Google's web link.
    url: Mapped[str | None] = mapped_column(Text)
    # none|confirmed|tentative|canceled|unknown (EventKit's vocabulary, used by every source).
    status: Mapped[str] = mapped_column(String(16), default="none")
    received_at: Mapped[datetime]
