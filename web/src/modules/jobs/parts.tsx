import { ChevronLeft, Trash2 } from "lucide-react";
import { useState, type ReactNode } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { statusColor } from "@/app/tokens";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { type EditableColumn } from "@/components/EditableTable";
import { Button } from "@/components/ui/button";
import { cn, sentence } from "@/lib/utils";

import { useInvalidateJobs, useStatusInfo, type StatusKind } from "./api";
import { formatDate } from "./format";

/** The id a page gives the first input of its add form, so "n" can focus it. */
export const QUICK_ADD_ID = "jobs-quick-add";

/** The color token for a status kind (never a hex value). */
export function kindTone(kind: StatusKind): string {
  switch (kind) {
    case "lead":
      return statusColor("today");
    case "active":
      return statusColor("ok");
    case "closed":
      return statusColor("open");
    case "dropped":
      return statusColor("done");
  }
}

/** A small tinted pill in a token color. */
export function Chip({
  tone,
  children,
  className,
  title,
}: {
  tone: string;
  children: ReactNode;
  className?: string;
  title?: string;
}) {
  return (
    <span
      title={title}
      className={cn(
        "inline-flex max-w-full items-center truncate rounded-full px-2 py-px text-[11px] font-medium whitespace-nowrap",
        className,
      )}
      style={{ color: tone, background: `color-mix(in oklab, ${tone} 14%, transparent)` }}
    >
      {children}
    </span>
  );
}

/** A status key shown with its configured label, colored by its kind. */
export function StatusChip({ status, className }: { status: string; className?: string }) {
  const info = useStatusInfo();
  return (
    <Chip tone={kindTone(info.kind(status))} className={className}>
      {info.label(status)}
    </Chip>
  );
}

export function TagList({ tags, className }: { tags: string[]; className?: string }) {
  if (!tags.length) return null;
  return (
    <span className={cn("inline-flex flex-wrap gap-1", className)}>
      {tags.map((tag) => (
        <span
          key={tag}
          className="rounded bg-secondary px-1.5 py-px text-[11px] text-secondary-foreground"
        >
          {tag}
        </span>
      ))}
    </span>
  );
}

/** A titled block of a page. */
export function Section({
  title,
  action,
  children,
  className,
}: {
  title: ReactNode;
  action?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={cn("min-w-0 space-y-2", className)}>
      <header className="flex min-h-7 flex-wrap items-center justify-between gap-2">
        <h2 className="text-xs font-medium text-muted-foreground">{title}</h2>
        {action}
      </header>
      {children}
    </section>
  );
}

/** A bordered card for a section's body. */
export function Card({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn("rounded-lg border border-border bg-card p-3 md:p-4", className)}>
      {children}
    </div>
  );
}

/** A quiet line for "nothing here" inside a section. */
export function Muted({ children, className }: { children: ReactNode; className?: string }) {
  return <p className={cn("text-[13px] text-muted-foreground", className)}>{children}</p>;
}

/** A server error message under a form. */
export function ErrorLine({ message }: { message: string | null | undefined }) {
  if (!message) return null;
  return (
    <p role="alert" className="text-[13px] text-status-error">
      {sentence(message)}
    </p>
  );
}

export function BackLink({ to, children }: { to: string; children: ReactNode }) {
  return (
    <Link
      to={to}
      className="inline-flex items-center gap-0.5 text-xs text-muted-foreground hover:text-foreground"
    >
      <ChevronLeft className="size-3.5" aria-hidden />
      {children}
    </Link>
  );
}

/**
 * A delete control with its own confirm step. A refusal (e.g. the server's 409) is shown as a
 * toast with the server's message. After a delete, `onDeleted` runs first (e.g. leave the
 * record's page), then the job queries refresh.
 */
export function DeleteButton({
  what,
  description,
  onDelete,
  onDeleted,
  icon = false,
  className,
}: {
  /** "this interview", "Acme Corp" */
  what: string;
  description?: ReactNode;
  onDelete: () => Promise<unknown>;
  onDeleted?: () => void;
  icon?: boolean;
  className?: string;
}) {
  const invalidate = useInvalidateJobs();
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);

  async function confirm() {
    setPending(true);
    try {
      await onDelete();
      setOpen(false);
      toast.success(`Deleted ${what}`);
      onDeleted?.();
      invalidate();
    } catch (error) {
      setOpen(false);
      toast.error(`Could not delete: ${sentence((error as Error).message)}`);
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      {icon ? (
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={`Delete ${what}`}
          title={`Delete ${what}`}
          className={cn("text-muted-foreground hover:text-destructive", className)}
          onClick={(e) => {
            e.stopPropagation();
            setOpen(true);
          }}
        >
          <Trash2 />
        </Button>
      ) : (
        <Button
          variant="ghost"
          size="sm"
          className={cn("text-muted-foreground hover:text-destructive", className)}
          onClick={() => setOpen(true)}
        >
          <Trash2 />
          Delete
        </Button>
      )}
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={`Delete ${what}?`}
        description={description ?? "This cannot be undone from here."}
        confirmLabel="Delete"
        pending={pending}
        onConfirm={() => void confirm()}
      />
    </>
  );
}

/** A date column that reads "Oct 16" and edits as a date input. */
export function dateColumn<T>(
  key: Extract<keyof T, string>,
  header: string,
  className = "w-32",
  editable = true,
): EditableColumn<T> {
  return {
    key,
    header,
    type: editable ? "date" : "readonly",
    className,
    render: (row) => {
      const day = row[key] as unknown as string | null | undefined;
      return formatDate(day) || <span className="text-muted-foreground/60">—</span>;
    },
  };
}

/** Small text link styled for dense lists. */
export function TextLink({
  to,
  children,
  className,
}: {
  to: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <Link
      to={to}
      onClick={(e) => e.stopPropagation()}
      className={cn("truncate font-medium text-foreground hover:underline", className)}
    >
      {children}
    </Link>
  );
}

/** Small "label  value" grid for read-only facts. */
export function Facts({ items }: { items: [string, ReactNode][] }) {
  const shown = items.filter(([, value]) => value !== null && value !== undefined && value !== "");
  if (!shown.length) return null;
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-[13px]">
      {shown.map(([label, value]) => (
        <div key={label} className="contents">
          <dt className="text-muted-foreground">{label}</dt>
          <dd className="min-w-0 break-words">{value}</dd>
        </div>
      ))}
    </dl>
  );
}
