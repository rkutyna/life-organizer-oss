import { Plus } from "lucide-react";
import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";

import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { sentence } from "@/lib/utils";

import { jobsApi, useJobsMutation, useStatusInfo, type ApplicationCreated } from "./api";
import { CompanyPicker } from "./CompanyPicker";
import { today } from "./format";
import { QUICK_ADD_ID } from "./parts";

/**
 * One line to log a submitted application: company (picked or new), title, status, date.
 * An open lead with the same title at the company is submitted in place by the server; the
 * toast says so, or lists the leads when several matched.
 */
export function ApplicationQuickAdd() {
  const navigate = useNavigate();
  const info = useStatusInfo();
  const create = useJobsMutation(jobsApi.createApplication);
  const [company, setCompany] = useState("");
  const [title, setTitle] = useState("");
  const [status, setStatus] = useState("applied");
  const [date, setDate] = useState(today());

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!company.trim() || !title.trim()) {
      toast.error("Give a company and a title");
      return;
    }
    try {
      const created = await create.mutateAsync({
        company: company.trim(),
        title: title.trim(),
        status: status || null,
        date_applied: date || null,
      });
      announce(created);
      setTitle("");
      setCompany("");
      setDate(today());
      document.getElementById(QUICK_ADD_ID)?.focus();
    } catch (error) {
      toast.error(`Could not add: ${sentence((error as Error).message)}`);
    }
  }

  function announce(created: ApplicationCreated) {
    const open = { label: "Open", onClick: () => navigate(`/jobs/applications/${created.id}`) };
    if (created.promoted_from_lead) {
      toast.success("Submitted your open lead", {
        description: `${created.title} at ${created.company} moved from Leads to Applications.`,
        action: open,
      });
    } else if (created.lead_candidates?.length) {
      const ids = created.lead_candidates;
      toast.warning(`${ids.length} open leads have this title`, {
        description: (
          <span className="flex flex-wrap gap-x-2">
            None was submitted. Open:
            {ids.map((id) => (
              <button
                key={id}
                type="button"
                className="text-primary underline"
                onClick={() => navigate(`/jobs/applications/${id}`)}
              >
                lead {id}
              </button>
            ))}
          </span>
        ),
        action: open,
        duration: 15_000,
      });
    } else {
      toast.success(
        created.company_created ? `Added, with the new company ${created.company}` : "Application added",
        { action: open },
      );
    }
  }

  return (
    <form
      onSubmit={submit}
      aria-label="Add an application"
      className="grid gap-2 rounded-lg border border-dashed border-border p-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)_9rem_9.5rem_auto]"
    >
      <div className="min-w-0">
        <CompanyPicker
          id={QUICK_ADD_ID}
          value={company}
          onValueChange={setCompany}
          placeholder="Company (new or existing)"
        />
      </div>
      <Input
        aria-label="Title"
        placeholder="Title, e.g. Software Engineer"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        className="h-8 text-[13px]"
      />
      <NativeSelect aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
        {info.options("active", "closed").map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </NativeSelect>
      <Input
        type="date"
        aria-label="Date applied"
        value={date}
        onChange={(e) => setDate(e.target.value)}
        className="h-8 text-[13px]"
      />
      <Button type="submit" size="sm" disabled={create.isPending}>
        <Plus />
        Add
      </Button>
    </form>
  );
}
