# syntax=docker/dockerfile:1
# One image: build the web app, then the Python app that serves it and the API.
# Build from the repo root:  docker compose build

# ---- web: React PWA -> /app/web/dist ---------------------------------------------------
FROM node:22-alpine AS web
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# ---- app: FastAPI + SQLite --------------------------------------------------------------
FROM python:3.12-slim-bookworm AS app
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PYTHONUNBUFFERED=1

RUN useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin organizer

WORKDIR /app/server
# Dependencies first, so code changes do not reinstall them.
COPY server/pyproject.toml server/uv.lock server/.python-version ./
RUN uv sync --frozen --no-dev --no-install-project

COPY server/ ./
COPY --from=web /app/web/dist /app/web/dist
RUN rm -rf data && mkdir -p data && chown organizer:organizer data

ENV PATH="/app/server/.venv/bin:$PATH" \
    WEB_DIST=/app/web/dist \
    DATABASE_URL=sqlite:////app/server/data/organizer.db

USER organizer
# The SQLite database lives in this volume (see docker-compose.yml).
VOLUME ["/app/server/data"]
EXPOSE 8600

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8600/api/health', timeout=4)"

# Schema first (Alembic is the only thing that creates tables), then the app.
# FORWARDED_ALLOW_IPS: which addresses may set X-Forwarded-* (your reverse proxy). The compose
# file publishes the port on the host's loopback only, so only local proxies can reach it.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port 8600 --proxy-headers --forwarded-allow-ips=\"${FORWARDED_ALLOW_IPS:-*}\""]
