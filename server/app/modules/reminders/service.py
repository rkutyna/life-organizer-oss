"""Changing reminders from code: the router's writes, and other modules' own reminders.

Each function queues at most one op through app.audit; a change that changes nothing queues
nothing. An op on a Google Tasks reminder is applied by the server right away (`dispatch`), so
the reminder that comes back is usually already synced. An op on an Apple reminder waits for
the Mac helper.

Refusals raise `ReminderRefused` with an HTTP status and a message that is safe to show:
- a list that is unknown or read-only;
- a due time or a priority on a Google Tasks list (Google Tasks keeps a due date only, and has
  no priority): refused, not stripped, so the caller knows;
- a move to a list of another account;
- any change to a reminder whose create failed (retry or withdraw that first).
"""

from datetime import date, time
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.config import Settings
from app.modules.reminders import google_tasks, sync
from app.modules.reminders.models import Reminder, ReminderList, ReminderOp

NO_TIME = "Google Tasks keeps a due date but no time; send the date without due_time"
NO_PRIORITY = "Google Tasks has no priority; leave priority empty for this list"


class ReminderRefused(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def default_list(session: Session, account_ids: set[int] | None = None) -> ReminderList | None:
    """Apple's default list, else the first Google account's default."""
    found = [
        lst
        for lst in session.scalars(
            select(ReminderList)
            .where(ReminderList.is_default)
            .order_by(ReminderList.source, ReminderList.account_id)
        )
        if account_ids is None or lst.account_id is None or lst.account_id in account_ids
    ]
    return found[0] if found else None


def writable_list(session: Session, list_id: str) -> ReminderList:
    found = session.scalars(select(ReminderList).where(ReminderList.ext_id == list_id)).first()
    if found is None:
        raise ReminderRefused(
            422, f"unknown reminders list {list_id!r}; /api/reminders/lists has them"
        )
    if not found.writable:
        raise ReminderRefused(422, f"the list {found.title!r} is read-only")
    return found


def check_editable(session: Session, row: Reminder) -> list[ReminderOp]:
    """The reminder's live ops, or a refusal if its create failed."""
    ops = sync.live_ops(session, [row.id])
    if sync.create_failed(ops, row):
        raise ReminderRefused(
            409, "the provider never got this reminder (its create failed); retry or withdraw it"
        )
    return ops


def dispatch(session: Session, settings: Settings, row: Reminder) -> None:
    """Apply the reminder's pending server ops now (Google). Apple ops wait for the helper."""
    if row.source == "google":
        google_tasks.apply_pending(session, settings, {row.id})


def create(
    session: Session,
    settings: Settings,
    *,
    title: str,
    author: str,
    notes: str = "",
    due_date: date | None = None,
    due_time: time | None = None,
    priority: int | None = None,
    list_id: str | None = None,
) -> Reminder:
    """Queue a new reminder (in `list_id`, else the default list). Its placeholder row is shown
    at once and keeps its id when the provider reports it."""
    if list_id is not None:
        lst = writable_list(session, list_id)
    else:
        found = default_list(session)
        if found is None:
            raise ReminderRefused(
                422, "no reminders list yet: connect Google Tasks or the Mac helper first"
            )
        lst = found
    if lst.source == "google":
        if due_time is not None:
            raise ReminderRefused(422, NO_TIME)
        if priority is not None:
            raise ReminderRefused(422, NO_PRIORITY)
    fields = {
        "title": title,
        "notes": notes,
        "due_date": sync.wire_date(due_date),
        "due_time": sync.wire_time(due_time) if due_date else None,
        "priority": priority,
        "list_id": lst.ext_id,
    }
    with audit.transaction(session):
        row = Reminder(
            source=lst.source,
            account_id=lst.account_id,
            ext_id=None,
            local_id=None,
            list_ext_id=lst.ext_id,
            title=title,
            notes=notes,
            due_date=due_date,
            due_time=sync.minute(due_time) if due_date else None,
            priority=priority,
            completed=False,
            received_at=None,
        )
        session.add(row)
        session.flush()
        sync.queue(session, row, "create", fields, {}, author)
    dispatch(session, settings, row)
    return row


def update(
    session: Session,
    settings: Settings,
    row: Reminder,
    changes: dict[str, Any],
    author: str,
) -> bool:
    """Queue a change to the fields given (a ReminderUpdate's `exclude_unset` dump). Clearing
    due_date also clears due_time. False when nothing changes."""
    ops = check_editable(session, row)
    current = sync.effective(row, ops)
    google = row.source == "google"

    wanted: dict[str, Any] = {}
    for key in ("title", "notes"):
        if key in changes:
            wanted[key] = changes[key]
    if "priority" in changes:
        if google and changes["priority"] is not None:
            raise ReminderRefused(422, NO_PRIORITY)
        wanted["priority"] = changes["priority"]
    if "list_id" in changes:
        target = writable_list(session, changes["list_id"])
        if (target.source, target.account_id) != (row.source, row.account_id):
            raise ReminderRefused(
                422,
                "a reminder can only move to another list of the same account; "
                "create it in the other list instead",
            )
        wanted["list_id"] = target.ext_id
    if "due_date" in changes or "due_time" in changes:
        if google and changes.get("due_time") is not None:
            raise ReminderRefused(422, NO_TIME)
        due_date = (
            changes["due_date"] if "due_date" in changes else sync.parse_date(current.due_date)
        )
        due_time = (
            changes["due_time"] if "due_time" in changes else sync.parse_time(current.due_time)
        )
        if due_date is None and due_time is not None:
            if "due_date" not in changes:
                raise ReminderRefused(422, "due_time needs a due_date")
            due_time = None
        wanted["due_date"] = sync.wire_date(due_date)
        wanted["due_time"] = sync.wire_time(due_time) if due_date else None

    fields = {key: value for key, value in wanted.items() if current.get(key) != value}
    if "due_date" in fields or "due_time" in fields:  # due travels as one field
        fields["due_date"], fields["due_time"] = wanted["due_date"], wanted["due_time"]
    if not fields:
        return False
    base = {key: current.get(key) for key in fields}
    sync.queue(session, row, "update", fields, base, author)
    dispatch(session, settings, row)
    return True


def is_completed(session: Session, row: Reminder) -> bool:
    """Completed as the organizer shows it: the provider's state with queued changes applied."""
    return bool(sync.effective(row, sync.live_ops(session, [row.id])).completed)


def set_completed(
    session: Session, settings: Settings, row: Reminder, done: bool, author: str
) -> bool:
    """Queue completing or un-completing. False when it already is."""
    ops = check_editable(session, row)
    if sync.effective(row, ops).completed == done:
        return False
    kind = "complete" if done else "uncomplete"
    sync.queue(session, row, kind, {}, {"completed": not done}, author)
    dispatch(session, settings, row)
    return True


def retry(session: Session, settings: Settings, op: ReminderOp, author: str) -> ReminderOp:
    """Queue a failed op again (and apply it now when the server is its applier). Refused when
    its reminder is gone or the row is no longer the reminder it was queued for."""
    row = session.get(Reminder, op.reminder_id)
    if not sync.target_matches(op, row):
        raise ReminderRefused(409, f"{sync.STALE_TARGET}; withdraw it")
    audit.update(session, op, {"state": "pending", "error": None, "attempts": 0}, author)
    assert row is not None
    dispatch(session, settings, row)
    return op
