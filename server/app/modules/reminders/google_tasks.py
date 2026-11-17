"""Google Tasks, both ways: the poll that mirrors an account's lists and tasks, and the server
applier that carries the organizer's ops to Google right away.

The poll reads every task list and its tasks (completed and hidden ones too, then keeps open
tasks and those completed in the last 30 days) and replaces that account's rows, all or
nothing, through `sync.replace_snapshot`.

The applier follows the same rules as the Mac helper (docs/REMINDERS.md):
- the loop rule: a field still equal to the op's `base` takes the op's value;
- a field changed on both sides goes to the last writer, comparing the task's `updated` with
  the op's queue time, and is reported in the op's `conflicts`;
- completing always applies; un-completing yields to a completion made after it was queued.
After applying, the task Google returns is written into the mirror at once, so the reminder is
`synced` without waiting for the next poll.

Google Tasks keeps a due date but no time, and has no priority. The router refuses both for
Google lists before an op is queued.

Errors: a refused grant or a 4xx answer fails the op (it can be retried or withdrawn); a
network error, a 429 or a 5xx leaves it pending, and the next poll retries it, up to
MAX_ATTEMPTS.

HTTP goes through `app.providers.google.make_client()`, which tests point at an
`httpx.MockTransport`.
"""

import hashlib
import logging
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any
from urllib.parse import quote

import httpx
from sqlalchemy.orm import Session

from app import audit, freshness
from app.config import Settings
from app.modules.reminders import sync
from app.modules.reminders.accounts import account_name, freshness_key
from app.modules.reminders.models import Reminder, ReminderOp
from app.providers import google
from app.providers import service as provider_accounts
from app.providers.models import ProviderAccount
from app.timeutil import utcnow

log = logging.getLogger(__name__)

API = "https://tasks.googleapis.com/tasks/v1"
PAGE_SIZE = 100
MAX_PAGES = 50
MAX_ATTEMPTS = 5
ACCOUNT_TYPE = "google"
AUTHOR = "system"
# Google Tasks lists have no color; each list gets a stable one from this palette.
PALETTE = ("#1A73E8", "#188038", "#E37400", "#D93025", "#9334E6", "#007B83", "#C5221F")


class GoogleTasksError(Exception):
    """Google answered with an error."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status

    @property
    def transient(self) -> bool:
        return self.status is None or self.status == 429 or self.status >= 500


@dataclass(frozen=True)
class SyncResult:
    lists: int
    reminders: int


def list_color(list_id: str) -> str:
    digest = hashlib.sha256(list_id.encode()).digest()
    return PALETTE[digest[0] % len(PALETTE)]


# --------------------------------------------------------------------------- HTTP


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Accept": "application/json"}


def _error(response: httpx.Response, action: str) -> GoogleTasksError:
    try:
        detail = response.json().get("error", {}).get("message")
    except (ValueError, AttributeError):
        detail = None
    message = f"Google Tasks answered {response.status_code} to {action}"
    return GoogleTasksError(message + (f": {detail}" if detail else ""), response.status_code)


def _pages(
    http: httpx.Client, url: str, params: dict[str, str], headers: dict[str, str]
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    page_token: str | None = None
    for _ in range(MAX_PAGES):
        query = {**params, **({"pageToken": page_token} if page_token else {})}
        response = http.get(url, params=query, headers=headers)
        if response.status_code != 200:
            raise _error(response, "a list request")
        body = response.json()
        items.extend(body.get("items", []) or [])
        page_token = body.get("nextPageToken")
        if not page_token:
            break
    return items


def _task_url(list_id: str, task_id: str | None = None) -> str:
    url = f"{API}/lists/{quote(list_id, safe='')}/tasks"
    return f"{url}/{quote(task_id, safe='')}" if task_id else url


# --------------------------------------------------------------------------- mapping


def _timestamp(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else None


def due_date(value: Any) -> date | None:
    """Google stores a due date as midnight UTC of that day; the date part is the day."""
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def wire_due(value: str | None) -> str | None:
    """A wire due_date ("YYYY-MM-DD") as Google's RFC 3339 due value."""
    return f"{value}T00:00:00.000Z" if value else None


def incoming(task: dict[str, Any], list_id: str) -> sync.IncomingReminder:
    completed = task.get("status") == "completed"
    return sync.IncomingReminder(
        external_id=str(task["id"]),
        local_id=None,
        list_id=list_id,
        title=str(task.get("title") or ""),
        notes=str(task.get("notes") or ""),
        due_date=due_date(task.get("due")),
        due_time=None,
        priority=None,
        completed=completed,
        completed_at=_timestamp(task.get("completed")) if completed else None,
        url=task.get("webViewLink") or None,
        created_at=None,
        modified_at=_timestamp(task.get("updated")),
    )


def _keep(task: dict[str, Any], cutoff: datetime) -> bool:
    if task.get("deleted") or not task.get("id"):
        return False
    if task.get("status") != "completed":
        return True
    done = _timestamp(task.get("completed"))
    return done is None or done >= cutoff


# --------------------------------------------------------------------------- the poll


def sync_account(
    session: Session,
    settings: Settings,
    account: ProviderAccount,
    *,
    now: datetime | None = None,
) -> SyncResult:
    """Poll one Google account and replace its rows. Errors are recorded and re-raised."""
    now = now or utcnow()
    key = freshness_key(account.id)
    name = account_name(account)
    cutoff = now - timedelta(days=sync.COMPLETED_DAYS)
    try:
        token = google.access_token(session, settings, account)
        headers = _headers(token)
        lists: list[sync.IncomingList] = []
        reminders: list[sync.IncomingReminder] = []
        with google.make_client() as http:
            for entry in _pages(
                http, f"{API}/users/@me/lists", {"maxResults": str(PAGE_SIZE)}, headers
            ):
                list_id = str(entry["id"])
                lists.append(
                    sync.IncomingList(
                        id=list_id,
                        title=str(entry.get("title") or ""),
                        color=list_color(list_id),
                        account=name,
                        account_type=ACCOUNT_TYPE,
                        writable=True,
                    )
                )
                params = {
                    "showCompleted": "true",
                    "showHidden": "true",
                    "showDeleted": "false",
                    "maxResults": str(PAGE_SIZE),
                }
                for task in _pages(http, _task_url(list_id), params, headers):
                    if _keep(task, cutoff):
                        reminders.append(incoming(task, list_id))
        default = lists[0].id if lists else None  # Google's first list is its default
        with audit.transaction(session):
            counts = sync.replace_snapshot(
                session, sync.Scope("google", account.id), lists, reminders, default, now
            )
        freshness.mark_success(session, key, at=now)  # commits
        provider_accounts.mark_success(session, account)
    except Exception as exc:
        session.rollback()
        message = str(exc) or type(exc).__name__
        if isinstance(exc, google.GoogleAuthError):
            message = f"Google refused the sign-in; reconnect the account in Settings ({message})"
        freshness.mark_error(session, key, message)
        if not isinstance(exc, google.GoogleAuthError):  # access_token already marked it
            provider_accounts.mark_error(session, account, f"Tasks: {message}")
        raise
    return SyncResult(lists=counts.lists, reminders=counts.reminders)


# --------------------------------------------------------------------------- the applier


def apply_pending(
    session: Session, settings: Settings, reminder_ids: set[int] | None = None
) -> None:
    """Apply pending server ops in queue order. One reminder's ops stop at the first that stays
    pending, so they always land in order."""
    blocked: set[int] = set()
    for op, row in sync.pending_for(session, "server"):
        if reminder_ids is not None and op.reminder_id not in reminder_ids:
            continue
        if op.reminder_id in blocked:
            continue
        apply_op(session, settings, op, row)
        if op.state == "pending":
            blocked.add(op.reminder_id)


def apply_op(
    session: Session, settings: Settings, op: ReminderOp, row: Reminder | None
) -> ReminderOp:
    """Apply one server op now and record the outcome through app.audit. Never raises."""
    if row is None:
        return _fail(session, op, "the reminder is gone from Google Tasks")
    account = session.get(ProviderAccount, row.account_id) if row.account_id else None
    if account is None or not account.enabled:
        return _fail(session, op, "the Google account is not connected; reconnect it in Settings")
    try:
        token = google.access_token(session, settings, account)
        with google.make_client() as http:
            if op.kind == "create":
                task, list_id, conflicts = _create(http, token, op)
            else:
                task, list_id, conflicts = _change(http, token, op, row)
    except google.GoogleAuthError as exc:
        return _fail(session, op, f"Google refused the sign-in; reconnect the account ({exc})")
    except GoogleTasksError as exc:
        if exc.status == 404:
            return _fail(session, op, "the reminder is gone from Google Tasks")
        if exc.transient:
            return _retry_later(session, op, str(exc))
        return _fail(session, op, str(exc))
    except httpx.HTTPError as exc:
        return _retry_later(session, op, f"could not reach Google Tasks ({type(exc).__name__})")

    with audit.transaction(session):
        sync.apply_ack(
            session,
            op,
            ok=True,
            external_id=str(task["id"]) if op.kind == "create" else None,
            local_id=None,
            error=None,
            conflicts=conflicts,
            author=AUTHOR,
        )
        # Mirror Google's answer now: the overlay ends, the reminder is synced.
        sync.fill(row, incoming(task, list_id), utcnow())
        session.flush()
    return op


def _fail(session: Session, op: ReminderOp, message: str) -> ReminderOp:
    return sync.apply_ack(
        session,
        op,
        ok=False,
        external_id=None,
        local_id=None,
        error=message,
        conflicts=[],
        author=AUTHOR,
    )


def _retry_later(session: Session, op: ReminderOp, message: str) -> ReminderOp:
    attempts = (op.attempts or 0) + 1
    if attempts >= MAX_ATTEMPTS:
        audit.update(session, op, {"attempts": attempts}, AUTHOR)
        return _fail(session, op, f"{message}; gave up after {attempts} attempts")
    log.info("reminders: op %s will be retried (%s)", op.id, message)
    audit.update(session, op, {"attempts": attempts, "error": message[:2000]}, AUTHOR)
    return op


def _create(
    http: httpx.Client, token: str, op: ReminderOp
) -> tuple[dict[str, Any], str, list[dict[str, Any]]]:
    fields = op.payload or {}
    list_id = str(fields.get("list_id") or "")
    if not list_id:
        raise GoogleTasksError("no list to create the reminder in", 400)
    body: dict[str, Any] = {"title": fields.get("title") or "", "notes": fields.get("notes") or ""}
    if fields.get("due_date"):
        body["due"] = wire_due(fields["due_date"])
    response = http.post(_task_url(list_id), json=body, headers=_headers(token))
    if response.status_code not in (200, 201):
        raise _error(response, "creating a task")
    return response.json(), list_id, []


def _provider_values(task: dict[str, Any], list_id: str) -> dict[str, Any]:
    return {
        "title": str(task.get("title") or ""),
        "notes": str(task.get("notes") or ""),
        "due_date": sync.wire_date(due_date(task.get("due"))),
        "due_time": None,
        "priority": None,
        "list_id": list_id,
        "completed": task.get("status") == "completed",
    }


def _shown(value: Any) -> str | None:
    return None if value is None else str(value)


def _change(
    http: httpx.Client, token: str, op: ReminderOp, row: Reminder
) -> tuple[dict[str, Any], str, list[dict[str, Any]]]:
    """Update, complete or uncomplete one task under the loop rule and the conflict rule."""
    if not row.ext_id or not row.list_ext_id:
        raise GoogleTasksError("the reminder is not in Google Tasks yet", 409)
    list_id = row.list_ext_id
    response = http.get(_task_url(list_id, row.ext_id), headers=_headers(token))
    if response.status_code != 200:
        raise _error(response, "reading the task")
    task = response.json()
    if task.get("deleted"):
        raise GoogleTasksError("the task was deleted", 404)
    current = _provider_values(task, list_id)
    modified = _timestamp(task.get("updated"))
    provider_newer = modified is not None and modified > op.created_at
    base = op.base or {}
    conflicts: list[dict[str, Any]] = []
    patch: dict[str, Any] = {}
    move_to: str | None = None

    if op.kind == "complete":
        if not current["completed"]:
            patch["status"] = "completed"
    elif op.kind == "uncomplete":
        if current["completed"]:
            done_at = _timestamp(task.get("completed"))
            if done_at is not None and done_at > op.created_at:
                # Completed again after the uncomplete was queued: completion is never lost.
                conflicts.append(
                    {
                        "field": "completed",
                        "kept": "provider",
                        "provider_value": "true",
                        "organizer_value": "false",
                    }
                )
            else:
                patch["status"] = "needsAction"
                patch["completed"] = None
    else:
        fields = dict(op.payload or {})
        groups: dict[str, list[str]] = {}
        for key in fields:
            groups.setdefault(sync.sync_field(key), []).append(key)
        for name, keys in groups.items():
            wanted = {k: fields[k] for k in keys}
            have = {k: current.get(k) for k in keys}
            if have == wanted:
                continue
            was = {k: base.get(k) for k in keys}
            if have != was:  # changed on both sides
                kept = "provider" if provider_newer else "organizer"
                conflicts.append(
                    {
                        "field": name,
                        "kept": kept,
                        "provider_value": _shown(have.get(keys[0])),
                        "organizer_value": _shown(wanted.get(keys[0])),
                    }
                )
                if kept == "provider":
                    continue
            if name == "title":
                patch["title"] = wanted["title"]
            elif name == "notes":
                patch["notes"] = wanted["notes"]
            elif name == "due":
                patch["due"] = wire_due(wanted.get("due_date"))
            elif name == "list":
                move_to = str(wanted["list_id"])
            # priority never reaches here: the router refuses it for Google lists.

    if patch:
        response = http.patch(_task_url(list_id, row.ext_id), json=patch, headers=_headers(token))
        if response.status_code != 200:
            raise _error(response, "updating the task")
        task = response.json()
    if move_to and move_to != list_id:
        response = http.post(
            f"{_task_url(list_id, row.ext_id)}/move",
            params={"destinationTasklist": move_to},
            headers=_headers(token),
        )
        if response.status_code != 200:
            raise _error(response, "moving the task")
        task = response.json()
        list_id = move_to
    return task, list_id, conflicts
