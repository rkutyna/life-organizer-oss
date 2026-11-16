import type { ReactNode } from "react";

import { cn, sentence } from "@/lib/utils";

/** One block of the settings page: a heading, a line of explanation, then the controls. */
export function Section({
  id,
  title,
  description,
  actions,
  children,
  className,
}: {
  id: string;
  title: string;
  description?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section aria-labelledby={`${id}-title`} className={cn("rounded-lg border border-border bg-card", className)}>
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-3 md:px-5">
        <div className="min-w-0 space-y-0.5">
          <h2 id={`${id}-title`} className="text-[13px] font-semibold tracking-tight">
            {title}
          </h2>
          {description && <p className="text-[13px] text-muted-foreground">{description}</p>}
        </div>
        {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
      </header>
      <div className="px-4 py-4 md:px-5">{children}</div>
    </section>
  );
}

/** Inline error under a form. */
export function FormError({ message }: { message: string | null | undefined }) {
  if (!message) return null;
  return (
    <p role="alert" className="text-[13px] text-status-error">
      {sentence(message)}
    </p>
  );
}
