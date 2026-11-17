# Plan: a self-hosted organizer

Status: phases 0 (core), 1 (calendar) and 2 (mail, MCP) built 2026-11-16; phases 3-5 not started. This repo is **private** until the checks in §9 pass.

## 1. What this is

A self-hosted web app that puts four things in one place:

- **Calendar**: every calendar you have, read-only, with your job-search dates on top.
- **Reminders**: your existing reminders or tasks, two-way, with dated ones shown on the calendar.
- **Job tracker**: companies, applications and their status history, contacts, interviews, events, leads.
- **Mail**: read-only headers from your mail accounts, and one message read on demand.

Claude can reach all of it through an MCP server.

It is extracted from a private, single-user organizer that has run in production since October 2026. That codebase's patterns are proven, and they carry over: modules, the audit log, the ingest contract, and the read-only mirrors. Its personal parts stay behind: health, a fitness challenge, Claude-session monitoring, GitHub projects, and a job workflow built around one person's folder of markdown files.

## 2. Decisions so far

| Topic | Decision |
|---|---|
| Hosting | **Self-hosted.** One install per person, run with Docker Compose on a small server, a VPS or a Mac. Nobody runs a shared service. |
| Users | **One user per install.** No `user_id` on any table. This is the biggest saving over a multi-user rewrite. |
| Providers | **Mixed.** Apple (iCloud and Mac apps), Google (Calendar, Tasks and Gmail) and generic standards (CalDAV and IMAP), each behind an adapter. |
| Repo | A new repo with fresh history, so no personal data from the original's history comes along. Code is copied in module by module and scrubbed (§8). |
| Scope v1 | Calendar, reminders, job tracker and mail, plus the web app and MCP. Native iOS and macOS apps come later (§10). |

## 3. What changes from the original

| Area | Original | Here |
|---|---|---|
| Network and auth | Reachable on a private tailnet only, with no app-level auth on most routes | **Real auth on every route** (§4.1). The app must be safe even if someone exposes it. |
| Author of writes | Hardcoded to the owner's name | `me` (the UI), `claude`, `helper` or `system`. A display name is a setting. |
| Config | Owner's host, time zone and list names as defaults | Neutral defaults. A first-run setup page writes the settings. |
| Timezone and holidays | US Eastern, US federal holidays | Time zone set at setup. Holiday country is a setting and can be off. |
| Calendar in | Mac helper (EventKit) and iCloud CalDAV | Provider adapters: CalDAV (any server, iCloud preset), Google Calendar API, and the Mac helper (optional) |
| Reminders | Apple only via the Mac helper; tied to a separate to-do module | Provider adapters: Google Tasks (server-side) and Apple Reminders via the Mac helper. **Reminders are the to-do system**: no separate to-dos module. |
| Mail | iCloud IMAP and Gmail, credentials in `.env`, OAuth by CLI, MCP only | Any IMAP account (iCloud, Fastmail and others as presets) and Gmail. Accounts are added in Settings, with an in-browser OAuth flow. A read-only web inbox and MCP. |
| Job tracker | Built around one person's markdown workspace, week plans, a scoreboard of nine lanes, Sheet importers | A **generic tracker** (§5.3). The workspace mirror, week blocks, lanes, LeetCode, reps, packaging and skills are dropped. |
| Migrations | 18 interleaved migrations, several for dropped modules | One fresh baseline migration |
| Native apps | iOS, macOS and Watch | Later (§10). The web app is a PWA. |

## 4. Architecture

```
 Browser / PWA ──┐
 Claude (MCP) ───┼──▶ organizer server (FastAPI + SQLite, one Docker container)
 Mac helper ─────┘      /api/<module>/*   web + MCP, session or token auth
  (optional, Apple       /api/ingest/*     helper pushes, device token
   Calendar and          background polls: CalDAV, Google Calendar, Google Tasks, IMAP, Gmail
   Reminders only)       serves the built React app at /
```

Most of this is unchanged from the original:

- **Server:** Python 3.12, FastAPI, SQLAlchemy 2, Alembic, SQLite in WAL mode, APScheduler.
- **Web:** React, Vite, Tailwind, TanStack Query, FullCalendar.
- **Helper:** Swift, EventKit, a LaunchAgent.
- **MCP:** Python with FastMCP. It works through the REST API, never the database.

The rules carry over as well:

- Every owned write goes through `audit.py` (`change_log`, revertible).
- Mirrored data is read-only, and every mirror shows its age.
- Modules are self-contained and auto-discovered.

### 4.1 Auth (new)

- **Web:** one password, set on the setup page and stored as an argon2 hash. The session is an HTTP-only, SameSite cookie, and every write is protected against CSRF.
- **API tokens** are made in Settings, one per client: the MCP server, the Mac helper, later the native apps. Each token has scopes: `api` (the REST API), `ingest` (the helper only) and `mail`, kept separate so mail can only be read by a token made for it. Tokens are hashed at rest, can be revoked, and record when they were last used.
- **Recommended exposure**, in order:
  1. Tailscale (`tailscale serve`).
  2. A Cloudflare Tunnel with Access.
  3. LAN only.

  The docs cover all three. A plain public port works but is discouraged.
- **Remote MCP for claude.ai:** an optional second container. It uses the same Cloudflare Access pattern as the original, but the allowed email is a setting.

### 4.2 Provider adapters (new)

Each feature defines a small interface, and each provider implements it. Provider accounts are rows in a `provider_accounts` table, holding kind, label, encrypted credentials, status and last sync. They are no longer `.env` variables, so the friend adds accounts from Settings.

| Feature | Interface | Providers v1 |
|---|---|---|
| Calendar | `list_calendars()`, `list_events(window)` | CalDAV (generic, iCloud preset), Google Calendar, Apple via the helper's push |
| Reminders | `list_lists()`, `list_items()`, `apply(op)` | Google Tasks (applied directly by the server), Apple via the helper's op queue (applied by the helper) |
| Mail | `list_headers(folder, since)`, `fetch_body(id)` | IMAP (generic, with iCloud, Fastmail and Outlook presets), Gmail API |

- **Credentials at rest:** encrypted with a key from `ORGANIZER_SECRET_KEY` in `.env`, the one secret the friend must set. The key never goes in the database.
- **Apple Reminders cannot use CalDAV.** iCloud's upgraded reminders are not exposed over CalDAV, so Apple Reminders needs the Mac helper. Apple Calendar does not: CalDAV covers iCloud calendars without a Mac.
- **Google OAuth for self-hosters:** each install brings its own Google Cloud OAuth client. Settings walks through creating it, then runs the consent flow with a redirect to the install's own URL. Two caveats must be documented:
  - Refresh tokens expire after 7 days while the app is in "Testing" mode, so the friend publishes it to Production, unverified. Google then shows an "unverified app" screen, which is acceptable for personal use.
  - `gmail.readonly` is a restricted scope. An unverified app can use it for a small number of users, its owner included.

## 5. The four features

### 5.1 Calendar

- **Keep:**
  - the CalendarItem schema and the provider registry (`calendar.py`);
  - the unified `/api/calendar` feed;
  - the day, week, month and custom year views;
  - the freshness strip;
  - the EventKit/CalDAV dedupe (§6 of the original design), generalized to "helper versus any server-side source for the same account".
- **Add:** a Google Calendar adapter (`events.list` with `singleEvents=true`, a sync token per calendar) and a generic CalDAV URL.
- **Drop for v1:** the "mirror out" that writes organizer items into an Apple calendar. It existed for to-dos and job blocks. A later version could instead publish an ICS feed (a read-only URL holding a secret token) that any calendar app can subscribe to. That needs no helper and works with Google too.
- **Job items** on the calendar: interviews, job events and next-action due dates.

### 5.2 Reminders

- **Keep:**
  - the op-queue model: an owned `ReminderOp`, written through audit, with a sync state of `synced`, `syncing`, `waiting_for_device` or `failed`;
  - the field-level loop rule (compare with the last value written, never with timestamps alone);
  - last-writer-wins conflict handling, with fields merged.
- **Google Tasks:** the server applies ops itself right away, so a sync takes seconds instead of waiting for the Mac. It uses the same op table, with an `applier` of `server` or `helper`.
- **Drop:**
  - the to-dos module;
  - the "Organizer" list mirror (`todo_sync.py`, `/api/mirror/todos`).

  Reminders in the friend's own lists are the tasks. This removes the hardest code in the original: the two sources of truth and the deletion rules of §5.2.1.
- **Web UI:** moves out of the old `todos` page into `web/src/modules/reminders/`. It has a list view, Today and overdue, quick-add with natural-language dates (the parser is reused), and a drawer for editing.
- **Known gap:** Google Tasks has a due date but no due time. The UI hides the time field for Google lists.

### 5.3 Job tracker (the biggest rewrite)

The original's job module is about 13k lines of server code and 8.8k of web code, but most of it serves one person's workflow. Each part is kept, generalized or dropped:

| Keep (generalize) | Drop |
|---|---|
| **Companies:** name unique ignoring case; notes; a target flag; a free-form `tags` field in place of the owner-specific alumni and region columns | Week files, blocks, checklists, `W<n> D<n>` commits |
| **Applications** with dated status history, and `reached` (how far an application got) | Scoreboard lanes, the tripwire, the floor, the Health Advisor commit lane |
| **Leads** as a stage of an application, with one record per posting (`matching.py`) | LeetCode, reps, packaging, the skills map |
| **Contacts:** next action and due date, reply date | The workspace mirror mode and the `files` and `gitlog` modules |
| **Interviews**, linked to calendar events; **events** such as fairs and networking | The Google Sheet importers and their hardcoded tabs and counts |
| **Pipeline:** counts by status and `reached` | Message drafts, draft context and outreach rules (§10.6) |
| **Weekly goals:** optional, user-defined (applications and outreach per week), with no fixed lanes | |
| **CSV import with a column-mapping step**, dry run first | |

- **Statuses** are a configurable list with sensible defaults (lead, applied, screen, interview, offer, rejected, withdrawn, ghosted). The pipeline counts only; it shows no rates, as in the original.
- **Port order:** models and matching first, then status history, the pipeline, contacts and interviews, and the web pages, written new against the smaller model. The original's pages are dense with lane and workspace UI; reusing their components is fine, but copying them whole is not.

### 5.4 Mail

- **Keep everything about the safety model** (from the original's `docs/mail.md`):
  - read-only end to end (IMAP `EXAMINE` and `BODY.PEEK`, `gmail.readonly`);
  - headers stored and bodies fetched live, never stored;
  - every result marked untrusted;
  - the HTML sanitizer, which removes hidden text and counts it;
  - sender authentication from `Authentication-Results`;
  - the MCP mail toolset is opt-in and refused next to any write tool.
- **Change:**
  - accounts come from `provider_accounts`, not `.env`;
  - generic IMAP with presets;
  - Gmail consent runs in the browser, not through a CLI;
  - a new **read-only web inbox**: a list, a reader that shows the sanitized body and the sender checks, a filter by account, search on stored headers;
  - the window (30 days by default) is a setting.
- **Never:** send, delete, move or mark mail. A later "link this email to an application" stores a pointer (the message id), not the content.

## 6. MCP

- **Toolsets:** `calendar`, `reminders`, `jobs` and `mail` (opt-in). The server instructions describe "your organizer" with no name.
- **Auth:** an API token with the `api` scope, plus a separate token with the `mail` scope for the mail server (docs/MCP.md).
- **Authors:** `claude`, and `claude_remote` for the remote connector, are kept so history shows which client wrote what.

## 7. Repo layout

```
server/app/{main,config,db,audit,auth,calendar,discovery,freshness,scheduler,providers}.py
server/app/modules/{calendar_ext,reminders,jobs,mail,settings}/
web/src/modules/{calendar,reminders,jobs,mail,settings}/
mac-helper/      optional: EventKit calendar push and Reminders ops only
mcp/
deploy/          Dockerfile, docker-compose.yml, .env.example, exposure guides
docs/            PLAN.md (this), SETUP.md, PROVIDERS.md, SECURITY.md
```

## 8. Porting approach and the privacy check

- **Copy by module, never by history.** Each module is copied in its own commit, scrubbed, tested, and committed with a message that says so.
- **The scrub check:**
  - `scripts/scrub-check.sh` runs in CI and as a pre-commit hook.
  - It greps the tree and every commit for a **denylist kept outside the repo**: a local file, gitignored and never committed, because the list itself is personal (names, hosts, domains, team ids, account ids, folder names).
  - CI also gets a generic check that needs no list: no absolute `/Users/` paths, no tailnet hostnames, no hardcoded emails.
- **Fixtures are synthetic** and copy only the format of real data.
- **Dev seed:** a fictional user with fake companies, calendars and mail headers. The seed is the demo the friend sees before connecting anything.

## 9. Phases

| Phase | Work | Done when |
|---|---|---|
| 0 | **Core:** config, db, audit, auth (§4.1), the setup page, settings, `provider_accounts` with encrypted credentials, discovery, freshness, scheduler, baseline migration; the web shell; Dockerfile and compose; the scrub check and CI | `docker compose up`, setup, login and an empty calendar work on a clean machine |
| 1 | **Calendar:** CalDAV (generic and iCloud), Google Calendar and its OAuth flow, holidays as a setting, the web calendar | An iCloud calendar and a Google calendar show together, and stale sources show their age |
| 2 | **Mail:** IMAP with presets, Gmail, the web inbox, the MCP mail toolset | An iCloud and a Gmail inbox are listed read-only; one body reads clean |
| 3 | **Reminders:** Google Tasks two-way, the web UI; then the Mac helper, cut down to calendar and reminders, built and signed for distribution | A task added on the phone shows in the organizer and a change made here reaches the phone, for Google and for Apple |
| 4 | **Job tracker:** the generic model, matching, pipeline, CSV import with mapping, calendar items, MCP tools | The friend imports their spreadsheet and works from the tracker for a week |
| 5 | **Go public:** `SECURITY.md`, a threat-model pass over auth and mail, the license, README screenshots from the seed, the friend's first install from the docs alone | The scrub check passes on all history, and an outside reviewer finds no personal data |

Phases 1 and 2 are independent and can be built in parallel once phase 0 lands. Phase 3's Google half is independent too. The helper half is signed and notarized for distribution (§10.3).

### 9.1 Phase 0 as built (2026-11-16)

Where the build differs from the sections above:
- **Auth and accounts are core, not a module.** They live in `server/app/auth/` (principal, sessions, tokens, `/api/auth`, `/api/settings`) and `server/app/providers/` (`core_provider_accounts`, Fernet encryption via HKDF from `ORGANIZER_SECRET_KEY`, `/api/settings/accounts`). The web Settings page is `web/src/modules/settings/`.
- **Scopes are `api`, `ingest` and `mail`** (not `mcp`/`mcp-mail`). The Mac helper will send `Authorization: Bearer` with an `ingest` token, so there is no separate `X-Ingest-Token`.
- **A token's author is fixed when it is made.** The browser is always `me`, and there is no `X-Author` header.
- **The owner's settings are bookkeeping, not audited records.** The config row (name, time zone, holiday country, password hash), sessions, tokens and accounts are kept out of `change_log` so that hashes and ciphertext never land there.
- **Public routes:**
  - `/api/health`;
  - `/api/auth/state`, `/api/auth/setup` and `/api/auth/login`;
  - the two pick lists setup needs (`/api/settings/timezones` and `/api/settings/holiday-countries`).

  `tests/test_main.py` fails if any other route answers without auth.
- **Login throttle:** in memory; 5 failures per client address in 15 minutes, and 30 overall per hour.
- **Docker:** the container runs as a non-root user with a named volume, and the port is published on loopback only.

## 10. Decisions (2026-11-16)

1. **License:** MIT. `LICENSE` names "Life Organizer for Mac contributors" as the copyright holder, so no personal name is needed. Put a real name there before going public if you prefer one.
2. **Name:** "Life Organizer for Mac", for the app and the repo. The repo itself is still `life-organizer-oss` until it is renamed. Note that the server runs on any Docker host and reads Google accounts too; only the helper and the native apps are Mac-specific.
3. **Mac helper distribution:** sign it with a Developer ID and notarize it, as long as that stays simple: a `.pkg` or a zipped app built by one script. If notarizing turns out to be hard, ship build-from-source instructions first and report back.
4. **Native apps:** yes, later. They will point at the friend's server, with a neutral bundle id, and ship through TestFlight or source builds.
5. **Upstream relationship:** yes. The original personal organizer will eventually run on this core, with its personal modules in a private add-on. That makes the core's module boundaries strict:
   - core code never names a module;
   - modules reach each other only through published service functions;
   - the extension points an add-on needs are kept public and documented: auto-discovered modules, calendar providers, freshness sources, revert hooks and token scopes.
6. **Job tracker extras:** no. The friend just wants the tracker. Message drafts, draft context and outreach rules are left out of v1 (§5.3).
