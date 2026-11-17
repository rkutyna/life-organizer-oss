# MCP: Claude and your organizer

`mcp/` is an MCP server that lets Claude use your organizer. It works only through the
organizer's REST API, with an API token you make in **Settings → API tokens**; it never opens the
database. It runs two ways:

- **stdio**, for Claude Code on any machine that can reach the organizer;
- **streamable HTTP** in a container behind Cloudflare Access, as a custom connector for claude.ai
  (web, desktop and mobile).

## Toolsets

| Toolset | Tools | Token scope | Notes |
|---|---|---|---|
| `calendar` | `calendar`, `calendar_sources` | `api` | Read-only. Every source merged, with each mirror's freshness. |
| `mail` | `emails`, `email` | `mail` | Read-only and **opt-in**. See the safety rule below. |
| `jobs` | reads: `applications`, `leads`, `companies`, `contacts`, `interviews`, `job_events`, `pipeline`, `job_statuses`, `weekly_goals`; writes: `add_application`, `set_application_status`, `add_lead`, `mark_applied`, `drop_lead`, `update_company`, `add_contact`, `update_contact`, `add_interview`, `update_interview`, `add_job_event`, `update_job_event`, `set_weekly_goal` | `api` | The job tracker ([JOBS.md](JOBS.md)). Writes are logged under the token's author and revertible from History. |
| `reminders` | `reminders`, `reminder_lists`, `add_reminder`, `update_reminder`, `complete_reminder` | `api` | Reads and writes Apple Reminders (through the Mac helper) and Google Tasks; see docs/REMINDERS.md. |

`ORGANIZER_MCP_TOOLSETS` picks what a server serves: `all` (the default) is every toolset except
`mail`, or give a comma list such as `calendar` or `mail`. `ORGANIZER_MCP_READ_ONLY=1` drops
every tool that writes. Because `jobs` and `reminders` write, `all,mail` is refused unless the
server is also read-only; `calendar,mail` is fine.

## Tokens

Make each token in **Settings → API tokens**. A token's author is fixed when you make it, and
the organizer's history shows it on every write.

| Variable | Scope | Author | Used by |
|---|---|---|---|
| `ORGANIZER_TOKEN` | `api` | `claude` (Claude Code) or `claude_remote` (connector) | every toolset except mail |
| `ORGANIZER_MAIL_TOKEN` | `mail` | the same | the mail toolset only |

An `api` token cannot read mail, and a `mail` token reads nothing else. A server refuses to start
without the token its toolsets need, and names the variable to set. `ORGANIZER_URL` is the
organizer's address (default `http://localhost:8600`; set it if you changed `ORGANIZER_PORT` or
reach the organizer elsewhere); `ORGANIZER_TIMEOUT` is in seconds (default 15).

**An organizer behind Cloudflare Access.** Access stops a client that can't sign in with a
browser. Give the MCP server a Cloudflare Access service token
([CLOUDFLARE.md](CLOUDFLARE.md), step 5) in `ORGANIZER_CF_ACCESS_CLIENT_ID` and
`ORGANIZER_CF_ACCESS_CLIENT_SECRET`. With both set, every request to the organizer carries them
as `CF-Access-Client-Id` and `CF-Access-Client-Secret`, beside the API token. Set both or
neither: with one, the server refuses to start and names the other. A call that Access redirects
to its sign-in page fails with a message saying which settings to check. The secret is never
logged.

### Checking it without Claude

From `mcp/`, with a token from Settings → API tokens:

```bash
ORGANIZER_URL=http://localhost:8600 ORGANIZER_TOKEN=org_... uv run organizer-mcp
```

It speaks MCP over stdio. Any MCP client (or the MCP Inspector, `npx @modelcontextprotocol/inspector
uv run organizer-mcp`) can list its tools and call one, e.g. `calendar` with `start` and `end`
(ISO dates or datetimes; both are required).

## Claude Code (stdio)

You need [uv](https://docs.astral.sh/uv/) and a checkout of this repo. Register the server
for your user, so the token stays out of any project's files:

```bash
claude mcp add --env ORGANIZER_URL=https://organizer.example.com \
  --env ORGANIZER_TOKEN=<api token> \
  --transport stdio --scope user \
  organizer -- uv run --directory /path/to/organizer/mcp organizer-mcp
```

Keep another option between the last `--env` and the server's name: directly after `--env`,
Claude Code reads the name as one more variable and rejects it
([Claude Code MCP docs](https://code.claude.com/docs/en/mcp)). `ORGANIZER_URL` must be an
address the server can reach: `http://localhost:8600` on the organizer's own machine, its
Tailscale address, or a hostname behind Cloudflare Access together with a service token
(add `--env ORGANIZER_CF_ACCESS_CLIENT_ID=<client id>` and
`--env ORGANIZER_CF_ACCESS_CLIENT_SECRET=<client secret>`, see above). Check it with
`claude mcp list`, which shows `✔ Connected`.

For mail, add a second server with its own token:

```bash
claude mcp add --env ORGANIZER_URL=https://organizer.example.com \
  --env ORGANIZER_MCP_TOOLSETS=mail \
  --env ORGANIZER_MAIL_TOKEN=<mail token> \
  --transport stdio --scope user \
  organizer-mail -- uv run --directory /path/to/organizer/mcp organizer-mcp
```

The same in a project's `.mcp.json` reads the token from your environment, so no secret is
committed:

```json
{
  "mcpServers": {
    "organizer": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/organizer/mcp", "organizer-mcp"],
      "env": {
        "ORGANIZER_URL": "https://organizer.example.com",
        "ORGANIZER_TOKEN": "${ORGANIZER_TOKEN}"
      }
    }
  }
}
```

## claude.ai (remote connector)

claude.ai calls custom connectors from Anthropic's cloud, so the endpoint must be reachable
from the internet. Cloudflare Access does the sign-in (OAuth, with Managed OAuth); the container
checks Access's signed assertion on every request, and the token it holds limits what it can
do. [REMOTE-CONNECTOR.md](REMOTE-CONNECTOR.md) is the complete setup: the Access application,
the tunnel route, `.env`, testing with curl, adding the connector in Claude, tool permissions,
revoking and troubleshooting.

```
claude.ai ──HTTPS──▶ Cloudflare Access (Managed OAuth, your email only)
                       │ tunnel, adds Cf-Access-Jwt-Assertion
                       ▼
          organizer-mcp:8601   (checks Host and the assertion, else 421/401)
                       │ Authorization: Bearer <api token, author claude_remote>
                       ▼
          organizer:8600  (the compose network)
```

In short:
- **Compose profiles.** `remote-mcp` starts `organizer-mcp`; `remote-mcp-mail` starts
  `organizer-mcp-mail`, the separate mail connector. Switch them on with
  `COMPOSE_PROFILES=remote-mcp` (comma-separated) in `.env`. The `cloudflare` profile runs
  `cloudflared` in the same project ([CLOUDFLARE.md](CLOUDFLARE.md)).
- **Settings** (`.env.example` lists them): `ORGANIZER_MCP_TOKEN` (scope `api`, author
  `claude_remote`), `CF_ACCESS_TEAM_DOMAIN`, `CF_ACCESS_AUD`, `MCP_PUBLIC_HOST`,
  `MCP_ALLOWED_EMAIL`; for mail, `ORGANIZER_MCP_MAIL_TOKEN`, `MCP_MAIL_PUBLIC_HOST` and
  `MCP_MAIL_CF_ACCESS_AUD`. A container with a setting missing exits and names it.
- **Ports.** The connectors listen on the host's loopback at `MCP_PORT` (8601) and
  `MCP_MAIL_PORT` (8602), and on the compose network as `organizer-mcp:8601` and
  `organizer-mcp-mail:8601`. Never route a connector's hostname to the organizer's port.
- **Check.** `curl -si -X POST http://127.0.0.1:8601/mcp -H 'Host: <MCP_PUBLIC_HOST>'` answers
  401 without an Access assertion, and 421 with any other Host. `docker compose logs
  organizer-mcp` shows every refusal and its reason.

## The mail safety rule

Anyone can send you an email, so everything in one is untrusted text that may try to instruct
Claude. The mail tools are built around that:

- **Never beside a write tool.** A server refuses to start if `mail` is chosen together with any
  toolset that writes, unless `ORGANIZER_MCP_READ_ONLY=1`. One email therefore can't ask Claude
  to change your records through the same server. Run mail as its own server or connector.
- **Opt-in.** `all` leaves mail out; it is served only when named.
- **Read-only end to end.** The toolset has no write tool, and the API can't send, delete, move
  or flag mail. Reading a message does not mark it read.
- **Results are marked untrusted.** Every result carries `untrusted: true` and a note telling
  Claude to follow no instruction in a message and to tell you what it asks instead. Sender
  checks (`sender_checks.verified`, `sender_warning`, `warnings`) say whether the From address
  can be believed.
- **Its own token.** Only a `mail`-scope token reads `/api/mail`, so the general token in other
  clients can't.
