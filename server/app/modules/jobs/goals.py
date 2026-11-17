"""Optional weekly goals: a target per countable thing per week, and this week's progress.

There are no fixed lanes. A goal names one of METRICS and a target; a week runs Monday to
Sunday in the configured time zone. What each metric counts:

- applications: applications with date_applied in the week (leads have none)
- outreach: contacts first reached out to (contacted_on) in the week
- leads: leads logged in the week (their first status event)
- interviews: interviews on a day in the week
- events: job events on a day in the week, unless marked not attended
"""

import datetime as dt

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.modules.jobs import statuses
from app.modules.jobs.models import (
    Application,
    ApplicationStatusEvent,
    Contact,
    Interview,
    JobEvent,
    WeeklyGoal,
)

METRICS: dict[str, str] = {
    "applications": "Applications",
    "outreach": "Outreach",
    "leads": "Leads",
    "interviews": "Interviews",
    "events": "Events",
}


def week_bounds(day: dt.date) -> tuple[dt.date, dt.date]:
    """(Monday, Sunday) of the week containing `day`."""
    start = day - dt.timedelta(days=day.weekday())
    return start, start + dt.timedelta(days=6)


def count(session: Session, metric: str, start: dt.date, end: dt.date) -> int:
    if metric == "applications":
        stmt = select(func.count(Application.id)).where(
            Application.date_applied.between(start, end)
        )
    elif metric == "outreach":
        stmt = select(func.count(Contact.id)).where(Contact.contacted_on.between(start, end))
    elif metric == "leads":
        stmt = (
            select(func.count(func.distinct(ApplicationStatusEvent.application_id)))
            .join(Application, Application.id == ApplicationStatusEvent.application_id)
            .where(
                ApplicationStatusEvent.status == statuses.LEAD,
                ApplicationStatusEvent.on_date.between(start, end),
                Application.deleted_at.is_(None),
            )
        )
    elif metric == "interviews":
        stmt = select(func.count(Interview.id)).where(Interview.on_date.between(start, end))
    elif metric == "events":
        stmt = select(func.count(JobEvent.id)).where(
            JobEvent.on_date.between(start, end), JobEvent.attended.is_not(False)
        )
    else:
        raise ValueError(f"unknown metric {metric!r}")
    return session.scalar(stmt) or 0


def progress(session: Session, day: dt.date) -> dict:
    start, end = week_bounds(day)
    goals = session.scalars(select(WeeklyGoal).order_by(WeeklyGoal.id)).all()
    order = list(METRICS)
    goals = sorted(goals, key=lambda g: order.index(g.metric) if g.metric in order else 99)
    return {
        "week_start": start,
        "week_end": end,
        "goals": [
            {
                "id": goal.id,
                "metric": goal.metric,
                "label": METRICS.get(goal.metric, goal.metric),
                "target": goal.target,
                "actual": count(session, goal.metric, start, end),
            }
            for goal in goals
        ],
    }
