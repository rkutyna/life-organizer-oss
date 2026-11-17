import { ListChecks } from "lucide-react";
import { lazy } from "react";

import type { AppModule } from "@/app/modules";

export default {
  key: "reminders",
  label: "Reminders",
  path: "/reminders",
  icon: ListChecks,
  navOrder: 10,
  shortcut: "r",
  page: lazy(() => import("./RemindersPage")),
  shortcuts: [
    { keys: "N", description: "New reminder" },
    { keys: "J K", description: "Next / previous reminder" },
    { keys: "X", description: "Check off / uncheck" },
    { keys: "Enter", description: "Open the reminder" },
    { keys: "Esc", description: "Clear the selection" },
  ],
  calendarDetails: {
    reminders: lazy(() => import("./ReminderCalendarDetail")),
  },
} satisfies AppModule;
