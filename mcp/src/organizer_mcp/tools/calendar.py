"""The merged calendar: every source between two times, and the sources themselves. Read-only."""

import datetime as dt
from typing import Any

from mcp.types import ToolAnnotations

from organizer_mcp.core import _as_list, _datetime_param, app, client

TOOLSET = "calendar"
SCOPE = "api"
TOOLS = frozenset({"calendar", "calendar_sources"})
WRITES: frozenset[str] = frozenset()

READ_ONLY = ToolAnnotations(readOnlyHint=True)

ITEM_FIELDS = (
    "id",
    "source",
    "title",
    "start",
    "end",
    "all_day",
    "status",
    "detail_url",
    "read_only",
)


def _item(row: dict[str, Any]) -> dict[str, Any]:
    """The fields Claude uses; color, label and provider extras are left out."""
    return {name: row.get(name) for name in ITEM_FIELDS}


@app.tool(annotations=READ_ONLY)
def calendar(
    start: dt.datetime | dt.date,
    end: dt.datetime | dt.date,
    sources: str | list[str] | None = None,
) -> dict[str, Any]:
    """Everything on the calendar between start and end (end is exclusive), merged and sorted.

    start and end accept a date (read as local midnight) or a datetime; a datetime without an
    offset is the organizer's local time. sources limits the answer to source keys such as
    "holidays" (calendar_sources lists them); omit it for every source. Returns {start, end,
    items, errors}. Each item is {id, source, title, start, end, all_day, status, detail_url,
    read_only}; all-day items have date values and an exclusive end. errors names any source
    that failed, so an empty day may be an error rather than a real absence.
    """
    data = client().get(
        "/api/calendar",
        params={
            "start": _datetime_param(start),
            "end": _datetime_param(end),
            "sources": ",".join(_as_list(sources) or []) or None,
        },
    )
    return {
        "start": data["start"],
        "end": data["end"],
        "items": [_item(item) for item in data["items"]],
        "errors": data["errors"],
    }


@app.tool(annotations=READ_ONLY)
def calendar_sources() -> list[dict[str, Any]]:
    """Every source on the calendar: its key (for calendar's sources filter), label and how
    current it is.

    Returns [{key, label, live, freshness}]. live is true for sources computed from the
    organizer's own data, which are always current. A mirrored source (a connected calendar)
    has freshness {state, last_success_at, last_attempt_at, last_error, last_error_at}: when
    state is not ok, say how old its events are before relying on them.
    """
    rows = client().get("/api/calendar/sources")
    out = []
    for row in rows:
        fresh = row.get("freshness")
        out.append(
            {
                "key": row.get("key"),
                "label": row.get("label"),
                "live": row.get("live"),
                "freshness": None
                if fresh is None
                else {
                    name: fresh.get(name)
                    for name in (
                        "state",
                        "last_success_at",
                        "last_attempt_at",
                        "last_error",
                        "last_error_at",
                    )
                },
            }
        )
    return out
