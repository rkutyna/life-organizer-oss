import { Ban, Send } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

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

import { jobsApi, useJobsMutation, type Application } from "./api";
import { today } from "./format";
import { ErrorLine } from "./parts";

/**
 * Apply and Drop for an open lead. Apply submits it (status applied, date applied, default
 * today); Drop cuts it without applying and needs a reason, which the server keeps in the
 * status event and the notes.
 */
export function LeadActions({
  lead,
  size = "xs",
  onApplied,
}: {
  lead: Application;
  size?: "xs" | "sm";
  onApplied?: () => void;
}) {
  const [dialog, setDialog] = useState<"apply" | "drop" | null>(null);
  return (
    <span className="inline-flex items-center gap-1" onClick={(e) => e.stopPropagation()}>
      <Button variant="outline" size={size} onClick={() => setDialog("apply")}>
        <Send />
        Apply
      </Button>
      <Button variant="ghost" size={size} onClick={() => setDialog("drop")}>
        <Ban />
        Drop
      </Button>
      <ApplyDialog
        lead={lead}
        open={dialog === "apply"}
        onOpenChange={(open) => setDialog(open ? "apply" : null)}
        onApplied={onApplied}
      />
      <DropDialog lead={lead} open={dialog === "drop"} onOpenChange={(open) => setDialog(open ? "drop" : null)} />
    </span>
  );
}

function ApplyDialog({
  lead,
  open,
  onOpenChange,
  onApplied,
}: {
  lead: Application;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onApplied?: () => void;
}) {
  const apply = useJobsMutation((onDate: string) => jobsApi.applyLead(lead.id, { on_date: onDate || null }));
  const [date, setDate] = useState(today());

  function submit(event: FormEvent) {
    event.preventDefault();
    apply.mutate(date, {
      onSuccess: () => {
        toast.success(`Applied: ${lead.title} at ${lead.company}`);
        onOpenChange(false);
        onApplied?.();
      },
    });
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-sm">
        <form onSubmit={submit} className="space-y-4">
          <DialogHeader>
            <DialogTitle className="text-base">Submit this lead?</DialogTitle>
            <DialogDescription className="text-[13px]">
              {lead.title} at {lead.company} becomes an application.
            </DialogDescription>
          </DialogHeader>
          <label className="flex items-center gap-3 text-[13px]">
            <span className="text-muted-foreground">Applied on</span>
            <Input
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
              className="h-8 w-40 text-[13px]"
              autoFocus
            />
          </label>
          <ErrorLine message={apply.error?.message} />
          <DialogFooter>
            <Button type="button" variant="outline" size="sm" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" size="sm" disabled={apply.isPending}>
              Apply
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function DropDialog({
  lead,
  open,
  onOpenChange,
}: {
  lead: Application;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const drop = useJobsMutation((reason: string) => jobsApi.dropLead(lead.id, reason));
  const [reason, setReason] = useState("");

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!reason.trim()) return;
    drop.mutate(reason.trim(), {
      onSuccess: () => {
        toast.success(`Dropped: ${lead.title}`);
        setReason("");
        onOpenChange(false);
      },
    });
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-sm">
        <form onSubmit={submit} className="space-y-4">
          <DialogHeader>
            <DialogTitle className="text-base">Drop this lead?</DialogTitle>
            <DialogDescription className="text-[13px]">
              {lead.title} at {lead.company} is cut without applying.
            </DialogDescription>
          </DialogHeader>
          <Input
            aria-label="Reason"
            placeholder="Reason (required), e.g. needs relocation"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="h-8 text-[13px]"
            autoFocus
            required
          />
          <ErrorLine message={drop.error?.message} />
          <DialogFooter>
            <Button type="button" variant="outline" size="sm" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" size="sm" variant="destructive" disabled={drop.isPending || !reason.trim()}>
              Drop lead
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
