"""The organizer tools over streamable HTTP, for the claude.ai custom connector.

Run with `organizer-mcp http`. It serves the same tool functions as the stdio server, filtered by
toolset, at `/mcp` (and `/`) on MCP_HOST:MCP_PORT, behind AccessGuard. Cloudflare Access does the
OAuth; this process only trusts Access's signed assertion. The layout is in docs/MCP.md.

The organizer token it is given fixes the author of its writes: make it with author
`claude_remote`, so the organizer's history tells the connector from Claude Code.

Settings, beyond those in organizer_mcp.config:
  MCP_PUBLIC_HOST         the connector's hostname, e.g. organizer-mcp.example.com (required)
  CF_ACCESS_TEAM_DOMAIN   e.g. <team>.cloudflareaccess.com (required)
  CF_ACCESS_AUD           the Access application's AUD tag (required)
  MCP_ALLOWED_EMAIL       the one identity allowed through (required)
  ORGANIZER_MCP_TOOLSETS  `all` (default; leaves out the opt-in `mail`) or a comma list
  ORGANIZER_MCP_READ_ONLY `1` drops every write tool
  MCP_HOST, MCP_PORT      bind address, default 127.0.0.1 and 8601 (0.0.0.0 in a container)
"""

from __future__ import annotations

import logging
import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass

import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from starlette.types import ASGIApp, Receive, Scope, Send

from organizer_mcp import server, toolsets
from organizer_mcp.access import (
    AccessGuard,
    AccessVerifier,
    KeyResolver,
    jwks_resolver,
    team_issuer,
)
from organizer_mcp.config import ConfigError, load_settings, require_tokens

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8601
MCP_PATH = "/mcp"
REQUIRED = ("MCP_PUBLIC_HOST", "CF_ACCESS_TEAM_DOMAIN", "CF_ACCESS_AUD", "MCP_ALLOWED_EMAIL")


@dataclass(frozen=True)
class RemoteSettings:
    host: str
    port: int
    public_host: str
    issuer: str
    audience: str
    allowed_email: str
    toolsets: frozenset[str]
    read_only: bool


def load_remote_settings(env: Mapping[str, str] | None = None) -> RemoteSettings:
    source = os.environ if env is None else env
    values = {name: (source.get(name) or "").strip() for name in REQUIRED}
    missing = [name for name, value in values.items() if not value]
    if missing:
        raise ConfigError(
            f"{', '.join(missing)} must be set for the HTTP server; it never serves without Access"
        )
    if "@" not in values["MCP_ALLOWED_EMAIL"]:
        raise ConfigError("MCP_ALLOWED_EMAIL must be an email address")

    raw_port = (source.get("MCP_PORT") or "").strip()
    try:
        port = int(raw_port) if raw_port else DEFAULT_PORT
    except ValueError as exc:
        raise ConfigError(f"MCP_PORT must be a port number, got {raw_port!r}") from exc

    read_only = toolsets.parse_read_only(source.get(toolsets.READ_ONLY_ENV))
    chosen = toolsets.choose(source.get(toolsets.TOOLSETS_ENV), read_only)

    return RemoteSettings(
        host=(source.get("MCP_HOST") or DEFAULT_HOST).strip(),
        port=port,
        public_host=values["MCP_PUBLIC_HOST"].lower(),
        issuer=team_issuer(values["CF_ACCESS_TEAM_DOMAIN"]),
        audience=values["CF_ACCESS_AUD"],
        allowed_email=values["MCP_ALLOWED_EMAIL"],
        toolsets=chosen,
        read_only=read_only,
    )


def build_mcp(settings: RemoteSettings) -> FastMCP:
    """A new FastMCP holding the selected tools of the stdio server, with read-only hints."""
    remote = FastMCP(
        "organizer",
        instructions=server.app.instructions,
        stateless_http=True,
        json_response=True,
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
    registered = {tool.name: tool for tool in server.app._tool_manager.list_tools()}
    for name in toolsets.selected_tools(registered, settings.toolsets, settings.read_only):
        tool = registered[name]
        remote.add_tool(
            tool.fn,
            name=tool.name,
            title=tool.title,
            description=tool.description,
            annotations=tool.annotations
            or ToolAnnotations(readOnlyHint=name not in toolsets.WRITE_TOOLS),
        )
    return remote


def serve_root_too(app: ASGIApp) -> ASGIApp:
    """Answer MCP at `/` as well as `/mcp`.

    Claude requires the protected-resource metadata's `resource` to equal the connector URL,
    path included, and Access may advertise the bare hostname. If sign-in fails with `.../mcp`,
    the bare hostname works with no rebuild.
    """

    async def aliased(scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and scope["path"] == "/":
            scope = {**scope, "path": MCP_PATH, "raw_path": MCP_PATH.encode()}
        await app(scope, receive, send)

    return aliased


def build_app(settings: RemoteSettings, resolve_key: KeyResolver | None = None) -> ASGIApp:
    verifier = AccessVerifier(
        issuer=settings.issuer,
        audience=settings.audience,
        allowed_email=settings.allowed_email,
        resolve_key=resolve_key or jwks_resolver(settings.issuer),
    )
    return AccessGuard(
        serve_root_too(build_mcp(settings).streamable_http_app()),
        verifier,
        allowed_host=settings.public_host,
    )


def main() -> None:
    try:
        organizer = load_settings()
        settings = load_remote_settings()
        require_tokens(organizer, toolsets.required_scopes(settings.toolsets))
    except ConfigError as exc:
        sys.stderr.write(f"organizer-mcp http: {exc}\n")
        raise SystemExit(2) from exc
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("organizer_mcp.access").info(
        "serving toolsets %s%s on %s:%s for %s",
        ",".join(sorted(settings.toolsets)),
        " (read-only)" if settings.read_only else "",
        settings.host,
        settings.port,
        settings.public_host,
    )
    uvicorn.run(build_app(settings), host=settings.host, port=settings.port, log_level="info")
