import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams, Link } from "react-router";
import { ArrowLeft, AlertCircle, ChevronDown, ChevronRight, Map, ExternalLink, ListTree } from "lucide-react";
import { searchTraces, searchLogs } from "@/lib/api";
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
import { type LogDocument, extractBody, severityColor } from "@/lib/logs";

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
  isCollapsed,
  onToggleCollapse,
  onClick,
}: {
  node: SpanTreeNode;
  traceStart: number;
  traceDuration: number;
  serviceColors: Map<string, string>;
  isSelected: boolean;
  isCollapsed: boolean;
  onToggleCollapse: (() => void) | null;
  onClick: () => void;
}) {
  const span = node.span;
  const color = serviceColors.get(span.service_name) ?? "oklch(0.6 0 0)";
  const hasError = span.span_status?.code === 2;
  const hasChildren = node.children.length > 0;

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
      style={{
        height: 28,
        borderLeft: isSelected ? `3px solid ${color}` : "3px solid transparent",
      }}
    >
      {/* Label area — 30% */}
      <div
        className="flex w-[30%] shrink-0 items-center overflow-hidden border-r border-border px-2 text-xs"
        style={{ paddingLeft: `${4 + node.depth * 20}px` }}
      >
        {/* Collapse/expand chevron */}
        {hasChildren ? (
          <button
            onClick={(e) => {
              e.stopPropagation();
              onToggleCollapse?.();
            }}
            className="flex h-4 w-4 shrink-0 items-center justify-center text-muted-foreground hover:text-foreground"
          >
            {isCollapsed ? (
              <ChevronRight className="h-3 w-3" />
            ) : (
              <ChevronDown className="h-3 w-3" />
            )}
          </button>
        ) : (
          <span className="inline-block w-4 shrink-0" />
        )}
        <span
          className="ml-1 inline-block h-2.5 w-2.5 shrink-0 rounded-full"
          style={{ backgroundColor: color }}
        />
        <span className="ml-1.5 truncate text-muted-foreground">
          {span.service_name}
        </span>
        <span className="ml-1 truncate font-medium">{span.span_name}</span>
        {hasError && <AlertCircle className="ml-1 h-3 w-3 shrink-0 text-red-500" />}
        {isCollapsed && (
          <span className="ml-1 shrink-0 rounded bg-muted px-1 py-0.5 text-[9px] text-muted-foreground">
            {countDescendants(node)}
          </span>
        )}
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

/** Count all descendants of a tree node. */
function countDescendants(node: SpanTreeNode): number {
  let count = 0;
  for (const child of node.children) {
    count += 1 + countDescendants(child);
  }
  return count;
}

// --- Async bridge row ---

function AsyncBridgeRow({
  node,
  traceStart,
  traceDuration,
}: {
  node: SpanTreeNode;
  traceStart: number;
  traceDuration: number;
}) {
  // Find the earliest consumer child start time
  const consumerChildren = node.children.filter(
    (c) => c.span.span_kind === 5 && c.span.service_name !== node.span.service_name,
  );
  if (consumerChildren.length === 0 || traceDuration <= 0) return null;

  const producerEnd = node.span.span_end_timestamp_nanos;
  const firstConsumerStart = Math.min(
    ...consumerChildren.map((c) => c.span.span_start_timestamp_nanos),
  );

  // Only show bridge if there's a meaningful gap
  const gapNanos = firstConsumerStart - producerEnd;
  if (gapNanos < traceDuration * 0.005) return null;

  const offsetPct = ((producerEnd - traceStart) / traceDuration) * 100;
  const widthPct = (gapNanos / traceDuration) * 100;
  const gapMs = gapNanos / 1_000_000;

  return (
    <div
      className="flex border-b border-border/30"
      style={{ height: 20 }}
    >
      {/* Label area */}
      <div
        className="flex w-[30%] shrink-0 items-center border-r border-border px-2 text-[10px] text-muted-foreground/50 italic"
        style={{ paddingLeft: `${8 + (node.depth + 1) * 20}px` }}
      >
        async {formatDuration(gapMs)}
      </div>
      {/* Bridge bar */}
      <div className="relative flex-1">
        <div
          className="absolute top-2 h-[3px] rounded-full"
          style={{
            left: `${offsetPct}%`,
            width: `${widthPct}%`,
            minWidth: 4,
            backgroundImage: "repeating-linear-gradient(90deg, oklch(0.5 0 0) 0 4px, transparent 4px 8px)",
            backgroundSize: "8px 3px",
            animation: "dash-flow-bg 0.5s linear infinite",
          }}
        />
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
                <span className="font-medium">{evt.name}</span>
                <span className="text-muted-foreground">
                  {formatTimestampShort(evt.time_unix_nano)}
                </span>
              </div>
              {evt.attributes &&
                Object.keys(evt.attributes).length > 0 && (
                  <div className="mt-1.5 space-y-0.5">
                    {Object.entries(evt.attributes).map(([key, val]) => (
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

function SpanLogs({ spanId }: { spanId: string }) {
  const [open, setOpen] = useState(true);
  const [logs, setLogs] = useState<LogDocument[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    searchLogs<LogDocument>({
      query: `span_id:${spanId}`,
      max_hits: 5,
      sort_by: "-timestamp_nanos",
    })
      .then((res) => {
        if (!cancelled) setLogs(res.hits);
      })
      .catch(() => {
        if (!cancelled) setLogs([]);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [spanId]);

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
        Logs
      </button>
      {open && (
        <div className="pl-4">
          {loading ? (
            <p className="py-1 text-xs text-muted-foreground">Loading...</p>
          ) : logs.length === 0 ? (
            <p className="py-1 text-xs text-muted-foreground">No logs for this span</p>
          ) : (
            <div className="space-y-1">
              {logs.map((log, i) => (
                <div key={i} className="flex gap-2 text-xs">
                  <span className="shrink-0 whitespace-nowrap text-muted-foreground">
                    {formatTimestampShort(log.timestamp_nanos)}
                  </span>
                  <span className={`shrink-0 font-medium ${severityColor(log.severity_text)}`}>
                    {log.severity_text}
                  </span>
                  <span className="truncate text-foreground">
                    {extractBody(log.body)}
                  </span>
                </div>
              ))}
              <Link
                to={`/logs?f=${encodeURIComponent(`span_id:${spanId}`)}`}
                className="mt-1 inline-flex items-center gap-1 text-xs text-muted-foreground underline decoration-muted-foreground/30 hover:text-foreground hover:decoration-foreground"
              >
                View all logs for this span
                <ExternalLink className="h-3 w-3" />
              </Link>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SpanDetailInline({ span }: { span: SpanDocument }) {
  const hasError = span.span_status?.code === 2;

  return (
    <div className="border-b border-border bg-card/50">
      <div className="px-4 py-3 space-y-3">
        {/* Header */}
        <div className="flex items-center gap-2">
          <h3 className="text-sm font-semibold">{span.span_name}</h3>
          {hasError && <AlertCircle className="h-4 w-4 shrink-0 text-red-500" />}
          <span className="text-xs text-muted-foreground">·</span>
          <Link
            to={`/traces?f=${encodeURIComponent(`service_name:${span.service_name}`)}`}
            className="text-xs text-muted-foreground underline decoration-muted-foreground/30 hover:text-foreground hover:decoration-foreground"
          >
            {span.service_name}
          </Link>
        </div>

        {/* Summary grid */}
        <div className="grid grid-cols-4 gap-x-6 gap-y-1.5 text-xs">
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

        {/* Attribute sections — side by side */}
        <div className="grid grid-cols-3 gap-4 border-t border-border pt-3">
          <div className="space-y-1">
            <AttributeList label="Span Attributes" attrs={span.span_attributes} />
            <SpanEvents events={span.events} />
          </div>
          <div>
            <AttributeList
              label="Resource Attributes"
              attrs={span.resource_attributes}
            />
          </div>
          <div>
            <SpanLogs spanId={span.span_id} />
          </div>
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
  const initialSpanId = useRef(searchParams.get("span"));
  const [collapsedSpans, setCollapsedSpans] = useState<Set<string>>(new Set());

  const toggleCollapse = useCallback((spanId: string) => {
    setCollapsedSpans((prev) => {
      const next = new Set(prev);
      if (next.has(spanId)) next.delete(spanId);
      else next.add(spanId);
      return next;
    });
  }, []);

  const fetchTrace = useCallback(async () => {
    if (!traceId) return;
    setLoading(true);
    setError(null);
    try {
      const res = await searchTraces<SpanDocument>({
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

  // Filter tree to hide children of collapsed spans
  const visibleTree = useMemo(() => {
    if (collapsedSpans.size === 0) return tree;
    const result: SpanTreeNode[] = [];
    let skipUntilDepth = Infinity;
    for (const node of tree) {
      if (node.depth > skipUntilDepth) continue;
      skipUntilDepth = Infinity;
      result.push(node);
      if (collapsedSpans.has(node.span.span_id)) {
        skipUntilDepth = node.depth;
      }
    }
    return result;
  }, [tree, collapsedSpans]);

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
      <div className="flex h-14 shrink-0 items-center gap-3 border-b border-border bg-card px-4">
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
          to={`/logs?f=${encodeURIComponent(`trace_id:${traceId}`)}`}
          className="ml-auto flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
        >
          <ListTree className="h-3 w-3" />
          Trace Logs
        </Link>
        <Link
          to={`/?f=${encodeURIComponent(`trace_id:${traceId}`)}`}
          className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
        >
          <Map className="h-3 w-3" />
          Show in Map
        </Link>
        {numHits > spans.length && (
          <span className="text-xs text-amber-500">
            Showing {spans.length} of {numHits} spans
          </span>
        )}
      </div>

      {/* Waterfall */}
      <div className="flex flex-1 flex-col overflow-hidden">
        <TimeRuler durationMs={traceDurationMs} />
        <div className="flex-1 overflow-y-auto">
          {visibleTree.map((node) => (
            <span
              key={node.span.span_id}
              ref={node.span.span_id === initialSpanId.current ? (el) => {
                if (el) {
                  initialSpanId.current = null;
                  requestAnimationFrame(() => el.scrollIntoView({ block: "center", behavior: "smooth" }));
                }
              } : undefined}
            >
              <WaterfallRow
                node={node}
                traceStart={traceStart}
                traceDuration={traceDurationNanos}
                serviceColors={serviceColors}
                isSelected={node.span.span_id === selectedSpanId}
                isCollapsed={collapsedSpans.has(node.span.span_id)}
                onToggleCollapse={
                  node.children.length > 0
                    ? () => toggleCollapse(node.span.span_id)
                    : null
                }
                onClick={() =>
                  setSelectedSpanId(
                    node.span.span_id === selectedSpanId
                      ? null
                      : node.span.span_id,
                  )
                }
              />
              {node.span.span_id === selectedSpanId && selectedSpan && (
                <SpanDetailInline span={selectedSpan} />
              )}
              {node.span.span_kind === 4 && !collapsedSpans.has(node.span.span_id) && (
                <AsyncBridgeRow
                  node={node}
                  traceStart={traceStart}
                  traceDuration={traceDurationNanos}
                />
              )}
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}
