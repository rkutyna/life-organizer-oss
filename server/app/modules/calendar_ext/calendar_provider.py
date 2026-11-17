"""The `calendar_ext` source: events from connected calendar accounts and the Mac helper.

One registered source for all of them; each item names its own calendar (`source_label`,
`meta.calendar_key`) and keeps that calendar's color, so the web app lists one toggle per
calendar, grouped by account (`GET /api/calendar_ext/calendars`). Items are read-only.

Only enabled accounts show. The helper's copies and the server's copies of one account are
deduplicated by dedup.py, using each stream's freshness.
"""

import hashlib
from datetime import datetime, timedelta

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app import freshness
from app.calendar import CalendarItem, register_provider
from app.modules.calendar_ext import catalog, dedup
from app.modules.calendar_ext.calendar_accounts import calendar_accounts
from app.modules.calendar_ext.ingest import SOURCE as EVENTKIT
from app.modules.calendar_ext.models import ExternalEvent
from app.timeutil import to_local, utcnow

SOURCE_KEY = "calendar_ext"
SOURCE_LABEL = "Connected calendars"
COLOR = catalog.DEFAULT_COLOR


def external_items(session: Session, start: datetime, end: datetime) -> list[CalendarItem]:
    enabled = calendar_accounts(session)
    now = utcnow()
    rows = _overlapping(session, [cal.id for cal in enabled], start, end)
    by_account: dict[int, list[ExternalEvent]] = {cal.id: [] for cal in enabled}
    helper_rows = []
    for row in rows:
        if row.account_id is None:
            helper_rows.append(row)
        elif row.account_id in by_account:
            by_account[row.account_id].append(row)
    servers = [
        dedup.ServerAccount(
            name=cal.name,
            rows=by_account[cal.id],
            fresh=dedup.server_is_fresh(
                freshness.source_status(session, cal.freshness_key).last_success_at, now
            ),
        )
        for cal in enabled
    ]
    merged = dedup.merge(
        helper_rows,
        servers,
        eventkit_fresh=dedup.eventkit_is_fresh(
            freshness.source_status(session, EVENTKIT).last_success_at, now
        ),
    )
    shown = catalog.build(session, enabled)
    return [_item(row, shown) for row in merged]


def _overlapping(
    session: Session, account_ids: list[int], start: datetime, end: datetime
) -> list[ExternalEvent]:
    """Rows of enabled accounts and the helper that touch [start, end). A zero-length row
    counts if it starts inside."""
    stmt = (
        select(ExternalEvent)
        .where(
            or_(ExternalEvent.account_id.in_(account_ids), ExternalEvent.source == EVENTKIT),
            ExternalEvent.start < end,
            or_(ExternalEvent.end > start, ExternalEvent.start >= start),
        )
        .order_by(ExternalEvent.start, ExternalEvent.id)
    )
    return list(session.scalars(stmt))


def _item(row: ExternalEvent, shown: catalog.Catalog) -> CalendarItem:
    if row.all_day:
        start = to_local(row.start).date()
        end = to_local(row.end).date()
        if end <= start:
            end = start + timedelta(days=1)
    else:
        start = to_local(row.start)
        end = to_local(row.end)
    entry = shown.entry(row.account, row.calendar_title)
    account_label = (
        shown.account_labels.get(row.account_id) if row.account_id is not None else None
    ) or row.account
    return CalendarItem(
        id=f"{SOURCE_KEY}:{_stable_id(row)}",
        source=SOURCE_KEY,
        source_label=row.calendar_title or SOURCE_LABEL,
        title=row.title,
        start=start,
        end=end,
        all_day=row.all_day,
        color=entry.color,
        status=row.status,
        detail_url=row.url,
        read_only=True,
        meta={
            "calendar_key": entry.key,
            "calendar": row.calendar_title,
            "account": account_label or None,
            "account_id": row.account_id,
            "location": row.location,
            "origin": row.source,
        },
    )


def _stable_id(row: ExternalEvent) -> str:
    """The same event keeps its id whichever stream currently supplies it."""
    key = "\x1f".join(
        [
            dedup.account_key(row.account),
            row.calendar_title,
            row.uid,
            row.occurrence_start.isoformat(),
        ]
    )
    return hashlib.sha256(key.encode()).hexdigest()[:32]


register_provider(SOURCE_KEY, SOURCE_LABEL, COLOR, external_items, freshness_source=EVENTKIT)
