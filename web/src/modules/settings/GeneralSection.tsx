import { useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";

import { Field } from "@/components/Field";
import { HolidayCountrySelect, TimezoneSelect } from "@/components/RegionFields";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";

import { useAppSettings, useUpdateSettings, type AppSettings } from "./api";
import { FormError, Section } from "./Section";

/** Display name, time zone and holidays. Saves only the fields that changed. */
export function GeneralSection() {
  const settings = useAppSettings();
  return (
    <Section
      id="general"
      title="General"
      description="Your name as the organizer shows it, and how it lays out your calendar."
    >
      {settings.data ? (
        <GeneralForm settings={settings.data} />
      ) : settings.isError ? (
        <FormError message={`Could not load settings: ${settings.error.message}`} />
      ) : (
        <div className="space-y-3">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
        </div>
      )}
    </Section>
  );
}

function GeneralForm({ settings }: { settings: AppSettings }) {
  const update = useUpdateSettings();
  const [displayName, setDisplayName] = useState(settings.display_name);
  const [timezone, setTimezone] = useState(settings.timezone);
  const [country, setCountry] = useState<string | null>(settings.holiday_country);
  const [error, setError] = useState<string | null>(null);

  // Follow the server when it changes underneath (another tab, a refetch after save).
  useEffect(() => {
    setDisplayName(settings.display_name);
    setTimezone(settings.timezone);
    setCountry(settings.holiday_country);
  }, [settings]);

  const changes = {
    ...(displayName.trim() !== settings.display_name && { display_name: displayName.trim() }),
    ...(timezone !== settings.timezone && { timezone }),
    ...(country !== settings.holiday_country && { holiday_country: country }),
  };
  const dirty = Object.keys(changes).length > 0;

  function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!displayName.trim()) return setError("The display name can't be empty.");
    update.mutate(changes, {
      onSuccess: () => toast.success("Settings saved"),
      onError: (err) => setError(err.message),
    });
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <Field label="Display name" htmlFor="settings-name" className="sm:grid-cols-[8rem_1fr]">
        <Input
          id="settings-name"
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          className="max-w-sm"
        />
      </Field>
      <Field label="Time zone" htmlFor="settings-timezone" className="sm:grid-cols-[8rem_1fr]">
        <TimezoneSelect
          id="settings-timezone"
          value={timezone}
          onChange={setTimezone}
          className="max-w-sm"
        />
      </Field>
      <Field label="Public holidays" htmlFor="settings-holidays" className="sm:grid-cols-[8rem_1fr]">
        <HolidayCountrySelect
          id="settings-holidays"
          value={country}
          onChange={setCountry}
          className="max-w-sm"
        />
      </Field>
      <FormError message={error} />
      <div className="flex justify-end gap-2 pt-1">
        {dirty && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => {
              setDisplayName(settings.display_name);
              setTimezone(settings.timezone);
              setCountry(settings.holiday_country);
              setError(null);
            }}
          >
            Discard
          </Button>
        )}
        <Button type="submit" size="sm" disabled={!dirty || update.isPending}>
          {update.isPending ? "Saving…" : "Save"}
        </Button>
      </div>
    </form>
  );
}
