import { useCallback, useMemo, useRef, useState } from "react";
import { useSearchParams, Link } from "react-router";
import { ListTree, ExternalLink } from "lucide-react";
import { search } from "@/lib/api";
import { FilterBar, type FilterState } from "@/components/filter-bar";
import { formatTimestamp } from "@/lib/traces";
import {
  type LogDocument,
  extractBody,
  severityColor,
} from "@/lib/logs";

export function LogsView() {
  const [searchParams, setSearchParams] = useSearchParams();
  const [logs, setLogs] = useState<LogDocument[]>([]);
  const [numHits, setNumHits] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const filterBarStateRef = useRef<FilterState | undefined>(undefined);
  const [expandedLogIdx, setExpandedLogIdx] = useState<number | null>(null);

  const fetchData = useCallback(
    async (filters?: FilterState) => {
      const effectiveFilters = filters ?? filterBarStateRef.current;
      setLoading(true);
      setError(null);
      try {
        const query =
          effectiveFilters?.query && effectiveFilters.query !== "*"
            ? effectiveFilters.query
            : "*";
        const res = await search<LogDocument>("otel-logs-v0_9", {
          query,
          max_hits: 200,
          sort_by: "-timestamp_nanos",
        });
        setNumHits(res.num_hits);
        setLogs(res.hits);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to fetch logs");
      } finally {
        setLoading(false);
      }
    },
    [],
  );

  const handleFilterChange = useCallback(
    (filters: FilterState) => {
      filterBarStateRef.current = filters;
      fetchData(filters);
    },
    [fetchData],
  );

  const tracesLink = useMemo(() => {
    const p = new URLSearchParams();
    const time = searchParams.get("time");
    if (time) p.set("time", time);
    for (const f of searchParams.getAll("f")) {
      p.append("f", f);
    }
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

  return (
    <div className="flex flex-1 flex-col">
      <FilterBar
        index="otel-logs-v0_9"
        timestampField="timestamp_nanos"
        onFilterChange={handleFilterChange}
        trailing={tracesLink}
      />
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
          {numHits > 200 && (
            <div className="border-b border-border bg-muted/30 px-4 py-1.5 text-xs text-muted-foreground">
              Showing 200 of {numHits.toLocaleString()} matching logs
            </div>
          )}
          <div className="flex-1 overflow-y-auto">
            <table className="w-full text-sm">
              <thead className="sticky top-0 z-10 border-b border-border bg-card text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-2 text-left font-medium">Timestamp</th>
                  <th className="px-4 py-2 text-left font-medium">Severity</th>
                  <th className="px-4 py-2 text-left font-medium">Service</th>
                  <th className="px-4 py-2 text-left font-medium">Message</th>
                  <th className="px-4 py-2 text-center font-medium">Trace</th>
                </tr>
              </thead>
              <tbody>
                {logs.map((log, idx) => {
                  const isExpanded = expandedLogIdx === idx;
                  return (
                    <LogRow
                      key={idx}
                      log={log}
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
          </div>
        </div>
      )}
    </div>
  );
}

function LogRow({
  log,
  isExpanded,
  onToggle,
  onServiceClick,
}: {
  log: LogDocument;
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
        <td className="whitespace-nowrap px-4 py-2 text-xs text-muted-foreground">
          {formatTimestamp(log.timestamp_nanos)}
        </td>
        <td className="px-4 py-2">
          <span
            className={`text-xs font-medium ${severityColor(log.severity_text)}`}
          >
            {log.severity_text || `SEV${log.severity_number}`}
          </span>
        </td>
        <td className="px-4 py-2">
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
        <td className="max-w-md truncate px-4 py-2 text-muted-foreground">
          {bodyText}
        </td>
        <td className="px-4 py-2 text-center">
          {log.trace_id ? (
            <Link
              to={`/traces/${log.trace_id}`}
              onClick={(e) => e.stopPropagation()}
              className="inline-flex text-muted-foreground hover:text-foreground"
            >
              <ExternalLink className="h-3.5 w-3.5" />
            </Link>
          ) : null}
        </td>
      </tr>
      {isExpanded && (
        <tr className="border-b border-border/50 bg-muted/20">
          <td colSpan={5} className="px-4 py-3">
            <LogDetail log={log} bodyText={bodyText} />
          </td>
        </tr>
      )}
    </>
  );
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
          {log.span_id && <span>span_id: {log.span_id}</span>}
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
