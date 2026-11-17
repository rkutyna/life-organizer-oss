import { Flag, StickyNote } from "lucide-react";

import { formatDue } from "@/lib/dates";
import { cn } from "@/lib/utils";

import type { Reminder } from "./api";
import { PRIORITY_LABELS, priorityColor } from "./priority";
import { DoneToggle, ListChip, SyncMark } from "./ReminderBits";

/** One row of the reminders list: check, title, notes mark, sync mark, priority, list, due. */
export function ReminderRow({
  reminder,
  today,
  selected,
  showList,
  onSelect,
  onOpen,
  onToggleDone,
  toggleDisabled = false,
}: {
  reminder: Reminder;
  /** Today as "YYYY-MM-DD". */
  today: string;
  selected: boolean;
  /** Show the list chip (off when one list is being viewed). */
  showList: boolean;
  onSelect: () => void;
  onOpen: () => void;
  onToggleDone: () => void;
  /** A reminder in a read-only list cannot be checked off. */
  toggleDisabled?: boolean;
}) {
  const done = reminder.completed;
  const due = reminder.due_date;
  const overdue = !done && due !== null && due < today;
  const dueToday = !done && due === today;

  return (
    <li
      data-row-key={reminder.id}
      data-selected={selected || undefined}
      onMouseDown={onSelect}
      onClick={onOpen}
      className={cn(
        "group flex h-9 cursor-default items-center gap-3 rounded-md px-2.5 transition-colors",
        "hover:bg-accent/60 data-[selected]:bg-selection",
      )}
    >
      <DoneToggle done={done} onToggle={onToggleDone} disabled={toggleDisabled} />
      <span
        className={cn(
          "min-w-0 flex-1 truncate text-[13px]",
          done && "text-muted-foreground line-through decoration-muted-foreground/50",
        )}
      >
        {reminder.title}
      </span>
      {reminder.notes && (
        <StickyNote className="size-3.5 shrink-0 text-muted-foreground/70" aria-label="Has notes" />
      )}
      <SyncMark reminder={reminder} />
      {reminder.priority && !done && (
        <Flag
          className="size-3.5 shrink-0"
          style={{ color: priorityColor(reminder.priority) }}
          aria-label={`${PRIORITY_LABELS[reminder.priority]} priority`}
        />
      )}
      {showList && <ListChip title={reminder.list_title} color={reminder.list_color} />}
      {due && (
        <span
          className={cn(
            "shrink-0 text-xs tabular text-muted-foreground",
            overdue && "text-status-overdue",
            dueToday && "text-status-today",
          )}
        >
          {formatDue(due, reminder.due_time)}
        </span>
      )}
    </li>
  );
}
