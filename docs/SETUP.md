# Setting up Life Organizer for Mac

You need a machine that stays on (a small home server, a VPS, or a Mac) with Docker and
Docker Compose. To have Claude Code do the setup with you, open it in the repo folder and ask it
to set the organizer up; it follows [INSTALL-WITH-CLAUDE.md](INSTALL-WITH-CLAUDE.md).

## 1. Start it

```bash
git clone <this repo> life-organizer && cd life-organizer
cp .env.example .env
openssl rand -base64 32        # paste the output after ORGANIZER_SECRET_KEY= in .env
docker compose up -d --build
```

Open http://localhost:8600 on that machine. On first visit, the organizer asks for:
- your name;
- a password (10+ characters);
- your time zone;
- which country's holidays to show.

That creates your account. There is one account per install.

**Keep a copy of `ORGANIZER_SECRET_KEY`** in your password manager. It encrypts the passwords
and tokens of the accounts you connect.
- If you lose the key, you have to reconnect those accounts.
- If someone gets the key together with the database, they can read those credentials.

## 2. Reach it from your other devices

The app listens on the host's loopback (`127.0.0.1:8600`) only. Choose one of these:

1. **Tailscale (recommended, simplest).** Install Tailscale on the server and your devices,
   then run `tailscale serve --bg 8600` on the server (`tailscale serve status` shows the
   address; `tailscale serve reset` turns it off). The app is then at
   `https://<machine>.<your-tailnet>.ts.net` from your devices only, with HTTPS. It is never on
   the public internet, and the Mac helper and Claude Code reach it the same way. In `.env`, set
   `PUBLIC_BASE_URL=https://<machine>.<your-tailnet>.ts.net` and `COOKIE_SECURE=always`, then
   `docker compose up -d`.
2. **Cloudflare Tunnel with Access.** A hostname of your own, such as
   `organizer.example.com`, reachable from any browser after Cloudflare Access lets only your
   email in. [CLOUDFLARE.md](CLOUDFLARE.md) is the step-by-step:
   - a remotely managed tunnel, run by the `cloudflared` service in this compose project
     (profile `cloudflare`, token in `.env` as `CLOUDFLARE_TUNNEL_TOKEN`) or on the host;
   - a route from your hostname to `http://organizer:8600` (or `http://127.0.0.1:8600` from the
     host);
   - an Access application for that hostname with a policy that allows only your email;
   - `PUBLIC_BASE_URL=https://organizer.example.com` and `COOKIE_SECURE=always` in `.env`, and
     the Google redirect URI `https://organizer.example.com/api/oauth/google/callback`.

   The organizer's own password still applies behind Access. Clients that use an API token
   instead of a browser (the Mac app, the Mac helper, Claude Code on another machine) each get a
   Cloudflare Access service token to pass Access ([CLOUDFLARE.md](CLOUDFLARE.md), step 5). The claude.ai connector also uses Cloudflare,
   on its own hostname ([REMOTE-CONNECTOR.md](REMOTE-CONNECTOR.md)); Tailscale for your devices
   plus Cloudflare for the connector is a good mix.
3. **Your LAN only.** Change the port mapping in `docker-compose.yml` to `"8600:8600"`. Without
   HTTPS the browser won't install it as an app, and the session cookie travels unencrypted on
   your network.

Do not publish the port on the open internet without HTTPS in front. Behind any HTTPS proxy,
set `COOKIE_SECURE=always` in `.env`, so the session cookie is only ever sent over HTTPS.

**Finish setup before you expose it.** Until setup has run, whoever opens the page first chooses
the password. Run setup on the machine itself (http://localhost:8600), then add the proxy.

## 3. Connect Claude (optional)

In **Settings → API tokens**, make a token with author "Claude" and scope `api`, then follow
docs/MCP.md for Claude Code. For Claude on the web, desktop and mobile (a claude.ai custom
connector), follow docs/REMOTE-CONNECTOR.md. Mail needs a separate token with the `mail` scope,
so a general Claude token can't read your mail. Connecting mail accounts is covered in
docs/MAIL.md.

## Updating

```bash
git pull && docker compose up -d --build
```

Database migrations run automatically on start.

## Backups

The database is a single SQLite file in the `organizer-data` Docker volume. To copy it out
safely while the app runs:

```bash
mkdir -p ~/organizer-backups
docker compose exec organizer python -c "import sqlite3; s=sqlite3.connect('data/organizer.db'); d=sqlite3.connect('data/backup.db'); s.backup(d); d.close()"
docker compose cp organizer:/app/server/data/backup.db ~/organizer-backups/organizer-$(date +%F).db
docker compose exec organizer rm data/backup.db
```

`organizer` is the service name, so these work whatever the project or folder is called. Keep
backups outside the repo folder (it holds your personal data), and apart from your `.env`.

### Restoring

```bash
docker compose stop organizer
docker compose cp ~/organizer-backups/organizer-YYYY-MM-DD.db organizer:/app/server/data/organizer.db
docker compose start organizer
```

The container must have been created once (`docker compose up -d`). A restore replaces
everything since the backup. Connected accounts still need the same `ORGANIZER_SECRET_KEY`.

## Demo data

To look around before connecting anything, fill a separate, fresh database with made-up data.
This needs the development tools below (uv, Node), not Docker. It never touches an install that
is already set up. Port 8611 is used so it can run beside a Docker install (8600) and its
connector ports (8601, 8602).

```bash
cd web && npm install && npm run build && cd ..          # the server serves this build
cd server && export DATABASE_URL=sqlite:///./data/demo.db
uv run alembic upgrade head
uv run python -m app.demo_seed --password "demo password 1"
SCHEDULER_ENABLED=false WEB_DIST=../web/dist uv run uvicorn app.main:app --port 8611
```

Open http://localhost:8611 and sign in with that password. The demo accounts have no real server behind them, which is why
the scheduler is off and opening a demo message shows a connection error.

## Development

```bash
cd server && uv sync && uv run alembic upgrade head
EXPOSE_API_DOCS=true uv run uvicorn app.main:app --reload --port 8610   # API docs at /docs
cd web && npm install && API_URL=http://localhost:8610 npm run dev      # http://localhost:5173
```

The web dev server proxies `/api` to `API_URL` (default `http://localhost:8600`); the examples
use 8610 so development never collides with a Docker install or its connector ports. `npm run gen:api` reads the same
`API_URL` and needs the server started with `EXPOSE_API_DOCS=true`.

Before committing, run `git config core.hooksPath .githooks` once per clone. The pre-commit hook
runs `scripts/scrub-check.sh`.
