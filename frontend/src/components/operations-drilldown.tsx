import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { X, AlertTriangle, CircleCheck, Loader2 } from "lucide-react";
import { searchTraces } from "@/lib/api";
import { SPAN_KIND_SHORT, formatDuration } from "@/lib/traces";
import { parseTimeParam, buildTimeRangeClause } from "@/lib/time";
import { type SampledSpan, deriveEdgeOperations } from "@/lib/service-graph";

interface OperationsDrilldownProps {
  serviceName: string;
  errorsOnly: boolean;
  isImplicit: boolean;
  sourceService?: string;
  sampledSpans?: SampledSpan[];
  onClose: () => void;
  onToggleErrorsOnly: (errorsOnly: boolean) => void;
}

interface OperationRow {
  fingerprint: string;
  spanName: string;
  spanKind: number;
  count: number;
  avgDurationMs: number;
  status: "ok" | "error";
}

interface DrilldownSpanDoc {
  span_fingerprint: string | null;
  span_name: string;
  span_kind: number;
}

interface TermsBucket {
  key: string;
  doc_count: number;
  avg_duration?: { value: number };
}

interface TermsAgg {
  buckets: TermsBucket[];
}

type SearchResult = {
  hits: DrilldownSpanDoc[];
  aggregations?: Record<string, unknown>;
};

const AGG_SHAPE = {
  operations: {
    terms: { field: "span_fingerprint", size: 50 },
    aggs: {
      avg_duration: { avg: { field: "span_duration_millis" } },
    },
  },
};

function bucketsToRows(
  buckets: TermsBucket[],
  fpLookup: Map<string, { spanName: string; spanKind: number }>,
  status: "ok" | "error",
): OperationRow[] {
  return buckets.map((b) => {
    const info = fpLookup.get(b.key);
    return {
      fingerprint: b.key,
      spanName: info?.spanName ?? b.key.slice(0, 12) + "...",
      spanKind: info?.spanKind ?? 0,
      count: b.doc_count,
      avgDurationMs: b.avg_duration?.value ?? 0,
      status,
    };
  });
}

export function OperationsDrilldownPanel({
  serviceName,
  errorsOnly,
  isImplicit,
  sourceService,
  sampledSpans,
  onClose,
  onToggleErrorsOnly,
}: OperationsDrilldownProps) {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const [operations, setOperations] = useState<OperationRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Edge → real service: derive operations client-side from sampled spans
  // (same parent-child join logic that produces the edge count labels)
  const useClientSide = !!sourceService && !isImplicit && !!sampledSpans;

  const clientSideOps = useMemo(() => {
    if (!useClientSide) return null;
    return deriveEdgeOperations(sampledSpans, sourceService!, serviceName);
  }, [useClientSide, sampledSpans, sourceService, serviceName]);

  // Client-side path: convert DerivedOperation[] → OperationRow[]
  useEffect(() => {
    if (!useClientSide || !clientSideOps) return;

    const rows: OperationRow[] = [];
    for (const op of clientSideOps) {
      if (op.errorCount > 0) {
        rows.push({
          fingerprint: `${op.spanName}\0${op.spanKind}`,
          spanName: op.spanName,
          spanKind: op.spanKind,
          count: op.errorCount,
          avgDurationMs: op.avgDurationMs,
          status: "error",
        });
      }
      const okCount = op.count - op.errorCount;
      if (okCount > 0 && !errorsOnly) {
        rows.push({
          fingerprint: `${op.spanName}\0${op.spanKind}`,
          spanName: op.spanName,
          spanKind: op.spanKind,
          count: okCount,
          avgDurationMs: op.avgDurationMs,
          status: "ok",
        });
      }
    }
    rows.sort((a, b) => b.count - a.count);
    setOperations(rows);
    setLoading(false);
    setError(null);
  }, [useClientSide, clientSideOps, errorsOnly]);

  // Server-side path: Quickwit queries (node drilldowns + implicit targets)
  const fetchOperations = useCallback(async () => {
    if (useClientSide) return;
    setLoading(true);
    setError(null);
    try {
      const timeSel = parseTimeParam(searchParams.get("time"));
      const timeClause = buildTimeRangeClause(timeSel);
      const serviceBase = isImplicit
        ? sourceService
          ? `service_name:"${sourceService}" AND (span_kind:3 OR span_kind:4) AND (span_attributes.peer.service:"${serviceName}" OR span_attributes.db.system:"${serviceName}")`
          : `(span_kind:3 OR span_kind:4) AND (span_attributes.peer.service:"${serviceName}" OR span_attributes.db.system:"${serviceName}")`
        : `service_name:"${serviceName}" AND (span_kind:2 OR span_kind:5)`;
      const base = `${timeClause} AND ${serviceBase}`;
      const errorQuery = `${base} AND span_status.code:2`;
      const okQuery = `${base} AND NOT span_status.code:2`;

      // Always fetch errors; fetch OK only when not errorsOnly
      const errorReq = searchTraces<DrilldownSpanDoc>({
        query: errorQuery,
        max_hits: 100,
        aggs: AGG_SHAPE,
      });
      const okReq = errorsOnly
        ? null
        : searchTraces<DrilldownSpanDoc>({
            query: okQuery,
            max_hits: 100,
            aggs: AGG_SHAPE,
          });

      const [errorRes, okRes] = await Promise.all([
        errorReq,
        okReq ?? Promise.resolve(null),
      ]) as [SearchResult, SearchResult | null];

      // Build fingerprint → {spanName, spanKind} lookup from sample hits
      const fpLookup = new Map<string, { spanName: string; spanKind: number }>();
      for (const hit of errorRes.hits) {
        if (hit.span_fingerprint && !fpLookup.has(hit.span_fingerprint)) {
          fpLookup.set(hit.span_fingerprint, {
            spanName: hit.span_name,
            spanKind: hit.span_kind,
          });
        }
      }
      if (okRes) {
        for (const hit of okRes.hits) {
          if (hit.span_fingerprint && !fpLookup.has(hit.span_fingerprint)) {
            fpLookup.set(hit.span_fingerprint, {
              spanName: hit.span_name,
              spanKind: hit.span_kind,
            });
          }
        }
      }

      const errorBuckets =
        (errorRes.aggregations?.operations as TermsAgg | undefined)?.buckets ?? [];
      const okBuckets = okRes
        ? ((okRes.aggregations?.operations as TermsAgg | undefined)?.buckets ?? [])
        : [];

      // Resolve any fingerprints missing from the lookup (sample hits
      // didn't cover all agg buckets)
      const allBuckets = [...errorBuckets, ...okBuckets];
      const missingFps = allBuckets
        .map((b) => b.key)
        .filter((fp) => !fpLookup.has(fp));
      const uniqueMissing = [...new Set(missingFps)];
      if (uniqueMissing.length > 0) {
        const fpClauses = uniqueMissing.map((fp) => `span_fingerprint:"${fp}"`).join(" OR ");
        const resolveQuery = `${base} AND (${fpClauses})`;
        try {
          const resolveRes = await searchTraces<DrilldownSpanDoc>({
            query: resolveQuery,
            max_hits: uniqueMissing.length * 2,
          });
          for (const hit of resolveRes.hits) {
            if (hit.span_fingerprint && !fpLookup.has(hit.span_fingerprint)) {
              fpLookup.set(hit.span_fingerprint, {
                spanName: hit.span_name,
                spanKind: hit.span_kind,
              });
            }
          }
        } catch {
          // Best-effort — fall back to hash display
        }
      }

      const rows = [
        ...bucketsToRows(errorBuckets, fpLookup, "error"),
        ...bucketsToRows(okBuckets, fpLookup, "ok"),
      ];

      // Sort by count descending
      rows.sort((a, b) => b.count - a.count);
      setOperations(rows);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to fetch operations");
    } finally {
      setLoading(false);
    }
  }, [serviceName, errorsOnly, isImplicit, sourceService, searchParams, useClientSide]);

  useEffect(() => {
    if (!useClientSide) fetchOperations();
  }, [fetchOperations, useClientSide]);

  return (
    <div className="flex w-96 shrink-0 flex-col overflow-hidden border-l border-border bg-card">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <div className="min-w-0">
          <h3 className="truncate text-sm font-medium text-foreground">
            {sourceService ? `${sourceService} → ${serviceName}` : serviceName}
          </h3>
          <p className="text-xs text-muted-foreground">Operations</p>
        </div>
        <div className="flex items-center gap-2">
          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <input
              type="checkbox"
              checked={errorsOnly}
              onChange={(e) => onToggleErrorsOnly(e.target.checked)}
              className="h-3.5 w-3.5 rounded border-border"
            />
            Errors only
          </label>
          <button
            onClick={onClose}
            className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
      </div>

      {/* Content */}
      {loading ? (
        <div className="flex flex-1 items-center justify-center text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
        </div>
      ) : error ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 px-4">
          <p className="text-sm text-destructive">{error}</p>
          <button
            onClick={fetchOperations}
            className="rounded-md bg-secondary px-3 py-1.5 text-xs text-secondary-foreground hover:bg-secondary/80"
          >
            Retry
          </button>
        </div>
      ) : operations.length === 0 ? (
        <div className="flex flex-1 items-center justify-center px-4 text-center text-sm text-muted-foreground">
          No operations found
        </div>
      ) : (
        <div className="flex-1 overflow-y-auto">
          {operations.map((op) => (
            <OperationRowItem
              key={`${op.fingerprint}-${op.status}`}
              op={op}
              onClick={() => {
                const params = new URLSearchParams();
                const fp = op.fingerprint;
                if (isImplicit) {
                  let q = sourceService
                    ? `service_name:"${sourceService}" AND (span_attributes.peer.service:"${serviceName}" OR span_attributes.db.system:"${serviceName}") AND span_fingerprint:"${fp}"`
                    : `(span_attributes.peer.service:"${serviceName}" OR span_attributes.db.system:"${serviceName}") AND span_fingerprint:"${fp}"`;
                  if (op.status === "error") q += " AND span_status.code:2";
                  params.append("q", q);
                } else if (sourceService) {
                  // Edge → real service: filter by source service + span name
                  let q = `service_name:"${sourceService}" AND (span_kind:3 OR span_kind:4) AND span_name:"${op.spanName}"`;
                  if (op.status === "error") q += " AND span_status.code:2";
                  params.append("q", q);
                } else {
                  params.append("f", `service_name:${serviceName}`);
                  params.append("f", `span_fingerprint:${fp}`);
                  if (op.status === "error") {
                    params.append("f", "span_status.code:2");
                  }
                }
                navigate(`/traces?${params.toString()}`);
              }}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function OperationRowItem({
  op,
  onClick,
}: {
  op: OperationRow;
  onClick: () => void;
}) {
  const kindLabel = SPAN_KIND_SHORT[op.spanKind];
  const isError = op.status === "error";

  return (
    <button
      onClick={onClick}
      className="flex w-full items-start gap-3 border-b border-border/50 px-4 py-2.5 text-left hover:bg-muted/30"
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          {isError ? (
            <AlertTriangle className="h-3.5 w-3.5 shrink-0 text-red-500" />
          ) : (
            <CircleCheck className="h-3.5 w-3.5 shrink-0 text-emerald-500" />
          )}
          {kindLabel && (
            <span className="shrink-0 rounded bg-muted px-1 py-0.5 text-[10px] font-medium text-muted-foreground">
              {kindLabel}
            </span>
          )}
          <span className="truncate text-sm text-foreground">
            {op.spanName}
          </span>
        </div>
        <div className="mt-1 flex items-center gap-3 pl-5 text-xs text-muted-foreground">
          <span>{op.count.toLocaleString()} calls</span>
          <span>{formatDuration(op.avgDurationMs)}</span>
        </div>
      </div>
    </button>
  );
}
