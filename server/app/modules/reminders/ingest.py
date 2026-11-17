"""The Mac helper's Apple Reminders endpoints, mounted at /api/ingest behind the `ingest` scope
(app.main). The contract is in docs/REMINDERS.md:

- `POST /api/ingest/reminders`: a full snapshot of every Apple Reminders list. Apple lists and
  reminders are replaced (anything absent is gone); Google Tasks rows are untouched.
- `GET /api/ingest/reminders/ops`: pending Apple ops, oldest first, and `instance_id`, this
  database's identity. Each call records that the helper is polling, which is what tells
  "syncing" from "waiting for the device". Google ops never appear here: the server applies
  them itself. An op whose reminder is gone (or is no longer the one it was queued for) is
  failed instead of sent.
- `POST /api/ingest/reminders/ops/{id}/ack`: the result of applying one op. The helper sends
  back the `instance_id` it got the op with; an ack for another instance is refused (409).

Sizes are bounded: at most MAX_LISTS lists and MAX_REMINDERS reminders per snapshot, titles,
notes and urls up to MAX_TITLE, MAX_NOTES and MAX_URL characters (a larger snapshot is a 422).

Mirrored rows are written directly (rule 4 covers owned records only); op state goes through
app.audit.
"""

import re
from datetime import date, datetime, time
from typing import Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, field_validator

from app import audit, freshness
from app.deps import AuthorDep, SessionDep
from app.modules.reminders import sync
from app.modules.reminders.accounts import HELPER_SOURCE
from app.modules.reminders.models import ReminderOp
from app.modules.reminders.schemas import MAX_NOTES, OpFieldValue, OpKind, ReminderOpOut
from app.timeutil import utcnow

router = APIRouter()

MAX_LISTS = 500
MAX_REMINDERS = 20_000
MAX_TITLE = 5_000
MAX_URL = 4_000
MAX_CONFLICTS = 50
MAX_ERROR = 2_000

_HEX_COLOR = re.compile(r"#?([0-9A-Fa-f]{6})(?:[0-9A-Fa-f]{2})?")


def normalize_color(value: str | None) -> str | None:
    """`#RRGGBB` in upper case. `#RRGGBBAA` loses its alpha. Anything else is None."""
    if not value:
        return None
    match = _HEX_COLOR.fullmatch(value.strip())
    return f"#{match.group(1).upper()}" if match else None


# --------------------------------------------------------------------------- snapshot


class ReminderListIn(BaseModel):
    id: str = Field(min_length=1, max_length=1000, description="EKCalendar.calendarIdentifier")
    title: str = Field(default="", max_length=500)
    color: str | None = Field(default=None, max_length=16)
    account: str | None = Field(default=None, max_length=500)
    account_type: str | None = Field(default=None, max_length=32)
    writable: bool = True


class ReminderIn(BaseModel):
    external_id: str | None = Field(
        default=None, max_length=1000, description="calendarItemExternalIdentifier"
    )
    local_id: str = Field(min_length=1, max_length=1000, description="calendarItemIdentifier")
    list_id: str = Field(max_length=1000, description="One of the snapshot's own lists")
    title: str = Field(default="", max_length=MAX_TITLE)
    notes: str | None = Field(default=None, max_length=MAX_NOTES)
    due_date: date | None = None
    due_time: time | None = Field(default=None, description="HH:MM, local wall clock")
    priority: int | None = Field(default=None, ge=1, le=3)
    completed: bool = False
    completed_at: datetime | None = None
    url: str | None = Field(default=None, max_length=MAX_URL)
    created_at: datetime | None = None
    modified_at: datetime | None = None

    @field_validator("notes")
    @classmethod
    def notes_text(cls, value: str | None) -> str:
        return value or ""


class RemindersPushIn(BaseModel):
    lists: list[ReminderListIn] = Field(max_length=MAX_LISTS)
    default_list_id: str | None = Field(default=None, max_length=1000)
    reminders: list[ReminderIn] = Field(
        max_length=MAX_REMINDERS,
        description="A reminder whose list_id is not in `lists` is dropped",
    )


class RemindersPushOut(BaseModel):
    lists: int
    reminders: int
    removed: int


@router.post("/reminders", response_model=RemindersPushOut)
def push_reminders(payload: RemindersPushIn, session: SessionDep) -> RemindersPushOut:
    """Replace the Apple Reminders mirror with this snapshot."""
    now = utcnow()
    try:
        lists = [
            sync.IncomingList(
                id=lst.id,
                title=lst.title,
                color=normalize_color(lst.color),
                account=lst.account or "",
                account_type=lst.account_type,
                writable=lst.writable,
            )
            for lst in payload.lists
        ]
        reminders = [
            sync.IncomingReminder(
                external_id=r.external_id or None,
                local_id=r.local_id,
                list_id=r.list_id,
                title=r.title,
                notes=r.notes or "",
                due_date=r.due_date,
                due_time=r.due_time,
                priority=r.priority,
                completed=r.completed,
                completed_at=r.completed_at,
                url=r.url or None,
                created_at=r.created_at,
                modified_at=r.modified_at,
            )
            for r in payload.reminders
        ]
        with audit.transaction(session):
            counts = sync.replace_snapshot(
                session, sync.Scope("apple"), lists, reminders, payload.default_list_id, now
            )
        freshness.mark_success(session, HELPER_SOURCE, at=now)  # commits
    except Exception as exc:
        session.rollback()
        freshness.mark_error(session, HELPER_SOURCE, str(exc) or type(exc).__name__)
        raise
    return RemindersPushOut(lists=counts.lists, reminders=counts.reminders, removed=counts.removed)


# --------------------------------------------------------------------------- ops


class HelperOpOut(BaseModel):
    id: int
    reminder_id: int
    kind: OpKind
    external_id: str | None = Field(description="The target's calendarItemExternalIdentifier")
    local_id: str | None = Field(description="The target's calendarItemIdentifier")
    fields: dict[str, OpFieldValue] = Field(
        description="Fields to set; a key that is absent stays as it is"
    )
    base: dict[str, OpFieldValue | bool] = Field(
        description="What the organizer believed Reminders held for those fields when queued"
    )
    queued_at: datetime


class HelperOpsOut(BaseModel):
    ops: list[HelperOpOut]
    server_time: datetime
    instance_id: str = Field(
        description="This database's identity, stable for its life. Op ids are unique within "
        "it only: key anything remembered about an op by (instance_id, id)."
    )


@router.get("/reminders/ops", response_model=HelperOpsOut)
def pending_ops(session: SessionDep) -> HelperOpsOut:
    """Pending Apple ops in queue order. Apply them in this order, per reminder."""
    now = utcnow()
    sync.record_ops_poll(session, now)
    instance = sync.instance_id(session)
    with audit.transaction(session):
        pending = sync.fail_stale(session, sync.pending_for(session, "helper"), sync.SYSTEM)
    out = [
        HelperOpOut(
            id=op.id,
            reminder_id=op.reminder_id,
            kind=op.kind,  # type: ignore[arg-type]
            external_id=row.ext_id,
            local_id=row.local_id,
            fields=dict(op.payload or {}),
            base=dict(op.base or {}),
            queued_at=op.created_at,
        )
        for op, row in pending
    ]
    return HelperOpsOut(ops=out, server_time=now, instance_id=instance)


class ConflictIn(BaseModel):
    field: str = Field(max_length=32)
    kept: Literal["provider", "organizer"]
    provider_value: str | None = Field(default=None, max_length=MAX_NOTES)
    organizer_value: str | None = Field(default=None, max_length=MAX_NOTES)


class AckIn(BaseModel):
    ok: bool
    external_id: str | None = Field(default=None, max_length=1000)
    local_id: str | None = Field(default=None, max_length=1000)
    error: str | None = Field(default=None, max_length=MAX_ERROR * 5)
    conflicts: list[ConflictIn] = Field(default_factory=list, max_length=MAX_CONFLICTS)
    instance_id: str | None = Field(
        default=None,
        max_length=64,
        description="The instance_id the op was fetched with; another instance's ack is a 409",
    )


@router.post("/reminders/ops/{op_id}/ack", response_model=ReminderOpOut)
def ack_op(op_id: int, payload: AckIn, session: SessionDep, author: AuthorDep) -> ReminderOpOut:
    """Record what applying one op did. An op withdrawn in the organizer meanwhile is a 404;
    the helper drops it (whatever it changed is mirrored by the next push)."""
    if payload.instance_id is not None and payload.instance_id != sync.instance_id(session):
        raise HTTPException(409, "this op came from another server instance; drop it")
    op = session.get(ReminderOp, op_id)
    if op is None or op.deleted_at is not None or op.applier != "helper":
        raise HTTPException(404, f"op {op_id} not found (withdrawn?)")
    sync.apply_ack(
        session,
        op,
        ok=payload.ok,
        external_id=payload.external_id or None,
        local_id=payload.local_id or None,
        error=payload.error,
        conflicts=[c.model_dump() for c in payload.conflicts],
        author=author,
    )
    return sync.op_out(op)
