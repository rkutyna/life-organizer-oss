# organizer-mcp

The organizer's MCP server: Claude reads your calendar (and, on a server set up for it, your mail)
through the organizer's REST API with a scoped API token. Setup, toolsets and the mail safety
rule are in [docs/MCP.md](../docs/MCP.md).

```bash
uv sync && uv run ruff check . && uv run ruff format --check . && uv run pytest
uv run organizer-mcp           # stdio, for Claude Code (needs ORGANIZER_TOKEN)
uv run organizer-mcp http      # streamable HTTP behind Cloudflare Access
```
