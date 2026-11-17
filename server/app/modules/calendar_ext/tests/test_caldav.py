"""The CalDAV poll with a fake client: expansion, per-account replacement, failures, the job.

Nothing here contacts a server: tests inject a FakeCalDAV or monkeypatch `caldav_sync.connect`.
"""

from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.calendar_ext import caldav_sync, jobs
from app.modules.calendar_ext.caldav_sync import RemoteCalendar, SyncResult, sync_account
from app.modules.calendar_ext.models import ExternalCalendar, ExternalEvent
from app.modules.calendar_ext.tests.support import (
    FakeCalDAV,
    caldav_account,
    vcalendar,
    vevent,
)
from app.providers import service as accounts
from app.timeutil import set_timezone

NY = ZoneInfo("America/New_York")
NOW = datetime(2026, 4, 15, 12, tzinfo=UTC)
WORK_URL = "https://caldav.example.com/calendars/work/"
HOME_URL = "https://caldav.example.com/calendars/home/"

STANDUP = vevent(
    "standup@example.com",
    "Weekly standup",
    "DTSTART;TZID=America/New_York:20260302T090000",
    "DTEND;TZID=America/New_York:20260302T093000",
    "RRULE:FREQ=WEEKLY;COUNT=4",
    "LOCATION:Room A",
    "STATUS:CONFIRMED",
)
# The March 9 occurrence is moved to 11:00. Its RECURRENCE-ID keeps the original 09:00 slot.
STANDUP_MOVED = vevent(
    "standup@example.com",
    "Weekly standup (moved)",
    "RECURRENCE-ID;TZID=America/New_York:20260309T090000",
    "DTSTART;TZID=America/New_York:20260309T110000",
    "DTEND;TZID=America/New_York:20260309T113000",
)
OFFSITE = vevent(
    "offsite@example.com",
    "Team offsite",
    "DTSTART;VALUE=DATE:20260420",
    "DTEND;VALUE=DATE:20260421",
)
ANCIENT = vevent(
    "ancient@example.com",
    "Ancient",
    "DTSTART;TZID=America/New_York:20100105T100000",
    "DTEND;TZID=America/New_York:20100105T110000",
)


@pytest.fixture(autouse=True)
def new_york():
    set_timezone("America/New_York")
    yield
    set_timezone(None)


def work_fake(*components: str) -> FakeCalDAV:
    return FakeCalDAV(
        remote_calendars=[RemoteCalendar(ext_id=WORK_URL, title="Work", color="#3366CCFF")],
        texts={WORK_URL: [vcalendar(*components)]},
    )


def events_of(session: Session, account_id: int) -> list[ExternalEvent]:
    stmt = (
        select(ExternalEvent)
        .where(ExternalEvent.account_id == account_id)
        .order_by(ExternalEvent.occurrence_start, ExternalEvent.uid)
    )
    return list(session.scalars(stmt))


def test_sync_expands_recurrences_and_writes_the_accounts_rows(
    session: Session, settings: Settings
):
    account = caldav_account(session, settings)

    result = sync_account(
        session, settings, account, source=work_fake(STANDUP, OFFSITE, ANCIENT), now=NOW
    )

    assert result == SyncResult(calendars=1, events=5)
    rows = events_of(session, account.id)
    standups = [r for r in rows if r.uid == "standup@example.com"]
    assert [r.occurrence_start.astimezone(NY).day for r in standups] == [2, 9, 16, 23]
    assert {r.start.astimezone(NY).hour for r in standups} == {9}
    assert all(r.source == "caldav" and r.account == "iCloud" for r in rows)
    assert all(r.calendar_title == "Work" and r.calendar_ext_id == WORK_URL for r in rows)
    assert standups[0].location == "Room A"
    assert standups[0].status == "confirmed"
    assert not any(r.uid == "ancient@example.com" for r in rows)

    offsite = next(r for r in rows if r.uid == "offsite@example.com")
    assert offsite.all_day is True
    assert offsite.start.astimezone(NY).timetuple()[:5] == (2026, 4, 20, 0, 0)
    assert offsite.end.astimezone(NY).timetuple()[:5] == (2026, 4, 21, 0, 0)

    [calendar] = session.scalars(select(ExternalCalendar))
    assert (calendar.title, calendar.color, calendar.account_id) == ("Work", "#3366CC", account.id)

    assert freshness.source_status(session, f"calendar:{account.id}").last_success_at == NOW
    assert accounts.status(account) == "ok"


def test_a_generic_account_is_named_by_its_label(session: Session, settings: Settings):
    account = caldav_account(
        session, settings, preset="caldav", label="Team server", url="https://dav.example.com/"
    )

    sync_account(session, settings, account, source=work_fake(OFFSITE), now=NOW)

    assert {r.account for r in events_of(session, account.id)} == {"Team server"}


def test_an_edited_occurrence_keeps_its_original_slot_for_dedup(
    session: Session, settings: Settings
):
    account = caldav_account(session, settings)

    sync_account(session, settings, account, source=work_fake(STANDUP, STANDUP_MOVED), now=NOW)

    moved = next(r for r in events_of(session, account.id) if r.title.endswith("(moved)"))
    assert moved.occurrence_start.astimezone(NY).timetuple()[:5] == (2026, 3, 9, 9, 0)
    assert moved.start.astimezone(NY).timetuple()[:5] == (2026, 3, 9, 11, 0)


def test_each_sync_replaces_only_that_accounts_rows(session: Session, settings: Settings):
    first = caldav_account(session, settings)
    other = caldav_account(
        session, settings, preset="caldav", label="Other", url="https://dav.example.com/"
    )
    sync_account(session, settings, first, source=work_fake(STANDUP, OFFSITE), now=NOW)
    sync_account(session, settings, other, source=work_fake(OFFSITE), now=NOW)

    second = FakeCalDAV(
        remote_calendars=[RemoteCalendar(ext_id=HOME_URL, title="Home", color=None)],
        texts={HOME_URL: [vcalendar(OFFSITE)]},
    )
    sync_account(session, settings, first, source=second, now=NOW)

    assert [(r.calendar_title, r.uid) for r in events_of(session, first.id)] == [
        ("Home", "offsite@example.com")
    ]
    assert len(events_of(session, other.id)) == 1


def test_a_failed_fetch_keeps_the_previous_rows(session: Session, settings: Settings):
    account = caldav_account(session, settings)
    sync_account(session, settings, account, source=work_fake(STANDUP), now=NOW)
    before = len(events_of(session, account.id))

    broken = FakeCalDAV(fail_with=RuntimeError("server unreachable"))
    with pytest.raises(RuntimeError, match="server unreachable"):
        sync_account(session, settings, account, source=broken, now=NOW)

    assert len(events_of(session, account.id)) == before
    status = freshness.source_status(session, f"calendar:{account.id}")
    assert status.state == "error"
    assert status.last_error == "server unreachable"
    assert status.last_success_at == NOW
    assert accounts.status(account) == "error"


def test_the_real_client_is_built_from_the_stored_account(
    session: Session, settings: Settings, monkeypatch
):
    account = caldav_account(
        session, settings, preset="caldav", label="Team", url="https://dav.example.com/u/"
    )
    seen = []

    def fake_connect(url, username, password):
        seen.append((url, username, password))
        return work_fake(OFFSITE)

    monkeypatch.setattr(caldav_sync, "connect", fake_connect)

    sync_account(session, settings, account, now=NOW)

    assert seen == [("https://dav.example.com/u/", "someone@example.com", "synthetic-app-password")]


def test_removing_an_account_removes_its_rows_right_away(
    session: Session, settings: Settings, client
):
    account = caldav_account(session, settings)
    sync_account(session, settings, account, source=work_fake(STANDUP), now=NOW)
    account_id = account.id

    assert client.delete(f"/api/settings/accounts/{account_id}").status_code == 204

    session.expire_all()
    assert events_of(session, account_id) == []
    assert list(session.scalars(select(ExternalCalendar))) == []


def test_the_poll_job_syncs_every_enabled_account_and_forgets_removed_ones(
    app, settings: Settings, session: Session, monkeypatch
):
    class FakeScheduler:
        def __init__(self) -> None:
            self.added: list[tuple] = []

        def add_job(self, func, trigger, **kwargs) -> None:
            self.added.append((func, trigger, kwargs))

    good = caldav_account(session, settings)
    broken = caldav_account(
        session, settings, preset="caldav", label="Broken", url="https://broken.example.com/"
    )
    off = caldav_account(
        session, settings, preset="caldav", label="Off", url="https://off.example.com/"
    )
    off.enabled = False
    session.commit()
    freshness.mark_success(session, "calendar:999")  # an account removed long ago

    def fake_connect(url, username, password):
        if "broken" in url:
            return FakeCalDAV(fail_with=RuntimeError("login refused"))
        if "off" in url:
            raise AssertionError("a disabled account must not be polled")
        return work_fake(OFFSITE)

    monkeypatch.setattr(caldav_sync, "connect", fake_connect)
    scheduler = FakeScheduler()
    jobs.register_jobs(scheduler, app.state.session_factory, settings)

    [(poll, trigger, kwargs)] = scheduler.added
    assert trigger == "interval"
    assert kwargs["minutes"] == 15
    assert kwargs["id"] == "calendar_ext_poll"

    poll()  # one failing account does not stop the others

    session.expire_all()
    assert len(events_of(session, good.id)) == 1
    assert freshness.source_status(session, f"calendar:{broken.id}").last_error == "login refused"
    registered = freshness.registered_sources()
    assert f"calendar:{good.id}" in registered
    assert f"calendar:{off.id}" not in registered
    assert "calendar:999" not in {s.source for s in freshness.all_statuses(session)}
