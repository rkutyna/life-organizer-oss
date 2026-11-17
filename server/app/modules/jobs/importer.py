"""CSV import with a column-mapping step: preview, dry run, commit, undo.

1. **Preview** reads the file and suggests a mapping from each column to a field (`TARGETS`),
   and, for the column mapped to `status`, each distinct value with a suggested status. This is
   the only step that returns cell text: it is shown to the person importing and stored nowhere.
2. **Dry run** walks every row with the chosen mapping and reports what a commit would do:
   counts, plus the rows that match records already in the tracker (row number and record id)
   and the rows with problems (row number, field and a code). It writes nothing.
3. **Commit** does the same walk and writes, as author `system`, in one audit batch, so the
   report's `batch_id` names every change it made. **Undo** reverts that batch.

Reports carry counts, codes, row numbers, field keys and record ids, never cell text.

Matching is on natural keys, so importing the same file twice changes nothing the second time:

- an application is (company, title, date applied): company names fold case and spacing,
  titles also punctuation (matching.py). A matched row updates the fields whose non-blank cells
  differ, and adds its status (and `reached` stage) to the history only if the history lacks it.
  A row that is past the lead stage and matches exactly one open lead of the same title submits
  that lead (`promote`) instead of making a second record.
- a contact is (name, company).

Rows never match records made earlier in the same import, so a dry run and a commit agree. A
second row with the same key as an earlier one is skipped (`duplicate_row`). Blank cells never
clear a field. Unmapped columns go into an application's `extra` when `keep_unmapped` is on.
"""

import csv
import datetime as dt
import io
import json
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, Literal

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.modules.jobs import service, statuses
from app.modules.jobs.matching import company_named, fold_name, fold_title, same_contact
from app.modules.jobs.models import (
    Application,
    ApplicationStatusEvent,
    Company,
    Contact,
    Interview,
)
from app.modules.jobs.status_sync import sync_application_status
from app.timeutil import today_local

Kind = Literal["applications", "contacts"]

AUTHOR = "system"
MAX_BYTES = 5_000_000
MAX_ROWS = 10_000
PREVIEW_ROWS = 20
MAX_LISTED = 500  # problems and matches listed in a report; the counts are always complete


@dataclass(frozen=True)
class Target:
    key: str
    label: str
    type: Literal["text", "date", "status", "tags"] = "text"
    required: bool = False
    # Column headers (folded) that suggest this field.
    synonyms: tuple[str, ...] = ()


TARGETS: dict[Kind, tuple[Target, ...]] = {
    "applications": (
        Target(
            "company",
            "Company",
            required=True,
            synonyms=("company", "company name", "employer", "organization", "organisation", "org"),
        ),
        Target(
            "title",
            "Title",
            required=True,
            synonyms=(
                "title",
                "position",
                "role",
                "job title",
                "job",
                "position title",
                "job role",
                "role title",
            ),
        ),
        Target(
            "status",
            "Status",
            "status",
            synonyms=("status", "stage", "application status", "state", "current status"),
        ),
        Target(
            "date_applied",
            "Date applied",
            "date",
            synonyms=(
                "date applied",
                "applied on",
                "applied",
                "application date",
                "date",
                "submitted",
                "date submitted",
                "submitted on",
            ),
        ),
        Target(
            "status_date",
            "Status date",
            "date",
            synonyms=(
                "status date",
                "last update",
                "last updated",
                "updated",
                "date of status",
                "status changed",
                "response date",
            ),
        ),
        Target(
            "reached",
            "Furthest stage",
            "status",
            synonyms=("reached", "furthest stage", "furthest", "highest stage", "got to"),
        ),
        Target(
            "found_on",
            "Date found",
            "date",
            synonyms=("date found", "found on", "found", "date saved", "saved on"),
        ),
        Target("location", "Location", synonyms=("location", "city", "place", "office", "where")),
        Target(
            "posting_url",
            "Posting URL",
            synonyms=(
                "url",
                "link",
                "posting",
                "job link",
                "posting url",
                "job url",
                "listing",
                "posting link",
                "job posting",
            ),
        ),
        Target(
            "source",
            "Source",
            synonyms=(
                "source",
                "found via",
                "channel",
                "where found",
                "board",
                "job board",
                "via",
                "referral source",
            ),
        ),
        Target(
            "next_action",
            "Next action",
            synonyms=(
                "next action",
                "next step",
                "next steps",
                "follow up",
                "followup",
                "todo",
                "to do",
                "action",
            ),
        ),
        Target(
            "next_action_due",
            "Next action due",
            "date",
            synonyms=(
                "follow up date",
                "followup date",
                "next action date",
                "due",
                "due date",
                "next step date",
                "follow up by",
                "follow up on",
            ),
        ),
        Target("notes", "Notes", synonyms=("notes", "note", "comments", "comment", "details")),
        Target("tags", "Tags", "tags", synonyms=("tags", "tag", "labels", "label")),
    ),
    "contacts": (
        Target(
            "name",
            "Name",
            required=True,
            synonyms=("name", "contact", "person", "full name", "contact name"),
        ),
        Target(
            "company",
            "Company",
            synonyms=("company", "company name", "employer", "organization", "org"),
        ),
        Target("role", "Role", synonyms=("role", "title", "position", "job title")),
        Target("email", "Email", synonyms=("email", "e mail", "email address", "mail")),
        Target(
            "profile_url",
            "Profile URL",
            synonyms=("profile", "profile url", "linkedin", "url", "link", "website"),
        ),
        Target(
            "contacted_on",
            "Contacted on",
            "date",
            synonyms=(
                "contacted on",
                "contacted",
                "date contacted",
                "reached out",
                "outreach date",
                "first contact",
                "sent",
                "sent on",
            ),
        ),
        Target(
            "replied_on",
            "Replied on",
            "date",
            synonyms=("replied on", "replied", "reply date", "response date", "responded"),
        ),
        Target(
            "next_action",
            "Next action",
            synonyms=("next action", "next step", "follow up", "todo", "action"),
        ),
        Target(
            "next_action_due",
            "Next action due",
            "date",
            synonyms=("follow up date", "next action date", "due", "due date", "follow up by"),
        ),
        Target("notes", "Notes", synonyms=("notes", "note", "comments", "comment")),
        Target("tags", "Tags", "tags", synonyms=("tags", "tag", "labels")),
    ),
}

# Folded cell values that suggest a default status. Values equal to a status's key or label
# (folded) are suggested first.
STATUS_SYNONYMS: dict[str, tuple[str, ...]] = {
    "lead": (
        "to apply",
        "wishlist",
        "wish list",
        "interested",
        "saved",
        "bookmarked",
        "todo",
        "not applied",
        "planning",
    ),
    "applied": (
        "submitted",
        "sent",
        "application sent",
        "in review",
        "under review",
        "pending",
        "waiting",
        "applied online",
        "in progress",
    ),
    "screen": (
        "phone screen",
        "screening",
        "recruiter call",
        "recruiter screen",
        "hr screen",
        "phone interview",
        "phone call",
    ),
    "interview": (
        "interviewing",
        "onsite",
        "on site",
        "technical",
        "final round",
        "interviews",
        "second round",
        "first round",
        "technical interview",
    ),
    "offer": ("offered", "accepted", "offer received", "offer accepted"),
    "rejected": (
        "declined",
        "no",
        "rejection",
        "not selected",
        "denied",
        "turned down",
        "not moving forward",
        "closed",
    ),
    "withdrawn": ("withdrew", "withdraw", "cancelled", "canceled", "pulled out"),
    "ghosted": ("no response", "no reply", "none", "silence", "no answer", "unresponsive"),
    "dropped": ("skip", "skipped", "not applying", "pass", "passed"),
}


class ImportError_(ValueError):  # noqa: N801  (not the builtin ImportError)
    """The file or the mapping cannot be used at all (HTTP 422)."""


# --------------------------------------------------------------------------- reading the file


def read_csv(text: str) -> tuple[list[str], list[list[str]]]:
    """(headers, rows). The first non-blank row is the header; blank rows are dropped, short
    rows padded. Blank and repeated headers get unique names ("Column 3", "Notes (2)")."""
    if len(text.encode("utf-8", errors="ignore")) > MAX_BYTES:
        raise ImportError_(f"the file is over {MAX_BYTES // 1_000_000} MB")
    text = text.lstrip("﻿")
    try:
        dialect: Any = csv.Sniffer().sniff(text[:4096], delimiters=",;\t")
    except csv.Error:
        dialect = csv.excel
    rows = [row for row in csv.reader(io.StringIO(text), dialect) if any(c.strip() for c in row)]
    if not rows:
        raise ImportError_("the file has no rows")
    raw_headers, body = rows[0], rows[1:]
    if len(body) > MAX_ROWS:
        raise ImportError_(f"the file has more than {MAX_ROWS} rows; split it")
    width = max(len(raw_headers), *(len(r) for r in body)) if body else len(raw_headers)
    headers: list[str] = []
    seen: Counter[str] = Counter()
    for i in range(width):
        name = " ".join(raw_headers[i].split()) if i < len(raw_headers) else ""
        name = name or f"Column {i + 1}"
        seen[name.casefold()] += 1
        if seen[name.casefold()] > 1:
            name = f"{name} ({seen[name.casefold()]})"
        headers.append(name)
    body = [[c.strip() for c in r] + [""] * (width - len(r)) for r in body]
    return headers, body


def _fold_header(text: str) -> str:
    return " ".join(re.sub(r"[^\w]+", " ", text).replace("_", " ").split()).casefold()


def suggest_mapping(headers: list[str], kind: Kind) -> dict[str, str | None]:
    """Each header's suggested field, or None. A field is suggested for one header at most:
    an exact synonym beats a partial one, then the leftmost header wins."""
    targets = TARGETS[kind]
    scored: list[tuple[int, int, str, str]] = []  # (score, column, header, target)
    for column, header in enumerate(headers):
        folded = _fold_header(header)
        for target in targets:
            if folded in target.synonyms or folded == target.key.replace("_", " "):
                scored.append((0, column, header, target.key))
            elif any(f" {s} " in f" {folded} " for s in target.synonyms if len(s) > 3):
                scored.append((1, column, header, target.key))
    mapping: dict[str, str | None] = dict.fromkeys(headers)
    used: set[str] = set()
    for _, _, header, key in sorted(scored):
        if mapping[header] is None and key not in used:
            mapping[header] = key
            used.add(key)
    return mapping


def suggest_status(session: Session, value: str) -> str | None:
    folded = fold_name(value)
    if not folded:
        return None
    defs = statuses.load(session)
    for s in defs:
        if folded in (fold_name(s.key), fold_name(s.label)):
            return s.key
    known = {s.key for s in defs}
    for key, words in STATUS_SYNONYMS.items():
        if key in known and folded in words:
            return key
    return None


# --------------------------------------------------------------------------- cell values

_MONTHS = {
    m: i
    for i, names in enumerate(
        [
            ("jan", "january"),
            ("feb", "february"),
            ("mar", "march"),
            ("apr", "april"),
            ("may",),
            ("jun", "june"),
            ("jul", "july"),
            ("aug", "august"),
            ("sep", "sept", "september"),
            ("oct", "october"),
            ("nov", "november"),
            ("dec", "december"),
        ],
        start=1,
    )
    for m in names
}


def parse_date(value: str, *, day_first: bool = False) -> dt.date | None:
    """A date in a common spreadsheet spelling, or None if it is not one.

    ISO (2026-11-05, with or without a time), 2026/11/05, 11/5/2026 and 11/5/26 (5/11/2026 with
    day_first), 5 Nov 2026, Nov 5, 2026, November 5 2026, and spreadsheet serial numbers."""
    text = value.strip()
    if not text:
        return None
    try:
        if re.match(r"^\d{4}-\d{2}-\d{2}([ T].*)?$", text):
            return dt.date.fromisoformat(text[:10])
        m = re.match(r"^(\d{4})[/.](\d{1,2})[/.](\d{1,2})$", text)
        if m:
            return dt.date(int(m[1]), int(m[2]), int(m[3]))
        m = re.match(r"^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2}|\d{4})$", text)
        if m:
            a, b, year = int(m[1]), int(m[2]), int(m[3])
            year += 2000 if year < 100 else 0
            month, day = (b, a) if day_first else (a, b)
            return dt.date(year, month, day)
        words = re.findall(r"[A-Za-z]+|\d+", text)
        if len(words) == 3:
            parts = [w.casefold() for w in words]
            if parts[0] in _MONTHS and parts[1].isdigit() and parts[2].isdigit():
                return dt.date(int(parts[2]), _MONTHS[parts[0]], int(parts[1]))
            if parts[1] in _MONTHS and parts[0].isdigit() and parts[2].isdigit():
                return dt.date(int(parts[2]), _MONTHS[parts[1]], int(parts[0]))
        if re.match(r"^\d{5}(\.\d+)?$", text) and 20000 <= float(text) <= 80000:
            return dt.date(1899, 12, 30) + dt.timedelta(days=int(float(text)))
    except ValueError:
        return None
    return None


def split_tags(value: str) -> list[str]:
    return [t for t in re.split(r"[,;|]", value) if t.strip()]


# --------------------------------------------------------------------------- the walk


@dataclass
class Spec:
    kind: Kind
    mapping: dict[str, str | None]
    status_map: dict[str, str] = field(default_factory=dict)
    day_first: bool = False
    keep_unmapped: bool = True


@dataclass
class Report:
    kind: Kind
    committed: bool
    rows: int = 0
    create: int = 0
    update: int = 0
    unchanged: int = 0
    promote: int = 0
    skipped: int = 0
    companies_created: int = 0
    problems: list[dict[str, Any]] = field(default_factory=list)
    matches: list[dict[str, Any]] = field(default_factory=list)
    batch_id: str | None = None

    def problem(self, row: int, code: str, field_key: str | None = None, *, skip: bool) -> None:
        if len(self.problems) < MAX_LISTED:
            self.problems.append({"row": row, "code": code, "field": field_key, "skipped": skip})

    def match(self, row: int, record_id: int, action: str) -> None:
        if len(self.matches) < MAX_LISTED:
            self.matches.append({"row": row, "record_id": record_id, "action": action})


def _check_spec(session: Session, headers: list[str], spec: Spec) -> None:
    keys = {t.key: t for t in TARGETS[spec.kind]}
    chosen = [v for v in spec.mapping.values() if v]
    unknown_headers = [h for h in spec.mapping if h not in headers]
    if unknown_headers:
        raise ImportError_(f"{len(unknown_headers)} mapped column(s) are not in the file")
    bad = [v for v in chosen if v not in keys]
    if bad:
        raise ImportError_(f"unknown field(s): {', '.join(sorted(set(bad)))}")
    repeated = [k for k, n in Counter(chosen).items() if n > 1]
    if repeated:
        raise ImportError_(f"each field takes one column; repeated: {', '.join(repeated)}")
    missing = [t.key for t in keys.values() if t.required and t.key not in chosen]
    if missing:
        raise ImportError_(f"map a column to: {', '.join(missing)}")
    known = {s.key for s in statuses.load(session)}
    wrong = sorted({v for v in spec.status_map.values() if v and v not in known})
    if wrong:
        raise ImportError_(f"unknown status(es) in the status map: {', '.join(wrong)}")


def run(session: Session, csv_text: str, spec: Spec, *, commit: bool) -> Report:
    """Walk every row; write only when `commit`. Returns the report."""
    headers, rows = read_csv(csv_text)
    _check_spec(session, headers, spec)
    report = Report(kind=spec.kind, committed=commit, rows=len(rows))
    walker = _Walker(session, headers, spec, report, commit)
    if commit:
        with audit.transaction(session) as batch_id:
            walker.walk(rows)
        report.batch_id = batch_id if (report.create or report.update or report.promote) else None
    else:
        walker.walk(rows)
        session.rollback()
    return report


class _Walker:
    def __init__(
        self, session: Session, headers: list[str], spec: Spec, report: Report, commit: bool
    ):
        self.session = session
        self.headers = headers
        self.spec = spec
        self.report = report
        self.commit = commit
        self.columns = {target: headers.index(h) for h, target in spec.mapping.items() if target}
        self.unmapped = [i for i, h in enumerate(headers) if not spec.mapping.get(h)]
        self.types = {t.key: t.type for t in TARGETS[spec.kind]}
        self.defs = statuses.by_key(session)
        self.active = [s.key for s in self.defs.values() if s.kind == "active"]
        self.status_map = {fold_name(k): v for k, v in spec.status_map.items() if v}
        self.new_companies: dict[str, Company | None] = {}  # folded name -> created (commit)
        self.created: dict[str, set[int]] = {"applications": set(), "contacts": set()}
        self.seen_keys: set[tuple] = set()

    def walk(self, rows: list[list[str]]) -> None:
        for number, cells in enumerate(rows, start=2):  # row 1 is the header
            values = self._values(number, cells)
            if values is None:
                continue
            if self.spec.kind == "applications":
                self._application(number, values, cells)
            else:
                self._contact(number, values)

    # ---------------------------------------------------------------- cells to values

    def _values(self, number: int, cells: list[str]) -> dict[str, Any] | None:
        values: dict[str, Any] = {}
        for key, column in self.columns.items():
            raw = cells[column]
            if not raw:
                continue
            kind = self.types[key]
            if kind == "date":
                parsed = parse_date(raw, day_first=self.spec.day_first)
                if parsed is None:
                    self.report.problem(number, "bad_date", key, skip=False)
                    continue
                values[key] = parsed
            elif kind == "status":
                status = self.status_map.get(fold_name(raw)) or suggest_status(self.session, raw)
                if status is None:
                    if key == "status":
                        self.report.problem(number, "unknown_status", key, skip=True)
                        self.report.skipped += 1
                        return None
                    self.report.problem(number, "unknown_status", key, skip=False)
                    continue
                values[key] = status
            elif kind == "tags":
                values[key] = service.normalize_tags(split_tags(raw))
            else:
                values[key] = raw
        for key in TARGETS[self.spec.kind]:
            if key.required and not values.get(key.key):
                self.report.problem(number, f"missing_{key.key}", key.key, skip=True)
                self.report.skipped += 1
                return None
        return values

    def _company(self, name: str) -> tuple[int | None, str]:
        """(existing company id or None, folded name). Counts and, on commit, creates new ones."""
        existing = company_named(self.session, name)
        folded = fold_name(name)
        if existing is not None:
            return existing.id, folded
        if folded not in self.new_companies:
            self.report.companies_created += 1
            created = None
            if self.commit:
                created, _ = service.company_for_name(self.session, name, AUTHOR)
            self.new_companies[folded] = created
        made = self.new_companies[folded]
        return (made.id if made is not None else None), folded

    def _diff(self, record: Any, values: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
        changes = {}
        for key in fields:
            if key not in values:
                continue
            new = values[key]
            if key == "tags":
                merged = service.normalize_tags([*(record.tags or []), *new])
                if merged != (record.tags or []):
                    changes[key] = merged
            elif getattr(record, key) != new:
                changes[key] = new
        return changes

    # ---------------------------------------------------------------- applications

    APP_FIELDS = (
        "location",
        "posting_url",
        "source",
        "next_action",
        "next_action_due",
        "notes",
        "tags",
    )

    def _application(self, number: int, values: dict[str, Any], cells: list[str]) -> None:
        report = self.report
        company_id, company_key = self._company(values["company"])
        title = " ".join(values["title"].split())
        applied = values.get("date_applied")
        status = values.get("status") or (statuses.APPLIED if applied else statuses.LEAD)
        is_lead = self.defs[status].kind in ("lead", "dropped")
        if is_lead:
            applied = None
        key = ("a", company_key, fold_title(title), applied)
        if key in self.seen_keys:
            report.problem(number, "duplicate_row", skip=True)
            report.skipped += 1
            return
        self.seen_keys.add(key)
        extra = {}
        if self.spec.keep_unmapped:
            extra = {self.headers[i]: cells[i] for i in self.unmapped if cells[i]}

        existing = self._existing_application(company_id, title, applied, is_lead)
        if existing is not None:
            self._update_application(number, existing, values, status, extra)
            return
        leads = []
        if company_id is not None and not is_lead:
            leads = [a for a in self._postings(company_id, title) if a.status == statuses.LEAD]
        if len(leads) == 1:
            report.promote += 1
            report.match(number, leads[0].id, "promote")
            if self.commit:
                fields = {k: values[k] for k in self.APP_FIELDS if k in values}
                if extra:
                    fields["extra"] = extra
                if applied:
                    fields["date_applied"] = applied
                service.promote_lead(
                    self.session, leads[0], fields, AUTHOR, status=statuses.APPLIED
                )
                self._add_history(leads[0], values, status, applied)
            return
        report.create += 1
        if not self.commit:
            return
        fields = {k: values[k] for k in self.APP_FIELDS if k in values}
        application = audit.create(
            self.session,
            Application(
                **fields,
                company_id=company_id,
                title=title,
                status=status,
                date_applied=applied,
                extra=extra,
            ),
            AUTHOR,
        )
        self.created["applications"].add(application.id)
        if is_lead:
            found = values.get("found_on") or values.get("status_date") or today_local()
            self._event(application, statuses.LEAD, found)
            if status == statuses.DROPPED:
                self._event(application, statuses.DROPPED, values.get("status_date") or found)
        else:
            self._add_history(application, values, status, applied)
        sync_application_status(self.session, application, AUTHOR)

    def _postings(self, company_id: int, title: str) -> list[Application]:
        wanted = fold_title(title)
        rows = self.session.scalars(
            select(Application).where(Application.company_id == company_id).order_by(Application.id)
        )
        return [
            a
            for a in rows
            if fold_title(a.title) == wanted and a.id not in self.created["applications"]
        ]

    def _existing_application(
        self, company_id: int | None, title: str, applied: dt.date | None, is_lead: bool
    ) -> Application | None:
        if company_id is None:
            return None
        for row in self._postings(company_id, title):
            row_is_lead = row.status in (statuses.LEAD, statuses.DROPPED)
            if row.date_applied == applied and row_is_lead == is_lead:
                return row
        return None

    def _history(self, application_id: int) -> set[str]:
        return set(
            self.session.scalars(
                select(ApplicationStatusEvent.status).where(
                    ApplicationStatusEvent.application_id == application_id
                )
            )
        )

    def _missing_history(
        self, application: Application | None, values: dict, status: str
    ) -> list[str]:
        """The statuses this row would add: applied, then reached, then the status itself, minus
        those already in the history."""
        have = self._history(application.id) if application is not None else set()
        wanted = [statuses.APPLIED]
        reached = values.get("reached")
        if reached in self.active:
            wanted.append(reached)
        wanted.append(status)
        return [s for s in dict.fromkeys(wanted) if s not in have]

    def _add_history(
        self, application: Application, values: dict, status: str, applied: dt.date | None
    ) -> None:
        start = applied or values.get("status_date") or today_local()
        last = max(values.get("status_date") or start, start)
        for s in self._missing_history(application, values, status):
            self._event(application, s, last if s == status else start)
        sync_application_status(self.session, application, AUTHOR)

    def _event(self, application: Application, status: str, on: dt.date) -> None:
        audit.create(
            self.session,
            ApplicationStatusEvent(
                application_id=application.id, status=status, on_date=on, note=""
            ),
            AUTHOR,
        )

    def _update_application(
        self, number: int, existing: Application, values: dict, status: str, extra: dict
    ) -> None:
        changes = self._diff(existing, values, self.APP_FIELDS)
        merged_extra = {**(existing.extra or {}), **extra}
        if extra and merged_extra != (existing.extra or {}):
            changes["extra"] = merged_extra
        is_lead = existing.status in (statuses.LEAD, statuses.DROPPED)
        new_history = [] if is_lead else self._missing_history(existing, values, status)
        if not changes and not new_history:
            self.report.unchanged += 1
            self.report.match(number, existing.id, "unchanged")
            return
        self.report.update += 1
        self.report.match(number, existing.id, "update")
        if self.commit:
            if changes:
                audit.update(self.session, existing, changes, AUTHOR)
            if new_history:
                self._add_history(existing, values, status, existing.date_applied)

    # ---------------------------------------------------------------- contacts

    CONTACT_FIELDS = (
        "role",
        "email",
        "profile_url",
        "contacted_on",
        "replied_on",
        "next_action",
        "next_action_due",
        "notes",
        "tags",
    )

    def _contact(self, number: int, values: dict[str, Any]) -> None:
        report = self.report
        company_id, company_key = (None, "")
        if values.get("company"):
            company_id, company_key = self._company(values["company"])
        name = " ".join(values["name"].split())
        key = ("c", company_key, fold_name(name))
        if key in self.seen_keys:
            report.problem(number, "duplicate_row", skip=True)
            report.skipped += 1
            return
        self.seen_keys.add(key)
        existing = None
        if company_id is not None or not company_key:
            matches = [
                c
                for c in same_contact(self.session, name, company_id)
                if c.id not in self.created["contacts"]
            ]
            existing = matches[0] if matches else None
        if existing is not None:
            changes = self._diff(existing, values, self.CONTACT_FIELDS)
            if not changes:
                report.unchanged += 1
                report.match(number, existing.id, "unchanged")
                return
            report.update += 1
            report.match(number, existing.id, "update")
            if self.commit:
                audit.update(self.session, existing, changes, AUTHOR)
            return
        report.create += 1
        if self.commit:
            fields = {k: values[k] for k in self.CONTACT_FIELDS if k in values}
            contact = audit.create(
                self.session, Contact(**fields, name=name, company_id=company_id), AUTHOR
            )
            self.created["contacts"].add(contact.id)


# --------------------------------------------------------------------------- preview


def preview(
    session: Session,
    csv_text: str,
    kind: Kind,
    mapping: dict[str, str | None] | None,
    day_first: bool = False,
) -> dict[str, Any]:
    """Headers, the first rows, the (suggested) mapping and the status column's values."""
    headers, rows = read_csv(csv_text)
    chosen = suggest_mapping(headers, kind)
    if mapping is not None:
        chosen = {h: mapping.get(h) for h in headers}
    status_header = next((h for h, t in chosen.items() if t == "status"), None)
    values: list[dict[str, Any]] = []
    if status_header is not None:
        column = headers.index(status_header)
        counts = Counter(r[column] for r in rows if r[column])
        by_fold: dict[str, tuple[str, int]] = {}
        for value, n in counts.most_common():
            folded = fold_name(value)
            first, total = by_fold.get(folded, (value, 0))
            by_fold[folded] = (first, total + n)
        values = [
            {"value": value, "count": n, "suggested": suggest_status(session, value)}
            for value, n in sorted(by_fold.values(), key=lambda p: -p[1])
        ][:100]
    dates_ambiguous = _dates_ambiguous(headers, rows, chosen, kind)
    return {
        "kind": kind,
        "headers": headers,
        "rows": rows[:PREVIEW_ROWS],
        "row_count": len(rows),
        "mapping": chosen,
        "targets": [
            {"key": t.key, "label": t.label, "type": t.type, "required": t.required}
            for t in TARGETS[kind]
        ],
        "status_column": status_header,
        "status_values": values,
        "day_first_suggested": dates_ambiguous == "day_first",
    }


def _dates_ambiguous(headers, rows, mapping, kind) -> str | None:
    """'day_first' when some slash date only parses day-first (e.g. 25/11/2026)."""
    date_keys = {t.key for t in TARGETS[kind] if t.type == "date"}
    columns = [headers.index(h) for h, t in mapping.items() if t in date_keys]
    for row in rows:
        for column in columns:
            m = re.match(r"^(\d{1,2})[/.\-](\d{1,2})[/.\-]\d{2,4}$", row[column])
            if m and int(m[1]) > 12 >= int(m[2]):
                return "day_first"
    return None


# --------------------------------------------------------------------------- undo


@dataclass
class UndoReport:
    reverted: int = 0
    conflicts: int = 0


_UNDO_TABLES = (
    Application.__tablename__,
    ApplicationStatusEvent.__tablename__,
    Contact.__tablename__,
    Company.__tablename__,
    Interview.__tablename__,
)


def undo(session: Session, batch_id: str, author: str) -> UndoReport:
    """Revert an import's batch, newest change first, in one new batch. A change edited again
    since (or a record deleted since) is left as it is and counted in `conflicts`."""
    changes = [
        c
        for c in audit.batch_changes(session, batch_id)
        if c.table_name in _UNDO_TABLES and c.reverts_change_id is None
    ]
    if not changes or any(c.author != AUTHOR for c in changes):
        raise ImportError_("that batch is not an import")
    report = UndoReport()
    with audit.transaction(session):
        for change in reversed(changes):
            already = session.scalar(
                select(audit.ChangeLog.id).where(audit.ChangeLog.reverts_change_id == change.id)
            )
            if already is not None:
                continue
            if not _revertible(session, change):
                report.conflicts += 1
                continue
            audit.revert(session, change.id, author)
            report.reverted += 1
    return report


def _revertible(session: Session, change: audit.ChangeLog) -> bool:
    """What `audit.revert` would accept: a create whose record is still live (one a revert hook
    already removed counts as done, not as a conflict), an update whose field still holds the
    imported value."""
    model = audit.model_for_table(change.table_name)
    obj = session.get(model, int(change.record_id), execution_options={"include_deleted": True})
    if obj is None:
        return False
    if obj.deleted_at is not None:
        return False
    if change.op == "create":
        if isinstance(obj, Company):  # a company something was added to since stays
            return not any(
                session.scalars(select(model.id).where(model.company_id == obj.id)).first()
                for model in (Application, Contact)
            )
        return True
    if change.op == "update" and change.field is not None:
        current = json.loads(json.dumps(getattr(obj, change.field), default=str))
        return current == audit.decode_value(change.new_value)
    return False
