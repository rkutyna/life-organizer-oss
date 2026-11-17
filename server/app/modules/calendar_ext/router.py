"""/api/calendar_ext: the calendars shown, grouped by account; connecting CalDAV; sync now.

- `GET /calendars`: every shown calendar with its key and color, grouped by account, with each
  account's freshness. The web app toggles items by `meta.calendar_key`.
- `POST /accounts/caldav`: connect an iCloud or other CalDAV account. The login is tested
  before anything is saved. Signed-in browser only, like all account management.
- `POST /sync`: poll every account now instead of waiting for the next run.
"""

import logging
from typing import Literal
from urllib.parse import urlsplit

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session, sessionmaker

from app import freshness
from app.auth.principal import require_browser
from app.config import Settings
from app.db import session_scope
from app.deps import SessionDep, SettingsDep
from app.modules.calendar_ext import caldav_sync, catalog
from app.modules.calendar_ext.calendar_accounts import (
    CALDAV_KIND,
    ICLOUD_NAME,
    ICLOUD_URL,
    calendar_accounts,
    register_freshness,
)
from app.modules.calendar_ext.sync import sync_all
from app.providers import crypto
from app.providers import service as accounts

log = logging.getLogger(__name__)

router = APIRouter()


# --------------------------------------------------------------------------- calendars


class CalendarOut(BaseModel):
    key: str = Field(description="Matches CalendarItem.meta.calendar_key")
    title: str
    color: str


class CalendarGroupOut(BaseModel):
    account_id: int | None = Field(description="None for the Mac helper's own calendars")
    label: str
    kind: str = Field(description="caldav, google or eventkit")
    freshness: freshness.SourceStatusOut
    calendars: list[CalendarOut]


@router.get("/calendars", response_model=list[CalendarGroupOut])
def list_calendars(session: SessionDep) -> list[CalendarGroupOut]:
    """Every calendar the calendar shows, grouped by account, each account with its age."""
    shown = catalog.build(session, calendar_accounts(session))
    return [
        CalendarGroupOut(
            account_id=group.account_id,
            label=group.label,
            kind=group.kind,
            freshness=freshness.source_status(session, group.freshness_key),
            calendars=[CalendarOut(**vars(c)) for c in group.calendars],
        )
        for group in shown.groups
    ]


# --------------------------------------------------------------------------- sync now


class SyncOutcomeOut(BaseModel):
    account_id: int
    ok: bool
    events: int
    error: str | None


@router.post("/sync", response_model=list[SyncOutcomeOut])
def sync_now(session: SessionDep, settings: SettingsDep) -> list[SyncOutcomeOut]:
    """Poll every enabled calendar account now. Failures are reported per account."""
    return [SyncOutcomeOut(**vars(outcome)) for outcome in sync_all(session, settings)]


# --------------------------------------------------------------------------- connect CalDAV


class CalDAVConnectIn(BaseModel):
    preset: Literal["icloud", "caldav"] = Field(
        description="icloud: the server is iCloud's; caldav: any server, at `url`"
    )
    label: str | None = Field(default=None, max_length=100)
    url: str | None = Field(default=None, max_length=1000, description="caldav preset only")
    username: str = Field(min_length=1, max_length=500)
    password: str = Field(min_length=1, max_length=500)


class CalDAVAccountOut(BaseModel):
    id: int
    label: str
    calendars: int = Field(description="Event calendars found when the login was tested")


def _server_url(payload: CalDAVConnectIn) -> str:
    if payload.preset == "icloud":
        return ICLOUD_URL
    url = (payload.url or "").strip()
    parts = urlsplit(url)
    if parts.scheme not in ("https", "http") or not parts.hostname:
        raise HTTPException(400, "Enter the server's full address, starting with https://")
    if parts.username or parts.password:
        raise HTTPException(400, "Put the username and password in their own fields, not the URL")
    return url


def _login_error(payload: CalDAVConnectIn, exc: Exception) -> str:
    if isinstance(exc, caldav_sync.LoginFailed):
        if payload.preset == "icloud":
            return (
                "Apple refused the sign-in. Check the Apple ID, and use an app-specific "
                "password (not your Apple ID password)."
            )
        return "The server refused the username or password."
    detail = (str(exc) or type(exc).__name__).replace(payload.password, "***")
    return f"Could not read calendars from the server: {detail}"


@router.post(
    "/accounts/caldav",
    response_model=CalDAVAccountOut,
    status_code=201,
    dependencies=[Depends(require_browser)],
)
def connect_caldav(
    payload: CalDAVConnectIn,
    request: Request,
    background: BackgroundTasks,
    session: SessionDep,
    settings: SettingsDep,
) -> CalDAVAccountOut:
    """Test the login, then save the account and sync it in the background."""
    url = _server_url(payload)
    username = payload.username.strip()
    for existing in accounts.accounts(session, CALDAV_KIND):
        config = accounts.config(existing)
        same_user = str(config.get("username", "")).casefold() == username.casefold()
        if same_user and str(config.get("url", "")).rstrip("/") == url.rstrip("/"):
            raise HTTPException(409, f'This account is already connected as "{existing.label}"')

    source = caldav_sync.connect(url, username, payload.password)
    try:
        found = source.calendars()
    except Exception as exc:
        raise HTTPException(400, _login_error(payload, exc)) from None

    default_label = ICLOUD_NAME if payload.preset == "icloud" else urlsplit(url).hostname or url
    try:
        account = accounts.create(
            session,
            settings,
            kind=CALDAV_KIND,
            label=(payload.label or "").strip() or default_label,
            credentials={"password": payload.password},
            config={"preset": payload.preset, "url": url, "username": username},
        )
    except crypto.CryptoUnavailable as exc:
        raise HTTPException(503, str(exc)) from None
    register_freshness(session)
    session.commit()

    background.add_task(
        _first_sync, request.app.state.session_factory, settings, account.id, source
    )
    return CalDAVAccountOut(id=account.id, label=account.label, calendars=len(found))


def _first_sync(
    factory: sessionmaker[Session],
    settings: Settings,
    account_id: int,
    source: caldav_sync.CalDAVSource,
) -> None:
    """Sync a new account right away, reusing the client that tested its login."""
    with session_scope(factory) as session:
        cal = next((c for c in calendar_accounts(session) if c.id == account_id), None)
        if cal is None:
            return
        try:
            caldav_sync.sync_account(session, settings, cal.account, source=source)
        except Exception as exc:  # recorded on the account; the next poll retries
            log.warning("first sync of calendar account %s failed: %s", account_id, exc)
