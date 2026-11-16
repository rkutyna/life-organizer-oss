import { useQuery } from "@tanstack/react-query";
import { Check, ChevronsUpDown } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { api, unwrap } from "@/api/client";
import { NativeSelect } from "@/components/Field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";

/**
 * The time zone and holiday-country pickers, shared by the setup page and Settings.
 *
 *   <TimezoneSelect id="tz" value={tz} onChange={setTz} />
 *   <HolidayCountrySelect id="hc" value={country} onChange={setCountry} />   // null is "None"
 */

/** The browser's own time zone, e.g. "Europe/Berlin". */
export function browserTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

/** The region of the browser's locale ("en-GB" -> "GB"), if it has one. */
export function browserRegion(): string | null {
  try {
    const locale = new Intl.Locale(navigator.language);
    return locale.region ?? locale.maximize().region ?? null;
  } catch {
    return null;
  }
}

function localTimezones(): string[] {
  try {
    return Intl.supportedValuesOf("timeZone");
  } catch {
    return ["UTC"];
  }
}

/** The server's time zone list. Falls back to the browser's list if the server's can't load. */
export function useTimezones() {
  const query = useQuery({
    queryKey: ["settings", "timezones"],
    queryFn: () => unwrap(api.GET("/api/settings/timezones")),
    staleTime: Infinity,
  });
  const fallback = useMemo(() => (query.isError ? localTimezones() : undefined), [query.isError]);
  return { zones: query.data ?? fallback, isPending: query.isPending };
}

export function useHolidayCountries() {
  return useQuery({
    queryKey: ["settings", "holiday-countries"],
    queryFn: () => unwrap(api.GET("/api/settings/holiday-countries")),
    staleTime: Infinity,
  });
}

/** "America/Argentina/Buenos_Aires" -> "America / Argentina / Buenos Aires". */
function zoneLabel(zone: string): string {
  return zone.replace(/_/g, " ").replace(/\//g, " / ");
}

const MAX_SHOWN = 200;

/** A searchable time zone picker: type any part of the name ("york", "berlin", "utc"). */
export function TimezoneSelect({
  id,
  value,
  onChange,
  disabled,
  className,
}: {
  id?: string;
  value: string;
  onChange: (zone: string) => void;
  disabled?: boolean;
  className?: string;
}) {
  const { zones, isPending } = useTimezones();
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [active, setActive] = useState(0);
  const listRef = useRef<HTMLUListElement>(null);

  const matches = useMemo(() => {
    const needle = search.trim().toLowerCase().replace(/[\s/]+/g, "_");
    const all = zones ?? [];
    if (!needle) return all;
    return all.filter((zone) => zone.toLowerCase().replace(/\//g, "_").includes(needle));
  }, [zones, search]);
  const shown = matches.slice(0, MAX_SHOWN);

  useEffect(() => {
    listRef.current
      ?.querySelector<HTMLElement>(`[data-index="${active}"]`)
      ?.scrollIntoView({ block: "nearest" });
  }, [active]);

  function pick(zone: string) {
    onChange(zone);
    setOpen(false);
    setSearch("");
  }

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActive((i) => Math.min(i + 1, shown.length - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActive((i) => Math.max(i - 1, 0));
    } else if (event.key === "Enter") {
      event.preventDefault();
      if (shown[active]) pick(shown[active]);
    }
  }

  return (
    <Popover
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) {
          setSearch("");
          setActive(Math.max(0, (zones ?? []).indexOf(value)));
        }
      }}
    >
      <PopoverTrigger asChild>
        <Button
          id={id}
          type="button"
          variant="outline"
          role="combobox"
          aria-expanded={open}
          disabled={disabled || isPending}
          className={cn("w-full justify-between px-3 font-normal", className)}
        >
          <span className="truncate">
            {value ? zoneLabel(value) : isPending ? "Loading…" : "Choose a time zone"}
          </span>
          <ChevronsUpDown className="opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-(--radix-popover-trigger-width) min-w-64 p-0">
        <div className="border-b border-border p-1.5">
          <Input
            autoFocus
            value={search}
            onChange={(event) => {
              setSearch(event.target.value);
              setActive(0);
            }}
            onKeyDown={onKeyDown}
            placeholder="Search time zones"
            aria-label="Search time zones"
            className="h-8"
          />
        </div>
        <ul
          ref={listRef}
          role="listbox"
          aria-label="Time zones"
          className="max-h-64 overflow-y-auto p-1 scrollbar-thin"
        >
          {shown.length === 0 && (
            <li className="px-2 py-1.5 text-[13px] text-muted-foreground">No match</li>
          )}
          {shown.map((zone, index) => (
            <li
              key={zone}
              data-index={index}
              role="option"
              aria-selected={zone === value}
              onMouseEnter={() => setActive(index)}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => pick(zone)}
              className={cn(
                "flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 text-[13px]",
                index === active && "bg-accent",
              )}
            >
              <Check className={cn("size-3.5 shrink-0", zone !== value && "invisible")} />
              <span className="truncate">{zoneLabel(zone)}</span>
            </li>
          ))}
          {matches.length > MAX_SHOWN && (
            <li className="px-2 py-1.5 text-xs text-muted-foreground">
              {matches.length - MAX_SHOWN} more; keep typing to narrow the list
            </li>
          )}
        </ul>
      </PopoverContent>
    </Popover>
  );
}

/** The country whose public holidays show on the calendar, or "None" (null). */
export function HolidayCountrySelect({
  id,
  value,
  onChange,
  disabled,
  className,
}: {
  id?: string;
  value: string | null;
  onChange: (country: string | null) => void;
  disabled?: boolean;
  className?: string;
}) {
  const countries = useHolidayCountries();
  const sorted = useMemo(
    () => [...(countries.data ?? [])].sort((a, b) => a.name.localeCompare(b.name)),
    [countries.data],
  );
  // Keep a saved country selectable even if the list has not loaded.
  const missing = value && !sorted.some((c) => c.code === value);
  return (
    <NativeSelect
      id={id}
      value={value ?? ""}
      onChange={(event) => onChange(event.target.value || null)}
      disabled={disabled || countries.isPending}
      className={cn("h-9 w-full text-sm", className)}
    >
      <option value="">None</option>
      {missing && <option value={value}>{value}</option>}
      {sorted.map((country) => (
        <option key={country.code} value={country.code}>
          {country.name}
        </option>
      ))}
    </NativeSelect>
  );
}
