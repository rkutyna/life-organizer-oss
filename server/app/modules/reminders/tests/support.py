"""Synthetic fixtures for the reminders tests. Every list, title, address and id is invented;
Google is an httpx.MockTransport that is never a real server."""

import json
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.config import Settings
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount

PUSH = "/api/ingest/reminders"
OPS = "/api/ingest/reminders/ops"
GOOGLE_USER = "someone@example.com"


def a_list(
    list_id: str,
    title: str,
    *,
    color: str | None = "#FF9500",
    account: str | None = "iCloud",
    writable: bool = True,
) -> dict[str, Any]:
    return {
        "id": list_id,
        "title": title,
        "color": color,
        "account": account,
        "account_type": "caldav",
        "writable": writable,
    }


def a_reminder(
    local_id: str,
    list_id: str,
    title: str,
    *,
    external_id: str | None = "same-as-local",
    notes: str | None = None,
    due_date: str | None = None,
    due_time: str | None = None,
    priority: int | None = None,
    completed: bool = False,
    completed_at: str | None = None,
    modified_at: str | None = "2026-10-01T09:00:00-04:00",
) -> dict[str, Any]:
    return {
        "external_id": f"ext-{local_id}" if external_id == "same-as-local" else external_id,
        "local_id": local_id,
        "list_id": list_id,
        "title": title,
        "notes": notes,
        "due_date": due_date,
        "due_time": due_time,
        "priority": priority,
        "completed": completed,
        "completed_at": completed_at,
        "url": None,
        "created_at": "2026-09-01T09:00:00-04:00",
        "modified_at": modified_at,
    }


def push_body(
    lists: list[dict[str, Any]],
    reminders: list[dict[str, Any]],
    *,
    default_list_id: str | None = None,
) -> dict[str, Any]:
    """A snapshot as the Mac helper sends it (envelope fields included)."""
    return {
        "collected_at": "2026-10-19T12:00:00-04:00",
        "host": "test-mac",
        "lists": lists,
        "default_list_id": default_list_id,
        "reminders": reminders,
    }


def push(helper: TestClient, body: dict[str, Any]) -> dict[str, Any]:
    response = helper.post(PUSH, json=body)
    assert response.status_code == 200, response.text
    return response.json()


def helper_ops(helper: TestClient) -> list[dict[str, Any]]:
    response = helper.get(OPS)
    assert response.status_code == 200, response.text
    return response.json()["ops"]


def ack(helper: TestClient, op_id: int, **body: Any) -> dict[str, Any]:
    body.setdefault("ok", True)
    response = helper.post(f"{OPS}/{op_id}/ack", json=body)
    assert response.status_code == 200, response.text
    return response.json()


GROCERIES = a_list("L-groceries", "Groceries", color="#34C759")
ERRANDS = a_list("L-errands", "Errands", color="#007AFF")
SHARED = a_list("L-shared", "Shared (read-only)", writable=False)


# --------------------------------------------------------------------------- Google Tasks


def google_account(
    session: Session, settings: Settings, *, email: str = GOOGLE_USER, tasks: bool = True
) -> ProviderAccount:
    scopes = [google.SCOPES["tasks"]] if tasks else [google.SCOPES["calendar"]]
    return accounts.create(
        session,
        settings,
        kind="google",
        label=email,
        credentials={"refresh_token": "synthetic-refresh-token"},
        config={"email": email, "scopes": scopes},
    )


@dataclass
class FakeTasks:
    """An in-memory Google Tasks API behind an httpx.MockTransport.

    `lists` maps a task list id to its title; `tasks` maps a list id to {task id: task}.
    `fail` maps "METHOD path-regex" to a status code to answer instead. Every request is
    recorded in `calls` as (method, path, json body or None), and its query in `queries`.
    Listing tasks honors `updatedMin` and `completedMin` as Google does.
    """

    lists: dict[str, str] = field(default_factory=dict)
    tasks: dict[str, dict[str, dict[str, Any]]] = field(default_factory=dict)
    fail: dict[str, int] = field(default_factory=dict)
    calls: list[tuple[str, str, Any]] = field(default_factory=list)
    queries: list[dict[str, str]] = field(default_factory=list)
    clock: str = "2026-10-19T12:00:00.000Z"
    raise_network: bool = False
    _next: int = 0

    def add(self, list_id: str, task_id: str, title: str, **extra: Any) -> dict[str, Any]:
        task = {
            "id": task_id,
            "title": title,
            "status": "needsAction",
            "updated": "2026-10-01T13:00:00.000Z",
            "webViewLink": f"https://tasks.example.com/{task_id}",
            **extra,
        }
        self.tasks.setdefault(list_id, {})[task_id] = task
        return task

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path.removeprefix("/tasks/v1")
        body = json.loads(request.content) if request.content else None
        self.calls.append((request.method, path, body))
        self.queries.append(dict(request.url.params))
        if self.raise_network:
            raise httpx.ConnectError("synthetic network failure", request=request)
        for pattern, status in self.fail.items():
            method, _, regex = pattern.partition(" ")
            if request.method == method and re.fullmatch(regex, path):
                return httpx.Response(status, json={"error": {"message": "synthetic failure"}})
        if path == "/users/@me/lists":
            items = [{"id": k, "title": v} for k, v in self.lists.items()]
            return httpx.Response(200, json={"items": items})
        match = re.fullmatch(r"/lists/([^/]+)/tasks(?:/([^/]+))?(/move)?", path)
        if not match:
            return httpx.Response(404, json={"error": {"message": "no such path"}})
        list_id, task_id, move = match.groups()
        tasks = self.tasks.setdefault(list_id, {})
        if task_id is None and request.method == "GET":
            return httpx.Response(200, json={"items": _listed(tasks, request.url.params)})
        if task_id is None and request.method == "POST":
            self._next += 1
            new = {"id": f"new-{self._next}", "status": "needsAction", **(body or {})}
            new["updated"] = self.clock
            tasks[new["id"]] = new
            return httpx.Response(200, json=new)
        task = tasks.get(task_id or "")
        if task is None:
            return httpx.Response(404, json={"error": {"message": "Task not found"}})
        if move:
            destination = request.url.params["destinationTasklist"]
            del tasks[task["id"]]
            self.tasks.setdefault(destination, {})[task["id"]] = task
            task["updated"] = self.clock
            return httpx.Response(200, json=task)
        if request.method == "GET":
            return httpx.Response(200, json=task)
        if request.method == "PATCH":
            for key, value in (body or {}).items():
                if value is None:
                    task.pop(key, None)
                else:
                    task[key] = value
            if (body or {}).get("status") == "completed":
                task["completed"] = self.clock
            task["updated"] = self.clock
            return httpx.Response(200, json=task)
        return httpx.Response(405)


def _stamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _listed(tasks: dict[str, dict[str, Any]], params: Any) -> list[dict[str, Any]]:
    out = list(tasks.values())
    if "updatedMin" in params:
        since = _stamp(params["updatedMin"])
        out = [t for t in out if _stamp(t["updated"]) >= since]
    if "completedMin" in params:
        since = _stamp(params["completedMin"])
        out = [
            t
            for t in out
            if t.get("status") != "completed"
            or not t.get("completed")
            or _stamp(t["completed"]) >= since
        ]
    return out


@pytest.fixture
def fake_tasks(monkeypatch: pytest.MonkeyPatch) -> FakeTasks:
    fake = FakeTasks()
    monkeypatch.setattr(
        google, "make_client", lambda: httpx.Client(transport=httpx.MockTransport(fake.handler))
    )
    monkeypatch.setattr(google, "access_token", lambda session, settings, account: "synthetic")
    return fake
