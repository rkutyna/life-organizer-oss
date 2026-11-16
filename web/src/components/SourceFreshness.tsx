import { useQuery } from "@tanstack/react-query";
import { ChevronRight } from "lucide-react";

import { api, unwrap, type SourceStatus } from "@/api/client";
import { statusColor } from "@/app/tokens";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { formatAge, formatTimestamp } from "@/lib/dates";
import { cn } from "@/lib/utils";

export const sourceStatusKey = ["status", "sources"] as const;

/** Every mirrored source's freshness, refreshed each minute. */
export function useSourceStatuses() {
  return useQuery({
    queryKey: sourceStatusKey,
    queryFn: () => unwrap(api.GET("/api/status/sources")),
    refetchInterval: 60_000,
  });
}

/**
 * The order the strip lists sources in: calendars first, then the other mirrors. A source not
 * listed here goes at the end, in the server's order.
 */
const ORDER = ["eventkit", "caldav", "google_calendar", "reminders", "mail"];

function rank(source: string): number {
  const index = ORDER.indexOf(source);
  return index === -1 ? ORDER.length : index;
}

/** The sources worth warning about (stale or failing), in strip order. */
function freshnessAlerts(data: SourceStatus[] | undefined, sources?: string[]): SourceStatus[] {
  return (data ?? [])
    .filter((s) => !sources || sources.includes(s.source))
    .map((status, index) => ({ status, index }))
    .sort((a, b) => rank(a.status.source) - rank(b.status.source) || a.index - b.index)
    .map(({ status }) => status)
    .filter((status) => {
      const { tone } = view(status);
      return tone === "stale" || tone === "error";
    });
}

/** Whether `<SourceFreshness sources={…} />` would show anything, so a page can skip its row. */
export function useHasFreshnessAlerts(sources?: string[]): boolean {
  const { data, isError } = useSourceStatuses();
  return isError || freshnessAlerts(data, sources).length > 0;
}

/** How one source reads. "Not set up" and "not synced yet" are states, not alarms. */
type Tone = "ok" | "stale" | "error" | "quiet";

function isNotConfigured(status: SourceStatus): boolean {
  return status.state === "error" && Boolean(status.last_error?.includes("not configured"));
}

function view(status: SourceStatus): { text: string; tone: Tone } {
  if (isNotConfigured(status)) return { text: "not set up", tone: "quiet" };
  switch (status.state) {
    case "ok":
      return { text: `as of ${formatAge(status.last_success_at)}`, tone: "ok" };
    case "stale":
      return { text: `stale · as of ${formatAge(status.last_success_at)}`, tone: "stale" };
    case "error":
      return {
        text: status.last_success_at
          ? `failing · last synced ${formatAge(status.last_success_at)}`
          : "failing",
        tone: "error",
      };
    default:
      return { text: "not synced yet", tone: "quiet" };
  }
}

const DOT: Record<Tone, string> = {
  ok: statusColor("ok"),
  stale: statusColor("stale"),
  error: statusColor("error"),
  quiet: statusColor("never"),
};

/**
 * Freshness warnings for mirrored sources (every mirror shows its age).
 *
 * Quiet by default: a source only appears when it is stale or failing. Healthy sources, ones
 * not set up, and ones not synced yet render nothing; with nothing to warn about the component
 * renders nothing at all. Each source's exact age stays one hover away on the pages that link
 * to it.
 *
 *   <SourceFreshness />                       all sources (calendar page)
 *   <SourceFreshness sources={["mail"]} />    just the ones a page depends on
 *   <SourceFreshness collapsible />           on phones, one summary line that opens the list
 */
export function SourceFreshness({
  sources,
  emptyLabel = null,
  collapsible = false,
  className,
}: {
  sources?: string[];
  emptyLabel?: string | null;
  collapsible?: boolean;
  className?: string;
}) {
  const { data, isError } = useSourceStatuses();
  const shown = freshnessAlerts(data, sources);

  if (isError) {
    return (
      <p className={cn("text-xs text-muted-foreground", className)}>Source status unavailable</p>
    );
  }
  if (!shown.length) {
    return emptyLabel ? (
      <p className={cn("flex items-center gap-1.5 text-xs text-muted-foreground", className)}>
        <span className="size-1.5 rounded-full" style={{ background: statusColor("ok") }} />
        {emptyLabel}
      </p>
    ) : null;
  }

  const list = <StatusList statuses={shown} />;
  if (!collapsible) return <div className={className}>{list}</div>;
  return (
    <div className={className}>
      <details className="group sm:hidden">
        <summary className="flex cursor-pointer list-none items-center gap-1.5 text-xs text-muted-foreground [&::-webkit-details-marker]:hidden">
          <ChevronRight className="size-3 transition-transform group-open:rotate-90" aria-hidden />
          {summarize(shown)}
        </summary>
        <div className="pt-1.5 pl-4">{list}</div>
      </details>
      <div className="hidden sm:block">{list}</div>
    </div>
  );
}

/** "Sources: 4 live · 1 failing · 2 not set up" for the collapsed phone view. */
function summarize(statuses: SourceStatus[]): string {
  const counts = new Map<string, number>();
  for (const status of statuses) {
    const { tone } = view(status);
    const label =
      tone === "ok"
        ? "live"
        : tone === "stale"
          ? "stale"
          : tone === "error"
            ? "failing"
            : isNotConfigured(status)
              ? "not set up"
              : "not synced yet";
    counts.set(label, (counts.get(label) ?? 0) + 1);
  }
  const order = ["live", "stale", "failing", "not set up", "not synced yet"];
  const parts = order.filter((label) => counts.has(label)).map((label) => `${counts.get(label)} ${label}`);
  return `Sources: ${parts.join(" · ")}`;
}

function StatusList({ statuses }: { statuses: SourceStatus[] }) {
  return (
    <ul className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
      {statuses.map((status) => {
        const { text, tone } = view(status);
        return (
          <li key={status.source}>
            <Tooltip>
              <TooltipTrigger asChild>
                <span className="flex cursor-default items-center gap-1.5 text-muted-foreground">
                  <span className="size-1.5 rounded-full" style={{ background: DOT[tone] }} />
                  <span className="text-foreground/80">{status.label}</span>
                  <span
                    className={cn(
                      "tabular",
                      tone === "stale" && "text-status-stale",
                      tone === "error" && "text-status-error",
                    )}
                  >
                    {text}
                  </span>
                </span>
              </TooltipTrigger>
              <TooltipContent className="max-w-xs">
                {status.last_success_at
                  ? `Last synced ${formatTimestamp(status.last_success_at)}`
                  : "Not synced yet"}
                {isNotConfigured(status)
                  ? " · not configured on the server"
                  : status.state === "error" && status.last_error
                    ? ` · ${status.last_error}`
                    : ""}
              </TooltipContent>
            </Tooltip>
          </li>
        );
      })}
    </ul>
  );
}
