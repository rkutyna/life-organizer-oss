# Life Organizer for Mac: the native app

A native macOS app for your own Life Organizer server. It is a client of the server's REST API,
like the web app: it holds no data of its own beyond a cache, and every change goes through the
server.

- **Calendar:** agenda, day, week, month and year views over every source, with the freshness of
  each mirrored source.
- **Reminders:** lists, Today, Upcoming and All, quick-add with natural-language dates
  ("Call the plumber tomorrow 3pm !1"), complete and edit, and each change's sync state.
- **Jobs:** pipeline counts, applications, leads, contacts, interviews and events, record views,
  status changes, apply or drop a lead.
- **Mail:** a read-only inbox and reader. Every message is marked untrusted, with the sender
  checks the server reports.
- **Settings:** server address, API token, connection test, an optional Cloudflare Access
  service token, and (Settings window → Helper) the Mac helper run inside the app.

You build it yourself with Xcode. **No paid Apple developer account is needed** (see "What needs
a paid account" below).

## Prerequisites

| What | Version |
|---|---|
| macOS to **run** the app | 15 (Sequoia) or later |
| Xcode to **build** it | 26 or later (Swift 6.2), from the App Store; it needs a recent macOS 15 or later |
| A Life Organizer server | running and set up (docs/SETUP.md) |
| An Apple ID | optional; a free one signed in to Xcode keeps permissions across rebuilds (below) |

After installing Xcode, open it once to accept the license, and check that the command line uses
it: `xcode-select -p` should print `/Applications/Xcode.app/Contents/Developer` (if not:
`sudo xcode-select -s /Applications/Xcode.app`).

## Build

### From the command line

```bash
apple/scripts/test.sh              # the package tests (no server, no network)
apple/scripts/build.sh             # builds, signed "to run locally" with no team
open "apple/.build/DerivedData/Build/Products/Debug/Life Organizer.app"
```

`build.sh --release` builds the Release configuration. The script runs:

```bash
xcodebuild -project apple/LifeOrganizer.xcodeproj -scheme LifeOrganizer -destination 'platform=macOS' \
  -derivedDataPath apple/.build/DerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

To keep the app, copy it to `/Applications` (or `~/Applications`) yourself. Gatekeeper doesn't
block an app you built on this Mac.

### From Xcode

1. Open `apple/LifeOrganizer.xcodeproj`.
2. Choose the scheme **LifeOrganizer** and the destination **My Mac**.
3. Product → Run (⌘R).

Signing is preset to **Sign to Run Locally** with no team (`apple/Config/App.xcconfig`); you
don't need to change it. To sign with your own (free) Apple ID instead, which keeps macOS's
permission grants and Keychain access across rebuilds, create `apple/Config/Local.xcconfig`
(ignored by git):

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
```

Your team id is in Xcode → Settings → Accounts. `DEVELOPMENT_TEAM=ABCDE12345 apple/scripts/build.sh`
does the same from the command line.

## First launch

The app opens a sheet asking for two things:

1. **Server address:** the address you open your organizer at in a browser, for example
   `http://localhost:8600` (the organizer on this Mac, the default), your Tailscale address
   `https://<machine>.<tailnet>.ts.net`, or your Cloudflare hostname.
2. **API token:** in the web app, open **Settings → API tokens** and make a token with author
   **me** and the scopes **api** and **mail**. Copy it; the web app shows it once.

**Check and Save** tests both before saving:

| Result | Meaning |
|---|---|
| Connected | Done. |
| Connected, but no mail scope | Everything but Mail works. Make a token with both scopes. |
| 401 | The token is mistyped or was revoked. Make a new one. |
| 403 | The token lacks the `api` scope (an `ingest` or `mail`-only token). |
| Can't reach the organizer | Wrong address, the server is down, or your VPN/tunnel is off. |

The token is kept in your login Keychain (service `com.lifeorganizerformac.app`, account
`api-token`) and is never shown or logged. Settings (⌘, or the sidebar) changes the address or the
token later, and has **Test Connection**.

Plain `http://` is fine to this Mac. To another machine it sends the token unencrypted, and
Settings warns about it; use HTTPS (Tailscale or Cloudflare, docs/SETUP.md).

### Behind Cloudflare Access

If your organizer is behind Cloudflare Access, the app needs an Access **service token** of its
own (docs/CLOUDFLARE.md explains how to make one and which "Service Auth" policy to add). Enter
its Client ID and Client Secret in Settings, section **Advanced: Cloudflare Access service
token**. The secret goes in the Keychain (account `cf-access-client-secret`); the client id is not
a secret. When both are set, every request carries `CF-Access-Client-Id` and
`CF-Access-Client-Secret` alongside `Authorization: Bearer`. The secret is never logged.

### Environment variables (development)

| Variable | Overrides |
|---|---|
| `ORGANIZER_BASE_URL` | the server address |
| `ORGANIZER_TOKEN` | the API token (the Keychain is then not read) |
| `ORGANIZER_CF_ACCESS_CLIENT_ID`, `ORGANIZER_CF_ACCESS_CLIENT_SECRET` | the Access service token (both must be set) |

In Xcode, Product → Scheme → Edit Scheme → Run → Arguments has the first two, unticked. From a
shell:

```bash
ORGANIZER_BASE_URL=http://localhost:8601 ORGANIZER_TOKEN=... \
  "apple/.build/DerivedData/Build/Products/Debug/Life Organizer.app/Contents/MacOS/Life Organizer"
```

## The Mac helper inside the app (optional)

The Mac helper (`mac-helper/`) sends Apple Calendar and Apple Reminders to your organizer and
applies the reminder changes you make there. You can run it as its own background program
(mac-helper/README.md), or inside this app, while the app is open:

1. In the web app, make a **second** token: author **helper**, scope **ingest** only.
2. In the app's Settings window (⌘,) → **Helper**, paste it and **Save Token**. It is kept in the
   Keychain apart from the app's token (account `helper-ingest-token`).
3. Press **Request Access** and allow Calendars and Reminders (Full Access).
4. Turn on **Run the Mac helper in this app**.

It is off by default, and it never asks for permissions on its own. It uses the app's server
address and Access service token. It takes the same lock as the command-line helper, so it
refuses to start while that one runs (and the other way round): use one or the other. To switch
from the LaunchAgent, run `organizer-helper uninstall` first. Its status file and log are the
command-line helper's (`~/Library/Application Support/LifeOrganizerHelper/`,
`~/Library/Logs/LifeOrganizerHelper/`).

## Permissions

| What | When | Why |
|---|---|---|
| Keychain | first save of a token | the API token, the helper's token, the Access secret |
| Calendars, Reminders | only after Request Access in Settings → Helper | the in-app helper |
| Local network | the first request to a server on your LAN | macOS asks before an app talks to the local network |

The app is **not sandboxed**: the in-app helper uses EventKit the way the command-line helper does,
and the app reads nothing else on your Mac. It has no hardened runtime either; only notarized
distribution needs one.

**Rebuilding with "Sign to Run Locally":** an ad-hoc signature changes with every build, and
macOS ties permissions and Keychain access to the signature. After a rebuild, macOS may ask again
for Calendars and Reminders access (or list the app twice in System Settings → Privacy &
Security), and may ask once to allow access to the Keychain item: choose **Always Allow**.
Signing with your own Apple ID (above) avoids both.

## Troubleshooting

- **"Can't reach the server."** Open the same address in a browser on this Mac. On the
  organizer's own Mac it is `http://localhost:8600`; from another Mac use the Tailscale or
  Cloudflare address, not `localhost`.
- **401 in Test Connection.** The token is mistyped or revoked. Make a new one (author me, scopes
  api and mail) and Save Token.
- **403, or Mail says "no mail scope".** The token lacks a scope. Tokens can't be edited: make a
  new one with both scopes.
- **Behind Cloudflare, every request fails (often with a 403 or a login page).** Set the Access
  service token in Settings → Advanced, and check the Access application has a "Service Auth"
  policy for it.
- **A Keychain prompt about "Life Organizer".** The app was rebuilt with a new ad-hoc signature.
  Choose Always Allow, or sign with your Apple ID.
- **The helper says another helper is running.** The command-line helper's LaunchAgent is loaded:
  `organizer-helper uninstall`, then turn the switch off and on.
- **The helper can't read calendars or reminders.** System Settings → Privacy & Security →
  Calendars (and Reminders): turn on Life Organizer, then turn the helper off and on.
- **Old data with an "as of" badge.** The app shows its last good copy when a refresh fails;
  the badge says how old it is. ⌘R refreshes the screen on show. Settings → Clear Cached Data
  empties the cache (`~/Library/Caches/com.lifeorganizerformac.app`). Mail is never cached.
- **Build fails with "tools version 6.2" or `defaultIsolation`.** Xcode is older than 26.
- **Build fails asking for a team.** Run `apple/scripts/build.sh` (it passes no team), or check
  that `apple/Config/Local.xcconfig` names a team you are signed in to.

## What needs a paid account

| You want to | Account |
|---|---|
| Build and run the app on your own Mac | none |
| Keep permissions across rebuilds | a free Apple ID in Xcode (optional) |
| Give a ready-made, notarized app to other people | the Apple Developer Program (paid): Developer ID signing, hardened runtime, notarization |

Nothing in the app needs a paid feature: no App Groups, push, iCloud or other capability.

## For developers

```
apple/
  LifeOrganizer.xcodeproj   the app target (App/ is a synchronized folder: add files, no pbxproj edit)
  App/                      @main, the in-app helper (HelperCore) and its Settings tab
  Config/                   App.xcconfig (identity and signing), Info.plist, optional Local.xcconfig
  OrganizerKit/             the Swift package with almost all the code
    openapi.json            the server's schema snapshot the types are generated from
    Sources/OrganizerAPI/   Generated/ (never edit), the client, the cache, Modules/ facades
    Sources/OrganizerCore/  address, token and Access rules, Keychain store, connection check,
                            Resource/Loadable freshness, quick-add parser
    Sources/OrganizerUI/    DesignSystem/, Shell/ (sidebar, Settings, first launch), Features/<Module>/
    Tests/                  StubServer tests; opt-in snapshot and live-write tests
  scripts/                  build.sh, test.sh, gen-api.sh + gen-api.py, quickadd-golden.mjs
```

- **Identity:** bundle id `com.lifeorganizerformac.app` (`LO_BUNDLE_ID` in `Config/App.xcconfig`),
  display name "Life Organizer", URL scheme `lifeorganizer://<module>/<path>?<query>` (for example
  `lifeorganizer://jobs/applications/3`), Keychain service = the bundle id.
- **Deployment target:** macOS 15. The package uses Swift 6.2's default main-actor isolation for
  the UI, hence Xcode 26.
- **API types** are generated, never written by hand. Run a local server with
  `EXPOSE_API_DOCS=true` (docs/SETUP.md, "Development"), then
  `apple/scripts/gen-api.sh http://localhost:8601` (`--offline` regenerates from the snapshot).
  The script refuses any host but this Mac. Commit `openapi.json` and `Generated/` together.
- **Client:** sends `Authorization: Bearer` (and the Access headers when set); an error shows the
  server's own message. Every GET but mail is saved as the last good copy; a screen starts from it
  and shows its age when older than 5 minutes or when a refresh failed.
- **A module** is a store (`@Observable`, one `Resource` per read) and a screen in
  `Features/<Module>/`, registered in `Shell/ModuleRegistry.swift`. Calendar is the reference.
- **Looking at screens without a window:** with a local demo server (docs/SETUP.md, "Demo data")
  and a token for it,
  `ORGANIZER_TEST_SERVER=http://localhost:8601 ORGANIZER_TEST_TOKEN=... ORGANIZER_SNAPSHOT_DIR=/tmp/shots apple/scripts/test.sh --filter Snapshot`
  draws each screen to a PNG (add `ORGANIZER_SNAPSHOT_APPEARANCE=dark`). Offscreen drawing leaves
  out materials, so a selected sidebar row shows as a dark block there, not in the app.
- **Writes against a demo server:** `ORGANIZER_LIVE_WRITES=1` plus the two variables above runs
  `--filter LiveWrite`, which completes a reminder and changes an application's status through
  the app's stores. Only ever against a throwaway demo database.
