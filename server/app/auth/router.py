"""/api/auth: first-run setup, sign in and out, password change.

`state`, `setup` and `login` are public (the browser has no session yet); they still need the
CSRF header on POST. Everything else needs a signed-in browser.
"""

import time
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from app.auth import service
from app.auth.principal import (
    COOKIE_NAME,
    Principal,
    check_csrf,
    require_browser,
    session_from_cookie,
)
from app.deps import SessionDep, SettingsDep

router = APIRouter(prefix="/api/auth", tags=["auth"])

throttle = service.LoginThrottle()


class AuthState(BaseModel):
    setup_required: bool
    authenticated: bool
    display_name: str | None = Field(description="Only when authenticated")


class SetupIn(BaseModel):
    display_name: str = Field(min_length=1, max_length=100)
    password: str = Field(max_length=1000)
    timezone: str
    holiday_country: str | None = Field(default=None, max_length=8)


class LoginIn(BaseModel):
    password: str = Field(max_length=1000)


class PasswordIn(BaseModel):
    current_password: str = Field(max_length=1000)
    new_password: str = Field(max_length=1000)


def _set_cookie(response: Response, request: Request, settings, raw: str) -> None:
    secure = {
        "always": True,
        "never": False,
        "auto": request.url.scheme == "https",
    }[settings.cookie_secure]
    response.set_cookie(
        COOKIE_NAME,
        raw,
        max_age=settings.session_idle_days * 86400,
        httponly=True,
        secure=secure,
        samesite="strict",
        path="/",
    )


def _client(request: Request) -> str:
    """The address the login throttle counts against.

    Behind a reverse proxy (Tailscale, cloudflared, Caddy...) it is the last X-Forwarded-For
    entry: the one the proxy itself appended, which the client cannot choose. Earlier entries
    are whatever the client sent and are ignored. Without a proxy it is the peer address.
    """
    forwarded = request.headers.get("x-forwarded-for", "")
    hops = [hop.strip() for hop in forwarded.split(",") if hop.strip()]
    if hops:
        return hops[-1]
    return request.client.host if request.client else "unknown"


@router.get("/state", response_model=AuthState)
def auth_state(request: Request, session: SessionDep) -> AuthState:
    """Whether setup is needed and whether this browser is signed in."""
    config = service.load_config(session)
    if config is None:
        return AuthState(setup_required=True, authenticated=False, display_name=None)
    signed_in = session_from_cookie(request, session) is not None
    return AuthState(
        setup_required=False,
        authenticated=signed_in,
        display_name=config.display_name if signed_in else None,
    )


@router.post("/setup", response_model=AuthState, dependencies=[Depends(check_csrf)])
def setup(
    payload: SetupIn,
    request: Request,
    response: Response,
    session: SessionDep,
    settings: SettingsDep,
) -> AuthState:
    """Create the owner's password and settings, and sign this browser in. Once only."""
    if payload.holiday_country is not None:
        from app.holidays_provider import supported_countries

        if payload.holiday_country not in supported_countries():
            raise HTTPException(422, f"unknown holiday country {payload.holiday_country!r}")
    if not service.valid_timezone(payload.timezone):
        raise HTTPException(422, f"unknown time zone {payload.timezone!r}")
    try:
        config = service.setup(
            session,
            display_name=payload.display_name,
            password=payload.password,
            timezone=payload.timezone,
            holiday_country=payload.holiday_country,
        )
    except PermissionError as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    raw = service.start_session(session, request.headers.get("user-agent"))
    _set_cookie(response, request, settings, raw)
    return AuthState(setup_required=False, authenticated=True, display_name=config.display_name)


@router.post("/login", response_model=AuthState, dependencies=[Depends(check_csrf)])
def login(
    payload: LoginIn,
    request: Request,
    response: Response,
    session: SessionDep,
    settings: SettingsDep,
) -> AuthState:
    """Sign this browser in with the password."""
    config = service.load_config(session)
    if config is None:
        raise HTTPException(409, "set up the organizer first")
    client = _client(request)
    wait = throttle.retry_after(client)
    if wait is not None:
        raise HTTPException(
            429,
            f"too many failed sign-ins; try again in {wait // 60 + 1} minutes",
            headers={"Retry-After": str(wait)},
        )
    delay = throttle.overall_delay()
    if delay:
        time.sleep(delay)  # many failures lately, from anywhere: slow down, never refuse
    if not service.verify_password(config, payload.password):
        throttle.failed(client)
        raise HTTPException(401, "wrong password")
    throttle.succeeded(client)
    raw = service.start_session(session, request.headers.get("user-agent"))
    _set_cookie(response, request, settings, raw)
    return AuthState(setup_required=False, authenticated=True, display_name=config.display_name)


@router.post("/logout", status_code=204)
def logout(
    response: Response,
    session: SessionDep,
    principal: Annotated[Principal, Depends(require_browser)],
) -> None:
    """Sign this browser out."""
    service.end_session(session, principal.record_id)
    response.delete_cookie(COOKIE_NAME, path="/")


@router.post("/password", status_code=204)
def change_password(
    payload: PasswordIn,
    session: SessionDep,
    principal: Annotated[Principal, Depends(require_browser)],
) -> None:
    """Change the password. Every other signed-in browser is signed out."""
    config = service.load_config(session)
    assert config is not None  # a session exists, so setup happened
    if not service.verify_password(config, payload.current_password):
        raise HTTPException(403, "the current password is wrong")
    try:
        service.change_password(session, config, payload.new_password, principal.record_id)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
