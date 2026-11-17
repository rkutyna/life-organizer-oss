"""Parsing mail: header fields for the mirror, and a whole message for a read.

Both providers end here. IMAP hands over header bytes and raw RFC 822 bytes; the Gmail API's
metadata comes as name/value pairs (rebuilt into a header block) and its full message as raw
bytes too, so one parser serves both and they cannot drift.

Parsing never raises on a bad message: one malformed email must not stop the mirror. What is
odd about the sender (a malformed From, two addresses, an address posing as a display name) is
kept as `sender_warning` so a reader sees it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import UTC, datetime
from email import message_from_bytes, policy
from email.errors import ObsoleteHeaderDefect
from email.message import EmailMessage, Message
from email.parser import BytesHeaderParser
from email.utils import getaddresses, parsedate_to_datetime

from app.modules.mail.sanitize import (
    MAX_ADDRESS,
    MAX_ATTACHMENTS,
    MAX_FILENAME,
    MAX_NAME,
    MAX_RECIPIENTS,
    MAX_SUBJECT,
    clean_header,
)

HEADER_FIELDS = ("From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To")
_MESSAGE_ID = re.compile(r"<[^<>\s]{1,250}>")
MAX_DEPTH = 20


@dataclass(frozen=True)
class HeaderFields:
    from_name: str
    from_address: str
    to: list[dict[str, str]]
    cc: list[dict[str, str]]
    subject: str
    sent_at: datetime | None
    message_id: str | None
    in_reply_to: str | None
    sender_warning: str | None = None


UNREADABLE = HeaderFields("", "", [], [], "", None, None, None, "The headers could not be read.")


@dataclass
class ParsedMessage:
    headers: HeaderFields
    reply_to: list[dict[str, str]]
    # The parts a mail app would display, in order: ("html" | "plain", text).
    body_parts: list[tuple[str, str]]
    attachments: list[dict[str, object]] = field(default_factory=list)
    # The values of every Authentication-Results header, topmost (the receiving server's) first.
    authentication_results: list[str] = field(default_factory=list)


def _header_text(msg: Message, name: str) -> str:
    try:
        value = msg.get(name)
        return str(value) if value is not None else ""
    except Exception:  # a header so malformed the policy cannot parse it: treat it as absent
        return ""


def _addresses(msg: Message, name: str) -> list[dict[str, str]]:
    raw = _header_text(msg, name)
    if not raw:
        return []
    out = []
    for display, address in getaddresses([raw])[:MAX_RECIPIENTS]:
        if not (display or address):
            continue
        out.append(
            {"name": clean_header(display, MAX_NAME), "address": clean_header(address, MAX_ADDRESS)}
        )
    return out


def _date(msg: Message) -> datetime | None:
    raw = _header_text(msg, "Date")
    if not raw:
        return None
    try:
        parsed = parsedate_to_datetime(raw)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC)
    except Exception:  # unparseable, or out of range (year 9999 at -1400 overflows)
        return None


def _message_id(value: str) -> str | None:
    match = _MESSAGE_ID.search(clean_header(value, 1000))
    return match.group(0) if match else None


def _sender_warning(msg: Message) -> str | None:
    """What about the From line could make the sender shown not the real one."""
    try:
        values = msg.get_all("From") or []
        if not values:
            return "The message has no From line."
        if len(values) > 1:
            return "The message has more than one From line: the sender shown may not be real."
        header = values[0]
        defects = [
            d for d in getattr(header, "defects", ()) if not isinstance(d, ObsoleteHeaderDefect)
        ]
        addresses = list(getattr(header, "addresses", ()))
    except Exception:
        return "The From line could not be read: the sender shown may not be real."
    if defects:
        return (
            f"The From line is malformed ({clean_header(str(header), 200)}): the address shown "
            "may not be the real sender."
        )
    if len(addresses) != 1:
        return f"The From line names {len(addresses)} addresses: the sender shown may not be real."
    name = addresses[0].display_name or ""
    if "@" in name:
        return (
            f"The sender's display name looks like an address ({clean_header(name, 100)}); "
            f"the real address is {clean_header(addresses[0].addr_spec, 100)}."
        )
    return None


def header_fields(msg: Message) -> HeaderFields:
    try:
        sender = _addresses(msg, "From")
        first = sender[0] if sender else {"name": "", "address": ""}
        return HeaderFields(
            from_name=first["name"],
            from_address=first["address"],
            to=_addresses(msg, "To"),
            cc=_addresses(msg, "Cc"),
            subject=clean_header(_header_text(msg, "Subject"), MAX_SUBJECT),
            sent_at=_date(msg),
            message_id=_message_id(_header_text(msg, "Message-ID")),
            in_reply_to=_message_id(_header_text(msg, "In-Reply-To")),
            sender_warning=_sender_warning(msg),
        )
    except Exception:
        return UNREADABLE


def parse_headers(header_bytes: bytes) -> HeaderFields:
    """Header fields from a header block (IMAP's BODY.PEEK[HEADER.FIELDS (...)])."""
    try:
        msg = BytesHeaderParser(policy=policy.default).parsebytes(header_bytes)
    except Exception:
        return UNREADABLE
    return header_fields(msg)


_HEADER_NAME = re.compile(r"^[A-Za-z0-9-]{1,76}$")


def parse_header_pairs(pairs: list[dict[str, str]]) -> HeaderFields:
    """Header fields from the Gmail API's [{name, value}] list."""
    block = "".join(
        f"{p['name']}: {' '.join(str(p.get('value', '')).splitlines())}\r\n"
        for p in pairs
        if _HEADER_NAME.match(str(p.get("name", "")))
    )
    return parse_headers(block.encode("utf-8", errors="replace"))


# --- The body a mail app shows, and the attachments ------------------------------------------


def _part_text(part: Message) -> str:
    try:
        content = part.get_content()  # type: ignore[attr-defined]
    except Exception:
        payload = part.get_payload(decode=True) or b""
        content = payload.decode("utf-8", errors="replace")  # type: ignore[union-attr]
    return content if isinstance(content, str) else ""


def _is_attachment(part: Message) -> bool:
    disposition = part.get_content_disposition()
    if disposition == "attachment":
        return True
    if part.get_filename() and disposition != "inline":
        return True
    return not part.get_content_type().startswith("text/")


def _children(part: Message) -> list[Message]:
    payload = part.get_payload()
    return [p for p in payload if isinstance(p, Message)] if isinstance(payload, list) else []


def _displayed(part: Message, depth: int = 0) -> list[tuple[str, str]]:
    """The parts a mail app shows. In multipart/alternative the last part it can render is the
    preferred one (RFC 2046), HTML over plain; other multiparts show every inline text part in
    order. An attached message (message/rfc822) is an attachment, never the body."""
    if depth > MAX_DEPTH:
        return []
    content_type = part.get_content_type()
    if content_type == "message/rfc822":
        return []
    if part.is_multipart():
        children = _children(part)
        if content_type == "multipart/alternative":
            shown = [_displayed(c, depth + 1) for c in children]
            for parts in reversed(shown):
                if any(kind == "html" for kind, _ in parts):
                    return parts
            for parts in reversed(shown):
                if parts:
                    return parts
            return []
        out: list[tuple[str, str]] = []
        for child in children:
            out += _displayed(child, depth + 1)
        return out
    if _is_attachment(part):
        return []
    if content_type == "text/html":
        return [("html", _part_text(part))]
    if content_type == "text/plain":
        return [("plain", _part_text(part))]
    return []


def _attachments(part: Message, out: list[dict[str, object]], depth: int = 0) -> None:
    if depth > MAX_DEPTH or len(out) >= MAX_ATTACHMENTS:
        return
    content_type = part.get_content_type()
    if content_type == "message/rfc822":
        inner = _children(part)
        subject = _header_text(inner[0], "Subject") if inner else ""
        out.append(
            {
                "filename": clean_header(
                    part.get_filename() or f"attached message: {subject}", MAX_FILENAME
                ),
                "content_type": "message/rfc822",
                "size": len(inner[0].as_bytes()) if inner else 0,
            }
        )
        return
    if part.is_multipart():
        for child in _children(part):
            _attachments(child, out, depth + 1)
        return
    if _is_attachment(part) and (part.get_filename() or part.get_content_disposition()):
        payload = part.get_payload(decode=True) or b""
        out.append(
            {
                "filename": clean_header(part.get_filename() or "", MAX_FILENAME),
                "content_type": clean_header(content_type, 100),
                "size": len(payload),  # type: ignore[arg-type]
            }
        )


def parse_raw(raw: bytes) -> ParsedMessage:
    """A whole message: headers, the parts a mail app would display, and its attachments' names,
    types and sizes (attachments themselves are never returned)."""
    msg: EmailMessage = message_from_bytes(raw, policy=policy.default)  # type: ignore[assignment]
    attachments: list[dict[str, object]] = []
    try:
        body_parts = _displayed(msg)
        _attachments(msg, attachments)
    except Exception:
        body_parts = []
    try:
        results = [str(v).strip() for v in (msg.get_all("Authentication-Results") or [])]
    except Exception:
        results = []
    return ParsedMessage(
        headers=header_fields(msg),
        reply_to=_addresses(msg, "Reply-To"),
        body_parts=body_parts,
        attachments=attachments,
        authentication_results=results,
    )


# --- Sender authentication --------------------------------------------------------------------

_RESULT = re.compile(r"^([a-z0-9-]+)(?:/[0-9]+)?\s*=\s*([a-z]+)\b(.*)$", re.IGNORECASE | re.DOTALL)
_PROPERTY = re.compile(r"\b([a-z]+\.[a-z0-9-]+)\s*=\s*(\"[^\"]*\"|[^\s;]+)", re.IGNORECASE)


def _clauses(value: str) -> list[str]:
    """An Authentication-Results value split on `;` outside quoted strings, with (comments)
    removed, as RFC 8601 reads it. Text in a comment or a quoted string can never start a
    clause, so a sender who picks an envelope address like "dmarc=pass@..." adds no result."""
    clauses: list[str] = []
    buf: list[str] = []
    depth = 0
    quoted = escaped = False
    for ch in value:
        if escaped:
            escaped = False
            if depth == 0:
                buf.append(ch)
            continue
        if ch == "\\" and (quoted or depth):
            escaped = True
            if quoted and depth == 0:
                buf.append(ch)
            continue
        if depth:
            depth += {"(": 1, ")": -1}.get(ch, 0)
            continue
        if quoted:
            buf.append(ch)
            quoted = ch != '"'
            continue
        if ch == "(":
            depth = 1
            buf.append(" ")
        elif ch == '"':
            quoted = True
            buf.append(ch)
        elif ch == ";":
            clauses.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    clauses.append("".join(buf).strip())
    return clauses


def _authserv(clauses: list[str]) -> str:
    first = clauses[0].split() if clauses and clauses[0] else []
    return first[0].lower() if first else ""


def _trusted(server: str, trusted_servers: tuple[str, ...]) -> bool:
    return any(server == t or server.endswith("." + t) for t in trusted_servers)


def sender_checks(results: list[str], trusted_servers: tuple[str, ...]) -> dict[str, str] | None:
    """SPF, DKIM and DMARC as the receiving mail server recorded them, plus the domain DMARC
    checked (`dmarc_from`, its header.from).

    Only the run of Authentication-Results headers at the top of the message whose authserv-id
    is one of the provider's own servers counts. The receiving server adds its headers above
    everything the sender wrote, so the first header from anyone else ends the run: one the
    sender put in the message is never read. Each method's result is the first clause that
    starts with it; text in comments and quoted strings is ignored. None when the top header is
    not the provider's or names no result.
    """
    checks: dict[str, str] = {}
    for value in results:
        clauses = _clauses(value)
        if not _trusted(_authserv(clauses), trusted_servers):
            break
        for clause in clauses[1:]:
            match = _RESULT.match(clause)
            if not match:
                continue
            method, result, rest = match.group(1).lower(), match.group(2).lower(), match.group(3)
            if method not in ("spf", "dkim", "dmarc") or method in checks:
                continue
            checks[method] = result
            if method == "dmarc":
                for name, prop in _PROPERTY.findall(rest):
                    if name.lower() == "header.from":
                        checks["dmarc_from"] = prop.strip('"').lower()
    return checks or None
