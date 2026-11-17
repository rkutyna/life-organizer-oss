import { ChevronRight, Pencil, Plug, Plus } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import { accountConnectors, type AccountConnector } from "@/app/modules";
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

/** The calendar, mail and reminders accounts this install syncs, and the ways to add one. */
export function AccountsSection() {
  const accounts = useAccounts();
  const [renaming, setRenaming] = useState<ProviderAccount | null>(null);
  const [removing, setRemoving] = useState<ProviderAccount | null>(null);
  const remove = useDeleteAccount();
  const [adding, setAdding] = useState(false);
  const connectors = accountConnectors();

  return (
    <Section
      id="accounts"
      title="Connected accounts"
      description="The accounts the organizer reads your calendars, mail and reminders from."
      actions={
        connectors.length > 0 && (
          <Button size="sm" variant="outline" onClick={() => setAdding(true)}>
            <Plus /> Add account
          </Button>
        )
      }
    >
      {accounts.isPending ? (
        <Skeleton className="h-14 w-full" />
      ) : accounts.isError ? (
        <FormError message={`Could not load accounts: ${accounts.error.message}`} />
      ) : accounts.data.length === 0 ? (
        <EmptyState
          icon={Plug}
          title="No accounts connected"
          description={
            connectors.length > 0
              ? "Add a calendar, mail or reminders account to start syncing."
              : "Calendar, mail and reminders accounts arrive in later versions. Until then the calendar shows public holidays."
          }
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
      <AddAccountDialog open={adding} connectors={connectors} onClose={() => setAdding(false)} />

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

function AddAccountDialog({
  open,
  connectors,
  onClose,
}: {
  open: boolean;
  connectors: AccountConnector[];
  onClose: () => void;
}) {
  const [chosen, setChosen] = useState<AccountConnector | null>(null);

  function close() {
    setChosen(null);
    onClose();
  }

  const Form = chosen?.form;
  return (
    <Dialog open={open} onOpenChange={(next) => !next && close()}>
      <DialogContent className="sm:max-w-md">
        {Form ? (
          <Form onDone={close} onCancel={() => setChosen(null)} />
        ) : (
          <>
            <DialogHeader>
              <DialogTitle className="text-base">Add an account</DialogTitle>
              <DialogDescription className="text-[13px]">
                Calendars and mail are only read. Nothing in them is changed.
              </DialogDescription>
            </DialogHeader>
            <ul className="-mx-2 grid gap-0.5">
              {connectors.map((connector) => (
                <li key={connector.key}>
                  <button
                    type="button"
                    onClick={() => setChosen(connector)}
                    className="flex w-full items-center gap-3 rounded-md px-2 py-2 text-left hover:bg-accent focus-visible:bg-accent focus-visible:outline-none"
                  >
                    <span className="min-w-0 flex-1">
                      <span className="block text-[13px] font-medium">{connector.label}</span>
                      {connector.description && (
                        <span className="block text-xs text-muted-foreground">{connector.description}</span>
                      )}
                    </span>
                    <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
