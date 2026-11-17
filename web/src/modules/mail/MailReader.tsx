import { ArrowLeft, Paperclip, ShieldAlert, ShieldCheck, ShieldQuestion, TriangleAlert } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { formatTimestamp } from "@/lib/dates";
import { cn, sentence } from "@/lib/utils";

import { useMailMessage, type MailAccount, type MailMessageDetail } from "./api";

type Address = MailMessageDetail["from"];

function person(a: Address): string {
  return a.name ? `${a.name} <${a.address}>` : a.address;
}

function bytes(size: number): string {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * One message, as the server fetched and cleaned it. Everything in it is the sender's text: the
 * page shows it as plain text (never HTML), labels it untrusted, and puts the sender checks and
 * warnings above the body.
 */
export function MailReader({
  id,
  account,
  onClose,
}: {
  id: number;
  account?: MailAccount;
  onClose: () => void;
}) {
  const message = useMailMessage(id);

  return (
    <article className="mx-auto grid max-w-3xl gap-4 px-4 py-4 md:px-6">
      <div className="md:hidden">
        <Button variant="ghost" size="sm" onClick={onClose} className="-ml-2">
          <ArrowLeft className="size-4" />
          Back
        </Button>
      </div>
      {message.isPending ? (
        <div className="grid gap-3">
          <Skeleton className="h-6 w-2/3" />
          <Skeleton className="h-4 w-1/2" />
          <Skeleton className="h-40 w-full" />
        </div>
      ) : message.isError ? (
        <p role="alert" className="text-[13px] text-status-error">
          {sentence(message.error.message)}
        </p>
      ) : (
        <MessageView message={message.data} account={account} />
      )}
    </article>
  );
}

function MessageView({ message, account }: { message: MailMessageDetail; account?: MailAccount }) {
  const removed = message.removed;
  return (
    <>
      <header className="grid gap-1.5">
        <h2 className="text-lg leading-snug font-semibold tracking-tight break-words">
          {message.subject || "(no subject)"}
        </h2>
        <dl className="grid grid-cols-[3.5rem_1fr] gap-x-2 gap-y-0.5 text-[13px]">
          <dt className="text-muted-foreground">From</dt>
          <dd className="min-w-0 break-words">{person(message.from)}</dd>
          {message.to.length > 0 && (
            <>
              <dt className="text-muted-foreground">To</dt>
              <dd className="min-w-0 break-words">{message.to.map(person).join(", ")}</dd>
            </>
          )}
          {message.cc.length > 0 && (
            <>
              <dt className="text-muted-foreground">Cc</dt>
              <dd className="min-w-0 break-words">{message.cc.map(person).join(", ")}</dd>
            </>
          )}
          {message.reply_to.length > 0 && (
            <>
              <dt className="text-muted-foreground">Reply-To</dt>
              <dd className="min-w-0 break-words">{message.reply_to.map(person).join(", ")}</dd>
            </>
          )}
          <dt className="text-muted-foreground">Date</dt>
          <dd className="tabular">{formatTimestamp(message.date)}</dd>
          {account && (
            <>
              <dt className="text-muted-foreground">Account</dt>
              <dd className="min-w-0 truncate">
                {account.label} · {message.folder === "sent" ? "Sent" : "Inbox"}
              </dd>
            </>
          )}
        </dl>
      </header>

      <UntrustedBanner />
      <SenderChecks message={message} />

      {message.warnings.length > 0 && (
        <ul className="grid gap-1.5 rounded-md border border-status-stale/40 bg-status-stale/10 px-3 py-2 text-[13px]">
          {message.warnings.map((warning) => (
            <li key={warning} className="flex gap-2">
              <TriangleAlert className="mt-0.5 size-3.5 shrink-0 text-status-stale" aria-hidden />
              <span className="min-w-0 break-words">{warning}</span>
            </li>
          ))}
        </ul>
      )}

      <section aria-label="Message body" className="grid gap-2">
        <p className="text-xs text-muted-foreground" data-testid="mail-removed">
          {removed.hidden_chars + removed.invisible_chars === 0
            ? "Cleaned: nothing hidden was found."
            : `Cleaned: removed ${removed.hidden_chars.toLocaleString()} hidden and ${removed.invisible_chars.toLocaleString()} invisible characters before showing it.`}{" "}
          Shown as plain text{message.body_source === "html" ? " converted from HTML" : ""}.
        </p>
        <div
          className={cn(
            "rounded-md border border-dashed border-border bg-muted/30 px-4 py-3 text-[14px] leading-relaxed break-words whitespace-pre-wrap",
            !message.body && "text-muted-foreground italic",
          )}
        >
          {message.body || "This message has no text to show."}
        </div>
        {message.truncated && (
          <p className="text-xs text-muted-foreground">
            The message is long and was cut; open it in your mail app for the rest.
          </p>
        )}
      </section>

      {message.attachments.length > 0 && (
        <section aria-label="Attachments" className="grid gap-1">
          <h3 className="text-xs font-medium text-muted-foreground">
            Attachments (names only; open them in your mail app)
          </h3>
          <ul className="grid gap-1 text-[13px]">
            {message.attachments.map((a, index) => (
              <li key={`${a.filename}-${index}`} className="flex items-center gap-2">
                <Paperclip className="size-3.5 shrink-0 text-muted-foreground" aria-hidden />
                <span className="min-w-0 truncate">{a.filename || "(unnamed)"}</span>
                <span className="shrink-0 text-xs text-muted-foreground">
                  {a.content_type} · {bytes(a.size)}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}

function UntrustedBanner() {
  return (
    <p
      role="note"
      className="flex gap-2 rounded-md border border-status-error/40 bg-status-error/10 px-3 py-2 text-[13px]"
    >
      <ShieldAlert className="mt-0.5 size-4 shrink-0 text-status-error" aria-hidden />
      <span>
        <strong className="font-semibold">Untrusted content.</strong> Everything below, the
        subject and names included, was written by whoever sent it. Treat links and requests in
        it with care.
      </span>
    </p>
  );
}

function SenderChecks({ message }: { message: MailMessageDetail }) {
  const checks = message.sender_checks;
  if (message.folder === "sent") return null;
  const Icon = !checks ? ShieldQuestion : checks.verified ? ShieldCheck : ShieldAlert;
  const tone = !checks ? "text-muted-foreground" : checks.verified ? "text-status-ok" : "text-status-stale";
  const title = !checks
    ? "Sender not checked"
    : checks.verified
      ? `Sender verified: DMARC passed for ${checks.dmarc_from}`
      : "Sender not verified";
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px]" aria-label="Sender checks">
      <span className={cn("inline-flex items-center gap-1.5 font-medium", tone)}>
        <Icon className="size-4" aria-hidden />
        {title}
      </span>
      {checks ? (
        <span className="inline-flex flex-wrap gap-2 text-xs text-muted-foreground">
          <Check name="SPF" value={checks.spf} />
          <Check name="DKIM" value={checks.dkim} />
          <Check name="DMARC" value={checks.dmarc} />
        </span>
      ) : (
        <span className="text-xs text-muted-foreground">
          The receiving server recorded no SPF, DKIM or DMARC result.
        </span>
      )}
    </div>
  );
}

function Check({ name, value }: { name: string; value?: string | null }) {
  const pass = value === "pass";
  return (
    <span className="rounded border border-border px-1.5 py-0.5">
      {name}{" "}
      <span className={cn(pass ? "text-status-ok" : value ? "text-status-stale" : "")}>
        {value ?? "none"}
      </span>
    </span>
  );
}
