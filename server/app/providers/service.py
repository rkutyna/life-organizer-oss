"""Connected accounts: create, read credentials, record sync results.

A feature module (calendar, mail, reminders) adds its own connect flow and calls these:

    from app.providers import service as accounts

    account = accounts.create(session, settings, kind="imap", label="Personal mail",
                              credentials={"password": "..."},
                              config={"host": "imap.example.com", "username": "me@example.com"})
    creds = accounts.credentials(settings, account)        # decrypted dict
    accounts.mark_success(session, account)                # commits
    accounts.mark_error(session, account, "login failed")  # commits

Credentials never appear in logs, errors or API output.
"""

import json
from typing import Any, Literal

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.providers import crypto
from app.providers.models import ProviderAccount
from app.timeutil import utcnow

AccountStatus = Literal["ok", "error", "never", "disabled"]


def create(
    session: Session,
    settings: Settings,
    *,
    kind: str,
    label: str,
    credentials: dict[str, Any] | None,
    config: dict[str, Any] | None = None,
) -> ProviderAccount:
    key = settings.organizer_secret_key.get_secret_value()
    account = ProviderAccount(
        kind=kind,
        label=label.strip(),
        credentials_encrypted=crypto.encrypt(key, credentials) if credentials else None,
        config_json=json.dumps(config or {}, sort_keys=True),
    )
    session.add(account)
    session.commit()
    return account


def credentials(settings: Settings, account: ProviderAccount) -> dict[str, Any]:
    if account.credentials_encrypted is None:
        return {}
    return crypto.decrypt(
        settings.organizer_secret_key.get_secret_value(), account.credentials_encrypted
    )


def set_credentials(
    session: Session, settings: Settings, account: ProviderAccount, data: dict[str, Any]
) -> None:
    account.credentials_encrypted = crypto.encrypt(
        settings.organizer_secret_key.get_secret_value(), data
    )
    session.commit()


def config(account: ProviderAccount) -> dict[str, Any]:
    return json.loads(account.config_json or "{}")


def accounts(session: Session, kind: str | None = None, *, enabled_only: bool = False):
    stmt = select(ProviderAccount).order_by(ProviderAccount.id)
    if kind is not None:
        stmt = stmt.where(ProviderAccount.kind == kind)
    if enabled_only:
        stmt = stmt.where(ProviderAccount.enabled.is_(True))
    return list(session.scalars(stmt))


def status(account: ProviderAccount) -> AccountStatus:
    if not account.enabled:
        return "disabled"
    if account.last_error_at and (
        account.last_sync_at is None or account.last_error_at > account.last_sync_at
    ):
        return "error"
    if account.last_sync_at is None:
        return "never"
    return "ok"


def mark_success(session: Session, account: ProviderAccount) -> None:
    account.last_sync_at = utcnow()
    account.last_error = None
    account.last_error_at = None
    session.commit()


def mark_error(session: Session, account: ProviderAccount, message: str) -> None:
    account.last_error = message[:2000]
    account.last_error_at = utcnow()
    session.commit()
