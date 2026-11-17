"""Reminders tables: lists and reminders mirrored from Apple Reminders and Google Tasks, and the
owned op queue that carries the organizer's changes back to them (docs/REMINDERS.md).

Mirrored, replaced by each sync (no OwnedMixin, no audit trail):
- `ReminderList`: every list the providers report.
- `Reminder`: incomplete reminders plus those completed in the last 30 days. The provider is the
  source of truth. One exception to "only a sync writes here": a reminder created in the
  organizer gets a placeholder row when its create op is queued (`received_at` is null), so it
  has its organizer id at once. The sync that carries it fills it in.

`source` says where a row comes from:
- "apple": Apple Reminders, pushed by the Mac helper. `account_id` is null.
- "google": Google Tasks, polled by the server. `account_id` is the Google account; the foreign
  key cascades, so removing the account removes its rows.

Owned, written only through `app.audit`:
- `ReminderOp`: one organizer-side intent (create, update, complete, uncomplete). Its `applier`
  is "helper" for Apple rows (the Mac polls the queue, applies with EventKit and acks) or
  "server" for Google rows (the server applies it itself through the Tasks API). Its state moves
  pending -> applied | failed.

Bookkeeping:
- `HelperContact`: when the helper last polled for ops, for the "waiting for the Mac" state.
- `ServerInstance`: one row, made once, whose random id tells the helper this database from an
  earlier or later one (op ids restart when a database is recreated).

Ids are never reused (`sqlite_autoincrement`): an op names its reminder by id, and the helper
names ops by id, so a deleted row's id must not come back for an unrelated one.
"""

from datetime import date, datetime, time
from typing import Any

from sqlalchemy import JSON, Boolean, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base, OwnedMixin

SOURCES = ("apple", "google")
APPLIERS = ("helper", "server")


class ReminderList(Base):
    __tablename__ = "reminders_lists"

    id: Mapped[int] = mapped_column(primary_key=True)
    source: Mapped[str] = mapped_column(String(16), default="apple", index=True)
    account_id: Mapped[int | None] = mapped_column(
        ForeignKey("core_provider_accounts.id", ondelete="CASCADE"), index=True
    )
    # The API's list id: EKCalendar.calendarIdentifier (Apple) or the Google task list id.
    ext_id: Mapped[str] = mapped_column(String(1000), unique=True)
    title: Mapped[str] = mapped_column(String(500))
    color: Mapped[str | None] = mapped_column(String(7))
    # The account's name: the Mac's account title ("iCloud"), or the Google address.
    account: Mapped[str] = mapped_column(String(500), default="")
    account_type: Mapped[str | None] = mapped_column(String(32))
    writable: Mapped[bool] = mapped_column(Boolean, default=True)
    # The list new reminders go into when none is chosen (Apple's default, else the first
    # Google list).
    is_default: Mapped[bool] = mapped_column(Boolean, default=False)
    # Order within its source, as the provider sent it.
    position: Mapped[int] = mapped_column(default=0)
    received_at: Mapped[datetime]


class Reminder(Base):
    __tablename__ = "reminders_items"
    __table_args__ = {"sqlite_autoincrement": True}

    id: Mapped[int] = mapped_column(primary_key=True)
    source: Mapped[str] = mapped_column(String(16), default="apple", index=True)
    account_id: Mapped[int | None] = mapped_column(
        ForeignKey("core_provider_accounts.id", ondelete="CASCADE"), index=True
    )
    # Apple: calendarItemExternalIdentifier, stable across devices. Google: the task id.
    # Null until the provider reports it (a placeholder, or an account that has not assigned one).
    ext_id: Mapped[str | None] = mapped_column(String(1000), index=True)
    # Apple: calendarItemIdentifier, device-local; the fallback key when ext_id is missing or
    # changes. Null for Google.
    local_id: Mapped[str | None] = mapped_column(String(1000), index=True)
    list_ext_id: Mapped[str | None] = mapped_column(String(1000), index=True)
    title: Mapped[str] = mapped_column(Text, default="")
    notes: Mapped[str] = mapped_column(Text, default="")
    # Wall-clock date and time (minute precision) in the configured zone; due_time needs
    # due_date. Google Tasks keeps a date only, so its rows never have a time.
    due_date: Mapped[date | None] = mapped_column(index=True)
    due_time: Mapped[time | None]
    # 1 high, 2 medium, 3 low (EventKit 1-4, 5, 6-9); null for none. Always null for Google.
    priority: Mapped[int | None]
    completed: Mapped[bool] = mapped_column(Boolean, default=False, index=True)
    completed_at: Mapped[datetime | None]
    url: Mapped[str | None] = mapped_column(Text)
    ext_created_at: Mapped[datetime | None]
    # Last modified at the provider: the timestamp the conflict rule compares.
    ext_modified_at: Mapped[datetime | None]
    # When a sync last carried this row. Null: a placeholder the provider has not reported.
    received_at: Mapped[datetime | None]
    # When a sync first carried this provider reminder (never updated). A create's ack may fold
    # a row into its placeholder only if the row first arrived after the op was queued.
    first_received_at: Mapped[datetime | None]


class ReminderOp(OwnedMixin, Base):
    """One queued change. `created_at` is when it was queued (the conflict rule's timestamp)
    and `created_by` who asked (me from the web app, claude from MCP)."""

    __tablename__ = "reminders_ops"
    __table_args__ = {"sqlite_autoincrement": True}

    id: Mapped[int] = mapped_column(primary_key=True)
    reminder_id: Mapped[int] = mapped_column(index=True)
    # The target reminder as it was when the op was queued: its source and account, and (in
    # ext_id/local_id below) its provider ids. An op is retried or dispatched only while the
    # row `reminder_id` still is that reminder (sync.target_matches). Null source: queued
    # before targets were recorded, never checked.
    source: Mapped[str | None] = mapped_column(String(16))
    account_id: Mapped[int | None]
    # create | update | complete | uncomplete
    kind: Mapped[str] = mapped_column(String(16))
    # helper (Apple Reminders, applied by the Mac) | server (Google Tasks, applied here)
    applier: Mapped[str] = mapped_column(String(16), default="helper", index=True)
    # The fields to set (create, update), in wire form: title, notes, due_date ("YYYY-MM-DD"),
    # due_time ("HH:MM"), priority (1-3), list_id. due_date and due_time always travel together.
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    # What the organizer believed the provider held for those fields when the op was queued
    # (the mirror with earlier pending ops applied). The applier compares against it.
    base: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    # pending | applied | failed
    state: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    # Server ops: how many times applying was tried (transient errors are retried).
    attempts: Mapped[int] = mapped_column(default=0)
    # The target's provider ids: copied from the row when queued, and for a create (queued on
    # a placeholder that has none) the new reminder's ids from the ack or the API's answer.
    ext_id: Mapped[str | None] = mapped_column(String(1000))
    local_id: Mapped[str | None] = mapped_column(String(1000))
    applied_at: Mapped[datetime | None]
    error: Mapped[str | None] = mapped_column(Text)
    # [{field, kept: "provider"|"organizer", provider_value, organizer_value}].
    conflicts: Mapped[list[dict[str, Any]] | None] = mapped_column(JSON)


class HelperContact(Base):
    """Last time the helper did something, by kind ("ops_poll"). Bookkeeping, not owned."""

    __tablename__ = "reminders_helper_contact"

    kind: Mapped[str] = mapped_column(String(32), primary_key=True)
    at: Mapped[datetime]


class ServerInstance(Base):
    """This database's identity, made once (sync.instance_id). Bookkeeping, not owned."""

    __tablename__ = "reminders_instance"

    id: Mapped[int] = mapped_column(primary_key=True)
    instance_id: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime]


from app.modules.reminders import revert_hooks  # noqa: E402, F401
