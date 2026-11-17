import { Layers, RefreshCw } from "lucide-react";

import { sourceColor } from "@/app/tokens";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { formatTimestamp } from "@/lib/dates";
import { cn } from "@/lib/utils";

import type { CalendarGroup } from "./externalApi";
import { describeFreshness } from "./freshness";

type Source = { key: string; label: string; color?: string | null };

/**
 * The calendar's toggles, collapsed behind one "Calendars" button so they take no room in the
 * header: built-in sources (holidays, ...) first, then each connected account with its age and
 * one toggle per calendar. Shows how many are switched off, and a dot when an account is out
 * of date.
 */
export function CalendarsMenu({
  sources,
  groups,
  hidden,
  onToggle,
  onShowAll,
  onSync,
  syncing,
}: {
  sources: Source[];
  groups: CalendarGroup[];
  hidden: string[];
  onToggle: (key: string) => void;
  onShowAll: () => void;
  onSync?: () => void;
  syncing?: boolean;
}) {
  const keys = [
    ...sources.map((s) => s.key),
    ...groups.flatMap((g) => g.calendars.map((c) => c.key)),
  ];
  const off = keys.filter((key) => hidden.includes(key)).length;
  const alerts = groups.filter((g) => describeFreshness(g.freshness).alert).length;
  const empty = sources.length === 0 && groups.length === 0;
  const hasAccounts = groups.some((g) => g.account_id !== null);

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          aria-label={`Calendars${off ? `, ${off} hidden` : ""}${alerts ? `, ${alerts} out of date` : ""}`}
        >
          <Layers />
          Calendars
          {off > 0 && (
            <span className="rounded-full bg-muted px-1.5 text-[11px] text-muted-foreground tabular">
              {off} off
            </span>
          )}
          {alerts > 0 && <span className="size-1.5 rounded-full bg-status-stale" aria-hidden />}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="max-h-[70vh] w-72 overflow-y-auto p-1.5 scrollbar-thin">
        {empty && (
          <p className="px-2 py-1.5 text-[13px] text-muted-foreground">
            No calendars yet. Connect one in Settings → Connected accounts.
          </p>
        )}
        <ul aria-label="Calendars" className="flex flex-col">
          {sources.map((source) => (
            <ToggleRow
              key={source.key}
              label={source.label}
              color={sourceColor(source.key, source.color)}
              shown={!hidden.includes(source.key)}
              onToggle={() => onToggle(source.key)}
            />
          ))}
        </ul>
        {groups.map((group) => {
          const age = describeFreshness(group.freshness);
          const synced = group.freshness.last_success_at
            ? `Last synced ${formatTimestamp(group.freshness.last_success_at)}`
            : "Not synced yet";
          const error = group.freshness.state === "error" ? group.freshness.last_error : null;
          return (
            <section
              key={group.account_id ?? group.kind}
              aria-label={group.label}
              className={cn(
                "flex flex-col",
                (sources.length > 0 || group !== groups[0]) && "mt-1 border-t border-border pt-1",
              )}
            >
              <div
                className="flex items-baseline gap-2 px-2 pt-1 pb-0.5"
                title={error ? `${synced} · ${error}` : synced}
              >
                <span className="min-w-0 flex-1 truncate text-xs font-medium text-muted-foreground">
                  {group.label}
                </span>
                <span
                  className={cn(
                    "flex shrink-0 items-center gap-1 text-[11px] text-muted-foreground tabular",
                    group.freshness.state === "stale" && "text-status-stale",
                    group.freshness.state === "error" && "text-status-error",
                  )}
                >
                  <span className="size-1.5 rounded-full" style={{ background: age.color }} />
                  {age.text}
                </span>
              </div>
              {group.calendars.length === 0 ? (
                <p className="px-2 py-1 text-xs text-muted-foreground">No calendars yet</p>
              ) : (
                <ul className="flex flex-col">
                  {group.calendars.map((calendar) => (
                    <ToggleRow
                      key={calendar.key}
                      label={calendar.title || "Untitled"}
                      color={calendar.color}
                      shown={!hidden.includes(calendar.key)}
                      onToggle={() => onToggle(calendar.key)}
                    />
                  ))}
                </ul>
              )}
            </section>
          );
        })}
        {(off > 0 || (hasAccounts && onSync)) && (
          <div className="mt-1 flex items-center border-t border-border pt-1">
            {off > 0 && (
              <button
                type="button"
                onClick={onShowAll}
                className="flex-1 rounded-sm px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
              >
                Show all
              </button>
            )}
            {hasAccounts && onSync && (
              <button
                type="button"
                onClick={onSync}
                disabled={syncing}
                className="ml-auto flex items-center gap-1.5 rounded-sm px-2 py-1.5 text-xs text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-60"
              >
                <RefreshCw className={cn("size-3", syncing && "animate-spin")} aria-hidden />
                {syncing ? "Syncing…" : "Sync now"}
              </button>
            )}
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}

function ToggleRow({
  label,
  color,
  shown,
  onToggle,
}: {
  label: string;
  color: string;
  shown: boolean;
  onToggle: () => void;
}) {
  return (
    <li>
      <button
        type="button"
        role="menuitemcheckbox"
        aria-checked={shown}
        onClick={onToggle}
        className={cn(
          "flex w-full items-center gap-2.5 rounded-sm px-2 py-1.5 text-left text-[13px] hover:bg-accent",
          !shown && "text-muted-foreground",
        )}
      >
        <span
          className="size-2.5 shrink-0 rounded-full border-[1.5px]"
          style={{ borderColor: color, background: shown ? color : "transparent" }}
        />
        <span className="flex-1 truncate">{label}</span>
      </button>
    </li>
  );
}
