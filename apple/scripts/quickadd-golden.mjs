#!/usr/bin/env node
// Golden cases for the native quick-add parser, produced by the web's own parser.
//
// The web parses quick-add text with chrono-node (web/src/modules/reminders/parse.ts). The native
// port (OrganizerCore/QuickAdd/QuickAddParser.swift) is tested against what chrono returns
// for the inputs below, at fixed reference times, so the two cannot drift silently.
//
//   node apple/scripts/quickadd-golden.mjs [path/to/web]     # default: <repo>/web
//
// Needs `npm install` in that web folder. Writes
// apple/OrganizerKit/Tests/OrganizerCoreTests/Fixtures/quickadd-golden.json.
// Add an input to CASES, run this, then run `swift test`.

import { createRequire } from "node:module";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const webDir = resolve(process.argv[2] ?? join(here, "..", "..", "web"));
const require = createRequire(join(webDir, "package.json"));
const chrono = require("chrono-node");

// Fixed wall-clock reference times. The script runs with TZ set below, so `new Date(y, m, ...)`
// is that local time; the Swift tests use the same zone.
process.env.TZ = "America/New_York";
const TIME_ZONE = "America/New_York";
const NOWS = {
  // Friday morning.
  fri: new Date(2026, 9, 23, 10, 30),
  // Sunday evening, late in the year (forward dates roll into the next year).
  sun: new Date(2026, 11, 27, 21, 0),
};

const CASES = {
  fri: [
    "Call the plumber tomorrow 3pm !1",
    "Buy milk",
    "Buy milk !2",
    "!3 Water plants",
    "Read book !1 tomorrow",
    "!4 is not a priority",
    "price went up!1",
    "Pay rent on friday",
    "Pay rent friday",
    "Pay rent this friday",
    "Pay rent next friday",
    "Haircut sat 11am",
    "Call bank on mon",
    "Monday standup",
    "Dentist next tuesday at 10am",
    "Submit report by monday",
    "Team lunch today at noon",
    "Team lunch today",
    "Call mom tonight",
    "Water the plants tomorrow morning",
    "Email Sam this afternoon",
    "Gym this evening",
    "Garbage out sunday night",
    "tomorrow",
    "Due friday",
    "Workshop the day after tomorrow",
    "Renew passport in 2 weeks",
    "Check oil in 3 days",
    "Plan trip in 1 month",
    "Call back in 2 hours",
    "Stretch in 30 minutes",
    "Book flights next week",
    "Taxes next month",
    "Meeting oct 30 2pm",
    "Birthday party Nov 2",
    "Halloween costume October 31",
    "Return library books 24 oct",
    "Doctor appointment Jan 5",
    "Pay deposit Oct 1",
    "Interview prep 10/28 at 3:30pm",
    "Concert 12/5",
    "Vacation 2026-12-20",
    "Pick up dry cleaning 5pm",
    "Fix bike 8 pm",
    "Morning run 6am",
    "Standup at 9:30",
    "Review PR 14:00",
    "Lunch at 1",
    "Call at 3pm tomorrow",
    "next friday dinner",
    "Wedding june 14",
    "Leave at midnight",
    "Pay invoice by 12/1 !2",
    "Prep slides wed 4:15pm !1",
  ],
  sun: [
    "Doctor appointment Jan 5",
    "Pay rent friday",
    "Pay rent monday",
    "Night shift 9pm",
    "Wake up 7am",
    "Plan year next month",
    "Party new year's eve",
    "Review goals Dec 31",
    "Groceries tomorrow",
    "Check in 12/26",
  ],
};

// --- the web's parse.ts, verbatim in behaviour -------------------------------------------
const PRIORITY = /(^|\s)!([123])(?=\s|$)/;
const DANGLING = /\s+(on|at|by|due|for|from)$/i;
const tidy = (text) => text.replace(/\s+/g, " ").trim().replace(DANGLING, "").trim();
const pad = (n) => String(n).padStart(2, "0");
const day = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const clock = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;

function parseQuickAdd(input, now) {
  let text = input;
  let priority = null;
  const flag = text.match(PRIORITY);
  if (flag) {
    priority = Number(flag[2]);
    text = text.replace(flag[0], " ");
  }
  const [match] = chrono.parse(text, now, { forwardDate: true });
  if (!match) return { title: tidy(text), due_date: null, due_time: null, priority, date_text: null };
  const when = match.start.date();
  const rest = tidy(text.slice(0, match.index) + " " + text.slice(match.index + match.text.length));
  return {
    title: rest || tidy(text),
    due_date: day(when),
    due_time: match.start.isCertain("hour") ? clock(when) : null,
    priority,
    date_text: match.text,
  };
}
// -------------------------------------------------------------------------------------------

const cases = [];
for (const [key, inputs] of Object.entries(CASES)) {
  const now = NOWS[key];
  for (const input of inputs) {
    cases.push({ now: `${day(now)}T${clock(now)}`, input, expected: parseQuickAdd(input, now) });
  }
}

const out = join(here, "..", "OrganizerKit", "Tests", "OrganizerCoreTests", "Fixtures", "quickadd-golden.json");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(
  out,
  JSON.stringify({ generated_by: "apple/scripts/quickadd-golden.mjs", chrono: "2.10.1", time_zone: TIME_ZONE, cases }, null, 2) + "\n",
);
console.log(`wrote ${cases.length} cases to ${out}`);
