export const PRIORITY_LABELS: Record<number, string> = { 1: "High", 2: "Medium", 3: "Low" };

export const PRIORITY_OPTIONS = [
  { value: "1", label: "High" },
  { value: "2", label: "Medium" },
  { value: "3", label: "Low" },
];

/** Token color per priority (high reads as urgent, low recedes). */
export function priorityColor(priority: number | null | undefined): string {
  if (priority === 1) return "var(--status-overdue)";
  if (priority === 2) return "var(--status-stale)";
  return "var(--muted-foreground)";
}
