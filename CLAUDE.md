# CLAUDE.md — working in this repo

Read `docs/PLAN.md` first. This repo will become public: it is a self-hosted, single-user
organizer (calendar, reminders, job tracker, mail) extracted from a private personal organizer.

## Rules

1. **No personal data, ever.** No real names, emails, hostnames, domains, tailnet names, Apple
   team or bundle ids, account ids, folder paths under `/Users/`, or anything copied from a real
   calendar, mailbox or job record. Fixtures and seeds are fictional. Run `scripts/scrub-check.sh`
   (once it exists) before every commit.
2. **Port code module by module and scrub it**; never import the original repo's git history.
3. **Owned records are written only through `server/app/audit.py`.**
4. **Mirrored data is read-only.** Calendars, reminders (except through the op queue) and mail
   are never edited directly. Mail is read-only end to end and can never send, delete, move or flag.
5. **Every route is authenticated** (session cookie or scoped API token). Do not assume a
   private network.
6. **A module is self-contained** under `server/app/modules/<name>/` and `web/src/modules/<name>/`.
7. **Provider credentials live encrypted in `provider_accounts`**, never in logs or responses.
8. **Auth lives in `app/auth/principal.py`.** `app.main` mounts every router behind a scope
   guard (`api`, `ingest`, `mail`); account management is browser-only. A new public route
   needs a reason and a line in `tests/test_main.py`'s public set.

## Commands

```bash
cd server && uv sync && uv run pytest          # tests (ruff check . && ruff format --check .)
uv run alembic upgrade head && uv run uvicorn app.main:app --reload --port 8600
uv run alembic revision --autogenerate --rev-id 00NN -m "..."   # after changing models
cd web && npm install && npm run dev           # proxies /api to :8600
npm run typecheck && npm run build && npm run gen:api
docker compose up -d --build                   # needs .env (see .env.example)
scripts/scrub-check.sh [--staged|--history]    # personal-data check
```

## Done means

Server tests, web typecheck and build, and `scripts/scrub-check.sh --history` pass; the change
is committed with a clear message.
