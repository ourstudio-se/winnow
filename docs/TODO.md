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
- [x] **Configurable log columns** — sidebar column selector with drag-and-drop reordering (`@dnd-kit`), pseudo columns (Timestamp, Severity, Service, Message, Trace) with pretty renderers, data field discovery from fetched documents, localStorage persistence, `SidebarPanelContext` for view→sidebar injection
- [x] **Load more (logs + traces)** — timestamp-cursor pagination ("load more" button at bottom of list); narrows within existing time range so it can never exceed time picker bounds; logs cursor on `timestamp_nanos`, traces cursor on `span_start_timestamp_nanos`; accumulated spans re-grouped into traces on each load
- [x] **Resizable table columns** — drag-to-resize handles on log and trace table headers, `table-layout: fixed`, pixel widths persisted in localStorage, horizontal scroll when columns exceed viewport; shared `ResizeHandle` component
- [x] **Elasticsearch-style time picker** — Popover-based picker with quick presets (15m–30d + All time) on left panel and absolute From/To datetime-local inputs on right panel; supports relative, absolute, and "all time" selections; backward-compatible URL encoding (`?time=1h`, `?time=abs:...`, `?time=all`); persisted via URL + localStorage
- [x] **Sortable log columns** — clickable column headers with sort indicators (▲/▼); cycles desc → asc → reset; backend sort via Quickwit `sort_by`; cursor pagination for default timestamp sort, `start_offset` for custom sorts; sort preference persisted in localStorage
- [x] **Raw query mode** — toggle on FilterBar switches between chip-based filters and a freeform Tantivy query input; URL-driven via `q` param (presence = raw mode); Ctrl+Enter or Run button submits; raw query wrapped in parens to preserve AND-join with time range; cross-view links (Logs→Traces, Traces→Service Map) carry `q` param
- [x] **Raw query autocomplete** — token-at-cursor parsing suggests field names (from discovered fields) and values (via terms agg, cached per field); keyboard nav (Arrow/Tab/Enter/Escape); absolute-positioned dropdown; value insertion with quoting; `tantivy-tokens.ts` pure parsing module + `RawQueryInput` component
- [x] **Time histogram** — Kibana-style bar chart between FilterBar and data table in logs + traces views; uses Quickwit `histogram` agg on u64 nanosecond timestamp fields; auto-sized "nice" intervals (1s–1d); plain SVG bars with drag-to-select that zooms the time range; tooltip on hover; shared `time.ts` module extracted from FilterBar; FilterBar syncs external URL `time` param changes; second-precision absolute time serialization
- [ ] Verify: can see service map with real edges, click through to traces and logs

## Index Metadata Endpoint

- [x] `GET /api/v1/indexes/{index}` backend route — proxies Quickwit index metadata
- [x] `getIndexMetadata()` in `quickwit.zig` — GET request, returns raw response + status
- [x] `extractMetadataIndex` extractor + `handleIndexMetadata` handler in `api.zig`
- [x] Unit tests for `extractMetadataIndex` (valid paths, edge cases)
- [x] `getIndexMetadata()` client function in `frontend/src/lib/api.ts`
- [x] Verify: manual test with running Quickwit (`curl /api/v1/traces/metadata`)

## KDL Config, Schema Validation, Retention, Dynamic Indexes

- [x] Add kdl-zig dependency (`build.zig.zon`, `build.zig`, nix lock)
- [x] Create `index_schema.zig` — shared `FieldMapping` type + `buildIndexConfig` JSON builder
- [x] Restructure `otel_index.zig` and `otel_logs_index.zig` — structured field data instead of raw JSON strings
- [x] Create `config.zig` — KDL config parsing, env var override, CLI `--config` flag, defaults (`winnow-traces-v0_1`, `winnow-logs-v0_1`)
- [x] Create `schema_validation.zig` — `validateSchema` (field type/tokenizer checks), `checkRetention` (warn on mismatch)
- [x] Rewire `main.zig` — new startup flow: parse CLI → load config → validate/create indexes
- [x] Update `api.zig` — `IndexConfig` struct, `isAllowedIndex` helper, index list returns `{"traces":"...","logs":"..."}`
- [x] Rename env vars: `OTEL_TRACES_INDEX`/`OTEL_LOGS_INDEX` → `WINNOW_TRACES_INDEX`/`WINNOW_LOGS_INDEX`
- [x] ~~Frontend: `IndexProvider` context, `useIndexes()` hook, all views use dynamic index names~~ (replaced by stable API endpoints)
- [x] Update integration test — new index names, new index list response format
- [ ] Verify: `zig build test` passes
- [ ] Verify: `zig build run` with no config starts with default indexes
- [ ] Verify: frontend loads and all views work
- [ ] Verify: `nix build` succeeds

## Configurable Serve Section (Collector/API Split)

- [x] Add `Listener` and `ServeConfig` types to `config.zig`
- [x] Add `getIntProp` helper for parsing integer KDL properties
- [x] Parse `serve` block in KDL config (children enable components, `port` property per child)
- [x] Add `serve` field to `Config` with backward-compatible defaults (both on 8080)
- [x] Config tests: both components + ports, collector-only, empty serve block error, default, port-as-string, default port
- [x] Add `ServerRole` struct and `acceptLoop` function to `main.zig`
- [x] Role-gated routing in `handleConnection` (disabled components return 404)
- [x] Multi-port startup: single server when same port, two servers in separate threads when different ports
- [x] Update README.md with serve block documentation
- [ ] Verify: `zig build test` passes
- [ ] Verify: `zig build run` with no config — backward compatible, everything on 8080
- [ ] Verify: `zig build run` with serve block (collector-only) — only collector endpoints respond
- [ ] Verify: `zig build run` with split ports — both components on respective ports

## Stable API Endpoints (replace dynamic index routing)

- [x] Rewrite `api.zig` — fixed routes `/api/v1/{traces,logs}/{search,metadata}`, remove `isAllowedIndex`, `extractSearchIndex`, `extractMetadataIndex`, `handleIndexList`
- [x] Rewrite `api.ts` — `searchTraces()`, `searchLogs()`, `getTracesMetadata()`, `getLogsMetadata()`, remove `listIndexes`, `IndexMap`, `IndexId`
- [x] Delete `index-context.tsx` — no more `IndexProvider` / `useIndexes()`
- [x] Update `layout.tsx` — remove `IndexProvider` wrapper
- [x] Update all frontend views — `service-map`, `traces`, `logs`, `trace-detail`, `operations-drilldown` use new API functions
- [x] Update `filter-bar.tsx` and `time-histogram.tsx` — `index: "traces" | "logs"` prop, select right search/metadata function
- [x] Update integration test — new API paths, replace old index-list/unknown-index tests with metadata test
- [ ] Verify: `zig build test` passes
- [ ] Verify: `pnpm build` succeeds with no TS errors
- [ ] Verify: frontend loads instantly (no "Connecting..." spinner)

## Dev Tooling

- [x] `docker-compose.yml` — Quickwit v0.9.0-rc with persistent volume (ports 7290/7291)
- [x] `scripts/generate-data.py` — OTel data generator simulating 5-service topology with ~10% error injection

## Phase 7: Single Binary Packaging

- [x] Build frontend (`pnpm build`) and embed dist/ into the Zig binary via `@embedFile`
- [x] `scripts/embed-frontend.sh` generates `static_assets.zig` from frontend dist
- [x] Serve embedded assets from `handleStatic()` with correct MIME types and cache headers
- [x] SPA fallback: unrecognized paths serve `index.html` for client-side routing
- [x] `packages.frontend` nix derivation builds React app via pnpm
- [x] `packages.default` nix derivation embeds frontend + builds single static binary
- [x] Verify: `nix build` produces 8.7MB statically-linked binary with embedded frontend
