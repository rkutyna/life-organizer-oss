"""What the sync and the reads need from a mailbox, whichever provider holds it.

The real sources are imap.ImapSource and gmail.GmailSource. Tests pass fakes and never reach a
mail server. A source only reads: the protocol has no method that could change a mailbox, and
each implementation is built so it cannot (docs/MAIL.md, "Read-only").
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from typing import Protocol

from app.modules.mail.message import HeaderFields

# The most of one message a read downloads. IMAP fetches only this many bytes; a Gmail message
# whose size is over it is refused. Attachments are what make a message big, and they are never
# returned, so a cut message still has its text.
MAX_RAW_BYTES = 10 * 1024 * 1024


class MailError(Exception):
    """A mailbox could not be read. The message is safe to show (no credentials in it)."""


@dataclass(frozen=True)
class FolderIds:
    folder: str  # "inbox" or "sent"
    mailbox: str  # the provider's name for it
    remote_ids: list[str]


@dataclass(frozen=True)
class RemoteHeader:
    folder: str
    mailbox: str
    remote_id: str
    headers: HeaderFields
    size: int | None
    # When the mailbox received it; the fallback when the Date header is missing or bad.
    received: datetime | None


class MailSource(Protocol):
    # The receiving servers whose Authentication-Results headers can be believed.
    trusted_auth_servers: tuple[str, ...]

    def list_ids(self, since: date) -> list[FolderIds]:
        """Every message in Inbox and Sent received on or after `since`."""
        ...

    def fetch_headers(self, folder: FolderIds, remote_ids: list[str]) -> list[RemoteHeader]:
        """Header fields of some of a folder's messages. A message gone meanwhile is skipped."""
        ...

    def fetch_raw(self, mailbox: str, remote_id: str) -> bytes | None:
        """The message's raw bytes (at most MAX_RAW_BYTES), or None if it is no longer there."""
        ...

    def close(self) -> None: ...
