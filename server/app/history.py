"""History API over `change_log`: list changes and revert one.

The web `RecordHistoryPanel` uses these for every owned record:
`GET /api/history?table=jobs_applications&record_id=12` and `POST /api/history/{id}/revert`.
"""

from datetime import datetime
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from app import audit
from app.deps import AuthorDep, SessionDep


class ChangeOut(BaseModel):
    id: int
    batch_id: str
    ts: datetime
    author: str
    op: audit.Op
    table_name: str
    record_id: str
    field: str | None
    old_value: Any
    new_value: Any
    reverts_change_id: int | None

    @classmethod
    def from_row(cls, row: audit.ChangeLog) -> "ChangeOut":
        return cls(
            id=row.id,
            batch_id=row.batch_id,
            ts=row.ts,
            author=row.author,
            op=row.op,  # type: ignore[arg-type]
            table_name=row.table_name,
            record_id=row.record_id,
            field=row.field,
            old_value=audit.decode_value(row.old_value),
            new_value=audit.decode_value(row.new_value),
            reverts_change_id=row.reverts_change_id,
        )


router = APIRouter(prefix="/api/history", tags=["history"])


@router.get("", response_model=list[ChangeOut])
def list_history(
    session: SessionDep,
    table: str | None = Query(None, description="Table name, e.g. jobs_applications"),
    record_id: str | None = Query(None, description="Primary key of one record"),
    limit: int = Query(200, ge=1, le=1000),
) -> list[ChangeOut]:
    """Changes, newest first. Filter by table, or by table and record."""
    if record_id is not None and table is None:
        raise HTTPException(400, "record_id needs table")
    rows = audit.history(session, table, record_id, limit)
    return [ChangeOut.from_row(row) for row in rows]


@router.post("/{change_id}/revert", response_model=list[ChangeOut])
def revert_change(change_id: int, session: SessionDep, author: AuthorDep) -> list[ChangeOut]:
    """Undo one change. Returns the change rows the revert wrote."""
    try:
        rows = audit.revert(session, change_id, author)
    except LookupError as exc:
        raise HTTPException(404, str(exc)) from exc
    except audit.RevertConflict as exc:
        raise HTTPException(409, str(exc)) from exc
    return [ChangeOut.from_row(row) for row in rows]
