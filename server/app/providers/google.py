"""Google accounts: one OAuth consent per Google account, shared by every feature that reads it.

A Google account is a `ProviderAccount` with kind "google". Its config holds the address and
the scopes granted; its encrypted credentials hold the tokens:

    config      {"email": "someone@example.com", "scopes": ["https://www.googleapis.com/..."]}
    credentials {"refresh_token": "...", "access_token": "...", "expires_at": "<ISO UTC>"}

A feature module (calendar, mail, reminders) never runs the OAuth flow itself. It asks for the
accounts that granted its scope and for a fresh access token:

    from app.providers import google

    for account in google.accounts_with(session, "calendar"):
        try:
            token = google.access_token(session, settings, account)
        except google.GoogleAuthError:
            continue        # already marked as failing; the owner must reconnect it
        ...httpx.get(url, headers={"Authorization": f"Bearer {token}"})...

In tests, create an account with `app.providers.service.create(kind="google", ...)` and
monkeypatch `google.access_token`.

The consent flow (Settings → Add account → Google: `POST /api/settings/google/start`, then the
public callback `GET /api/oauth/google/callback`) and the token refresh are being built in core;
until they land, `access_token` raises `NotImplementedError`.
"""

from typing import Literal

from sqlalchemy.orm import Session

from app.config import Settings
from app.providers import service as accounts
from app.providers.models import ProviderAccount

KIND = "google"

Feature = Literal["calendar", "gmail", "tasks"]

# Read-only wherever the feature allows it. Tasks needs write access: reminders are two-way.
SCOPES: dict[str, str] = {
    "calendar": "https://www.googleapis.com/auth/calendar.readonly",
    "gmail": "https://www.googleapis.com/auth/gmail.readonly",
    "tasks": "https://www.googleapis.com/auth/tasks",
}
# Always asked for, to learn which Google account was connected.
IDENTITY_SCOPES = ("openid", "email")


class GoogleAuthError(Exception):
    """The account's grant no longer works (revoked, expired). It must be reconnected."""


def granted_scopes(account: ProviderAccount) -> list[str]:
    return list(accounts.config(account).get("scopes", []))


def account_email(account: ProviderAccount) -> str:
    return str(accounts.config(account).get("email", ""))


def accounts_with(session: Session, feature: Feature) -> list[ProviderAccount]:
    """Enabled Google accounts that granted `feature`'s scope."""
    scope = SCOPES[feature]
    return [
        account
        for account in accounts.accounts(session, KIND, enabled_only=True)
        if scope in granted_scopes(account)
    ]


def access_token(session: Session, settings: Settings, account: ProviderAccount) -> str:
    """A valid access token for `account`, refreshed when it is about to expire.

    Raises `GoogleAuthError` (after marking the account as failing) when Google refuses the
    refresh token.
    """
    raise NotImplementedError("Google OAuth is being built in core; monkeypatch this in tests")
