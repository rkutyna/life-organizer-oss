import { addDays, format } from "date-fns";
import { ChevronLeft, ChevronRight, Pencil, Plus, Trash2 } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { parseDay, toDay } from "@/lib/dates";
import { sentence } from "@/lib/utils";

import {
  GOAL_METRICS,
  jobsApi,
  useGoalProgress,
  useGoals,
  useJobsMutation,
  type GoalMetric,
  type WeeklyGoal,
} from "./api";
import { Card, ErrorLine, kindTone, Muted, Section } from "./parts";

/**
 * Optional weekly goals: each goal's count for a week (Monday to Sunday) against its target,
 * with previous/next week, and an edit mode to add, change or remove goals (one per metric).
 */
export function GoalsPanel() {
  const [week, setWeek] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const progress = useGoalProgress(week);

  function shift(days: number) {
    if (!progress.data) return;
    setWeek(toDay(addDays(parseDay(progress.data.week_start), days)));
  }

  const range = progress.data
    ? `${format(parseDay(progress.data.week_start), "MMM d")} – ${format(parseDay(progress.data.week_end), "MMM d")}`
    : "";

  return (
    <Section
      title="Weekly goals"
      action={
        <div className="flex items-center gap-1">
          <Button variant="ghost" size="icon-xs" aria-label="Previous week" onClick={() => shift(-7)}>
            <ChevronLeft />
          </Button>
          <button
            type="button"
            className="min-w-28 text-center text-xs text-muted-foreground tabular hover:text-foreground"
            title="This week"
            onClick={() => setWeek(null)}
          >
            {range}
          </button>
          <Button variant="ghost" size="icon-xs" aria-label="Next week" onClick={() => shift(7)}>
            <ChevronRight />
          </Button>
          <Button
            variant={editing ? "secondary" : "ghost"}
            size="xs"
            onClick={() => setEditing((v) => !v)}
            aria-pressed={editing}
          >
            <Pencil />
            {editing ? "Done" : "Edit"}
          </Button>
        </div>
      }
    >
      <Card className="space-y-3">
        {progress.isPending ? (
          <Skeleton className="h-16 w-full" />
        ) : progress.isError ? (
          <Muted className="text-status-error">Could not load goals: {progress.error.message}</Muted>
        ) : progress.data.goals.length === 0 && !editing ? (
          <Muted>
            No weekly goals yet.{" "}
            <button type="button" className="text-primary hover:underline" onClick={() => setEditing(true)}>
              Set one
            </button>{" "}
            for applications, outreach, leads, interviews or events.
          </Muted>
        ) : (
          <ul className="space-y-2">
            {progress.data.goals.map((goal) => {
              const met = goal.actual >= goal.target;
              const width = goal.target > 0 ? Math.min(1, goal.actual / goal.target) * 100 : met ? 100 : 0;
              return (
                <li key={goal.id} className="grid grid-cols-[7rem_1fr_4.5rem] items-center gap-2 text-[13px]">
                  <span className="truncate">{goal.label}</span>
                  <span className="h-2 overflow-hidden rounded-full bg-secondary" aria-hidden>
                    <span
                      className="block h-full rounded-full"
                      style={{ width: `${width}%`, background: kindTone(met ? "active" : "lead") }}
                    />
                  </span>
                  <span className="text-right tabular">
                    {goal.actual} <span className="text-muted-foreground">of {goal.target}</span>
                  </span>
                </li>
              );
            })}
          </ul>
        )}
        {editing && <GoalsEditor />}
      </Card>
    </Section>
  );
}

function GoalsEditor() {
  const goals = useGoals();
  const create = useJobsMutation(jobsApi.createGoal);
  const used = new Set((goals.data ?? []).map((g) => g.metric));
  const free = GOAL_METRICS.filter((m) => !used.has(m.value));
  const [metric, setMetric] = useState<GoalMetric | "">("");
  const [target, setTarget] = useState("5");
  const chosen = metric && !used.has(metric) ? metric : (free[0]?.value ?? "");

  async function add(event: FormEvent) {
    event.preventDefault();
    if (!chosen) return;
    try {
      await create.mutateAsync({ metric: chosen, target: Number(target) || 0 });
      setMetric("");
    } catch (error) {
      toast.error(`Could not add the goal: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <div className="space-y-2 border-t border-border pt-3">
      {(goals.data ?? []).map((goal) => (
        <GoalRow key={goal.id} goal={goal} />
      ))}
      {free.length > 0 && (
        <form onSubmit={add} className="flex flex-wrap items-center gap-2" aria-label="Add a weekly goal">
          <NativeSelect
            aria-label="Metric"
            value={chosen}
            onChange={(e) => setMetric(e.target.value as GoalMetric)}
          >
            {free.map((m) => (
              <option key={m.value} value={m.value}>
                {m.label}
              </option>
            ))}
          </NativeSelect>
          <Input
            type="number"
            min={0}
            max={1000}
            aria-label="Target per week"
            value={target}
            onChange={(e) => setTarget(e.target.value)}
            className="h-8 w-20 text-[13px]"
          />
          <span className="text-xs text-muted-foreground">per week</span>
          <Button type="submit" size="sm" variant="outline" disabled={create.isPending}>
            <Plus />
            Add goal
          </Button>
        </form>
      )}
      <ErrorLine message={create.error?.message} />
    </div>
  );
}

function GoalRow({ goal }: { goal: WeeklyGoal }) {
  const update = useJobsMutation((target: number) => jobsApi.updateGoal(goal.id, target));
  const remove = useJobsMutation(() => jobsApi.deleteGoal(goal.id));
  const [draft, setDraft] = useState(String(goal.target));
  const label = GOAL_METRICS.find((m) => m.value === goal.metric)?.label ?? goal.metric;

  function save() {
    const next = Number(draft);
    if (!Number.isFinite(next) || next === goal.target || draft === "") {
      setDraft(String(goal.target));
      return;
    }
    update.mutate(next, {
      onError: (error) => {
        toast.error(`Could not save: ${sentence(error.message)}`);
        setDraft(String(goal.target));
      },
    });
  }

  return (
    <div className="flex items-center gap-2 text-[13px]">
      <span className="w-28 truncate">{label}</span>
      <Input
        type="number"
        min={0}
        max={1000}
        aria-label={`${label} target`}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={save}
        onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
        className="h-7 w-20 text-[13px]"
      />
      <span className="text-xs text-muted-foreground">per week</span>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={`Remove the ${label.toLowerCase()} goal`}
        className="ml-auto text-muted-foreground hover:text-destructive"
        disabled={remove.isPending}
        onClick={() =>
          remove.mutate(undefined, {
            onError: (error) => toast.error(`Could not remove: ${sentence(error.message)}`),
          })
        }
      >
        <Trash2 />
      </Button>
    </div>
  );
}
