"""The tracker's calendar sources, and the demo seed."""

import datetime as dt

from sqlalchemy import select

from app import audit
from app.modules.jobs import demo
from app.modules.jobs.models import Company
from app.timeutil import today_local


def items(client, start="2026-11-16", end="2026-11-23"):
    r = client.get("/api/calendar", params={"start": start, "end": end})
    assert r.status_code == 200, r.text
    assert r.json()["errors"] == []
    return {i["id"]: i for i in r.json()["items"] if i["source"].startswith("jobs_")}


def test_interviews_events_and_due_dates_are_on_the_calendar(client):
    app = client.post(
        "/api/jobs/applications",
        json={
            "company": "Acme Corp",
            "title": "Engineer",
            "next_action": "Check portal",
            "next_action_due": "2026-11-19",
        },
    ).json()
    timed = client.post(
        "/api/jobs/interviews",
        json={
            "application_id": app["id"],
            "stage": "Onsite",
            "on_date": "2026-11-18",
            "start_time": "14:00",
            "duration_minutes": 90,
        },
    ).json()
    allday = client.post(
        "/api/jobs/interviews", json={"application_id": app["id"], "on_date": "2026-11-17"}
    ).json()
    client.post("/api/jobs/interviews", json={"application_id": app["id"]})  # unscheduled
    event = client.post(
        "/api/jobs/events",
        json={
            "name": "Career Fair",
            "on_date": "2026-11-20",
            "start_time": "17:00",
            "end_time": "19:30",
        },
    ).json()
    contact = client.post(
        "/api/jobs/contacts",
        json={"name": "Jane Doe", "next_action": "Thank-you note", "next_action_due": "2026-11-21"},
    ).json()

    found = items(client)
    assert len(found) == 5
    onsite = found[f"jobs_interviews:{timed['id']}"]
    assert onsite["title"] == "Onsite: Acme Corp"
    assert onsite["start"] == "2026-11-18T14:00:00-05:00"
    assert onsite["end"] == "2026-11-18T15:30:00-05:00"
    assert onsite["read_only"] is False
    assert onsite["meta"]["application_id"] == app["id"]
    day = found[f"jobs_interviews:{allday['id']}"]
    assert day["all_day"] is True and day["end"] == "2026-11-18"
    fair = found[f"jobs_events:{event['id']}"]
    assert fair["end"] == "2026-11-20T19:30:00-05:00"
    due = found[f"jobs_due:contact-{contact['id']}"]
    assert due["title"] == "Thank-you note: Jane Doe" and due["meta"]["kind"] == "contact"
    assert f"jobs_due:application-{app['id']}" in found

    client.delete(f"/api/jobs/applications/{app['id']}")
    assert len(items(client)) == 2  # the event and the contact's due date


def test_sources_are_listed_as_live(client):
    sources = {s["key"]: s for s in client.get("/api/calendar/sources").json()}
    for key in ("jobs_interviews", "jobs_events", "jobs_due"):
        assert sources[key]["live"] is True


def test_demo_seed(client, session):
    demo.seed(session)
    demo.seed(session)  # a second run adds nothing
    assert len(session.scalars(select(Company)).all()) == len(demo.COMPANIES)
    assert {c.author for c in audit.history(session, limit=1000)} == {"system"}
    p = client.get("/api/jobs/pipeline").json()
    assert p["total"] == len(demo.APPLICATIONS)
    assert p["leads"] == {"open": len(demo.LEADS), "dropped": len(demo.DROPPED)}
    statuses = {row["status"] for row in p["by_status"] if row["count"]}
    assert {"applied", "screen", "interview", "offer", "rejected", "ghosted"} <= statuses
    today = today_local()
    monday = today - dt.timedelta(days=today.weekday())
    week = items(client, monday.isoformat(), (monday + dt.timedelta(days=7)).isoformat())
    kinds = {i["source"] for i in week.values()}
    assert {"jobs_interviews", "jobs_events", "jobs_due"} <= kinds
    progress = client.get("/api/jobs/goals/progress").json()
    assert {g["metric"] for g in progress["goals"]} == {"applications", "outreach"}
