"""Synthetic fixtures for the calendar_ext tests. Every name, address, time and calendar here is
invented; servers are example.com hosts that are never contacted."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from sqlalchemy.orm import Session

from app.config import Settings
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount

ICLOUD_USER = "someone@example.com"
GOOGLE_USER = "someone.else@example.com"


def push_body(window: dict, calendars: list[dict], events: list[dict]) -> dict:
    """A helper push as the Mac helper sends it (envelope fields included)."""
    return {
        "source": "eventkit",
        "window": window,
        "calendars": calendars,
        "events": events,
        "collected_at": "2026-04-15T12:00:00Z",
        "host": "test-mac",
    }


def ek_calendar(
    cal_id: str,
    title: str,
    *,
    color: str | None = "#3366CC",
    account: str | None = "iCloud",
    account_type: str | None = "caldav",
) -> dict:
    return {
        "id": cal_id,
        "title": title,
        "color": color,
        "account": account,
        "account_type": account_type,
    }


def ek_event(
    uid: str,
    calendar_id: str,
    title: str,
    start: str,
    end: str,
    *,
    all_day: bool = False,
    occurrence_start: str | None = None,
    location: str | None = None,
    url: str | None = None,
    status: str = "confirmed",
) -> dict:
    return {
        "uid": uid,
        "calendar_id": calendar_id,
        "title": title,
        "start": start,
        "end": end,
        "all_day": all_day,
        "location": location,
        "url": url,
        "occurrence_start": occurrence_start or start,
        "status": status,
    }


@dataclass
class FakeCalDAV:
    """Stands in for DAVSource (a CalDAVSource). Records calls; can be told to fail.

    `remote_calendars` holds RemoteCalendar values; `texts` maps a calendar's ext_id to its
    iCalendar resources.
    """

    remote_calendars: list[Any] = field(default_factory=list)
    texts: dict[str, list[str]] = field(default_factory=dict)
    fail_with: Exception | None = None
    calls: list[Any] = field(default_factory=list)

    def calendars(self) -> list[Any]:
        self.calls.append(("calendars",))
        if self.fail_with is not None:
            raise self.fail_with
        return list(self.remote_calendars)

    def ical_texts(self, calendar: Any, start: datetime, end: datetime) -> list[str]:
        self.calls.append(("ical_texts", calendar.ext_id, start, end))
        return list(self.texts.get(calendar.ext_id, []))


def vcalendar(*components: str) -> str:
    body = "\r\n".join(components)
    header = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//synthetic//test//EN"
    return f"{header}\r\n{body}\r\nEND:VCALENDAR\r\n"


def vevent(uid: str, summary: str, *lines: str) -> str:
    body = "\r\n".join([f"UID:{uid}", f"SUMMARY:{summary}", *lines])
    return f"BEGIN:VEVENT\r\n{body}\r\nEND:VEVENT"


def caldav_account(
    session: Session,
    settings: Settings,
    *,
    preset: str = "icloud",
    label: str = "iCloud",
    url: str = "https://caldav.icloud.com",
    username: str = ICLOUD_USER,
) -> ProviderAccount:
    return accounts.create(
        session,
        settings,
        kind="caldav",
        label=label,
        credentials={"password": "synthetic-app-password"},
        config={"preset": preset, "url": url, "username": username},
    )


def google_account(
    session: Session, settings: Settings, *, email: str = GOOGLE_USER, calendar: bool = True
) -> ProviderAccount:
    scopes = [google.SCOPES["calendar"]] if calendar else [google.SCOPES["gmail"]]
    return accounts.create(
        session,
        settings,
        kind="google",
        label=email,
        credentials={"refresh_token": "synthetic-refresh-token"},
        config={"email": email, "scopes": scopes},
    )
