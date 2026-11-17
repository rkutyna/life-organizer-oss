"""The demo seed: fictional lists and reminders, some dated this week, and repeatable."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.audit import ChangeLog
from app.modules.reminders import demo
from app.modules.reminders.models import Reminder
from app.timeutil import today_local


def test_demo_seed(client, session: Session):
    demo.seed(session)
    demo.seed(session)  # repeatable: replaces, never duplicates
    assert len(session.scalars(select(Reminder)).all()) == len(demo.ITEMS)
    assert session.scalars(select(ChangeLog)).all() == []

    lists = client.get("/api/reminders/lists").json()
    assert [lst["title"] for lst in lists] == ["Home", "Errands", "Work", "Books to read"]
    open_items = client.get("/api/reminders").json()
    today = today_local().isoformat()
    assert any(r["due_date"] == today for r in open_items)
    assert all(r["sync"]["state"] == "synced" for r in open_items)
    assert client.get("/api/reminders/status").json()["helper"]["state"] == "ok"
