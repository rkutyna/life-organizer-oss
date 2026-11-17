import { Navigate, NavLink, Route, Routes, useNavigate } from "react-router";

import { PageHeader } from "@/components/PageHeader";
import { useHotkeys } from "@/lib/hotkeys";
import { cn } from "@/lib/utils";

import ApplicationPage from "./ApplicationPage";
import ApplicationsPage from "./ApplicationsPage";
import CompaniesPage from "./CompaniesPage";
import CompanyPage from "./CompanyPage";
import ContactPage from "./ContactPage";
import ContactsPage from "./ContactsPage";
import EventsPage from "./EventsPage";
import ImportPage from "./ImportPage";
import InterviewsPage from "./InterviewsPage";
import LeadsPage from "./LeadsPage";
import OverviewPage from "./OverviewPage";
import { QUICK_ADD_ID } from "./parts";
import StatusSettingsPage from "./StatusSettingsPage";

const TABS = [
  { to: "/jobs", label: "Overview", end: true },
  { to: "/jobs/applications", label: "Applications" },
  { to: "/jobs/leads", label: "Leads" },
  { to: "/jobs/companies", label: "Companies" },
  { to: "/jobs/contacts", label: "Contacts" },
  { to: "/jobs/interviews", label: "Interviews" },
  { to: "/jobs/events", label: "Events" },
  { to: "/jobs/import", label: "Import" },
  { to: "/jobs/settings", label: "Settings" },
];

/**
 * The job tracker: one header with the sections as tabs, then the section's page. The shell
 * mounts this at `/jobs/*`, so the routes below are relative to /jobs.
 *
 * Keys: 1-9 switch sections, n focuses the page's add form, / the table filter.
 */
export default function JobsPage() {
  const navigate = useNavigate();
  const sectionKeys = Object.fromEntries(
    TABS.map((tab, index) => [String(index + 1), () => navigate(tab.to)]),
  );
  useHotkeys({
    ...sectionKeys,
    n: () => document.getElementById(QUICK_ADD_ID)?.focus(),
    "/": () =>
      document.querySelector<HTMLInputElement>('main input[aria-label="Filter rows"]')?.focus(),
  });

  return (
    <>
      <PageHeader title="Jobs">
        <nav
          aria-label="Job sections"
          className="-mx-1 flex gap-1 overflow-x-auto px-1 pb-0.5 scrollbar-none"
        >
          {TABS.map((tab, index) => (
            <NavLink
              key={tab.to}
              to={tab.to}
              end={tab.end}
              title={`${tab.label} (${index + 1})`}
              className={({ isActive }) =>
                cn(
                  "shrink-0 rounded-md px-2.5 py-1 text-[13px] text-muted-foreground transition-colors hover:bg-accent hover:text-foreground",
                  isActive && "bg-accent font-medium text-foreground",
                )
              }
            >
              {tab.label}
            </NavLink>
          ))}
        </nav>
      </PageHeader>

      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto scrollbar-thin">
        <div className="mx-auto w-full max-w-6xl p-4 md:p-6">
          <Routes>
            <Route index element={<OverviewPage />} />
            <Route path="applications" element={<ApplicationsPage />} />
            <Route path="applications/:applicationId" element={<ApplicationPage />} />
            <Route path="leads" element={<LeadsPage />} />
            <Route path="companies" element={<CompaniesPage />} />
            <Route path="companies/:companyId" element={<CompanyPage />} />
            <Route path="contacts" element={<ContactsPage />} />
            <Route path="contacts/:contactId" element={<ContactPage />} />
            <Route path="interviews" element={<InterviewsPage />} />
            <Route path="events" element={<EventsPage />} />
            <Route path="import" element={<ImportPage />} />
            <Route path="settings" element={<StatusSettingsPage />} />
            <Route path="*" element={<Navigate to="/jobs" replace />} />
          </Routes>
        </div>
      </div>
    </>
  );
}
