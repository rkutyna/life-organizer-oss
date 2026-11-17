"""The Google Calendar poll: one Google account (that granted the calendar scope) at a time.

Every run reads the account's calendar list (every calendar it shows, with Google's colors)
and each calendar's events over the same window as CalDAV, with `singleEvents=true` so Google
expands recurrences. It replaces that account's rows, all or nothing, like the CalDAV poll.

This is a windowed full refresh, not an incremental sync: Google's sync tokens cannot be
combined with `timeMin`/`timeMax`, and without a window `singleEvents=true` would expand
endless recurrences.

HTTP goes through `app.providers.google.make_client()`, which tests point at an
`httpx.MockTransport`.
"""

from datetime import date, datetime, timedelta
from typing import Any
from urllib.parse import quote

import httpx
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.calendar_ext.caldav_sync import SyncResult, replace_account_rows, sync_window
from app.modules.calendar_ext.calendar_accounts import account_name, freshness_key
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.modules.calendar_ext.normalize import aware_utc, midnight, normalize_color
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount
from app.timeutil import utcnow

SOURCE = "google"
ACCOUNT_TYPE = "caldav"  # what the Mac reports for a Google account
API = "https://www.googleapis.com/calendar/v3"
PAGE_SIZE = 2500
MAX_PAGES = 40  # a runaway pager stops here (100k events per calendar)

_STATUS = {"confirmed": "confirmed", "tentative": "tentative", "cancelled": "canceled"}


class GoogleCalendarError(Exception):
    """Google answered with an error the sync cannot get past."""


def sync_account(
    session: Session,
    settings: Settings,
    account: ProviderAccount,
    *,
    now: datetime | None = None,
) -> SyncResult:
    """Poll one Google account and replace its rows. Errors are recorded and re-raised.

    A refused grant (`GoogleAuthError`) has already marked the account itself as failing.
    """
    now = now or utcnow()
    key = freshness_key(account.id)
    name = account_name(account)
    start, end = sync_window(now)
    try:
        token = google.access_token(session, settings, account)
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        calendars: list[ExternalCalendar] = []
        events: list[ExternalEvent] = []
        with google.make_client() as http:
            for entry in _pages(http, f"{API}/users/me/calendarList", {}, headers):
                if entry.get("deleted"):
                    continue
                calendar = ExternalCalendar(
                    source=SOURCE,
                    account_id=account.id,
                    ext_id=str(entry["id"]),
                    title=str(entry.get("summaryOverride") or entry.get("summary") or ""),
                    color=normalize_color(entry.get("backgroundColor")),
                    account=name,
                    account_type=ACCOUNT_TYPE,
                )
                calendars.append(calendar)
                params = {
                    "singleEvents": "true",
                    "timeMin": start.isoformat(),
                    "timeMax": end.isoformat(),
                    "maxResults": str(PAGE_SIZE),
                    "showDeleted": "false",
                }
                url = f"{API}/calendars/{quote(calendar.ext_id, safe='')}/events"
                untitled = "Busy" if entry.get("accessRole") == "freeBusyReader" else "(No title)"
                for item in _pages(http, url, params, headers):
                    row = event_row(item, calendar, now, untitled=untitled)
                    if row is not None:
                        events.append(row)
        replace_account_rows(session, account.id, calendars, events)
        freshness.mark_success(session, key, at=now)  # commits
        accounts.mark_success(session, account)
    except Exception as exc:
        session.rollback()
        message = str(exc) or type(exc).__name__
        if isinstance(exc, google.GoogleAuthError):
            message = f"Google refused the sign-in; reconnect the account in Settings ({message})"
        freshness.mark_error(session, key, message)
        if not isinstance(exc, google.GoogleAuthError):  # access_token already marked it
            accounts.mark_error(session, account, f"Calendar: {message}")
        raise
    return SyncResult(calendars=len(calendars), events=len(events))


def _pages(
    http: httpx.Client, url: str, params: dict[str, str], headers: dict[str, str]
) -> list[dict[str, Any]]:
    """Every item of a paged Google list."""
    items: list[dict[str, Any]] = []
    page_token: str | None = None
    for _ in range(MAX_PAGES):
        query = {**params, **({"pageToken": page_token} if page_token else {})}
        response = http.get(url, params=query, headers=headers)
        if response.status_code != 200:
            raise GoogleCalendarError(_error_message(response))
        body = response.json()
        items.extend(body.get("items", []))
        page_token = body.get("nextPageToken")
        if not page_token:
            break
    return items


def _error_message(response: httpx.Response) -> str:
    try:
        detail = response.json().get("error", {}).get("message")
    except ValueError:
        detail = None
    return f"Google Calendar answered {response.status_code}" + (f": {detail}" if detail else "")


def _when(value: dict[str, Any]) -> datetime | date | None:
    if value.get("dateTime"):
        return datetime.fromisoformat(value["dateTime"])
    if value.get("date"):
        return date.fromisoformat(value["date"])
    return None


def event_row(
    item: dict[str, Any],
    calendar: ExternalCalendar,
    received_at: datetime,
    *,
    untitled: str = "(No title)",
) -> ExternalEvent | None:
    """One occurrence (singleEvents=true already expanded it), or None to skip it."""
    if item.get("status") == "cancelled":
        return None
    first = _when(item.get("start") or {})
    if first is None:
        return None
    last = _when(item.get("end") or {}) or first
    # A moved instance of a recurring event keeps its original slot for dedup.
    original = _when(item.get("originalStartTime") or {}) or first
    all_day = not isinstance(first, datetime)
    if all_day:
        first_day = first if isinstance(first, date) else first.date()
        last_day = last if isinstance(last, date) and not isinstance(last, datetime) else first_day
        if last_day <= first_day:
            last_day = first_day + timedelta(days=1)
        occurrence_day = original.date() if isinstance(original, datetime) else original
        start, end, occurrence = midnight(first_day), midnight(last_day), midnight(occurrence_day)
    else:
        start = aware_utc(first)
        end = aware_utc(last) if isinstance(last, datetime) else start
        occurrence = aware_utc(original) if isinstance(original, datetime) else start
    return ExternalEvent(
        source=SOURCE,
        account_id=calendar.account_id,
        uid=str(item.get("iCalUID") or item.get("id") or ""),
        occurrence_start=occurrence,
        calendar_ext_id=calendar.ext_id,
        calendar_title=calendar.title,
        account=calendar.account,
        account_type=ACCOUNT_TYPE,
        # Calendars shared as free/busy only send no summary.
        title=str(item.get("summary") or untitled),
        start=start,
        end=end,
        all_day=all_day,
        location=item.get("location") or None,
        url=item.get("htmlLink") or None,
        status=_STATUS.get(str(item.get("status") or ""), "none"),
        received_at=received_at,
    )
