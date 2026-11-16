import { KeyRound, LogOut } from "lucide-react";
import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import { MIN_PASSWORD_LENGTH, useSignOut } from "@/app/auth";
import { Field } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import { useAppSettings, useChangePassword } from "./api";
import { FormError, Section } from "./Section";

/** Change the password; sign out (the only way to on a phone); the secret-key warning. */
export function SecuritySection() {
  const settings = useAppSettings();
  const change = useChangePassword();
  const signOut = useSignOut();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);

  function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!current) return setError("Enter your current password.");
    if (next.length < MIN_PASSWORD_LENGTH)
      return setError(`The new password needs at least ${MIN_PASSWORD_LENGTH} characters.`);
    if (next !== confirm) return setError("The two new passwords don't match.");
    change.mutate(
      { current_password: current, new_password: next },
      {
        onSuccess: () => {
          toast.success("Password changed");
          setCurrent("");
          setNext("");
          setConfirm("");
        },
        onError: (err) => setError(err.message),
      },
    );
  }

  return (
    <Section
      id="security"
      title="Security"
      description="One password signs you in on every device."
      actions={
        <Button
          variant="outline"
          size="sm"
          disabled={signOut.isPending}
          onClick={() =>
            signOut.mutate(undefined, {
              onError: (err) => toast.error(`Could not sign out cleanly: ${err.message}`),
            })
          }
        >
          <LogOut />
          Sign out
        </Button>
      }
    >
      {settings.data && !settings.data.secret_key_configured && (
        <div
          role="status"
          className="mb-4 flex gap-2.5 rounded-md border border-status-stale/40 bg-status-stale/10 px-3 py-2.5 text-[13px]"
        >
          <KeyRound className="mt-0.5 size-4 shrink-0 text-status-stale" aria-hidden />
          <p>
            <code className="font-mono text-[12px]">ORGANIZER_SECRET_KEY</code> is not set. Set it
            in <code className="font-mono text-[12px]">.env</code> and restart the server before
            you connect any accounts: their credentials are encrypted with it.
          </p>
        </div>
      )}
      <form onSubmit={submit} className="space-y-3">
        {/* Lets password managers tie the new password to this install. */}
        <input type="text" autoComplete="username" hidden readOnly value="organizer" />
        <Field label="Current password" htmlFor="pw-current" className="sm:grid-cols-[8rem_1fr]">
          <Input
            id="pw-current"
            type="password"
            autoComplete="current-password"
            value={current}
            onChange={(e) => setCurrent(e.target.value)}
            className="max-w-sm"
          />
        </Field>
        <Field label="New password" htmlFor="pw-new" className="sm:grid-cols-[8rem_1fr]">
          <Input
            id="pw-new"
            type="password"
            autoComplete="new-password"
            value={next}
            onChange={(e) => setNext(e.target.value)}
            placeholder={`at least ${MIN_PASSWORD_LENGTH} characters`}
            className="max-w-sm"
          />
        </Field>
        <Field label="Confirm" htmlFor="pw-confirm" className="sm:grid-cols-[8rem_1fr]">
          <Input
            id="pw-confirm"
            type="password"
            autoComplete="new-password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            className="max-w-sm"
          />
        </Field>
        <FormError message={error} />
        <div className="flex justify-end pt-1">
          <Button
            type="submit"
            size="sm"
            disabled={change.isPending || !current || !next || !confirm}
          >
            {change.isPending ? "Changing…" : "Change password"}
          </Button>
        </div>
      </form>
    </Section>
  );
}
