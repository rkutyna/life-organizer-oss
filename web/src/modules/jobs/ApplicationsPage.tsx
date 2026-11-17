import { ListFilter, X } from "lucide-react";
import { useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { toast } from "sonner";

import { EditableTable, type EditableColumn } from "@/components/EditableTable";
import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Skeleton } from "@/components/ui/skeleton";
import { cn, sentence } from "@/lib/utils";

import {
  jobsApi,
  useApplications,
  useCompanies,
  useInvalidateJobs,
  useStatusInfo,
  useTags,
  type Application,
  type ApplicationUpdate,
} from "./api";
import { ApplicationQuickAdd } from "./ApplicationQuickAdd";
import { kindTone, Muted, TagList, TextLink, dateColumn } from "./parts";

/**
 * Applications as an editable table. Filters live in the URL (?status=a&status=b&company=&tag=
 * &q=), so a filtered view can be bookmarked or linked from the overview. Leads are left out
 * unless a lead status is picked in the filter (they have their own page).
 */
export default function ApplicationsPage() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const status = params.getAll("status");
  const companyId = params.get("company") ? Number(params.get("company")) : undefined;
  const tag = params.get("tag") ?? "";
  const q = params.get("q") ?? "";

  const info = useStatusInfo();
  const companies = useCompanies();
  const tags = useTags();
  const applications = useApplications({ status, company_id: companyId, tag });
  const invalidate = useInvalidateJobs();

  function update(changes: Record<string, string | string[] | null>) {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(changes)) {
      next.delete(key);
      if (Array.isArray(value)) value.forEach((v) => next.append(key, v));
      else if (value) next.set(key, value);
    }
    setParams(next, { replace: true });
  }

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
        key: "status",
        header: "Status",
        className: "w-36",
        sortValue: (a) => info.list.findIndex((s) => s.key === a.status),
        render: (a) => <StatusSelect application={a} />,
      },
      dateColumn<Application>("date_applied", "Applied"),
      {
        key: "reached",
        header: "Reached",
        className: "w-28",
        sortValue: (a) => (a.reached ? info.list.findIndex((s) => s.key === a.reached) : -1),
        render: (a) => (a.reached ? info.label(a.reached) : <span className="text-muted-foreground/60">—</span>),
      },
      { key: "location", header: "Location", type: "text", className: "min-w-28" },
      { key: "source", header: "Source", type: "text", className: "min-w-24" },
      { key: "next_action", header: "Next action", type: "text", className: "min-w-36" },
      dateColumn<Application>("next_action_due", "Due"),
      {
        key: "tags",
        header: "Tags",
        sortValue: (a) => a.tags.join(", "),
        render: (a) => <TagList tags={a.tags} />,
      },
    ],
    [info],
  );

  async function save(row: Application, key: keyof Application, value: unknown) {
    await jobsApi.updateApplication(row.id, { [key]: value } as ApplicationUpdate);
    invalidate();
  }

  const hasFilters = status.length > 0 || companyId !== undefined || tag !== "" || q !== "";

  return (
    <div className="space-y-3">
      <ApplicationQuickAdd />

      {applications.isPending ? (
        <Skeleton className="h-64 w-full" />
      ) : applications.isError ? (
        <Muted className="text-status-error">Could not load applications: {applications.error.message}</Muted>
      ) : (
        <EditableTable
          rows={applications.data}
          columns={columns}
          getRowId={(a) => a.id}
          onSave={save}
          isCellReadOnly={(a, key) => key === "date_applied" && ["lead", "dropped"].includes(info.kind(a.status))}
          onOpen={(a) => navigate(`/jobs/applications/${a.id}`)}
          initialSort={{ key: "date_applied", desc: true }}
          searchPlaceholder="Filter title, company, notes… ( / )"
          emptyMessage={hasFilters ? "No applications match these filters." : "No applications yet. Add one above."}
          filter={q}
          onFilterChange={(text) => update({ q: text || null })}
          toolbar={
            <>
              <StatusFilter selected={status} onChange={(next) => update({ status: next })} />
              <NativeSelect
                aria-label="Filter by company"
                value={companyId !== undefined ? String(companyId) : ""}
                onChange={(e) => update({ company: e.target.value || null })}
                className="max-w-48 bg-card"
              >
                <option value="">All companies</option>
                {(companies.data ?? []).map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </NativeSelect>
              {(tags.data?.length ?? 0) > 0 && (
                <NativeSelect
                  aria-label="Filter by tag"
                  value={tag}
                  onChange={(e) => update({ tag: e.target.value || null })}
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
              {hasFilters && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => update({ status: [], company: null, tag: null, q: null })}
                >
                  <X />
                  Clear
                </Button>
              )}
            </>
          }
        />
      )}
    </div>
  );
}

/** Pick one or more statuses; none means every submitted application (no leads). */
function StatusFilter({ selected, onChange }: { selected: string[]; onChange: (next: string[]) => void }) {
  const info = useStatusInfo();
  const [open, setOpen] = useState(false);
  const label =
    selected.length === 0
      ? "All statuses"
      : selected.length === 1
        ? info.label(selected[0])
        : `${selected.length} statuses`;

  function toggle(key: string) {
    onChange(selected.includes(key) ? selected.filter((k) => k !== key) : [...selected, key]);
  }

  function kindOnly(kind: "active" | "closed") {
    onChange(info.list.filter((s) => s.kind === kind).map((s) => s.key));
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="outline" size="sm" className={cn("bg-card", selected.length && "border-ring")}>
          <ListFilter />
          {label}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-56 p-2">
        <div className="mb-1 flex flex-wrap gap-1">
          <Button variant="ghost" size="xs" onClick={() => kindOnly("active")}>
            Active
          </Button>
          <Button variant="ghost" size="xs" onClick={() => kindOnly("closed")}>
            Closed
          </Button>
          <Button variant="ghost" size="xs" onClick={() => onChange([])}>
            All
          </Button>
        </div>
        <ul className="space-y-0.5">
          {info.list.map((s) => (
            <li key={s.key}>
              <label className="flex cursor-pointer items-center gap-2 rounded px-1.5 py-1 text-[13px] hover:bg-accent">
                <input
                  type="checkbox"
                  checked={selected.includes(s.key)}
                  onChange={() => toggle(s.key)}
                  className="size-3.5 accent-primary"
                />
                <span className="size-2 rounded-full" style={{ background: kindTone(s.kind) }} aria-hidden />
                <span className="flex-1 truncate">{s.label}</span>
              </label>
            </li>
          ))}
        </ul>
      </PopoverContent>
    </Popover>
  );
}

/**
 * The status cell: a select that records a new dated status event (today) through
 * POST .../status, not a field edit. The history keeps every change.
 */
export function StatusSelect({ application, className }: { application: Application; className?: string }) {
  const info = useStatusInfo();
  const invalidate = useInvalidateJobs();
  const [saving, setSaving] = useState(false);
  const kind = info.kind(application.status);
  const options = info.options("active", "closed");

  async function change(status: string) {
    if (!status || status === application.status) return;
    setSaving(true);
    try {
      await jobsApi.addStatusEvent(application.id, { status });
      invalidate();
      toast.success(`${application.title}: ${info.label(status)}`);
    } catch (error) {
      toast.error(`Could not change the status: ${sentence((error as Error).message)}`);
    } finally {
      setSaving(false);
    }
  }

  return (
    <select
      aria-label={`Status of ${application.title}`}
      value={application.status}
      disabled={saving}
      onClick={(e) => e.stopPropagation()}
      onChange={(e) => void change(e.target.value)}
      className={cn(
        "h-7 w-full max-w-36 cursor-pointer truncate rounded-md border border-transparent bg-transparent px-1.5 text-[12px] font-medium outline-none hover:border-input focus-visible:border-ring",
        saving && "opacity-50",
        className,
      )}
      style={{ color: kindTone(kind) }}
    >
      {(kind === "lead" || kind === "dropped") && (
        <option value={application.status} disabled>
          {info.label(application.status)}
        </option>
      )}
      {options.map((o) => (
        <option key={o.value} value={o.value} className="text-foreground">
          {o.label}
        </option>
      ))}
    </select>
  );
}
