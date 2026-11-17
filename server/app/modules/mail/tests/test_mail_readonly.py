"""Nothing in the mail module can change a mailbox or send mail.

IMAP: every command the IMAP source sends is recorded against a fake server, and only the
read-only ones are allowed (EXAMINE, never SELECT; BODY.PEEK, so not even the read flag moves).
Gmail: every request is recorded; only GETs reach the Gmail API, and nothing is ever posted (the
token comes from core). A source scan catches a forbidden call added later.
"""

from __future__ import annotations

import base64
import json
import re
from datetime import date
from pathlib import Path
from typing import Any

import httpx
import pytest

from app.modules.mail import gmail, imap
from app.modules.mail.sources import FolderIds, MailError
from app.modules.mail.tests.fakes import raw_message

PACKAGE = Path(__file__).resolve().parents[1]
ALLOWED_IMAP = {"login", "list", "select", "response", "uid", "logout"}


class FakeIMAP:
    """Answers like imaplib.IMAP4_SSL for a two-mailbox account; records every call."""

    def __init__(self, uids_after_literal: bool = False) -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        self.uids_after_literal = uids_after_literal
        self.validity = b"77"
        self.messages = {"1": raw_message(subject="One"), "2": raw_message(subject="Two")}

    def __getattr__(self, name: str) -> Any:
        raise AssertionError(f"the mail module called IMAP {name!r}")

    def _record(self, name: str, *args: Any, **kwargs: Any) -> None:
        self.calls.append((name, args, kwargs))

    def login(self, user: str, password: str) -> tuple[str, list[bytes]]:
        self._record("login", user)
        return "OK", [b"logged in"]

    def list(self) -> tuple[str, list[bytes]]:
        self._record("list")
        return "OK", [
            b'(\\HasNoChildren) "/" "INBOX"',
            b'(\\HasNoChildren \\Sent) "/" "Sent Messages"',
            b'(\\HasNoChildren \\Trash) "/" "Deleted Messages"',
        ]

    def select(self, mailbox: str, readonly: bool = False) -> tuple[str, list[bytes]]:
        self._record("select", mailbox, readonly=readonly)
        return "OK", [b"2"]

    def response(self, name: str) -> tuple[str, list[bytes]]:
        self._record("response", name)
        return name, [self.validity]

    def uid(self, command: str, *args: str) -> tuple[str, list[Any]]:
        self._record("uid", command, *args)
        if command == "SEARCH":
            return "OK", [b" ".join(k.encode() for k in self.messages)]
        uids, items = args
        out: list[Any] = []
        for uid in uids.split(","):
            raw = self.messages[uid]
            if items == imap.RAW_ITEMS:
                out += [(f"1 (UID {uid} BODY[]<0> {{{len(raw)}}}".encode(), raw), b")"]
                continue
            header = raw.split(b"\n\n", 1)[0] + b"\r\n\r\n"
            meta = f'1 (RFC822.SIZE {len(raw)} INTERNALDATE "10-Nov-2026 10:00:00 -0500" '
            if self.uids_after_literal:
                out += [(f"{meta}BODY[HEADER] {{{len(header)}}}".encode(), header)]
                out.append(f" UID {uid})".encode())
            else:
                out += [(f"{meta}UID {uid} BODY[HEADER] {{{len(header)}}}".encode(), header)]
                out.append(b")")
        return "OK", out

    def logout(self) -> tuple[str, list[bytes]]:
        self._record("logout")
        return "BYE", [b""]


def icloud(fake: FakeIMAP) -> imap.ImapSource:
    return imap.ImapSource(
        "pat@example.org", "app-pass", "imap.example", connect=lambda host, port: fake
    )


@pytest.mark.parametrize("uids_after_literal", [False, True])
def test_the_imap_source_reads_with_examine_and_peek_only(uids_after_literal: bool) -> None:
    fake = FakeIMAP(uids_after_literal)
    source = icloud(fake)

    folders = source.list_ids(date(2026, 10, 1))
    headers = source.fetch_headers(folders[0], folders[0].remote_ids)
    raw = source.fetch_raw("INBOX", "77:2")
    source.close()

    assert [(f.folder, f.mailbox, f.remote_ids) for f in folders] == [
        ("inbox", "INBOX", ["77:1", "77:2"]),
        ("sent", "Sent Messages", ["77:1", "77:2"]),
    ]
    assert [(h.remote_id, h.headers.subject) for h in headers] == [("77:1", "One"), ("77:2", "Two")]
    assert headers[0].received is not None and headers[0].received.isoformat() == (
        "2026-11-10T10:00:00-05:00"
    )
    assert raw == fake.messages["2"]

    assert {name for name, _, _ in fake.calls} <= ALLOWED_IMAP
    selects = [(args, kwargs) for name, args, kwargs in fake.calls if name == "select"]
    assert selects and all(kwargs == {"readonly": True} for _, kwargs in selects)
    assert {args[0] for args, _ in selects} == {'"INBOX"', '"Sent Messages"'}
    uid_commands = [args for name, args, _ in fake.calls if name == "uid"]
    assert {a[0] for a in uid_commands} == {"SEARCH", "FETCH"}
    assert ("SEARCH", "SINCE", "01-Oct-2026") in uid_commands
    for args in uid_commands:
        if args[0] == "FETCH":
            items = args[2]
            assert "BODY.PEEK[" in items
            assert not re.search(r"(?<!PEEK)BODY\[|RFC822(?![.]SIZE)", items), items


def test_server_controlled_names_and_uids_cannot_add_commands() -> None:
    class Hostile(FakeIMAP):
        def list(self) -> tuple[str, list[bytes]]:
            self._record("list")
            return "OK", [b'(\\HasNoChildren \\Sent) "/" "Sent\rA9 UID STORE 1 +FLAGS (\\Deleted)"']

        def uid(self, command: str, *args: str) -> tuple[str, list[Any]]:
            if command == "SEARCH":
                self._record("uid", command, *args)
                return "OK", [b"1 1:* 2"]
            return super().uid(command, *args)

    fake = Hostile()
    source = icloud(fake)
    with pytest.raises(MailError, match="line break"):
        source.list_ids(date(2026, 10, 1))
    assert (
        icloud(FakeIMAP()).fetch_raw("INBOX", "77:1\r\nA1 UID STORE 1 +FLAGS (\\Deleted)") is None
    )

    plain = FakeIMAP()
    plain_source = icloud(plain)
    plain.messages = {"1": raw_message(), "2": raw_message()}
    original = plain.uid

    def ranged(command: str, *args: str) -> tuple[str, list[Any]]:
        if command == "SEARCH":
            return "OK", [b"1 1:* 2"]
        return original(command, *args)

    plain.uid = ranged  # type: ignore[method-assign]
    folders = plain_source.list_ids(date(2026, 10, 1))
    assert folders[0].remote_ids == ["77:1", "77:2"]  # the range is dropped


def test_a_rebuilt_mailbox_reads_as_gone() -> None:
    fake = FakeIMAP()
    assert icloud(fake).fetch_raw("INBOX", "76:2") is None


def test_a_refused_login_is_a_mail_error_without_the_password() -> None:
    import imaplib

    class Refusing(FakeIMAP):
        def login(self, user: str, password: str) -> tuple[str, list[bytes]]:
            raise imaplib.IMAP4.error("[AUTHENTICATIONFAILED] Authentication failed.")

    with pytest.raises(MailError) as caught:
        icloud(Refusing()).list_ids(date(2026, 10, 1))
    assert str(caught.value) == "IMAP login failed: [AUTHENTICATIONFAILED] Authentication failed."
    assert "app-pass" not in str(caught.value)


def test_the_connect_check_is_read_only_too() -> None:
    fake = FakeIMAP()
    source = icloud(fake)
    assert source.check() == ["INBOX", "Sent Messages"]
    source.close()

    assert [name for name, _, _ in fake.calls] == ["login", "list", "select", "response", "logout"]
    assert fake.calls[2][2] == {"readonly": True}


def test_an_unreachable_host_is_a_mail_error() -> None:
    def refuse(host: str, port: int) -> FakeIMAP:
        raise OSError("connection refused")

    source = imap.ImapSource("u", "p", "imap.example", 993, connect=refuse)
    with pytest.raises(MailError, match=r"IMAP unreachable at imap.example:993"):
        source.check()


class FakeGoogle:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.refuse = 0  # answer this many requests with 401

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.refuse:
            self.refuse -= 1
            return httpx.Response(401, json={"error": {"message": "expired"}})
        path = request.url.path.removeprefix("/gmail/v1/users/me/")
        if path == "messages":
            label = request.url.params["labelIds"]
            ids = [{"id": "a"}, {"id": "b"}, {"id": "../x?y"}] if label == "INBOX" else []
            return httpx.Response(200, json={"messages": ids})
        message_id = path.split("/")[1]
        if message_id == "b":
            return httpx.Response(404, json={"error": {"message": "not found"}})
        raw = raw_message(subject="Hello")
        if request.url.params["format"] == "raw":
            encoded = base64.urlsafe_b64encode(raw).decode().rstrip("=")
            return httpx.Response(200, json={"raw": encoded, "sizeEstimate": len(raw)})
        return httpx.Response(
            200,
            json={
                "id": message_id,
                "internalDate": "1794330000000",
                "sizeEstimate": 1234,
                "payload": {"headers": [{"name": "Subject", "value": "Hello"}]},
            },
        )


class Tokens:
    def __init__(self) -> None:
        self.calls = 0
        self.error: MailError | None = None

    def __call__(self) -> str:
        self.calls += 1
        if self.error:
            raise self.error
        return f"at-{self.calls}"


def google_source(fake: FakeGoogle, tokens: Tokens | None = None) -> gmail.GmailSource:
    return gmail.GmailSource(tokens or Tokens(), transport=httpx.MockTransport(fake))


def test_the_gmail_source_only_gets_from_the_api() -> None:
    fake = FakeGoogle()
    source = google_source(fake)

    folders = source.list_ids(date(2026, 10, 1))
    headers = source.fetch_headers(folders[0], folders[0].remote_ids)
    raw = source.fetch_raw("INBOX", "a")
    gone = source.fetch_raw("INBOX", "b")
    source.close()

    assert [(f.folder, f.remote_ids) for f in folders] == [("inbox", ["a", "b"]), ("sent", [])]
    assert [(h.remote_id, h.headers.subject, h.size) for h in headers] == [("a", "Hello", 1234)]
    assert raw is not None and b"Subject: Hello" in raw
    assert gone is None

    for request in fake.requests:
        assert request.method == "GET"
        assert str(request.url).startswith(gmail.API_BASE + "/")
        assert request.headers["authorization"].startswith("Bearer at-")
    list_query = fake.requests[0].url.params
    assert list_query["q"] == "after:1790812800"  # 2026-10-01T00:00Z


def test_a_refused_access_token_is_asked_for_again_once() -> None:
    fake = FakeGoogle()
    fake.refuse = 1
    tokens = Tokens()
    google_source(fake, tokens).fetch_raw("INBOX", "a")

    assert [r.method for r in fake.requests] == ["GET", "GET"]
    assert [r.headers["authorization"] for r in fake.requests] == ["Bearer at-1", "Bearer at-2"]

    fake.refuse = 2
    with pytest.raises(MailError, match="reconnect the Google account"):
        google_source(fake).fetch_raw("INBOX", "a")


def test_an_account_that_must_be_reconnected_says_so() -> None:
    tokens = Tokens()
    tokens.error = MailError("The Google account needs reconnecting in Settings")

    with pytest.raises(MailError, match="needs reconnecting"):
        google_source(FakeGoogle(), tokens).list_ids(date(2026, 10, 1))


def test_gmail_is_asked_for_read_only_access() -> None:
    from app.providers import google

    assert gmail.SCOPE == "https://www.googleapis.com/auth/gmail.readonly"
    assert google.SCOPES["gmail"] == gmail.SCOPE


FORBIDDEN = [
    r"^\s*(?:import|from)\s+smtplib",
    r"\bimaplib\.IMAP4(?:_SSL)?\(.*\)\.(?!login)",
    r"""(?i)["'](?:STORE|COPY|MOVE|APPEND|EXPUNGE|DELETE|RENAME|CREATE|SELECT)\b""",
    r"_simple_command|_command\(",
    r"\.(?:store|expunge|copy|move|rename|create|delete|subscribe|setacl|setquota)\(",
    r"readonly\s*=\s*False",
    r"\.select\((?![^\n]*readonly=True)",
    r"\.(?:put|patch|delete)\(",
]


@pytest.mark.parametrize("name", sorted(p.name for p in PACKAGE.glob("*.py")))
def test_no_mailbox_changing_call_in_the_source(name: str) -> None:
    text = (PACKAGE / name).read_text()
    for pattern in FORBIDDEN:
        assert not re.search(pattern, text, re.MULTILINE), f"{name} matches {pattern}"
    # The only POSTs are this module's own browser-only routes (they change the organizer's
    # records, never a mailbox); no code posts anywhere.
    posts = re.findall(r"(?<!@router)\.post\(", text)
    assert posts == [], f"{name} posts"


def test_folder_ids_round_trip_through_json() -> None:
    # The sync stores remote ids as strings; an IMAP id keeps its UIDVALIDITY prefix.
    folder = FolderIds("inbox", "INBOX", ["77:1"])
    assert json.loads(json.dumps(folder.remote_ids)) == ["77:1"]


def test_imap_checks_the_server_certificate(monkeypatch) -> None:
    import ssl

    context = imap.tls_context()
    assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname

    seen: dict = {}

    def fake_ssl(host, port, **kwargs):
        seen.update(kwargs)
        return object()

    monkeypatch.setattr(imap.imaplib, "IMAP4_SSL", fake_ssl)
    imap.default_connect("imap.example.com", 993)
    assert seen["ssl_context"].verify_mode == ssl.CERT_REQUIRED


def test_connect_errors_read_plainly() -> None:
    import socket
    import ssl

    assert "no server called imap.example.invalid" in imap._unreachable(
        "imap.example.invalid", 993, socket.gaierror(-2, "Name or service not known")
    )
    assert "trusted certificate" in imap._unreachable(
        "imap.example.com", 993, ssl.SSLCertVerificationError("bad cert")
    )
    assert "refused" in imap._unreachable("imap.example.com", 993, ConnectionRefusedError())
