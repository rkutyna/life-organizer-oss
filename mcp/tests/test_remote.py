"""The remote connector: toolset filtering, its settings, and the Access guard in front of the
streamable HTTP app. Assertions are signed with a key made here and resolved without a network
call; MCP requests go through Starlette's test client."""

from __future__ import annotations

import datetime as dt
from collections.abc import Iterator
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from starlette.testclient import TestClient
from support import API_TOKEN, FakeOrganizer

from organizer_mcp import remote, server
from organizer_mcp.config import ConfigError
from organizer_mcp.tools import jobs, reminders

# What `all` serves: every tool but the opt-in mail toolset's.
DEFAULT_TOOLS = {"calendar", "calendar_sources"} | jobs.TOOLS | reminders.TOOLS
PUBLIC_HOST = "organizer-mcp.example.com"
ISSUER = "https://team.cloudflareaccess.com"
AUD = "aud-tag-0123456789"
EMAIL = "owner@example.com"
ENV = {
    "MCP_PUBLIC_HOST": PUBLIC_HOST,
    "CF_ACCESS_TEAM_DOMAIN": "team.cloudflareaccess.com",
    "CF_ACCESS_AUD": AUD,
    "MCP_ALLOWED_EMAIL": EMAIL,
}
MCP_HEADERS = {"accept": "application/json, text/event-stream", "content-type": "application/json"}

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def assertion(key: Any = KEY, **overrides: Any) -> str:
    now = dt.datetime.now(dt.UTC)
    claims = {
        "aud": [AUD],
        "iss": ISSUER,
        "email": EMAIL,
        "iat": now,
        "exp": now + dt.timedelta(minutes=5),
        "sub": "user-1",
        "type": "app",
    }
    claims.update(overrides)
    claims = {name: value for name, value in claims.items() if value is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "k1"})


def settings(**env: str) -> remote.RemoteSettings:
    return remote.load_remote_settings({**ENV, **env})


@pytest.fixture
def http(organizer: FakeOrganizer) -> Iterator[TestClient]:
    app = remote.build_app(settings(), resolve_key=lambda token: KEY.public_key())
    with TestClient(app, base_url=f"https://{PUBLIC_HOST}") as client:
        yield client


def rpc(
    client: TestClient,
    method: str,
    params: dict[str, Any] | None = None,
    path: str = "/mcp",
    **headers: str,
):
    body = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    return client.post(path, json=body, headers={**MCP_HEADERS, **headers})


def authed(**overrides: Any) -> dict[str, str]:
    return {"cf-access-jwt-assertion": assertion(**overrides)}


# ----------------------------------------------------------------------------- toolsets


def test_build_mcp_serves_only_the_selected_tools_with_hints() -> None:
    mcp = remote.build_mcp(settings(ORGANIZER_MCP_TOOLSETS="mail"))
    tools = {tool.name: tool for tool in mcp._tool_manager.list_tools()}
    assert set(tools) == {"emails", "email"}
    assert tools["emails"].annotations.readOnlyHint is True
    assert tools["emails"].parameters == server.app._tool_manager.get_tool("emails").parameters
    assert mcp.instructions == server.app.instructions


def test_the_default_leaves_mail_out() -> None:
    mcp = remote.build_mcp(settings())
    assert {tool.name for tool in mcp._tool_manager.list_tools()} == DEFAULT_TOOLS


# ----------------------------------------------------------------------------- settings


def test_settings_require_every_access_value() -> None:
    for name in remote.REQUIRED:
        with pytest.raises(ConfigError, match=name):
            remote.load_remote_settings({**ENV, name: " "})


def test_settings_defaults_and_normalising() -> None:
    loaded = settings(
        CF_ACCESS_TEAM_DOMAIN="https://team.cloudflareaccess.com/",
        MCP_PUBLIC_HOST="Organizer-MCP.example.com",
    )
    assert (loaded.host, loaded.port) == ("127.0.0.1", 8601)
    assert loaded.issuer == ISSUER
    assert loaded.public_host == PUBLIC_HOST
    assert loaded.read_only is False
    assert loaded.toolsets == {"calendar", "jobs", "reminders"}


def test_settings_for_the_mail_container() -> None:
    loaded = settings(
        ORGANIZER_MCP_TOOLSETS="mail", ORGANIZER_MCP_READ_ONLY="1", MCP_HOST="0.0.0.0"
    )
    assert loaded.toolsets == {"mail"} and loaded.read_only and loaded.host == "0.0.0.0"


@pytest.mark.parametrize(
    ("env", "message"),
    [
        ({"MCP_PORT": "eighty"}, "MCP_PORT"),
        ({"ORGANIZER_MCP_TOOLSETS": "email"}, "ORGANIZER_MCP_TOOLSETS"),
        ({"ORGANIZER_MCP_READ_ONLY": "yes"}, "ORGANIZER_MCP_READ_ONLY"),
        ({"MCP_ALLOWED_EMAIL": "owner"}, "email address"),
    ],
)
def test_settings_refuse_bad_values(env: dict[str, str], message: str) -> None:
    with pytest.raises(ConfigError, match=message):
        settings(**env)


def test_main_refuses_to_start_without_the_token(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    started: list[Any] = []
    monkeypatch.setattr(remote.uvicorn, "run", lambda *a, **k: started.append(a))
    for name, value in {**ENV, "ORGANIZER_MCP_TOOLSETS": "mail"}.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setenv("ORGANIZER_TOKEN", "general")
    monkeypatch.delenv("ORGANIZER_MAIL_TOKEN", raising=False)
    with pytest.raises(SystemExit):
        remote.main()
    assert "ORGANIZER_MAIL_TOKEN is not set" in capsys.readouterr().err
    assert started == []


# ----------------------------------------------------------------------------- the guard


def test_no_assertion_is_refused(http: TestClient, organizer: FakeOrganizer) -> None:
    response = rpc(http, "tools/list")
    assert response.status_code == 401
    assert organizer.requests == []


@pytest.mark.parametrize(
    "token",
    [
        assertion(key=OTHER_KEY),
        assertion(aud=["another-app"]),
        assertion(iss="https://other.cloudflareaccess.com"),
        assertion(exp=dt.datetime.now(dt.UTC) - dt.timedelta(minutes=5)),
        assertion(email="someone@example.com"),
        assertion(email=None),
        "not-a-jwt",
    ],
    ids=["other key", "other aud", "other issuer", "expired", "other email", "no email", "junk"],
)
def test_bad_assertions_are_refused(http: TestClient, token: str) -> None:
    response = rpc(http, "tools/list", **{"cf-access-jwt-assertion": token})
    assert response.status_code == 401
    assert response.json() == {"detail": "Cloudflare Access assertion missing or invalid"}


def test_unknown_host_is_refused_even_with_a_valid_assertion(http: TestClient) -> None:
    response = rpc(http, "tools/list", host="127.0.0.1:8601", **authed())
    assert response.status_code == 421


def test_email_matches_without_case(http: TestClient) -> None:
    response = rpc(http, "tools/list", **authed(email=EMAIL.upper()))
    assert response.status_code == 200


def test_valid_assertion_reaches_the_tools(http: TestClient) -> None:
    initialize = rpc(
        http,
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "0"},
        },
        **authed(),
    )
    assert initialize.status_code == 200
    assert initialize.json()["result"]["serverInfo"]["name"] == "organizer"

    listed = rpc(http, "tools/list", **authed())
    assert listed.status_code == 200
    assert {tool["name"] for tool in listed.json()["result"]["tools"]} == DEFAULT_TOOLS


def test_a_tool_call_goes_to_the_organizer_with_its_token(
    http: TestClient, organizer: FakeOrganizer
) -> None:
    organizer.reply("GET", "/api/calendar/sources", [])
    response = rpc(http, "tools/call", {"name": "calendar_sources", "arguments": {}}, **authed())
    assert response.status_code == 200
    assert response.json()["result"]["isError"] is False
    request = organizer.only("GET", "/api/calendar/sources")
    assert request.headers["authorization"] == f"Bearer {API_TOKEN}"
    assert "x-author" not in request.headers


def test_root_serves_mcp_too(http: TestClient) -> None:
    assert rpc(http, "tools/list", path="/").status_code == 401
    listed = rpc(http, "tools/list", path="/", **authed())
    assert listed.status_code == 200
    assert {tool["name"] for tool in listed.json()["result"]["tools"]} == DEFAULT_TOOLS


def test_other_paths_need_the_assertion_before_a_404(http: TestClient) -> None:
    assert http.get("/admin").status_code == 401
    assert http.get("/admin", headers=authed()).status_code == 404
