import { ArrowUpRight, Lock } from "lucide-react";

import type { CalendarDetailProps } from "@/app/modules";
import { Button } from "@/components/ui/button";
import { formatTimestamp } from "@/lib/dates";
import { cn, sentence } from "@/lib/utils";

import { useCalendarGroups } from "./externalApi";
import { describeFreshness } from "./freshness";

const STATUS_TEXT: Record<string, string> = {
  tentative: "Tentative",
  canceled: "Canceled",
};

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

/**
 * The drawer for an event from a connected calendar or the Mac helper: read-only, with where it
 * came from and how old that copy is.
 */
export default function ExternalEventDetail({ item }: CalendarDetailProps) {
  const groups = useCalendarGroups();
  const meta = item.meta ?? {};
  const calendar = text(meta.calendar);
  const account = text(meta.account);
  const location = text(meta.location);
  const fromHelper = meta.origin === "eventkit";
  const accountId = typeof meta.account_id === "number" ? meta.account_id : null;
  const group = groups.data?.find((g) => g.account_id === accountId);
  const age = group ? describeFreshness(group.freshness) : null;
  const status = item.status ? STATUS_TEXT[item.status] : undefined;
  const link = item.detail_url?.startsWith("http") ? item.detail_url : null;
  const google = link?.includes("google.com/calendar");

  return (
    <div className="space-y-4">
      <h2 className={cn("text-base font-medium", item.status === "canceled" && "line-through")}>
        {item.title || "(No title)"}
      </h2>

      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-[13px]">
        {status && (
          <>
            <dt className="text-muted-foreground">Status</dt>
            <dd>{status}</dd>
          </>
        )}
        {location && (
          <>
            <dt className="text-muted-foreground">Where</dt>
            <dd className="break-words">{location}</dd>
          </>
        )}
        {calendar && (
          <>
            <dt className="text-muted-foreground">Calendar</dt>
            <dd className="flex items-center gap-1.5">
              <span className="size-2 shrink-0 rounded-full" style={{ background: item.color }} />
              {calendar}
            </dd>
          </>
        )}
        {account && (
          <>
            <dt className="text-muted-foreground">Account</dt>
            <dd className="break-words">{account}</dd>
          </>
        )}
        <dt className="text-muted-foreground">Synced</dt>
        <dd>
          {fromHelper ? (
            "From the Mac helper"
          ) : age && group ? (
            <span
              className="flex items-center gap-1.5"
              title={
                group.freshness.last_success_at
                  ? `Last synced ${formatTimestamp(group.freshness.last_success_at)}`
                  : undefined
              }
            >
              <span className="size-1.5 rounded-full" style={{ background: age.color }} />
              <span
                className={cn(
                  "tabular",
                  group.freshness.state === "stale" && "text-status-stale",
                  group.freshness.state === "error" && "text-status-error",
                )}
              >
                {sentence(age.text)}
              </span>
            </span>
          ) : (
            "From a connected account"
          )}
        </dd>
      </dl>

      <div className="flex flex-wrap items-center gap-3">
        {link && (
          <Button asChild variant="outline" size="sm">
            <a href={link} target="_blank" rel="noreferrer">
              {google ? "Open in Google Calendar" : "Open link"}
              <ArrowUpRight />
            </a>
          </Button>
        )}
        <span className="flex items-center gap-1 text-xs text-muted-foreground">
          <Lock className="size-3" aria-hidden />
          Read-only here; edit it in its own calendar app
        </span>
      </div>
    </div>
  );
}
