"""/api/history: listing changes for a record and reverting one over HTTP.

Writes go through `audit` directly on a test-only model; the history API is what is tested.
"""

from collections.abc import Callable

from fastapi.testclient import TestClient
from sqlalchemy import String
from sqlalchemy.orm import Mapped, Session, mapped_column

from app import audit
from app.db import Base, OwnedMixin


class Note(OwnedMixin, Base):
    __tablename__ = "test_history_notes"

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(50))


def history(client: TestClient, note_id: int) -> list[dict]:
    response = client.get(
        "/api/history", params={"table": "test_history_notes", "record_id": note_id}
    )
    assert response.status_code == 200
    return response.json()


def make_note(session: Session) -> Note:
    return audit.create(session, Note(title="Original"), "me")


def test_lists_changes_newest_first(client: TestClient, session: Session):
    note = make_note(session)
    audit.update(session, note, {"title": "Renamed"}, "claude")

    rows = history(client, note.id)

    assert [(r["op"], r["author"]) for r in rows] == [("update", "claude"), ("create", "me")]
    assert rows[0]["old_value"] == "Original" and rows[0]["new_value"] == "Renamed"


def test_revert_is_logged_as_the_browser(client: TestClient, session: Session):
    note = make_note(session)
    audit.update(session, note, {"title": "Renamed"}, "claude")
    change = history(client, note.id)[0]["id"]

    response = client.post(f"/api/history/{change}/revert")

    assert response.status_code == 200
    [row] = response.json()
    assert (row["author"], row["reverts_change_id"]) == ("me", change)
    session.expire_all()
    assert session.get(Note, note.id).title == "Original"


def test_revert_author_comes_from_the_token(
    client: TestClient, session: Session, token_client: Callable[..., TestClient]
):
    note = make_note(session)
    audit.update(session, note, {"title": "Renamed"}, "me")
    change = history(client, note.id)[0]["id"]

    claude = token_client(["api"], author="claude")
    [row] = claude.post(f"/api/history/{change}/revert").json()

    assert row["author"] == "claude"


def test_revert_a_delete_restores(client: TestClient, session: Session):
    note = make_note(session)
    audit.delete(session, note, "me")
    change = history(client, note.id)[0]["id"]

    assert client.post(f"/api/history/{change}/revert").status_code == 200
    session.expire_all()
    assert session.get(Note, note.id).deleted_at is None


def test_revert_conflict_is_409(client: TestClient, session: Session):
    note = make_note(session)
    audit.update(session, note, {"title": "Second"}, "me")
    older = history(client, note.id)[0]["id"]
    audit.update(session, note, {"title": "Third"}, "me")

    response = client.post(f"/api/history/{older}/revert")

    assert response.status_code == 409
    assert "changed again" in response.json()["detail"]


def test_revert_unknown_change_is_404(client: TestClient):
    assert client.post("/api/history/999/revert").status_code == 404


def test_record_id_needs_table(client: TestClient):
    assert client.get("/api/history", params={"record_id": 1}).status_code == 400
