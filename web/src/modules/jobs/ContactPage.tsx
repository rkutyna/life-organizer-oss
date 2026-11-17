import { Link, useNavigate, useParams } from "react-router";

import { RecordHistoryPanel } from "@/components/RecordHistoryPanel";
import { Skeleton } from "@/components/ui/skeleton";

import {
  jobsApi,
  TABLES,
  useCompanies,
  useContact,
  useInvalidateJobs,
  useJobsMutation,
  type ContactUpdate,
} from "./api";
import { BackLink, Card, DeleteButton, Muted, Section } from "./parts";
import { RecordField, TagsField } from "./RecordField";

/** One contact: editable fields and change history. */
export default function ContactPage() {
  const params = useParams();
  const id = Number(params.contactId);
  const navigate = useNavigate();
  const contact = useContact(Number.isFinite(id) ? id : null);
  const companies = useCompanies();
  const invalidate = useInvalidateJobs();
  const update = useJobsMutation((changes: ContactUpdate) => jobsApi.updateContact(id, changes));
  const save = (changes: ContactUpdate) => update.mutateAsync(changes);

  if (contact.isPending) return <Skeleton className="h-96 w-full" />;
  if (contact.isError) {
    return (
      <div className="space-y-2">
        <BackLink to="/jobs/contacts">Contacts</BackLink>
        <Muted className="text-status-error">Could not load this contact: {contact.error.message}</Muted>
      </div>
    );
  }

  const c = contact.data;
  return (
    <div className="space-y-5">
      <div className="space-y-1">
        <BackLink to="/jobs/contacts">Contacts</BackLink>
        <h2 className="text-lg font-semibold tracking-tight">{c.name}</h2>
        <p className="text-[13px] text-muted-foreground">
          {c.role}
          {c.role && c.company && " · "}
          {c.company_id && c.company && (
            <Link to={`/jobs/companies/${c.company_id}`} className="hover:text-foreground hover:underline">
              {c.company}
            </Link>
          )}
        </p>
      </div>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <Section title="Details" className="min-w-0">
          <Card className="space-y-2.5">
            <RecordField label="Name" kind="text" required value={c.name} onSave={(v) => save({ name: v as string })} />
            <RecordField
              label="Company"
              kind="select"
              value={c.company_id !== null ? String(c.company_id) : ""}
              options={(companies.data ?? []).map((co) => ({ value: String(co.id), label: co.name }))}
              onSave={(v) => save({ company_id: v === null ? null : Number(v) })}
            />
            <RecordField label="Role" kind="text" value={c.role} onSave={(v) => save({ role: v as string })} />
            <RecordField
              label="Email"
              kind="text"
              value={c.email}
              placeholder="jane@example.com"
              onSave={(v) => save({ email: v as string })}
            />
            <RecordField
              label="Profile"
              kind="url"
              value={c.profile_url}
              placeholder="https://…"
              onSave={(v) => save({ profile_url: v as string })}
            />
            <RecordField
              label="Contacted"
              kind="date"
              value={c.contacted_on}
              onSave={(v) => save({ contacted_on: v as string | null })}
            />
            <RecordField
              label="Replied"
              kind="date"
              value={c.replied_on}
              onSave={(v) => save({ replied_on: v as string | null })}
            />
            <RecordField
              label="Next action"
              kind="text"
              value={c.next_action}
              onSave={(v) => save({ next_action: v as string })}
            />
            <RecordField
              label="Due"
              kind="date"
              value={c.next_action_due}
              onSave={(v) => save({ next_action_due: v as string | null })}
            />
            <TagsField value={c.tags} onSave={(tags) => save({ tags })} />
            <RecordField label="Notes" kind="textarea" value={c.notes} onSave={(v) => save({ notes: v as string })} />
          </Card>
        </Section>

        <aside className="min-w-0 space-y-4">
          <Card>
            <RecordHistoryPanel table={TABLES.contacts} recordId={c.id} onReverted={invalidate} />
          </Card>
          <DeleteButton
            what={c.name}
            onDelete={() => jobsApi.deleteContact(c.id)}
            onDeleted={() => navigate("/jobs/contacts")}
          />
        </aside>
      </div>
    </div>
  );
}
