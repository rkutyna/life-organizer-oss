import { Check, CircleAlert, Clock, Loader2, RotateCw, Undo2 } from "lucide-react";
import type { MouseEvent } from "react";
import { toast } from "sonner";

import { sourceColor } from "@/app/tokens";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { formatAge, formatTimestamp } from "@/lib/dates";
import { cn } from "@/lib/utils";

import {
  failedOps,
  providerName,
  useReminderStatus,
  useRetryOp,
  useWithdrawOp,
  type Reminder,
} from "./api";

/** Round check button, shared by the list and the drawers. */
export function DoneToggle({
  done,
  onToggle,
  disabled,
  className,
}: {
  done: boolean;
  onToggle: () => void;
  disabled?: boolean;
  className?: string;
}) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={done}
      aria-label={done ? "Mark not done" : "Mark done"}
      disabled={disabled}
      onClick={(e) => {
        e.stopPropagation();
        onToggle();
      }}
      className={cn(
        "grid size-4 shrink-0 place-content-center rounded-full border transition-colors outline-none focus-visible:ring-2 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-40",
        done
          ? "border-transparent bg-status-done text-background"
          : "border-muted-foreground/50 hover:border-foreground",
        className,
      )}
    >
      {done && <Check className="size-3" strokeWidth={3} />}
    </button>
  );
}

/** Small list label in the list's color. On phones only the color dot shows. */
export function ListChip({ title, color }: { title: string | null; color: string | null }) {
  return (
    <span
      className="flex max-w-28 shrink-0 items-center gap-1 rounded-full border border-border px-1.5 py-px text-[11px] text-muted-foreground"
      title={title ?? undefined}
    >
      <span
        className="size-2 shrink-0 rounded-full"
        style={{ background: color ?? sourceColor("reminders") }}
      />
      <span className="sr-only truncate sm:not-sr-only sm:whitespace-nowrap">{title}</span>
    </span>
  );
}

/** Stop a click on a row's control from also opening or selecting the row. */
const stop = (e: MouseEvent) => e.stopPropagation();

/**
 * The row's sync mark: nothing when synced; a spinner while a change is on its way; a muted
 * clock when the Mac has not picked it up; a red mark for a change the provider refused (its
 * popover offers Retry and Withdraw).
 */
export function SyncMark({ reminder }: { reminder: Reminder }) {
  const { sync } = reminder;
  const provider = providerName(reminder.source);
  if (sync.state === "synced") return null;

  if (sync.state === "syncing") {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <span
            role="img"
            aria-label={`Saving to ${provider}`}
            className="grid shrink-0 place-items-center"
          >
            <Loader2 className="size-3 animate-spin text-muted-foreground" aria-hidden />
          </span>
        </TooltipTrigger>
        <TooltipContent>Saving to {provider}</TooltipContent>
      </Tooltip>
    );
  }

  if (sync.state === "waiting_for_device") {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <span className="flex shrink-0 items-center gap-1 text-[11px] text-muted-foreground tabular">
            <Clock className="size-3" aria-hidden />
            <span className="sr-only sm:not-sr-only sm:whitespace-nowrap">waiting for Mac</span>
          </span>
        </TooltipTrigger>
        <TooltipContent>
          {sync.waiting_since
            ? `Queued ${formatTimestamp(sync.waiting_since)}. Applies when your Mac is awake.`
            : "Applies when your Mac is awake."}
        </TooltipContent>
      </Tooltip>
    );
  }

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          aria-label={`${provider} did not take a change. Show details`}
          title={`${provider} did not take a change`}
          onClick={stop}
          onMouseDown={stop}
          className="grid size-5 shrink-0 place-items-center rounded-sm text-status-error outline-none focus-visible:ring-2 focus-visible:ring-ring/50"
        >
          <CircleAlert className="size-3.5" aria-hidden />
        </button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-64 p-3" onClick={stop} onMouseDown={stop}>
        <FailedActions reminder={reminder} />
      </PopoverContent>
    </Popover>
  );
}

/** The error and the two ways out: try the failed change again, or drop it. */
export function FailedActions({ reminder }: { reminder: Reminder }) {
  const retry = useRetryOp();
  const withdraw = useWithdrawOp();
  const ops = failedOps(reminder);
  const busy = retry.isPending || withdraw.isPending;

  async function each(run: (opId: number) => Promise<unknown>) {
    const results = await Promise.allSettled(ops.map((op) => run(op.id)));
    const failed = results.find((r) => r.status === "rejected");
    if (failed && failed.status === "rejected") {
      toast.error(`Could not update: ${(failed.reason as Error).message}`);
    }
  }

  return (
    <div className="space-y-2.5 text-[13px]">
      <p className="flex items-center gap-1.5 font-medium text-status-error">
        <CircleAlert className="size-3.5 shrink-0" aria-hidden />
        {providerName(reminder.source)} did not take this change.
      </p>
      {reminder.sync.error && (
        <p className="break-words text-xs text-muted-foreground">{reminder.sync.error}</p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button
          size="sm"
          variant="outline"
          disabled={busy || ops.length === 0}
          onClick={() => each((id) => retry.mutateAsync(id))}
        >
          <RotateCw />
          Retry
        </Button>
        <Button
          size="sm"
          variant="ghost"
          disabled={busy || ops.length === 0}
          onClick={() => each((id) => withdraw.mutateAsync(id))}
        >
          <Undo2 />
          Withdraw
        </Button>
      </div>
    </div>
  );
}

/** The sync state as a line of text, for the drawers. */
export function SyncNote({ reminder }: { reminder: Reminder }) {
  const { sync } = reminder;
  const provider = providerName(reminder.source);
  if (sync.state === "synced") {
    return <p className="text-xs text-muted-foreground">Synced with {provider}</p>;
  }
  if (sync.state === "syncing") {
    return (
      <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <Loader2 className="size-3 animate-spin" aria-hidden />
        Saving to {provider}
      </p>
    );
  }
  if (sync.state === "waiting_for_device") {
    return (
      <p className="flex items-start gap-1.5 text-xs text-muted-foreground">
        <Clock className="mt-px size-3 shrink-0" aria-hidden />
        <span>
          Waiting for Mac
          {sync.waiting_since ? ` since ${formatAge(sync.waiting_since)}` : ""}. The change applies
          when your Mac is awake and the helper is running.
        </span>
      </p>
    );
  }
  return (
    <div className="rounded-md border border-border p-3">
      <FailedActions reminder={reminder} />
    </div>
  );
}

/**
 * Shown while queued Apple changes cannot reach the Mac because the helper is not polling.
 * Calm on purpose: it is information, not an alarm.
 */
export function HelperBanner() {
  const { data } = useReminderStatus();
  if (!data?.waiting_for_device) return null;
  return (
    <p
      role="status"
      className="flex items-center gap-2 rounded-md bg-muted px-3 py-2 text-[13px] text-muted-foreground"
    >
      <Clock className="size-3.5 shrink-0" aria-hidden />
      Apple Reminders changes will apply when your Mac is awake and the helper is running.
    </p>
  );
}
