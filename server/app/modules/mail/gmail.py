"""Gmail over its REST API, read-only.

Two locks, either enough on its own:
- the Google account's grant for Gmail is `gmail.readonly` (app.providers.google asks for
  nothing else), so Google refuses any change or send;
- `_ReadOnlyGmail` makes only GET requests to the Gmail API, with an access token from core
  (app.providers.google.access_token, which refreshes it). It never posts anything.
  tests/test_mail_readonly.py records every request and fails on anything else.
"""

from __future__ import annotations

import base64
import re
from collections.abc import Callable
from datetime import UTC, date, datetime
from typing import Any

import httpx

from app.modules.mail.message import HEADER_FIELDS, parse_header_pairs
from app.modules.mail.sources import MAX_RAW_BYTES, FolderIds, MailError, RemoteHeader

_ID = re.compile(r"^[0-9a-fA-F]{1,32}$")
SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
API_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"
TIMEOUT_SECONDS = 30
PAGE_SIZE = 500
FOLDERS = (("inbox", "INBOX"), ("sent", "SENT"))
TRUSTED_AUTH_SERVERS = ("mx.google.com",)

REFUSED = (
    "Gmail refused the access token: reconnect the Google account in Settings, Connected accounts."
)

# Returns a valid access token; raises MailError when the account must be reconnected.
TokenGetter = Callable[[], str]


class _ReadOnlyGmail:
    """The only object that calls Google, and it only GETs from the Gmail API."""

    def __init__(self, token: TokenGetter, transport: httpx.BaseTransport | None = None) -> None:
        self._token = token
        self._http = httpx.Client(timeout=TIMEOUT_SECONDS, transport=transport)

    def get(self, path: str, params: list[tuple[str, str]] | None = None) -> dict[str, Any] | None:
        """GET <API_BASE>/<path>. None for a 404 (the message is gone)."""
        for attempt in (0, 1):
            headers = {"Authorization": f"Bearer {self._token()}"}
            try:
                response = self._http.get(f"{API_BASE}/{path}", params=params, headers=headers)
            except httpx.HTTPError as exc:
                raise MailError(f"Gmail API unreachable: {exc}") from None
            if response.status_code == 401 and attempt == 0:
                continue  # the token expired early: ask core for one again, once
            if response.status_code == 401:
                raise MailError(REFUSED)
            if response.status_code == 404:
                return None
            if response.status_code != 200:
                message = _json(response).get("error", {})
                detail = message.get("message", "") if isinstance(message, dict) else ""
                raise MailError(
                    f"Gmail API {path.split('/')[0]}: HTTP {response.status_code} {detail}"
                )
            return _json(response)
        raise MailError(REFUSED)

    def close(self) -> None:
        self._http.close()


def _json(response: httpx.Response) -> dict[str, Any]:
    try:
        body = response.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


class GmailSource:
    trusted_auth_servers = TRUSTED_AUTH_SERVERS

    def __init__(self, token: TokenGetter, transport: httpx.BaseTransport | None = None) -> None:
        self._api = _ReadOnlyGmail(token, transport)

    def list_ids(self, since: date) -> list[FolderIds]:
        after = int(datetime(since.year, since.month, since.day, tzinfo=UTC).timestamp())
        out = []
        for folder, label in FOLDERS:
            ids: list[str] = []
            page: str | None = None
            while True:
                params = [
                    ("labelIds", label),
                    ("q", f"after:{after}"),
                    ("maxResults", str(PAGE_SIZE)),
                ]
                if page:
                    params.append(("pageToken", page))
                body = self._api.get("messages", params) or {}
                ids.extend(
                    str(m["id"]) for m in body.get("messages", []) if _ID.match(str(m.get("id")))
                )
                page = body.get("nextPageToken")
                if not page:
                    break
            out.append(FolderIds(folder, label, ids))
        return out

    def fetch_headers(self, folder: FolderIds, remote_ids: list[str]) -> list[RemoteHeader]:
        params = [("format", "metadata")] + [("metadataHeaders", h) for h in HEADER_FIELDS]
        out = []
        for remote_id in remote_ids:
            if not _ID.match(remote_id):
                continue
            body = self._api.get(f"messages/{remote_id}", params)
            if body is None:
                continue
            internal = body.get("internalDate")
            received = datetime.fromtimestamp(int(internal) / 1000, tz=UTC) if internal else None
            out.append(
                RemoteHeader(
                    folder=folder.folder,
                    mailbox=folder.mailbox,
                    remote_id=remote_id,
                    headers=parse_header_pairs(body.get("payload", {}).get("headers", [])),
                    size=int(body["sizeEstimate"]) if body.get("sizeEstimate") else None,
                    received=received,
                )
            )
        return out

    def fetch_raw(self, mailbox: str, remote_id: str) -> bytes | None:
        if not _ID.match(remote_id):
            return None
        body = self._api.get(f"messages/{remote_id}", [("format", "raw")])
        if body is None:
            return None
        if int(body.get("sizeEstimate") or 0) > MAX_RAW_BYTES:
            raise MailError(
                f"This message is over {MAX_RAW_BYTES // (1024 * 1024)} MB (attachments); "
                "open it in Gmail."
            )
        raw = str(body.get("raw", ""))
        return base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))

    def close(self) -> None:
        self._api.close()
