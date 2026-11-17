"""Connecting a Google account: start the consent flow, and Google's redirect back.

- `GET /api/settings/google` and `POST /api/settings/google/start` are browser-only (mounted
  with the other settings routes).
- `GET /api/oauth/google/callback` is public: Google redirects the browser here, and the session
  cookie (SameSite=Strict) is not sent on that cross-site navigation. The single-use `state`
  made by `start` is what authorizes it.
"""

from typing import Literal
from urllib.parse import urlencode

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field

from app.deps import SessionDep, SettingsDep
from app.providers import crypto, google

router = APIRouter(prefix="/api/settings/google", tags=["settings"])
callback_router = APIRouter(tags=["settings"])

SETTINGS_PAGE = "/settings"


class GoogleStatus(BaseModel):
    configured: bool = Field(description="GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are set")
    redirect_uri: str = Field(description="Add this to the OAuth client's authorized redirect URIs")


class GoogleStart(BaseModel):
    features: list[Literal["calendar", "gmail", "tasks"]] = Field(min_length=1)


class GoogleStartOut(BaseModel):
    authorize_url: str


def _base_url(request: Request) -> str:
    return str(request.base_url)


@router.get("", response_model=GoogleStatus)
def google_status(request: Request, settings: SettingsDep) -> GoogleStatus:
    return GoogleStatus(
        configured=google.is_configured(settings),
        redirect_uri=google.redirect_uri(settings, _base_url(request)),
    )


@router.post("/start", response_model=GoogleStartOut)
def start(
    payload: GoogleStart, request: Request, session: SessionDep, settings: SettingsDep
) -> GoogleStartOut:
    """Begin connecting a Google account. Send the browser to the returned URL."""
    try:
        crypto.encrypt(settings.organizer_secret_key.get_secret_value(), {})
    except crypto.CryptoUnavailable as exc:
        raise HTTPException(503, str(exc)) from exc
    try:
        url = google.start_consent(
            session, settings, payload.features, google.redirect_uri(settings, _base_url(request))
        )
    except google.ConsentError as exc:
        raise HTTPException(409, str(exc)) from exc
    return GoogleStartOut(authorize_url=url)


@callback_router.get(google.CALLBACK_PATH, response_class=RedirectResponse, status_code=303)
def callback(
    session: SessionDep,
    settings: SettingsDep,
    state: str = "",
    code: str = "",
    error: str = "",
) -> RedirectResponse:
    """Google's redirect. Always answers with a redirect back to Settings."""
    if error or not code or not state:
        reason = "cancelled" if error == "access_denied" else (error or "no code")
        return _back("error", reason)
    try:
        account = google.complete_consent(session, settings, state, code)
    except google.ConsentError as exc:
        return _back("error", str(exc))
    except Exception:  # noqa: BLE001 - never show a stack trace to a redirect
        return _back("error", "Google could not be reached; try again")
    return _back("connected", google.account_email(account))


def _back(result: str, detail: str) -> RedirectResponse:
    query = urlencode({"google": result, "detail": detail[:200]})
    return RedirectResponse(f"{SETTINGS_PAGE}?{query}", status_code=303)
