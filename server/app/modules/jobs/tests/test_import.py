"""The CSV import: suggested mapping, status values, dry run, commit, idempotency, lead
promotion, problems reported without cell text, contacts, and undo. The CSVs are synthetic."""

import datetime as dt

import pytest
from sqlalchemy import select

from app import audit
from app.modules.jobs.importer import parse_date, suggest_mapping
from app.modules.jobs.models import Application

SHEET = """﻿Company,Position,Status,Date Applied,Link,Notes,Salary
Acme Corp,Software Engineer,Applied,11/02/2026,https://example.com/1,Via the site,100k
Example Labs,Research Engineer,Phone Screen,2026-10-28,,,
acme corp,Data Engineer,Rejected,Oct 20 2026,,Secret note text,
Globex,Analyst,Wishlist,,,,
Initech,Platform Engineer,Mystery value,11/01/2026,,,
,No company row,Applied,11/01/2026,,,
Acme Corp,Software Engineer,Applied,11/02/2026,,duplicate,
Initech,QA Engineer,Applied,31/10/2026,,,
"""

MAPPING = {
    "Company": "company",
    "Position": "title",
    "Status": "status",
    "Date Applied": "date_applied",
    "Link": "posting_url",
    "Notes": "notes",
    "Salary": None,
}


def spec(**extra):
    return {"csv": SHEET, "kind": "applications", "mapping": MAPPING, **extra}


def test_parse_date_spellings():
    assert parse_date("2026-11-05") == dt.date(2026, 11, 5)
    assert parse_date("2026-11-05T10:00:00") == dt.date(2026, 11, 5)
    assert parse_date("11/5/2026") == dt.date(2026, 11, 5)
    assert parse_date("11/5/26") == dt.date(2026, 11, 5)
    assert parse_date("5/11/2026", day_first=True) == dt.date(2026, 11, 5)
    assert parse_date("Nov 5, 2026") == dt.date(2026, 11, 5)
    assert parse_date("5 November 2026") == dt.date(2026, 11, 5)
    assert parse_date("2026/11/05") == dt.date(2026, 11, 5)
    assert parse_date("46331") == dt.date(2026, 11, 5)
    assert parse_date("31/31/2026") is None
    assert parse_date("soon") is None


def test_suggested_mapping():
    headers = ["Company Name", "Job Title", "Stage", "Applied On", "URL", "Follow-up date", "X"]
    assert suggest_mapping(headers, "applications") == {
        "Company Name": "company",
        "Job Title": "title",
        "Stage": "status",
        "Applied On": "date_applied",
        "URL": "posting_url",
        "Follow-up date": "next_action_due",
        "X": None,
    }


def test_preview_suggests_mapping_and_status_values(client):
    r = client.post("/api/jobs/import/preview", json={"csv": SHEET})
    assert r.status_code == 200, r.text
    p = r.json()
    assert p["headers"][0] == "Company"  # the byte-order mark is gone
    assert p["row_count"] == 8
    assert p["mapping"]["Company"] == "company" and p["mapping"]["Position"] == "title"
    values = {v["value"]: v["suggested"] for v in p["status_values"]}
    assert values == {
        "Applied": "applied",
        "Phone Screen": "screen",
        "Rejected": "rejected",
        "Wishlist": "lead",
        "Mystery value": None,
    }
    assert p["day_first_suggested"] is True  # 31/10 only reads day-first


def test_dry_run_reports_counts_and_codes_without_cell_text(client):
    r = client.post("/api/jobs/import/dry-run", json=spec())
    assert r.status_code == 200, r.text
    report = r.json()
    assert report["committed"] is False and report["batch_id"] is None
    assert (report["rows"], report["create"], report["skipped"]) == (8, 5, 3)
    assert report["companies_created"] == 4
    codes = {(p["row"], p["code"]) for p in report["problems"]}
    assert codes == {
        (6, "unknown_status"),
        (7, "missing_company"),
        (8, "duplicate_row"),
        (9, "bad_date"),
    }
    text = r.text
    for secret in ("Secret note text", "Mystery value", "example.com", "Acme"):
        assert secret not in text
    assert client.get("/api/jobs/applications", params={"leads": "include"}).json() == []


def test_commit_writes_as_system_in_one_batch_and_is_idempotent(client, session):
    status_map = {"Mystery value": "screen"}
    report = client.post("/api/jobs/import/commit", json=spec(status_map=status_map)).json()
    assert report["committed"] is True and report["create"] == 6
    batch = audit.batch_changes(session, report["batch_id"])
    assert batch and {c.author for c in batch} == {"system"}

    apps = client.get("/api/jobs/applications", params={"leads": "include"}).json()
    by_title = {a["title"]: a for a in apps}
    assert by_title["Software Engineer"]["extra"] == {"Salary": "100k"}
    assert by_title["Research Engineer"]["status"] == "screen"
    assert by_title["Research Engineer"]["reached"] == "screen"
    assert by_title["Analyst"]["status"] == "lead"
    assert by_title["Analyst"]["date_applied"] is None
    assert by_title["QA Engineer"]["date_applied"] is None  # bad date: the field is left out
    assert by_title["Data Engineer"]["company"] == "Acme Corp"  # folded to one company
    assert len(client.get("/api/jobs/companies").json()) == 4

    again = client.post("/api/jobs/import/commit", json=spec(status_map=status_map)).json()
    assert (again["create"], again["update"], again["unchanged"]) == (0, 0, 6)
    assert again["batch_id"] is None


def test_matched_rows_update_and_add_missing_history(client):
    client.post("/api/jobs/import/commit", json=spec())
    changed = SHEET.replace("Phone Screen,2026-10-28,,", "Rejected,2026-10-28,,new note")
    report = client.post("/api/jobs/import/dry-run", json={**spec(), "csv": changed}).json()
    assert report["update"] == 1
    [match] = [m for m in report["matches"] if m["action"] == "update"]
    client.post("/api/jobs/import/commit", json={**spec(), "csv": changed})
    app = client.get(f"/api/jobs/applications/{match['record_id']}").json()
    assert app["status"] == "rejected" and app["notes"] == "new note"
    events = client.get(f"/api/jobs/applications/{match['record_id']}/status").json()
    assert [e["status"] for e in events] == ["applied", "screen", "rejected"]


def test_import_promotes_an_open_lead(client):
    lead = client.post(
        "/api/jobs/leads", json={"company": "ACME CORP", "title": "Software  Engineer"}
    ).json()
    report = client.post("/api/jobs/import/dry-run", json=spec()).json()
    assert report["promote"] == 1
    assert {"row": 2, "record_id": lead["id"], "action": "promote"} in report["matches"]
    client.post("/api/jobs/import/commit", json=spec())
    promoted = client.get(f"/api/jobs/applications/{lead['id']}").json()
    assert promoted["status"] == "applied" and promoted["date_applied"] == "2026-11-02"


def test_reached_column_fills_the_history(client):
    csv = (
        "Company,Title,Status,Applied,Furthest\nAcme Corp,Engineer,Rejected,2026-11-01,Interview\n"
    )
    mapping = {
        "Company": "company",
        "Title": "title",
        "Status": "status",
        "Applied": "date_applied",
        "Furthest": "reached",
    }
    client.post("/api/jobs/import/commit", json={"csv": csv, "mapping": mapping})
    [app] = client.get("/api/jobs/applications").json()
    assert app["status"] == "rejected" and app["reached"] == "interview"


def test_mapping_errors(client):
    r = client.post("/api/jobs/import/dry-run", json={**spec(), "mapping": {"Company": "company"}})
    assert r.status_code == 422 and "title" in r.json()["detail"]
    bad = {**MAPPING, "Notes": "title"}
    assert (
        client.post("/api/jobs/import/dry-run", json={**spec(), "mapping": bad}).status_code == 422
    )
    bad = {**MAPPING, "Nope": "notes"}
    assert (
        client.post("/api/jobs/import/dry-run", json={**spec(), "mapping": bad}).status_code == 422
    )
    r = client.post("/api/jobs/import/dry-run", json=spec(status_map={"Applied": "nope"}))
    assert r.status_code == 422
    assert client.post("/api/jobs/import/preview", json={"csv": "\n\n"}).status_code == 422


def test_contacts_import(client):
    csv = "Name;Company;Email;Contacted\nJane Doe;Example Labs;jane@example.com;2026-11-03\n"
    csv += "John Roe;;;\n"
    mapping = {"Name": "name", "Company": "company", "Email": "email", "Contacted": "contacted_on"}
    body = {"csv": csv, "kind": "contacts", "mapping": mapping}
    report = client.post("/api/jobs/import/commit", json=body).json()
    assert (report["create"], report["companies_created"]) == (2, 1)
    again = client.post("/api/jobs/import/commit", json=body).json()
    assert again["unchanged"] == 2
    contacts = {c["name"]: c for c in client.get("/api/jobs/contacts").json()}
    assert contacts["Jane Doe"]["company"] == "Example Labs"
    assert contacts["Jane Doe"]["contacted_on"] == "2026-11-03"
    assert contacts["John Roe"]["company"] is None


def test_undo_reverts_the_import(client, session):
    existing = client.post(
        "/api/jobs/applications", json={"company": "Acme Corp", "title": "Kept"}
    ).json()
    report = client.post("/api/jobs/import/commit", json=spec()).json()
    r = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]})
    assert r.status_code == 200, r.text
    assert r.json()["conflicts"] == 0
    left = client.get("/api/jobs/applications", params={"leads": "include"}).json()
    assert [a["id"] for a in left] == [existing["id"]]
    assert [c["name"] for c in client.get("/api/jobs/companies").json()] == ["Acme Corp"]
    # Undoing twice does nothing more, and a non-import batch is refused.
    again = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]}).json()
    assert again["reverted"] == 0
    other = audit.history(session, "jobs_applications", existing["id"])[0].batch_id
    assert client.post("/api/jobs/import/undo", json={"batch_id": other}).status_code == 422


@pytest.mark.parametrize("size", [5_000_001])
def test_oversized_file_is_refused(client, size):
    r = client.post("/api/jobs/import/preview", json={"csv": "a" * size})
    assert r.status_code == 422


def test_dry_run_writes_nothing(client, session):
    client.post("/api/jobs/import/dry-run", json=spec())
    assert session.scalars(select(Application)).all() == []
