import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { History, Undo2 } from "lucide-react";
import { toast } from "sonner";

import { api, unwrap, type Change } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { formatAge, formatTimestamp } from "@/lib/dates";
import { cn } from "@/lib/utils";

/** Query key prefix for history. Invalidate `["history"]` after writing any owned record. */
export const historyKey = (table: string, recordId: string | number) =>
  ["history", table, String(recordId)] as const;

const AUTHOR_LABELS: Record<string, string> = {
  me: "You",
  claude: "Claude",
  claude_remote: "Claude (remote)",
  helper: "Mac helper",
  system: "System",
};

function fieldLabel(field: string): string {
  const words = field.replace(/_id$/, "").replace(/_/g, " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function formatValue(value: unknown): string {
  if (value === null || value === undefined || value === "") return "empty";
  if (typeof value === "boolean") return value ? "yes" : "no";
  if (typeof value === "string") {
    if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return formatTimestamp(value);
    return value.length > 60 ? `${value.slice(0, 57)}…` : value;
  }
  return JSON.stringify(value);
}

/** Per-field display of logged values, e.g. `{ priority: (v) => PRIORITY_LABELS[v] }`. */
export type FieldFormatters = Record<string, (value: unknown) => string>;

function describe(change: Change, formatters?: FieldFormatters): React.ReactNode {
  if (change.op === "create") return change.reverts_change_id ? "Restored" : "Created";
  if (change.op === "delete") return "Deleted";
  const format = (value: unknown) => {
    const custom = change.field ? formatters?.[change.field] : undefined;
    return value != null && custom ? custom(value) : formatValue(value);
  };
  return (
    <>
      <span className="text-muted-foreground">{fieldLabel(change.field ?? "")} </span>
      <span className={cn(change.old_value == null && "italic text-muted-foreground")}>
        {format(change.old_value)}
      </span>
      <span className="text-muted-foreground"> → </span>
      <span className={cn(change.new_value == null && "italic text-muted-foreground")}>
        {format(change.new_value)}
      </span>
    </>
  );
}

/** Consecutive changes from one logical write (same batch_id) shown together. */
function groupByBatch(changes: Change[]): Change[][] {
  const groups: Change[][] = [];
  for (const change of changes) {
    const last = groups[groups.length - 1];
    if (last && last[0].batch_id === change.batch_id) last.push(change);
    else groups.push([change]);
  }
  return groups;
}

/**
 * Who changed what on one owned record, newest first, with one-click revert per change.
 *
 *   <RecordHistoryPanel table="jobs_applications" recordId={app.id} onReverted={refetch} />
 *
 * `table` is the server table name (`__tablename__`). Reverts are themselves logged.
 * `formatters` turns stored values into words for chosen fields (priority 1 -> "High").
 */
export function RecordHistoryPanel({
  table,
  recordId,
  onReverted,
  formatters,
  className,
}: {
  table: string;
  recordId: string | number;
  onReverted?: () => void;
  formatters?: FieldFormatters;
  className?: string;
}) {
  const queryClient = useQueryClient();
  const history = useQuery({
    queryKey: historyKey(table, recordId),
    queryFn: () =>
      unwrap(api.GET("/api/history", { params: { query: { table, record_id: String(recordId) } } })),
  });

  const revert = useMutation({
    mutationFn: (changeId: number) =>
      unwrap(
        api.POST("/api/history/{change_id}/revert", { params: { path: { change_id: changeId } } }),
      ),
    onSuccess: () => {
      toast.success("Change reverted");
      void queryClient.invalidateQueries({ queryKey: ["history"] });
      onReverted?.();
    },
    onError: (error) => toast.error(`Could not revert: ${error.message}`),
  });

  return (
    <section aria-label="History" className={cn("text-[13px]", className)}>
      <h3 className="mb-2 flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
        <History className="size-3.5" aria-hidden />
        History
      </h3>
      {history.isPending ? (
        <div className="space-y-2">
          <Skeleton className="h-4 w-3/4" />
          <Skeleton className="h-4 w-1/2" />
        </div>
      ) : history.isError ? (
        <p className="text-status-error">Could not load history: {history.error.message}</p>
      ) : history.data.length === 0 ? (
        <p className="text-muted-foreground">No changes recorded.</p>
      ) : (
        <ol className="relative space-y-3 border-l border-border pl-3">
          {groupByBatch(history.data).map((group) => (
            <li key={group[0].batch_id} className="relative">
              <span className="absolute top-1.5 -left-[16.5px] size-2 rounded-full border-2 border-card bg-muted-foreground/50" />
              <div className="mb-0.5 flex items-center gap-1.5 text-xs text-muted-foreground">
                <span className="font-medium text-foreground/80">
                  {AUTHOR_LABELS[group[0].author] ?? group[0].author}
                </span>
                <span title={formatTimestamp(group[0].ts)}>{formatAge(group[0].ts)}</span>
                {group[0].reverts_change_id !== null && <span>· undo</span>}
              </div>
              <ul className="space-y-0.5">
                {group.map((change) => (
                  <li key={change.id} className="group flex items-start gap-2">
                    <span className="min-w-0 flex-1 break-words">
                      {describe(change, formatters)}
                    </span>
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          aria-label="Revert this change"
                          className="opacity-60 group-hover:opacity-100 focus-visible:opacity-100"
                          disabled={revert.isPending}
                          onClick={() => revert.mutate(change.id)}
                        >
                          <Undo2 />
                        </Button>
                      </TooltipTrigger>
                      <TooltipContent>Revert this change</TooltipContent>
                    </Tooltip>
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
