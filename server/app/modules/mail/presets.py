"""IMAP presets: the host, port and trusted receiving servers of common providers.

`auth_servers` are the authserv-ids whose Authentication-Results headers can be believed: the
provider's own receiving servers, which add their header above everything the sender wrote
(message.sender_checks). A custom host has none unless the owner enters them, and then sender
checks read as unknown rather than trusting a header the sender may have written.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ImapPreset:
    key: str
    label: str
    host: str
    port: int
    auth_servers: tuple[str, ...]
    help: str


IMAP_PRESETS: dict[str, ImapPreset] = {
    p.key: p
    for p in (
        ImapPreset(
            key="icloud",
            label="iCloud Mail",
            host="imap.mail.me.com",
            port=993,
            auth_servers=("icloud.com", "me.com", "apple.com"),
            help=(
                "Use your full iCloud address and an app-specific password made at "
                "account.apple.com (Sign-In and Security, App-Specific Passwords), not your "
                "Apple Account password."
            ),
        ),
        ImapPreset(
            key="fastmail",
            label="Fastmail",
            host="imap.fastmail.com",
            port=993,
            auth_servers=("messagingengine.com",),
            help=(
                "Use your Fastmail address and an app password with IMAP access, made in "
                "Settings, Privacy & Security, App passwords. A read-only one is enough."
            ),
        ),
        ImapPreset(
            key="outlook",
            label="Outlook.com",
            host="outlook.office365.com",
            port=993,
            auth_servers=("outlook.com", "protection.outlook.com"),
            help=(
                "Use your Microsoft address and an app password. Microsoft has been turning off "
                "password sign-in for IMAP, so this may be refused; if it is, the account "
                "cannot be read this way."
            ),
        ),
    )
}
CUSTOM = "custom"
