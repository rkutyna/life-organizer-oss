import type { SourceStatus } from "@/api/client";
import { statusColor } from "@/app/tokens";
import { formatAge } from "@/lib/dates";

/** One account's age, worded like the freshness strip: "as of 5 min ago", "stale · …". */
export function describeFreshness(status: SourceStatus): {
  text: string;
  color: string;
  alert: boolean;
} {
  switch (status.state) {
    case "ok":
      return { text: `as of ${formatAge(status.last_success_at)}`, color: statusColor("ok"), alert: false };
    case "stale":
      return {
        text: `stale · as of ${formatAge(status.last_success_at)}`,
        color: statusColor("stale"),
        alert: true,
      };
    case "error":
      return {
        text: status.last_success_at
          ? `failing · last synced ${formatAge(status.last_success_at)}`
          : "failing",
        color: statusColor("error"),
        alert: true,
      };
    default:
      return { text: "not synced yet", color: statusColor("never"), alert: false };
  }
}
