import { Plus } from "lucide-react";
import { useMemo, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { toast } from "sonner";

import { ApiError } from "@/api/client";
import { EditableTable, type EditableColumn } from "@/components/EditableTable";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { sentence } from "@/lib/utils";

import {
  jobsApi,
  useInvalidateJobs,
  useJobsMutation,
  useLeads,
  type Application,
  type ApplicationUpdate,
  type LeadCreate,
} from "./api";
import { CompanyPicker } from "./CompanyPicker";
import { formatDate, today } from "./format";
import { LeadActions } from "./LeadActions";
import { Muted, QUICK_ADD_ID, StatusChip, TextLink } from "./parts";

/**
 * Postings worth applying to, not submitted yet. Apply turns a lead into an application; Drop
 * cuts it with a reason. ?dropped=1 also shows the dropped ones.
 */
export default function LeadsPage() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const includeDropped = params.get("dropped") === "1";
  const leads = useLeads(includeDropped);
  const invalidate = useInvalidateJobs();

  const columns = useMemo<EditableColumn<Application>[]>(
    () => [
      {
        key: "title",
        header: "Title",
        className: "min-w-48",
        render: (a) => <TextLink to={`/jobs/applications/${a.id}`}>{a.title}</TextLink>,
      },
      { key: "company", header: "Company", className: "min-w-32" },
      {
        key: "found_on",
        header: "Found",
        className: "w-24",
        render: (a) => formatDate(a.found_on) || <span className="text-muted-foreground/60">—</span>,
      },
      { key: "location", header: "Location", type: "text", className: "min-w-28" },
      { key: "source", header: "Source", type: "text", className: "min-w-24" },
      { key: "next_action", header: "Next action", type: "text", className: "min-w-32" },
      {
        key: "id",
        header: includeDropped ? "Status" : "Actions",
        className: "w-44",
        sortValue: (a) => a.status,
        render: (a) => (a.status === "lead" ? <LeadActions lead={a} /> : <StatusChip status={a.status} />),
      },
    ],
    [includeDropped],
  );

  async function save(row: Application, key: keyof Application, value: unknown) {
    await jobsApi.updateApplication(row.id, { [key]: value } as ApplicationUpdate);
    invalidate();
  }

  return (
    <div className="space-y-3">
      <LeadForm />
      {leads.isPending ? (
        <Skeleton className="h-48 w-full" />
      ) : leads.isError ? (
        <Muted className="text-status-error">Could not load leads: {leads.error.message}</Muted>
      ) : (
        <EditableTable
          rows={leads.data}
          columns={columns}
          getRowId={(a) => a.id}
          onSave={save}
          onOpen={(a) => navigate(`/jobs/applications/${a.id}`)}
          searchPlaceholder="Filter leads… ( / )"
          emptyMessage="No open leads. Log a posting above when you find one."
          toolbar={
            <label className="flex items-center gap-1.5 text-[13px] text-muted-foreground">
              <input
                type="checkbox"
                checked={includeDropped}
                onChange={(e) => setParams(e.target.checked ? { dropped: "1" } : {}, { replace: true })}
                className="size-3.5 accent-primary"
              />
              Show dropped
            </label>
          }
        />
      )}
    </div>
  );
}

/**
 * Log a lead. A posting the company already has (same title, ignoring case and punctuation) is
 * refused with the server's message; "Add anyway" logs it as a repost.
 */
function LeadForm() {
  const create = useJobsMutation(jobsApi.createLead);
  const [company, setCompany] = useState("");
  const [title, setTitle] = useState("");
  const [url, setUrl] = useState("");
  const [location, setLocation] = useState("");
  const [source, setSource] = useState("");
  const [foundOn, setFoundOn] = useState(today());
  const [conflict, setConflict] = useState<string | null>(null);

  async function send(force: boolean) {
    if (!company.trim() || !title.trim()) {
      toast.error("Give a company and a title");
      return;
    }
    const body: LeadCreate = {
      company: company.trim(),
      title: title.trim(),
      posting_url: url.trim(),
      location: location.trim(),
      source: source.trim(),
      found_on: foundOn || null,
      force,
    };
    try {
      const lead = await create.mutateAsync(body);
      toast.success(
        lead.company_created ? `Lead logged, with the new company ${lead.company}` : "Lead logged",
      );
      setConflict(null);
      setTitle("");
      setUrl("");
      setLocation("");
      setCompany("");
      document.getElementById(QUICK_ADD_ID)?.focus();
    } catch (error) {
      if (error instanceof ApiError && error.status === 409) setConflict(error.message);
      else toast.error(`Could not log the lead: ${sentence((error as Error).message)}`);
    }
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    void send(false);
  }

  return (
    <form onSubmit={submit} aria-label="Log a lead" className="space-y-2 rounded-lg border border-dashed border-border p-2">
      <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)_minmax(0,1.2fr)]">
        <CompanyPicker
          id={QUICK_ADD_ID}
          value={company}
          onValueChange={(v) => {
            setCompany(v);
            setConflict(null);
          }}
          placeholder="Company (new or existing)"
        />
        <Input
          aria-label="Title"
          placeholder="Title"
          value={title}
          onChange={(e) => {
            setTitle(e.target.value);
            setConflict(null);
          }}
          className="h-8 text-[13px]"
        />
        <Input
          aria-label="Posting URL"
          placeholder="Posting URL"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          className="h-8 text-[13px]"
        />
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Input
          aria-label="Location"
          placeholder="Location"
          value={location}
          onChange={(e) => setLocation(e.target.value)}
          className="h-8 w-40 text-[13px]"
        />
        <Input
          aria-label="Source"
          placeholder="Source, e.g. job board"
          value={source}
          onChange={(e) => setSource(e.target.value)}
          className="h-8 w-44 text-[13px]"
        />
        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          Found
          <Input
            type="date"
            aria-label="Found on"
            value={foundOn}
            onChange={(e) => setFoundOn(e.target.value)}
            className="h-8 w-40 text-[13px]"
          />
        </label>
        <Button type="submit" size="sm" className="ml-auto" disabled={create.isPending}>
          <Plus />
          Log lead
        </Button>
      </div>
      {conflict && (
        <div role="alert" className="flex flex-wrap items-center gap-2 rounded-md bg-secondary px-2 py-1.5 text-[13px]">
          <span className="flex-1 text-status-stale">{sentence(conflict)}</span>
          <Button type="button" size="xs" variant="outline" onClick={() => void send(true)} disabled={create.isPending}>
            Add anyway
          </Button>
        </div>
      )}
    </form>
  );
}
