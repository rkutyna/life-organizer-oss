"""Where reminders come from, and each source's freshness.

- Apple Reminders: the Mac helper's pushes, freshness source `reminders` (HELPER_SOURCE).
- Google Tasks: every enabled Google account that granted the Tasks scope
  (`app.providers.google.accounts_with(session, "tasks")`). Each account is its own freshness
  source, `reminders:<account id>`, so the page shows the age of every account separately.
  Removed accounts lose their rows (the foreign key cascades, and `purge_removed` catches a
  withdrawn scope) and their freshness entry at the next sync.
"""

from datetime import timedelta

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app import freshness
from app.freshness import SourceStatus
from app.modules.reminders.models import Reminder, ReminderList
from app.providers import google
from app.providers import service as provider_accounts
from app.providers.models import ProviderAccount

HELPER_SOURCE = "reminders"
HELPER_LABEL = "Mac helper (Apple Reminders)"
HELPER_STALE_AFTER = timedelta(minutes=45)
FRESHNESS_PREFIX = "reminders:"
GOOGLE_STALE_AFTER = timedelta(minutes=30)

freshness.register_source(HELPER_SOURCE, HELPER_LABEL, stale_after=HELPER_STALE_AFTER)


def freshness_key(account_id: int) -> str:
    return f"{FRESHNESS_PREFIX}{account_id}"


def account_name(account: ProviderAccount) -> str:
    return google.account_email(account) or account.label


def tasks_accounts(session: Session) -> list[ProviderAccount]:
    """Enabled Google accounts that granted Tasks, by id."""
    return google.accounts_with(session, "tasks")


def label_freshness(current: list[ProviderAccount]) -> None:
    """Name each account's freshness source. The registry lives in memory, so reads call this
    too: a restarted server knows the names before its first poll."""
    for account in current:
        freshness.register_source(
            freshness_key(account.id), f"{account.label} tasks", GOOGLE_STALE_AFTER
        )


def register_freshness(session: Session) -> list[ProviderAccount]:
    """Register every Tasks account as a freshness source and forget the rest. Does not commit."""
    current = tasks_accounts(session)
    keep = {freshness_key(account.id) for account in current}
    label_freshness(current)
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
    """Delete Google rows of accounts that are gone or no longer grant Tasks.

    Rows of a disabled account stay (hidden) until it is re-enabled or removed. Does not commit.
    """
    kept = {
        account.id
        for account in provider_accounts.accounts(session, google.KIND)
        if google.SCOPES["tasks"] in google.granted_scopes(account)
    }
    for model in (Reminder, ReminderList):
        session.execute(
            delete(model).where(
                model.source == "google",
                model.account_id.is_not(None),
                model.account_id.not_in(kept),
            )
        )
