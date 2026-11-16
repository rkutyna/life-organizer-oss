import { ArrowUpRight, Lock } from "lucide-react";
import { Suspense } from "react";
import { Link } from "react-router";

import type { CalendarItem } from "@/api/client";
import { calendarDetailFor } from "@/app/modules";
import { itemColor } from "@/app/tokens";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

import { formatItemWhen } from "./items";

/**
 * What the calendar drawer shows for a clicked item. If the item's module registered a
 * `calendarDetails` component for its source, that component renders it: an editor for owned
 * items, a richer read-only view for mirrored ones. Otherwise a generic
 * read-only view with a link to where the item lives.
 */
export function ItemDetail({ item, onClose }: { item: CalendarItem; onClose: () => void }) {
  const Editor = calendarDetailFor(item.source);

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        <span
          className="size-2 rounded-full"
          style={{ background: itemColor(item) }}
        />
        <span>{item.source_label}</span>
        <span>·</span>
        <span className="tabular">{formatItemWhen(item)}</span>
      </div>

      {Editor ? (
        <Suspense fallback={<Skeleton className="h-24 w-full" />}>
          <Editor item={item} onClose={onClose} />
        </Suspense>
      ) : (
        <ReadOnlyItem item={item} />
      )}
    </div>
  );
}

function ReadOnlyItem({ item }: { item: CalendarItem }) {
  const external = item.detail_url?.startsWith("http");
  const meta = Object.entries(item.meta ?? {}).filter(
    ([, value]) => value !== null && value !== "" && typeof value !== "object",
  );
  return (
    <div className="space-y-4">
      <h2 className="text-base font-medium">{item.title}</h2>
      {item.status && (
        <p className="text-[13px]">
          <span className="text-muted-foreground">Status </span>
          {item.status}
        </p>
      )}
      {meta.length > 0 && (
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-[13px]">
          {meta.map(([key, value]) => (
            <div key={key} className="contents">
              <dt className="text-muted-foreground">{key.replace(/_/g, " ")}</dt>
              <dd>{String(value)}</dd>
            </div>
          ))}
        </dl>
      )}
      <div className="flex flex-wrap items-center gap-3">
        {item.detail_url && (
          <Button asChild variant="outline" size="sm">
            {external ? (
              <a href={item.detail_url} target="_blank" rel="noreferrer">
                Open source
                <ArrowUpRight />
              </a>
            ) : (
              <Link to={item.detail_url}>
                Open
                <ArrowUpRight />
              </Link>
            )}
          </Button>
        )}
        {item.read_only && (
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <Lock className="size-3" aria-hidden />
            Read-only here; edit it where it lives
          </span>
        )}
      </div>
    </div>
  );
}
