"""The FastMCP surface and the stdio entry point: the tool list, the instructions, one call
through the protocol layer, and the startup checks on toolsets and tokens."""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from support import FakeOrganizer

from organizer_mcp import server, toolsets

CALENDAR_TOOLS = ["calendar", "calendar_sources"]
MAIL_TOOLS = ["emails", "email"]
JOBS_TOOLS = [
    "applications",
    "leads",
    "companies",
    "contacts",
    "interviews",
    "job_events",
    "pipeline",
    "job_statuses",
    "weekly_goals",
    "add_application",
    "set_application_status",
    "add_lead",
    "mark_applied",
    "drop_lead",
    "update_company",
    "add_contact",
    "update_contact",
    "add_interview",
    "update_interview",
    "add_job_event",
    "update_job_event",
    "set_weekly_goal",
]
REMINDER_TOOLS = [
    "reminders",
    "reminder_lists",
    "add_reminder",
    "complete_reminder",
    "update_reminder",
]
EXPECTED_TOOLS = CALENDAR_TOOLS + MAIL_TOOLS + JOBS_TOOLS + REMINDER_TOOLS


def listed() -> dict[str, Any]:
    return {tool.name: tool for tool in asyncio.run(server.app.list_tools())}


def test_all_tools_are_registered_in_order_and_described() -> None:
    tools = listed()
    assert list(tools) == EXPECTED_TOOLS
    for name, tool in tools.items():
        assert tool.description and len(tool.description) > 60, name
        assert tool.annotations.readOnlyHint is (name not in toolsets.WRITE_TOOLS), name


def test_instructions_name_no_one() -> None:
    text = server.app.instructions
    assert text.startswith("Your organizer")
    assert "owner" in text


def test_an_api_error_reaches_claude_as_a_tool_error(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/mail/messages/99", {"detail": "message 99 not found"}, 404)
    with pytest.raises(ToolError, match="message 99 not found"):
        asyncio.run(server.app.call_tool("email", {"id": 99}))


def test_serve_only_removes_the_tools_left_out(monkeypatch: pytest.MonkeyPatch) -> None:
    removed: list[str] = []
    monkeypatch.setattr(server.app, "remove_tool", removed.append)

    assert server.serve_only(toolsets.choose(None, False)) == ["emails", "email"]
    assert removed == ["emails", "email"]
    assert server.serve_only(toolsets.choose("mail", False)) == (
        CALENDAR_TOOLS + JOBS_TOOLS + REMINDER_TOOLS
    )
    assert server.serve_only(toolsets.choose("calendar,mail", False)) == (
        JOBS_TOOLS + REMINDER_TOOLS
    )
    assert server.serve_only(toolsets.choose("all,mail", True)) == []


@pytest.fixture
def run(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """main() with the stdio loop stubbed out; returns the transports it was started with."""
    started: list[str] = []
    monkeypatch.setattr(server.app, "run", lambda transport: started.append(transport))
    monkeypatch.setattr(server.app, "remove_tool", lambda name: None)
    monkeypatch.setattr("sys.argv", ["organizer-mcp"])
    for name in (
        "ORGANIZER_URL",
        "ORGANIZER_TOKEN",
        "ORGANIZER_MAIL_TOKEN",
        "ORGANIZER_MCP_TOOLSETS",
        "ORGANIZER_MCP_READ_ONLY",
    ):
        monkeypatch.delenv(name, raising=False)
    return started


def test_main_needs_the_api_token(
    run: list[str], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit) as info:
        server.main()
    assert info.value.code == 2
    err = capsys.readouterr().err
    assert "ORGANIZER_TOKEN is not set" in err and "Settings → API tokens" in err
    assert run == []

    monkeypatch.setenv("ORGANIZER_TOKEN", "t")
    server.main()
    assert run == ["stdio"]


def test_main_for_mail_needs_only_the_mail_token(
    run: list[str], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ORGANIZER_MCP_TOOLSETS", "mail")
    monkeypatch.setenv("ORGANIZER_TOKEN", "t")
    with pytest.raises(SystemExit):
        server.main()
    assert "ORGANIZER_MAIL_TOKEN is not set" in capsys.readouterr().err

    monkeypatch.delenv("ORGANIZER_TOKEN")
    monkeypatch.setenv("ORGANIZER_MAIL_TOKEN", "m")
    server.main()
    assert run == ["stdio"]


@pytest.mark.parametrize(
    ("toolsets_env", "message"),
    [("email", "unknown toolset"), ("calendar,later", "unknown toolset")],
)
def test_main_refuses_bad_toolsets(
    run: list[str],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    toolsets_env: str,
    message: str,
) -> None:
    monkeypatch.setenv("ORGANIZER_TOKEN", "t")
    monkeypatch.setenv("ORGANIZER_MCP_TOOLSETS", toolsets_env)
    with pytest.raises(SystemExit):
        server.main()
    assert message in capsys.readouterr().err
    assert run == []
