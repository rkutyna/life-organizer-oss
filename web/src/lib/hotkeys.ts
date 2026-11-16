/**
 * Single-key shortcuts.
 *
 *   useHotkeys({ n: focusQuickAdd, j: next, k: previous, x: toggleDone }, { enabled: !drawerOpen });
 *
 * Key names: a lowercase letter ("n"), "shift+x", a symbol ("?"), or a KeyboardEvent.key name
 * ("Enter", "Escape", "ArrowLeft", "Delete", "Backspace"). Shortcuts are ignored while typing
 * in a field (except Escape) and whenever Cmd/Ctrl/Alt is held, so browser shortcuts still work.
 */

import { useEffect, useRef } from "react";

export type HotkeyMap = Record<string, (event: KeyboardEvent) => void>;

export function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable;
}

/** Buttons and links handle Enter/Space themselves; page shortcuts leave those keys alone. */
function isActivationOnControl(name: string, target: EventTarget | null): boolean {
  if (name !== "Enter" && name !== " ") return false;
  return target instanceof HTMLElement && target.closest("button, a, [role='button']") !== null;
}

export function hotkeyName(event: KeyboardEvent): string {
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  return event.shiftKey && /^[a-z]$/.test(key) ? `shift+${key}` : key;
}

export function useHotkeys(bindings: HotkeyMap, options: { enabled?: boolean } = {}): void {
  const enabled = options.enabled ?? true;
  const latest = useRef(bindings);

  useEffect(() => {
    latest.current = bindings;
  });

  useEffect(() => {
    if (!enabled) return;
    function onKeyDown(event: KeyboardEvent) {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
      const name = hotkeyName(event);
      const handler = latest.current[name];
      if (!handler) return;
      if (isTypingTarget(event.target) && name !== "Escape") return;
      if (isActivationOnControl(name, event.target)) return;
      event.preventDefault();
      handler(event);
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [enabled]);
}
