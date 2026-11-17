"""Fictional demo calendars for screenshots and trying the app (`python -m app.demo_seed`).

One demo CalDAV account with two calendars and a week of made-up events around today. The
account has no credentials, so run the demo with SCHEDULER_ENABLED=false or its sync will fail.
"""

from datetime import date, datetime, time, timedelta

from sqlalchemy.orm import Session

from app import freshness
from app.config import get_settings
from app.modules.calendar_ext.calendar_accounts import CALDAV_KIND, freshness_key
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.providers import service as accounts
from app.timeutil import local_tz, today_local, utcnow

CALENDARS = {
    "home": ("Home", "#3b82f6"),
    "work": ("Work", "#10b981"),
}

# (calendar, day offset from this week's Monday, start hour or None for all-day, hours, title)
EVENTS = [
    ("work", 0, 9, 1, "Team stand-up"),
    ("work", 0, 14, 1.5, "Design review"),
    ("home", 1, 18, 1, "Climbing gym"),
    ("work", 2, 11, 0.5, "1:1 with manager"),
    ("home", 2, 19, 2, "Dinner with friends"),
    ("work", 3, 10, 2, "Quarterly planning"),
    ("home", 4, None, 1, "Pay rent"),
    ("home", 5, 10, 3, "Farmers market and errands"),
    ("home", 6, 16, 1, "Call family"),
]


def seed(session: Session) -> None:
    account = accounts.create(
        session,
        get_settings(),
        kind=CALDAV_KIND,
        label="Demo calendars",
        credentials=None,
        config={"preset": "caldav", "url": "https://caldav.example.com", "username": "demo"},
    )
    monday = today_local() - timedelta(days=today_local().weekday())
    now = utcnow()
    for key, (title, color) in CALENDARS.items():
        session.add(
            ExternalCalendar(
                source="caldav",
                account_id=account.id,
                ext_id=f"https://caldav.example.com/demo/{key}/",
                title=title,
                color=color,
                account=account.label,
                account_type="caldav",
            )
        )
    for n, (key, offset, hour, hours, title) in enumerate(EVENTS):
        day = monday + timedelta(days=offset)
        start, end, all_day = _times(day, hour, hours)
        session.add(
            ExternalEvent(
                source="caldav",
                account_id=account.id,
                uid=f"demo-{n}@example.com",
                occurrence_start=start,
                calendar_ext_id=f"https://caldav.example.com/demo/{key}/",
                calendar_title=CALENDARS[key][0],
                account=account.label,
                account_type="caldav",
                title=title,
                start=start,
                end=end,
                all_day=all_day,
                status="confirmed",
                received_at=now,
            )
        )
    session.commit()
    freshness.mark_success(session, freshness_key(account.id))
    accounts.mark_success(session, account)


def _times(day: date, hour: float | None, hours: float) -> tuple[datetime, datetime, bool]:
    tz = local_tz()
    if hour is None:
        start = datetime.combine(day, time.min, tzinfo=tz)
        return start, start + timedelta(days=1), True
    start = datetime.combine(day, time(int(hour), int(hour % 1 * 60)), tzinfo=tz)
    return start, start + timedelta(hours=hours), False
