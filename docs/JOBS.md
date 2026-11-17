# Job tracker

The job tracker keeps your search in one place: the companies you're looking at, every posting
from the day you find it to the day it closes, the people you talk to, interviews and career
events. You can bring in your existing spreadsheet as a CSV.

- The **web app** (**Jobs**, or `g j`) has an overview, applications, leads, companies, contacts,
  interviews, events, the import wizard and settings.
- The **calendar** shows interviews, job events and next-action due dates, and you can edit them
  from its drawer.
- **Claude** reads and writes the tracker through the `jobs` toolset of the MCP server
  ([MCP.md](MCP.md)).

Every change is logged with who made it (you, or Claude; `system` only for the demo data and for
writing out the default status list), and you can revert it from a record's History. An import
is logged under whoever ran it.

## The model

| Record | What it holds |
|---|---|
| **Company** | A name, a website, a *target* flag (on your list of places to aim for), notes and free-form tags. Names are unique ignoring case, spacing and Unicode lookalikes: "Acme Corp", "acme  corp" and a fullwidth "Ａcme Corp" are one company. |
| **Application** | One posting at a company: title, status, date applied, location, posting URL, where you found it, a next action with a due date, notes, tags, and any spreadsheet columns that mapped to no field (`extra`). |
| **Status history** | The dated status changes behind each application. The current status is always the status of the latest change (see [Status history](#status-history)). |
| **Contact** | A person, at a company or at none: role, email, profile link, the day you first reached out, the day they replied, a next action with a due date, notes and tags. |
| **Interview** | An interview for an application: stage (free text), day, start time, duration, place or video link, interviewer and notes. |
| **Event** | A career fair, networking evening or info session: day, times, place, link, whether you went, notes and tags. |
| **Weekly goal** | Optional. A target per week for one of: applications, outreach, leads, interviews, events. |

Notes and next actions take up to 20,000 characters, names 200 and titles 300.

Tags replace fixed columns such as region or school: tag a company `remote` or an application
`referral`, then filter by the tag. An application matches a tag filter when it or its company
has the tag.

## Leads and applications are one record

A lead is a posting you might apply to. It's an application whose status is **lead**, with no
date applied. When you apply, the same record moves on, so a posting is never tracked twice.

- **Logging a lead** is refused when the company already has a lead or an application with the
  same title. The error names that record. Titles match ignoring case, spacing and punctuation,
  so "Engineer, Platform" and "Engineer - Platform" are the same posting. Dropped leads don't
  count. To log a genuine reposting anyway, use *Add anyway* (`force`). Renaming an open lead,
  or moving it to another company, onto a posting that is already tracked is refused the same
  way (`force` on the PATCH allows it).
- **Applying to a lead** (*Apply*) sets the date applied and adds an *applied* status change. It
  can't be dated before the day the lead was found.
- **Adding an application** for a posting that matches exactly one open lead *submits that lead*
  instead of creating a second record (promotion). The values you enter replace the lead's, and
  notes are appended. When several open leads match, none is guessed: a new record is created
  and the response lists the candidates (`lead_candidates`).
- **Dropping a lead** sets the status to **dropped** with your reason. The reason is kept in the
  status history and appended to the notes.
- Giving an open lead any later status (for example *screen*) submits it first.

There is no fuzzy matching. Two postings are joined only when their names fold to the same text.
The fold applies Unicode NFKC normalization and ignores invisible characters such as zero-width
spaces, so "Café" typed two ways, or a name pasted with a hidden character, still matches.

## Status history

The history and the application have to agree, so these edits are refused (409):

- dating a status change before the *lead* event, or the lead event after another change;
- dating anything after the *dropped* event of a dropped lead;
- an edit or delete that would turn a submitted application back into a lead (moving the lead
  event last, deleting the *applied* event of a former lead) or un-drop a lead (deleting the
  *dropped* event). Use *Apply*, *Drop* or History for those;
- deleting the last status change.

Other changes are free: fix a date, change *screen* to *interview*, delete a stage you logged by
mistake.

## Statuses

The status list is yours to edit (**Jobs → Settings**). The defaults:

| Status | Kind |
|---|---|
| Lead | lead |
| Applied | active |
| Screen | active |
| Interview | active |
| Offer | active |
| Rejected | closed |
| Withdrawn | closed |
| Ghosted | closed |
| Dropped lead | dropped |

- **active** statuses are the stages of the funnel, in list order. **closed** ones end an
  application without moving it on.
- *Lead*, *Applied* and *Dropped lead* are reserved. You can rename and move them, but you can't
  remove them or change their kind. You can add, rename, reorder and remove the others, and
  switch them between active and closed.
- A status still used by some live application's history can't be removed. Deleted records
  don't hold it: you can remove a status only deleted records use, and restoring one of them
  from History is then refused until you add the status back with the same key.
- The defaults apply until the first edit, which saves the whole list (logged as `system`).

## The pipeline

The overview counts. It shows no rates or percentages.

- **By status**: each submitted application's *current* status. One that had a screen and an
  interview and was then rejected counts only as rejected.
- **Reached**: how far applications got. For each active stage, in list order, it counts the
  applications whose history reached that stage or a later one. A rejected application whose
  history has an interview counts toward *interview*. Reordering the active statuses changes
  what "later" means.
- **Leads** (open and dropped) are counted apart and are not in the total.
- **Interviews**: applications with at least one interview, and the interview records.

The pipeline takes the same filters as the applications list (company, tag, date applied,
search), so the two always count the same rows.

## Weekly goals

Goals are optional, with at most one per metric. A week runs Monday to Sunday in your time zone.

| Metric | Counts |
|---|---|
| applications | applications whose date applied is in the week |
| outreach | contacts whose *contacted on* date is in the week |
| leads | leads logged in the week |
| interviews | interviews on a day in the week |
| events | events on a day in the week, unless marked not attended |

## CSV import

**Jobs → Import** brings in a spreadsheet saved as CSV, either applications or contacts. Your
file goes to the server as text with each step, and the server never stores it.

1. **Preview.** The wizard reads the header row and suggests a field for each column (it knows
   common names such as *Company*, *Job Title*, *Stage*, *Applied On*, *Link*, *Follow-up
   date*). You can change any mapping or skip a column. For the columns mapped to *Status* and
   *Furthest stage*, it lists each distinct value with a suggested status ("Phone screen" →
   Screen, "No response" → Ghosted, "Wishlist" → Lead). Pick one for any value it can't place.
   This is the only step that shows your cells.
2. **Dry run.** The server walks every row and reports what an import would do: rows to create,
   update, leave unchanged, or that would submit an open lead. It also lists rows that match
   existing records (row number and record id) and rows with problems. Nothing is written.
3. **Import.** The same walk, now writing. Every change is made by you (or by Claude, when it
   runs the import) in one batch.
4. **Undo.** *Undo this import* reverts that batch. What has been worked on since is left alone
   and counted as a conflict: a field you've edited since, and a record the import created that
   has changed since (edited, given a status change, an interview or a history edit), which
   stays with its whole history. A company stays while it has applications or contacts.

Rules:

- **Fields.** Applications: company and title (required), status, date applied, status date,
  furthest stage, date found, location, posting URL, source, next action, next action due,
  notes, tags. Contacts: name (required), company, role, email, profile URL, contacted on,
  replied on, next action, next action due, notes, tags.
- **Natural keys make it idempotent.** An application is (company, title, date applied) and a
  contact is (name, company), with names and titles folded as described above. Importing the
  same file twice changes nothing the second time.
- **A matched row** updates only the fields whose cells are filled and differ. Its status, and
  its furthest stage, are added to the history only if the history doesn't have them yet.
  Blank cells never clear anything.
- **History for new rows.** A new submitted row gets *applied* on its date, then its furthest
  stage if one is given, then its status (dated with the status date when mapped). A row with no
  status is a lead when it has no date applied, and applied when it has one.
- **Leads.** A row past the lead stage that matches exactly one open lead submits that lead. A
  lead row (no date applied, a lead status) matches the posting with the same title whatever
  its status, so a lead you've applied to since isn't logged again when you re-import.
- **Companies** named in the file are matched by folded name and created when new.
- **Dates** may be ISO (2026-11-05), US (11/5/2026, 11/5/26), day-first (5/11/2026, when you
  tick *Dates are day/month/year*), written out (Nov 5, 2026; 5 November 2026), or spreadsheet
  serial numbers. The wizard suggests day-first when some date only reads that way.
- **Unmapped columns** are kept on an application as imported columns (`extra`), unless you turn
  that off.
- **Problems** don't stop the import. A row is skipped for `missing_company`, `missing_title`,
  `missing_name`, `unknown_status` (in the status column), `duplicate_row` (same key as an
  earlier row) or `too_long` in the company, title or name. A date that can't be read
  (`bad_date`), a date found in the future (`future_date`), an unknown furthest stage, other
  text longer than the app takes (`too_long`) or more than 30 tags (`too_many_tags`) only leaves
  that field out.
- **Reports** (dry run and import) carry counts, codes, row numbers, field names and record ids.
  They never carry cell text.
- **Limits:** 5 MB, 10,000 rows and 500 columns per file, and 128 KB per cell; a file past them
  is refused with the line number. Empty cells at the end of a row don't count as columns. Text
  fields take what the app takes (see [The model](#the-model)). Comma, semicolon and tab
  separators are detected, and a byte-order mark is ignored.

## On the calendar

| Source | Shows | Editable in the drawer |
|---|---|---|
| Interviews | Each interview with a day. With a start time it lasts its duration (an hour by default); without one it's all day. | Day, time, duration, stage, place, interviewer, notes, which application it belongs to; delete |
| Job events | Each event, timed when it has a start time | Every field; delete |
| Follow-ups | All day on the due date of each contact's and application's next action | The next action and its due date; *Done* clears both |

## API

Everything is under `/api/jobs` and needs the `api` scope (or the signed-in browser).

| Route | What it does |
|---|---|
| `GET/POST /companies`, `GET/PATCH/DELETE /companies/{id}` | Companies. `reuse_existing` on create returns the existing company instead of a 409. A company with applications or contacts can't be deleted. |
| `GET/POST /applications`, `GET/PATCH/DELETE /applications/{id}` | Applications. Filters: `status` (repeatable), `company_id`, `tag`, `applied_from`, `applied_to`, `q`, `due_by`, `leads=exclude\|include\|only`. Create takes `company_id` or a `company` name. PATCH takes `force` to rename an open lead onto a tracked posting. Delete takes the status history and interviews with it, and History restores them together. |
| `GET/POST /applications/{id}/status` | The status history, oldest first; add a dated status change |
| `POST /applications/{id}/apply`, `POST /applications/{id}/drop` | Submit or drop an open lead |
| `PATCH/DELETE /status-events/{id}` | Fix a status change's date, status or note; the status follows. Refused when the history would stop agreeing with the application ([Status history](#status-history)). |
| `GET/POST /leads` | Open leads (`include_dropped` adds the dropped ones); log a lead (`force` for a repost) |
| `GET/POST /contacts`, `GET/PATCH/DELETE /contacts/{id}` | Contacts. Filters: `company_id`, `tag`, `q`, `due_by` |
| `GET/POST /interviews`, `GET/PATCH/DELETE /interviews/{id}` | Interviews. Filters: `application_id`, `upcoming` |
| `GET/POST /events`, `GET/PATCH/DELETE /events/{id}` | Job events. Filters: `start`, `end` |
| `GET/POST /goals`, `PATCH/DELETE /goals/{id}`, `GET /goals/progress?week=` | Weekly goals and a week's progress |
| `GET/POST /statuses`, `PATCH/DELETE /statuses/{key}`, `PUT /statuses/order` | The status list |
| `GET /pipeline` | The counts above; takes the applications filters |
| `GET /tags` | Every tag in use |
| `POST /import/preview`, `/import/dry-run`, `/import/commit`, `/import/undo` | The CSV import |

## History and reverts

Records that depend on each other stay consistent when you revert one change:

- Reverting a status change also undoes the rest of that change on the application: the
  status-history entry it added, and for *Apply* the date applied. The status is derived again.
- Reverting a change to the status history derives the application's status again. It is
  refused when it would break the [status history](#status-history) rules, for example
  reverting the *applied* entry of an *Apply* on its own, or the only entry.
- Reverting an application's delete restores the status history and interviews deleted with it.
- Reverting an application's creation removes its status history and interviews too.
- A revert that would bring back a status no longer in the list, remove a reserved or used
  status, or restore a company whose name another company has taken since is refused.

## Demo data

`app.modules.jobs.demo.seed(session)` fills an empty tracker with a made-up search: eight
companies, applications in every status with their history, open and dropped leads, contacts
with next actions due, two interviews and a career fair this week, and two weekly goals. Every
name is fictional and dates are relative to today. It writes as `system` and does nothing if a
company already exists.
