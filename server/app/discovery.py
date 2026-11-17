"""Finds feature modules under app/modules/ and imports their optional parts.

Used by `app.main` (to mount routers, providers, ingest and jobs) and by Alembic (to see
every model). A module is any package `app/modules/<name>/`; see app/main.py for the parts.
"""

import importlib
import importlib.util
import pkgutil
from types import ModuleType

from app import modules as modules_package

MODULE_PARTS = ("models", "router", "calendar_provider", "ingest", "jobs")


def module_names() -> list[str]:
    """Names of the packages under app/modules/, alphabetically."""
    return sorted(
        info.name
        for info in pkgutil.iter_modules(modules_package.__path__)
        if info.ispkg and not info.name.startswith("_")
    )


def import_module_part(name: str, part: str) -> ModuleType | None:
    """Import app.modules.<name>.<part> if that file exists, else return None."""
    qualified = f"app.modules.{name}.{part}"
    if importlib.util.find_spec(qualified) is None:
        return None
    return importlib.import_module(qualified)


def import_all_models() -> None:
    """Import every model so `Base.metadata` is complete (Alembic, audit.revert)."""
    importlib.import_module("app.audit")  # change_log
    importlib.import_module("app.freshness")  # source_status
    importlib.import_module("app.auth.models")  # core_config, core_sessions, core_api_tokens
    importlib.import_module("app.providers.models")  # core_provider_accounts
    importlib.import_module("app.providers.google")  # core_oauth_states
    for name in module_names():
        import_module_part(name, "models")
