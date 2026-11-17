"""Mail: read-only mirrors of the owner's connected mailboxes (docs/MAIL.md).

Any IMAP account (iCloud, Fastmail and Outlook presets, or a custom host) and any Google account
that granted Gmail. The server keeps the headers of the last MAIL_WINDOW_DAYS of Inbox and Sent
for each account (sync.py, every 15 minutes) and fetches a message's body live when one is asked
for (router.py). Bodies are never stored. Nothing here can send, move, flag or delete mail: the
IMAP side opens mailboxes with EXAMINE and fetches with BODY.PEEK (imap.py), and the Gmail side
uses a gmail.readonly grant and only makes GET requests (gmail.py).

All mail text is written by whoever sent it. Every response is marked `untrusted`, and the body
is cleaned (sanitize.py) of the hidden text and invisible characters that prompt injection
hides in.
"""
