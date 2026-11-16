"""audit.py: create/update/delete logging, soft delete, revert, transactions."""

import json
from datetime import UTC, date, datetime

import pytest
from sqlalchemy import String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from app import audit
from app.db import Base, OwnedMixin


class Probe(OwnedMixin, Base):
    """A test-only owned model with one column of each common type."""

    __tablename__ = "test_audit_probes"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(50))
    count: Mapped[int] = mapped_column(default=0)
    flag: Mapped[bool] = mapped_column(default=False)
    day: Mapped[date | None]
    stamp: Mapped[datetime | None]


def rows(session: Session) -> list[audit.ChangeLog]:
    return list(session.scalars(select(audit.ChangeLog).order_by(audit.ChangeLog.id)))


def test_create_logs_a_snapshot(session: Session):
    probe = audit.create(session, Probe(name="a", count=2), "me")

    assert probe.id is not None
    assert probe.created_by == "me"
    [row] = rows(session)
    assert (row.op, row.table_name, row.record_id, row.field) == (
        "create",
        "test_audit_probes",
        str(probe.id),
        None,
    )
    assert row.author == "me"
    assert row.old_value is None
    snapshot = json.loads(row.new_value)
    assert snapshot["name"] == "a" and snapshot["count"] == 2


def test_update_logs_only_changed_fields_in_one_batch(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    audit.update(session, probe, {"name": "b", "count": 0, "day": date(2026, 10, 18)}, "claude")

    updates = [r for r in rows(session) if r.op == "update"]
    assert {r.field for r in updates} == {"name", "day"}  # count did not change
    assert len({r.batch_id for r in updates}) == 1
    name_row = next(r for r in updates if r.field == "name")
    assert (json.loads(name_row.old_value), json.loads(name_row.new_value)) == ("a", "b")
    assert name_row.author == "claude"


def test_update_with_no_changes_writes_nothing(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    audit.update(session, probe, {"name": "a"}, "me")
    assert len(rows(session)) == 1


def test_update_rejects_unknown_and_managed_fields(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    with pytest.raises(ValueError):
        audit.update(session, probe, {"nope": 1}, "me")
    with pytest.raises(ValueError):
        audit.update(session, probe, {"created_by": "claude"}, "me")
    with pytest.raises(ValueError):
        audit.update(session, probe, {"id": 99}, "me")


def test_unknown_author_is_rejected(session: Session):
    with pytest.raises(ValueError):
        audit.create(session, Probe(name="a"), "mallory")


def test_delete_is_soft_and_hidden_from_queries(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    probe_id = probe.id
    audit.delete(session, probe, "me")
    session.expunge_all()

    assert session.scalars(select(Probe)).all() == []
    assert session.get(Probe, probe_id) is None
    hidden = session.get(Probe, probe_id, execution_options={"include_deleted": True})
    assert hidden is not None and hidden.deleted_at is not None
    delete_row = rows(session)[-1]
    assert delete_row.op == "delete"
    assert json.loads(delete_row.old_value)["name"] == "a"


def test_revert_update_restores_value_of_each_type(session: Session):
    stamp = datetime(2026, 10, 1, 12, 30, tzinfo=UTC)
    probe = audit.create(session, Probe(name="a", day=date(2026, 1, 2), stamp=stamp), "me")
    audit.update(
        session,
        probe,
        {"name": "b", "flag": True, "day": None, "stamp": datetime(2026, 10, 2, tzinfo=UTC)},
        "me",
    )
    for change in [r for r in rows(session) if r.op == "update"]:
        audit.revert(session, change.id, "me")

    session.refresh(probe)
    assert (probe.name, probe.flag, probe.day, probe.stamp) == ("a", False, date(2026, 1, 2), stamp)


def test_revert_writes_its_own_log_rows(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    audit.update(session, probe, {"name": "b"}, "me")
    change = rows(session)[-1]

    [revert_row] = audit.revert(session, change.id, "claude")

    assert revert_row.op == "update"
    assert revert_row.reverts_change_id == change.id
    assert revert_row.author == "claude"
    assert json.loads(revert_row.new_value) == "a"


def test_revert_update_conflicts_when_field_changed_again(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    audit.update(session, probe, {"name": "b"}, "me")
    first = rows(session)[-1]
    audit.update(session, probe, {"name": "c"}, "me")

    with pytest.raises(audit.RevertConflict):
        audit.revert(session, first.id, "me")


def test_revert_create_deletes_and_revert_delete_restores(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    probe_id = probe.id
    create_row = rows(session)[-1]

    [delete_row] = audit.revert(session, create_row.id, "me")
    assert delete_row.op == "delete"
    assert session.scalars(select(Probe)).all() == []

    [restore_row] = audit.revert(session, delete_row.id, "me")
    assert restore_row.op == "create"
    assert restore_row.reverts_change_id == delete_row.id
    session.expunge_all()
    assert session.get(Probe, probe_id).name == "a"


def test_revert_delete_after_audit_delete(session: Session):
    probe = audit.create(session, Probe(name="a"), "me")
    audit.delete(session, probe, "me")
    delete_row = rows(session)[-1]

    audit.revert(session, delete_row.id, "me")

    assert [p.name for p in session.scalars(select(Probe))] == ["a"]


def test_revert_unknown_change_raises_lookup_error(session: Session):
    with pytest.raises(LookupError):
        audit.revert(session, 12345, "me")


def test_transaction_groups_calls_into_one_batch(session: Session):
    with audit.transaction(session) as batch_id:
        a = audit.create(session, Probe(name="a"), "me")
        audit.create(session, Probe(name="b"), "me")
        audit.update(session, a, {"count": 5}, "me")

    assert {r.batch_id for r in rows(session)} == {batch_id}


def test_transaction_rolls_back_everything_on_error(session: Session):
    with pytest.raises(RuntimeError), audit.transaction(session):
        audit.create(session, Probe(name="a"), "me")
        raise RuntimeError("boom")

    assert session.scalars(select(Probe)).all() == []
    assert rows(session) == []


def test_naive_datetimes_are_refused(session: Session):
    with pytest.raises(Exception, match="naive datetime"):
        audit.create(session, Probe(name="a", stamp=datetime(2026, 1, 1)), "me")


def test_revert_hook_runs_after_the_undo_in_the_same_batch(session: Session):
    seen: list[tuple[str, int, bool]] = []

    def hook(hook_session, change, obj, author):
        seen.append((change.op, obj.id, obj.deleted_at is None))
        if obj.deleted_at is None:
            audit.update(hook_session, obj, {"count": obj.count + 1}, author)

    audit.register_revert_hook("test_audit_probes", hook)
    audit.register_revert_hook("test_audit_probes", hook)  # registering twice is a no-op
    try:
        probe = audit.create(session, Probe(name="a"), "me")
        audit.delete(session, probe, "me")
        delete_row = rows(session)[-1]

        written = audit.revert(session, delete_row.id, "claude")
    finally:
        audit._REVERT_HOOKS.pop("test_audit_probes", None)

    assert seen == [("delete", probe.id, True)]
    assert [(r.op, r.field) for r in written] == [("create", None), ("update", "count")]
    assert len({r.batch_id for r in written}) == 1
    assert written[0].reverts_change_id == delete_row.id


def test_a_failing_revert_hook_rolls_the_revert_back(session: Session):
    def hook(hook_session, change, obj, author):
        raise audit.RevertConflict("refused by hook")

    audit.register_revert_hook("test_audit_probes", hook)
    try:
        probe = audit.create(session, Probe(name="a"), "me")
        probe_id = probe.id
        create_row = rows(session)[-1]
        with pytest.raises(audit.RevertConflict):
            audit.revert(session, create_row.id, "me")
    finally:
        audit._REVERT_HOOKS.pop("test_audit_probes", None)

    session.expunge_all()
    assert session.get(Probe, probe_id).deleted_at is None
    assert [r.op for r in rows(session)] == ["create"]


def test_batch_changes_lists_one_batch_in_order(session: Session):
    with audit.transaction(session) as batch_id:
        audit.create(session, Probe(name="a"), "me")
        audit.create(session, Probe(name="b"), "me")
    audit.create(session, Probe(name="c"), "me")

    names = [json.loads(r.new_value)["name"] for r in audit.batch_changes(session, batch_id)]
    assert names == ["a", "b"]
