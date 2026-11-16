import { keepPreviousData, useQuery } from "@tanstack/react-query";

import { api, unwrap } from "@/api/client";

/**
 * Calendar data. Any module that writes something shown on the calendar invalidates
 * `["calendar"]` after the write.
 */
export const calendarKeys = {
  all: ["calendar"] as const,
  range: (start: string, end: string) => ["calendar", "items", start, end] as const,
  sources: ["calendar", "sources"] as const,
};

/** Items overlapping [start, end). Dates are ISO strings (date or datetime). */
export function useCalendarItems(range: { start: string; end: string } | null) {
  return useQuery({
    queryKey: calendarKeys.range(range?.start ?? "", range?.end ?? ""),
    queryFn: () =>
      unwrap(api.GET("/api/calendar", { params: { query: { start: range!.start, end: range!.end } } })),
    enabled: range !== null,
    placeholderData: keepPreviousData,
  });
}

export function useCalendarSources() {
  return useQuery({
    queryKey: calendarKeys.sources,
    queryFn: () => unwrap(api.GET("/api/calendar/sources")),
    staleTime: 5 * 60_000,
  });
}
