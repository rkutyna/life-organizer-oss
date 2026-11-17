import { Link, useNavigate, useParams } from "react-router";

import { RecordHistoryPanel } from "@/components/RecordHistoryPanel";
import { Skeleton } from "@/components/ui/skeleton";

import {
  jobsApi,
  TABLES,
  useApplications,
  useCompany,
  useContacts,
  useInvalidateJobs,
  useJobsMutation,
  useStatusInfo,
  type Application,
  type CompanyUpdate,
} from "./api";
import { dueLabel, formatDate } from "./format";
import { LeadActions } from "./LeadActions";
import { BackLink, Card, DeleteButton, Muted, Section, StatusChip } from "./parts";
import { RecordField, TagsField } from "./RecordField";

/** One company: its fields, its applications, leads and contacts, and its change history. */
export default function CompanyPage() {
  const params = useParams();
  const id = Number(params.companyId);
  const navigate = useNavigate();
  const info = useStatusInfo();
  const company = useCompany(id);
  const records = useApplications({ company_id: id, leads: "include" });
  const contacts = useContacts({ company_id: id });
  const invalidate = useInvalidateJobs();
  const update = useJobsMutation((changes: CompanyUpdate) => jobsApi.updateCompany(id, changes));
  const save = (changes: CompanyUpdate) => update.mutateAsync(changes);

  if (company.isPending) return <Skeleton className="h-96 w-full" />;
  if (company.isError) {
    return (
      <div className="space-y-2">
        <BackLink to="/jobs/companies">Companies</BackLink>
        <Muted className="text-status-error">Could not load this company: {company.error.message}</Muted>
      </div>
    );
  }

  const c = company.data;
  const all = records.data ?? [];
  const applications = all.filter((a) => !["lead", "dropped"].includes(info.kind(a.status)));
  const leads = all.filter((a) => info.kind(a.status) === "lead");
  const dropped = all.filter((a) => info.kind(a.status) === "dropped");

  return (
    <div className="space-y-5">
      <div className="space-y-1">
        <BackLink to="/jobs/companies">Companies</BackLink>
        <h2 className="text-lg font-semibold tracking-tight">{c.name}</h2>
      </div>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <div className="min-w-0 space-y-6">
          <Section title="Details">
            <Card className="space-y-2.5">
              <RecordField label="Name" kind="text" required value={c.name} onSave={(v) => save({ name: v as string })} />
              <RecordField
                label="Website"
                kind="url"
                value={c.website}
                placeholder="https://example.com"
                onSave={(v) => save({ website: v as string })}
              />
              <RecordField label="A target" kind="check" value={c.target} onSave={(v) => save({ target: v as boolean })} />
              <TagsField value={c.tags} onSave={(tags) => save({ tags })} />
              <RecordField label="Notes" kind="textarea" value={c.notes} onSave={(v) => save({ notes: v as string })} />
            </Card>
          </Section>

          <Section
            title={`Applications · ${applications.length}`}
            action={
              <Link to={`/jobs/applications?company=${id}`} className="text-xs text-muted-foreground hover:text-foreground">
                In the table
              </Link>
            }
          >
            <RecordList rows={applications} empty="No applications at this company." />
          </Section>

          <Section title={`Open leads · ${leads.length}`}>
            <RecordList rows={leads} empty="No open leads." lead />
          </Section>

          {dropped.length > 0 && (
            <Section title={`Dropped leads · ${dropped.length}`}>
              <RecordList rows={dropped} empty="" />
            </Section>
          )}

          <Section title={`Contacts · ${contacts.data?.length ?? 0}`}>
            {(contacts.data ?? []).length === 0 ? (
              <Muted>No contacts at this company.</Muted>
            ) : (
              <ul className="divide-y divide-border rounded-lg border border-border bg-card">
                {contacts.data!.map((contact) => (
                  <li key={contact.id} className="flex items-center gap-3 px-3 py-2 text-[13px]">
                    <Link to={`/jobs/contacts/${contact.id}`} className="min-w-0 flex-1 truncate font-medium hover:underline">
                      {contact.name}
                      {contact.role && <span className="font-normal text-muted-foreground"> · {contact.role}</span>}
                    </Link>
                    {contact.next_action_due && (
                      <span className="text-xs text-muted-foreground tabular">
                        {contact.next_action || "Next action"} · {dueLabel(contact.next_action_due)}
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Section>
        </div>

        <aside className="min-w-0 space-y-4">
          <Card>
            <RecordHistoryPanel table={TABLES.companies} recordId={c.id} onReverted={invalidate} />
          </Card>
          <DeleteButton
            what={c.name}
            description="Refused while it still has applications, leads or contacts."
            onDelete={() => jobsApi.deleteCompany(c.id)}
            onDeleted={() => navigate("/jobs/companies")}
          />
        </aside>
      </div>
    </div>
  );
}

function RecordList({ rows, empty, lead = false }: { rows: Application[]; empty: string; lead?: boolean }) {
  if (rows.length === 0) return <Muted>{empty}</Muted>;
  return (
    <ul className="divide-y divide-border rounded-lg border border-border bg-card">
      {rows.map((a) => (
        <li key={a.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-[13px]">
          <Link to={`/jobs/applications/${a.id}`} className="min-w-0 flex-1 truncate font-medium hover:underline">
            {a.title}
          </Link>
          {a.date_applied && <span className="text-xs text-muted-foreground tabular">{formatDate(a.date_applied)}</span>}
          {lead ? <LeadActions lead={a} /> : <StatusChip status={a.status} />}
        </li>
      ))}
    </ul>
  );
}
