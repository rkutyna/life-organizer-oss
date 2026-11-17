import { Plus } from "lucide-react";
import { useMemo, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { toast } from "sonner";

import { EditableTable, type EditableColumn } from "@/components/EditableTable";
import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { sentence } from "@/lib/utils";

import {
  jobsApi,
  useContacts,
  useInvalidateJobs,
  useJobsMutation,
  useTags,
  type Contact,
  type ContactUpdate,
} from "./api";
import { CompanyPicker } from "./CompanyPicker";
import { daysFromToday, today } from "./format";
import { Muted, QUICK_ADD_ID, TagList, TextLink, dateColumn } from "./parts";

/** People you reach out to, with their next action and due date. ?tag=, ?due=week and ?q= filter. */
export default function ContactsPage() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const tag = params.get("tag") ?? "";
  const q = params.get("q") ?? "";
  const dueWeek = params.get("due") === "week";
  const contacts = useContacts({ tag, due_by: dueWeek ? daysFromToday(7) : undefined });
  const tags = useTags();
  const invalidate = useInvalidateJobs();

  function update(key: string, value: string) {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next, { replace: true });
  }

  const columns = useMemo<EditableColumn<Contact>[]>(
    () => [
      {
        key: "name",
        header: "Name",
        className: "min-w-40",
        render: (c) => <TextLink to={`/jobs/contacts/${c.id}`}>{c.name}</TextLink>,
      },
      { key: "company", header: "Company", className: "min-w-32" },
      { key: "role", header: "Role", type: "text", className: "min-w-32" },
      dateColumn<Contact>("contacted_on", "Contacted"),
      dateColumn<Contact>("replied_on", "Replied"),
      { key: "next_action", header: "Next action", type: "text", className: "min-w-40" },
      dateColumn<Contact>("next_action_due", "Due"),
      {
        key: "tags",
        header: "Tags",
        sortValue: (c) => c.tags.join(", "),
        render: (c) => <TagList tags={c.tags} />,
      },
    ],
    [],
  );

  async function save(row: Contact, key: keyof Contact, value: unknown) {
    await jobsApi.updateContact(row.id, { [key]: value } as ContactUpdate);
    invalidate();
  }

  return (
    <div className="space-y-3">
      <ContactForm />
      {contacts.isPending ? (
        <Skeleton className="h-48 w-full" />
      ) : contacts.isError ? (
        <Muted className="text-status-error">Could not load contacts: {contacts.error.message}</Muted>
      ) : (
        <EditableTable
          rows={contacts.data}
          columns={columns}
          getRowId={(c) => c.id}
          onSave={save}
          onOpen={(c) => navigate(`/jobs/contacts/${c.id}`)}
          initialSort={{ key: "name" }}
          searchPlaceholder="Filter contacts… ( / )"
          emptyMessage={tag || q || dueWeek ? "No contacts match." : "No contacts yet. Add one above."}
          filter={q}
          onFilterChange={(text) => update("q", text)}
          toolbar={
            <>
              <label className="flex items-center gap-1.5 text-[13px] text-muted-foreground">
                <input
                  type="checkbox"
                  checked={dueWeek}
                  onChange={(e) => update("due", e.target.checked ? "week" : "")}
                  className="size-3.5 accent-primary"
                />
                Due within a week
              </label>
              {(tags.data?.length ?? 0) > 0 && (
                <NativeSelect
                  aria-label="Filter by tag"
                  value={tag}
                  onChange={(e) => update("tag", e.target.value)}
                  className="max-w-40 bg-card"
                >
                  <option value="">All tags</option>
                  {tags.data!.map((t) => (
                    <option key={t} value={t}>
                      {t}
                    </option>
                  ))}
                </NativeSelect>
              )}
            </>
          }
        />
      )}
    </div>
  );
}

function ContactForm() {
  const navigate = useNavigate();
  const create = useJobsMutation(jobsApi.createContact);
  const [name, setName] = useState("");
  const [company, setCompany] = useState("");
  const [role, setRole] = useState("");
  const [contactedOn, setContactedOn] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!name.trim()) return;
    try {
      const contact = await create.mutateAsync({
        name: name.trim(),
        company: company.trim() || null,
        role: role.trim(),
        contacted_on: contactedOn || null,
      });
      toast.success(`Added ${contact.name}`, {
        action: { label: "Open", onClick: () => navigate(`/jobs/contacts/${contact.id}`) },
      });
      setName("");
      setCompany("");
      setRole("");
      setContactedOn("");
      document.getElementById(QUICK_ADD_ID)?.focus();
    } catch (error) {
      toast.error(`Could not add the contact: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <form
      onSubmit={submit}
      aria-label="Add a contact"
      className="grid gap-2 rounded-lg border border-dashed border-border p-2 sm:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)_minmax(0,1fr)_auto_auto]"
    >
      <Input
        id={QUICK_ADD_ID}
        aria-label="Name"
        placeholder="Name, e.g. Jane Doe"
        value={name}
        onChange={(e) => setName(e.target.value)}
        className="h-8 text-[13px]"
      />
      <CompanyPicker value={company} onValueChange={setCompany} placeholder="Company (optional)" />
      <Input
        aria-label="Role"
        placeholder="Role, e.g. Recruiter"
        value={role}
        onChange={(e) => setRole(e.target.value)}
        className="h-8 text-[13px]"
      />
      <div className="flex items-center gap-1">
        <Input
          type="date"
          aria-label="Contacted on"
          title="Contacted on"
          value={contactedOn}
          onChange={(e) => setContactedOn(e.target.value)}
          className="h-8 w-40 text-[13px]"
        />
        {!contactedOn && (
          <Button type="button" variant="ghost" size="xs" onClick={() => setContactedOn(today())}>
            Today
          </Button>
        )}
      </div>
      <Button type="submit" size="sm" disabled={create.isPending || !name.trim()}>
        <Plus />
        Add
      </Button>
    </form>
  );
}
