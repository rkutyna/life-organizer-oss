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
| `reminders` | `reminders`, `reminder_lists`, `add_reminder`, `update_reminder`, `complete_reminder` | `api` | Reads and writes Apple Reminders (through the Mac helper) and Google Tasks; see docs/REMINDERS.md. |
| `jobs` | | `api` | Coming with that feature. Naming it today is a clear startup error. |

`ORGANIZER_MCP_TOOLSETS` picks what a server serves: `all` (the default) is every toolset except
`mail`, or give a comma list such as `calendar` or `mail`. `ORGANIZER_MCP_READ_ONLY=1` drops
every tool that writes. Because `reminders` writes, `all,mail` is refused at startup unless
`ORGANIZER_MCP_READ_ONLY=1` is set; serve mail from its own server.

## Tokens

Make each token in **Settings → API tokens**. A token's author is fixed when you make it, and
the organizer's history shows it on every write.

| Variable | Scope | Author | Used by |
|---|---|---|---|
| `ORGANIZER_TOKEN` | `api` | `claude` (Claude Code) or `claude_remote` (connector) | every toolset except mail |
| `ORGANIZER_MAIL_TOKEN` | `mail` | the same | the mail toolset only |

An `api` token cannot read mail, and a `mail` token reads nothing else. A server refuses to start
without the token its toolsets need, and names the variable to set. `ORGANIZER_URL` is the
organizer's address (default `http://localhost:8600`); `ORGANIZER_TIMEOUT` is in seconds
(default 15).

## Claude Code (stdio)

You need [uv](https://docs.astral.sh/uv/) and a checkout of this repo. Register the server
for your user, so the token stays out of any project's files:

```bash
claude mcp add --transport stdio --scope user \
  --env ORGANIZER_URL=https://organizer.example.com \
  --env ORGANIZER_TOKEN=<api token> \
  organizer -- uv run --directory /path/to/organizer/mcp organizer-mcp
```

For mail, add a second server with its own token:

```bash
claude mcp add --transport stdio --scope user \
  --env ORGANIZER_URL=https://organizer.example.com \
  --env ORGANIZER_MCP_TOOLSETS=mail \
  --env ORGANIZER_MAIL_TOKEN=<mail token> \
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
from the internet. Cloudflare Access does the sign-in (OAuth); the container checks Access's
signed assertion on every request, and the token it holds limits what it can do.

```
claude.ai ──HTTPS──▶ Cloudflare Access (Managed OAuth, your email only)
                       │ tunnel, adds Cf-Access-Jwt-Assertion
                       ▼
          127.0.0.1:8601  organizer-mcp   (checks Host and the assertion, else 401/421)
                       │ Authorization: Bearer <api token, author claude_remote>
                       ▼
          organizer:8600  (the compose network)
```

1. **Token.** In Settings → API tokens, make a token with scope `api` and author
   `claude_remote`. Put it in `.env` as `ORGANIZER_MCP_TOKEN`.
2. **Access application.** In Cloudflare Zero Trust → Access → Applications, add a
   self-hosted application for `organizer-mcp.example.com`, with a policy that allows only your
   email. Under its advanced settings, turn **Managed OAuth** on and allow the redirect URI
   `https://claude.ai/api/mcp/auth_callback`. Copy its **Application Audience (AUD) tag**.
3. **Tunnel.** Add a public hostname `organizer-mcp.example.com` to your Cloudflare Tunnel,
   pointing at `http://127.0.0.1:8601` (or `http://organizer-mcp:8601` if `cloudflared` runs on
   the compose network). Never point it at the organizer's own port for this hostname.
4. **Settings.** In `.env`, uncomment and fill in the MCP block from `.env.example`:
   `CF_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com`, `CF_ACCESS_AUD`, `MCP_PUBLIC_HOST`
   and `MCP_ALLOWED_EMAIL`. Then run `docker compose --profile mcp up -d --build`.
5. **Check.** `curl -si http://127.0.0.1:8601/mcp` on the host answers 421 (wrong Host), and
   `curl -si https://organizer-mcp.example.com/mcp` from anywhere answers 401 until you sign in.
6. **claude.ai.** Settings → Connectors → Add custom connector, with the URL
   `https://organizer-mcp.example.com/mcp`. Sign in through Access. If authorization fails,
   add it again with the bare `https://organizer-mcp.example.com`; the server answers at both.

Optionally, add a Cloudflare WAF rule that blocks `/` and `/mcp` on that hostname from outside
Anthropic's published egress range (see Claude's connector docs). `docker compose logs
organizer-mcp` shows every refusal and its reason.

**Mail as a connector.** The `organizer-mcp-mail` service (profile `mcp-mail`) is the same image
fixed to the mail toolset, read-only. Give it its own hostname (`MCP_MAIL_PUBLIC_HOST`), its own
Access application (`MCP_MAIL_CF_ACCESS_AUD`), its own tunnel route to `127.0.0.1:8602`, and a
`mail`-scope token made with author `claude_remote` (`ORGANIZER_MCP_MAIL_TOKEN`). Add it to
claude.ai as a second connector, and switch it on only in the chats that need mail.

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
