"""Synthetic mail for the tests: made-up people at example.com, no real mailbox."""

from __future__ import annotations

from datetime import UTC, date, datetime
from email.message import EmailMessage

from app.modules.mail.message import HeaderFields, parse_raw
from app.modules.mail.sources import FolderIds, RemoteHeader

SENT_AT = datetime(2026, 11, 10, 15, 0, tzinfo=UTC)
GMAIL_AUTH = "mx.google.com; dkim=pass header.i=@example.com; spf=pass; dmarc=pass"


def raw_message(
    *,
    subject: str = "Coffee next week?",
    sender: str = "Alex Example <alex@example.com>",
    to: str = "Pat Tester <pat@example.org>",
    plain: str | None = "Hi Pat,\nAre you free Tuesday?\nAlex",
    html: str | None = None,
    reply_to: str | None = None,
    authentication_results: list[str] | None = None,
    attachment: tuple[str, bytes] | None = None,
    when: datetime = SENT_AT,
) -> bytes:
    msg = EmailMessage()
    for value in authentication_results or []:
        msg["Authentication-Results"] = value
    msg["From"] = sender
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = when.strftime("%a, %d %b %Y %H:%M:%S +0000")
    msg["Message-ID"] = "<m1@example.com>"
    if reply_to:
        msg["Reply-To"] = reply_to
    if plain is not None:
        msg.set_content(plain)
    if html is not None:
        if plain is None:
            msg.set_content(html, subtype="html")
        else:
            msg.add_alternative(html, subtype="html")
    if attachment is not None:
        name, data = attachment
        msg.add_attachment(data, maintype="application", subtype="pdf", filename=name)
    return msg.as_bytes()


def header_of(raw: bytes) -> HeaderFields:
    return parse_raw(raw).headers


class FakeSource:
    """An in-memory mailbox. `folders` maps folder -> {remote_id: raw bytes}."""

    def __init__(
        self,
        account_id: int = 0,
        folders: dict[str, dict[str, bytes]] | None = None,
        trusted: tuple[str, ...] = ("mx.google.com",),
    ) -> None:
        self.account_id = account_id
        self.trusted_auth_servers = trusted
        self.folders = folders if folders is not None else {"inbox": {}, "sent": {}}
        self.header_fetches: list[list[str]] = []
        self.raw_fetches: list[str] = []
        self.closed = 0
        self.fail: Exception | None = None

    def _mailbox(self, folder: str) -> str:
        return "INBOX" if folder == "inbox" else "Sent Messages"

    def list_ids(self, since: date) -> list[FolderIds]:
        if self.fail:
            raise self.fail
        return [FolderIds(f, self._mailbox(f), list(ids)) for f, ids in self.folders.items()]

    def fetch_headers(self, folder: FolderIds, remote_ids: list[str]) -> list[RemoteHeader]:
        self.header_fetches.append(list(remote_ids))
        out = []
        for rid in remote_ids:
            raw = self.folders[folder.folder].get(rid)
            if raw is None:
                continue
            out.append(
                RemoteHeader(folder.folder, folder.mailbox, rid, header_of(raw), len(raw), None)
            )
        return out

    def fetch_raw(self, mailbox: str, remote_id: str) -> bytes | None:
        self.raw_fetches.append(remote_id)
        for folder, ids in self.folders.items():
            if self._mailbox(folder) == mailbox and remote_id in ids:
                return ids[remote_id]
        return None

    def close(self) -> None:
        self.closed += 1
