import { Pencil, Plug } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import { statusColor } from "@/app/tokens";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { EmptyState } from "@/components/EmptyState";
import { Button } from "@/components/ui/button";
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

import { useAccounts, useDeleteAccount, useUpdateAccount, type ProviderAccount } from "./api";
import { accountKindLabel } from "./labels";
import { FormError, Section } from "./Section";

const STATUS_TEXT: Record<ProviderAccount["status"], string> = {
  ok: "Syncing",
  error: "Failing",
  never: "Not synced yet",
  disabled: "Disabled",
};

const STATUS_TONE: Record<ProviderAccount["status"], string> = {
  ok: statusColor("ok"),
  error: statusColor("error"),
  never: statusColor("never"),
  disabled: statusColor("never"),
};

/** The calendar, mail and reminders accounts this install syncs. Adding them comes later. */
export function AccountsSection() {
  const accounts = useAccounts();
  const [renaming, setRenaming] = useState<ProviderAccount | null>(null);
  const [removing, setRemoving] = useState<ProviderAccount | null>(null);
  const remove = useDeleteAccount();

  return (
    <Section
      id="accounts"
      title="Connected accounts"
      description="The accounts the organizer reads your calendars, mail and reminders from."
    >
      {accounts.isPending ? (
        <Skeleton className="h-14 w-full" />
      ) : accounts.isError ? (
        <FormError message={`Could not load accounts: ${accounts.error.message}`} />
      ) : accounts.data.length === 0 ? (
        <EmptyState
          icon={Plug}
          title="No accounts connected"
          description="Calendar, mail and reminders accounts arrive in later versions. Until then the calendar shows public holidays."
          className="py-6"
        />
      ) : (
        <ul className="-my-1 divide-y divide-border">
          {accounts.data.map((account) => (
            <AccountRow
              key={account.id}
              account={account}
              onRename={() => setRenaming(account)}
              onRemove={() => setRemoving(account)}
            />
          ))}
        </ul>
      )}

      <RenameDialog account={renaming} onClose={() => setRenaming(null)} />

      <ConfirmDialog
        open={removing !== null}
        onOpenChange={(open) => !open && setRemoving(null)}
        title={`Remove "${removing?.label ?? ""}"?`}
        description="The organizer stops syncing it and deletes its saved credentials. Nothing changes in the account itself."
        confirmLabel="Remove"
        pending={remove.isPending}
        onConfirm={() =>
          removing &&
          remove.mutate(removing.id, {
            onSuccess: () => {
              toast.success("Account removed");
              setRemoving(null);
            },
            onError: (err) => toast.error(`Could not remove: ${err.message}`),
          })
        }
      />
    </Section>
  );
}

function AccountRow({
  account,
  onRename,
  onRemove,
}: {
  account: ProviderAccount;
  onRename: () => void;
  onRemove: () => void;
}) {
  const update = useUpdateAccount();

  function toggle() {
    update.mutate(
      { id: account.id, enabled: !account.enabled },
      {
        onSuccess: (saved) => toast.success(saved.enabled ? "Account enabled" : "Account disabled"),
        onError: (err) => toast.error(`Could not update: ${err.message}`),
      },
    );
  }

  return (
    <li className="flex flex-wrap items-start gap-x-4 gap-y-2 py-3">
      <div className="min-w-0 flex-1 space-y-0.5">
        <div className="flex flex-wrap items-baseline gap-x-2">
          <span className={cn("text-[13px] font-medium", !account.enabled && "text-muted-foreground")}>
            {account.label}
          </span>
          <span className="text-xs text-muted-foreground">{accountKindLabel(account.kind)}</span>
        </div>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
          <span className="flex items-center gap-1.5">
            <span
              className="size-1.5 rounded-full"
              style={{ background: STATUS_TONE[account.status] }}
              aria-hidden
            />
            <span className={cn(account.status === "error" && "text-status-error")}>
              {STATUS_TEXT[account.status]}
            </span>
          </span>
          <span>
            Last sync{" "}
            {account.last_sync_at ? (
              <span title={formatTimestamp(account.last_sync_at)}>
                {formatAge(account.last_sync_at)}
              </span>
            ) : (
              "never"
            )}
          </span>
        </div>
        {account.last_error && (
          <p className="pt-0.5 text-xs break-words text-status-error">{account.last_error}</p>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <Button variant="outline" size="xs" onClick={toggle} disabled={update.isPending}>
          {account.enabled ? "Disable" : "Enable"}
        </Button>
        <Button variant="ghost" size="icon-xs" aria-label={`Rename ${account.label}`} title="Rename" onClick={onRename}>
          <Pencil />
        </Button>
        <Button
          variant="ghost"
          size="xs"
          className="text-destructive hover:text-destructive"
          onClick={onRemove}
        >
          Remove
        </Button>
      </div>
    </li>
  );
}

function RenameDialog({ account, onClose }: { account: ProviderAccount | null; onClose: () => void }) {
  return (
    <Dialog open={account !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-sm">
        {account && <RenameForm key={account.id} account={account} onClose={onClose} />}
      </DialogContent>
    </Dialog>
  );
}

function RenameForm({ account, onClose }: { account: ProviderAccount; onClose: () => void }) {
  const update = useUpdateAccount();
  const [label, setLabel] = useState(account.label);
  const [error, setError] = useState<string | null>(null);

  function submit(event: FormEvent) {
    event.preventDefault();
    const next = label.trim();
    if (!next) return setError("The name can't be empty.");
    if (next === account.label) return onClose();
    update.mutate(
      { id: account.id, label: next },
      {
        onSuccess: () => {
          toast.success("Account renamed");
          onClose();
        },
        onError: (err) => setError(err.message),
      },
    );
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      <DialogHeader>
        <DialogTitle className="text-base">Rename account</DialogTitle>
        <DialogDescription className="text-[13px]">
          The name is only used here, in the organizer.
        </DialogDescription>
      </DialogHeader>
      <Input autoFocus value={label} onChange={(e) => setLabel(e.target.value)} aria-label="Account name" />
      <FormError message={error} />
      <DialogFooter>
        <Button type="button" variant="outline" size="sm" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" size="sm" disabled={update.isPending}>
          Save
        </Button>
      </DialogFooter>
    </form>
  );
}
