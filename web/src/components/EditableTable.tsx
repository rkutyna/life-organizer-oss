import {
  flexRender,
  getCoreRowModel,
  getFilteredRowModel,
  getSortedRowModel,
  useReactTable,
  type ColumnDef,
  type ColumnFiltersState,
  type Row,
  type SortingState,
} from "@tanstack/react-table";
import { ArrowDown, ArrowUp, Search } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { toast } from "sonner";

import { useHotkeys } from "@/lib/hotkeys";
import { cn } from "@/lib/utils";

/**
 * A sortable, filterable table whose cells edit in place. Works for any record type: you
 * describe the columns and supply `onSave`, which PATCHes one field.
 *
 *   <EditableTable
 *     rows={companies}
 *     getRowId={(c) => c.id}
 *     columns={[
 *       { key: "name", header: "Name", type: "text" },
 *       { key: "next_date", header: "Next", type: "date" },
 *       { key: "stage", header: "Stage", type: "select", options: STAGE_OPTIONS },
 *       { key: "created_by", header: "By" },                      // read-only
 *     ]}
 *     onSave={(company, key, value) =>
 *       unwrap(api.PATCH("/api/jobs/companies/{company_id}", {
 *         params: { path: { company_id: company.id } }, body: { [key]: value },
 *       }))
 *     }
 *   />
 *
 * Click a cell (or focus it and press Enter) to edit; Enter or leaving the field saves,
 * Escape cancels. `isCellReadOnly(row, key)` locks single cells, e.g. a mirrored row's. An empty date/time/number/select saves null. If `onSave` throws, the
 * error is shown and the old value stays.
 *
 * Keyboard rows: pass `onOpen` and j/k (or the arrow keys) move a row selection, Enter opens the
 * selected row, Escape clears it. The keys are page-wide (ignored while typing), so give
 * `onOpen` to one table per page, and set `keysEnabled={false}` while a drawer covers it.
 */

export type CellType = "text" | "number" | "date" | "time" | "select" | "readonly";

export interface SelectOption {
  value: string;
  label: string;
}

export interface EditableColumn<T> {
  /** Field on the record; also the key sent to `onSave`. */
  key: Extract<keyof T, string>;
  header: string;
  /** How the cell edits. Default "readonly". */
  type?: CellType;
  /** Choices for "select" columns. A select column also gets a filter dropdown. */
  options?: SelectOption[];
  /** The filter dropdown's "all" entry, e.g. "All channels". Default "All <header>". */
  filterAllLabel?: string;
  /** Custom display. Editing still uses `type`. */
  render?: (row: T) => ReactNode;
  /** Value to sort and search by, when the raw field is not right for it. */
  sortValue?: (row: T) => string | number | null | undefined;
  /** Extra classes for the column's cells, e.g. "w-32" or "text-right". */
  className?: string;
}

export interface EditableTableProps<T> {
  rows: T[];
  columns: EditableColumn<T>[];
  getRowId: (row: T) => string | number;
  /** Save one edited cell. Throw (or reject) to report failure. */
  onSave: (row: T, key: Extract<keyof T, string>, value: unknown) => Promise<unknown>;
  /** True to show one row's cell read-only whatever its column's type (e.g. a mirrored row). */
  isCellReadOnly?: (row: T, key: Extract<keyof T, string>) => boolean;
  onRowClick?: (row: T) => void;
  /** Open a row from the keyboard (Enter on the j/k selection). Turns the row keys on. */
  onOpen?: (row: T) => void;
  /** Row keys on or off, e.g. off while a drawer is open. Default true. */
  keysEnabled?: boolean;
  initialSort?: { key: Extract<keyof T, string>; desc?: boolean };
  searchPlaceholder?: string;
  emptyMessage?: string;
  /** Extra controls rendered next to the search box. */
  toolbar?: ReactNode;
  className?: string;
}

export function EditableTable<T>({
  rows,
  columns,
  getRowId,
  onSave,
  isCellReadOnly,
  onRowClick,
  onOpen,
  keysEnabled = true,
  initialSort,
  searchPlaceholder = "Filter…",
  emptyMessage = "Nothing to show.",
  toolbar,
  className,
}: EditableTableProps<T>) {
  const [sorting, setSorting] = useState<SortingState>(
    initialSort ? [{ id: initialSort.key, desc: initialSort.desc ?? false }] : [],
  );
  const [globalFilter, setGlobalFilter] = useState("");
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([]);
  const [editing, setEditing] = useState<{ rowId: string; key: string } | null>(null);

  const columnDefs = useMemo<ColumnDef<T>[]>(
    () =>
      columns.map((column) => ({
        id: column.key,
        header: column.header,
        // null -> undefined so empty values sort last in both directions.
        accessorFn: (row: T) =>
          (column.sortValue ? column.sortValue(row) : (row[column.key] as unknown)) ?? undefined,
        sortUndefined: "last",
        filterFn: (row: Row<T>, id: string, value: string) =>
          String(row.original[id as keyof T] ?? "") === value,
        meta: column,
      })),
    [columns],
  );

  const table = useReactTable({
    data: rows,
    columns: columnDefs,
    state: { sorting, globalFilter, columnFilters },
    onSortingChange: setSorting,
    onGlobalFilterChange: setGlobalFilter,
    onColumnFiltersChange: setColumnFilters,
    getRowId: (row) => String(getRowId(row)),
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    globalFilterFn: (row, id, value: string) =>
      String(row.getValue(id) ?? "")
        .toLowerCase()
        .includes(value.toLowerCase()),
  });

  const selectColumns = columns.filter((c) => c.type === "select" && c.options?.length);

  // Keyboard row selection, by row id so it survives re-sorts and refetches.
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const visibleRows = table.getRowModel().rows;
  const selectedIndex = visibleRows.findIndex((row) => row.id === selectedId);
  const rowRefs = useRef(new Map<string, HTMLTableRowElement>());

  function moveSelection(step: number) {
    if (!visibleRows.length) return;
    const next =
      selectedIndex === -1
        ? step > 0
          ? 0
          : visibleRows.length - 1
        : Math.min(visibleRows.length - 1, Math.max(0, selectedIndex + step));
    setSelectedId(visibleRows[next].id);
  }

  useEffect(() => {
    if (selectedId) rowRefs.current.get(selectedId)?.scrollIntoView({ block: "nearest" });
  }, [selectedId]);

  useHotkeys(
    {
      j: () => moveSelection(1),
      k: () => moveSelection(-1),
      ArrowDown: () => moveSelection(1),
      ArrowUp: () => moveSelection(-1),
      Enter: () => {
        const row = visibleRows[selectedIndex];
        if (row && onOpen) onOpen(row.original);
      },
      Escape: () => setSelectedId(null),
    },
    { enabled: Boolean(onOpen) && keysEnabled && editing === null },
  );

  return (
    <div className={cn("flex min-h-0 flex-col gap-2", className)}>
      <div className="flex flex-wrap items-center gap-2">
        <label className="relative flex min-w-40 flex-1 items-center sm:max-w-64">
          <Search className="pointer-events-none absolute left-2 size-3.5 text-muted-foreground" />
          <input
            value={globalFilter}
            onChange={(e) => setGlobalFilter(e.target.value)}
            placeholder={searchPlaceholder}
            aria-label="Filter rows"
            className="h-8 w-full rounded-md border border-input bg-card pr-2 pl-7 text-[13px] outline-none focus:border-ring focus:ring-2 focus:ring-ring/30"
          />
        </label>
        {selectColumns.map((column) => (
          <select
            key={column.key}
            aria-label={`Filter by ${column.header}`}
            value={(table.getColumn(column.key)?.getFilterValue() as string) ?? ""}
            onChange={(e) => table.getColumn(column.key)?.setFilterValue(e.target.value || undefined)}
            className="h-8 rounded-md border border-input bg-card px-2 text-[13px] outline-none focus:border-ring"
          >
            <option value="">{column.filterAllLabel ?? `All ${column.header.toLowerCase()}`}</option>
            {column.options!.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        ))}
        {toolbar}
        <span className="ml-auto text-xs text-muted-foreground tabular">
          {visibleRows.length} of {rows.length}
        </span>
      </div>

      <div className="min-h-0 overflow-auto rounded-lg border border-border bg-card scrollbar-thin">
        <table className="w-full border-collapse text-[13px]">
          <thead className="sticky top-0 z-10 bg-card">
            {table.getHeaderGroups().map((group) => (
              <tr key={group.id} className="border-b border-border">
                {group.headers.map((header) => {
                  const sorted = header.column.getIsSorted();
                  const meta = header.column.columnDef.meta as EditableColumn<T>;
                  return (
                    <th
                      key={header.id}
                      scope="col"
                      aria-sort={
                        sorted === "asc" ? "ascending" : sorted === "desc" ? "descending" : "none"
                      }
                      className={cn(
                        "h-8 px-3 text-left text-xs font-medium whitespace-nowrap text-muted-foreground",
                        meta.className,
                      )}
                    >
                      <button
                        type="button"
                        onClick={header.column.getToggleSortingHandler()}
                        className="inline-flex items-center gap-1 hover:text-foreground"
                      >
                        {flexRender(header.column.columnDef.header, header.getContext())}
                        {sorted === "asc" && <ArrowUp className="size-3" />}
                        {sorted === "desc" && <ArrowDown className="size-3" />}
                      </button>
                    </th>
                  );
                })}
              </tr>
            ))}
          </thead>
          <tbody>
            {visibleRows.length === 0 ? (
              <tr>
                <td colSpan={columns.length} className="px-3 py-8 text-center text-muted-foreground">
                  {emptyMessage}
                </td>
              </tr>
            ) : (
              visibleRows.map((row) => (
                <tr
                  key={row.id}
                  ref={(node) => {
                    if (node) rowRefs.current.set(row.id, node);
                    else rowRefs.current.delete(row.id);
                  }}
                  aria-selected={onOpen ? row.id === selectedId : undefined}
                  onClick={
                    onRowClick
                      ? () => {
                          setSelectedId(row.id);
                          onRowClick(row.original);
                        }
                      : undefined
                  }
                  className={cn(
                    "border-b border-border last:border-b-0 hover:bg-accent/50",
                    onRowClick && "cursor-pointer",
                    row.id === selectedId && "bg-selection hover:bg-selection",
                  )}
                >
                  {row.getVisibleCells().map((cell) => {
                    const column = cell.column.columnDef.meta as EditableColumn<T>;
                    const isEditing =
                      editing?.rowId === row.id && editing.key === column.key;
                    return (
                      <td key={cell.id} className={cn("h-8 px-1 align-middle", column.className)}>
                        <EditableCell
                          row={row.original}
                          column={column}
                          readOnly={isCellReadOnly?.(row.original, column.key) ?? false}
                          editing={isEditing}
                          onStartEdit={() => setEditing({ rowId: row.id, key: column.key })}
                          onStopEdit={() => setEditing(null)}
                          onSave={onSave}
                        />
                      </td>
                    );
                  })}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function rawValue<T>(row: T, column: EditableColumn<T>): unknown {
  return row[column.key];
}

/** Value as the <input> wants it. */
function toInput(value: unknown, type: CellType): string {
  if (value === null || value === undefined) return "";
  if (type === "time") return String(value).slice(0, 5);
  return String(value);
}

/** Input text back to the API value. Empty -> null except for text. */
function fromInput(text: string, type: CellType): unknown {
  if (type === "text") return text;
  if (text === "") return null;
  if (type === "number") return Number(text);
  if (type === "select" && /^-?\d+$/.test(text)) return Number(text);
  return text;
}

function display<T>(row: T, column: EditableColumn<T>): ReactNode {
  if (column.render) return column.render(row);
  const value = rawValue(row, column);
  if (value === null || value === undefined || value === "") {
    return <span className="text-muted-foreground/60">—</span>;
  }
  if (column.type === "select") {
    return column.options?.find((o) => o.value === String(value))?.label ?? String(value);
  }
  if (column.type === "time") return String(value).slice(0, 5);
  return String(value);
}

function EditableCell<T>({
  row,
  column,
  readOnly,
  editing,
  onStartEdit,
  onStopEdit,
  onSave,
}: {
  row: T;
  column: EditableColumn<T>;
  readOnly: boolean;
  editing: boolean;
  onStartEdit: () => void;
  onStopEdit: () => void;
  onSave: EditableTableProps<T>["onSave"];
}) {
  const type = readOnly ? "readonly" : (column.type ?? "readonly");
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);
  // Enter, Escape, a select change and blur can all end one edit; only the first counts.
  const finished = useRef(false);

  if (type === "readonly") {
    // A read-only row keeps its normal text; a read-only column reads as secondary.
    const muted = !readOnly || (column.type ?? "readonly") === "readonly";
    return <div className={cn("truncate px-2", muted && "text-muted-foreground")}>{display(row, column)}</div>;
  }

  function start() {
    finished.current = false;
    setDraft(toInput(rawValue(row, column), type));
    onStartEdit();
  }

  function cancel() {
    finished.current = true;
    onStopEdit();
  }

  async function commit(text: string) {
    if (finished.current) return;
    finished.current = true;
    onStopEdit();
    const next = fromInput(text, type);
    const current = rawValue(row, column);
    if (toInput(next, type) === toInput(current, type)) return;
    setSaving(true);
    try {
      await onSave(row, column.key, next);
    } catch (error) {
      toast.error(`Could not save ${column.header.toLowerCase()}: ${(error as Error).message}`);
    } finally {
      setSaving(false);
    }
  }

  if (editing) {
    const common = {
      autoFocus: true,
      value: draft,
      "aria-label": column.header,
      onClick: (e: React.MouseEvent) => e.stopPropagation(),
      onBlur: () => void commit(draft),
      onKeyDown: (e: React.KeyboardEvent) => {
        if (e.key === "Enter") void commit(draft);
        if (e.key === "Escape") cancel();
      },
      className:
        "h-7 w-full min-w-24 rounded-md border border-ring bg-background px-2 text-[13px] outline-none ring-2 ring-ring/25",
    };
    if (type === "select") {
      return (
        <select
          {...common}
          onChange={(e) => {
            setDraft(e.target.value);
            void commit(e.target.value);
          }}
        >
          <option value="">—</option>
          {column.options?.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      );
    }
    return (
      <input
        {...common}
        type={type === "number" ? "number" : type}
        onChange={(e) => setDraft(e.target.value)}
      />
    );
  }

  return (
    <div
      role="button"
      tabIndex={0}
      title="Click to edit"
      onClick={(e) => {
        e.stopPropagation();
        start();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          start();
        }
      }}
      className={cn(
        "flex h-7 cursor-text items-center truncate rounded-md px-2 outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring/40",
        saving && "opacity-50",
      )}
    >
      {display(row, column)}
    </div>
  );
}
