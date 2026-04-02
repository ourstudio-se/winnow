// --- Types ---

export type EdgeType = "sync" | "async";

export interface AggregatedEdge {
  source: string;
  dest: string;
  callCount: number;
  errorCount: number;
  avgDurationMs: number;
  edgeType: EdgeType;
}

export interface InnerTermsBucket {
  key: string;
  doc_count: number;
  avg_duration?: { value: number };
}
export interface OuterTermsBucket {
  key: string;
  doc_count: number;
  dests: { buckets: InnerTermsBucket[] };
}
export interface EdgesAggResponse {
  edges: { buckets: OuterTermsBucket[] };
}

export interface ServiceTermsBucket {
  key: string;
  doc_count: number;
  avg_duration?: { value: number };
}
export interface ServiceAggResponse {
  services: { buckets: ServiceTermsBucket[] };
}

export type ServiceKind = "database" | "cache" | "gateway" | "messaging" | "service";

export interface ServiceStats {
  [key: string]: unknown;
  label: string;
  serviceKind: ServiceKind;
  totalCalls: number;
  totalErrors: number;
  avgDurationMs: number;
  errorRate: number;
  isRoot: boolean;
  isImplicit: boolean;
}

export type ServiceEdgeData = {
  [key: string]: unknown;
  callCount: number;
  errorCount: number;
  avgDurationMs: number;
  edgeType: EdgeType;
};

// --- Sampled span type for parent-child joining ---

export interface SampledSpan {
  trace_id: string;
  span_id: string;
  parent_span_id: string | null;
  service_name: string;
  span_name: string;
  span_fingerprint: string | null;
  span_kind: number;
  span_status: { code?: number } | null;
  span_duration_millis: number;
  span_attributes: Record<string, unknown> | null;
}

export const TRACE_SAMPLE_SIZE = 200;
export const MAX_SAMPLED_SPANS = 5000;

// --- Helpers ---

export function formatDuration(ms: number): string {
  if (ms < 1) return "<1ms";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60000).toFixed(1)}m`;
}

export function inferServiceKind(name: string): ServiceKind {
  const lower = name.toLowerCase();
  if (/postgres|mysql|maria|mongo|cockroach|sqlite|oracle|mssql|sql|db/.test(lower))
    return "database";
  if (/redis|memcache|cache|valkey|dragonfly/.test(lower)) return "cache";
  if (/kafka|rabbitmq|rabbit|amqp|pulsar|nats|sqs|sns|kinesis|eventbus|eventhub/.test(lower))
    return "messaging";
  if (/gateway|proxy|nginx|envoy|haproxy|ingress|lb|load.?balancer/.test(lower))
    return "gateway";
  return "service";
}

function inferMessagingTopic(attrs: Record<string, unknown> | null): string | null {
  if (!attrs) return null;
  // Well-known keys in priority order (OTel semconv + system-specific + bare)
  for (const key of [
    "messaging.destination.name",
    "messaging.destination",
    "messaging.kafka.destination.topic",
    "messaging.kafka.topic",
    "messaging.rabbitmq.destination.routing_key",
    "messaging.nats.subject",
    "messaging.eventhubs.destination.name",
    "messaging.servicebus.destination.name",
    // Bare keys (non-standard but common in some instrumentation libraries)
    "kafka.topic",
    "rabbitmq.routing_key",
    "nats.subject",
  ]) {
    if (typeof attrs[key] === "string") return attrs[key] as string;
  }
  // Fallback: scan for any messaging attribute that looks like a destination
  for (const [key, val] of Object.entries(attrs)) {
    if (typeof val !== "string") continue;
    if (key.startsWith("messaging.") && /destination|topic|subject|queue|channel/.test(key)) {
      return val;
    }
  }
  return null;
}

function inferMessagingSystem(attrs: Record<string, unknown> | null): string | null {
  if (!attrs) return null;
  if (typeof attrs["messaging.system"] === "string") return attrs["messaging.system"] as string;
  // Infer from attribute key prefixes (standard and bare)
  for (const key of Object.keys(attrs)) {
    if (key.startsWith("messaging.kafka.") || key.startsWith("kafka.")) return "kafka";
    if (key.startsWith("messaging.rabbitmq.") || key.startsWith("rabbitmq.")) return "rabbitmq";
    if (key.startsWith("messaging.nats.") || key.startsWith("nats.")) return "nats";
    if (key.startsWith("messaging.eventhubs.")) return "eventhubs";
    if (key.startsWith("messaging.servicebus.")) return "servicebus";
  }
  return null;
}

// --- Aggregation (peer.service edges) ---

export function parseEdgesFromAggs(
  allAgg: EdgesAggResponse,
  errorAgg: EdgesAggResponse,
): AggregatedEdge[] {
  const errorLookup = new Map<string, number>();
  for (const outer of errorAgg.edges.buckets) {
    for (const inner of outer.dests.buckets) {
      errorLookup.set(`${outer.key}\0${inner.key}`, inner.doc_count);
    }
  }

  const result: AggregatedEdge[] = [];
  for (const outer of allAgg.edges.buckets) {
    for (const inner of outer.dests.buckets) {
      result.push({
        source: outer.key,
        dest: inner.key,
        callCount: inner.doc_count,
        errorCount: errorLookup.get(`${outer.key}\0${inner.key}`) ?? 0,
        avgDurationMs: Math.round(inner.avg_duration?.value ?? 0),
        edgeType: "sync",
      });
    }
  }
  return result;
}

// --- Parent-child edge derivation from sampled traces ---

/** Infer implicit peer name from span attributes (for CLIENT spans with no child in the trace). */
function inferPeerName(attrs: Record<string, unknown> | null): string | null {
  if (!attrs) return null;
  if (typeof attrs["peer.service"] === "string") return attrs["peer.service"];
  if (typeof attrs["db.system"] === "string") return attrs["db.system"];
  return null;
}

interface EdgeStat {
  count: number;
  errors: number;
  totalDuration: number;
  edgeType: EdgeType;
}

function addEdgeStat(
  edgeStats: Map<string, EdgeStat>,
  source: string,
  dest: string,
  durationMs: number,
  isError: boolean,
  edgeType: EdgeType = "sync",
) {
  const key = `${source}\0${dest}`;
  const existing = edgeStats.get(key);
  if (existing) {
    existing.count += 1;
    existing.errors += isError ? 1 : 0;
    existing.totalDuration += durationMs;
    if (edgeType === "async") existing.edgeType = "async";
  } else {
    edgeStats.set(key, { count: 1, errors: isError ? 1 : 0, totalDuration: durationMs, edgeType });
  }
}

/** Build an intermediary node name from messaging system and topic. */
function messagingNodeName(system: string | null, topic: string | null): string | null {
  if (system && topic) return `${system}/${topic}`;
  if (system) return system;
  if (topic) return topic;
  return null;
}

export function deriveEdgesFromTraces(spans: SampledSpan[]): AggregatedEdge[] {
  if (spans.length === 0) return [];

  // Group spans by trace_id
  const traceGroups = new Map<string, SampledSpan[]>();
  for (const span of spans) {
    let group = traceGroups.get(span.trace_id);
    if (!group) {
      group = [];
      traceGroups.set(span.trace_id, group);
    }
    group.push(span);
  }

  // Accumulate edge stats: "source\0dest" → {count, errors, totalDuration, edgeType}
  const edgeStats = new Map<string, EdgeStat>();

  for (const [, traceSpans] of traceGroups) {
    // Build span_id → span lookup for this trace
    const spanById = new Map<string, SampledSpan>();
    for (const span of traceSpans) {
      spanById.set(span.span_id, span);
    }

    // Track which CLIENT/PRODUCER spans have a cross-service child
    const hasExternalChild = new Set<string>();

    // Walk each span, find cross-service parent-child links
    for (const child of traceSpans) {
      if (!child.parent_span_id) continue;
      const parent = spanById.get(child.parent_span_id);
      if (!parent) continue;
      if (parent.service_name === child.service_name) continue;

      hasExternalChild.add(parent.span_id);

      // Async messaging: either parent is PRODUCER (4) or child is CONSUMER (5).
      // We check both to handle mis-parented instrumentation (e.g. consumer span
      // parented to an HTTP handler instead of the producer span).
      const isMessaging = parent.span_kind === 4 || child.span_kind === 5;

      if (isMessaging) {
        const topic = inferMessagingTopic(parent.span_attributes) ?? inferMessagingTopic(child.span_attributes);
        const system = inferMessagingSystem(parent.span_attributes) ?? inferMessagingSystem(child.span_attributes);
        const intermediary = messagingNodeName(system, topic);
        // Error attribution: based on the CLIENT/PRODUCER span's own status,
        // not the child's. The child's errors belong to the target node.
        const isError = parent.span_status?.code === 2;

        if (intermediary) {
          // Split into two async edges: source → topic, topic → dest
          addEdgeStat(edgeStats, parent.service_name, intermediary, parent.span_duration_millis, isError, "async");
          addEdgeStat(edgeStats, intermediary, child.service_name, parent.span_duration_millis, isError, "async");
        } else {
          // No messaging attrs — direct async edge
          addEdgeStat(edgeStats, parent.service_name, child.service_name, parent.span_duration_millis, isError, "async");
        }
      } else {
        // Synchronous edge (CLIENT → SERVER or other)
        // Error attribution: based on the CLIENT/PRODUCER span's own status.
        addEdgeStat(
          edgeStats,
          parent.service_name,
          child.service_name,
          parent.span_duration_millis,
          parent.span_status?.code === 2,
        );
      }
    }

    // For CLIENT/PRODUCER spans (kind 3/4) with no cross-service child,
    // infer the destination from attributes (e.g. db.system, peer.service)
    for (const span of traceSpans) {
      if (span.span_kind !== 3 && span.span_kind !== 4) continue;
      if (hasExternalChild.has(span.span_id)) continue;

      // PRODUCER with no external child — try messaging attrs first
      if (span.span_kind === 4) {
        const topic = inferMessagingTopic(span.span_attributes);
        const system = inferMessagingSystem(span.span_attributes);
        const intermediary = messagingNodeName(system, topic);
        if (intermediary && intermediary !== span.service_name) {
          addEdgeStat(edgeStats, span.service_name, intermediary, span.span_duration_millis, span.span_status?.code === 2, "async");
          continue;
        }
      }

      const peerName = inferPeerName(span.span_attributes);
      if (!peerName || peerName === span.service_name) continue;
      const edgeType: EdgeType = span.span_kind === 4 ? "async" : "sync";
      addEdgeStat(
        edgeStats,
        span.service_name,
        peerName,
        span.span_duration_millis,
        span.span_status?.code === 2,
        edgeType,
      );
    }
  }

  const result: AggregatedEdge[] = [];
  for (const [key, stats] of edgeStats) {
    const [source, dest] = key.split("\0");
    result.push({
      source,
      dest,
      callCount: stats.count,
      errorCount: stats.errors,
      avgDurationMs: stats.count > 0 ? Math.round(stats.totalDuration / stats.count) : 0,
      edgeType: stats.edgeType,
    });
  }
  return result;
}

// --- Derive per-operation stats for a specific edge from sampled spans ---

export interface DerivedOperation {
  spanName: string;
  spanFingerprint: string | null;
  spanKind: number;
  count: number;
  errorCount: number;
  avgDurationMs: number;
}

/**
 * For edge sourceService → targetService, walk sampled traces and find
 * cross-service parent-child pairs. Groups by the source-side (CLIENT/PRODUCER)
 * span's operation name — exactly matching how deriveEdgesFromTraces counts.
 */
export function deriveEdgeOperations(
  spans: SampledSpan[],
  sourceService: string,
  targetService: string,
): DerivedOperation[] {
  const traceGroups = new Map<string, SampledSpan[]>();
  for (const span of spans) {
    let group = traceGroups.get(span.trace_id);
    if (!group) {
      group = [];
      traceGroups.set(span.trace_id, group);
    }
    group.push(span);
  }

  const opStats = new Map<string, { count: number; errors: number; totalDuration: number; spanKind: number; fingerprint: string | null }>();

  for (const [, traceSpans] of traceGroups) {
    const spanById = new Map<string, SampledSpan>();
    for (const span of traceSpans) {
      spanById.set(span.span_id, span);
    }

    for (const child of traceSpans) {
      if (!child.parent_span_id) continue;
      const parent = spanById.get(child.parent_span_id);
      if (!parent) continue;
      if (parent.service_name !== sourceService) continue;
      if (child.service_name !== targetService) continue;

      // Cross-service span for this edge — group by source-side operation
      // Error attribution: based on the CLIENT/PRODUCER span's own status.
      const key = `${parent.span_name}\0${parent.span_kind}`;
      const isError = parent.span_status?.code === 2;
      const existing = opStats.get(key);
      if (existing) {
        existing.count += 1;
        existing.errors += isError ? 1 : 0;
        existing.totalDuration += parent.span_duration_millis;
      } else {
        opStats.set(key, {
          count: 1,
          errors: isError ? 1 : 0,
          totalDuration: parent.span_duration_millis,
          spanKind: parent.span_kind,
          fingerprint: parent.span_fingerprint,
        });
      }
    }
  }

  const result: DerivedOperation[] = [];
  for (const [key, stats] of opStats) {
    const [spanName] = key.split("\0");
    result.push({
      spanName,
      spanFingerprint: stats.fingerprint,
      spanKind: stats.spanKind,
      count: stats.count,
      errorCount: stats.errors,
      avgDurationMs: stats.count > 0 ? Math.round(stats.totalDuration / stats.count) : 0,
    });
  }
  result.sort((a, b) => b.count - a.count);
  return result;
}

// --- Merge parent-child edges with peer.service edges ---

export function mergeEdges(
  parentChildEdges: AggregatedEdge[],
  peerServiceEdges: AggregatedEdge[],
  realServiceNames: Set<string>,
): AggregatedEdge[] {
  // Start with all parent-child edges
  const edgeMap = new Map<string, AggregatedEdge>();
  for (const edge of parentChildEdges) {
    edgeMap.set(`${edge.source}\0${edge.dest}`, edge);
  }

  // Add peer.service edges only for destinations that are NOT real services
  // (i.e., implicit leaves like databases/caches that don't emit their own spans)
  for (const edge of peerServiceEdges) {
    if (realServiceNames.has(edge.dest)) continue;
    const key = `${edge.source}\0${edge.dest}`;
    if (!edgeMap.has(key)) {
      edgeMap.set(key, edge);
    }
  }

  return [...edgeMap.values()];
}

// --- Per-node stats ---

export function computeServiceStats(
  serviceNames: string[],
  aggregated: AggregatedEdge[],
  svcTotals: Map<string, { count: number; avgDurationMs: number }>,
  svcErrors: Map<string, number>,
  realServiceNames: Set<string>,
): Map<string, ServiceStats> {
  const dests = new Set(aggregated.map((e) => e.dest));
  const roots = new Set(serviceNames.filter((n) => !dests.has(n)));
  // Implicit = doesn't emit its own spans (not seen in sampled traces), only
  // appears as an edge destination inferred from peer.service / db.system.
  // Note: svcTotals only has SERVER/CONSUMER spans, so a client-only service
  // like a frontend would be missing from svcTotals but IS a real service.
  const implicitLeaves = new Set(serviceNames.filter((n) => !realServiceNames.has(n)));

  const stats = new Map<string, ServiceStats>();
  for (const name of serviceNames) {
    if (implicitLeaves.has(name)) {
      let totalCalls = 0, totalErrors = 0, weightedDuration = 0;
      for (const edge of aggregated) {
        if (edge.dest === name) {
          totalCalls += edge.callCount;
          totalErrors += edge.errorCount;
          weightedDuration += edge.avgDurationMs * edge.callCount;
        }
      }
      stats.set(name, {
        label: name,
        serviceKind: inferServiceKind(name),
        totalCalls,
        totalErrors,
        avgDurationMs: totalCalls > 0 ? Math.round(weightedDuration / totalCalls) : 0,
        errorRate: totalCalls > 0 ? totalErrors / totalCalls : 0,
        isRoot: false,
        isImplicit: true,
      });
    } else {
      const svc = svcTotals.get(name);
      const errors = svcErrors.get(name) ?? 0;
      const totalCalls = svc?.count ?? 0;
      stats.set(name, {
        label: name,
        serviceKind: inferServiceKind(name),
        totalCalls,
        totalErrors: errors,
        avgDurationMs: Math.round(svc?.avgDurationMs ?? 0),
        errorRate: totalCalls > 0 ? errors / totalCalls : 0,
        isRoot: roots.has(name),
        isImplicit: false,
      });
    }
  }

  return stats;
}

// --- Force-directed layout (d3-force) ---

import {
  forceSimulation,
  forceLink,
  forceManyBody,
  forceCenter,
  forceCollide,
  forceY,
  type SimulationNodeDatum,
  type SimulationLinkDatum,
} from "d3-force";

export interface ForceNode extends SimulationNodeDatum {
  id: string;
  depth: number;
}

export function computeDepths(
  serviceNames: string[],
  aggregated: AggregatedEdge[],
): Map<string, number> {
  const inDegree = new Map<string, number>();
  const adj = new Map<string, string[]>();
  for (const name of serviceNames) {
    inDegree.set(name, 0);
    adj.set(name, []);
  }
  for (const edge of aggregated) {
    adj.get(edge.source)!.push(edge.dest);
    inDegree.set(edge.dest, (inDegree.get(edge.dest) ?? 0) + 1);
  }
  const depth = new Map<string, number>();
  const queue: string[] = [];
  for (const name of serviceNames) {
    if (inDegree.get(name) === 0) {
      queue.push(name);
      depth.set(name, 0);
    }
  }
  while (queue.length > 0) {
    const node = queue.shift()!;
    const d = depth.get(node)!;
    for (const neighbor of adj.get(node)!) {
      if (!depth.has(neighbor) || depth.get(neighbor)! < d + 1) {
        depth.set(neighbor, d + 1);
      }
      const remaining = inDegree.get(neighbor)! - 1;
      inDegree.set(neighbor, remaining);
      if (remaining === 0) queue.push(neighbor);
    }
  }
  const maxDepth = Math.max(0, ...depth.values());
  for (const name of serviceNames) {
    if (!depth.has(name)) depth.set(name, maxDepth + 1);
  }
  return depth;
}

export function computeForceLayout(
  serviceNames: string[],
  aggregated: AggregatedEdge[],
): Map<string, { x: number; y: number }> {
  const positions = new Map<string, { x: number; y: number }>();
  if (serviceNames.length === 0) return positions;
  if (serviceNames.length === 1) {
    positions.set(serviceNames[0], { x: 0, y: 0 });
    return positions;
  }

  const depths = computeDepths(serviceNames, aggregated);

  const nodes: ForceNode[] = serviceNames.map((name) => ({
    id: name,
    depth: depths.get(name)!,
  }));

  const nameIndex = new Map(serviceNames.map((n, i) => [n, i]));
  const links: SimulationLinkDatum<ForceNode>[] = aggregated.map((e) => ({
    source: nameIndex.get(e.source)!,
    target: nameIndex.get(e.dest)!,
  }));

  const simulation = forceSimulation<ForceNode>(nodes)
    .force(
      "link",
      forceLink<ForceNode, SimulationLinkDatum<ForceNode>>(links)
        .distance(180)
        .strength(0.7),
    )
    .force("charge", forceManyBody<ForceNode>().strength(-600))
    .force("center", forceCenter(0, 0))
    .force("collide", forceCollide<ForceNode>(60))
    .force(
      "y",
      forceY<ForceNode>((d) => d.depth * 150).strength(0.3),
    )
    .stop();

  for (let i = 0; i < 300; i++) simulation.tick();

  for (const node of nodes) {
    positions.set(node.id, {
      x: Math.round(node.x ?? 0),
      y: Math.round(node.y ?? 0),
    });
  }

  return positions;
}

// --- Hierarchical (DAG) layout ---

export function computeHierarchicalLayout(
  serviceNames: string[],
  aggregated: AggregatedEdge[],
): Map<string, { x: number; y: number }> {
  const positions = new Map<string, { x: number; y: number }>();
  if (serviceNames.length === 0) return positions;
  if (serviceNames.length === 1) {
    positions.set(serviceNames[0], { x: 0, y: 0 });
    return positions;
  }

  const depths = computeDepths(serviceNames, aggregated);

  // Group nodes by layer
  const layers = new Map<number, string[]>();
  for (const name of serviceNames) {
    const d = depths.get(name)!;
    let layer = layers.get(d);
    if (!layer) {
      layer = [];
      layers.set(d, layer);
    }
    layer.push(name);
  }

  // Build adjacency for barycenter ordering
  const children = new Map<string, string[]>();
  for (const name of serviceNames) children.set(name, []);
  for (const edge of aggregated) {
    children.get(edge.source)!.push(edge.dest);
  }

  // Order each layer by barycenter of parent positions (minimize crossings)
  const xIndex = new Map<string, number>();
  const sortedDepths = [...layers.keys()].sort((a, b) => a - b);

  // First layer: sort alphabetically
  const firstLayer = layers.get(sortedDepths[0])!;
  firstLayer.sort();
  firstLayer.forEach((name, i) => xIndex.set(name, i));

  // Subsequent layers: order by average x-index of parents
  for (let li = 1; li < sortedDepths.length; li++) {
    const layer = layers.get(sortedDepths[li])!;
    const parentAvg = new Map<string, number>();
    for (const name of layer) {
      // Find all parents (nodes in previous layers with edges to this node)
      let sum = 0, count = 0;
      for (const edge of aggregated) {
        if (edge.dest === name && xIndex.has(edge.source)) {
          sum += xIndex.get(edge.source)!;
          count++;
        }
      }
      parentAvg.set(name, count > 0 ? sum / count : 0);
    }
    layer.sort((a, b) => (parentAvg.get(a) ?? 0) - (parentAvg.get(b) ?? 0));
    layer.forEach((name, i) => xIndex.set(name, i));
  }

  // Assign positions
  const layerSpacingY = 160;
  const nodeSpacingX = 200;

  for (const [depth, layer] of layers) {
    const totalWidth = (layer.length - 1) * nodeSpacingX;
    const startX = -totalWidth / 2;
    for (let i = 0; i < layer.length; i++) {
      positions.set(layer[i], {
        x: Math.round(startX + i * nodeSpacingX),
        y: Math.round(depth * layerSpacingY),
      });
    }
  }

  return positions;
}
