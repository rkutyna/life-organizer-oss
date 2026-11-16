"""Public holidays as a built-in, read-only calendar source (`source="holidays"`).

The country is the owner's choice (setup or Settings; None turns the source off). Computed by
the `holidays` library, so it is always live. Observed days (e.g. "Independence Day
(observed)") are included because they are the actual day off.
"""

from datetime import datetime, timedelta
from functools import cache

import holidays
from sqlalchemy.orm import Session

from app.auth.models import AppConfig
from app.calendar import CalendarItem, local_date_bounds, register_provider

SOURCE_KEY = "holidays"
SOURCE_LABEL = "Holidays"
COLOR = "#a0782c"


@cache
def supported_countries() -> dict[str, str]:
    """ISO code -> country name, for every country the holidays library knows."""
    names: dict[str, str] = {}
    for module_name, (_class, code, *_rest) in holidays.registry.COUNTRIES.items():
        names[code] = module_name.replace("_", " ").title()
    return dict(sorted(names.items(), key=lambda item: item[1]))


def holiday_items(session: Session, start: datetime, end: datetime) -> list[CalendarItem]:
    config = session.get(AppConfig, 1)
    country = config.holiday_country if config else None
    if not country:
        return []
    first, stop = local_date_bounds(start, end)
    calendar = holidays.country_holidays(country, years=range(first.year, stop.year + 1))
    items = []
    for day, name in sorted(calendar.items()):
        if not first <= day < stop:
            continue
        items.append(
            CalendarItem(
                id=f"{SOURCE_KEY}:{day.isoformat()}",
                source=SOURCE_KEY,
                source_label=SOURCE_LABEL,
                title=name,
                start=day,
                end=day + timedelta(days=1),
                all_day=True,
                color=COLOR,
                detail_url=None,
                read_only=True,
                meta={"observed": "(observed)" in name, "country": country},
            )
        )
    return items


register_provider(SOURCE_KEY, SOURCE_LABEL, COLOR, holiday_items)
