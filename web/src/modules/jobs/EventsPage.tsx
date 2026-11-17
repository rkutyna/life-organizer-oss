import { Plus } from "lucide-react";
import { useState } from "react";
import { useSearchParams } from "react-router";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

import { useEvents } from "./api";
import { EventCard, EventForm } from "./EventParts";
import { today } from "./format";
import { Muted, QUICK_ADD_ID, Section } from "./parts";

/**
 * Job events: fairs, networking, info sessions. Coming up first; past ones on request
 * (?past=1). The calendar links here with ?event=<id>, which opens and highlights that one.
 */
export default function EventsPage() {
  const [params, setParams] = useSearchParams();
  const events = useEvents();
  const [adding, setAdding] = useState(false);
  const highlighted = params.get("event") ? Number(params.get("event")) : null;

  const all = events.data ?? [];
  const now = today();
  const upcoming = all.filter((e) => e.on_date >= now);
  const past = all.filter((e) => e.on_date < now).reverse();
  const highlightIsPast = past.some((e) => e.id === highlighted);
  const showPast = params.get("past") === "1" || highlightIsPast;

  function setPast(on: boolean) {
    const next = new URLSearchParams(params);
    if (on) next.set("past", "1");
    else {
      next.delete("past");
      if (highlightIsPast) next.delete("event");
    }
    setParams(next, { replace: true });
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        {!adding && (
          <Button id={QUICK_ADD_ID} size="sm" variant="outline" onClick={() => setAdding(true)}>
            <Plus />
            Add event
          </Button>
        )}
        <label className="ml-auto flex items-center gap-1.5 text-[13px] text-muted-foreground">
          <input
            type="checkbox"
            checked={showPast}
            onChange={(e) => setPast(e.target.checked)}
            className="size-3.5 accent-primary"
          />
          Show past events
        </label>
      </div>

      {adding && <EventForm onDone={() => setAdding(false)} focusId={QUICK_ADD_ID} />}

      {events.isPending ? (
        <Skeleton className="h-32 w-full" />
      ) : events.isError ? (
        <Muted className="text-status-error">Could not load events: {events.error.message}</Muted>
      ) : (
        <>
          <Section title={`Coming up · ${upcoming.length}`}>
            {upcoming.length === 0 ? (
              <Muted>No events coming up.</Muted>
            ) : (
              <div className="space-y-2">
                {upcoming.map((event) => (
                  <EventCard key={event.id} event={event} highlight={event.id === highlighted} />
                ))}
              </div>
            )}
          </Section>
          {showPast && (
            <Section title={`Past · ${past.length}`}>
              {past.length === 0 ? (
                <Muted>No past events.</Muted>
              ) : (
                <div className="space-y-2">
                  {past.map((event) => (
                    <EventCard key={event.id} event={event} highlight={event.id === highlighted} />
                  ))}
                </div>
              )}
            </Section>
          )}
          {highlighted !== null && !all.some((e) => e.id === highlighted) && (
            <Muted className="text-status-error">Event {highlighted} was not found (deleted?).</Muted>
          )}
        </>
      )}
    </div>
  );
}
