"""Application.status is derived: it is the status of the application's latest live status event
(by on_date, then id). The status endpoints, the importer and the revert hooks all keep it in
step through `sync_application_status`."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.modules.jobs.models import Application, ApplicationStatusEvent


def latest_status_event(session: Session, application_id: int) -> ApplicationStatusEvent | None:
    return session.scalars(
        select(ApplicationStatusEvent)
        .where(ApplicationStatusEvent.application_id == application_id)
        .order_by(ApplicationStatusEvent.on_date.desc(), ApplicationStatusEvent.id.desc())
        .limit(1)
    ).first()


def sync_application_status(session: Session, application: Application, author: str) -> None:
    """Make Application.status the status of its latest live event. A deleted application, or
    one with no live events, is left alone."""
    if application.deleted_at is not None:
        return
    latest = latest_status_event(session, application.id)
    if latest is not None and latest.status != application.status:
        audit.update(session, application, {"status": latest.status}, author)
