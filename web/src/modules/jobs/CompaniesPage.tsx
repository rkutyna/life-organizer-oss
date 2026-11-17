import { Plus } from "lucide-react";
import { useMemo, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { toast } from "sonner";

import { EditableTable, type EditableColumn } from "@/components/EditableTable";
import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";

import {
  jobsApi,
  useCompanies,
  useInvalidateJobs,
  useJobsMutation,
  useTags,
  type CompanyRow,
  type CompanyUpdate,
} from "./api";
import { ErrorLine, Muted, QUICK_ADD_ID, TagList, TextLink } from "./parts";

const YES_NO = [
  { value: "true", label: "Target" },
  { value: "false", label: "—" },
];

/** Companies with their application, lead and contact counts. ?tag= and ?q= filter. */
export default function CompaniesPage() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const tag = params.get("tag") ?? "";
  const q = params.get("q") ?? "";
  const companies = useCompanies({ tag });
  const tags = useTags();
  const invalidate = useInvalidateJobs();

  function update(key: string, value: string) {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next, { replace: true });
  }

  const columns = useMemo<EditableColumn<CompanyRow>[]>(
    () => [
      {
        key: "name",
        header: "Name",
        className: "min-w-44",
        render: (c) => <TextLink to={`/jobs/companies/${c.id}`}>{c.name}</TextLink>,
      },
      {
        key: "target",
        header: "Target",
        type: "select",
        options: YES_NO,
        filterAllLabel: "Targets or not",
        className: "w-28",
      },
      { key: "website", header: "Website", type: "text", className: "min-w-40" },
      { key: "applications", header: "Applications", className: "w-28 text-right" },
      { key: "leads", header: "Open leads", className: "w-24 text-right" },
      { key: "contacts", header: "Contacts", className: "w-24 text-right" },
      {
        key: "tags",
        header: "Tags",
        sortValue: (c) => c.tags.join(", "),
        render: (c) => <TagList tags={c.tags} />,
      },
    ],
    [],
  );

  async function save(row: CompanyRow, key: keyof CompanyRow, value: unknown) {
    let body: CompanyUpdate;
    if (key === "target") {
      if (value === null) return;
      body = { target: value === "true" };
    } else body = { [key]: value } as CompanyUpdate;
    await jobsApi.updateCompany(row.id, body);
    invalidate();
  }

  return (
    <div className="space-y-3">
      <CompanyForm />
      {companies.isPending ? (
        <Skeleton className="h-48 w-full" />
      ) : companies.isError ? (
        <Muted className="text-status-error">Could not load companies: {companies.error.message}</Muted>
      ) : (
        <EditableTable
          rows={companies.data}
          columns={columns}
          getRowId={(c) => c.id}
          onSave={save}
          onOpen={(c) => navigate(`/jobs/companies/${c.id}`)}
          searchPlaceholder="Filter companies… ( / )"
          emptyMessage={tag || q ? "No companies match." : "No companies yet. They are added with applications, or above."}
          filter={q}
          onFilterChange={(text) => update("q", text)}
          toolbar={
            (tags.data?.length ?? 0) > 0 && (
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
            )
          }
        />
      )}
    </div>
  );
}

/** Add a company. A name already taken (ignoring case and spacing) is refused with a message. */
function CompanyForm() {
  const navigate = useNavigate();
  const create = useJobsMutation(jobsApi.createCompany);
  const [name, setName] = useState("");
  const [website, setWebsite] = useState("");
  const [target, setTarget] = useState(false);

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!name.trim()) return;
    create.mutate(
      { name: name.trim(), website: website.trim(), target },
      {
        onSuccess: (company) => {
          toast.success(`Added ${company.name}`, {
            action: { label: "Open", onClick: () => navigate(`/jobs/companies/${company.id}`) },
          });
          setName("");
          setWebsite("");
          setTarget(false);
        },
      },
    );
  }

  return (
    <form onSubmit={submit} aria-label="Add a company" className="space-y-1 rounded-lg border border-dashed border-border p-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          id={QUICK_ADD_ID}
          aria-label="Company name"
          placeholder="Company name, e.g. Acme Corp"
          value={name}
          onChange={(e) => {
            setName(e.target.value);
            create.reset();
          }}
          className="h-8 min-w-48 flex-1 text-[13px]"
        />
        <Input
          aria-label="Website"
          placeholder="https://example.com"
          value={website}
          onChange={(e) => setWebsite(e.target.value)}
          className="h-8 w-56 text-[13px]"
        />
        <label className="flex items-center gap-1.5 text-[13px]">
          <input
            type="checkbox"
            checked={target}
            onChange={(e) => setTarget(e.target.checked)}
            className="size-3.5 accent-primary"
          />
          Target
        </label>
        <Button type="submit" size="sm" disabled={create.isPending || !name.trim()}>
          <Plus />
          Add company
        </Button>
      </div>
      <ErrorLine message={create.error?.message} />
    </form>
  );
}
