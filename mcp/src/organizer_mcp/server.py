"""The organizer as Claude tools: FastMCP over stdio (Claude Code), or streamable HTTP.

Each tool is a thin call to the organizer's REST API with a scoped API token; the token fixes
the author of any write on the server. Run with `organizer-mcp` for stdio, or `organizer-mcp
http` for the claude.ai connector behind Cloudflare Access (organizer_mcp.remote).

Settings (organizer_mcp.config): ORGANIZER_URL, ORGANIZER_TIMEOUT, ORGANIZER_TOKEN and, for the
mail toolset only, ORGANIZER_MAIL_TOKEN. ORGANIZER_MCP_TOOLSETS chooses the toolsets (`all`, the
default, is every toolset but the opt-in `mail`); ORGANIZER_MCP_READ_ONLY=1 drops the writes.

The tools live in organizer_mcp/tools/<name>.py, the shared app, client and helpers in
organizer_mcp.core. This module is the entry point and re-exports `app`, `client`, `use_client`
and every tool function, so `server.<name>` works in tests.
"""

import os
import sys
from collections.abc import Iterable

from organizer_mcp import toolsets
from organizer_mcp.config import ConfigError, load_settings, require_tokens
from organizer_mcp.core import app, client, use_client
from organizer_mcp.tools import MODULES
from organizer_mcp.tools.calendar import calendar, calendar_sources
from organizer_mcp.tools.mail import email, emails

__all__ = [
    "MODULES",
    "app",
    "calendar",
    "calendar_sources",
    "client",
    "email",
    "emails",
    "main",
    "serve_only",
    "use_client",
]


def main() -> None:
    if sys.argv[1:] == ["http"]:
        from organizer_mcp import remote

        remote.main()
        return
    try:
        settings = load_settings()
        read_only = toolsets.parse_read_only(os.environ.get(toolsets.READ_ONLY_ENV))
        chosen = toolsets.choose(os.environ.get(toolsets.TOOLSETS_ENV), read_only)
        require_tokens(settings, toolsets.required_scopes(chosen))
    except ConfigError as exc:
        sys.stderr.write(f"organizer-mcp: {exc}\n")
        raise SystemExit(2) from exc
    serve_only(chosen, read_only)
    app.run(transport="stdio")


def serve_only(chosen: Iterable[str], read_only: bool = False) -> list[str]:
    """Remove the tools the chosen toolsets leave out (and the writes, when read-only) from the
    stdio app. Returns the removed tools' names."""
    registered = [tool.name for tool in app._tool_manager.list_tools()]
    keep = set(toolsets.selected_tools(registered, chosen, read_only))
    dropped = [name for name in registered if name not in keep]
    for name in dropped:
        app.remove_tool(name)
    return dropped
