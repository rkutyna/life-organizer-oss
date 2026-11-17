"""Regression tests for the CSV import from a security and correctness review: file limits that
bound memory, per-row problems instead of crashes, the REST length limits, future dates,
re-importing leads, an undo that leaves later work alone, and import authorship. Every name and
CSV is fictional."""

import datetime as dt
import tracemalloc

import pytest
from sqlalchemy import select

from app import audit
from app.modules.jobs import importer
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


MAPPING = {"Company": "company", "Title": "title", "Status": "status", "Applied": "date_applied"}


def commit(client, csv, mapping=None, **kw):
    r = client.post(
        "/api/jobs/import/commit", json={"csv": csv, "mapping": mapping or MAPPING, **kw}
    )
    assert r.status_code == 200, r.text
    return r.json()


def codes(report):
    return {(p["row"], p["code"], p["field"], p["skipped"]) for p in report["problems"]}


def test_a_row_wider_than_the_column_cap_is_refused(client):
    csv = "Company,Title\n" + ",".join(["x"] * (importer.MAX_COLUMNS + 1)) + "\nAcme,X\n"
    r = client.post("/api/jobs/import/preview", json={"csv": csv})
    assert r.status_code == 422
    assert "columns" in r.json()["detail"]


def test_trailing_empty_cells_do_not_widen_the_file(client):
    csv = "Company,Title\n" + "A,B" + "," * 50_000 + "\n" + "Acme,X\n" * 2_000
    r = client.post("/api/jobs/import/preview", json={"csv": csv})
    assert r.status_code == 200
    assert r.json()["headers"] == ["Company", "Title"]
    assert r.json()["row_count"] == 2_001


def test_one_wide_row_does_not_pad_every_row():
    # One row at the cap and many narrow ones: memory follows the cells, not rows x width.
    csv = "Company,Title\n" + ",".join(["x"] * importer.MAX_COLUMNS) + "\n" + "Acme,X\n" * 9_000
    tracemalloc.start()
    try:
        headers, rows = importer.read_csv(csv)
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert len(headers) == importer.MAX_COLUMNS and len(rows) == 9_001
    assert max(len(r) for r in rows[1:]) == 2  # narrow rows keep their own length
    assert peak < 20_000_000


def test_too_many_rows_is_refused(client):
    csv = "Company,Title\n" + "Acme,X\n" * (importer.MAX_ROWS + 1)
    r = client.post("/api/jobs/import/preview", json={"csv": csv})
    assert r.status_code == 422 and "rows" in r.json()["detail"]


def test_preview_pads_only_the_rows_it_shows(client):
    csv = "Company,Title,Notes\nAcme,X\nGlobex,Y,Hello\n"
    p = client.post("/api/jobs/import/preview", json={"csv": csv}).json()
    assert p["rows"] == [["Acme", "X", ""], ["Globex", "Y", "Hello"]]


def test_a_cell_over_the_csv_limit_is_a_422(client):
    csv = "Company,Title\nAcme Corp," + "x" * 200_000 + "\n"
    for step in ("preview", "dry-run", "commit"):
        body = {"csv": csv, "mapping": {"Company": "company", "Title": "title"}}
        r = client.post(f"/api/jobs/import/{step}", json=body)
        assert r.status_code == 422, step
        assert "line 2" in r.json()["detail"]


def test_too_many_tags_is_a_row_problem_not_a_crash(client):
    tags = ";".join(f"t{i}" for i in range(31))
    csv = f'Company,Title,Tags\nAcme Corp,Data Engineer,"{tags}"\nAcme Corp,Analyst,remote\n'
    mapping = {"Company": "company", "Title": "title", "Tags": "tags"}
    report = commit(client, csv, mapping)
    assert report["create"] == 2
    assert (2, "too_many_tags", "tags", False) in codes(report)
    leads = {a["title"]: a for a in client.get("/api/jobs/leads").json()}
    assert leads["Data Engineer"]["tags"] == [] and leads["Analyst"]["tags"] == ["remote"]


def test_tags_merged_past_the_limit_skip_only_the_tags(client):
    existing = application(client, title="Data Engineer", tags=[f"a{i}" for i in range(29)])
    applied = existing["date_applied"]
    csv = (
        "Company,Title,Status,Applied,Tags,Notes\n"
        f'Acme Corp,Data Engineer,Applied,{applied},"b1;b2",new note\n'
        "Acme Corp,Analyst,Applied,2026-11-01,x,\n"
    )
    mapping = {**MAPPING, "Tags": "tags", "Notes": "notes"}
    report = commit(client, csv, mapping)
    assert (report["update"], report["create"]) == (1, 1)
    assert (2, "too_many_tags", "tags", False) in codes(report)
    after = get(client, existing["id"]).json()
    assert len(after["tags"]) == 29 and after["notes"] == "new note"


def test_import_applies_the_rest_length_limits(client):
    csv = (
        "Company,Title,Notes,Location\n"
        f"{'N' * 201},Engineer,,\n"
        f"Acme Corp,{'T' * 301},,\n"
        f"Acme Corp,Analyst,{'x' * 20_001},{'L' * 201}\n"
    )
    mapping = {"Company": "company", "Title": "title", "Notes": "notes", "Location": "location"}
    report = commit(client, csv, mapping)
    assert report["create"] == 1 and report["skipped"] == 2
    assert codes(report) == {
        (2, "too_long", "company", True),
        (3, "too_long", "title", True),
        (4, "too_long", "notes", False),
        (4, "too_long", "location", False),
    }
    [row] = client.get("/api/jobs/leads").json()
    assert row["title"] == "Analyst" and row["notes"] == "" and row["location"] == ""
    names = [c["name"] for c in client.get("/api/jobs/companies").json()]
    assert names == ["Acme Corp"]


def test_import_limits_contact_text_too(client):
    csv = f"Name,Email,Notes\n{'J' * 201},,\nJane Doe,{'e' * 321}@example.com,ok\n"
    body = {
        "csv": csv,
        "kind": "contacts",
        "mapping": {"Name": "name", "Email": "email", "Notes": "notes"},
    }
    report = client.post("/api/jobs/import/commit", json=body).json()
    assert report["create"] == 1
    assert (2, "too_long", "name", True) in codes(report)
    assert (3, "too_long", "email", False) in codes(report)


def test_import_refuses_a_future_date_found(client):
    csv = "Company,Title,Found\nAcme Corp,Data Engineer,2099-01-01\n"
    mapping = {"Company": "company", "Title": "title", "Found": "found_on"}
    report = commit(client, csv, mapping)
    assert (2, "future_date", "found_on", False) in codes(report)
    [row] = client.get("/api/jobs/leads").json()
    assert row["found_on"] == days_ago(0)


def test_reimporting_a_lead_after_applying_does_not_log_it_again(client):
    csv = "Company,Title,Status,Applied\nAcme Corp,Data Engineer,Wishlist,\n"
    assert commit(client, csv)["create"] == 1
    [first] = client.get("/api/jobs/leads").json()
    client.post(f"/api/jobs/applications/{first['id']}/apply", json={})
    again = commit(client, csv)
    assert (again["create"], again["unchanged"]) == (0, 1)
    assert client.get("/api/jobs/leads").json() == []
    assert [e["status"] for e in events(client, first["id"])] == ["lead", "applied"]


def test_reimporting_a_lead_row_with_new_notes_updates_the_submitted_posting(client):
    csv = "Company,Title,Status,Applied,Notes\nAcme Corp,Data Engineer,Wishlist,,\n"
    mapping = {**MAPPING, "Notes": "notes"}
    commit(client, csv, mapping)
    [first] = client.get("/api/jobs/leads").json()
    client.post(f"/api/jobs/applications/{first['id']}/apply", json={})
    report = commit(client, csv.replace("Wishlist,,", "Wishlist,,Remote ok"), mapping)
    assert (report["create"], report["update"]) == (0, 1)
    after = get(client, first["id"]).json()
    assert after["status"] == "applied" and after["notes"] == "Remote ok"
    assert [e["status"] for e in events(client, first["id"])] == ["lead", "applied"]


def test_undo_leaves_an_application_worked_on_since(client, session):
    csv = "Company,Title,Status,Applied\nAcme Corp,Data Engineer,Applied,2026-11-01\n"
    report = commit(client, csv)
    [app] = client.get("/api/jobs/applications").json()
    interview = client.post(
        "/api/jobs/interviews", json={"application_id": app["id"], "stage": "onsite"}
    ).json()
    client.post(f"/api/jobs/applications/{app['id']}/status", json={"status": "interview"})
    client.patch(f"/api/jobs/applications/{app['id']}", json={"notes": "my own notes"})
    undone = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]}).json()
    assert undone["conflicts"] >= 1
    assert client.get(f"/api/jobs/interviews/{interview['id']}").status_code == 200
    kept = get(client, app["id"]).json()
    assert kept["status"] == "interview" and kept["notes"] == "my own notes"
    assert [e["status"] for e in events(client, app["id"])] == ["applied", "interview"]


@pytest.mark.parametrize("touch", ["interview", "status", "notes"])
def test_any_outside_change_keeps_an_imported_application(client, touch):
    csv = "Company,Title,Status,Applied\nAcme Corp,Data Engineer,Applied,2026-11-01\n"
    report = commit(client, csv)
    [app] = client.get("/api/jobs/applications").json()
    if touch == "interview":
        client.post("/api/jobs/interviews", json={"application_id": app["id"]})
    elif touch == "status":
        client.post(f"/api/jobs/applications/{app['id']}/status", json={"status": "screen"})
    else:
        client.patch(f"/api/jobs/applications/{app['id']}", json={"notes": "mine"})
    undone = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]}).json()
    assert undone["conflicts"] == 2  # the application, and its company that still has it
    assert get(client, app["id"]).status_code == 200
    assert events(client, app["id"])[0]["status"] == "applied"


def test_undo_leaves_a_contact_edited_since(client):
    csv = "Name,Email\nJane Doe,jane@example.com\nJohn Roe,\n"
    body = {"csv": csv, "kind": "contacts", "mapping": {"Name": "name", "Email": "email"}}
    report = client.post("/api/jobs/import/commit", json=body).json()
    jane = next(c for c in client.get("/api/jobs/contacts").json() if c["name"] == "Jane Doe")
    client.patch(f"/api/jobs/contacts/{jane['id']}", json={"role": "Recruiter"})
    undone = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]}).json()
    assert (undone["reverted"], undone["conflicts"]) == (1, 1)
    assert [c["name"] for c in client.get("/api/jobs/contacts").json()] == ["Jane Doe"]


def test_undo_after_a_lead_promotion_has_no_false_conflict(client):
    found = lead(client, title="Data Engineer", found_on=days_ago(5))
    csv = f"Company,Title,Status,Applied\nAcme Corp,Data Engineer,Screen,{days_ago(0)}\n"
    report = commit(client, csv)
    assert report["promote"] == 1
    undone = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]}).json()
    assert undone["conflicts"] == 0
    after = get(client, found["id"]).json()
    assert after["status"] == "lead" and after["date_applied"] is None
    assert [e["status"] for e in events(client, found["id"])] == ["lead"]


def test_undo_of_added_history_on_an_existing_application(client):
    existing = application(client, title="Data Engineer", date_applied="2026-11-01")
    csv = "Company,Title,Status,Applied\nAcme Corp,Data Engineer,Rejected,2026-11-01\n"
    report = commit(client, csv)
    assert report["update"] == 1
    undone = client.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]}).json()
    assert undone["conflicts"] == 0
    assert get(client, existing["id"]).json()["status"] == "applied"
    assert [e["status"] for e in events(client, existing["id"])] == ["applied"]


def test_import_and_undo_are_logged_under_the_callers_author(token_client, session):
    claude = token_client(["api"], author="claude")
    csv = "Company,Title\nAcme Corp,Data Engineer\n"
    body = {"csv": csv, "mapping": {"Company": "company", "Title": "title"}}
    report = claude.post("/api/jobs/import/commit", json=body).json()
    assert {c.author for c in audit.batch_changes(session, report["batch_id"])} == {"claude"}
    r = claude.post("/api/jobs/import/undo", json={"batch_id": report["batch_id"]})
    assert r.status_code == 200 and r.json()["reverted"] > 0
    assert set(session.scalars(select(audit.ChangeLog.author))) == {"claude"}


def test_import_promotion_never_dates_history_before_the_lead(client):
    found = lead(client, title="Data Engineer", found_on=days_ago(3))
    csv = f"Company,Title,Status,Applied\nAcme Corp,Data Engineer,Screen,{days_ago(10)}\n"
    assert commit(client, csv)["promote"] == 1
    history = events(client, found["id"])
    assert [e["status"] for e in history] == ["lead", "applied", "screen"]
    assert all(e["on_date"] >= days_ago(3) for e in history)
    assert get(client, found["id"]).json()["status"] == "screen"
