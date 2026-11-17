import { Plus } from "lucide-react";
import { useState } from "react";
import { useSearchParams } from "react-router";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

import { useInterviews } from "./api";
import { today } from "./format";
import { InterviewCard, InterviewForm } from "./InterviewParts";
import { Muted, QUICK_ADD_ID, Section } from "./parts";

/** Every interview: coming up (and unscheduled) first, past ones on request (?past=1). */
export default function InterviewsPage() {
  const [params, setParams] = useSearchParams();
  const showPast = params.get("past") === "1";
  const interviews = useInterviews({ upcoming: !showPast });
  const [adding, setAdding] = useState(false);

  const all = interviews.data ?? [];
  const now = today();
  const upcoming = all.filter((i) => i.on_date === null || i.on_date >= now);
  const past = all.filter((i) => i.on_date !== null && i.on_date < now).reverse();

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        {!adding && (
          <Button id={QUICK_ADD_ID} size="sm" variant="outline" onClick={() => setAdding(true)}>
            <Plus />
            Add interview
          </Button>
        )}
        <label className="ml-auto flex items-center gap-1.5 text-[13px] text-muted-foreground">
          <input
            type="checkbox"
            checked={showPast}
            onChange={(e) => setParams(e.target.checked ? { past: "1" } : {}, { replace: true })}
            className="size-3.5 accent-primary"
          />
          Show past interviews
        </label>
      </div>

      {adding && <InterviewForm onDone={() => setAdding(false)} focusId={QUICK_ADD_ID} />}

      {interviews.isPending ? (
        <Skeleton className="h-32 w-full" />
      ) : interviews.isError ? (
        <Muted className="text-status-error">Could not load interviews: {interviews.error.message}</Muted>
      ) : (
        <>
          <Section title={`Coming up · ${upcoming.length}`}>
            {upcoming.length === 0 ? (
              <Muted>No interviews coming up. Add one here or from an application.</Muted>
            ) : (
              <div className="space-y-2">
                {upcoming.map((interview) => (
                  <InterviewCard key={interview.id} interview={interview} showApplication />
                ))}
              </div>
            )}
          </Section>
          {showPast && (
            <Section title={`Past · ${past.length}`}>
              {past.length === 0 ? (
                <Muted>No past interviews.</Muted>
              ) : (
                <div className="space-y-2">
                  {past.map((interview) => (
                    <InterviewCard key={interview.id} interview={interview} showApplication />
                  ))}
                </div>
              )}
            </Section>
          )}
        </>
      )}
    </div>
  );
}
