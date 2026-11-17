"""Job tracker tables. Every one is organizer-owned (`OwnedMixin`): written only through
`app.audit`, so each change lands in `change_log` and can be reverted from History.

- `Company`: a name that is unique ignoring case and spacing (enforced by `matching`), a target
  flag, notes and free-form `tags`.
- `Application`: one posting at a company. A lead is an application whose status is `lead`
  (see statuses.py), so a posting is one record from the day it is found to the day it closes.
  `status` is derived: it is the status of the latest live `ApplicationStatusEvent`
  (status_sync.py), and only the status endpoints change it.
- `ApplicationStatusEvent`: the dated history behind `Application.status`, and the source of
  `reached` (how far an application got).
- `Contact`, `Interview`, `JobEvent`: people, interviews and fairs or networking events.
  Interviews, events and next-action due dates are on the calendar (calendar_provider.py).
- `WeeklyGoal`: an optional target per countable thing per week (goals.py).
- `JobStatus`: the configurable status list. While it has no live rows the defaults in
  statuses.py apply; the first edit writes them out (statuses.py).

Dates and times a person picks (an interview's day and time) are wall-clock values in the
configured time zone, stored without a zone (app.timeutil).
"""

import datetime as dt

from sqlalchemy import JSON, ForeignKey, Index, String, Text, text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base, OwnedMixin


def _live_unique(name: str, *columns: str) -> Index:
    """Unique among live rows only, so a deleted record's key can come back."""
    return Index(name, *columns, unique=True, sqlite_where=text("deleted_at IS NULL"))


class Company(OwnedMixin, Base):
    __tablename__ = "jobs_companies"
    __table_args__ = (_live_unique("uq_jobs_companies_name", "name"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    website: Mapped[str] = mapped_column(String(500), default="")
    # On the list of companies to aim for.
    target: Mapped[bool] = mapped_column(default=False)
    notes: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[list[str]] = mapped_column(JSON, default=list)


class Application(OwnedMixin, Base):
    """One posting. `status` follows the latest status event; `date_applied` is unset while it
    is a lead."""

    __tablename__ = "jobs_applications"

    id: Mapped[int] = mapped_column(primary_key=True)
    company_id: Mapped[int] = mapped_column(ForeignKey("jobs_companies.id"), index=True)
    title: Mapped[str] = mapped_column(String(300))
    status: Mapped[str] = mapped_column(String(32), index=True)
    date_applied: Mapped[dt.date | None] = mapped_column(index=True)
    location: Mapped[str] = mapped_column(String(200), default="")
    posting_url: Mapped[str] = mapped_column(String(2000), default="")
    # Where the posting was found (a job board, a referral, a fair), as written.
    source: Mapped[str] = mapped_column(String(200), default="")
    next_action: Mapped[str] = mapped_column(Text, default="")
    next_action_due: Mapped[dt.date | None] = mapped_column(index=True)
    notes: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[list[str]] = mapped_column(JSON, default=list)
    # Imported spreadsheet columns that map to no field, header -> value.
    extra: Mapped[dict[str, str]] = mapped_column(JSON, default=dict)


class ApplicationStatusEvent(OwnedMixin, Base):
    """One dated status change on an application."""

    __tablename__ = "jobs_application_status_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    application_id: Mapped[int] = mapped_column(ForeignKey("jobs_applications.id"), index=True)
    status: Mapped[str] = mapped_column(String(32))
    on_date: Mapped[dt.date] = mapped_column(index=True)
    note: Mapped[str] = mapped_column(Text, default="")


class Contact(OwnedMixin, Base):
    """A person: a recruiter, a referrer, someone met at a fair."""

    __tablename__ = "jobs_contacts"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    company_id: Mapped[int | None] = mapped_column(ForeignKey("jobs_companies.id"), index=True)
    # Their job title, as written.
    role: Mapped[str] = mapped_column(String(200), default="")
    email: Mapped[str] = mapped_column(String(320), default="")
    # A profile page or another place to reach them from.
    profile_url: Mapped[str] = mapped_column(String(500), default="")
    # The day you first reached out (counts toward an outreach goal), and the day they replied.
    contacted_on: Mapped[dt.date | None] = mapped_column(index=True)
    replied_on: Mapped[dt.date | None]
    next_action: Mapped[str] = mapped_column(Text, default="")
    next_action_due: Mapped[dt.date | None] = mapped_column(index=True)
    notes: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[list[str]] = mapped_column(JSON, default=list)


class Interview(OwnedMixin, Base):
    """An interview for an application. A day with no time is shown all day on the calendar;
    one with neither is still being scheduled."""

    __tablename__ = "jobs_interviews"

    id: Mapped[int] = mapped_column(primary_key=True)
    application_id: Mapped[int] = mapped_column(ForeignKey("jobs_applications.id"), index=True)
    # Free text: "recruiter screen", "technical", "onsite".
    stage: Mapped[str] = mapped_column(String(100), default="")
    on_date: Mapped[dt.date | None] = mapped_column(index=True)
    start_time: Mapped[dt.time | None]
    duration_minutes: Mapped[int | None]
    # A place or a video link.
    location: Mapped[str] = mapped_column(String(500), default="")
    interviewer: Mapped[str] = mapped_column(String(200), default="")
    notes: Mapped[str] = mapped_column(Text, default="")


class JobEvent(OwnedMixin, Base):
    """A career fair, a networking evening, an info session."""

    __tablename__ = "jobs_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(300))
    # Free text: "fair", "networking", "info session".
    kind: Mapped[str] = mapped_column(String(50), default="")
    on_date: Mapped[dt.date] = mapped_column(index=True)
    start_time: Mapped[dt.time | None]
    end_time: Mapped[dt.time | None]
    location: Mapped[str] = mapped_column(String(500), default="")
    url: Mapped[str] = mapped_column(String(2000), default="")
    attended: Mapped[bool | None]
    notes: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[list[str]] = mapped_column(JSON, default=list)


class WeeklyGoal(OwnedMixin, Base):
    """A target for one countable thing per week (goals.METRICS), one goal per metric."""

    __tablename__ = "jobs_weekly_goals"
    __table_args__ = (_live_unique("uq_jobs_weekly_goals_metric", "metric"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    metric: Mapped[str] = mapped_column(String(32))
    target: Mapped[int]


class JobStatus(OwnedMixin, Base):
    """One entry of the status list. `kind` is lead, dropped, active or closed (statuses.py)."""

    __tablename__ = "jobs_statuses"
    __table_args__ = (_live_unique("uq_jobs_statuses_key", "key"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    key: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(100))
    kind: Mapped[str] = mapped_column(String(16))
    position: Mapped[int] = mapped_column(default=0)


# Revert hooks need the models above; importing them here registers them wherever the models are
# loaded (the app, Alembic, tests).
from app.modules.jobs import revert_hooks  # noqa: E402, F401
