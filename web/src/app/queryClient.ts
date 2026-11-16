import { QueryClient } from "@tanstack/react-query";

import { ApiError, setUnauthorizedHandler } from "@/api/client";

import { authStateKey } from "./auth";

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: true,
      // Client errors (4xx) will not fix themselves on retry.
      retry: (count, error) =>
        !(error instanceof ApiError && error.status >= 400 && error.status < 500) && count < 2,
    },
  },
});

// A 401 outside /api/auth/ means the session is gone: re-ask who is signed in, which brings
// back the login page.
setUnauthorizedHandler(() => {
  void queryClient.invalidateQueries({ queryKey: authStateKey });
});
