"""The reminder side of the sync: what the organizer shows, queueing ops, the helper's acks and
replacing the mirror with a provider's snapshot (docs/REMINDERS.md).

The provider (Apple Reminders or Google Tasks) is the source of truth. The organizer never edits
the mirror; it queues an op, the op's applier (the Mac helper or the server) applies it and
records the result, and the next sync mirrors it. Until then the op is *overlaid* on the
mirrored row: every reminder is shown as the provider last reported it, with its pending ops
(and applied ops not yet mirrored back) applied in order.

Values travel in wire form: due_date "YYYY-MM-DD", due_time "HH:MM" (minute precision),
priority 1-3. due_date and due_time are one field, "due", for conflicts.
"""

import logging
import secrets
from collections import defaultdict
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta
from typing import Any

from sqlalchemy import delete, or_, select
from sqlalchemy.orm import Session

from app import audit
from app.modules.reminders.models import (
    HelperContact,
    Reminder,
    ReminderList,
    ReminderOp,
    ServerInstance,
)
from app.modules.reminders.schemas import (
    OpConflictOut,
    ReminderListOut,
    ReminderOpOut,
    ReminderOut,
    ReminderSyncOut,
    SyncField,
    SyncState,
)
from app.timeutil import utcnow

log = logging.getLogger(__name__)

HELPER = "helper"
SYSTEM = "system"
OPS_POLL = "ops_poll"
# A helper op older than this, with no ops poll from the helper within it, is "waiting for the
# device".
WAITING_AFTER = timedelta(minutes=2)
# Applied ops stay in the overlay until a sync newer than their result; older ones are history.
APPLIED_OVERLAY_HORIZON = timedelta(days=1)
# A confirmed create that the next sync does not carry is kept this long (the snapshot may have
# been collected before the create), then treated as deleted at the provider.
CREATE_GRACE = timedelta(minutes=10)
# Reminders completed longer ago than this are not mirrored.
COMPLETED_DAYS = 30

VALUE_FIELDS = ("title", "notes", "due_date", "due_time", "priority", "list_id")
PROVIDER_NAMES = {"apple": "Apple Reminders", "google": "Google Tasks"}


# --------------------------------------------------------------------------- wire values


def wire_date(value: date | None) -> str | None:
    return value.isoformat() if value is not None else None


def wire_time(value: time | None) -> str | None:
    return value.strftime("%H:%M") if value is not None else None


def parse_date(value: Any) -> date | None:
    return date.fromisoformat(value) if value else None


def parse_time(value: Any) -> time | None:
    return time.fromisoformat(value).replace(second=0, microsecond=0) if value else None


def minute(value: time | None) -> time | None:
    return value.replace(second=0, microsecond=0) if value is not None else None


def sync_field(key: str) -> SyncField:
    if key in ("due_date", "due_time"):
        return "due"
    if key == "list_id":
        return "list"
    return key  # type: ignore[return-value]


def applier_for(source: str) -> str:
    return "server" if source == "google" else "helper"


@dataclass
class Values:
    """A reminder's user-facing fields, in wire form."""

    title: str
    notes: str
    due_date: str | None
    due_time: str | None
    priority: int | None
    completed: bool
    completed_at: datetime | None
    list_id: str | None

    def get(self, key: str) -> Any:
        return getattr(self, key)


def mirrored_values(row: Reminder) -> Values:
    return Values(
        title=row.title,
        notes=row.notes or "",
        due_date=wire_date(row.due_date),
        due_time=wire_time(row.due_time) if row.due_date else None,
        priority=row.priority,
        completed=row.completed,
        completed_at=row.completed_at,
        list_id=row.list_ext_id,
    )


# --------------------------------------------------------------------------- op targets


def target_matches(op: ReminderOp, row: Reminder | None) -> bool:
    """Whether `row` is still the reminder `op` was queued for.

    Ids are never reused, but an op also records its target's source, account and provider ids
    when it is queued, and is only retried, dispatched or shown on a row that still matches
    them. A provider id matches on either key (Apple's external id can arrive late or change
    while the local id stays). An op queued on a placeholder (no ids yet) matches only a row
    that has none either: confirming the create gives its other ops the new ids.
    """
    if row is None or op.reminder_id != row.id:
        return False
    if op.source is None:  # queued before targets were recorded
        return True
    if (op.source, op.account_id) != (row.source, row.account_id):
        return False
    if op.ext_id is None and op.local_id is None:
        return row.ext_id is None and row.local_id is None
    if op.ext_id is not None and op.ext_id == row.ext_id:
        return True
    return op.local_id is not None and op.local_id == row.local_id


STALE_TARGET = "the reminder this change was for is gone; it was not applied"


# --------------------------------------------------------------------------- the overlay


def overlays(op: ReminderOp, row: Reminder) -> bool:
    """Whether `op` still shapes what the organizer shows for `row`."""
    if op.state == "pending":
        return True
    if op.state == "applied" and op.applied_at is not None:
        return row.received_at is None or op.applied_at > row.received_at
    return False


def effective(row: Reminder, ops: Sequence[ReminderOp]) -> Values:
    """The mirrored row with its overlaying ops applied, oldest first.

    A field the applier reported it kept from the provider (a conflict the provider won) is not
    overlaid: the provider's value is the answer.
    """
    values = mirrored_values(row)
    for op in sorted(ops, key=lambda o: o.id):
        if not target_matches(op, row) or not overlays(op, row):
            continue
        kept = {c.get("field") for c in (op.conflicts or []) if c.get("kept") == "provider"}
        if op.kind == "complete":
            if "completed" not in kept and not values.completed:
                values = replace(values, completed=True, completed_at=op.created_at)
        elif op.kind == "uncomplete":
            if "completed" not in kept:
                values = replace(values, completed=False, completed_at=None)
        else:
            changes = {k: v for k, v in op.payload.items() if k in VALUE_FIELDS}
            changes = {k: v for k, v in changes.items() if sync_field(k) not in kept}
            values = replace(values, **changes)
    return values


def live_ops(session: Session, reminder_ids: Iterable[int] | None = None) -> list[ReminderOp]:
    """Ops that can still shape what is shown: pending, failed, and recently applied."""
    since = utcnow() - APPLIED_OVERLAY_HORIZON
    stmt = (
        select(ReminderOp)
        .where(or_(ReminderOp.state != "applied", ReminderOp.applied_at >= since))
        .order_by(ReminderOp.id)
    )
    if reminder_ids is not None:
        stmt = stmt.where(ReminderOp.reminder_id.in_(list(reminder_ids)))
    return list(session.scalars(stmt))


def ops_by_reminder(ops: Iterable[ReminderOp]) -> dict[int, list[ReminderOp]]:
    grouped: dict[int, list[ReminderOp]] = defaultdict(list)
    for op in ops:
        grouped[op.reminder_id].append(op)
    return grouped


# --------------------------------------------------------------------------- output


def last_ops_poll(session: Session) -> datetime | None:
    row = session.get(HelperContact, OPS_POLL)
    return row.at if row else None


def helper_polling(last_poll: datetime | None, now: datetime) -> bool:
    return last_poll is not None and now - last_poll <= WAITING_AFTER


def op_out(op: ReminderOp) -> ReminderOpOut:
    return ReminderOpOut(
        id=op.id,
        reminder_id=op.reminder_id,
        kind=op.kind,  # type: ignore[arg-type]
        applier=op.applier,  # type: ignore[arg-type]
        fields=dict(op.payload or {}),
        state=op.state,  # type: ignore[arg-type]
        error=op.error,
        conflicts=[OpConflictOut.model_validate(c) for c in (op.conflicts or [])],
        created_at=op.created_at,
        created_by=op.created_by,
        applied_at=op.applied_at,
    )


def sync_out(
    row: Reminder, ops: Sequence[ReminderOp], now: datetime, last_poll: datetime | None
) -> ReminderSyncOut:
    mine = sorted((op for op in ops if target_matches(op, row)), key=lambda o: o.id)
    pending = [op for op in mine if op.state == "pending"]
    failed = [op for op in mine if op.state == "failed"]
    in_flight = [op for op in mine if op.state == "applied" and overlays(op, row)]

    fields: list[SyncField] = []
    for op in pending + in_flight:
        if op.kind in ("complete", "uncomplete"):
            names: list[SyncField] = ["completed"]
        elif op.kind == "create":
            names = ["title", "notes", "due", "priority", "list"]
        else:
            names = [sync_field(key) for key in op.payload]
        for name in names:
            if name not in fields:
                fields.append(name)

    waiting_since = pending[0].created_at if pending else None
    state: SyncState
    if failed:
        state = "failed"
    elif pending:
        assert waiting_since is not None
        old_helper_op = any(
            op.applier == "helper" and now - op.created_at > WAITING_AFTER for op in pending
        )
        waiting = old_helper_op and not helper_polling(last_poll, now)
        state = "waiting_for_device" if waiting else "syncing"
    elif in_flight:
        state = "syncing"
    else:
        state = "synced"
    return ReminderSyncOut(
        state=state,
        pending_fields=fields,
        pending_ops=[op_out(op) for op in mine if op.state in ("pending", "failed")],
        waiting_since=waiting_since,
        error=failed[-1].error if failed else None,
    )


def reminder_out(
    row: Reminder,
    ops: Sequence[ReminderOp],
    lists: dict[str, ReminderList],
    now: datetime,
    last_poll: datetime | None,
) -> ReminderOut:
    values = effective(row, ops)
    lst = lists.get(values.list_id) if values.list_id else None
    return ReminderOut(
        id=row.id,
        source=row.source,  # type: ignore[arg-type]
        account_id=row.account_id,
        external_id=row.ext_id,
        list_id=values.list_id,
        list_title=lst.title if lst else None,
        list_color=lst.color if lst else None,
        title=values.title,
        notes=values.notes,
        due_date=parse_date(values.due_date),
        due_time=parse_time(values.due_time) if values.due_date else None,
        priority=values.priority,
        completed=values.completed,
        completed_at=values.completed_at,
        url=row.url,
        modified_at=row.ext_modified_at,
        mirrored_at=row.received_at,
        in_provider=row.received_at is not None,
        sync=sync_out(row, ops, now, last_poll),
    )


def lists_by_id(session: Session) -> dict[str, ReminderList]:
    return {lst.ext_id: lst for lst in session.scalars(select(ReminderList))}


def render(session: Session, rows: Sequence[Reminder]) -> list[ReminderOut]:
    """ReminderOut for each row, loading their ops and the lists once."""
    ops = live_ops(session, [row.id for row in rows])
    grouped = ops_by_reminder(ops)
    lists = lists_by_id(session)
    now = utcnow()
    last_poll = last_ops_poll(session)
    return [reminder_out(row, grouped.get(row.id, []), lists, now, last_poll) for row in rows]


def list_outs(session: Session, account_ids: set[int] | None = None) -> list[ReminderListOut]:
    """Every list, Apple first, then each Google account by id; each source in its own order.

    `account_ids`: the Google accounts currently enabled (others' lists are hidden).
    """
    rows = list(session.scalars(select(Reminder)))
    grouped = ops_by_reminder(live_ops(session))
    open_counts: dict[str | None, int] = defaultdict(int)
    for row in rows:
        values = effective(row, grouped.get(row.id, []))
        if not values.completed:
            open_counts[values.list_id] += 1
    stmt = select(ReminderList).order_by(
        ReminderList.source, ReminderList.account_id, ReminderList.position, ReminderList.id
    )
    return [
        ReminderListOut(
            id=lst.ext_id,
            title=lst.title,
            color=lst.color,
            source=lst.source,  # type: ignore[arg-type]
            account_id=lst.account_id,
            account=lst.account,
            account_type=lst.account_type,
            writable=lst.writable,
            is_default=lst.is_default,
            supports_time=lst.source != "google",
            supports_priority=lst.source != "google",
            open_count=open_counts.get(lst.ext_id, 0),
        )
        for lst in session.scalars(stmt)
        if account_ids is None or lst.account_id is None or lst.account_id in account_ids
    ]


# --------------------------------------------------------------------------- queueing


def queue(
    session: Session,
    row: Reminder,
    kind: str,
    payload: dict[str, Any],
    base: dict[str, Any],
    author: str,
) -> ReminderOp:
    """Record one intent through app.audit (commits unless inside audit.transaction)."""
    op = ReminderOp(
        reminder_id=row.id,
        source=row.source,
        account_id=row.account_id,
        ext_id=row.ext_id,
        local_id=row.local_id,
        kind=kind,
        applier=applier_for(row.source),
        payload=payload,
        base=base,
        state="pending",
        attempts=0,
        conflicts=None,
    )
    return audit.create(session, op, author)


def create_failed(ops: Sequence[ReminderOp], row: Reminder) -> bool:
    """A placeholder whose create op failed: the provider never got it."""
    return row.received_at is None and any(
        op.kind == "create" and op.state == "failed" and target_matches(op, row) for op in ops
    )


# --------------------------------------------------------------------------- the helper


def instance_id(session: Session) -> str:
    """This database's identity: a random id made once and kept. The helper keys what it
    remembers about ops by (instance, op id), so a recreated database, whose op ids start
    again at 1, is never taken for the one the helper knew."""
    row = session.scalars(select(ServerInstance).order_by(ServerInstance.id)).first()
    if row is None:
        row = ServerInstance(instance_id=secrets.token_hex(16), created_at=utcnow())
        session.add(row)
        session.commit()
    return row.instance_id


def record_ops_poll(session: Session, at: datetime) -> None:
    row = session.get(HelperContact, OPS_POLL)
    if row is None:
        session.add(HelperContact(kind=OPS_POLL, at=at))
    else:
        row.at = at
    session.commit()


def pending_for(
    session: Session, applier: str, limit: int = 200
) -> list[tuple[ReminderOp, Reminder | None]]:
    """Pending ops of one applier in queue order, each with its reminder row (None if gone).
    The caller fails an op whose row is not its target any more (`target_matches`)."""
    ops = list(
        session.scalars(
            select(ReminderOp)
            .where(ReminderOp.state == "pending", ReminderOp.applier == applier)
            .order_by(ReminderOp.id)
            .limit(limit)
        )
    )
    rows = {
        row.id: row
        for row in session.scalars(
            select(Reminder).where(Reminder.id.in_([op.reminder_id for op in ops]))
        )
    }
    return [(op, rows.get(op.reminder_id)) for op in ops]


def log_conflicts(op: ReminderOp, conflicts: Sequence[dict[str, Any]]) -> None:
    for c in conflicts:
        log.warning(
            "reminders: op %s (%s) field %s changed on both sides; %s wins",
            op.id,
            op.kind,
            c.get("field"),
            c.get("kept"),
        )


def apply_ack(
    session: Session,
    op: ReminderOp,
    *,
    ok: bool,
    external_id: str | None,
    local_id: str | None,
    error: str | None,
    conflicts: list[dict[str, Any]],
    author: str = HELPER,
) -> ReminderOp:
    """Record the applier's result for one op. Acking an op that is no longer pending changes
    nothing (the helper may retry an ack whose answer it lost)."""
    if op.state != "pending":
        return op
    now = utcnow()
    with audit.transaction(session):
        changes: dict[str, Any]
        if ok:
            changes = {"state": "applied", "applied_at": now, "error": None}
            if conflicts:
                changes["conflicts"] = conflicts
                log_conflicts(op, conflicts)
            if op.kind == "create" and (external_id or local_id):
                refused = foreign_twin(session, op, external_id, local_id)
                if refused is not None:
                    ok = False
                    error = refused
                else:
                    changes["ext_id"] = external_id
                    changes["local_id"] = local_id
                    confirm_create(session, op, external_id, local_id, author)
        if not ok:
            changes = {
                "state": "failed",
                "error": (error or "the applier reported a failure")[:2000],
            }
            log.warning("reminders: op %s (%s) failed: %s", op.id, op.kind, changes["error"])
        audit.update(session, op, changes, author)
    return op


def _twins(
    session: Session, op: ReminderOp, external_id: str | None, local_id: str | None
) -> list[Reminder]:
    """Other rows of the placeholder's scope that carry one of the create's new ids."""
    placeholder = session.get(Reminder, op.reminder_id)
    if placeholder is None:
        return []
    clauses = []
    if external_id:
        clauses.append(Reminder.ext_id == external_id)
    if local_id:
        clauses.append(Reminder.local_id == local_id)
    if not clauses:
        return []
    return [
        r
        for r in session.scalars(
            select(Reminder).where(
                Reminder.source == placeholder.source,
                _same_account(Reminder, placeholder.account_id),
                or_(*clauses),
            )
        )
        if r.id != placeholder.id
    ]


def foreign_twin(
    session: Session, op: ReminderOp, external_id: str | None, local_id: str | None
) -> str | None:
    """Why a create's reported ids cannot be its new reminder, or None.

    A sync may already carry the new reminder (collected between the create and its result);
    such a row first arrived after the op was queued. A row that was there before, or another
    create's placeholder, is an unrelated reminder: folding it in would take it over.
    """
    for twin in _twins(session, op, external_id, local_id):
        if twin.first_received_at is None or twin.first_received_at < op.created_at:
            log.warning(
                "reminders: op %s's result names reminder %s, which predates the op",
                op.id,
                twin.id,
            )
            return (
                "the applier reported an existing reminder as this new one; "
                "retry to create it again"
            )
    return None


def confirm_create(
    session: Session,
    op: ReminderOp,
    external_id: str | None,
    local_id: str | None,
    author: str,
) -> None:
    """Give the placeholder its provider ids. If a sync already brought the new reminder in as a
    row of its own (collected between the create and the ack), fold that row into the
    placeholder so the organizer id the UI holds stays the reminder's id (`foreign_twin` has
    checked that each such row is the new reminder). The placeholder's other ops, queued
    before it had ids, now name the new reminder."""
    placeholder = session.get(Reminder, op.reminder_id)
    if placeholder is None:
        return
    for twin in _twins(session, op, external_id, local_id):
        copy_mirrored(twin, placeholder)
        for other in session.scalars(select(ReminderOp).where(ReminderOp.reminder_id == twin.id)):
            audit.update(session, other, {"reminder_id": placeholder.id}, author)
        session.delete(twin)
    placeholder.ext_id = external_id or placeholder.ext_id
    placeholder.local_id = local_id or placeholder.local_id
    for other in session.scalars(
        select(ReminderOp).where(
            ReminderOp.reminder_id == placeholder.id,
            ReminderOp.id != op.id,
            ReminderOp.source.is_not(None),
            ReminderOp.ext_id.is_(None),
            ReminderOp.local_id.is_(None),
        )
    ):
        audit.update(
            session,
            other,
            {"ext_id": placeholder.ext_id, "local_id": placeholder.local_id},
            author,
        )
    session.flush()


def retarget(session: Session, row: Reminder, old_ext_id: str | None, author: str) -> None:
    """The provider gave `row` a new external id (a Google task moved to another list): its
    live ops that named the old one follow it."""
    if row.ext_id == old_ext_id or old_ext_id is None:
        return
    for other in session.scalars(
        select(ReminderOp).where(
            ReminderOp.reminder_id == row.id,
            ReminderOp.ext_id == old_ext_id,
            ReminderOp.state != "applied",
        )
    ):
        audit.update(session, other, {"ext_id": row.ext_id}, author)


def fail_stale(
    session: Session, pairs: Sequence[tuple[ReminderOp, Reminder | None]], author: str
) -> list[tuple[ReminderOp, Reminder]]:
    """Fail each op whose row is gone or is no longer its target; return the others."""
    kept: list[tuple[ReminderOp, Reminder]] = []
    for op, row in pairs:
        if row is not None and target_matches(op, row):
            kept.append((op, row))
            continue
        log.warning("reminders: op %s (%s) no longer has its reminder", op.id, op.kind)
        audit.update(session, op, {"state": "failed", "error": STALE_TARGET}, author)
    return kept


MIRRORED_COLUMNS = (
    "ext_id",
    "local_id",
    "list_ext_id",
    "title",
    "notes",
    "due_date",
    "due_time",
    "priority",
    "completed",
    "completed_at",
    "url",
    "ext_created_at",
    "ext_modified_at",
    "received_at",
    "first_received_at",
)


def copy_mirrored(source: Reminder, target: Reminder) -> None:
    for column in MIRRORED_COLUMNS:
        setattr(target, column, getattr(source, column))


# --------------------------------------------------------------------------- snapshots


@dataclass(frozen=True)
class Scope:
    """Which rows one snapshot covers: the helper's Apple rows, or one Google account's."""

    source: str
    account_id: int | None = None

    def lists(self):
        return select(ReminderList).where(
            ReminderList.source == self.source, _same_account(ReminderList, self.account_id)
        )

    def reminders(self):
        return select(Reminder).where(
            Reminder.source == self.source, _same_account(Reminder, self.account_id)
        )


def _same_account(model, account_id: int | None):
    if account_id is None:
        return model.account_id.is_(None)
    return model.account_id == account_id


@dataclass
class IncomingList:
    id: str
    title: str
    color: str | None
    account: str
    account_type: str | None
    writable: bool


@dataclass
class IncomingReminder:
    external_id: str | None
    local_id: str | None
    list_id: str
    title: str
    notes: str
    due_date: date | None
    due_time: time | None
    priority: int | None
    completed: bool
    completed_at: datetime | None
    url: str | None
    created_at: datetime | None
    modified_at: datetime | None


@dataclass
class SnapshotCounts:
    lists: int
    reminders: int
    removed: int


def replace_snapshot(
    session: Session,
    scope: Scope,
    lists: Sequence[IncomingList],
    reminders: Sequence[IncomingReminder],
    default_list_id: str | None,
    now: datetime,
) -> SnapshotCounts:
    """Replace one scope's mirror with a snapshot, inside the caller's audit.transaction.

    `now` is when the snapshot's collection started (the poll's start for Google). The scope's
    lists are replaced outright. A reminder whose list is not among the snapshot's own lists is
    dropped (a snapshot cannot file reminders under another source's list). Reminders are
    matched to existing rows by external id, then by local id, so a reminder keeps its
    organizer id across syncs (and across an external id that arrives late). Rows the snapshot
    does not carry are gone at the provider and are deleted, with their pending ops failed; a
    placeholder survives while its create is pending or failed, and for CREATE_GRACE after it
    was applied. A row written after `now` (the server applied a change while a poll was
    reading) is newer than the snapshot: it is neither overwritten nor deleted. Other scopes
    are untouched.
    """
    taken = {
        lst.ext_id: lst
        for lst in session.scalars(
            select(ReminderList).where(ReminderList.ext_id.in_([incoming.id for incoming in lists]))
        )
    }
    session.execute(
        delete(ReminderList).where(
            ReminderList.source == scope.source,
            _same_account(ReminderList, scope.account_id),
        )
    )
    session.flush()
    added = 0
    own_lists: set[str] = set()
    for position, lst in enumerate(lists):
        other = taken.get(lst.id)
        if other is not None and (other.source, other.account_id) != (
            scope.source,
            scope.account_id,
        ):
            log.warning("reminders: list id %r is already used by another source", lst.id)
            continue
        own_lists.add(lst.id)
        session.add(
            ReminderList(
                source=scope.source,
                account_id=scope.account_id,
                ext_id=lst.id,
                title=lst.title,
                color=lst.color,
                account=lst.account,
                account_type=lst.account_type,
                writable=lst.writable,
                is_default=lst.id == default_list_id,
                position=position,
                received_at=now,
            )
        )
        added += 1

    rows = list(session.scalars(scope.reminders()))
    by_ext = {r.ext_id: r for r in rows if r.ext_id}
    by_local = {r.local_id: r for r in rows if r.local_id}
    seen: set[int] = set()
    kept = [item for item in reminders if item.list_id in own_lists]
    if len(kept) != len(reminders):
        log.warning(
            "reminders: dropped %d %s reminders whose list is not in the snapshot",
            len(reminders) - len(kept),
            scope.source,
        )
    for item in kept:
        row = by_ext.get(item.external_id) if item.external_id else None
        if (row is None or id(row) in seen) and item.local_id:
            row = by_local.get(item.local_id)
        if row is None or id(row) in seen:
            row = Reminder(source=scope.source, account_id=scope.account_id)
            session.add(row)
        seen.add(id(row))
        if _newer_than(row, now):
            continue
        fill(row, item, now)

    removed = 0
    gone = [row for row in rows if id(row) not in seen]
    if gone:
        ops = ops_by_reminder(live_ops(session, [row.id for row in gone]))
        provider = PROVIDER_NAMES.get(scope.source, scope.source)
        for row in gone:
            mine = ops.get(row.id, [])
            if row.received_at is None and _placeholder_survives(mine, now):
                continue
            if _newer_than(row, now) or any(
                op.kind == "create" and op.created_at >= now for op in mine
            ):
                continue
            for op in mine:
                if op.state == "pending":
                    audit.update(
                        session,
                        op,
                        {"state": "failed", "error": f"the reminder is gone from {provider}"},
                        HELPER if scope.source == "apple" else SYSTEM,
                    )
            session.delete(row)
            removed += 1
    session.flush()
    return SnapshotCounts(lists=added, reminders=len(kept), removed=removed)


def _newer_than(row: Reminder, now: datetime) -> bool:
    return row.received_at is not None and row.received_at > now


def fill(row: Reminder, item: IncomingReminder, now: datetime) -> None:
    """Copy one reported reminder onto its mirrored row."""
    row.ext_id = item.external_id
    row.local_id = item.local_id
    row.list_ext_id = item.list_id
    row.title = item.title
    row.notes = item.notes
    row.due_date = item.due_date
    row.due_time = minute(item.due_time) if item.due_date else None
    row.priority = item.priority
    row.completed = item.completed
    row.completed_at = item.completed_at if item.completed else None
    row.url = item.url
    row.ext_created_at = item.created_at
    row.ext_modified_at = item.modified_at
    row.received_at = now
    if row.first_received_at is None:
        row.first_received_at = now


def _placeholder_survives(ops: Sequence[ReminderOp], now: datetime) -> bool:
    for op in ops:
        if op.kind != "create":
            continue
        if op.state in ("pending", "failed"):
            return True
        if op.state == "applied" and op.applied_at and now - op.applied_at < CREATE_GRACE:
            return True
    return False


def cancel(session: Session, op: ReminderOp, author: str) -> None:
    """Withdraw a pending or failed op (soft delete through app.audit). Withdrawing the create
    of a reminder the provider never reported also removes its placeholder and every other op
    queued on it."""
    with audit.transaction(session):
        audit.delete(session, op, author)
        if op.kind != "create":
            return
        row = session.get(Reminder, op.reminder_id)
        if row is None or row.received_at is not None or row.ext_id is not None:
            return
        for other in session.scalars(
            select(ReminderOp).where(
                ReminderOp.reminder_id == row.id, ReminderOp.state != "applied"
            )
        ):
            audit.delete(session, other, author)
        session.delete(row)
        session.flush()
