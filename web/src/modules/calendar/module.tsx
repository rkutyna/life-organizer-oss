import { CalendarDays } from "lucide-react";
import { lazy } from "react";

import type { AppModule } from "@/app/modules";

export default {
  key: "calendar",
  label: "Calendar",
  path: "/",
  icon: CalendarDays,
  navOrder: 0,
  shortcut: "c",
  page: lazy(() => import("./CalendarPage")),
  shortcuts: [
    { keys: "D W M Y", description: "Day / week / month / year" },
    { keys: "T", description: "Today" },
    { keys: "← →", description: "Previous / next" },
  ],
} satisfies AppModule;
