"""The toolsets are derived from the declarations beside the tools, and those declarations must
match what is registered. Choosing toolsets: `all`, the opt-in mail set, sets not built yet, and
the rule that mail is never served beside a write tool."""

from __future__ import annotations

from types import ModuleType

import pytest

from organizer_mcp import server, toolsets
from organizer_mcp.config import ConfigError
from organizer_mcp.tools import MODULES


def registered() -> dict[str, str]:
    """Each registered tool's name and the module its function is defined in."""
    return {tool.name: tool.fn.__module__ for tool in server.app._tool_manager.list_tools()}


def fake(
    name: str, toolset: str, tools: set[str], writes: set[str] = frozenset(), scope: str = "api"
) -> ModuleType:
    module = ModuleType(name)
    module.TOOLSET = toolset
    module.SCOPE = scope
    module.TOOLS = frozenset(tools)
    module.WRITES = frozenset(writes)
    return module


# ----------------------------------------------------------------------------- declarations


def test_every_registered_tool_is_declared_and_every_declared_tool_is_registered() -> None:
    declared = set().union(*toolsets.TOOLSETS.values())
    tools = set(registered())
    assert tools - declared == set(), "registered but in no module's TOOLS"
    assert declared - tools == set(), "declared in TOOLS but not registered"


def test_each_module_declares_exactly_the_tools_it_defines() -> None:
    where = registered()
    for module in MODULES:
        defined = {name for name, owner in where.items() if owner == module.__name__}
        assert defined == module.TOOLS, module.__name__
        assert module.WRITES <= module.TOOLS, module.__name__
        assert module.SCOPE in ("api", "mail"), module.__name__


def test_the_toolsets_of_this_version() -> None:
    assert {
        "calendar": {"calendar", "calendar_sources"},
        "mail": {"emails", "email"},
    } == toolsets.TOOLSETS
    assert frozenset() == toolsets.WRITE_TOOLS
    assert toolsets.SCOPES == {"calendar": "api", "mail": "mail"}
    assert {"reminders", "jobs"} == toolsets.PLANNED


def test_derive_refuses_a_tool_declared_twice() -> None:
    with pytest.raises(ValueError, match="x is declared by both a and b"):
        toolsets.derive([fake("a", "one", {"x"}), fake("b", "two", {"x", "y"})])


def test_derive_refuses_a_write_the_module_does_not_have() -> None:
    with pytest.raises(ValueError, match="a declares writes it does not have: z"):
        toolsets.derive([fake("a", "one", {"x"}, {"z"})])


def test_derive_refuses_a_toolset_with_two_scopes() -> None:
    with pytest.raises(ValueError, match="toolset one mixes the api and mail scopes"):
        toolsets.derive([fake("a", "one", {"x"}), fake("b", "one", {"y"}, scope="mail")])


def test_derive_keeps_first_seen_order_and_merges() -> None:
    sets, writes, scopes = toolsets.derive(
        [fake("a", "one", {"x"}), fake("b", "two", {"y"}, {"y"}), fake("c", "one", {"z"})]
    )
    assert list(sets) == ["one", "two"]
    assert sets == {"one": {"x", "z"}, "two": {"y"}}
    assert writes == {"y"}
    assert scopes == {"one": "api", "two": "api"}


# ----------------------------------------------------------------------------- choosing


def test_parse_toolsets() -> None:
    everything_but_mail = set(toolsets.TOOLSETS) - {"mail"}
    assert toolsets.parse_toolsets(None) == everything_but_mail == {"calendar"}
    assert toolsets.parse_toolsets(" all ") == everything_but_mail
    assert toolsets.parse_toolsets("all, Mail") == set(toolsets.TOOLSETS)
    assert toolsets.parse_toolsets("mail") == {"mail"}
    assert toolsets.parse_toolsets("Calendar") == {"calendar"}
    with pytest.raises(toolsets.UnknownToolset, match="unknown toolset.*email"):
        toolsets.parse_toolsets("calendar,email")


@pytest.mark.parametrize("name", ["reminders", "jobs", "calendar,Jobs"])
def test_a_planned_toolset_says_it_is_not_built_yet(name: str) -> None:
    with pytest.raises(toolsets.UnknownToolset, match="not in this version yet; choose from all"):
        toolsets.parse_toolsets(name)


def test_read_only_flag() -> None:
    assert toolsets.parse_read_only(None) is False
    assert toolsets.parse_read_only(" 1 ") is True
    assert toolsets.parse_read_only("true") is True
    assert toolsets.parse_read_only("0") is False
    with pytest.raises(ConfigError, match="ORGANIZER_MCP_READ_ONLY"):
        toolsets.parse_read_only("yes")


def test_required_scopes() -> None:
    assert toolsets.required_scopes({"calendar"}) == {"api"}
    assert toolsets.required_scopes({"mail"}) == {"mail"}
    assert toolsets.required_scopes({"calendar", "mail"}) == {"api", "mail"}


# A world with a write tool, as later toolsets (reminders, jobs) will bring.
SETS = {"mail": frozenset({"emails", "email"}), "todo": frozenset({"todos", "add_todo"})}
WRITES = frozenset({"add_todo"})


@pytest.mark.parametrize(
    ("chosen", "read_only", "refused"),
    [
        ({"mail"}, False, False),
        ({"todo"}, False, False),
        ({"mail", "todo"}, False, True),
        ({"mail", "todo"}, True, False),
    ],
)
def test_mail_is_never_served_beside_a_write(
    chosen: set[str], read_only: bool, refused: bool
) -> None:
    def check() -> None:
        toolsets.check_mail_isolation(chosen, read_only, sets=SETS, writes=WRITES)

    if refused:
        with pytest.raises(toolsets.MailNotIsolated, match="only without write tools.*add_todo"):
            check()
    else:
        check()


def test_mail_beside_the_read_only_calendar_is_allowed() -> None:
    assert toolsets.choose("all,mail", read_only=False) == {"calendar", "mail"}


def test_choose_names_the_variable() -> None:
    with pytest.raises(ConfigError, match="^ORGANIZER_MCP_TOOLSETS: unknown toolset"):
        toolsets.choose("email", read_only=False)


def test_selected_tools_keep_registration_order() -> None:
    available = [tool.name for tool in server.app._tool_manager.list_tools()]
    assert toolsets.selected_tools(available, {"calendar", "mail"}, False) == available
    assert toolsets.selected_tools(available, {"mail"}, False) == ["emails", "email"]
