"""Keep job records consistent when a change is reverted from History.

Registered with `app.audit.register_revert_hook` when the jobs models are imported. A hook that
raises `audit.RevertConflict` refuses the revert: `audit.revert` runs hooks inside its
transaction, so everything the revert wrote is rolled back and History answers 409.

- Any revert touching a status event (create, update or delete) re-derives its application's
  status, because Application.status is the status of the latest live event. It is refused when
  it would bring back an event whose status has since been removed from the status list, or
  leave the history disagreeing with the application (`service.history_problem`): no event left,
  a lead event after a submitted one, a lead with a date applied.
- Reverting an application's delete also restores the status events and interviews that the
  delete cascaded to (the rows deleted in the same batch). Children deleted on their own, in an
  earlier batch, stay deleted. The status is re-derived once, after every child is back, so the
  restore does not log a status flip per event.
- Reverting an application's create soft-deletes its live status events and interviews too, as
  DELETE /applications/{id} would, so no child is left pointing at a deleted application.
- Reverting an application's `status` change undoes the rest of its batch on that application:
  the status-event changes (the event a status change added, or the edit or delete that moved
  the status) and the other fields the batch changed (an apply's `date_applied`, a promotion's
  fields), then derives the status again. Reverting only the field would leave it disagreeing
  with the history. A change edited again since is left alone; if the application ends up a
  lead or dropped lead with a date applied anyway, the date is cleared.
- Restoring a company, or reverting a rename, is refused when another live company now has the
  same folded name.
- Reverting a status-list change is refused when it would remove a reserved status or one in use.
"""

from contextlib import suppress

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.db import OwnedMixin
from app.modules.jobs import service, statuses
from app.modules.jobs.matching import company_named
from app.modules.jobs.models import (
    Application,
    ApplicationStatusEvent,
    Company,
    Interview,
    JobStatus,
)
from app.modules.jobs.status_sync import sync_application_status

# Set in session.info while an application's children are being restored, so each restored
# status event does not re-derive the status on its own (it is derived once at the end).
RESTORING_CHILDREN = "jobs_restoring_children"

CHILD_MODELS: tuple[type[ApplicationStatusEvent] | type[Interview], ...] = (
    ApplicationStatusEvent,
    Interview,
)
_CHILD_TABLES = {model.__tablename__: model for model in CHILD_MODELS}


def _removed_status(key: str) -> audit.RevertConflict:
    return audit.RevertConflict(
        f"status {key!r} is no longer in the status list; add it back (key {key!r}) first"
    )


def after_status_event_revert(
    session: Session, change: audit.ChangeLog, obj: OwnedMixin, author: str
) -> None:
    assert isinstance(obj, ApplicationStatusEvent)
    if obj.deleted_at is None and obj.status not in statuses.by_key(session):
        raise _removed_status(obj.status)
    if session.info.get(RESTORING_CHILDREN):
        return
    application = session.get(
        Application, obj.application_id, execution_options={"include_deleted": True}
    )
    if application is None or application.deleted_at is not None:
        return
    problem = service.history_problem(
        application.date_applied, service.history_keys(session, application.id)
    )
    if problem is not None:
        raise audit.RevertConflict(problem)
    sync_application_status(session, application, author)


def after_application_revert(
    session: Session, change: audit.ChangeLog, obj: OwnedMixin, author: str
) -> None:
    assert isinstance(obj, Application)
    if change.op == "delete" and obj.deleted_at is None:
        _restore_cascaded_children(session, change, obj, author)
    elif change.op == "create" and obj.deleted_at is not None:
        _delete_live_children(session, obj, author)
    elif change.op == "update" and change.field == "status":
        _revert_rest_of_batch(session, change, obj, author)


def _event_revert_allowed(
    session: Session, change: audit.ChangeLog, event: ApplicationStatusEvent
) -> bool:
    """False when reverting `change` would bring back a status no longer in the list. Checked
    before the revert so a refusal writes nothing."""
    known = statuses.by_key(session)
    if change.op == "delete":
        return event.status in known
    if change.op == "update" and change.field == "status":
        return audit.decode_value(change.old_value) in known
    return True


def _revert_rest_of_batch(
    session: Session, change: audit.ChangeLog, application: Application, author: str
) -> None:
    siblings = [
        c
        for c in reversed(audit.batch_changes(session, change.batch_id))
        if c.reverts_change_id is None and c.id != change.id and not _reverted(session, c.id)
    ]
    session.info[RESTORING_CHILDREN] = True
    try:
        for sibling in siblings:
            if sibling.table_name != ApplicationStatusEvent.__tablename__:
                continue
            event = session.get(
                ApplicationStatusEvent,
                int(sibling.record_id),
                execution_options={"include_deleted": True},
            )
            if event is None or event.application_id != application.id:
                continue
            if not _event_revert_allowed(session, sibling, event):
                continue
            with suppress(audit.RevertConflict):  # refused before writing anything
                audit.revert(session, sibling.id, author)
    finally:
        session.info.pop(RESTORING_CHILDREN, None)
    for sibling in siblings:
        if (
            sibling.table_name == Application.__tablename__
            and sibling.record_id == str(application.id)
            and sibling.op == "update"
            and sibling.field != "status"
        ):
            with suppress(audit.RevertConflict):  # refused before writing anything
                audit.revert(session, sibling.id, author)
    sync_application_status(session, application, author)
    if service.phase(application.status) != "submitted" and application.date_applied is not None:
        audit.update(session, application, {"date_applied": None}, author)


def _reverted(session: Session, change_id: int) -> bool:
    return (
        session.scalar(
            select(audit.ChangeLog.id).where(audit.ChangeLog.reverts_change_id == change_id)
        )
        is not None
    )


def _restore_cascaded_children(
    session: Session, change: audit.ChangeLog, application: Application, author: str
) -> None:
    if application.status not in statuses.by_key(session):
        raise _removed_status(application.status)
    session.info[RESTORING_CHILDREN] = True
    try:
        for sibling in audit.batch_changes(session, change.batch_id):
            model = _CHILD_TABLES.get(sibling.table_name)
            if model is None or sibling.op != "delete":
                continue
            child = session.get(
                model, int(sibling.record_id), execution_options={"include_deleted": True}
            )
            if child is None or child.application_id != application.id or child.deleted_at is None:
                continue
            audit.revert(session, sibling.id, author)
    finally:
        session.info.pop(RESTORING_CHILDREN, None)
    sync_application_status(session, application, author)


def _delete_live_children(session: Session, application: Application, author: str) -> None:
    for model in CHILD_MODELS:
        children = session.scalars(select(model).where(model.application_id == application.id))
        for child in children.all():
            audit.delete(session, child, author)


def after_company_revert(
    session: Session, change: audit.ChangeLog, obj: OwnedMixin, author: str
) -> None:
    assert isinstance(obj, Company)
    restored = change.op == "delete"
    renamed = change.op == "update" and change.field == "name"
    if obj.deleted_at is None and (restored or renamed):
        other = company_named(session, obj.name, exclude_id=obj.id)
        if other is not None:
            raise audit.RevertConflict(
                f"company {other.id} is now named {other.name!r}; rename it first"
            )


def after_job_status_revert(
    session: Session, change: audit.ChangeLog, obj: OwnedMixin, author: str
) -> None:
    assert isinstance(obj, JobStatus)
    if obj.deleted_at is None:
        return
    # The revert removed the status (it undid the status's creation).
    if obj.key in statuses.RESERVED:
        raise audit.RevertConflict(f"{obj.key!r} is a reserved status and cannot be removed")
    used = statuses.in_use(session, obj.key)
    if used:
        raise audit.RevertConflict(
            f"{used} status change(s) use {obj.key!r}; change them before removing it"
        )


audit.register_revert_hook(ApplicationStatusEvent.__tablename__, after_status_event_revert)
audit.register_revert_hook(Application.__tablename__, after_application_revert)
audit.register_revert_hook(Company.__tablename__, after_company_revert)
audit.register_revert_hook(JobStatus.__tablename__, after_job_status_revert)
