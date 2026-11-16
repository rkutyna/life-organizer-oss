import { PageHeader } from "@/components/PageHeader";

import { AccountsSection } from "./AccountsSection";
import { GeneralSection } from "./GeneralSection";
import { SecuritySection } from "./SecuritySection";
import { TokensSection } from "./TokensSection";

/** Everything you can set for this install, on one page. */
export default function SettingsPage() {
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
