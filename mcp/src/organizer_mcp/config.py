"""Settings from the environment.

  ORGANIZER_URL         the organizer's base URL (default http://localhost:8600)
  ORGANIZER_TIMEOUT     seconds to wait for an answer (default 15)
  ORGANIZER_TOKEN       an API token with the `api` scope, for every toolset but mail
  ORGANIZER_MAIL_TOKEN  an API token with the `mail` scope, for the mail toolset only

Tokens are made in the organizer's Settings → API tokens. A token's author is fixed when it is
made, so the organizer's history shows which client wrote what: use author `claude` for Claude
Code over stdio and `claude_remote` for the claude.ai connector.
"""

from __future__ import annotations

import os
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Literal

DEFAULT_URL = "http://localhost:8600"
DEFAULT_TIMEOUT = 15.0

Scope = Literal["api", "mail"]
TOKEN_ENV = "ORGANIZER_TOKEN"
MAIL_TOKEN_ENV = "ORGANIZER_MAIL_TOKEN"
TOKEN_ENVS: dict[str, str] = {"api": TOKEN_ENV, "mail": MAIL_TOKEN_ENV}


class ConfigError(Exception):
    """A setting in the environment is unusable."""


@dataclass(frozen=True)
class Settings:
    url: str
    timeout: float
    token: str | None = None
    mail_token: str | None = None

    def token_for(self, scope: str) -> str | None:
        return self.mail_token if scope == "mail" else self.token


def missing_token_message(scope: str) -> str:
    env = TOKEN_ENVS[scope]
    return (
        f"{env} is not set: make an API token with the '{scope}' scope in the organizer's "
        f"Settings → API tokens and set it as {env} in this MCP server's environment"
    )


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    source = os.environ if env is None else env

    url = (source.get("ORGANIZER_URL") or DEFAULT_URL).strip().rstrip("/")
    if not url.startswith(("http://", "https://")):
        raise ConfigError(f"ORGANIZER_URL must start with http:// or https://, got {url!r}")

    raw_timeout = (source.get("ORGANIZER_TIMEOUT") or "").strip()
    if not raw_timeout:
        timeout = DEFAULT_TIMEOUT
    else:
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise ConfigError(
                f"ORGANIZER_TIMEOUT must be a number of seconds, got {raw_timeout!r}"
            ) from exc
        if timeout <= 0:
            raise ConfigError(f"ORGANIZER_TIMEOUT must be positive, got {raw_timeout!r}")

    return Settings(
        url=url,
        timeout=timeout,
        token=(source.get(TOKEN_ENV) or "").strip() or None,
        mail_token=(source.get(MAIL_TOKEN_ENV) or "").strip() or None,
    )


def require_tokens(settings: Settings, scopes: Iterable[str]) -> None:
    """Refuse to start when a served toolset's token is missing, rather than fail on each call."""
    for scope in sorted(set(scopes)):
        if not settings.token_for(scope):
            raise ConfigError(missing_token_message(scope))
