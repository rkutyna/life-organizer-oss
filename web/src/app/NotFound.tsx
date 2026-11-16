import { Link } from "react-router";

import { EmptyState } from "@/components/EmptyState";
import { PageHeader } from "@/components/PageHeader";

export function NotFound() {
  return (
    <>
      <PageHeader title="Not found" />
      <EmptyState
        title="Nothing lives at this address"
        description={
          <Link to="/" className="text-primary hover:underline">
            Back to the calendar
          </Link>
        }
      />
    </>
  );
}
