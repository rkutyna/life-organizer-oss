# Installing Life Organizer for Mac with an AI agent

**This runbook is written for an AI coding agent** (such as Claude Code) that is setting up the
organizer with its owner sitting beside it. A person can follow it too; the other guides
([SETUP.md](SETUP.md), [CLOUDFLARE.md](CLOUDFLARE.md), [REMOTE-CONNECTOR.md](REMOTE-CONNECTOR.md))
are the same material written for people.

Each step gives the goal, who does it, the commands, how to check it worked, and what to do
when it doesn't. Work through the steps in order, and stop at every decision point to ask.

## Rules for the agent

1. **Never do a HUMAN step.** They are marked **[HUMAN]**. Explain what to do, then wait until
   the human says it is done. Why: these steps put a secret or a consent in play, and anything
   you type or read lands in your transcript, which is sent to your model provider and may be
   stored or logged. The organizer's whole security model assumes those secrets stay with the
   owner. Specifically:
   - **The organizer's password.** The human chooses and types it in the browser. Never
     suggest, generate, store or type it.
   - **Any other password, app-specific password, or OAuth consent screen** (iCloud, IMAP,
     Google, Cloudflare, Claude). Only the owner may grant access to their accounts.
   - **API token secrets, Cloudflare service token secrets and the tunnel token.** The human
     copies them from the screen and pastes them into `.env`, an app's settings or a terminal
     themselves. Never ask for them in chat.
   - **Cloudflare and Claude dashboard clicks.** They need the human's login, and some of them
     (an Access policy, a WAF rule) decide who can reach the owner's data.
2. **Never print a secret.** Don't `cat .env`, don't run `docker compose config` without
   `--services` or `--no-interpolate` (it prints every resolved secret), don't `docker inspect`
   the containers, and don't echo tokens. To check that a value is set, test it without
   showing it, as the commands below do.
3. **Ask at every [ASK].** Those are decisions for the human; don't pick for them.
4. **Don't expose the organizer before step 5 is done.** Until the human has finished setup,
   whoever opens the page first chooses the password.
5. **Report, don't work around.** If a step fails in a way this runbook doesn't cover, tell the
   human what you saw. Don't edit the code, the compose file or a Cloudflare setting to get past
   it.
6. **Leave the user's other things alone.** Don't stop or remove Docker containers, images or
   volumes that aren't this project's, and don't change system settings.

## Decision points (ask these)

| When | Question for the human |
|---|---|
| Before step 2 | Where should the repo live? (default: `~/life-organizer`) |
| Step 5 | Time zone and holiday country (they choose them in the browser) |
| Step 6 | How to reach it from other devices: **Tailscale** (simplest, private), **Cloudflare** (a public hostname behind Cloudflare Access), or neither for now? |
| Step 6, 10 | If Cloudflare: which domain on Cloudflare, and which hostnames? (e.g. `organizer.example.com`, `organizer-mcp.example.com`) Which email will they sign in to Cloudflare Access with? |
| Step 7 | Do they want Google (Calendar, Gmail, Tasks)? |
| Step 8 | Which accounts to connect: iCloud calendar, other CalDAV, IMAP mail (iCloud, Fastmail, Outlook, other), Google |
| Step 9 | Claude Code access? With mail too? |
| Step 10 | The claude.ai connector? With a separate mail connector? |
| Step 11, 12 | The Mac app? The Mac helper (needed for Apple Reminders)? |
| Step 13 | Where should backups go? |

---

## Step 1. Prerequisites

**Goal:** the machine has what the install needs. **Who:** agent.

```bash
docker --version && docker compose version && docker info --format '{{.ServerVersion}}'
git --version
openssl version
lsof -nP -iTCP:8600 -sTCP:LISTEN || echo "port 8600 free"
```

**Expect:** a Docker version, `Docker Compose version v2...`, a server version (the daemon is
running), git and openssl versions, and `port 8600 free`.

Only for later, optional steps:

```bash
uv --version            # step 9, Claude Code over stdio
claude --version        # step 9
xcodebuild -version     # steps 11 and 12 (Mac app, Mac helper); or: swift --version
tailscale version       # step 6, if Tailscale is chosen
```

**If it fails:**
- No Docker, or `docker info` errors: **[HUMAN]** installs and starts Docker Desktop (or
  OrbStack, or Docker Engine on Linux). Installing software is the owner's call.
- Port 8600 is taken: set `ORGANIZER_PORT` to a free port in step 3, and use that port wherever
  this runbook says 8600.
- No `uv`: it is only needed for step 9 (https://docs.astral.sh/uv/). Ask before installing it.

## Step 2. Clone

**Goal:** a checkout of the repo. **Who:** agent. **[ASK]** where it should live.

If the human already cloned it and you are running inside it, skip to step 3.

```bash
git clone <repo URL> ~/life-organizer && cd ~/life-organizer
```

**Verify:** `ls docker-compose.yml .env.example docs/INSTALL-WITH-CLAUDE.md` lists all three.

## Step 3. `.env` with a generated secret

**Goal:** a `.env` with a strong `ORGANIZER_SECRET_KEY`, generated without ever printing it.
**Who:** agent, then **[HUMAN]** saves the key.

```bash
test -e .env && echo "STOP: .env exists" || {
  KEY="$(openssl rand -base64 32)" awk 'BEGIN { k = ENVIRON["KEY"] }
    /^ORGANIZER_SECRET_KEY=/ { print "ORGANIZER_SECRET_KEY=" k; next } { print }' \
    .env.example > .env && chmod 600 .env
}
```

**Verify** (shows only whether it is set):

```bash
grep -cE '^ORGANIZER_SECRET_KEY=.{40,}$' .env      # expect: 1
ls -l .env                                          # expect: -rw-------
```

If `ORGANIZER_PORT` must change (step 1), edit that line now.

**[HUMAN]** open `.env` in an editor and save the `ORGANIZER_SECRET_KEY` value in a password
manager. It encrypts the passwords and tokens of the accounts they connect: lose it and they
reconnect every account; leak it together with a database copy and those credentials can be
read. The agent doesn't display it, so it stays out of the transcript.

**If it fails:** `STOP: .env exists` means an earlier attempt or a previous install. Ask the
human before touching it; it may hold a key that existing data needs.

## Step 4. Start it

**Goal:** the organizer running on `127.0.0.1:8600`. **Who:** agent.

```bash
docker compose up -d --build
```

The first build takes a few minutes (it builds the web app too).

**Verify:**

```bash
docker compose ps --format '{{.Service}} {{.Status}}'   # expect: organizer Up ... (healthy)
curl -s http://localhost:8600/api/health                 # expect: {"ok":true}
curl -s http://localhost:8600/api/auth/state             # expect: {"setup_required":true,...}
```

`healthy` can take up to a minute to appear; `/api/health` answers as soon as the server is up.

**If it fails:**
- `set ORGANIZER_SECRET_KEY in .env`: step 3 didn't write the key; redo it.
- `port is already allocated`: change `ORGANIZER_PORT` in `.env`, then `docker compose up -d`.
- The container restarts: `docker compose logs --tail 50 organizer` and report what it says.
- `setup_required` is `false` on a fresh install: someone already ran setup on this database.
  Ask the human.

## Step 5. First-run setup in the browser [HUMAN]

**Goal:** the owner's account exists. **[HUMAN]**, on this machine, before any exposure.

Ask the human to open **http://localhost:8600** on this machine and fill in:
- their name;
- **a password they choose** (10 characters or more). Not you: never propose one;
- their time zone and holiday country.

**Verify:** `curl -s http://localhost:8600/api/auth/state` now shows `"setup_required":false`.

Do not continue to step 6 until it does.

## Step 6. Remote access: Tailscale or Cloudflare

**Goal:** the web app reachable from the owner's other devices over HTTPS. **[ASK]**
Tailscale, Cloudflare, or neither for now.

| | Tailscale | Cloudflare |
|---|---|---|
| Who can reach it | Only the owner's devices, signed in to their tailnet | Any browser, after Cloudflare Access lets only the owner's email in |
| Needs | A free Tailscale account, the app on each device | A domain on Cloudflare, a free Zero Trust organization |
| Mac app, Mac helper, Claude Code on other machines | Work over the tailnet address | Each needs a Cloudflare Access service token (CLOUDFLARE.md step 5), or runs on this machine with localhost |
| claude.ai connector (step 10) | Not possible over Tailscale alone | Same tunnel |

Recommend Tailscale for the devices. Cloudflare is needed anyway for step 10; the two mix
well (Tailscale for devices, Cloudflare only for the connector).

### 6a. Tailscale

1. **[HUMAN]** install Tailscale on this machine and their phone and computers, and sign in
   (https://tailscale.com/download). Signing in is a login: the human does it.
2. Agent, on this machine:

   ```bash
   tailscale serve --bg 8600
   tailscale serve status
   ```

   `serve status` shows `https://<machine>.<tailnet>.ts.net` proxying to
   `http://127.0.0.1:8600`. If Tailscale asks to enable HTTPS certificates for the tailnet, that
   is a setting in the human's Tailscale admin console: **[HUMAN]** approves it.
3. Agent, in `.env`: set `PUBLIC_BASE_URL=https://<machine>.<tailnet>.ts.net` and
   `COOKIE_SECURE=always`, then `docker compose up -d`.

**Verify:** `curl -s https://<machine>.<tailnet>.ts.net/api/health` from this machine answers
`{"ok":true}`; the human opens the address on their phone and signs in.

**If it fails:** `tailscale serve` errors about HTTPS: enable HTTPS certificates (human, admin
console). Turn it off with `tailscale serve reset`.

### 6b. Cloudflare

Follow [CLOUDFLARE.md](CLOUDFLARE.md) with the human. Split of work:

| Part | Who |
|---|---|
| Domain on Cloudflare, Zero Trust organization, team name | **[HUMAN]** (their account) |
| Create the tunnel; copy its token into `.env` as `CLOUDFLARE_TUNNEL_TOKEN` | **[HUMAN]** (dashboard; the token is a secret) |
| `COMPOSE_PROFILES=cloudflare` in `.env`, `docker compose up -d` | agent |
| Tunnel route `organizer.<domain>` → `http://organizer:8600` (`http://127.0.0.1:8600` if cloudflared runs on the host) | **[HUMAN]** (dashboard) |
| Access application for that hostname, Allow policy with their email | **[HUMAN]** (dashboard; it decides who gets in) |
| `PUBLIC_BASE_URL=https://organizer.<domain>`, `COOKIE_SECURE=always`, `docker compose up -d` | agent |
| For each token client (Mac app, Mac helper, Claude Code on another machine): a service token, created in Zero Trust → Access controls → Service credentials → Service Tokens | **[HUMAN]** (dashboard; the Client Secret is shown once and is a secret) |
| A **Service Auth** policy on the web application that includes those service tokens (not Allow, not "Any Access Service Token") | **[HUMAN]** (dashboard) |

Do the Access application **before** telling the human to open the hostname. The service tokens
can wait until steps 9, 11 and 12 need them; CLOUDFLARE.md step 5 covers expiry, rotation and
revoking, so tell the human about the expiry notification there.

**Verify:**

```bash
grep -cE '^CLOUDFLARE_TUNNEL_TOKEN=.{50,}$' .env                        # expect: 1
docker compose logs --tail 20 cloudflared | grep -c 'Registered tunnel connection'   # expect: 1 or more
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://organizer.example.com
# expect: 302 https://<team>.cloudflareaccess.com/...  (Access's sign-in)
```

A `200` with the organizer's page instead of the 302 means no Access application covers the
hostname: tell the human at once; the organizer is public with only its password in front.

**If it fails:** CLOUDFLARE.md has a troubleshooting table (empty token, 502, 1033, redirect URI).

## Step 7. Google OAuth client (optional) [HUMAN]

**Goal:** the organizer can connect Google Calendar, Gmail and Google Tasks. **[ASK]**
does the human want Google at all? If not, skip to step 8.

All of it happens in the human's Google Cloud Console: **[HUMAN]**, with [GOOGLE.md](GOOGLE.md)
open. You can read the steps out and answer questions. The redirect URI to register is the one
Settings → Connected accounts → Add account → Google account shows; it is `PUBLIC_BASE_URL`
plus `/api/oauth/google/callback`, or `http://localhost:8600/api/oauth/google/callback` with no
remote access. Google accepts plain http only for localhost.

The client secret goes into `.env` as `GOOGLE_CLIENT_SECRET`. **[HUMAN]** pastes the ID and
the secret there. Then the agent runs `docker compose up -d` (a plain `restart` doesn't re-read
`.env`).

**Verify:** `grep -cE '^GOOGLE_CLIENT_ID=.+\.apps\.googleusercontent\.com$' .env` → `1`, and
the Google option in Add account no longer says the client is missing.

## Step 8. Connect accounts [HUMAN]

**Goal:** calendars, reminders and mail flowing in. **[HUMAN]**, in Settings → Connected
accounts → Add account. **[ASK]** which ones they want.

Every one of these needs a password, an app-specific password or an OAuth consent, so the
human enters it. You explain where to get it:

| Account | What the human needs | Guide |
|---|---|---|
| iCloud calendar | An app-specific password from account.apple.com (Sign-In and Security → App-Specific Passwords) | [CALENDAR.md](CALENDAR.md) |
| Other CalDAV (Fastmail, Nextcloud...) | The server's CalDAV URL, username, app password | [CALENDAR.md](CALENDAR.md) |
| IMAP mail (iCloud, Fastmail, Outlook, other) | An app password for IMAP | [MAIL.md](MAIL.md) |
| Google (Calendar, Gmail, Tasks) | Step 7 done; they tick what to read and approve Google's screen | [GOOGLE.md](GOOGLE.md) |
| Apple Reminders | The Mac helper (step 12); no account here | [REMINDERS.md](REMINDERS.md) |

**Verify:** each account appears in Settings without an error; the Calendars menu shows each
account's freshness ("as of ... ago") within a few minutes. Calendars → Sync now polls at once.

**If it fails:** the form reports a refused login directly; the account's guide covers the
usual causes (Apple ID password instead of an app-specific one, Outlook's disabled IMAP
passwords, Google's 7-day expiry in Testing mode).

## Step 9. Claude Code (stdio MCP)

**Goal:** Claude Code can use the organizer's tools. **[ASK]** do they want it? With mail?
Needs `uv` and `claude` (step 1).

1. **[HUMAN]** in the organizer, Settings → API tokens → new token, scope **API**, author
   **Claude**. Copy it (shown once).
2. **[HUMAN]** runs this in **their own terminal**, not through the agent (and not with Claude
   Code's `!` prefix, which puts the output in the transcript), replacing `<api token>`. The
   agent fills in the path and URL beforehand:

   ```bash
   claude mcp add --env ORGANIZER_URL=http://localhost:8600 \
     --env ORGANIZER_TOKEN=<api token> \
     --transport stdio --scope user \
     organizer -- uv run --directory "$HOME/life-organizer/mcp" organizer-mcp
   ```

   Keep an option such as `--transport` between the last `--env` and the name; directly after
   `--env`, the name is read as another variable. `ORGANIZER_URL` is `http://localhost:8600`
   when Claude Code runs on this machine, or the Tailscale address from another machine.
   Behind Cloudflare Access, use the HTTPS hostname and add a service token for Claude Code
   (CLOUDFLARE.md step 5) with two more options, which the human also fills in:
   `--env ORGANIZER_CF_ACCESS_CLIENT_ID=<client id> --env ORGANIZER_CF_ACCESS_CLIENT_SECRET=<client secret>`.
   Both or neither: with only one, the server refuses to start and names the missing one.
3. Mail (optional): a second token, scope **Mail**, author **Claude**, and a second server:

   ```bash
   claude mcp add --env ORGANIZER_URL=http://localhost:8600 \
     --env ORGANIZER_MCP_TOOLSETS=mail --env ORGANIZER_MAIL_TOKEN=<mail token> \
     --transport stdio --scope user \
     organizer-mail -- uv run --directory "$HOME/life-organizer/mcp" organizer-mcp
   ```

   Tell the human to connect `organizer-mail` only to sessions that need mail ([MCP.md](MCP.md),
   the mail safety rule).

**Verify:** `claude mcp list` shows `organizer: ... ✔ Connected` (and `organizer-mail`). Don't
run `claude mcp get`; it may show the token. In a new Claude Code session, ask for this week's
calendar.

**If it fails:**
- `✘ Failed to connect`: run `cd mcp && uv sync` once; check the path in `--directory`.
- A tool call says `ORGANIZER_TOKEN is not set`: the `--env` was swallowed; `claude mcp remove
  organizer` and add it again with the option order above.
- 401 from the organizer: the token was mistyped or revoked; make a new one.

## Step 10. The claude.ai connector, through Cloudflare

**Goal:** Claude on the web, desktop and mobile can use the organizer as a custom connector.
**[ASK]** do they want it? A separate mail connector too? Which hostname?

Follow [REMOTE-CONNECTOR.md](REMOTE-CONNECTOR.md) with the human. It needs the tunnel from
step 6b (only the tunnel part, if the web app uses Tailscale). Split of work:

| Part | Who |
|---|---|
| Token, scope API, author **Claude (remote)**, pasted into `.env` as `ORGANIZER_MCP_TOKEN` | **[HUMAN]** |
| Access application for `organizer-mcp.<domain>`: Allow policy with their email, **Managed OAuth** on, redirect URI `https://claude.ai/api/mcp/auth_callback`; copy the AUD tag | **[HUMAN]** (dashboard) |
| Tunnel route `organizer-mcp.<domain>` → `http://organizer-mcp:8601` (`http://127.0.0.1:8601` if cloudflared runs on the host), HTTP Host Header set to the hostname | **[HUMAN]** (dashboard) |
| `.env`: `CF_ACCESS_TEAM_DOMAIN`, `CF_ACCESS_AUD`, `MCP_PUBLIC_HOST`, `MCP_ALLOWED_EMAIL`; add `remote-mcp` to `COMPOSE_PROFILES`; `docker compose up -d --build` | agent (the AUD tag and team domain are not secrets) |
| curl checks | agent |
| Add the connector in Claude (Customize → Connectors → Add custom connector; Sign in now; Register automatically) and sign in | **[HUMAN]** |
| Tool permissions: writes on **Needs approval** | **[HUMAN]** |
| Optional WAF rule limiting `/` and `/mcp` to Anthropic's ranges | **[HUMAN]** (dashboard) |

**Verify:**

```bash
grep -cE '^ORGANIZER_MCP_TOKEN=org_' .env                 # expect: 1
docker compose logs organizer-mcp | grep 'serving toolsets'   # expect: serving toolsets calendar,jobs,reminders ...
curl -si -X POST http://127.0.0.1:8601/mcp -H 'Host: organizer-mcp.example.com' | head -1   # expect: 401
curl -si https://organizer-mcp.example.com/mcp | grep -i '^www-authenticate'              # expect: a Bearer ... line (from Access)
```

A 401 from the public URL **without** `www-authenticate` and with the body `Cloudflare Access
assertion missing or invalid` means Access doesn't cover the hostname. After the WAF rule, the
public `/mcp` answers 403 from this machine; that is expected.

Then the human asks Claude (with the connector on in that chat) for today's calendar.

**If it fails:** REMOTE-CONNECTOR.md has the troubleshooting table, keyed by the container's
log lines (`docker compose logs organizer-mcp`).

## Step 11. The Mac app (optional)

**Goal:** the native Mac app. **[ASK]** do they want it?

It is built from source with Xcode; **no paid Apple developer account is needed**. Follow
`apple/README.md` in this repo. If that file isn't in the checkout yet, tell the human the Mac
app isn't available in this version and skip the step.

| Part | Who |
|---|---|
| Xcode 26 or later installed, `xcode-select -p` pointing at it | **[HUMAN]** (App Store) |
| `apple/scripts/test.sh && apple/scripts/build.sh` (signs to run locally, no team) | agent |
| Token, author **me**, scopes **api** and **mail** | **[HUMAN]**, in the web app's Settings → API tokens |
| Open the app; on first launch enter the server address and paste the token | **[HUMAN]** |

The server address is the one the human opens in a browser (`http://localhost:8600` on the
organizer's own Mac, else the Tailscale or Cloudflare HTTPS address). The first-launch sheet
checks it before saving: a 401 means a mistyped or revoked token, a 403 a missing scope.

If the human chose Cloudflare for the web app, the app needs a service token of its own
(CLOUDFLARE.md step 5). **[HUMAN]** enters its Client ID and Client Secret in the app's
Settings, section **Advanced: Cloudflare Access service token** (the environment variables
`ORGANIZER_CF_ACCESS_CLIENT_ID` and `ORGANIZER_CF_ACCESS_CLIENT_SECRET` override them). The
details are in `apple/README.md`.

**Verify:** Settings → Test Connection says "Connected" with the api and mail scopes, and the
Calendar shows this week.

## Step 12. The Mac helper (optional)

**Goal:** Apple Reminders (two-way) and every Apple Calendar account. **[ASK]** only
needed for Apple Reminders, or for calendars that aren't on iCloud/CalDAV/Google. It runs on a
Mac signed in to the owner's iCloud account.

Follow [mac-helper/README.md](../mac-helper/README.md). Split of work:

| Part | Who |
|---|---|
| `cd mac-helper && swift build && swift test && scripts/install.sh` | agent (Xcode or Command Line Tools; no paid account) |
| Token, scope **Ingest** only, author **Mac helper** | **[HUMAN]** |
| Config at `~/.config/life-organizer-for-mac/helper.json` from `helper.example.json`, `chmod 600`, `server.url` set | agent |
| `organizer-helper set-token` (paste the token; it isn't shown) | **[HUMAN]**, in their own terminal |
| `organizer-helper doctor` | agent |
| `organizer-helper install`, then approve the Calendars and Reminders prompts | agent runs it; **[HUMAN]** answers the macOS prompts |

`server.url` is `http://localhost:8600` when the helper runs on the organizer's own Mac, or the
Tailscale address. Behind Cloudflare Access, it is the HTTPS hostname, and the helper needs a
service token of its own (CLOUDFLARE.md step 5): the agent sets `server.cf_access_client_id` in
the config, and **[HUMAN]** puts the secret in `server.cf_access_client_secret` or in the Keychain,
as `mac-helper/README.md` describes (`organizer-helper set-cf-access-secret` stores it there).
`doctor` then shows whether Access let it through.

The Mac app (step 11) can run the helper inside itself instead (Settings → Helper, off by
default; `apple/README.md`). Use one or the other, never both: the second one refuses to start.

**Verify:** `organizer-helper doctor` ends without failures, `organizer-helper status` shows a
recent push, and the organizer's Reminders page shows the Apple lists within a few minutes.

## Step 13. Backups

**Goal:** a copy of the database, outside the repo and apart from `.env`. **[ASK]** where.

```bash
mkdir -p ~/organizer-backups
docker compose exec organizer python -c "import sqlite3; s=sqlite3.connect('data/organizer.db'); d=sqlite3.connect('data/backup.db'); s.backup(d); d.close()"
docker compose cp organizer:/app/server/data/backup.db ~/organizer-backups/organizer-$(date +%F).db
docker compose exec organizer rm data/backup.db
```

**Verify:** `ls -l ~/organizer-backups/` shows today's file, a few hundred KB or more.

Tell the human:
- the backup holds their data (job records, mail headers); keep it off shared folders;
- keep it apart from the `ORGANIZER_SECRET_KEY` (step 3): together they unlock the stored
  account credentials;
- to automate it, the same commands can run from cron or a LaunchAgent; offer to set one up
  only if they ask (it is a persistent change to their machine).

Restoring is in [SETUP.md](SETUP.md), "Restoring".

## Finished

Summarize for the human what is set up, which URLs to use, which tokens exist (by name and
author, never by value), and what was skipped. Updating later is
`git pull && docker compose up -d --build`; migrations run on start.
