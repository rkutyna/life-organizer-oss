"""Regression tests for the tracker's records from a security and correctness review: a status
history that keeps agreeing with its application, status-list guards on History reverts,
lookalike company names, duplicate leads by rename and the REST text limits. Every name is
fictional."""

import datetime as dt

import pytest
from sqlalchemy import select

from app import audit
from app.modules.jobs.matching import fold_name, fold_title
from app.modules.jobs.models import JobStatus
from app.timeutil import today_local


def days_ago(n: int) -> str:
    # The app's configured time zone applies once the client fixture has started it.
    return (today_local() - dt.timedelta(days=n)).isoformat()


def application(client, company="Acme Corp", title="Software Engineer", **kw):
    r = client.post("/api/jobs/applications", json={"company": company, "title": title, **kw})
    assert r.status_code == 201, r.text
    return r.json()


def lead(client, company="Acme Corp", title="Software Engineer", **kw):
    r = client.post("/api/jobs/leads", json={"company": company, "title": title, **kw})
    assert r.status_code == 201, r.text
    return r.json()


def events(client, application_id):
    return client.get(f"/api/jobs/applications/{application_id}/status").json()


def get(client, application_id):
    return client.get(f"/api/jobs/applications/{application_id}")


def change(session, table, *, record_id=None, field=None, op=None):
    stmt = select(audit.ChangeLog).where(audit.ChangeLog.table_name == table)
    if record_id is not None:
        stmt = stmt.where(audit.ChangeLog.record_id == str(record_id))
    if field is not None:
        stmt = stmt.where(audit.ChangeLog.field == field)
    if op is not None:
        stmt = stmt.where(audit.ChangeLog.op == op)
    return session.scalars(stmt.order_by(audit.ChangeLog.id.desc())).first()


def revert(client, change_row):
    return client.post(f"/api/history/{change_row.id}/revert")


@pytest.mark.parametrize(
    "path,body",
    [
        ("/api/jobs/companies", {"name": "Big", "notes": "x" * 20_001}),
        ("/api/jobs/applications", {"company": "Acme", "title": "X", "notes": "x" * 20_001}),
        ("/api/jobs/leads", {"company": "Acme", "title": "X", "next_action": "x" * 20_001}),
        ("/api/jobs/contacts", {"name": "Jane Doe", "notes": "x" * 20_001}),
        ("/api/jobs/events", {"name": "Fair", "on_date": "2026-11-20", "notes": "x" * 20_001}),
    ],
)
def test_rest_caps_notes_and_next_actions(client, path, body):
    assert client.post(path, json=body).status_code == 422


def test_rest_caps_notes_on_update_and_status_notes(client):
    created = application(client)
    r = client.patch(f"/api/jobs/applications/{created['id']}", json={"notes": "x" * 20_001})
    assert r.status_code == 422
    r = client.post(
        f"/api/jobs/applications/{created['id']}/status",
        json={"status": "screen", "note": "x" * 20_001},
    )
    assert r.status_code == 422
    r = client.patch(f"/api/jobs/applications/{created['id']}", json={"notes": "x" * 20_000})
    assert r.status_code == 200


def submitted_lead(client):
    found = lead(client, found_on=days_ago(10))
    r = client.post(f"/api/jobs/applications/{found['id']}/apply", json={"on_date": days_ago(5)})
    assert r.json()["status"] == "applied"
    return found["id"]


def test_moving_the_lead_event_after_the_applied_one_is_refused(client):
    application_id = submitted_lead(client)
    lead_event = next(e for e in events(client, application_id) if e["status"] == "lead")
    r = client.patch(f"/api/jobs/status-events/{lead_event['id']}", json={"on_date": days_ago(0)})
    assert r.status_code == 409
    after = get(client, application_id).json()
    assert after["status"] == "applied" and after["date_applied"] == days_ago(5)
    # Moving it within the lead's own days is fine.
    r = client.patch(f"/api/jobs/status-events/{lead_event['id']}", json={"on_date": days_ago(6)})
    assert r.status_code == 200


def test_moving_the_applied_event_before_the_lead_is_refused(client):
    application_id = submitted_lead(client)
    applied = next(e for e in events(client, application_id) if e["status"] == "applied")
    r = client.patch(f"/api/jobs/status-events/{applied['id']}", json={"on_date": days_ago(20)})
    assert r.status_code == 409


def test_deleting_the_applied_event_of_a_former_lead_is_refused(client):
    application_id = submitted_lead(client)
    applied = next(e for e in events(client, application_id) if e["status"] == "applied")
    assert client.delete(f"/api/jobs/status-events/{applied['id']}").status_code == 409
    assert get(client, application_id).json()["status"] == "applied"


def test_deleting_the_dropped_event_is_refused(client):
    found = lead(client)
    client.post(f"/api/jobs/applications/{found['id']}/drop", json={"reason": "Too far"})
    dropped = next(e for e in events(client, found["id"]) if e["status"] == "dropped")
    assert client.delete(f"/api/jobs/status-events/{dropped['id']}").status_code == 409
    assert get(client, found["id"]).json()["status"] == "dropped"


def test_ordinary_history_edits_still_work(client):
    created = application(client, date_applied=days_ago(10))
    client.post(
        f"/api/jobs/applications/{created['id']}/status",
        json={"status": "screen", "on_date": days_ago(5)},
    )
    client.post(
        f"/api/jobs/applications/{created['id']}/status",
        json={"status": "interview", "on_date": days_ago(2)},
    )
    screen = next(e for e in events(client, created["id"]) if e["status"] == "screen")
    r = client.patch(f"/api/jobs/status-events/{screen['id']}", json={"on_date": days_ago(1)})
    assert r.status_code == 200
    assert get(client, created["id"]).json()["status"] == "screen"
    assert client.delete(f"/api/jobs/status-events/{screen['id']}").status_code == 204
    assert get(client, created["id"]).json()["status"] == "interview"
    last = events(client, created["id"])
    assert len(last) == 2
    applied = last[0]
    assert client.delete(f"/api/jobs/status-events/{applied['id']}").status_code == 204
    only = events(client, created["id"])[0]
    assert client.delete(f"/api/jobs/status-events/{only['id']}").status_code == 409


def test_reverting_an_applys_status_restores_its_date_applied(client, session):
    application_id = submitted_lead(client)
    r = revert(
        client, change(session, "jobs_applications", record_id=application_id, field="status")
    )
    assert r.status_code == 200, r.text
    after = get(client, application_id).json()
    assert after["status"] == "lead" and after["date_applied"] is None
    assert [e["status"] for e in events(client, application_id)] == ["lead"]


def test_reverting_an_applys_status_clears_a_date_edited_since(client, session):
    application_id = submitted_lead(client)
    status_change = change(session, "jobs_applications", record_id=application_id, field="status")
    client.patch(f"/api/jobs/applications/{application_id}", json={"date_applied": days_ago(4)})
    assert revert(client, status_change).status_code == 200
    after = get(client, application_id).json()
    assert after["status"] == "lead" and after["date_applied"] is None


def test_reverting_the_applied_event_alone_is_refused(client, session):
    application_id = submitted_lead(client)
    applied = next(e for e in events(client, application_id) if e["status"] == "applied")
    created = change(
        session, "jobs_application_status_events", record_id=applied["id"], op="create"
    )
    assert revert(client, created).status_code == 409
    assert get(client, application_id).json()["status"] == "applied"


def test_reverting_the_only_events_create_is_refused(client, session):
    created = application(client)
    [only] = events(client, created["id"])
    row = change(session, "jobs_application_status_events", record_id=only["id"], op="create")
    assert revert(client, row).status_code == 409
    assert len(events(client, created["id"])) == 1


def test_restoring_a_record_whose_status_was_removed_is_refused(client, session):
    created = application(client, status="screen")
    client.delete(f"/api/jobs/applications/{created['id']}")
    assert client.delete("/api/jobs/statuses/screen").status_code == 204
    deleted = change(session, "jobs_applications", record_id=created["id"], op="delete")
    r = revert(client, deleted)
    assert r.status_code == 409 and "screen" in r.json()["detail"]
    assert get(client, created["id"]).status_code == 404
    # With the status added back, the restore works.
    client.post("/api/jobs/statuses", json={"label": "Screen", "kind": "active", "key": "screen"})
    assert revert(client, deleted).status_code == 200
    assert get(client, created["id"]).json()["status"] == "screen"
    assert created["id"] in [a["id"] for a in client.get("/api/jobs/applications").json()]


def test_restoring_an_event_whose_status_was_removed_is_refused(client, session):
    created = application(client, status="screen")
    screen = next(e for e in events(client, created["id"]) if e["status"] == "screen")
    client.delete(f"/api/jobs/status-events/{screen['id']}")
    assert client.delete("/api/jobs/statuses/screen").status_code == 204
    deleted = change(session, "jobs_application_status_events", record_id=screen["id"], op="delete")
    assert revert(client, deleted).status_code == 409
    assert get(client, created["id"]).json()["status"] == "applied"


def test_history_cannot_revert_a_reserved_status_away(client, session):
    client.post("/api/jobs/statuses", json={"label": "Take-home", "kind": "active"})
    applied = session.scalars(select(JobStatus).where(JobStatus.key == "applied")).one()
    created = change(session, "jobs_statuses", record_id=applied.id, op="create")
    r = revert(client, created)
    assert r.status_code == 409 and "reserved" in r.json()["detail"]
    assert "applied" in [s["key"] for s in client.get("/api/jobs/statuses").json()]


def test_history_cannot_revert_a_status_in_use_away(client, session):
    client.post("/api/jobs/statuses", json={"label": "Take-home", "kind": "active"})
    created = change(session, "jobs_statuses", op="create")
    used = application(client, status="take_home")
    assert revert(client, created).status_code == 409
    assert "take_home" in [s["key"] for s in client.get("/api/jobs/statuses").json()]
    assert used["id"] in [a["id"] for a in client.get("/api/jobs/applications").json()]


def test_history_can_revert_an_unused_status(client, session):
    client.post("/api/jobs/statuses", json={"label": "Take-home", "kind": "active"})
    assert revert(client, change(session, "jobs_statuses", op="create")).status_code == 200
    assert "take_home" not in [s["key"] for s in client.get("/api/jobs/statuses").json()]


def test_restoring_a_status_whose_key_was_reused_is_a_409(client, session):
    client.post("/api/jobs/statuses", json={"label": "Take-home", "kind": "active"})
    client.delete("/api/jobs/statuses/take_home")
    client.post("/api/jobs/statuses", json={"label": "Take home", "kind": "closed"})
    deleted = change(session, "jobs_statuses", op="delete")
    assert revert(client, deleted).status_code == 409


def test_a_blank_status_label_is_refused(client):
    assert client.patch("/api/jobs/statuses/screen", json={"label": "   "}).status_code == 422
    r = client.post("/api/jobs/statuses", json={"label": "  ", "kind": "active"})
    assert r.status_code == 422
    labels = {s["key"]: s["label"] for s in client.get("/api/jobs/statuses").json()}
    assert labels["screen"] == "Screen"


def test_fold_name_normalizes_lookalikes():
    assert fold_name("Café Nova") == fold_name("Café Nova")
    assert fold_name("Ａcme") == fold_name("Acme")
    assert fold_name("Acme​") == fold_name("Acme") == fold_name("﻿A‍cme")
    assert fold_name("Acme Corp") == fold_name("acme corp")
    assert fold_title("Engineer， Platform") == fold_title("Engineer - Platform")


def test_lookalike_company_names_are_one_company(client):
    assert client.post("/api/jobs/companies", json={"name": "Café Nova"}).status_code == 201
    assert client.post("/api/jobs/companies", json={"name": "Café Nova"}).status_code == 409
    assert client.post("/api/jobs/companies", json={"name": "Acme"}).status_code == 201
    assert client.post("/api/jobs/companies", json={"name": "Ａcme"}).status_code == 409
    assert client.post("/api/jobs/companies", json={"name": "Acme​"}).status_code == 409


def test_restoring_a_company_whose_name_was_taken_since_is_refused(client, session):
    c = client.post("/api/jobs/companies", json={"name": "Acme Corp"}).json()
    client.delete(f"/api/jobs/companies/{c['id']}")
    assert client.post("/api/jobs/companies", json={"name": "acme corp"}).status_code == 201
    r = revert(client, change(session, "jobs_companies", record_id=c["id"], op="delete"))
    assert r.status_code == 409
    assert [x["name"] for x in client.get("/api/jobs/companies").json()] == ["acme corp"]


def test_restoring_a_company_whose_exact_name_was_taken_is_a_409(client, session):
    c = client.post("/api/jobs/companies", json={"name": "Acme Corp"}).json()
    client.delete(f"/api/jobs/companies/{c['id']}")
    client.post("/api/jobs/companies", json={"name": "Acme Corp"})
    r = revert(client, change(session, "jobs_companies", record_id=c["id"], op="delete"))
    assert r.status_code == 409


def test_reverting_a_rename_into_a_taken_name_is_refused(client, session):
    c = client.post("/api/jobs/companies", json={"name": "Globex"}).json()
    client.patch(f"/api/jobs/companies/{c['id']}", json={"name": "Initech"})
    client.post("/api/jobs/companies", json={"name": "GLOBEX"})
    r = revert(client, change(session, "jobs_companies", record_id=c["id"], field="name"))
    assert r.status_code == 409


def test_renaming_a_lead_onto_a_tracked_posting_is_refused_unless_forced(client):
    taken = lead(client, title="Data Engineer")
    other = lead(client, title="Data Analyst")
    r = client.patch(f"/api/jobs/applications/{other['id']}", json={"title": "data  engineer"})
    assert r.status_code == 409 and str(taken["id"]) in r.json()["detail"]
    r = client.patch(
        f"/api/jobs/applications/{other['id']}", json={"title": "Data Engineer", "force": True}
    )
    assert r.status_code == 200 and r.json()["title"] == "Data Engineer"


def test_moving_a_lead_to_a_company_tracking_the_title_is_refused(client):
    tracked = application(client, company="Globex", title="Data Engineer")
    moving = lead(client, company="Acme Corp", title="Data Engineer")
    r = client.patch(
        f"/api/jobs/applications/{moving['id']}", json={"company_id": tracked["company_id"]}
    )
    assert r.status_code == 409


def test_renaming_a_lead_to_its_own_title_or_past_a_dropped_one_is_fine(client):
    dropped = lead(client, title="Data Engineer")
    client.post(f"/api/jobs/applications/{dropped['id']}/drop", json={"reason": "Closed"})
    other = lead(client, title="Data Analyst")
    r = client.patch(f"/api/jobs/applications/{other['id']}", json={"title": "Data Analyst"})
    assert r.status_code == 200
    r = client.patch(f"/api/jobs/applications/{other['id']}", json={"title": "Data Engineer"})
    assert r.status_code == 200


def test_a_status_change_dated_before_the_lead_was_found_is_refused(client):
    application_id = submitted_lead(client)
    r = client.post(
        f"/api/jobs/applications/{application_id}/status",
        json={"status": "screen", "on_date": days_ago(20)},
    )
    assert r.status_code == 409
    r = client.post(
        f"/api/jobs/applications/{application_id}/status",
        json={"status": "screen", "on_date": days_ago(7)},
    )
    assert r.status_code == 201  # before the latest event, after the lead: recorded
