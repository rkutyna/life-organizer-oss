/**
 * Quick-add parsing: "Call the plumber tomorrow 3pm !1" ->
 * { title: "Call the plumber", due_date: "2026-10-19", due_time: "15:00", priority: 1 }.
 *
 * Dates come from chrono-node (forward-looking, so "Friday" means the next Friday).
 * "!1" / "!2" / "!3" sets priority (high / medium / low).
 */

import * as chrono from "chrono-node";
import { format } from "date-fns";

import { toDay } from "@/lib/dates";

export interface QuickAdd {
  title: string;
  due_date: string | null;
  due_time: string | null;
  priority: number | null;
  /** The words chrono read as the date, for highlighting. */
  dateText: string | null;
}

const PRIORITY = /(^|\s)!([123])(?=\s|$)/;
const DANGLING = /\s+(on|at|by|due|for|from)$/i;

function tidy(text: string): string {
  return text.replace(/\s+/g, " ").trim().replace(DANGLING, "").trim();
}

export function parseQuickAdd(input: string, now: Date = new Date()): QuickAdd {
  let text = input;
  let priority: number | null = null;
  const flag = text.match(PRIORITY);
  if (flag) {
    priority = Number(flag[2]);
    text = text.replace(flag[0], " ");
  }

  const [match] = chrono.parse(text, now, { forwardDate: true });
  if (!match) {
    return { title: tidy(text), due_date: null, due_time: null, priority, dateText: null };
  }

  const when = match.start.date();
  const rest = tidy(text.slice(0, match.index) + " " + text.slice(match.index + match.text.length));
  return {
    // "tomorrow" alone: keep the words as the title rather than adding an empty reminder.
    title: rest || tidy(text),
    due_date: toDay(when),
    due_time: match.start.isCertain("hour") ? format(when, "HH:mm") : null,
    priority,
    dateText: match.text,
  };
}

/**
 * What a list can hold: Google Tasks keeps a due date but no time, and no priority. The
 * server refuses both for a Google list, so quick-add drops them first and says so.
 */
export function fitToList(
  parsed: QuickAdd,
  list: { supports_time: boolean; supports_priority: boolean } | undefined,
): { fields: QuickAdd; dropped: string[] } {
  if (!list) return { fields: parsed, dropped: [] };
  const dropped: string[] = [];
  const fields = { ...parsed };
  if (!list.supports_time && fields.due_time) {
    fields.due_time = null;
    dropped.push("time");
  }
  if (!list.supports_priority && fields.priority) {
    fields.priority = null;
    dropped.push("priority");
  }
  return { fields, dropped };
}
