"""/api/settings: the install's general settings and its API tokens. Signed-in browser only,
except the two pick lists (time zones, holiday countries), which setup needs.

Connected accounts (`/api/settings/accounts`) are in app.providers.router.
"""

from datetime import datetime
from typing import Literal
from zoneinfo import available_timezones

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.auth import service
from app.auth.models import ApiToken
from app.auth.principal import SCOPES, TOKEN_AUTHORS
from app.deps import SessionDep, SettingsDep, get_or_404
from app.holidays_provider import supported_countries

router = APIRouter(prefix="/api/settings", tags=["settings"])
# Static pick lists the setup screen needs before anyone is signed in. They reveal nothing about
# the install.
public_router = APIRouter(prefix="/api/settings", tags=["settings"])


class AppSettingsOut(BaseModel):
    display_name: str
    timezone: str
    holiday_country: str | None
    secret_key_configured: bool = Field(
        description="ORGANIZER_SECRET_KEY is set, so accounts can be connected"
    )


class AppSettingsUpdate(BaseModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=100)
    timezone: str | None = None
    holiday_country: str | None = Field(default=None, description="null turns holidays off")


class HolidayCountry(BaseModel):
    code: str
    name: str


class ApiTokenOut(BaseModel):
    id: int
    name: str
    author: str
    scopes: list[str]
    prefix: str
    created_at: datetime
    last_used_at: datetime | None
    revoked_at: datetime | None

    @classmethod
    def from_row(cls, row: ApiToken) -> "ApiTokenOut":
        return cls(
            id=row.id,
            name=row.name,
            author=row.author,
            scopes=[s for s in row.scopes.split(",") if s],
            prefix=row.prefix,
            created_at=row.created_at,
            last_used_at=row.last_used_at,
            revoked_at=row.revoked_at,
        )


class ApiTokenCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    author: Literal[TOKEN_AUTHORS]  # type: ignore[valid-type]
    scopes: list[Literal[SCOPES]] = Field(min_length=1)  # type: ignore[valid-type]


class ApiTokenCreated(BaseModel):
    token: ApiTokenOut
    secret: str = Field(description="Shown once; only its hash is stored")


def _settings_out(session, settings) -> AppSettingsOut:
    config = service.load_config(session)
    assert config is not None
    return AppSettingsOut(
        display_name=config.display_name,
        timezone=config.timezone,
        holiday_country=config.holiday_country,
        secret_key_configured=bool(settings.organizer_secret_key.get_secret_value()),
    )


@router.get("", response_model=AppSettingsOut)
def get_app_settings(session: SessionDep, settings: SettingsDep) -> AppSettingsOut:
    return _settings_out(session, settings)


@router.patch("", response_model=AppSettingsOut)
def update_app_settings(
    payload: AppSettingsUpdate, session: SessionDep, settings: SettingsDep
) -> AppSettingsOut:
    config = service.load_config(session)
    assert config is not None
    changes = payload.model_dump(exclude_unset=True)
    if "timezone" in changes and (
        changes["timezone"] is None or not service.valid_timezone(changes["timezone"])
    ):
        raise HTTPException(422, f"unknown time zone {changes['timezone']!r}")
    country = changes.get("holiday_country")
    if country is not None and country not in supported_countries():
        raise HTTPException(422, f"unknown holiday country {country!r}")
    if "display_name" in changes and changes["display_name"] is None:
        raise HTTPException(422, "display_name cannot be empty")
    for field, value in changes.items():
        setattr(config, field, value.strip() if field == "display_name" else value)
    session.commit()
    service.apply_timezone(session)
    return _settings_out(session, settings)


@public_router.get("/timezones", response_model=list[str])
def list_timezones() -> list[str]:
    """IANA time zone names, for the setup and settings pickers."""
    return sorted(tz for tz in available_timezones() if "/" in tz and not tz.startswith("Etc/"))


@public_router.get("/holiday-countries", response_model=list[HolidayCountry])
def list_holiday_countries() -> list[HolidayCountry]:
    return [HolidayCountry(code=code, name=name) for code, name in supported_countries().items()]


@router.get("/tokens", response_model=list[ApiTokenOut])
def list_tokens(session: SessionDep) -> list[ApiTokenOut]:
    return [ApiTokenOut.from_row(row) for row in service.list_tokens(session)]


@router.post("/tokens", response_model=ApiTokenCreated, status_code=201)
def create_token(payload: ApiTokenCreate, session: SessionDep) -> ApiTokenCreated:
    """Make a token for a client. The secret is in this response only."""
    row, secret = service.create_token(session, payload.name, payload.author, payload.scopes)
    return ApiTokenCreated(token=ApiTokenOut.from_row(row), secret=secret)


@router.delete("/tokens/{token_id}", status_code=204)
def revoke_token(token_id: int, session: SessionDep) -> None:
    """Revoke a token. It stays listed, marked revoked."""
    service.revoke_token(session, get_or_404(session, ApiToken, token_id))
