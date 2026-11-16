"""/api/settings and connected accounts, with their encrypted credentials."""

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy.orm import Session

from app.config import Settings
from app.providers import crypto
from app.providers import service as accounts
from app.providers.models import ProviderAccount
from app.timeutil import local_tz
from conftest import SECRET_KEY


def test_settings_read_and_update(client: TestClient):
    body = client.get("/api/settings").json()
    assert body == {
        "display_name": "Test Owner",
        "timezone": "America/New_York",
        "holiday_country": "US",
        "secret_key_configured": True,
    }

    updated = client.patch(
        "/api/settings", json={"timezone": "Europe/Berlin", "display_name": "  Sam  "}
    ).json()

    assert updated["timezone"] == "Europe/Berlin" and updated["display_name"] == "Sam"
    assert str(local_tz()) == "Europe/Berlin"


def test_settings_validation(client: TestClient):
    assert client.patch("/api/settings", json={"timezone": "Nowhere/Land"}).status_code == 422
    assert client.patch("/api/settings", json={"timezone": None}).status_code == 422
    assert client.patch("/api/settings", json={"holiday_country": "ZZ"}).status_code == 422
    assert client.patch("/api/settings", json={"display_name": None}).status_code == 422


def test_pickers_are_public_for_setup(anon: TestClient):
    assert "Europe/Berlin" in anon.get("/api/settings/timezones").json()
    assert anon.get("/api/settings/holiday-countries").status_code == 200


def test_pickers(client: TestClient):
    zones = client.get("/api/settings/timezones").json()
    assert "America/New_York" in zones and "Etc/GMT+5" not in zones
    countries = {c["code"]: c["name"] for c in client.get("/api/settings/holiday-countries").json()}
    assert countries["US"] == "United States"


def test_secret_key_status(client: TestClient, app):
    app.state.settings = app.state.settings.model_copy(
        update={"organizer_secret_key": SecretStr("")}
    )
    assert client.get("/api/settings").json()["secret_key_configured"] is False


# --------------------------------------------------------------------------- crypto


def test_crypto_round_trip():
    token = crypto.encrypt(SECRET_KEY, {"password": "hunter2-but-longer"})
    assert "hunter2" not in token
    assert crypto.decrypt(SECRET_KEY, token) == {"password": "hunter2-but-longer"}


def test_crypto_needs_a_real_key():
    with pytest.raises(crypto.CryptoUnavailable):
        crypto.encrypt("", {"a": 1})
    with pytest.raises(crypto.CryptoUnavailable):
        crypto.encrypt("short", {"a": 1})


def test_changed_key_cannot_read_old_credentials():
    token = crypto.encrypt(SECRET_KEY, {"a": 1})
    with pytest.raises(crypto.CredentialsUnreadable):
        crypto.decrypt("x" * 40, token)


# --------------------------------------------------------------------------- accounts


def make_account(session: Session, settings: Settings) -> ProviderAccount:
    return accounts.create(
        session,
        settings,
        kind="imap",
        label="Mail",
        credentials={"password": "app-specific-secret"},
        config={"host": "imap.example.com"},
    )


def test_credentials_are_encrypted_and_never_listed(
    client: TestClient, session: Session, settings: Settings
):
    account = make_account(session, settings)
    assert "app-specific-secret" not in account.credentials_encrypted
    assert accounts.credentials(settings, account) == {"password": "app-specific-secret"}
    assert accounts.config(account) == {"host": "imap.example.com"}

    response = client.get("/api/settings/accounts")

    assert "app-specific-secret" not in response.text
    assert "credentials" not in response.text
    [listed] = response.json()
    assert (listed["kind"], listed["label"], listed["status"]) == ("imap", "Mail", "never")


def test_account_status_follows_syncs(client: TestClient, session: Session, settings: Settings):
    account = make_account(session, settings)
    accounts.mark_success(session, account)
    assert accounts.status(account) == "ok"
    accounts.mark_error(session, account, "login failed")
    assert accounts.status(account) == "error"
    [listed] = client.get("/api/settings/accounts").json()
    assert listed["last_error"] == "login failed"
    accounts.mark_success(session, account)
    assert accounts.status(account) == "ok" and account.last_error is None


def test_rename_disable_and_remove(client: TestClient, session: Session, settings: Settings):
    account = make_account(session, settings)

    renamed = client.patch(f"/api/settings/accounts/{account.id}", json={"label": "Work mail"})
    assert renamed.json()["label"] == "Work mail"
    disabled = client.patch(f"/api/settings/accounts/{account.id}", json={"enabled": False})
    assert disabled.json()["status"] == "disabled"

    assert client.delete(f"/api/settings/accounts/{account.id}").status_code == 204
    assert client.get("/api/settings/accounts").json() == []
    assert client.delete(f"/api/settings/accounts/{account.id}").status_code == 404


def test_tokens_cannot_see_accounts(client: TestClient, token_client):
    assert token_client(["api", "mail"]).get("/api/settings/accounts").status_code == 403
