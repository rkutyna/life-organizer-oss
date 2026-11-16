/**
 * Typed API client. Paths, params and bodies are checked against `schema.d.ts`, which is
 * generated from the server (`npm run gen:api` with the server on :8600). Never edit it.
 *
 *   const items = await unwrap(api.GET("/api/calendar", { params: { query: { start, end } } }));
 *   await unwrap(api.PATCH("/api/settings", { body: { display_name: "Sam" } }));
 *
 * Auth: the browser sends the session cookie (`credentials: "same-origin"`). Every request also
 * carries `X-Requested-With: organizer`, which the server's CSRF guard requires on cookie-
 * authenticated writes. The server takes the author of a write from the credential, so the UI
 * never says who it is.
 *
 * `unwrap` turns an error response into a thrown `ApiError` (TanStack Query then shows it as a
 * query/mutation error). A 401 from anything outside `/api/auth/` means the session ended: the
 * handler set with `setUnauthorizedHandler` runs (the app invalidates the auth state, which
 * brings back the login screen).
 */

import createClient, { type Middleware } from "openapi-fetch";

import type { components, paths } from "./schema";

export const api = createClient<paths>({
  baseUrl: "",
  credentials: "same-origin",
  headers: { "X-Requested-With": "organizer" },
});

let onUnauthorized: (() => void) | null = null;

/** Set once by the app: what to do when a request outside `/api/auth/` comes back 401. */
export function setUnauthorizedHandler(handler: (() => void) | null): void {
  onUnauthorized = handler;
}

const sessionGuard: Middleware = {
  onResponse({ schemaPath, response }) {
    if (response.status === 401 && !schemaPath.startsWith("/api/auth/")) onUnauthorized?.();
    return undefined;
  },
};
api.use(sessionGuard);

export type Schemas = components["schemas"];

// Shared shapes, re-exported under short names.
export type CalendarItem = Schemas["CalendarItem"];
export type CalendarSource = Schemas["CalendarSourceOut"];
export type SourceStatus = Schemas["SourceStatusOut"];
export type Change = Schemas["ChangeOut"];
export type AuthState = Schemas["AuthState"];

export class ApiError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/** Await an openapi-fetch call and return its data, or throw an ApiError. */
export async function unwrap<T>(
  request: Promise<{ data?: T; error?: unknown; response: Response }>,
): Promise<T> {
  const { data, error, response } = await request;
  if (error !== undefined || !response.ok) {
    throw new ApiError(response.status, errorMessage(error, response));
  }
  return data as T;
}

/** FastAPI errors are `{detail: string}` or `{detail: [{loc, msg}]}` (validation). */
function errorMessage(error: unknown, response: Response): string {
  if (error && typeof error === "object" && "detail" in error) {
    const detail = (error as { detail: unknown }).detail;
    if (typeof detail === "string") return detail;
    if (Array.isArray(detail)) {
      return detail
        .map((d: { loc?: unknown[]; msg?: string }) => {
          const field = d.loc?.filter((part) => part !== "body").join(".");
          return field ? `${field}: ${d.msg}` : (d.msg ?? "invalid");
        })
        .join("; ");
    }
  }
  return `${response.status} ${response.statusText || "request failed"}`;
}
