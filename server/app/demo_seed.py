"""Fill an empty install with fictional demo data, for screenshots and for trying the app.

    cd server && export DATABASE_URL=sqlite:///./data/demo.db
    uv run alembic upgrade head
    uv run python -m app.demo_seed --password "demo password 1"
    SCHEDULER_ENABLED=false WEB_DIST=../web/dist uv run uvicorn app.main:app --port 8600

It runs setup (name "Demo User") and then each module's `demo.py` (`seed(session)`), in module
order. Demo accounts have no credentials, so keep the scheduler off. It refuses a database that
is already set up, so it can never mix demo rows into real data.
"""

import argparse
import sys

from app.auth import service as auth_service
from app.config import get_settings
from app.db import make_engine, make_session_factory
from app.discovery import import_all_models, import_module_part, module_names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--password", required=True, help="The demo login's password")
    parser.add_argument("--timezone", default="America/New_York")
    parser.add_argument("--holidays", default="US", help="Holiday country code, or none")
    args = parser.parse_args(argv)

    settings = get_settings()
    import_all_models()
    factory = make_session_factory(make_engine(settings.database_url))
    with factory() as session:
        if auth_service.load_config(session) is not None:
            print("refusing: this database is already set up (demo data only goes in a fresh one)")
            return 1
        auth_service.setup(
            session,
            display_name="Demo User",
            password=args.password,
            timezone=args.timezone,
            holiday_country=None if args.holidays.lower() == "none" else args.holidays,
        )
        for name in module_names():
            demo = import_module_part(name, "demo")
            if demo is None:
                continue
            demo.seed(session)
            print(f"seeded {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
