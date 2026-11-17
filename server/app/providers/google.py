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

The consent flow is in `app.providers.google_router`: Settings → Add account → Google calls
`POST /api/settings/google/start`, the browser goes to Google, and Google sends it back to the
public `GET /api/oauth/google/callback`, which this module's `complete_consent` finishes.
Each install uses its owner's own OAuth client (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET).
"""

import base64
import hashlib
import json
import secrets
from collections.abc import Callable
from datetime import datetime, timedelta
from typing import Any, Literal
from urllib.parse import urlencode

import httpx
from sqlalchemy import String, Text, delete, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.config import Settings
from app.db import Base
from app.providers import service as accounts
from app.providers.models import ProviderAccount
from app.timeutil import utcnow

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

AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo"
REVOKE_URL = "https://oauth2.googleapis.com/revoke"
CALLBACK_PATH = "/api/oauth/google/callback"

STATE_TTL = timedelta(minutes=15)
# Refresh an access token this long before Google says it expires.
EXPIRY_MARGIN = timedelta(seconds=90)
TIMEOUT = httpx.Timeout(20.0)

# Tests replace this to talk to an httpx.MockTransport instead of Google.
make_client: Callable[[], httpx.Client] = lambda: httpx.Client(timeout=TIMEOUT)  # noqa: E731


class GoogleAuthError(Exception):
    """The account's grant no longer works (revoked, expired). It must be reconnected."""


class ConsentError(Exception):
    """The consent flow failed. The message is for the API and logs; `code` is what the
    Settings page is told after Google's redirect, so that page only ever shows its own words."""

    def __init__(self, message: str, code: str = "failed") -> None:
        super().__init__(message)
        self.code = code


class OAuthState(Base):
    """A consent flow in progress: one row per click on "Continue to Google". Single use.

    Bookkeeping, not an owned record. Only the state's hash is stored; the PKCE verifier is
    useless without the authorization code, which only Google's redirect carries.
    """

    __tablename__ = "core_oauth_states"

    state_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    provider: Mapped[str] = mapped_column(String(32))
    code_verifier: Mapped[str] = mapped_column(String(128))
    redirect_uri: Mapped[str] = mapped_column(Text)
    scopes: Mapped[str] = mapped_column(Text)  # space-separated, as requested
    created_at: Mapped[datetime] = mapped_column(default=utcnow)


# --------------------------------------------------------------------------- for features


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
    refresh token. Network failures raise httpx errors: transient, nothing is marked.
    """
    creds = accounts.credentials(settings, account)
    expires_at = creds.get("expires_at")
    fresh = expires_at and datetime.fromisoformat(expires_at) - EXPIRY_MARGIN > utcnow()
    if creds.get("access_token") and fresh:
        return creds["access_token"]
    refresh = creds.get("refresh_token")
    if not refresh:
        _fail(session, account, "no refresh token stored; reconnect this Google account")
    with make_client() as client:
        response = client.post(
            TOKEN_URL,
            data={
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": settings.google_client_id,
                "client_secret": settings.google_client_secret.get_secret_value(),
            },
        )
    if response.status_code in (400, 401):
        error = _error_code(response)
        _fail(session, account, f"Google refused the saved sign-in ({error}); reconnect it")
    response.raise_for_status()
    body = response.json()
    creds["access_token"] = body["access_token"]
    creds["expires_at"] = _expiry(body).isoformat()
    accounts.set_credentials(session, settings, account, creds)
    return creds["access_token"]


# --------------------------------------------------------------------------- consent flow


def is_configured(settings: Settings) -> bool:
    return bool(settings.google_client_id and settings.google_client_secret.get_secret_value())


def redirect_uri(settings: Settings, request_base_url: str) -> str:
    base = (settings.public_base_url or request_base_url).rstrip("/")
    return f"{base}{CALLBACK_PATH}"


def start_consent(
    session: Session, settings: Settings, features: list[Feature], redirect: str
) -> str:
    """Record a new consent flow and return Google's authorization URL to send the browser to."""
    if not is_configured(settings):
        raise ConsentError("set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in .env first")
    if not features:
        raise ConsentError("choose at least one thing to read")
    scopes = " ".join([*IDENTITY_SCOPES, *(SCOPES[f] for f in sorted(set(features)))])
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=")
    _prune_states(session)
    session.add(
        OAuthState(
            state_hash=_hash(state),
            provider=KIND,
            code_verifier=verifier,
            redirect_uri=redirect,
            scopes=scopes,
        )
    )
    session.commit()
    query = {
        "client_id": settings.google_client_id,
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": scopes,
        "state": state,
        "code_challenge": challenge.decode(),
        "code_challenge_method": "S256",
        # A refresh token on every consent, so reconnecting an account always repairs it.
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "true",
    }
    return f"{AUTHORIZE_URL}?{urlencode(query)}"


def complete_consent(
    session: Session, settings: Settings, state: str, code: str
) -> ProviderAccount:
    """Finish a consent flow: exchange the code, then create or update the Google account."""
    row = session.get(OAuthState, _hash(state))
    if row is None or row.provider != KIND:
        raise ConsentError("this sign-in link is unknown or was already used; start again", "state")
    session.delete(row)  # single use, whatever happens next
    session.commit()
    if utcnow() - row.created_at > STATE_TTL:
        raise ConsentError("the sign-in took too long; start again", "expired")

    with make_client() as client:
        token_response = client.post(
            TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": row.code_verifier,
                "redirect_uri": row.redirect_uri,
                "client_id": settings.google_client_id,
                "client_secret": settings.google_client_secret.get_secret_value(),
            },
        )
        if token_response.status_code != 200:
            raise ConsentError(
                f"Google did not accept the sign-in ({_error_code(token_response)})", "rejected"
            )
        tokens = token_response.json()
        info = client.get(
            USERINFO_URL, headers={"Authorization": f"Bearer {tokens['access_token']}"}
        )
        if info.status_code != 200:
            raise ConsentError("could not read which Google account this is", "identity")
        email = str(info.json().get("email") or "")
    if not email:
        raise ConsentError("Google did not say which account this is", "identity")

    granted = sorted(set(tokens.get("scope", row.scopes).split()))
    creds: dict[str, Any] = {
        "access_token": tokens["access_token"],
        "expires_at": _expiry(tokens).isoformat(),
    }
    existing = _account_for(session, email)
    if existing is not None:
        old = accounts.credentials(settings, existing)
        creds["refresh_token"] = tokens.get("refresh_token") or old.get("refresh_token")
        config = accounts.config(existing)
        config["scopes"] = sorted(set(config.get("scopes", [])) | set(granted))
        existing.config_json = _dumps(config)
        existing.enabled = True
        existing.last_error = None
        existing.last_error_at = None
        accounts.set_credentials(session, settings, existing, creds)  # commits
        return existing
    if not tokens.get("refresh_token"):
        raise ConsentError(
            "Google sent no refresh token; remove this app's access in your Google account "
            "settings and try again",
            "no_refresh_token",
        )
    creds["refresh_token"] = tokens["refresh_token"]
    return accounts.create(
        session,
        settings,
        kind=KIND,
        label=email,
        credentials=creds,
        config={"email": email, "scopes": granted},
    )


def revoke(settings: Settings, account: ProviderAccount) -> None:
    """Best effort: tell Google to drop the grant (when the owner removes the account)."""
    try:
        token = accounts.credentials(settings, account).get("refresh_token")
        if token:
            with make_client() as client:
                client.post(REVOKE_URL, data={"token": token})
    except Exception:  # noqa: BLE001 - removing the account must not depend on Google
        pass


# --------------------------------------------------------------------------- internals


def _fail(session: Session, account: ProviderAccount, message: str):
    accounts.mark_error(session, account, message)
    raise GoogleAuthError(message)


def _error_code(response: httpx.Response) -> str:
    try:
        return str(response.json().get("error") or response.status_code)
    except ValueError:
        return str(response.status_code)


def _expiry(token_body: dict[str, Any]) -> datetime:
    return utcnow() + timedelta(seconds=int(token_body.get("expires_in", 3600)))


def _hash(state: str) -> str:
    return hashlib.sha256(state.encode()).hexdigest()


def _prune_states(session: Session) -> None:
    session.execute(delete(OAuthState).where(OAuthState.created_at < utcnow() - STATE_TTL))


def _account_for(session: Session, email: str) -> ProviderAccount | None:
    for account in session.scalars(select(ProviderAccount).where(ProviderAccount.kind == KIND)):
        if account_email(account).lower() == email.lower():
            return account
    return None


def _dumps(data: dict[str, Any]) -> str:
    return json.dumps(data, sort_keys=True)
