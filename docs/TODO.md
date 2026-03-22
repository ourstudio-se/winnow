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

## Phase 4: Service Graph (derived from traces)

- [x] ~~Servicegraph index removed~~ — service map now queries the traces index directly
- [x] Frontend derives edges from CLIENT/PRODUCER spans (span_kind 3/4) at query time
- [x] Destination resolved client-side via `peer.service` → `server.address` → `net.peer.name` → `http.host` fallback chain
- [x] FilterBar uses native Quickwit `start_timestamp`/`end_timestamp` instead of nanosecond range queries
- [x] Integration test verifies CLIENT spans with `peer.service` attribute
- [x] Service map uses server-side nested terms aggs (`max_hits: 0`) instead of raw-hit client-side aggregation
- [x] Error attribution: source-based (errors attributed to the calling service, not the destination)
- [x] Implicit leaf detection: nodes like postgres/redis that only appear as `peer.service` destinations are detected and drilldown queries adjusted to query CLIENT spans targeting them
- [x] Simplified to `peer.service` only (dropped 4-key fallback chain)

## Phase 4b: OTLP Log Ingest

- [x] Vendor OTLP log proto files (`logs/v1/logs.proto`, `collector/logs/v1/logs_service.proto`)
- [x] Add logs proto to `build.zig` protoc invocation
- [x] Create `src/otel_logs_index.zig` — otel-logs-v0_9 index schema
- [x] Add `LogDoc` struct and `transformLogsToNdjson` to `ingest.zig`
- [x] Add `handleLogs` handler in `ingest.zig`
- [x] Make index names configurable via env vars (`OTEL_TRACES_INDEX`, `OTEL_LOGS_INDEX`)
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
  - Index allowlist restricts access to `otel-traces-v0_9`, `otel-logs-v0_9`
  - Unknown indexes get 404, wrong methods get 405
- [x] Wire `api.zig` into `main.zig` — replace `handleApi` stub, pass `allowed_indexes` from `IndexConfig`
- [x] Unit tests: index ID extraction, allowed-index validation
- [x] Verify: `zig build test` passes (26/26 tests)
- [x] Integration tests: trace search, trace detail by ID, log search, unknown index 404, index list
- [x] Verify: `nix build .#checks.x86_64-linux.integration` passes

## Phase 6a: Frontend Scaffold

- [x] Scaffold React app in `frontend/` — Vite + TypeScript + pnpm
- [x] Install and configure shadcn/ui (New York/Nova preset, Zinc palette, Tailwind v4)
- [x] Install React Router v7 and @xyflow/react
- [x] Configure Vite dev proxy (`/api` and `/v1` → `localhost:8080`)
- [x] Create typed API client (`src/lib/api.ts`) — `search()`, `listIndexes()`
- [x] Create layout with sidebar nav ("Winnow" branding, 3 nav items with Lucide icons)
- [x] Create router with 3 routes: `/` (Service Map), `/traces`, `/logs`
- [x] Create placeholder views for all 3 routes
- [x] Dark mode only (`<html class="dark">`)
- [x] Verify: `pnpm build` succeeds with no TS errors

## Phase 6b–6d: Frontend Views (TODO)

- [x] **Service Map view** — fetch service graph, render with React Flow
- [x] **Service Map filter bar** — metadata-driven field filters + time range picker
- [x] **FilterBar redesign** — "Add filter" chip flow with field picker popover, nested JSON key discovery via doc sampling, dot-escaping for Quickwit queries
- [x] **FilterBar value autocomplete** — terms aggregation populates suggested values when selecting a field, combobox-style picker with search filtering and custom value entry
- [x] **FilterBar base query scoping** — autocomplete (terms agg + field discovery) scoped to the view's base query (e.g. CLIENT/PRODUCER spans only on service map)
- [x] **Traces view** — trace list with FilterBar + grouped table, full-page trace detail with span waterfall timeline and detail panel
- [x] **Service Map context menu** — single-click node opens context menu (show logs, show traces, operations overview, errors-only conditionally shown based on service error count)
- [x] **Operations drilldown panel** — right-side panel on service map; errored and OK operations shown as separate rows (never merged), each row navigates to traces with service + fingerprint + status filter
- [x] **Traces fingerprint + status filters** — `fingerprint` and `status` URL params filter traces, shown as dismissable chips (status chip color-coded red/green)
- [x] **Traces view filter fixes** — fixed race condition (FilterBar state ref prevents no-time-range fetches), removed redundant service_name filters via `additionalHiddenFields`, fixed service name click preserving URL params, fixed "Show traces" context menu for implicit nodes (uses `peer` param), hidden "Show logs" for implicit nodes
- [x] **Persistent time preset** — time picker selection persists across views via URL param (`time`) + localStorage fallback; service map race condition fixed with filterBarStateRef guard; removed unused `startTimestamp`/`endTimestamp` from FilterState and SearchRequest
- [x] **Cross-view service/peer/trace filters** — "Service Map" links from traces list and trace detail carry `service`, `peer`, and `trace` URL params; service map reads them, scopes all 4 queries, shows dismissable chips, hides from FilterBar field picker
- [x] **Unified FilterBar URL param filters** — URL param filters (service, peer, fingerprint, status, trace) merged into FilterBar via `urlFilters` prop; single filter row with reactive chips, removed duplicate filter state/clear functions/chip bar from views
- [x] **All filters URL-persisted** — eliminated dual filter system (local state + URL pseudo-filters); every filter is now a `f=field:value` URL param, persisted across navigation; removed `UrlFilterConfig`, `urlFilters` prop, and all view-specific filter configs; all cross-view links use `f=` params
- [x] **Logs view** — search bar + table listing logs, link to associated trace
- [ ] Verify: can see service map with real edges, click through to traces and logs

## Index Metadata Endpoint

- [x] `GET /api/v1/indexes/{index}` backend route — proxies Quickwit index metadata
- [x] `getIndexMetadata()` in `quickwit.zig` — GET request, returns raw response + status
- [x] `extractMetadataIndex` extractor + `handleIndexMetadata` handler in `api.zig`
- [x] Unit tests for `extractMetadataIndex` (valid paths, edge cases)
- [x] `getIndexMetadata()` client function in `frontend/src/lib/api.ts`
- [ ] Verify: manual test with running Quickwit (`curl /api/v1/indexes/otel-traces-v0_9`)

## Dev Tooling

- [x] `docker-compose.yml` — Quickwit v0.9.0-rc with persistent volume (ports 7290/7291)
- [x] `scripts/generate-data.py` — OTel data generator simulating 5-service topology with ~10% error injection

## Phase 7: Single Binary Packaging

- [ ] Build frontend (`pnpm build`) and embed dist/ into the Zig binary via `@embedFile` or `std.Build` install step
- [ ] Serve embedded assets from `handleStatic()` with correct MIME types
- [ ] Add `packages.default` to `flake.nix` that builds the full binary
- [ ] Verify: `nix build && ./result/bin/telemetry-experiment` serves the UI and API from one process
