"""The reminders toolset: list resolution by name or id, the trimmed shapes, the bodies sent,
clear, and the api token on every call. The organizer is a FakeOrganizer."""

from __future__ import annotations

import datetime as dt

import pytest
from support import API_TOKEN, FakeOrganizer, query, sent_json

from organizer_mcp.client import OrganizerError
from organizer_mcp.tools import reminders as tools

LISTS = [
    {
        "id": "L-home",
        "title": "Home",
        "color": "#FF9500",
        "source": "apple",
        "account_id": None,
        "account": "iCloud",
        "account_type": "caldav",
        "writable": True,
        "is_default": True,
        "supports_time": True,
        "supports_priority": True,
        "open_count": 2,
    },
    {
        "id": "g-errands",
        "title": "Errands",
        "color": "#1A73E8",
        "source": "google",
        "account_id": 3,
        "account": "someone@example.com",
        "account_type": "google",
        "writable": True,
        "is_default": True,
        "supports_time": False,
        "supports_priority": False,
        "open_count": 1,
    },
    {
        "id": "L-errands",
        "title": "errands",
        "color": None,
        "source": "apple",
        "account_id": None,
        "account": "iCloud",
        "account_type": "caldav",
        "writable": True,
        "is_default": False,
        "supports_time": True,
        "supports_priority": True,
        "open_count": 0,
    },
]


def reminder(**changes: object) -> dict:
    row = {
        "id": 7,
        "source": "apple",
        "account_id": None,
        "external_id": "ext-7",
        "list_id": "L-home",
        "list_title": "Home",
        "list_color": "#FF9500",
        "title": "Water the plants",
        "notes": "",
        "due_date": "2026-11-20",
        "due_time": "09:30:00",
        "priority": None,
        "completed": False,
        "completed_at": None,
        "url": None,
        "modified_at": None,
        "mirrored_at": "2026-11-16T10:00:00Z",
        "in_provider": True,
        "sync": {
            "state": "syncing",
            "pending_fields": ["completed"],
            "pending_ops": [],
            "waiting_since": None,
            "error": None,
        },
    }
    row.update(changes)
    return row


def test_reminders_are_trimmed_and_filtered_by_list_name(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/reminders/lists", LISTS)
    organizer.reply("GET", "/api/reminders", [reminder()])
    [item] = tools.reminders(list="HOME", include_completed=True)
    assert item == {
        "id": 7,
        "title": "Water the plants",
        "notes": "",
        "list": "Home",
        "list_id": "L-home",
        "provider": "apple",
        "due_date": "2026-11-20",
        "due_time": "09:30",
        "priority": None,
        "completed": False,
        "sync": "syncing",
        "pending": ["completed"],
        "error": None,
    }
    request = organizer.only("GET", "/api/reminders")
    assert query(request) == {"list": ["L-home"], "include_completed": ["true"]}
    assert request.headers["authorization"] == f"Bearer {API_TOKEN}"


def test_an_ambiguous_or_unknown_list_name_is_an_error(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/reminders/lists", LISTS)
    with pytest.raises(OrganizerError, match="ambiguous: Errands .*errands .*pass the list id"):
        tools.reminders(list="Errands")
    with pytest.raises(OrganizerError, match="no reminders list named 'Chores'"):
        tools.reminders(list="Chores")
    organizer.reply("GET", "/api/reminders", [])
    assert tools.reminders(list="g-errands") == []  # an exact id always wins


def test_reminder_lists(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/reminders/lists", LISTS)
    google = tools.reminder_lists()[1]
    assert google == {
        "provider": "google",
        "id": "g-errands",
        "title": "Errands",
        "account": "someone@example.com",
        "writable": True,
        "is_default": True,
        "supports_time": False,
        "supports_priority": False,
        "open_count": 1,
    }


def test_add_reminder_sends_only_what_was_given(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/reminders/lists", LISTS)
    organizer.reply("POST", "/api/reminders", reminder(), status=201)
    tools.add_reminder(
        "Water the plants", list="home", due_date=dt.date(2026, 11, 20), due_time=dt.time(9, 30)
    )
    assert sent_json(organizer.only("POST", "/api/reminders")) == {
        "title": "Water the plants",
        "list_id": "L-home",
        "due_date": "2026-11-20",
        "due_time": "09:30:00",
    }


def test_a_refusal_reaches_claude_as_its_message(organizer: FakeOrganizer) -> None:
    organizer.reply(
        "POST",
        "/api/reminders",
        {"detail": "Google Tasks keeps a due date but no time; send the date without due_time"},
        status=422,
    )
    with pytest.raises(OrganizerError, match="no time"):
        tools.add_reminder("Call", due_date=dt.date(2026, 11, 20), due_time=dt.time(9, 0))


def test_complete_and_uncomplete(organizer: FakeOrganizer) -> None:
    organizer.reply("POST", "/api/reminders/7/complete", reminder(completed=True))
    organizer.reply("POST", "/api/reminders/7/uncomplete", reminder())
    assert tools.complete_reminder(7)["completed"] is True
    assert tools.complete_reminder(7, completed=False)["completed"] is False
    assert sent_json(organizer.only("POST", "/api/reminders/7/complete")) is None


def test_update_reminder_sets_and_clears(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/reminders/lists", LISTS)
    organizer.reply("PATCH", "/api/reminders/7", reminder())
    tools.update_reminder(7, title="Water the ferns", list="L-errands", clear=["due_date"])
    assert sent_json(organizer.only("PATCH", "/api/reminders/7")) == {
        "title": "Water the ferns",
        "list_id": "L-errands",
        "due_date": None,
    }


def test_update_reminder_refuses_nothing_and_set_plus_clear(organizer: FakeOrganizer) -> None:
    with pytest.raises(OrganizerError, match="nothing to change"):
        tools.update_reminder(7)
    with pytest.raises(OrganizerError, match="priority is both set and cleared"):
        tools.update_reminder(7, priority=1, clear=["priority"])
    assert organizer.requests == []
