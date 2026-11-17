import { Briefcase } from "lucide-react";
import { lazy } from "react";

import type { AppModule } from "@/app/modules";

export default {
  key: "jobs",
  label: "Jobs",
  path: "/jobs",
  icon: Briefcase,
  navOrder: 20,
  shortcut: "j",
  page: lazy(() => import("./JobsPage")),
  shortcuts: [
    { keys: "1 – 9", description: "Jobs sections (Overview … Settings)" },
    { keys: "N", description: "New application, lead, contact or event (focus the add form)" },
    { keys: "/", description: "Filter the table" },
    { keys: "J K Enter", description: "Move through rows, open one" },
  ],
  calendarDetails: {
    jobs_interviews: lazy(() => import("./InterviewCalendarDetail")),
    jobs_events: lazy(() => import("./EventCalendarDetail")),
    jobs_due: lazy(() => import("./DueCalendarDetail")),
  },
} satisfies AppModule;
