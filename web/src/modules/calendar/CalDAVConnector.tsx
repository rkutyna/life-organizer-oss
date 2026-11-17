import { ArrowUpRight } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import type { AccountConnector, AccountConnectorProps } from "@/app/modules";
import { Field } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { sentence } from "@/lib/utils";

import { useConnectCalDAV } from "./externalApi";

const APPLE_APP_PASSWORDS = "https://support.apple.com/en-us/102654";

type Preset = "icloud" | "caldav";

/**
 * Settings → Add account → iCloud or CalDAV calendar. The server signs in before saving, so a
 * wrong password is reported here and nothing is stored.
 */
function CalDAVForm({ preset, onDone, onCancel }: AccountConnectorProps & { preset: Preset }) {
  const connect = useConnectCalDAV();
  const [url, setUrl] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [label, setLabel] = useState("");
  const icloud = preset === "icloud";

  function submit(event: FormEvent) {
    event.preventDefault();
    connect.mutate(
      {
        preset,
        username: username.trim(),
        password,
        url: icloud ? null : url.trim(),
        label: label.trim() || null,
      },
      {
        onSuccess: (account) => {
          toast.success(
            `${account.label} connected: ${account.calendars} calendar${account.calendars === 1 ? "" : "s"}. Events arrive in a moment.`,
          );
          onDone();
        },
      },
    );
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      <DialogHeader>
        <DialogTitle className="text-base">
          {icloud ? "Connect iCloud calendars" : "Connect a CalDAV calendar"}
        </DialogTitle>
        <DialogDescription className="text-[13px]">
          {icloud ? (
            <>
              Use your Apple ID and an app-specific password, not your Apple ID password.{" "}
              <a
                href={APPLE_APP_PASSWORDS}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-0.5 text-foreground underline underline-offset-2"
              >
                How to make one
                <ArrowUpRight className="size-3" aria-hidden />
              </a>
            </>
          ) : (
            "Any CalDAV server: Fastmail, Nextcloud, Radicale and others. Calendars are only read."
          )}
        </DialogDescription>
      </DialogHeader>

      <div className="grid gap-2.5">
        {!icloud && (
          <Field label="Server URL" htmlFor="caldav-url">
            <Input
              id="caldav-url"
              type="url"
              required
              autoFocus
              placeholder="https://caldav.example.com/"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
            />
          </Field>
        )}
        <Field label={icloud ? "Apple ID" : "Username"} htmlFor="caldav-username">
          <Input
            id="caldav-username"
            required
            autoFocus={icloud}
            autoComplete="username"
            type={icloud ? "email" : "text"}
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </Field>
        <Field label={icloud ? "App password" : "Password"} htmlFor="caldav-password">
          <Input
            id="caldav-password"
            type="password"
            required
            autoComplete="off"
            placeholder={icloud ? "xxxx-xxxx-xxxx-xxxx" : undefined}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </Field>
        <Field label="Name" htmlFor="caldav-label">
          <Input
            id="caldav-label"
            placeholder={icloud ? "iCloud" : "The server's name"}
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
        </Field>
      </div>

      {connect.error && (
        <p role="alert" className="text-[13px] text-status-error">
          {sentence(connect.error.message)}
        </p>
      )}
      <DialogFooter>
        <Button type="button" variant="outline" size="sm" onClick={onCancel}>
          Back
        </Button>
        <Button type="submit" size="sm" disabled={connect.isPending}>
          {connect.isPending ? "Signing in…" : "Connect"}
        </Button>
      </DialogFooter>
    </form>
  );
}

export const calendarConnectors: AccountConnector[] = [
  {
    key: "icloud-calendar",
    label: "iCloud calendar",
    description: "Your iCloud calendars, with an app-specific password. No Mac needed.",
    order: 10,
    form: (props) => <CalDAVForm preset="icloud" {...props} />,
  },
  {
    key: "caldav-calendar",
    label: "CalDAV calendar",
    description: "Any CalDAV server, by URL, username and password.",
    order: 20,
    form: (props) => <CalDAVForm preset="caldav" {...props} />,
  },
];
