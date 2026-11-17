import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo } from "react";

import { api, unwrap, type Schemas } from "@/api/client";

/**
 * The job tracker's API: types, query keys, queries and writes.
 *
 * Every query key starts with `["jobs"]`, so one invalidation refreshes all job data. Every write
 * (through `useJobsMutation` or `useInvalidateJobs`) also refreshes `["calendar"]` (interviews,
 * events and next-action due dates show there) and `["history"]` (the record history panels).
 */

export type JobStatus = Schemas["JobStatusOut"];
export type StatusKind = JobStatus["kind"];
export type Company = Schemas["CompanyOut"];
export type CompanyRow = Schemas["CompanyRowOut"];
export type CompanyUpdate = Schemas["CompanyUpdate"];
export type Application = Schemas["ApplicationOut"];
export type ApplicationCreated = Schemas["ApplicationCreatedOut"];
export type ApplicationCreate = Schemas["ApplicationCreate"];
export type ApplicationUpdate = Schemas["ApplicationUpdate"];
export type LeadCreate = Schemas["LeadCreate"];
export type StatusEvent = Schemas["StatusEventOut"];
export type StatusEventUpdate = Schemas["StatusEventUpdate"];
export type Contact = Schemas["ContactOut"];
export type ContactCreate = Schemas["ContactCreate"];
export type ContactUpdate = Schemas["ContactUpdate"];
export type Interview = Schemas["InterviewOut"];
export type InterviewCreate = Schemas["InterviewCreate"];
export type InterviewUpdate = Schemas["InterviewUpdate"];
export type JobEvent = Schemas["JobEventOut"];
export type JobEventCreate = Schemas["JobEventCreate"];
export type JobEventUpdate = Schemas["JobEventUpdate"];
export type WeeklyGoal = Schemas["WeeklyGoalOut"];
export type GoalMetric = WeeklyGoal["metric"];
export type WeekProgress = Schemas["WeekProgressOut"];
export type Pipeline = Schemas["PipelineOut"];
export type ImportKind = Schemas["JobsImportPreviewOut"]["kind"];
export type ImportPreview = Schemas["JobsImportPreviewOut"];
export type ImportSpec = Schemas["JobsImportSpec"];
export type ImportReport = Schemas["JobsImportReport"];
export type ImportUndo = Schemas["JobsImportUndoOut"];

/** Server table names, for RecordHistoryPanel. */
export const TABLES = {
  applications: "jobs_applications",
  statusEvents: "jobs_application_status_events",
  companies: "jobs_companies",
  contacts: "jobs_contacts",
  interviews: "jobs_interviews",
  events: "jobs_events",
} as const;

export const GOAL_METRICS: { value: GoalMetric; label: string }[] = [
  { value: "applications", label: "Applications" },
  { value: "outreach", label: "Outreach" },
  { value: "leads", label: "Leads" },
  { value: "interviews", label: "Interviews" },
  { value: "events", label: "Events" },
];

export interface ApplicationFilters {
  status?: string[];
  company_id?: number;
  tag?: string;
  leads?: "exclude" | "include" | "only";
  /** Only next actions due on or before this day. */
  due_by?: string;
}

export interface CompanyFilters {
  tag?: string;
  target?: boolean;
}

export interface ContactFilters {
  company_id?: number;
  tag?: string;
  due_by?: string;
}

export interface InterviewFilters {
  application_id?: number;
  upcoming?: boolean;
}

export const jobsKeys = {
  all: ["jobs"] as const,
  statuses: ["jobs", "statuses"] as const,
  tags: ["jobs", "tags"] as const,
  pipeline: ["jobs", "pipeline"] as const,
  goals: ["jobs", "goals"] as const,
  progress: (week: string | null) => ["jobs", "goals", "progress", week ?? "now"] as const,
  applications: (filters: ApplicationFilters) => ["jobs", "applications", filters] as const,
  application: (id: number) => ["jobs", "application", id] as const,
  statusEvents: (id: number) => ["jobs", "application", id, "status"] as const,
  leads: (includeDropped: boolean) => ["jobs", "leads", includeDropped] as const,
  companies: (filters: CompanyFilters) => ["jobs", "companies", filters] as const,
  company: (id: number) => ["jobs", "company", id] as const,
  contacts: (filters: ContactFilters) => ["jobs", "contacts", filters] as const,
  contact: (id: number) => ["jobs", "contact", id] as const,
  interviews: (filters: InterviewFilters) => ["jobs", "interviews", filters] as const,
  interview: (id: number) => ["jobs", "interview", id] as const,
  events: ["jobs", "events"] as const,
  event: (id: number) => ["jobs", "event", id] as const,
};

// ------------------------------------------------------------------------------- queries

export function useStatuses() {
  return useQuery({
    queryKey: jobsKeys.statuses,
    queryFn: () => unwrap(api.GET("/api/jobs/statuses")),
    staleTime: 5 * 60_000,
  });
}

export interface StatusInfo {
  list: JobStatus[];
  label: (key: string) => string;
  kind: (key: string) => StatusKind;
  /** Statuses of the given kinds, in list order, as select options. */
  options: (...kinds: StatusKind[]) => { value: string; label: string }[];
}

/** The configurable status list with lookups. Labels fall back to the key while loading. */
export function useStatusInfo(): StatusInfo {
  const statuses = useStatuses();
  return useMemo(() => {
    const list = statuses.data ?? [];
    const byKey = new Map(list.map((s) => [s.key, s]));
    return {
      list,
      label: (key) => byKey.get(key)?.label ?? key,
      kind: (key) => byKey.get(key)?.kind ?? (key === "lead" ? "lead" : key === "dropped" ? "dropped" : "active"),
      options: (...kinds) =>
        list.filter((s) => kinds.includes(s.kind)).map((s) => ({ value: s.key, label: s.label })),
    };
  }, [statuses.data]);
}

export function useTags() {
  return useQuery({
    queryKey: jobsKeys.tags,
    queryFn: async () => (await unwrap(api.GET("/api/jobs/tags"))).tags,
  });
}

export function usePipeline() {
  return useQuery({
    queryKey: jobsKeys.pipeline,
    queryFn: () => unwrap(api.GET("/api/jobs/pipeline")),
  });
}

export function useGoals() {
  return useQuery({
    queryKey: jobsKeys.goals,
    queryFn: () => unwrap(api.GET("/api/jobs/goals")),
  });
}

export function useGoalProgress(week: string | null) {
  return useQuery({
    queryKey: jobsKeys.progress(week),
    queryFn: () =>
      unwrap(api.GET("/api/jobs/goals/progress", { params: { query: { week: week ?? undefined } } })),
    placeholderData: keepPreviousData,
  });
}

export function useApplications(filters: ApplicationFilters, enabled = true) {
  return useQuery({
    queryKey: jobsKeys.applications(filters),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/applications", {
          params: {
            query: {
              status: filters.status?.length ? filters.status : undefined,
              company_id: filters.company_id,
              tag: filters.tag || undefined,
              leads: filters.leads,
              due_by: filters.due_by,
            },
          },
        }),
      ),
    placeholderData: keepPreviousData,
    enabled,
  });
}

export function useApplication(id: number | null) {
  return useQuery({
    queryKey: jobsKeys.application(id ?? 0),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/applications/{application_id}", {
          params: { path: { application_id: id! } },
        }),
      ),
    enabled: id !== null,
  });
}

export function useStatusEvents(id: number) {
  return useQuery({
    queryKey: jobsKeys.statusEvents(id),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/applications/{application_id}/status", {
          params: { path: { application_id: id } },
        }),
      ),
  });
}

export function useLeads(includeDropped: boolean) {
  return useQuery({
    queryKey: jobsKeys.leads(includeDropped),
    queryFn: () =>
      unwrap(api.GET("/api/jobs/leads", { params: { query: { include_dropped: includeDropped } } })),
    placeholderData: keepPreviousData,
  });
}

export function useCompanies(filters: CompanyFilters = {}) {
  return useQuery({
    queryKey: jobsKeys.companies(filters),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/companies", {
          params: { query: { tag: filters.tag || undefined, target: filters.target } },
        }),
      ),
    placeholderData: keepPreviousData,
  });
}

export function useCompany(id: number) {
  return useQuery({
    queryKey: jobsKeys.company(id),
    queryFn: () =>
      unwrap(api.GET("/api/jobs/companies/{company_id}", { params: { path: { company_id: id } } })),
  });
}

export function useContacts(filters: ContactFilters = {}) {
  return useQuery({
    queryKey: jobsKeys.contacts(filters),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/contacts", {
          params: {
            query: {
              company_id: filters.company_id,
              tag: filters.tag || undefined,
              due_by: filters.due_by,
            },
          },
        }),
      ),
    placeholderData: keepPreviousData,
  });
}

export function useContact(id: number | null) {
  return useQuery({
    queryKey: jobsKeys.contact(id ?? 0),
    queryFn: () =>
      unwrap(api.GET("/api/jobs/contacts/{contact_id}", { params: { path: { contact_id: id! } } })),
    enabled: id !== null,
  });
}

export function useInterviews(filters: InterviewFilters = {}) {
  return useQuery({
    queryKey: jobsKeys.interviews(filters),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/interviews", {
          params: {
            query: { application_id: filters.application_id, upcoming: filters.upcoming },
          },
        }),
      ),
  });
}

export function useInterview(id: number | null) {
  return useQuery({
    queryKey: jobsKeys.interview(id ?? 0),
    queryFn: () =>
      unwrap(
        api.GET("/api/jobs/interviews/{interview_id}", {
          params: { path: { interview_id: id! } },
        }),
      ),
    enabled: id !== null,
  });
}

export function useEvents() {
  return useQuery({
    queryKey: jobsKeys.events,
    queryFn: () => unwrap(api.GET("/api/jobs/events")),
  });
}

export function useEvent(id: number | null) {
  return useQuery({
    queryKey: jobsKeys.event(id ?? 0),
    queryFn: () =>
      unwrap(api.GET("/api/jobs/events/{event_id}", { params: { path: { event_id: id! } } })),
    enabled: id !== null,
  });
}

// ------------------------------------------------------------------------------- writes

/** Refresh everything a job write can change: job data, the calendar and history panels. */
export function useInvalidateJobs() {
  const queryClient = useQueryClient();
  return useCallback(() => {
    void queryClient.invalidateQueries({ queryKey: jobsKeys.all });
    void queryClient.invalidateQueries({ queryKey: ["calendar"] });
    void queryClient.invalidateQueries({ queryKey: ["history"] });
  }, [queryClient]);
}

/** A job write that refreshes job data, the calendar and history when it succeeds. */
export function useJobsMutation<V, R>(write: (vars: V) => Promise<R>) {
  const invalidate = useInvalidateJobs();
  return useMutation({ mutationFn: write, onSuccess: () => invalidate() });
}

/**
 * Plain calls, one per write route. Wrap them in `useJobsMutation` (or call
 * `useInvalidateJobs()` afterwards) so the views refresh.
 */
export const jobsApi = {
  // statuses
  addStatus: (body: Schemas["JobStatusCreate"]) =>
    unwrap(api.POST("/api/jobs/statuses", { body })),
  updateStatusDef: (key: string, body: Schemas["JobStatusUpdate"]) =>
    unwrap(api.PATCH("/api/jobs/statuses/{key}", { params: { path: { key } }, body })),
  reorderStatuses: (keys: string[]) =>
    unwrap(api.PUT("/api/jobs/statuses/order", { body: { keys } })),
  removeStatusDef: (key: string) =>
    unwrap(api.DELETE("/api/jobs/statuses/{key}", { params: { path: { key } } })),

  // companies
  createCompany: (body: Schemas["CompanyCreate"]) =>
    unwrap(api.POST("/api/jobs/companies", { body })),
  updateCompany: (id: number, body: CompanyUpdate) =>
    unwrap(
      api.PATCH("/api/jobs/companies/{company_id}", { params: { path: { company_id: id } }, body }),
    ),
  deleteCompany: (id: number) =>
    unwrap(api.DELETE("/api/jobs/companies/{company_id}", { params: { path: { company_id: id } } })),

  // applications and leads
  createApplication: (body: ApplicationCreate) =>
    unwrap(api.POST("/api/jobs/applications", { body })),
  updateApplication: (id: number, body: ApplicationUpdate) =>
    unwrap(
      api.PATCH("/api/jobs/applications/{application_id}", {
        params: { path: { application_id: id } },
        body,
      }),
    ),
  deleteApplication: (id: number) =>
    unwrap(
      api.DELETE("/api/jobs/applications/{application_id}", {
        params: { path: { application_id: id } },
      }),
    ),
  addStatusEvent: (id: number, body: Schemas["JobStatusChange"]) =>
    unwrap(
      api.POST("/api/jobs/applications/{application_id}/status", {
        params: { path: { application_id: id } },
        body,
      }),
    ),
  applyLead: (id: number, body: Schemas["JobApplyIn"]) =>
    unwrap(
      api.POST("/api/jobs/applications/{application_id}/apply", {
        params: { path: { application_id: id } },
        body,
      }),
    ),
  dropLead: (id: number, reason: string) =>
    unwrap(
      api.POST("/api/jobs/applications/{application_id}/drop", {
        params: { path: { application_id: id } },
        body: { reason },
      }),
    ),
  updateStatusEvent: (id: number, body: StatusEventUpdate) =>
    unwrap(api.PATCH("/api/jobs/status-events/{event_id}", { params: { path: { event_id: id } }, body })),
  deleteStatusEvent: (id: number) =>
    unwrap(api.DELETE("/api/jobs/status-events/{event_id}", { params: { path: { event_id: id } } })),
  createLead: (body: LeadCreate) => unwrap(api.POST("/api/jobs/leads", { body })),

  // contacts
  createContact: (body: ContactCreate) => unwrap(api.POST("/api/jobs/contacts", { body })),
  updateContact: (id: number, body: ContactUpdate) =>
    unwrap(
      api.PATCH("/api/jobs/contacts/{contact_id}", { params: { path: { contact_id: id } }, body }),
    ),
  deleteContact: (id: number) =>
    unwrap(api.DELETE("/api/jobs/contacts/{contact_id}", { params: { path: { contact_id: id } } })),

  // interviews
  createInterview: (body: InterviewCreate) => unwrap(api.POST("/api/jobs/interviews", { body })),
  updateInterview: (id: number, body: InterviewUpdate) =>
    unwrap(
      api.PATCH("/api/jobs/interviews/{interview_id}", {
        params: { path: { interview_id: id } },
        body,
      }),
    ),
  deleteInterview: (id: number) =>
    unwrap(
      api.DELETE("/api/jobs/interviews/{interview_id}", { params: { path: { interview_id: id } } }),
    ),

  // events
  createEvent: (body: JobEventCreate) => unwrap(api.POST("/api/jobs/events", { body })),
  updateEvent: (id: number, body: JobEventUpdate) =>
    unwrap(api.PATCH("/api/jobs/events/{event_id}", { params: { path: { event_id: id } }, body })),
  deleteEvent: (id: number) =>
    unwrap(api.DELETE("/api/jobs/events/{event_id}", { params: { path: { event_id: id } } })),

  // goals
  createGoal: (body: Schemas["WeeklyGoalCreate"]) => unwrap(api.POST("/api/jobs/goals", { body })),
  updateGoal: (id: number, target: number) =>
    unwrap(api.PATCH("/api/jobs/goals/{goal_id}", { params: { path: { goal_id: id } }, body: { target } })),
  deleteGoal: (id: number) =>
    unwrap(api.DELETE("/api/jobs/goals/{goal_id}", { params: { path: { goal_id: id } } })),

  // import (preview and dry run write nothing)
  importPreview: (body: Schemas["JobsImportPreviewIn"]) =>
    unwrap(api.POST("/api/jobs/import/preview", { body })),
  importDryRun: (body: ImportSpec) => unwrap(api.POST("/api/jobs/import/dry-run", { body })),
  importCommit: (body: ImportSpec) => unwrap(api.POST("/api/jobs/import/commit", { body })),
  importUndo: (batchId: string) =>
    unwrap(api.POST("/api/jobs/import/undo", { body: { batch_id: batchId } })),
};
