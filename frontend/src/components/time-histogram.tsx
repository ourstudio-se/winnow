import { useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router";
import { searchTraces, searchLogs } from "@/lib/api";
import {
  parseTimeParam,
  computeTimeRange,
  pickInterval,
} from "@/lib/time";

interface Bucket {
  key: number; // nanosecond timestamp
  doc_count: number;
}

interface TimeHistogramProps {
  index: "traces" | "logs";
  timestampField?: string;
  query: string;
  onRangeSelect: (from: Date, to: Date) => void;
}

const BAR_HEIGHT = 56;
const LABEL_HEIGHT = 16;
const CHART_HEIGHT = BAR_HEIGHT + LABEL_HEIGHT;
const MIN_DRAG_PX = 4;
const TARGET_TICK_COUNT = 6;

/** Nice intervals for axis ticks (ms). */
const TICK_INTERVALS_MS = [
  1_000,       // 1s
  5_000,       // 5s
  10_000,      // 10s
  15_000,      // 15s
  30_000,      // 30s
  60_000,      // 1m
  300_000,     // 5m
  600_000,     // 10m
  900_000,     // 15m
  1_800_000,   // 30m
  3_600_000,   // 1h
  10_800_000,  // 3h
  21_600_000,  // 6h
  43_200_000,  // 12h
  86_400_000,  // 1d
];

function pickTickInterval(windowMs: number): number {
  for (const interval of TICK_INTERVALS_MS) {
    if (windowMs / interval <= TARGET_TICK_COUNT * 2) return interval;
  }
  return TICK_INTERVALS_MS[TICK_INTERVALS_MS.length - 1];
}

function formatBucketTime(ms: number): string {
  const d = new Date(ms);
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const da = String(d.getDate()).padStart(2, "0");
  const h = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  return `${mo}-${da} ${h}:${mi}:${s}`;
}

/** Format a tick label — short form, detail level adapts to the window size. */
function formatTickLabel(ms: number, windowMs: number): string {
  const d = new Date(ms);
  const h = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");

  if (windowMs <= 300_000) {
    // <=5 min: show HH:mm:ss
    return `${h}:${mi}:${s}`;
  }
  if (windowMs <= 86_400_000) {
    // <=1 day: show HH:mm
    return `${h}:${mi}`;
  }
  // >1 day: show MM-DD HH:mm
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const da = String(d.getDate()).padStart(2, "0");
  return `${mo}-${da} ${h}:${mi}`;
}

function generateTicks(startMs: number, endMs: number): number[] {
  const windowMs = endMs - startMs;
  const interval = pickTickInterval(windowMs);
  const first = Math.ceil(startMs / interval) * interval;
  const ticks: number[] = [];
  for (let t = first; t < endMs; t += interval) {
    ticks.push(t);
  }
  return ticks;
}

export function TimeHistogram({
  index,
  timestampField = "span_start_timestamp_nanos",
  query,
  onRangeSelect,
}: TimeHistogramProps) {
  const [searchParams] = useSearchParams();
  const [buckets, setBuckets] = useState<Bucket[]>([]);
  const [intervalMs, setIntervalMs] = useState(0);
  const [loading, setLoading] = useState(false);
  const [containerWidth, setContainerWidth] = useState(0);

  // Drag state
  const [dragStartX, setDragStartX] = useState<number | null>(null);
  const [dragCurrentX, setDragCurrentX] = useState<number | null>(null);
  const dragging = dragStartX !== null && dragCurrentX !== null;

  // Tooltip
  const [tooltip, setTooltip] = useState<{
    x: number;
    y: number;
    timeRange: string;
    count: number;
  } | null>(null);

  const svgRef = useRef<SVGSVGElement>(null);

  // Observe container width via ref callback (survives mount/unmount cycles)
  const roRef = useRef<ResizeObserver | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const containerCallbackRef = (el: HTMLDivElement | null) => {
    if (roRef.current) {
      roRef.current.disconnect();
      roRef.current = null;
    }
    containerRef.current = el;
    if (el) {
      const ro = new ResizeObserver(([entry]) =>
        setContainerWidth(entry.contentRect.width),
      );
      ro.observe(el);
      roRef.current = ro;
    }
  };

  // Parse time range from URL
  const timeSel = parseTimeParam(searchParams.get("time"));
  const timeRange = computeTimeRange(timeSel);

  // Fetch histogram data
  useEffect(() => {
    if (!query || containerWidth === 0) return;

    const windowMs = timeRange.endMs - timeRange.startMs;
    if (windowMs <= 0) return;

    const interval = pickInterval(windowMs);
    const intervalNs = interval * 1_000_000;

    setIntervalMs(interval);
    setLoading(true);

    const doSearch = index === "traces" ? searchTraces : searchLogs;
    let cancelled = false;
    doSearch<unknown>({
      query,
      max_hits: 0,
      aggs: {
        histogram: {
          histogram: {
            field: timestampField,
            interval: intervalNs,
          },
        },
      },
    })
      .then((res) => {
        if (cancelled) return;
        const raw = (res.aggregations?.histogram as any)?.buckets ?? [];
        setBuckets(
          raw.map((b: any) => ({ key: Number(b.key), doc_count: b.doc_count })),
        );
      })
      .catch(() => {
        if (!cancelled) setBuckets([]);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query, index, timestampField, timeRange.startMs, timeRange.endMs, containerWidth]);

  const windowMs = timeRange.endMs - timeRange.startMs;
  if (windowMs <= 0) {
    return <div ref={containerCallbackRef} className="hidden" />;
  }

  // Filter buckets to the visible window
  const startNs = timeRange.startMs * 1_000_000;
  const endNs = timeRange.endMs * 1_000_000;
  const intervalNs = intervalMs * 1_000_000;
  const visibleBuckets = buckets.filter(
    (b) => b.key + intervalNs > startNs && b.key < endNs,
  );

  const maxCount = Math.max(1, ...visibleBuckets.map((b) => b.doc_count));
  const ticks = generateTicks(timeRange.startMs, timeRange.endMs);

  function xFromMs(ms: number): number {
    return ((ms - timeRange.startMs) / windowMs) * containerWidth;
  }

  function xFromNs(ns: number): number {
    return xFromMs(ns / 1_000_000);
  }

  function msFromX(x: number): number {
    return timeRange.startMs + (x / containerWidth) * windowMs;
  }

  const barWidthPx = (intervalMs / windowMs) * containerWidth;

  // Mouse handlers for drag-to-select
  function handleMouseDown(e: React.MouseEvent<SVGSVGElement>) {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) return;
    const x = e.clientX - rect.left;
    setDragStartX(x);
    setDragCurrentX(x);
  }

  function handleMouseMove(e: React.MouseEvent<SVGSVGElement>) {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) return;
    const x = e.clientX - rect.left;

    if (dragStartX !== null) {
      setDragCurrentX(x);
      setTooltip(null);
    } else {
      // Find hovered bucket
      const mouseMs = msFromX(x);
      const mouseNs = mouseMs * 1_000_000;
      const hovered = visibleBuckets.find(
        (b) => mouseNs >= b.key && mouseNs < b.key + intervalNs,
      );
      if (hovered && (e.clientY - rect.top) <= BAR_HEIGHT) {
        const bucketStartMs = hovered.key / 1_000_000;
        const bucketEndMs = bucketStartMs + intervalMs;
        setTooltip({
          x: e.clientX - rect.left,
          y: e.clientY - rect.top,
          timeRange: `${formatBucketTime(bucketStartMs)} – ${formatBucketTime(bucketEndMs)}`,
          count: hovered.doc_count,
        });
      } else {
        setTooltip(null);
      }
    }
  }

  function handleMouseUp(_e: React.MouseEvent<SVGSVGElement>) {
    if (dragStartX === null || dragCurrentX === null) return;
    const dist = Math.abs(dragCurrentX - dragStartX);

    if (dist >= MIN_DRAG_PX) {
      const x1 = Math.max(0, Math.min(dragStartX, dragCurrentX));
      const x2 = Math.min(containerWidth, Math.max(dragStartX, dragCurrentX));
      const from = new Date(msFromX(x1));
      const to = new Date(msFromX(x2));
      onRangeSelect(from, to);
    }

    setDragStartX(null);
    setDragCurrentX(null);
  }

  function handleMouseLeave() {
    setTooltip(null);
    if (dragStartX !== null) {
      setDragStartX(null);
      setDragCurrentX(null);
    }
  }

  // Selection overlay coords
  const selX = dragging ? Math.max(0, Math.min(dragStartX!, dragCurrentX!)) : 0;
  const selW = dragging
    ? Math.min(containerWidth, Math.max(dragStartX!, dragCurrentX!)) - selX
    : 0;

  return (
    <div
      ref={containerCallbackRef}
      className="relative overflow-hidden border-b border-border bg-card px-3"
      style={{ height: CHART_HEIGHT + 8, paddingTop: 4, paddingBottom: 4 }}
    >
      {containerWidth > 0 && (
        <svg
          ref={svgRef}
          width={containerWidth}
          height={CHART_HEIGHT}
          overflow="visible"
          className={`block ${loading && buckets.length === 0 ? "opacity-30" : ""}`}
          style={{ cursor: dragging ? "col-resize" : "crosshair" }}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
          onMouseLeave={handleMouseLeave}
        >
          {/* Bars */}
          {visibleBuckets.map((b) => {
            const x = xFromNs(b.key);
            const h = (b.doc_count / maxCount) * BAR_HEIGHT;
            return (
              <rect
                key={b.key}
                x={x}
                y={BAR_HEIGHT - h}
                width={Math.max(1, barWidthPx - 1)}
                height={h}
                className="fill-primary/60"
                rx={1}
              />
            );
          })}

          {/* Drag selection overlay */}
          {dragging && selW > 0 && (
            <rect
              x={selX}
              y={0}
              width={selW}
              height={BAR_HEIGHT}
              className="fill-primary/20 stroke-primary/50"
              strokeWidth={1}
            />
          )}

          {/* Time axis ticks + labels */}
          {ticks.map((t) => {
            const x = xFromMs(t);
            return (
              <g key={t}>
                <line
                  x1={x}
                  y1={BAR_HEIGHT}
                  x2={x}
                  y2={BAR_HEIGHT + 4}
                  className="stroke-muted-foreground/40"
                  strokeWidth={1}
                />
                <text
                  x={x}
                  y={CHART_HEIGHT - 1}
                  textAnchor="middle"
                  className="fill-muted-foreground"
                  style={{ fontSize: 10 }}
                >
                  {formatTickLabel(t, windowMs)}
                </text>
              </g>
            );
          })}
        </svg>
      )}

      {/* Tooltip */}
      {tooltip && !dragging && (
        <div
          className="pointer-events-none absolute z-50 rounded border border-border bg-popover px-2 py-1 text-xs shadow-md"
          style={{
            left: Math.min(tooltip.x, containerWidth - 180),
            top: -4,
            transform: "translateY(-100%)",
          }}
        >
          <div className="text-muted-foreground">{tooltip.timeRange}</div>
          <div className="font-medium">
            {tooltip.count.toLocaleString()} {tooltip.count === 1 ? "hit" : "hits"}
          </div>
        </div>
      )}
    </div>
  );
}
