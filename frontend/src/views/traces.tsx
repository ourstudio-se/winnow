import { useCallback, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams, Link } from "react-router";
import { AlertCircle, Map } from "lucide-react";
import { search } from "@/lib/api";
import { FilterBar, type FilterState } from "@/components/filter-bar";
import {
  type SpanDocument,
  type TraceSummary,
  groupSpansByTrace,
  formatDuration,
  formatTimestamp,
} from "@/lib/traces";

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
        const fpFilter = searchParams.getAll("f").find(f => f.startsWith("span_fingerprint:"));
        if (fpFilter && res.hits.length > 0) {
          const fpValue = fpFilter.slice("span_fingerprint:".length);
          const match = res.hits.find((h) => h.span_fingerprint === fpValue);
          if (match) setResolvedLabels((prev) => ({ ...prev, span_fingerprint: match.span_name }));
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
    const p = new URLSearchParams();
    const time = searchParams.get("time");
    if (time) p.set("time", time);
    for (const f of searchParams.getAll("f")) {
      p.append("f", f);
    }
    const qs = p.toString();
    return (
      <Link
        to={qs ? `/?${qs}` : "/"}
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
                          // Remove existing service_name filter, add new one
                          const existing = next.getAll("f");
                          next.delete("f");
                          for (const f of existing) {
                            if (!f.startsWith("service_name:")) next.append("f", f);
                          }
                          next.append("f", `service_name:${trace.rootServiceName}`);
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
