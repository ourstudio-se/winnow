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

export interface StatusBucket {
  key: string;
  doc_count: number;
}

export interface InnerTermsBucket {
  key: string;
  doc_count: number;
  avg_duration?: { value: number };
  by_status?: { buckets: StatusBucket[] };
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
  by_status?: { buckets: StatusBucket[] };
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

// --- Connector (servicegraph) types ---

interface ConnectorServerBucket {
  key: string;
  doc_count: number;
  total_calls: { value: number };
  total_errors: { value: number };
}

interface ConnectorClientBucket {
  key: string;
  doc_count: number;
  by_server: { buckets: ConnectorServerBucket[] };
}

export interface ConnectorAggResponse {
  by_client: { buckets: ConnectorClientBucket[] };
}

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

// --- Helpers for by_status sub-aggregation ---

export function errorCountFromStatus(buckets: StatusBucket[] | undefined): number {
  if (!buckets) return 0;
  return buckets.find((b) => String(b.key) === "2")?.doc_count ?? 0;
}

// --- Aggregation (peer.service edges) ---

export function parseEdgesFromAggs(
  agg: EdgesAggResponse,
): AggregatedEdge[] {
  const result: AggregatedEdge[] = [];
  for (const outer of agg.edges.buckets) {
    for (const inner of outer.dests.buckets) {
      result.push({
        source: outer.key,
        dest: inner.key,
        callCount: inner.doc_count,
        errorCount: errorCountFromStatus(inner.by_status?.buckets),
        avgDurationMs: Math.round(inner.avg_duration?.value ?? 0),
        edgeType: "sync",
      });
    }
  }
  return result;
}

// --- Connector edge parsing ---

export function parseConnectorEdges(
  agg: ConnectorAggResponse,
): AggregatedEdge[] {
  const result: AggregatedEdge[] = [];
  for (const clientBucket of agg.by_client.buckets) {
    for (const serverBucket of clientBucket.by_server.buckets) {
      result.push({
        source: clientBucket.key,
        dest: serverBucket.key,
        callCount: Math.round(serverBucket.total_calls?.value ?? 0),
        errorCount: Math.round(serverBucket.total_errors?.value ?? 0),
        avgDurationMs: 0, // Connector doesn't provide duration
        edgeType: "sync",
      });
    }
  }
  return result;
}

// --- Merge connector edges with peer.service edges ---

export function mergeEdgesV2(
  connectorEdges: AggregatedEdge[],
  peerEdges: AggregatedEdge[],
  realServiceNames: Set<string>,
): AggregatedEdge[] {
  // Start with connector edges (these are the authoritative edges)
  const edgeMap = new Map<string, AggregatedEdge>();
  for (const edge of connectorEdges) {
    edgeMap.set(`${edge.source}\0${edge.dest}`, edge);
  }

  // Add peer.service edges only for destinations that are NOT real services
  // and not already covered by connector edges (i.e., implicit leaves)
  for (const edge of peerEdges) {
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
