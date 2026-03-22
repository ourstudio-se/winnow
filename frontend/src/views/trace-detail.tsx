import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate, useParams, useSearchParams, Link } from "react-router";
import { ArrowLeft, AlertCircle, ChevronDown, ChevronRight, Map } from "lucide-react";
import { search } from "@/lib/api";
import {
  type SpanDocument,
  type SpanTreeNode,
  buildSpanTree,
  assignServiceColors,
  formatDuration,
  formatTimestamp,
  formatTimestampShort,
  spanKindLabel,
} from "@/lib/traces";

// --- Time ruler ---

function TimeRuler({ durationMs }: { durationMs: number }) {
  const ticks = 5;
  const markers = Array.from({ length: ticks + 1 }, (_, i) => ({
    pct: (i / ticks) * 100,
    label: formatDuration((i / ticks) * durationMs),
  }));

  return (
    <div className="relative h-6 border-b border-border bg-card text-[10px] text-muted-foreground">
      {/* Label area placeholder (matches waterfall left column) */}
      <div className="absolute inset-y-0 left-0 w-[30%] border-r border-border" />
      {/* Tick marks in the bar area */}
      <div className="absolute inset-y-0 left-[30%] right-0">
        {markers.map((m) => (
          <span
            key={m.pct}
            className="absolute bottom-0.5"
            style={{ left: `${m.pct}%`, transform: "translateX(-50%)" }}
          >
            {m.label}
          </span>
        ))}
      </div>
    </div>
  );
}

// --- Waterfall row ---

function WaterfallRow({
  node,
  traceStart,
  traceDuration,
  serviceColors,
  isSelected,
  onClick,
}: {
  node: SpanTreeNode;
  traceStart: number;
  traceDuration: number;
  serviceColors: Map<string, string>;
  isSelected: boolean;
  onClick: () => void;
}) {
  const span = node.span;
  const color = serviceColors.get(span.service_name) ?? "oklch(0.6 0 0)";
  const hasError = span.span_status?.code === 2;

  const offsetPct =
    traceDuration > 0
      ? ((span.span_start_timestamp_nanos - traceStart) / traceDuration) * 100
      : 0;
  const spanDurationNanos =
    span.span_end_timestamp_nanos - span.span_start_timestamp_nanos;
  const widthPct =
    traceDuration > 0
      ? Math.max(0.5, (spanDurationNanos / traceDuration) * 100)
      : 0.5;

  return (
    <div
      onClick={onClick}
      className={`flex cursor-pointer border-b border-border/30 hover:bg-muted/20 ${isSelected ? "bg-muted/40" : ""}`}
      style={{ height: 28 }}
    >
      {/* Label area — 30% */}
      <div
        className="flex w-[30%] shrink-0 items-center gap-1.5 overflow-hidden border-r border-border px-2 text-xs"
        style={{ paddingLeft: `${8 + node.depth * 20}px` }}
      >
        <span
          className="inline-block h-2.5 w-2.5 shrink-0 rounded-full"
          style={{ backgroundColor: color }}
        />
        <span className="truncate text-muted-foreground">
          {span.service_name}
        </span>
        <span className="truncate font-medium">{span.span_name}</span>
        {hasError && <AlertCircle className="h-3 w-3 shrink-0 text-red-500" />}
      </div>

      {/* Bar area — 70% */}
      <div className="relative flex-1">
        <div
          className="absolute top-1 flex h-4 items-center rounded-sm px-1 text-[10px] font-medium text-white"
          style={{
            left: `${offsetPct}%`,
            width: `${widthPct}%`,
            minWidth: 2,
            backgroundColor: color,
          }}
        >
          <span className="truncate">
            {formatDuration(span.span_duration_millis)}
          </span>
        </div>
      </div>
    </div>
  );
}

// --- Span detail panel ---

function AttributeList({
  label,
  attrs,
}: {
  label: string;
  attrs: Record<string, unknown> | null;
}) {
  const [open, setOpen] = useState(true);
  if (!attrs || Object.keys(attrs).length === 0) return null;

  return (
    <div>
      <button
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-1 py-1.5 text-xs font-medium text-muted-foreground hover:text-foreground"
      >
        {open ? (
          <ChevronDown className="h-3 w-3" />
        ) : (
          <ChevronRight className="h-3 w-3" />
        )}
        {label}
      </button>
      {open && (
        <div className="space-y-0.5 pl-4">
          {Object.entries(attrs).map(([key, val]) => (
            <div key={key} className="flex gap-2 text-xs">
              <span className="shrink-0 text-muted-foreground">{key}</span>
              <span className="break-all font-mono">
                {typeof val === "object" && val !== null
                  ? JSON.stringify(val, null, 2)
                  : String(val)}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function SpanEvents({
  events,
}: {
  events: SpanDocument["events"];
}) {
  const [open, setOpen] = useState(true);
  if (!events || events.length === 0) return null;

  return (
    <div>
      <button
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-1 py-1.5 text-xs font-medium text-muted-foreground hover:text-foreground"
      >
        {open ? (
          <ChevronDown className="h-3 w-3" />
        ) : (
          <ChevronRight className="h-3 w-3" />
        )}
        Events ({events.length})
      </button>
      {open && (
        <div className="space-y-2 pl-4">
          {events.map((evt, i) => (
            <div
              key={i}
              className="rounded-md border border-border/50 bg-muted/20 px-2.5 py-2"
            >
              <div className="flex items-center justify-between text-xs">
                <span className="font-medium">{evt.event_name}</span>
                <span className="text-muted-foreground">
                  {formatTimestampShort(evt.event_timestamp_nanos)}
                </span>
              </div>
              {evt.event_attributes &&
                Object.keys(evt.event_attributes).length > 0 && (
                  <div className="mt-1.5 space-y-0.5">
                    {Object.entries(evt.event_attributes).map(([key, val]) => (
                      <div key={key} className="flex gap-2 text-xs">
                        <span className="shrink-0 text-muted-foreground">
                          {key}
                        </span>
                        <span className="break-all font-mono">
                          {typeof val === "object" && val !== null
                            ? JSON.stringify(val, null, 2)
                            : String(val)}
                        </span>
                      </div>
                    ))}
                  </div>
                )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function SpanDetailPanel({ span }: { span: SpanDocument }) {
  const hasError = span.span_status?.code === 2;

  return (
    <div className="flex w-96 shrink-0 flex-col overflow-y-auto border-l border-border bg-card">
      {/* Header */}
      <div className="border-b border-border px-4 py-3">
        <div className="flex items-center gap-2">
          <h3 className="truncate text-sm font-semibold">{span.span_name}</h3>
          {hasError && <AlertCircle className="h-4 w-4 shrink-0 text-red-500" />}
        </div>
        <Link
          to={`/traces?f=${encodeURIComponent(`service_name:${span.service_name}`)}`}
          className="mt-0.5 block text-xs text-muted-foreground underline decoration-muted-foreground/30 hover:text-foreground hover:decoration-foreground"
        >
          {span.service_name}
        </Link>
      </div>

      {/* Summary fields */}
      <div className="space-y-3 px-4 py-3">
        <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-xs">
          <div>
            <span className="text-muted-foreground">Kind</span>
            <p className="font-medium">{spanKindLabel(span.span_kind)}</p>
          </div>
          <div>
            <span className="text-muted-foreground">Duration</span>
            <p className="font-medium">
              {formatDuration(span.span_duration_millis)}
            </p>
          </div>
          <div>
            <span className="text-muted-foreground">Start</span>
            <p className="font-medium">
              {formatTimestampShort(span.span_start_timestamp_nanos)}
            </p>
          </div>
          <div>
            <span className="text-muted-foreground">Status</span>
            <p className="font-medium">
              {hasError ? (
                <span className="text-red-500">
                  Error{span.span_status?.message ? `: ${span.span_status.message}` : ""}
                </span>
              ) : (
                "OK"
              )}
            </p>
          </div>
          <div className="col-span-2">
            <span className="text-muted-foreground">Span ID</span>
            <p className="font-mono font-medium">{span.span_id}</p>
          </div>
          {span.parent_span_id && (
            <div className="col-span-2">
              <span className="text-muted-foreground">Parent Span ID</span>
              <p className="font-mono font-medium">{span.parent_span_id}</p>
            </div>
          )}
        </div>

        <div className="space-y-1 border-t border-border pt-3">
          <AttributeList label="Span Attributes" attrs={span.span_attributes} />
          <AttributeList
            label="Resource Attributes"
            attrs={span.resource_attributes}
          />
          <SpanEvents events={span.events} />
        </div>
      </div>
    </div>
  );
}

// --- Main view ---

export function TraceDetailView() {
  const { traceId } = useParams<{ traceId: string }>();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  // Go back to wherever the user came from (preserves filters/params)
  const goBack = useCallback(() => navigate(-1), [navigate]);
  const [spans, setSpans] = useState<SpanDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [numHits, setNumHits] = useState(0);
  const [selectedSpanId, setSelectedSpanId] = useState<string | null>(
    () => searchParams.get("span"),
  );

  const fetchTrace = useCallback(async () => {
    if (!traceId) return;
    setLoading(true);
    setError(null);
    try {
      const res = await search<SpanDocument>("otel-traces-v0_9", {
        query: `trace_id:${traceId}`,
        max_hits: 1000,
      });
      setNumHits(res.num_hits);
      setSpans(res.hits);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to fetch trace");
    } finally {
      setLoading(false);
    }
  }, [traceId]);

  useEffect(() => {
    fetchTrace();
  }, [fetchTrace]);

  const tree = useMemo(() => buildSpanTree(spans), [spans]);

  const serviceColors = useMemo(
    () => assignServiceColors(spans.map((s) => s.service_name)),
    [spans],
  );

  const selectedSpan = useMemo(
    () => (selectedSpanId ? spans.find((s) => s.span_id === selectedSpanId) ?? null : null),
    [spans, selectedSpanId],
  );

  // Trace-level stats
  const traceStart = useMemo(
    () =>
      spans.length > 0
        ? Math.min(...spans.map((s) => s.span_start_timestamp_nanos))
        : 0,
    [spans],
  );
  const traceEnd = useMemo(
    () =>
      spans.length > 0
        ? Math.max(...spans.map((s) => s.span_end_timestamp_nanos))
        : 0,
    [spans],
  );
  const traceDurationNanos = traceEnd - traceStart;
  const traceDurationMs = traceDurationNanos / 1_000_000;

  const rootServiceName = useMemo(() => {
    const root = spans.find((s) => s.is_root);
    if (root) return root.service_name;
    if (spans.length > 0)
      return spans.reduce((a, b) =>
        a.span_start_timestamp_nanos <= b.span_start_timestamp_nanos ? a : b,
      ).service_name;
    return null;
  }, [spans]);

  if (loading) {
    return (
      <div className="flex flex-1 items-center justify-center text-muted-foreground">
        Loading trace...
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-3">
        <p className="text-destructive">{error}</p>
        <button
          onClick={fetchTrace}
          className="rounded-md bg-secondary px-3 py-1.5 text-sm text-secondary-foreground hover:bg-secondary/80"
        >
          Retry
        </button>
      </div>
    );
  }

  if (spans.length === 0) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-2 text-muted-foreground">
        <h2 className="text-lg font-medium text-foreground">
          No spans found for this trace
        </h2>
        <button
          onClick={goBack}
          className="text-sm underline hover:text-foreground"
        >
          Back to traces
        </button>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      {/* Header bar */}
      <div className="flex items-center gap-3 border-b border-border bg-card px-4 py-2.5">
        <button
          onClick={goBack}
          className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" />
        </button>
        <div className="flex items-center gap-3 text-sm">
          {rootServiceName && (
            <>
              <Link
                to={`/traces?f=${encodeURIComponent(`service_name:${rootServiceName}`)}`}
                className="font-medium underline decoration-muted-foreground/30 hover:decoration-foreground"
              >
                {rootServiceName}
              </Link>
              <span className="text-muted-foreground">|</span>
            </>
          )}
          <span className="font-mono text-xs text-muted-foreground">
            {traceId?.slice(0, 16)}...
          </span>
          <span className="text-muted-foreground">|</span>
          <span>
            {spans.length} span{spans.length !== 1 && "s"}
          </span>
          <span className="text-muted-foreground">|</span>
          <span>{formatDuration(traceDurationMs)}</span>
          <span className="text-muted-foreground">|</span>
          <span className="text-xs text-muted-foreground">
            {formatTimestamp(traceStart)}
          </span>
        </div>
        <Link
          to={`/?f=${encodeURIComponent(`trace_id:${traceId}`)}`}
          className="ml-auto flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
        >
          <Map className="h-3 w-3" />
          Service Map
        </Link>
        {numHits > spans.length && (
          <span className="text-xs text-amber-500">
            Showing {spans.length} of {numHits} spans
          </span>
        )}
      </div>

      {/* Waterfall + detail panel */}
      <div className="flex flex-1 overflow-hidden">
        {/* Waterfall */}
        <div className="flex flex-1 flex-col overflow-hidden">
          <TimeRuler durationMs={traceDurationMs} />
          <div className="flex-1 overflow-y-auto">
            {tree.map((node) => (
              <WaterfallRow
                key={node.span.span_id}
                node={node}
                traceStart={traceStart}
                traceDuration={traceDurationNanos}
                serviceColors={serviceColors}
                isSelected={node.span.span_id === selectedSpanId}
                onClick={() =>
                  setSelectedSpanId(
                    node.span.span_id === selectedSpanId
                      ? null
                      : node.span.span_id,
                  )
                }
              />
            ))}
          </div>
        </div>

        {/* Detail panel */}
        {selectedSpan && <SpanDetailPanel span={selectedSpan} />}
      </div>
    </div>
  );
}
