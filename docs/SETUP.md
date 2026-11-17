# Setting up Life Organizer for Mac

You need a machine that stays on (a small home server, a VPS, or a Mac) with Docker and
Docker Compose.

## 1. Start it

```bash
git clone <this repo> organizer && cd organizer
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

1. **Tailscale (recommended).** Install Tailscale on the server and your devices, then run
   `tailscale serve --bg --https=443 http://127.0.0.1:8600` on the server. The app is then at
   `https://<machine>.<your-tailnet>.ts.net` from your devices only, with HTTPS. It is never on
   the public internet.
2. **Cloudflare Tunnel with Access.**
   - Point a tunnel's public hostname at `http://127.0.0.1:8600` (or at the container on a shared Docker network).
   - Add a Cloudflare Access application with a policy that allows only your email.
   - The organizer's own password still applies behind Access.
3. **Your LAN only.** Change the port mapping in `docker-compose.yml` to `"8600:8600"`. Without
   HTTPS the browser won't install it as an app, and the session cookie travels unencrypted on
   your network.

Do not publish the port on the open internet without HTTPS in front.

## 3. Connect Claude (optional)

In **Settings → API tokens**, make a token with author "Claude" and scope `api`, then follow
docs/MCP.md. Mail needs a separate token with the `mail` scope, so a general Claude token can't
read your mail. Connecting mail accounts is covered in docs/MAIL.md.

## Updating

```bash
git pull && docker compose up -d --build
```

Database migrations run automatically on start.

## Backups

The database is a single SQLite file in the `organizer-data` Docker volume. To copy it out
safely while the app runs:

```bash
docker compose exec organizer python -c "import sqlite3; s=sqlite3.connect('data/organizer.db'); d=sqlite3.connect('data/backup.db'); s.backup(d); d.close()"
docker compose cp organizer:/app/server/data/backup.db ./organizer-backup.db
```

Store the backup apart from your `.env`.

## Development

```bash
cd server && uv sync && uv run alembic upgrade head && uv run uvicorn app.main:app --reload --port 8600
cd web && npm install && npm run dev      # http://localhost:5173, proxies /api to :8600
```

Before committing, run `git config core.hooksPath .githooks` once per clone. The pre-commit hook
runs `scripts/scrub-check.sh`.
