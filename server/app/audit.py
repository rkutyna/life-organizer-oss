"""THE write path for organizer-owned records.

Every create, update and delete of an owned record goes through this module, so it lands in
`change_log` with its author. Routers never call `session.add`, `session.delete` or
`session.commit` on owned models themselves.

    from app import audit

    company = audit.create(session, Company(name="Acme"), author)
    audit.update(session, company, {"name": "Acme Corp", "target": True}, author)
    audit.delete(session, company, author)          # soft delete: sets deleted_at
    audit.revert(session, change_id, author)     # undo one change_log row (itself logged)

Each call commits on its own. To make several calls one logical write (one commit, one
`batch_id`), wrap them:

    with audit.transaction(session):
        audit.update(session, application, {"status": "interview"}, author)
        audit.create(session, StatusEvent(application_id=application.id, ...), author)

What gets logged (one `change_log` row each, values are JSON text):

- create: `field=None`, `old_value=None`, `new_value` = snapshot of every column.
- update: one row per field that actually changed, `old_value` -> `new_value`.
- delete: `field=None`, `old_value` = snapshot, `new_value=None`. The row is kept with
  `deleted_at` set (soft delete), so reverting a delete is always possible.

Reverting:

- an update sets that one field back. Refused (`RevertConflict`) if the field has changed
  again since; revert the newer change first.
- a create soft-deletes the record.
- a delete restores the record (logged as `op="create"`).
Every revert row points at the change it undid via `reverts_change_id`.

Revert hooks. A module whose records depend on each other (a derived field, a cascaded delete)
registers a hook for a table; `revert()` calls it after undoing a change to that table, inside
the same transaction, so whatever the hook writes lands in the revert's batch:

    def after_event_revert(session, change, obj, author):
        ...re-derive the parent's status through audit.update(...)...

    audit.register_revert_hook("jobs_application_status_events", after_event_revert)

`change` is the change_log row that was undone and `obj` the record as it stands after the
undo (loaded including soft-deleted rows). A hook may call `revert()` itself, e.g. to restore
children deleted in the same batch as their parent (`batch_changes(session, change.batch_id)`).
"""

import enum
import json
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from datetime import date, datetime, time
from decimal import Decimal
from typing import Any, Literal, TypeVar, get_args
from uuid import uuid4

from sqlalchemy import ForeignKey, Index, String, Text, inspect, select
from sqlalchemy.orm import Mapped, Session, mapped_column
from sqlalchemy.types import TypeDecorator

from app.db import Base, OwnedMixin
from app.timeutil import utcnow

# me: the person who owns this install (the web app and the native apps); claude: Claude over
# a local MCP server; claude_remote: Claude through the remote MCP connector; helper: the Mac
# helper; system: importers, seeds and background jobs. The author always comes from the
# credential that made the request (app.auth), never from a header.
Author = Literal["me", "claude", "claude_remote", "helper", "system"]
CLAUDE_AUTHORS = frozenset({"claude", "claude_remote"})
AUTHORS: tuple[str, ...] = get_args(Author)

Op = Literal["create", "update", "delete"]

# Columns audit manages itself; `update()` refuses to change them.
MANAGED_FIELDS = frozenset({"created_at", "created_by", "updated_at", "deleted_at"})

_BATCH_KEY = "audit_batch_id"

T = TypeVar("T", bound=OwnedMixin)


class ChangeLog(Base):
    """One row per field change (update) or per whole-record create/delete."""

    __tablename__ = "change_log"
    __table_args__ = (Index("ix_change_log_record", "table_name", "record_id"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    batch_id: Mapped[str] = mapped_column(String(32), index=True)
    ts: Mapped[datetime] = mapped_column(default=utcnow, index=True)
    author: Mapped[str] = mapped_column(String(16))
    op: Mapped[str] = mapped_column(String(8))
    table_name: Mapped[str] = mapped_column(String(64))
    record_id: Mapped[str] = mapped_column(String(64))
    field: Mapped[str | None] = mapped_column(String(64))
    old_value: Mapped[str | None] = mapped_column(Text)
    new_value: Mapped[str | None] = mapped_column(Text)
    reverts_change_id: Mapped[int | None] = mapped_column(ForeignKey("change_log.id"))


class AuditError(Exception):
    """Base class for audit errors."""


class RevertConflict(AuditError):
    """The change cannot be reverted as things stand (HTTP 409)."""


RevertHook = Callable[[Session, ChangeLog, OwnedMixin, str], None]

_REVERT_HOOKS: dict[str, list[RevertHook]] = {}


def register_revert_hook(table_name: str, hook: RevertHook) -> None:
    """Call `hook(session, change, obj, author)` after every revert of a change to `table_name`.

    Registering the same function twice for a table is a no-op (modules may be re-imported).
    """
    hooks = _REVERT_HOOKS.setdefault(table_name, [])
    if hook not in hooks:
        hooks.append(hook)


# --------------------------------------------------------------------------- public API


@contextmanager
def transaction(session: Session) -> Iterator[str]:
    """Group several audit calls into one commit and one batch_id. Yields the batch_id.

    Re-entrant: an inner `transaction()` joins the outer one.
    """
    if _BATCH_KEY in session.info:
        yield session.info[_BATCH_KEY]
        return
    batch_id = uuid4().hex
    session.info[_BATCH_KEY] = batch_id
    try:
        yield batch_id
        session.commit()
    except BaseException:
        session.rollback()
        raise
    finally:
        session.info.pop(_BATCH_KEY, None)


def create(session: Session, obj: T, author: str) -> T:
    """Insert a new owned record and log it. Returns the same object, with its id set."""
    _check(obj, author)
    obj.created_by = author
    with transaction(session) as batch_id:
        session.add(obj)
        session.flush()
        _log(session, batch_id, author, "create", obj, new_value=_dumps(_snapshot(obj)))
    return obj


def update(session: Session, obj: T, changes: Mapping[str, Any], author: str) -> T:
    """Apply `changes` (field -> new value) and log each field that actually changed.

    Values must already have the column's Python type (date, not "2026-10-18"); pass a
    validated pydantic model's `model_dump(exclude_unset=True)`. Unknown or managed fields
    raise `ValueError`. Returns the object.
    """
    return _update(session, obj, changes, author, reverts_change_id=None)


def delete(session: Session, obj: T, author: str) -> None:
    """Soft-delete an owned record (sets `deleted_at`) and log a snapshot of it."""
    _delete(session, obj, author, reverts_change_id=None)


def revert(session: Session, change_id: int, author: str) -> list[ChangeLog]:
    """Undo one `change_log` row. Returns the new change rows the revert wrote.

    Raises `LookupError` if the change does not exist, `RevertConflict` if it cannot be
    undone as things stand.
    """
    change = session.get(ChangeLog, change_id)
    if change is None:
        raise LookupError(f"change {change_id} not found")
    model = model_for_table(change.table_name)
    obj = _get_including_deleted(session, model, change.record_id)
    if obj is None:
        raise RevertConflict(f"{change.table_name} {change.record_id} no longer exists")

    with transaction(session) as batch_id:
        if change.op == "update":
            if obj.deleted_at is not None:
                raise RevertConflict("the record is deleted; restore it first")
            assert change.field is not None
            if _dumps(getattr(obj, change.field)) != change.new_value:
                raise RevertConflict(
                    f"'{change.field}' changed again after this change; "
                    "revert the newer change first"
                )
            column = _columns(obj)[change.field]
            old = _decode(column.type, change.old_value)
            _update(session, obj, {change.field: old}, author, reverts_change_id=change.id)
        elif change.op == "create":
            if obj.deleted_at is not None:
                raise RevertConflict("the record is already deleted")
            _delete(session, obj, author, reverts_change_id=change.id)
        elif change.op == "delete":
            if obj.deleted_at is None:
                raise RevertConflict("the record is not deleted")
            obj.deleted_at = None
            session.flush()
            _log(
                session,
                batch_id,
                author,
                "create",
                obj,
                new_value=_dumps(_snapshot(obj)),
                reverts_change_id=change.id,
            )
        else:  # pragma: no cover - op is constrained on write
            raise RevertConflict(f"unknown op {change.op!r}")

        for hook in _REVERT_HOOKS.get(change.table_name, ()):
            hook(session, change, obj, author)

    return batch_changes(session, batch_id)


def history(
    session: Session,
    table_name: str | None = None,
    record_id: str | int | None = None,
    limit: int = 200,
) -> list[ChangeLog]:
    """Change rows, newest first, optionally for one table or one record."""
    stmt = select(ChangeLog).order_by(ChangeLog.id.desc()).limit(limit)
    if table_name is not None:
        stmt = stmt.where(ChangeLog.table_name == table_name)
    if record_id is not None:
        stmt = stmt.where(ChangeLog.record_id == str(record_id))
    return list(session.scalars(stmt))


def batch_changes(session: Session, batch_id: str) -> list[ChangeLog]:
    """Every change row written in one batch, oldest first."""
    return list(
        session.scalars(
            select(ChangeLog).where(ChangeLog.batch_id == batch_id).order_by(ChangeLog.id)
        )
    )


def model_for_table(table_name: str) -> type[OwnedMixin]:
    """The owned model class mapped to `table_name`."""
    for mapper in Base.registry.mappers:
        cls = mapper.class_
        if issubclass(cls, OwnedMixin) and mapper.local_table.name == table_name:
            return cls
    raise LookupError(f"no owned model for table {table_name!r}")


def decode_value(text: str | None) -> Any:
    """A logged JSON value as plain JSON data (for API output)."""
    return None if text is None else json.loads(text)


# --------------------------------------------------------------------------- internals


def _update(
    session: Session,
    obj: T,
    changes: Mapping[str, Any],
    author: str,
    reverts_change_id: int | None,
) -> T:
    _check(obj, author)
    if obj.deleted_at is not None:
        raise ValueError("cannot update a deleted record")
    columns = _columns(obj)
    pk = {c.key for c in inspect(type(obj)).primary_key}
    for field in changes:
        if field not in columns:
            raise ValueError(f"{type(obj).__name__} has no column {field!r}")
        if field in pk or field in MANAGED_FIELDS:
            raise ValueError(f"{field!r} is managed by audit and cannot be updated")

    diffs = []
    for field, new in changes.items():
        old_json, new_json = _dumps(getattr(obj, field)), _dumps(new)
        if old_json != new_json:
            diffs.append((field, new, old_json, new_json))
    if not diffs:
        return obj

    with transaction(session) as batch_id:
        for field, new, _, _ in diffs:
            setattr(obj, field, new)
        session.flush()
        for field, _, old_json, new_json in diffs:
            _log(
                session,
                batch_id,
                author,
                "update",
                obj,
                field=field,
                old_value=old_json,
                new_value=new_json,
                reverts_change_id=reverts_change_id,
            )
    return obj


def _delete(session: Session, obj: OwnedMixin, author: str, reverts_change_id: int | None):
    _check(obj, author)
    if obj.deleted_at is not None:
        raise ValueError("record is already deleted")
    with transaction(session) as batch_id:
        snapshot = _dumps(_snapshot(obj))
        obj.deleted_at = utcnow()
        session.flush()
        _log(
            session,
            batch_id,
            author,
            "delete",
            obj,
            old_value=snapshot,
            reverts_change_id=reverts_change_id,
        )


def _log(
    session: Session,
    batch_id: str,
    author: str,
    op: Op,
    obj: OwnedMixin,
    *,
    field: str | None = None,
    old_value: str | None = None,
    new_value: str | None = None,
    reverts_change_id: int | None = None,
) -> None:
    session.add(
        ChangeLog(
            batch_id=batch_id,
            author=author,
            op=op,
            table_name=type(obj).__table__.name,
            record_id=_record_id(obj),
            field=field,
            old_value=old_value,
            new_value=new_value,
            reverts_change_id=reverts_change_id,
        )
    )
    session.flush()


def _check(obj: object, author: str) -> None:
    if not isinstance(obj, OwnedMixin):
        raise TypeError(f"{type(obj).__name__} is not an owned model (missing OwnedMixin)")
    if author not in AUTHORS:
        raise ValueError(f"unknown author {author!r}; expected one of {AUTHORS}")


def _columns(obj: OwnedMixin) -> dict[str, Any]:
    return {attr.key: attr.columns[0] for attr in inspect(type(obj)).column_attrs}


def _snapshot(obj: OwnedMixin) -> dict[str, Any]:
    return {key: _encode(getattr(obj, key)) for key in _columns(obj)}


def _record_id(obj: OwnedMixin) -> str:
    identity = inspect(obj).identity
    if identity is None:
        raise ValueError("object has no primary key yet")
    return ",".join(str(part) for part in identity)


def _get_including_deleted(session: Session, model: type[T], record_id: str) -> T | None:
    pk_columns = inspect(model).primary_key
    raw = record_id.split(",")
    key = tuple(
        int(part) if col.type.python_type is int else part
        for col, part in zip(pk_columns, raw, strict=True)
    )
    return session.get(
        model, key[0] if len(key) == 1 else key, execution_options={"include_deleted": True}
    )


def _encode(value: Any) -> Any:
    if isinstance(value, datetime | date | time):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, enum.Enum):
        return value.value
    return value


def _dumps(value: Any) -> str:
    return json.dumps(_encode(value), sort_keys=True, default=str)


def _decode(column_type: Any, text: str | None) -> Any:
    value = None if text is None else json.loads(text)
    if value is None:
        return None
    if isinstance(column_type, TypeDecorator):  # e.g. UTCDateTime -> DateTime
        column_type = column_type.impl_instance
    try:
        python_type = column_type.python_type
    except NotImplementedError:
        return value
    if issubclass(python_type, datetime):
        return datetime.fromisoformat(value)
    if issubclass(python_type, date):
        return date.fromisoformat(value)
    if issubclass(python_type, time):
        return time.fromisoformat(value)
    if issubclass(python_type, Decimal):
        return Decimal(value)
    if issubclass(python_type, enum.Enum):
        return python_type(value)
    return value
