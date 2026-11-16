/**
 * Date helpers. The server sends:
 * - wall-clock dates as "YYYY-MM-DD" and times as "HH:MM:SS" (a task's due date/time),
 * - timestamps as ISO strings with an offset ("2026-10-18T14:00:00Z").
 * Parse dates with `parseDay` (local midnight), never `new Date("YYYY-MM-DD")` (that is UTC).
 */

import {
  differenceInCalendarDays,
  format,
  formatDistanceToNowStrict,
  isSameYear,
  parseISO,
} from "date-fns";

/** Local date -> "YYYY-MM-DD". */
export function toDay(date: Date): string {
  return format(date, "yyyy-MM-dd");
}

/** "YYYY-MM-DD" -> Date at local midnight. */
export function parseDay(day: string): Date {
  return parseISO(day);
}

/** "15:00:00" or "15:00" -> "3:00 PM" (locale formatted). */
export function formatClock(time: string): string {
  const [h, m] = time.split(":").map(Number);
  const date = new Date(2000, 0, 1, h, m);
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

/** "HH:MM" for an <input type="time"> from "HH:MM:SS". */
export function toTimeInput(time: string | null | undefined): string {
  return time ? time.slice(0, 5) : "";
}

/** A friendly day label: Today, Tomorrow, Yesterday, a weekday within a week, else "Oct 24". */
export function formatDayLabel(day: string, now: Date = new Date()): string {
  const date = parseDay(day);
  const diff = differenceInCalendarDays(date, now);
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  if (diff === -1) return "Yesterday";
  if (diff > 1 && diff < 7) return format(date, "EEEE");
  return isSameYear(date, now) ? format(date, "MMM d") : format(date, "MMM d, yyyy");
}

/** Due label for a task: "Today", "Tomorrow 3:00 PM", "Oct 24". */
export function formatDue(dueDate: string | null, dueTime: string | null, now = new Date()) {
  if (!dueDate) return "";
  const day = formatDayLabel(dueDate, now);
  return dueTime ? `${day} ${formatClock(dueTime)}` : day;
}

/** "5 min ago" style age of an ISO timestamp. */
export function formatAge(iso: string | null | undefined): string {
  if (!iso) return "never";
  const date = parseISO(iso);
  if (Date.now() - date.getTime() < 45_000) return "just now";
  return `${formatDistanceToNowStrict(date)} ago`;
}

/** Absolute timestamp for tooltips: "Oct 18, 2026, 2:05 PM". */
export function formatTimestamp(iso: string): string {
  return parseISO(iso).toLocaleString([], {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}
