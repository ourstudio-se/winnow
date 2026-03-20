# TODO — Iteration 1: "It Works"

Goal: ingest traces and logs from an OTel-instrumented app, store in Quickwit, display a service map, trace timeline, and log viewer.

## Phase 1: Dependencies & Proto Compilation

- [x] Add zig-protobuf to `build.zig.zon` and wire into build
- [x] Vendor OTLP proto definitions (`opentelemetry/proto/collector/trace/v1/trace_service.proto` + deps)
- [x] Add build step that compiles `.proto` → Zig structs via zig-protobuf's `protoc-gen-zig`
- [x] Verify: `zig build` succeeds and generated structs are importable from `main.zig`

## Phase 2: Quickwit Client

- [x] Create `src/quickwit.zig` — HTTP client wrapping Quickwit's REST API
  - `indexExists`, `createIndex`, `ensureIndex` — index lifecycle management
  - `ingest(index_id, ndjson_body)` — POST NDJSON to Quickwit's ingest API
  - `search(index_id, query_json)` — POST to search API, return raw response
- [x] Create `src/otel_index.zig` — otel-traces-v0_9 index schema as comptime JSON
- [x] Initialize Quickwit client on startup, ensure trace index exists
- [x] Read `QUICKWIT_URL` from env, default `http://localhost:7280`
- [x] Verify: `zig build test` passes

## Phase 3: OTLP Trace Ingest

- [x] Add route `POST /v1/traces` to the HTTP server
- [x] Decode incoming protobuf body using generated OTLP structs
- [x] Transform OTLP spans → flat JSON docs matching otel-traces-v0_9 schema
- [x] Ingest transformed docs via `quickwit.ingest()` as NDJSON
- [x] Return proper OTLP ExportTraceServiceResponse
- [x] Verify: point an OTel SDK (e.g. `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:8080`) at the server, traces appear in Quickwit
- [x] NixOS VM integration test (`nix build .#checks.x86_64-linux.integration`) — spins up Quickwit in Docker, sends traces via Python OTel SDK, verifies spans in Quickwit search

## Phase 4: Service Graph Computation

- [x] Define Quickwit index schema for `servicegraph` (fields: `source`, `dest`, `operation`, `span_kind`, `duration_ms`, `is_error`, `timestamp`, `trace_id`)
- [x] Create index on startup if it doesn't exist
- [x] After ingesting a trace batch, extract service-to-service edges from CLIENT/PRODUCER spans (dest resolved via `peer.service` → `server.address` → `net.peer.name` → `http.host` fallback chain)
- [x] Per-span edge documents (not pre-aggregated) — aggregation at query time via Quickwit
- [x] Edge ingest is fire-and-forget (failures logged, don't fail trace ingest)
- [x] Unit tests for edge extraction
- [x] Verify: NixOS VM integration test passes with servicegraph assertions

## Phase 4b: OTLP Log Ingest

- [x] Vendor OTLP log proto files (`logs/v1/logs.proto`, `collector/logs/v1/logs_service.proto`)
- [x] Add logs proto to `build.zig` protoc invocation
- [x] Create `src/otel_logs_index.zig` — otel-logs-v0_9 index schema
- [x] Add `LogDoc` struct and `transformLogsToNdjson` to `ingest.zig`
- [x] Add `handleLogs` handler in `ingest.zig`
- [x] Make index names configurable via env vars (`OTEL_TRACES_INDEX`, `OTEL_LOGS_INDEX`, `SERVICEGRAPH_INDEX`)
- [x] Add `IndexConfig` struct to `main.zig`, pass index IDs to handlers
- [x] Add `POST /v1/logs` route
- [x] Ensure logs index exists on startup
- [x] Unit tests for `transformLogsToNdjson` (empty request, single log record)
- [x] Verify: `zig build test` passes
- [x] Verify: NixOS VM integration test passes with log assertions

## Phase 5: Quickwit Search Proxy

- [x] Add `searchRaw()` to `quickwit.zig` — returns body + HTTP status (for proxy forwarding)
- [x] Create `src/api.zig` — thin proxy module (~100 lines)
  - `POST /api/v1/{index}/search` — validate index in allowed list, forward to Quickwit, return response verbatim
  - `GET /api/v1/indexes` — return JSON array of allowed index IDs
  - Index allowlist restricts access to `otel-traces-v0_9`, `otel-logs-v0_9`, `servicegraph`
  - Unknown indexes get 404, wrong methods get 405
- [x] Wire `api.zig` into `main.zig` — replace `handleApi` stub, pass `allowed_indexes` from `IndexConfig`
- [x] Unit tests: index ID extraction, allowed-index validation
- [x] Verify: `zig build test` passes (26/26 tests)
- [x] Integration tests: trace search, trace detail by ID, log search, service graph search, unknown index 404, index list
- [x] Verify: `nix build .#checks.x86_64-linux.integration` passes

## Phase 6: Frontend

- [ ] Scaffold React app in `frontend/` — Vite + TypeScript + pnpm
- [ ] Install and configure shadcn/ui
- [ ] Pick visualization lib (ECharts or React Flow) and add it
- [ ] **Service Map view** — fetch `/api/graph`, render nodes (services) and edges (calls) with request rate labels
- [ ] **Traces view** — search bar + table listing traces from `/api/traces`, click to expand span timeline
- [ ] **Logs view** — search bar + table listing logs from `/api/logs`, link to associated trace
- [ ] Basic layout: sidebar with Service Map / Traces / Logs nav, main content area
- [ ] Verify: can see service map with real edges, click through to traces and logs

## Phase 7: Single Binary Packaging

- [ ] Build frontend (`pnpm build`) and embed dist/ into the Zig binary via `@embedFile` or `std.Build` install step
- [ ] Serve embedded assets from `handleStatic()` with correct MIME types
- [ ] Add `packages.default` to `flake.nix` that builds the full binary
- [ ] Verify: `nix build && ./result/bin/telemetry-experiment` serves the UI and API from one process
