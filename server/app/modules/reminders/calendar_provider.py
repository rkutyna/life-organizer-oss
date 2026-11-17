"""Dated, incomplete reminders on the unified calendar (source "reminders").

Each reminder is shown as the organizer shows it everywhere (queued changes applied), so one
checked off in the organizer leaves the calendar at once. A reminder with only a due date is an
all-day item; one with a time is a 30-minute item. Items keep their list's color, are
read-only here (the provider is the source of truth) and link to the reminders page, where
they are edited.

The source has no single freshness entry: Apple and each Google account keep their own, shown
on the reminders page (`GET /api/reminders/status`).
"""

from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from app.calendar import CalendarItem, local_date_bounds, register_provider
from app.modules.reminders import sync
from app.modules.reminders.router import visible_rows
from app.timeutil import combine_local

SOURCE_KEY = "reminders"
SOURCE_LABEL = "Reminders"
COLOR = "#F19A37"  # used when a list has no color of its own
TIMED_LENGTH = timedelta(minutes=30)


def reminder_items(session: Session, start: datetime, end: datetime) -> list[CalendarItem]:
    first, stop = local_date_bounds(start, end)
    items = []
    for out in sync.render(session, visible_rows(session)):
        if out.completed or out.due_date is None or not first <= out.due_date < stop:
            continue
        if out.due_time is None:
            item_start, item_end, all_day = out.due_date, out.due_date + timedelta(days=1), True
        else:
            item_start = combine_local(out.due_date, out.due_time)
            item_end, all_day = item_start + TIMED_LENGTH, False
        items.append(
            CalendarItem(
                id=f"{SOURCE_KEY}:{out.id}",
                source=SOURCE_KEY,
                source_label=SOURCE_LABEL,
                title=out.title,
                start=item_start,
                end=item_end,
                all_day=all_day,
                color=out.list_color or COLOR,
                status="open",
                detail_url=f"/reminders?reminder={out.id}",
                read_only=True,
                meta={
                    "reminder_id": out.id,
                    "list": out.list_title,
                    "list_id": out.list_id,
                    "provider": out.source,
                    "priority": out.priority,
                    "sync_state": out.sync.state,
                },
            )
        )
    return items


register_provider(SOURCE_KEY, SOURCE_LABEL, COLOR, reminder_items)
