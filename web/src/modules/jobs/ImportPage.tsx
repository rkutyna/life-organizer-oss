import { FileUp, RotateCcw, Upload } from "lucide-react";
import { useRef, useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { cn, sentence } from "@/lib/utils";

import {
  jobsApi,
  useInvalidateJobs,
  useStatusInfo,
  type ImportKind,
  type ImportPreview,
  type ImportReport,
  type ImportSpec,
  type ImportUndo,
} from "./api";
import { plural } from "./format";
import { Card, ErrorLine, Muted, Section } from "./parts";

type Mapping = Record<string, string | null>;

const PROBLEM_TEXT: Record<string, string> = {
  missing_company: "No company",
  missing_title: "No title",
  missing_name: "No name",
  unknown_status: "Status not mapped",
  bad_date: "Date not understood",
  duplicate_row: "Same record as an earlier row",
};

const MAX_FILE_BYTES = 5_000_000;

/**
 * CSV import in three steps, nothing written until the last:
 * 1. choose the file and map its columns (and its status values) to the tracker's fields,
 * 2. dry run: what an import would create, update or skip, and which rows have problems,
 * 3. import, with "Undo this import" afterwards.
 * The file is read in the browser and sent as text with each step; the server keeps nothing
 * between steps. Only the preview carries cell text; the reports carry row numbers and ids.
 */
export default function ImportPage() {
  const info = useStatusInfo();
  const invalidate = useInvalidateJobs();
  const fileInput = useRef<HTMLInputElement>(null);

  const [kind, setKind] = useState<ImportKind>("applications");
  const [fileName, setFileName] = useState("");
  const [csv, setCsv] = useState("");
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [mapping, setMapping] = useState<Mapping>({});
  const [statusMap, setStatusMap] = useState<Record<string, string>>({});
  const [dayFirst, setDayFirst] = useState(false);
  const [keepUnmapped, setKeepUnmapped] = useState(true);
  const [dryRun, setDryRun] = useState<ImportReport | null>(null);
  const [committed, setCommitted] = useState<ImportReport | null>(null);
  const [undone, setUndone] = useState<ImportUndo | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function resetAfterFile() {
    setDryRun(null);
    setCommitted(null);
    setUndone(null);
    setError(null);
  }

  async function loadPreview(text: string, forKind: ImportKind, withMapping?: Mapping) {
    setBusy("preview");
    setError(null);
    try {
      const result = await jobsApi.importPreview({ csv: text, kind: forKind, mapping: withMapping ?? null });
      setPreview(result);
      setMapping(result.mapping);
      setStatusMap((current) => {
        const next: Record<string, string> = {};
        for (const v of result.status_values) next[v.value] = current[v.value] ?? v.suggested ?? "";
        return next;
      });
      if (!withMapping) setDayFirst(result.day_first_suggested);
    } catch (caught) {
      setError((caught as Error).message);
      if (!withMapping) setPreview(null);
    } finally {
      setBusy(null);
    }
  }

  function chooseFile(file: File | undefined) {
    if (!file) return;
    if (file.size > MAX_FILE_BYTES) {
      setError("The file is over 5 MB; split it and import the parts");
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const text = String(reader.result ?? "");
      setFileName(file.name);
      setCsv(text);
      setStatusMap({});
      resetAfterFile();
      void loadPreview(text, kind);
    };
    reader.onerror = () => setError("Could not read the file");
    reader.readAsText(file);
  }

  function changeKind(next: ImportKind) {
    setKind(next);
    resetAfterFile();
    setStatusMap({});
    if (csv) void loadPreview(csv, next);
  }

  function changeMapping(header: string, target: string | null) {
    // status_values cover the columns mapped to status and to reached (furthest stage).
    // Each field takes one column: picking a field moves it off any other column.
    const next: Mapping = { ...mapping };
    if (target) for (const h of Object.keys(next)) if (next[h] === target) next[h] = null;
    next[header] = target;
    const statusKeys = ["status", "reached"];
    const statusTouched =
      statusKeys.includes(mapping[header] ?? "") || statusKeys.includes(target ?? "");
    setMapping(next);
    setDryRun(null);
    if (statusTouched) void loadPreview(csv, kind, next);
  }

  function spec(): ImportSpec {
    const status_map: Record<string, string> = {};
    for (const [value, key] of Object.entries(statusMap)) if (key) status_map[value] = key;
    return { csv, kind, mapping, status_map, day_first: dayFirst, keep_unmapped: keepUnmapped };
  }

  async function runDry() {
    setBusy("dry");
    setError(null);
    try {
      setDryRun(await jobsApi.importDryRun(spec()));
    } catch (caught) {
      setError((caught as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function commit() {
    setBusy("commit");
    setError(null);
    try {
      const report = await jobsApi.importCommit(spec());
      setCommitted(report);
      invalidate();
      toast.success("Import finished");
    } catch (caught) {
      setError((caught as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function undo() {
    if (!committed?.batch_id) return;
    setBusy("undo");
    try {
      const result = await jobsApi.importUndo(committed.batch_id);
      setUndone(result);
      invalidate();
      toast.success(`Undid ${plural(result.reverted, "change")}`);
    } catch (caught) {
      toast.error(`Could not undo: ${sentence((caught as Error).message)}`);
    } finally {
      setBusy(null);
    }
  }

  function startOver() {
    setFileName("");
    setCsv("");
    setPreview(null);
    setMapping({});
    setStatusMap({});
    resetAfterFile();
    if (fileInput.current) fileInput.current.value = "";
  }

  const missing = preview
    ? preview.targets.filter((t) => t.required && !Object.values(mapping).includes(t.key))
    : [];
  const unmappedStatuses = preview?.status_values.filter((v) => !statusMap[v.value]) ?? [];
  const statusOptions = info.list.map((s) => ({ value: s.key, label: s.label }));

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <Section title="1. Choose a CSV file">
        <Card className="space-y-3">
          <div className="flex flex-wrap items-center gap-3">
            <NativeSelect
              aria-label="What the file holds"
              value={kind}
              disabled={committed !== null}
              onChange={(e) => changeKind(e.target.value as ImportKind)}
            >
              <option value="applications">Applications</option>
              <option value="contacts">Contacts</option>
            </NativeSelect>
            <input
              ref={fileInput}
              type="file"
              accept=".csv,text/csv"
              className="hidden"
              onChange={(e) => chooseFile(e.target.files?.[0])}
            />
            <Button
              variant="outline"
              size="sm"
              disabled={committed !== null}
              onClick={() => fileInput.current?.click()}
            >
              <FileUp />
              {fileName ? "Choose another file" : "Choose file"}
            </Button>
            {fileName && (
              <span className="text-[13px] text-muted-foreground">
                {fileName}
                {preview && ` · ${plural(preview.row_count, "row")}`}
              </span>
            )}
            {fileName && (
              <Button variant="ghost" size="sm" className="ml-auto" onClick={startOver}>
                <RotateCcw />
                Start over
              </Button>
            )}
          </div>
          <p className="text-xs text-muted-foreground">
            A spreadsheet exported as CSV, with a header row. Rows that match records already here (same company,
            title and date applied; or same name and company) update them; importing the same file twice changes
            nothing the second time.
          </p>
          {busy === "preview" && <Muted>Reading the file…</Muted>}
          {!preview && <ErrorLine message={error} />}
        </Card>
      </Section>

      {preview && !committed && (
        <Section title="2. Map the columns">
          <Card className="space-y-4">
            <div className="overflow-x-auto rounded-md border border-border scrollbar-thin">
              <table className="w-full border-collapse text-[12px]">
                <thead>
                  <tr className="border-b border-border bg-secondary/50">
                    {preview.headers.map((header) => (
                      <th key={header} className="min-w-36 px-2 py-1.5 text-left align-top font-medium">
                        <div className="mb-1 truncate" title={header}>
                          {header}
                        </div>
                        <NativeSelect
                          aria-label={`Field for ${header}`}
                          value={mapping[header] ?? ""}
                          onChange={(e) => changeMapping(header, e.target.value || null)}
                          className={cn("h-7 w-full text-[12px]", !mapping[header] && "text-muted-foreground")}
                        >
                          <option value="">Skip</option>
                          {preview.targets.map((t) => (
                            <option key={t.key} value={t.key}>
                              {t.label}
                              {t.required ? " *" : ""}
                            </option>
                          ))}
                        </NativeSelect>
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {preview.rows.slice(0, 8).map((row, index) => (
                    <tr key={index} className="border-b border-border last:border-b-0">
                      {preview.headers.map((header, column) => (
                        <td
                          key={header}
                          className={cn(
                            "max-w-48 truncate px-2 py-1",
                            !mapping[header] && "text-muted-foreground/60",
                          )}
                        >
                          {row[column]}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {preview.row_count > 8 && (
              <p className="text-xs text-muted-foreground">
                The first 8 of {plural(preview.row_count, "row")}.
              </p>
            )}
            {missing.length > 0 && (
              <p className="text-[13px] text-status-stale">
                Map a column to: {missing.map((t) => t.label).join(", ")}.
              </p>
            )}

            {preview.status_values.length > 0 && (
              <div className="space-y-2">
                <h3 className="text-xs font-medium text-muted-foreground">
                  Status values in {statusColumns(preview, mapping)}
                </h3>
                <p className="text-xs text-muted-foreground">
                  One choice per value covers both the status and the furthest-stage column.
                </p>
                <ul className="grid gap-1.5 sm:grid-cols-2">
                  {preview.status_values.map((v) => (
                    <li key={v.value} className="flex items-center gap-2 text-[13px]">
                      <span className="min-w-0 flex-1 truncate" title={v.value}>
                        {v.value} <span className="text-xs text-muted-foreground">× {v.count}</span>
                      </span>
                      <NativeSelect
                        aria-label={`Status for ${v.value}`}
                        value={statusMap[v.value] ?? ""}
                        onChange={(e) => {
                          setStatusMap({ ...statusMap, [v.value]: e.target.value });
                          setDryRun(null);
                        }}
                        className={cn("h-7 w-40", !statusMap[v.value] && "border-status-stale")}
                      >
                        <option value="">Choose… (else skipped)</option>
                        {statusOptions.map((o) => (
                          <option key={o.value} value={o.value}>
                            {o.label}
                          </option>
                        ))}
                      </NativeSelect>
                    </li>
                  ))}
                </ul>
                {unmappedStatuses.length > 0 && (
                  <p className="text-xs text-status-stale">
                    Not chosen: {unmappedStatuses.map((v) => `“${v.value}”`).join(", ")}. A row whose status is
                    one of these is skipped; as a furthest stage, only that field is left out.
                  </p>
                )}
              </div>
            )}

            <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-[13px]">
              <label className="flex items-center gap-1.5">
                <input
                  type="checkbox"
                  checked={dayFirst}
                  onChange={(e) => {
                    setDayFirst(e.target.checked);
                    setDryRun(null);
                  }}
                  className="size-3.5 accent-primary"
                />
                Dates are day/month/year
                {preview.day_first_suggested && (
                  <span className="text-xs text-muted-foreground">(some dates only read this way)</span>
                )}
              </label>
              {kind === "applications" && (
                <label className="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    checked={keepUnmapped}
                    onChange={(e) => {
                      setKeepUnmapped(e.target.checked);
                      setDryRun(null);
                    }}
                    className="size-3.5 accent-primary"
                  />
                  Keep skipped columns (shown on the record as imported columns)
                </label>
              )}
              <Button
                size="sm"
                className="ml-auto"
                disabled={missing.length > 0 || busy !== null}
                onClick={() => void runDry()}
              >
                {busy === "dry" ? "Checking…" : "Dry run"}
              </Button>
            </div>
            <ErrorLine message={error} />
          </Card>
        </Section>
      )}

      {dryRun && !committed && (
        <Section title="3. Check and import">
          <Card className="space-y-4">
            <ReportCounts report={dryRun} />
            <ReportDetails report={dryRun} preview={preview} kind={kind} />
            <div className="flex flex-wrap items-center gap-3 border-t border-border pt-3">
              <span className="text-xs text-muted-foreground">
                Nothing has been written yet. Each change is logged and the whole import can be undone.
              </span>
              <Button
                size="sm"
                className="ml-auto"
                disabled={busy !== null || dryRun.create + dryRun.update + dryRun.promote === 0}
                onClick={() => void commit()}
              >
                <Upload />
                {busy === "commit" ? "Importing…" : `Import ${plural(dryRun.create + dryRun.update + dryRun.promote, "row")}`}
              </Button>
            </div>
          </Card>
        </Section>
      )}

      {committed && (
        <Section title="Imported">
          <Card className="space-y-4">
            <ReportCounts report={committed} />
            <ReportDetails report={committed} preview={preview} kind={kind} />
            <div className="flex flex-wrap items-center gap-3 border-t border-border pt-3">
              {undone ? (
                <span className="text-[13px]">
                  Undone: {plural(undone.reverted, "change")} reverted
                  {undone.conflicts > 0 && `, ${plural(undone.conflicts, "change")} left alone because they were edited since`}
                  .
                </span>
              ) : committed.batch_id ? (
                <Button variant="outline" size="sm" disabled={busy !== null} onClick={() => void undo()}>
                  <RotateCcw />
                  {busy === "undo" ? "Undoing…" : "Undo this import"}
                </Button>
              ) : (
                <span className="text-[13px] text-muted-foreground">Nothing was written.</span>
              )}
              <Link
                to={kind === "contacts" ? "/jobs/contacts" : "/jobs/applications"}
                className="text-[13px] text-primary hover:underline"
              >
                Go to {kind}
              </Link>
              <Button variant="ghost" size="sm" className="ml-auto" onClick={startOver}>
                Import another file
              </Button>
            </div>
          </Card>
        </Section>
      )}
    </div>
  );
}

/** "“Stage” and “Got to”": the columns mapped to status and reached, quoted. */
function statusColumns(preview: ImportPreview, mapping: Mapping): string {
  const columns = preview.headers.filter((h) => mapping[h] === "status" || mapping[h] === "reached");
  const quoted = columns.map((h) => `“${h}” (${mapping[h] === "status" ? "status" : "furthest stage"})`);
  return quoted.join(" and ") || "the status columns";
}

function ReportCounts({ report }: { report: ImportReport }) {
  const items: [string, number][] = [
    [report.committed ? "Created" : "Would create", report.create],
    [report.committed ? "Updated" : "Would update", report.update],
    ["Unchanged", report.unchanged],
    [report.committed ? "Leads submitted" : "Would submit a lead", report.promote],
    ["Skipped", report.skipped],
    [report.committed ? "New companies" : "New companies", report.companies_created],
  ];
  return (
    <div className="flex flex-wrap gap-x-6 gap-y-2">
      <div>
        <span className="block text-lg font-semibold tabular leading-tight">{report.rows}</span>
        <span className="block text-xs text-muted-foreground">Rows</span>
      </div>
      {items.map(([label, value]) => (
        <div key={label}>
          <span className={cn("block text-lg font-semibold tabular leading-tight", value === 0 && "text-muted-foreground")}>
            {value}
          </span>
          <span className="block text-xs text-muted-foreground">{label}</span>
        </div>
      ))}
    </div>
  );
}

function ReportDetails({
  report,
  preview,
  kind,
}: {
  report: ImportReport;
  preview: ImportPreview | null;
  kind: ImportKind;
}) {
  // Row numbers count the header as row 1; the preview holds the first rows' cells.
  const cells = (row: number) => preview?.rows[row - 2]?.filter(Boolean).slice(0, 4).join(" · ");
  const recordPath = (id: number) => (kind === "contacts" ? `/jobs/contacts/${id}` : `/jobs/applications/${id}`);
  const actionText = { update: "updates", unchanged: "matches, no change", promote: "submits lead" } as const;

  return (
    <div className="grid gap-4 md:grid-cols-2">
      <div className="space-y-1.5">
        <h3 className="text-xs font-medium text-muted-foreground">
          Problems · {report.problems.length}
          {report.problems.length >= 500 && " (first 500)"}
        </h3>
        {report.problems.length === 0 ? (
          <Muted>None.</Muted>
        ) : (
          <ul className="max-h-72 space-y-0.5 overflow-y-auto text-[13px] scrollbar-thin">
            {report.problems.map((p, index) => (
              <li key={index} className="flex gap-2">
                <span className="w-14 shrink-0 text-muted-foreground tabular">Row {p.row}</span>
                <span className="min-w-0 flex-1">
                  <span className={p.skipped ? "text-status-error" : "text-status-stale"}>
                    {PROBLEM_TEXT[p.code] ?? p.code}
                  </span>
                  {p.field && <span className="text-muted-foreground"> ({p.field})</span>}
                  {p.skipped ? " · row skipped" : " · field left out"}
                  {cells(p.row) && <span className="block truncate text-xs text-muted-foreground">{cells(p.row)}</span>}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="space-y-1.5">
        <h3 className="text-xs font-medium text-muted-foreground">
          Matches existing records · {report.matches.length}
          {report.matches.length >= 500 && " (first 500)"}
        </h3>
        {report.matches.length === 0 ? (
          <Muted>None: every row is new.</Muted>
        ) : (
          <ul className="max-h-72 space-y-0.5 overflow-y-auto text-[13px] scrollbar-thin">
            {report.matches.map((m) => (
              <li key={`${m.row}-${m.record_id}`} className="flex gap-2">
                <span className="w-14 shrink-0 text-muted-foreground tabular">Row {m.row}</span>
                <span className="min-w-0 flex-1 truncate">
                  {actionText[m.action]}{" "}
                  <Link to={recordPath(m.record_id)} className="text-primary hover:underline">
                    record {m.record_id}
                  </Link>
                  {cells(m.row) && <span className="block truncate text-xs text-muted-foreground">{cells(m.row)}</span>}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
