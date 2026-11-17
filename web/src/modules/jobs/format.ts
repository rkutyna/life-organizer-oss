import { addDays, differenceInCalendarDays, format, isSameYear } from "date-fns";

import { formatClock, parseDay, toDay } from "@/lib/dates";

import type { Interview, JobEvent } from "./api";

/** Today as "YYYY-MM-DD" (local). */
export function today(): string {
  return toDay(new Date());
}

/** "YYYY-MM-DD" n days from today. */
export function daysFromToday(n: number): string {
  return toDay(addDays(new Date(), n));
}

/** "Oct 16" this year, "Oct 16, 2025" otherwise; "" for no day. */
export function formatDate(day: string | null | undefined): string {
  if (!day) return "";
  const date = parseDay(day);
  return isSameYear(date, new Date()) ? format(date, "MMM d") : format(date, "MMM d, yyyy");
}

/** "Tue, Nov 18" style, with the year when it is not this year. */
export function formatDayLong(day: string): string {
  const date = parseDay(day);
  return isSameYear(date, new Date()) ? format(date, "EEE, MMM d") : format(date, "EEE, MMM d, yyyy");
}

/** Days from today to a day: negative when past. */
export function daysUntil(day: string): number {
  return differenceInCalendarDays(parseDay(day), new Date());
}

/** "Overdue 3d", "Today", "Tomorrow", "In 4d", for a due date. */
export function dueLabel(day: string): string {
  const diff = daysUntil(day);
  if (diff < 0) return `Overdue ${-diff}d`;
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  return diff < 7 ? `In ${diff}d` : formatDate(day);
}

/** "Tue, Nov 18 · 2:00 PM · 45 min", or "Not scheduled". */
export function formatInterviewWhen(interview: Interview): string {
  if (!interview.on_date) return "Not scheduled";
  const parts = [formatDayLong(interview.on_date)];
  if (interview.start_time) parts.push(formatClock(interview.start_time));
  if (interview.duration_minutes) parts.push(`${interview.duration_minutes} min`);
  return parts.join(" · ");
}

/** "Tue, Nov 18 · 6:00 PM–8:00 PM". */
export function formatEventWhen(event: JobEvent): string {
  const parts = [formatDayLong(event.on_date)];
  if (event.start_time) {
    parts.push(
      event.end_time
        ? `${formatClock(event.start_time)}–${formatClock(event.end_time)}`
        : formatClock(event.start_time),
    );
  }
  return parts.join(" · ");
}

/** "a, b, c" -> ["a", "b", "c"], dropping blanks. */
export function splitList(text: string): string[] {
  return text
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);
}

export function isWebUrl(text: string): boolean {
  return /^https?:\/\/\S+$/i.test(text.trim());
}

/** "1 application", "3 applications". */
export function plural(n: number, word: string, many = `${word}s`): string {
  return `${n} ${n === 1 ? word : many}`;
}
