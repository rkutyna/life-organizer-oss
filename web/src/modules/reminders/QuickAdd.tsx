import { CalendarDays, Flag, Info, Plus } from "lucide-react";
import { useMemo, useState, type RefObject } from "react";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Kbd } from "@/components/ui/kbd";
import { formatDue, parseDay } from "@/lib/dates";
import { readStorage, writeStorage } from "@/lib/storage";

import { useCreateReminder, type ReminderList } from "./api";
import { fitToList, parseQuickAdd } from "./parse";
import { PRIORITY_LABELS, priorityColor } from "./priority";

/** The list last chosen on this device. */
const TARGET_KEY = "reminders.addTo";

/** Writable lists grouped by account, in the server's order. */
function groupByAccount(lists: ReminderList[]): [string, ReminderList[]][] {
  const groups = new Map<string, ReminderList[]>();
  for (const list of lists) {
    const label = list.source === "google" ? `Google · ${list.account}` : list.account || "Apple";
    groups.set(label, [...(groups.get(label) ?? []), list]);
  }
  return [...groups.entries()];
}

/**
 * One line to add a reminder, with natural-language dates ("tomorrow 3pm", "next fri", "!1"
 * for high priority) and a live preview of what was understood. The list is remembered per
 * device. Google Tasks lists keep a date only: a time or priority is dropped, and the preview
 * says so. Enter adds; Escape clears.
 */
export function QuickAdd({
  inputRef,
  lists,
  preferredList,
}: {
  inputRef: RefObject<HTMLInputElement | null>;
  lists: ReminderList[];
  /** The list being viewed, if any: new reminders go there. */
  preferredList?: string | null;
}) {
  const [text, setText] = useState("");
  const [remembered, setRemembered] = useState(() => readStorage<string | null>(TARGET_KEY, null));
  const writable = useMemo(() => lists.filter((list) => list.writable), [lists]);
  const byId = (id: string | null | undefined) => writable.find((list) => list.id === id);
  const target =
    byId(preferredList) ?? byId(remembered) ?? writable.find((l) => l.is_default) ?? writable[0];

  const create = useCreateReminder();
  const parsed = useMemo(() => (text.trim() ? parseQuickAdd(text) : null), [text]);
  const fitted = parsed ? fitToList(parsed, target) : null;

  function chooseTarget(next: string) {
    setRemembered(next);
    writeStorage(TARGET_KEY, next);
  }

  function submit() {
    if (!fitted?.fields.title || !target) return;
    const { title, due_date, due_time, priority } = fitted.fields;
    create.mutate(
      { title, due_date, due_time, priority, list_id: target.id },
      {
        onSuccess: () => setText(""),
        onError: (error: Error) => toast.error(`Could not add: ${error.message}`),
      },
    );
  }

  const disabled = create.isPending || !target;
  return (
    <div className="rounded-lg border border-border bg-card shadow-xs focus-within:border-ring focus-within:ring-2 focus-within:ring-ring/20">
      <div className="flex items-center gap-2 px-3">
        <Plus className="size-4 shrink-0 text-muted-foreground" aria-hidden />
        <input
          ref={inputRef}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              submit();
            } else if (e.key === "Escape") {
              setText("");
              e.currentTarget.blur();
            }
          }}
          placeholder={
            target
              ? "Add a reminder — try “Call the plumber tomorrow 3pm !1”"
              : "Connect Google Tasks or the Mac helper to add reminders"
          }
          aria-label="New reminder"
          className="h-10 min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground/70"
          disabled={disabled}
        />
        {writable.length > 0 && (
          <NativeSelect
            aria-label="Add to list"
            title="The list a new reminder goes into"
            value={target?.id ?? ""}
            onChange={(e) => chooseTarget(e.target.value)}
            disabled={create.isPending}
            className="h-7 max-w-28 shrink-0 border-transparent bg-transparent px-1 text-xs text-muted-foreground shadow-none sm:max-w-44 dark:bg-transparent"
          >
            {groupByAccount(writable).map(([account, group]) => (
              <optgroup key={account} label={account}>
                {group.map((list) => (
                  <option key={list.id} value={list.id}>
                    {list.title}
                  </option>
                ))}
              </optgroup>
            ))}
          </NativeSelect>
        )}
        <Kbd className="hidden sm:inline-flex">N</Kbd>
      </div>
      {fitted && (parsed?.due_date || parsed?.priority) && (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-t border-border px-3 py-1.5 text-xs">
          <span className="truncate text-foreground">{fitted.fields.title}</span>
          {fitted.fields.due_date && (
            <span
              className="flex items-center gap-1 font-medium"
              style={{ color: "var(--source-reminders)" }}
            >
              <CalendarDays className="size-3.5" aria-hidden />
              {formatDue(fitted.fields.due_date, fitted.fields.due_time)}
              <span className="font-normal text-muted-foreground">
                ·{" "}
                {parseDay(fitted.fields.due_date).toLocaleDateString([], {
                  weekday: "short",
                  month: "short",
                  day: "numeric",
                })}
              </span>
            </span>
          )}
          {fitted.fields.priority && (
            <span
              className="flex items-center gap-1"
              style={{ color: priorityColor(fitted.fields.priority) }}
            >
              <Flag className="size-3.5" aria-hidden />
              {PRIORITY_LABELS[fitted.fields.priority]}
            </span>
          )}
          {fitted.dropped.length > 0 && (
            <span className="flex items-center gap-1 text-muted-foreground">
              <Info className="size-3.5" aria-hidden />
              Google Tasks keeps no {fitted.dropped.join(" or ")}; it is left out
            </span>
          )}
          <span className="ml-auto hidden text-muted-foreground sm:inline">Enter to add</span>
        </div>
      )}
    </div>
  );
}
