import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

import { PageHeader } from "@/components/PageHeader";

/** Stand-in page for a module that is not built yet: says what will live there. */
export function PlaceholderPage({
  title,
  icon: Icon,
  summary,
  planned,
}: {
  title: string;
  icon: LucideIcon;
  summary: ReactNode;
  planned: string[];
}) {
  return (
    <>
      <PageHeader title={title} />
      <div className="flex-1 overflow-y-auto">
        <div className="mx-auto max-w-2xl p-4 md:p-6">
          <section className="rounded-lg border border-dashed border-border bg-card/60 p-5">
            <div className="mb-3 flex items-center gap-2">
              <Icon className="size-4 text-muted-foreground" aria-hidden />
              <h2 className="text-[13px] font-medium">Coming soon</h2>
            </div>
            <p className="mb-4 text-[13px] text-muted-foreground">{summary}</p>
            <ul className="space-y-1.5 text-[13px]">
              {planned.map((line) => (
                <li key={line} className="flex gap-2">
                  <span className="mt-[7px] size-1 shrink-0 rounded-full bg-muted-foreground/60" />
                  <span>{line}</span>
                </li>
              ))}
            </ul>
          </section>
        </div>
      </div>
    </>
  );
}
