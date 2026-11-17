"""Sync every Google Tasks account: the background poll and "Sync now" both run this.

Pending Google ops are retried first (a network error left them pending), then each account
is polled, so the snapshot already carries what the retries changed.
"""

import logging
from dataclasses import dataclass

from sqlalchemy.orm import Session

from app.config import Settings
from app.modules.reminders import google_tasks
from app.modules.reminders.accounts import purge_removed, register_freshness

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class AccountSyncOutcome:
    account_id: int
    ok: bool
    lists: int
    reminders: int
    error: str | None


def sync_all(session: Session, settings: Settings) -> list[AccountSyncOutcome]:
    """Forget removed accounts, retry pending ops, then poll each enabled account in turn
    (one failing never stops the others)."""
    current = register_freshness(session)
    purge_removed(session)
    session.commit()
    try:
        google_tasks.apply_pending(session, settings)
    except Exception as exc:  # never stop the poll; each op records its own outcome
        session.rollback()
        log.warning("reminders: retrying Google ops failed: %s", type(exc).__name__)
    outcomes = []
    for account in current:
        try:
            result = google_tasks.sync_account(session, settings, account)
        except Exception as exc:
            log.warning("tasks account %s failed to sync: %s", account.id, type(exc).__name__)
            outcomes.append(
                AccountSyncOutcome(account.id, False, 0, 0, str(exc) or type(exc).__name__)
            )
            continue
        outcomes.append(AccountSyncOutcome(account.id, True, result.lists, result.reminders, None))
    return outcomes
