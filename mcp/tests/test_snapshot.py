"""The MCP surface as Claude sees it, pinned: every tool's name, description, input and output
schema and annotations, in registration order, plus the server's name and instructions.

A deliberate change to a tool regenerates it:

    uv run python tests/test_snapshot.py
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from organizer_mcp import server

SNAPSHOT = Path(__file__).with_name("tool_snapshot.json")


def current() -> dict[str, Any]:
    tools = asyncio.run(server.app.list_tools())
    return {
        "name": server.app.name,
        "instructions": server.app.instructions,
        "tools": [tool.model_dump(mode="json", exclude_none=True) for tool in tools],
    }


def test_the_tool_surface_matches_the_snapshot() -> None:
    expected = json.loads(SNAPSHOT.read_text())
    actual = current()
    assert [t["name"] for t in actual["tools"]] == [t["name"] for t in expected["tools"]]
    assert actual == expected


if __name__ == "__main__":
    SNAPSHOT.write_text(json.dumps(current(), indent=2, sort_keys=True) + "\n")
    print(f"wrote {SNAPSHOT}")
