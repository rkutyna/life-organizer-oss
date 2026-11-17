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

/**
 * What the server's Google redirect may report. Only these fixed words are ever shown: anyone
 * can link to /settings?google=..., so nothing from the URL itself reaches the page.
 */
const GOOGLE_RESULTS: Record<string, string> = {
  cancelled: "Google sign-in was cancelled.",
  denied: "Google did not grant access. Try again from Add account.",
  state: "That Google sign-in link was already used or is unknown. Start again from Add account.",
  expired: "The Google sign-in took too long. Start again from Add account.",
  rejected: "Google did not accept the sign-in. Check the OAuth client settings in docs/GOOGLE.md.",
  identity: "Google did not say which account this is. Try again.",
  no_refresh_token:
    "Google sent no lasting sign-in. Remove this app's access in your Google account settings, then try again.",
  unreachable: "Google could not be reached. Try again.",
};

/** Google's consent flow ends back here with ?google=<result>; say so once. */
function useGoogleReturn() {
  const [params, setParams] = useSearchParams();
  const result = params.get("google");
  useEffect(() => {
    if (!result) return;
    if (result === "connected") toast.success("Google account connected.");
    else toast.error(GOOGLE_RESULTS[result] ?? "Connecting the Google account failed. Try again.");
    setParams({}, { replace: true });
    document.getElementById("accounts-title")?.scrollIntoView();
  }, [result, setParams]);
}
