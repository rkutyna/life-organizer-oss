import { Check, Copy, Plus, TriangleAlert } from "lucide-react";
import { useRef, useState, type FormEvent } from "react";
import { toast } from "sonner";

import { EmptyState } from "@/components/EmptyState";
import { NativeSelect } from "@/components/Field";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { formatAge, formatTimestamp } from "@/lib/dates";
import { cn } from "@/lib/utils";

import { useCreateToken, useRevokeToken, useTokens, type ApiToken, type ApiTokenCreate } from "./api";
import { AUTHOR_OPTIONS, authorLabel, SCOPE_OPTIONS } from "./labels";
import { FormError, Section } from "./Section";

/** API tokens: one per client (MCP server, Mac helper, scripts). Secrets are shown once. */
export function TokensSection() {
  const tokens = useTokens();
  const revoke = useRevokeToken();
  const [creating, setCreating] = useState(false);
  const [toRevoke, setToRevoke] = useState<ApiToken | null>(null);

  const list = tokens.data ?? [];
  // Active tokens first, newest first within each group.
  const sorted = [...list].sort(
    (a, b) =>
      Number(a.revoked_at !== null) - Number(b.revoked_at !== null) ||
      b.created_at.localeCompare(a.created_at),
  );

  return (
    <Section
      id="tokens"
      title="API tokens"
      description="Give each client its own token: the MCP server, the Mac helper, a script. Revoke one and only that client loses access."
      actions={
        <Button size="sm" variant="outline" onClick={() => setCreating(true)}>
          <Plus />
          New token
        </Button>
      }
    >
      {tokens.isPending ? (
        <div className="space-y-2">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
        </div>
      ) : tokens.isError ? (
        <FormError message={`Could not load tokens: ${tokens.error.message}`} />
      ) : sorted.length === 0 ? (
        <EmptyState
          title="No tokens yet"
          description="Make one when you connect Claude or the Mac helper."
          className="py-6"
        />
      ) : (
        <div className="-mx-4 overflow-x-auto md:-mx-5 scrollbar-thin">
          <table className="w-full min-w-[40rem] text-[13px]">
            <thead>
              <tr className="border-b border-border text-left text-xs text-muted-foreground">
                <th className="py-1.5 pr-3 pl-4 font-medium md:pl-5">Name</th>
                <th className="px-3 py-1.5 font-medium">Author</th>
                <th className="px-3 py-1.5 font-medium">Scopes</th>
                <th className="px-3 py-1.5 font-medium">Prefix</th>
                <th className="px-3 py-1.5 font-medium">Created</th>
                <th className="px-3 py-1.5 font-medium">Last used</th>
                <th className="py-1.5 pr-4 pl-3 md:pr-5">
                  <span className="sr-only">Status</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((token) => {
                const revoked = token.revoked_at !== null;
                return (
                  <tr
                    key={token.id}
                    className={cn(
                      "border-b border-border last:border-b-0",
                      revoked && "text-muted-foreground",
                    )}
                  >
                    <td className="max-w-48 truncate py-2 pr-3 pl-4 font-medium md:pl-5">
                      {token.name}
                    </td>
                    <td className="px-3 py-2">{authorLabel(token.author)}</td>
                    <td className="px-3 py-2">
                      <span className="flex flex-wrap gap-1">
                        {token.scopes.map((scope) => (
                          <Badge key={scope} variant="outline" className="font-normal">
                            {scope}
                          </Badge>
                        ))}
                      </span>
                    </td>
                    <td className="px-3 py-2 font-mono text-[12px]">{token.prefix}…</td>
                    <td className="px-3 py-2 whitespace-nowrap">
                      <span title={formatTimestamp(token.created_at)}>
                        {formatAge(token.created_at)}
                      </span>
                    </td>
                    <td className="px-3 py-2 whitespace-nowrap">
                      {token.last_used_at ? (
                        <span title={formatTimestamp(token.last_used_at)}>
                          {formatAge(token.last_used_at)}
                        </span>
                      ) : (
                        <span className="text-muted-foreground">never</span>
                      )}
                    </td>
                    <td className="py-2 pr-4 pl-3 text-right whitespace-nowrap md:pr-5">
                      {revoked ? (
                        <span className="text-xs" title={formatTimestamp(token.revoked_at!)}>
                          Revoked {formatAge(token.revoked_at)}
                        </span>
                      ) : (
                        <Button
                          variant="ghost"
                          size="xs"
                          className="text-destructive hover:text-destructive"
                          onClick={() => setToRevoke(token)}
                        >
                          Revoke
                        </Button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <CreateTokenDialog open={creating} onOpenChange={setCreating} />

      <ConfirmDialog
        open={toRevoke !== null}
        onOpenChange={(open) => !open && setToRevoke(null)}
        title={`Revoke "${toRevoke?.name ?? ""}"?`}
        description="Any client using this token stops working at once. This can't be undone; make a new token to reconnect it."
        confirmLabel="Revoke"
        pending={revoke.isPending}
        onConfirm={() =>
          toRevoke &&
          revoke.mutate(toRevoke.id, {
            onSuccess: () => {
              toast.success("Token revoked");
              setToRevoke(null);
            },
            onError: (err) => toast.error(`Could not revoke: ${err.message}`),
          })
        }
      />
    </Section>
  );
}

type Author = ApiTokenCreate["author"];
type Scope = ApiTokenCreate["scopes"][number];

/** The create form, then the one-time reveal of the secret. */
function CreateTokenDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const create = useCreateToken();
  const [name, setName] = useState("");
  const [author, setAuthor] = useState<Author>("claude");
  const [scopes, setScopes] = useState<Scope[]>(["api"]);
  const [error, setError] = useState<string | null>(null);
  const [secret, setSecret] = useState<string | null>(null);

  function reset() {
    setName("");
    setAuthor("claude");
    setScopes(["api"]);
    setError(null);
    setSecret(null);
    create.reset();
  }

  function close(next: boolean) {
    onOpenChange(next);
    if (!next) reset();
  }

  function toggleScope(scope: Scope, on: boolean) {
    setScopes((prev) => (on ? [...prev, scope] : prev.filter((s) => s !== scope)));
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!name.trim()) return setError("Give the token a name, such as the client that will use it.");
    if (scopes.length === 0) return setError("Choose at least one scope.");
    create.mutate(
      { name: name.trim(), author, scopes },
      {
        onSuccess: (created) => setSecret(created.secret),
        onError: (err) => setError(err.message),
      },
    );
  }

  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogContent
        className="sm:max-w-md"
        // The secret must not vanish on a stray click or Escape.
        onInteractOutside={(event) => secret && event.preventDefault()}
        onEscapeKeyDown={(event) => secret && event.preventDefault()}
      >
        {secret ? (
          <SecretReveal secret={secret} onDone={() => close(false)} />
        ) : (
          <form onSubmit={submit} className="grid gap-4">
            <DialogHeader>
              <DialogTitle className="text-base">New API token</DialogTitle>
              <DialogDescription className="text-[13px]">
                Writes made with the token are logged under its author.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-1.5">
              <label htmlFor="token-name" className="text-[13px] font-medium">
                Name
              </label>
              <Input
                id="token-name"
                autoFocus
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g. Claude Desktop on my laptop"
              />
            </div>
            <div className="grid gap-1.5">
              <label htmlFor="token-author" className="text-[13px] font-medium">
                Author
              </label>
              <NativeSelect
                id="token-author"
                value={author}
                onChange={(e) => setAuthor(e.target.value as Author)}
                className="h-9 text-sm"
              >
                {AUTHOR_OPTIONS.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}: {option.hint}
                  </option>
                ))}
              </NativeSelect>
            </div>
            <fieldset className="grid gap-2">
              <legend className="mb-1.5 text-[13px] font-medium">Scopes</legend>
              {SCOPE_OPTIONS.map((option) => (
                <label key={option.value} className="flex items-start gap-2.5 text-[13px]">
                  <Checkbox
                    className="mt-0.5"
                    checked={scopes.includes(option.value)}
                    onCheckedChange={(checked) => toggleScope(option.value, checked === true)}
                  />
                  <span>
                    <span className="font-medium">{option.label}</span>
                    <span className="block text-muted-foreground">{option.hint}</span>
                  </span>
                </label>
              ))}
            </fieldset>
            <FormError message={error} />
            <DialogFooter>
              <Button type="button" variant="outline" size="sm" onClick={() => close(false)}>
                Cancel
              </Button>
              <Button type="submit" size="sm" disabled={create.isPending}>
                {create.isPending ? "Creating…" : "Create token"}
              </Button>
            </DialogFooter>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}

function SecretReveal({ secret, onDone }: { secret: string; onDone: () => void }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(secret);
    } catch {
      // No clipboard API (plain http on a LAN address): fall back to selecting the text.
      inputRef.current?.select();
      if (!document.execCommand("copy")) {
        toast.error("Could not copy. Select the secret and copy it by hand.");
        return;
      }
    }
    setCopied(true);
    toast.success("Secret copied");
  }

  return (
    <div className="grid gap-4">
      <DialogHeader>
        <DialogTitle className="text-base">Copy your new token</DialogTitle>
        <DialogDescription className="sr-only">The token's secret, shown once.</DialogDescription>
      </DialogHeader>
      <div className="flex gap-2.5 rounded-md border border-status-stale/40 bg-status-stale/10 px-3 py-2.5 text-[13px]">
        <TriangleAlert className="mt-0.5 size-4 shrink-0 text-status-stale" aria-hidden />
        <p>
          <span className="font-medium">This secret is shown once.</span> Copy it now and store it
          where the client can read it. You can't see it again; if it is lost, revoke the token and
          make a new one.
        </p>
      </div>
      <div className="flex gap-2">
        <Input
          ref={inputRef}
          readOnly
          value={secret}
          aria-label="Token secret"
          className="font-mono text-[12px]"
          onFocus={(e) => e.target.select()}
        />
        <Button variant="outline" onClick={() => void copy()} aria-label="Copy secret">
          {copied ? <Check /> : <Copy />}
          {copied ? "Copied" : "Copy"}
        </Button>
      </div>
      <DialogFooter>
        <Button size="sm" onClick={onDone}>
          Done
        </Button>
      </DialogFooter>
    </div>
  );
}
