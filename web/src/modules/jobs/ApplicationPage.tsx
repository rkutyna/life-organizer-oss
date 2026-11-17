import { Link, useNavigate, useParams } from "react-router";

import { RecordHistoryPanel } from "@/components/RecordHistoryPanel";
import { Skeleton } from "@/components/ui/skeleton";

import {
  jobsApi,
  TABLES,
  useApplication,
  useCompanies,
  useInvalidateJobs,
  useJobsMutation,
  useStatusInfo,
  type ApplicationUpdate,
} from "./api";
import { formatDate } from "./format";
import { ApplicationInterviews } from "./InterviewParts";
import { LeadActions } from "./LeadActions";
import { BackLink, Card, DeleteButton, Facts, Muted, Section, StatusChip } from "./parts";
import { RecordField, TagsField } from "./RecordField";
import { StatusTimeline } from "./StatusTimeline";

/** One application (or lead): its fields, status history, interviews and change history. */
export default function ApplicationPage() {
  const params = useParams();
  const id = Number(params.applicationId);
  const navigate = useNavigate();
  const info = useStatusInfo();
  const application = useApplication(Number.isFinite(id) ? id : null);
  const companies = useCompanies();
  const invalidate = useInvalidateJobs();
  const update = useJobsMutation((changes: ApplicationUpdate) => jobsApi.updateApplication(id, changes));
  const save = (changes: ApplicationUpdate) => update.mutateAsync(changes);

  if (application.isPending) return <Skeleton className="h-96 w-full" />;
  if (application.isError) {
    return (
      <div className="space-y-2">
        <BackLink to="/jobs/applications">Applications</BackLink>
        <Muted className="text-status-error">Could not load this application: {application.error.message}</Muted>
      </div>
    );
  }

  const app = application.data;
  const kind = info.kind(app.status);
  const isLead = kind === "lead" || kind === "dropped";
  const extra = Object.entries(app.extra ?? {});

  return (
    <div className="space-y-5">
      <div className="space-y-1">
        <BackLink to={isLead ? "/jobs/leads" : "/jobs/applications"}>{isLead ? "Leads" : "Applications"}</BackLink>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
          <h2 className="text-lg font-semibold tracking-tight">{app.title}</h2>
          <StatusChip status={app.status} />
          {app.reached && app.reached !== app.status && (
            <span className="text-xs text-muted-foreground">reached {info.label(app.reached)}</span>
          )}
        </div>
        <p className="text-[13px] text-muted-foreground">
          <Link to={`/jobs/companies/${app.company_id}`} className="hover:text-foreground hover:underline">
            {app.company}
          </Link>
          {app.date_applied && <> · applied {formatDate(app.date_applied)}</>}
          {app.location && <> · {app.location}</>}
        </p>
      </div>

      {kind === "lead" && (
        <Card className="flex flex-wrap items-center justify-between gap-2 border-dashed">
          <span className="text-[13px] text-muted-foreground">An open lead: not applied to yet.</span>
          <LeadActions lead={app} size="sm" />
        </Card>
      )}

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <div className="min-w-0 space-y-6">
          <Section title="Details">
            <Card className="space-y-2.5">
              <RecordField label="Title" kind="text" required value={app.title} onSave={(v) => save({ title: v as string })} />
              <RecordField
                label="Company"
                kind="select"
                required
                value={String(app.company_id)}
                options={(companies.data ?? []).map((c) => ({ value: String(c.id), label: c.name }))}
                onSave={(v) => save({ company_id: Number(v) })}
              />
              <RecordField
                label="Date applied"
                kind="date"
                value={app.date_applied}
                disabled={isLead}
                hint={isLead ? "A lead has no date applied; Apply submits it" : undefined}
                onSave={(v) => save({ date_applied: v as string | null })}
              />
              <RecordField label="Location" kind="text" value={app.location} onSave={(v) => save({ location: v as string })} />
              <RecordField
                label="Posting"
                kind="url"
                value={app.posting_url}
                placeholder="https://jobs.example.com/…"
                onSave={(v) => save({ posting_url: v as string })}
              />
              <RecordField
                label="Source"
                kind="text"
                value={app.source}
                placeholder="Where you found it"
                onSave={(v) => save({ source: v as string })}
              />
              <RecordField
                label="Next action"
                kind="text"
                value={app.next_action}
                onSave={(v) => save({ next_action: v as string })}
              />
              <RecordField
                label="Due"
                kind="date"
                value={app.next_action_due}
                onSave={(v) => save({ next_action_due: v as string | null })}
              />
              <TagsField value={app.tags} onSave={(tags) => save({ tags })} />
              <RecordField label="Notes" kind="textarea" value={app.notes} onSave={(v) => save({ notes: v as string })} />
            </Card>
          </Section>

          {extra.length > 0 && (
            <Section title="Imported columns">
              <Card>
                <Facts items={extra.map(([key, value]) => [key, value])} />
              </Card>
            </Section>
          )}

          <StatusTimeline application={app} />
          <ApplicationInterviews applicationId={app.id} />
        </div>

        <aside className="min-w-0 space-y-4">
          <Card>
            <RecordHistoryPanel
              table={TABLES.applications}
              recordId={app.id}
              onReverted={invalidate}
              formatters={{ status: (v) => info.label(String(v)), reached: (v) => info.label(String(v)) }}
            />
          </Card>
          <DeleteButton
            what={`this ${isLead ? "lead" : "application"}`}
            description="Its status history and interviews go with it."
            onDelete={() => jobsApi.deleteApplication(app.id)}
            onDeleted={() => navigate(isLead ? "/jobs/leads" : "/jobs/applications")}
          />
        </aside>
      </div>
    </div>
  );
}
