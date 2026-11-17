import { useEffect } from "react";
import { useSearchParams } from "react-router";
import { toast } from "sonner";

import { PageHeader } from "@/components/PageHeader";

import { AccountsSection } from "./AccountsSection";
import { GeneralSection } from "./GeneralSection";
import { SecuritySection } from "./SecuritySection";
import { TokensSection } from "./TokensSection";

/** Everything you can set for this install, on one page. */
export default function SettingsPage() {
  useGoogleReturn();
  return (
    <>
      <PageHeader title="Settings" />
      <div className="min-h-0 flex-1 overflow-y-auto scrollbar-thin">
        <div className="mx-auto flex max-w-3xl flex-col gap-5 p-4 md:p-6">
          <GeneralSection />
          <SecuritySection />
          <TokensSection />
          <AccountsSection />
        </div>
      </div>
    </>
  );
}

/** Google's consent flow ends back here with ?google=connected|error&detail=...; say so once. */
function useGoogleReturn() {
  const [params, setParams] = useSearchParams();
  const result = params.get("google");
  const detail = params.get("detail") ?? "";
  useEffect(() => {
    if (!result) return;
    if (result === "connected") toast.success(`Connected ${detail || "your Google account"}`);
    else toast.error(detail === "cancelled" ? "Google sign-in was cancelled" : `Google: ${detail}`);
    setParams({}, { replace: true });
    document.getElementById("accounts-title")?.scrollIntoView();
  }, [result, detail, setParams]);
}
