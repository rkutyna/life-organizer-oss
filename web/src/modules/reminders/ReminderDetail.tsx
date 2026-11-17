import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Field, NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { formatAge, toTimeInput } from "@/lib/dates";

import {
  isReadOnlyList,
  providerName,
  useReminder,
  useReminderLists,
  useSetReminderDone,
  useUpdateReminder,
  type Reminder,
  type ReminderUpdate,
} from "./api";
import { PRIORITY_OPTIONS } from "./priority";
import { DoneToggle, SyncNote } from "./ReminderBits";

/**
 * Edit one reminder in place: each field saves on its own and travels to its provider through
 * the op queue. There is no delete: the organizer never deletes a reminder. A read-only list
 * shows its fields locked; a Google Tasks list has no time and no priority, so those fields are
 * hidden.
 */
export function ReminderDetail({ reminderId }: { reminderId: number }) {
  const reminder = useReminder(reminderId);

  if (reminder.isPending) {
    return (
      <div className="space-y-3 p-1">
        <Skeleton className="h-6 w-2/3" />
        <Skeleton className="h-4 w-1/2" />
        <Skeleton className="h-20 w-full" />
      </div>
    );
  }
  if (reminder.isError) {
    return <p className="text-[13px] text-muted-foreground">{reminder.error.message}</p>;
  }
  return <ReminderForm key={reminder.data.id} reminder={reminder.data} />;
}

function ReminderForm({ reminder }: { reminder: Reminder }) {
  const lists = useReminderLists();
  const update = useUpdateReminder();
  const setDone = useSetReminderDone();
  const [title, setTitle] = useState(reminder.title);
  const [notes, setNotes] = useState(reminder.notes);

  // Pick up changes made elsewhere (a poll, another tab, the phone).
  useEffect(() => setTitle(reminder.title), [reminder.title]);
  useEffect(() => setNotes(reminder.notes), [reminder.notes]);

  const provider = providerName(reminder.source);
  const google = reminder.source === "google";
  const readOnly = isReadOnlyList(lists.data, reminder.list_id);
  // A reminder moves only within its account: the writable lists of the same account, plus
  // the current one so it still shows.
  const listChoices = (lists.data ?? []).filter(
    (list) =>
      list.id === reminder.list_id ||
      (list.writable && list.source === reminder.source && list.account_id === reminder.account_id),
  );

  function save(changes: ReminderUpdate) {
    update.mutate(
      { id: reminder.id, changes },
      { onError: (error) => toast.error(`Could not save: ${error.message}`) },
    );
  }

  function saveTitle() {
    const next = title.trim();
    if (!next) setTitle(reminder.title);
    else if (next !== reminder.title) save({ title: next });
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-start gap-3">
        <DoneToggle
          done={reminder.completed}
          disabled={readOnly}
          onToggle={() => setDone.mutate({ id: reminder.id, done: !reminder.completed })}
          className="mt-[7px]"
        />
        <textarea
          value={title}
          disabled={readOnly}
          onChange={(e) => setTitle(e.target.value)}
          onBlur={saveTitle}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              e.currentTarget.blur();
            }
          }}
          rows={1}
          aria-label="Title"
          className="field-sizing-content min-h-8 flex-1 resize-none rounded-md bg-transparent px-1 py-0.5 text-base font-medium outline-none focus:bg-accent/50 disabled:cursor-not-allowed disabled:opacity-70"
        />
      </div>

      <div className="space-y-2.5">
        <Field label="Due" htmlFor="reminder-due-date">
          <Input
            id="reminder-due-date"
            type="date"
            value={reminder.due_date ?? ""}
            disabled={readOnly}
            onChange={(e) => save({ due_date: e.target.value || null })}
            className="h-8 w-40"
          />
          {!google && (
            <Input
              type="time"
              aria-label="Due time"
              value={toTimeInput(reminder.due_time)}
              disabled={readOnly || !reminder.due_date}
              onChange={(e) => save({ due_time: e.target.value || null })}
              className="h-8 w-36"
            />
          )}
          {reminder.due_date && !readOnly && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Clear due date"
              onClick={() => save({ due_date: null })}
            >
              <X />
            </Button>
          )}
        </Field>
        {google && (
          <p className="text-xs text-muted-foreground sm:pl-[7.25rem]">
            Google Tasks keeps a due date but no time or priority.
          </p>
        )}
        {!google && (
          <Field label="Priority" htmlFor="reminder-priority">
            <NativeSelect
              id="reminder-priority"
              value={reminder.priority?.toString() ?? ""}
              disabled={readOnly}
              onChange={(e) => save({ priority: e.target.value ? Number(e.target.value) : null })}
              className="w-40"
            >
              <option value="">None</option>
              {PRIORITY_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </NativeSelect>
          </Field>
        )}
        <Field label="List" htmlFor="reminder-list">
          <NativeSelect
            id="reminder-list"
            value={reminder.list_id ?? ""}
            disabled={readOnly || listChoices.length < 2}
            onChange={(e) => save({ list_id: e.target.value })}
            className="w-40 truncate"
          >
            {listChoices.map((list) => (
              <option key={list.id} value={list.id} disabled={!list.writable}>
                {list.title}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Notes" htmlFor="reminder-notes" className="sm:items-start">
          <Textarea
            id="reminder-notes"
            value={notes}
            disabled={readOnly}
            onChange={(e) => setNotes(e.target.value)}
            onBlur={() => notes !== reminder.notes && save({ notes })}
            placeholder="Add notes"
            className="min-h-20 text-[13px]"
          />
        </Field>
      </div>

      <div className="space-y-2">
        <SyncNote reminder={reminder} />
        {readOnly && (
          <p className="text-xs text-muted-foreground">
            This list is read-only in {provider}, so its reminders cannot be changed here.
          </p>
        )}
      </div>

      <p className="text-xs text-muted-foreground">
        {reminder.list_title ?? "No list"} · {provider}
        {reminder.modified_at && ` · last changed there ${formatAge(reminder.modified_at)}`}
      </p>
    </div>
  );
}
