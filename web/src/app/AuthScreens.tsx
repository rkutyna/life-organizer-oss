import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";

import {
  browserRegion,
  browserTimezone,
  HolidayCountrySelect,
  TimezoneSelect,
  useHolidayCountries,
  useTimezones,
} from "@/components/RegionFields";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { sentence } from "@/lib/utils";

import { MIN_PASSWORD_LENGTH, useLogin, useSetup } from "./auth";
import { ThemeToggle } from "./ThemeToggle";

/** The frame both screens share: a centered card on the page background. */
function AuthLayout({
  title,
  description,
  children,
}: {
  title: string;
  description: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="flex min-h-dvh flex-col bg-background">
      <div className="flex justify-end p-3">
        <ThemeToggle />
      </div>
      <main className="flex flex-1 items-start justify-center px-4 pt-[8vh] pb-12">
        <div className="w-full max-w-sm">
          <div className="mb-6 flex flex-col items-center gap-3 text-center">
            <img src="/icon.svg" alt="" className="size-10 rounded-[10px]" />
            <div className="space-y-1">
              <h1 className="text-lg font-semibold tracking-tight">{title}</h1>
              <p className="text-[13px] text-muted-foreground">{description}</p>
            </div>
          </div>
          <div className="rounded-lg border border-border bg-card p-5 shadow-xs">{children}</div>
        </div>
      </main>
    </div>
  );
}

function Label({ htmlFor, children, hint }: { htmlFor: string; children: ReactNode; hint?: ReactNode }) {
  return (
    <div className="mb-1.5 flex items-baseline justify-between gap-2">
      <label htmlFor={htmlFor} className="text-[13px] font-medium">
        {children}
      </label>
      {hint && <span className="text-xs text-muted-foreground">{hint}</span>}
    </div>
  );
}

function FormError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <p role="alert" className="rounded-md bg-status-error/10 px-3 py-2 text-[13px] text-status-error">
      {sentence(message)}
    </p>
  );
}

/** First run: name, password, time zone and holidays. Posts /api/auth/setup. */
export function SetupScreen() {
  const setup = useSetup();
  const { zones } = useTimezones();
  const countries = useHolidayCountries();

  const [displayName, setDisplayName] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [timezone, setTimezone] = useState("");
  const [country, setCountry] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Default the time zone to the browser's once the list is in, if the list has it.
  const tzChosen = useRef(false);
  useEffect(() => {
    if (tzChosen.current || !zones?.length) return;
    tzChosen.current = true;
    const local = browserTimezone();
    setTimezone(zones.includes(local) ? local : zones.includes("UTC") ? "UTC" : zones[0]);
  }, [zones]);

  // Default the holidays to the browser locale's region, if it is in the list.
  const countryChosen = useRef(false);
  useEffect(() => {
    if (countryChosen.current || !countries.data) return;
    countryChosen.current = true;
    const region = browserRegion();
    if (region && countries.data.some((c) => c.code === region)) setCountry(region);
  }, [countries.data]);

  function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    const name = displayName.trim();
    if (!name) return setError("Enter a display name.");
    if (password.length < MIN_PASSWORD_LENGTH)
      return setError(`The password needs at least ${MIN_PASSWORD_LENGTH} characters.`);
    if (password !== confirm) return setError("The two passwords don't match.");
    if (!timezone) return setError("Choose a time zone.");
    setup.mutate(
      { display_name: name, password, timezone, holiday_country: country },
      { onError: (err) => setError(err.message) },
    );
  }

  return (
    <AuthLayout
      title="Set up Life Organizer for Mac"
      description="This runs once. You can change any of it later in Settings."
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <div>
          <Label htmlFor="setup-name">Display name</Label>
          <Input
            id="setup-name"
            autoFocus
            autoComplete="name"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
          />
        </div>
        <div>
          <Label htmlFor="setup-password" hint={`at least ${MIN_PASSWORD_LENGTH} characters`}>
            Password
          </Label>
          <Input
            id="setup-password"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <div>
          <Label htmlFor="setup-confirm">Confirm password</Label>
          <Input
            id="setup-confirm"
            type="password"
            autoComplete="new-password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
          />
        </div>
        <div>
          <Label htmlFor="setup-timezone">Time zone</Label>
          <TimezoneSelect id="setup-timezone" value={timezone} onChange={setTimezone} />
        </div>
        <div>
          <Label htmlFor="setup-holidays" hint="shown on the calendar">
            Public holidays
          </Label>
          <HolidayCountrySelect id="setup-holidays" value={country} onChange={setCountry} />
          {countries.isError && (
            <p className="mt-1 text-xs text-muted-foreground">
              The country list did not load. You can choose one later in Settings.
            </p>
          )}
        </div>
        <FormError message={error} />
        <Button type="submit" className="w-full" disabled={setup.isPending}>
          {setup.isPending ? "Setting up…" : "Finish setup"}
        </Button>
      </form>
    </AuthLayout>
  );
}

/** Password only: there is one user per install. */
export function LoginScreen({ displayName }: { displayName: string | null }) {
  const login = useLogin();
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);

  function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!password) return setError("Enter your password.");
    login.mutate(password, {
      onError: (err) => {
        setError(err.message);
        setPassword("");
      },
    });
  }

  return (
    <AuthLayout
      title="Life Organizer for Mac"
      description={displayName ? `Welcome back, ${displayName}. Sign in to continue.` : "Welcome back. Sign in to continue."}
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <div>
          <Label htmlFor="login-password">Password</Label>
          <Input
            id="login-password"
            type="password"
            autoFocus
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <FormError message={error} />
        <Button type="submit" className="w-full" disabled={login.isPending}>
          {login.isPending ? "Signing in…" : "Sign in"}
        </Button>
      </form>
    </AuthLayout>
  );
}

/** Before the auth state is known, or when the server cannot be reached. */
export function AuthPending({ error, onRetry }: { error?: string; onRetry?: () => void }) {
  return (
    <div className="flex min-h-dvh items-center justify-center bg-background px-4">
      {error ? (
        <div className="max-w-sm space-y-3 text-center">
          <p className="text-[13px] font-medium">Can't reach the organizer server</p>
          <p className="text-[13px] text-muted-foreground">{error}</p>
          {onRetry && (
            <Button variant="outline" size="sm" onClick={onRetry}>
              Try again
            </Button>
          )}
        </div>
      ) : (
        <p className="text-[13px] text-muted-foreground">Loading…</p>
      )}
    </div>
  );
}
