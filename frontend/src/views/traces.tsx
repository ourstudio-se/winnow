import { useCallback, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams, Link } from "react-router";
import { AlertCircle, Map } from "lucide-react";
import { search } from "@/lib/api";
import { FilterBar, type FilterState, type UrlFilterConfig } from "@/components/filter-bar";
import {
  type SpanDocument,
  type TraceSummary,
  groupSpansByTrace,
  formatDuration,
  formatTimestamp,
} from "@/lib/traces";

const TRACES_URL_FILTERS: UrlFilterConfig[] = [
  {
    param: "service",
    label: "Service",
    hiddenField: "service_name",
    buildClause: (v) => `service_name:"${v}"`,
  },
  {
    param: "peer",
    label: "Peer",
    hiddenField: "span_attributes.peer.service",
    buildClause: (v) => `(span_kind:3 OR span_kind:4) AND span_attributes.peer.service:"${v}"`,
  },
  {
    param: "fingerprint",
    label: "Operation",
    hiddenField: "span_fingerprint",
    buildClause: (v) => `span_fingerprint:"${v}"`,
    renderValue: (v) => ({ text: v.slice(0, 12) + "...", className: "font-mono" }),
  },
  {
    param: "status",
    label: "Status",
    buildClause: (v) => v === "error" ? "span_status.code:2" : "NOT span_status.code:2",
    renderValue: (v) =>
      v === "error"
        ? { text: "Errors", className: "text-red-400" }
        : { text: "OK", className: "text-emerald-400" },
  },
];

export function TracesView() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const [traces, setTraces] = useState<TraceSummary[]>([]);
  const [numHits, setNumHits] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const filterBarStateRef = useRef<FilterState | undefined>(undefined);
  const [resolvedLabels, setResolvedLabels] = useState<Record<string, string>>({});

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
        const res = await search<SpanDocument>("otel-traces-v0_9", {
          query,
          max_hits: 200,
          sort_by: "-span_start_timestamp_nanos",
        });
        setNumHits(res.num_hits);
        setTraces(groupSpansByTrace(res.hits));
        // Resolve fingerprint → human-readable span name from first matching hit
        const fp = searchParams.get("fingerprint");
        if (fp && res.hits.length > 0) {
          const match = res.hits.find((h) => h.span_fingerprint === fp);
          if (match) setResolvedLabels((prev) => ({ ...prev, fingerprint: match.span_name }));
        }
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to fetch traces");
      } finally {
        setLoading(false);
      }
    },
    [searchParams],
  );

  const handleFilterChange = useCallback(
    (filters: FilterState) => {
      filterBarStateRef.current = filters;
      fetchData(filters);
    },
    [fetchData],
  );

  const serviceMapLink = useMemo(() => {
    const svc = searchParams.get("service");
    const peer = searchParams.get("peer");
    if (!svc && !peer) return null;
    const p = new URLSearchParams();
    if (svc) p.set("service", svc);
    if (peer) p.set("peer", peer);
    return (
      <Link
        to={`/?${p}`}
        className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
      >
        <Map className="h-3 w-3" />
        Service Map
      </Link>
    );
  }, [searchParams]);

  return (
    <div className="flex flex-1 flex-col">
      <FilterBar
        index="otel-traces-v0_9"
        onFilterChange={handleFilterChange}
        urlFilters={TRACES_URL_FILTERS}
        resolvedLabels={resolvedLabels}
        trailing={serviceMapLink}
      />
      {loading ? (
        <div className="flex flex-1 items-center justify-center text-muted-foreground">
          Loading traces...
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
      ) : traces.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 text-muted-foreground">
          <h2 className="text-lg font-medium text-foreground">
            No traces found
          </h2>
          <p className="text-sm">
            Send traces through the OTLP endpoint to see them here.
          </p>
        </div>
      ) : (
        <div className="flex flex-1 flex-col overflow-hidden">
          {numHits > 200 && (
            <div className="border-b border-border bg-muted/30 px-4 py-1.5 text-xs text-muted-foreground">
              Showing traces from 200 of {numHits.toLocaleString()} matching spans
            </div>
          )}
          <div className="flex-1 overflow-y-auto">
            <table className="w-full text-sm">
              <thead className="sticky top-0 z-10 border-b border-border bg-card text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-2 text-left font-medium">Timestamp</th>
                  <th className="px-4 py-2 text-left font-medium">Service</th>
                  <th className="px-4 py-2 text-left font-medium">Operation</th>
                  <th className="px-4 py-2 text-right font-medium">Duration</th>
                  <th className="px-4 py-2 text-right font-medium">Spans</th>
                  <th className="px-4 py-2 text-center font-medium">Status</th>
                </tr>
              </thead>
              <tbody>
                {traces.map((trace) => (
                  <tr
                    key={trace.traceId}
                    onClick={() => navigate(`/traces/${trace.traceId}`)}
                    className="cursor-pointer border-b border-border/50 hover:bg-muted/30"
                  >
                    <td className="whitespace-nowrap px-4 py-2 text-xs text-muted-foreground">
                      {formatTimestamp(trace.startTimestampNanos)}
                    </td>
                    <td className="px-4 py-2">
                      <span
                        onClick={(e) => {
                          e.stopPropagation();
                          const next = new URLSearchParams(searchParams);
                          next.set("service", trace.rootServiceName);
                          setSearchParams(next, { replace: true });
                        }}
                        className="font-medium underline decoration-muted-foreground/30 hover:decoration-foreground"
                      >
                        {trace.rootServiceName}
                      </span>
                      {trace.serviceCount > 1 && (
                        <span className="ml-1.5 text-xs text-muted-foreground">
                          +{trace.serviceCount - 1}
                        </span>
                      )}
                    </td>
                    <td className="max-w-xs truncate px-4 py-2 text-muted-foreground">
                      {trace.rootSpanName}
                    </td>
                    <td className="whitespace-nowrap px-4 py-2 text-right tabular-nums">
                      {formatDuration(trace.durationMillis)}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                      {trace.spanCount}
                    </td>
                    <td className="px-4 py-2 text-center">
                      {trace.hasError ? (
                        <AlertCircle className="mx-auto h-4 w-4 text-red-500" />
                      ) : (
                        <span className="inline-block h-2 w-2 rounded-full bg-emerald-500" />
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
