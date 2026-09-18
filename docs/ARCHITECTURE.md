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
- Single binary, tiny Docker image
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

## General-Purpose Metrics (Deferred — September 2026)

We evaluated adding an optional metrics module for general time-series data
(host metrics, request latencies, etc.). **Decision: hold off until Quickwit's
upstream metrics engine matures. We stay all-in on Quickwit.**

### Why the current Quickwit engine can't back this
The servicegraph-metrics-on-Quickwit approach above works because that data is
low-cardinality, fixed-schema, and pre-aggregated. General metrics violate all
three assumptions, and the tantivy-based engine breaks on:
- **Storage economics** — a metric point is ~16 bytes of information; stored as
  a document it re-carries its full label set through index structures built
  for text search. A real TSDB sorts by series and delta-encodes (1–2
  bytes/sample) — a 10–100x difference in storage and scan volume.
- **Query model** — no timeseries concept; every panel refresh reconstructs
  series via terms + date_histogram aggregations (scatter-gather over all
  splits, terms-agg memory blowup at high cardinality). No `rate()`,
  counter-reset handling, staleness, or cross-series joins.
- **Access pattern** — relentless small writes across all series plus
  high-frequency reads of the leading edge; Quickwit's commit cadence, split
  merging, and caching are tuned for bursty log batches.

The GreptimeDB-style "unified event model materialized into metrics on demand"
doesn't transfer: unification there happens at the query layer, but the
physical engine underneath is series-sorted columnar storage. Sort order is
the whole game; it can't be faked over inverted-index splits.

### What Quickwit upstream is building (verified September 2026)
Quickwit (post-Datadog acquisition) is building a **second, parallel storage
engine specifically for metrics** — effectively rebuilding Datadog's internal
"Husky" store in the OSS repo (the ADRs reference Husky conventions and phases
directly; the repo's evolution doc names metrics as the current priority
signal):
- Crates: `quickwit-parquet-engine`, `quickwit-datafusion`, `quickwit-df-core`,
  `quickwit-compaction`; OTLP metrics receiver
  (`quickwit-opentelemetry/src/otlp/arrow_metrics.rs`)
- Design: OTLP → Arrow RecordBatch → `timeseries_id` assignment → Parquet
  splits sorted by `metric_name|tags|timestamp` with page-level stats and
  zonemaps → DataFusion query layer with page pruning → time-windowed sorted
  compaction. A textbook columnar TSDB.
- ADRs: `docs/internals/adr/001-parquet-data-model.md`,
  `002-sort-schema-parquet-splits.md`, `003-time-windowed-sorted-compaction.md`

**Not consumable yet** (as of September 2026): ADR-002 status "Proposed"; no
PromQL anywhere; no SQL/metrics query endpoint in `quickwit-serve` (DataFusion
layer is internal); no user-facing docs; gaps ledger lists no per-point dedup,
no multi-level caching, no leading-edge prioritization. Unclear whether any of
it is usable in v0.9.0 (July 2026).

### Alternatives evaluated for an interim backend (rejected — we wait instead)
| Option | Notes |
|---|---|
| **VictoriaMetrics** | Best mature single-binary option (Apache-2.0, native OTLP), but OSS is local-disk only — and it's a second storage dependency |
| **GreptimeDB** | Best architectural fit (single binary, OTLP-native, S3/GCS/Azure in OSS), but young — and a second storage dependency |
| **Prometheus 3.x as push sink** | Boring and solid (native OTLP ingest), but local-disk, single-node, no retention story |
| **ClickHouse** | Would compete with the Quickwit decision rather than complement it |

### Adoption criteria (revisit when all hold)
- OTLP metrics ingest wired end-to-end in a tagged Quickwit release
- A public, stable query surface (DataFusion SQL or PromQL over HTTP)
- User-facing documentation / config for metrics indexes
When that lands, the metrics module translates `queryMetrics` into that API and
the deploy story stays "point at Quickwit and go."

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
Minimal image containing:
- Zig backend binary
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
