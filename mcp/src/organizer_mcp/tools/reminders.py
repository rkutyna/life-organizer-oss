"""Reminders: the owner's lists from Apple Reminders (through the Mac helper) and Google Tasks,
read with queued changes applied, and changed through the organizer's op queue."""

import datetime as dt
from typing import Any, Literal

from mcp.types import ToolAnnotations

from organizer_mcp.client import OrganizerClient, OrganizerError
from organizer_mcp.core import app, client

TOOLSET = "reminders"
SCOPE = "api"
TOOLS = frozenset(
    {"reminders", "reminder_lists", "add_reminder", "update_reminder", "complete_reminder"}
)
WRITES = frozenset({"add_reminder", "update_reminder", "complete_reminder"})

READ_ONLY = ToolAnnotations(readOnlyHint=True)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False)

# 1 high, 2 medium, 3 low (the API's vocabulary).
Priority = Literal[1, 2, 3]
ClearReminderField = Literal["due_date", "due_time", "priority"]


def _resolve_list(c: OrganizerClient, name_or_id: str) -> str:
    """A list id from its id or its name (exact id first, then a name ignoring case)."""
    key = name_or_id.strip()
    if not key:
        raise OrganizerError("list is empty")
    rows = c.get("/api/reminders/lists")
    for row in rows:
        if row["id"] == key:
            return key
    matches = [row for row in rows if row["title"].strip().casefold() == key.casefold()]
    if len(matches) > 1:
        found = ", ".join(f"{row['title']} ({row.get('account') or '?'})" for row in matches)
        raise OrganizerError(f"ambiguous: {found} all match {key!r}; pass the list id")
    if matches:
        return matches[0]["id"]
    raise OrganizerError(f"not found: no reminders list named {key!r}; reminder_lists() lists them")


def _reminder(row: dict[str, Any]) -> dict[str, Any]:
    sync = row.get("sync") or {}
    return {
        "id": row.get("id"),
        "title": row.get("title"),
        "notes": row.get("notes") or "",
        "list": row.get("list_title"),
        "list_id": row.get("list_id"),
        "provider": row.get("source"),
        "due_date": row.get("due_date"),
        "due_time": (row.get("due_time") or "")[:5] or None,
        "priority": row.get("priority"),
        "completed": row.get("completed"),
        "sync": sync.get("state"),
        "pending": sync.get("pending_fields") or [],
        "error": sync.get("error"),
    }


LIST_FIELDS = (
    "id",
    "title",
    "account",
    "writable",
    "is_default",
    "supports_time",
    "supports_priority",
    "open_count",
)


def _list(row: dict[str, Any]) -> dict[str, Any]:
    return {"provider": row.get("source"), **{name: row.get(name) for name in LIST_FIELDS}}


def _drop_none(body: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in body.items() if value is not None}


def _patch_body(values: dict[str, Any], clear: list[str] | None) -> dict[str, Any]:
    """The fields passed, plus an explicit null for each field named in clear."""
    body = _drop_none(values)
    for name in clear or []:
        if name in body:
            raise OrganizerError(f"{name} is both set and cleared; choose one")
        body[name] = None
    if not body:
        raise OrganizerError("nothing to change: pass a field to set or name one in clear")
    return body


@app.tool(annotations=READ_ONLY)
def reminders(list: str | None = None, include_completed: bool = False) -> list[dict[str, Any]]:
    """The owner's reminders, as their provider last reported them, with queued changes applied.

    list: a list name (ignoring case) or an id from reminder_lists(); omit it for every list.
    include_completed also returns reminders completed in the last 30 days. Open reminders come
    first by due date. Each item is {id, title, notes, list, list_id, provider, due_date,
    due_time, priority (1 high, 2 medium, 3 low), completed, sync, pending, error}. provider is
    "apple" (Apple Reminders, through the Mac helper) or "google" (Google Tasks). sync is
    "synced"; "syncing" (a change is on its way); "waiting_for_device" (an Apple change has been
    queued over two minutes and the Mac helper is not polling, so the Mac is asleep or off); or
    "failed" (see error). pending names the fields the provider does not have yet.
    """
    c = client()
    list_id = _resolve_list(c, list) if list is not None else None
    rows = c.get("/api/reminders", params={"list": list_id, "include_completed": include_completed})
    return [_reminder(row) for row in rows]


@app.tool(annotations=READ_ONLY)
def reminder_lists() -> list[dict[str, Any]]:
    """The owner's reminders lists, Apple Reminders first, then each Google account's.

    Each is {id, title, provider, account, writable, is_default, supports_time,
    supports_priority, open_count}. A list that is not writable cannot take new or moved
    reminders. is_default marks where add_reminder puts a reminder when no list is given. Google
    Tasks lists have supports_time and supports_priority false: they keep a due date only.
    """
    return [_list(row) for row in client().get("/api/reminders/lists")]


@app.tool(annotations=WRITE)
def add_reminder(
    title: str,
    list: str | None = None,
    due_date: dt.date | None = None,
    due_time: dt.time | None = None,
    notes: str | None = None,
    priority: Priority | None = None,
) -> dict[str, Any]:
    """Add a reminder (author: claude). Returns it in the reminders() shape.

    list is a list name or id (default: the default list). due_time needs due_date; times have
    minute precision. A Google Tasks list takes no due_time and no priority (the call is refused
    with a message; retry without them). A Google reminder is created at once (sync "synced"). An
    Apple reminder is queued and created once the Mac helper runs, within about a minute while
    the Mac is awake; it is listed at once with sync "syncing" and keeps its id.
    """
    c = client()
    body = _drop_none(
        {
            "title": title,
            "list_id": _resolve_list(c, list) if list is not None else None,
            "due_date": due_date,
            "due_time": due_time,
            "notes": notes,
            "priority": priority,
        }
    )
    return _reminder(c.post("/api/reminders", body))


@app.tool(annotations=WRITE)
def complete_reminder(id: int, completed: bool = True) -> dict[str, Any]:
    """Check off a reminder, or with completed=false uncheck it (author: claude). Returns it in
    the reminders() shape.

    Google Tasks applies it at once; Apple Reminders once the Mac helper runs (until then it
    shows with sync "syncing" or "waiting_for_device"). Completing a completed reminder changes
    nothing.
    """
    action = "complete" if completed else "uncomplete"
    return _reminder(client().post(f"/api/reminders/{id}/{action}"))


@app.tool(annotations=WRITE)
def update_reminder(
    id: int,
    title: str | None = None,
    notes: str | None = None,
    due_date: dt.date | None = None,
    due_time: dt.time | None = None,
    priority: Priority | None = None,
    list: str | None = None,
    clear: list[ClearReminderField] | None = None,
) -> dict[str, Any]:
    """Change the fields you pass on a reminder (author: claude). Returns the reminder.

    If the reminder is also edited elsewhere before the change lands, the later edit wins,
    field by field. list moves it to another list of the same account (a name or id). To remove
    a value, name it in clear: due_date (this also clears due_time), due_time or priority.
    Setting and clearing the same field in one call is an error. Google Tasks reminders take no
    due_time and no priority.
    """
    c = client()
    body = _patch_body(
        {
            "title": title,
            "notes": notes,
            "due_date": due_date,
            "due_time": due_time,
            "priority": priority,
            "list_id": _resolve_list(c, list) if list is not None else None,
        },
        clear,
    )
    return _reminder(c.patch(f"/api/reminders/{id}", body))
