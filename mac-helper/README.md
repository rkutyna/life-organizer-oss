# Life Organizer Helper for Mac

An optional, small background program for your Mac. It connects Apple Calendar and Apple Reminders to your
self-hosted organizer:

- **Calendar:** it reads every calendar in the Calendar app (all accounts) and sends a snapshot to
  `POST /api/ingest/calendar` every 5 minutes, and a few seconds after any change. It only reads.
- **Reminders:** it sends a snapshot of every Reminders list to `POST /api/ingest/reminders`. Changes you make
  in the organizer (add, edit, move, check off or uncheck) are queued there. The helper asks for them every
  30 seconds (`GET /api/ingest/reminders/ops`), applies them in Apple Reminders, and reports each result back
  (`POST /api/ingest/reminders/ops/{id}/ack`).

What it does **not** do:

- It never deletes a reminder and never changes a calendar event.
- It never writes to a read-only (shared) list.
- It reads no event notes, attachments or attendees. It reads no mail, contacts or files.
- It talks to one server only, the `server.url` in your config.

You need it only for Apple Reminders, which has no server API. iCloud calendars can also be added to the
organizer directly over CalDAV, without a Mac. The helper is still useful there: it covers every account in
the Calendar app, local calendars included.

## Install

**No paid Apple developer account is needed** to build and run the helper yourself:
- Building from source needs only Xcode or its command-line tools. The install script signs the
  result ad hoc.
- A free Apple ID signed in to Xcode gives you an "Apple Development" certificate, which keeps
  macOS's Calendar and Reminders permissions across rebuilds (below).
- A paid account (the Apple Developer Program) is only needed to publish a ready-made, notarized
  release for other people (`scripts/release.sh`).

### From a release

When a signed release is published on the project's Releases page, download it. Until then (or
if you prefer), build from source as below. A release:

- **`.pkg`** (signed, notarized and stapled): double-click it. It installs `/usr/local/bin/organizer-helper`.
- **`.zip`** (signed and notarized; a bare program cannot be stapled): unzip it and move the program onto your
  PATH:
  ```bash
  sudo mkdir -p /usr/local/bin && sudo mv organizer-helper /usr/local/bin/
  ```
  The first time it runs, macOS checks the notarization online, so be connected the first time.

Check the download against the `.sha256` file next to it: `shasum -a 256 -c organizer-helper-*.sha256`.

An `-unsigned.zip` is a test build. Gatekeeper blocks it once it has been downloaded; build from source instead.

### From source

You need Xcode or the Command Line Tools (Swift 6) and macOS 14 or later.

```bash
cd mac-helper
swift build && swift test
scripts/install.sh                     # builds a release, copies it to ~/.local/bin, signs it ad hoc
```

With an ad-hoc signature, macOS asks for Calendars and Reminders access again after every rebuild. If you have
an Apple developer certificate, pass it and the grants survive rebuilds:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/install.sh
DEST_DIR=/usr/local/bin scripts/install.sh       # another install folder
```

Make sure the install folder is on your PATH, or use the full path in the commands below.

## Set up

### 1. A token

In your organizer, open **Settings → API tokens** and create a token with the **`ingest`** scope only. That
scope lets the helper push snapshots and fetch reminder changes, and nothing else. Copy it; the organizer shows
it once.

### 2. The config

The config file is `~/.config/life-organizer-for-mac/helper.json`. Every command takes `--config PATH` to use another
one.

```bash
mkdir -p ~/.config/life-organizer-for-mac
cp helper.example.json ~/.config/life-organizer-for-mac/helper.json
chmod 600 ~/.config/life-organizer-for-mac/helper.json
```

Set `server.url` to your organizer's address, for example `https://organizer.example.com`. There is no default.
Plain `http://` is accepted only for this Mac itself (`localhost`, `127.0.0.1`, `::1`). For another host over
plain http, which sends the token unencrypted, you must also set `server.allow_insecure_http` to `true`;
`doctor` flags it.

The config must not be writable by other users (anyone who could edit it could send your token to another
server): `run` refuses to start if it is. If it holds the token (`server.token`), it must not be readable by
others either; `run` logs a warning and `doctor` reports it. `chmod 600` covers both.

### 3. Store the token

Keep the token in the macOS Keychain (recommended):

```bash
organizer-helper set-token             # paste the token; it is not shown
# or: pbpaste | organizer-helper set-token
```

It is stored as a generic password. The service is the config's `bundle_id` (default
`com.lifeorganizerformac.helper`), or `keychain.service` if set. The account is `ingest-token`. You can also put
the token in the config as `server.token`; when that is set, the Keychain is not read. The token is never
printed or logged.

### Behind Cloudflare Access (optional)

If your organizer is behind Cloudflare Access, the helper needs an Access **service token** to
get through, besides its ingest token. Docs elsewhere in this repo explain how to create one in
Cloudflare and which "Service Auth" policy to add. Then:

- set `server.cf_access_client_id` in the config to the token's client id;
- store its client secret in the Keychain (recommended), or put it in the config as
  `server.cf_access_client_secret`:

  ```bash
  organizer-helper set-cf-access-secret     # paste the client secret; it is not shown
  ```

  It is stored under the same Keychain service as the token, account `cf-access-client-secret`.

When both are set, every request carries `CF-Access-Client-Id` and `CF-Access-Client-Secret`
alongside `Authorization: Bearer`. `doctor` says whether they are set and where the secret came
from, never its value. Neither secret is ever logged.

### 4. Check

```bash
organizer-helper doctor
```

`doctor` only reads. It checks the config, the server address, where the token came from (it never prints the
token), the program's embedded bundle id and signature, the permission status, and whether the server accepts
the token. For that last check it sends an empty push, which the server rejects without saving anything.

`doctor` never asks for permissions. Run from Terminal, the permission lines show the Terminal app's grant,
not the helper's.

### 5. Run it in the background

```bash
organizer-helper install               # writes and loads ~/Library/LaunchAgents/<label>.plist
organizer-helper install --print       # shows the plist and changes nothing
organizer-helper status                # what the background helper last did
organizer-helper uninstall             # unloads and removes the LaunchAgent
```

The LaunchAgent runs `organizer-helper run` at login and keeps it running. Its label is the config's
`launch_agent_label`, else `bundle_id`. If you used `--config`, the LaunchAgent gets the same path. `uninstall`
leaves the Keychain item and the config in place. To remove the token, use Keychain Access or
`security delete-generic-password -s com.lifeorganizerformac.helper -a ingest-token`.

Only one helper runs at a time. A second `run` exits with code 3 while another one holds the lock.

## Permissions

On its first run, the background helper asks for two permissions. The prompts name **Life Organizer Helper**:

- **Calendars: Full Access**, to read your events.
- **Reminders: Full Access**, to read your lists and apply the organizer's changes.

If you deny one, that part stops and the rest keeps working. `organizer-helper status` and the organizer's
freshness strip show the stopped part as an error ("calendar access is denied"). macOS asks only once. To change
your answer later, open **System Settings → Privacy & Security → Calendars** (or **Reminders**), turn on
Life Organizer Helper (or `organizer-helper`), then restart the helper:
`launchctl kickstart -k gui/$(id -u)/com.lifeorganizerformac.helper`.

macOS ties each permission to the program's signature and bundle id. A new signature (an ad-hoc rebuild, for
example) may ask again or show up as a second entry.

## Logs and files

| What | Where |
|---|---|
| Log (rotated at 5 MB) | `~/Library/Logs/LifeOrganizerHelper/helper.log`, or the config's `log_path` |
| launchd's own output | `~/Library/Logs/LifeOrganizerHelper/launchd.log` |
| Last results (`status`) | `~/Library/Application Support/LifeOrganizerHelper/status.json` |
| Applied creates (no duplicates) | `~/Library/Application Support/LifeOrganizerHelper/reminders.json` |
| Single-instance lock | `~/Library/Application Support/LifeOrganizerHelper/helper.lock` |
| LaunchAgent | `~/Library/LaunchAgents/<label>.plist` |

## How reminders sync

- **The snapshot is complete.** Every list is sent, with every incomplete reminder plus those completed in the
  last 30 days (`reminders.completed_days`). Whatever is missing from a snapshot is gone from the organizer's
  copy. The snapshot is sent when Reminders changes, right after the helper applies changes, and at least every
  3 minutes (`reminders.snapshot_seconds`) if it differs. An unchanged snapshot is sent again every 15 minutes
  (`heartbeat_seconds`), so the organizer can tell the helper is alive.
- **Changes are applied in order.** Each change says which fields to set and what the organizer believed
  those fields held when you made the change.
- **The loop rule.** A field that still holds what the organizer believed is set to the new value. A field
  that also changed on your phone has changed on both sides. Then the most recent change wins: the reminder's
  last-modified time against the time the organizer queued its change. Every such case is reported back as a
  conflict, saying which side was kept. Fields merge: if you renamed a reminder on your phone and changed its
  due date in the organizer, both changes stay.
- **A completion is never lost.** Checking off always applies. Unchecking from the organizer gives way to a
  check-off made in Reminders after it.
- **Nothing is deleted.** The helper has no delete. A change whose reminder no longer exists is reported as
  failed, and read-only lists are never written. A change withdrawn in the organizer meanwhile is dropped.
- **Safe to repeat.** If a report back is lost, the change is sent again. Applying it twice does nothing
  more, and an add is never made twice. The helper remembers adds by the server's instance id and the change's
  id, so a recreated server database (whose change ids start again) is never mistaken for the old one.

## Config reference

| Key | Default | Meaning |
|---|---|---|
| `server.url` | none | The organizer's base URL: https, or http to this Mac only |
| `server.token` | `null` | The ingest token; `null` reads it from the Keychain |
| `server.timeout_seconds` | `30` | Per request |
| `server.allow_insecure_http` | `false` | Allow plain http to another host (the token travels unencrypted) |
| `server.cf_access_client_id` | `null` | A Cloudflare Access service token's client id; `null` sends no Access headers |
| `server.cf_access_client_secret` | `null` | Its client secret; `null` reads it from the Keychain (account `cf-access-client-secret`) |
| `bundle_id` | `com.lifeorganizerformac.helper` | Default Keychain service and LaunchAgent label (reverse-DNS) |
| `launch_agent_label` | `null` (= `bundle_id`) | The LaunchAgent's label (reverse-DNS) |
| `keychain.service` / `keychain.account` | `null` (= `bundle_id`) / `ingest-token` | Where `set-token` stores the token |
| `host` | the Mac's local host name | Sent with each snapshot |
| `heartbeat_seconds` | `900` | Resend an unchanged snapshot this often |
| `calendar.enabled` | `true` | Send Apple Calendar |
| `calendar.interval_seconds` | `300` | Read the calendars this often |
| `calendar.past_days` / `future_days` | `365` / `365` | The window sent |
| `calendar.debounce_seconds` | `5` | Wait after a change before reading again |
| `reminders.enabled` | `true` | Send Apple Reminders and apply changes |
| `reminders.apply_ops` | `true` | Apply the organizer's changes (`false`: send only) |
| `reminders.ops_poll_seconds` | `30` | Ask for changes this often |
| `reminders.snapshot_seconds` | `180` | Read Reminders at least this often |
| `reminders.completed_days` | `30` | Send completed reminders for this long |
| `reminders.alarm_at_due_time` | `true` | A due time set in the organizer gets an alarm when the reminder has none |
| `log_path` | `null` | Another log file |

## Troubleshooting

- **`doctor` says the token was rejected (401/403).** The token was revoked, mistyped, or lacks the `ingest`
  scope. Create a new one and run `set-token` again. The background helper picks it up on its next request.
- **`doctor` says the token was rejected, and the organizer is behind Cloudflare Access.** Cloudflare
  refused the request before it reached the organizer. Set `server.cf_access_client_id` and the secret
  (above), and check that the Access application has a "Service Auth" policy for that service token.
- **"server.url is not configured".** Set `server.url` to an `https://` address (or `http://` to this Mac).
- **"server.url uses plain http to another host".** Use https. On a network you trust you can set
  `server.allow_insecure_http` to `true` instead.
- **"... is writable by other users".** Run `chmod 600` on the config, as the message says.
- **"reachable, but /api/ingest/calendar is not there (HTTP 404)".** `server.url` points to the wrong place,
  or to a path in front of the organizer.
- **No permission prompt appeared.** The prompt appears only for the background helper, not for commands run
  in Terminal. Run `organizer-helper install`, then look in System Settings → Privacy & Security. `doctor` shows
  whether the program carries its embedded Info.plist and a signature with the same bundle id. If not,
  reinstall with `scripts/install.sh`.
- **A Keychain prompt asks to allow `organizer-helper`.** The program's signature changed since `set-token`
  stored the item (an ad-hoc rebuild, for example). Choose Always Allow, or run `set-token` again with the new
  program.
- **A change from the organizer failed.** `organizer-helper status` and the log show why. Common causes: the
  list is read-only, or the reminder was deleted on another device.
- **"another helper is running".** Two copies would apply every change twice, so the second one refuses to
  start. Stop the other copy, or run `organizer-helper uninstall` first.

## Releasing (maintainers)

`scripts/release.sh` builds a universal (arm64 and x86_64) binary. It signs the binary with a Developer ID, the
hardened runtime, a secure timestamp and the calendars entitlement (there is no separate reminders
entitlement), then notarizes it with `notarytool`:

```bash
SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=profile \
INSTALLER_IDENTITY="Developer ID Installer: ..." scripts/release.sh   # a stapled .pkg
SIGN_IDENTITY=... NOTARY_PROFILE=... scripts/release.sh               # a notarized .zip (not stapled)
scripts/release.sh --unsigned                                         # a test build
BUNDLE_ID=org.example.helper scripts/release.sh ...                   # another bundle id
```

The script checks the identities before it builds. With `BUNDLE_ID`, the embedded Info.plist is generated with
that id, and users of the build set the same `bundle_id` in their config. Artifacts go to `dist/` with a
`.sha256` file. Keep the version in `Resources/Info.plist` and `Sources/HelperCore/Support/Version.swift` the
same; a test checks this.
