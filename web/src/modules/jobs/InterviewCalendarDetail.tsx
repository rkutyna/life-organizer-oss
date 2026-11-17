import { ArrowUpRight } from "lucide-react";
import { Link } from "react-router";

import type { CalendarDetailProps } from "@/app/modules";
import { Skeleton } from "@/components/ui/skeleton";

import { jobsApi, useInterview } from "./api";
import { InterviewEditor } from "./InterviewParts";
import { DeleteButton, Muted } from "./parts";

function metaNumber(value: unknown): number | null {
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** An interview opened from the calendar: edit it in place, delete it, open its application. */
export default function InterviewCalendarDetail({ item, onClose }: CalendarDetailProps) {
  const id = metaNumber(item.meta?.interview_id);
  const interview = useInterview(id);

  if (id === null) return <Muted className="text-status-error">This item has no interview id.</Muted>;
  if (interview.isPending) return <Skeleton className="h-48 w-full" />;
  if (interview.isError) {
    return <Muted className="text-status-error">Could not load the interview: {interview.error.message}</Muted>;
  }

  const i = interview.data;
  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-base font-medium">
          {i.stage || "Interview"} · {i.company}
        </h2>
        <Link
          to={`/jobs/applications/${i.application_id}`}
          className="inline-flex items-center gap-1 text-[13px] text-muted-foreground hover:text-foreground hover:underline"
        >
          {i.application_title}
          <ArrowUpRight className="size-3.5" />
        </Link>
      </div>
      <InterviewEditor interview={i} />
      <div className="border-t border-border pt-3">
        <DeleteButton what="this interview" onDelete={() => jobsApi.deleteInterview(i.id)} onDeleted={onClose} />
      </div>
    </div>
  );
}
