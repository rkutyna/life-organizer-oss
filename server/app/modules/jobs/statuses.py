"""The configurable status list.

Every status has a `kind`:

- `lead`: a posting worth applying to, not submitted yet. Only the reserved `lead` status.
- `dropped`: a lead cut without applying. Only the reserved `dropped` status.
- `active`: submitted and moving forward. These are the funnel's stages, in list order, and
  `reached` counts how far an application got through them. The reserved `applied` status is the
  first stage: the one a lead gets when it is submitted.
- `closed`: finished without moving on (rejected, withdrawn, ghosted).

The defaults below apply until the list is edited. The first edit writes them out as
`JobStatus` rows (author `system`, in the edit's own batch), and from then on the rows are the
list. The three reserved statuses can be renamed and moved but not removed, and their kind is
fixed. A status still used by an application's history cannot be removed.
"""

import re
from dataclasses import dataclass
from typing import Literal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app import audit
from app.modules.jobs.models import ApplicationStatusEvent, JobStatus

Kind = Literal["lead", "dropped", "active", "closed"]
KINDS: tuple[Kind, ...] = ("lead", "dropped", "active", "closed")

LEAD = "lead"
DROPPED = "dropped"
APPLIED = "applied"
RESERVED: dict[str, Kind] = {LEAD: "lead", DROPPED: "dropped", APPLIED: "active"}

KEY_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,31}$")


@dataclass(frozen=True)
class StatusDef:
    key: str
    label: str
    kind: Kind
    position: int

    @property
    def reserved(self) -> bool:
        return self.key in RESERVED


DEFAULTS: tuple[StatusDef, ...] = tuple(
    StatusDef(key, label, kind, position)
    for position, (key, label, kind) in enumerate(
        [
            ("lead", "Lead", "lead"),
            ("applied", "Applied", "active"),
            ("screen", "Screen", "active"),
            ("interview", "Interview", "active"),
            ("offer", "Offer", "active"),
            ("rejected", "Rejected", "closed"),
            ("withdrawn", "Withdrawn", "closed"),
            ("ghosted", "Ghosted", "closed"),
            ("dropped", "Dropped lead", "dropped"),
        ]
    )
)


class StatusError(ValueError):
    """A status edit that would break the list (HTTP 409 or 422 by `code`)."""

    def __init__(self, message: str, code: int = 422) -> None:
        super().__init__(message)
        self.code = code


def _rows(session: Session) -> list[JobStatus]:
    return list(session.scalars(select(JobStatus).order_by(JobStatus.position, JobStatus.id)))


def load(session: Session) -> list[StatusDef]:
    """The status list in order: the saved rows, or the defaults while there are none."""
    rows = _rows(session)
    if not rows:
        return list(DEFAULTS)
    return [StatusDef(r.key, r.label, r.kind, r.position) for r in rows]  # type: ignore[arg-type]


def by_key(session: Session) -> dict[str, StatusDef]:
    return {s.key: s for s in load(session)}


def keys_of_kind(session: Session, *kinds: Kind) -> list[str]:
    return [s.key for s in load(session) if s.kind in kinds]


def require(session: Session, key: str, kinds: tuple[Kind, ...] | None = None) -> StatusDef:
    """The status `key`, or a ValueError naming the valid choices."""
    known = by_key(session)
    status = known.get(key)
    allowed = [s.key for s in known.values() if kinds is None or s.kind in kinds]
    if status is None or key not in allowed:
        raise ValueError(f"unknown status {key!r}; expected one of: {', '.join(allowed)}")
    return status


def _materialize(session: Session) -> list[JobStatus]:
    """Write the defaults out as rows if there are none yet (inside the caller's batch)."""
    rows = _rows(session)
    if rows:
        return rows
    return [
        audit.create(
            session,
            JobStatus(key=d.key, label=d.label, kind=d.kind, position=d.position),
            "system",
        )
        for d in DEFAULTS
    ]


def slug(label: str) -> str:
    key = re.sub(r"[^a-z0-9]+", "_", label.casefold()).strip("_")[:32]
    if key and not key[0].isalpha():
        key = f"s_{key}"[:32]
    return key


def add(session: Session, label: str, kind: Kind, key: str | None, author: str) -> StatusDef:
    """Add a status at the end of its kind's run (an active one before the closed ones)."""
    if kind not in ("active", "closed"):
        raise StatusError("only active and closed statuses can be added")
    label = label.strip()
    key = (key or slug(label)).strip()
    if not KEY_PATTERN.match(key):
        raise StatusError("key must be lowercase letters, digits and _, starting with a letter")
    with audit.transaction(session):
        rows = _materialize(session)
        if any(r.key == key for r in rows):
            raise StatusError(f"status {key!r} already exists", 409)
        # After the last row of the same kind, or at the end.
        same_kind = [r.position for r in rows if r.kind == kind]
        position = (max(same_kind) + 1) if same_kind else len(rows)
        for row in rows:
            if row.position >= position:
                audit.update(session, row, {"position": row.position + 1}, author)
        row = audit.create(
            session, JobStatus(key=key, label=label, kind=kind, position=position), author
        )
    return StatusDef(row.key, row.label, row.kind, row.position)  # type: ignore[arg-type]


def update(session: Session, key: str, changes: dict, author: str) -> StatusDef:
    """Rename a status or change a non-reserved one's kind (active or closed)."""
    with audit.transaction(session):
        rows = _materialize(session)
        row = next((r for r in rows if r.key == key), None)
        if row is None:
            raise StatusError(f"status {key!r} not found", 404)
        if "kind" in changes and changes["kind"] != row.kind:
            if key in RESERVED:
                raise StatusError(f"the kind of the reserved status {key!r} is fixed")
            if changes["kind"] not in ("active", "closed"):
                raise StatusError("a status can only be made active or closed")
        if "label" in changes:
            changes["label"] = changes["label"].strip()
        audit.update(session, row, changes, author)
    return StatusDef(row.key, row.label, row.kind, row.position)  # type: ignore[arg-type]


def reorder(session: Session, keys: list[str], author: str) -> list[StatusDef]:
    """Put the list in the order of `keys`, which must name every status once."""
    with audit.transaction(session):
        rows = _materialize(session)
        if sorted(keys) != sorted(r.key for r in rows):
            raise StatusError("the new order must name every status exactly once")
        by = {r.key: r for r in rows}
        for position, key in enumerate(keys):
            audit.update(session, by[key], {"position": position}, author)
    return load(session)


def remove(session: Session, key: str, author: str) -> None:
    """Remove a status nothing uses. The reserved ones stay."""
    if key in RESERVED:
        raise StatusError(f"{key!r} is a reserved status and cannot be removed", 409)
    used = session.scalar(
        select(func.count(ApplicationStatusEvent.id)).where(ApplicationStatusEvent.status == key)
    )
    if used:
        raise StatusError(
            f"{used} status change(s) use {key!r}; change them before removing it", 409
        )
    with audit.transaction(session):
        rows = _materialize(session)
        row = next((r for r in rows if r.key == key), None)
        if row is None:
            raise StatusError(f"status {key!r} not found", 404)
        audit.delete(session, row, author)
