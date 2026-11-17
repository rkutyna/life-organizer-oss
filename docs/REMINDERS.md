# Reminders

The organizer shows the reminders you already keep, in your own lists, and changes them both
ways. There is no separate to-do list: your reminders are the tasks. Two providers are
supported, and you can use both at once:

| Provider | How it is read | How changes get back | Needs |
|---|---|---|---|
| **Google Tasks** | The server polls each Google account every 5 minutes (and on **Sync** on the Reminders page) | The server applies each change itself, at once | A Google account connected with **Tasks** ticked |
| **Apple Reminders** | The Mac helper pushes a snapshot every few minutes and whenever Reminders changes | The Mac helper polls the change queue every 30 seconds and applies each change with EventKit | A Mac signed in to your iCloud account, running the helper (`mac-helper/README.md`) |

iCloud's reminders cannot be read over CalDAV, so Apple Reminders needs the Mac helper. Apple
*Calendar* does not: CalDAV covers it without a Mac (docs/GOOGLE.md and Settings).

What you get:
- **Reminders page** (`/reminders`, `g r`): your lists grouped by account, then Overdue, Today,
  Upcoming, No date and Completed recently (the last 30 days). Quick-add understands dates such as
  "tomorrow 3pm", "next fri" or "in 2 weeks", and `!1`/`!2`/`!3` for priority. Click a reminder
  to edit it in a drawer; check it off from the list.
- **Calendar**: open reminders with a due date appear in their list's color. All-day if they
  have no time, 30 minutes if they do. They are read-only there; the drawer links to the
  Reminders page.
- **MCP**: the `reminders` toolset (`reminders`, `reminder_lists`, `add_reminder`,
  `update_reminder`, `complete_reminder`); see docs/MCP.md.

The organizer never deletes a reminder, in either provider.

## Google Tasks

1. In Google Cloud Console, enable the **Google Tasks API** in the same project as your OAuth
   client, and add the scope `.../auth/tasks` under Data access (docs/GOOGLE.md).
2. In Settings → Connected accounts → Add account → Google account, tick **Tasks**. An account
   that is already connected can be connected again with Tasks ticked; the new scope is added.
3. The first poll runs within 5 minutes, or press **Sync** on the Reminders page.

Tasks needs write access (`auth/tasks`, not read-only), because changes go both ways.

**Limits of Google Tasks:**
- **A due date, no time.** Google Tasks stores only the day. The organizer *refuses* a due time
  on a Google list (HTTP 422 with a message) rather than silently dropping it, so an API or MCP
  caller learns about it. The web app hides the time field on Google reminders, and quick-add
  leaves a parsed time out and says so in its preview.
- **No priority.** Refused the same way, and hidden in the web app.
- **Moving** a reminder works between lists of the same Google account. Moving between
  accounts, or between Google and Apple, is refused: create it in the other list instead.
- Subtasks show as ordinary reminders; their nesting is not shown.

Each Google account has its own freshness entry (`reminders:<account id>`), shown at the foot
of the list sidebar and on `GET /api/reminders/status`. Removing the account in Settings removes
its reminders from the organizer (not from Google).

## Apple Reminders through the Mac helper

Install the helper on a Mac that is signed in to your iCloud account (`mac-helper/README.md`):
make an API token with the **ingest** scope in Settings → API tokens, give it to the helper,
and approve the Reminders (and Calendars) prompts. The helper then:

- pushes every Reminders list and its reminders (open ones, and those completed in the last 30
  days) to `POST /api/ingest/reminders`, replacing the organizer's Apple copy;
- asks `GET /api/ingest/reminders/ops` for queued changes every 30 seconds, applies them in order
  and reports each result to `POST /api/ingest/reminders/ops/{id}/ack`;
- pushes again right after applying, so the organizer shows the result.

Changes made while the Mac is asleep wait in the queue and apply when it wakes. Lists that are
read-only on the Mac (some shared lists) are shown but cannot be changed.

The helper's freshness entry is `reminders` ("Mac helper (Apple Reminders)").

## How a change travels

Every change you make here (check off, uncheck, edit title, notes, due date or time, priority,
list; or add a reminder) is recorded as an **op**: an owned record written through the audit
log, so History shows who asked for it (`me` from the web app, `claude` from MCP) and a
pending one can be undone. Each op has an **applier**: `server` for Google Tasks, `helper` for
Apple Reminders.

Until the provider reports the result, the reminder is shown as the provider last reported it
with its queued ops applied on top, so the change appears at once. Each reminder carries a
**sync state**:

| State | Meaning |
|---|---|
| `synced` | The provider has every change. |
| `syncing` | A change is on its way: queued, or applied and not yet mirrored back. A Google change normally skips this, since the server applies it before answering. A Google change that hit a network error stays here and is retried by the next poll (5 attempts). |
| `waiting_for_device` | An Apple change has been queued for over 2 minutes and the helper has not polled in 2 minutes: the Mac is asleep or the helper is off. Shown as "waiting for Mac". |
| `failed` | The provider refused the change (shown with its error). **Retry** queues it again; **Withdraw** drops it. Withdrawing the create of a reminder the provider never got removes it. |

A new reminder gets its organizer id at once and keeps it when the provider reports it.

## The sync rules

**The loop rule.** Changes are detected by comparing values, never by modification times
alone. Each op carries a `base`: the values the organizer believed the provider held for those
fields when the op was queued (the mirror with earlier queued ops applied). The applier
compares each field with the provider's current value:
- still equal to `base`: nobody else changed it, so the op's value is written;
- different: the field changed on both sides (a **conflict**).

So the organizer's own change coming back in the next sync is plain mirroring, never a new edit,
and nothing loops.

**Conflicts: last writer wins, field by field.** A field changed on both sides goes to whichever
change is newer: the provider's last-modified time against the op's queue time. Fields merge:
each side keeps the fields only it changed. Every conflict is logged and kept on the op
(`conflicts: [{field, kept: provider|organizer, provider_value, organizer_value}]`); a field
the provider won is shown with the provider's value.

**Completion is never lost.** Completing always applies (and completing a completed reminder
does nothing). Un-completing yields to a completion made at the provider after it was queued.

**Deletions.** A reminder that disappears from the provider is removed from the organizer at the
next sync, and its pending ops fail ("the reminder is gone from ..."). A new reminder's
placeholder survives while its create is pending or failed, and for 10 minutes after it was
applied, in case the snapshot was collected before the create.

**Identity.** Apple reminders are matched by `calendarItemExternalIdentifier`, then by the
device-local `calendarItemIdentifier`, so a late external id keeps the row and its organizer id.
Google tasks are matched by task id within their account. Lists are keyed by their provider id.

## Endpoints

Web app and MCP (`api` scope): `GET /api/reminders` (`list`, `include_completed`, `dated`),
`GET /api/reminders/lists`, `GET /api/reminders/status`, `POST /api/reminders/sync`,
`GET|PATCH /api/reminders/{id}`, `POST /api/reminders`, `POST /api/reminders/{id}/complete`
and `/uncomplete`, `GET /api/reminders/ops`, `POST /api/reminders/ops/{id}/retry`,
`DELETE /api/reminders/ops/{id}`.

Mac helper (`ingest` scope): `POST /api/ingest/reminders`, `GET /api/ingest/reminders/ops`,
`POST /api/ingest/reminders/ops/{id}/ack`. The wire format is in the docstrings of
`server/app/modules/reminders/ingest.py`, and the OpenAPI schema at `/docs`.
