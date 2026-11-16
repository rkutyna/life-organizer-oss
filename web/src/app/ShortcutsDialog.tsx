import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Kbd } from "@/components/ui/kbd";

import { MODULES } from "./modules";

function Keys({ keys }: { keys: string }) {
  return (
    <span className="flex shrink-0 gap-1">
      {keys.split(" ").map((key, i) => (
        <Kbd key={i}>{key}</Kbd>
      ))}
    </span>
  );
}

function Section({ title, rows }: { title: string; rows: { keys: string; description: string }[] }) {
  return (
    <section>
      <h3 className="mb-1.5 text-[11px] font-medium tracking-wide text-muted-foreground uppercase">
        {title}
      </h3>
      <ul className="space-y-1">
        {rows.map((row) => (
          <li key={row.keys} className="flex items-center justify-between gap-4 text-[13px]">
            <span>{row.description}</span>
            <Keys keys={row.keys} />
          </li>
        ))}
      </ul>
    </section>
  );
}

export function ShortcutsDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const goTo = MODULES.filter((m) => m.shortcut).flatMap((m) =>
    [m.shortcut!, ...(m.altShortcuts ?? [])].map((key) => ({
      keys: `G ${key.toUpperCase()}`,
      description: `Go to ${m.label}`,
    })),
  );
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85dvh] overflow-y-auto sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
        </DialogHeader>
        <div className="space-y-5">
          <Section title="Anywhere" rows={[...goTo, { keys: "?", description: "This list" }]} />
          {MODULES.filter((m) => m.shortcuts?.length).map((m) => (
            <Section key={m.key} title={m.label} rows={m.shortcuts!} />
          ))}
        </div>
      </DialogContent>
    </Dialog>
  );
}
