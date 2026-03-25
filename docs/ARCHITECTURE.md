# Architecture

## System Overview

```
                    ┌──────────────────────────────────┐
                    │         Frontend (React)          │
                    │    shadcn + visualization libs    │
                    └──────────────┬───────────────────┘
                                   │ HTTP/WebSocket
                    ┌──────────────▼───────────────────┐
                    │        Backend (Zig)              │
                    │                                   │
                    │  ┌─────────┐ ┌────────────────┐  │
                    │  │  OTLP   │ │  Jaeger gRPC   │  │
                    │  │ receiver│ │  API (full)     │  │
                    │  └────┬────┘ └───────┬────────┘  │
                    │       │              │            │
                    │       │  ┌───────────────────┐   │
                    │       │  │  Prometheus HTTP   │   │
                    │       │  │  API (subset)      │   │
                    │       │  └─────────┬─────────┘   │
                    │       │            │             │
                    │  ┌────▼────────────▼──────────┐  │
                    │  │   Data Source Abstraction   │  │
                    │  └────────────┬───────────────┘  │
                    │               │                   │
                    │        ┌──────▼──────┐           │
                    │        │  Quickwit   │           │
                    │        │  (traces,   │           │
                    │        │   logs,     │           │
                    │        │   metrics)  │           │
                    │        └─────────────┘           │
                    └──────────────────────────────────┘
```

## Backend (Zig)

### Why Zig
- Single static binary, tiny Docker image
- No runtime, no GC — predictable latency for an always-on service
- Fast compile times, lightweight tooling (ZLS doesn't eat your RAM)
- C interop for any native libs we need if we ever need them
- Minimal dependency philosophy — the language and ecosystem encourage small dep trees
- It's fun

### Dependencies
We want a small, explicit set of mature dependencies:
- **zig-protobuf** ([Arwalk/zig-protobuf](https://github.com/Arwalk/zig-protobuf)) — proto3 serialization/deserialization. 390 stars, 20 contributors, production-ready, v4.0.0 (March 2026).
- **gRPC-zig** ([ziglana/gRPC-zig](https://github.com/ziglana/gRPC-zig)) — gRPC client & server with HTTP/2, streaming, TLS. Pure Zig, no external deps.

That's it. HTTP/1.1 serving uses Zig's `std.http`. Everything else we write ourselves.

### Interfaces
1. **OTLP Receiver** — accepts OpenTelemetry data (gRPC + HTTP/protobuf)
   - Forwards trace/log data to Quickwit's OTLP ingest endpoint
   - Pre-computes service graph metrics, stores as metric documents in Quickwit
2. **Jaeger gRPC API** — full implementation of `SpanReaderPlugin` AND `DependenciesReaderPlugin`
   - Reads from Quickwit via its search API
   - Computes/serves dependency graph from service graph metrics
   - Can run headless as a drop-in Jaeger replacement
3. **Prometheus-compatible Query API** — subset of the Prometheus HTTP API
   - `/api/v1/query`, `/api/v1/query_range`, `/api/v1/series`
   - Translates PromQL (subset) into Quickwit aggregation queries
   - Enables external tools to query our metrics
4. **Frontend API** — serves the UI, provides query endpoints
5. **Service Graph Computation** — like OTel's servicegraph connector, but we own it
   - Processes spans to extract service-to-service edges
   - Computes request rates, error rates, latency percentiles
   - Stores as metric documents in Quickwit

### Data Source Abstraction
```
trait DataSource {
    // Traces
    fn searchTraces(query: TraceQuery) -> []Trace
    fn getTrace(traceId: string) -> Trace
    fn getDependencies(timeRange: TimeRange) -> []DependencyLink

    // Logs
    fn searchLogs(query: LogQuery) -> []LogRecord

    // Metrics (backed by Quickwit aggregations)
    fn queryMetrics(query: MetricQuery) -> TimeSeries
    fn getServiceGraph(timeRange: TimeRange) -> ServiceGraph
}
```
v1: Quickwit backs everything — traces, logs, and metrics.
The abstraction exists so we can swap backends later without touching UI code.

## Metrics on Quickwit

### Why not a separate TSDB?
The original plan was Mimir, but that pulls in a large Grafana-ecosystem dependency for
what is fundamentally a simple data problem. The service graph metrics we need are
low-cardinality and well-defined:
- Request count per (source_service, dest_service, operation) over time
- Error count per same dimensions
- Latency histograms per same dimensions

These are just documents with timestamps. Quickwit has aggregation support (terms,
histograms, avg, sum, percentiles) that can serve these queries.

### How it works
- Service graph computation produces metric documents (JSON) and ingests them into
  a dedicated Quickwit index (e.g., `metrics-servicegraph`)
- The Prometheus-compatible query API translates incoming queries into Quickwit
  aggregation requests
- We only implement the PromQL subset we actually need: `rate()`,
  `histogram_quantile()`, basic label matching, range queries

### The big win
One storage backend, one operational dependency. The deploy story is:
"point at Quickwit and go." If we ever hit a performance wall with time-series
workloads on Quickwit, we can add a dedicated TSDB behind the same Prometheus API
layer — the swap would be transparent to the frontend and external consumers.

### Alternatives evaluated
| Option | Why not |
|---|---|
| **Mimir** | AGPL-3.0, heavy, too coupled to Grafana ecosystem |
| **Thanos** | Requires Prometheus sidecar |
| **VictoriaMetrics** | S3/object storage is enterprise-only |
| **InfluxDB** | Own ecosystem baggage, licensing churn |

## Frontend

### Stack
- React + TypeScript
- shadcn/ui for components
- Visualization: evaluate **Apache ECharts** (has both time series and graph/network
  visualizations) or **uPlot** (time series) + **React Flow** (node graphs)

### UX Principles
1. **One way to do anything.** No "dashboards vs explore vs drilldown vs alerting view"
   for looking at the same data. One unified interface.
2. **No programmer UI.** No raw query editors, no JSON model editing, no "data source
   configuration" pages. Users point at a Quickwit cluster and go.
3. **Everything is connected.** Click a service → see its traces. Click a trace → see
   its logs. Click a log → see the span. No "configure data links" step.
4. **No first-class/second-class distinction.** Every supported backend gets full UI
   integration or it doesn't ship.

### Core Views
1. **Service Map** — the service dependency graph, always available, always correct.
   Click any node to drill into that service.
2. **Traces** — search, filter, timeline view. Span details with connected logs.
3. **Logs** — search, filter, structured display. Click trace_id to jump to trace.
4. **Service Detail** — request rate, error rate, latency for a single service over time.
   Inbound/outbound dependencies. Recent errors.

## Deployment

### Docker Image
Single `FROM scratch` image containing:
- Zig backend binary (statically linked)
- Frontend assets (embedded in binary or copied to image)
- Default config

```
docker run -p 8080:8080 \
  -e QUICKWIT_URL=http://quickwit:7280 \
  winnow:latest
```

### Nix Flake
```
nix run github:ourstudio-se/winnow
nix build github:ourstudio-se/winnow#docker-image
```

Flake outputs:
- `packages.default` — the backend binary with embedded frontend
- `packages.docker-image` — OCI image
- `devShells.default` — development environment with all deps
