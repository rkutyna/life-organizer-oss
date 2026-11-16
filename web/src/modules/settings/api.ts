import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { api, unwrap, type Schemas } from "@/api/client";
import { authStateKey } from "@/app/auth";

export type AppSettings = Schemas["AppSettingsOut"];
export type ApiToken = Schemas["ApiTokenOut"];
export type ApiTokenCreate = Schemas["ApiTokenCreate"];
export type ProviderAccount = Schemas["ProviderAccountOut"];

/** Calendar queries live under ["calendar"] (any module that changes the calendar invalidates it). */
const CALENDAR_KEY = ["calendar"] as const;

export const settingsKeys = {
  settings: ["settings", "app"] as const,
  tokens: ["settings", "tokens"] as const,
  accounts: ["settings", "accounts"] as const,
};

export function useAppSettings() {
  return useQuery({
    queryKey: settingsKeys.settings,
    queryFn: () => unwrap(api.GET("/api/settings")),
  });
}

export function useUpdateSettings() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["AppSettingsUpdate"]) => unwrap(api.PATCH("/api/settings", { body })),
    onSuccess: (settings) => {
      queryClient.setQueryData(settingsKeys.settings, settings);
      // The display name shows on the login page; holidays and the time zone shape the calendar.
      void queryClient.invalidateQueries({ queryKey: authStateKey });
      void queryClient.invalidateQueries({ queryKey: CALENDAR_KEY });
      void queryClient.invalidateQueries({ queryKey: ["status"] });
    },
  });
}

export function useChangePassword() {
  return useMutation({
    mutationFn: (body: { current_password: string; new_password: string }) =>
      unwrap(api.POST("/api/auth/password", { body })),
  });
}

export function useTokens() {
  return useQuery({
    queryKey: settingsKeys.tokens,
    queryFn: () => unwrap(api.GET("/api/settings/tokens")),
  });
}

export function useCreateToken() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: ApiTokenCreate) => unwrap(api.POST("/api/settings/tokens", { body })),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: settingsKeys.tokens }),
  });
}

export function useRevokeToken() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (tokenId: number) =>
      unwrap(api.DELETE("/api/settings/tokens/{token_id}", { params: { path: { token_id: tokenId } } })),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: settingsKeys.tokens }),
  });
}

export function useAccounts() {
  return useQuery({
    queryKey: settingsKeys.accounts,
    queryFn: () => unwrap(api.GET("/api/settings/accounts")),
  });
}

/** After any account change: the list, the calendar and the freshness strip can all move. */
function useAccountChanged() {
  const queryClient = useQueryClient();
  return () => {
    void queryClient.invalidateQueries({ queryKey: settingsKeys.accounts });
    void queryClient.invalidateQueries({ queryKey: CALENDAR_KEY });
    void queryClient.invalidateQueries({ queryKey: ["status"] });
  };
}

export function useUpdateAccount() {
  const changed = useAccountChanged();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: number; label?: string; enabled?: boolean }) =>
      unwrap(
        api.PATCH("/api/settings/accounts/{account_id}", {
          params: { path: { account_id: id } },
          body,
        }),
      ),
    onSuccess: changed,
  });
}

export function useDeleteAccount() {
  const changed = useAccountChanged();
  return useMutation({
    mutationFn: (id: number) =>
      unwrap(
        api.DELETE("/api/settings/accounts/{account_id}", { params: { path: { account_id: id } } }),
      ),
    onSuccess: changed,
  });
}
