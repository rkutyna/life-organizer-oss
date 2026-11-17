"""The HTTP client: the bearer token on every request, query rendering, how failures become
messages, and the settings it is built from."""

from __future__ import annotations

import datetime as dt

import httpx
import pytest
from support import API_TOKEN, BASE_URL, MAIL_TOKEN, FakeOrganizer, query, sent_json

from organizer_mcp.client import OrganizerClient, OrganizerError
from organizer_mcp.config import ConfigError, Settings, load_settings, require_tokens


def make_client(fake: FakeOrganizer, **tokens: str | None) -> OrganizerClient:
    tokens = {"token": API_TOKEN, "mail_token": MAIL_TOKEN, **tokens}
    return OrganizerClient(BASE_URL, timeout=5, transport=httpx.MockTransport(fake), **tokens)


@pytest.mark.parametrize("method", ["GET", "POST", "PUT", "PATCH", "DELETE"])
def test_every_request_carries_the_api_token_and_no_author(
    organizer: FakeOrganizer, method: str
) -> None:
    organizer.reply(method, "/api/things/1", {})
    client = make_client(organizer)
    if method in ("POST", "PUT", "PATCH"):
        getattr(client, method.lower())("/api/things/1", {"title": "x"})
    else:
        getattr(client, method.lower())("/api/things/1")
    request = organizer.only(method, "/api/things/1")
    assert request.headers["authorization"] == f"Bearer {API_TOKEN}"
    assert "x-author" not in request.headers


def test_the_mail_scope_sends_the_mail_token(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/mail/accounts", [])
    make_client(organizer).get("/api/mail/accounts", scope="mail")
    request = organizer.only("GET", "/api/mail/accounts")
    assert request.headers["authorization"] == f"Bearer {MAIL_TOKEN}"


def test_a_missing_token_is_named_before_any_request(organizer: FakeOrganizer) -> None:
    with pytest.raises(OrganizerError) as info:
        make_client(organizer, token=None).get("/api/calendar")
    assert str(info.value).startswith(
        "ORGANIZER_TOKEN is not set: make an API token with the 'api'"
    )
    assert "Settings → API tokens" in str(info.value)
    assert organizer.requests == []


def test_query_drops_unset_values_and_renders_the_rest(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/things", [])
    make_client(organizer).get(
        "/api/things",
        params={
            "status": ["open", "done"],
            "channel": None,
            "historical": False,
            "since": dt.date(2026, 10, 1),
            "include_hidden": True,
        },
    )
    assert query(organizer.only("GET", "/api/things")) == {
        "status": ["open", "done"],
        "historical": ["false"],
        "since": ["2026-10-01"],
        "include_hidden": ["true"],
    }


def test_write_body_renders_dates_and_keeps_explicit_nulls(organizer: FakeOrganizer) -> None:
    organizer.reply("PATCH", "/api/things/3", {})
    make_client(organizer).patch("/api/things/3", {"due": dt.date(2026, 10, 20), "list": None})
    assert sent_json(organizer.only("PATCH", "/api/things/3")) == {
        "due": "2026-10-20",
        "list": None,
    }


def test_no_content_returns_none(organizer: FakeOrganizer) -> None:
    organizer.reply("DELETE", "/api/things/3", None, status=204)
    assert make_client(organizer).delete("/api/things/3") is None


def test_unknown_path_404_names_the_endpoint(organizer: FakeOrganizer) -> None:
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/nothing", {"date": "2026-10-18"})
    assert str(info.value) == "not found: no organizer endpoint at GET /api/nothing"


def test_lowercase_generic_404_is_treated_the_same(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/nothing", {"detail": "not found"}, status=404)
    with pytest.raises(OrganizerError, match="^not found: no organizer endpoint at GET"):
        make_client(organizer).get("/api/nothing")


def test_specific_404_keeps_the_servers_message(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/mail/messages/12", {"detail": "message 12 not found"}, 404)
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/mail/messages/12", scope="mail")
    assert str(info.value) == "message 12 not found"


def test_404_without_not_found_wording_is_prefixed(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/things/9", {"detail": "no such thing"}, status=404)
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/things/9")
    assert str(info.value) == "not found: no such thing"


def test_400_passes_the_server_message_through(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/calendar", {"detail": "end must be after start"}, status=400)
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/calendar")
    assert str(info.value) == "end must be after start"


def test_validation_422_is_rendered_field_by_field(organizer: FakeOrganizer) -> None:
    organizer.reply(
        "GET",
        "/api/calendar",
        {
            "detail": [
                {"type": "missing", "loc": ["query", "start"], "msg": "Field required"},
                {"type": "datetime_parsing", "loc": ["query", "end"], "msg": "Input is invalid"},
            ]
        },
        status=422,
    )
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/calendar")
    assert str(info.value) == "start: Field required; end: Input is invalid"


@pytest.mark.parametrize(
    ("status", "detail", "scope", "env"),
    [
        (401, "invalid or revoked API token", "api", "ORGANIZER_TOKEN"),
        (403, "this credential lacks the 'mail' scope", "mail", "ORGANIZER_MAIL_TOKEN"),
    ],
)
def test_auth_failures_name_the_token_to_check(
    organizer: FakeOrganizer, status: int, detail: str, scope: str, env: str
) -> None:
    organizer.reply("GET", "/api/x", {"detail": detail}, status=status)
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/x", scope=scope)
    assert str(info.value) == (
        f"organizer refused GET /api/x (HTTP {status}): {detail}. Check {env}: it must be a "
        f"live token with the '{scope}' scope (Settings → API tokens)"
    )


def test_other_server_errors_say_what_failed(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/calendar", {"detail": "boom"}, status=500)
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/calendar")
    assert str(info.value) == "organizer error on GET /api/calendar (HTTP 500): boom"


def test_connection_failure_says_the_organizer_is_unreachable(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/calendar", httpx.ConnectError("connection refused"))
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/calendar")
    assert str(info.value) == (
        f"organizer unreachable at {BASE_URL} (is it running, and is ORGANIZER_URL right?)"
    )


def test_read_timeout_names_the_wait(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/calendar", httpx.ReadTimeout("slow"))
    with pytest.raises(OrganizerError) as info:
        make_client(organizer).get("/api/calendar")
    assert str(info.value) == (
        f"organizer at {BASE_URL} did not answer within 5s on GET /api/calendar"
    )


def test_non_json_success_is_reported() -> None:
    def html(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>not json</html>")

    client = OrganizerClient(BASE_URL, transport=httpx.MockTransport(html), token="t")
    with pytest.raises(OrganizerError, match="non-JSON for GET /api/calendar"):
        client.get("/api/calendar")


# --------------------------------------------------------------------------- settings


def test_default_settings() -> None:
    settings = load_settings({})
    assert settings == Settings(url="http://localhost:8600", timeout=15.0)


def test_settings_from_environment() -> None:
    settings = load_settings(
        {
            "ORGANIZER_URL": "http://127.0.0.1:8600/",
            "ORGANIZER_TIMEOUT": "7.5",
            "ORGANIZER_TOKEN": " a ",
            "ORGANIZER_MAIL_TOKEN": "",
        }
    )
    assert settings == Settings("http://127.0.0.1:8600", 7.5, token="a", mail_token=None)


@pytest.mark.parametrize(
    "env",
    [
        {"ORGANIZER_URL": "organizer.example.com:8600"},
        {"ORGANIZER_TIMEOUT": "soon"},
        {"ORGANIZER_TIMEOUT": "0"},
    ],
)
def test_bad_settings_are_rejected(env: dict[str, str]) -> None:
    with pytest.raises(ConfigError):
        load_settings(env)


def test_require_tokens_names_each_missing_one() -> None:
    settings = Settings("http://organizer.test", 5, token="a")
    require_tokens(settings, {"api"})
    with pytest.raises(ConfigError, match="^ORGANIZER_MAIL_TOKEN is not set"):
        require_tokens(settings, {"api", "mail"})
    with pytest.raises(ConfigError, match="^ORGANIZER_TOKEN is not set"):
        require_tokens(Settings("http://organizer.test", 5), {"api"})
