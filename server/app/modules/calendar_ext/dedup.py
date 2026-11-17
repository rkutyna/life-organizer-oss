"""Merge the Mac helper's copies of events with the server's own copies of the same account.

A calendar account can reach the organizer twice: through the Mac helper (EventKit reads every
account the Mac's Calendar app has) and directly, as a connected account the server polls
(CalDAV or Google). Pure functions only: the calendar provider loads the rows, works out each
stream's freshness and calls `merge`.

A helper row belongs to a connected account when its EventKit account name matches the
account's name ("iCloud" for the iCloud preset, the address for Google, the label for any other
CalDAV account; matched ignoring case) and its EventKit account type is CalDAV-based. A copy is
identified by (calendar title, account name, event UID, occurrence start).

The rule, per connected account and the helper rows that belong to it:
- Helper fresher than 2 hours: helper rows win for every key they cover, and the server's rows
  fill only the keys the helper lacks.
- Helper stale, server fresh (synced within the last hour): the server's rows win, and the
  helper's rows for that account are dropped.
- Both stale: nothing is hidden. The server's rows win for the keys they cover and the helper's
  rows fill the rest. A stale copy is better than an empty calendar; the freshness strip says
  how old it is.

Helper rows that belong to no connected account (a local calendar, an Exchange account, an
account not connected here) are always shown.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Generic, Protocol, TypeVar

EVENTKIT_FRESH_FOR = timedelta(hours=2)
SERVER_FRESH_FOR = timedelta(hours=1)
# EventKit source types the server can also read directly (iCloud reports "caldav" or
# "mobileme"; Google and other CalDAV accounts report "caldav").
MATCHABLE_ACCOUNT_TYPES = frozenset({"caldav", "mobileme"})


class Occurrence(Protocol):
    """What dedup reads from a row. ExternalEvent satisfies it; so do test doubles."""

    uid: str
    calendar_title: str
    account: str
    account_type: str | None
    occurrence_start: datetime


T = TypeVar("T", bound=Occurrence)


@dataclass(frozen=True)
class ServerAccount(Generic[T]):
    """One connected account's rows, under the name the Mac would show for it."""

    name: str
    rows: Sequence[T]
    fresh: bool


def account_key(name: str) -> str:
    return name.strip().casefold()


def occurrence_key(row: Occurrence) -> tuple[str, str, str, datetime]:
    """(calendar title, account, UID, occurrence start). Two copies match only on all four."""
    return (row.calendar_title, account_key(row.account), row.uid, row.occurrence_start)


def eventkit_is_fresh(last_success_at: datetime | None, now: datetime) -> bool:
    """True when the helper's last successful push is less than 2 hours old."""
    return last_success_at is not None and now - last_success_at < EVENTKIT_FRESH_FOR


def server_is_fresh(last_success_at: datetime | None, now: datetime) -> bool:
    """True when an account's last successful poll is less than 1 hour old."""
    return last_success_at is not None and now - last_success_at < SERVER_FRESH_FOR


def merge_account(
    eventkit: Sequence[T],
    server: Sequence[T],
    *,
    eventkit_fresh: bool,
    server_fresh: bool,
) -> list[T]:
    """One account's rows from both streams, per the rule in the module docstring."""
    if eventkit_fresh:
        covered = {occurrence_key(row) for row in eventkit}
        return [*eventkit, *(row for row in server if occurrence_key(row) not in covered)]
    if server_fresh:
        return list(server)
    covered = {occurrence_key(row) for row in server}
    return [*server, *(row for row in eventkit if occurrence_key(row) not in covered)]


def merge(
    eventkit: Sequence[T],
    servers: Sequence[ServerAccount[T]],
    *,
    eventkit_fresh: bool,
) -> list[T]:
    """Every row to show, deduplicated account by account.

    Connected accounts that share a name (two accounts both called "iCloud") are treated as
    one, fresh only when all of them are.
    """
    groups: dict[str, tuple[list[T], bool]] = {}
    for server in servers:
        rows, fresh = groups.get(account_key(server.name), ([], True))
        groups[account_key(server.name)] = ([*rows, *server.rows], fresh and server.fresh)

    helper_rows: dict[str, list[T]] = {key: [] for key in groups}
    unmatched: list[T] = []
    for row in eventkit:
        key = account_key(row.account)
        if key in groups and row.account_type in MATCHABLE_ACCOUNT_TYPES:
            helper_rows[key].append(row)
        else:
            unmatched.append(row)

    merged: list[T] = []
    for key, (rows, fresh) in groups.items():
        merged.extend(
            merge_account(helper_rows[key], rows, eventkit_fresh=eventkit_fresh, server_fresh=fresh)
        )
    return [*merged, *unmatched]
