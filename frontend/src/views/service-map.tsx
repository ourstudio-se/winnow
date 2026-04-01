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
  type SimulationLinkDatum,
  type Simulation,
} from "d3-force";
import { Server, Database, Globe, Zap, AlertTriangle } from "lucide-react";
import { searchTraces } from "@/lib/api";
import { FilterBar, type FilterState } from "@/components/filter-bar";
import { ServiceContextMenu } from "@/components/service-context-menu";
import { OperationsDrilldownPanel } from "@/components/operations-drilldown";
import {
  type AggregatedEdge,
  type EdgesAggResponse,
  type ServiceAggResponse,
  type ServiceKind,
  type ServiceStats,
  type ServiceEdgeData,
  type SampledSpan,
  type ForceNode,
  TRACE_SAMPLE_SIZE,
  MAX_SAMPLED_SPANS,
  formatDuration,
  parseEdgesFromAggs,
  deriveEdgesFromTraces,
  mergeEdges,
  computeServiceStats,
  computeDepths,
  computeForceLayout,
} from "@/lib/service-graph";

// --- Icons ---

const serviceKindIcon: Record<ServiceKind, typeof Server> = {
  database: Database,
  cache: Zap,
  gateway: Globe,
  service: Server,
};

// --- Graph building ---

function buildGraph(
  aggregated: AggregatedEdge[],
  svcTotals: Map<string, { count: number; avgDurationMs: number }>,
  svcErrors: Map<string, number>,
): {
  nodes: Node<ServiceStats>[];
  edges: Edge<ServiceEdgeData>[];
} {
  // Include all known services — not just those with edges — so isolated
  // services (no cross-service calls, no peer.service) still appear as nodes.
  const serviceNames = new Set<string>();
  for (const e of aggregated) {
    serviceNames.add(e.source);
    serviceNames.add(e.dest);
  }
  for (const name of svcTotals.keys()) {
    serviceNames.add(name);
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
    sourceService?: string;
  } | null>(null);

  const filterBarStateRef = useRef<FilterState | undefined>(undefined);

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

  const onEdgeClick = useCallback(
    (_event: React.MouseEvent, edge: Edge<ServiceEdgeData>) => {
      setContextMenu(null);
      const destNode = nodes.find((n) => n.id === edge.target);
      const isImplicit = destNode?.data.isImplicit ?? false;
      setDrilldown({
        serviceName: edge.target,
        errorsOnly: false,
        isImplicit,
        sourceService: edge.source,
      });
    },
    [nodes],
  );

  const onPaneClick = useCallback(() => {
    setContextMenu(null);
  }, []);

  const fetchData = useCallback(
    async (filters?: FilterState) => {
      const effectiveFilters = filters ?? filterBarStateRef.current;
      setLoading(true);
      setError(null);
      try {
        const userQuery =
          effectiveFilters?.query && effectiveFilters.query !== "*"
            ? effectiveFilters.query
            : "";

        // peer.service agg queries still use CLIENT/PRODUCER filter
        const kindFilter = "(span_kind:3 OR span_kind:4)";
        const baseQuery = userQuery ? `${kindFilter} AND ${userQuery}` : kindFilter;

        // Trace ID sampling: terms agg naturally surfaces multi-service traces
        // (they have more spans, so rank higher by doc_count)
        const traceIdAggs = {
          trace_ids: {
            terms: { field: "trace_id", size: TRACE_SAMPLE_SIZE },
          },
        };

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

        // Wave 1: 5 parallel queries (trace ID sampling + 4 existing aggs)
        const [traceIdRes, allRes, errorRes, svcAllRes, svcErrRes] = await Promise.all([
          searchTraces<never>({
            query: svcQuery,
            max_hits: 0,
            aggs: traceIdAggs,
          }),
          searchTraces<never>({
            query: baseQuery,
            max_hits: 0,
            aggs: nestedAggs,
          }),
          searchTraces<never>({
            query: `${baseQuery} AND span_status.code:2`,
            max_hits: 0,
            aggs: nestedAggs,
          }),
          searchTraces<never>({
            query: svcQuery,
            max_hits: 0,
            aggs: svcAggs,
          }),
          searchTraces<never>({
            query: svcErrorQuery,
            max_hits: 0,
            aggs: { services: { terms: { field: "service_name", size: 200 } } },
          }),
        ]);

        // Wave 2: bulk fetch ALL spans for sampled traces (no user filter — the
        // filter already scoped which traces we sampled; we need the full trace
        // to build cross-service edges, not just the matching spans)
        const traceIdBuckets = (traceIdRes.aggregations as { trace_ids: { buckets: { key: string }[] } }).trace_ids.buckets;
        const traceIds = traceIdBuckets.map((b) => b.key);
        let sampledSpans: SampledSpan[] = [];
        if (traceIds.length > 0) {
          try {
            const traceQuery = traceIds.map((id) => `trace_id:${id}`).join(" OR ");
            const spansRes = await searchTraces<SampledSpan>({
              query: traceQuery,
              max_hits: MAX_SAMPLED_SPANS,
            });
            sampledSpans = spansRes.hits;
          } catch (e) {
            console.warn("Failed to fetch sampled spans for parent-child edges, falling back to peer.service only:", e);
          }
        }

        // Derive edges from parent-child relationships
        const pcEdges = deriveEdgesFromTraces(sampledSpans);
        const realServiceNames = new Set(sampledSpans.map((s) => s.service_name));

        // Parse peer.service edges from aggregations
        const allAgg = allRes.aggregations as unknown as EdgesAggResponse;
        const errorAgg = errorRes.aggregations as unknown as EdgesAggResponse;
        const peerEdges = parseEdgesFromAggs(allAgg, errorAgg);

        // Merge: parent-child takes priority, peer.service only for implicit leaves
        const aggregated = mergeEdges(pcEdges, peerEdges, realServiceNames);

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
      filterBarStateRef.current = filters;
      fetchData(filters);
    },
    [fetchData],
  );

  // Cleanup simulation on unmount
  useEffect(() => {
    return () => {
      simRef.current?.stop();
    };
  }, []);

  return (
    <div className="flex flex-1 flex-col">
      <FilterBar
        index="traces"
        baseQuery="(span_kind:3 OR span_kind:4)"
        onFilterChange={handleFilterChange}
      />
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
              onEdgeClick={onEdgeClick}
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
              sourceService={drilldown.sourceService}
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
