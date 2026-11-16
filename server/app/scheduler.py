"""Background jobs (APScheduler), e.g. the CalDAV and IMAP polls.

A module that needs a periodic job adds `jobs.py` exposing `register_jobs`; `app.main`
calls it at startup when `SCHEDULER_ENABLED` is true (it is off in tests):

    from apscheduler.schedulers.background import BackgroundScheduler
    from sqlalchemy.orm import Session, sessionmaker

    from app.config import Settings
    from app.db import session_scope
    from app.timeutil import utcnow

    def register_jobs(
        scheduler: BackgroundScheduler, session_factory: sessionmaker[Session], settings: Settings
    ) -> None:
        def poll() -> None:
            with session_scope(session_factory) as session:
                ...fetch, store, freshness.mark_success(session, "caldav")...

        # next_run_time=utcnow() also runs it once right at startup
        scheduler.add_job(poll, "interval", minutes=15, id="caldav_poll", next_run_time=utcnow())

Jobs run in a thread pool, so each run opens its own session.
"""

from apscheduler.schedulers.background import BackgroundScheduler

from app.config import Settings


def make_scheduler(settings: Settings) -> BackgroundScheduler:
    return BackgroundScheduler(
        timezone=settings.timezone,
        job_defaults={"coalesce": True, "max_instances": 1, "misfire_grace_time": 300},
    )
