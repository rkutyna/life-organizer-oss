"""Companies, applications, leads, status history, revert hooks, contacts, interviews, events,
goals, statuses and the pipeline, through the API. Every name is fictional."""

import datetime as dt

from sqlalchemy import select

from app import audit
from app.modules.jobs.models import Application, ApplicationStatusEvent
from app.timeutil import today_local


def company(client, name="Acme Corp", **extra):
    r = client.post("/api/jobs/companies", json={"name": name, **extra})
    assert r.status_code == 201, r.text
    return r.json()


def application(client, company_name="Acme Corp", title="Software Engineer", **extra):
    r = client.post(
        "/api/jobs/applications", json={"company": company_name, "title": title, **extra}
    )
    assert r.status_code == 201, r.text
    return r.json()


def lead(client, company_name="Acme Corp", title="Software Engineer", **extra):
    r = client.post("/api/jobs/leads", json={"company": company_name, "title": title, **extra})
    assert r.status_code == 201, r.text
    return r.json()


def history(client, application_id):
    r = client.get(f"/api/jobs/applications/{application_id}/status")
    return [e["status"] for e in r.json()]


# --------------------------------------------------------------------------- companies


def test_company_names_are_unique_ignoring_case_and_spacing(client):
    first = company(client, "Acme Corp", tags=["remote", " Remote ", ""])
    assert first["tags"] == ["remote"]
    r = client.post("/api/jobs/companies", json={"name": "acme   CORP"})
    assert r.status_code == 409
    r = client.post("/api/jobs/companies", json={"name": "acme corp", "reuse_existing": True})
    assert r.status_code == 201
    assert r.json()["id"] == first["id"] and r.json()["created"] is False
    other = company(client, "Example Labs")
    r = client.patch(f"/api/jobs/companies/{other['id']}", json={"name": "ACME corp"})
    assert r.status_code == 409


def test_company_delete_is_refused_while_it_has_records(client):
    created = application(client)
    r = client.delete(f"/api/jobs/companies/{created['company_id']}")
    assert r.status_code == 409
    client.delete(f"/api/jobs/applications/{created['id']}")
    assert client.delete(f"/api/jobs/companies/{created['company_id']}").status_code == 204


def test_company_list_counts_applications_leads_and_contacts(client):
    application(client, title="Engineer")
    lead(client, title="Designer")
    client.post("/api/jobs/contacts", json={"name": "Jane Doe", "company": "Acme Corp"})
    gone = client.post("/api/jobs/contacts", json={"name": "John Roe", "company": "Acme Corp"})
    client.delete(f"/api/jobs/contacts/{gone.json()['id']}")
    [row] = client.get("/api/jobs/companies").json()
    assert (row["applications"], row["leads"], row["contacts"]) == (1, 1, 1)


# --------------------------------------------------------------------------- applications


def test_create_application_names_a_new_company_and_writes_history(client):
    created = application(client, status="interview", date_applied="2026-11-02")
    assert created["company_created"] is True
    assert created["status"] == "interview"
    assert created["reached"] == "interview"
    assert history(client, created["id"]) == ["applied", "interview"]
    again = application(client, title="Other role")
    assert again["company_created"] is False and again["company_id"] == created["company_id"]


def test_unknown_or_lead_status_is_refused_on_create(client):
    r = client.post(
        "/api/jobs/applications", json={"company": "Acme", "title": "X", "status": "nope"}
    )
    assert r.status_code == 422
    r = client.post(
        "/api/jobs/applications", json={"company": "Acme", "title": "X", "status": "lead"}
    )
    assert r.status_code == 422


def test_status_follows_latest_event_and_back_dated_events_do_not_move_it(client):
    created = application(client, date_applied="2026-11-01")
    url = f"/api/jobs/applications/{created['id']}/status"
    r = client.post(url, json={"status": "screen", "on_date": "2026-11-05"})
    assert r.json()["status"] == "screen"
    r = client.post(url, json={"status": "rejected", "on_date": "2026-11-03", "note": "late"})
    assert r.json()["status"] == "screen"
    assert history(client, created["id"]) == ["applied", "rejected", "screen"]


def test_filters_by_status_company_tag_and_search(client):
    a = application(client, "Acme Corp", "Platform Engineer", tags=["remote"])
    application(client, "Globex", "Data Analyst")
    company_id = client.get("/api/jobs/companies", params={"q": "globex"}).json()[0]["id"]
    client.patch(f"/api/jobs/companies/{company_id}", json={"tags": ["Fintech"]})
    client.post(f"/api/jobs/applications/{a['id']}/status", json={"status": "screen"})
    lead(client, "Acme Corp", "Designer")

    def titles(**params):
        return sorted(
            r["title"] for r in client.get("/api/jobs/applications", params=params).json()
        )

    assert titles() == ["Data Analyst", "Platform Engineer"]
    assert titles(status="screen") == ["Platform Engineer"]
    assert titles(company_id=company_id) == ["Data Analyst"]
    assert titles(tag="REMOTE") == ["Platform Engineer"]
    assert titles(tag="fintech") == ["Data Analyst"]  # the company's tag counts
    assert titles(q="acme") == ["Platform Engineer"]
    assert titles(leads="only") == ["Designer"]
    assert len(titles(leads="include")) == 3


def test_delete_cascades_and_reverting_it_restores_the_children(client, session):
    created = application(client)
    client.post(f"/api/jobs/applications/{created['id']}/status", json={"status": "screen"})
    client.post(
        "/api/jobs/interviews",
        json={"application_id": created["id"], "on_date": "2026-11-20", "stage": "Screen"},
    )
    assert client.delete(f"/api/jobs/applications/{created['id']}").status_code == 204
    assert client.get("/api/jobs/interviews").json() == []

    delete = next(
        c for c in audit.history(session, "jobs_applications", created["id"]) if c.op == "delete"
    )
    r = client.post(f"/api/history/{delete.id}/revert")
    assert r.status_code == 200, r.text
    restored = client.get(f"/api/jobs/applications/{created['id']}").json()
    assert restored["status"] == "screen"
    assert history(client, created["id"]) == ["applied", "screen"]
    assert len(client.get("/api/jobs/interviews").json()) == 1


def test_reverting_a_status_event_rederives_the_status(client, session):
    created = application(client)
    client.post(f"/api/jobs/applications/{created['id']}/status", json={"status": "offer"})
    event = session.scalars(
        select(ApplicationStatusEvent).where(ApplicationStatusEvent.status == "offer")
    ).one()
    create_change = next(
        c
        for c in audit.history(session, "jobs_application_status_events", event.id)
        if c.op == "create"
    )
    r = client.post(f"/api/history/{create_change.id}/revert")
    assert r.status_code == 200, r.text
    assert client.get(f"/api/jobs/applications/{created['id']}").json()["status"] == "applied"


def test_reverting_an_application_create_removes_its_children(client, session):
    created = application(client)
    client.post("/api/jobs/interviews", json={"application_id": created["id"]})
    create_change = next(
        c for c in audit.history(session, "jobs_applications", created["id"]) if c.op == "create"
    )
    assert client.post(f"/api/history/{create_change.id}/revert").status_code == 200
    assert client.get("/api/jobs/interviews").json() == []
    live = session.scalars(select(ApplicationStatusEvent)).all()
    assert live == []


def test_status_event_edit_and_delete_keep_status_in_step(client):
    created = application(client, date_applied="2026-11-01")
    client.post(
        f"/api/jobs/applications/{created['id']}/status",
        json={"status": "screen", "on_date": "2026-11-04"},
    )
    events = client.get(f"/api/jobs/applications/{created['id']}/status").json()
    screen = events[-1]
    r = client.patch(f"/api/jobs/status-events/{screen['id']}", json={"status": "rejected"})
    assert r.status_code == 200
    assert client.get(f"/api/jobs/applications/{created['id']}").json()["status"] == "rejected"
    assert client.delete(f"/api/jobs/status-events/{screen['id']}").status_code == 204
    assert client.get(f"/api/jobs/applications/{created['id']}").json()["status"] == "applied"
    r = client.delete(f"/api/jobs/status-events/{events[0]['id']}")
    assert r.status_code == 409  # the last event stays
    r = client.patch(f"/api/jobs/status-events/{events[0]['id']}", json={"status": "lead"})
    assert r.status_code == 422


# --------------------------------------------------------------------------- leads


def test_lead_is_refused_twice_unless_forced(client):
    first = lead(client, title="Engineer, Platform")
    assert first["status"] == "lead" and first["date_applied"] is None
    r = client.post(
        "/api/jobs/leads", json={"company": "acme corp", "title": "engineer - platform"}
    )
    assert r.status_code == 409
    assert f"lead {first['id']}" in r.json()["detail"]
    forced = lead(client, title="Engineer - Platform", force=True)
    assert forced["id"] != first["id"]


def test_future_found_on_is_refused(client):
    tomorrow = (today_local() + dt.timedelta(days=1)).isoformat()
    r = client.post("/api/jobs/leads", json={"company": "Acme", "title": "X", "found_on": tomorrow})
    assert r.status_code == 422


def test_application_for_an_open_lead_promotes_it(client):
    found = (today_local() - dt.timedelta(days=3)).isoformat()
    open_lead = lead(client, title="Data Engineer", notes="Saw it on a board", found_on=found)
    created = application(client, "ACME corp", "data engineer", notes="Applied online")
    assert created["promoted_from_lead"] is True
    assert created["id"] == open_lead["id"]
    assert created["status"] == "applied"
    assert created["date_applied"] == today_local().isoformat()
    assert created["notes"] == "Saw it on a board\n\nApplied online"
    assert history(client, created["id"]) == ["lead", "applied"]
    assert client.get("/api/jobs/leads").json() == []


def test_several_matching_leads_are_not_guessed(client):
    a = lead(client, title="Analyst")
    b = lead(client, title="Analyst", force=True)
    created = application(client, title="Analyst")
    assert created["promoted_from_lead"] is False
    assert created["lead_candidates"] == [a["id"], b["id"]]


def test_apply_and_drop(client):
    found = (today_local() - dt.timedelta(days=2)).isoformat()
    one = lead(client, title="One", found_on=found)
    r = client.post(f"/api/jobs/applications/{one['id']}/apply", json={"status": "screen"})
    assert r.status_code == 200
    assert r.json()["status"] == "screen" and r.json()["reached"] == "screen"
    assert history(client, one["id"]) == ["lead", "applied", "screen"]
    r = client.post(f"/api/jobs/applications/{one['id']}/apply")
    assert r.status_code == 409

    early = (today_local() - dt.timedelta(days=5)).isoformat()
    two = lead(client, title="Two", found_on=found)
    r = client.post(f"/api/jobs/applications/{two['id']}/apply", json={"on_date": early})
    assert r.status_code == 422
    r = client.post(f"/api/jobs/applications/{two['id']}/drop", json={"reason": "Needs relocation"})
    assert r.json()["status"] == "dropped"
    assert "Needs relocation" in r.json()["notes"]
    assert [x["id"] for x in client.get("/api/jobs/leads").json()] == []
    dropped = client.get("/api/jobs/leads", params={"include_dropped": True}).json()
    assert [x["id"] for x in dropped] == [two["id"]]
    # A dropped lead does not block logging the posting again.
    lead(client, title="Two")


def test_status_change_on_a_lead_submits_it(client):
    open_lead = lead(client, title="Lead")
    r = client.post(
        f"/api/jobs/applications/{open_lead['id']}/status", json={"status": "interview"}
    )
    assert r.status_code == 201
    assert r.json()["date_applied"] == today_local().isoformat()
    assert history(client, open_lead["id"]) == ["lead", "applied", "interview"]


def test_lead_has_no_date_applied(client):
    open_lead = lead(client)
    r = client.patch(
        f"/api/jobs/applications/{open_lead['id']}", json={"date_applied": "2026-11-01"}
    )
    assert r.status_code == 422


# --------------------------------------------------------------------------- statuses


def test_statuses_default_then_materialize_on_first_edit(client, session):
    keys = [s["key"] for s in client.get("/api/jobs/statuses").json()]
    assert keys == [
        "lead",
        "applied",
        "screen",
        "interview",
        "offer",
        "rejected",
        "withdrawn",
        "ghosted",
        "dropped",
    ]
    r = client.post("/api/jobs/statuses", json={"label": "Take-home", "kind": "active"})
    assert r.status_code == 201
    assert r.json()["key"] == "take_home"
    keys = [s["key"] for s in client.get("/api/jobs/statuses").json()]
    assert keys.index("take_home") == keys.index("offer") + 1
    created = [c for c in audit.history(session, "jobs_statuses") if c.op == "create"]
    assert len(created) == 10
    assert {c.author for c in created} == {"system", "me"}


def test_status_rules(client):
    assert client.delete("/api/jobs/statuses/applied").status_code == 409
    r = client.patch("/api/jobs/statuses/lead", json={"kind": "active"})
    assert r.status_code == 422
    r = client.patch("/api/jobs/statuses/applied", json={"label": "Submitted"})
    assert r.json()["label"] == "Submitted"
    created = application(client)
    client.post(f"/api/jobs/applications/{created['id']}/status", json={"status": "ghosted"})
    assert client.delete("/api/jobs/statuses/ghosted").status_code == 409
    assert client.delete("/api/jobs/statuses/withdrawn").status_code == 204
    r = client.post(f"/api/jobs/applications/{created['id']}/status", json={"status": "withdrawn"})
    assert r.status_code == 422
    keys = [s["key"] for s in client.get("/api/jobs/statuses").json()]
    r = client.put("/api/jobs/statuses/order", json={"keys": list(reversed(keys))})
    assert [s["key"] for s in r.json()] == list(reversed(keys))
    r = client.put("/api/jobs/statuses/order", json={"keys": keys[:-1]})
    assert r.status_code == 422


def test_reached_follows_the_active_order(client):
    created = application(client, status="interview")
    client.put(
        "/api/jobs/statuses/order",
        json={
            "keys": [
                "lead",
                "applied",
                "interview",
                "screen",
                "offer",
                "rejected",
                "withdrawn",
                "ghosted",
                "dropped",
            ]
        },
    )
    client.post(f"/api/jobs/applications/{created['id']}/status", json={"status": "screen"})
    assert client.get(f"/api/jobs/applications/{created['id']}").json()["reached"] == "screen"


# --------------------------------------------------------------------------- pipeline


def test_pipeline_counts_current_status_reached_and_leads(client):
    a = application(client, title="A")
    application(client, title="B", status="screen")
    c = application(client, title="C")
    client.post(f"/api/jobs/applications/{a['id']}/status", json={"status": "interview"})
    client.post(f"/api/jobs/applications/{a['id']}/status", json={"status": "rejected"})
    client.post(f"/api/jobs/applications/{c['id']}/status", json={"status": "ghosted"})
    client.post("/api/jobs/interviews", json={"application_id": a["id"]})
    lead(client, title="D")
    dropped = lead(client, title="E")
    client.post(f"/api/jobs/applications/{dropped['id']}/drop", json={"reason": "no"})

    p = client.get("/api/jobs/pipeline").json()
    counts = {row["status"]: row["count"] for row in p["by_status"]}
    assert p["total"] == 3
    assert counts["rejected"] == 1 and counts["screen"] == 1 and counts["ghosted"] == 1
    assert counts["interview"] == 0
    reached = {row["status"]: row["count"] for row in p["reached"]}
    assert reached == {"applied": 3, "screen": 2, "interview": 1, "offer": 0}
    assert p["leads"] == {"open": 1, "dropped": 1}
    assert p["interviews"] == {"applications": 1, "records": 1}
    assert "rate" not in str(p)


def test_pipeline_takes_the_list_filters(client):
    application(client, "Acme Corp", "A", tags=["remote"])
    application(client, "Globex", "B")
    p = client.get("/api/jobs/pipeline", params={"tag": "remote"}).json()
    assert p["total"] == 1


# ------------------------------------------------------------- contacts, interviews, events


def test_contacts_crud_and_filters(client):
    r = client.post(
        "/api/jobs/contacts",
        json={
            "name": "Jane Doe",
            "company": "Example Labs",
            "role": "Recruiter",
            "next_action": "Follow up",
            "next_action_due": "2026-11-20",
        },
    )
    assert r.status_code == 201 and r.json()["company_created"] is True
    contact_id = r.json()["id"]
    client.post("/api/jobs/contacts", json={"name": "Pat Placeholder"})
    assert len(client.get("/api/jobs/contacts").json()) == 2
    assert len(client.get("/api/jobs/contacts", params={"due_by": "2026-11-21"}).json()) == 1
    assert len(client.get("/api/jobs/contacts", params={"q": "example labs"}).json()) == 1
    r = client.patch(
        f"/api/jobs/contacts/{contact_id}", json={"replied_on": "2026-11-18", "next_action": None}
    )
    assert r.json()["replied_on"] == "2026-11-18" and r.json()["next_action"] == ""


def test_interview_and_event_validation(client):
    created = application(client)
    r = client.post(
        "/api/jobs/interviews", json={"application_id": created["id"], "start_time": "10:00"}
    )
    assert r.status_code == 422
    r = client.post("/api/jobs/interviews", json={"application_id": 999})
    assert r.status_code == 422
    r = client.post(
        "/api/jobs/interviews",
        json={"application_id": created["id"], "on_date": "2026-11-20", "start_time": "10:00"},
    )
    assert r.json()["company"] == "Acme Corp"
    r = client.patch(f"/api/jobs/interviews/{r.json()['id']}", json={"on_date": None})
    assert r.status_code == 422
    r = client.post(
        "/api/jobs/events",
        json={"name": "Fair", "on_date": "2026-11-20", "start_time": "18:00", "end_time": "17:00"},
    )
    assert r.status_code == 422
    r = client.post("/api/jobs/events", json={"name": "Fair", "on_date": "2026-11-20"})
    assert r.status_code == 201
    listed = client.get("/api/jobs/events", params={"start": "2026-11-20", "end": "2026-11-20"})
    assert len(listed.json()) == 1


# --------------------------------------------------------------------------- goals


def test_goals_and_progress(client):
    r = client.post("/api/jobs/goals", json={"metric": "applications", "target": 5})
    assert r.status_code == 201
    assert (
        client.post("/api/jobs/goals", json={"metric": "applications", "target": 3}).status_code
        == 409
    )
    client.post("/api/jobs/goals", json={"metric": "outreach", "target": 2})
    today = today_local()
    application(client, title="This week", date_applied=today.isoformat())
    application(client, title="Last week", date_applied=(today - dt.timedelta(days=7)).isoformat())
    client.post("/api/jobs/contacts", json={"name": "Jane Doe", "contacted_on": today.isoformat()})
    p = client.get("/api/jobs/goals/progress").json()
    assert {g["metric"]: (g["actual"], g["target"]) for g in p["goals"]} == {
        "applications": (1, 5),
        "outreach": (1, 2),
    }
    assert dt.date.fromisoformat(p["week_start"]).weekday() == 0


# --------------------------------------------------------------------------- audit and tokens


def test_writes_are_audited_with_the_token_author(token_client, session):
    claude = token_client(["api"], author="claude")
    r = claude.post("/api/jobs/leads", json={"company": "Acme Corp", "title": "Engineer"})
    assert r.status_code == 201
    rows = audit.history(session, "jobs_applications", r.json()["id"])
    assert rows and {c.author for c in rows} == {"claude"}
    assert session.get(Application, r.json()["id"]).created_by == "claude"


def test_mail_token_cannot_reach_jobs(token_client):
    mail_only = token_client(["mail"])
    assert mail_only.get("/api/jobs/applications").status_code == 403


def test_tags_are_listed_once(client):
    company(client, "Acme Corp", tags=["Remote"])
    application(client, title="X", tags=["remote", "referral"])
    assert client.get("/api/jobs/tags").json() == {"tags": ["referral", "Remote"]}


def test_found_on_due_by_and_moving_an_interview(client):
    found = (today_local() - dt.timedelta(days=2)).isoformat()
    open_lead = lead(client, title="Lead", found_on=found)
    assert open_lead["found_on"] == found
    due = application(client, title="Due", next_action="Call", next_action_due="2026-11-18")
    application(client, title="Later", next_action_due="2026-12-30")
    listed = client.get("/api/jobs/applications", params={"due_by": "2026-11-20"}).json()
    assert [a["id"] for a in listed] == [due["id"]]
    interview = client.post("/api/jobs/interviews", json={"application_id": due["id"]}).json()
    r = client.patch(
        f"/api/jobs/interviews/{interview['id']}", json={"application_id": open_lead["id"]}
    )
    assert r.json()["application_title"] == "Lead"
    r = client.patch(f"/api/jobs/interviews/{interview['id']}", json={"application_id": 999})
    assert r.status_code == 422


def test_reverting_a_status_change_undoes_its_event(client, session):
    created = application(client)
    client.post(f"/api/jobs/applications/{created['id']}/status", json={"status": "interview"})
    change = next(
        c for c in audit.history(session, "jobs_applications", created["id"]) if c.field == "status"
    )
    r = client.post(f"/api/history/{change.id}/revert")
    assert r.status_code == 200, r.text
    assert client.get(f"/api/jobs/applications/{created['id']}").json()["status"] == "applied"
    assert history(client, created["id"]) == ["applied"]
