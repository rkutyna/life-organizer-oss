import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import type { AccountConnectorProps } from "@/app/modules";
import { Field, NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { sentence } from "@/lib/utils";

import { useConnectImap, useImapPresets } from "./api";

const CUSTOM = "custom";

/**
 * Settings → Add account → Email (IMAP). The server signs in (read-only) before saving, so a
 * wrong password is reported here and nothing is stored. The password is kept encrypted.
 */
export function ImapConnector({ onDone, onCancel }: AccountConnectorProps) {
  const presets = useImapPresets();
  const connect = useConnectImap();
  const [preset, setPreset] = useState("icloud");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [label, setLabel] = useState("");
  const [host, setHost] = useState("");
  const [port, setPort] = useState("993");
  const [authServers, setAuthServers] = useState("");

  const chosen = presets.data?.find((p) => p.key === preset);
  const custom = preset === CUSTOM;

  function submit(event: FormEvent) {
    event.preventDefault();
    connect.mutate(
      {
        preset,
        label: label.trim() || chosen?.label || host.trim() || "Mail",
        username: username.trim(),
        password,
        host: custom ? host.trim() : null,
        port: custom ? Number(port) || 993 : 993,
        auth_servers: custom
          ? authServers
              .split(/[\s,]+/)
              .map((s) => s.trim())
              .filter(Boolean)
          : [],
      },
      {
        onSuccess: (account) => {
          toast.success(`${account.label} connected. Its headers arrive in a moment.`);
          onDone();
        },
      },
    );
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      <DialogHeader>
        <DialogTitle className="text-base">Connect an email account</DialogTitle>
        <DialogDescription className="text-[13px]">
          Read only: the organizer keeps the headers of your recent mail and opens a message only
          when you do. It can never send, move, flag or delete mail.
        </DialogDescription>
      </DialogHeader>

      <div className="grid gap-2.5">
        <Field label="Provider" htmlFor="imap-preset">
          <NativeSelect
            id="imap-preset"
            className="w-full"
            value={preset}
            onChange={(e) => setPreset(e.target.value)}
          >
            {(presets.data ?? []).map((p) => (
              <option key={p.key} value={p.key}>
                {p.label}
              </option>
            ))}
            <option value={CUSTOM}>Other IMAP server</option>
          </NativeSelect>
        </Field>
        {chosen && <p className="text-xs text-muted-foreground sm:pl-[7.25rem]">{chosen.help}</p>}
        {custom && (
          <>
            <Field label="IMAP server" htmlFor="imap-host">
              <Input
                id="imap-host"
                required
                placeholder="imap.example.com"
                value={host}
                onChange={(e) => setHost(e.target.value)}
              />
              <Input
                id="imap-port"
                aria-label="Port"
                inputMode="numeric"
                className="w-20"
                value={port}
                onChange={(e) => setPort(e.target.value)}
              />
            </Field>
            <p className="text-xs text-muted-foreground sm:pl-[7.25rem]">
              TLS only (usually port 993).
            </p>
          </>
        )}
        <Field label="Email address" htmlFor="imap-username">
          <Input
            id="imap-username"
            required
            autoComplete="username"
            placeholder="you@example.com"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </Field>
        <Field label="App password" htmlFor="imap-password">
          <Input
            id="imap-password"
            type="password"
            required
            autoComplete="off"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </Field>
        <Field label="Name" htmlFor="imap-label">
          <Input
            id="imap-label"
            placeholder={chosen?.label ?? "Work mail"}
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
        </Field>
        {custom && (
          <>
            <Field label="Trusted servers" htmlFor="imap-auth">
              <Input
                id="imap-auth"
                placeholder="mx.example.com (optional)"
                value={authServers}
                onChange={(e) => setAuthServers(e.target.value)}
              />
            </Field>
            <p className="text-xs text-muted-foreground sm:pl-[7.25rem]">
              The provider's receiving servers, whose sender checks (SPF, DKIM, DMARC) can be
              believed. Leave empty and sender checks show as unknown.
            </p>
          </>
        )}
      </div>

      {(connect.error ?? presets.error) && (
        <p role="alert" className="text-[13px] text-status-error">
          {sentence((connect.error ?? presets.error)!.message)}
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
