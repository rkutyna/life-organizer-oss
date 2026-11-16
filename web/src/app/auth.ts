/**
 * Who is signed in. `GET /api/auth/state` decides what the app renders (src/app/App.tsx):
 * the setup page on a fresh install, the login page without a session, else the shell.
 *
 * Any 401 from a non-auth endpoint invalidates this query (registered in queryClient.ts), so an
 * expired session falls back to the login page on its own.
 */

import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";

import { api, unwrap, type AuthState } from "@/api/client";

export const authStateKey = ["auth", "state"] as const;

/** Passwords shorter than this are refused by the server. */
export const MIN_PASSWORD_LENGTH = 10;

export function useAuthState() {
  return useQuery({
    queryKey: authStateKey,
    queryFn: () => unwrap(api.GET("/api/auth/state")),
  });
}

/** After a successful setup or login: store the new state, which swaps the screen. */
function signedIn(queryClient: QueryClient, state: AuthState) {
  queryClient.setQueryData(authStateKey, state);
}

export function useSetup() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      display_name: string;
      password: string;
      timezone: string;
      holiday_country: string | null;
    }) => unwrap(api.POST("/api/auth/setup", { body })),
    onSuccess: (state) => signedIn(queryClient, state),
  });
}

export function useLogin() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (password: string) => unwrap(api.POST("/api/auth/login", { body: { password } })),
    onSuccess: (state) => signedIn(queryClient, state),
  });
}

/** Ends the session and drops every cached response, so nothing outlives the sign-out. */
export function useSignOut() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/api/auth/logout")),
    onSettled: () => {
      queryClient.setQueryData<AuthState>(authStateKey, {
        setup_required: false,
        authenticated: false,
        display_name: null,
      });
      queryClient.removeQueries({ predicate: (query) => query.queryKey[0] !== "auth" });
    },
  });
}
