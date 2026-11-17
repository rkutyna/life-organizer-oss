import { Check } from "lucide-react";
import { useMemo } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn, sentence } from "@/lib/utils";

import {
  jobsApi,
  useApplications,
  useContacts,
  useInterviews,
  useInvalidateJobs,
  usePipeline,
  type StatusKind,
} from "./api";
import { daysFromToday, daysUntil, dueLabel, formatInterviewWhen, plural } from "./format";
import { GoalsPanel } from "./GoalsPanel";
import { Card, kindTone, Muted, Section } from "./parts";

/** The tracker at a glance: pipeline counts, weekly goals, what is coming up and what is due. */
export default function OverviewPage() {
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <PipelinePanel />
      <div className="space-y-6">
        <GoalsPanel />
        <UpcomingInterviews />
        <FollowUps />
      </div>
    </div>
  );
}

/** One labelled bar whose length is its count against the largest in its group. */
function CountBar({
  label,
  count,
  max,
  tone,
  to,
}: {
  label: string;
  count: number;
  max: number;
  tone: string;
  to?: string;
}) {
  const width = max > 0 ? Math.max(count > 0 ? 3 : 0, (count / max) * 100) : 0;
  const name = to ? (
    <Link to={to} className="truncate hover:underline">
      {label}
    </Link>
  ) : (
    <span className="truncate">{label}</span>
  );
  return (
    <li className="grid grid-cols-[7.5rem_1fr_2.5rem] items-center gap-2 text-[13px]">
      {name}
      <span className="h-2 overflow-hidden rounded-full bg-secondary" aria-hidden>
        <span className="block h-full rounded-full" style={{ width: `${width}%`, background: tone }} />
      </span>
      <span className="text-right tabular">{count}</span>
    </li>
  );
}

function PipelinePanel() {
  const pipeline = usePipeline();

  if (pipeline.isPending) {
    return (
      <Section title="Pipeline">
        <Skeleton className="h-64 w-full" />
      </Section>
    );
  }
  if (pipeline.isError) {
    return (
      <Section title="Pipeline">
        <Muted className="text-status-error">Could not load the pipeline: {pipeline.error.message}</Muted>
      </Section>
    );
  }

  const data = pipeline.data;
  const groups: { kind: StatusKind; title: string }[] = [
    { kind: "active", title: "Active" },
    { kind: "closed", title: "Closed" },
  ];
  const statusMax = Math.max(0, ...data.by_status.map((s) => s.count));
  const reachedMax = Math.max(0, ...data.reached.map((s) => s.count));

  return (
    <Section title="Pipeline">
      <Card className="space-y-5">
        <div className="flex flex-wrap gap-x-6 gap-y-2 text-[13px]">
          <Stat label="Applications" value={data.total} to="/jobs/applications" />
          <Stat label="Open leads" value={data.leads.open} to="/jobs/leads" />
          <Stat label="Dropped leads" value={data.leads.dropped} to="/jobs/leads?dropped=1" />
          <Stat label="Interviews" value={data.interviews.records} to="/jobs/interviews" />
          <Stat label="Applications interviewed" value={data.interviews.applications} />
        </div>

        {groups.map((group) => {
          const rows = data.by_status.filter((s) => s.kind === group.kind);
          if (!rows.length) return null;
          return (
            <div key={group.kind} className="space-y-1.5">
              <h3 className="text-xs font-medium text-muted-foreground">
                {group.title} · {rows.reduce((n, s) => n + s.count, 0)}
              </h3>
              <ul className="space-y-1">
                {rows.map((s) => (
                  <CountBar
                    key={s.status}
                    label={s.label}
                    count={s.count}
                    max={statusMax}
                    tone={kindTone(group.kind)}
                    to={`/jobs/applications?status=${encodeURIComponent(s.status)}`}
                  />
                ))}
              </ul>
            </div>
          );
        })}

        {data.reached.length > 0 && (
          <div className="space-y-1.5">
            <h3 className="text-xs font-medium text-muted-foreground">
              How far applications got (this stage or past it)
            </h3>
            <ul className="space-y-1">
              {data.reached.map((s) => (
                <CountBar
                  key={s.status}
                  label={s.label}
                  count={s.count}
                  max={reachedMax}
                  tone={kindTone("lead")}
                />
              ))}
            </ul>
          </div>
        )}
      </Card>
    </Section>
  );
}

function Stat({ label, value, to }: { label: string; value: number; to?: string }) {
  const body = (
    <>
      <span className="block text-lg font-semibold tabular leading-tight">{value}</span>
      <span className="block text-xs text-muted-foreground">{label}</span>
    </>
  );
  return to ? (
    <Link to={to} className="rounded-md hover:bg-accent/60">
      {body}
    </Link>
  ) : (
    <div>{body}</div>
  );
}

function UpcomingInterviews() {
  const interviews = useInterviews({ upcoming: true });
  const shown = (interviews.data ?? []).slice(0, 8);
  return (
    <Section
      title="Upcoming interviews"
      action={
        <Link to="/jobs/interviews" className="text-xs text-muted-foreground hover:text-foreground">
          All interviews
        </Link>
      }
    >
      {interviews.isPending ? (
        <Skeleton className="h-16 w-full" />
      ) : interviews.isError ? (
        <Muted className="text-status-error">Could not load interviews.</Muted>
      ) : shown.length === 0 ? (
        <Muted>No interviews coming up.</Muted>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border bg-card">
          {shown.map((interview) => (
            <li key={interview.id} className="px-3 py-2">
              <Link
                to={`/jobs/applications/${interview.application_id}`}
                className="block min-w-0 hover:underline"
              >
                <span className="text-[13px] font-medium">
                  {interview.stage || "Interview"} · {interview.company}
                </span>
                <span className="ml-1 text-[13px] text-muted-foreground">
                  {interview.application_title}
                </span>
              </Link>
              <p className="text-xs text-muted-foreground tabular">
                {formatInterviewWhen(interview)}
                {interview.location && ` · ${interview.location}`}
              </p>
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

interface DueRow {
  key: string;
  kind: "contact" | "application";
  id: number;
  action: string;
  due: string;
  who: string;
  to: string;
}

/** Next actions due within a week (and overdue ones), from contacts and applications. */
function FollowUps() {
  const horizon = daysFromToday(7);
  const contacts = useContacts({ due_by: horizon });
  const applications = useApplications({ leads: "include", due_by: horizon });
  const invalidate = useInvalidateJobs();

  const rows = useMemo<DueRow[]>(() => {
    const out: DueRow[] = [];
    for (const c of contacts.data ?? []) {
      if (!c.next_action_due) continue;
      out.push({
        key: `c${c.id}`,
        kind: "contact",
        id: c.id,
        action: c.next_action || "Follow up",
        due: c.next_action_due,
        who: c.company ? `${c.name} · ${c.company}` : c.name,
        to: `/jobs/contacts/${c.id}`,
      });
    }
    for (const a of applications.data ?? []) {
      if (!a.next_action_due) continue;
      out.push({
        key: `a${a.id}`,
        kind: "application",
        id: a.id,
        action: a.next_action || "Next step",
        due: a.next_action_due,
        who: `${a.title} · ${a.company}`,
        to: `/jobs/applications/${a.id}`,
      });
    }
    return out.sort((x, y) => x.due.localeCompare(y.due));
  }, [contacts.data, applications.data, horizon]);

  async function done(row: DueRow) {
    const clear = { next_action: "", next_action_due: null };
    try {
      if (row.kind === "contact") await jobsApi.updateContact(row.id, clear);
      else await jobsApi.updateApplication(row.id, clear);
      invalidate();
      toast.success("Marked done");
    } catch (error) {
      toast.error(`Could not save: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <Section title="Follow-ups due this week">
      {contacts.isPending || applications.isPending ? (
        <Skeleton className="h-16 w-full" />
      ) : contacts.isError || applications.isError ? (
        <Muted className="text-status-error">Could not load next actions.</Muted>
      ) : rows.length === 0 ? (
        <Muted>Nothing due in the next seven days.</Muted>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border bg-card">
          {rows.map((row) => (
            <li key={row.key} className="group flex items-center gap-3 px-3 py-2">
              <span
                className={cn(
                  "w-20 shrink-0 text-xs tabular",
                  daysUntil(row.due) < 0 ? "text-status-overdue" : "text-muted-foreground",
                  daysUntil(row.due) === 0 && "text-status-today",
                )}
              >
                {dueLabel(row.due)}
              </span>
              <Link to={row.to} className="min-w-0 flex-1 hover:underline">
                <span className="block truncate text-[13px]">{row.action}</span>
                <span className="block truncate text-xs text-muted-foreground">{row.who}</span>
              </Link>
              <Button
                variant="ghost"
                size="xs"
                className="opacity-70 group-hover:opacity-100"
                aria-label={`Mark "${row.action}" done`}
                onClick={() => void done(row)}
              >
                <Check />
                Done
              </Button>
            </li>
          ))}
        </ul>
      )}
      {rows.length > 0 && (
        <p className="text-xs text-muted-foreground">{plural(rows.length, "next action")}</p>
      )}
    </Section>
  );
}
