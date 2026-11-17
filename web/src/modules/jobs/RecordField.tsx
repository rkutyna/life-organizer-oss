import { X } from "lucide-react";
import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from "react";

import { Field, NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { toTimeInput } from "@/lib/dates";
import { cn, sentence } from "@/lib/utils";

import { useTags } from "./api";
import { isWebUrl } from "./format";

export type FieldKind =
  | "text"
  | "textarea"
  | "url"
  | "number"
  | "date"
  | "time"
  | "select"
  | "tristate"
  | "check";

export interface Option {
  value: string;
  label: string;
}

const YES_NO: Option[] = [
  { value: "true", label: "Yes" },
  { value: "false", label: "No" },
];

interface RecordFieldProps {
  label: string;
  kind: FieldKind;
  /** The stored value; null or undefined when unset. */
  value: string | number | boolean | null | undefined;
  /** Save one value (already in API form). Reject to show the error under the field. */
  onSave: (next: unknown) => Promise<unknown>;
  options?: Option[];
  /** The server does not accept null here: no "None" choice, no clear button. */
  required?: boolean;
  disabled?: boolean;
  hint?: ReactNode;
  placeholder?: string;
  /** Label of the empty choice of a select or tristate. */
  emptyLabel?: string;
  className?: string;
}

/**
 * One labelled field on a detail page that saves on its own: text on blur (Enter leaves a
 * single-line field), dates, times, selects and checkboxes on change. Each save is one PATCH of
 * just this field, so each edit is one entry in the record's history. A rejected save puts the
 * server's message under the field and restores the stored value.
 */
export function RecordField({
  label,
  kind,
  value,
  onSave,
  options: givenOptions,
  required = false,
  disabled = false,
  hint,
  placeholder,
  emptyLabel,
  className,
}: RecordFieldProps) {
  const options = givenOptions ?? (kind === "tristate" ? YES_NO : []);
  const id = useId();
  const stored = toDraft(value, kind);
  const [draft, setDraft] = useState(stored);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const focused = useRef(false);

  // Pick up changes made elsewhere (a revert, another field's save) unless typing here.
  useEffect(() => {
    if (!focused.current) setDraft(stored);
  }, [stored]);

  async function commit(text: string) {
    if (text === stored) return;
    if (required && text.trim() === "" && kind !== "check") {
      setError(`${label} cannot be empty`);
      setDraft(stored);
      return;
    }
    setSaving(true);
    try {
      await onSave(toPayload(text, kind));
      setError(null);
    } catch (caught) {
      setError((caught as Error).message);
      setDraft(stored);
    } finally {
      setSaving(false);
    }
  }

  const blocked = disabled || saving;
  const feedback = (error || hint) && (
    <div className="space-y-0.5 text-xs sm:pl-[7.5rem]">
      {hint && <p className="text-muted-foreground">{hint}</p>}
      {error && <p className="text-status-error">{sentence(error)}</p>}
    </div>
  );

  if (kind === "check") {
    return (
      <div className={cn("space-y-1", className)}>
        <label className="flex items-center gap-2 text-[13px] sm:pl-[7.5rem]">
          <input
            id={id}
            type="checkbox"
            checked={value === true}
            disabled={blocked}
            onChange={(e) => void commit(e.target.checked ? "true" : "false")}
            className="size-4 accent-primary"
          />
          <span>{label}</span>
        </label>
        {feedback}
      </div>
    );
  }

  const common = { id, disabled: blocked, "aria-invalid": error ? true : undefined };
  const onFocus = () => {
    focused.current = true;
  };
  const onBlur = (text: string) => {
    focused.current = false;
    void commit(text);
  };
  const enterLeaves = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") e.currentTarget.blur();
    if (e.key === "Escape") {
      setDraft(stored);
      e.currentTarget.blur();
    }
  };

  let control: ReactNode;
  switch (kind) {
    case "textarea":
      control = (
        <Textarea
          {...common}
          aria-label={label}
          value={draft}
          placeholder={placeholder}
          rows={3}
          onChange={(e) => setDraft(e.target.value)}
          onFocus={onFocus}
          onBlur={(e) => onBlur(e.target.value)}
          className="min-h-16 w-full text-[13px]"
        />
      );
      break;

    case "text":
    case "url":
      control = (
        <div className="flex w-full min-w-0 items-center gap-2">
          <Input
            {...common}
            aria-label={label}
            value={draft}
            placeholder={placeholder}
            onChange={(e) => setDraft(e.target.value)}
            onFocus={onFocus}
            onBlur={(e) => onBlur(e.target.value)}
            onKeyDown={enterLeaves}
            className="h-8 text-[13px]"
          />
          {kind === "url" && isWebUrl(stored) && (
            <a
              href={stored.trim()}
              target="_blank"
              rel="noreferrer"
              className="shrink-0 text-xs text-primary hover:underline"
            >
              Open
            </a>
          )}
        </div>
      );
      break;

    case "number":
      control = (
        <Input
          {...common}
          aria-label={label}
          type="number"
          min={0}
          value={draft}
          placeholder={placeholder}
          onChange={(e) => setDraft(e.target.value)}
          onFocus={onFocus}
          onBlur={(e) => onBlur(e.target.value)}
          onKeyDown={enterLeaves}
          className="h-8 w-28 text-[13px]"
        />
      );
      break;

    case "date":
    case "time":
      control = (
        <div className="flex items-center gap-1">
          <Input
            {...common}
            aria-label={label}
            type={kind}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onFocus={onFocus}
            onBlur={(e) => onBlur(e.target.value)}
            onKeyDown={enterLeaves}
            className={cn("h-8 text-[13px]", kind === "date" ? "w-40" : "w-32")}
          />
          {!required && draft && !blocked && (
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label={`Clear ${label.toLowerCase()}`}
              onClick={() => {
                setDraft("");
                void commit("");
              }}
            >
              <X />
            </Button>
          )}
        </div>
      );
      break;

    case "select":
    case "tristate":
      control = (
        <NativeSelect
          {...common}
          aria-label={label}
          value={draft}
          onChange={(e) => {
            setDraft(e.target.value);
            void commit(e.target.value);
          }}
          className="w-56 max-w-full"
        >
          {(!required || draft === "") && (
            <option value="">{emptyLabel ?? (kind === "tristate" ? "Not set" : "None")}</option>
          )}
          {options.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </NativeSelect>
      );
      break;
  }

  return (
    <div className={cn("space-y-1", className)}>
      <Field label={label} htmlFor={id}>
        {control}
      </Field>
      {feedback}
    </div>
  );
}

function toDraft(value: RecordFieldProps["value"], kind: FieldKind): string {
  if (value === null || value === undefined) return "";
  if (kind === "tristate" || kind === "check") return value ? "true" : "false";
  if (kind === "time") return toTimeInput(String(value));
  return String(value);
}

/** The API value for a draft: "" is empty text for text kinds and null for the rest. */
function toPayload(text: string, kind: FieldKind): unknown {
  switch (kind) {
    case "number":
      return text === "" ? null : Number(text);
    case "date":
    case "time":
    case "select":
      return text === "" ? null : text;
    case "tristate":
      return text === "" ? null : text === "true";
    case "check":
      return text === "true";
    case "text":
    case "url":
      return text.trim();
    default:
      return text;
  }
}

/**
 * A labelled tag editor: the tags as removable chips, and an input that adds one on Enter or
 * comma (suggesting tags already in use). Each change saves the whole list.
 */
export function TagsField({
  label = "Tags",
  value,
  onSave,
  className,
}: {
  label?: string;
  value: string[];
  onSave: (tags: string[]) => Promise<unknown>;
  className?: string;
}) {
  const id = useId();
  const listId = useId();
  const known = useTags();
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function save(next: string[]) {
    setSaving(true);
    try {
      await onSave(next);
      setError(null);
    } catch (caught) {
      setError((caught as Error).message);
    } finally {
      setSaving(false);
    }
  }

  function add(text: string = draft) {
    const tag = text.replace(/,$/, "").trim();
    setDraft("");
    if (!tag || value.some((t) => t.toLowerCase() === tag.toLowerCase())) return;
    void save([...value, tag]);
  }

  return (
    <div className={cn("space-y-1", className)}>
      <Field label={label} htmlFor={id}>
        <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1">
          {value.map((tag) => (
            <span
              key={tag}
              className="inline-flex items-center gap-0.5 rounded bg-secondary py-px pr-0.5 pl-1.5 text-xs text-secondary-foreground"
            >
              {tag}
              <button
                type="button"
                aria-label={`Remove tag ${tag}`}
                disabled={saving}
                onClick={() => void save(value.filter((t) => t !== tag))}
                className="rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground"
              >
                <X className="size-3" />
              </button>
            </span>
          ))}
          <Input
            id={id}
            list={listId}
            value={draft}
            disabled={saving}
            placeholder={value.length ? "Add…" : "Add a tag"}
            aria-label={`Add ${label.toLowerCase()}`}
            onChange={(e) => {
              if (e.target.value.endsWith(",")) add(e.target.value);
              else setDraft(e.target.value);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                add();
              }
              if (e.key === "Backspace" && draft === "" && value.length) {
                void save(value.slice(0, -1));
              }
            }}
            onBlur={() => draft.trim() && add()}
            className="h-7 w-32 text-[13px]"
          />
          <datalist id={listId}>
            {(known.data ?? [])
              .filter((t) => !value.includes(t))
              .map((t) => (
                <option key={t} value={t} />
              ))}
          </datalist>
        </div>
      </Field>
      {error && <p className="text-xs text-status-error sm:pl-[7.5rem]">{sentence(error)}</p>}
    </div>
  );
}
