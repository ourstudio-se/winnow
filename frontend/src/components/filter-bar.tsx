import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "react-router";
import { X, Plus, Search, Loader2, Calendar, ChevronDown, Code, Play } from "lucide-react";
import { RawQueryInput } from "@/components/raw-query-input";
import {
  getIndexMetadata,
  search as apiSearch,
  type IndexId,
} from "@/lib/api";
import {
  type TimeSelection,
  QUICK_PRESETS,
  DEFAULT_PRESET,
  STORAGE_KEY,
  parseTimeParam,
  serializeTimeParam,
  fmtDate,
  fmtTime,
  timeSelectionLabel,
} from "@/lib/time";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";

export interface FilterState {
  query: string;
}

interface FilterBarProps {
  index: IndexId;
  onFilterChange: (filters: FilterState) => void;
  /** Optional base query to scope autocomplete suggestions (e.g. "span_kind:3"). Defaults to "*". */
  baseQuery?: string;
  /** View-provided display overrides for filter values keyed by field name (e.g. span_fingerprint → span name). */
  resolvedLabels?: Record<string, string>;
  /** Right-aligned trailing content (e.g. "Service Map" link). */
  trailing?: React.ReactNode;
  /** Timestamp field used for time range queries and sort. Defaults to "span_start_timestamp_nanos". */
  timestampField?: string;
}

interface ActiveFilter {
  field: string;
  value: string;
  kind: "text" | "bool";
}

interface DiscoveredField {
  field: string;
  kind: "text" | "bool";
}

// Fields not useful as user-facing filters
const HIDDEN_FIELDS = new Set([
  "span_start_timestamp_nanos",
  "span_end_timestamp_nanos",
  "span_kind",
  "span_id",
  "parent_span_id",
  "span_fingerprint",
  "resource_dropped_attributes_count",
  "span_dropped_attributes_count",
  "span_dropped_events_count",
  "span_dropped_links_count",
  "events",
  "event_names",
  "links",
  // Log-specific internal fields
  "timestamp_nanos",
  "observed_timestamp_nanos",
  "dropped_attributes_count",
  "scope_dropped_attributes_count",
  "trace_flags",
  "scope_name",
  "scope_version",
  "scope_attributes",
]);

/** Format a field path for Quickwit queries and aggregations.
 *  With expand_dots: true (the default on Quickwit's OTel indexes), dotted
 *  attribute keys like "http.method" are expanded into nested paths at index
 *  time, so the natural dotted path works as-is for both queries and aggs.
 */
function formatFieldPath(field: string): string {
  return field;
}

async function fetchFieldValues(index: IndexId, field: string, baseQuery = "*"): Promise<string[]> {
  const res = await apiSearch<unknown>(index, {
    query: baseQuery,
    max_hits: 0,
    aggs: {
      values: { terms: { field: formatFieldPath(field), size: 50 } },
    },
  });
  const buckets = (res.aggregations?.values as any)?.buckets ?? [];
  return buckets.map((b: any) => String(b.key));
}

function collectKeys(obj: unknown, prefix: string, out: Set<string>) {
  if (obj == null || typeof obj !== "object") return;
  for (const [key, val] of Object.entries(obj as Record<string, unknown>)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (val != null && typeof val === "object" && !Array.isArray(val)) {
      collectKeys(val, path, out);
    } else {
      out.add(path);
    }
  }
}

async function discoverFields(index: IndexId, baseQuery = "*", sortField = "span_start_timestamp_nanos"): Promise<DiscoveredField[]> {
  const fields: DiscoveredField[] = [];

  // 1) Top-level fields from index metadata
  const meta = await getIndexMetadata(index);
  const mappings = meta?.index_config?.doc_mapping?.field_mappings;
  if (!Array.isArray(mappings)) return fields;

  const jsonFieldNames: string[] = [];

  for (const m of mappings) {
    if (HIDDEN_FIELDS.has(m.name)) continue;
    if (m.type === "text") {
      fields.push({ field: m.name, kind: "text" });
    } else if (m.type === "bool") {
      fields.push({ field: m.name, kind: "bool" });
    } else if (m.type === "json") {
      jsonFieldNames.push(m.name);
    }
  }

  // 2) For JSON fields, sample docs to discover nested keys
  if (jsonFieldNames.length > 0) {
    try {
      const res = await apiSearch<Record<string, unknown>>(index, {
        query: baseQuery,
        max_hits: 100,
        sort_by: `-${sortField}`,
      });

      for (const jsonField of jsonFieldNames) {
        const keys = new Set<string>();
        for (const doc of res.hits) {
          const val = doc[jsonField];
          if (val != null && typeof val === "object" && !Array.isArray(val)) {
            collectKeys(val, "", keys);
          }
        }
        const sorted = [...keys].sort();
        for (const key of sorted) {
          fields.push({ field: `${jsonField}.${key}`, kind: "text" });
        }
      }
    } catch (e) {
      console.warn("Failed to sample docs for field discovery:", e);
    }
  }

  return fields;
}

function buildQuery(filters: ActiveFilter[]): string {
  if (filters.length === 0) return "*";
  const parts = filters.map((f) => {
    const formatted = formatFieldPath(f.field);
    return `${formatted}:"${f.value}"`;
  });
  return parts.join(" AND ");
}

// --- Components ---

function FilterChip({
  filter,
  resolvedLabel,
  onRemove,
}: {
  filter: ActiveFilter;
  resolvedLabel?: string;
  onRemove: () => void;
}) {
  return (
    <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs text-foreground">
      <span className="text-muted-foreground">{filter.field}</span>
      <span>=</span>
      <span className="font-medium">{resolvedLabel ?? filter.value}</span>
      <button
        onClick={onRemove}
        className="ml-0.5 rounded-sm p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
      >
        <X className="h-3 w-3" />
      </button>
    </span>
  );
}

export function FilterBar({ index, onFilterChange, baseQuery = "*", resolvedLabels, trailing, timestampField = "span_start_timestamp_nanos" }: FilterBarProps) {
  const [searchParams, setSearchParams] = useSearchParams();
  const [timeSelection, setTimeSelection] = useState<TimeSelection>(() => {
    const fromUrl = searchParams.get("time");
    if (fromUrl) return parseTimeParam(fromUrl);
    const fromStorage = localStorage.getItem(STORAGE_KEY);
    if (fromStorage) return parseTimeParam(fromStorage);
    return { type: "relative", ...DEFAULT_PRESET };
  });
  const [timePickerOpen, setTimePickerOpen] = useState(false);
  const [absFromDate, setAbsFromDate] = useState("");
  const [absFromTime, setAbsFromTime] = useState("00:00");
  const [absToDate, setAbsToDate] = useState("");
  const [absToTime, setAbsToTime] = useState("00:00");
  const [discoveredFields, setDiscoveredFields] = useState<DiscoveredField[]>(
    [],
  );
  const [popoverOpen, setPopoverOpen] = useState(false);
  const [popoverStep, setPopoverStep] = useState<"field" | "value">("field");
  const [selectedField, setSelectedField] = useState<DiscoveredField | null>(
    null,
  );
  const [fieldSearch, setFieldSearch] = useState("");
  const [valueInput, setValueInput] = useState("");
  const [suggestedValues, setSuggestedValues] = useState<string[]>([]);
  const [valuesLoading, setValuesLoading] = useState(false);
  const valueInputRef = useRef<HTMLInputElement>(null);

  // Raw query mode — driven by URL `q` param
  const rawQuery = searchParams.get("q");
  const isRawMode = rawQuery !== null;
  const [rawInput, setRawInput] = useState(rawQuery ?? "");
  // Sync local input when URL q param changes externally (navigation)
  useEffect(() => { setRawInput(rawQuery ?? ""); }, [rawQuery]);

  // Derive active filters from URL params
  const activeFilters = useMemo(() => {
    return searchParams.getAll("f").map((raw) => {
      const colonIdx = raw.indexOf(":");
      return {
        field: colonIdx >= 0 ? raw.slice(0, colonIdx) : raw,
        value: colonIdx >= 0 ? raw.slice(colonIdx + 1) : "",
        kind: "text" as const,
      };
    });
  }, [searchParams]);

  // Sync URL param on mount if missing (populate from resolved value)
  useEffect(() => {
    const serialized = serializeTimeParam(timeSelection);
    if (searchParams.get("time") !== serialized) {
      const next = new URLSearchParams(searchParams);
      next.set("time", serialized);
      setSearchParams(next, { replace: true });
    }
    // Only on mount
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Sync timeSelection from URL when it changes externally (e.g. histogram drag-select)
  useEffect(() => {
    const urlTime = searchParams.get("time");
    if (urlTime && urlTime !== serializeTimeParam(timeSelection)) {
      const parsed = parseTimeParam(urlTime);
      setTimeSelection(parsed);
      localStorage.setItem(STORAGE_KEY, urlTime);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  // Discover fields on mount / index change
  useEffect(() => {
    let cancelled = false;
    discoverFields(index, baseQuery, timestampField)
      .then((fields) => {
        if (!cancelled) setDiscoveredFields(fields);
      })
      .catch((err) => console.warn("Field discovery failed:", err));
    return () => {
      cancelled = true;
    };
  }, [index, baseQuery, timestampField]);

  // Build FilterState from current active filters + time selection.
  // rawQ: null = chip mode, "" = raw mode with empty input, non-empty = raw query string.
  const buildFilterState = useCallback(
    (filters: ActiveFilter[], sel: TimeSelection, rawQ: string | null): FilterState => {
      const parts: string[] = [];
      if (sel.type === "relative") {
        const nowNanos = BigInt(Date.now()) * 1_000_000n;
        const startNanos = nowNanos - BigInt(sel.seconds) * 1_000_000_000n;
        parts.push(`${timestampField}:[${startNanos} TO ${nowNanos}]`);
      } else {
        const fromNanos = BigInt(sel.from.getTime()) * 1_000_000n;
        const toNanos = BigInt(sel.to.getTime()) * 1_000_000n;
        parts.push(`${timestampField}:[${fromNanos} TO ${toNanos}]`);
      }
      if (rawQ !== null) {
        // Raw mode: wrap user input in parens so OR doesn't break precedence
        if (rawQ) parts.push(`(${rawQ})`);
        // Empty raw query = no user filter (equivalent to *)
      } else {
        const filterQuery = buildQuery(filters);
        if (filterQuery !== "*") parts.push(filterQuery);
      }
      return {
        query: parts.length > 0 ? parts.join(" AND ") : "*",
      };
    },
    [timestampField],
  );

  // Fire onFilterChange on mount and whenever filters or time change
  const prevFilterKeyRef = useRef<string | null>(null);
  useEffect(() => {
    const key = searchParams.getAll("f").join("\0") + "\0" + serializeTimeParam(timeSelection) + "\0" + (searchParams.get("q") ?? "");
    if (key !== prevFilterKeyRef.current) {
      prevFilterKeyRef.current = key;
      onFilterChange(buildFilterState(activeFilters, timeSelection, rawQuery));
    }
  }, [activeFilters, timeSelection, buildFilterState, onFilterChange, searchParams, rawQuery]);

  function addFilter(field: DiscoveredField, value: string) {
    const trimmed = value.trim();
    if (!trimmed && field.kind === "text") return;
    const next = new URLSearchParams(searchParams);
    // Remove any existing filter on the same field
    const existing = next.getAll("f");
    next.delete("f");
    for (const f of existing) {
      const colonIdx = f.indexOf(":");
      const fField = colonIdx >= 0 ? f.slice(0, colonIdx) : f;
      if (fField !== field.field) next.append("f", f);
    }
    next.append("f", `${field.field}:${trimmed}`);
    setSearchParams(next, { replace: true });
  }

  function removeFilter(field: string) {
    const next = new URLSearchParams(searchParams);
    const existing = next.getAll("f");
    next.delete("f");
    for (const f of existing) {
      const colonIdx = f.indexOf(":");
      const fField = colonIdx >= 0 ? f.slice(0, colonIdx) : f;
      if (fField !== field) next.append("f", f);
    }
    setSearchParams(next, { replace: true });
  }

  function toggleRawMode() {
    const next = new URLSearchParams(searchParams);
    if (isRawMode) {
      next.delete("q");
    } else {
      const chipQuery = buildQuery(activeFilters);
      next.set("q", chipQuery === "*" ? "" : chipQuery);
    }
    setSearchParams(next, { replace: true });
  }

  function submitRawQuery() {
    const next = new URLSearchParams(searchParams);
    next.set("q", rawInput);
    setSearchParams(next, { replace: true });
  }

  function handleTimeChange(sel: TimeSelection) {
    setTimeSelection(sel);
    const serialized = serializeTimeParam(sel);
    localStorage.setItem(STORAGE_KEY, serialized);
    const next = new URLSearchParams(searchParams);
    next.set("time", serialized);
    setSearchParams(next, { replace: true });
    onFilterChange(buildFilterState(activeFilters, sel, rawQuery));
  }

  /** Pre-fill absolute inputs from the current selection and open the picker. */
  function handleTimePickerOpen(open: boolean) {
    if (open) {
      if (timeSelection.type === "absolute") {
        setAbsFromDate(fmtDate(timeSelection.from));
        setAbsFromTime(fmtTime(timeSelection.from));
        setAbsToDate(fmtDate(timeSelection.to));
        setAbsToTime(fmtTime(timeSelection.to));
      } else {
        const now = new Date();
        const from = new Date(now.getTime() - timeSelection.seconds * 1000);
        setAbsFromDate(fmtDate(from));
        setAbsFromTime("00:00");
        setAbsToDate(fmtDate(now));
        setAbsToTime("00:00");
      }
    }
    setTimePickerOpen(open);
  }

  // Reset popover state when it closes
  function handlePopoverOpenChange(open: boolean) {
    setPopoverOpen(open);
    // Reset to field-picker step on every open and close
    setPopoverStep("field");
    setSelectedField(null);
    setFieldSearch("");
    setValueInput("");
    setSuggestedValues([]);
    setValuesLoading(false);
  }

  // Combine baseQuery with active filters so autocomplete narrows progressively
  function buildAutocompletQuery(): string {
    const filterQuery = buildQuery(activeFilters);
    if (filterQuery === "*") return baseQuery;
    return `${baseQuery} AND ${filterQuery}`;
  }

  // Autocomplete value fetching — scoped only to baseQuery (the view's
  // intrinsic scope, e.g. span_kind:3 for service map) so that suggestions
  // show all values within the time range, not narrowed by the current filter.
  // This lets the user discover and switch to values not in the current result set.
  const fetchValuesForAutocomplete = useCallback(
    (field: string) => fetchFieldValues(index, field, baseQuery),
    [index, baseQuery],
  );

  function handleFieldSelect(field: DiscoveredField) {
    setSelectedField(field);
    setPopoverStep("value");
    setValueInput("");
    setSuggestedValues([]);
    // Focus the value input after render
    requestAnimationFrame(() => valueInputRef.current?.focus());
    // Fetch actual values via terms aggregation (skip for bool fields)
    if (field.kind !== "bool") {
      setValuesLoading(true);
      fetchFieldValues(index, field.field, buildAutocompletQuery())
        .then(setSuggestedValues)
        .catch(() => {})
        .finally(() => setValuesLoading(false));
    }
  }

  function handleValueSubmit() {
    if (!selectedField) return;
    addFilter(selectedField, valueInput);
    setPopoverOpen(false);
  }

  // Filtered field list — hide fields that already have active filters
  const filteredFields = useMemo(() => {
    const activeFieldSet = new Set(activeFilters.map((f) => f.field));
    let fields = discoveredFields.filter((f) => !activeFieldSet.has(f.field));
    if (!fieldSearch) return fields;
    const lower = fieldSearch.toLowerCase();
    return fields.filter((f) => f.field.toLowerCase().includes(lower));
  }, [discoveredFields, fieldSearch, activeFilters]);

  const filteredValues = useMemo(() => {
    if (!valueInput) return suggestedValues;
    const lower = valueInput.toLowerCase();
    return suggestedValues.filter((v) => v.toLowerCase().includes(lower));
  }, [suggestedValues, valueInput]);

  return (
    <div className="flex min-h-14 flex-wrap items-center gap-2 border-b border-border bg-card px-3 py-2">
      {/* Time picker */}
      <Popover open={timePickerOpen} onOpenChange={handleTimePickerOpen}>
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            size="xs"
            className="gap-1.5 text-foreground"
          >
            <Calendar className="h-3 w-3 text-muted-foreground" />
            <span className="max-w-48 truncate">{timeSelectionLabel(timeSelection)}</span>
            <ChevronDown className="h-3 w-3 text-muted-foreground" />
          </Button>
        </PopoverTrigger>
        <PopoverContent align="start" className="w-auto p-0" sideOffset={8}>
          <div className="flex">
            {/* Left: quick presets */}
            <div className="flex flex-col border-r border-border py-1" style={{ minWidth: "10rem" }}>
              <div className="px-3 py-1.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground">
                Quick select
              </div>
              {QUICK_PRESETS.map((p) => (
                <button
                  key={p.key}
                  onClick={() => {
                    handleTimeChange({ type: "relative", ...p });
                    setTimePickerOpen(false);
                  }}
                  className={`px-3 py-1.5 text-left text-xs hover:bg-muted ${
                    timeSelection.type === "relative" && timeSelection.key === p.key
                      ? "bg-muted font-medium text-foreground"
                      : "text-muted-foreground"
                  }`}
                >
                  {p.label}
                </button>
              ))}
            </div>

            {/* Right: absolute time range */}
            <div className="flex flex-col gap-3 p-3" style={{ minWidth: "16rem" }}>
              <div className="text-[10px] font-medium uppercase tracking-wider text-muted-foreground">
                Absolute time range
              </div>
              <div className="flex flex-col gap-1">
                <span className="text-xs text-muted-foreground">From</span>
                <div className="flex gap-1.5">
                  <input
                    type="date"
                    value={absFromDate}
                    onChange={(e) => setAbsFromDate(e.target.value)}
                    className="h-8 flex-1 rounded-md border border-input bg-transparent px-2 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
                  />
                  <input
                    type="time"
                    value={absFromTime}
                    onChange={(e) => setAbsFromTime(e.target.value)}
                    className="h-8 w-20 rounded-md border border-input bg-transparent px-2 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
                  />
                </div>
              </div>
              <div className="flex flex-col gap-1">
                <span className="text-xs text-muted-foreground">To</span>
                <div className="flex gap-1.5">
                  <input
                    type="date"
                    value={absToDate}
                    onChange={(e) => setAbsToDate(e.target.value)}
                    className="h-8 flex-1 rounded-md border border-input bg-transparent px-2 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
                  />
                  <input
                    type="time"
                    value={absToTime}
                    onChange={(e) => setAbsToTime(e.target.value)}
                    className="h-8 w-20 rounded-md border border-input bg-transparent px-2 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
                  />
                </div>
              </div>
              <Button
                size="sm"
                className="w-full"
                disabled={!absFromDate || !absToDate}
                onClick={() => {
                  const from = new Date(`${absFromDate}T${absFromTime || "00:00"}`);
                  const to = new Date(`${absToDate}T${absToTime || "00:00"}`);
                  if (!isNaN(from.getTime()) && !isNaN(to.getTime()) && from < to) {
                    handleTimeChange({ type: "absolute", from, to });
                    setTimePickerOpen(false);
                  }
                }}
              >
                Apply
              </Button>
            </div>
          </div>
        </PopoverContent>
      </Popover>

      {/* Chip mode: active filter chips + add filter popover */}
      {!isRawMode && (
        <>
          {activeFilters.map((f) => (
            <FilterChip
              key={f.field}
              filter={f}
              resolvedLabel={resolvedLabels?.[f.field]}
              onRemove={() => removeFilter(f.field)}
            />
          ))}

          <Popover open={popoverOpen} onOpenChange={handlePopoverOpenChange}>
            <PopoverTrigger asChild>
              <Button variant="outline" size="xs" className="gap-1 text-muted-foreground">
                <Plus className="h-3 w-3" />
                Add filter
              </Button>
            </PopoverTrigger>
            <PopoverContent align="start" className="w-64 p-0">
              {popoverStep === "field" ? (
                <div className="flex flex-col">
                  <div className="flex items-center gap-2 border-b border-border px-2.5 py-2">
                    <Search className="h-3.5 w-3.5 text-muted-foreground" />
                    <input
                      type="text"
                      placeholder="Search fields..."
                      value={fieldSearch}
                      onChange={(e) => setFieldSearch(e.target.value)}
                      className="flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
                      autoFocus
                    />
                  </div>
                  <div className="max-h-64 overflow-y-auto py-1">
                    {filteredFields.length === 0 ? (
                      <div className="px-3 py-4 text-center text-xs text-muted-foreground">
                        No fields found
                      </div>
                    ) : (
                      filteredFields.map((f) => (
                        <button
                          key={f.field}
                          onClick={() => handleFieldSelect(f)}
                          className="flex w-full items-center justify-between px-3 py-1.5 text-left text-xs hover:bg-muted"
                        >
                          <span className="truncate">{f.field}</span>
                          <span className="ml-2 shrink-0 text-[10px] text-muted-foreground">
                            {f.kind}
                          </span>
                        </button>
                      ))
                    )}
                  </div>
                </div>
              ) : selectedField?.kind === "bool" ? (
                <div className="flex flex-col gap-2.5 p-2.5">
                  <div className="text-xs font-medium text-muted-foreground">
                    {selectedField?.field}
                  </div>
                  <div className="flex gap-2">
                    <Button
                      variant="outline"
                      size="xs"
                      className="flex-1"
                      onClick={() => {
                        if (selectedField) addFilter(selectedField, "true");
                        setPopoverOpen(false);
                      }}
                    >
                      true
                    </Button>
                    <Button
                      variant="outline"
                      size="xs"
                      className="flex-1"
                      onClick={() => {
                        if (selectedField) addFilter(selectedField, "false");
                        setPopoverOpen(false);
                      }}
                    >
                      false
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="flex flex-col">
                  <div className="border-b border-border px-2.5 py-2 text-xs font-medium text-muted-foreground">
                    {selectedField?.field}
                  </div>
                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      handleValueSubmit();
                    }}
                    className="flex items-center gap-2 border-b border-border px-2.5 py-2"
                  >
                    <Search className="h-3.5 w-3.5 text-muted-foreground" />
                    <input
                      ref={valueInputRef}
                      type="text"
                      placeholder="Type to filter..."
                      value={valueInput}
                      onChange={(e) => setValueInput(e.target.value)}
                      className="flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
                    />
                    {valuesLoading && (
                      <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground" />
                    )}
                  </form>
                  <div className="max-h-48 overflow-y-auto py-1">
                    {valuesLoading && suggestedValues.length === 0 ? (
                      <div className="px-3 py-4 text-center text-xs text-muted-foreground">
                        Loading values...
                      </div>
                    ) : filteredValues.length > 0 ? (
                      filteredValues.map((v) => (
                        <button
                          key={v}
                          onClick={() => {
                            if (selectedField) addFilter(selectedField, v);
                            setPopoverOpen(false);
                          }}
                          className="flex w-full items-center px-3 py-1.5 text-left text-xs hover:bg-muted"
                        >
                          <span className="truncate">{v}</span>
                        </button>
                      ))
                    ) : !valuesLoading && valueInput ? (
                      <div className="px-3 py-2 text-center text-xs text-muted-foreground">
                        No matches — press Enter to use "{valueInput}"
                      </div>
                    ) : !valuesLoading ? (
                      <div className="px-3 py-2 text-center text-xs text-muted-foreground">
                        Type a value and press Enter
                      </div>
                    ) : null}
                  </div>
                </div>
              )}
            </PopoverContent>
          </Popover>
        </>
      )}

      {/* Raw query mode: text input + Run button */}
      {isRawMode && (
        <>
          <RawQueryInput
            value={rawInput}
            onChange={setRawInput}
            onSubmit={submitRawQuery}
            discoveredFields={discoveredFields}
            fetchValues={fetchValuesForAutocomplete}
          />
          <Button variant="default" size="xs" className="gap-1" onClick={submitRawQuery}>
            <Play className="h-3 w-3" />
            Run
          </Button>
        </>
      )}

      {/* Trailing content + raw mode toggle */}
      <div className="ml-auto flex items-center gap-2">
        {trailing}
        <Button
          variant="ghost"
          size="xs"
          className={`gap-1 text-muted-foreground hover:text-foreground ${isRawMode ? "bg-muted text-foreground" : ""}`}
          onClick={toggleRawMode}
          title={isRawMode ? "Switch to filter chips" : "Switch to raw query"}
        >
          <Code className="h-3 w-3" />
        </Button>
      </div>
    </div>
  );
}
