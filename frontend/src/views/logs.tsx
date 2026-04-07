import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams, Link } from "react-router";
import { ListTree, ExternalLink, ArrowUp, ArrowDown, ArrowUpDown, Columns3 } from "lucide-react";
import { searchLogs } from "@/lib/api";
import { FilterBar, type FilterState } from "@/components/filter-bar";
import { TimeHistogram } from "@/components/time-histogram";
import { serializeTimeParam, nanosToRfc3339 } from "@/lib/time";
import { formatTimestamp } from "@/lib/traces";
import {
  type LogDocument,
  type LogColumnDef,
  type SortDirection,
  extractBody,
  severityColor,
  discoverDataFields,
  getFieldValue,
  loadColumns,
  saveColumns,
  loadColumnWidths,
  saveColumnWidths,
  getColumnWidth,
  loadLogSort,
  saveLogSort,
  PSEUDO_COLUMNS,
  PSEUDO_SORT_FIELDS,
} from "@/lib/logs";
import { ColumnSelector } from "@/components/column-selector";
import { ResizeHandle } from "@/components/resize-handle";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";

const PAGE_SIZE = 200;

export function LogsView() {
  const [searchParams, setSearchParams] = useSearchParams();
  const [logs, setLogs] = useState<LogDocument[]>([]);
  const [numHits, setNumHits] = useState(0);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const filterBarStateRef = useRef<FilterState | undefined>(undefined);
  const [expandedLogIdx, setExpandedLogIdx] = useState<number | null>(null);

  // Column state
  const [columns, setColumns] = useState<string[]>(loadColumns);
  const [discoveredFields, setDiscoveredFields] = useState<LogColumnDef[]>([]);
  const [columnWidths, setColumnWidths] = useState<Record<string, number>>(loadColumnWidths);

  // Sort state
  const [sortField, setSortField] = useState<string | null>(() => loadLogSort()?.field ?? null);
  const [sortDir, setSortDir] = useState<SortDirection>(() => loadLogSort()?.dir ?? "desc");

  // Measure scroll container so the table always fills at least 100%
  const [containerWidth, setContainerWidth] = useState(0);
  const roRef = useRef<ResizeObserver | null>(null);
  const scrollRef = useCallback((el: HTMLDivElement | null) => {
    if (roRef.current) {
      roRef.current.disconnect();
      roRef.current = null;
    }
    if (el) {
      const ro = new ResizeObserver(([entry]) =>
        setContainerWidth(entry.contentRect.width),
      );
      ro.observe(el);
      roRef.current = ro;
    }
  }, []);

  // Compute exact pixel widths — extra space goes to _message (or last col)
  const { resolvedWidths, tableWidth } = useMemo(() => {
    const widths: Record<string, number> = {};
    let sum = 0;
    for (const id of columns) {
      widths[id] = getColumnWidth(columnWidths, id);
      sum += widths[id];
    }
    const tw = Math.max(sum, containerWidth);
    const slack = tw - sum;
    if (slack > 0 && columns.length > 0) {
      const flexCol = columns.includes("_message")
        ? "_message"
        : columns[columns.length - 1];
      widths[flexCol] += slack;
    }
    return { resolvedWidths: widths, tableWidth: tw };
  }, [columns, columnWidths, containerWidth]);

  // Persist columns to localStorage
  const handleColumnsChange = useCallback((newColumns: string[]) => {
    setColumns(newColumns);
    saveColumns(newColumns);
  }, []);

  // Resolve the base query from current filters (or the last known filters)
  const getBaseQuery = useCallback((filters?: FilterState) => {
    const effectiveFilters = filters ?? filterBarStateRef.current;
    return effectiveFilters?.query && effectiveFilters.query !== "*"
      ? effectiveFilters.query
      : "*";
  }, []);

  const buildSortBy = useCallback(
    (field: string | null, dir: SortDirection) => {
      if (!field) return "-timestamp_nanos";
      return dir === "desc" ? `-${field}` : field;
    },
    [],
  );

  const fetchData = useCallback(
    async (filters?: FilterState) => {
      setLoading(true);
      setError(null);
      try {
        const res = await searchLogs<LogDocument>({
          query: getBaseQuery(filters),
          max_hits: PAGE_SIZE,
          sort_by: buildSortBy(sortField, sortDir),
        });
        setNumHits(res.num_hits);
        setLogs(res.hits);
        setDiscoveredFields(discoverDataFields(res.hits));
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to fetch logs");
      } finally {
        setLoading(false);
      }
    },
    [getBaseQuery, buildSortBy, sortField, sortDir],
  );

  const loadMore = useCallback(async () => {
    if (logs.length === 0) return;

    setLoadingMore(true);
    try {
      let res;
      if (!sortField) {
        // Default sort (timestamp desc): use cursor-based pagination
        const lastTs = logs[logs.length - 1].timestamp_nanos;
        const lastTsRfc = nanosToRfc3339(lastTs);
        const base = getBaseQuery();
        const cursorQuery = base === "*"
          ? `timestamp_nanos:<${lastTsRfc}`
          : `${base} AND timestamp_nanos:<${lastTsRfc}`;
        res = await searchLogs<LogDocument>({
          query: cursorQuery,
          max_hits: PAGE_SIZE,
          sort_by: "-timestamp_nanos",
        });
      } else {
        // Custom sort: use start_offset pagination
        res = await searchLogs<LogDocument>({
          query: getBaseQuery(),
          max_hits: PAGE_SIZE,
          sort_by: buildSortBy(sortField, sortDir),
          start_offset: logs.length,
        });
      }
      const allLogs = [...logs, ...res.hits];
      setLogs(allLogs);
      setDiscoveredFields(discoverDataFields(allLogs));
    } catch {
      // Silently fail — user can retry
    } finally {
      setLoadingMore(false);
    }
  }, [getBaseQuery, buildSortBy, sortField, sortDir, logs]);

  const [currentQuery, setCurrentQuery] = useState("*");

  const handleFilterChange = useCallback(
    (filters: FilterState) => {
      filterBarStateRef.current = filters;
      setCurrentQuery(filters.query);
      fetchData(filters);
    },
    [fetchData],
  );

  const handleHistogramRangeSelect = useCallback(
    (from: Date, to: Date) => {
      const next = new URLSearchParams(searchParams);
      next.set("time", serializeTimeParam({ type: "absolute", from, to }));
      setSearchParams(next, { replace: true });
    },
    [searchParams, setSearchParams],
  );

  const handleSort = useCallback(
    (colId: string) => {
      const qwField = PSEUDO_SORT_FIELDS[colId];
      if (qwField === undefined) return; // not sortable

      let nextField: string | null;
      let nextDir: SortDirection;

      if (sortField === qwField && sortDir === "desc") {
        // desc → asc
        nextField = qwField;
        nextDir = "asc";
      } else if (sortField === qwField && sortDir === "asc") {
        // asc → reset to default
        nextField = null;
        nextDir = "desc";
      } else {
        // different field or no sort → sort this field desc
        nextField = qwField;
        nextDir = "desc";
      }

      setSortField(nextField);
      setSortDir(nextDir);
      saveLogSort(nextField ? { field: nextField, dir: nextDir } : null);
    },
    [sortField, sortDir],
  );

  // Re-fetch when sort changes (skip initial mount — fetchData is triggered by FilterBar)
  const sortMountRef = useRef(true);
  useEffect(() => {
    if (sortMountRef.current) {
      sortMountRef.current = false;
      return;
    }
    fetchData();
  }, [sortField, sortDir]); // eslint-disable-line react-hooks/exhaustive-deps

  const tracesLink = useMemo(() => {
    const p = new URLSearchParams();
    const time = searchParams.get("time");
    if (time) p.set("time", time);
    for (const f of searchParams.getAll("f")) {
      p.append("f", f);
    }
    const q = searchParams.get("q");
    if (q != null) p.set("q", q);
    const qs = p.toString();
    return (
      <Link
        to={qs ? `/traces?${qs}` : "/traces"}
        className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
      >
        <ListTree className="h-3 w-3" />
        Traces
      </Link>
    );
  }, [searchParams]);

  // Resolve column defs for current active columns
  const pseudoMap = useMemo(() => {
    const m = new Map<string, LogColumnDef>();
    for (const c of PSEUDO_COLUMNS) m.set(c.id, c);
    return m;
  }, []);

  const columnCount = columns.length;

  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      <FilterBar
        index="logs"
        timestampField="timestamp_nanos"
        onFilterChange={handleFilterChange}
        trailing={
          <>
            <Popover>
              <PopoverTrigger asChild>
                <Button variant="ghost" size="sm" className="gap-1 text-muted-foreground hover:text-foreground">
                  <Columns3 className="h-3 w-3" /> Columns
                </Button>
              </PopoverTrigger>
              <PopoverContent align="end" className="w-64 p-0" sideOffset={8}>
                <div className="max-h-96 overflow-y-auto p-3">
                  <ColumnSelector
                    activeColumns={columns}
                    availableData={discoveredFields}
                    onColumnsChange={handleColumnsChange}
                  />
                </div>
              </PopoverContent>
            </Popover>
            {tracesLink}
          </>
        }
      />
      {!loading && !error && logs.length > 0 && (
        <TimeHistogram
          index="logs"
          timestampField="timestamp_nanos"
          query={currentQuery}
          onRangeSelect={handleHistogramRangeSelect}
        />
      )}
      {loading ? (
        <div className="flex flex-1 items-center justify-center text-muted-foreground">
          Loading logs...
        </div>
      ) : error ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-3">
          <p className="text-destructive">{error}</p>
          <button
            onClick={() => fetchData()}
            className="rounded-md bg-secondary px-3 py-1.5 text-sm text-secondary-foreground hover:bg-secondary/80"
          >
            Retry
          </button>
        </div>
      ) : logs.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 text-muted-foreground">
          <h2 className="text-lg font-medium text-foreground">
            No logs found
          </h2>
          <p className="text-sm">
            Send logs through the OTLP endpoint to see them here.
          </p>
        </div>
      ) : (
        <div className="flex flex-1 flex-col overflow-hidden">
          {numHits > logs.length && (
            <div className="border-b border-border bg-muted/30 px-4 py-1.5 text-xs text-muted-foreground">
              Showing {logs.length.toLocaleString()} of {numHits.toLocaleString()} matching logs
            </div>
          )}
          <div ref={scrollRef} className="flex-1 overflow-auto">
            <table
              className="text-sm"
              style={{ tableLayout: "fixed", width: tableWidth }}
            >
              <thead className="sticky top-0 z-10 border-b border-border bg-card text-xs text-muted-foreground">
                <tr>
                  {columns.map((colId) => {
                    const pseudo = pseudoMap.get(colId);
                    const label = pseudo?.label ?? colId;
                    const align = colId === "_trace" ? "text-center" : "text-left";
                    const w = resolvedWidths[colId];
                    const qwSortField = pseudo ? PSEUDO_SORT_FIELDS[colId] : undefined;
                    const sortable = qwSortField !== undefined;
                    const isActiveSort = sortable && sortField === qwSortField;
                    return (
                      <th
                        key={colId}
                        className={`relative px-4 py-2 font-medium ${align} overflow-hidden text-ellipsis whitespace-nowrap`}
                        style={{ width: w, maxWidth: w }}
                      >
                        {sortable ? (
                          <button
                            onClick={() => handleSort(colId)}
                            className="inline-flex items-center gap-1 hover:text-foreground"
                          >
                            {label}
                            {isActiveSort ? (
                              sortDir === "desc" ? <ArrowDown className="h-3 w-3" /> : <ArrowUp className="h-3 w-3" />
                            ) : (
                              <ArrowUpDown className="h-3 w-3 opacity-0 group-hover/th:opacity-100" />
                            )}
                          </button>
                        ) : (
                          label
                        )}
                        <ResizeHandle
                          width={w}
                          onResize={(newW) =>
                            setColumnWidths((prev) => ({ ...prev, [colId]: newW }))
                          }
                          onResizeEnd={(newW) => {
                            setColumnWidths((prev) => {
                              const next = { ...prev, [colId]: newW };
                              saveColumnWidths(next);
                              return next;
                            });
                          }}
                        />
                      </th>
                    );
                  })}
                </tr>
              </thead>
              <tbody>
                {logs.map((log, idx) => {
                  const isExpanded = expandedLogIdx === idx;
                  return (
                    <LogRow
                      key={idx}
                      log={log}
                      columns={columns}
                      columnCount={columnCount}
                      isExpanded={isExpanded}
                      onToggle={() =>
                        setExpandedLogIdx(isExpanded ? null : idx)
                      }
                      onServiceClick={(serviceName) => {
                        const next = new URLSearchParams(searchParams);
                        const existing = next.getAll("f");
                        next.delete("f");
                        for (const f of existing) {
                          if (!f.startsWith("service_name:"))
                            next.append("f", f);
                        }
                        next.append("f", `service_name:${serviceName}`);
                        setSearchParams(next, { replace: true });
                      }}
                    />
                  );
                })}
              </tbody>
            </table>
            {numHits > logs.length && (
              <div className="flex justify-center border-t border-border py-3">
                <button
                  onClick={loadMore}
                  disabled={loadingMore}
                  className="text-sm text-muted-foreground hover:text-foreground disabled:opacity-50"
                >
                  {loadingMore
                    ? "Loading..."
                    : `Load ${Math.min(PAGE_SIZE, numHits - logs.length).toLocaleString()} more logs`}
                </button>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function LogRow({
  log,
  columns,
  columnCount,
  isExpanded,
  onToggle,
  onServiceClick,
}: {
  log: LogDocument;
  columns: string[];
  columnCount: number;
  isExpanded: boolean;
  onToggle: () => void;
  onServiceClick: (serviceName: string) => void;
}) {
  const bodyText = extractBody(log.body);

  return (
    <>
      <tr
        onClick={onToggle}
        className="cursor-pointer border-b border-border/50 hover:bg-muted/30"
      >
        {columns.map((colId) => (
          <LogCell
            key={colId}
            colId={colId}
            log={log}
            bodyText={bodyText}
            onServiceClick={onServiceClick}
          />
        ))}
      </tr>
      {isExpanded && (
        <tr className="border-b border-border/50 bg-muted/20">
          <td colSpan={columnCount} className="px-4 py-3">
            <LogDetail log={log} bodyText={bodyText} />
          </td>
        </tr>
      )}
    </>
  );
}

function LogCell({
  colId,
  log,
  bodyText,
  onServiceClick,
}: {
  colId: string;
  log: LogDocument;
  bodyText: string;
  onServiceClick: (serviceName: string) => void;
}) {
  switch (colId) {
    case "_timestamp":
      return (
        <td className="whitespace-nowrap px-4 py-2 text-xs text-muted-foreground">
          {formatTimestamp(log.timestamp_nanos)}
        </td>
      );
    case "_severity":
      return (
        <td className="whitespace-nowrap px-4 py-2">
          <span
            className={`text-xs font-medium ${severityColor(log.severity_text)}`}
          >
            {log.severity_text || `SEV${log.severity_number}`}
          </span>
        </td>
      );
    case "_service":
      return (
        <td className="whitespace-nowrap px-4 py-2">
          <span
            onClick={(e) => {
              e.stopPropagation();
              onServiceClick(log.service_name);
            }}
            className="font-medium underline decoration-muted-foreground/30 hover:decoration-foreground"
          >
            {log.service_name}
          </span>
        </td>
      );
    case "_message":
      return (
        <td className="truncate px-4 py-2 text-muted-foreground">
          {bodyText}
        </td>
      );
    case "_trace":
      return (
        <td className="whitespace-nowrap px-4 py-2 text-center">
          {log.trace_id ? (
            <Link
              to={`/traces/${log.trace_id}${log.span_id ? `?span=${log.span_id}` : ""}`}
              onClick={(e) => e.stopPropagation()}
              className="inline-flex text-muted-foreground hover:text-foreground"
            >
              <ExternalLink className="h-3.5 w-3.5" />
            </Link>
          ) : null}
        </td>
      );
    default:
      // Data field
      return (
        <td className="truncate px-4 py-2 font-mono text-xs text-muted-foreground">
          {getFieldValue(log, colId)}
        </td>
      );
  }
}

function LogDetail({
  log,
  bodyText,
}: {
  log: LogDocument;
  bodyText: string;
}) {
  const hasAttributes =
    log.attributes && Object.keys(log.attributes).length > 0;
  const hasResourceAttributes =
    log.resource_attributes && Object.keys(log.resource_attributes).length > 0;

  return (
    <div className="flex flex-col gap-3 text-xs">
      {/* Body */}
      <div>
        <div className="mb-1 font-medium text-muted-foreground">Body</div>
        <pre className="whitespace-pre-wrap break-all rounded bg-muted/50 p-2 font-mono text-foreground">
          {bodyText}
        </pre>
      </div>

      {/* Attributes */}
      {hasAttributes && (
        <div>
          <div className="mb-1 font-medium text-muted-foreground">
            Attributes
          </div>
          <KeyValueTable data={log.attributes!} />
        </div>
      )}

      {/* Resource attributes */}
      {hasResourceAttributes && (
        <div>
          <div className="mb-1 font-medium text-muted-foreground">
            Resource Attributes
          </div>
          <KeyValueTable data={log.resource_attributes!} />
        </div>
      )}

      {/* Trace / Span IDs */}
      {(log.trace_id || log.span_id) && (
        <div className="flex gap-4 font-mono text-muted-foreground">
          {log.trace_id && (
            <span>
              trace_id:{" "}
              <Link
                to={`/traces/${log.trace_id}`}
                className="text-foreground underline decoration-muted-foreground/30 hover:decoration-foreground"
              >
                {log.trace_id}
              </Link>
            </span>
          )}
          {log.span_id && (
            <span>
              span_id:{" "}
              {log.trace_id ? (
                <Link
                  to={`/traces/${log.trace_id}?span=${log.span_id}`}
                  className="text-foreground underline decoration-muted-foreground/30 hover:decoration-foreground"
                >
                  {log.span_id}
                </Link>
              ) : (
                log.span_id
              )}
            </span>
          )}
        </div>
      )}
    </div>
  );
}

function KeyValueTable({ data }: { data: Record<string, unknown> }) {
  const entries = flattenObject(data);
  return (
    <table className="w-full text-xs">
      <tbody>
        {entries.map(([key, value]) => (
          <tr key={key} className="border-b border-border/30">
            <td className="whitespace-nowrap py-1 pr-4 font-mono text-muted-foreground">
              {key}
            </td>
            <td className="break-all py-1 font-mono text-foreground">
              {typeof value === "string" ? value : JSON.stringify(value)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function flattenObject(
  obj: Record<string, unknown>,
  prefix = "",
): [string, unknown][] {
  const result: [string, unknown][] = [];
  for (const [key, val] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (val != null && typeof val === "object" && !Array.isArray(val)) {
      result.push(...flattenObject(val as Record<string, unknown>, path));
    } else {
      result.push([path, val]);
    }
  }
  return result;
}
