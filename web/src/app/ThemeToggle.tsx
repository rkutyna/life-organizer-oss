import { Monitor, Moon, Sun } from "lucide-react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

import { useTheme } from "./theme";

const LABELS = { system: "System theme", light: "Light theme", dark: "Dark theme" } as const;
const ICONS = { system: Monitor, light: Sun, dark: Moon } as const;

/** Cycles system → light → dark. `showLabel` for the sidebar, icon-only elsewhere. */
export function ThemeToggle({ showLabel = false, className }: { showLabel?: boolean; className?: string }) {
  const { preference, cycle } = useTheme();
  const Icon = ICONS[preference];
  return (
    <Button
      variant="ghost"
      size={showLabel ? "sm" : "icon-sm"}
      onClick={cycle}
      title={`${LABELS[preference]} (click to change)`}
      aria-label={LABELS[preference]}
      className={cn(showLabel && "justify-start gap-2 px-2 text-muted-foreground", className)}
    >
      <Icon />
      {showLabel && <span className="text-[13px]">{LABELS[preference]}</span>}
    </Button>
  );
}
