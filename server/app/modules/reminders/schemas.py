"""Request and response bodies for /api/reminders (the web app and MCP side).

The helper's wire types (/api/ingest/reminders*) live in ingest.py.
"""

from datetime import date, datetime, time
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from app.freshness import SourceStatusOut

Source = Literal["apple", "google"]
Applier = Literal["helper", "server"]
OpKind = Literal["create", "update", "complete", "uncomplete"]
OpState = Literal["pending", "applied", "failed"]
# synced: the provider has every change. syncing: changes are queued or applied and not yet
# mirrored back. waiting_for_device: a helper op is over 2 minutes old and the Mac helper has not
# polled for ops in 2 minutes (the Mac is asleep or the helper is off). failed: an op failed;
# see `error`.
SyncState = Literal["synced", "syncing", "waiting_for_device", "failed"]
# A field a queued change touches. "due" is due_date and due_time together.
SyncField = Literal["title", "notes", "due", "priority", "completed", "list"]
# Op payload values in wire form: due_date "YYYY-MM-DD", due_time "HH:MM", priority 1-3.
OpFieldValue = str | int | None


class ReminderCreate(BaseModel):
    title: str = Field(min_length=1, max_length=500)
    list_id: str | None = Field(
        default=None, description="A list id from /api/reminders/lists; default: the default list"
    )
    notes: str = ""
    due_date: date | None = None
    due_time: time | None = Field(
        default=None, description="Needs due_date; minute precision. Not for Google Tasks lists."
    )
    priority: int | None = Field(
        default=None, ge=1, le=3, description="1 high, 2 medium, 3 low. Not for Google Tasks lists."
    )

    @field_validator("title")
    @classmethod
    def strip_title(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("title is empty")
        return value

    @model_validator(mode="after")
    def time_needs_date(self) -> "ReminderCreate":
        if self.due_time is not None and self.due_date is None:
            raise ValueError("due_time needs a due_date")
        return self


class ReminderUpdate(BaseModel):
    """PATCH body. Only the fields you send change; null clears due_date, due_time or priority.

    Clearing due_date also clears due_time. list_id moves the reminder to another list of the
    same account.
    """

    title: str | None = Field(default=None, min_length=1, max_length=500)
    notes: str | None = None
    due_date: date | None = None
    due_time: time | None = None
    priority: int | None = Field(default=None, ge=1, le=3)
    list_id: str | None = None

    @field_validator("title")
    @classmethod
    def title_not_blank(cls, value: str | None) -> str:
        if value is None or not value.strip():
            raise ValueError("title is empty")
        return value.strip()

    @field_validator("notes")
    @classmethod
    def notes_not_null(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("notes cannot be null; send an empty string")
        return value

    @field_validator("list_id")
    @classmethod
    def list_not_null(cls, value: str | None) -> str:
        if value is None or not value:
            raise ValueError("list_id cannot be cleared; send another list's id")
        return value


class ReminderListOut(BaseModel):
    id: str = Field(description="Pass it as list_id")
    title: str
    color: str | None
    source: Source = Field(description="apple (through the Mac helper) or google (Google Tasks)")
    account_id: int | None = Field(description="The connected Google account; null for Apple")
    account: str = Field(description="The account's name: 'iCloud', a Google address, ...")
    account_type: str | None
    writable: bool
    is_default: bool
    supports_time: bool = Field(description="False for Google Tasks: a due date but no time")
    supports_priority: bool = Field(description="False for Google Tasks: no priority")
    open_count: int = Field(
        description="Incomplete reminders in the list, pending changes included"
    )


class OpConflictOut(BaseModel):
    field: str
    kept: Literal["provider", "organizer"]
    provider_value: str | None = None
    organizer_value: str | None = None


class ReminderOpOut(BaseModel):
    id: int
    reminder_id: int
    kind: OpKind
    applier: Applier
    fields: dict[str, OpFieldValue] = Field(
        description="What the op sets, in wire form (due_date YYYY-MM-DD, due_time HH:MM)"
    )
    state: OpState
    error: str | None
    conflicts: list[OpConflictOut]
    created_at: datetime = Field(description="When it was queued")
    created_by: str
    applied_at: datetime | None


class ReminderSyncOut(BaseModel):
    state: SyncState
    pending_fields: list[SyncField] = Field(
        description="Fields whose shown value the provider does not have yet"
    )
    pending_ops: list[ReminderOpOut] = Field(description="Pending and failed ops, oldest first")
    waiting_since: datetime | None = Field(description="When the oldest pending op was queued")
    error: str | None = Field(description="The newest failed op's error")


class ReminderOut(BaseModel):
    """A reminder as the organizer shows it: the provider's state with queued changes applied."""

    id: int
    source: Source
    account_id: int | None
    external_id: str | None = Field(description="The provider's id, null until known")
    list_id: str | None
    list_title: str | None
    list_color: str | None
    title: str
    notes: str
    due_date: date | None
    due_time: time | None
    priority: int | None = Field(description="1 high, 2 medium, 3 low")
    completed: bool
    completed_at: datetime | None
    url: str | None
    modified_at: datetime | None = Field(description="Last modified at the provider")
    mirrored_at: datetime | None = Field(description="Last sync that carried it; null if never")
    in_provider: bool = Field(description="False until the provider has reported it")
    sync: ReminderSyncOut


class GoogleTasksAccountOut(BaseModel):
    account_id: int
    label: str
    freshness: SourceStatusOut


class ReminderStatusOut(BaseModel):
    helper: SourceStatusOut = Field(description="The Mac helper's Apple Reminders pushes")
    google: list[GoogleTasksAccountOut] = Field(
        description="Each Google account that granted Tasks, with its last poll"
    )
    last_ops_poll_at: datetime | None = Field(description="Last time the helper asked for ops")
    helper_polling: bool = Field(description="The helper asked for ops in the last 2 minutes")
    pending_ops: int
    failed_ops: int
    oldest_pending_at: datetime | None
    waiting_for_device: bool = Field(
        description="A helper op is over 2 minutes old and helper_polling is false"
    )


class ReminderSyncOutcomeOut(BaseModel):
    account_id: int
    ok: bool
    lists: int
    reminders: int
    error: str | None
