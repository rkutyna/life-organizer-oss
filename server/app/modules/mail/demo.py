"""Fictional demo mail headers for screenshots and trying the app (`python -m app.demo_seed`).

One demo IMAP account with a few made-up messages. Only headers exist: opening a message tries
to fetch its body from a mailbox that does not exist and shows that error.
"""

from datetime import timedelta

from sqlalchemy.orm import Session

from app import freshness
from app.config import get_settings
from app.modules.mail.models import MailMessage
from app.modules.mail.sync import freshness_key
from app.providers import service as accounts
from app.providers.service import create as save_account  # see test_mail_readonly
from app.timeutil import utcnow

ME = {"name": "Demo User", "address": "demo@example.com"}

# (folder, hours ago, from name, from address, subject, warning)
MESSAGES = [
    (
        "inbox",
        1,
        "Acme Corp Recruiting",
        "jobs@acme.example.com",
        "Next steps: interview scheduling",
        None,
    ),
    ("inbox", 5, "Jane Doe", "jane@example.org", "Coffee next week?", None),
    (
        "inbox",
        20,
        "Example Labs",
        "careers@examplelabs.example.com",
        "Thanks for applying to Example Labs",
        None,
    ),
    (
        "inbox",
        30,
        "City Library",
        "notices@library.example.org",
        "Your hold is ready for pickup",
        None,
    ),
    (
        "inbox",
        50,
        "Account Security",
        "security@bank-alerts.example.net",
        "Verify your account now",
        "The sender's domain failed authentication (DMARC fail).",
    ),
    ("sent", 6, ME["name"], ME["address"], "Re: Coffee next week?", None),
]


def seed(session: Session) -> None:
    account = save_account(
        session,
        get_settings(),
        kind="imap",
        label="Demo mail",
        credentials=None,
        config={"preset": "custom", "host": "imap.example.com", "username": ME["address"]},
    )
    now = utcnow()
    for n, (folder, hours, name, address, subject, warning) in enumerate(MESSAGES):
        sent = folder == "sent"
        session.add(
            MailMessage(
                account_id=account.id,
                folder=folder,
                mailbox="Sent Messages" if sent else "INBOX",
                remote_id=f"1:{n + 1}",
                message_id=f"<demo-{n}@example.com>",
                from_name=name,
                from_address=address,
                to=[{"name": "Jane Doe", "address": "jane@example.org"}] if sent else [ME],
                subject=subject,
                sent_at=now - timedelta(hours=hours),
                size=4096,
                sender_warning=warning,
                received_at=now,
            )
        )
    session.commit()
    freshness.mark_success(session, freshness_key(account.id))
    accounts.mark_success(session, account)
