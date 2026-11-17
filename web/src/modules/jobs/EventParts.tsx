import { ChevronDown, ChevronRight, ExternalLink, Plus } from "lucide-react";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn, sentence } from "@/lib/utils";

import { jobsApi, useJobsMutation, type JobEvent, type JobEventUpdate } from "./api";
import { formatEventWhen, isWebUrl, splitList, today } from "./format";
import { Chip, DeleteButton, kindTone, TagList } from "./parts";
import { RecordField, TagsField } from "./RecordField";

/** One job event, edited field by field. */
export function EventEditor({ event }: { event: JobEvent }) {
  const update = useJobsMutation((changes: JobEventUpdate) => jobsApi.updateEvent(event.id, changes));
  const save = (changes: JobEventUpdate) => update.mutateAsync(changes);

  return (
    <div className="space-y-2.5">
      <RecordField label="Name" kind="text" required value={event.name} onSave={(v) => save({ name: v as string })} />
      <RecordField
        label="Kind"
        kind="text"
        value={event.kind}
        placeholder="fair, networking, info session"
        onSave={(v) => save({ kind: v as string })}
      />
      <RecordField label="Day" kind="date" required value={event.on_date} onSave={(v) => save({ on_date: v as string })} />
      <RecordField
        label="Start"
        kind="time"
        value={event.start_time}
        onSave={(v) => save({ start_time: v as string | null })}
      />
      <RecordField
        label="End"
        kind="time"
        value={event.end_time}
        hint={event.start_time ? undefined : "An end time needs a start time"}
        onSave={(v) => save({ end_time: v as string | null })}
      />
      <RecordField label="Location" kind="text" value={event.location} onSave={(v) => save({ location: v as string })} />
      <RecordField label="Link" kind="url" value={event.url} onSave={(v) => save({ url: v as string })} />
      <RecordField
        label="Attended"
        kind="tristate"
        value={event.attended}
        emptyLabel="Unknown"
        onSave={(v) => save({ attended: v as boolean | null })}
      />
      <TagsField value={event.tags} onSave={(tags) => save({ tags })} />
      <RecordField label="Notes" kind="textarea" value={event.notes} onSave={(v) => save({ notes: v as string })} />
    </div>
  );
}

function AttendedChip({ attended }: { attended: boolean | null }) {
  if (attended === null) return null;
  return attended ? (
    <Chip tone={kindTone("active")}>Attended</Chip>
  ) : (
    <Chip tone={kindTone("dropped")}>Missed</Chip>
  );
}

/** A collapsible event card; `highlight` opens it, rings it and scrolls it into view. */
export function EventCard({ event, highlight = false }: { event: JobEvent; highlight?: boolean }) {
  const [open, setOpen] = useState(highlight);
  const ref = useRef<HTMLElement>(null);

  useEffect(() => {
    if (highlight) {
      setOpen(true);
      ref.current?.scrollIntoView({ block: "center" });
    }
  }, [highlight]);

  return (
    <article
      ref={ref}
      id={`job-event-${event.id}`}
      className={cn("rounded-lg border border-border bg-card", highlight && "ring-2 ring-ring/40")}
    >
      <div className="flex items-center gap-2 px-3 py-2">
        <button
          type="button"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
          className="flex min-w-0 flex-1 items-start gap-1.5 text-left"
        >
          {open ? (
            <ChevronDown className="mt-0.5 size-3.5 shrink-0 text-muted-foreground" />
          ) : (
            <ChevronRight className="mt-0.5 size-3.5 shrink-0 text-muted-foreground" />
          )}
          <span className="min-w-0">
            <span className="flex flex-wrap items-center gap-2 text-[13px] font-medium">
              <span className="truncate">{event.name}</span>
              {event.kind && <span className="font-normal text-muted-foreground">{event.kind}</span>}
              <AttendedChip attended={event.attended} />
              <TagList tags={event.tags} />
            </span>
            <span className="block text-xs text-muted-foreground tabular">
              {formatEventWhen(event)}
              {event.location && ` · ${event.location}`}
            </span>
          </span>
        </button>
        {isWebUrl(event.url) && (
          <a
            href={event.url.trim()}
            target="_blank"
            rel="noreferrer"
            aria-label="Open the event's link"
            className="text-muted-foreground hover:text-foreground"
          >
            <ExternalLink className="size-3.5" />
          </a>
        )}
        <DeleteButton icon what={event.name} onDelete={() => jobsApi.deleteEvent(event.id)} />
      </div>
      {open && (
        <div className="border-t border-border px-3 py-3">
          <EventEditor event={event} />
        </div>
      )}
    </article>
  );
}

/** A new job event: a name and a day, optionally times, place, link and tags. */
export function EventForm({ onDone, focusId }: { onDone?: () => void; focusId?: string }) {
  const create = useJobsMutation(jobsApi.createEvent);
  const [name, setName] = useState("");
  const [kind, setKind] = useState("");
  const [day, setDay] = useState(today());
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [location, setLocation] = useState("");
  const [url, setUrl] = useState("");
  const [tags, setTags] = useState("");

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!name.trim() || !day) {
      toast.error("Give a name and a day");
      return;
    }
    try {
      await create.mutateAsync({
        name: name.trim(),
        kind: kind.trim(),
        on_date: day,
        start_time: start || null,
        end_time: end || null,
        location: location.trim(),
        url: url.trim(),
        tags: splitList(tags),
      });
      toast.success("Event added");
      setName("");
      setKind("");
      setStart("");
      setEnd("");
      setLocation("");
      setUrl("");
      setTags("");
      onDone?.();
    } catch (error) {
      toast.error(`Could not add the event: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <form onSubmit={submit} aria-label="New event" className="space-y-2 rounded-lg border border-dashed border-border p-3">
      <div className="grid gap-2 sm:grid-cols-4">
        <Input
          id={focusId}
          aria-label="Name"
          placeholder="Name, e.g. Example Labs career fair"
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="h-8 text-[13px] sm:col-span-2"
        />
        <Input
          aria-label="Kind"
          placeholder="Kind: fair, networking…"
          value={kind}
          onChange={(e) => setKind(e.target.value)}
          className="h-8 text-[13px]"
        />
        <Input
          type="date"
          aria-label="Day"
          value={day}
          onChange={(e) => setDay(e.target.value)}
          className="h-8 text-[13px]"
          required
        />
        <div className="flex items-center gap-1">
          <Input
            type="time"
            aria-label="Start time"
            value={start}
            onChange={(e) => setStart(e.target.value)}
            className="h-8 text-[13px]"
          />
          <span className="text-muted-foreground">–</span>
          <Input
            type="time"
            aria-label="End time"
            value={end}
            disabled={!start}
            onChange={(e) => setEnd(e.target.value)}
            className="h-8 text-[13px]"
          />
        </div>
        <Input
          aria-label="Location"
          placeholder="Location"
          value={location}
          onChange={(e) => setLocation(e.target.value)}
          className="h-8 text-[13px]"
        />
        <Input
          aria-label="Link"
          placeholder="https://events.example.com/…"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          className="h-8 text-[13px]"
        />
        <Input
          aria-label="Tags"
          placeholder="Tags, comma separated"
          value={tags}
          onChange={(e) => setTags(e.target.value)}
          className="h-8 text-[13px]"
        />
      </div>
      <div className="flex justify-end gap-2">
        {onDone && (
          <Button type="button" variant="ghost" size="sm" onClick={onDone}>
            Cancel
          </Button>
        )}
        <Button type="submit" size="sm" disabled={create.isPending}>
          <Plus />
          Add event
        </Button>
      </div>
    </form>
  );
}
