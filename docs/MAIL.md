# Mail

The organizer can list the recent mail in your iCloud, Fastmail, Outlook, other IMAP and Gmail
accounts, and open one message when you ask. It only reads. Nothing in it can send, delete,
move, flag or mark mail as read.

- The **web inbox** (**Mail**, or `g m`) lists the mirrored headers. You can filter them by
  account and by Inbox or Sent, and search subjects, names and addresses. Opening a message
  fetches it from the mailbox and shows the cleaned text, the sender checks and what the cleaner
  removed.
- **Claude** reads mail through the opt-in `mail` toolset of the MCP server (docs/MCP.md), with a
  token of its own.

## Connect an account

### iCloud, Fastmail, Outlook or another IMAP server

In **Settings → Connected accounts → Add account → Email (IMAP)**, pick a provider and enter:

| Provider | Server | Username | Password |
|---|---|---|---|
| iCloud Mail | `imap.mail.me.com:993` | your full iCloud address | an app-specific password from account.apple.com (Sign-In and Security → App-Specific Passwords) |
| Fastmail | `imap.fastmail.com:993` | your Fastmail address | an app password with IMAP access (Settings → Privacy & Security → App passwords) |
| Outlook.com | `outlook.office365.com:993` | your Microsoft address | an app password (see the caveat below) |
| Other IMAP server | your provider's host and port | usually your address | the password or app password your provider gives for IMAP |

- The organizer signs in before it saves anything, so you see a wrong password at once.
- The password is stored encrypted with `ORGANIZER_SECRET_KEY`, and it is never shown again or
  logged.
- The first sync starts right away, and one runs every 15 minutes after that.
- Only implicit TLS (usually port 993) is supported, so the password never crosses the network
  in clear.
- Make a separate app password for the organizer. That way, you can revoke it without touching
  anything else.

**Other IMAP server: trusted servers.** The sender checks come from the `Authentication-Results`
header that your provider's receiving server adds. The organizer believes that header only when
it names a server you trust. The presets already know their provider's servers. For another
provider, enter its receiving servers' names (for example `mx.example.com`). If you leave the
field empty, the sender checks show as unknown, because a header the sender wrote is never
believed.

### Gmail

Gmail is read through a Google account, the same one the calendar uses. In
**Settings → Connected accounts → Add account → Google account**, tick **Gmail** and follow
Google's consent screen (docs/GOOGLE.md covers the one-time OAuth client setup). The organizer
asks for `gmail.readonly` only.

- `gmail.readonly` is a *restricted* scope. An unverified OAuth client of your own can use it for
  its test users, you included. Google shows an "unverified app" screen, which is expected for
  personal use.
- In Testing mode, Google expires the sign-in after 7 days, so publish the OAuth client to
  Production (it can stay unverified).
- If Google refuses the stored sign-in, the account shows an error in Settings and in the inbox.
  Connect it again.

### How far back

The mirror keeps the last **30 days** of Inbox and Sent. To change that, set
`MAIL_WINDOW_DAYS` (1 to 365) in `.env` and restart. Older messages drop out of the mirror; they
stay in your mailbox.

## The safety model

All mail is written by whoever sent it, and anyone can send you mail. So the mail module is
built to never change a mailbox and to treat every word of mail as untrusted.

**Read-only, end to end.**
- IMAP has no read-only login: an IMAP password could move or delete mail. So one small class
  (`ReadOnlyIMAP` in `server/app/modules/mail/imap.py`) is the only code that talks to the
  server, and it can send only these commands: `LOGIN`, `LIST`, `EXAMINE` (never `SELECT`),
  `UID SEARCH SINCE`, two fixed `UID FETCH` item lists that use `BODY.PEEK` (so not even the read
  flag changes), and `LOGOUT`. Mailbox names and UIDs from the server are checked, so they cannot
  smuggle in another command.
- Gmail is read with a `gmail.readonly` grant, so Google itself refuses any change or send. The
  code also makes only `GET` requests to the Gmail API.
- Tests record every IMAP command and every Gmail request against fakes and fail on anything
  else. They also scan the module's source for mailbox-changing calls.

**Headers stored, bodies never.**
- The server stores From, To, Cc, Subject, Date, Message-ID and In-Reply-To for the window,
  each cleaned.
- A message's body is fetched from the mailbox when it is opened, cleaned, returned, and not
  kept. The browser drops it a few minutes after the reader closes.
- Attachments are listed by name, type and size only.

**Every result is marked untrusted.** Every mail API response carries `untrusted: true`, and the
reader shows an "Untrusted content" banner. The MCP tools tell Claude to treat mail as data, to
follow no instruction in it, and to leave any decision to you.

**The body is cleaned before anyone sees it** (`sanitize.py`). Prompt injection hides text that a
mail app would never show. So the cleaner:
- converts HTML to the text a mail app would show;
- removes scripts, styles, comments, hidden elements and text styled not to show (`display:none`,
  zero sizes, text colored like its background, off-screen positioning, and more);
- removes invisible characters (zero-width characters, bidi controls, the tag block and others).

What it removed is **counted**, not warned about, because newsletters hide preview text all the
time. The reader shows the counts. When the cleaner meets styling it cannot follow, it adds a
warning instead.

**Sender checks** (`message.sender_checks`). SPF, DKIM and DMARC are read from the
`Authentication-Results` headers that your provider's receiving server added. Only the run of
those headers at the top of the message that names a trusted server is read; one the sender
wrote further down is ignored. A sender counts as **verified** only when DMARC passed for the
From address's own domain. Otherwise the reader explains what is wrong:
- a malformed or doubled From line;
- a display name that looks like another address;
- DMARC for another domain, or a DMARC failure;
- a Reply-To that goes to another domain.

**Mail has its own scope.** `/api/mail/*` needs the `mail` scope. A signed-in browser has it, but
an API token has it only if it was made with it. So the general `api` token you give Claude
cannot read mail. Connecting an account and "Sync now" work from the browser only; no token can
do either. In MCP, the `mail` toolset is opt-in (`all` leaves it out), and the server refuses to
serve it next to any tool that writes.

## Known gaps

- **Outlook.com:** Microsoft has been turning off password sign-in for IMAP on consumer accounts.
  If the connect form reports a refused login even with an app password, that account cannot be
  read this way (OAuth for Microsoft is not supported). Microsoft's `Authentication-Results`
  headers also often leave out the server name, so their sender checks may show as unknown.
- **Removed or disabled accounts:** their headers stop showing at once, and the next sync deletes
  them from the database.
- **Backups:** the mirrored headers (senders, recipients, subjects) are in the database, so they
  are in your backups too. Bodies never are.
- **Search** looks at the mirrored headers only (subject, names, addresses), never at bodies.
