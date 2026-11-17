"""The tracker on the calendar: interviews, job events and next-action due dates.

Three sources, so each can be toggled and colored on its own. All are owned and live (no
freshness), and editable from the calendar drawer: the web module registers a detail component
for each source key.

- `jobs_interviews`: interviews with a day. A start time makes a timed item lasting
  `duration_minutes` (an hour by default); no time makes an all-day item.
- `jobs_events`: job events, timed when they have a start time (an hour long unless they have an
  end time), else all day.
- `jobs_due`: all-day items on the due date of each contact's and application's next action.
  Ids are `jobs_due:contact-<id>` and `jobs_due:application-<id>`.
"""

import datetime as dt

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.calendar import CalendarItem, local_date_bounds, register_provider
from app.modules.jobs.models import Application, Company, Contact, Interview, JobEvent
from app.timeutil import combine_local, today_local

INTERVIEWS = "jobs_interviews"
EVENTS = "jobs_events"
DUE = "jobs_due"

INTERVIEW_COLOR = "#3b6fd8"
EVENT_COLOR = "#8b5cf6"
DUE_COLOR = "#d97706"

DEFAULT_MINUTES = 60


def _span(on: dt.date, start: dt.time | None, end: dt.time | None, minutes: int | None):
    """(start, end, all_day) for a day and optional times."""
    if start is None:
        return on, on + dt.timedelta(days=1), True
    begins = combine_local(on, start)
    if end is not None and end > start:
        return begins, combine_local(on, end), False
    return begins, begins + dt.timedelta(minutes=minutes or DEFAULT_MINUTES), False


def _company_names(session: Session, ids: set[int]) -> dict[int, str]:
    if not ids:
        return {}
    rows = session.execute(
        select(Company.id, Company.name)
        .where(Company.id.in_(ids))
        .execution_options(include_deleted=True)
    )
    return dict(rows.all())


def interview_items(session: Session, start: dt.datetime, end: dt.datetime) -> list[CalendarItem]:
    first, stop = local_date_bounds(start, end)
    rows = session.execute(
        select(Interview, Application)
        .join(Application, Application.id == Interview.application_id)
        .where(Interview.on_date >= first, Interview.on_date < stop)
    ).all()
    names = _company_names(session, {a.company_id for _, a in rows})
    items = []
    for interview, application in rows:
        assert interview.on_date is not None
        begins, ends, all_day = _span(
            interview.on_date, interview.start_time, None, interview.duration_minutes
        )
        company = names.get(application.company_id, "")
        stage = interview.stage or "Interview"
        items.append(
            CalendarItem(
                id=f"{INTERVIEWS}:{interview.id}",
                source=INTERVIEWS,
                source_label="Interviews",
                title=f"{stage}: {company}" if company else stage,
                start=begins,
                end=ends,
                all_day=all_day,
                color=INTERVIEW_COLOR,
                status=application.status,
                detail_url=f"/jobs/applications/{application.id}",
                read_only=False,
                meta={
                    "interview_id": interview.id,
                    "application_id": application.id,
                    "application_title": application.title,
                    "company": company,
                    "stage": interview.stage,
                    "location": interview.location or None,
                    "interviewer": interview.interviewer or None,
                },
            )
        )
    return items


def event_items(session: Session, start: dt.datetime, end: dt.datetime) -> list[CalendarItem]:
    first, stop = local_date_bounds(start, end)
    rows = session.scalars(
        select(JobEvent).where(JobEvent.on_date >= first, JobEvent.on_date < stop)
    ).all()
    items = []
    for event in rows:
        begins, ends, all_day = _span(event.on_date, event.start_time, event.end_time, None)
        items.append(
            CalendarItem(
                id=f"{EVENTS}:{event.id}",
                source=EVENTS,
                source_label="Job events",
                title=event.name,
                start=begins,
                end=ends,
                all_day=all_day,
                color=EVENT_COLOR,
                status=None
                if event.attended is None
                else ("attended" if event.attended else "missed"),
                detail_url=f"/jobs/events?event={event.id}",
                read_only=False,
                meta={
                    "event_id": event.id,
                    "kind": event.kind or None,
                    "location": event.location or None,
                    "url": event.url or None,
                },
            )
        )
    return items


def due_items(session: Session, start: dt.datetime, end: dt.datetime) -> list[CalendarItem]:
    first, stop = local_date_bounds(start, end)
    today = today_local()
    contacts = session.scalars(
        select(Contact).where(Contact.next_action_due >= first, Contact.next_action_due < stop)
    ).all()
    applications = session.scalars(
        select(Application).where(
            Application.next_action_due >= first, Application.next_action_due < stop
        )
    ).all()
    names = _company_names(
        session,
        {c.company_id for c in contacts if c.company_id} | {a.company_id for a in applications},
    )
    items = []
    for contact in contacts:
        assert contact.next_action_due is not None
        company = names.get(contact.company_id) if contact.company_id else None
        action = contact.next_action or "Follow up"
        items.append(
            _due_item(
                f"contact-{contact.id}",
                f"{action}: {contact.name}",
                contact.next_action_due,
                today,
                f"/jobs/contacts/{contact.id}",
                {
                    "kind": "contact",
                    "record_id": contact.id,
                    "name": contact.name,
                    "company": company,
                    "next_action": contact.next_action,
                },
            )
        )
    for application in applications:
        assert application.next_action_due is not None
        company = names.get(application.company_id, "")
        action = application.next_action or "Follow up"
        items.append(
            _due_item(
                f"application-{application.id}",
                f"{action}: {company}",
                application.next_action_due,
                today,
                f"/jobs/applications/{application.id}",
                {
                    "kind": "application",
                    "record_id": application.id,
                    "name": application.title,
                    "company": company,
                    "next_action": application.next_action,
                },
            )
        )
    return items


def _due_item(native: str, title: str, due: dt.date, today: dt.date, url: str, meta: dict):
    return CalendarItem(
        id=f"{DUE}:{native}",
        source=DUE,
        source_label="Follow-ups",
        title=title,
        start=due,
        end=due + dt.timedelta(days=1),
        all_day=True,
        color=DUE_COLOR,
        status="overdue" if due < today else "open",
        detail_url=url,
        read_only=False,
        meta=meta,
    )


register_provider(INTERVIEWS, "Interviews", INTERVIEW_COLOR, interview_items)
register_provider(EVENTS, "Job events", EVENT_COLOR, event_items)
register_provider(DUE, "Follow-ups", DUE_COLOR, due_items)
