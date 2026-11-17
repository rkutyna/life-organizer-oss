import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { api, unwrap, type Schemas } from "@/api/client";

import { calendarKeys } from "./api";

/**
 * Connected calendars (server module `calendar_ext`): the calendars shown, grouped by account,
 * connecting a CalDAV account, and "sync now". Everything here is read-only mirrored data.
 */
export type CalendarGroup = Schemas["CalendarGroupOut"];
export type ConnectCalDAV = Schemas["CalDAVConnectIn"];

/** The calendar source whose items carry their own calendar (`meta.calendar_key`). */
export const EXTERNAL_SOURCE = "calendar_ext";

const groupsKey = [...calendarKeys.all, "external", "groups"] as const;

export function useCalendarGroups() {
  return useQuery({
    queryKey: groupsKey,
    queryFn: () => unwrap(api.GET("/api/calendar_ext/calendars")),
    refetchInterval: 60_000,
  });
}

/** After anything that changes mirrored calendars: the feed, the groups, freshness, accounts. */
function useRefreshAll() {
  const queryClient = useQueryClient();
  return () => {
    void queryClient.invalidateQueries({ queryKey: calendarKeys.all });
    void queryClient.invalidateQueries({ queryKey: ["status"] });
    void queryClient.invalidateQueries({ queryKey: ["settings", "accounts"] });
  };
}

export function useConnectCalDAV() {
  const refresh = useRefreshAll();
  return useMutation({
    mutationFn: (body: ConnectCalDAV) =>
      unwrap(api.POST("/api/calendar_ext/accounts/caldav", { body })),
    onSuccess: refresh,
  });
}

export function useSyncNow() {
  const refresh = useRefreshAll();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/api/calendar_ext/sync")),
    onSettled: refresh,
  });
}
