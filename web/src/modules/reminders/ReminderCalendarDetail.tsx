import { ArrowUpRight, Check } from "lucide-react";
import { Link } from "react-router";

import type { CalendarDetailProps } from "@/app/modules";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { formatDue } from "@/lib/dates";
import { cn } from "@/lib/utils";

import {
  isReadOnlyList,
  providerName,
  useReminder,
  useReminderLists,
  useSetReminderDone,
} from "./api";
import { SyncNote } from "./ReminderBits";

/**
 * The calendar drawer for a dated reminder: what it is, where it lives, its sync state, a way to
 * check it off, and a link to the reminders page, where it is edited.
 */
export default function ReminderCalendarDetail({ item }: CalendarDetailProps) {
  const id = typeof item.meta?.reminder_id === "number" ? item.meta.reminder_id : null;
  const reminder = useReminder(id);
  const lists = useReminderLists();
  const setDone = useSetReminderDone();

  if (reminder.isPending) return <Skeleton className="h-24 w-full" />;
  if (reminder.isError) {
    return <p className="text-[13px] text-muted-foreground">{reminder.error.message}</p>;
  }
  const r = reminder.data;
  return (
    <div className="space-y-4">
      <h2
        className={cn(
          "text-base font-medium",
          r.completed && "text-muted-foreground line-through",
        )}
      >
        {r.title}
      </h2>
      <dl className="grid grid-cols-[5rem_1fr] gap-y-1.5 text-[13px]">
        <dt className="text-muted-foreground">List</dt>
        <dd>
          {r.list_title ?? "None"}{" "}
          <span className="text-muted-foreground">· {providerName(r.source)}</span>
        </dd>
        <dt className="text-muted-foreground">Due</dt>
        <dd className="tabular">{r.due_date ? formatDue(r.due_date, r.due_time) : "No date"}</dd>
      </dl>
      <SyncNote reminder={r} />
      <div className="flex flex-wrap gap-2">
        <Button
          size="sm"
          variant="outline"
          disabled={setDone.isPending || isReadOnlyList(lists.data, r.list_id)}
          onClick={() => setDone.mutate({ id: r.id, done: !r.completed })}
        >
          <Check />
          {r.completed ? "Mark not done" : "Mark done"}
        </Button>
        <Button size="sm" variant="ghost" asChild>
          <Link to={item.detail_url ?? `/reminders?reminder=${r.id}`}>
            Open in Reminders
            <ArrowUpRight />
          </Link>
        </Button>
      </div>
    </div>
  );
}
