import { ArrowDown, ArrowUp, Lock, Plus, Trash2 } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { sentence } from "@/lib/utils";

import { jobsApi, useInvalidateJobs, useJobsMutation, useStatuses, type JobStatus } from "./api";
import { Card, ErrorLine, kindTone, Muted, QUICK_ADD_ID, Section } from "./parts";

const KIND_TEXT: Record<JobStatus["kind"], string> = {
  lead: "Lead: not applied yet",
  dropped: "Dropped lead",
  active: "Active: a pipeline stage",
  closed: "Closed: ended",
};

/**
 * The status list. Active statuses, in list order, are the pipeline's stages (`reached`
 * counts how far an application got through them); closed ones end an application. lead,
 * applied and dropped are reserved: they can be renamed and moved, never removed.
 */
export default function StatusSettingsPage() {
  const statuses = useStatuses();
  const invalidate = useInvalidateJobs();
  const [busy, setBusy] = useState(false);

  async function run(write: () => Promise<unknown>, failure: string) {
    setBusy(true);
    try {
      await write();
      invalidate();
    } catch (error) {
      toast.error(`${failure}: ${sentence((error as Error).message)}`);
    } finally {
      setBusy(false);
    }
  }

  function move(index: number, step: number) {
    const list = statuses.data ?? [];
    const target = index + step;
    if (target < 0 || target >= list.length) return;
    const keys = list.map((s) => s.key);
    [keys[index], keys[target]] = [keys[target], keys[index]];
    void run(() => jobsApi.reorderStatuses(keys), "Could not reorder");
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <Section title="Statuses">
        <Card className="space-y-3">
          <p className="text-[13px] text-muted-foreground">
            Active statuses are the pipeline&apos;s stages, in this order. Closed ones end an application. Lead,
            applied and dropped are built in: rename or move them, but they stay.
          </p>
          {statuses.isPending ? (
            <Skeleton className="h-48 w-full" />
          ) : statuses.isError ? (
            <Muted className="text-status-error">Could not load statuses: {statuses.error.message}</Muted>
          ) : (
            <ol className="divide-y divide-border rounded-md border border-border">
              {statuses.data.map((status, index) => (
                <StatusRow
                  key={status.key}
                  status={status}
                  first={index === 0}
                  last={index === statuses.data.length - 1}
                  busy={busy}
                  onMove={(step) => move(index, step)}
                  onRename={(label) =>
                    run(() => jobsApi.updateStatusDef(status.key, { label }), "Could not rename")
                  }
                  onKind={(kind) =>
                    run(() => jobsApi.updateStatusDef(status.key, { kind }), "Could not change the kind")
                  }
                  onRemove={() => run(() => jobsApi.removeStatusDef(status.key), "Could not remove")}
                />
              ))}
            </ol>
          )}
          <AddStatus />
        </Card>
      </Section>
    </div>
  );
}

function StatusRow({
  status,
  first,
  last,
  busy,
  onMove,
  onRename,
  onKind,
  onRemove,
}: {
  status: JobStatus;
  first: boolean;
  last: boolean;
  busy: boolean;
  onMove: (step: number) => void;
  onRename: (label: string) => Promise<void>;
  onKind: (kind: "active" | "closed") => Promise<void>;
  onRemove: () => Promise<void>;
}) {
  const [label, setLabel] = useState(status.label);
  useEffect(() => setLabel(status.label), [status.label]);

  function rename() {
    const next = label.trim();
    if (!next || next === status.label) {
      setLabel(status.label);
      return;
    }
    void onRename(next);
  }

  return (
    <li className="flex flex-wrap items-center gap-2 px-2 py-1.5">
      <span className="size-2.5 shrink-0 rounded-full" style={{ background: kindTone(status.kind) }} aria-hidden />
      <Input
        aria-label={`Label of ${status.key}`}
        value={label}
        onChange={(e) => setLabel(e.target.value)}
        onBlur={rename}
        onKeyDown={(e) => {
          if (e.key === "Enter") e.currentTarget.blur();
          if (e.key === "Escape") {
            setLabel(status.label);
            e.currentTarget.blur();
          }
        }}
        className="h-7 w-44 text-[13px]"
      />
      <code className="text-[11px] text-muted-foreground">{status.key}</code>
      <span className="ml-auto flex items-center gap-1">
        {status.reserved || status.kind === "lead" || status.kind === "dropped" ? (
          <span className="flex items-center gap-1 text-xs text-muted-foreground" title="Built in: kind fixed, never removed">
            <Lock className="size-3" aria-hidden />
            {KIND_TEXT[status.kind]}
          </span>
        ) : (
          <NativeSelect
            aria-label={`Kind of ${status.label}`}
            value={status.kind}
            disabled={busy}
            onChange={(e) => void onKind(e.target.value as "active" | "closed")}
            className="h-7"
          >
            <option value="active">{KIND_TEXT.active}</option>
            <option value="closed">{KIND_TEXT.closed}</option>
          </NativeSelect>
        )}
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={`Move ${status.label} up`}
          disabled={first || busy}
          onClick={() => onMove(-1)}
        >
          <ArrowUp />
        </Button>
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={`Move ${status.label} down`}
          disabled={last || busy}
          onClick={() => onMove(1)}
        >
          <ArrowDown />
        </Button>
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={`Remove ${status.label}`}
          title={status.reserved ? "Built in; cannot be removed" : `Remove ${status.label}`}
          disabled={status.reserved || busy}
          className="text-muted-foreground hover:text-destructive"
          onClick={() => void onRemove()}
        >
          <Trash2 />
        </Button>
      </span>
    </li>
  );
}

function AddStatus() {
  const add = useJobsMutation(jobsApi.addStatus);
  const [label, setLabel] = useState("");
  const [kind, setKind] = useState<"active" | "closed">("active");

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!label.trim()) return;
    add.mutate(
      { label: label.trim(), kind },
      {
        onSuccess: (status) => {
          toast.success(`Added ${status.label}`);
          setLabel("");
        },
      },
    );
  }

  return (
    <form onSubmit={submit} aria-label="Add a status" className="space-y-1">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          id={QUICK_ADD_ID}
          aria-label="New status label"
          placeholder="New status, e.g. Take-home"
          value={label}
          onChange={(e) => {
            setLabel(e.target.value);
            add.reset();
          }}
          className="h-8 w-56 text-[13px]"
        />
        <NativeSelect aria-label="Kind" value={kind} onChange={(e) => setKind(e.target.value as "active" | "closed")}>
          <option value="active">{KIND_TEXT.active}</option>
          <option value="closed">{KIND_TEXT.closed}</option>
        </NativeSelect>
        <Button type="submit" size="sm" variant="outline" disabled={add.isPending || !label.trim()}>
          <Plus />
          Add status
        </Button>
      </div>
      <p className="text-xs text-muted-foreground">A new status goes after the last one of its kind.</p>
      <ErrorLine message={add.error?.message} />
    </form>
  );
}
