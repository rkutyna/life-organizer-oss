import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

/** A labelled row in a detail form: label on the left (top on phones), control on the right. */
export function Field({
  label,
  htmlFor,
  children,
  className,
}: {
  label: string;
  htmlFor?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("grid gap-1 sm:grid-cols-[6.5rem_1fr] sm:items-center sm:gap-3", className)}>
      <label htmlFor={htmlFor} className="text-xs text-muted-foreground">
        {label}
      </label>
      <div className="flex min-w-0 items-center gap-2">{children}</div>
    </div>
  );
}

/** Native select styled like the shadcn Input (dense, accessible, no portal). */
export function NativeSelect({ className, ...props }: React.ComponentProps<"select">) {
  return (
    <select
      className={cn(
        "h-8 rounded-md border border-input bg-transparent px-2 text-[13px] outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 dark:bg-input/30",
        className,
      )}
      {...props}
    />
  );
}
