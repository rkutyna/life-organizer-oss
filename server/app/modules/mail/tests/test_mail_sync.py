"""The header mirror: adds new messages, fetches only what it has not seen, drops what is gone,
and records freshness. A failed run changes nothing; one bad message does not fail a run.
Accounts are connected accounts: IMAP ones, and Google ones that granted Gmail."""

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import freshness
from app.config import Settings
from app.modules.mail import gmail
from app.modules.mail.imap import ImapSource
from app.modules.mail.models import MailMessage
from app.modules.mail.sources import MailError
from app.modules.mail.sync import build_source, mail_accounts, sync_account, sync_all
from app.modules.mail.tests.conftest import account_of, factory_for
from app.modules.mail.tests.fakes import FakeSource, raw_message
from app.providers import google
from app.providers import service as accounts
from app.providers.models import ProviderAccount


def rows(session: Session) -> list[MailMessage]:
    return list(session.scalars(select(MailMessage).order_by(MailMessage.remote_id)))


def sync(session: Session, settings: Settings, fake: FakeSource, factory=None):
    account = account_of(session, fake)
    return sync_account(session, settings, account, factory=factory or factory_for(fake))


def test_a_first_sync_mirrors_inbox_and_sent_headers(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    fake = FakeSource(
        account_id=imap_account.id,
        folders={
            "inbox": {"7:1": raw_message(), "7:2": raw_message(subject="Second")},
            "sent": {"9:1": raw_message(subject="Re: Coffee", sender="Pat <pat@example.org>")},
        },
    )
    result = sync(session, settings, fake)

    assert result is not None and (result.listed, result.added, result.removed) == (3, 3, 0)
    first = rows(session)[0]
    assert (first.account_id, first.folder, first.mailbox) == (imap_account.id, "inbox", "INBOX")
    assert (first.from_name, first.from_address) == ("Alex Example", "alex@example.com")
    assert first.to == [{"name": "Pat Tester", "address": "pat@example.org"}]
    assert first.subject == "Coffee next week?"
    assert first.sender_warning is None
    assert [r.folder for r in rows(session)] == ["inbox", "inbox", "sent"]
    assert freshness.source_status(session, f"mail_{imap_account.id}").state == "ok"
    session.refresh(imap_account)
    assert accounts.status(imap_account) == "ok"  # Settings shows the IMAP account as working
    assert fake.closed == 1


def test_a_later_sync_fetches_only_new_ids_and_drops_gone_ones(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    fake = FakeSource(
        account_id=imap_account.id,
        folders={"inbox": {"7:1": raw_message(), "7:2": raw_message()}, "sent": {}},
    )
    sync(session, settings, fake)

    del fake.folders["inbox"]["7:1"]
    fake.folders["inbox"]["7:3"] = raw_message(subject="Third")
    result = sync(session, settings, fake)

    assert result is not None and (result.added, result.removed) == (1, 1)
    assert fake.header_fetches == [["7:1", "7:2"], ["7:3"]]
    assert [r.remote_id for r in rows(session)] == ["7:2", "7:3"]


def test_one_hostile_message_does_not_stop_the_mirror(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    hostile = (
        b"From: ceo@example.com <attacker@example.net>\r\n"
        b"Date: Fri, 31 Dec 9999 23:59:59 -1400\r\nSubject: hi\r\n\r\nbody"
    )
    fake = FakeSource(
        account_id=imap_account.id,
        folders={"inbox": {"7:1": hostile, "7:2": raw_message()}, "sent": {}},
    )

    result = sync(session, settings, fake)

    assert result is not None and result.added == 2
    bad = rows(session)[0]
    assert bad.sender_warning is not None and "malformed" in bad.sender_warning
    assert freshness.source_status(session, f"mail_{imap_account.id}").state == "ok"


def test_an_account_missing_its_settings_records_it_and_touches_nothing(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    fake = FakeSource(account_id=imap_account.id)
    assert sync(session, settings, fake, factory=lambda *_: None) is None
    status = freshness.source_status(session, f"mail_{imap_account.id}")
    assert (status.state, status.last_error) == ("error", "not configured")


def test_a_failed_run_keeps_the_old_rows_and_records_the_error(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    fake = FakeSource(account_id=imap_account.id, folders={"inbox": {"7:1": raw_message()}})
    sync(session, settings, fake)

    fake.fail = MailError("IMAP login failed: [AUTHENTICATIONFAILED]")
    with pytest.raises(MailError):
        sync(session, settings, fake)

    assert [r.remote_id for r in rows(session)] == ["7:1"]
    status = freshness.source_status(session, f"mail_{imap_account.id}")
    assert status.last_error == "IMAP login failed: [AUTHENTICATIONFAILED]"
    session.refresh(imap_account)
    assert accounts.status(imap_account) == "error"
    assert imap_account.last_error == "IMAP login failed: [AUTHENTICATIONFAILED]"
    assert fake.closed == 2


def test_accounts_are_kept_apart_and_removed_ones_pruned(
    session: Session,
    settings: Settings,
    imap_account: ProviderAccount,
    gmail_account: ProviderAccount,
) -> None:
    other = accounts.create(
        session,
        settings,
        kind="imap",
        label="Other",
        credentials={"password": "x"},
        config={"host": "imap.example.net", "port": 993, "username": "o@example.net"},
    )
    fakes = [
        FakeSource(account_id=imap_account.id, folders={"inbox": {"7:1": raw_message()}}),
        FakeSource(account_id=gmail_account.id, folders={"inbox": {"a1": raw_message()}}),
        FakeSource(account_id=other.id, folders={"inbox": {"b1": raw_message()}}),
    ]
    assert sync_all(session, settings, factory=factory_for(*fakes)) == {}
    assert len(rows(session)) == 3

    fakes[1].folders["inbox"] = {}
    other.enabled = False
    session.commit()
    sync_all(session, settings, factory=factory_for(*fakes))

    assert [(r.account_id, r.remote_id) for r in rows(session)] == [(imap_account.id, "7:1")]
    assert f"mail_{other.id}" not in freshness.registered_sources()
    assert f"mail_{imap_account.id}" in freshness.registered_sources()


def test_one_failing_account_does_not_stop_the_others(
    session: Session,
    settings: Settings,
    imap_account: ProviderAccount,
    gmail_account: ProviderAccount,
) -> None:
    broken = FakeSource(account_id=imap_account.id)
    broken.fail = MailError("IMAP unreachable at imap.mail.me.com:993: timed out")
    working = FakeSource(account_id=gmail_account.id, folders={"inbox": {"a1": raw_message()}})

    errors = sync_all(session, settings, factory=factory_for(broken, working))

    assert errors == {imap_account.id: "IMAP unreachable at imap.mail.me.com:993: timed out"}
    assert [r.account_id for r in rows(session)] == [gmail_account.id]


def test_mail_accounts_are_enabled_imap_and_google_accounts_with_gmail(
    session: Session,
    settings: Settings,
    imap_account: ProviderAccount,
    gmail_account: ProviderAccount,
) -> None:
    accounts.create(
        session,
        settings,
        kind="google",
        label="Calendar only",
        credentials={"refresh_token": "1//c"},
        config={"email": "cal@example.com", "scopes": [google.SCOPES["calendar"]]},
    )
    accounts.create(session, settings, kind="caldav", label="Calendar", credentials=None)

    found = [(a.id, a.kind, a.label, a.address) for a in mail_accounts(session)]
    assert found == [
        (imap_account.id, "imap", "Personal mail", "pat@example.org"),
        (gmail_account.id, "gmail", "Work Google", "pat@example.com"),
    ]
    assert f"mail_{imap_account.id}" in freshness.registered_sources()


def test_the_real_imap_source_uses_the_preset_and_the_stored_password(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    seen = []

    def connect(host: str, port: int):
        seen.append((host, port))
        raise OSError("no network in tests")

    account = account_of(session, FakeSource(account_id=imap_account.id))
    source = build_source(session, settings, account, connect=connect)

    assert isinstance(source, ImapSource)
    assert source.trusted_auth_servers == ("icloud.com", "me.com", "apple.com")
    with pytest.raises(MailError, match="unreachable"):
        source.list_ids(account.record.created_at.date())
    assert seen == [("imap.mail.me.com", 993)]


def test_a_custom_host_trusts_only_the_servers_entered(
    session: Session, settings: Settings
) -> None:
    record = accounts.create(
        session,
        settings,
        kind="imap",
        label="Custom",
        credentials={"password": "pw"},
        config={
            "preset": "custom",
            "host": "mail.example.net",
            "port": 993,
            "username": "me@example.net",
            "auth_servers": ["mx.example.net"],
        },
    )
    account = account_of(session, FakeSource(account_id=record.id))
    source = build_source(session, settings, account)
    assert source is not None and source.trusted_auth_servers == ("mx.example.net",)


def test_unreadable_credentials_are_a_mail_error(
    session: Session, settings: Settings, imap_account: ProviderAccount
) -> None:
    other_key = settings.model_copy(
        update={"organizer_secret_key": SecretStr("a-different-key-" * 3)}
    )
    account = account_of(session, FakeSource(account_id=imap_account.id))
    with pytest.raises(MailError, match="cannot be decrypted"):
        build_source(session, other_key, account)


def test_gmail_reads_with_the_access_token_from_core(
    session: Session,
    settings: Settings,
    gmail_account: ProviderAccount,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    asked = []

    def access_token(session_, settings_, account):
        asked.append(account.id)
        return "core-token"

    monkeypatch.setattr(google, "access_token", access_token)
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"messages": []})

    account = account_of(session, FakeSource(account_id=gmail_account.id))
    source = build_source(session, settings, account, transport=httpx.MockTransport(handler))
    assert isinstance(source, gmail.GmailSource)
    result = sync_account(session, settings, account, factory=lambda *_: source)

    assert result is not None and result.listed == 0
    assert asked and set(asked) == {gmail_account.id}
    assert {r.headers["authorization"] for r in seen} == {"Bearer core-token"}
    assert {r.method for r in seen} == {"GET"}


def test_a_google_account_that_must_be_reconnected_records_the_error(
    session: Session,
    settings: Settings,
    gmail_account: ProviderAccount,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def refused(session_, settings_, account):
        raise google.GoogleAuthError("invalid_grant")

    monkeypatch.setattr(google, "access_token", refused)
    account = account_of(session, FakeSource(account_id=gmail_account.id))
    source = build_source(
        session, settings, account, transport=httpx.MockTransport(lambda r: httpx.Response(500))
    )

    with pytest.raises(MailError, match="reconnecting"):
        sync_account(session, settings, account, factory=lambda *_: source)
    status = freshness.source_status(session, f"mail_{gmail_account.id}")
    assert status.state == "error" and "reconnecting" in (status.last_error or "")
