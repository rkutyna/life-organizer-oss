"""Which toolset each tool belongs to, which tools write, and which toolsets a server serves.

ORGANIZER_MCP_TOOLSETS chooses the toolsets (over stdio and over HTTP alike), and
ORGANIZER_MCP_READ_ONLY=1 drops the writes. Both work from the declarations beside the tools in
organizer_mcp/tools/<name>.py (TOOLSET, SCOPE, TOOLS, WRITES), not from lists kept here by hand.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from types import ModuleType

from organizer_mcp.config import ConfigError
from organizer_mcp.tools import MODULES

TOOLSETS_ENV = "ORGANIZER_MCP_TOOLSETS"
READ_ONLY_ENV = "ORGANIZER_MCP_READ_ONLY"


def derive(
    modules: Iterable[ModuleType],
) -> tuple[dict[str, frozenset[str]], frozenset[str], dict[str, str]]:
    """(TOOLSETS, WRITE_TOOLS, SCOPES) from the modules' declarations.

    Modules that share a TOOLSET are merged, and must share its SCOPE; the sets keep the order
    they first appear in. A tool declared by two modules, or a write that is not one of its
    module's tools, is an error.
    """
    toolsets: dict[str, frozenset[str]] = {}
    scopes: dict[str, str] = {}
    writes: set[str] = set()
    owner: dict[str, str] = {}
    for module in modules:
        name = module.__name__
        tools: frozenset[str] = module.TOOLS
        for tool in tools:
            if tool in owner:
                raise ValueError(f"{tool} is declared by both {owner[tool]} and {name}")
            owner[tool] = name
        stray = module.WRITES - tools
        if stray:
            raise ValueError(f"{name} declares writes it does not have: {', '.join(sorted(stray))}")
        toolset = module.TOOLSET
        if scopes.setdefault(toolset, module.SCOPE) != module.SCOPE:
            raise ValueError(
                f"toolset {toolset} mixes the {scopes[toolset]} and {module.SCOPE} scopes"
            )
        toolsets[toolset] = toolsets.get(toolset, frozenset()) | tools
        writes |= module.WRITES
    return toolsets, frozenset(writes), scopes


TOOLSETS, WRITE_TOOLS, SCOPES = derive(MODULES)

# Toolsets `all` leaves out: each must be named to be served. Mail is here because every word of
# it is written by strangers, so it should reach only a session that asked for it.
OPT_IN = frozenset({"mail"})

# Toolsets the organizer will have but this version does not serve yet. Naming one is a clear
# error rather than "unknown"; a planned set drops out of here as soon as its module exists.
PLANNED = frozenset({"reminders", "jobs"}) - set(TOOLSETS)


class UnknownToolset(ValueError):
    """ORGANIZER_MCP_TOOLSETS named a set that does not exist."""


class MailNotIsolated(ValueError):
    """ORGANIZER_MCP_TOOLSETS put mail beside tools that write."""


def parse_toolsets(raw: str | None) -> frozenset[str]:
    """`all` (or empty) for every set but the opt-in ones, otherwise a comma-separated list of
    set names, which may include `all` (`all,mail` is everything)."""
    names = {part.strip().lower() for part in (raw or "").split(",") if part.strip()}
    if not names:
        names = {"all"}
    if "all" in names:
        names = (names - {"all"}) | (set(TOOLSETS) - OPT_IN)
    choices = (
        f"choose from all, {', '.join(TOOLSETS)} ({', '.join(sorted(OPT_IN))} only when named)"
    )
    planned = names & PLANNED
    if planned:
        raise UnknownToolset(
            f"toolset(s) {', '.join(sorted(planned))} are not in this version yet; {choices}"
        )
    unknown = names - set(TOOLSETS)
    if unknown:
        raise UnknownToolset(f"unknown toolset(s) {', '.join(sorted(unknown))}; {choices}")
    return frozenset(names)


def parse_read_only(raw: str | None) -> bool:
    value = (raw or "").strip().lower()
    if value not in ("", "0", "1", "false", "true"):
        raise ConfigError(f"{READ_ONLY_ENV} must be 0 or 1, got {value!r}")
    return value in ("1", "true")


def check_mail_isolation(
    toolsets: Iterable[str],
    read_only: bool,
    *,
    sets: Mapping[str, frozenset[str]] | None = None,
    writes: frozenset[str] | None = None,
) -> None:
    """Mail is served only where no write tool is: alone, beside read-only sets, or with
    ORGANIZER_MCP_READ_ONLY=1.

    An email can carry instructions; a server that holds both mail and writes would let one
    email ask Claude to change the owner's records in the same breath. So this is refused at
    startup, not left to a default. `sets` and `writes` default to the real declarations."""
    sets = TOOLSETS if sets is None else sets
    writes = WRITE_TOOLS if writes is None else writes
    chosen = set(toolsets)
    if "mail" not in chosen or read_only:
        return
    found = sorted(set().union(*(sets[t] for t in chosen)) & writes)
    if found:
        raise MailNotIsolated(
            f"mail is served only without write tools: set {TOOLSETS_ENV}=mail (or add "
            f"{READ_ONLY_ENV}=1); these would write: {', '.join(found[:6])}"
            + ("..." if len(found) > 6 else "")
        )


def choose(raw_toolsets: str | None, read_only: bool) -> frozenset[str]:
    """The toolsets to serve, checked, or a ConfigError naming the variable."""
    try:
        chosen = parse_toolsets(raw_toolsets)
        check_mail_isolation(chosen, read_only)
    except (UnknownToolset, MailNotIsolated) as exc:
        raise ConfigError(f"{TOOLSETS_ENV}: {exc}") from exc
    return chosen


def required_scopes(toolsets: Iterable[str]) -> frozenset[str]:
    """The API token scopes the chosen toolsets call with."""
    return frozenset(SCOPES[name] for name in toolsets)


def selected_tools(available: Iterable[str], toolsets: Iterable[str], read_only: bool) -> list[str]:
    """The tools to serve, in the order they were registered."""
    allowed: set[str] = set()
    for name in toolsets:
        allowed |= TOOLSETS[name]
    if read_only:
        allowed -= WRITE_TOOLS
    return [name for name in available if name in allowed]
