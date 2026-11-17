import { ArrowUpRight, Check } from "lucide-react";
import { Link } from "react-router";
import { toast } from "sonner";

import type { CalendarDetailProps } from "@/app/modules";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { sentence } from "@/lib/utils";

import { jobsApi, useApplication, useContact, useInvalidateJobs } from "./api";
import { Muted } from "./parts";
import { RecordField } from "./RecordField";

interface NextAction {
  next_action: string;
  next_action_due: string | null;
}

/**
 * A next action's due date opened from the calendar (a contact's or an application's): edit the
 * action and the day in place, mark it done (clears both), or open the record.
 */
export default function DueCalendarDetail({ item, onClose }: CalendarDetailProps) {
  const kind = item.meta?.kind === "contact" ? "contact" : "application";
  const raw = Number(item.meta?.record_id);
  const id = Number.isFinite(raw) && raw > 0 ? raw : null;
  const contact = useContact(kind === "contact" ? id : null);
  const application = useApplication(kind === "application" ? id : null);
  const invalidate = useInvalidateJobs();

  const query = kind === "contact" ? contact : application;
  if (id === null) return <Muted className="text-status-error">This item has no record id.</Muted>;
  if (query.isPending) return <Skeleton className="h-32 w-full" />;
  if (query.isError) {
    return <Muted className="text-status-error">Could not load it: {query.error.message}</Muted>;
  }

  const record: NextAction = query.data;
  const title =
    kind === "contact" && contact.data
      ? contact.data.company
        ? `${contact.data.name} · ${contact.data.company}`
        : contact.data.name
      : application.data
        ? `${application.data.title} · ${application.data.company}`
        : "";
  const link = kind === "contact" ? `/jobs/contacts/${id}` : `/jobs/applications/${id}`;

  async function save(changes: Partial<NextAction>) {
    const result =
      kind === "contact"
        ? await jobsApi.updateContact(id!, changes)
        : await jobsApi.updateApplication(id!, changes);
    invalidate();
    return result;
  }

  async function done() {
    try {
      await save({ next_action: "", next_action_due: null });
      toast.success("Marked done");
      onClose();
    } catch (error) {
      toast.error(`Could not save: ${sentence((error as Error).message)}`);
    }
  }

  return (
    <div className="space-y-4">
      <div>
        <p className="text-xs text-muted-foreground">{kind === "contact" ? "Contact" : "Application"}</p>
        <Link
          to={link}
          className="inline-flex items-center gap-1 text-base font-medium hover:underline"
        >
          {title}
          <ArrowUpRight className="size-3.5" />
        </Link>
      </div>
      <div className="space-y-2.5">
        <RecordField
          label="Next action"
          kind="text"
          value={record.next_action}
          placeholder="Follow up"
          onSave={(v) => save({ next_action: v as string })}
        />
        <RecordField
          label="Due"
          kind="date"
          value={record.next_action_due}
          onSave={(v) => save({ next_action_due: v as string | null })}
        />
      </div>
      <div className="border-t border-border pt-3">
        <Button size="sm" variant="outline" onClick={() => void done()}>
          <Check />
          Done
        </Button>
      </div>
    </div>
  );
}
