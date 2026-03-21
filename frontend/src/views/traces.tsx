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
  const [fingerprintFilter, setFingerprintFilter] = useState<string | null>(
    () => searchParams.get("fingerprint"),
  );
  const [fingerprintLabel, setFingerprintLabel] = useState<string | null>(null);
  const [peerFilter, setPeerFilter] = useState<string | null>(
    () => searchParams.get("peer"),
  );
  const [statusFilter, setStatusFilter] = useState<"ok" | "error" | null>(
    () => {
      const v = searchParams.get("status");
      return v === "ok" || v === "error" ? v : null;
    },
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
        if (peerFilter) {
          parts.push(`(span_kind:3 OR span_kind:4) AND span_attributes.peer.service:"${peerFilter}"`);
        }
        if (fingerprintFilter) {
          parts.push(`span_fingerprint:"${fingerprintFilter}"`);
        }
        if (statusFilter === "error") {
          parts.push("span_status.code:2");
        } else if (statusFilter === "ok") {
          parts.push("NOT span_status.code:2");
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
        // Resolve fingerprint → human-readable span name from first matching hit
        if (fingerprintFilter && res.hits.length > 0) {
          const match = res.hits.find(
            (h) => h.span_fingerprint === fingerprintFilter,
          );
          setFingerprintLabel(match?.span_name ?? null);
        }
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to fetch traces");
      } finally {
        setLoading(false);
      }
    },
    [serviceFilter, peerFilter, fingerprintFilter, statusFilter],
  );

  const handleFilterChange = useCallback(
    (filters: FilterState) => {
      fetchData(filters);
    },
    [fetchData],
  );

  function clearServiceFilter() {
    setServiceFilter(null);
    const next = new URLSearchParams(searchParams);
    next.delete("service");
    setSearchParams(next, { replace: true });
  }

  function clearPeerFilter() {
    setPeerFilter(null);
    const next = new URLSearchParams(searchParams);
    next.delete("peer");
    setSearchParams(next, { replace: true });
  }

  function clearFingerprintFilter() {
    setFingerprintFilter(null);
    setFingerprintLabel(null);
    const next = new URLSearchParams(searchParams);
    next.delete("fingerprint");
    setSearchParams(next, { replace: true });
  }

  function clearStatusFilter() {
    setStatusFilter(null);
    const next = new URLSearchParams(searchParams);
    next.delete("status");
    setSearchParams(next, { replace: true });
  }

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  return (
    <div className="flex flex-1 flex-col">
      <FilterBar index="otel-traces-v0_9" onFilterChange={handleFilterChange} />
      {(serviceFilter || peerFilter || fingerprintFilter || statusFilter) && (
        <div className="flex items-center gap-2 border-b border-border bg-muted/30 px-4 py-1.5">
          {serviceFilter && (
            <>
              <span className="text-xs text-muted-foreground">Service:</span>
              <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs font-medium text-foreground">
                {serviceFilter}
                <button
                  onClick={clearServiceFilter}
                  className="ml-0.5 rounded-sm p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
                >
                  <X className="h-3 w-3" />
                </button>
              </span>
            </>
          )}
          {peerFilter && (
            <>
              <span className="text-xs text-muted-foreground">Peer:</span>
              <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs font-medium text-foreground">
                {peerFilter}
                <button
                  onClick={clearPeerFilter}
                  className="ml-0.5 rounded-sm p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
                >
                  <X className="h-3 w-3" />
                </button>
              </span>
            </>
          )}
          {fingerprintFilter && (
            <>
              <span className="text-xs text-muted-foreground">Operation:</span>
              <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs font-medium text-foreground">
                {fingerprintLabel ?? fingerprintFilter.slice(0, 12) + "..."}
                <button
                  onClick={clearFingerprintFilter}
                  className="ml-0.5 rounded-sm p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
                >
                  <X className="h-3 w-3" />
                </button>
              </span>
            </>
          )}
          {statusFilter && (
            <>
              <span className="text-xs text-muted-foreground">Status:</span>
              <span className={`inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs font-medium ${
                statusFilter === "error"
                  ? "border-red-500/30 bg-red-500/10 text-red-400"
                  : "border-emerald-500/30 bg-emerald-500/10 text-emerald-400"
              }`}>
                {statusFilter === "error" ? "Errors" : "OK"}
                <button
                  onClick={clearStatusFilter}
                  className="ml-0.5 rounded-sm p-0.5 hover:bg-muted"
                >
                  <X className="h-3 w-3" />
                </button>
              </span>
            </>
          )}
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
