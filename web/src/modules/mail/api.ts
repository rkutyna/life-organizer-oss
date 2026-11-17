import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { api, unwrap, type Schemas } from "@/api/client";

export type MailAccount = Schemas["MailAccountOut"];
export type MailMessage = Schemas["MailMessageOut"];
export type MailMessageDetail = Schemas["MailMessageDetail"];
export type MailImapPreset = Schemas["MailImapPreset"];
export type MailImapConnect = Schemas["MailImapConnect"];
export type MailFolder = "inbox" | "sent";

export interface MailFilters {
  account?: number;
  folder?: MailFolder;
  q?: string;
}

export const mailKeys = {
  all: ["mail"] as const,
  messages: (filters: MailFilters) => ["mail", "messages", filters] as const,
  message: (id: number) => ["mail", "message", id] as const,
  presets: ["mail", "presets"] as const,
};

/** Mirrored headers, newest first. Reads the organizer's mirror only, never a mailbox. */
export function useMailMessages(filters: MailFilters) {
  return useQuery({
    queryKey: mailKeys.messages(filters),
    queryFn: () =>
      unwrap(
        api.GET("/api/mail/messages", {
          params: {
            query: {
              account: filters.account,
              folder: filters.folder,
              q: filters.q || undefined,
              limit: 200,
            },
          },
        }),
      ),
    placeholderData: keepPreviousData,
    refetchInterval: 5 * 60_000,
  });
}

/**
 * One message, fetched live from its mailbox and cleaned by the server. Bodies are never
 * stored by the server, and the browser drops them a few minutes after the reader closes.
 */
export function useMailMessage(id: number | null) {
  return useQuery({
    queryKey: mailKeys.message(id ?? 0),
    queryFn: () =>
      unwrap(api.GET("/api/mail/messages/{message_id}", { params: { path: { message_id: id! } } })),
    enabled: id !== null,
    staleTime: 5 * 60_000,
    gcTime: 5 * 60_000,
    retry: false,
  });
}

export function useSyncMailAccount() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (accountId: number) =>
      unwrap(
        api.POST("/api/mail/accounts/{account_id}/sync", {
          params: { path: { account_id: accountId } },
        }),
      ),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: mailKeys.all });
      void queryClient.invalidateQueries({ queryKey: ["status"] });
    },
  });
}

export function useImapPresets() {
  return useQuery({
    queryKey: mailKeys.presets,
    queryFn: () => unwrap(api.GET("/api/mail/imap-presets")),
    staleTime: Infinity,
  });
}

export function useConnectImap() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: MailImapConnect) => unwrap(api.POST("/api/mail/accounts/imap", { body })),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: mailKeys.all });
      void queryClient.invalidateQueries({ queryKey: ["settings", "accounts"] });
      void queryClient.invalidateQueries({ queryKey: ["status"] });
    },
  });
}
