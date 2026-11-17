"""The header mirror: every 15 minutes, each connected mail account's Inbox and Sent headers for
the last MAIL_WINDOW_DAYS.

Mail accounts are connected accounts (`core_provider_accounts`): every enabled "imap" account,
and every enabled "google" account that granted Gmail (app.providers.google.accounts_with).

A run lists the ids in the window, drops rows whose message is gone (deleted, moved, or older
than the window), and fetches headers only for ids it has not seen, so a steady mailbox costs one
listing per run. A failed run changes nothing and records the error. Bodies are never fetched
here.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.mail.gmail import GmailSource
from app.modules.mail.imap import Connect, ImapSource, default_connect
from app.modules.mail.models import MailMessage
from app.modules.mail.presets import IMAP_PRESETS
from app.modules.mail.sources import MailError, MailSource
from app.providers import crypto, google
from app.providers import service as accounts
from app.providers.models import ProviderAccount
from app.timeutil import to_local, utcnow

IMAP_KIND = "imap"
STALE_AFTER = timedelta(hours=1)
MailKind = Literal["imap", "gmail"]


@dataclass(frozen=True)
class MailAccount:
    id: int
    kind: MailKind
    label: str
    address: str
    record: ProviderAccount


def freshness_key(account_id: int) -> str:
    return f"mail_{account_id}"


def _address(record: ProviderAccount) -> str:
    if record.kind == google.KIND:
        return google.account_email(record)
    return str(accounts.config(record).get("username", ""))


def mail_accounts(session: Session) -> list[MailAccount]:
    """The enabled mail accounts, each registered as a freshness source."""
    records = accounts.accounts(session, IMAP_KIND, enabled_only=True)
    records += google.accounts_with(session, "gmail")
    out = []
    for record in sorted(records, key=lambda r: r.id):
        kind: MailKind = "gmail" if record.kind == google.KIND else "imap"
        account = MailAccount(record.id, kind, record.label, _address(record), record)
        freshness.register_source(freshness_key(record.id), f"Mail: {record.label}", STALE_AFTER)
        out.append(account)
    return out


def mail_account(session: Session, account_id: int) -> MailAccount | None:
    return next((a for a in mail_accounts(session) if a.id == account_id), None)


def imap_trusted_servers(config: dict) -> tuple[str, ...]:
    preset = IMAP_PRESETS.get(str(config.get("preset", "")))
    if preset is not None and preset.host == config.get("host"):
        return preset.auth_servers
    return tuple(str(s) for s in config.get("auth_servers", []) if s)


# How a sync or a read reaches a mailbox. Tests pass fakes.
SourceFactory = Callable[[Session, Settings, MailAccount], MailSource | None]


def build_source(
    session: Session,
    settings: Settings,
    account: MailAccount,
    *,
    connect: Connect = default_connect,
    transport=None,
) -> MailSource | None:
    """The real source for an account. Raises MailError when its credentials cannot be read."""
    if account.kind == "gmail":

        def token() -> str:
            try:
                return google.access_token(session, settings, account.record)
            except google.GoogleAuthError as exc:
                raise MailError(
                    f"The Google account needs reconnecting in Settings ({exc})"
                ) from None

        return GmailSource(token, transport=transport)
    config = accounts.config(account.record)
    try:
        password = str(accounts.credentials(settings, account.record).get("password", ""))
    except (crypto.CredentialsUnreadable, crypto.CryptoUnavailable) as exc:
        raise MailError(str(exc)) from None
    host = str(config.get("host", ""))
    if not host or not password:
        return None
    return ImapSource(
        str(config.get("username", "")),
        password,
        host,
        int(config.get("port", 993)),
        imap_trusted_servers(config),
        connect=connect,
    )


@dataclass(frozen=True)
class MailSyncResult:
    listed: int
    added: int
    removed: int


def sync_account(
    session: Session,
    settings: Settings,
    account: MailAccount,
    *,
    factory: SourceFactory = build_source,
    now: datetime | None = None,
) -> MailSyncResult | None:
    """Refresh one account's headers. None when the account is missing its settings."""
    key = freshness_key(account.id)
    try:
        source = factory(session, settings, account)
    except MailError as exc:
        _failed(session, account, key, str(exc))
        raise
    if source is None:
        _failed(session, account, key, "not configured")
        return None
    now = now or utcnow()
    since = to_local(now).date() - timedelta(days=settings.mail_window_days)
    try:
        folders = source.list_ids(since)
        existing = {
            (row.folder, row.remote_id): row
            for row in session.scalars(
                select(MailMessage).where(MailMessage.account_id == account.id)
            )
        }
        listed = {(f.folder, rid) for f in folders for rid in f.remote_ids}
        gone = [row.id for k, row in existing.items() if k not in listed]
        if gone:
            session.execute(delete(MailMessage).where(MailMessage.id.in_(gone)))
        added = 0
        for folder in folders:
            new = [rid for rid in folder.remote_ids if (folder.folder, rid) not in existing]
            if not new:
                continue
            for remote in source.fetch_headers(folder, new):
                h = remote.headers
                session.add(
                    MailMessage(
                        account_id=account.id,
                        folder=remote.folder,
                        mailbox=remote.mailbox,
                        remote_id=remote.remote_id,
                        message_id=h.message_id,
                        in_reply_to=h.in_reply_to,
                        from_name=h.from_name,
                        from_address=h.from_address,
                        to=h.to,
                        cc=h.cc,
                        subject=h.subject,
                        sent_at=h.sent_at or remote.received or now,
                        size=remote.size,
                        sender_warning=h.sender_warning,
                        received_at=now,
                    )
                )
                added += 1
        freshness.mark_success(session, key, at=now)  # commits
        if account.kind == "imap":
            # The mail module owns IMAP accounts, so Settings shows their status from here. A
            # Google account is shared with other features; core records its auth failures.
            accounts.mark_success(session, account.record)
    except Exception as exc:
        session.rollback()
        message = str(exc) if isinstance(exc, MailError) else f"{type(exc).__name__}: {exc}"
        _failed(session, account, key, message)
        raise
    finally:
        source.close()
    return MailSyncResult(listed=len(listed), added=added, removed=len(gone))


def _failed(session: Session, account: MailAccount, key: str, message: str) -> None:
    freshness.mark_error(session, key, message)
    if account.kind == "imap":
        accounts.mark_error(session, account.record, message)


def prune_removed_accounts(session: Session, active: list[MailAccount]) -> int:
    """Drop the mirrored headers of accounts that were removed or disabled. Commits."""
    keep = [a.id for a in active]
    result = session.execute(delete(MailMessage).where(MailMessage.account_id.not_in(keep)))
    session.commit()
    return int(result.rowcount or 0)  # type: ignore[attr-defined]


def sync_all(
    session: Session, settings: Settings, *, factory: SourceFactory = build_source
) -> dict[int, str]:
    """Sync every mail account, one after another; one failing does not stop the others.
    Returns the errors by account id."""
    active = mail_accounts(session)
    prune_removed_accounts(session, active)
    errors: dict[int, str] = {}
    for account in active:
        try:
            sync_account(session, settings, account, factory=factory)
        except Exception as exc:  # recorded by sync_account
            errors[account.id] = str(exc)
    return errors
