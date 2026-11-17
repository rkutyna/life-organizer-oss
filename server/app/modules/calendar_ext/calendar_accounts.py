"""The connected accounts this module reads calendars from, and their freshness.

- A CalDAV account is a `ProviderAccount` of kind "caldav". Its config holds the server URL, the
  username and the preset ("icloud" or "caldav"); its credentials hold the password.
- A Google account is read when it granted the calendar scope (`app.providers.google`).

Each account is its own freshness source, `calendar:<account id>`, so the calendar shows the
age of every account separately. Removed accounts lose their rows (the foreign key cascades,
and `purge_removed` catches anything left) and their freshness entry at the next sync.
"""

from dataclasses import dataclass
from datetime import timedelta
from typing import Literal

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app import freshness
from app.freshness import SourceStatus
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount

CALDAV_KIND = "caldav"
ICLOUD_URL = "https://caldav.icloud.com"
ICLOUD_NAME = "iCloud"  # what the Mac's Calendar app calls an iCloud account
FRESHNESS_PREFIX = "calendar:"
STALE_AFTER = timedelta(hours=1)

Preset = Literal["icloud", "caldav"]


@dataclass(frozen=True)
class CalendarAccount:
    account: ProviderAccount
    source: Literal["caldav", "google"]
    # The account's name as the Mac shows it, used to match the helper's copies (dedup.py).
    name: str

    @property
    def id(self) -> int:
        return self.account.id

    @property
    def label(self) -> str:
        return self.account.label

    @property
    def freshness_key(self) -> str:
        return freshness_key(self.account.id)


def freshness_key(account_id: int) -> str:
    return f"{FRESHNESS_PREFIX}{account_id}"


def caldav_preset(account: ProviderAccount) -> Preset:
    return "icloud" if accounts.config(account).get("preset") == "icloud" else "caldav"


def account_name(account: ProviderAccount) -> str:
    """The name the Mac's Calendar app would show for this account."""
    if account.kind == google.KIND:
        return google.account_email(account) or account.label
    if caldav_preset(account) == "icloud":
        return ICLOUD_NAME
    return account.label


def _is_calendar_google(account: ProviderAccount) -> bool:
    return google.SCOPES["calendar"] in google.granted_scopes(account)


def calendar_accounts(session: Session) -> list[CalendarAccount]:
    """Enabled accounts to read calendars from: CalDAV first, then Google, each by id."""
    found = [
        CalendarAccount(account, "caldav", account_name(account))
        for account in accounts.accounts(session, CALDAV_KIND, enabled_only=True)
    ]
    found += [
        CalendarAccount(account, "google", account_name(account))
        for account in google.accounts_with(session, "calendar")
    ]
    return found


def register_freshness(session: Session) -> list[CalendarAccount]:
    """Register every enabled account as a freshness source and forget the rest.

    Returns the enabled accounts. Does not commit.
    """
    current = calendar_accounts(session)
    keep = {cal.freshness_key for cal in current}
    for cal in current:
        freshness.register_source(cal.freshness_key, f"{cal.label} calendars", STALE_AFTER)
    known = set(freshness.registered_sources()) | set(
        session.scalars(
            select(SourceStatus.source).where(SourceStatus.source.startswith(FRESHNESS_PREFIX))
        )
    )
    for key in known:
        if key.startswith(FRESHNESS_PREFIX) and key not in keep:
            freshness.forget_source(session, key)
    return current


def purge_removed(session: Session) -> None:
    """Delete rows of accounts that are gone or no longer grant calendar access.

    The foreign key already cascades on delete; this also covers a Google account whose
    calendar scope was withdrawn. Rows of a disabled account stay (hidden) until it is
    re-enabled or removed. Does not commit.
    """
    kept = {a.id for a in accounts.accounts(session, CALDAV_KIND)} | {
        a.id for a in accounts.accounts(session, google.KIND) if _is_calendar_google(a)
    }
    for model in (ExternalEvent, ExternalCalendar):
        session.execute(
            delete(model).where(model.account_id.is_not(None), model.account_id.not_in(kept))
        )
