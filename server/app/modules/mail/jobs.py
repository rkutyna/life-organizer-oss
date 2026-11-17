"""The mail header poll: every 15 minutes, every connected mail account, one after another.

One job for all accounts, so an account connected in Settings is picked up on the next run
without a restart (connecting one also syncs it right away; router.connect_imap).
"""

import logging

from apscheduler.schedulers.background import BackgroundScheduler
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings
from app.db import session_scope
from app.modules.mail.sync import sync_all
from app.timeutil import utcnow

log = logging.getLogger(__name__)

POLL_EVERY_MINUTES = 15


def register_jobs(
    scheduler: BackgroundScheduler,
    session_factory: sessionmaker[Session],
    settings: Settings,
) -> None:
    def poll() -> None:
        with session_scope(session_factory) as session:
            errors = sync_all(session, settings)
        for account_id, error in errors.items():
            log.warning("mail account %s: %s", account_id, error)

    scheduler.add_job(
        poll, "interval", minutes=POLL_EVERY_MINUTES, id="mail_poll", next_run_time=utcnow()
    )
