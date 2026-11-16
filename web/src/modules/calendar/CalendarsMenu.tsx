import { Layers } from "lucide-react";

import { sourceColor } from "@/app/tokens";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";

type Source = { key: string; label: string; color?: string | null };

/**
 * The calendar's source toggles, collapsed behind one "Calendars" button so they take no room
 * in the header. Shows how many are switched off.
 */
export function CalendarsMenu({
  sources,
  hidden,
  onToggle,
  onShowAll,
}: {
  sources: Source[];
  hidden: string[];
  onToggle: (key: string) => void;
  onShowAll: () => void;
}) {
  const off = sources.filter((s) => hidden.includes(s.key)).length;
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="outline" size="sm" aria-label={`Calendars${off ? `, ${off} hidden` : ""}`}>
          <Layers />
          Calendars
          {off > 0 && (
            <span className="rounded-full bg-muted px-1.5 text-[11px] text-muted-foreground tabular">
              {off} off
            </span>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-64 p-1.5">
        {sources.length === 0 && (
          <p className="px-2 py-1.5 text-[13px] text-muted-foreground">
            No calendars yet. Public holidays can be turned on in Settings.
          </p>
        )}
        <ul aria-label="Calendars" className="flex flex-col">
          {sources.map((source) => {
            const shown = !hidden.includes(source.key);
            const color = sourceColor(source.key, source.color);
            return (
              <li key={source.key}>
                <button
                  type="button"
                  role="menuitemcheckbox"
                  aria-checked={shown}
                  onClick={() => onToggle(source.key)}
                  className={cn(
                    "flex w-full items-center gap-2.5 rounded-sm px-2 py-1.5 text-left text-[13px] hover:bg-accent",
                    !shown && "text-muted-foreground",
                  )}
                >
                  <span
                    className="size-2.5 shrink-0 rounded-full border-[1.5px]"
                    style={{ borderColor: color, background: shown ? color : "transparent" }}
                  />
                  <span className="flex-1 truncate">{source.label}</span>
                </button>
              </li>
            );
          })}
        </ul>
        {off > 0 && (
          <div className="mt-1 border-t border-border pt-1">
            <button
              type="button"
              onClick={onShowAll}
              className="w-full rounded-sm px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
            >
              Show all
            </button>
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}
