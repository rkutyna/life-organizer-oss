"""Sync every connected calendar account: the background poll and "Sync now" both run this."""

import logging
from dataclasses import dataclass

from sqlalchemy.orm import Session

from app.config import Settings
from app.modules.calendar_ext import caldav_sync, google_sync
from app.modules.calendar_ext.calendar_accounts import (
    CalendarAccount,
    purge_removed,
    register_freshness,
)

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class AccountSyncOutcome:
    account_id: int
    ok: bool
    events: int
    error: str | None


def sync_one(session: Session, settings: Settings, cal: CalendarAccount) -> AccountSyncOutcome:
    """Sync one account. A failure is recorded on it and reported, never raised."""
    try:
        if cal.source == "google":
            result = google_sync.sync_account(session, settings, cal.account)
        else:
            result = caldav_sync.sync_account(session, settings, cal.account)
    except Exception as exc:
        log.warning("calendar account %s failed to sync: %s", cal.id, type(exc).__name__)
        return AccountSyncOutcome(cal.id, False, 0, str(exc) or type(exc).__name__)
    return AccountSyncOutcome(cal.id, True, result.events, None)


def sync_all(session: Session, settings: Settings) -> list[AccountSyncOutcome]:
    """Forget removed accounts, then sync each enabled one in turn (one failing never stops
    the others)."""
    current = register_freshness(session)
    purge_removed(session)
    session.commit()
    return [sync_one(session, settings, cal) for cal in current]
