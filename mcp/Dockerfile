# syntax=docker/dockerfile:1
# The organizer MCP server over streamable HTTP, for the claude.ai connector behind Cloudflare
# Access (docs/MCP.md). Built by docker-compose.yml with mcp/ as the context.
FROM python:3.12-slim-bookworm
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PYTHONUNBUFFERED=1

WORKDIR /app/mcp
# Dependencies first, so code changes do not reinstall them.
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src/ ./src/
RUN uv sync --frozen --no-dev

# Inside the container it listens on every interface; compose publishes the port on the host's
# loopback only, so a tunnel on that host (or on the compose network) is the one way in.
ENV PATH="/app/mcp/.venv/bin:$PATH" \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8601
# Nothing here needs root: the image holds no secrets and writes nothing.
USER 65534:65534
EXPOSE 8601

# Up means listening. Every unauthenticated request gets a 401 or 421, so a TCP connect is the probe.
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s \
  CMD python -c "import os, socket; socket.create_connection(('127.0.0.1', int(os.environ.get('MCP_PORT', '8601'))), 4)"

CMD ["organizer-mcp", "http"]
