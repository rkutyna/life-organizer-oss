"""The origin's own check on Cloudflare Access, in front of the remote MCP app.

Access is the OAuth server for the claude.ai connector (docs/MCP.md). Every request it lets
through carries a signed `Cf-Access-Jwt-Assertion`. This guard verifies that assertion (RS256
against the team's published keys, this application's AUD tag, the team issuer, expiry) and
that it names the one allowed email. Anything else gets a 401 and never reaches a tool, so a
misrouted tunnel or another process on the host can't call the organizer through this server.

It also checks the Host header against the public hostname (a 421 otherwise). The SDK's own
DNS-rebinding check is left off: it would accept only the bind address's Host, and its Origin
rule would refuse whatever Origin Claude's backend may send.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import anyio.to_thread
import jwt
from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

ASSERTION_HEADER = "cf-access-jwt-assertion"
LEEWAY_SECONDS = 30

log = logging.getLogger("organizer_mcp.access")

# Given the raw token, the public key that signed it. The default fetches the team's JWKS.
KeyResolver = Callable[[str], Any]


class AccessDenied(Exception):
    """The request carries no usable Access assertion. The message is for the log only."""


def team_issuer(team_domain: str) -> str:
    """`https://<team>.cloudflareaccess.com`, from the domain with or without a scheme."""
    host = team_domain.strip().removeprefix("https://").removeprefix("http://").rstrip("/")
    if not host:
        raise ValueError("the Cloudflare Access team domain is empty")
    return f"https://{host}"


def jwks_resolver(issuer: str) -> KeyResolver:
    """Keys from `<issuer>/cdn-cgi/access/certs`, cached, refetched on an unknown key id."""
    client = jwt.PyJWKClient(f"{issuer}/cdn-cgi/access/certs", cache_keys=True, lifespan=3600)
    return lambda token: client.get_signing_key_from_jwt(token).key


@dataclass(frozen=True)
class AccessVerifier:
    issuer: str
    audience: str
    allowed_email: str
    resolve_key: KeyResolver

    def verify(self, token: str | None) -> str:
        """The verified email, or AccessDenied. Blocking: a cache miss fetches the keys."""
        if not token:
            raise AccessDenied(f"no {ASSERTION_HEADER} header")
        try:
            key = self.resolve_key(token)
            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=self.audience,
                issuer=self.issuer,
                leeway=LEEWAY_SECONDS,
                options={"require": ["exp", "iat", "iss", "aud"]},
            )
        except jwt.PyJWTError as exc:
            raise AccessDenied(f"assertion rejected: {exc}") from exc
        email = str(claims.get("email") or "")
        if email.lower() != self.allowed_email.lower():
            raise AccessDenied("assertion is not for the allowed user")
        return email


class AccessGuard:
    """ASGI middleware: HTTP requests need the public Host and a valid assertion; lifespan
    events pass through."""

    def __init__(self, app: ASGIApp, verifier: AccessVerifier, allowed_host: str) -> None:
        self.app = app
        self.verifier = verifier
        self.allowed_host = allowed_host.lower()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "lifespan":
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        host = headers.get("host", "").lower()
        if host != self.allowed_host:
            log.warning("refused %s %s: Host %r", scope.get("method"), scope.get("path"), host)
            if scope["type"] == "http":
                await JSONResponse({"detail": "unknown host"}, status_code=421)(
                    scope, receive, send
                )
            return
        token = headers.get(ASSERTION_HEADER)
        try:
            await anyio.to_thread.run_sync(self.verifier.verify, token)
        except AccessDenied as exc:
            log.warning("refused %s %s: %s", scope.get("method"), scope.get("path"), exc)
            if scope["type"] != "http":
                return
            response = JSONResponse(
                {"detail": "Cloudflare Access assertion missing or invalid"}, status_code=401
            )
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)
