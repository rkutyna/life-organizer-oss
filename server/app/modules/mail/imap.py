"""Any IMAP mailbox (iCloud, Fastmail, Outlook or a custom host), read-only.

IMAP has no read-only login: the (app-specific) password could move, flag or delete mail, and
the same password usually works for SMTP. So read-only is enforced here, in one narrow class:

- `ReadOnlyIMAP` is the only code that talks to the server, and it can send exactly these
  commands: LOGIN, LIST, EXAMINE (imaplib's select(readonly=True)), UID SEARCH SINCE, two fixed
  UID FETCH item lists that use BODY.PEEK (so nothing is even marked read), and LOGOUT. There is
  no STORE, COPY, MOVE, APPEND, EXPUNGE or SELECT, and nothing in this module imports smtplib.
- tests/test_mail_readonly.py records every command against a fake server and fails on anything
  else, and scans this package's source for the forbidden calls.
"""

from __future__ import annotations

import contextlib
import imaplib
import re
from collections.abc import Callable
from datetime import date, datetime
from typing import Any

from app.modules.mail.message import HEADER_FIELDS, parse_headers
from app.modules.mail.sources import MAX_RAW_BYTES, FolderIds, MailError, RemoteHeader

IMAP_PORT = 993
TIMEOUT_SECONDS = 30
FETCH_CHUNK = 200
SENT_NAMES = ("Sent Messages", "Sent", "Sent Items", "Sent Mail")

_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
HEADER_ITEMS = (
    "(UID RFC822.SIZE INTERNALDATE BODY.PEEK[HEADER.FIELDS (" + " ".join(HEADER_FIELDS) + ")])"
)
RAW_ITEMS = f"(UID BODY.PEEK[]<0.{MAX_RAW_BYTES}>)"

_LIST_LINE = re.compile(rb'^\((?P<flags>[^)]*)\) (?:"[^"]*"|NIL) (?P<name>.+)$')
_UID = re.compile(rb"\bUID (\d+)")
_SIZE = re.compile(rb"\bRFC822\.SIZE (\d+)")
_INTERNALDATE = re.compile(rb'\bINTERNALDATE "([^"]+)"')


def imap_date(day: date) -> str:
    """IMAP's date format (RFC 3501), with English month names whatever the locale."""
    return f"{day.day:02d}-{_MONTHS[day.month - 1]}-{day.year}"


def _quote(mailbox: str) -> str:
    if any(c in mailbox for c in "\r\n\0"):
        raise MailError("refusing a mailbox name with a line break in it")
    return '"' + mailbox.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _check(typ: str, data: Any, what: str) -> Any:
    if typ != "OK":
        detail = data[0].decode(errors="replace") if data and isinstance(data[0], bytes) else ""
        raise MailError(f"IMAP {what} failed: {detail or typ}")
    return data


class ReadOnlyIMAP:
    """The only object that sends IMAP commands. Each method is one fixed, read-only command."""

    def __init__(self, conn: Any) -> None:
        self._conn = conn
        self._examined: str | None = None
        self._uidvalidity: str | None = None

    def login(self, username: str, password: str) -> None:
        try:
            self._conn.login(username, password)
        except imaplib.IMAP4.error as exc:
            raise MailError(f"IMAP login failed: {exc}") from None

    def mailboxes(self) -> list[tuple[str, set[str]]]:
        """(name, flags) of every mailbox."""
        data = _check(*self._conn.list(), "LIST")
        out = []
        for line in data:
            if not isinstance(line, bytes):
                continue
            match = _LIST_LINE.match(line)
            if not match:
                continue
            name = match.group("name").decode("utf-8", errors="replace").strip()
            if name.startswith('"') and name.endswith('"'):
                name = name[1:-1].replace('\\"', '"').replace("\\\\", "\\")
            flags = {f.decode().lower() for f in match.group("flags").split()}
            out.append((name, flags))
        return out

    def examine(self, mailbox: str) -> str:
        """Open a mailbox read-only (EXAMINE) and return its UIDVALIDITY."""
        if self._examined == mailbox and self._uidvalidity is not None:
            return self._uidvalidity
        _check(*self._conn.select(_quote(mailbox), readonly=True), f"EXAMINE {mailbox}")
        _, values = self._conn.response("UIDVALIDITY")
        value = values[0].decode() if values and isinstance(values[0], bytes) else ""
        self._examined, self._uidvalidity = mailbox, value
        return value

    def search_since(self, day: date) -> list[str]:
        data = _check(*self._conn.uid("SEARCH", "SINCE", imap_date(day)), "UID SEARCH")
        found = data[0].decode(errors="replace").split() if data and data[0] else []
        return [uid for uid in found if _UID_TEXT.match(uid)]  # never a range like 1:*

    def fetch_headers(self, uids: list[str]) -> list[tuple[bytes, bytes]]:
        return _records(_check(*self._conn.uid("FETCH", _uid_set(uids), HEADER_ITEMS), "FETCH"))

    def fetch_raw(self, uid: str) -> list[tuple[bytes, bytes]]:
        return _records(_check(*self._conn.uid("FETCH", _uid_set([uid]), RAW_ITEMS), "FETCH"))

    def logout(self) -> None:
        with contextlib.suppress(Exception):  # already gone; nothing to clean up
            self._conn.logout()


_UID_TEXT = re.compile(r"^[0-9]{1,10}$")


def _uid_set(uids: list[str]) -> str:
    """UIDs for a FETCH line: digits only, so nothing else can reach the command."""
    if not uids or not all(_UID_TEXT.match(uid) for uid in uids):
        raise MailError("refusing a UID that is not a number")
    return ",".join(uids)


def _records(data: list[Any]) -> list[tuple[bytes, bytes]]:
    """(item text, literal) per message from a FETCH response. Items a server sends after the
    literal arrive as a separate bytes element and are joined to that message's item text."""
    records: list[list[bytes]] = []
    for element in data:
        if isinstance(element, tuple) and len(element) == 2:
            records.append([element[0], element[1]])
        elif isinstance(element, bytes) and records:
            records[-1][0] += element
    return [(meta, literal) for meta, literal in records]


def _received(meta: bytes) -> datetime | None:
    match = _INTERNALDATE.search(meta)
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1).decode(), "%d-%b-%Y %H:%M:%S %z")
    except ValueError:
        return None


Connect = Callable[[str, int], Any]


def default_connect(host: str, port: int) -> Any:
    """Implicit TLS only (port 993 by default): the password never crosses the network in clear."""
    return imaplib.IMAP4_SSL(host, port, timeout=TIMEOUT_SECONDS)


class ImapSource:
    def __init__(
        self,
        username: str,
        password: str,
        host: str,
        port: int = IMAP_PORT,
        trusted_auth_servers: tuple[str, ...] = (),
        connect: Connect = default_connect,
    ) -> None:
        self._username = username
        self._password = password
        self._host = host
        self._port = port
        self._connect = connect
        self._imap: ReadOnlyIMAP | None = None
        # The receiving servers whose Authentication-Results headers can be believed (the
        # preset's, or what the owner entered). Empty: sender checks always read as unknown,
        # never as a header the sender wrote.
        self.trusted_auth_servers = trusted_auth_servers

    def _session(self) -> ReadOnlyIMAP:
        if self._imap is None:
            try:
                conn = self._connect(self._host, self._port)
            except (OSError, imaplib.IMAP4.error) as exc:
                raise MailError(f"IMAP unreachable at {self._host}:{self._port}: {exc}") from None
            imap = ReadOnlyIMAP(conn)
            imap.login(self._username, self._password)
            self._imap = imap
        return self._imap

    def _folders(self) -> list[tuple[str, str]]:
        names = self._session().mailboxes()
        sent = next((n for n, flags in names if "\\sent" in flags), None)
        if sent is None:
            present = {n for n, _ in names}
            sent = next((n for n in SENT_NAMES if n in present), None)
        folders = [("inbox", "INBOX")]
        if sent is not None:
            folders.append(("sent", sent))
        return folders

    def check(self) -> list[str]:
        """Log in, list the mailboxes and open the Inbox read-only: what connecting an account
        tests before it is saved. Returns the folders the mirror will read."""
        imap = self._session()
        folders = self._folders()
        imap.examine("INBOX")
        return [mailbox for _, mailbox in folders]

    def list_ids(self, since: date) -> list[FolderIds]:
        imap = self._session()
        out = []
        for folder, mailbox in self._folders():
            validity = imap.examine(mailbox)
            uids = imap.search_since(since)
            out.append(FolderIds(folder, mailbox, [f"{validity}:{uid}" for uid in uids]))
        return out

    def fetch_headers(self, folder: FolderIds, remote_ids: list[str]) -> list[RemoteHeader]:
        imap = self._session()
        validity = imap.examine(folder.mailbox)
        uids = [
            rid.split(":", 1)[1]
            for rid in remote_ids
            if rid.split(":", 1)[0] == validity and _UID_TEXT.match(rid.split(":", 1)[1])
        ]
        out = []
        for start in range(0, len(uids), FETCH_CHUNK):
            for meta, literal in imap.fetch_headers(uids[start : start + FETCH_CHUNK]):
                uid = _UID.search(meta)
                if not uid:
                    continue
                size = _SIZE.search(meta)
                out.append(
                    RemoteHeader(
                        folder=folder.folder,
                        mailbox=folder.mailbox,
                        remote_id=f"{validity}:{uid.group(1).decode()}",
                        headers=parse_headers(literal),
                        size=int(size.group(1)) if size else None,
                        received=_received(meta),
                    )
                )
        return out

    def fetch_raw(self, mailbox: str, remote_id: str) -> bytes | None:
        validity, _, uid = remote_id.partition(":")
        if not _UID_TEXT.match(uid):
            return None
        imap = self._session()
        if imap.examine(mailbox) != validity:
            return None  # the mailbox was rebuilt; its old UIDs mean nothing now
        records = imap.fetch_raw(uid)
        return records[0][1] if records else None

    def close(self) -> None:
        if self._imap is not None:
            self._imap.logout()
            self._imap = None
