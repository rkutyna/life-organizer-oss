"""Mirrored mail headers. Not owned: no audit trail, and each sync replaces an account's rows.

One row per message per folder (a message to yourself is in Inbox and Sent). Bodies are never
stored; router.py fetches them from the mailbox when asked. Every text column has already been
cleaned (sanitize.clean_header) and is still the sender's text.

`account_id` is the connected account (`core_provider_accounts.id`): an "imap" account, or a
"google" account that granted Gmail. It is not a foreign key: when an account is removed in
Settings, the next sync deletes its rows (sync.prune_removed_accounts) and reads stop showing
them at once.
"""

from datetime import datetime

from sqlalchemy import JSON, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class MailMessage(Base):
    __tablename__ = "mail_messages"
    __table_args__ = (
        UniqueConstraint("account_id", "folder", "remote_id"),
        Index("ix_mail_messages_account_sent_at", "account_id", "sent_at"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    account_id: Mapped[int] = mapped_column(Integer)
    # "inbox" or "sent".
    folder: Mapped[str] = mapped_column(String(16))
    # The mailbox's own name for the folder: "INBOX", "Sent Messages", or a Gmail label id.
    mailbox: Mapped[str] = mapped_column(String(200))
    # IMAP: "<uidvalidity>:<uid>". Gmail: the API's message id.
    remote_id: Mapped[str] = mapped_column(String(200))
    message_id: Mapped[str | None] = mapped_column(String(1000))
    in_reply_to: Mapped[str | None] = mapped_column(String(1000))
    from_name: Mapped[str] = mapped_column(String(300), default="")
    from_address: Mapped[str] = mapped_column(String(320), default="")
    # [{"name": ..., "address": ...}], at most sanitize.MAX_RECIPIENTS each.
    to: Mapped[list] = mapped_column(JSON, default=list)
    cc: Mapped[list] = mapped_column(JSON, default=list)
    subject: Mapped[str] = mapped_column(Text, default="")
    # The Date header (UTC), or when the mailbox received it if the header is missing or bad.
    sent_at: Mapped[datetime]
    size: Mapped[int | None] = mapped_column(Integer)
    # Why the From line may not be the real sender (message.HeaderFields.sender_warning).
    sender_warning: Mapped[str | None] = mapped_column(Text)
    received_at: Mapped[datetime]
