"""app.auth: setup, sign in and out, CSRF, sessions, API tokens and scopes."""

from collections.abc import Callable
from datetime import timedelta

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import router as auth_router
from app.auth.models import ApiToken, AppConfig, AuthSession
from app.auth.principal import COOKIE_NAME
from app.timeutil import local_tz, utcnow
from conftest import CSRF, PASSWORD, SETUP


def state(c: TestClient) -> dict:
    return c.get("/api/auth/state").json()


# --------------------------------------------------------------------------- setup


def test_fresh_install_needs_setup(anon: TestClient):
    assert state(anon) == {"setup_required": True, "authenticated": False, "display_name": None}
    assert anon.get("/api/calendar/sources").status_code == 401


def test_setup_signs_in_and_stores_only_a_hash(anon: TestClient, session: Session):
    response = anon.post("/api/auth/setup", json=SETUP)

    assert response.status_code == 200
    assert response.json() == {
        "setup_required": False,
        "authenticated": True,
        "display_name": "Test Owner",
    }
    cookie = response.headers["set-cookie"]
    assert COOKIE_NAME in cookie and "HttpOnly" in cookie and "SameSite=strict" in cookie
    config = session.get(AppConfig, 1)
    assert PASSWORD not in config.password_hash and config.password_hash.startswith("$argon2")
    [browser] = session.scalars(select(AuthSession))
    assert anon.cookies[COOKIE_NAME] not in browser.token_hash
    assert str(local_tz()) == "America/New_York"


def test_setup_happens_once(client: TestClient, anon: TestClient):
    response = anon.post("/api/auth/setup", json={**SETUP, "password": "another password"})
    assert response.status_code == 409


def test_setup_validates(anon: TestClient):
    assert anon.post("/api/auth/setup", json={**SETUP, "password": "short"}).status_code == 422
    assert anon.post("/api/auth/setup", json={**SETUP, "timezone": "Mars/Base"}).status_code == 422
    bad_country = anon.post("/api/auth/setup", json={**SETUP, "holiday_country": "ZZ"})
    assert bad_country.status_code == 422
    assert state(anon)["setup_required"] is True


def test_setup_without_the_csrf_header_is_refused(app: FastAPI):
    with TestClient(app) as bare:
        assert bare.post("/api/auth/setup", json=SETUP).status_code == 403


def test_secure_cookie_over_https(app: FastAPI):
    with TestClient(app, base_url="https://testserver", headers=CSRF) as https:
        cookie = https.post("/api/auth/setup", json=SETUP).headers["set-cookie"]
    assert "Secure" in cookie


# --------------------------------------------------------------------------- sign in


def test_login_and_logout(client: TestClient, app: FastAPI):
    with TestClient(app, headers=CSRF) as other:
        assert state(other)["authenticated"] is False
        assert other.post("/api/auth/login", json={"password": "wrong password"}).status_code == 401
        assert other.post("/api/auth/login", json={"password": PASSWORD}).status_code == 200
        assert state(other) == {
            "setup_required": False,
            "authenticated": True,
            "display_name": "Test Owner",
        }
        assert other.get("/api/calendar/sources").status_code == 200

        assert other.post("/api/auth/logout").status_code == 204
        assert other.get("/api/calendar/sources").status_code == 401
    assert client.get("/api/calendar/sources").status_code == 200  # the other browser stays in


def test_repeated_failures_are_throttled(client: TestClient, app: FastAPI, monkeypatch):
    monkeypatch.setattr(auth_router, "throttle", type(auth_router.throttle)())
    with TestClient(app, headers=CSRF) as attacker:
        for _ in range(5):
            assert (
                attacker.post("/api/auth/login", json={"password": "nope nope"}).status_code == 401
            )
        response = attacker.post("/api/auth/login", json={"password": PASSWORD})
    assert response.status_code == 429
    assert int(response.headers["retry-after"]) > 0


def test_a_stolen_cookie_value_is_not_the_stored_value(client: TestClient, app, session: Session):
    [browser] = session.scalars(select(AuthSession))
    with TestClient(app, headers=CSRF, cookies={COOKIE_NAME: browser.token_hash}) as forged:
        assert forged.get("/api/calendar/sources").status_code == 401


def test_idle_session_expires(client: TestClient, session: Session):
    [browser] = session.scalars(select(AuthSession))
    browser.last_seen_at = utcnow() - timedelta(days=31)
    session.commit()

    assert client.get("/api/calendar/sources").status_code == 401
    assert session.scalars(select(AuthSession)).all() == []


def test_cookie_writes_need_the_csrf_header(client: TestClient):
    assert client.patch("/api/settings", json={"display_name": "X"}).status_code == 200
    response = client.patch(
        "/api/settings", json={"display_name": "Y"}, headers={"X-Requested-With": ""}
    )
    assert response.status_code == 403
    assert client.get("/api/settings").json()["display_name"] == "X"


def test_password_change_signs_out_other_browsers(client: TestClient, app: FastAPI):
    with TestClient(app, headers=CSRF) as other:
        other.post("/api/auth/login", json={"password": PASSWORD})

        wrong = client.post(
            "/api/auth/password", json={"current_password": "nope", "new_password": "a" * 12}
        )
        assert wrong.status_code == 403
        weak = client.post(
            "/api/auth/password", json={"current_password": PASSWORD, "new_password": "short"}
        )
        assert weak.status_code == 422
        ok = client.post(
            "/api/auth/password",
            json={"current_password": PASSWORD, "new_password": "a brand new password"},
        )
        assert ok.status_code == 204

        assert other.get("/api/calendar/sources").status_code == 401
        assert client.get("/api/calendar/sources").status_code == 200
        assert other.post("/api/auth/login", json={"password": PASSWORD}).status_code == 401
        login = other.post("/api/auth/login", json={"password": "a brand new password"})
        assert login.status_code == 200


# --------------------------------------------------------------------------- tokens


def test_token_secret_is_shown_once_and_hashed(client: TestClient, session: Session):
    response = client.post(
        "/api/settings/tokens", json={"name": "MCP", "author": "claude", "scopes": ["api"]}
    )
    assert response.status_code == 201
    body = response.json()
    secret = body["secret"]
    assert secret.startswith("org_") and body["token"]["prefix"] == secret[:12]
    [row] = session.scalars(select(ApiToken))
    assert secret not in row.token_hash
    listed = client.get("/api/settings/tokens").json()
    assert "secret" not in listed[0] and listed[0]["scopes"] == ["api"]


def test_token_reaches_the_api_but_not_account_settings(
    token_client: Callable[..., TestClient],
):
    claude = token_client(["api"])
    assert claude.get("/api/calendar/sources").status_code == 200
    assert claude.post("/api/history/1/revert").status_code == 404  # no CSRF header needed
    assert claude.get("/api/settings").status_code == 403
    assert claude.get("/api/settings/tokens").status_code == 403
    mint = claude.post(
        "/api/settings/tokens", json={"name": "x", "author": "me", "scopes": ["api"]}
    )
    assert mint.status_code == 403


def test_scopes_are_enforced(token_client: Callable[..., TestClient]):
    helper = token_client(["ingest"], author="helper")
    assert helper.get("/api/calendar/sources").status_code == 403


def test_revoked_or_unknown_token_is_401(
    client: TestClient, token_client: Callable[..., TestClient], app: FastAPI
):
    claude = token_client(["api"])
    token_id = client.get("/api/settings/tokens").json()[0]["id"]
    assert client.delete(f"/api/settings/tokens/{token_id}").status_code == 204

    assert claude.get("/api/calendar/sources").status_code == 401
    assert client.get("/api/settings/tokens").json()[0]["revoked_at"] is not None
    with TestClient(app, headers={"Authorization": "Bearer org_made_up"}) as unknown:
        assert unknown.get("/api/calendar/sources").status_code == 401
    with TestClient(app, headers={"Authorization": "Basic abc"}) as basic:
        assert basic.get("/api/calendar/sources").status_code == 401


def test_token_use_is_recorded(token_client: Callable[..., TestClient], session: Session):
    token_client(["api"]).get("/api/calendar/sources")
    [row] = session.scalars(select(ApiToken))
    assert row.last_used_at is not None


def test_token_create_validates(client: TestClient):
    def create(**fields):
        body = {"name": "x", "author": "claude", "scopes": ["api"], **fields}
        return client.post("/api/settings/tokens", json=body).status_code

    assert create(author="system") == 422
    assert create(scopes=[]) == 422
    assert create(scopes=["admin"]) == 422
