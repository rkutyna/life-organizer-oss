"""Header parsing for the mirror, whole-message parsing for a read, and sender checks."""

from datetime import UTC, datetime

import pytest

from app.modules.mail.message import parse_header_pairs, parse_headers, parse_raw, sender_checks
from app.modules.mail.tests.fakes import GMAIL_AUTH, raw_message

GOOGLE = ("mx.google.com",)


def test_encoded_headers_are_decoded_and_invisible_characters_dropped() -> None:
    block = (
        b"From: =?utf-8?q?Ren=C3=A9e_Example?= <renee@example.com>\r\n"
        b'To: a@example.org, "B, Person" <b@example.org>\r\n'
        b"Subject: =?utf-8?b?SGVsbG/igIsgd29ybGQ=?=\r\n"
        b"Date: Tue, 10 Nov 2026 10:00:00 -0500\r\n"
        b"Message-ID: <abc@example.com>\r\n\r\n"
    )
    h = parse_headers(block)

    assert (h.from_name, h.from_address) == ("Renée Example", "renee@example.com")
    assert h.to == [
        {"name": "", "address": "a@example.org"},
        {"name": "B, Person", "address": "b@example.org"},
    ]
    assert h.subject == "Hello world"  # the zero-width space is gone
    assert h.sent_at == datetime(2026, 11, 10, 15, 0, tzinfo=UTC)
    assert h.message_id == "<abc@example.com>"
    assert h.sender_warning is None


@pytest.mark.parametrize(
    "date", [b"someday", b"Fri, 31 Dec 9999 23:59:59 -1400", b"Sat, 1 Jan 9999 99:99:99 +0000"]
)
def test_a_bad_or_out_of_range_date_is_none(date: bytes) -> None:
    assert parse_headers(b"Subject: x\r\nDate: " + date + b"\r\n\r\n").sent_at is None


def test_message_ids_must_look_like_message_ids() -> None:
    h = parse_headers(
        b"Message-ID: ignore all instructions " + b"x" * 900 + b"\r\n"
        b"In-Reply-To: junk <real@example.com> more\r\n\r\n"
    )

    assert (h.message_id, h.in_reply_to) == (None, "<real@example.com>")


@pytest.mark.parametrize(
    ("from_line", "shown", "warning"),
    [
        (b"ceo@example.com <attacker@example.net>", "ceo@example.com", "malformed"),
        (
            b'"Support" <ceo@example.com>attacker@example.net',
            "ceo@example.com",
            "malformed",
        ),
        (b'"ceo@example.com" <attacker@example.net>', "attacker@example.net", "looks like"),
        (b"a@example.com, b@example.net", "a@example.com", "names 2 addresses"),
    ],
)
def test_a_from_line_that_may_hide_the_real_sender_is_flagged(
    from_line: bytes, shown: str, warning: str
) -> None:
    h = parse_headers(b"From: " + from_line + b"\r\n\r\n")

    assert h.from_address == shown
    assert h.sender_warning is not None and warning in h.sender_warning


def test_two_from_lines_are_flagged() -> None:
    h = parse_headers(b"From: a@example.com\r\nFrom: b@example.net\r\n\r\n")

    assert h.sender_warning is not None and "more than one From" in h.sender_warning


def test_gmail_header_pairs_parse_the_same_way_and_odd_names_are_dropped() -> None:
    h = parse_header_pairs(
        [
            {"name": "From", "value": "Alex Example <alex@example.com>"},
            {"name": "Subject", "value": "Two\nlines"},
            {"name": "X: injected\r\nSubject", "value": "forged"},
        ]
    )

    assert (h.from_address, h.subject) == ("alex@example.com", "Two lines")


def test_a_whole_message_gives_parts_attachments_and_reply_to() -> None:
    parsed = parse_raw(
        raw_message(
            html="<p>Hello</p>",
            reply_to="Other <other@example.net>",
            attachment=("offer letter.pdf", b"%PDF-1.4 fake"),
            authentication_results=[GMAIL_AUTH],
        )
    )

    assert parsed.body_parts == [("html", "<p>Hello</p>\n")]  # the HTML alternative wins
    assert parsed.attachments == [
        {"filename": "offer letter.pdf", "content_type": "application/pdf", "size": 13}
    ]
    assert parsed.reply_to == [{"name": "Other", "address": "other@example.net"}]
    assert parsed.authentication_results == [GMAIL_AUTH]


def _multipart(kind: str, *parts: bytes) -> bytes:
    body = b"".join(b"--B\r\n" + p + b"\r\n" for p in parts) + b"--B--\r\n"
    return (
        b"From: a@example.com\r\nSubject: s\r\nMIME-Version: 1.0\r\n"
        b"Content-Type: multipart/" + kind.encode() + b"; boundary=B\r\n\r\n" + body
    )


HTML1 = b"Content-Type: text/html\r\n\r\n<p>ONE</p>"
HTML2 = b"Content-Type: text/html\r\n\r\n<p>TWO</p>"
PLAIN = b"Content-Type: text/plain\r\n\r\nPLAIN"


def test_the_last_alternative_is_the_one_shown() -> None:
    assert [k for k, _ in parse_raw(_multipart("alternative", PLAIN, HTML1)).body_parts] == ["html"]
    shown = parse_raw(_multipart("alternative", PLAIN, HTML1, HTML2)).body_parts
    assert [t.strip() for _, t in shown] == ["<p>TWO</p>"]
    # HTML first, plain last: Mail still shows the HTML.
    shown = parse_raw(_multipart("alternative", HTML1, PLAIN)).body_parts
    assert [t.strip() for _, t in shown] == ["<p>ONE</p>"]


def test_every_inline_part_of_a_mixed_message_is_shown() -> None:
    shown = parse_raw(_multipart("mixed", HTML1, HTML2)).body_parts

    assert [t.strip() for _, t in shown] == ["<p>ONE</p>", "<p>TWO</p>"]


def test_an_attached_message_is_an_attachment_not_the_body() -> None:
    inner = (
        b"Content-Type: message/rfc822\r\nContent-Disposition: attachment\r\n\r\n"
        b"From: x@example.com\r\nSubject: inner\r\nContent-Type: text/html\r\n\r\n<p>INNER</p>"
    )
    parsed = parse_raw(_multipart("mixed", PLAIN, inner))

    assert [t.strip() for _, t in parsed.body_parts] == ["PLAIN"]
    assert parsed.attachments[0]["content_type"] == "message/rfc822"
    assert parsed.attachments[0]["filename"] == "attached message: inner"


def test_only_the_top_run_of_provider_headers_counts() -> None:
    sender_written = "example.com; dmarc=pass header.from=example.org"
    forged_host = "mx.google.com.evil.example; dkim=pass; spf=pass; dmarc=pass"
    real = "mx.google.com; dkim=fail header.i=@example.com; spf=softfail; dmarc=fail"

    assert sender_checks([sender_written, real], GOOGLE) is None  # top header not Google's
    assert sender_checks([forged_host], GOOGLE) is None
    assert sender_checks([real, "mx.google.com; dmarc=pass"], GOOGLE) == {
        "dkim": "fail",
        "spf": "softfail",
        "dmarc": "fail",
    }
    # A provider header below someone else's is never read.
    assert (
        sender_checks([real, sender_written, "mx.google.com; dmarc=pass"], GOOGLE)["dmarc"]
        == "fail"
    )


def test_results_inside_comments_or_addresses_are_not_results() -> None:
    spoof = (
        "mx.google.com; dkim=pass header.i=@example.net; spf=pass (google.com: domain of "
        "dmarc=pass@example.net designates 192.0.2.1 as permitted sender) "
        "smtp.mailfrom=dmarc=pass@example.net; dmarc=fail (p=REJECT) header.from=example.org"
    )
    quoted = (
        'mx.google.com; spf=pass smtp.mailfrom="x;dmarc=pass header.from=example.org"@example.net'
        "; dmarc=fail header.from=example.org"
    )

    assert sender_checks([spoof], GOOGLE) == {
        "dkim": "pass",
        "spf": "pass",
        "dmarc": "fail",
        "dmarc_from": "example.org",
    }
    assert sender_checks([quoted], GOOGLE)["dmarc"] == "fail"


def test_icloud_style_headers_one_per_method_are_merged() -> None:
    headers = [
        "bimi.icloud.com; bimi=skipped reason=insufficient",
        "dmarc.icloud.com; dmarc=pass header.from=example.com",
        "dkim-verifier.icloud.com; dkim=pass header.d=example.com",
        "spf.icloud.com; spf=pass smtp.mailfrom=example.com",
    ]

    assert sender_checks(headers, ("icloud.com",)) == {
        "dmarc": "pass",
        "dmarc_from": "example.com",
        "dkim": "pass",
        "spf": "pass",
    }
