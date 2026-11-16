import {
  addDays,
  eachMonthOfInterval,
  endOfMonth,
  format,
  getDay,
  isWeekend,
  startOfWeek,
} from "date-fns";
import { useMemo } from "react";

import type { CalendarItem } from "@/api/client";
import { sourceColor } from "@/app/tokens";
import { toDay } from "@/lib/dates";
import { cn } from "@/lib/utils";

import { summarizeByDay, WEEK_STARTS_ON, type DaySummary } from "./items";

const MAX_DOTS = 3;

/** Background tint by number of items: 0, 1, 2–3, 4–5, 6+. */
function densityTint(count: number): string | undefined {
  const level = count === 0 ? 0 : count === 1 ? 1 : count <= 3 ? 2 : count <= 5 ? 3 : 4;
  const percent = [0, 7, 13, 20, 28][level];
  return percent ? `color-mix(in oklab, var(--primary) ${percent}%, transparent)` : undefined;
}

/**
 * Twelve mini-months. Each day shows a dot per source (up to three) and a tint for how busy
 * it is. Click a day to open it in the day view, a month name for the month view.
 */
export function YearView({
  year,
  items,
  onPickDay,
  onPickMonth,
}: {
  year: number;
  items: CalendarItem[];
  onPickDay: (day: Date) => void;
  onPickMonth: (month: Date) => void;
}) {
  const byDay = useMemo(() => summarizeByDay(items), [items]);
  const months = eachMonthOfInterval({ start: new Date(year, 0, 1), end: new Date(year, 11, 1) });
  const today = toDay(new Date());
  const weekdays = Array.from({ length: 7 }, (_, i) =>
    format(addDays(startOfWeek(new Date(), { weekStartsOn: WEEK_STARTS_ON }), i), "EEEEE"),
  );

  return (
    <div className="grid grid-cols-2 gap-x-4 gap-y-6 p-4 sm:grid-cols-3 md:p-6 xl:grid-cols-4">
      {months.map((month) => (
        <MiniMonth
          key={month.getMonth()}
          month={month}
          byDay={byDay}
          today={today}
          weekdays={weekdays}
          onPickDay={onPickDay}
          onPickMonth={onPickMonth}
        />
      ))}
    </div>
  );
}

function MiniMonth({
  month,
  byDay,
  today,
  weekdays,
  onPickDay,
  onPickMonth,
}: {
  month: Date;
  byDay: Map<string, DaySummary>;
  today: string;
  weekdays: string[];
  onPickDay: (day: Date) => void;
  onPickMonth: (month: Date) => void;
}) {
  const leading = (getDay(month) - WEEK_STARTS_ON + 7) % 7;
  const days = Array.from({ length: endOfMonth(month).getDate() }, (_, i) => addDays(month, i));

  return (
    <section aria-label={format(month, "MMMM yyyy")} className="min-w-0">
      <button
        type="button"
        onClick={() => onPickMonth(month)}
        className="mb-1.5 px-0.5 text-[13px] font-semibold tracking-tight hover:text-primary"
      >
        {format(month, "MMMM")}
      </button>
      <div className="grid grid-cols-7 gap-px text-center">
        {weekdays.map((d, i) => (
          <span key={i} className="pb-0.5 text-[10px] font-medium text-muted-foreground/70">
            {d}
          </span>
        ))}
        {Array.from({ length: leading }, (_, i) => (
          <span key={`pad-${i}`} />
        ))}
        {days.map((day) => {
          const key = toDay(day);
          const summary = byDay.get(key);
          const dots = summary ? [...summary.sources.entries()].slice(0, MAX_DOTS) : [];
          const isToday = key === today;
          const label = summary
            ? `${format(day, "EEE, MMM d")}: ${summary.count} item${summary.count === 1 ? "" : "s"} — ${summary.titles.join(", ")}`
            : format(day, "EEE, MMM d");
          return (
            <button
              key={key}
              type="button"
              onClick={() => onPickDay(day)}
              title={label}
              aria-label={label}
              style={{ background: densityTint(summary?.count ?? 0) }}
              className={cn(
                "flex aspect-square min-w-0 flex-col items-center justify-center gap-[2px] rounded-[5px] text-[11px] leading-none tabular transition-colors",
                "hover:ring-1 hover:ring-border focus-visible:ring-2 focus-visible:ring-ring/60 focus-visible:outline-none",
                isWeekend(day) && !summary && "text-muted-foreground/70",
                isToday && "font-semibold text-primary ring-1 ring-primary",
              )}
            >
              <span>{day.getDate()}</span>
              <span className="flex h-[4px] gap-[2px]">
                {dots.map(([source, color]) => (
                  <span
                    key={source}
                    className="size-[4px] rounded-full"
                    style={{ background: sourceColor(source, color) }}
                  />
                ))}
              </span>
            </button>
          );
        })}
      </div>
    </section>
  );
}
