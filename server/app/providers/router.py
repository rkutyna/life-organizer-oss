"""/api/settings/accounts: list, rename, enable or disable, and remove connected accounts.

Signed-in browser only. Adding an account is each feature's own flow (a CalDAV form, Google's
consent screen, ...), added with that feature.
"""

from datetime import datetime

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.deps import SessionDep, get_or_404
from app.providers import service
from app.providers.models import ProviderAccount

router = APIRouter(prefix="/api/settings/accounts", tags=["settings"])


class ProviderAccountOut(BaseModel):
    id: int
    kind: str
    label: str
    enabled: bool
    status: service.AccountStatus
    last_error: str | None
    last_sync_at: datetime | None
    created_at: datetime

    @classmethod
    def from_row(cls, row: ProviderAccount) -> "ProviderAccountOut":
        return cls(
            id=row.id,
            kind=row.kind,
            label=row.label,
            enabled=row.enabled,
            status=service.status(row),
            last_error=row.last_error,
            last_sync_at=row.last_sync_at,
            created_at=row.created_at,
        )


class ProviderAccountUpdate(BaseModel):
    label: str | None = Field(default=None, min_length=1, max_length=100)
    enabled: bool | None = None


@router.get("", response_model=list[ProviderAccountOut])
def list_accounts(session: SessionDep) -> list[ProviderAccountOut]:
    return [ProviderAccountOut.from_row(row) for row in service.accounts(session)]


@router.patch("/{account_id}", response_model=ProviderAccountOut)
def update_account(
    account_id: int, payload: ProviderAccountUpdate, session: SessionDep
) -> ProviderAccountOut:
    account = get_or_404(session, ProviderAccount, account_id)
    if payload.label is not None:
        account.label = payload.label.strip()
    if payload.enabled is not None:
        account.enabled = payload.enabled
    session.commit()
    return ProviderAccountOut.from_row(account)


@router.delete("/{account_id}", status_code=204)
def delete_account(account_id: int, session: SessionDep) -> None:
    """Remove the account and its stored credentials. Data mirrored from it goes with it
    (each feature module deletes its mirrored rows on the next sync)."""
    session.delete(get_or_404(session, ProviderAccount, account_id))
    session.commit()
