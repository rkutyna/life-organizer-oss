import { ArrowUpRight } from "lucide-react";
import { Link } from "react-router";

import type { CalendarDetailProps } from "@/app/modules";
import { Skeleton } from "@/components/ui/skeleton";

import { jobsApi, useEvent } from "./api";
import { EventEditor } from "./EventParts";
import { DeleteButton, Muted } from "./parts";

/** A job event opened from the calendar: edit it in place or delete it. */
export default function EventCalendarDetail({ item, onClose }: CalendarDetailProps) {
  const raw = item.meta?.event_id;
  const id = typeof raw === "number" ? raw : Number.isFinite(Number(raw)) ? Number(raw) : null;
  const event = useEvent(id);

  if (id === null) return <Muted className="text-status-error">This item has no event id.</Muted>;
  if (event.isPending) return <Skeleton className="h-48 w-full" />;
  if (event.isError) {
    return <Muted className="text-status-error">Could not load the event: {event.error.message}</Muted>;
  }

  const e = event.data;
  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-2">
        <h2 className="text-base font-medium">{e.name}</h2>
        <Link
          to={`/jobs/events?event=${e.id}`}
          className="inline-flex shrink-0 items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
        >
          Events
          <ArrowUpRight className="size-3.5" />
        </Link>
      </div>
      <EventEditor event={e} />
      <div className="border-t border-border pt-3">
        <DeleteButton what={e.name} onDelete={() => jobsApi.deleteEvent(e.id)} onDeleted={onClose} />
      </div>
    </div>
  );
}
