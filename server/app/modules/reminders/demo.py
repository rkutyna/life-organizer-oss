"""Fictional demo reminders, for screenshots and for trying the organizer before connecting
anything. Every list and reminder here is invented.

    from app.modules.reminders import demo
    demo.seed(session)

Writes mirrored rows directly, as if the Mac helper had pushed them (Apple Reminders), and
marks the helper's source fresh. Dates are relative to today, so a few fall in this week.
Running it again replaces the demo's Apple lists and reminders.
"""

from datetime import time, timedelta

from sqlalchemy.orm import Session

from app import audit, freshness
from app.auth import service as auth_service
from app.modules.reminders import sync
from app.modules.reminders.accounts import HELPER_SOURCE
from app.timeutil import today_local, utcnow

LISTS = [
    sync.IncomingList("demo-home", "Home", "#FF9500", "iCloud", "caldav", True),
    sync.IncomingList("demo-errands", "Errands", "#007AFF", "iCloud", "caldav", True),
    sync.IncomingList("demo-work", "Work", "#34C759", "iCloud", "caldav", True),
    sync.IncomingList("demo-books", "Books to read", "#AF52DE", "iCloud", "caldav", True),
]

# (list, title, notes, due in days or None, due time or None, priority, completed days ago)
ITEMS: list[tuple[str, str, str, int | None, time | None, int | None, int | None]] = [
    ("demo-home", "Water the plants", "", 0, None, None, None),
    ("demo-home", "Replace the smoke alarm battery", "", -2, None, 1, None),
    (
        "demo-home",
        "Book a plumber for the kitchen tap",
        "Ask about Saturday",
        2,
        time(9, 0),
        2,
        None,
    ),
    ("demo-home", "Defrost the freezer", "", None, None, None, None),
    ("demo-errands", "Pick up dry cleaning", "", 1, time(17, 30), None, None),
    ("demo-errands", "Return library books", "", 3, None, None, None),
    ("demo-errands", "Buy a birthday card", "", 4, None, 2, None),
    ("demo-errands", "Renew bike insurance", "", 12, None, None, None),
    ("demo-errands", "Buy stamps", "", None, None, None, 1),
    (
        "demo-work",
        "Send the quarterly report",
        "Draft is in the shared folder",
        1,
        time(11, 0),
        1,
        None,
    ),
    ("demo-work", "Prepare slides for Thursday", "", 3, time(14, 0), None, None),
    ("demo-work", "Expense the conference trip", "", -1, None, None, None),
    ("demo-work", "Update the team wiki", "", None, None, 3, None),
    ("demo-work", "Reply to the vendor survey", "", None, None, None, 2),
    ("demo-books", "The Left Hand of Darkness", "", None, None, None, None),
    ("demo-books", "A Psalm for the Wild-Built", "", None, None, None, None),
]


def seed(session: Session) -> None:
    auth_service.apply_timezone(session)  # "today" in the owner's zone, even from a script
    now = utcnow()
    today = today_local()
    reminders = []
    for n, (list_id, title, notes, due_in, at, priority, done_ago) in enumerate(ITEMS, start=1):
        due = today + timedelta(days=due_in) if due_in is not None else None
        done_at = now - timedelta(days=done_ago) if done_ago is not None else None
        reminders.append(
            sync.IncomingReminder(
                external_id=f"demo-reminder-{n}",
                local_id=f"demo-local-{n}",
                list_id=list_id,
                title=title,
                notes=notes,
                due_date=due,
                due_time=at if due else None,
                priority=priority,
                completed=done_at is not None,
                completed_at=done_at,
                url=None,
                created_at=now - timedelta(days=20),
                modified_at=now - timedelta(days=1),
            )
        )
    with audit.transaction(session):
        sync.replace_snapshot(session, sync.Scope("apple"), LISTS, reminders, "demo-home", now)
    freshness.mark_success(session, HELPER_SOURCE, at=now)  # commits
