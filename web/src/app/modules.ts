/**
 * Web module registry. Every folder `src/modules/<name>/` with a `module.tsx` whose default
 * export is an `AppModule` is picked up automatically: it gets a nav entry, a route and a
 * "g <shortcut>" key. Adding a module never edits the shell, the nav or the router.
 *
 *   // src/modules/mail/module.tsx
 *   import { lazy } from "react";
 *   import { Mail } from "lucide-react";
 *   import type { AppModule } from "@/app/modules";
 *
 *   export default {
 *     key: "mail",
 *     label: "Mail",
 *     path: "/mail",
 *     icon: Mail,
 *     navOrder: 30,
 *     shortcut: "e",
 *     page: lazy(() => import("./MailPage")),
 *   } satisfies AppModule;
 */

import type { LucideIcon } from "lucide-react";
import type { ComponentType } from "react";

import type { CalendarItem } from "@/api/client";

export interface CalendarDetailProps {
  item: CalendarItem;
  /** Close the drawer (e.g. after deleting the record). */
  onClose: () => void;
}

export interface AccountConnectorProps {
  /** The account was connected (or the flow left the page, e.g. to an OAuth consent screen). */
  onDone: () => void;
  onCancel: () => void;
}

/**
 * One way to add a connected account, offered by Settings → Connected accounts → Add account.
 * A module registers its own (a CalDAV form, an IMAP form, a "Connect Google" button), so
 * Settings never needs editing for a new provider. The form posts to the module's own API.
 */
export interface AccountConnector {
  /** Stable key, e.g. "caldav", "imap", "google". */
  key: string;
  /** Menu label, e.g. "iCloud or CalDAV calendar". */
  label: string;
  /** One line under the label: what it reads and what it needs. */
  description?: string;
  /** Lower first in the menu. */
  order?: number;
  form: ComponentType<AccountConnectorProps>;
}

export interface AppModule {
  /** Folder name under src/modules/, e.g. "reminders". */
  key: string;
  /** Nav label. */
  label: string;
  /** Route; "/" is the calendar. The page may define sub-routes with <Routes> (path/*). */
  path: string;
  icon: LucideIcon;
  /** Nav position, low first: Calendar 0, Reminders 10, Jobs 20, Mail 30, Settings 90. */
  navOrder: number;
  /** Key for the "g <key>" go-to shortcut: a letter, or a symbol such as ",". */
  shortcut?: string;
  /** More keys that also go here after "g" (shown in the help dialog with the main one). */
  altShortcuts?: string[];
  /** The page component. Use React.lazy so each module loads as its own chunk. */
  page: ComponentType;
  /** Page shortcuts, listed in the "?" help dialog (the page binds them with useHotkeys). */
  shortcuts?: { keys: string; description: string }[];
  /**
   * Detail views for this module's calendar items, keyed by `CalendarItem.source`. The
   * calendar drawer renders it when such an item is clicked (owned items edit in place).
   */
  calendarDetails?: Record<string, ComponentType<CalendarDetailProps>>;
  /** Ways this module adds connected accounts (see `AccountConnector`). */
  accountConnectors?: AccountConnector[];
}

const found = import.meta.glob<AppModule>("../modules/*/module.tsx", {
  eager: true,
  import: "default",
});

export const MODULES: AppModule[] = Object.values(found).sort((a, b) => a.navOrder - b.navOrder);

/** The detail component a module registered for a calendar source, if any. */
export function calendarDetailFor(source: string): ComponentType<CalendarDetailProps> | undefined {
  for (const module of MODULES) {
    const detail = module.calendarDetails?.[source];
    if (detail) return detail;
  }
  return undefined;
}

/** Every module's account connectors, in menu order. */
export function accountConnectors(): AccountConnector[] {
  return MODULES.flatMap((module) => module.accountConnectors ?? []).sort(
    (a, b) => (a.order ?? 50) - (b.order ?? 50) || a.label.localeCompare(b.label),
  );
}
