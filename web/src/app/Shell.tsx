import { LogOut } from "lucide-react";
import { Suspense, useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { hotkeyName, isTypingTarget } from "@/lib/hotkeys";
import { cn } from "@/lib/utils";

import { useSignOut } from "./auth";
import { MODULES } from "./modules";
import { ShortcutsDialog } from "./ShortcutsDialog";
import { ThemeToggle } from "./ThemeToggle";

/**
 * App frame: left nav on desktop, bottom tab bar under 768px. Nav entries come from the
 * module registry (src/app/modules.ts), never from a hand-kept list. Sign out sits at the foot
 * of the sidebar; on phones it is on the Settings page.
 */
export function Shell() {
  const [helpOpen, setHelpOpen] = useState(false);
  useGoToShortcuts(() => setHelpOpen(true));

  return (
    <div className="flex h-dvh overflow-hidden">
      <Sidebar onHelp={() => setHelpOpen(true)} />
      <main className="flex min-w-0 flex-1 flex-col overflow-hidden pb-[calc(3.5rem+env(safe-area-inset-bottom))] md:pb-0">
        <Suspense fallback={<div className="p-6 text-muted-foreground">Loading…</div>}>
          <Outlet />
        </Suspense>
      </main>
      <BottomTabs />
      <ShortcutsDialog open={helpOpen} onOpenChange={setHelpOpen} />
    </div>
  );
}

function Sidebar({ onHelp }: { onHelp: () => void }) {
  return (
    <nav
      aria-label="Main"
      className="hidden w-52 shrink-0 flex-col border-r border-sidebar-border bg-sidebar text-sidebar-foreground md:flex"
    >
      <div className="flex h-12 items-center gap-2 px-4">
        <img src="/icon.svg" alt="" className="size-5 rounded-[5px]" />
        <span className="text-[13px] font-semibold tracking-tight text-foreground">Life Organizer</span>
      </div>
      <ul className="flex flex-1 flex-col gap-px px-2 pt-1">
        {MODULES.map((module) => (
          <li key={module.key}>
            <NavLink
              to={module.path}
              end={module.path === "/"}
              className={({ isActive }) =>
                cn(
                  "group flex h-8 items-center gap-2.5 rounded-md px-2 text-[13px] transition-colors",
                  "hover:bg-sidebar-accent hover:text-foreground",
                  isActive && "bg-sidebar-accent font-medium text-foreground",
                )
              }
            >
              <module.icon className="size-4 shrink-0 opacity-80" />
              <span className="flex-1 truncate">{module.label}</span>
              {module.shortcut && (
                <span className="hidden gap-0.5 text-[10px] text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 lg:flex">
                  <Kbd>G</Kbd>
                  <Kbd>{module.shortcut.toUpperCase()}</Kbd>
                </span>
              )}
            </NavLink>
          </li>
        ))}
      </ul>
      <div className="flex items-center gap-1 border-t border-sidebar-border p-2">
        <ThemeToggle showLabel className="flex-1" />
        <SignOutButton />
        <button
          type="button"
          onClick={onHelp}
          className="rounded-md px-2 py-1 text-muted-foreground hover:bg-sidebar-accent hover:text-foreground"
          title="Keyboard shortcuts"
        >
          <Kbd>?</Kbd>
        </button>
      </div>
    </nav>
  );
}

function SignOutButton() {
  const signOut = useSignOut();
  return (
    <Button
      variant="ghost"
      size="icon-sm"
      title="Sign out"
      aria-label="Sign out"
      className="text-muted-foreground"
      disabled={signOut.isPending}
      onClick={() =>
        signOut.mutate(undefined, {
          onError: (error) => toast.error(`Could not sign out cleanly: ${error.message}`),
        })
      }
    >
      <LogOut />
    </Button>
  );
}

function BottomTabs() {
  return (
    <nav
      aria-label="Main"
      className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-background/95 pb-safe backdrop-blur md:hidden"
    >
      <ul className="flex h-14">
        {MODULES.map((module) => (
          <li key={module.key} className="flex-1">
            <NavLink
              to={module.path}
              end={module.path === "/"}
              className={({ isActive }) =>
                cn(
                  "flex h-full flex-col items-center justify-center gap-0.5 text-[10px] text-muted-foreground",
                  isActive && "text-primary",
                )
              }
            >
              <module.icon className="size-5" />
              <span className="leading-none">{module.label}</span>
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}

/** "g" then a module's key navigates there; "?" opens the shortcuts dialog. */
function useGoToShortcuts(openHelp: () => void) {
  const navigate = useNavigate();
  const pendingG = useRef<number | null>(null);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.metaKey || event.ctrlKey || event.altKey || isTypingTarget(event.target)) return;
      const name = hotkeyName(event);
      if (pendingG.current !== null) {
        window.clearTimeout(pendingG.current);
        pendingG.current = null;
        const target = MODULES.find(
          (m) => m.shortcut === name || m.altShortcuts?.includes(name),
        );
        if (target) {
          event.preventDefault();
          navigate(target.path);
        }
        return;
      }
      if (name === "g") {
        pendingG.current = window.setTimeout(() => (pendingG.current = null), 1000);
      } else if (name === "?") {
        event.preventDefault();
        openHelp();
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [navigate, openHelp]);
}
