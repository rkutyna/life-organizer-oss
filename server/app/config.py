"""Deployment settings, read from the environment and `server/.env`.

These are the things only the person running the server can decide (where the database lives,
the encryption key, cookies). Everything a user changes from the web app (display name, time
zone, holidays) lives in the database instead (`app.auth.models.AppConfig`).

Use `get_settings()` everywhere; never read `os.environ` directly. Tests build their own
`Settings(...)` and pass it to `create_app(settings)`.
"""

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Relative SQLite paths resolve against the working directory (`server/` in dev).
    database_url: str = "sqlite:///./data/organizer.db"

    # Encrypts connected accounts' credentials at rest (app.providers.crypto). Any string of 32+
    # characters; `openssl rand -base64 32` makes one. Keep it out of backups of the database:
    # without it, a stolen database file holds no usable passwords or tokens. Empty: the app
    # runs, but no account can be connected.
    organizer_secret_key: SecretStr = SecretStr("")

    # Time zone used until setup sets one in the database.
    default_timezone: str = "UTC"

    # The session cookie's Secure flag. "auto": set when the request arrived over HTTPS
    # (directly or through a proxy that sends X-Forwarded-Proto).
    cookie_secure: Literal["auto", "always", "never"] = "auto"
    # How long a browser stays signed in without being used.
    session_idle_days: int = Field(default=30, ge=1, le=365)

    # The address people use to reach the app, e.g. https://organizer.example.ts.net. Used to
    # build OAuth redirect URIs; empty means "the address the request came in on".
    public_base_url: str = ""

    # Your own Google Cloud OAuth client ("Web application"), for Google Calendar, Gmail and
    # Tasks (app.providers.google; docs/GOOGLE.md). Empty: Google accounts can't be connected.
    google_client_id: str = ""
    google_client_secret: SecretStr = SecretStr("")

    # Built web app served at `/`. Skipped when the folder does not exist.
    web_dist: Path = Path("../web/dist")

    # Background polls (APScheduler). Off in tests.
    scheduler_enabled: bool = True

    # Serve /docs, /redoc and /openapi.json. Off in production (they map the whole API for
    # anyone); turn on for development, e.g. for `npm run gen:api`.
    expose_api_docs: bool = False

    # Mail (app/modules/mail, docs/MAIL.md): how many days back the header mirror reaches.
    # Older messages drop out of it.
    mail_window_days: int = Field(default=30, ge=1, le=365)


@lru_cache
def get_settings() -> Settings:
    return Settings()
