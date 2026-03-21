import { useCallback, useEffect, useState } from "react";
import { useNavigate, useSearchParams, Link } from "react-router";
import { AlertCircle, X, Map } from "lucide-react";
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
  const [serviceFilter, setServiceFilter] = useState<string | null>(
    () => searchParams.get("service"),
  );
  const [traces, setTraces] = useState<TraceSummary[]>([]);
  const [numHits, setNumHits] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(
    async (filters?: FilterState) => {
      setLoading(true);
      setError(null);
      try {
        const parts: string[] = [];
        if (serviceFilter) {
          parts.push(`service_name:"${serviceFilter}"`);
        }
        if (filters?.query && filters.query !== "*") {
          parts.push(filters.query);
        }
        const query = parts.length > 0 ? parts.join(" AND ") : "*";
        const res = await search<SpanDocument>("otel-traces-v0_9", {
          query,
          max_hits: 200,
          sort_by: "-span_start_timestamp_nanos",
        });
        setNumHits(res.num_hits);
        setTraces(groupSpansByTrace(res.hits));
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to fetch traces");
      } finally {
        setLoading(false);
      }
    },
    [serviceFilter],
  );

  const handleFilterChange = useCallback(
    (filters: FilterState) => {
      fetchData(filters);
    },
    [fetchData],
  );

  function clearServiceFilter() {
    setServiceFilter(null);
    setSearchParams({}, { replace: true });
  }

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  return (
    <div className="flex flex-1 flex-col">
      <FilterBar index="otel-traces-v0_9" onFilterChange={handleFilterChange} />
      {serviceFilter && (
        <div className="flex items-center gap-2 border-b border-border bg-muted/30 px-4 py-1.5">
          <span className="text-xs text-muted-foreground">Filtered by service:</span>
          <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs font-medium text-foreground">
            {serviceFilter}
            <button
              onClick={clearServiceFilter}
              className="ml-0.5 rounded-sm p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
            >
              <X className="h-3 w-3" />
            </button>
          </span>
          <Link
            to="/"
            className="ml-auto flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
          >
            <Map className="h-3 w-3" />
            Service Map
          </Link>
        </div>
      )}
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
                          navigate(`/traces?service=${encodeURIComponent(trace.rootServiceName)}`);
                          setServiceFilter(trace.rootServiceName);
                          setSearchParams({ service: trace.rootServiceName }, { replace: true });
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
