"""A fake organizer behind httpx.MockTransport, and request helpers. No socket is opened."""

from __future__ import annotations

import json
from typing import Any

import httpx

BASE_URL = "http://organizer.test"
API_TOKEN = "org_api-token-for-tests"
MAIL_TOKEN = "org_mail-token-for-tests"


class FakeOrganizer:
    """Canned replies keyed by (method, path). An unregistered route answers 404 the way FastAPI
    does. A reply may be a callable taking the request, or an exception to raise instead."""

    def __init__(self) -> None:
        self._routes: dict[tuple[str, str], tuple[int, Any]] = {}
        self.requests: list[httpx.Request] = []

    def reply(self, method: str, path: str, body: Any = None, status: int = 200) -> None:
        self._routes[(method, path)] = (status, body)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        route = self._routes.get((request.method, request.url.path))
        if route is None:
            return httpx.Response(404, json={"detail": "Not Found"})
        status, body = route
        if isinstance(body, Exception):
            raise body
        if callable(body):
            body = body(request)
        if status == 204:
            return httpx.Response(204)
        return httpx.Response(status, json=body)

    def sent(self, method: str, path: str) -> list[httpx.Request]:
        return [r for r in self.requests if r.method == method and r.url.path == path]

    def only(self, method: str, path: str) -> httpx.Request:
        found = self.sent(method, path)
        assert len(found) == 1, f"expected one {method} {path}, got {len(found)}"
        return found[0]


def sent_json(request: httpx.Request) -> Any:
    """The JSON body of a request, or None when it had none."""
    return json.loads(request.content) if request.content else None


def query(request: httpx.Request) -> dict[str, list[str]]:
    """The query string as {key: [values]}, so repeated keys are visible."""
    out: dict[str, list[str]] = {}
    for key, value in request.url.params.multi_items():
        out.setdefault(key, []).append(value)
    return out
