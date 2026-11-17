"""The job tracker: applications and leads, companies, contacts, interviews, events, the pipeline
and weekly goals. Reads and writes through /api/jobs with the `api` token.

A lead is an application whose status is `lead`: a posting is one record from the day it is
found to the day it closes. Statuses are a list the owner can edit (job_statuses); `lead`,
`applied` and `dropped` always exist. A company is given by name, or by id as "#12" (see
`_company_id`). Every write is logged under the token's author and can be reverted from History
in the web app.
"""

from __future__ import annotations

import datetime as dt
import re
from typing import Any, Literal

from mcp.types import ToolAnnotations

from organizer_mcp.client import OrganizerError
from organizer_mcp.core import app, client

TOOLSET = "jobs"
SCOPE = "api"
READS = frozenset(
    {
        "applications",
        "leads",
        "companies",
        "contacts",
        "interviews",
        "job_events",
        "pipeline",
        "job_statuses",
        "weekly_goals",
    }
)
WRITES = frozenset(
    {
        "add_application",
        "set_application_status",
        "add_lead",
        "mark_applied",
        "drop_lead",
        "update_company",
        "add_contact",
        "update_contact",
        "add_interview",
        "update_interview",
        "add_job_event",
        "update_job_event",
        "set_weekly_goal",
    }
)
TOOLS = READS | WRITES

READ_ONLY = ToolAnnotations(readOnlyHint=True)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False)
# set_weekly_goal removes a goal when its target is None.
WRITE_MAY_DELETE = ToolAnnotations(readOnlyHint=False, destructiveHint=True)
DESTRUCTIVE = frozenset({"set_weekly_goal"})

Metric = Literal["applications", "outreach", "leads", "interviews", "events"]
ClearApplicationField = Literal["next_action", "next_action_due"]
ClearContactField = Literal["contacted_on", "replied_on", "next_action", "next_action_due"]
ClearInterviewField = Literal["on_date", "start_time", "duration_minutes"]
ClearEventField = Literal["start_time", "end_time", "attended"]

# Text fields the organizer stores as "" rather than null: clearing one sends "".
_TEXT_FIELDS = frozenset({"next_action"})

APPLICATION_FIELDS = (
    "id",
    "company_id",
    "company",
    "title",
    "status",
    "reached",
    "date_applied",
    "found_on",
    "location",
    "posting_url",
    "source",
    "next_action",
    "next_action_due",
    "tags",
    "notes",
)
CONTACT_FIELDS = (
    "id",
    "name",
    "company_id",
    "company",
    "role",
    "email",
    "profile_url",
    "contacted_on",
    "replied_on",
    "next_action",
    "next_action_due",
    "tags",
    "notes",
)
INTERVIEW_FIELDS = (
    "id",
    "application_id",
    "company",
    "application_title",
    "stage",
    "on_date",
    "start_time",
    "duration_minutes",
    "location",
    "interviewer",
    "notes",
)
EVENT_FIELDS = (
    "id",
    "name",
    "kind",
    "on_date",
    "start_time",
    "end_time",
    "location",
    "url",
    "attended",
    "tags",
    "notes",
)
COMPANY_FIELDS = ("id", "name", "website", "target", "tags", "notes")


def _pick(row: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
    return {name: row.get(name) for name in fields}


def _drop_none(body: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in body.items() if value is not None}


def _patch_body(fields: dict[str, Any], clear: list[str] | None) -> dict[str, Any]:
    """The fields given, plus each field named in clear set to null ("" for text)."""
    body = _drop_none(fields)
    for name in clear or []:
        if name in body:
            raise OrganizerError(f"{name} is both set and listed in clear; pick one")
        body[name] = "" if name in _TEXT_FIELDS else None
    if not body:
        raise OrganizerError("nothing to change: pass at least one field")
    return body


def _time(value: dt.time | None) -> str | None:
    return None if value is None else value.strftime("%H:%M")


def _fold(text: str) -> str:
    return " ".join(text.split()).casefold()


_ID_PREFIXED = re.compile(r"(?:#|id:)\s*([0-9]+)", re.ASCII | re.IGNORECASE)
_ASCII_DIGITS = re.compile(r"[0-9]+", re.ASCII)


def _company_id(company: str | int) -> int:
    """A company's id, from an id or a name.

    An int, "#12" or "id:12" is an id. Anything else is a name, matched ignoring case and
    spacing, so a company named "1984" is found by its name. Text of ASCII digits that names no
    company is still read as an id, as it was before the "#" form existed. Digits outside ASCII
    ("²", "١٢") are only ever part of a name.
    """
    if isinstance(company, int) and not isinstance(company, bool):
        return company
    text = " ".join(str(company).split())
    prefixed = _ID_PREFIXED.fullmatch(text)
    if prefixed:
        return int(prefixed[1])
    rows = client().get("/api/jobs/companies", params={"q": text})
    for row in rows:
        if _fold(row["name"]) == _fold(text):
            return int(row["id"])
    if _ASCII_DIGITS.fullmatch(text):
        return int(text)
    raise OrganizerError(f"not found: no company named {company!r} (companies lists them)")


def _applications_out(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [_pick(row, APPLICATION_FIELDS) for row in rows]


def _created(row: dict[str, Any]) -> dict[str, Any]:
    out = _pick(row, APPLICATION_FIELDS)
    out["company_created"] = row.get("company_created", False)
    out["promoted_from_lead"] = row.get("promoted_from_lead", False)
    out["lead_candidates"] = row.get("lead_candidates", [])
    return out


# --------------------------------------------------------------------------- reads


@app.tool(annotations=READ_ONLY)
def applications(
    status: str | list[str] | None = None,
    company: str | None = None,
    tag: str | None = None,
    since: dt.date | None = None,
    until: dt.date | None = None,
    q: str | None = None,
    include_leads: bool = False,
) -> list[dict[str, Any]]:
    """Job applications, newest applied first, undated ones last. Filters combine.

    status takes one or more status keys (job_statuses lists them). Leads are left out unless
    include_leads is true or status names lead or dropped (see leads). company is a company's name
    or "#id". tag matches the application's tags or its company's, ignoring case. since and until
    bound date_applied, inclusive. q matches part of the title or the company name. Each
    application is {id, company_id, company, title, status, reached, date_applied, found_on,
    location, posting_url, source, next_action, next_action_due, tags, notes}. reached is the
    furthest stage its status history got to, so a rejected application can still show it reached
    interview.
    """
    statuses = [status] if isinstance(status, str) else status
    rows = client().get(
        "/api/jobs/applications",
        params={
            "status": statuses or None,
            "company_id": None if company is None else _company_id(company),
            "tag": tag,
            "applied_from": since,
            "applied_to": until,
            "q": q or None,
            "leads": "include" if include_leads else None,
        },
    )
    return _applications_out(rows)


@app.tool(annotations=READ_ONLY)
def leads(include_dropped: bool = False) -> list[dict[str, Any]]:
    """Leads: postings worth applying to, not submitted yet, newest logged first.

    include_dropped=False (the default) lists the open leads. True adds the ones cut without
    applying, whose reason is at the end of their notes. A lead has no date_applied; found_on is
    the day it was logged. mark_applied turns a lead into an application. Each lead has the same
    fields as applications.
    """
    rows = client().get("/api/jobs/leads", params={"include_dropped": include_dropped or None})
    return _applications_out(rows)


@app.tool(annotations=READ_ONLY)
def companies(
    q: str | None = None, tag: str | None = None, target_only: bool = False
) -> list[dict[str, Any]]:
    """Companies by name, with how many applications (leads not counted), open leads and
    contacts each has.

    q matches part of the name; tag filters by a tag, ignoring case; target_only keeps the
    companies flagged as targets. Each row is {id, name, website, target, tags, notes,
    applications, leads, contacts}.
    """
    rows = client().get(
        "/api/jobs/companies",
        params={"q": q or None, "tag": tag, "target": True if target_only else None},
    )
    return [
        {**_pick(row, COMPANY_FIELDS), **_pick(row, ("applications", "leads", "contacts"))}
        for row in rows
    ]


@app.tool(annotations=READ_ONLY)
def contacts(
    company: str | None = None, q: str | None = None, due_by: dt.date | None = None
) -> list[dict[str, Any]]:
    """Contacts, by name. Omit the filters for every contact.

    company is a company's name or "#id"; an unknown name is a not-found error. q matches part of
    the name, role or company. due_by keeps the contacts whose next action is due on or before
    that day. Each contact is {id, name, company_id, company, role, email, profile_url,
    contacted_on, replied_on, next_action, next_action_due, tags, notes}.
    """
    rows = client().get(
        "/api/jobs/contacts",
        params={
            "company_id": None if company is None else _company_id(company),
            "q": q or None,
            "due_by": due_by,
        },
    )
    return [_pick(row, CONTACT_FIELDS) for row in rows]


@app.tool(annotations=READ_ONLY)
def interviews(
    upcoming_only: bool = True, application_id: int | None = None
) -> list[dict[str, Any]]:
    """Interviews by day and time; ones without a day yet (still being scheduled) come last.

    upcoming_only=True (the default) keeps the ones from today on and the unscheduled ones; pass
    False for the full history. application_id limits the list to one application. Each interview
    is {id, application_id, company, application_title, stage, on_date, start_time,
    duration_minutes, location, interviewer, notes}. Times are the organizer's local wall-clock
    time.
    """
    rows = client().get(
        "/api/jobs/interviews",
        params={"upcoming": upcoming_only or None, "application_id": application_id},
    )
    return [_pick(row, INTERVIEW_FIELDS) for row in rows]


@app.tool(annotations=READ_ONLY)
def job_events(since: dt.date | None = None, until: dt.date | None = None) -> list[dict[str, Any]]:
    """Job events (career fairs, networking, info sessions) by day, optionally between since and
    until, inclusive. Each event is {id, name, kind, on_date, start_time, end_time, location, url,
    attended, tags, notes}; attended is null until it is marked.
    """
    rows = client().get("/api/jobs/events", params={"start": since, "end": until})
    return [_pick(row, EVENT_FIELDS) for row in rows]


@app.tool(annotations=READ_ONLY)
def pipeline(
    company: str | None = None,
    tag: str | None = None,
    since: dt.date | None = None,
    until: dt.date | None = None,
) -> Any:
    """Application counts by status, with the same filters as applications. These are counts,
    not conversion rates.

    by_status is each application's current status only: one that had a screen and an interview
    and was then rejected counts only as rejected, so zero screens there does not mean nobody was
    screened. How far applications got is in reached (each active stage in order, from the dated
    status history) and interviews (applications with interview records, and the records).

    Submitted applications are counted on their own (total). Leads are reported apart in leads
    (open and dropped) and are not in the total.
    """
    return client().get(
        "/api/jobs/pipeline",
        params={
            "company_id": None if company is None else _company_id(company),
            "tag": tag,
            "applied_from": since,
            "applied_to": until,
        },
    )


@app.tool(annotations=READ_ONLY)
def job_statuses() -> list[dict[str, Any]]:
    """The status list, in order: [{key, label, kind}]. Use the keys in the other tools.

    kind is lead (an open lead), dropped (a lead cut without applying), active (submitted and
    moving forward; their order is the stages reached counts) or closed (finished without moving
    on). The owner can rename and add statuses; lead, applied and dropped always exist.
    """
    rows = client().get("/api/jobs/statuses")
    return [_pick(row, ("key", "label", "kind")) for row in rows]


@app.tool(annotations=READ_ONLY)
def weekly_goals(week: dt.date | None = None) -> Any:
    """Progress on the owner's weekly goals for the week (Monday to Sunday) containing week
    (default this week): {week_start, week_end, goals: [{id, metric, label, target, actual}]}.

    A goal counts one metric: applications (date applied in the week), outreach (contacts first
    reached out to in the week), leads (logged in the week), interviews or events (on a day in the
    week). Goals are optional; an empty list means none are set.
    """
    return client().get("/api/jobs/goals/progress", params={"week": week})


# --------------------------------------------------------------------------- applications, leads


@app.tool(annotations=WRITE)
def add_application(
    company: str,
    title: str,
    status: str | None = None,
    date_applied: dt.date | None = None,
    location: str | None = None,
    posting_url: str | None = None,
    source: str | None = None,
    next_action: str | None = None,
    next_action_due: dt.date | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    """Record a job application.

    The company is matched by name (ignoring case and spacing) and created if it does not exist;
    company_created in the answer says which happened. status is an active or closed status key
    (default applied; job_statuses lists them). date_applied defaults to today. The status history
    gets applied, then the status given if it is past applied, both dated date_applied; when the
    application submits a lead (below), they are dated the later of date_applied and the day the
    lead was found instead, since the status follows the latest event.

    One record per posting: when exactly one open lead at the company has the same title
    (ignoring case, spacing and punctuation), that lead becomes the application, keeping its id,
    and promoted_from_lead is true. The values given here replace the lead's; ones left out keep
    the lead's, and notes are appended. When several open leads match, a new record is created and
    lead_candidates lists them for the owner to resolve. For a lead you already know the id of,
    mark_applied is the direct way. Returns the application.
    """
    body = _drop_none(
        {
            "company": company,
            "title": title,
            "status": status,
            "date_applied": date_applied,
            "location": location,
            "posting_url": posting_url,
            "source": source,
            "next_action": next_action,
            "next_action_due": next_action_due,
            "tags": tags,
            "notes": notes,
        }
    )
    return _created(client().post("/api/jobs/applications", body))


@app.tool(annotations=WRITE)
def set_application_status(
    application_id: int,
    status: str,
    on_date: dt.date | None = None,
    note: str | None = None,
) -> dict[str, Any]:
    """Record a status change on an application.

    This appends a dated status event, and the application's status follows its latest event.
    status is an active or closed status key (job_statuses). on_date defaults to today. An event
    dated before the latest one is recorded but leaves the current status alone. Giving an open
    lead a status submits it first, as mark_applied does; lead and dropped are set only by add_lead
    and drop_lead. Returns the application.
    """
    body = _drop_none({"status": status, "on_date": on_date, "note": note})
    row = client().post(f"/api/jobs/applications/{application_id}/status", body)
    return _pick(row, APPLICATION_FIELDS)


@app.tool(annotations=WRITE)
def add_lead(
    company: str,
    title: str,
    posting_url: str | None = None,
    source: str | None = None,
    location: str | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
    found_on: dt.date | None = None,
    force: bool = False,
) -> dict[str, Any]:
    """Log a lead: a posting worth applying to, before it is submitted.

    The company is matched by name (ignoring case and spacing) and created if it does not exist;
    company_created in the answer says which happened. found_on is the day the posting was found
    and defaults to today; it cannot be in the future. source is where it was found.

    A posting is logged once: if the company already has a lead or an application with the same
    title (ignoring case, spacing and punctuation; dropped leads do not count), this is refused and
    the error names that record's id and status; use it instead. force=True logs a new lead
    anyway, for a genuine reposting. An application later entered for this posting becomes this
    lead (same id). Returns the lead.
    """
    body = _drop_none(
        {
            "company": company,
            "title": title,
            "posting_url": posting_url,
            "source": source,
            "location": location,
            "tags": tags,
            "notes": notes,
            "found_on": found_on,
            "force": force or None,
        }
    )
    return _created(client().post("/api/jobs/leads", body))


@app.tool(annotations=WRITE)
def mark_applied(
    application_id: int, on_date: dt.date | None = None, status: str | None = None
) -> dict[str, Any]:
    """Turn an open lead into a submitted application.

    Sets date_applied to on_date (default today) and appends an applied status event (and status,
    when one past applied is given, on the same day); the lead's history is kept. The date cannot
    be before the day the lead was found, and only an open lead can be applied to. Returns the
    application.
    """
    body = _drop_none({"on_date": on_date, "status": status})
    row = client().post(f"/api/jobs/applications/{application_id}/apply", body or None)
    return _pick(row, APPLICATION_FIELDS)


@app.tool(annotations=WRITE)
def drop_lead(application_id: int, reason: str) -> dict[str, Any]:
    """Cut an open lead without applying.

    The lead's status becomes dropped, dated today. The reason is kept in its status history and
    appended to its notes; leads(include_dropped=True) still lists it. reason is required and must
    not be blank. Returns the lead.
    """
    row = client().post(f"/api/jobs/applications/{application_id}/drop", {"reason": reason})
    return _pick(row, APPLICATION_FIELDS)


# --------------------------------------------------------------------------- companies, contacts


@app.tool(annotations=WRITE)
def update_company(
    company: str,
    name: str | None = None,
    website: str | None = None,
    target: bool | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
    add_note: str | None = None,
) -> dict[str, Any]:
    """Change the fields you pass on a company. Returns the updated company.

    company is a name (ignoring case and spacing) or "#id". Fields you leave out keep their value.
    name renames it; a name another company already has is refused. target puts the company on
    the owner's target list (or takes it off). tags replaces the tags. notes replaces the notes;
    add_note appends a paragraph to them instead.
    """
    c = client()
    company_id = _company_id(company)
    if notes is not None and add_note is not None:
        raise OrganizerError("pass notes (replace) or add_note (append), not both")
    if add_note is not None:
        current = c.get(f"/api/jobs/companies/{company_id}").get("notes") or ""
        note = add_note.strip()
        notes = f"{current.rstrip()}\n\n{note}" if current.strip() else note
    body = _patch_body(
        {"name": name, "website": website, "target": target, "tags": tags, "notes": notes}, None
    )
    return _pick(c.patch(f"/api/jobs/companies/{company_id}", body), COMPANY_FIELDS)


@app.tool(annotations=WRITE)
def add_contact(
    name: str,
    company: str | None = None,
    role: str | None = None,
    email: str | None = None,
    profile_url: str | None = None,
    contacted_on: dt.date | None = None,
    replied_on: dt.date | None = None,
    next_action: str | None = None,
    next_action_due: dt.date | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    """Add a contact: a recruiter, a referrer, someone met at an event.

    company is matched by name and created if it does not exist (company_created in the answer
    says which happened); leave it out for someone at no company. contacted_on is the day the
    owner first reached out (it counts toward an outreach goal), replied_on the day they replied.
    A next action with a due date shows on the calendar. Returns the contact.
    """
    body = _drop_none(
        {
            "name": name,
            "company": company,
            "role": role,
            "email": email,
            "profile_url": profile_url,
            "contacted_on": contacted_on,
            "replied_on": replied_on,
            "next_action": next_action,
            "next_action_due": next_action_due,
            "tags": tags,
            "notes": notes,
        }
    )
    row = client().post("/api/jobs/contacts", body)
    return {**_pick(row, CONTACT_FIELDS), "company_created": row.get("company_created", False)}


@app.tool(annotations=WRITE)
def update_contact(
    contact_id: int,
    name: str | None = None,
    company: str | None = None,
    role: str | None = None,
    email: str | None = None,
    profile_url: str | None = None,
    contacted_on: dt.date | None = None,
    replied_on: dt.date | None = None,
    next_action: str | None = None,
    next_action_due: dt.date | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
    clear: list[ClearContactField] | None = None,
) -> dict[str, Any]:
    """Change the fields you pass on a contact. Returns the updated contact.

    Fields you leave out keep their value. To remove a value, name it in clear: contacted_on,
    replied_on, next_action or next_action_due (mark a next action done by clearing both).
    company moves the contact to the company with that name or "#id", which must exist. tags
    replaces the tags.
    """
    body = _patch_body(
        {
            "name": name,
            "company_id": None if company is None else _company_id(company),
            "role": role,
            "email": email,
            "profile_url": profile_url,
            "contacted_on": contacted_on,
            "replied_on": replied_on,
            "next_action": next_action,
            "next_action_due": next_action_due,
            "tags": tags,
            "notes": notes,
        },
        clear,
    )
    return _pick(client().patch(f"/api/jobs/contacts/{contact_id}", body), CONTACT_FIELDS)


# --------------------------------------------------------------------------- interviews, events


@app.tool(annotations=WRITE)
def add_interview(
    application_id: int,
    stage: str | None = None,
    on_date: dt.date | None = None,
    start_time: dt.time | None = None,
    duration_minutes: int | None = None,
    location: str | None = None,
    interviewer: str | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    """Record an interview once it is booked.

    on_date is the day and start_time the local wall-clock time (a time needs a day); leave both
    out while it is still being scheduled. duration_minutes defaults to an hour on the calendar.
    stage is free text such as "recruiter screen" or "onsite"; location is a place or a video
    link. The interview shows on the calendar once it has a day. It does not change the
    application's status: use set_application_status for that. Returns the interview.
    """
    body = _drop_none(
        {
            "application_id": application_id,
            "stage": stage,
            "on_date": on_date,
            "start_time": _time(start_time),
            "duration_minutes": duration_minutes,
            "location": location,
            "interviewer": interviewer,
            "notes": notes,
        }
    )
    return _pick(client().post("/api/jobs/interviews", body), INTERVIEW_FIELDS)


@app.tool(annotations=WRITE)
def update_interview(
    interview_id: int,
    stage: str | None = None,
    on_date: dt.date | None = None,
    start_time: dt.time | None = None,
    duration_minutes: int | None = None,
    location: str | None = None,
    interviewer: str | None = None,
    notes: str | None = None,
    clear: list[ClearInterviewField] | None = None,
) -> dict[str, Any]:
    """Change the fields you pass on an interview, e.g. when it is rescheduled.

    Fields you leave out keep their value. To remove the day, the time or the duration, name it in
    clear: on_date, start_time or duration_minutes (a time cannot stay without a day). Returns
    the updated interview.
    """
    body = _patch_body(
        {
            "stage": stage,
            "on_date": on_date,
            "start_time": _time(start_time),
            "duration_minutes": duration_minutes,
            "location": location,
            "interviewer": interviewer,
            "notes": notes,
        },
        clear,
    )
    return _pick(client().patch(f"/api/jobs/interviews/{interview_id}", body), INTERVIEW_FIELDS)


@app.tool(annotations=WRITE)
def add_job_event(
    name: str,
    on_date: dt.date,
    kind: str | None = None,
    start_time: dt.time | None = None,
    end_time: dt.time | None = None,
    location: str | None = None,
    url: str | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    """Add a job event: a career fair, a networking evening, an info session.

    kind is free text such as "fair" or "networking". start_time and end_time are local
    wall-clock times; without a start time the event is all day on the calendar. Returns the
    event.
    """
    body = _drop_none(
        {
            "name": name,
            "on_date": on_date,
            "kind": kind,
            "start_time": _time(start_time),
            "end_time": _time(end_time),
            "location": location,
            "url": url,
            "tags": tags,
            "notes": notes,
        }
    )
    return _pick(client().post("/api/jobs/events", body), EVENT_FIELDS)


@app.tool(annotations=WRITE)
def update_job_event(
    event_id: int,
    name: str | None = None,
    on_date: dt.date | None = None,
    kind: str | None = None,
    start_time: dt.time | None = None,
    end_time: dt.time | None = None,
    location: str | None = None,
    url: str | None = None,
    attended: bool | None = None,
    tags: list[str] | None = None,
    notes: str | None = None,
    clear: list[ClearEventField] | None = None,
) -> dict[str, Any]:
    """Change the fields you pass on a job event, e.g. mark it attended afterward.

    Fields you leave out keep their value. To remove a time or the attended mark, name it in
    clear: start_time, end_time or attended. Returns the updated event.
    """
    body = _patch_body(
        {
            "name": name,
            "on_date": on_date,
            "kind": kind,
            "start_time": _time(start_time),
            "end_time": _time(end_time),
            "location": location,
            "url": url,
            "attended": attended,
            "tags": tags,
            "notes": notes,
        },
        clear,
    )
    return _pick(client().patch(f"/api/jobs/events/{event_id}", body), EVENT_FIELDS)


@app.tool(annotations=WRITE_MAY_DELETE)
def set_weekly_goal(metric: Metric, target: int | None) -> dict[str, Any]:
    """Set the owner's weekly target for one metric, or remove that goal with target=None.

    metric is applications, outreach, leads, interviews or events (see weekly_goals for what each
    counts). Only set a goal the owner asked for. Returns {metric, target}, target null when the
    goal was removed.
    """
    c = client()
    existing = next((g for g in c.get("/api/jobs/goals") if g["metric"] == metric), None)
    if target is None:
        if existing is not None:
            c.delete(f"/api/jobs/goals/{existing['id']}")
        return {"metric": metric, "target": None}
    if existing is None:
        row = c.post("/api/jobs/goals", {"metric": metric, "target": target})
    else:
        row = c.patch(f"/api/jobs/goals/{existing['id']}", {"target": target})
    return {"metric": row["metric"], "target": row["target"]}
