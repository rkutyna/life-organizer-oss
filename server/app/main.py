"""App factory: auth, core routers, module auto-discovery, background jobs and the web app.

Module auto-discovery. Every package under `app/modules/<name>/` is scanned for these
optional files; a module never needs an edit to this file:

    models.py             SQLAlchemy models (imported first, so Alembic sees them)
    router.py             `router = APIRouter()`, mounted at /api/<name>, `api` scope required
                          (a module named `mail` needs the `mail` scope instead)
    calendar_provider.py  calls `app.calendar.register_provider(...)` at import
    ingest.py             `router = APIRouter()`, mounted at /api/ingest, `ingest` scope required
    jobs.py               `register_jobs(scheduler, session_factory, settings)`

Every /api route is authenticated (app.auth.principal) except /api/health, the setup and
sign-in routes in app.auth.router, setup's two pick lists in app.auth.settings_router, and
Google's OAuth redirect in app.providers.google_router.

Run: `uv run uvicorn app.main:app --reload --port 8600` (from `server/`).
Schema changes go through Alembic (`uv run alembic upgrade head`); this file never creates
tables.
"""

import importlib
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel
from sqlalchemy.exc import OperationalError

from app import calendar, freshness, history
from app.auth import router as auth_router
from app.auth import service as auth_service
from app.auth import settings_router
from app.auth.principal import require_api, require_browser, require_ingest, require_mail
from app.config import Settings, get_settings
from app.db import make_engine, make_session_factory
from app.discovery import MODULE_PARTS, import_all_models, import_module_part, module_names
from app.providers import google_router
from app.providers import router as accounts_router
from app.scheduler import make_scheduler

log = logging.getLogger(__name__)

VERSION = "0.1.0"

# Modules whose router needs a scope other than `api`.
MODULE_SCOPES = {"mail": require_mail}

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "same-origin",
}


class ModuleInfo(BaseModel):
    name: str
    parts: list[str]


class StatusOut(BaseModel):
    ok: bool
    version: str
    timezone: str
    modules: list[ModuleInfo]


class HealthOut(BaseModel):
    ok: bool


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    engine = make_engine(settings.database_url)
    session_factory = make_session_factory(engine)
    job_registrations = []

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        try:
            with session_factory() as session:
                auth_service.apply_timezone(session)
        except OperationalError:
            log.warning("database not migrated yet; run `alembic upgrade head`")
        scheduler = None
        if settings.scheduler_enabled and job_registrations:
            scheduler = make_scheduler(settings)
            for register_jobs in job_registrations:
                register_jobs(scheduler, session_factory, settings)
            scheduler.start()
        yield
        if scheduler is not None:
            scheduler.shutdown(wait=False)
        engine.dispose()

    api = FastAPI(
        title="Life Organizer for Mac",
        version=VERSION,
        lifespan=lifespan,
        generate_unique_id_function=operation_id,
    )
    api.state.settings = settings
    api.state.engine = engine
    api.state.session_factory = session_factory

    @api.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        for header, value in SECURITY_HEADERS.items():
            response.headers.setdefault(header, value)
        if request.url.path.startswith("/api/"):
            response.headers.setdefault("Cache-Control", "no-store")
        return response

    @api.get("/api/health", response_model=HealthOut, tags=["status"])
    def health() -> HealthOut:
        """Liveness, for container health checks. Public."""
        return HealthOut(ok=True)

    # Auth and account management.
    api.include_router(auth_router.router)
    browser_only = [Depends(require_browser)]
    api.include_router(settings_router.public_router)
    api.include_router(settings_router.router, dependencies=browser_only)
    api.include_router(accounts_router.router, dependencies=browser_only)
    api.include_router(google_router.router, dependencies=browser_only)
    api.include_router(google_router.callback_router)  # public; the OAuth state authorizes it

    # Core routers and the built-in holidays source.
    signed_in = [Depends(require_api)]
    api.include_router(calendar.router, dependencies=signed_in)
    api.include_router(history.router, dependencies=signed_in)
    api.include_router(freshness.router, dependencies=signed_in)
    importlib.import_module("app.holidays_provider")  # registers source "holidays"

    # Modules.
    import_all_models()
    discovered: list[ModuleInfo] = []
    for name in module_names():
        parts = []
        for part in MODULE_PARTS:
            module = import_module_part(name, part)
            if module is None:
                continue
            parts.append(part)
            if part == "router":
                guard = MODULE_SCOPES.get(name, require_api)
                api.include_router(
                    module.router,
                    prefix=f"/api/{name}",
                    tags=[name],
                    dependencies=[Depends(guard)],
                )
            elif part == "ingest":
                api.include_router(
                    module.router,
                    prefix="/api/ingest",
                    tags=["ingest"],
                    dependencies=[Depends(require_ingest)],
                )
            elif part == "jobs":
                job_registrations.append(module.register_jobs)
        discovered.append(ModuleInfo(name=name, parts=parts))

    @api.get("/api/status", response_model=StatusOut, tags=["status"], dependencies=signed_in)
    def status() -> StatusOut:
        """Version, time zone and which modules were discovered."""
        from app.timeutil import local_tz

        return StatusOut(ok=True, version=VERSION, timezone=local_tz().key, modules=discovered)

    mount_web(api, settings.web_dist)
    return api


def operation_id(route: APIRoute) -> str:
    """Readable OpenAPI operation ids: "<tag>_<function name>", e.g. "jobs_list_companies"."""
    return f"{route.tags[0]}_{route.name}" if route.tags else route.name


def mount_web(api: FastAPI, dist: Path) -> None:
    """Serve the built web app at / with SPA fallback. API paths never fall back."""
    dist = dist.resolve()
    index = dist / "index.html"
    if not index.is_file():
        log.info("web app not built (%s missing); serving the API only", index)
        return

    @api.get("/{path:path}", include_in_schema=False)
    def web(path: str) -> FileResponse:
        if path == "api" or path.startswith("api/"):
            raise HTTPException(404, "not found")
        candidate = (dist / path).resolve()
        if path and candidate.is_file() and candidate.is_relative_to(dist):
            immutable = path.startswith("assets/")
            cache = "public, max-age=31536000, immutable" if immutable else "no-cache"
            return FileResponse(candidate, headers={"Cache-Control": cache})
        return FileResponse(index, headers={"Cache-Control": "no-cache"})


app = create_app()
