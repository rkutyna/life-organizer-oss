"""/api/mail: the mirrored headers, one message read live, and connecting an IMAP account.

`app.main` mounts this behind the `mail` scope: a signed-in browser has it, and an API token has
it only if it was made for mail, so a token for Claude's general tools cannot read mail.
Connecting an account and "sync now" are browser-only (`require_browser`); they change the
organizer's own records, never a mailbox. Nothing here can send, move, flag or delete mail.

Every response carries `untrusted: true`: subjects, names, bodies and attachment names are all
written by whoever sent the mail. A read fetches the message from the mailbox (bodies are never
stored), cleans it (sanitize.py) and adds warnings for what a reader should distrust: a From
line that may not be the sender, a sender DMARC does not verify, hidden or uninterpretable
content, and replies that go somewhere else.
"""

from __future__ import annotations

import contextlib
from datetime import date, datetime, time, timedelta
from typing import Annotated, Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy import select

from app import freshness
from app.auth.principal import require_browser
from app.config import Settings
from app.db import session_scope
from app.deps import SessionDep, SettingsDep
from app.modules.mail.imap import IMAP_PORT, Connect, ImapSource, default_connect
from app.modules.mail.message import parse_raw, sender_checks
from app.modules.mail.models import MailMessage
from app.modules.mail.presets import CUSTOM, IMAP_PRESETS
from app.modules.mail.sanitize import render_body
from app.modules.mail.sources import MAX_RAW_BYTES, MailError
from app.modules.mail.sync import (
    IMAP_KIND,
    MailAccount,
    SourceFactory,
    build_source,
    freshness_key,
    mail_account,
    mail_accounts,
    sync_account,
)
from app.providers import crypto
from app.providers.service import create as save_account
from app.timeutil import combine_local

UNTRUSTED = Field(True, description="Always true: mail text is written by whoever sent it")
SCAN_LIMIT = 5000  # rows a text search looks through (about a month of mail, several accounts)

router = APIRouter()
browser_only = [Depends(require_browser)]


def get_source_factory() -> SourceFactory:
    """How a read or a sync reaches a mailbox. The real sources in production; tests override."""
    return build_source


def get_imap_connect() -> Connect:
    """How connecting an IMAP account opens the connection it tests. Tests override it."""
    return default_connect


SourceFactoryDep = Annotated[SourceFactory, Depends(get_source_factory)]
ImapConnectDep = Annotated[Connect, Depends(get_imap_connect)]
Folder = Literal["inbox", "sent"]


class MailAddress(BaseModel):
    name: str
    address: str


class MailAccountOut(BaseModel):
    id: int = Field(description="The connected account's id (Settings, Connected accounts)")
    kind: Literal["imap", "gmail"]
    label: str
    address: str
    state: freshness.FreshnessState
    as_of: datetime | None = Field(description="The last successful header sync (UTC)")
    error: str | None


class MailMessageOut(BaseModel):
    id: int
    account: int = Field(description="The account's id (see accounts)")
    folder: Folder
    sender: MailAddress = Field(alias="from")
    sender_warning: str | None = Field(
        description="Why the From line may not be the real sender; null when nothing is odd"
    )
    to: list[MailAddress]
    cc: list[MailAddress]
    subject: str
    date: datetime
    size: int | None
    message_id: str | None
    in_reply_to: str | None
    untrusted: bool = UNTRUSTED

    model_config = {"populate_by_name": True}


class MailMessageList(BaseModel):
    accounts: list[MailAccountOut]
    messages: list[MailMessageOut]
    untrusted: bool = UNTRUSTED


class MailAttachment(BaseModel):
    filename: str
    content_type: str
    size: int


class MailSenderChecks(BaseModel):
    verified: bool = Field(
        description="DMARC passed for the From address's own domain: the only case where the "
        "From address is known to be real"
    )
    spf: str | None = None
    dkim: str | None = None
    dmarc: str | None = None
    dmarc_from: str | None = Field(None, description="The domain DMARC checked (header.from)")


class MailRemoved(BaseModel):
    hidden_chars: int = Field(description="Characters of text styled not to show, taken out")
    invisible_chars: int = Field(description="Invisible characters taken out")


class MailMessageDetail(MailMessageOut):
    reply_to: list[MailAddress]
    body: str
    body_source: Literal["html", "plain", "mixed", "none"] = Field(
        description="html: HTML converted to the text a mail app shows; plain: a text part; "
        "mixed: several displayed parts"
    )
    truncated: bool
    attachments: list[MailAttachment] = Field(description="Names, types and sizes only")
    sender_checks: MailSenderChecks | None = Field(
        description="As the receiving server recorded them; null when it recorded none"
    )
    removed: MailRemoved = Field(
        description="What the cleaner took out before serving the body; common in newsletters "
        "(hidden preview text), so counted rather than warned about"
    )
    warnings: list[str]


class MailImapPreset(BaseModel):
    key: str
    label: str
    host: str
    port: int
    help: str


class MailImapConnect(BaseModel):
    preset: str = Field(CUSTOM, description='A preset key, or "custom"')
    label: str = Field(min_length=1, max_length=100)
    username: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=1000)
    host: str | None = Field(None, max_length=253, description="Custom only; presets set it")
    port: int = Field(IMAP_PORT, ge=1, le=65535, description="Custom only; implicit TLS")
    auth_servers: list[str] = Field(
        default_factory=list,
        max_length=10,
        description="Custom only: the receiving servers whose Authentication-Results headers "
        "can be believed (e.g. mx.example.com). Empty: sender checks read as unknown.",
    )


class MailSyncOut(BaseModel):
    listed: int
    added: int
    removed: int


def _account_out(session: SessionDep, account: MailAccount) -> MailAccountOut:
    status = freshness.source_status(session, freshness_key(account.id))
    return MailAccountOut(
        id=account.id,
        kind=account.kind,
        label=account.label,
        address=account.address,
        state=status.state,
        as_of=status.last_success_at,
        error=status.last_error,
    )


def _out(row: MailMessage) -> MailMessageOut:
    return MailMessageOut(
        id=row.id,
        account=row.account_id,
        folder=row.folder,  # type: ignore[arg-type]
        sender=MailAddress(name=row.from_name, address=row.from_address),
        sender_warning=row.sender_warning,
        to=[MailAddress(**a) for a in row.to or []],
        cc=[MailAddress(**a) for a in row.cc or []],
        subject=row.subject,
        date=row.sent_at,
        size=row.size,
        message_id=row.message_id,
        in_reply_to=row.in_reply_to,
    )


def _people(row: MailMessage) -> list[dict[str, str]]:
    return [{"name": row.from_name, "address": row.from_address}, *(row.to or []), *(row.cc or [])]


def _matches(row: MailMessage, q: str | None, sender: str | None) -> bool:
    """Plain substring matching, any case and any script (so % and _ are just characters)."""
    if sender:
        who = f"{row.from_name}\n{row.from_address}".casefold()
        if sender not in who:
            return False
    if q:
        texts = [row.subject] + [
            f"{p.get('name', '')}\n{p.get('address', '')}" for p in _people(row)
        ]
        if not any(q in text.casefold() for text in texts):
            return False
    return True


@router.get("/accounts", response_model=list[MailAccountOut])
def list_accounts(session: SessionDep) -> list[MailAccountOut]:
    """Each connected mail account and how fresh its header mirror is."""
    return [_account_out(session, a) for a in mail_accounts(session)]


@router.get("/imap-presets", response_model=list[MailImapPreset])
def list_imap_presets() -> list[MailImapPreset]:
    """Providers whose IMAP settings are known (the connect form's choices)."""
    return [
        MailImapPreset(key=p.key, label=p.label, host=p.host, port=p.port, help=p.help)
        for p in IMAP_PRESETS.values()
    ]


def _sync_in_background(request: Request, account_id: int, factory: SourceFactory) -> None:
    settings: Settings = request.app.state.settings
    with session_scope(request.app.state.session_factory) as session:
        account = mail_account(session, account_id)
        if account is None:
            return
        # A failure is recorded in freshness and on the account, where Settings shows it.
        with contextlib.suppress(Exception):
            sync_account(session, settings, account, factory=factory)


@router.post(
    "/accounts/imap", response_model=MailAccountOut, status_code=201, dependencies=browser_only
)
def connect_imap(
    payload: MailImapConnect,
    request: Request,
    background: BackgroundTasks,
    session: SessionDep,
    settings: SettingsDep,
    connect: ImapConnectDep,
    factory: SourceFactoryDep,
) -> MailAccountOut:
    """Connect an IMAP account: tests the login (read-only) before anything is saved, stores the
    password encrypted, and starts the first header sync."""
    preset = IMAP_PRESETS.get(payload.preset)
    if preset is None and payload.preset != CUSTOM:
        raise HTTPException(422, f"unknown preset {payload.preset!r}")
    if preset is not None:
        host, port, auth_servers = preset.host, preset.port, list(preset.auth_servers)
    else:
        host = (payload.host or "").strip().lower()
        port = payload.port
        auth_servers = [s.strip().lower() for s in payload.auth_servers if s.strip()]
        if not host or any(c in host for c in " /:@\r\n\0"):
            raise HTTPException(422, "enter the IMAP server's host name, e.g. imap.example.com")
    username = payload.username.strip()
    source = ImapSource(username, payload.password, host, port, (), connect=connect)
    try:
        source.check()
    except MailError as exc:
        raise HTTPException(400, f"Could not sign in to {host}: {exc}") from None
    finally:
        source.close()
    config = {"preset": payload.preset, "host": host, "port": port, "username": username}
    if preset is None:
        config["auth_servers"] = auth_servers
    try:
        record = save_account(
            session,
            settings,
            kind=IMAP_KIND,
            label=payload.label,
            credentials={"password": payload.password},
            config=config,
        )
    except crypto.CryptoUnavailable as exc:
        raise HTTPException(503, str(exc)) from None
    background.add_task(_sync_in_background, request, record.id, factory)
    account = mail_account(session, record.id)
    assert account is not None
    return _account_out(session, account)


@router.post("/accounts/{account_id}/sync", response_model=MailSyncOut, dependencies=browser_only)
def sync_now(
    account_id: int, session: SessionDep, settings: SettingsDep, factory: SourceFactoryDep
) -> MailSyncOut:
    """Refresh one account's headers now (reads the mailbox; changes nothing in it)."""
    account = mail_account(session, account_id)
    if account is None:
        raise HTTPException(404, f"no mail account {account_id}")
    try:
        result = sync_account(session, settings, account, factory=factory)
    except MailError as exc:
        raise HTTPException(502, str(exc)) from None
    if result is None:
        raise HTTPException(503, f"mail account {account_id} is missing its settings")
    return MailSyncOut(listed=result.listed, added=result.added, removed=result.removed)


@router.get("/messages", response_model=MailMessageList, response_model_by_alias=True)
def list_messages(
    session: SessionDep,
    account: int | None = Query(None, description="An account id (see accounts)"),
    folder: Folder | None = None,
    since: date | None = Query(None, description="Local date, inclusive"),
    until: date | None = Query(None, description="Local date, inclusive"),
    q: str | None = Query(None, description="Matches subject, sender or recipients, any case"),
    sender: str | None = Query(None, description="Matches the sender's name or address"),
    limit: int = Query(50, ge=1, le=200),
) -> MailMessageList:
    """Mirrored headers, newest first. Never touches a mailbox."""
    active = mail_accounts(session)
    stmt = select(MailMessage).where(MailMessage.account_id.in_([a.id for a in active]))
    if account is not None:
        stmt = stmt.where(MailMessage.account_id == account)
    if folder:
        stmt = stmt.where(MailMessage.folder == folder)
    if since:
        stmt = stmt.where(MailMessage.sent_at >= combine_local(since, time.min))
    if until:
        stmt = stmt.where(MailMessage.sent_at < combine_local(until + timedelta(days=1), time.min))
    stmt = stmt.order_by(MailMessage.sent_at.desc(), MailMessage.id.desc())
    q_key = q.strip().casefold() if q and q.strip() else None
    sender_key = sender.strip().casefold() if sender and sender.strip() else None
    if q_key is None and sender_key is None:
        rows = list(session.scalars(stmt.limit(limit)))
    else:
        rows = []
        for row in session.scalars(stmt.limit(SCAN_LIMIT)):
            if _matches(row, q_key, sender_key):
                rows.append(row)
                if len(rows) >= limit:
                    break
    return MailMessageList(
        accounts=[_account_out(session, a) for a in active], messages=[_out(r) for r in rows]
    )


def _domain(address: str) -> str:
    return address.rsplit("@", 1)[-1].lower() if "@" in address else ""


def _verified(row: MailMessage, checks: dict[str, str] | None) -> bool:
    if not checks or checks.get("dmarc") != "pass":
        return False
    domain = _domain(row.from_address)
    return bool(domain) and checks.get("dmarc_from") == domain


def _warnings(row: MailMessage, reply_to: list[dict[str, str]], checks: dict | None) -> list[str]:
    warnings = [row.sender_warning] if row.sender_warning else []
    domain = _domain(row.from_address) or "unknown"
    if row.folder == "inbox" and not _verified(row, checks):
        dmarc = (checks or {}).get("dmarc")
        if checks is None:
            warnings.append(
                "The sender could not be verified (the receiving server recorded no SPF, DKIM "
                "or DMARC result): the From address may not be who sent it."
            )
        elif dmarc == "pass":
            warnings.append(
                f"DMARC passed for {checks.get('dmarc_from') or 'another domain'}, not for the "
                f"From address's domain ({domain}): the From address may be forged."
            )
        elif dmarc not in ("fail", "quarantine", "reject"):  # none, bestguesspass, temperror...
            warnings.append(
                f"The sender's domain ({domain}) could not be verified "
                f"(DMARC {dmarc or 'absent'}): the From address may be forged."
            )
        else:
            warnings.append(f"DMARC {dmarc} for {domain}: this message is probably forged.")
    sender_domain = _domain(row.from_address)
    elsewhere = sorted(
        {
            a["address"]
            for a in reply_to
            if a.get("address") and _domain(a["address"]) != sender_domain
        }
    )
    if elsewhere:
        warnings.append(f"Replies go to {', '.join(elsewhere)}, not the sender's domain.")
    return warnings


@router.get(
    "/messages/{message_id}", response_model=MailMessageDetail, response_model_by_alias=True
)
def read_message(
    message_id: int,
    session: SessionDep,
    settings: SettingsDep,
    factory: SourceFactoryDep,
) -> MailMessageDetail:
    """One message, fetched from its mailbox now and cleaned. The mailbox is not changed (it is
    not even marked read)."""
    row = session.get(MailMessage, message_id)
    account = mail_account(session, row.account_id) if row is not None else None
    if row is None or account is None:
        raise HTTPException(404, f"no mirrored mail message {message_id}")
    too_big = row.size is not None and row.size > MAX_RAW_BYTES
    if account.kind == "gmail" and too_big:
        raise HTTPException(
            413,
            f"message {message_id} is over {MAX_RAW_BYTES // (1024 * 1024)} MB; open it in Gmail",
        )
    try:
        source = factory(session, settings, account)
    except MailError as exc:
        raise HTTPException(502, str(exc)) from None
    if source is None:
        raise HTTPException(503, f"mail account {account.id} is missing its settings")
    try:
        raw = source.fetch_raw(row.mailbox, row.remote_id)
    except MailError as exc:
        raise HTTPException(502, str(exc)) from None
    finally:
        source.close()
    if raw is None:
        raise HTTPException(410, f"message {message_id} is no longer in mail account {account.id}")
    parsed = parse_raw(raw)
    body = render_body(parsed.body_parts)
    checks = sender_checks(parsed.authentication_results, source.trusted_auth_servers)
    base = _out(row)
    return MailMessageDetail(
        **base.model_dump(by_alias=False),
        reply_to=[MailAddress(**a) for a in parsed.reply_to],
        body=body.text,
        body_source=body.source,  # type: ignore[arg-type]
        truncated=body.truncated,
        attachments=[MailAttachment(**a) for a in parsed.attachments],  # type: ignore[arg-type]
        sender_checks=(
            MailSenderChecks(verified=_verified(row, checks), **checks)
            if checks is not None
            else None
        ),
        removed=MailRemoved(hidden_chars=body.hidden_chars, invisible_chars=body.invisible_chars),
        warnings=_warnings(row, parsed.reply_to, checks) + body.warnings,
    )
