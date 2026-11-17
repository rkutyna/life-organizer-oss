import { Settings } from "lucide-react";
import { lazy } from "react";

import type { AppModule } from "@/app/modules";

import { GoogleConnector } from "./GoogleConnector";

export default {
  key: "settings",
  label: "Settings",
  path: "/settings",
  icon: Settings,
  navOrder: 90,
  shortcut: "s",
  altShortcuts: [","],
  page: lazy(() => import("./SettingsPage")),
  accountConnectors: [
    {
      key: "google",
      label: "Google account",
      description: "Google Calendar and Gmail, read only, through Google's own sign-in.",
      order: 10,
      form: GoogleConnector,
    },
  ],
} satisfies AppModule;
