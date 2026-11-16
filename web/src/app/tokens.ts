/**
 * Typed access to the color tokens in src/styles/tokens.css (the one place colors live).
 *
 *   <span style={{ background: sourceColor(source.key, source.color) }} />   a source
 *   <span style={{ background: itemColor(item) }} />                         one calendar item
 *   <span style={{ color: statusColor("overdue") }} />
 *
 * A source without a --source-<key> token falls back to the color the server sent. Items of
 * OWN_COLOR_SOURCES keep their own color: each synced calendar keeps its own color.
 */

/** "job_events" -> "job-events", matching the CSS custom property names. */
function cssKey(key: string): string {
  return key.replace(/[^a-zA-Z0-9]+/g, "-").toLowerCase();
}

export function sourceColor(source: string, fallback?: string | null): string {
  return `var(--source-${cssKey(source)}, ${fallback || "var(--source-default)"})`;
}

/**
 * Sources whose items carry their own color rather than the source's token: each synced calendar
 * keeps the color its provider gives it, each reminder its list's color.
 */
const OWN_COLOR_SOURCES = new Set(["apple", "reminders"]);

/** The color of one calendar item: its own for a synced calendar, else its source's token. */
export function itemColor(item: { source: string; color?: string | null }): string {
  if (OWN_COLOR_SOURCES.has(item.source) && item.color) return item.color;
  return sourceColor(item.source, item.color);
}

export type StatusKey =
  | "open"
  | "done"
  | "overdue"
  | "today"
  | "ok"
  | "stale"
  | "error"
  | "never";

export function statusColor(status: StatusKey | string): string {
  return `var(--status-${cssKey(status)}, var(--status-open))`;
}
