"""The tracker's write rules, shared by the router, the CSV importer and the demo seed.

Every function writes through `app.audit` and groups its writes in one batch. They raise
`Conflict` (HTTP 409) or `ValueError` (HTTP 422); the router turns those into responses.

Leads are a stage of an application (statuses.py), so a posting stays one record:

- `create_lead` refuses a posting already tracked at the company (same title, ignoring case,
  spacing and punctuation) unless `force`, for a genuine reposting. A dropped lead does not count.
- `create_application` for a posting that matches exactly one open lead submits that lead in
  place (`promote_lead`) instead of making a second record. When several open leads match, none
  is guessed: a new record is made and their ids come back as `lead_candidates`.
- `apply_lead` submits a lead you already know; `drop_lead` cuts one without applying.
"""

import datetime as dt
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.modules.jobs import statuses
from app.modules.jobs.matching import company_named, same_posting
from app.modules.jobs.models import Application, ApplicationStatusEvent, Company, Interview
from app.modules.jobs.status_sync import latest_status_event, sync_application_status
from app.timeutil import today_local

MAX_TAGS = 30
MAX_TAG_LENGTH = 50


class Conflict(Exception):
    """The write would duplicate or break an existing record (HTTP 409)."""

    def __init__(self, message: str, record_id: int | None = None) -> None:
        super().__init__(message)
        self.record_id = record_id


def normalize_tags(tags: list[str] | None) -> list[str]:
    """Trimmed, single-spaced, without blanks or case-insensitive repeats, first spelling kept."""
    out: list[str] = []
    seen: set[str] = set()
    for tag in tags or []:
        clean = " ".join(str(tag).split())[:MAX_TAG_LENGTH]
        if clean and clean.casefold() not in seen:
            seen.add(clean.casefold())
            out.append(clean)
    if len(out) > MAX_TAGS:
        raise ValueError(f"at most {MAX_TAGS} tags")
    return out


# --------------------------------------------------------------------------- companies


def create_company(
    session: Session, fields: dict[str, Any], author: str, *, reuse_existing: bool = False
) -> tuple[Company, bool]:
    """(company, created). A name already taken (ignoring case and spacing) is a Conflict, or,
    with `reuse_existing`, returns that company unchanged."""
    name = " ".join(str(fields.get("name", "")).split())
    if not name:
        raise ValueError("a company needs a name")
    existing = company_named(session, name)
    if existing is not None:
        if reuse_existing:
            return existing, False
        raise Conflict(f"company {existing.id} is already named {existing.name!r}", existing.id)
    data = {**fields, "name": name, "tags": normalize_tags(fields.get("tags"))}
    return audit.create(session, Company(**data), author), True


def company_for_name(session: Session, name: str, author: str) -> tuple[Company, bool]:
    """The company with this name, created if there is none. (company, created)"""
    return create_company(session, {"name": name}, author, reuse_existing=True)


def rename_check(session: Session, company: Company, name: str) -> str:
    name = " ".join(name.split())
    if not name:
        raise ValueError("a company needs a name")
    other = company_named(session, name, exclude_id=company.id)
    if other is not None:
        raise Conflict(f"company {other.id} is already named {other.name!r}", other.id)
    return name


# --------------------------------------------------------------------------- status events


def _event(session: Session, application: Application, status: str, on: dt.date, note: str, author):
    audit.create(
        session,
        ApplicationStatusEvent(application_id=application.id, status=status, on_date=on, note=note),
        author,
    )


def add_status(
    session: Session,
    application: Application,
    status: str,
    author: str,
    *,
    on_date: dt.date | None = None,
    note: str = "",
) -> Application:
    """Record a status change. A lead given an active or closed status is submitted first
    (`apply_lead`); `lead` and `dropped` are set only by the lead routes."""
    target = statuses.require(session, status, ("active", "closed"))
    if application.status == statuses.LEAD:
        return apply_lead(
            session, application, author, on_date=on_date, status=target.key, note=note
        )
    if application.status == statuses.DROPPED:
        raise Conflict(f"application {application.id} is a dropped lead; log a new lead instead")
    with audit.transaction(session):
        _event(session, application, target.key, on_date or today_local(), note, author)
        sync_application_status(session, application, author)
    return application


# --------------------------------------------------------------------------- applications


@dataclass
class Created:
    application: Application
    promoted_from_lead: bool = False
    lead_candidates: list[int] = field(default_factory=list)


# Values that mean "not given" when an application is entered over a lead: the lead's own value
# is kept for these.
_BLANK = ("", None, [], {})


def create_application(
    session: Session, fields: dict[str, Any], author: str, *, status: str | None = None
) -> Created:
    """Create an application with its status history (`applied`, then `status` when it is past
    applied, both on the day applied), or submit the one open lead it matches (see the module
    docstring)."""
    status = statuses.require(session, status or statuses.APPLIED, ("active", "closed")).key
    fields = {**fields, "tags": normalize_tags(fields.get("tags"))}
    leads = same_posting(session, fields["company_id"], fields["title"], [statuses.LEAD])
    if len(leads) == 1:
        return Created(promote_lead(session, leads[0], fields, author, status=status), True)
    applied_on = fields.get("date_applied") or today_local()
    with audit.transaction(session):
        application = audit.create(
            session,
            Application(**{**fields, "date_applied": applied_on}, status=status),
            author,
        )
        for event_status in dict.fromkeys([statuses.APPLIED, status]):
            _event(session, application, event_status, applied_on, "", author)
    return Created(application, False, [lead.id for lead in leads])


def promote_lead(
    session: Session, lead: Application, fields: dict[str, Any], author: str, *, status: str
) -> Application:
    """The application entered for an open lead becomes that lead (same id), in one batch.

    Each field sent replaces the lead's; a blank one keeps it. Notes are appended to the lead's,
    tags and `extra` are merged. An `applied` event goes on the day applied (default today), or on
    the day the lead was found if that is later, since the status follows the latest event; a
    status past applied is added on the same day after it.
    """
    changes = {
        name: value
        for name, value in fields.items()
        if value not in _BLANK and name not in ("company_id",)
    }
    if "notes" in changes and lead.notes.strip() and changes["notes"] not in lead.notes:
        changes["notes"] = f"{lead.notes.rstrip()}\n\n{changes['notes']}"
    if "extra" in changes:
        changes["extra"] = {**(lead.extra or {}), **changes["extra"]}
    if "tags" in changes:
        changes["tags"] = normalize_tags([*(lead.tags or []), *changes["tags"]])
    applied_on = fields.get("date_applied") or today_local()
    changes["date_applied"] = applied_on
    found = latest_status_event(session, lead.id)
    on_date = max(applied_on, found.on_date) if found is not None else applied_on
    with audit.transaction(session):
        audit.update(session, lead, changes, author)
        for event_status in dict.fromkeys([statuses.APPLIED, status]):
            _event(session, lead, event_status, on_date, "", author)
        sync_application_status(session, lead, author)
    return lead


def create_lead(
    session: Session,
    fields: dict[str, Any],
    author: str,
    *,
    found_on: dt.date | None = None,
    force: bool = False,
) -> Application:
    """Log a posting worth applying to: status `lead`, no date_applied, its first status event
    dated found_on (default today). Refused when the posting is already tracked (see the module
    docstring)."""
    if not force:
        for row in same_posting(session, fields["company_id"], fields["title"]):
            if row.status != statuses.DROPPED:
                kind = "lead" if row.status == statuses.LEAD else "application"
                raise Conflict(
                    f"{kind} {row.id} at this company already has this title "
                    f"({row.title!r}, status {row.status}); force=true logs a new lead anyway",
                    row.id,
                )
    found_on = found_on or today_local()
    if found_on > today_local():
        raise ValueError("found_on cannot be in the future")
    fields = {**fields, "tags": normalize_tags(fields.get("tags")), "date_applied": None}
    with audit.transaction(session):
        lead = audit.create(session, Application(**fields, status=statuses.LEAD), author)
        _event(session, lead, statuses.LEAD, found_on, "", author)
    return lead


def apply_lead(
    session: Session,
    application: Application,
    author: str,
    *,
    on_date: dt.date | None = None,
    status: str = statuses.APPLIED,
    note: str = "",
) -> Application:
    """Submit an open lead: sets date_applied and appends an `applied` event (and `status`, when
    it is past applied), in one batch. The day cannot be before the day the lead was found,
    because the status follows the latest event."""
    if application.status != statuses.LEAD:
        raise Conflict(f"application {application.id} is not an open lead")
    status = statuses.require(session, status, ("active", "closed")).key
    on = on_date or today_local()
    found = latest_status_event(session, application.id)
    if found is not None and on < found.on_date:
        raise ValueError(f"applied on {on} is before the lead was found on {found.on_date}")
    with audit.transaction(session):
        audit.update(session, application, {"date_applied": on}, author)
        events = list(dict.fromkeys([statuses.APPLIED, status]))
        for event_status in events:
            _event(
                session,
                application,
                event_status,
                on,
                note if event_status == events[-1] else "",
                author,
            )
        sync_application_status(session, application, author)
    return application


def drop_lead(session: Session, application: Application, reason: str, author: str) -> Application:
    """Cut a lead without applying: status `dropped` dated today. The reason goes in the status
    event and is appended to the lead's notes, in one batch."""
    if application.status != statuses.LEAD:
        raise Conflict(f"application {application.id} is not an open lead")
    reason = reason.strip()
    if not reason:
        raise ValueError("give a reason for dropping the lead")
    today = today_local()
    found = latest_status_event(session, application.id)
    on = max(today, found.on_date) if found is not None else today
    dropped = f"Dropped {on.isoformat()}: {reason}"
    notes = f"{application.notes.rstrip()}\n{dropped}" if application.notes.strip() else dropped
    with audit.transaction(session):
        _event(session, application, statuses.DROPPED, on, reason, author)
        audit.update(session, application, {"notes": notes}, author)
        sync_application_status(session, application, author)
    return application


def delete_application(session: Session, application: Application, author: str) -> None:
    """Soft delete, with its status events and interviews, in one batch (History restores all
    of them together; see revert_hooks)."""
    with audit.transaction(session):
        for model in (Interview, ApplicationStatusEvent):
            for child in session.scalars(
                select(model).where(model.application_id == application.id)
            ).all():
                audit.delete(session, child, author)
        audit.delete(session, application, author)
