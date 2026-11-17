# The claude.ai connector, through Cloudflare

This page makes your organizer a **custom connector** in Claude: claude.ai on the web, the
desktop app and the mobile apps all use the connectors on your Claude account. It is the
end-to-end setup: Cloudflare Tunnel, a Cloudflare Access application that does the OAuth
sign-in, the `organizer-mcp` container, and adding the connector in Claude.

For Claude Code, you don't need any of this: the stdio server in [MCP.md](MCP.md) is simpler and
never leaves your machine. (If your organizer's web hostname is behind Cloudflare Access, the
stdio server reaches it with a service token; see [CLOUDFLARE.md](CLOUDFLARE.md), step 5. The
connector below needs none: its container talks to the organizer on the compose network.) The tunnel itself is covered in [CLOUDFLARE.md](CLOUDFLARE.md); this
page assumes you have one.

The Cloudflare and Claude names below were checked against their documentation in November 2026,
and each step links the page it comes from. Where the documentation doesn't settle a point, this
page says so.

## How it fits together

Claude calls a custom connector **from Anthropic's cloud**, not from your device, on every
surface. So the endpoint must be reachable from the internet over HTTPS on port 443, and a
Tailscale address won't do
([About custom connectors](https://support.claude.com/en/articles/11175166-about-custom-connectors)).
Claude's connectors sign in with OAuth 2.0
([Authentication for connectors](https://claude.com/docs/connectors/building/authentication.md)).
Cloudflare Access's **Managed OAuth** turns an Access application into exactly that kind of
OAuth server, so the organizer runs no OAuth code of its own
([Managed OAuth](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/)).

```
Claude (Anthropic's cloud)
   │ HTTPS  https://organizer-mcp.example.com/mcp   (Bearer: Access OAuth token)
   ▼
Cloudflare edge
   ├─ optional WAF rule: / and /mcp only from Anthropic's published range
   └─ Access application, Managed OAuth on, your email only
        • no token → 401 + WWW-Authenticate → Claude registers itself, you sign in once
        • valid token → forwards the request with a signed Cf-Access-Jwt-Assertion
   │ Cloudflare Tunnel (outbound from your machine)
   ▼
organizer-mcp container (port 8601; profile remote-mcp)
   ├─ Host must be MCP_PUBLIC_HOST                                  else 421
   ├─ assertion: RS256 by your team's keys, aud = CF_ACCESS_AUD,
   │  iss = your team domain, not expired, email = MCP_ALLOWED_EMAIL  else 401
   └─ the same tools as the stdio server, with an api token (author claude_remote)
   ▼
organizer:8600 (on the compose network; never routed through the tunnel)
```

Three layers, each enough on its own to stop a stranger:
- **Access** lets only your identity get a token.
- **The container** re-checks Access's signature, audience, issuer and email on every request,
  so a misrouted tunnel or another program on the machine can't call your tools through it.
- **The token** the container holds limits what it can do: the `api` scope never reads mail, and
  every write is logged under `claude_remote` and can be reverted from History.

**Mail** gets a second, separate connector on its own hostname, Access application and `mail`
token ([below](#the-mail-connector)). The main connector can't be given mail: the server refuses
to serve mail beside any tool that writes.

## Before you start

- The organizer running, with setup finished at http://localhost:8600.
- A domain on Cloudflare and a Zero Trust organization (free), with a tunnel running
  ([CLOUDFLARE.md](CLOUDFLARE.md), steps 1 and the firewall note). You don't need the web app's
  hostname for this; the connector has its own.
- Your **team domain**, `<team>.cloudflareaccess.com`, from Zero Trust → Settings
  ([FAQ](https://developers.cloudflare.com/cloudflare-one/faq/getting-started-faq/)).
- A hostname for the connector. The examples use `organizer-mcp.example.com`.
- A Claude plan with custom connectors: Free (one custom connector), Pro, Max, Ultra, Team or
  Enterprise. On Team and Enterprise, an Owner adds it
  ([About custom connectors](https://support.claude.com/en/articles/11175166-about-custom-connectors)).

## 1. The organizer token

In the organizer, **Settings → API tokens**: make a token with scope **API** only and author
**Claude (remote)** (`claude_remote`). Copy it; it is shown once. Put it in `.env`:

```bash
ORGANIZER_MCP_TOKEN=org_...
```

The author makes History tell the connector's writes apart from Claude Code's (`claude`).

## 2. The Access application

1. **Zero Trust → Access controls → Applications → Create new application → Self-hosted and
   private** ([self-hosted application](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)).
2. **Add public hostname:** `organizer-mcp` on your domain, **no path**. The OAuth endpoints
   Access adds live on this hostname too, so the application must cover all of it.
3. **Access policies:** an **Allow** policy that includes only your email address.
4. **Login method:** Cloudflare's default identity provider, or **One-time PIN** (a code by
   email; Zero Trust → Integrations → Identity providers,
   [One-time PIN](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/one-time-pin/)).
   With a single login method, **Apply instant authentication** skips the chooser.
5. **Create**, then edit the application again and open **Advanced settings**
   ([Managed OAuth](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/)):
   - Turn **Managed OAuth** on.
   - **Allowed redirect URIs:** `https://claude.ai/api/mcp/auth_callback`. That is the callback
     every hosted Claude app uses: web, desktop, mobile
     ([callback URLs](https://claude.com/docs/connectors/building/authentication.md)).
   - **Access token lifetime:** the default is 15 minutes; leave it. Claude refreshes on its own.
   - **Grant session duration:** how long Claude may keep refreshing before you sign in again,
     for example 30 days. Cloudflare suggests short tokens and a grant of one to two weeks for
     agents; longer means fewer sign-ins, shorter means a lost grant dies sooner.
   - Leave **Allow localhost clients** and **Allow loopback clients** off. They are for local
     tools such as Claude Code; use the stdio server there instead.
   - **Save.**
6. Copy the **Application Audience (AUD) Tag**: edit the application, **Additional settings**
   ([validate the JWT](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)).

With Managed OAuth on, Access answers a client without a token with `401` and a
`WWW-Authenticate` header pointing at its OAuth metadata, instead of redirecting to a login page.
Its discovery document is at `https://organizer-mcp.example.com/.well-known/oauth-authorization-server`.
Access issues opaque tokens to Claude and forwards each allowed request with a signed
`Cf-Access-Jwt-Assertion`, which the container verifies.

## 3. The tunnel route

**Networking → Tunnels** → your tunnel → **Routes** → **Add route** → **Published application**
([setup](https://developers.cloudflare.com/tunnel/setup/)):

- **Hostname:** `organizer-mcp` on your domain.
- **Service URL:** `http://organizer-mcp:8601` if cloudflared runs in this compose project
  (profile `cloudflare`), or `http://127.0.0.1:8601` if it runs on the host.
- **Additional application settings → HTTP → HTTP Host Header:** `organizer-mcp.example.com`
  ([origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/origin-parameters/)).
  The container refuses any other Host with `421`; setting it makes sure the public name
  arrives whatever cloudflared would otherwise send.

**Never route this hostname to port 8600.** The organizer behind it would then face the
internet with only its password, and Access's OAuth tokens would mean nothing to it.

Check **DNS → Records** for a proxied CNAME `organizer-mcp` to `<tunnel-id>.cfargotunnel.com`,
and add it if the dashboard didn't.

## 4. Settings and start

In `.env`, uncomment and fill in (`.env.example` lists them all):

```bash
COMPOSE_PROFILES=cloudflare,remote-mcp       # drop "cloudflare" if cloudflared runs on the host
ORGANIZER_MCP_TOKEN=org_...                  # step 1
CF_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com
CF_ACCESS_AUD=<the AUD tag from step 2>
MCP_PUBLIC_HOST=organizer-mcp.example.com
MCP_ALLOWED_EMAIL=you@example.com            # exactly the email your Access policy allows
```

Optional: `ORGANIZER_MCP_TOOLSETS` (default `all`: calendar, jobs, reminders; never mail) and
`ORGANIZER_MCP_READ_ONLY=1` to serve no write tools at all ([MCP.md](MCP.md), Toolsets).

```bash
docker compose up -d --build
docker compose logs organizer-mcp
```

The log's first line is `serving toolsets calendar,jobs,reminders on 0.0.0.0:8601 for
organizer-mcp.example.com`. If a setting is missing, the container exits instead and the log
names it, for example `CF_ACCESS_AUD must be set for the HTTP server; it never serves without
Access` or `ORGANIZER_TOKEN is not set: ...` (the `.env` name is `ORGANIZER_MCP_TOKEN`).

## 5. Test it with curl

On the machine itself, against the container:

```bash
curl -si -X POST http://127.0.0.1:8601/mcp -H 'Host: organizer-mcp.example.com'
# HTTP/1.1 401 Unauthorized ... {"detail":"Cloudflare Access assertion missing or invalid"}
curl -si http://127.0.0.1:8601/mcp
# HTTP/1.1 421 Misdirected Request   (wrong Host)
```

From anywhere, through Cloudflare (before you add the optional WAF rule):

```bash
curl -si https://organizer-mcp.example.com/mcp
# HTTP/2 401, with a www-authenticate header that names Access's metadata
curl -s https://organizer-mcp.example.com/.well-known/oauth-authorization-server
# JSON with authorization_endpoint, token_endpoint and registration_endpoint
```

Read the 401 closely, because two different things can answer it:
- **From Access** (what you want): a `www-authenticate: Bearer ...resource_metadata=...` header.
  Cloudflare's documentation doesn't show the header's exact text, so check only that it is
  there.
- **From the container:** the JSON body `Cloudflare Access assertion missing or invalid` and no
  `www-authenticate` header. That means the request reached your machine without passing Access:
  the Access application doesn't cover this hostname. Fix that before going on.
- A `302` to `<team>.cloudflareaccess.com` instead of a 401 means Managed OAuth is off.

## 6. Add the connector in Claude

On Free, Pro, Max or Ultra ([add a custom connector](https://claude.com/docs/connectors/custom/add-unlisted.md)):

1. **Customize → Connectors** → **Add** → **Add custom connector**.
2. **Name:** `Organizer`. **URL:** `https://organizer-mcp.example.com/mcp`. **Continue.**
3. **Authentication:** **Sign in now**.
4. **OAuth client:** **Register automatically**. That is Dynamic Client Registration, which
   Access's Managed OAuth provides. Claude's default, *Use Claude's published identity* (a Client
   ID Metadata Document), needs the authorization server to advertise support for it; Cloudflare's
   Managed OAuth page doesn't mention it, and Claude falls back to registration when it isn't
   advertised. If Claude marks an option **Detected**, keeping it is fine.
5. **Add**, then **Connect** if it shows, and sign in through Cloudflare Access (with One-time
   PIN, the code arrives by email). You land back on the Connectors page with the connector
   **Connected**.

On Team or Enterprise, an Owner adds it under **Organization settings → Connectors → Add →
Custom → Web**, and you then **Connect** it under Customize → Connectors.

**If sign-in fails** with "Authorization with the MCP server failed", remove the connector and
add it again with the bare `https://organizer-mcp.example.com`. Claude requires the OAuth
metadata's `resource` to equal the connector URL exactly, path included, and Cloudflare's
documentation doesn't say which form Access advertises. The container answers MCP at both `/`
and `/mcp`, so either URL works without a rebuild. Authentication settings can't be edited after
adding; to change them, remove the connector and add it again.

**Use it.** In a chat, **+** → **Connectors** turns each connector on or off for that
conversation. Connected connectors are available on the web, in the desktop app and in the
mobile apps, and in Claude Code when it is signed in with the same Claude account
([Get started with connectors](https://claude.com/docs/connectors/getting-started.md)).
Whether Claude's voice mode and other assistant surfaces use custom connectors is not stated in
the pages cited here; try it there.

## 7. Tool permissions

Claude can ask for your approval before it uses a tool (**Allow once** or **Always allow** in
the chat). Set it ahead of time under **Customize →
Connectors** → `Organizer` → **Tool permissions**: **Always allow**, **Needs approval** or
**Blocked**, per group or per tool
([manage a connector](https://claude.com/docs/connectors/getting-started.md)).

Recommended:

| Tools | Setting |
|---|---|
| Reads: `calendar`, `calendar_sources`, `reminders`, `reminder_lists`, `applications`, `leads`, `companies`, `contacts`, `interviews`, `job_events`, `pipeline`, `job_statuses`, `weekly_goals` | Always allow |
| Writes: `add_reminder`, `update_reminder`, `complete_reminder`, `add_application`, `set_application_status`, `add_lead`, `mark_applied`, `drop_lead`, `update_company`, `add_contact`, `update_contact`, `add_interview`, `update_interview`, `add_job_event`, `update_job_event`, `set_weekly_goal` | Needs approval |

Why: calendar invites and other text written by other people reach Claude through the read
tools, and such text can try to steer Claude into a write. With writes on **Needs approval**,
nothing changes without your click; every write is still logged under `claude_remote` and can
be reverted in History. Only choose **Always allow** for tools you trust to run unsupervised.
Claude's own guidance is to turn off write-capable tools before using Research, which can call
connector tools without asking
([About custom connectors](https://support.claude.com/en/articles/11175166-about-custom-connectors)).
For a connector with no writes at all, set `ORGANIZER_MCP_READ_ONLY=1`.

## 8. Optional: limit the hostname to Anthropic's addresses

Claude's connector traffic comes from Anthropic's published outbound ranges. A Cloudflare WAF
rule can block the MCP paths for everyone else, so even a stolen OAuth token is useless from
another network.

Anthropic's [IP addresses page](https://platform.claude.com/docs/en/api/ip-addresses) lists the
outbound IPv4 ranges `160.79.104.0/21` and `153.61.208.0/20` (no outbound IPv6). The connector
authentication page names only `160.79.104.0/21`. Use both, and check the page again when you set
this up; the ranges may change with notice.

In the Cloudflare dashboard, open your domain → **Security rules** → **Create rule** → **Custom
rules** ([create a custom rule](https://developers.cloudflare.com/waf/custom-rules/create-dashboard/)),
with the action **Block** and this expression (use the expression editor):

```
(http.host in {"organizer-mcp.example.com" "organizer-mail-mcp.example.com"})
and (http.request.uri.path eq "/" or starts_with(http.request.uri.path, "/mcp"))
and not ip.src in {160.79.104.0/21 153.61.208.0/20}
```

- Only `/` and `/mcp` are blocked. Access's own paths on the hostname (`/.well-known/...`,
  `/cdn-cgi/...`) must stay open: your browser uses them to sign in, and Claude fetches the
  discovery metadata from the same Anthropic range.
- The Free plan includes five custom rules
  ([custom rules](https://developers.cloudflare.com/waf/custom-rules/)).
- After this, `curl https://organizer-mcp.example.com/mcp` from your own machine answers `403`.
  That is the rule working.

## The mail connector

Mail is served by a second container, `organizer-mcp-mail` (profile `remote-mcp-mail`): the same
image, fixed to the read-only `mail` toolset, and the only container given the `mail` token. It
gets its own hostname and Access application, so it has its own sign-in and its own grant, and
you switch it on only in the chats that need mail. Read the safety rule in [MCP.md](MCP.md) and
[MAIL.md](MAIL.md) first.

1. **Token:** Settings → API tokens, scope **Mail** only, author **Claude (remote)**. In `.env`:
   `ORGANIZER_MCP_MAIL_TOKEN=org_...`.
2. **Access application** for `organizer-mail-mcp.example.com`, set up exactly as in step 2: the
   same email policy, Managed OAuth on, the same redirect URI. Its **AUD tag** is a different one.
3. **Tunnel route:** `organizer-mail-mcp` → `http://organizer-mcp-mail:8601` (cloudflared in this
   project) or `http://127.0.0.1:8602` (on the host), HTTP Host Header
   `organizer-mail-mcp.example.com`.
4. **WAF:** the expression above already lists both hostnames.
5. **Settings** in `.env`:

   ```bash
   COMPOSE_PROFILES=cloudflare,remote-mcp,remote-mcp-mail
   ORGANIZER_MCP_MAIL_TOKEN=org_...
   MCP_MAIL_PUBLIC_HOST=organizer-mail-mcp.example.com
   MCP_MAIL_CF_ACCESS_AUD=<the mail application's AUD tag>
   ```

   `CF_ACCESS_TEAM_DOMAIN` and `MCP_ALLOWED_EMAIL` are shared. Then `docker compose up -d --build`;
   `docker compose logs organizer-mcp-mail` shows `serving toolsets mail (read-only)`.
6. **Test** as in step 5, with port 8602 and the mail hostname.
7. **Claude:** add a second custom connector, `Organizer Mail`, URL
   `https://organizer-mail-mcp.example.com/mcp`, the same choices. Its tools only read, so
   **Always allow** is reasonable. Turn it on only in chats that need mail, and preferably not in
   the same chat as the main connector: an email is written by a stranger and could try to steer
   Claude into the main connector's write tools. Keeping those on **Needs approval** is what
   stops that.

## Revoking access

Any one of these cuts the connector off; they go from gentlest to most thorough.

- **For one chat:** **+** → **Connectors** → switch it off.
- **In Claude:** Customize → Connectors → the connector → **Disconnect** (signs Claude out; you
  can connect again) or **⋯ → Remove**.
- **At Cloudflare:** remove the hostname's route from the tunnel, or delete the Access
  application. Without the application, requests reach the container with no assertion, and it
  refuses every one with 401.
- **In the organizer:** Settings → API tokens → revoke the `claude_remote` token. The container
  then gets 401 from the organizer on every call. Make a new token to restore it.
- **The container:** drop `remote-mcp` from `COMPOSE_PROFILES` and run
  `docker compose rm -sf organizer-mcp` (dropping the profile alone leaves a running container
  up). The same for `remote-mcp-mail` and `organizer-mcp-mail`.

If you think the token leaked, revoke it in the organizer and check History for writes by
`claude_remote` you didn't make; each one can be reverted.

## Troubleshooting

`docker compose logs organizer-mcp` shows every refusal and why (no assertion, bad audience,
wrong email, wrong Host). Cloudflare's Access logs, in the Zero Trust dashboard, show the
sign-in side.

| Symptom | Likely cause and fix |
|---|---|
| The container keeps restarting; its log names a setting | A required value is missing from `.env`, or `.env` wasn't re-read: fill it in, `docker compose up -d` |
| `curl` to the hostname gets the container's JSON 401, no `www-authenticate` | No Access application covers the hostname. Add one (step 2) |
| `curl` gets a `302` to the team domain | Managed OAuth is off on the application |
| Claude: "Couldn't reach the MCP server" | No 401 with metadata reached Claude: Managed OAuth off, the hostname not covered by Access, or the WAF blocking `/.well-known/...` (only `/` and `/mcp` may be blocked) |
| Claude: "Authorization with the MCP server failed" | Use the bare hostname as the connector URL (step 6). Check the redirect URI `https://claude.ai/api/mcp/auth_callback` is in the application's Allowed redirect URIs |
| Sign-in works, tool calls fail; log says `assertion rejected: ... audience` | `CF_ACCESS_AUD` isn't this application's AUD tag (each application, mail included, has its own) |
| Log says `assertion rejected: ... issuer` | `CF_ACCESS_TEAM_DOMAIN` is wrong; it is `<team>.cloudflareaccess.com` |
| Log says `assertion is not for the allowed user` | You signed in to Access with another email than `MCP_ALLOWED_EMAIL` |
| Log says `refused ...: Host '...'`, `421` | The route sends another Host: set its HTTP Host Header to `MCP_PUBLIC_HOST` (step 3) |
| Cloudflare 502 | The route's Service URL is wrong for where cloudflared runs (service name inside this project, `127.0.0.1` on the host), or the container isn't running |
| Tools answer `401`/`403` from the organizer | The organizer token was revoked or has the wrong scope: make a new one (scope API, author Claude (remote)) |
| Worked for weeks, now asks to sign in | The grant session duration ran out. Connect again |
| No mail tools on the main connector | By design. Mail is only on the mail connector |
