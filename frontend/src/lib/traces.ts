// --- Types ---

export interface SpanDocument {
  trace_id: string;
  span_id: string;
  parent_span_id: string | null;
  service_name: string;
  span_name: string;
  span_kind: number;
  span_start_timestamp_nanos: number;
  span_end_timestamp_nanos: number;
  span_duration_millis: number;
  span_attributes: Record<string, unknown> | null;
  resource_attributes: Record<string, unknown> | null;
  span_status: { code?: number; message?: string } | null;
  events: Array<{
    event_name: string;
    event_timestamp_nanos: number;
    event_attributes: Record<string, unknown>;
  }> | null;
  links: unknown[] | null;
  is_root: boolean;
  span_fingerprint: string | null;
}

export interface TraceSummary {
  traceId: string;
  rootServiceName: string;
  rootSpanName: string;
  startTimestampNanos: number;
  durationMillis: number;
  spanCount: number;
  hasError: boolean;
  serviceCount: number;
}

export interface SpanTreeNode {
  span: SpanDocument;
  children: SpanTreeNode[];
  depth: number;
}

// --- Grouping & tree building ---

export function groupSpansByTrace(spans: SpanDocument[]): TraceSummary[] {
  const groups = new Map<string, SpanDocument[]>();
  for (const span of spans) {
    let group = groups.get(span.trace_id);
    if (!group) {
      group = [];
      groups.set(span.trace_id, group);
    }
    group.push(span);
  }

  const summaries: TraceSummary[] = [];
  for (const [traceId, traceSpans] of groups) {
    // Find root: prefer is_root flag, fallback to earliest start time
    const root =
      traceSpans.find((s) => s.is_root) ??
      traceSpans.reduce((a, b) =>
        a.span_start_timestamp_nanos <= b.span_start_timestamp_nanos ? a : b,
      );

    const services = new Set<string>();
    let hasError = false;
    let minStart = Infinity;
    let maxEnd = -Infinity;

    for (const s of traceSpans) {
      services.add(s.service_name);
      if (s.span_status?.code === 2) hasError = true;
      if (s.span_start_timestamp_nanos < minStart)
        minStart = s.span_start_timestamp_nanos;
      if (s.span_end_timestamp_nanos > maxEnd)
        maxEnd = s.span_end_timestamp_nanos;
    }

    const durationNanos = maxEnd - minStart;
    summaries.push({
      traceId,
      rootServiceName: root.service_name,
      rootSpanName: root.span_name,
      startTimestampNanos: minStart,
      durationMillis: durationNanos / 1_000_000,
      spanCount: traceSpans.length,
      hasError,
      serviceCount: services.size,
    });
  }

  // Most recent first
  summaries.sort((a, b) => b.startTimestampNanos - a.startTimestampNanos);
  return summaries;
}

export function buildSpanTree(spans: SpanDocument[]): SpanTreeNode[] {
  const nodeMap = new Map<string, SpanTreeNode>();
  for (const span of spans) {
    nodeMap.set(span.span_id, { span, children: [], depth: 0 });
  }

  const roots: SpanTreeNode[] = [];
  for (const node of nodeMap.values()) {
    const parentId = node.span.parent_span_id;
    const parent = parentId ? nodeMap.get(parentId) : null;
    if (parent) {
      parent.children.push(node);
    } else {
      roots.push(node);
    }
  }

  // Sort children by start time
  function sortChildren(node: SpanTreeNode) {
    node.children.sort(
      (a, b) =>
        a.span.span_start_timestamp_nanos - b.span.span_start_timestamp_nanos,
    );
    for (const child of node.children) sortChildren(child);
  }

  // Sort roots by start time
  roots.sort(
    (a, b) =>
      a.span.span_start_timestamp_nanos - b.span.span_start_timestamp_nanos,
  );
  for (const root of roots) sortChildren(root);

  // DFS flatten with depth assignment
  const flat: SpanTreeNode[] = [];
  function dfs(node: SpanTreeNode, depth: number) {
    node.depth = depth;
    flat.push(node);
    for (const child of node.children) dfs(child, depth + 1);
  }
  for (const root of roots) dfs(root, 0);

  return flat;
}

// --- Service colors ---

const SERVICE_PALETTE = [
  "oklch(0.7 0.15 250)", // blue
  "oklch(0.7 0.15 150)", // green
  "oklch(0.7 0.15 30)", // orange
  "oklch(0.7 0.15 310)", // purple
  "oklch(0.7 0.15 190)", // teal
  "oklch(0.7 0.15 60)", // yellow
  "oklch(0.7 0.15 340)", // pink
  "oklch(0.7 0.12 100)", // lime
];

export function assignServiceColors(
  serviceNames: string[],
): Map<string, string> {
  const sorted = [...new Set(serviceNames)].sort();
  const colors = new Map<string, string>();
  for (let i = 0; i < sorted.length; i++) {
    colors.set(sorted[i], SERVICE_PALETTE[i % SERVICE_PALETTE.length]);
  }
  return colors;
}

// --- Formatting ---

export function formatDuration(ms: number): string {
  if (ms < 0.001) return "<1us";
  if (ms < 1) return `${Math.round(ms * 1000)}us`;
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60000).toFixed(1)}m`;
}

export function formatTimestamp(nanos: number): string {
  return new Date(nanos / 1_000_000).toLocaleString();
}

export function formatTimestampShort(nanos: number): string {
  return new Date(nanos / 1_000_000).toLocaleTimeString();
}

export const SPAN_KIND_SHORT: Record<number, string> = {
  1: "INT",
  2: "SRV",
  3: "CLI",
  4: "PRD",
  5: "CSM",
};

const SPAN_KIND_LABELS: Record<number, string> = {
  0: "Unspecified",
  1: "Internal",
  2: "Server",
  3: "Client",
  4: "Producer",
  5: "Consumer",
};

export function spanKindLabel(kind: number): string {
  return SPAN_KIND_LABELS[kind] ?? `Kind(${kind})`;
}
