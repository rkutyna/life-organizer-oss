import { ChevronRight, ListChecks, RefreshCw } from "lucide-react";
import { useMemo, useRef, useState, type ReactNode } from "react";
import { Link, useSearchParams } from "react-router";
import { toast } from "sonner";

import type { SourceStatus } from "@/api/client";
import { statusColor } from "@/app/tokens";
import { EmptyState } from "@/components/EmptyState";
import { NativeSelect } from "@/components/Field";
import { PageHeader } from "@/components/PageHeader";
import { Button } from "@/components/ui/button";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { formatAge, formatTimestamp, toDay } from "@/lib/dates";
import { useHotkeys } from "@/lib/hotkeys";
import { readStorage, writeStorage } from "@/lib/storage";
import { cn } from "@/lib/utils";

import {
  isReadOnlyList,
  useReminderLists,
  useReminders,
  useReminderStatus,
  useSetReminderDone,
  useSyncNow,
  type Reminder,
  type ReminderList,
} from "./api";
import { QuickAdd } from "./QuickAdd";
import { HelperBanner } from "./ReminderBits";
import { ReminderDetail } from "./ReminderDetail";
import { ReminderRow } from "./ReminderRow";

const COMPLETED_OPEN_KEY = "reminders.showCompleted";
const COMPLETED_LIMIT = 30;

type SectionKey = "overdue" | "today" | "upcoming" | "undated" | "completed";

const SECTION_LABELS: Record<SectionKey, string> = {
  overdue: "Overdue",
  today: "Today",
  upcoming: "Upcoming",
  undated: "No date",
  completed: "Completed recently",
};

/** Open reminders by section (the server already sorts them), then completed, newest first. */
function sections(rows: Reminder[], today: string): [SectionKey, Reminder[]][] {
  const out: Record<SectionKey, Reminder[]> = {
    overdue: [],
    today: [],
    upcoming: [],
    undated: [],
    completed: [],
  };
  for (const r of rows) {
    if (r.completed) out.completed.push(r);
    else if (!r.due_date) out.undated.push(r);
    else if (r.due_date < today) out.overdue.push(r);
    else if (r.due_date === today) out.today.push(r);
    else out.upcoming.push(r);
  }
  out.completed = out.completed.slice(0, COMPLETED_LIMIT);
  return (Object.keys(out) as SectionKey[]).map((key) => [key, out[key]]);
}

/** Lists grouped by account: Apple Reminders first, then each Google account. */
function groupLists(lists: ReminderList[]): { key: string; label: string; lists: ReminderList[] }[] {
  const groups = new Map<string, { key: string; label: string; lists: ReminderList[] }>();
  for (const list of lists) {
    const key = list.source === "google" ? `google:${list.account_id}` : "apple";
    const label = list.source === "google" ? list.account : `Apple Reminders · ${list.account}`;
    const group = groups.get(key) ?? { key, label, lists: [] };
    group.lists.push(list);
    groups.set(key, group);
  }
  return [...groups.values()];
}

/**
 * Reminders from Apple Reminders (through the Mac helper) and Google Tasks, in one place: the
 * lists on the left, then Overdue, Today, Upcoming, No date and Completed recently. Quick-add
 * reads natural-language dates. A click opens the edit drawer (?reminder=<id>); ?list=<id>
 * shows one list. Every change goes back to its provider; each row shows its sync state.
 */
export default function RemindersPage() {
  const [params, setParams] = useSearchParams();
  const listFilter = params.get("list");
  const openId = params.get("reminder") ? Number(params.get("reminder")) : null;

  const reminders = useReminders();
  const lists = useReminderLists();
  const setDone = useSetReminderDone();
  const [showCompleted, setShowCompleted] = useState(() =>
    readStorage<boolean>(COMPLETED_OPEN_KEY, false),
  );
  const [selected, setSelected] = useState<number | null>(null);
  const quickAddRef = useRef<HTMLInputElement>(null);

  const today = toDay(new Date());
  const allLists = useMemo(() => lists.data ?? [], [lists.data]);
  const currentList = allLists.find((list) => list.id === listFilter) ?? null;
  const rows = useMemo(
    () => (reminders.data ?? []).filter((r) => !listFilter || r.list_id === listFilter),
    [reminders.data, listFilter],
  );
  const grouped = useMemo(() => sections(rows, today), [rows, today]);
  const openCount = rows.filter((r) => !r.completed).length;
  // The rows in keyboard order: what is visible, top to bottom.
  const visible = grouped.flatMap(([key, items]) =>
    key === "completed" && !showCompleted ? [] : items,
  );

  function update(changes: Record<string, string | null>, replace = false) {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(changes)) {
      if (value === null) next.delete(key);
      else next.set(key, value);
    }
    setParams(next, { replace });
  }

  function open(id: number) {
    setSelected(id);
    update({ reminder: String(id) });
  }

  function toggle(reminder: Reminder) {
    if (isReadOnlyList(allLists, reminder.list_id)) return;
    setDone.mutate(
      { id: reminder.id, done: !reminder.completed },
      { onError: (error) => toast.error(`Could not update: ${error.message}`) },
    );
  }

  function move(step: number) {
    if (!visible.length) return;
    const index = visible.findIndex((r) => r.id === selected);
    const next = visible[Math.min(visible.length - 1, Math.max(0, index + step))];
    setSelected(next.id);
    document
      .querySelector(`[data-row-key="${next.id}"]`)
      ?.scrollIntoView({ block: "nearest" });
  }

  const current = visible.find((r) => r.id === selected);
  useHotkeys(
    {
      n: () => quickAddRef.current?.focus(),
      j: () => move(1),
      ArrowDown: () => move(1),
      k: () => move(-1),
      ArrowUp: () => move(-1),
      x: () => current && toggle(current),
      Enter: () => current && open(current.id),
      Escape: () => setSelected(null),
    },
    { enabled: openId === null },
  );

  const noSources = lists.isSuccess && allLists.length === 0;
  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader
        title={currentList ? currentList.title : "Reminders"}
        subtitle={reminders.isSuccess ? `${openCount} open` : undefined}
        actions={<SyncButton />}
      >
        <NativeSelect
          aria-label="Show list"
          value={listFilter ?? ""}
          onChange={(e) => update({ list: e.target.value || null }, true)}
          className="w-full md:hidden"
        >
          <option value="">All lists</option>
          {groupLists(allLists).map((group) => (
            <optgroup key={group.key} label={group.label}>
              {group.lists.map((list) => (
                <option key={list.id} value={list.id}>
                  {list.title} ({list.open_count})
                </option>
              ))}
            </optgroup>
          ))}
        </NativeSelect>
      </PageHeader>

      <div className="flex min-h-0 flex-1">
        <aside className="hidden w-60 shrink-0 flex-col gap-4 overflow-y-auto border-r border-border p-3 md:flex">
          <ListNav lists={allLists} current={listFilter} total={reminders.data} onPick={(id) => update({ list: id }, true)} />
          <SourceAges />
        </aside>

        <main className="min-w-0 flex-1 overflow-y-auto">
          <div className="mx-auto flex max-w-3xl flex-col gap-4 px-4 py-4 md:px-6">
            {noSources ? (
              <EmptyState
                icon={ListChecks}
                title="No reminders yet"
                description="Connect a Google account with Tasks in Settings, or install the Mac helper to sync Apple Reminders."
                action={
                  <Button asChild size="sm" variant="outline">
                    <Link to="/settings">Open Settings</Link>
                  </Button>
                }
              />
            ) : (
              <>
                <QuickAdd inputRef={quickAddRef} lists={allLists} preferredList={listFilter} />
                <HelperBanner />
                {reminders.isPending ? (
                  <div className="space-y-2">
                    {Array.from({ length: 5 }, (_, i) => (
                      <Skeleton key={i} className="h-8 w-full" />
                    ))}
                  </div>
                ) : reminders.isError ? (
                  <p className="text-[13px] text-muted-foreground">
                    Reminders are unavailable right now: {reminders.error.message}
                  </p>
                ) : rows.length === 0 ? (
                  <EmptyState
                    icon={ListChecks}
                    title="Nothing here"
                    description="Add one above. Dates like “friday 9am” or “next tue” are understood."
                  />
                ) : (
                  grouped.map(([key, items]) =>
                    items.length === 0 ? null : (
                      <Section
                        key={key}
                        sectionKey={key}
                        count={items.length}
                        collapsed={key === "completed" ? !showCompleted : undefined}
                        onToggleCollapsed={
                          key === "completed"
                            ? () => {
                                setShowCompleted(!showCompleted);
                                writeStorage(COMPLETED_OPEN_KEY, !showCompleted);
                              }
                            : undefined
                        }
                      >
                        <ul className="flex flex-col">
                          {items.map((r) => (
                            <ReminderRow
                              key={r.id}
                              reminder={r}
                              today={today}
                              selected={r.id === selected}
                              showList={!listFilter}
                              onSelect={() => setSelected(r.id)}
                              onOpen={() => open(r.id)}
                              onToggleDone={() => toggle(r)}
                              toggleDisabled={isReadOnlyList(allLists, r.list_id)}
                            />
                          ))}
                        </ul>
                      </Section>
                    ),
                  )
                )}
              </>
            )}
          </div>
        </main>
      </div>

      <Sheet open={openId !== null} onOpenChange={(isOpen) => !isOpen && update({ reminder: null }, true)}>
        <SheetContent className="w-full gap-0 overflow-y-auto p-5 sm:max-w-md">
          <SheetHeader className="p-0 pb-4">
            <SheetTitle className="text-sm text-muted-foreground">Reminder</SheetTitle>
            <SheetDescription className="sr-only">
              Edit the reminder; each change syncs back to its list.
            </SheetDescription>
          </SheetHeader>
          {openId !== null && <ReminderDetail reminderId={openId} />}
        </SheetContent>
      </Sheet>
    </div>
  );
}

function Section({
  sectionKey,
  count,
  collapsed,
  onToggleCollapsed,
  children,
}: {
  sectionKey: SectionKey;
  count: number;
  collapsed?: boolean;
  onToggleCollapsed?: () => void;
  children: ReactNode;
}) {
  const label = (
    <span
      className={cn(
        "text-xs font-medium tracking-wide text-muted-foreground uppercase",
        sectionKey === "overdue" && "text-status-overdue",
      )}
    >
      {SECTION_LABELS[sectionKey]} <span className="tabular">{count}</span>
    </span>
  );
  return (
    <section aria-label={SECTION_LABELS[sectionKey]} className="flex flex-col gap-1">
      {onToggleCollapsed ? (
        <button
          type="button"
          aria-expanded={!collapsed}
          onClick={onToggleCollapsed}
          className="flex items-center gap-1 self-start rounded-sm px-2.5 outline-none focus-visible:ring-2 focus-visible:ring-ring/50"
        >
          <ChevronRight
            className={cn("size-3 text-muted-foreground transition-transform", !collapsed && "rotate-90")}
            aria-hidden
          />
          {label}
        </button>
      ) : (
        <h2 className="px-2.5">{label}</h2>
      )}
      {!collapsed && children}
    </section>
  );
}

/** The lists, grouped by account, with open counts. "All" on top. */
function ListNav({
  lists,
  current,
  total,
  onPick,
}: {
  lists: ReminderList[];
  current: string | null;
  total: Reminder[] | undefined;
  onPick: (id: string | null) => void;
}) {
  const allOpen = (total ?? []).filter((r) => !r.completed).length;
  const item = (key: string | null, label: string, count: number, color?: string | null) => (
    <li key={key ?? "all"}>
      <button
        type="button"
        aria-current={current === key ? "page" : undefined}
        onClick={() => onPick(key)}
        className={cn(
          "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] hover:bg-accent",
          current === key && "bg-selection font-medium",
        )}
      >
        {color !== undefined && (
          <span
            className="size-2.5 shrink-0 rounded-full"
            style={{ background: color ?? "var(--source-reminders)" }}
          />
        )}
        <span className="flex-1 truncate">{label}</span>
        <span className="text-xs text-muted-foreground tabular">{count}</span>
      </button>
    </li>
  );
  return (
    <nav aria-label="Lists" className="flex flex-col gap-3">
      <ul>{item(null, "All reminders", allOpen)}</ul>
      {groupLists(lists).map((group) => (
        <div key={group.key}>
          <p className="truncate px-2 pb-1 text-[11px] font-medium tracking-wide text-muted-foreground uppercase">
            {group.label}
          </p>
          <ul>{group.lists.map((list) => item(list.id, list.title, list.open_count, list.color))}</ul>
        </div>
      ))}
    </nav>
  );
}

/** How old each source's copy is: the Mac helper's last push and each Google account's poll. */
function SourceAges() {
  const status = useReminderStatus();
  if (!status.data) return null;
  const rows: { key: string; label: string; freshness: SourceStatus }[] = [];
  if (status.data.helper.state !== "never") {
    rows.push({ key: "helper", label: "Apple Reminders (Mac)", freshness: status.data.helper });
  }
  for (const account of status.data.google) {
    rows.push({ key: `g${account.account_id}`, label: account.label, freshness: account.freshness });
  }
  if (!rows.length) return null;
  return (
    <ul className="mt-auto flex flex-col gap-1 border-t border-border pt-3 text-xs">
      {rows.map(({ key, label, freshness }) => (
        <li key={key}>
          <Tooltip>
            <TooltipTrigger asChild>
              <span className="flex cursor-default items-center gap-1.5 text-muted-foreground">
                <span
                  className="size-1.5 shrink-0 rounded-full"
                  style={{ background: statusColor(freshness.state) }}
                />
                <span className="truncate text-foreground/80">{label}</span>
                <span className="ml-auto shrink-0 tabular">
                  {freshness.state === "error" ? "failing" : formatAge(freshness.last_success_at)}
                </span>
              </span>
            </TooltipTrigger>
            <TooltipContent className="max-w-xs">
              {freshness.last_success_at
                ? `Last synced ${formatTimestamp(freshness.last_success_at)}`
                : "Not synced yet"}
              {freshness.state === "error" && freshness.last_error ? ` · ${freshness.last_error}` : ""}
            </TooltipContent>
          </Tooltip>
        </li>
      ))}
    </ul>
  );
}

/** Poll Google Tasks now (shown when a Google account is connected). */
function SyncButton() {
  const status = useReminderStatus();
  const sync = useSyncNow();
  if (!status.data?.google.length) return null;
  return (
    <Button
      size="sm"
      variant="outline"
      disabled={sync.isPending}
      onClick={() =>
        sync.mutate(undefined, {
          onSuccess: (outcomes) => {
            const failed = outcomes.filter((o) => !o.ok);
            if (failed.length) toast.error(`Sync failed: ${failed[0].error}`);
          },
          onError: (error) => toast.error(`Sync failed: ${error.message}`),
        })
      }
    >
      <RefreshCw className={cn(sync.isPending && "animate-spin")} />
      Sync
    </Button>
  );
}
