import { Pencil, Trash2 } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { sentence } from "@/lib/utils";

import {
  jobsApi,
  useInvalidateJobs,
  useJobsMutation,
  useStatusEvents,
  useStatusInfo,
  type Application,
  type StatusEvent,
} from "./api";
import { formatDate, today } from "./format";
import { Card, Muted, Section, StatusChip } from "./parts";

/**
 * The dated status history of one application, oldest first, with "add status". The
 * application's status follows its latest event (the server keeps them in step); an event dated
 * before the latest is recorded but leaves the status alone.
 */
export function StatusTimeline({ application }: { application: Application }) {
  const info = useStatusInfo();
  const events = useStatusEvents(application.id);
  const add = useJobsMutation((body: { status: string; on_date: string | null; note: string }) =>
    jobsApi.addStatusEvent(application.id, body),
  );
  const options = info.options("active", "closed");
  const [status, setStatus] = useState("");
  const [onDate, setOnDate] = useState(today());
  const [note, setNote] = useState("");
  const chosen = status || options.find((o) => o.value !== application.status)?.value || "";

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!chosen) return;
    try {
      await add.mutateAsync({ status: chosen, on_date: onDate || null, note: note.trim() });
      toast.success(`Status: ${info.label(chosen)}`);
      setNote("");
      setStatus("");
      setOnDate(today());
    } catch (error) {
      toast.error(`Could not add the status: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <Section title="Status history">
      <Card className="space-y-3">
        {events.isPending ? (
          <Skeleton className="h-16 w-full" />
        ) : events.isError ? (
          <Muted className="text-status-error">Could not load the history: {events.error.message}</Muted>
        ) : events.data.length === 0 ? (
          <Muted>No status recorded yet.</Muted>
        ) : (
          <ol className="space-y-2.5 border-l border-border pl-3">
            {events.data.map((event) => (
              <EventRow key={event.id} event={event} only={events.data.length === 1} />
            ))}
          </ol>
        )}

        <form
          onSubmit={submit}
          aria-label="Add a status"
          className="flex flex-wrap items-center gap-2 border-t border-border pt-3"
        >
          <NativeSelect aria-label="New status" value={chosen} onChange={(e) => setStatus(e.target.value)}>
            {options.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </NativeSelect>
          <Input
            type="date"
            aria-label="Status date"
            value={onDate}
            onChange={(e) => setOnDate(e.target.value)}
            className="h-8 w-40 text-[13px]"
          />
          <Input
            aria-label="Note"
            placeholder="Note (optional)"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            className="h-8 min-w-40 flex-1 text-[13px]"
          />
          <Button type="submit" size="sm" disabled={add.isPending || !chosen}>
            Add status
          </Button>
        </form>
      </Card>
    </Section>
  );
}

function EventRow({ event, only }: { event: StatusEvent; only: boolean }) {
  const info = useStatusInfo();
  const invalidate = useInvalidateJobs();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState({ status: event.status, on_date: event.on_date, note: event.note });
  const [busy, setBusy] = useState(false);
  // lead and dropped events are set by the lead routes; their status cannot change here.
  const leadEvent = ["lead", "dropped"].includes(info.kind(event.status));

  async function save() {
    const changes = {
      ...(draft.status !== event.status ? { status: draft.status } : {}),
      ...(draft.on_date !== event.on_date && draft.on_date ? { on_date: draft.on_date } : {}),
      ...(draft.note !== event.note ? { note: draft.note } : {}),
    };
    setBusy(true);
    try {
      if (Object.keys(changes).length) {
        await jobsApi.updateStatusEvent(event.id, changes);
        invalidate();
      }
      setEditing(false);
    } catch (error) {
      toast.error(`Could not save: ${sentence((error as Error).message)}`);
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    setBusy(true);
    try {
      await jobsApi.deleteStatusEvent(event.id);
      invalidate();
      toast.success(`Removed the ${info.label(event.status)} status`);
    } catch (error) {
      // 409: an application keeps at least one status event.
      toast.error(`Could not remove: ${sentence((error as Error).message)}`);
    } finally {
      setBusy(false);
    }
  }

  if (editing) {
    return (
      <li className="relative space-y-2">
        <Dot />
        <div className="flex flex-wrap items-center gap-2">
          <NativeSelect
            aria-label="Event status"
            value={draft.status}
            disabled={leadEvent}
            onChange={(e) => setDraft({ ...draft, status: e.target.value })}
          >
            {leadEvent ? (
              <option value={event.status}>{info.label(event.status)}</option>
            ) : (
              info.options("active", "closed").map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))
            )}
          </NativeSelect>
          <Input
            type="date"
            aria-label="Event date"
            value={draft.on_date}
            onChange={(e) => setDraft({ ...draft, on_date: e.target.value })}
            className="h-8 w-40 text-[13px]"
          />
        </div>
        <Input
          aria-label="Event note"
          placeholder="Note"
          value={draft.note}
          onChange={(e) => setDraft({ ...draft, note: e.target.value })}
          onKeyDown={(e) => e.key === "Enter" && void save()}
          className="h-8 text-[13px]"
        />
        <div className="flex flex-wrap items-center justify-between gap-2">
          <Button
            variant="ghost"
            size="sm"
            className="text-muted-foreground hover:text-destructive"
            disabled={busy}
            title={only ? "An application keeps at least one status" : undefined}
            onClick={() => void remove()}
          >
            <Trash2 />
            Delete
          </Button>
          <div className="flex gap-2">
            <Button variant="ghost" size="sm" onClick={() => setEditing(false)}>
              Cancel
            </Button>
            <Button size="sm" onClick={() => void save()} disabled={busy}>
              Save
            </Button>
          </div>
        </div>
      </li>
    );
  }

  return (
    <li className="group relative">
      <Dot />
      <div className="flex items-start gap-2">
        <div className="min-w-0 flex-1 space-y-0.5">
          <div className="flex flex-wrap items-center gap-2 text-[13px]">
            <span className="w-24 text-muted-foreground tabular">{formatDate(event.on_date)}</span>
            <StatusChip status={event.status} />
          </div>
          {event.note && <p className="text-[13px] break-words text-muted-foreground">{event.note}</p>}
        </div>
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label="Edit this status event"
          onClick={() => {
            setDraft({ status: event.status, on_date: event.on_date, note: event.note });
            setEditing(true);
          }}
          className="opacity-60 group-hover:opacity-100 focus-visible:opacity-100"
        >
          <Pencil />
        </Button>
      </div>
    </li>
  );
}

function Dot() {
  return (
    <span className="absolute top-1.5 -left-[17.5px] size-2 rounded-full border-2 border-card bg-muted-foreground/50" />
  );
}
