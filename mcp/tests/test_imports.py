"""Every module imports on its own, first, in a fresh interpreter: no import cycle depends on
something else having been imported before it. Whatever is imported first, every tool ends up
registered, in the same order."""

from __future__ import annotations

import json
import subprocess
import sys

import pytest

from organizer_mcp import server
from organizer_mcp.tools import MODULE_NAMES

ENTRY_POINTS = [
    "organizer_mcp.core",
    "organizer_mcp.server",
    "organizer_mcp.toolsets",
    "organizer_mcp.remote",
    "organizer_mcp.tools",
    *(f"organizer_mcp.tools.{name}" for name in MODULE_NAMES),
]

PROBE = """
import importlib, json, sys
importlib.import_module(sys.argv[1])
from organizer_mcp.core import app
print(json.dumps([tool.name for tool in app._tool_manager.list_tools()]))
"""


@pytest.mark.parametrize("module", ENTRY_POINTS)
def test_a_module_imports_first_in_a_fresh_interpreter(module: str) -> None:
    done = subprocess.run(
        [sys.executable, "-c", PROBE, module], capture_output=True, text=True, timeout=60
    )
    assert done.returncode == 0, done.stderr
    registered = [tool.name for tool in server.app._tool_manager.list_tools()]
    # core is the plumbing the tools register on; it imports no tool module.
    assert json.loads(done.stdout) == ([] if module == "organizer_mcp.core" else registered)
