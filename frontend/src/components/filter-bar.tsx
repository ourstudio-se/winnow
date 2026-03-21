import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { X, Plus, Search, Loader2 } from "lucide-react";
import {
  getIndexMetadata,
  search as apiSearch,
  type IndexId,
} from "@/lib/api";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";

export interface FilterState {
  query: string;
  startTimestamp?: number;
  endTimestamp?: number;
}

interface FilterBarProps {
  index: IndexId;
  onFilterChange: (filters: FilterState) => void;
  /** Optional base query to scope autocomplete suggestions (e.g. "span_kind:3"). Defaults to "*". */
  baseQuery?: string;
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

interface TimePreset {
  label: string;
  seconds: number | null;
}

const TIME_PRESETS: TimePreset[] = [
  { label: "Last 15 minutes", seconds: 900 },
  { label: "Last 1 hour", seconds: 3600 },
  { label: "Last 6 hours", seconds: 21600 },
  { label: "Last 24 hours", seconds: 86400 },
  { label: "Last 7 days", seconds: 604800 },
  { label: "All time", seconds: null },
];

const DEFAULT_PRESET_INDEX = 1; // "Last 1 hour"

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

async function discoverFields(index: IndexId, baseQuery = "*"): Promise<DiscoveredField[]> {
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
        sort_by: "-span_start_timestamp_nanos",
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
  onRemove,
}: {
  filter: ActiveFilter;
  onRemove: () => void;
}) {
  return (
    <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs text-foreground">
      <span className="text-muted-foreground">{filter.field}</span>
      <span>=</span>
      <span className="font-medium">{filter.value}</span>
      <button
        onClick={onRemove}
        className="ml-0.5 rounded-sm p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
      >
        <X className="h-3 w-3" />
      </button>
    </span>
  );
}

export function FilterBar({ index, onFilterChange, baseQuery = "*" }: FilterBarProps) {
  const [activeFilters, setActiveFilters] = useState<ActiveFilter[]>([]);
  const [timePresetIndex, setTimePresetIndex] = useState(DEFAULT_PRESET_INDEX);
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
  const initialFiredRef = useRef(false);

  // Discover fields on mount / index change
  useEffect(() => {
    let cancelled = false;
    discoverFields(index, baseQuery)
      .then((fields) => {
        if (!cancelled) setDiscoveredFields(fields);
      })
      .catch((err) => console.warn("Field discovery failed:", err));
    return () => {
      cancelled = true;
    };
  }, [index, baseQuery]);

  // Build FilterState from current active filters + time preset.
  // Time range is embedded as a nanos range clause in the query string
  // (the traces index uses u64 timestamps, not datetime, so Quickwit's
  // start_timestamp/end_timestamp params don't apply).
  const buildFilterState = useCallback(
    (filters: ActiveFilter[], presetIdx: number): FilterState => {
      const preset = TIME_PRESETS[presetIdx];
      const parts: string[] = [];
      if (preset.seconds != null) {
        const nowNanos = BigInt(Date.now()) * 1_000_000n;
        const startNanos = nowNanos - BigInt(preset.seconds) * 1_000_000_000n;
        parts.push(
          `span_start_timestamp_nanos:[${startNanos} TO ${nowNanos}]`,
        );
      }
      const filterQuery = buildQuery(filters);
      if (filterQuery !== "*") parts.push(filterQuery);
      return {
        query: parts.length > 0 ? parts.join(" AND ") : "*",
      };
    },
    [],
  );

  // Fire initial filter on mount
  useEffect(() => {
    if (!initialFiredRef.current) {
      initialFiredRef.current = true;
      onFilterChange(buildFilterState(activeFilters, timePresetIndex));
    }
  }, [onFilterChange, buildFilterState, activeFilters, timePresetIndex]);

  function addFilter(field: DiscoveredField, value: string) {
    const trimmed = value.trim();
    if (!trimmed && field.kind === "text") return;
    const newFilter: ActiveFilter = {
      field: field.field,
      value: field.kind === "bool" ? trimmed : trimmed,
      kind: field.kind,
    };
    const next = [...activeFilters, newFilter];
    setActiveFilters(next);
    onFilterChange(buildFilterState(next, timePresetIndex));
  }

  function removeFilter(idx: number) {
    const next = activeFilters.filter((_, i) => i !== idx);
    setActiveFilters(next);
    onFilterChange(buildFilterState(next, timePresetIndex));
  }

  function handleTimePresetChange(newIndex: number) {
    setTimePresetIndex(newIndex);
    onFilterChange(buildFilterState(activeFilters, newIndex));
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

  // Filtered field list for the search
  const filteredFields = useMemo(() => {
    if (!fieldSearch) return discoveredFields;
    const lower = fieldSearch.toLowerCase();
    return discoveredFields.filter((f) =>
      f.field.toLowerCase().includes(lower),
    );
  }, [discoveredFields, fieldSearch]);

  const filteredValues = useMemo(() => {
    if (!valueInput) return suggestedValues;
    const lower = valueInput.toLowerCase();
    return suggestedValues.filter((v) => v.toLowerCase().includes(lower));
  }, [suggestedValues, valueInput]);

  return (
    <div className="flex flex-wrap items-center gap-2 border-b border-border bg-card px-3 py-2">
      {/* Time preset dropdown */}
      <select
        value={timePresetIndex}
        onChange={(e) => handleTimePresetChange(Number(e.target.value))}
        className="h-7 rounded-md border border-input bg-transparent px-2 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
      >
        {TIME_PRESETS.map((preset, i) => (
          <option key={i} value={i}>
            {preset.label}
          </option>
        ))}
      </select>

      {/* Active filter chips */}
      {activeFilters.map((f, i) => (
        <FilterChip key={`${f.field}-${i}`} filter={f} onRemove={() => removeFilter(i)} />
      ))}

      {/* Add filter popover */}
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
              {/* Search input */}
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
              {/* Field list */}
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
    </div>
  );
}
