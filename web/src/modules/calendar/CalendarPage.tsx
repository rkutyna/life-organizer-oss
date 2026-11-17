import "./calendar.css";

import type {
  DatesSetArg,
  EventClickArg,
  EventContentArg,
  EventInput,
  EventMountArg,
} from "@fullcalendar/core";
import dayGridPlugin from "@fullcalendar/daygrid";
import interactionPlugin, { type DateClickArg } from "@fullcalendar/interaction";
import FullCalendar from "@fullcalendar/react";
import timeGridPlugin from "@fullcalendar/timegrid";
import {
  addDays,
  addMonths,
  addWeeks,
  addYears,
  endOfWeek,
  format,
  isSameMonth,
  isSameYear,
  startOfWeek,
} from "date-fns";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import type { CalendarItem } from "@/api/client";
import { itemColor } from "@/app/tokens";
import { PageHeader } from "@/components/PageHeader";
import { SourceFreshness, useHasFreshnessAlerts } from "@/components/SourceFreshness";
import { Button } from "@/components/ui/button";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { toDay } from "@/lib/dates";
import { useHotkeys } from "@/lib/hotkeys";
import { readStorage, writeStorage } from "@/lib/storage";
import { cn } from "@/lib/utils";

import { useCalendarItems, useCalendarSources } from "./api";
import { CalendarsMenu } from "./CalendarsMenu";
import { ItemDetail } from "./ItemDetail";
import { EXTERNAL_SOURCE, useCalendarGroups, useSyncNow } from "./externalApi";
import { toggleKey, WEEK_STARTS_ON } from "./items";
import { YearView } from "./YearView";

type CalendarView = "day" | "week" | "month" | "year";

const VIEWS: { key: CalendarView; label: string; short: string }[] = [
  { key: "day", label: "Day", short: "D" },
  { key: "week", label: "Week", short: "W" },
  { key: "month", label: "Month", short: "M" },
  { key: "year", label: "Year", short: "Y" },
];

const FULLCALENDAR_VIEW = {
  day: "timeGridDay",
  week: "timeGridWeek",
  month: "dayGridMonth",
} as const;

function step(view: CalendarView, date: Date, direction: 1 | -1): Date {
  if (view === "day") return addDays(date, direction);
  if (view === "week") return addWeeks(date, direction);
  if (view === "month") return addMonths(date, direction);
  return addYears(date, direction);
}

function title(view: CalendarView, date: Date): string {
  if (view === "day") return format(date, "EEEE, MMMM d");
  if (view === "month") return format(date, "MMMM yyyy");
  if (view === "year") return format(date, "yyyy");
  const start = startOfWeek(date, { weekStartsOn: WEEK_STARTS_ON });
  const end = endOfWeek(date, { weekStartsOn: WEEK_STARTS_ON });
  if (isSameMonth(start, end)) return `${format(start, "MMM d")} – ${format(end, "d, yyyy")}`;
  if (isSameYear(start, end)) return `${format(start, "MMM d")} – ${format(end, "MMM d, yyyy")}`;
  return `${format(start, "MMM d, yyyy")} – ${format(end, "MMM d, yyyy")}`;
}

function toEvent(item: CalendarItem): EventInput {
  return {
    id: item.id,
    title: item.title,
    start: item.start,
    end: item.end,
    allDay: item.all_day,
    classNames: item.status === "done" ? ["is-done"] : [],
    extendedProps: { item },
  };
}

function EventContent({ event, timeText, view }: EventContentArg) {
  const time = timeText && !event.allDay && (
    <span className="shrink-0 text-[10.5px] text-muted-foreground tabular">{timeText}</span>
  );
  if (view.type === "dayGridMonth") {
    return (
      <div className="flex min-w-0 items-baseline gap-1 overflow-hidden px-1 leading-tight">
        {time}
        <span className="lo-event-title min-w-0 truncate">{event.title}</span>
      </div>
    );
  }
  // Time grid: title first so short events still show what they are.
  return (
    <div className="flex min-w-0 flex-wrap items-baseline gap-x-1.5 overflow-hidden px-1 py-px leading-tight">
      <span className="lo-event-title min-w-0 truncate font-medium">{event.title}</span>
      {time}
    </div>
  );
}

/** Home: one calendar over every source, in day / week / month (FullCalendar) or year view. */
export default function CalendarPage() {
  const [view, setView] = useState<CalendarView>(() =>
    readStorage<CalendarView>("calendar.view", "week"),
  );
  const [date, setDate] = useState(() => new Date());
  const [hidden, setHidden] = useState<string[]>(() =>
    readStorage<string[]>("calendar.hiddenSources", []),
  );
  const [fcRange, setFcRange] = useState<{ start: string; end: string } | null>(null);
  const [selected, setSelected] = useState<CalendarItem | null>(null);
  const calendarRef = useRef<FullCalendar>(null);

  const range =
    view === "year"
      ? { start: `${date.getFullYear()}-01-01`, end: `${date.getFullYear() + 1}-01-01` }
      : fcRange;
  const items = useCalendarItems(range);
  const sources = useCalendarSources();
  const groups = useCalendarGroups();
  const syncNow = useSyncNow();
  // Connected calendars are listed one by one, under their accounts, instead of as one source.
  const plainSources = useMemo(
    () => (sources.data ?? []).filter((source) => source.key !== EXTERNAL_SOURCE),
    [sources.data],
  );

  const visibleItems = useMemo(
    () => (items.data?.items ?? []).filter((item) => !hidden.includes(toggleKey(item))),
    [items.data, hidden],
  );
  const events = useMemo(() => visibleItems.map(toEvent), [visibleItems]);

  // FullCalendar follows our view/date state. Deferred to a microtask: FullCalendar re-renders
  // synchronously (flushSync), which React forbids from inside an effect.
  useEffect(() => {
    if (view === "year") return;
    const api = calendarRef.current?.getApi();
    queueMicrotask(() => api?.changeView(FULLCALENDAR_VIEW[view], date));
  }, [view, date]);

  function chooseView(next: CalendarView) {
    setView(next);
    writeStorage("calendar.view", next);
  }

  const hasFreshnessAlerts = useHasFreshnessAlerts();

  function showAllSources() {
    setHidden([]);
    writeStorage("calendar.hiddenSources", []);
  }

  function toggleSource(key: string) {
    const next = hidden.includes(key) ? hidden.filter((k) => k !== key) : [...hidden, key];
    setHidden(next);
    writeStorage("calendar.hiddenSources", next);
  }

  function openDay(day: Date) {
    setDate(day);
    chooseView("day");
  }

  useHotkeys(
    {
      d: () => chooseView("day"),
      w: () => chooseView("week"),
      m: () => chooseView("month"),
      y: () => chooseView("year"),
      t: () => setDate(new Date()),
      ArrowLeft: () => setDate((d) => step(view, d, -1)),
      ArrowRight: () => setDate((d) => step(view, d, 1)),
    },
    { enabled: selected === null },
  );

  return (
    <>
      <PageHeader
        title={title(view, date)}
        titleExtra={
          <CalendarsMenu
            sources={plainSources}
            groups={groups.data ?? []}
            hidden={hidden}
            onToggle={toggleSource}
            onShowAll={showAllSources}
            onSync={() =>
              syncNow.mutate(undefined, {
                onSuccess: (outcomes) => {
                  const failed = outcomes.filter((o) => !o.ok).length;
                  if (failed) toast.error(`${failed} account${failed === 1 ? "" : "s"} could not sync`);
                  else toast.success("Calendars synced");
                },
                onError: (err) => toast.error(`Could not sync: ${err.message}`),
              })
            }
            syncing={syncNow.isPending}
          />
        }
        actions={
          <>
            <Button variant="outline" size="sm" onClick={() => setDate(new Date())}>
              Today
            </Button>
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Previous"
              onClick={() => setDate((d) => step(view, d, -1))}
            >
              <ChevronLeft />
            </Button>
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Next"
              onClick={() => setDate((d) => step(view, d, 1))}
            >
              <ChevronRight />
            </Button>
            <div
              role="group"
              aria-label="Calendar view"
              className="ml-1 flex rounded-md border border-border p-0.5"
            >
              {VIEWS.map((v) => (
                <button
                  key={v.key}
                  type="button"
                  aria-pressed={view === v.key}
                  onClick={() => chooseView(v.key)}
                  title={`${v.label} (${v.short})`}
                  className={cn(
                    "h-6 rounded-[4px] px-2 text-xs text-muted-foreground hover:text-foreground",
                    view === v.key && "bg-accent font-medium text-foreground",
                  )}
                >
                  <span className="sm:hidden">{v.short}</span>
                  <span className="hidden sm:inline">{v.label}</span>
                </button>
              ))}
            </div>
          </>
        }
      >
        {hasFreshnessAlerts ? <SourceFreshness collapsible /> : null}
      </PageHeader>

      {items.data?.errors.length ? (
        <p className="border-b border-border bg-status-error/10 px-5 py-1.5 text-xs text-status-error">
          {items.data.errors.map((e) => `${e.source}: ${e.message}`).join(" · ")}
        </p>
      ) : null}

      <div className="lo-calendar relative min-h-0 flex-1 overflow-auto bg-card scrollbar-thin">
        {view === "year" ? (
          <YearView
            year={date.getFullYear()}
            items={visibleItems}
            onPickDay={openDay}
            onPickMonth={(month) => {
              setDate(month);
              chooseView("month");
            }}
          />
        ) : (
          <FullCalendar
            ref={calendarRef}
            plugins={[dayGridPlugin, timeGridPlugin, interactionPlugin]}
            initialView={FULLCALENDAR_VIEW[view]}
            initialDate={date}
            headerToolbar={false}
            height="100%"
            firstDay={WEEK_STARTS_ON}
            nowIndicator
            dayMaxEvents
            scrollTime="07:00:00"
            eventDisplay="block"
            eventTimeFormat={{ hour: "numeric", minute: "2-digit", meridiem: "short" }}
            displayEventEnd={false}
            views={{
              timeGridWeek: {
                dayHeaderContent: ({ date: day, isToday }) => (
                  <span className="flex items-baseline gap-1">
                    <span>{format(day, "EEE")}</span>
                    <span
                      className={cn("text-[13px] text-foreground tabular", isToday && "text-primary")}
                    >
                      {day.getDate()}
                    </span>
                  </span>
                ),
              },
              timeGridDay: { dayHeaderFormat: { weekday: "long" } },
              dayGridMonth: { dayHeaderFormat: { weekday: "short" } },
            }}
            slotLabelFormat={{ hour: "numeric", meridiem: "short" }}
            allDayText="all day"
            events={events}
            eventContent={(arg) => <EventContent {...arg} />}
            eventDidMount={(arg: EventMountArg) => {
              const item = arg.event.extendedProps.item as CalendarItem;
              arg.el.style.setProperty("--lo-event-color", itemColor(item));
              arg.el.title = arg.event.title;
            }}
            eventClick={(arg: EventClickArg) => {
              arg.jsEvent.preventDefault();
              setSelected(arg.event.extendedProps.item as CalendarItem);
            }}
            dateClick={(arg: DateClickArg) => {
              if (arg.view.type === "dayGridMonth") openDay(arg.date);
            }}
            navLinks
            navLinkDayClick={(day) => openDay(day)}
            datesSet={(arg: DatesSetArg) =>
              setFcRange((prev) => {
                const next = { start: toDay(arg.start), end: toDay(arg.end) };
                return prev?.start === next.start && prev.end === next.end ? prev : next;
              })
            }
          />
        )}
        {items.isFetching && (
          <div className="pointer-events-none absolute top-0 right-0 left-0 h-0.5 animate-pulse bg-primary/40" />
        )}
      </div>

      <Sheet open={selected !== null} onOpenChange={(open) => !open && setSelected(null)}>
        <SheetContent className="w-full gap-0 overflow-y-auto sm:max-w-md">
          <SheetHeader className="pb-2">
            <SheetTitle className="text-xs font-medium text-muted-foreground">
              {selected?.read_only ? "Event" : "Details"}
            </SheetTitle>
            <SheetDescription className="sr-only">Calendar item details</SheetDescription>
          </SheetHeader>
          <div className="px-4 pb-6">
            {selected && <ItemDetail item={selected} onClose={() => setSelected(null)} />}
          </div>
        </SheetContent>
      </Sheet>
    </>
  );
}
