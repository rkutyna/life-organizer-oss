# Security

## Reporting a problem

Please report vulnerabilities privately through GitHub's **Report a vulnerability** button
(Security → Advisories on this repository), not in a public issue. Include what you found, how
to reproduce it, and which version you ran. You should get a reply within a week.

## What this app protects, and how

The organizer is self-hosted and has **one user per install**. It holds credentials for your
mail and calendar accounts and a record of your job search, so it is built so that a careless
exposure isn't an immediate disaster.

**Every API route needs authentication.** The only exceptions are:
- the health check;
- first-run setup, which works only until it has run once;
- sign-in;
- the two static pick lists that setup needs;
- Google's OAuth redirect.

A test fails if any other route answers without credentials.

**Browser sessions:**
- The password is hashed with argon2.
- The session cookie is random, HttpOnly and `SameSite=Strict`; only its SHA-256 is stored.
- The cookie is `Secure` over HTTPS, and sessions expire after 30 days unused.
- Cookie-authenticated writes also need an `X-Requested-With` header, which other sites cannot
  send without a CORS preflight this server never grants.
- Failed sign-ins are throttled. After 5 failures in 15 minutes, that address must wait; the
  address is the one your reverse proxy appended to X-Forwarded-For, which a client cannot
  choose. After 30 failures in an hour from anywhere, every attempt is slowed down, but a
  correct password is never refused, so nobody can lock you out by failing on purpose.

**API tokens** (MCP server, Mac helper, scripts):
- Each token is stored only as a hash and can be revoked.
- A token's author is fixed when it is made, so a client cannot write in someone else's name.
  Every write is logged with its author and can be reverted.
- Scopes keep clients apart:
  - `api` for the organizer;
  - `ingest` for the Mac helper only;
  - `mail`, which no other scope includes.
- No token can create tokens, change the password, or manage accounts; only a signed-in browser
  can.

**Connected accounts:**
- Passwords and OAuth tokens are encrypted at rest with a key derived from
  `ORGANIZER_SECRET_KEY`. The key lives in the environment, never in the database, so a copy of
  the database alone holds no usable credentials. The key must be at least 32 characters, but
  its strength is up to you; make it with `openssl rand -base64 32`.
- IMAP and CalDAV servers' TLS certificates are verified, so an impostor on the network never
  receives a password. CalDAV over plain `http://` is refused except for a server on the same
  machine.
- The Google sign-in uses PKCE and a single-use, short-lived state. Removing a Google account
  also asks Google to revoke the grant.
- Calendar and Gmail access is read-only. Google Tasks needs write access, because reminders
  sync both ways, and is requested only when you tick it.

**Mail is treated as hostile:**
- Mailboxes are opened read-only (IMAP `EXAMINE` and `BODY.PEEK`, Gmail's read-only scope), and
  no code path can send, delete, move or flag mail. Tests check the source for such calls.
- Message bodies are fetched when opened and never stored.
- HTML is sanitized, and hidden or invisible text is removed and counted.
- Sender authentication results are shown, and every message is marked untrusted.
- The MCP server serves mail tools only when asked to, and a server that serves them refuses to
  also serve any tool that writes. Run mail as its own MCP server with its own `mail` token
  (docs/MCP.md). The isolation is per server, not per conversation: a Claude session that has
  both the mail server and the read-write server connected can still be steered by an email
  into using the other one. Connect the mail server only to sessions that need it.

**Reminders and the Mac helper:**
- The helper's token has the `ingest` scope only. What the Mac reports can't touch Google
  reminders or any record the organizer owns.
- Every change waits in a queue until it is applied. Each queued change records exactly which
  reminder it targets, and reminder ids are never reused, so a retried change can never land on
  a different reminder.
- Changes can't be re-applied by undoing them in History.
- The helper refuses a plain `http://` server address unless the server is on the same Mac (or
  you opt in explicitly). It also refuses to run with a config file that other users can write,
  and warns when one that holds a token is readable by them.
- What the helper sends is size-checked.

**The job tracker:**
- CSV imports are capped at 5 MB, 10,000 rows and 500 columns, with per-field length limits.
- An import's undo leaves alone anything you changed afterwards.
- Edits that would make an application's status disagree with its history are refused.

**The web app** is served with a Content-Security-Policy that allows scripts only from the app
itself, and it cannot be framed. The API's documentation pages (`/docs`, `/openapi.json`) are
off unless `EXPOSE_API_DOCS=true`.

**The container:**
- It runs as a non-root user.
- The port is published on the host's loopback only. Reach it through Tailscale, a Cloudflare
  Tunnel with Access, or another HTTPS proxy (docs/SETUP.md).

## What it does not protect against

- **Anyone with control of the host.** They can read the database and the environment, and
  therefore your credentials. Keep the host patched and its disk encrypted.
- **A stolen `ORGANIZER_SECRET_KEY` together with a database copy.** Store backups of the two
  apart.
- **Exposure without HTTPS.** Running on a plain public port without HTTPS sends the session
  cookie in the clear. Don't do that.
- **An install exposed before setup.** Until setup has run, whoever reaches the page first
  chooses the password. Finish setup locally before adding a proxy or tunnel.
- **A distributed password guesser.** The throttle slows one; your password's strength is what
  stops one. Prefer Tailscale or Cloudflare Access, which keep strangers from reaching the
  sign-in page at all.
- **Mail content shown to you or to Claude.** It is still written by strangers. The organizer
  marks it untrusted; deciding what to do with it is yours.
- **One owner per install.** There is no multi-user isolation, and every signed-in browser has
  full access.
