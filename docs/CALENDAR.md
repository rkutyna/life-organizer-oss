# Calendars

The calendar shows every calendar you connect, read-only, next to the organizer's own items and
public holidays. Nothing you see here is ever written back: to change an event, change it in
its own calendar app.

Connect calendars in **Settings → Connected accounts → Add account**. You can connect several
accounts of each kind. The organizer polls each one every 15 minutes (and right after you
connect it); **Calendars → Sync now** polls them at once.

## iCloud

You don't need a Mac. iCloud calendars are read over CalDAV.

1. Make an **app-specific password** for your Apple ID: sign in at
   [account.apple.com](https://account.apple.com), then Sign-In and Security → App-Specific
   Passwords ([Apple's guide](https://support.apple.com/en-us/102654)). Your Apple ID needs
   two-factor authentication for this.
2. In the organizer, choose **iCloud calendar** and enter your Apple ID and that password. Do not
   use your Apple ID password: Apple refuses it.

The organizer signs in before it saves anything; a wrong password is reported in the form. The
password is stored encrypted with `ORGANIZER_SECRET_KEY` (see SETUP.md). To stop access, remove
the account here, or revoke the app-specific password at Apple.

## Any CalDAV server

Fastmail, Nextcloud, Radicale, Baïkal, a NAS and most other calendar servers speak CalDAV.
Choose **CalDAV calendar** and enter:

- **Server URL**: the full CalDAV address, starting with `https://` (for example
  `https://caldav.example.com/dav/`). Your provider's help pages list it. The organizer uses the
  address as given and does no DNS discovery.
- **Username** and **password**. Use an app password if your provider offers them.
- **Name** (optional): how the account is labelled in the organizer. It defaults to the
  server's host name. If you also run the Mac helper, see the dedup rule below.

Every calendar on the account that holds events is read; task lists are skipped.

## Google

Google Calendar is read through Google's own sign-in, using an OAuth client of your own. Set it
up once as [GOOGLE.md](GOOGLE.md) describes, then choose **Google account** in Add account and
tick Calendar. The organizer reads every calendar your Google account lists (your own, shared
and subscribed ones) in the colors Google shows them in. Calendars shared with you as free/busy
only show their events as "Busy".

## What is read, and how fresh it is

- **Window:** one year back to one year ahead. Recurring events are expanded into single
  occurrences.
- **Shown:** title, time, location, status (tentative and canceled are marked), and a link to
  the event (the event's own URL, or Google's page for it). Descriptions, attendees and
  attachments are not stored.
- **Ages:** each account is its own freshness source. The Calendars menu shows every account's
  age next to its calendars ("as of 5 min ago"), and the strip under the calendar title warns
  when an account is **stale** (no successful poll for an hour) or **failing**, with the error
  on hover. A failing account keeps its last good events.
- **Hiding:** each calendar has its own toggle in the Calendars menu. Disabling an account in
  Settings hides its events and stops polling it; removing it deletes its events too.

## The Mac helper and the dedup rule

The optional Mac helper pushes what the Mac's Calendar app shows (`POST /api/ingest/calendar`,
with an API token of scope `ingest`). That includes accounts you may also have connected here,
so the same event can arrive twice. The organizer merges the two copies, account by account.

**Matching.** A helper event belongs to a connected account when its account name on the Mac
matches the account's name here, ignoring case, and the Mac's account type is CalDAV-based:

| Connected account | Name it is matched by |
|---|---|
| iCloud | `iCloud` |
| Google | the Google address |
| Other CalDAV | the account's name in the organizer: name it as the Mac does |

Two copies are the same event when the calendar title, the account name, the event UID and the
occurrence's original start all match. A moved occurrence of a repeating event keeps its
original start, so it still matches.

**Which copy is shown**, for each connected account and the helper events that belong to it:

| Helper (pushed within 2 hours) | Account (polled within 1 hour) | Shown |
|---|---|---|
| fresh | any | the helper's copies, plus the account's events the helper lacks |
| stale | fresh | the account's copies only |
| stale | stale | the account's copies, plus the helper's events the account lacks |

Nothing is hidden when both are stale: an old copy beats an empty calendar, and the freshness
strip says how old it is. Helper events from accounts not connected here (a local calendar,
Exchange, Birthdays) are always shown, under **On this Mac** in the Calendars menu. A calendar
that arrives both ways has one entry in the menu, under its account, and keeps its color and
show/hide setting whichever copy is shown.
