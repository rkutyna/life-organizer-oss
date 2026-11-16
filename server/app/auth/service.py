"""Setup, passwords, sessions and tokens: the logic behind app.auth.router."""

import threading
import time
from collections import deque
from zoneinfo import ZoneInfo, available_timezones

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.auth.models import ApiToken, AppConfig, AuthSession
from app.auth.principal import hash_secret, new_secret
from app.timeutil import set_timezone, utcnow

MIN_PASSWORD_LENGTH = 10
CONFIG_ID = 1

_hasher = PasswordHasher()


def load_config(session: Session) -> AppConfig | None:
    return session.get(AppConfig, CONFIG_ID)


def apply_timezone(session: Session) -> None:
    """Point app.timeutil at the configured time zone (startup and after a change)."""
    config = load_config(session)
    set_timezone(config.timezone if config else None)


def valid_timezone(name: str) -> bool:
    return name in available_timezones()


def check_password_strength(password: str) -> None:
    if len(password) < MIN_PASSWORD_LENGTH:
        raise ValueError(f"the password needs at least {MIN_PASSWORD_LENGTH} characters")


def setup(
    session: Session,
    *,
    display_name: str,
    password: str,
    timezone: str,
    holiday_country: str | None,
) -> AppConfig:
    """Create the owner. Raises `PermissionError` if setup already happened."""
    if load_config(session) is not None:
        raise PermissionError("this organizer is already set up")
    check_password_strength(password)
    ZoneInfo(timezone)  # raises for an unknown zone
    config = AppConfig(
        id=CONFIG_ID,
        display_name=display_name.strip(),
        timezone=timezone,
        holiday_country=holiday_country,
        password_hash=_hasher.hash(password),
    )
    session.add(config)
    session.commit()
    set_timezone(timezone)
    return config


def verify_password(config: AppConfig, password: str) -> bool:
    try:
        _hasher.verify(config.password_hash, password)
    except (VerificationError, InvalidHashError):
        return False
    return True


def change_password(
    session: Session, config: AppConfig, new_password: str, keep_session_id: int
) -> None:
    """Set a new password and sign out every other browser."""
    check_password_strength(new_password)
    config.password_hash = _hasher.hash(new_password)
    config.password_changed_at = utcnow()
    session.execute(delete(AuthSession).where(AuthSession.id != keep_session_id))
    session.commit()


def start_session(session: Session, user_agent: str | None) -> str:
    """Create a browser session and return the cookie's secret (stored only as a hash)."""
    raw = new_secret("ses")
    session.add(AuthSession(token_hash=hash_secret(raw), user_agent=(user_agent or "")[:300]))
    session.commit()
    return raw


def end_session(session: Session, session_id: int) -> None:
    session.execute(delete(AuthSession).where(AuthSession.id == session_id))
    session.commit()


def create_token(
    session: Session, name: str, author: str, scopes: list[str]
) -> tuple[ApiToken, str]:
    """Make an API token. Returns the row and the secret, which is never retrievable again."""
    raw = new_secret("org")
    token = ApiToken(
        name=name.strip(),
        author=author,
        scopes=",".join(sorted(set(scopes))),
        prefix=raw[:12],
        token_hash=hash_secret(raw),
    )
    session.add(token)
    session.commit()
    return token, raw


def list_tokens(session: Session) -> list[ApiToken]:
    return list(session.scalars(select(ApiToken).order_by(ApiToken.id)))


def revoke_token(session: Session, token: ApiToken) -> None:
    if token.revoked_at is None:
        token.revoked_at = utcnow()
        session.commit()


class LoginThrottle:
    """Refuses logins after repeated failures: per client address, and overall.

    In memory, so a restart clears it; that is acceptable for one owner and one process.
    """

    PER_CLIENT = (5, 15 * 60)  # failures, window in seconds
    OVERALL = (30, 60 * 60)

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._by_client: dict[str, deque[float]] = {}
        self._overall: deque[float] = deque()

    @staticmethod
    def _prune(entries: deque[float], window: int, now: float) -> None:
        while entries and now - entries[0] > window:
            entries.popleft()

    def retry_after(self, client: str) -> int | None:
        """Seconds until a login may be tried again, or None if it may be tried now."""
        now = time.monotonic()
        with self._lock:
            waits = []
            for entries, (limit, window) in (
                (self._by_client.get(client, deque()), self.PER_CLIENT),
                (self._overall, self.OVERALL),
            ):
                self._prune(entries, window, now)
                if len(entries) >= limit:
                    waits.append(int(window - (now - entries[0])) + 1)
            return max(waits) if waits else None

    def failed(self, client: str) -> None:
        now = time.monotonic()
        with self._lock:
            self._by_client.setdefault(client, deque()).append(now)
            self._overall.append(now)

    def succeeded(self, client: str) -> None:
        with self._lock:
            self._by_client.pop(client, None)
