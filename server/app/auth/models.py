"""Tables for the install's owner, browser sessions and API tokens.

Bookkeeping, not owned records: they hold password and token hashes, which must never be
copied into `change_log`, so they are written directly by `app.auth.service`.
"""

from datetime import datetime

from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.timeutil import utcnow


class AppConfig(Base):
    """The one row (id 1) describing this install and its owner. Absent until setup."""

    __tablename__ = "core_config"

    id: Mapped[int] = mapped_column(primary_key=True)
    display_name: Mapped[str] = mapped_column(String(100))
    timezone: Mapped[str] = mapped_column(String(64))
    # ISO 3166 code for the holidays calendar source; None turns it off.
    holiday_country: Mapped[str | None] = mapped_column(String(8))
    password_hash: Mapped[str] = mapped_column(Text)
    password_changed_at: Mapped[datetime] = mapped_column(default=utcnow)
    setup_completed_at: Mapped[datetime] = mapped_column(default=utcnow)


class AuthSession(Base):
    """A signed-in browser. The cookie holds a random secret; only its SHA-256 is stored."""

    __tablename__ = "core_sessions"

    id: Mapped[int] = mapped_column(primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    created_at: Mapped[datetime] = mapped_column(default=utcnow)
    last_seen_at: Mapped[datetime] = mapped_column(default=utcnow)
    user_agent: Mapped[str | None] = mapped_column(String(300))


class ApiToken(Base):
    """A credential for a non-browser client (MCP server, Mac helper, native app).

    The author is fixed when the token is made, so a client can never write as someone else.
    """

    __tablename__ = "core_api_tokens"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    author: Mapped[str] = mapped_column(String(16))
    # Comma-separated, e.g. "api" or "api,mail" (app.auth.principal.SCOPES).
    scopes: Mapped[str] = mapped_column(String(100))
    # The first characters of the secret, shown so the owner can tell tokens apart.
    prefix: Mapped[str] = mapped_column(String(16))
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    created_at: Mapped[datetime] = mapped_column(default=utcnow)
    last_used_at: Mapped[datetime | None]
    revoked_at: Mapped[datetime | None]
