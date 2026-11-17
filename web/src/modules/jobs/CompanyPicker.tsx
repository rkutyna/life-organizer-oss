import { useId, useMemo, useState, type KeyboardEvent, type RefObject } from "react";

import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

import { useCompanies } from "./api";

/**
 * A type-ahead over the existing companies. The text is the value: a name that matches no
 * company is fine, the server creates it (names match ignoring case and spacing).
 *
 * Keys: ArrowUp/ArrowDown move through suggestions, Enter picks the highlighted one (with
 * nothing highlighted, Enter submits the form), Escape closes the list.
 */
export function CompanyPicker({
  id,
  value,
  onValueChange,
  inputRef,
  placeholder = "Company",
  label = "Company",
  disabled,
  className,
}: {
  /** The input's id (e.g. so a shortcut can focus it). */
  id?: string;
  value: string;
  onValueChange: (text: string) => void;
  inputRef?: RefObject<HTMLInputElement | null>;
  placeholder?: string;
  label?: string;
  disabled?: boolean;
  className?: string;
}) {
  const companies = useCompanies();
  const listId = useId();
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);

  const needle = value.trim().toLowerCase();
  const all = companies.data ?? [];
  const suggestions = useMemo(
    () => (needle ? all.filter((c) => c.name.toLowerCase().includes(needle)).slice(0, 8) : []),
    [all, needle],
  );
  const exact = needle !== "" && all.some((c) => c.name.toLowerCase() === needle);
  const showList = open && needle !== "" && (suggestions.length > 0 || !exact);

  function pick(name: string) {
    onValueChange(name);
    setActive(-1);
    setOpen(false);
  }

  function onKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Escape") {
      setOpen(false);
      return;
    }
    if (!showList) return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActive((index) => Math.min(suggestions.length - 1, index + 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActive((index) => Math.max(-1, index - 1));
    } else if (event.key === "Enter" && active >= 0 && suggestions[active]) {
      event.preventDefault();
      pick(suggestions[active].name);
    }
  }

  return (
    <div className={cn("relative min-w-0", className)}>
      <Input
        ref={inputRef}
        id={id}
        value={value}
        disabled={disabled}
        placeholder={placeholder}
        aria-label={label}
        role="combobox"
        aria-expanded={showList}
        aria-controls={listId}
        aria-autocomplete="list"
        autoComplete="off"
        onChange={(e) => {
          onValueChange(e.target.value);
          setActive(-1);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onKeyDown={onKeyDown}
        className="h-8 text-[13px]"
      />
      {showList && (
        <ul
          id={listId}
          role="listbox"
          aria-label="Matching companies"
          className="absolute inset-x-0 top-full z-20 mt-1 max-h-60 overflow-auto rounded-md border border-border bg-popover p-1 text-popover-foreground shadow-md scrollbar-thin"
        >
          {suggestions.map((company, index) => (
            <li key={company.id} role="option" aria-selected={index === active}>
              <button
                type="button"
                // mousedown keeps focus in the input, so the list does not close before the pick.
                onMouseDown={(e) => {
                  e.preventDefault();
                  pick(company.name);
                }}
                className={cn(
                  "flex w-full items-center rounded px-2 py-1 text-left text-[13px] hover:bg-accent",
                  index === active && "bg-accent",
                )}
              >
                {company.name}
              </button>
            </li>
          ))}
          {!exact && (
            <li className="px-2 py-1 text-xs text-muted-foreground">
              New company: “{value.trim()}”
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
