import { Settings } from "lucide-react";
import { lazy } from "react";

import type { AppModule } from "@/app/modules";

export default {
  key: "settings",
  label: "Settings",
  path: "/settings",
  icon: Settings,
  navOrder: 90,
  shortcut: "s",
  altShortcuts: [","],
  page: lazy(() => import("./SettingsPage")),
} satisfies AppModule;
