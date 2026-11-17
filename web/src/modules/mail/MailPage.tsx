import { format, isThisYear, isToday, parseISO } from "date-fns";
import { AlertTriangle, Inbox, Mail, RefreshCw, Search, Send } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { toast } from "sonner";

import { statusColor } from "@/app/tokens";
import { EmptyState } from "@/components/EmptyState";
import { NativeSelect } from "@/components/Field";
import { PageHeader } from "@/components/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { formatAge, formatTimestamp } from "@/lib/dates";
import { useHotkeys } from "@/lib/hotkeys";
import { cn, sentence } from "@/lib/utils";

import {
  useMailMessages,
  useSyncMailAccount,
  type MailAccount,
  type MailFolder,
  type MailMessage,
} from "./api";
import { MailReader } from "./MailReader";

/** "3:05 PM" today, "Nov 10" this year, "Nov 10, 2025" before. */
export function listDate(iso: string): string {
  const date = parseISO(iso);
  if (isToday(date)) return format(date, "p");
  return isThisYear(date) ? format(date, "MMM d") : format(date, "MMM d, yyyy");
}

function who(message: MailMessage, folder: MailFolder): string {
  if (folder === "sent") {
    const first = message.to[0];
    const rest = message.to.length > 1 ? ` +${message.to.length - 1}` : "";
    return first ? `To: ${first.name || first.address}${rest}` : "To: (nobody)";
  }
  return message.from.name || message.from.address || "(no sender)";
}

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), ms);
    return () => window.clearTimeout(timer);
  }, [value, ms]);
  return debounced;
}

/**
 * The read-only inbox: mirrored headers on the left, the open message on the right (alone on a
 * phone). Filters live in the URL (?account=&folder=&q=&m=), so a view can be bookmarked.
 * Nothing here can change mail; the only write is "sync now", which refreshes the mirror.
 */
export default function MailPage() {
  const [params, setParams] = useSearchParams();
  const folder: MailFolder = params.get("folder") === "sent" ? "sent" : "inbox";
  const accountParam = params.get("account");
  const account = accountParam ? Number(accountParam) : undefined;
  const openId = params.get("m") ? Number(params.get("m")) : null;
  const [search, setSearch] = useState(params.get("q") ?? "");
  const q = useDebounced(search.trim(), 250);
  const searchRef = useRef<HTMLInputElement>(null);

  const messages = useMailMessages({ account, folder, q });
  const sync = useSyncMailAccount();
  const list = useMemo(() => messages.data?.messages ?? [], [messages.data]);
  const accounts = messages.data?.accounts ?? [];
  const accountById = useMemo(() => new Map(accounts.map((a) => [a.id, a])), [accounts]);

  function update(changes: Record<string, string | null>) {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(changes)) {
      if (value === null || value === "") next.delete(key);
      else next.set(key, value);
    }
    setParams(next, { replace: true });
  }

  useEffect(() => {
    if ((params.get("q") ?? "") !== q) update({ q: q || null });
  }, [q]);

  function open(id: number | null) {
    update({ m: id === null ? null : String(id) });
  }

  function step(delta: number) {
    if (list.length === 0) return;
    const index = list.findIndex((m) => m.id === openId);
    const next = index === -1 ? 0 : Math.min(list.length - 1, Math.max(0, index + delta));
    open(list[next].id);
    document.getElementById(`mail-row-${list[next].id}`)?.scrollIntoView({ block: "nearest" });
  }

  useHotkeys({
    j: () => step(1),
    k: () => step(-1),
    "/": (event) => {
      event.preventDefault();
      searchRef.current?.focus();
    },
    Escape: () => {
      if (document.activeElement === searchRef.current) searchRef.current?.blur();
      else open(null);
    },
  });

  async function syncShown() {
    const targets = account !== undefined ? accounts.filter((a) => a.id === account) : accounts;
    const results = await Promise.allSettled(targets.map((a) => sync.mutateAsync(a.id)));
    const failed = results.filter((r) => r.status === "rejected").length;
    if (failed) toast.error(`${failed} account${failed === 1 ? "" : "s"} could not be read`);
    else toast.success("Mail headers are up to date");
  }

  const noAccounts = messages.isSuccess && accounts.length === 0;

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader
        title="Mail"
        subtitle={<AccountsFreshness accounts={accounts} />}
        actions={
          accounts.length > 0 && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => void syncShown()}
              disabled={sync.isPending}
              title="Read new headers from the mailbox now"
            >
              <RefreshCw className={cn("size-3.5", sync.isPending && "animate-spin")} />
              <span className="hidden sm:inline">Sync now</span>
            </Button>
          )
        }
      >
        {!noAccounts && (
          <div className="flex flex-wrap items-center gap-2">
            <div className="inline-flex rounded-md border border-border p-0.5" role="tablist">
              {(["inbox", "sent"] as const).map((f) => (
                <button
                  key={f}
                  type="button"
                  role="tab"
                  aria-selected={folder === f}
                  onClick={() => update({ folder: f === "inbox" ? null : f, m: null })}
                  className={cn(
                    "inline-flex h-7 items-center gap-1.5 rounded px-2.5 text-[13px]",
                    folder === f ? "bg-accent font-medium" : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  {f === "inbox" ? <Inbox className="size-3.5" /> : <Send className="size-3.5" />}
                  {f === "inbox" ? "Inbox" : "Sent"}
                </button>
              ))}
            </div>
            <NativeSelect
              aria-label="Account"
              value={account ?? ""}
              onChange={(e) => update({ account: e.target.value || null, m: null })}
            >
              <option value="">All accounts</option>
              {accounts.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.label}
                </option>
              ))}
            </NativeSelect>
            <div className="relative min-w-48 flex-1 sm:max-w-80">
              <Search className="pointer-events-none absolute top-1/2 left-2 size-3.5 -translate-y-1/2 text-muted-foreground" />
              <Input
                ref={searchRef}
                type="search"
                aria-label="Search subjects, senders and recipients"
                placeholder="Search subjects, senders, recipients"
                className="h-8 pl-7 text-[13px]"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
          </div>
        )}
      </PageHeader>

      {noAccounts ? (
        <EmptyState
          icon={Mail}
          title="No mail accounts yet"
          description="Connect an IMAP account (iCloud, Fastmail, Outlook) or a Google account with Gmail. Mail is only read: nothing in your mailbox is ever changed."
          action={
            <Button asChild size="sm" variant="outline">
              <Link to="/settings#accounts">Add an account in Settings</Link>
            </Button>
          }
        />
      ) : (
        <div className="flex min-h-0 flex-1">
          <section
            aria-label={folder === "inbox" ? "Inbox" : "Sent"}
            className={cn(
              "min-h-0 w-full overflow-y-auto border-border md:w-[24rem] md:shrink-0 md:border-r lg:w-[28rem]",
              openId !== null && "hidden md:block",
            )}
          >
            {messages.isPending ? (
              <div className="grid gap-2 p-4">
                {Array.from({ length: 8 }, (_, i) => (
                  <Skeleton key={i} className="h-12 w-full" />
                ))}
              </div>
            ) : messages.isError ? (
              <p role="alert" className="p-4 text-[13px] text-status-error">
                {sentence(messages.error.message)}
              </p>
            ) : list.length === 0 ? (
              <EmptyState
                title={q ? "No headers match" : folder === "inbox" ? "Inbox is empty" : "Nothing sent"}
                description={
                  q
                    ? "Search looks at subjects, names and addresses of the mirrored headers."
                    : "Only the recent window of mail is mirrored."
                }
              />
            ) : (
              <ul className="divide-y divide-border">
                {list.map((message) => (
                  <MessageRow
                    key={message.id}
                    message={message}
                    folder={folder}
                    selected={message.id === openId}
                    account={accounts.length > 1 ? accountById.get(message.account) : undefined}
                    onOpen={() => open(message.id)}
                  />
                ))}
              </ul>
            )}
          </section>
          <section
            aria-label="Message"
            className={cn("min-h-0 min-w-0 flex-1 overflow-y-auto", openId === null && "hidden md:block")}
          >
            {openId === null ? (
              <EmptyState
                icon={Mail}
                className="h-full"
                title="No message open"
                description="Opening one fetches it from the mailbox and cleans it. It isn't marked as read, and its body is never stored."
              />
            ) : (
              <MailReader
                id={openId}
                account={(() => {
                  const message = list.find((m) => m.id === openId);
                  return message ? accountById.get(message.account) : undefined;
                })()}
                onClose={() => open(null)}
              />
            )}
          </section>
        </div>
      )}
    </div>
  );
}

function MessageRow({
  message,
  folder,
  selected,
  account,
  onOpen,
}: {
  message: MailMessage;
  folder: MailFolder;
  selected: boolean;
  account?: MailAccount;
  onOpen: () => void;
}) {
  return (
    <li>
      <button
        id={`mail-row-${message.id}`}
        type="button"
        onClick={onOpen}
        aria-current={selected || undefined}
        className={cn(
          "grid w-full gap-0.5 px-4 py-2.5 text-left hover:bg-accent/60 focus-visible:bg-accent focus-visible:outline-none",
          selected && "bg-accent",
        )}
      >
        <span className="flex items-baseline gap-2">
          <span className="min-w-0 flex-1 truncate text-[13px] font-medium">
            {who(message, folder)}
          </span>
          {message.sender_warning && (
            <AlertTriangle
              className="size-3.5 shrink-0 self-center text-status-stale"
              aria-label="The sender shown may not be real"
            />
          )}
          <time className="shrink-0 text-xs text-muted-foreground tabular" dateTime={message.date}>
            {listDate(message.date)}
          </time>
        </span>
        <span className="truncate text-[13px] text-muted-foreground">
          {message.subject || "(no subject)"}
        </span>
        {account && <span className="truncate text-[11px] text-muted-foreground/80">{account.label}</span>}
      </button>
    </li>
  );
}

/** One dot per account, colored by its mirror's freshness; the tooltip says how old it is. */
function AccountsFreshness({ accounts }: { accounts: MailAccount[] }) {
  if (accounts.length === 0) return null;
  return (
    <span className="inline-flex items-center gap-1.5">
      {accounts.map((a) => (
        <Tooltip key={a.id}>
          <TooltipTrigger asChild>
            <span
              className="inline-flex items-center gap-1 text-xs"
              aria-label={`${a.label}: ${a.state}`}
            >
              <span className="size-1.5 rounded-full" style={{ background: statusColor(a.state) }} />
              <span className="hidden lg:inline">{a.label}</span>
            </span>
          </TooltipTrigger>
          <TooltipContent className="max-w-72 text-xs">
            <p className="font-medium">
              {a.label} ({a.address})
            </p>
            <p>
              Headers synced {formatAge(a.as_of)}
              {a.as_of ? ` (${formatTimestamp(a.as_of)})` : ""}
            </p>
            {a.state === "error" && a.error && <p className="text-status-error">{sentence(a.error)}</p>}
          </TooltipContent>
        </Tooltip>
      ))}
    </span>
  );
}
