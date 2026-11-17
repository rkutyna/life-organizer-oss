"""/api/reminders: reminders from Apple Reminders and Google Tasks as the organizer shows them,
and the changes queued for them.

Reads show each reminder as its provider last reported it with its queued changes applied, plus
`sync` (synced, syncing, waiting_for_device, failed). Writes never touch the mirror: create,
patch, complete and uncomplete each queue one op through app.audit (the author is the
request's credential: me from the web app, claude from MCP). A Google Tasks op is applied by
the server before the response; an Apple op waits for the Mac helper. A write that changes
nothing queues nothing.
"""

from collections.abc import Callable
from typing import TypeVar

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import freshness
from app.deps import AuthorDep, SessionDep, SettingsDep, get_or_404
from app.modules.reminders import accounts, service, sync
from app.modules.reminders.google_sync import sync_all
from app.modules.reminders.models import Reminder, ReminderOp
from app.modules.reminders.schemas import (
    GoogleTasksAccountOut,
    OpState,
    ReminderCreate,
    ReminderListOut,
    ReminderOpOut,
    ReminderOut,
    ReminderStatusOut,
    ReminderSyncOutcomeOut,
    ReminderUpdate,
)
from app.timeutil import utcnow

router = APIRouter()

T = TypeVar("T")


def _refusals(fn: Callable[[], T]) -> T:
    try:
        return fn()
    except service.ReminderRefused as exc:
        raise HTTPException(exc.status, exc.message) from None


def visible_rows(session: Session) -> list[Reminder]:
    """Apple rows and the rows of enabled Google Tasks accounts."""
    enabled = {account.id for account in accounts.tasks_accounts(session)}
    rows = session.scalars(select(Reminder).order_by(Reminder.id))
    return [row for row in rows if row.account_id is None or row.account_id in enabled]


@router.get("", response_model=list[ReminderOut])
def list_reminders(
    session: SessionDep,
    list_id: str | None = Query(
        None, alias="list", description="Only this list (an id from /lists)"
    ),
    include_completed: bool = Query(False, description="Also reminders completed (last 30 days)"),
    dated: bool | None = Query(None, description="true: only with a due date; false: only without"),
    limit: int = Query(1000, ge=1, le=5000),
) -> list[ReminderOut]:
    """Open reminders by due date (undated last), then completed ones, newest first."""
    out = [
        item
        for item in sync.render(session, visible_rows(session))
        if (list_id is None or item.list_id == list_id)
        and (include_completed or not item.completed)
        and (dated is None or (item.due_date is not None) == dated)
    ]
    out.sort(key=display_order)
    return out[:limit]


@router.get("/lists", response_model=list[ReminderListOut])
def reminder_lists(session: SessionDep) -> list[ReminderListOut]:
    """Every list: Apple Reminders first, then each Google account's task lists."""
    enabled = {account.id for account in accounts.tasks_accounts(session)}
    return sync.list_outs(session, enabled)


@router.get("/status", response_model=ReminderStatusOut)
def reminders_status(session: SessionDep) -> ReminderStatusOut:
    """Each source's freshness, whether the helper is polling, and what is queued or failed."""
    now = utcnow()
    current = accounts.tasks_accounts(session)
    accounts.label_freshness(current)
    last_poll = sync.last_ops_poll(session)
    pending = list(
        session.scalars(
            select(ReminderOp).where(ReminderOp.state == "pending").order_by(ReminderOp.id)
        )
    )
    failed = session.scalars(select(ReminderOp.id).where(ReminderOp.state == "failed")).all()
    helper_pending = [op for op in pending if op.applier == "helper"]
    polling = sync.helper_polling(last_poll, now)
    oldest_helper = helper_pending[0].created_at if helper_pending else None
    return ReminderStatusOut(
        helper=freshness.source_status(session, accounts.HELPER_SOURCE),
        google=[
            GoogleTasksAccountOut(
                account_id=account.id,
                label=account.label,
                freshness=freshness.source_status(session, accounts.freshness_key(account.id)),
            )
            for account in current
        ],
        last_ops_poll_at=last_poll,
        helper_polling=polling,
        pending_ops=len(pending),
        failed_ops=len(failed),
        oldest_pending_at=pending[0].created_at if pending else None,
        waiting_for_device=(
            oldest_helper is not None and now - oldest_helper > sync.WAITING_AFTER and not polling
        ),
    )


@router.post("/sync", response_model=list[ReminderSyncOutcomeOut])
def sync_now(session: SessionDep, settings: SettingsDep) -> list[ReminderSyncOutcomeOut]:
    """Poll every Google Tasks account now (and retry pending Google ops). Apple Reminders
    syncs whenever the Mac helper pushes."""
    return [ReminderSyncOutcomeOut(**vars(outcome)) for outcome in sync_all(session, settings)]


@router.get("/ops", response_model=list[ReminderOpOut])
def list_ops(
    session: SessionDep,
    state: OpState | None = Query(None, description="Default: pending and failed"),
    reminder_id: int | None = Query(None),
    limit: int = Query(200, ge=1, le=2000),
) -> list[ReminderOpOut]:
    """Queued changes, newest first."""
    stmt = select(ReminderOp).order_by(ReminderOp.id.desc()).limit(limit)
    if state is None:
        stmt = stmt.where(ReminderOp.state.in_(("pending", "failed")))
    else:
        stmt = stmt.where(ReminderOp.state == state)
    if reminder_id is not None:
        stmt = stmt.where(ReminderOp.reminder_id == reminder_id)
    return [sync.op_out(op) for op in session.scalars(stmt)]


@router.delete("/ops/{op_id}", status_code=204)
def withdraw_op(op_id: int, session: SessionDep, author: AuthorDep) -> None:
    """Withdraw a pending or failed op. Withdrawing a create the provider never got removes the
    reminder from the organizer. If the helper already picked the op up, its change may still
    land; the next push shows what Apple Reminders holds."""
    op = get_or_404(session, ReminderOp, op_id)
    if op.state == "applied":
        raise HTTPException(409, "the op was already applied")
    sync.cancel(session, op, author)


@router.post("/ops/{op_id}/retry", response_model=ReminderOpOut)
def retry_op(
    op_id: int, session: SessionDep, settings: SettingsDep, author: AuthorDep
) -> ReminderOpOut:
    """Queue a failed op again. A Google op is applied again at once."""
    op = get_or_404(session, ReminderOp, op_id)
    if op.state != "failed":
        raise HTTPException(409, f"only a failed op can be retried (this one is {op.state})")
    service.retry(session, settings, op, author)
    session.refresh(op)
    return sync.op_out(op)


@router.post("", response_model=ReminderOut, status_code=201)
def create_reminder(
    payload: ReminderCreate, session: SessionDep, settings: SettingsDep, author: AuthorDep
) -> ReminderOut:
    """Queue a new reminder. It is shown at once and keeps its id when the provider reports it.
    Google Tasks lists refuse a due time and a priority (422)."""
    row = _refusals(
        lambda: service.create(
            session,
            settings,
            title=payload.title,
            notes=payload.notes,
            due_date=payload.due_date,
            due_time=payload.due_time,
            priority=payload.priority,
            list_id=payload.list_id,
            author=author,
        )
    )
    return _out(session, row)


@router.get("/{reminder_id}", response_model=ReminderOut)
def get_reminder(reminder_id: int, session: SessionDep) -> ReminderOut:
    return _out(session, get_or_404(session, Reminder, reminder_id))


@router.patch("/{reminder_id}", response_model=ReminderOut)
def update_reminder(
    reminder_id: int,
    payload: ReminderUpdate,
    session: SessionDep,
    settings: SettingsDep,
    author: AuthorDep,
) -> ReminderOut:
    """Queue a change to the fields sent. Clearing due_date also clears due_time."""
    row = get_or_404(session, Reminder, reminder_id)
    changes = payload.model_dump(exclude_unset=True)
    _refusals(lambda: service.update(session, settings, row, changes, author))
    return _out(session, row)


@router.post("/{reminder_id}/complete", response_model=ReminderOut)
def complete_reminder(
    reminder_id: int, session: SessionDep, settings: SettingsDep, author: AuthorDep
) -> ReminderOut:
    """Queue a completion. Completing a completed reminder queues nothing."""
    return _set_completed(session, settings, reminder_id, True, author)


@router.post("/{reminder_id}/uncomplete", response_model=ReminderOut)
def uncomplete_reminder(
    reminder_id: int, session: SessionDep, settings: SettingsDep, author: AuthorDep
) -> ReminderOut:
    """Queue un-completing. An open reminder queues nothing."""
    return _set_completed(session, settings, reminder_id, False, author)


# --------------------------------------------------------------------------- helpers


def display_order(item: ReminderOut) -> tuple:
    if not item.completed:
        return (
            0,
            item.due_date is None,
            item.due_date or 0,
            item.due_time is not None,
            item.due_time or 0,
            item.priority is None,
            item.priority or 0,
            item.title.casefold(),
            item.id,
        )
    stamp = item.completed_at.timestamp() if item.completed_at else 0
    return (1, -stamp, 0, 0, 0, 0, 0, item.title.casefold(), item.id)


def _set_completed(
    session: Session, settings, reminder_id: int, done: bool, author: str
) -> ReminderOut:
    row = get_or_404(session, Reminder, reminder_id)
    _refusals(lambda: service.set_completed(session, settings, row, done, author))
    return _out(session, row)


def _out(session: Session, row: Reminder) -> ReminderOut:
    session.refresh(row)
    return sync.render(session, [row])[0]
