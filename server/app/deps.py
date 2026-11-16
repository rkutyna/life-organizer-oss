"""FastAPI dependencies shared by every router.

from app.deps import AuthorDep, SessionDep, SettingsDep, get_or_404

@router.patch("/{company_id}")
def update_company(company_id: int, payload: CompanyUpdate, session: SessionDep, author: AuthorDep):
    company = get_or_404(session, Company, company_id)
    audit.update(session, company, payload.model_dump(exclude_unset=True), author)
    ...

Routers never check auth themselves: `app.main` mounts every router behind
`app.auth.principal.require_api` (or the ingest/mail guard). `AuthorDep` is the author of the
request's credential (`me` for the browser, the token's author otherwise).
"""

from collections.abc import Iterator
from typing import Annotated, Any, TypeVar

from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.auth.principal import get_author
from app.config import Settings

M = TypeVar("M")


def get_session(request: Request) -> Iterator[Session]:
    """One session per request, from the app's session factory."""
    with request.app.state.session_factory() as session:
        yield session


def get_settings_dep(request: Request) -> Settings:
    """The app's settings (tests pass their own to `create_app`)."""
    return request.app.state.settings


SessionDep = Annotated[Session, Depends(get_session)]
AuthorDep = Annotated[str, Depends(get_author)]
SettingsDep = Annotated[Settings, Depends(get_settings_dep)]


def get_or_404(session: Session, model: type[M], record_id: Any) -> M:
    """Load a live (not soft-deleted) record by primary key or raise 404."""
    obj = session.get(model, record_id)
    if obj is None or getattr(obj, "deleted_at", None) is not None:
        raise HTTPException(404, f"{model.__name__} {record_id} not found")
    return obj
