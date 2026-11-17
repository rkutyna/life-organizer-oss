"""/api/jobs/import: the CSV import's four steps (importer.py).

The file travels as text in a JSON body on each step, so the server keeps nothing between steps
and never stores the file. Only `/preview` answers with cell text.
"""

from typing import Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.deps import AuthorDep, SessionDep
from app.modules.jobs import importer

router = APIRouter()

CsvText = Field(max_length=importer.MAX_BYTES, description="The CSV file's text (UTF-8)")


class JobsImportPreviewIn(BaseModel):
    csv: str = CsvText
    kind: Literal["applications", "contacts"] = "applications"
    mapping: dict[str, str | None] | None = Field(
        default=None, description="Header -> field; leave out for a suggested mapping"
    )


class JobsImportTarget(BaseModel):
    key: str
    label: str
    type: Literal["text", "date", "status", "tags"]
    required: bool


class JobsImportStatusValue(BaseModel):
    value: str
    count: int
    suggested: str | None


class JobsImportPreviewOut(BaseModel):
    kind: Literal["applications", "contacts"]
    headers: list[str]
    rows: list[list[str]] = Field(description="The first rows, for the person importing only")
    row_count: int
    mapping: dict[str, str | None]
    targets: list[JobsImportTarget]
    status_column: str | None
    status_values: list[JobsImportStatusValue] = Field(
        description="Distinct values of the columns mapped to status and reached (furthest "
        "stage); one status_map covers both"
    )
    day_first_suggested: bool = Field(description="Some dates only read as day/month/year")


class JobsImportSpec(BaseModel):
    csv: str = CsvText
    kind: Literal["applications", "contacts"] = "applications"
    mapping: dict[str, str | None] = Field(description="Header -> field key, or null to skip")
    status_map: dict[str, str] = Field(
        default_factory=dict, description="Status cell value -> status key"
    )
    day_first: bool = Field(default=False, description="Read 05/11/2026 as 5 November")
    keep_unmapped: bool = Field(
        default=True, description="Keep unmapped columns in an application's extra"
    )


class JobsImportProblem(BaseModel):
    row: int = Field(description="Row number in the file; the header is row 1")
    code: str = Field(
        description="missing_company, missing_title, missing_name, unknown_status, bad_date, "
        "duplicate_row"
    )
    field: str | None
    skipped: bool = Field(description="The row was left out (otherwise only the field was)")


class JobsImportMatch(BaseModel):
    row: int
    record_id: int
    action: Literal["update", "unchanged", "promote"]


class JobsImportReport(BaseModel):
    kind: Literal["applications", "contacts"]
    committed: bool
    rows: int
    create: int
    update: int
    unchanged: int
    promote: int = Field(description="Rows that submit an open lead of the same posting")
    skipped: int
    companies_created: int
    problems: list[JobsImportProblem] = Field(description="At most 500 listed")
    matches: list[JobsImportMatch] = Field(description="At most 500 listed")
    batch_id: str | None = Field(description="The commit's audit batch, for undo")


class JobsImportUndoIn(BaseModel):
    batch_id: str = Field(min_length=1, max_length=32)


class JobsImportUndoOut(BaseModel):
    reverted: int
    conflicts: int = Field(description="Changes left alone because they were edited since")


def _spec(payload: JobsImportSpec) -> importer.Spec:
    return importer.Spec(
        kind=payload.kind,
        mapping=payload.mapping,
        status_map=payload.status_map,
        day_first=payload.day_first,
        keep_unmapped=payload.keep_unmapped,
    )


@router.post("/preview", response_model=JobsImportPreviewOut)
def import_preview(payload: JobsImportPreviewIn, session: SessionDep) -> JobsImportPreviewOut:
    """Read the file: headers, the first rows, a suggested (or the given) mapping and the status
    column's distinct values with suggested statuses. Writes nothing."""
    try:
        data = importer.preview(session, payload.csv, payload.kind, payload.mapping)
    except importer.ImportError_ as exc:
        raise HTTPException(422, str(exc)) from exc
    return JobsImportPreviewOut.model_validate(data)


@router.post("/dry-run", response_model=JobsImportReport)
def import_dry_run(payload: JobsImportSpec, session: SessionDep) -> JobsImportReport:
    """What a commit would do: counts, matched records and problems. Writes nothing."""
    try:
        report = importer.run(session, payload.csv, _spec(payload), commit=False)
    except importer.ImportError_ as exc:
        raise HTTPException(422, str(exc)) from exc
    return JobsImportReport.model_validate(report, from_attributes=True)


@router.post("/commit", response_model=JobsImportReport)
def import_commit(payload: JobsImportSpec, session: SessionDep) -> JobsImportReport:
    """Import: every write as author `system`, in one audit batch (`batch_id`)."""
    try:
        report = importer.run(session, payload.csv, _spec(payload), commit=True)
    except importer.ImportError_ as exc:
        raise HTTPException(422, str(exc)) from exc
    return JobsImportReport.model_validate(report, from_attributes=True)


@router.post("/undo", response_model=JobsImportUndoOut)
def import_undo(
    payload: JobsImportUndoIn, session: SessionDep, author: AuthorDep
) -> JobsImportUndoOut:
    """Revert an import's batch. Changes edited since are left alone and counted."""
    try:
        result = importer.undo(session, payload.batch_id, author)
    except importer.ImportError_ as exc:
        raise HTTPException(422, str(exc)) from exc
    return JobsImportUndoOut(reverted=result.reverted, conflicts=result.conflicts)
