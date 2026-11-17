import { addDays, format, isSameDay, parseISO, startOfDay } from "date-fns";

import type { CalendarItem } from "@/api/client";
import { toDay } from "@/lib/dates";

/** Weeks start on Monday, so the weekend sits together at the end. */
export const WEEK_STARTS_ON = 1 as const;

/**
 * The key an item is shown or hidden by: its own calendar when it names one (connected
 * calendars send `meta.calendar_key`), else its source.
 */
export function toggleKey(item: CalendarItem): string {
  const key = item.meta?.calendar_key;
  return typeof key === "string" && key ? key : item.source;
}

/** Start/end of an item as local Dates. All-day values are "YYYY-MM-DD" (end exclusive). */
export function itemBounds(item: CalendarItem): { start: Date; end: Date } {
  const start = parseISO(item.start);
  const end = item.end ? parseISO(item.end) : start;
  return { start, end: end > start ? end : start };
}

/** Local days ("YYYY-MM-DD") an item touches. */
export function itemDays(item: CalendarItem): string[] {
  const { start, end } = itemBounds(item);
  const days: string[] = [];
  let day = startOfDay(start);
  // End is exclusive: an item ending exactly at midnight does not touch the next day.
  const last = item.all_day || end.getTime() === startOfDay(end).getTime() ? addDays(end, -1) : end;
  while (day <= last || days.length === 0) {
    days.push(toDay(day));
    day = addDays(day, 1);
    if (days.length > 366) break;
  }
  return days;
}

export interface DaySummary {
  count: number;
  /** toggle key (source or calendar) -> color, in first-seen order. */
  sources: Map<string, string>;
  titles: string[];
}

/** Per-day counts and sources, for the year view. */
export function summarizeByDay(items: CalendarItem[]): Map<string, DaySummary> {
  const byDay = new Map<string, DaySummary>();
  for (const item of items) {
    for (const day of itemDays(item)) {
      let summary = byDay.get(day);
      if (!summary) {
        summary = { count: 0, sources: new Map(), titles: [] };
        byDay.set(day, summary);
      }
      summary.count += 1;
      const key = toggleKey(item);
      if (!summary.sources.has(key)) summary.sources.set(key, item.color);
      if (summary.titles.length < 6) summary.titles.push(item.title);
    }
  }
  return byDay;
}

/** "Thu, Nov 26 · All day" or "Tue, Oct 20 · 3:00 – 3:30 PM". */
export function formatItemWhen(item: CalendarItem): string {
  const { start, end } = itemBounds(item);
  const day = (d: Date) => format(d, "EEE, MMM d");
  if (item.all_day) {
    const lastDay = addDays(end, -1);
    return isSameDay(start, lastDay) || lastDay < start
      ? `${day(start)} · All day`
      : `${day(start)} – ${day(lastDay)}`;
  }
  const time = (d: Date) => d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return isSameDay(start, end)
    ? `${day(start)} · ${time(start)} – ${time(end)}`
    : `${day(start)} ${time(start)} – ${day(end)} ${time(end)}`;
}
