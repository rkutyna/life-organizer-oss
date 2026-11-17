import { useMutation, useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { api, unwrap } from "@/api/client";
import type { AccountConnectorProps } from "@/app/modules";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";

import { FormError } from "./Section";

type Feature = "calendar" | "gmail" | "tasks";

const FEATURES: { value: Feature; label: string; hint: string; available: boolean }[] = [
  { value: "calendar", label: "Calendar", hint: "Read your Google calendars.", available: true },
  { value: "gmail", label: "Gmail", hint: "Read mail headers; open a message on demand.", available: true },
  { value: "tasks", label: "Tasks", hint: "Read and update your Google Tasks lists as reminders.", available: true },
];

/** Settings → Add account → Google: pick what to read, then go to Google's consent screen. */
export function GoogleConnector({ onCancel }: AccountConnectorProps) {
  const status = useQuery({
    queryKey: ["settings", "google"],
    queryFn: () => unwrap(api.GET("/api/settings/google")),
  });
  const [chosen, setChosen] = useState<Set<Feature>>(new Set(["calendar", "gmail"]));
  const start = useMutation({
    mutationFn: (features: Feature[]) =>
      unwrap(api.POST("/api/settings/google/start", { body: { features } })),
    // Leave for Google; it sends the browser back to Settings when done.
    onSuccess: ({ authorize_url }) => window.location.assign(authorize_url),
  });

  function toggle(feature: Feature, on: boolean) {
    const next = new Set(chosen);
    if (on) next.add(feature);
    else next.delete(feature);
    setChosen(next);
  }

  return (
    <div className="grid gap-4">
      <DialogHeader>
        <DialogTitle className="text-base">Connect a Google account</DialogTitle>
        <DialogDescription className="text-[13px]">
          Google asks you to confirm. The organizer only reads what you choose here.
        </DialogDescription>
      </DialogHeader>

      {status.isPending ? (
        <Skeleton className="h-24 w-full" />
      ) : status.isError ? (
        <FormError message={status.error.message} />
      ) : !status.data.configured ? (
        <div className="space-y-2 text-[13px] text-muted-foreground">
          <p>Google needs an OAuth client of your own first. Once, in Google Cloud Console:</p>
          <ol className="list-decimal space-y-1 pl-5">
            <li>Create a project, enable the Google Calendar API, the Gmail API and the Google Tasks API.</li>
            <li>
              Configure the OAuth consent screen as an External app, add yourself as a user, and
              publish it (in Testing mode, Google's sign-in expires after 7 days).
            </li>
            <li>
              Create an OAuth client ID of type <em>Web application</em> with this redirect URI:
              <code className="mt-1 block rounded bg-muted px-2 py-1 font-mono text-xs break-all text-foreground">
                {status.data.redirect_uri}
              </code>
            </li>
            <li>
              Put its ID and secret in <code>.env</code> as <code>GOOGLE_CLIENT_ID</code> and{" "}
              <code>GOOGLE_CLIENT_SECRET</code>, then run <code>docker compose up -d</code> (a plain restart does not read <code>.env</code> again).
            </li>
          </ol>
          <p>The full steps are in docs/GOOGLE.md.</p>
        </div>
      ) : (
        <fieldset className="grid gap-2.5">
          <legend className="sr-only">What to read</legend>
          {FEATURES.map((feature) => (
            <label
              key={feature.value}
              className="flex items-start gap-2.5 text-[13px] has-[button:disabled]:opacity-60"
            >
              <Checkbox
                className="mt-0.5"
                checked={chosen.has(feature.value)}
                disabled={!feature.available}
                onCheckedChange={(on) => toggle(feature.value, on === true)}
              />
              <span>
                <span className="font-medium">{feature.label}</span>
                <span className="block text-xs text-muted-foreground">{feature.hint}</span>
              </span>
            </label>
          ))}
        </fieldset>
      )}

      <FormError message={start.error?.message} />
      <DialogFooter>
        <Button type="button" variant="outline" size="sm" onClick={onCancel}>
          Back
        </Button>
        {status.data?.configured && (
          <Button
            size="sm"
            disabled={chosen.size === 0 || start.isPending}
            onClick={() => start.mutate([...chosen])}
          >
            Continue to Google
          </Button>
        )}
      </DialogFooter>
    </div>
  );
}
