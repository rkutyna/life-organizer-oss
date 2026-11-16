/** Words for the values the settings API sends. */

export const AUTHOR_OPTIONS = [
  { value: "claude", label: "Claude", hint: "a local MCP server" },
  { value: "claude_remote", label: "Claude (remote)", hint: "the remote MCP connector" },
  { value: "helper", label: "Mac helper", hint: "pushes Apple Calendar and Reminders" },
  { value: "me", label: "You", hint: "your own scripts and apps" },
] as const;

export function authorLabel(author: string): string {
  return AUTHOR_OPTIONS.find((a) => a.value === author)?.label ?? author;
}

export const SCOPE_OPTIONS = [
  { value: "api", label: "API", hint: "Read and write the organizer, as the MCP server or an app does." },
  { value: "ingest", label: "Ingest", hint: "Push calendar and reminders data. For the Mac helper only." },
  { value: "mail", label: "Mail", hint: "Read mail headers and messages. For the mail MCP server only." },
] as const;

const ACCOUNT_KINDS: Record<string, string> = {
  caldav: "CalDAV",
  icloud_caldav: "iCloud Calendar",
  google: "Google",
  google_calendar: "Google Calendar",
  google_tasks: "Google Tasks",
  gmail: "Gmail",
  imap: "IMAP mail",
};

export function accountKindLabel(kind: string): string {
  return ACCOUNT_KINDS[kind] ?? kind.replace(/_/g, " ");
}
