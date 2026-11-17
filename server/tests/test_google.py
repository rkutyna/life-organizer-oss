"""app.providers.google: the consent flow, token refresh and scope lookup, against a fake Google."""

import json
from datetime import timedelta
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount
from app.timeutil import utcnow

CLIENT = {"google_client_id": "client-id.example", "google_client_secret": "client-secret"}


class FakeGoogle:
    """Answers the token, userinfo and revoke endpoints; records every request."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.email = "friend@example.com"
        self.refresh_token: str | None = "refresh-1"
        self.scope = f"openid email {google.SCOPES['calendar']}"
        self.refresh_error: str | None = None
        self.counter = 0

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = str(request.url)
        if url == google.TOKEN_URL:
            form = parse_qs(request.content.decode())
            if form["grant_type"] == ["refresh_token"] and self.refresh_error:
                return httpx.Response(400, json={"error": self.refresh_error})
            self.counter += 1
            body = {"access_token": f"access-{self.counter}", "expires_in": 3600}
            if form["grant_type"] == ["authorization_code"]:
                body["scope"] = self.scope
                if self.refresh_token:
                    body["refresh_token"] = self.refresh_token
            return httpx.Response(200, json=body)
        if url == google.USERINFO_URL:
            return httpx.Response(200, json={"email": self.email})
        if url == google.REVOKE_URL:
            return httpx.Response(200)
        return httpx.Response(404)

    def calls(self, url: str) -> list[httpx.Request]:
        return [r for r in self.requests if str(r.url) == url]


@pytest.fixture
def fake(monkeypatch) -> FakeGoogle:
    fake = FakeGoogle()
    monkeypatch.setattr(
        google, "make_client", lambda: httpx.Client(transport=httpx.MockTransport(fake.handler))
    )
    return fake


@pytest.fixture
def configured(app, settings: Settings) -> Settings:
    app.state.settings = settings.model_copy(
        update={
            "google_client_id": CLIENT["google_client_id"],
            "google_client_secret": SecretStr(CLIENT["google_client_secret"]),
            "public_base_url": "https://organizer.example.com",
        }
    )
    return app.state.settings


def start(client: TestClient, features=("calendar",)) -> dict[str, list[str]]:
    response = client.post("/api/settings/google/start", json={"features": list(features)})
    assert response.status_code == 200, response.text
    return parse_qs(urlparse(response.json()["authorize_url"]).query)


def finish(anon: TestClient, query: dict[str, list[str]], code: str = "code-1") -> httpx.Response:
    return anon.get(
        "/api/oauth/google/callback",
        params={"state": query["state"][0], "code": code},
        follow_redirects=False,
    )


def test_status_shows_the_redirect_uri(client: TestClient, configured: Settings):
    body = client.get("/api/settings/google").json()
    assert body == {
        "configured": True,
        "redirect_uri": "https://organizer.example.com/api/oauth/google/callback",
    }


def test_start_needs_a_client(client: TestClient):
    assert client.get("/api/settings/google").json()["configured"] is False
    response = client.post("/api/settings/google/start", json={"features": ["calendar"]})
    assert response.status_code == 409
    assert "GOOGLE_CLIENT_ID" in response.json()["detail"]


def test_start_builds_a_pkce_request(client: TestClient, configured: Settings, session: Session):
    query = start(client, ["gmail", "calendar"])

    assert query["client_id"] == ["client-id.example"]
    assert query["code_challenge_method"] == ["S256"]
    assert query["access_type"] == ["offline"]
    scopes = query["scope"][0].split()
    assert {"openid", "email", google.SCOPES["calendar"], google.SCOPES["gmail"]} == set(scopes)
    [row] = session.scalars(select(google.OAuthState))
    assert query["state"][0] not in row.state_hash


def test_consent_creates_an_encrypted_account(
    client: TestClient, anon: TestClient, configured: Settings, fake: FakeGoogle, session: Session
):
    response = finish(anon, start(client))

    assert response.status_code == 303
    assert response.headers["location"].startswith("/settings?google=connected")
    [account] = session.scalars(select(ProviderAccount))
    assert (account.kind, account.label) == ("google", "friend@example.com")
    assert google.granted_scopes(account) == sorted(fake.scope.split())
    assert "refresh-1" not in account.credentials_encrypted
    assert accounts.credentials(configured, account)["refresh_token"] == "refresh-1"
    [exchange] = fake.calls(google.TOKEN_URL)
    form = parse_qs(exchange.content.decode())
    assert form["code_verifier"][0] and form["redirect_uri"] == [
        "https://organizer.example.com/api/oauth/google/callback"
    ]
    listed = client.get("/api/settings/accounts").json()
    assert "refresh" not in json.dumps(listed)


def test_state_is_single_use(client: TestClient, anon: TestClient, configured, fake: FakeGoogle):
    query = start(client)
    assert "connected" in finish(anon, query).headers["location"]
    again = finish(anon, query)
    assert "google=error" in again.headers["location"]


def test_unknown_or_old_state_is_refused(
    client: TestClient, anon: TestClient, configured, fake: FakeGoogle, session: Session
):
    forged = anon.get(
        "/api/oauth/google/callback",
        params={"state": "made-up", "code": "x"},
        follow_redirects=False,
    )
    assert "google=error" in forged.headers["location"]

    query = start(client)
    row = session.scalars(select(google.OAuthState)).one()
    row.created_at = utcnow() - timedelta(hours=1)
    session.commit()
    assert "took+too+long" in finish(anon, query).headers["location"]
    assert fake.calls(google.TOKEN_URL) == []


def test_cancelled_consent(anon: TestClient):
    response = anon.get(
        "/api/oauth/google/callback", params={"error": "access_denied"}, follow_redirects=False
    )
    assert response.headers["location"].startswith("/settings?google=error&detail=cancelled")


def test_reconnecting_merges_scopes_and_keeps_the_refresh_token(
    client: TestClient, anon: TestClient, configured, fake: FakeGoogle, session: Session
):
    finish(anon, start(client))
    fake.scope = f"openid email {google.SCOPES['gmail']}"
    fake.refresh_token = None  # Google may omit it on a repeat consent
    finish(anon, start(client, ["gmail"]))

    [account] = session.scalars(select(ProviderAccount))
    session.refresh(account)
    assert {google.SCOPES["calendar"], google.SCOPES["gmail"]} <= set(
        google.granted_scopes(account)
    )
    assert accounts.credentials(configured, account)["refresh_token"] == "refresh-1"


def test_accounts_with_filters_by_scope_and_enabled(
    client: TestClient, anon: TestClient, configured, fake: FakeGoogle, session: Session
):
    finish(anon, start(client))
    assert len(google.accounts_with(session, "calendar")) == 1
    assert google.accounts_with(session, "gmail") == []
    [account] = google.accounts_with(session, "calendar")
    client.patch(f"/api/settings/accounts/{account.id}", json={"enabled": False})
    session.expire_all()
    assert google.accounts_with(session, "calendar") == []


def connected(client, anon, fake, session) -> ProviderAccount:
    finish(anon, start(client))
    return session.scalars(select(ProviderAccount)).one()


def test_access_token_is_cached_until_near_expiry(
    client, anon, configured: Settings, fake: FakeGoogle, session: Session
):
    account = connected(client, anon, fake, session)
    before = len(fake.calls(google.TOKEN_URL))

    assert google.access_token(session, configured, account) == "access-1"
    assert len(fake.calls(google.TOKEN_URL)) == before

    creds = accounts.credentials(configured, account)
    creds["expires_at"] = (utcnow() + timedelta(seconds=30)).isoformat()
    accounts.set_credentials(session, configured, account, creds)
    assert google.access_token(session, configured, account) == "access-2"
    refresh = parse_qs(fake.calls(google.TOKEN_URL)[-1].content.decode())
    assert refresh["grant_type"] == ["refresh_token"] and refresh["refresh_token"] == ["refresh-1"]
    assert google.access_token(session, configured, account) == "access-2"  # stored


def test_a_refused_refresh_marks_the_account(
    client, anon, configured: Settings, fake: FakeGoogle, session: Session
):
    account = connected(client, anon, fake, session)
    creds = accounts.credentials(configured, account)
    creds["expires_at"] = utcnow().isoformat()
    accounts.set_credentials(session, configured, account, creds)
    fake.refresh_error = "invalid_grant"

    with pytest.raises(google.GoogleAuthError):
        google.access_token(session, configured, account)

    assert accounts.status(account) == "error"
    assert "invalid_grant" in account.last_error


def test_removing_a_google_account_revokes_it(
    client, anon, configured: Settings, fake: FakeGoogle, session: Session
):
    account = connected(client, anon, fake, session)
    assert client.delete(f"/api/settings/accounts/{account.id}").status_code == 204
    [revoke] = fake.calls(google.REVOKE_URL)
    assert parse_qs(revoke.content.decode())["token"] == ["refresh-1"]


def test_start_and_status_are_browser_only(configured, token_client):
    claude = token_client(["api", "mail"])
    assert claude.get("/api/settings/google").status_code == 403
    assert (
        claude.post("/api/settings/google/start", json={"features": ["gmail"]}).status_code == 403
    )
