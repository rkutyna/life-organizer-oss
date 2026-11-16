"""Who is making a request, and the dependencies that enforce it.

Every `/api/*` route needs a principal except the few public auth routes and `/api/health`.
`app.main` applies the guards when it mounts routers; a module never adds its own.

- A browser authenticates with the session cookie. A cookie-authenticated request that changes
  something (POST, PUT, PATCH, DELETE) must also carry `X-Requested-With: organizer`. A page on
  another site cannot add that header without a CORS preflight, which this server never
  grants, so the header is the CSRF guard. Its author is `me`.
- Any other client sends `Authorization: Bearer <token>` (an `ApiToken`). Its author and scopes
  are the token's.

Scopes:
- `api`: the REST API, every module except mail.
- `ingest`: the Mac helper's `/api/ingest/*` pushes, and nothing else.
- `mail`: `/api/mail/*`. Kept apart so a token for Claude's general tools cannot read mail.

A browser session has `api` and `mail`, never `ingest`. Only a browser session may manage the
account (`require_browser`): no token can mint tokens or change the password.
"""

import hashlib
import secrets
from dataclasses import dataclass
from datetime import timedelta
from typing import Annotated, Literal

from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth.models import ApiToken, AuthSession
from app.timeutil import utcnow

Scope = Literal["api", "ingest", "mail"]
SCOPES: tuple[Scope, ...] = ("api", "ingest", "mail")
TOKEN_AUTHORS = ("me", "claude", "claude_remote", "helper")

COOKIE_NAME = "organizer_session"
CSRF_HEADER = "X-Requested-With"
CSRF_VALUE = "organizer"
UNSAFE_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
SESSION_SCOPES: frozenset[str] = frozenset({"api", "mail"})

# last_seen_at / last_used_at are written at most this often, so reads stay reads.
TOUCH_EVERY = timedelta(minutes=5)


@dataclass(frozen=True)
class Principal:
    kind: Literal["session", "token"]
    author: str
    scopes: frozenset[str]
    record_id: int


def hash_secret(secret: str) -> str:
    """SHA-256 of a high-entropy secret (session cookie or API token)."""
    return hashlib.sha256(secret.encode()).hexdigest()


def new_secret(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(32)}"


def check_csrf(request: Request) -> None:
    if request.method in UNSAFE_METHODS and request.headers.get(CSRF_HEADER) != CSRF_VALUE:
        raise HTTPException(403, f"missing {CSRF_HEADER}: {CSRF_VALUE} header")


def _db(request: Request) -> Session:
    return request.app.state.session_factory()


def session_from_cookie(request: Request, db: Session) -> AuthSession | None:
    """The live browser session the request's cookie names, or None."""
    raw = request.cookies.get(COOKIE_NAME)
    if not raw:
        return None
    row = db.scalar(select(AuthSession).where(AuthSession.token_hash == hash_secret(raw)))
    if row is None:
        return None
    idle = timedelta(days=request.app.state.settings.session_idle_days)
    now = utcnow()
    if now - row.last_seen_at > idle:
        db.delete(row)
        db.commit()
        return None
    if now - row.last_seen_at > TOUCH_EVERY:
        row.last_seen_at = now
        db.commit()
    return row


def _token(db: Session, raw: str) -> ApiToken | None:
    row = db.scalar(select(ApiToken).where(ApiToken.token_hash == hash_secret(raw)))
    if row is None or row.revoked_at is not None:
        return None
    now = utcnow()
    if row.last_used_at is None or now - row.last_used_at > TOUCH_EVERY:
        row.last_used_at = now
        db.commit()
    return row


def current_principal(
    request: Request,
    authorization: Annotated[
        str | None, Header(description="Bearer <API token>, for non-browser clients")
    ] = None,
) -> Principal:
    """The request's principal, or 401."""
    with _db(request) as db:
        if authorization:
            scheme, _, raw = authorization.partition(" ")
            token = _token(db, raw.strip()) if scheme.lower() == "bearer" and raw else None
            if token is None:
                raise HTTPException(401, "invalid or revoked API token")
            return Principal(
                kind="token",
                author=token.author,
                scopes=frozenset(s for s in token.scopes.split(",") if s),
                record_id=token.id,
            )
        browser = session_from_cookie(request, db)
        if browser is None:
            raise HTTPException(401, "not signed in")
        check_csrf(request)
        return Principal(kind="session", author="me", scopes=SESSION_SCOPES, record_id=browser.id)


PrincipalDep = Annotated[Principal, Depends(current_principal)]


def _require_scope(scope: Scope):
    def guard(principal: PrincipalDep) -> Principal:
        if scope not in principal.scopes:
            raise HTTPException(403, f"this credential lacks the '{scope}' scope")
        return principal

    guard.__name__ = f"require_{scope}"
    return guard


require_api = _require_scope("api")
require_ingest = _require_scope("ingest")
require_mail = _require_scope("mail")


def require_browser(principal: PrincipalDep) -> Principal:
    """Account management: a signed-in browser only, never an API token."""
    if principal.kind != "session":
        raise HTTPException(403, "only a signed-in browser can do this")
    return principal


def get_author(principal: PrincipalDep) -> str:
    """The audit author for the request's writes, from its credential."""
    return principal.author
