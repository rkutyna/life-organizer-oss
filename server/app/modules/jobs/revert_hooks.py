"""Keep job records consistent when a change is reverted from History.

Registered with `app.audit.register_revert_hook` when the jobs models are imported:

- Any revert touching a status event (create, update or delete) re-derives its application's
  status, because Application.status is the status of the latest live event.
- Reverting an application's delete also restores the status events and interviews that the
  delete cascaded to (the rows deleted in the same batch). Children deleted on their own, in an
  earlier batch, stay deleted. The status is re-derived once, after every child is back, so the
  restore does not log a status flip per event.
- Reverting an application's create soft-deletes its live status events and interviews too, as
  DELETE /applications/{id} would, so no child is left pointing at a deleted application.
- Reverting an application's `status` change undoes the status-event changes of the same batch
  (the event a status change added, or the edit or delete that moved the status), then derives
  the status again. Reverting only the field would leave it disagreeing with the history.
"""

from contextlib import suppress

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.db import OwnedMixin
from app.modules.jobs.models import Application, ApplicationStatusEvent, Interview
from app.modules.jobs.status_sync import sync_application_status

# Set in session.info while an application's children are being restored, so each restored
# status event does not re-derive the status on its own (it is derived once at the end).
RESTORING_CHILDREN = "jobs_restoring_children"

CHILD_MODELS: tuple[type[ApplicationStatusEvent] | type[Interview], ...] = (
    ApplicationStatusEvent,
    Interview,
)
_CHILD_TABLES = {model.__tablename__: model for model in CHILD_MODELS}


def after_status_event_revert(
    session: Session, change: audit.ChangeLog, obj: OwnedMixin, author: str
) -> None:
    assert isinstance(obj, ApplicationStatusEvent)
    if session.info.get(RESTORING_CHILDREN):
        return
    application = session.get(
        Application, obj.application_id, execution_options={"include_deleted": True}
    )
    if application is not None:
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
        _revert_status_events_of_batch(session, change, obj, author)


def _revert_status_events_of_batch(
    session: Session, change: audit.ChangeLog, application: Application, author: str
) -> None:
    table = ApplicationStatusEvent.__tablename__
    session.info[RESTORING_CHILDREN] = True
    try:
        for sibling in reversed(audit.batch_changes(session, change.batch_id)):
            if sibling.table_name != table or sibling.reverts_change_id is not None:
                continue
            event = session.get(
                ApplicationStatusEvent,
                int(sibling.record_id),
                execution_options={"include_deleted": True},
            )
            if event is None or event.application_id != application.id:
                continue
            with suppress(audit.RevertConflict):
                audit.revert(session, sibling.id, author)
    finally:
        session.info.pop(RESTORING_CHILDREN, None)
    sync_application_status(session, application, author)


def _restore_cascaded_children(
    session: Session, change: audit.ChangeLog, application: Application, author: str
) -> None:
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


audit.register_revert_hook(ApplicationStatusEvent.__tablename__, after_status_event_revert)
audit.register_revert_hook(Application.__tablename__, after_application_revert)
