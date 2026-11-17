"""The tool modules: the registry of toolsets.

Each module registers its tools on `organizer_mcp.core.app` when imported and declares, beside
them:

  TOOLSET  the toolset it belongs to (two modules may share one)
  SCOPE    the API token scope its calls need: "api", or "mail" for the mail toolset only
  TOOLS    the names it registers
  WRITES   those of TOOLS that change something

organizer_mcp.toolsets derives the toolsets from these declarations, and a test fails if a
registered tool is undeclared or a declared one is missing.

Adding a toolset (jobs is next) is one line: write tools/<name>.py with the
declarations above, then add "<name>" to MODULE_NAMES. Order matters: it is the order tools are
listed in, and a module may import an earlier one, never a later one.
"""

from __future__ import annotations

import importlib
from types import ModuleType

MODULE_NAMES = (
    "calendar",
    "mail",
    "jobs",
    "reminders",
)

MODULES: tuple[ModuleType, ...] = tuple(
    importlib.import_module(f"{__name__}.{name}") for name in MODULE_NAMES
)
