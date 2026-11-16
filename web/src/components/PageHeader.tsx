import type { ReactNode } from "react";

import { ThemeToggle } from "@/app/ThemeToggle";
import { cn } from "@/lib/utils";

/**
 * The top bar every page starts with: title on the left, actions on the right, optional
 * second row (`children`) for filters or tabs. On phones it also carries the theme toggle,
 * since the bottom tab bar has no room for it. `titleExtra` sits right after the title, so a
 * control can share the title's line instead of crowding the actions on a phone.
 */
export function PageHeader({
  title,
  subtitle,
  actions,
  titleExtra,
  children,
  className,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  titleExtra?: ReactNode;
  children?: ReactNode;
  className?: string;
}) {
  return (
    <header className={cn("shrink-0 border-b border-border bg-background", className)}>
      {/* Wraps on narrow screens: the actions drop to a second line instead of squeezing the title. */}
      <div className="flex min-h-12 flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2 md:px-5">
        <div className="flex min-w-36 flex-1 items-baseline gap-2">
          <h1 className="truncate text-[15px] font-semibold tracking-tight">{title}</h1>
          {subtitle && (
            <span className="truncate text-[13px] text-muted-foreground tabular">{subtitle}</span>
          )}
          {titleExtra && <div className="shrink-0 self-center">{titleExtra}</div>}
        </div>
        {/* The phone theme toggle sits with the actions, so it never wraps onto a line alone. */}
        <div className="ml-auto flex shrink-0 items-center gap-1.5">
          {actions}
          <ThemeToggle className="md:hidden" />
        </div>
      </div>
      {children && <div className="px-4 pb-2.5 md:px-5">{children}</div>}
    </header>
  );
}
