/**
 * Reminders: types, query keys and one hook per read or write.
 *
 * The server never edits the mirror directly. A write queues an op and returns the reminder with
 * `sync` showing where it stands: a Google Tasks change is usually applied before the answer
 * comes back ("synced"); an Apple Reminders change waits for the Mac helper ("syncing", or
 * "waiting_for_device" when the Mac is not polling). The UI shows every change at once
 * (optimistic). Lists poll every 5 s while a change is on its way and every 30 s otherwise.
 * Every write also refreshes the calendar, since dated reminders are on it.
 */

import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";

import { api, unwrap, type Schemas } from "@/api/client";

export type Reminder = Schemas["ReminderOut"];
export type ReminderList = Schemas["ReminderListOut"];
export type ReminderCreate = Schemas["ReminderCreate"];
export type ReminderUpdate = Schemas["ReminderUpdate"];
export type ReminderOp = Schemas["ReminderOpOut"];
export type ReminderStatus = Schemas["ReminderStatusOut"];

export const reminderKeys = {
  all: ["reminders"] as const,
  list: ["reminders", "list"] as const,
  detail: (id: number) => ["reminders", "detail", id] as const,
  lists: ["reminders", "lists"] as const,
  status: ["reminders", "status"] as const,
};

const SYNCING_MS = 5_000;
const IDLE_MS = 30_000;

function inFlight(reminder: Reminder): boolean {
  return reminder.sync.state === "syncing" || reminder.sync.state === "waiting_for_device";
}

/** Every reminder, open and completed in the last 30 days. */
export function useReminders() {
  return useQuery({
    queryKey: reminderKeys.list,
    queryFn: () =>
      unwrap(api.GET("/api/reminders", { params: { query: { include_completed: true } } })),
    refetchInterval: (query) => (query.state.data?.some(inFlight) ? SYNCING_MS : IDLE_MS),
  });
}

export function useReminder(id: number | null) {
  return useQuery({
    queryKey: reminderKeys.detail(id ?? 0),
    queryFn: () =>
      unwrap(api.GET("/api/reminders/{reminder_id}", { params: { path: { reminder_id: id! } } })),
    enabled: id !== null,
    refetchInterval: (query) =>
      query.state.data && inFlight(query.state.data) ? SYNCING_MS : IDLE_MS,
  });
}

/** Lists with open counts: Apple Reminders first, then each Google account's task lists. */
export function useReminderLists() {
  return useQuery({
    queryKey: reminderKeys.lists,
    queryFn: () => unwrap(api.GET("/api/reminders/lists")),
    refetchInterval: IDLE_MS,
  });
}

/** Each source's freshness, whether the helper is polling, and what is queued. */
export function useReminderStatus() {
  return useQuery({
    queryKey: reminderKeys.status,
    queryFn: () => unwrap(api.GET("/api/reminders/status")),
    refetchInterval: (query) => (query.state.data?.pending_ops ? SYNCING_MS : IDLE_MS),
  });
}

/** Refresh everything a reminder write can change. */
export function useInvalidateReminders() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: reminderKeys.all }),
      queryClient.invalidateQueries({ queryKey: ["calendar"] }),
      queryClient.invalidateQueries({ queryKey: ["history"] }),
    ]);
}

export function useCreateReminder() {
  const invalidate = useInvalidateReminders();
  return useMutation({
    mutationFn: (body: ReminderCreate) => unwrap(api.POST("/api/reminders", { body })),
    onSettled: invalidate,
  });
}

/** Poll every Google Tasks account now. Apple Reminders syncs whenever the helper pushes. */
export function useSyncNow() {
  const queryClient = useQueryClient();
  const invalidate = useInvalidateReminders();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/api/reminders/sync")),
    onSettled: () => {
      void invalidate();
      void queryClient.invalidateQueries({ queryKey: ["status"] });
    },
  });
}

/** Edit one reminder's fields. Optimistic: the row shows the new value at once. */
export function useUpdateReminder() {
  const queryClient = useQueryClient();
  const invalidate = useInvalidateReminders();
  return useMutation({
    mutationFn: ({ id, changes }: { id: number; changes: ReminderUpdate }) =>
      unwrap(
        api.PATCH("/api/reminders/{reminder_id}", {
          params: { path: { reminder_id: id } },
          body: changes,
        }),
      ),
    onMutate: async ({ id, changes }) => {
      await queryClient.cancelQueries({ queryKey: reminderKeys.all });
      const lists = queryClient.getQueryData<ReminderList[]>(reminderKeys.lists);
      patchReminder(queryClient, id, (r) => applyChanges(r, changes, lists));
    },
    onSuccess: (reminder) => storeReminder(queryClient, reminder),
    onSettled: invalidate,
  });
}

/** Check off / un-check. Optimistic, so the row moves the moment it is clicked. */
export function useSetReminderDone() {
  const queryClient = useQueryClient();
  const invalidate = useInvalidateReminders();
  return useMutation({
    mutationFn: ({ id, done }: { id: number; done: boolean }) => {
      const params = { params: { path: { reminder_id: id } } };
      return unwrap(
        done
          ? api.POST("/api/reminders/{reminder_id}/complete", params)
          : api.POST("/api/reminders/{reminder_id}/uncomplete", params),
      );
    },
    onMutate: async ({ id, done }) => {
      await queryClient.cancelQueries({ queryKey: reminderKeys.all });
      const completedAt = done ? new Date().toISOString() : null;
      patchReminder(queryClient, id, (r) => ({
        ...r,
        completed: done,
        completed_at: completedAt,
        sync: { ...r.sync, state: "syncing" },
      }));
    },
    onSuccess: (reminder) => storeReminder(queryClient, reminder),
    onSettled: invalidate,
  });
}

/** Queue a failed op again (a Google op is applied again at once). */
export function useRetryOp() {
  const invalidate = useInvalidateReminders();
  return useMutation({
    mutationFn: (opId: number) =>
      unwrap(api.POST("/api/reminders/ops/{op_id}/retry", { params: { path: { op_id: opId } } })),
    onSettled: invalidate,
  });
}

/** Drop a pending or failed op. Withdrawing a create that never reached the provider removes it. */
export function useWithdrawOp() {
  const invalidate = useInvalidateReminders();
  return useMutation({
    mutationFn: (opId: number) =>
      unwrap(api.DELETE("/api/reminders/ops/{op_id}", { params: { path: { op_id: opId } } })),
    onSettled: invalidate,
  });
}

/** The reminder's failed ops, oldest first. Retry and Withdraw act on each of them. */
export function failedOps(reminder: Reminder): ReminderOp[] {
  return reminder.sync.pending_ops.filter((op) => op.state === "failed");
}

/** A list the provider will not let us write to (e.g. a list shared read-only). */
export function isReadOnlyList(lists: ReminderList[] | undefined, listId: string | null): boolean {
  if (!listId || !lists) return false;
  return lists.some((list) => list.id === listId && !list.writable);
}

/** "Apple Reminders" or "Google Tasks", for sync wording. */
export function providerName(source: string): string {
  return source === "google" ? "Google Tasks" : "Apple Reminders";
}

function patchReminder(
  queryClient: QueryClient,
  id: number,
  change: (reminder: Reminder) => Reminder,
) {
  queryClient.setQueriesData<Reminder[]>({ queryKey: reminderKeys.list }, (old) =>
    old?.map((r) => (r.id === id ? change(r) : r)),
  );
  queryClient.setQueryData<Reminder>(reminderKeys.detail(id), (old) =>
    old && old.id === id ? change(old) : old,
  );
}

/** Put the server's copy of a reminder in every cache that holds it. */
function storeReminder(queryClient: QueryClient, reminder: Reminder) {
  queryClient.setQueryData(reminderKeys.detail(reminder.id), reminder);
  queryClient.setQueriesData<Reminder[]>({ queryKey: reminderKeys.list }, (old) =>
    old?.map((r) => (r.id === reminder.id ? reminder : r)),
  );
}

/** The optimistic copy of an edit: the same fields the server will set, marked syncing. */
function applyChanges(
  reminder: Reminder,
  changes: ReminderUpdate,
  lists: ReminderList[] | undefined,
): Reminder {
  const next: Reminder = { ...reminder, sync: { ...reminder.sync, state: "syncing" } };
  if (changes.title != null) next.title = changes.title;
  if (changes.notes != null) next.notes = changes.notes;
  if (changes.priority !== undefined) next.priority = changes.priority;
  if (changes.due_date !== undefined) {
    next.due_date = changes.due_date;
    if (changes.due_date === null) next.due_time = null;
  }
  if (changes.due_time !== undefined && changes.due_date !== null) next.due_time = changes.due_time;
  if (changes.list_id) {
    const list = lists?.find((l) => l.id === changes.list_id);
    next.list_id = changes.list_id;
    next.list_title = list?.title ?? next.list_title;
    next.list_color = list?.color ?? next.list_color;
  }
  return next;
}
