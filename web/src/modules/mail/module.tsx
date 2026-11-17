import { Mail } from "lucide-react";
import { lazy } from "react";

import type { AppModule } from "@/app/modules";

import { ImapConnector } from "./ImapConnector";

export default {
  key: "mail",
  label: "Mail",
  path: "/mail",
  icon: Mail,
  navOrder: 30,
  shortcut: "m",
  page: lazy(() => import("./MailPage")),
  shortcuts: [
    { keys: "J K", description: "Next / previous message" },
    { keys: "/", description: "Search headers" },
    { keys: "Esc", description: "Close the message" },
  ],
  accountConnectors: [
    {
      key: "imap",
      label: "Email (IMAP)",
      description: "iCloud, Fastmail, Outlook or any IMAP server, read only, with an app password.",
      order: 30,
      form: ImapConnector,
    },
  ],
} satisfies AppModule;
