"""Mail fixtures: connected accounts with fake credentials, and a fake mailbox installed as the
app's source, so no test reaches a mail server or Google.

    def test_x(client, session, settings, imap_account, mailbox):
        mailbox.folders["inbox"] = {"7:1": raw_message()}
        mirror(session, settings, mailbox)            # sync it into the header mirror
        client.get("/api/mail/messages")              # the signed-in browser has the mail scope
"""

from __future__ import annotations

import pytest
from fastapi import FastAPI
from sqlalchemy.orm import Session

from app.config import Settings
from app.modules.mail.router import get_source_factory
from app.modules.mail.sync import MailAccount, mail_account, sync_account
from app.modules.mail.tests.fakes import FakeSource
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount

ICLOUD_CONFIG = {
    "preset": "icloud",
    "host": "imap.mail.me.com",
    "port": 993,
    "username": "pat@example.org",
}


@pytest.fixture
def imap_account(session: Session, settings: Settings) -> ProviderAccount:
    return accounts.create(
        session,
        settings,
        kind="imap",
        label="Personal mail",
        credentials={"password": "abcd-efgh-ijkl-mnop"},
        config=ICLOUD_CONFIG,
    )


@pytest.fixture
def gmail_account(session: Session, settings: Settings) -> ProviderAccount:
    return accounts.create(
        session,
        settings,
        kind="google",
        label="Work Google",
        credentials={"refresh_token": "1//refresh"},
        config={"email": "pat@example.com", "scopes": [google.SCOPES["gmail"]]},
    )


def factory_for(*fakes: FakeSource):
    by_id = {fake.account_id: fake for fake in fakes}

    def factory(session: Session, settings: Settings, account: MailAccount) -> FakeSource | None:
        return by_id.get(account.id)

    return factory


@pytest.fixture
def mailbox(app: FastAPI, imap_account: ProviderAccount) -> FakeSource:
    fake = FakeSource(account_id=imap_account.id)
    app.dependency_overrides[get_source_factory] = lambda: factory_for(fake)
    return fake


def account_of(session: Session, fake: FakeSource) -> MailAccount:
    account = mail_account(session, fake.account_id)
    assert account is not None
    return account


def mirror(session: Session, settings: Settings, fake: FakeSource) -> None:
    sync_account(session, settings, account_of(session, fake), factory=factory_for(fake))
