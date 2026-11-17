"""Counts for the pipeline overview. Counts only, never rates.

- `by_status`: each submitted application's current status. One that had a screen and an
  interview and was then rejected counts only as rejected.
- `reached`: how far applications got, from the dated status history. For each active stage in
  list order, the applications whose history got to that stage or past it.
- `leads`: open and dropped leads, apart from the funnel; they are not in `total`.
- `interviews`: applications with interview records, and the records.

`filtered_ids` is shared with the applications list so both count the same rows.
"""

import datetime as dt
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.modules.jobs import statuses
from app.modules.jobs.models import Application, ApplicationStatusEvent, Company, Interview


@dataclass(frozen=True)
class Filters:
    company_id: int | None = None
    tag: str | None = None
    applied_from: dt.date | None = None
    applied_to: dt.date | None = None
    q: str | None = None


def filtered_rows(
    session: Session, filters: Filters, status_keys: Iterable[str] | None = None
) -> list[tuple[Application, Company]]:
    """(application, company) pairs matching the filters, optionally only these statuses.

    `tag` matches the application's tags or its company's, ignoring case. `q` matches the title
    or the company name. Date bounds are inclusive and leave out undated rows.
    """
    stmt = select(Application, Company).join(Company, Company.id == Application.company_id)
    if status_keys is not None:
        stmt = stmt.where(Application.status.in_(list(status_keys)))
    if filters.company_id is not None:
        stmt = stmt.where(Application.company_id == filters.company_id)
    if filters.applied_from is not None:
        stmt = stmt.where(Application.date_applied >= filters.applied_from)
    if filters.applied_to is not None:
        stmt = stmt.where(Application.date_applied <= filters.applied_to)
    rows = [(a, c) for a, c in session.execute(stmt).all()]
    if filters.tag:
        wanted = filters.tag.casefold()
        rows = [
            (a, c)
            for a, c in rows
            if any(t.casefold() == wanted for t in [*(a.tags or []), *(c.tags or [])])
        ]
    if filters.q:
        needle = filters.q.casefold()
        rows = [
            (a, c) for a, c in rows if needle in a.title.casefold() or needle in c.name.casefold()
        ]
    return rows


def reached_by_application(session: Session, ids: Iterable[int]) -> dict[int, str]:
    """application id -> the furthest active stage its live history got to."""
    order = statuses.keys_of_kind(session, "active")
    rank = {key: i for i, key in enumerate(order)}
    furthest: dict[int, int] = {}
    id_list = list(ids)
    if not id_list:
        return {}
    for application_id, status in session.execute(
        select(ApplicationStatusEvent.application_id, ApplicationStatusEvent.status).where(
            ApplicationStatusEvent.application_id.in_(id_list),
            ApplicationStatusEvent.status.in_(order),
        )
    ):
        r = rank[status]
        furthest[application_id] = max(furthest.get(application_id, r), r)
    return {application_id: order[r] for application_id, r in furthest.items()}


def pipeline(session: Session, filters: Filters) -> dict:
    defs = statuses.load(session)
    funnel_keys = [s.key for s in defs if s.kind in ("active", "closed")]
    funnel = [a for a, _ in filtered_rows(session, filters, funnel_keys)]
    ids = [a.id for a in funnel]
    by_status = Counter(a.status for a in funnel)

    active = [s for s in defs if s.kind == "active"]
    rank = {s.key: i for i, s in enumerate(active)}
    furthest = reached_by_application(session, ids)
    reached = [
        {
            "status": stage.key,
            "label": stage.label,
            "count": sum(1 for key in furthest.values() if rank[key] >= i),
        }
        for i, stage in enumerate(active)
    ]

    lead_rows = [
        a
        for a, _ in filtered_rows(
            session,
            Filters(company_id=filters.company_id, tag=filters.tag, q=filters.q),
            [statuses.LEAD, statuses.DROPPED],
        )
    ]
    lead_counts = Counter(a.status for a in lead_rows)

    with_interviews, records = (0, 0)
    if ids:
        with_interviews, records = session.execute(
            select(
                func.count(func.distinct(Interview.application_id)), func.count(Interview.id)
            ).where(Interview.application_id.in_(ids))
        ).one()

    return {
        "total": len(funnel),
        "by_status": [
            {"status": s.key, "label": s.label, "kind": s.kind, "count": by_status.get(s.key, 0)}
            for s in defs
            if s.kind in ("active", "closed")
        ],
        "reached": reached,
        "leads": {
            "open": lead_counts.get(statuses.LEAD, 0),
            "dropped": lead_counts.get(statuses.DROPPED, 0),
        },
        "interviews": {"applications": with_interviews, "records": records},
    }
