"""The CalDAV poll: one connected CalDAV account (iCloud or any other server) at a time.

Every run lists the account's event calendars, fetches each one's events from one year back to
one year ahead, expands recurrences (recurring_ical_events) and replaces that account's rows.
A run either replaces everything or nothing: a failed fetch leaves the previous rows and
records the error on the account and on its freshness source.

The network sits behind `CalDAVSource`. Tests replace `connect` (or pass `source=`) with a
fake and never reach a server.
"""

from dataclasses import dataclass
from datetime import datetime, time, timedelta
from typing import Any, Protocol

import icalendar
import recurring_ical_events
from caldav.elements.ical import CalendarColor
from sqlalchemy import delete
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.calendar_ext.calendar_accounts import account_name, freshness_key
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.modules.calendar_ext.normalize import all_day_date, aware_utc, midnight, normalize_color
from app.providers import service as accounts
from app.providers.models import ProviderAccount
from app.timeutil import combine_local, to_local, utcnow

SOURCE = "caldav"
ACCOUNT_TYPE = "caldav"
WINDOW_DAYS = 365  # one year back and one year ahead
REQUEST_TIMEOUT_SECONDS = 30

_STATUS = {"CONFIRMED": "confirmed", "TENTATIVE": "tentative", "CANCELLED": "canceled"}


@dataclass(frozen=True)
class RemoteCalendar:
    ext_id: str  # the calendar URL
    title: str
    color: str | None


class CalDAVSource(Protocol):
    """What the sync needs from a CalDAV server. The real one is DAVSource."""

    def calendars(self) -> list[RemoteCalendar]:
        """Event calendars only (task lists are skipped)."""
        ...

    def ical_texts(self, calendar: RemoteCalendar, start: datetime, end: datetime) -> list[str]:
        """The iCalendar text of each event resource that has an instance in [start, end).

        Recurring events come back unexpanded (one RRULE per resource); expansion happens here.
        """
        ...


class LoginFailed(Exception):
    """The server refused the username and password."""


class DAVSource:
    """The real client, over the caldav library. Connects on first use; not exercised by tests."""

    def __init__(self, url: str, username: str, password: str) -> None:
        self._url = url
        self._username = username
        self._password = password
        self._client: Any = None
        self._calendars: dict[str, Any] = {}

    def _dav(self) -> Any:
        if self._client is None:
            import caldav

            self._client = caldav.DAVClient(
                url=self._url,
                username=self._username,
                password=self._password,
                timeout=REQUEST_TIMEOUT_SECONDS,
                enable_rfc6764=False,  # the URL is given in full; no DNS discovery
            )
        return self._client

    def calendars(self) -> list[RemoteCalendar]:
        from caldav.lib.error import AuthorizationError

        try:
            found = self._dav().principal().calendars()
        except AuthorizationError as exc:
            raise LoginFailed("the server refused the username or password") from exc
        remote = []
        for calendar in found:
            try:
                components = {str(c).upper() for c in calendar.get_supported_components()}
            except Exception:  # servers that do not say are assumed to hold events
                components = {"VEVENT"}
            if "VEVENT" not in components:
                continue
            ext_id = str(calendar.url)
            self._calendars[ext_id] = calendar
            remote.append(
                RemoteCalendar(
                    ext_id=ext_id,
                    title=str(calendar.name or ""),
                    color=_server_color(calendar),
                )
            )
        return remote

    def ical_texts(self, calendar: RemoteCalendar, start: datetime, end: datetime) -> list[str]:
        found = self._calendars[calendar.ext_id].search(
            event=True, start=start, end=end, expand=False
        )
        return [obj.data for obj in found if obj.data]


def connect(url: str, username: str, password: str) -> CalDAVSource:
    """The client for one account. Tests monkeypatch this."""
    return DAVSource(url, username, password)


def _server_color(calendar: Any) -> str | None:
    try:
        properties = calendar.get_properties([CalendarColor()])
    except Exception:  # a missing color is cosmetic; the calendar still syncs
        return None
    for value in properties.values():
        if isinstance(value, str):
            return normalize_color(value)
    return None


@dataclass(frozen=True)
class SyncResult:
    calendars: int
    events: int


def sync_window(now: datetime) -> tuple[datetime, datetime]:
    """[start, end): local midnight one year back to local midnight a year and a day ahead."""
    today = to_local(now).date()
    return (
        combine_local(today - timedelta(days=WINDOW_DAYS), time.min),
        combine_local(today + timedelta(days=WINDOW_DAYS + 1), time.min),
    )


def source_for(settings: Settings, account: ProviderAccount) -> CalDAVSource:
    config = accounts.config(account)
    password = str(accounts.credentials(settings, account).get("password", ""))
    return connect(str(config.get("url", "")), str(config.get("username", "")), password)


def sync_account(
    session: Session,
    settings: Settings,
    account: ProviderAccount,
    *,
    source: CalDAVSource | None = None,
    now: datetime | None = None,
) -> SyncResult:
    """Poll one CalDAV account and replace its rows. Errors are recorded and re-raised."""
    now = now or utcnow()
    key = freshness_key(account.id)
    name = account_name(account)
    start, end = sync_window(now)
    try:
        client = source if source is not None else source_for(settings, account)
        calendars: list[ExternalCalendar] = []
        events: list[ExternalEvent] = []
        for remote in client.calendars():
            calendars.append(
                ExternalCalendar(
                    source=SOURCE,
                    account_id=account.id,
                    ext_id=remote.ext_id,
                    title=remote.title,
                    color=normalize_color(remote.color),
                    account=name,
                    account_type=ACCOUNT_TYPE,
                )
            )
            for text in client.ical_texts(remote, start, end):
                events.extend(
                    event_rows(text, remote, start, end, now, account_id=account.id, account=name)
                )
        replace_account_rows(session, account.id, calendars, events)
        freshness.mark_success(session, key, at=now)  # commits
        accounts.mark_success(session, account)
    except Exception as exc:
        session.rollback()
        message = str(exc) or type(exc).__name__
        freshness.mark_error(session, key, message)
        accounts.mark_error(session, account, message)
        raise
    return SyncResult(calendars=len(calendars), events=len(events))


def replace_account_rows(
    session: Session,
    account_id: int,
    calendars: list[ExternalCalendar],
    events: list[ExternalEvent],
) -> None:
    """Swap one account's rows for a new snapshot. Does not commit."""
    session.execute(delete(ExternalEvent).where(ExternalEvent.account_id == account_id))
    session.execute(delete(ExternalCalendar).where(ExternalCalendar.account_id == account_id))
    session.add_all([*calendars, *events])


def event_rows(
    text: str,
    calendar: RemoteCalendar,
    start: datetime,
    end: datetime,
    received_at: datetime,
    *,
    account_id: int,
    account: str,
) -> list[ExternalEvent]:
    """One ExternalEvent per occurrence of the events in one iCalendar resource, in [start, end)."""
    component = icalendar.Calendar.from_ical(text)
    rows = []
    for occ in recurring_ical_events.of(component).between(start, end):
        uid = str(occ.get("UID") or "").strip()
        if not uid:
            continue
        first = occ.start
        last = occ.end
        all_day = not isinstance(first, datetime)
        # Dedup needs the same occurrence start the Mac reports. For an edited occurrence that
        # is the RECURRENCE-ID (the original slot), not the moved DTSTART.
        original = occ.get("RECURRENCE-ID")
        occurrence = original.dt if original is not None else first
        if all_day:
            first_day = all_day_date(first)
            last_day = all_day_date(last) if last is not None else first_day
            if last_day <= first_day:
                last_day = first_day + timedelta(days=1)
            row_start, row_end = midnight(first_day), midnight(last_day)
            row_occurrence = midnight(all_day_date(occurrence))
        else:
            row_start = aware_utc(first)
            row_end = aware_utc(last) if last is not None else row_start
            row_occurrence = aware_utc(occurrence)
        status = str(occ.get("STATUS") or "").upper()
        rows.append(
            ExternalEvent(
                source=SOURCE,
                account_id=account_id,
                uid=uid,
                occurrence_start=row_occurrence,
                calendar_ext_id=calendar.ext_id,
                calendar_title=calendar.title,
                account=account,
                account_type=ACCOUNT_TYPE,
                title=str(occ.get("SUMMARY") or ""),
                start=row_start,
                end=row_end,
                all_day=all_day,
                location=str(occ.get("LOCATION") or "") or None,
                url=str(occ.get("URL") or "") or None,
                status=_STATUS.get(status, "none"),
                received_at=received_at,
            )
        )
    return rows
