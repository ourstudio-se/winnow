import { useCallback, useEffect, useRef, useState } from "react";
import {
  ReactFlow,
  Background,
  BackgroundVariant,
  Controls,
  Handle,
  Position,
  BaseEdge,
  EdgeLabelRenderer,
  getBezierPath,
  applyNodeChanges,
  type Node,
  type Edge,
  type NodeProps,
  type EdgeProps,
  type OnNodesChange,
} from "@xyflow/react";
import {
  forceSimulation,
  forceLink,
  forceManyBody,
  forceCenter,
  forceCollide,
  forceY,
  type SimulationNodeDatum,
  type SimulationLinkDatum,
  type Simulation,
} from "d3-force";
import { Server, Database, Globe, Zap, AlertTriangle } from "lucide-react";
import { search } from "@/lib/api";
import { FilterBar, type FilterState } from "@/components/filter-bar";
import { ServiceContextMenu } from "@/components/service-context-menu";
import { OperationsDrilldownPanel } from "@/components/operations-drilldown";

// --- Types ---

interface AggregatedEdge {
  source: string;
  dest: string;
  callCount: number;
  errorCount: number;
  avgDurationMs: number;
}

interface InnerTermsBucket {
  key: string;
  doc_count: number;
  avg_duration?: { value: number };
}
interface OuterTermsBucket {
  key: string;
  doc_count: number;
  dests: { buckets: InnerTermsBucket[] };
}
interface EdgesAggResponse {
  edges: { buckets: OuterTermsBucket[] };
}

interface ServiceTermsBucket {
  key: string;
  doc_count: number;
  avg_duration?: { value: number };
}
interface ServiceAggResponse {
  services: { buckets: ServiceTermsBucket[] };
}

type ServiceKind = "database" | "cache" | "gateway" | "service";

interface ServiceStats {
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

type ServiceEdgeData = {
  [key: string]: unknown;
  callCount: number;
  errorCount: number;
  avgDurationMs: number;
};

// --- Helpers ---

function formatDuration(ms: number): string {
  if (ms < 1) return "<1ms";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60000).toFixed(1)}m`;
}

function inferServiceKind(name: string): ServiceKind {
  const lower = name.toLowerCase();
  if (/postgres|mysql|maria|mongo|cockroach|sqlite|oracle|mssql|sql|db/.test(lower))
    return "database";
  if (/redis|memcache|cache|valkey|dragonfly/.test(lower)) return "cache";
  if (/gateway|proxy|nginx|envoy|haproxy|ingress|lb|load.?balancer/.test(lower))
    return "gateway";
  return "service";
}

const serviceKindIcon: Record<ServiceKind, typeof Server> = {
  database: Database,
  cache: Zap,
  gateway: Globe,
  service: Server,
};

// --- Aggregation ---

function parseEdgesFromAggs(
  allAgg: EdgesAggResponse,
  errorAgg: EdgesAggResponse,
): AggregatedEdge[] {
  // Build error count lookup: "source\0dest" → count
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
      });
    }
  }
  return result;
}

// --- Per-node stats ---

function computeServiceStats(
  serviceNames: string[],
  aggregated: AggregatedEdge[],
  svcTotals: Map<string, { count: number; avgDurationMs: number }>,
  svcErrors: Map<string, number>,
): Map<string, ServiceStats> {
  const sources = new Set(aggregated.map((e) => e.source));
  const dests = new Set(aggregated.map((e) => e.dest));
  const roots = new Set(serviceNames.filter((n) => !dests.has(n)));
  // Implicit leaves: appear only as destinations, never as sources (e.g. postgres, redis)
  const implicitLeaves = new Set(serviceNames.filter((n) => !sources.has(n) && dests.has(n)));

  const stats = new Map<string, ServiceStats>();
  for (const name of serviceNames) {
    if (implicitLeaves.has(name)) {
      // Implicit leaf: use edge-derived stats (incoming CLIENT spans targeting this service)
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
      // Real service: use per-service all-span-kind stats for accurate health
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

interface ForceNode extends SimulationNodeDatum {
  id: string;
  depth: number;
}

function computeDepths(
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

function computeForceLayout(
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

// --- Graph building ---

function buildGraph(
  aggregated: AggregatedEdge[],
  svcTotals: Map<string, { count: number; avgDurationMs: number }>,
  svcErrors: Map<string, number>,
): {
  nodes: Node<ServiceStats>[];
  edges: Edge<ServiceEdgeData>[];
} {
  const serviceNames = new Set<string>();
  for (const e of aggregated) {
    serviceNames.add(e.source);
    serviceNames.add(e.dest);
  }
  const sorted = [...serviceNames].sort();
  const positions = computeForceLayout(sorted, aggregated);
  const stats = computeServiceStats(sorted, aggregated, svcTotals, svcErrors);

  const nodes: Node<ServiceStats>[] = sorted.map((name) => {
    const pos = positions.get(name)!;
    return {
      id: name,
      type: "service",
      position: pos,
      data: stats.get(name)!,
      connectable: false,
    };
  });

  const edges: Edge<ServiceEdgeData>[] = aggregated.map((e) => ({
    id: `${e.source}->${e.dest}`,
    source: e.source,
    target: e.dest,
    type: "service",
    data: {
      callCount: e.callCount,
      errorCount: e.errorCount,
      avgDurationMs: e.avgDurationMs,
    },
  }));

  return { nodes, edges };
}

// --- Custom node ---

function ServiceNode({ data }: NodeProps<Node<ServiceStats>>) {
  const Icon = serviceKindIcon[data.serviceKind];
  const errorPct =
    data.errorRate > 0 ? `${(data.errorRate * 100).toFixed(0)}%` : null;

  // Threshold-based border: green < 5%, amber 5–15%, red > 15%
  let borderColor = "border-emerald-500";
  if (data.errorRate >= 0.15) borderColor = "border-red-500";
  else if (data.errorRate >= 0.05) borderColor = "border-amber-500";

  return (
    <div className="flex flex-col items-center gap-1.5">
      <Handle
        type="target"
        position={Position.Top}
        className="!border-none !bg-transparent !w-2 !h-2"
      />
      <div className="relative">
        <div
          className={`flex h-20 w-20 flex-col items-center justify-center rounded-full border-2 bg-card shadow-md ${borderColor}`}
        >
          <Icon className="mb-0.5 h-4 w-4 text-muted-foreground" />
          {data.totalCalls > 0 && (
            <div className="flex flex-col items-center text-[10px] leading-tight text-muted-foreground">
              <span>{data.totalCalls} calls</span>
              <span>{formatDuration(data.avgDurationMs)}</span>
            </div>
          )}
        </div>
        {errorPct && (
          <div className="absolute -right-1 -top-1 flex items-center gap-0.5 rounded-full bg-red-500 px-1.5 py-0.5 text-[9px] font-medium text-white">
            <AlertTriangle className="h-2.5 w-2.5" />
            {errorPct}
          </div>
        )}
      </div>
      <span className="max-w-[120px] truncate text-center text-xs font-medium text-foreground">
        {data.label}
      </span>
      <Handle
        type="source"
        position={Position.Bottom}
        className="!border-none !bg-transparent !w-2 !h-2"
      />
    </div>
  );
}

// --- Custom edge ---

const EDGE_GRAY = "oklch(0.45 0 0)";
const EDGE_RED = "oklch(0.6 0.18 25)";

function ServiceEdge({
  id,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourcePosition,
  targetPosition,
  data,
}: EdgeProps<Edge<ServiceEdgeData>>) {
  const hasErrors = data != null && data.errorCount > 0;
  const color = hasErrors ? EDGE_RED : EDGE_GRAY;

  const [edgePath, labelX, labelY] = getBezierPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
  });

  const labelText = hasErrors
    ? `${data!.callCount} · ${formatDuration(data!.avgDurationMs)} · ${data!.errorCount} err`
    : data
      ? `${data.callCount} · ${formatDuration(data.avgDurationMs)}`
      : "";

  return (
    <>
      <defs>
        <marker
          id={`arrow-${id}`}
          viewBox="0 0 12 12"
          refX="10"
          refY="6"
          markerWidth="12"
          markerHeight="12"
          orient="auto-start-reverse"
        >
          <path d="M 2 2 L 10 6 L 2 10 z" fill={color} />
        </marker>
      </defs>
      <BaseEdge
        id={id}
        path={edgePath}
        style={{ stroke: color, strokeWidth: 1 }}
        markerEnd={`url(#arrow-${id})`}
      />
      {labelText && (
        <EdgeLabelRenderer>
          <div
            className="rounded-md bg-card/80 px-1.5 py-0.5 text-[10px] text-muted-foreground shadow-sm ring-1 ring-border/50"
            style={{
              position: "absolute",
              transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)`,
              pointerEvents: "none",
            }}
          >
            {labelText}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  );
}

const nodeTypes = { service: ServiceNode };
const edgeTypes = { service: ServiceEdge };

// --- Main view ---

export function ServiceMapView() {
  const [nodes, setNodes] = useState<Node<ServiceStats>[]>([]);
  const [edges, setEdges] = useState<Edge<ServiceEdgeData>[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [contextMenu, setContextMenu] = useState<{
    serviceName: string;
    x: number;
    y: number;
    hasErrors: boolean;
    isImplicit: boolean;
  } | null>(null);
  const [drilldown, setDrilldown] = useState<{
    serviceName: string;
    errorsOnly: boolean;
    isImplicit: boolean;
  } | null>(null);

  // Simulation refs
  const simRef = useRef<Simulation<ForceNode, SimulationLinkDatum<ForceNode>> | null>(null);
  const simNodeMapRef = useRef(new Map<string, ForceNode>());
  const draggingRef = useRef<string | null>(null);

  // Handle React Flow changes (selection, dimensions) but NOT position — simulation owns that
  const handleNodesChange: OnNodesChange<Node<ServiceStats>> = useCallback(
    (changes) => {
      const filtered = changes.filter((c) => c.type !== "position");
      if (filtered.length > 0) {
        setNodes((nds) => applyNodeChanges(filtered, nds) as Node<ServiceStats>[]);
      }
    },
    [setNodes],
  );

  const startSimulation = useCallback(
    (
      graphNodes: Node<ServiceStats>[],
      graphEdges: Edge<ServiceEdgeData>[],
    ) => {
      // Stop any existing simulation
      simRef.current?.stop();

      const serviceNames = graphNodes.map((n) => n.id);
      const depths = computeDepths(
        serviceNames,
        graphEdges.map((e) => ({
          source: e.source,
          dest: e.target,
          callCount: 0,
          errorCount: 0,
          avgDurationMs: 0,
        })),
      );

      // Create simulation nodes initialized at computed positions
      const simNodes: ForceNode[] = graphNodes.map((n) => ({
        id: n.id,
        depth: depths.get(n.id) ?? 0,
        x: n.position.x,
        y: n.position.y,
      }));

      const nodeMap = new Map(simNodes.map((sn) => [sn.id, sn]));
      simNodeMapRef.current = nodeMap;

      const nameIndex = new Map(serviceNames.map((n, i) => [n, i]));
      const links: SimulationLinkDatum<ForceNode>[] = graphEdges.map((e) => ({
        source: nameIndex.get(e.source)!,
        target: nameIndex.get(e.target)!,
      }));

      const simulation = forceSimulation<ForceNode>(simNodes)
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
        .alpha(0)
        .alphaTarget(0)
        .on("tick", () => {
          setNodes((prev) =>
            prev.map((n) => {
              const sn = nodeMap.get(n.id);
              if (!sn) return n;
              return {
                ...n,
                position: { x: sn.x ?? 0, y: sn.y ?? 0 },
              };
            }),
          );
        });

      simRef.current = simulation;
    },
    [setNodes],
  );

  // Drag handlers — feed positions into the simulation
  const onNodeDragStart = useCallback(
    (_: React.MouseEvent, node: Node) => {
      draggingRef.current = node.id;
      const sn = simNodeMapRef.current.get(node.id);
      if (sn) {
        sn.fx = node.position.x;
        sn.fy = node.position.y;
      }
      simRef.current?.alphaTarget(0.3).restart();
    },
    [],
  );

  const onNodeDrag = useCallback((_: React.MouseEvent, node: Node) => {
    const sn = simNodeMapRef.current.get(node.id);
    if (sn) {
      sn.fx = node.position.x;
      sn.fy = node.position.y;
    }
  }, []);

  const onNodeDragStop = useCallback((_: React.MouseEvent, node: Node) => {
    draggingRef.current = null;
    const sn = simNodeMapRef.current.get(node.id);
    if (sn) {
      sn.fx = null;
      sn.fy = null;
    }
    simRef.current?.alphaTarget(0);
  }, []);

  const onNodeClick = useCallback(
    (event: React.MouseEvent, node: Node<ServiceStats>) => {
      setContextMenu({
        serviceName: node.id,
        x: event.clientX,
        y: event.clientY,
        hasErrors: node.data.totalErrors > 0,
        isImplicit: node.data.isImplicit,
      });
    },
    [],
  );

  const onPaneClick = useCallback(() => {
    setContextMenu(null);
  }, []);

  const fetchData = useCallback(
    async (filters?: FilterState) => {
      setLoading(true);
      setError(null);
      try {
        const userQuery = filters?.query && filters.query !== "*" ? filters.query : "";
        const kindFilter = "(span_kind:3 OR span_kind:4)";
        const baseQuery = userQuery ? `${kindFilter} AND ${userQuery}` : kindFilter;

        const nestedAggs = {
          edges: {
            terms: { field: "service_name", size: 200 },
            aggs: {
              dests: {
                terms: { field: "span_attributes.peer.service", size: 200 },
                aggs: {
                  avg_duration: { avg: { field: "span_duration_millis" } },
                },
              },
            },
          },
        };

        const svcAggs = {
          services: {
            terms: { field: "service_name", size: 200 },
            aggs: {
              avg_duration: { avg: { field: "span_duration_millis" } },
            },
          },
        };
        const svcQuery = userQuery || "*";
        const svcErrorQuery = userQuery ? `span_status.code:2 AND ${userQuery}` : "span_status.code:2";

        const [allRes, errorRes, svcAllRes, svcErrRes] = await Promise.all([
          search<never>("otel-traces-v0_9", {
            query: baseQuery,
            max_hits: 0,
            start_timestamp: filters?.startTimestamp,
            end_timestamp: filters?.endTimestamp,
            aggs: nestedAggs,
          }),
          search<never>("otel-traces-v0_9", {
            query: `${baseQuery} AND span_status.code:2`,
            max_hits: 0,
            start_timestamp: filters?.startTimestamp,
            end_timestamp: filters?.endTimestamp,
            aggs: nestedAggs,
          }),
          search<never>("otel-traces-v0_9", {
            query: svcQuery,
            max_hits: 0,
            start_timestamp: filters?.startTimestamp,
            end_timestamp: filters?.endTimestamp,
            aggs: svcAggs,
          }),
          search<never>("otel-traces-v0_9", {
            query: svcErrorQuery,
            max_hits: 0,
            start_timestamp: filters?.startTimestamp,
            end_timestamp: filters?.endTimestamp,
            aggs: { services: { terms: { field: "service_name", size: 200 } } },
          }),
        ]);

        const allAgg = allRes.aggregations as unknown as EdgesAggResponse;
        const errorAgg = errorRes.aggregations as unknown as EdgesAggResponse;
        const aggregated = parseEdgesFromAggs(allAgg, errorAgg);

        // Per-service stats (all span kinds) for node health
        const svcAllAgg = svcAllRes.aggregations as unknown as ServiceAggResponse;
        const svcErrAgg = svcErrRes.aggregations as unknown as ServiceAggResponse;
        const svcTotals = new Map<string, { count: number; avgDurationMs: number }>();
        for (const b of svcAllAgg.services.buckets) {
          svcTotals.set(b.key, { count: b.doc_count, avgDurationMs: b.avg_duration?.value ?? 0 });
        }
        const svcErrors = new Map<string, number>();
        for (const b of svcErrAgg.services.buckets) {
          svcErrors.set(b.key, b.doc_count);
        }

        const graph = buildGraph(aggregated, svcTotals, svcErrors);
        setNodes(graph.nodes);
        setEdges(graph.edges);
        startSimulation(graph.nodes, graph.edges);
      } catch (e) {
        setError(
          e instanceof Error ? e.message : "Failed to fetch service graph",
        );
      } finally {
        setLoading(false);
      }
    },
    [startSimulation],
  );

  const handleFilterChange = useCallback(
    (filters: FilterState) => {
      fetchData(filters);
    },
    [fetchData],
  );

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Cleanup simulation on unmount
  useEffect(() => {
    return () => {
      simRef.current?.stop();
    };
  }, []);

  return (
    <div className="flex flex-1 flex-col">
      <FilterBar index="otel-traces-v0_9" baseQuery="(span_kind:3 OR span_kind:4)" onFilterChange={handleFilterChange} />
      {loading ? (
        <div className="flex flex-1 items-center justify-center text-muted-foreground">
          Loading service map…
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
      ) : nodes.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 text-muted-foreground">
          <h2 className="text-lg font-medium text-foreground">
            No services found
          </h2>
          <p className="text-sm">
            Send traces through the OTLP endpoint to see your service map here.
          </p>
        </div>
      ) : (
        <div className="flex flex-1">
          <div className="flex-1">
            <ReactFlow
              nodes={nodes}
              edges={edges}
              onNodesChange={handleNodesChange}
              onNodeDragStart={onNodeDragStart}
              onNodeDrag={onNodeDrag}
              onNodeDragStop={onNodeDragStop}
              onNodeClick={onNodeClick}
              onPaneClick={onPaneClick}
              nodeTypes={nodeTypes}
              edgeTypes={edgeTypes}
              colorMode="dark"
              fitView
              fitViewOptions={{ padding: 0.4 }}
              nodesDraggable
              nodesConnectable={false}
              proOptions={{ hideAttribution: true }}
            >
              <Background variant={BackgroundVariant.Dots} gap={20} size={1} />
              <Controls />
            </ReactFlow>
          </div>
          {drilldown && (
            <OperationsDrilldownPanel
              serviceName={drilldown.serviceName}
              errorsOnly={drilldown.errorsOnly}
              isImplicit={drilldown.isImplicit}
              onClose={() => setDrilldown(null)}
              onToggleErrorsOnly={(errorsOnly) =>
                setDrilldown((prev) => (prev ? { ...prev, errorsOnly } : null))
              }
            />
          )}
        </div>
      )}
      {contextMenu && (
        <ServiceContextMenu
          serviceName={contextMenu.serviceName}
          x={contextMenu.x}
          y={contextMenu.y}
          hasErrors={contextMenu.hasErrors}
          isImplicit={contextMenu.isImplicit}
          onClose={() => setContextMenu(null)}
          onDrilldown={(errorsOnly) =>
            setDrilldown({
              serviceName: contextMenu.serviceName,
              errorsOnly,
              isImplicit: contextMenu.isImplicit,
            })
          }
        />
      )}
    </div>
  );
}
