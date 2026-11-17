import { ChevronDown, ChevronRight, Plus } from "lucide-react";
import { useState, type FormEvent } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { sentence } from "@/lib/utils";

import {
  jobsApi,
  useApplications,
  useInterviews,
  useJobsMutation,
  type Interview,
  type InterviewUpdate,
} from "./api";
import { formatInterviewWhen } from "./format";
import { DeleteButton, Muted, QUICK_ADD_ID, Section } from "./parts";
import { RecordField } from "./RecordField";

/** One interview, edited field by field (each save is one PATCH and one history entry). */
export function InterviewEditor({ interview }: { interview: Interview }) {
  const update = useJobsMutation((changes: InterviewUpdate) => jobsApi.updateInterview(interview.id, changes));
  const save = (changes: InterviewUpdate) => update.mutateAsync(changes);
  const applications = useApplications({ leads: "include" });
  const appOptions = (applications.data ?? []).map((a) => ({
    value: String(a.id),
    label: `${a.company} — ${a.title}`,
  }));
  // Until the list loads (or if it is filtered away), keep the current application choosable.
  if (!appOptions.some((o) => o.value === String(interview.application_id))) {
    appOptions.unshift({
      value: String(interview.application_id),
      label: `${interview.company} — ${interview.application_title}`,
    });
  }

  return (
    <div className="space-y-2.5">
      <RecordField
        label="Application"
        kind="select"
        required
        value={String(interview.application_id)}
        options={appOptions}
        hint="Change it to move the interview to another application"
        onSave={(v) => save({ application_id: Number(v) })}
      />
      <RecordField
        label="Stage"
        kind="text"
        value={interview.stage}
        placeholder="Recruiter screen, onsite…"
        onSave={(v) => save({ stage: v as string })}
      />
      <RecordField
        label="Day"
        kind="date"
        value={interview.on_date}
        onSave={(v) => save({ on_date: v as string | null })}
        hint={interview.on_date ? undefined : "On the calendar once it has a day"}
      />
      <RecordField
        label="Start time"
        kind="time"
        value={interview.start_time}
        onSave={(v) => save({ start_time: v as string | null })}
        hint={interview.start_time ? undefined : "No time: an all-day item"}
      />
      <RecordField
        label="Minutes"
        kind="number"
        value={interview.duration_minutes}
        placeholder="60"
        onSave={(v) => save({ duration_minutes: v as number | null })}
      />
      <RecordField
        label="Location"
        kind="text"
        value={interview.location}
        placeholder="Video link or address"
        onSave={(v) => save({ location: v as string })}
      />
      <RecordField
        label="Interviewer"
        kind="text"
        value={interview.interviewer}
        onSave={(v) => save({ interviewer: v as string })}
      />
      <RecordField
        label="Notes"
        kind="textarea"
        value={interview.notes}
        onSave={(v) => save({ notes: v as string })}
      />
    </div>
  );
}

/** A collapsible interview: the summary line, the editor when open, and delete. */
export function InterviewCard({
  interview,
  showApplication = false,
  defaultOpen = false,
}: {
  interview: Interview;
  showApplication?: boolean;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const label = interview.stage || "Interview";

  return (
    <article className="rounded-lg border border-border bg-card">
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
            <span className="block truncate text-[13px] font-medium">
              {label}
              {showApplication && <span className="font-normal text-muted-foreground"> · {interview.company}</span>}
            </span>
            <span className="block text-xs text-muted-foreground tabular">
              {formatInterviewWhen(interview)}
              {interview.interviewer && ` · ${interview.interviewer}`}
              {interview.location && ` · ${interview.location}`}
            </span>
          </span>
        </button>
        {showApplication && (
          <Link
            to={`/jobs/applications/${interview.application_id}`}
            className="hidden max-w-56 truncate text-xs text-muted-foreground hover:text-foreground hover:underline sm:block"
          >
            {interview.application_title}
          </Link>
        )}
        <DeleteButton
          icon
          what={`this ${label.toLowerCase()}`}
          onDelete={() => jobsApi.deleteInterview(interview.id)}
        />
      </div>
      {open && (
        <div className="border-t border-border px-3 py-3">
          <InterviewEditor interview={interview} />
        </div>
      )}
    </article>
  );
}

/**
 * A new interview. With `applicationId` it belongs to that application; otherwise the form
 * offers an application picker. Day and time may stay empty while it is being scheduled.
 */
export function InterviewForm({
  applicationId,
  onDone,
  focusId,
}: {
  applicationId?: number;
  onDone?: () => void;
  focusId?: string;
}) {
  const applications = useApplications({ leads: "include" }, applicationId === undefined);
  const create = useJobsMutation(jobsApi.createInterview);
  const [appId, setAppId] = useState("");
  const [stage, setStage] = useState("");
  const [day, setDay] = useState("");
  const [time, setTime] = useState("");
  const [minutes, setMinutes] = useState("");
  const [location, setLocation] = useState("");
  const [interviewer, setInterviewer] = useState("");
  const [notes, setNotes] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    const target = applicationId ?? (appId ? Number(appId) : null);
    if (target === null) {
      toast.error("Pick the application");
      return;
    }
    try {
      await create.mutateAsync({
        application_id: target,
        stage: stage.trim(),
        on_date: day || null,
        start_time: time || null,
        duration_minutes: minutes ? Number(minutes) : null,
        location: location.trim(),
        interviewer: interviewer.trim(),
        notes: notes.trim(),
      });
      toast.success("Interview added");
      setStage("");
      setDay("");
      setTime("");
      setMinutes("");
      setLocation("");
      setInterviewer("");
      setNotes("");
      onDone?.();
    } catch (error) {
      toast.error(`Could not add the interview: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <form
      onSubmit={submit}
      aria-label="New interview"
      className="space-y-2 rounded-lg border border-dashed border-border p-3"
    >
      {applicationId === undefined && (
        <NativeSelect
          id={focusId}
          aria-label="Application"
          value={appId}
          onChange={(e) => setAppId(e.target.value)}
          className="w-full"
          required
        >
          <option value="">Pick the application…</option>
          {(applications.data ?? []).map((a) => (
            <option key={a.id} value={a.id}>
              {a.company} — {a.title}
            </option>
          ))}
        </NativeSelect>
      )}
      <div className="grid gap-2 sm:grid-cols-4">
        <Input
          id={applicationId !== undefined ? focusId : undefined}
          aria-label="Stage"
          placeholder="Stage, e.g. Phone screen"
          value={stage}
          onChange={(e) => setStage(e.target.value)}
          className="h-8 text-[13px] sm:col-span-2"
        />
        <Input
          type="date"
          aria-label="Day"
          value={day}
          onChange={(e) => setDay(e.target.value)}
          className="h-8 text-[13px]"
        />
        <div className="flex gap-2">
          <Input
            type="time"
            aria-label="Start time"
            value={time}
            disabled={!day}
            title={day ? undefined : "Pick a day first"}
            onChange={(e) => setTime(e.target.value)}
            className="h-8 text-[13px]"
          />
          <Input
            type="number"
            min={5}
            max={1440}
            aria-label="Duration in minutes"
            placeholder="min"
            value={minutes}
            onChange={(e) => setMinutes(e.target.value)}
            className="h-8 w-20 text-[13px]"
          />
        </div>
        <Input
          aria-label="Location"
          placeholder="Location or video link"
          value={location}
          onChange={(e) => setLocation(e.target.value)}
          className="h-8 text-[13px] sm:col-span-2"
        />
        <Input
          aria-label="Interviewer"
          placeholder="Interviewer, e.g. Jane Doe"
          value={interviewer}
          onChange={(e) => setInterviewer(e.target.value)}
          className="h-8 text-[13px] sm:col-span-2"
        />
      </div>
      <Textarea
        aria-label="Notes"
        placeholder="Notes"
        value={notes}
        onChange={(e) => setNotes(e.target.value)}
        rows={2}
        className="min-h-12 text-[13px]"
      />
      <div className="flex justify-end gap-2">
        {onDone && (
          <Button type="button" variant="ghost" size="sm" onClick={onDone}>
            Cancel
          </Button>
        )}
        <Button type="submit" size="sm" disabled={create.isPending}>
          <Plus />
          Add interview
        </Button>
      </div>
    </form>
  );
}

/** The interviews of one application, with add. */
export function ApplicationInterviews({ applicationId }: { applicationId: number }) {
  const interviews = useInterviews({ application_id: applicationId });
  const [adding, setAdding] = useState(false);

  return (
    <Section
      title="Interviews"
      action={
        !adding && (
          <Button variant="ghost" size="xs" onClick={() => setAdding(true)}>
            <Plus />
            Add interview
          </Button>
        )
      }
    >
      <div className="space-y-2">
        {interviews.isPending ? null : interviews.isError ? (
          <Muted className="text-status-error">Could not load interviews.</Muted>
        ) : interviews.data.length === 0 && !adding ? (
          <Muted>No interviews yet.</Muted>
        ) : (
          interviews.data.map((interview) => <InterviewCard key={interview.id} interview={interview} />)
        )}
        {adding && (
          <InterviewForm applicationId={applicationId} onDone={() => setAdding(false)} focusId={QUICK_ADD_ID} />
        )}
      </div>
    </Section>
  );
}
