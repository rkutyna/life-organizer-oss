"""Connected accounts: a calendar, reminders or mail account the organizer reads from.

Bookkeeping, not an owned record: the encrypted credentials must not be copied into
`change_log`, so rows are written by app.providers.service only.
"""

from datetime import datetime

from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.timeutil import utcnow


class ProviderAccount(Base):
    __tablename__ = "core_provider_accounts"

    id: Mapped[int] = mapped_column(primary_key=True)
    # e.g. "caldav", "google", "imap", "apple_helper" (app.providers.service.KINDS).
    kind: Mapped[str] = mapped_column(String(32), index=True)
    label: Mapped[str] = mapped_column(String(100))
    enabled: Mapped[bool] = mapped_column(default=True)
    # Fernet token of a JSON object (app.providers.crypto); never returned by the API.
    credentials_encrypted: Mapped[str | None] = mapped_column(Text)
    # Non-secret settings as JSON text (server URL, username, which calendars to read).
    config_json: Mapped[str] = mapped_column(Text, default="{}")
    created_at: Mapped[datetime] = mapped_column(default=utcnow)
    last_sync_at: Mapped[datetime | None]
    last_error: Mapped[str | None] = mapped_column(Text)
    last_error_at: Mapped[datetime | None]
