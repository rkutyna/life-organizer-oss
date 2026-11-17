"""The Google Tasks poll, every 5 minutes (app.main calls register_jobs when the scheduler is
on). Apple Reminders needs no job: the Mac helper pushes."""

from apscheduler.schedulers.background import BackgroundScheduler
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings
from app.db import session_scope
from app.modules.reminders.google_sync import sync_all
from app.timeutil import utcnow

POLL_EVERY_MINUTES = 5


def register_jobs(
    scheduler: BackgroundScheduler,
    session_factory: sessionmaker[Session],
    settings: Settings,
) -> None:
    def poll() -> None:
        with session_scope(session_factory) as session:
            sync_all(session, settings)

    # next_run_time=now also runs it once at startup.
    scheduler.add_job(
        poll,
        "interval",
        minutes=POLL_EVERY_MINUTES,
        id="reminders_google_poll",
        next_run_time=utcnow(),
    )
