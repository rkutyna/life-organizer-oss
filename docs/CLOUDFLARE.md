# Cloudflare: a tunnel, and the web app behind Access

This page sets up a **Cloudflare Tunnel** for your install and puts the **web app** on a hostname
of your own, behind **Cloudflare Access**. The claude.ai connector uses the same tunnel; its own
steps are in [REMOTE-CONNECTOR.md](REMOTE-CONNECTOR.md).

If you only want the web app on your own phone and computers, **Tailscale is simpler**
([SETUP.md](SETUP.md), "Reach it from your other devices"): nothing is on the public internet,
and there is no domain to buy. Use Cloudflare for the web app when you want it reachable from
any browser, or when you already need Cloudflare for the claude.ai connector. Mixing the two is
fine: Tailscale for your devices, Cloudflare only for the connector.

Cloudflare's dashboard changes from time to time. The names below were checked against
Cloudflare's documentation in November 2026, and each step links the page it comes from. If a
label differs on your screen, follow the linked page.

## What you need

- **A domain on Cloudflare.** The domain's DNS must be served by Cloudflare
  ([Add a site](https://developers.cloudflare.com/fundamentals/manage-domains/add-site/)). The
  examples use `example.com`; you pick the hostnames, such as `organizer.example.com`.
- **A Cloudflare Zero Trust organization.** The Free plan covers up to 50 users, far more than
  one person needs ([plans](https://www.cloudflare.com/plans/sase-zero-trust/)). Creating it
  asks for a team name; your **team domain** is then `<team>.cloudflareaccess.com`, shown under
  Zero Trust → Settings ([FAQ](https://developers.cloudflare.com/cloudflare-one/faq/getting-started-faq/)).
- **Setup finished locally first.** Until setup has run, whoever opens the page first chooses
  the password. Run it at http://localhost:8600 before any hostname points at the organizer.

## 1. Create the tunnel

A tunnel is an outbound connection from your machine to Cloudflare. Nothing listens on a public
port, and your router needs no changes.

1. In the Cloudflare dashboard, go to **Networking → Tunnels** and select **Create Tunnel**.
   Name it (for example `organizer`) and create it
   ([Cloudflare: set up a tunnel](https://developers.cloudflare.com/tunnel/setup/)). Older guides
   and the Zero Trust dashboard show the same list under Networks → Tunnels.
2. Under **Setup Environment**, choose **Docker**. The page shows a command such as
   `docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token eyJ...`.
   **Don't run it.** Copy only the long token after `--token`. It is a secret: anyone who has it
   can run your tunnel.
3. Run `cloudflared` one of two ways:

   **In this compose project (simplest).** Put the token in `.env` and switch on the
   `cloudflare` profile:

   ```bash
   CLOUDFLARE_TUNNEL_TOKEN=eyJ...
   COMPOSE_PROFILES=cloudflare          # add remote-mcp etc. later, comma-separated
   ```

   Then `docker compose up -d`. The `cloudflared` service passes the token in the environment
   (`TUNNEL_TOKEN`, [run parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/run-parameters/)),
   so it never appears in a process list. It reaches the other services by name:
   `http://organizer:8600`, `http://organizer-mcp:8601`, `http://organizer-mcp-mail:8601`.

   **On the host.** If you already run `cloudflared` on the machine (as a system service or your
   own container), use it. Its routes then point at the loopback ports the compose file
   publishes: `http://127.0.0.1:8600` (web app), `http://127.0.0.1:8601` (connector),
   `http://127.0.0.1:8602` (mail connector). A `cloudflared` container outside this project can't
   reach the host's loopback; join it to this project's network and use the service names
   instead.
4. Back in the dashboard, wait until the tunnel shows as connected (Healthy), then **Continue**.

**Check:** `docker compose logs cloudflared` shows lines like `Registered tunnel connection`.

**Firewall.** `cloudflared` needs **outbound** TCP and UDP to port 7844 (and optionally 443 for
update checks); it needs **no inbound** port at all
([tunnel with a firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)).
Keep the organizer's and the connectors' ports on loopback, as the compose file publishes them.

## 2. Route the web app's hostname

1. **Networking → Tunnels** → your tunnel → **Routes** → **Add route** → **Published
   application** ([setup](https://developers.cloudflare.com/tunnel/setup/)).
2. **Hostname:** `organizer` and your domain. **Service URL:** `http://organizer:8600`
   (cloudflared in this project) or `http://127.0.0.1:8600` (cloudflared on the host).
3. Select **Add route**.
4. Check **DNS → Records** for a proxied CNAME `organizer` pointing at
   `<tunnel-id>.cfargotunnel.com`. Cloudflare's setup page doesn't say whether the dashboard
   always creates it; if it is missing, add it yourself (proxied).

**Don't open the hostname yet.** Until the Access application below exists, it is public, with
only the organizer's password in front.

## 3. Put Access in front of the web app

1. **Zero Trust → Access controls → Applications → Create new application → Self-hosted and
   private** ([self-hosted application](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)).
2. **Add public hostname:** `organizer` on your domain, no path.
3. **Access policies:** create an **Allow** policy whose rule includes only your own email
   address. Applications are deny-by-default: anyone who matches no Allow policy is refused.
4. **Login method:** new Zero Trust organizations sign people in with Cloudflare's own identity
   provider by default. To get a code by email instead, add **One-time PIN** under
   Zero Trust → Integrations → Identity providers
   ([One-time PIN](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/one-time-pin/)).
   A GitHub or Google login works too.
5. **Session Duration:** how often Access asks you to sign in again, for example 24 hours or a
   week.
6. Leave **Managed OAuth** off for the web app. It is for the claude.ai connector's
   hostname, not for browsers.
7. **Create.**

**Check:** in a private browser window, open `https://organizer.example.com`. Cloudflare's
sign-in page appears first; after it, the organizer's own sign-in. From a terminal,
`curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://organizer.example.com` answers
`302` with a URL on `<team>.cloudflareaccess.com`, never `200`.

## 4. Tell the organizer its address

In `.env`:

```bash
PUBLIC_BASE_URL=https://organizer.example.com
COOKIE_SECURE=always
```

Then `docker compose up -d` (a plain `restart` does not read `.env` again).

- `COOKIE_SECURE=always` makes the session cookie HTTPS-only.
- `PUBLIC_BASE_URL` is the address the organizer builds OAuth redirect URIs from. For Google,
  the redirect URI becomes `https://organizer.example.com/api/oauth/google/callback`; add exactly
  that under *Authorized redirect URIs* in your Google OAuth client ([GOOGLE.md](GOOGLE.md)).

## What Access does and doesn't cover

- **Browsers** pass Access with its cookie, then sign in to the organizer. Installing the web app
  on a phone's home screen works over this HTTPS address.
- **Apps and programs that use an API token instead of a browser** (the Mac app, the Mac helper,
  Claude Code's stdio MCP server on another machine, your scripts) can't sign in to Access, so
  Access stops them at Cloudflare. Give each one a **service token** (step 5). Clients on the
  organizer's own machine can skip Access altogether with `http://localhost:8600`, and Tailscale
  works too.
- **The claude.ai connector** is different again: it has its own hostname and Access
  application, with OAuth ([REMOTE-CONNECTOR.md](REMOTE-CONNECTOR.md)). Its container talks to
  the organizer on the compose network and needs no service token.
- **The organizer's own password still applies** behind Access. Access keeps strangers from
  reaching the sign-in page at all.

## 5. Let your apps through: service tokens

A Cloudflare Access **service token** is a client id and secret that a program sends as two
headers, `CF-Access-Client-Id` and `CF-Access-Client-Secret`. Access lets a request with a valid
pair through to the organizer, which then checks the program's organizer API token as usual. So
the program needs both: the service token gets it past Cloudflare, the API token gets it into
the organizer
([service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)).

Make **one service token per client** (Mac app, Mac helper, Claude Code), so you can revoke one
without touching the others.

### Create the token (you, in the dashboard)

1. **Zero Trust → Access controls → Service credentials → Service Tokens → Create Service
   Token.**
2. Name it after the client, for example `organizer-mac-helper`. The name shows in Access's logs.
3. **Service Token Duration:** how long it stays valid. Pick a year, or what you are comfortable
   with; Cloudflare can warn you before it runs out (below).
4. **Generate token.** Cloudflare shows the **Client ID** and the **Client Secret**. The secret is
   shown **only this once**: copy it straight into the client (below) or your password manager.
   If you lose it, make a new token.

### Allow it on the web app's Access application

1. **Zero Trust → Access controls → Applications** → the application for
   `organizer.example.com` → **Edit** → its policies.
2. Add a policy with the action **Service Auth** (not Allow: with Allow, Access would ask the
   program to sign in with a browser). In its rule, **Include → Service Token** and choose the
   token, or list all your clients' tokens
   ([policy actions and selectors](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)).
   Don't use **Any Access Service Token**: that admits every service token in your account,
   including ones made for something else. A **Service Token Tag** selector also works, if you
   tag your tokens.
3. Keep your existing **Allow** policy for your email; browsers still use it. Access evaluates
   Service Auth policies before Allow policies.
4. **Save.**

**Check** (with the id and secret in your own shell, not pasted into an AI chat):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://organizer.example.com/api/health
# 302: no service token, Access sends it to sign-in
curl -s -H "CF-Access-Client-Id: $CF_ID" -H "CF-Access-Client-Secret: $CF_SECRET" \
  https://organizer.example.com/api/health
# {"ok":true}: Access let it through
```

### Give each client its id and secret

| Client | Where the service token goes |
|---|---|
| Mac app | Settings → Advanced. Or the environment variables `ORGANIZER_CF_ACCESS_CLIENT_ID` and `ORGANIZER_CF_ACCESS_CLIENT_SECRET`, which override the settings ([apple/README.md](../apple/README.md)) |
| Mac helper | Its config: `server.cf_access_client_id` and `server.cf_access_client_secret`, or the secret in the macOS Keychain instead of the file ([mac-helper/README.md](../mac-helper/README.md)) |
| MCP server (Claude Code over stdio) | The environment variables `ORGANIZER_CF_ACCESS_CLIENT_ID` and `ORGANIZER_CF_ACCESS_CLIENT_SECRET`, beside `ORGANIZER_URL` and the API token ([MCP.md](MCP.md)) |
| Your own scripts | Send the two headers with every request, beside `Authorization: Bearer <API token>` |

Each client still uses `https://organizer.example.com` as the server address and its own
organizer API token.

### Expiry, rotation and revoking

- **Expiry.** A service token stops working at the end of its duration, and the client is then
  sent to Access's sign-in like a stranger. To be warned, add a notification: **Notifications →
  Add → Expiring Access Service Token**; it fires a week before. **Refresh** on the token adds a
  year; **Edit** sets another duration.
- **Rotating the secret.** **Rotate secret** issues a new secret and keeps the Client ID. Choose a
  grace period (one hour to 30 days) during which the old secret still works, put the new secret
  in the client, and the old one dies at the end of it. Or **Revoke immediately**.
- **Revoking.** **Delete** the token to cut that client off for good; **Disable token** does it
  reversibly. Removing the token from the Service Auth policy also stops it at this application.
  The organizer API token is separate: revoke it in Settings → API tokens if the client itself
  is lost.
- If a client's secret may have leaked, rotate it with **Revoke immediately**, then check the
  organizer's History for writes you didn't make.

## Turning it off

- Remove the route from the tunnel (Routes), or delete the Access application to lock the
  hostname out. Without a route, the hostname answers with a Cloudflare error.
- Stop the tunnel: drop `cloudflare` from `COMPOSE_PROFILES` and run
  `docker compose rm -sf cloudflared` (dropping the profile alone leaves a running container up).
- Delete the tunnel in **Networking → Tunnels** to invalidate its token.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `docker compose logs cloudflared` says `"cloudflared tunnel run" requires the ID or name of the tunnel` | `CLOUDFLARE_TUNNEL_TOKEN` is empty in `.env`, or `.env` wasn't re-read: run `docker compose up -d` |
| cloudflared logs authentication or `Unauthorized` errors | The token was mistyped, or the tunnel was deleted. Copy the token again from the tunnel's page |
| Cloudflare error 1033 on the hostname | The tunnel isn't connected. Check the cloudflared logs and outbound port 7844 |
| Error 502 on the hostname | The route's Service URL is wrong: `http://organizer:8600` only works for cloudflared in this project; on the host use `http://127.0.0.1:8600` |
| The organizer loads without Cloudflare's sign-in first | No Access application covers that hostname. Add one now, and check its policy allows only you |
| Google says `redirect_uri_mismatch` | `PUBLIC_BASE_URL` isn't set, or the URI in Google's console differs from the one Settings shows |
| Signed out on every visit | `COOKIE_SECURE=always` while reaching the organizer over plain `http://`; use the HTTPS hostname |
| An app or the MCP server reports "Cloudflare Access stopped ..." or a redirect to `cloudflareaccess.com` | It has no service token, or the token expired, was revoked, or isn't in the application's Service Auth policy (step 5) |
| A service token gets the sign-in page although it is valid | The policy's action is Allow instead of Service Auth |
