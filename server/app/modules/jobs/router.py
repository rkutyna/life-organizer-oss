"""/api/jobs: the job tracker.

Records: companies, applications (leads included: a lead is an application with status `lead`),
their status history, contacts, interviews, events and weekly goals. The status list
(`/statuses`), the pipeline counts (`/pipeline`) and the CSV import (`/import/*`,
import_router.py) sit beside them. Every write goes through `app.audit` (see service.py for the
lead and status rules), so History shows and reverts each change.
"""

import datetime as dt
from collections import Counter
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.deps import AuthorDep, SessionDep, get_or_404
from app.modules.jobs import goals, pipeline, service, statuses
from app.modules.jobs.import_router import router as import_router
from app.modules.jobs.models import (
    Application,
    ApplicationStatusEvent,
    Company,
    Contact,
    Interview,
    JobEvent,
    WeeklyGoal,
)
from app.modules.jobs.schemas import (
    ApplicationCreate,
    ApplicationCreatedOut,
    ApplicationOut,
    ApplicationUpdate,
    CompanyCreate,
    CompanyCreatedOut,
    CompanyOut,
    CompanyRef,
    CompanyRowOut,
    CompanyUpdate,
    ContactCreate,
    ContactCreatedOut,
    ContactOut,
    ContactUpdate,
    InterviewCreate,
    InterviewOut,
    InterviewUpdate,
    JobApplyIn,
    JobDropIn,
    JobEventCreate,
    JobEventOut,
    JobEventUpdate,
    JobStatusChange,
    JobStatusCreate,
    JobStatusOrder,
    JobStatusOut,
    JobStatusUpdate,
    JobTagsOut,
    LeadCreate,
    PipelineOut,
    StatusEventOut,
    StatusEventUpdate,
    WeeklyGoalCreate,
    WeeklyGoalOut,
    WeeklyGoalUpdate,
    WeekProgressOut,
)
from app.modules.jobs.status_sync import sync_application_status
from app.timeutil import today_local

router = APIRouter()
router.include_router(import_router, prefix="/import")


def _http(exc: Exception) -> HTTPException:
    if isinstance(exc, service.Conflict):
        return HTTPException(409, str(exc))
    if isinstance(exc, statuses.StatusError):
        return HTTPException(exc.code, str(exc))
    return HTTPException(422, str(exc))


def _require_live(session: Session, model, record_id: int | None, what: str) -> None:
    if record_id is not None and session.get(model, record_id) is None:
        raise HTTPException(422, f"{what} {record_id} not found")


def _company_ref(session: Session, ref: CompanyRef, author: str) -> tuple[int, bool]:
    """(company_id, created) from a company_id or a company name."""
    if ref.company_id is not None:
        _require_live(session, Company, ref.company_id, "company")
        return ref.company_id, False
    if ref.company:
        company, created = service.company_for_name(session, ref.company, author)
        return company.id, created
    raise HTTPException(422, "give company_id or company (a name)")


def _tags(changes: dict) -> dict:
    if changes.get("tags") is not None:
        changes["tags"] = service.normalize_tags(changes["tags"])
    elif "tags" in changes:
        changes["tags"] = []
    return changes


# --------------------------------------------------------------------------- statuses


def _status_out(s: statuses.StatusDef) -> JobStatusOut:
    return JobStatusOut(
        key=s.key, label=s.label, kind=s.kind, position=s.position, reserved=s.reserved
    )


@router.get("/statuses", response_model=list[JobStatusOut])
def list_statuses(session: SessionDep) -> list[JobStatusOut]:
    """The status list in order. Defaults apply until it is edited."""
    return [_status_out(s) for s in statuses.load(session)]


@router.post("/statuses", response_model=JobStatusOut, status_code=201)
def add_status_definition(
    payload: JobStatusCreate, session: SessionDep, author: AuthorDep
) -> JobStatusOut:
    """Add an active or closed status, after the last of its kind."""
    try:
        return _status_out(statuses.add(session, payload.label, payload.kind, payload.key, author))
    except statuses.StatusError as exc:
        raise _http(exc) from exc


@router.put("/statuses/order", response_model=list[JobStatusOut])
def reorder_statuses(
    payload: JobStatusOrder, session: SessionDep, author: AuthorDep
) -> list[JobStatusOut]:
    """Reorder the list. Active statuses' order is the funnel's stage order."""
    try:
        return [_status_out(s) for s in statuses.reorder(session, payload.keys, author)]
    except statuses.StatusError as exc:
        raise _http(exc) from exc


@router.patch("/statuses/{key}", response_model=JobStatusOut)
def update_status_definition(
    key: str, payload: JobStatusUpdate, session: SessionDep, author: AuthorDep
) -> JobStatusOut:
    try:
        changes = payload.model_dump(exclude_unset=True, exclude_none=True)
        return _status_out(statuses.update(session, key, changes, author))
    except statuses.StatusError as exc:
        raise _http(exc) from exc


@router.delete("/statuses/{key}", status_code=204)
def remove_status_definition(key: str, session: SessionDep, author: AuthorDep) -> None:
    """Remove a status no application's history uses. lead, applied and dropped stay."""
    try:
        statuses.remove(session, key, author)
    except statuses.StatusError as exc:
        raise _http(exc) from exc


# --------------------------------------------------------------------------- companies


@router.get("/companies", response_model=list[CompanyRowOut])
def list_companies(
    session: SessionDep,
    q: str | None = Query(None, description="Part of the name"),
    tag: str | None = None,
    target: bool | None = None,
) -> list[CompanyRowOut]:
    """Companies by name, with their application, lead and contact counts."""
    companies = session.scalars(select(Company).order_by(Company.name, Company.id)).all()
    if q:
        companies = [c for c in companies if q.casefold() in c.name.casefold()]
    if tag:
        companies = [c for c in companies if tag.casefold() in (t.casefold() for t in c.tags)]
    if target is not None:
        companies = [c for c in companies if c.target == target]
    lead_keys = {statuses.LEAD, statuses.DROPPED}
    applied: Counter[int] = Counter()
    leads: Counter[int] = Counter()
    for company_id, status in session.execute(select(Application.company_id, Application.status)):
        if status == statuses.LEAD:
            leads[company_id] += 1
        elif status not in lead_keys:
            applied[company_id] += 1
    contacts = Counter(session.scalars(select(Contact.company_id)).all())
    return [
        CompanyRowOut(
            **CompanyOut.model_validate(c).model_dump(),
            applications=applied[c.id],
            leads=leads[c.id],
            contacts=contacts.get(c.id, 0),
        )
        for c in companies
    ]


@router.post("/companies", response_model=CompanyCreatedOut, status_code=201)
def create_company(
    payload: CompanyCreate, session: SessionDep, author: AuthorDep
) -> CompanyCreatedOut:
    """Names are unique ignoring case and spacing: a taken name is refused (409), or with
    reuse_existing the existing company comes back with created=false."""
    fields = payload.model_dump(exclude={"reuse_existing"})
    try:
        company, created = service.create_company(
            session, fields, author, reuse_existing=payload.reuse_existing
        )
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    return CompanyCreatedOut(**CompanyOut.model_validate(company).model_dump(), created=created)


@router.get("/companies/{company_id}", response_model=CompanyOut)
def get_company(company_id: int, session: SessionDep) -> CompanyOut:
    return CompanyOut.model_validate(get_or_404(session, Company, company_id))


@router.patch("/companies/{company_id}", response_model=CompanyOut)
def update_company(
    company_id: int, payload: CompanyUpdate, session: SessionDep, author: AuthorDep
) -> CompanyOut:
    company = get_or_404(session, Company, company_id)
    changes = _tags(payload.model_dump(exclude_unset=True))
    try:
        if changes.get("name") is not None:
            changes["name"] = service.rename_check(session, company, changes["name"])
        for key in ("name", "target"):
            if key in changes and changes[key] is None:
                raise ValueError(f"{key} cannot be empty")
        for key in ("website", "notes"):
            if key in changes and changes[key] is None:
                changes[key] = ""
        audit.update(session, company, changes, author)
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    return CompanyOut.model_validate(company)


@router.delete("/companies/{company_id}", status_code=204)
def delete_company(company_id: int, session: SessionDep, author: AuthorDep) -> None:
    """Soft delete. Refused while the company still has applications or contacts."""
    company = get_or_404(session, Company, company_id)
    applications = len(
        session.scalars(select(Application.id).where(Application.company_id == company.id)).all()
    )
    contacts = len(
        session.scalars(select(Contact.id).where(Contact.company_id == company.id)).all()
    )
    if applications or contacts:
        raise HTTPException(
            409,
            f"company has {applications} application(s) and {contacts} contact(s); "
            "delete or move them first",
        )
    audit.delete(session, company, author)


# --------------------------------------------------------------------------- applications


def _application_outs(
    session: Session, rows: list[tuple[Application, str]]
) -> list[ApplicationOut]:
    ids = [a.id for a, _ in rows]
    reached = pipeline.reached_by_application(session, ids)
    found: dict[int, dt.date] = {}
    if ids:
        for application_id, on_date in session.execute(
            select(ApplicationStatusEvent.application_id, ApplicationStatusEvent.on_date)
            .where(
                ApplicationStatusEvent.application_id.in_(ids),
                ApplicationStatusEvent.status == statuses.LEAD,
            )
            .order_by(ApplicationStatusEvent.on_date)
        ):
            found.setdefault(application_id, on_date)
    return [
        ApplicationOut.model_validate(
            {
                **_attrs(a),
                "company": name,
                "reached": reached.get(a.id),
                "found_on": found.get(a.id),
            }
        )
        for a, name in rows
    ]


def _attrs(obj) -> dict:
    return {c.key: getattr(obj, c.key) for c in obj.__table__.columns}


def _application_out(session: Session, application: Application) -> ApplicationOut:
    company = session.get(
        Company, application.company_id, execution_options={"include_deleted": True}
    )
    return _application_outs(session, [(application, company.name if company else "")])[0]


def _filters(
    company_id: int | None = None,
    tag: str | None = Query(None, description="Matches the application's or its company's tags"),
    applied_from: dt.date | None = None,
    applied_to: dt.date | None = None,
    q: str | None = Query(None, description="Part of the title or company name"),
) -> pipeline.Filters:
    return pipeline.Filters(company_id, tag, applied_from, applied_to, q)


FiltersDep = Annotated[pipeline.Filters, Depends(_filters)]

_SORTS = {
    "-date_applied": (
        lambda a: (a.date_applied is None, -(a.date_applied or dt.date.min).toordinal(), -a.id)
    ),
    "date_applied": (lambda a: (a.date_applied is None, a.date_applied or dt.date.max, a.id)),
    "-updated_at": (lambda a: (-a.updated_at.timestamp(), -a.id)),
    "-id": (lambda a: -a.id),
}


@router.get("/applications", response_model=list[ApplicationOut])
def list_applications(
    session: SessionDep,
    filters: FiltersDep,
    status: list[str] | None = Query(None, description="One or more status keys"),
    leads: Literal["exclude", "include", "only"] = Query(
        "exclude", description="Leads (open and dropped) are left out unless asked for"
    ),
    sort: Literal["-date_applied", "date_applied", "-updated_at", "-id"] = "-date_applied",
    due_by: dt.date | None = Query(None, description="Only next actions due on or before"),
    limit: int = Query(1000, ge=1, le=5000),
) -> list[ApplicationOut]:
    """Applications, newest applied first by default; undated ones last. /pipeline counts the
    same rows for the same filters."""
    lead_keys = [statuses.LEAD, statuses.DROPPED]
    defs = statuses.load(session)
    if status:
        keys = status
    elif leads == "only":
        keys = lead_keys
    elif leads == "include":
        keys = [s.key for s in defs]
    else:
        keys = [s.key for s in defs if s.key not in lead_keys]
    rows = pipeline.filtered_rows(session, filters, keys)
    if due_by is not None:
        rows = [
            (a, c) for a, c in rows if a.next_action_due is not None and a.next_action_due <= due_by
        ]
    rows.sort(key=lambda pair: _SORTS[sort](pair[0]))
    return _application_outs(session, [(a, c.name) for a, c in rows[:limit]])


@router.post("/applications", response_model=ApplicationCreatedOut, status_code=201)
def create_application(
    payload: ApplicationCreate, session: SessionDep, author: AuthorDep
) -> ApplicationCreatedOut:
    """Creates the application and its first status event in one batch.

    A lead is a stage of an application, so an application entered for an open lead becomes that
    lead: when exactly one open lead at the company has the same title (ignoring case, spacing and
    punctuation), it is submitted in place with the fields sent and `promoted_from_lead` is true.
    When several match, none is guessed: a new record is created and `lead_candidates` lists them.
    The company may be named instead of given by id; a new name creates it.
    """
    try:
        with audit.transaction(session):
            company_id, company_created = _company_ref(session, payload, author)
            fields = payload.model_dump(exclude={"company", "company_id", "status"})
            created = service.create_application(
                session, {**fields, "company_id": company_id}, author, status=payload.status
            )
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    out = _application_out(session, created.application)
    return ApplicationCreatedOut(
        **out.model_dump(),
        company_created=company_created,
        promoted_from_lead=created.promoted_from_lead,
        lead_candidates=created.lead_candidates,
    )


@router.get("/applications/{application_id}", response_model=ApplicationOut)
def get_application(application_id: int, session: SessionDep) -> ApplicationOut:
    return _application_out(session, get_or_404(session, Application, application_id))


@router.patch("/applications/{application_id}", response_model=ApplicationOut)
def update_application(
    application_id: int, payload: ApplicationUpdate, session: SessionDep, author: AuthorDep
) -> ApplicationOut:
    """Change only the fields sent. The status changes through /status, /apply and /drop."""
    application = get_or_404(session, Application, application_id)
    changes = _tags(payload.model_dump(exclude_unset=True))
    if "company_id" in changes:
        if changes["company_id"] is None:
            raise HTTPException(422, "an application needs a company")
        _require_live(session, Company, changes["company_id"], "company")
    if "title" in changes and not changes["title"]:
        raise HTTPException(422, "an application needs a title")
    if changes.get("date_applied") is not None and application.status in (
        statuses.LEAD,
        statuses.DROPPED,
    ):
        raise HTTPException(422, "a lead has no date_applied; POST .../apply submits it")
    for key in ("location", "posting_url", "source", "next_action", "notes"):
        if key in changes and changes[key] is None:
            changes[key] = ""
    audit.update(session, application, changes, author)
    return _application_out(session, application)


@router.delete("/applications/{application_id}", status_code=204)
def delete_application(application_id: int, session: SessionDep, author: AuthorDep) -> None:
    """Soft delete, with its status events and interviews, in one batch."""
    service.delete_application(session, get_or_404(session, Application, application_id), author)


@router.get("/applications/{application_id}/status", response_model=list[StatusEventOut])
def list_status_events(application_id: int, session: SessionDep) -> list[StatusEventOut]:
    """The dated status history, oldest first."""
    get_or_404(session, Application, application_id)
    events = session.scalars(
        select(ApplicationStatusEvent)
        .where(ApplicationStatusEvent.application_id == application_id)
        .order_by(ApplicationStatusEvent.on_date, ApplicationStatusEvent.id)
    ).all()
    return [StatusEventOut.model_validate(e) for e in events]


@router.post(
    "/applications/{application_id}/status", response_model=ApplicationOut, status_code=201
)
def add_status_event(
    application_id: int, payload: JobStatusChange, session: SessionDep, author: AuthorDep
) -> ApplicationOut:
    """Append a dated status event; the status follows the latest event. An event dated before
    the latest one is recorded but leaves the status alone. Giving an open lead an active or
    closed status submits it first (as /apply)."""
    application = get_or_404(session, Application, application_id)
    try:
        service.add_status(
            session, application, payload.status, author, on_date=payload.on_date, note=payload.note
        )
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    return _application_out(session, application)


@router.post("/applications/{application_id}/apply", response_model=ApplicationOut)
def apply_to_lead(
    application_id: int, session: SessionDep, author: AuthorDep, payload: JobApplyIn | None = None
) -> ApplicationOut:
    """Submit an open lead: sets date_applied and appends an `applied` event, in one batch. The
    day cannot be before the day the lead was found."""
    payload = payload or JobApplyIn()
    application = get_or_404(session, Application, application_id)
    try:
        service.apply_lead(
            session,
            application,
            author,
            on_date=payload.on_date,
            status=payload.status or statuses.APPLIED,
        )
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    return _application_out(session, application)


@router.post("/applications/{application_id}/drop", response_model=ApplicationOut)
def drop_lead(
    application_id: int, payload: JobDropIn, session: SessionDep, author: AuthorDep
) -> ApplicationOut:
    """Cut an open lead without applying: status `dropped`, dated today. The reason goes in the
    status event and is appended to the notes."""
    application = get_or_404(session, Application, application_id)
    try:
        service.drop_lead(session, application, payload.reason, author)
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    return _application_out(session, application)


@router.patch("/status-events/{event_id}", response_model=StatusEventOut)
def update_status_event(
    event_id: int, payload: StatusEventUpdate, session: SessionDep, author: AuthorDep
) -> StatusEventOut:
    """Fix a status event's date, status or note. Lead events keep their status."""
    event = get_or_404(session, ApplicationStatusEvent, event_id)
    application = get_or_404(session, Application, event.application_id)
    changes = payload.model_dump(exclude_unset=True, exclude_none=True)
    if "status" in changes and changes["status"] != event.status:
        lead_kinds = (statuses.LEAD, statuses.DROPPED)
        if event.status in lead_kinds or changes["status"] in lead_kinds:
            raise HTTPException(422, "lead and dropped are set by the lead routes only")
        try:
            statuses.require(session, changes["status"], ("active", "closed"))
        except ValueError as exc:
            raise _http(exc) from exc
    with audit.transaction(session):
        audit.update(session, event, changes, author)
        sync_application_status(session, application, author)
    return StatusEventOut.model_validate(event)


@router.delete("/status-events/{event_id}", status_code=204)
def delete_status_event(event_id: int, session: SessionDep, author: AuthorDep) -> None:
    """Soft delete. An application keeps at least one status event."""
    event = get_or_404(session, ApplicationStatusEvent, event_id)
    application = get_or_404(session, Application, event.application_id)
    others = session.scalars(
        select(ApplicationStatusEvent.id).where(
            ApplicationStatusEvent.application_id == application.id,
            ApplicationStatusEvent.id != event.id,
        )
    ).all()
    if not others:
        raise HTTPException(409, "an application keeps at least one status event")
    with audit.transaction(session):
        audit.delete(session, event, author)
        sync_application_status(session, application, author)


# --------------------------------------------------------------------------- leads


@router.get("/leads", response_model=list[ApplicationOut])
def list_leads(
    session: SessionDep,
    include_dropped: bool = Query(False, description="Also the leads cut without applying"),
    limit: int = Query(1000, ge=1, le=5000),
) -> list[ApplicationOut]:
    """Open leads, newest logged first."""
    keys = [statuses.LEAD, statuses.DROPPED] if include_dropped else [statuses.LEAD]
    rows = pipeline.filtered_rows(session, pipeline.Filters(), keys)
    rows.sort(key=lambda pair: -pair[0].id)
    return _application_outs(session, [(a, c.name) for a, c in rows[:limit]])


@router.post("/leads", response_model=ApplicationCreatedOut, status_code=201)
def create_lead(
    payload: LeadCreate, session: SessionDep, author: AuthorDep
) -> ApplicationCreatedOut:
    """Log a posting worth applying to: status `lead`, no date_applied, its history starting on
    found_on (default today), in one batch.

    Refused with 409, naming the record, when the company already has a lead or application with
    the same title (ignoring case, spacing and punctuation; dropped leads do not count). `force`
    logs it anyway, for a reposting."""
    try:
        with audit.transaction(session):
            company_id, company_created = _company_ref(session, payload, author)
            fields = payload.model_dump(exclude={"company", "company_id", "found_on", "force"})
            lead = service.create_lead(
                session,
                {**fields, "company_id": company_id},
                author,
                found_on=payload.found_on,
                force=payload.force,
            )
    except (service.Conflict, ValueError) as exc:
        raise _http(exc) from exc
    out = _application_out(session, lead)
    return ApplicationCreatedOut(**out.model_dump(), company_created=company_created)


# --------------------------------------------------------------------------- contacts


def _contact_out(session: Session, contact: Contact) -> ContactOut:
    company = (
        session.get(Company, contact.company_id, execution_options={"include_deleted": True})
        if contact.company_id
        else None
    )
    return ContactOut.model_validate(
        {**_attrs(contact), "company": company.name if company else None}
    )


@router.get("/contacts", response_model=list[ContactOut])
def list_contacts(
    session: SessionDep,
    company_id: int | None = None,
    tag: str | None = None,
    q: str | None = Query(None, description="Part of the name, role or company"),
    due_by: dt.date | None = Query(None, description="Only next actions due on or before"),
) -> list[ContactOut]:
    """Contacts by name."""
    stmt = select(Contact).order_by(Contact.name, Contact.id)
    if company_id is not None:
        stmt = stmt.where(Contact.company_id == company_id)
    if due_by is not None:
        stmt = stmt.where(Contact.next_action_due <= due_by)
    out = [_contact_out(session, c) for c in session.scalars(stmt)]
    if tag:
        out = [c for c in out if tag.casefold() in (t.casefold() for t in c.tags)]
    if q:
        needle = q.casefold()
        out = [
            c
            for c in out
            if needle in c.name.casefold()
            or needle in c.role.casefold()
            or needle in (c.company or "").casefold()
        ]
    return out


@router.post("/contacts", response_model=ContactCreatedOut, status_code=201)
def create_contact(
    payload: ContactCreate, session: SessionDep, author: AuthorDep
) -> ContactCreatedOut:
    """A contact may belong to a company (by id or name; a new name creates it) or to none."""
    with audit.transaction(session):
        company_id, created = (None, False)
        if payload.company_id is not None or payload.company:
            company_id, created = _company_ref(session, payload, author)
        fields = payload.model_dump(exclude={"company", "company_id"})
        fields["tags"] = service.normalize_tags(fields["tags"])
        contact = audit.create(session, Contact(**fields, company_id=company_id), author)
    return ContactCreatedOut(**_contact_out(session, contact).model_dump(), company_created=created)


@router.get("/contacts/{contact_id}", response_model=ContactOut)
def get_contact(contact_id: int, session: SessionDep) -> ContactOut:
    return _contact_out(session, get_or_404(session, Contact, contact_id))


@router.patch("/contacts/{contact_id}", response_model=ContactOut)
def update_contact(
    contact_id: int, payload: ContactUpdate, session: SessionDep, author: AuthorDep
) -> ContactOut:
    contact = get_or_404(session, Contact, contact_id)
    changes = _tags(payload.model_dump(exclude_unset=True))
    _require_live(session, Company, changes.get("company_id"), "company")
    if "name" in changes and not changes["name"]:
        raise HTTPException(422, "a contact needs a name")
    for key in ("role", "email", "profile_url", "next_action", "notes"):
        if key in changes and changes[key] is None:
            changes[key] = ""
    audit.update(session, contact, changes, author)
    return _contact_out(session, contact)


@router.delete("/contacts/{contact_id}", status_code=204)
def delete_contact(contact_id: int, session: SessionDep, author: AuthorDep) -> None:
    audit.delete(session, get_or_404(session, Contact, contact_id), author)


# --------------------------------------------------------------------------- interviews


def _interview_out(session: Session, interview: Interview) -> InterviewOut:
    application = session.get(
        Application, interview.application_id, execution_options={"include_deleted": True}
    )
    company = session.get(
        Company, application.company_id, execution_options={"include_deleted": True}
    )
    return InterviewOut.model_validate(
        {
            **_attrs(interview),
            "company_id": application.company_id,
            "company": company.name if company else "",
            "application_title": application.title,
        }
    )


@router.get("/interviews", response_model=list[InterviewOut])
def list_interviews(
    session: SessionDep,
    application_id: int | None = None,
    upcoming: bool = Query(False, description="Only today on, and unscheduled ones"),
) -> list[InterviewOut]:
    """Interviews by day and time; unscheduled ones (no day) last."""
    stmt = select(Interview)
    if application_id is not None:
        stmt = stmt.where(Interview.application_id == application_id)
    rows = list(session.scalars(stmt))
    if upcoming:
        today = today_local()
        rows = [r for r in rows if r.on_date is None or r.on_date >= today]
    rows.sort(
        key=lambda r: (
            r.on_date is None,
            r.on_date or dt.date.max,
            r.start_time or dt.time.min,
            r.id,
        )
    )
    return [_interview_out(session, r) for r in rows]


@router.post("/interviews", response_model=InterviewOut, status_code=201)
def create_interview(
    payload: InterviewCreate, session: SessionDep, author: AuthorDep
) -> InterviewOut:
    """Record an interview. It shows on the calendar once it has a day. It does not change the
    application's status (POST /applications/{id}/status does)."""
    _require_live(session, Application, payload.application_id, "application")
    if payload.start_time is not None and payload.on_date is None:
        raise HTTPException(422, "a start time needs a day")
    interview = audit.create(session, Interview(**payload.model_dump()), author)
    return _interview_out(session, interview)


@router.get("/interviews/{interview_id}", response_model=InterviewOut)
def get_interview(interview_id: int, session: SessionDep) -> InterviewOut:
    return _interview_out(session, get_or_404(session, Interview, interview_id))


@router.patch("/interviews/{interview_id}", response_model=InterviewOut)
def update_interview(
    interview_id: int, payload: InterviewUpdate, session: SessionDep, author: AuthorDep
) -> InterviewOut:
    interview = get_or_404(session, Interview, interview_id)
    changes = payload.model_dump(exclude_unset=True)
    if "application_id" in changes:
        if changes["application_id"] is None:
            raise HTTPException(422, "an interview needs an application")
        _require_live(session, Application, changes["application_id"], "application")
    for key in ("stage", "location", "interviewer", "notes"):
        if key in changes and changes[key] is None:
            changes[key] = ""
    on_date = changes.get("on_date", interview.on_date)
    start = changes.get("start_time", interview.start_time)
    if start is not None and on_date is None:
        raise HTTPException(422, "a start time needs a day")
    audit.update(session, interview, changes, author)
    return _interview_out(session, interview)


@router.delete("/interviews/{interview_id}", status_code=204)
def delete_interview(interview_id: int, session: SessionDep, author: AuthorDep) -> None:
    audit.delete(session, get_or_404(session, Interview, interview_id), author)


# --------------------------------------------------------------------------- events


@router.get("/events", response_model=list[JobEventOut])
def list_events(
    session: SessionDep,
    start: dt.date | None = Query(None, description="On or after"),
    end: dt.date | None = Query(None, description="On or before"),
) -> list[JobEventOut]:
    """Job events by day and time."""
    stmt = select(JobEvent)
    if start is not None:
        stmt = stmt.where(JobEvent.on_date >= start)
    if end is not None:
        stmt = stmt.where(JobEvent.on_date <= end)
    rows = sorted(
        session.scalars(stmt), key=lambda e: (e.on_date, e.start_time or dt.time.min, e.id)
    )
    return [JobEventOut.model_validate(e) for e in rows]


def _check_event_times(start: dt.time | None, end: dt.time | None) -> None:
    if end is not None and (start is None or end <= start):
        raise HTTPException(422, "an end time needs a start time before it")


@router.post("/events", response_model=JobEventOut, status_code=201)
def create_event(payload: JobEventCreate, session: SessionDep, author: AuthorDep) -> JobEventOut:
    _check_event_times(payload.start_time, payload.end_time)
    fields = payload.model_dump()
    fields["tags"] = service.normalize_tags(fields["tags"])
    return JobEventOut.model_validate(audit.create(session, JobEvent(**fields), author))


@router.get("/events/{event_id}", response_model=JobEventOut)
def get_event(event_id: int, session: SessionDep) -> JobEventOut:
    return JobEventOut.model_validate(get_or_404(session, JobEvent, event_id))


@router.patch("/events/{event_id}", response_model=JobEventOut)
def update_event(
    event_id: int, payload: JobEventUpdate, session: SessionDep, author: AuthorDep
) -> JobEventOut:
    event = get_or_404(session, JobEvent, event_id)
    changes = _tags(payload.model_dump(exclude_unset=True))
    if "name" in changes and not changes["name"]:
        raise HTTPException(422, "an event needs a name")
    if "on_date" in changes and changes["on_date"] is None:
        raise HTTPException(422, "an event needs a day")
    for key in ("kind", "location", "url", "notes"):
        if key in changes and changes[key] is None:
            changes[key] = ""
    _check_event_times(
        changes.get("start_time", event.start_time), changes.get("end_time", event.end_time)
    )
    audit.update(session, event, changes, author)
    return JobEventOut.model_validate(event)


@router.delete("/events/{event_id}", status_code=204)
def delete_event(event_id: int, session: SessionDep, author: AuthorDep) -> None:
    audit.delete(session, get_or_404(session, JobEvent, event_id), author)


# --------------------------------------------------------------------------- goals


@router.get("/goals", response_model=list[WeeklyGoalOut])
def list_goals(session: SessionDep) -> list[WeeklyGoalOut]:
    return [
        WeeklyGoalOut.model_validate(g)
        for g in session.scalars(select(WeeklyGoal).order_by(WeeklyGoal.id))
    ]


@router.post("/goals", response_model=WeeklyGoalOut, status_code=201)
def create_goal(payload: WeeklyGoalCreate, session: SessionDep, author: AuthorDep) -> WeeklyGoalOut:
    """One goal per metric; a second for the same metric is refused (change its target)."""
    existing = session.scalars(
        select(WeeklyGoal).where(WeeklyGoal.metric == payload.metric)
    ).first()
    if existing is not None:
        raise HTTPException(409, f"goal {existing.id} already counts {payload.metric}")
    return WeeklyGoalOut.model_validate(
        audit.create(session, WeeklyGoal(**payload.model_dump()), author)
    )


@router.patch("/goals/{goal_id}", response_model=WeeklyGoalOut)
def update_goal(
    goal_id: int, payload: WeeklyGoalUpdate, session: SessionDep, author: AuthorDep
) -> WeeklyGoalOut:
    goal = get_or_404(session, WeeklyGoal, goal_id)
    audit.update(session, goal, payload.model_dump(), author)
    return WeeklyGoalOut.model_validate(goal)


@router.delete("/goals/{goal_id}", status_code=204)
def delete_goal(goal_id: int, session: SessionDep, author: AuthorDep) -> None:
    audit.delete(session, get_or_404(session, WeeklyGoal, goal_id), author)


@router.get("/goals/progress", response_model=WeekProgressOut)
def goal_progress(
    session: SessionDep,
    week: dt.date | None = Query(None, description="Any day of the week; default today"),
) -> WeekProgressOut:
    """Each goal's count for the week (Monday to Sunday) against its target."""
    return WeekProgressOut.model_validate(goals.progress(session, week or today_local()))


# --------------------------------------------------------------------------- pipeline, tags


@router.get("/pipeline", response_model=PipelineOut)
def get_pipeline(session: SessionDep, filters: FiltersDep) -> PipelineOut:
    """Counts by current status, how far applications got (`reached`), leads apart, and
    interviews. Counts, never rates. Takes the applications list's filters."""
    return PipelineOut.model_validate(pipeline.pipeline(session, filters))


@router.get("/tags", response_model=JobTagsOut)
def list_tags(session: SessionDep) -> JobTagsOut:
    """Every tag in use on companies, applications, contacts and events, for filters."""
    seen: dict[str, str] = {}
    for model in (Company, Application, Contact, JobEvent):
        for tags in session.scalars(select(model.tags)):
            for tag in tags or []:
                seen.setdefault(tag.casefold(), tag)
    return JobTagsOut(tags=sorted(seen.values(), key=str.casefold))
