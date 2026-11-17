"""dedup.py in isolation: the per-account rule, the account match and the copy key."""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest

from app.modules.calendar_ext import dedup
from app.modules.calendar_ext.dedup import ServerAccount

NOW = datetime(2026, 4, 15, 12, tzinfo=UTC)
START = datetime(2026, 4, 15, 13, tzinfo=UTC)


@dataclass(frozen=True)
class Row:
    label: str
    uid: str
    calendar_title: str = "Work"
    account: str = "iCloud"
    account_type: str | None = "caldav"
    occurrence_start: datetime = START


def labels(rows: list[Row]) -> list[str]:
    return [row.label for row in rows]


def icloud(*rows: Row, fresh: bool = True) -> ServerAccount[Row]:
    return ServerAccount(name="iCloud", rows=rows, fresh=fresh)


def test_fresh_helper_wins_and_the_server_fills_only_missing_keys():
    eventkit = [Row("ek-a", "a"), Row("ek-family", "fam", "Family")]
    server = icloud(Row("cd-a", "a"), Row("cd-c", "c"))

    merged = dedup.merge(eventkit, [server], eventkit_fresh=True)

    assert labels(merged) == ["ek-a", "ek-family", "cd-c"]


def test_key_is_scoped_by_calendar_title_account_and_occurrence():
    eventkit = [Row("ek-a", "a")]
    server = icloud(
        Row("cd-other-calendar", "a", calendar_title="Home"),
        Row("cd-other-occurrence", "a", occurrence_start=START + timedelta(days=7)),
    )

    merged = dedup.merge(eventkit, [server], eventkit_fresh=True)

    assert labels(merged) == ["ek-a", "cd-other-calendar", "cd-other-occurrence"]


def test_account_names_match_ignoring_case_and_spaces():
    eventkit = [Row("ek-a", "a", account=" ICLOUD ")]
    server = icloud(Row("cd-a", "a"))

    assert labels(dedup.merge(eventkit, [server], eventkit_fresh=True)) == ["ek-a"]
    assert labels(dedup.merge(eventkit, [server], eventkit_fresh=False)) == ["cd-a"]


def test_stale_helper_and_fresh_server_drop_that_accounts_helper_rows_only():
    eventkit = [
        Row("ek-icloud-a", "a"),
        Row("ek-icloud-only", "solo"),
        Row("ek-other", "g", "Team", "Fastmail", "caldav"),
        Row("ek-local", "l", "Notes", "On My Mac", "local"),
    ]
    server = icloud(Row("cd-a", "a"))

    merged = dedup.merge(eventkit, [server], eventkit_fresh=False)

    assert labels(merged) == ["cd-a", "ek-other", "ek-local"]


def test_both_stale_hides_nothing_and_the_server_wins_shared_keys():
    eventkit = [Row("ek-shared", "a"), Row("ek-icloud-only", "b")]
    server = icloud(Row("cd-shared", "a"), fresh=False)

    merged = dedup.merge(eventkit, [server], eventkit_fresh=False)

    assert labels(merged) == ["cd-shared", "ek-icloud-only"]


def test_helper_rows_of_an_account_not_connected_are_always_shown():
    eventkit = [Row("ek-a", "a"), Row("ek-b", "b", account="someone@example.com")]

    assert labels(dedup.merge(eventkit, [], eventkit_fresh=False)) == ["ek-a", "ek-b"]


def test_a_local_calendar_with_a_connected_accounts_name_is_not_matched():
    eventkit = [Row("ek-local", "a", account="iCloud", account_type="local")]
    server = icloud(Row("cd-a", "a"))

    merged = dedup.merge(eventkit, [server], eventkit_fresh=False)

    assert labels(merged) == ["cd-a", "ek-local"]


def test_each_connected_account_follows_its_own_freshness():
    eventkit = [
        Row("ek-icloud", "a"),
        Row("ek-google", "g", "Team", "someone@example.com"),
    ]
    servers = [
        icloud(Row("cd-icloud", "a"), fresh=True),
        ServerAccount(
            "someone@example.com", [Row("g-other", "x", "Team", "someone@example.com")], False
        ),
    ]

    merged = dedup.merge(eventkit, servers, eventkit_fresh=False)

    # iCloud is fresh: its server copy only. Google is stale too: both, server first.
    assert labels(merged) == ["cd-icloud", "g-other", "ek-google"]


def test_accounts_sharing_a_name_are_fresh_only_together():
    eventkit = [Row("ek-a", "a")]
    servers = [icloud(Row("cd-1", "x"), fresh=True), icloud(Row("cd-2", "y"), fresh=False)]

    merged = dedup.merge(eventkit, servers, eventkit_fresh=False)

    assert labels(merged) == ["cd-1", "cd-2", "ek-a"]


@pytest.mark.parametrize("eventkit_fresh", [True, False])
def test_no_rows_on_either_side(eventkit_fresh: bool):
    assert dedup.merge([], [icloud()], eventkit_fresh=eventkit_fresh) == []


@pytest.mark.parametrize(
    ("last_success", "expected"),
    [
        (NOW - timedelta(minutes=119), True),
        (NOW - timedelta(hours=2), False),
        (None, False),
    ],
)
def test_helper_freshness_is_under_two_hours(last_success, expected: bool):
    assert dedup.eventkit_is_fresh(last_success, NOW) is expected


@pytest.mark.parametrize(
    ("last_success", "expected"),
    [(None, False), (NOW - timedelta(minutes=59), True), (NOW - timedelta(hours=1), False)],
)
def test_server_freshness_is_under_one_hour(last_success, expected: bool):
    assert dedup.server_is_fresh(last_success, NOW) is expected
