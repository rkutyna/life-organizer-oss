"""The jobs toolset: the requests each tool sends, the trimmed answers, company lookup by name,
clear lists, and the guards that stop a confusing call before it reaches the organizer. Every
name is fictional."""

from __future__ import annotations

import asyncio
import datetime as dt

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from support import API_TOKEN, FakeOrganizer, query, sent_json

from organizer_mcp import server
from organizer_mcp.client import OrganizerError
from organizer_mcp.tools import jobs

APP = {
    "id": 7,
    "company_id": 3,
    "company": "Acme Corp",
    "title": "Software Engineer",
    "status": "applied",
    "reached": "applied",
    "date_applied": "2026-11-10",
    "found_on": None,
    "location": "",
    "posting_url": "",
    "source": "",
    "next_action": "",
    "next_action_due": None,
    "tags": [],
    "notes": "",
    "extra": {"Salary": "x"},
    "created_at": "2026-11-10T12:00:00Z",
    "created_by": "claude",
    "updated_at": "2026-11-10T12:00:00Z",
}
COMPANIES = [
    {
        "id": 3,
        "name": "Acme Corp",
        "website": "",
        "target": True,
        "tags": [],
        "notes": "Old",
        "applications": 1,
        "leads": 0,
        "contacts": 2,
    },
    {
        "id": 4,
        "name": "Acme Corporation",
        "website": "",
        "target": False,
        "tags": [],
        "notes": "",
        "applications": 0,
        "leads": 0,
        "contacts": 0,
    },
]


def test_applications_filters_and_trims(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/jobs/companies", COMPANIES)
    organizer.reply("GET", "/api/jobs/applications", [APP])
    rows = jobs.applications(
        status=["screen", "interview"],
        company="acme  corp",
        since=dt.date(2026, 11, 1),
        include_leads=True,
    )
    assert rows == [{name: APP[name] for name in jobs.APPLICATION_FIELDS}]
    request = organizer.only("GET", "/api/jobs/applications")
    assert query(request) == {
        "status": ["screen", "interview"],
        "company_id": ["3"],
        "applied_from": ["2026-11-01"],
        "leads": ["include"],
    }
    assert request.headers["authorization"] == f"Bearer {API_TOKEN}"


def test_unknown_company_name_is_a_clear_error(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/jobs/companies", COMPANIES)
    with pytest.raises(OrganizerError, match="no company named 'Globex'"):
        jobs.contacts(company="Globex")


def test_add_application_sends_the_company_name_and_reports_promotion(
    organizer: FakeOrganizer,
) -> None:
    organizer.reply(
        "POST",
        "/api/jobs/applications",
        {**APP, "company_created": False, "promoted_from_lead": True, "lead_candidates": []},
        201,
    )
    out = jobs.add_application("Acme Corp", "Software Engineer", date_applied=dt.date(2026, 11, 10))
    assert sent_json(organizer.only("POST", "/api/jobs/applications")) == {
        "company": "Acme Corp",
        "title": "Software Engineer",
        "date_applied": "2026-11-10",
    }
    assert out["promoted_from_lead"] is True and out["lead_candidates"] == []
    assert "extra" not in out


def test_add_lead_sends_force_only_when_set(organizer: FakeOrganizer) -> None:
    organizer.reply("POST", "/api/jobs/leads", {**APP, "status": "lead"}, 201)
    jobs.add_lead("Acme Corp", "Designer")
    jobs.add_lead("Acme Corp", "Designer", force=True)
    first, second = organizer.sent("POST", "/api/jobs/leads")
    assert "force" not in sent_json(first)
    assert sent_json(second)["force"] is True


def test_lead_conflict_reaches_claude_with_the_server_message(organizer: FakeOrganizer) -> None:
    detail = "lead 5 at this company already has this title; force=true logs a new lead anyway"
    organizer.reply("POST", "/api/jobs/leads", {"detail": detail}, 409)
    with pytest.raises(ToolError, match="lead 5 at this company"):
        asyncio.run(server.app.call_tool("add_lead", {"company": "Acme", "title": "Designer"}))


def test_status_apply_and_drop_routes(organizer: FakeOrganizer) -> None:
    organizer.reply("POST", "/api/jobs/applications/7/status", APP, 201)
    organizer.reply("POST", "/api/jobs/applications/7/apply", APP)
    organizer.reply("POST", "/api/jobs/applications/7/drop", {**APP, "status": "dropped"})
    jobs.set_application_status(7, "screen", on_date=dt.date(2026, 11, 12))
    jobs.mark_applied(7)
    jobs.drop_lead(7, "Needs relocation")
    assert sent_json(organizer.only("POST", "/api/jobs/applications/7/status")) == {
        "status": "screen",
        "on_date": "2026-11-12",
    }
    assert sent_json(organizer.only("POST", "/api/jobs/applications/7/apply")) is None
    assert sent_json(organizer.only("POST", "/api/jobs/applications/7/drop")) == {
        "reason": "Needs relocation"
    }


def test_update_contact_clear_and_guards(organizer: FakeOrganizer) -> None:
    organizer.reply("PATCH", "/api/jobs/contacts/2", {"id": 2, "name": "Jane Doe"})
    jobs.update_contact(
        2, replied_on=dt.date(2026, 11, 12), clear=["next_action", "next_action_due"]
    )
    assert sent_json(organizer.only("PATCH", "/api/jobs/contacts/2")) == {
        "replied_on": "2026-11-12",
        "next_action": "",
        "next_action_due": None,
    }
    with pytest.raises(OrganizerError, match="both set and listed in clear"):
        jobs.update_contact(2, next_action="Call", clear=["next_action"])
    with pytest.raises(OrganizerError, match="nothing to change"):
        jobs.update_contact(2)


def test_update_company_by_name_appends_a_note(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/jobs/companies", COMPANIES)
    organizer.reply("GET", "/api/jobs/companies/3", COMPANIES[0])
    organizer.reply("PATCH", "/api/jobs/companies/3", {**COMPANIES[0], "notes": "Old\n\nNew"})
    out = jobs.update_company("ACME corp", add_note=" New ", target=False)
    assert sent_json(organizer.only("PATCH", "/api/jobs/companies/3")) == {
        "target": False,
        "notes": "Old\n\nNew",
    }
    assert out["notes"] == "Old\n\nNew" and "applications" not in out
    with pytest.raises(OrganizerError, match="not both"):
        jobs.update_company("3", notes="x", add_note="y")


def test_interview_times_are_sent_as_wall_clock(organizer: FakeOrganizer) -> None:
    organizer.reply("POST", "/api/jobs/interviews", {"id": 1, "application_id": 7}, 201)
    organizer.reply("PATCH", "/api/jobs/interviews/1", {"id": 1})
    jobs.add_interview(7, stage="Onsite", on_date=dt.date(2026, 11, 20), start_time=dt.time(14, 0))
    assert sent_json(organizer.only("POST", "/api/jobs/interviews")) == {
        "application_id": 7,
        "stage": "Onsite",
        "on_date": "2026-11-20",
        "start_time": "14:00",
    }
    jobs.update_interview(1, clear=["start_time"])
    assert sent_json(organizer.only("PATCH", "/api/jobs/interviews/1")) == {"start_time": None}


def test_events(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/jobs/events", [])
    organizer.reply("POST", "/api/jobs/events", {"id": 1, "name": "Fair"}, 201)
    organizer.reply("PATCH", "/api/jobs/events/1", {"id": 1, "attended": True})
    jobs.job_events(since=dt.date(2026, 11, 1))
    assert query(organizer.only("GET", "/api/jobs/events")) == {"start": ["2026-11-01"]}
    jobs.add_job_event("Fair", dt.date(2026, 11, 20), start_time=dt.time(17, 30))
    assert sent_json(organizer.only("POST", "/api/jobs/events"))["start_time"] == "17:30"
    jobs.update_job_event(1, attended=True)
    assert sent_json(organizer.only("PATCH", "/api/jobs/events/1")) == {"attended": True}


def test_set_weekly_goal_creates_updates_and_removes(organizer: FakeOrganizer) -> None:
    goals: list[dict] = []
    organizer.reply("GET", "/api/jobs/goals", lambda request: goals)
    organizer.reply("POST", "/api/jobs/goals", {"id": 1, "metric": "outreach", "target": 3}, 201)
    assert jobs.set_weekly_goal("outreach", 3) == {"metric": "outreach", "target": 3}
    goals.append({"id": 1, "metric": "outreach", "target": 3})
    organizer.reply("PATCH", "/api/jobs/goals/1", {"id": 1, "metric": "outreach", "target": 5})
    assert jobs.set_weekly_goal("outreach", 5)["target"] == 5
    organizer.reply("DELETE", "/api/jobs/goals/1", None, 204)
    assert jobs.set_weekly_goal("outreach", None) == {"metric": "outreach", "target": None}
    assert len(organizer.sent("DELETE", "/api/jobs/goals/1")) == 1


def test_pipeline_statuses_and_goals_pass_through(organizer: FakeOrganizer) -> None:
    organizer.reply("GET", "/api/jobs/pipeline", {"total": 3})
    organizer.reply(
        "GET",
        "/api/jobs/statuses",
        [{"key": "lead", "label": "Lead", "kind": "lead", "position": 0, "reserved": True}],
    )
    organizer.reply("GET", "/api/jobs/goals/progress", {"goals": []})
    assert jobs.pipeline(tag="remote") == {"total": 3}
    assert query(organizer.only("GET", "/api/jobs/pipeline")) == {"tag": ["remote"]}
    assert jobs.job_statuses() == [{"key": "lead", "label": "Lead", "kind": "lead"}]
    assert jobs.weekly_goals() == {"goals": []}


def test_reads_are_read_only_and_writes_are_not() -> None:
    tools = {tool.name: tool for tool in asyncio.run(server.app.list_tools())}
    for name in jobs.READS:
        assert tools[name].annotations.readOnlyHint is True, name
    for name in jobs.WRITES:
        assert tools[name].annotations.readOnlyHint is False, name
        assert tools[name].annotations.destructiveHint is False, name


def test_docstrings_offer_no_drafts_and_no_rates() -> None:
    for name in jobs.TOOLS:
        doc = getattr(jobs, name).__doc__ or ""
        assert "draft" not in doc.lower()
        assert "%" not in doc
