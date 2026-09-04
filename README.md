# Winnow

An opinionated observability UI built on [Quickwit](https://quickwit.io). Accepts OpenTelemetry traces and logs, stores everything in Quickwit, and provides a single unified interface for navigating your system.

Born from frustration with Grafana's approach to observability. Instead of a general-purpose dashboarding tool that supports every backend and visualization, Winnow does fewer things and does them well. One storage backend, one interface, no configuration pages.

## Screenshots

<p align="center">
  <img src="assets/screenshot1.png" alt="Service map showing service topology with call counts, latencies, and error rates" width="100%">
</p>

The service map is the primary entry point. It shows your service topology with call counts, latencies, and error rates at a glance. Click any node to drill into its traces, logs, or operations.

<p align="center">
  <img src="assets/screenshot3.png" alt="Trace detail view with span waterfall timeline and span metadata" width="100%">
</p>

The trace detail view shows a waterfall timeline of all spans in a trace. Select a span to see its attributes, resource metadata, and associated logs in the right panel.

<p align="center">
  <img src="assets/screenshot2.png" alt="Log viewer with configurable columns, filters, and time histogram" width="100%">
</p>

The log viewer supports configurable columns, filters, sortable headers, and a time histogram. Every log with a trace ID links directly to its trace.

## What it does

Winnow receives OTLP data (traces and logs) over HTTP, transforms it, and ingests it into Quickwit. The frontend provides three connected views: a service map derived from trace data, a trace explorer with span waterfall timelines, and a log viewer. Everything is linked. Click a service to see its traces, click a trace to see its logs, click a log to jump to the span that produced it.

The entire application ships as a single statically-linked binary. The frontend is embedded at build time. Point it at a Quickwit instance and go.

## Stack

The backend is written in Zig. The frontend is React with TypeScript and shadcn/ui. Quickwit is the only external dependency at runtime. Nix handles all build tooling and packaging.

## Running

### With Nix (recommended)

Build and run directly from the repository:

```
nix build
./result/bin/winnow
```

By default the API listens on port 8080 and the collector on port 4318. Quickwit is expected at `http://localhost:7280`. Configure via environment variables:

```
QUICKWIT_URL=http://quickwit.example.com:7280 ./result/bin/winnow
```

You can also run without cloning, directly from a flake reference:

```
nix run github:ourstudio-se/winnow
```

### Sending data

Point any OpenTelemetry SDK at the server's OTLP HTTP endpoint:

```
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:8080
```

The server accepts `POST /v1/traces`, `POST /v1/logs`, and `POST /v1/metrics` in OTLP protobuf format. The metrics endpoint is used by the OTel Collector's servicegraph connector to feed pre-aggregated service edge data.

### Configuration

Configuration is resolved in order: defaults < KDL config file < environment variables.

**Config file** (optional):

```kdl
quickwit url="http://localhost:7280"
traces index="winnow-traces-v0_1" retention="90 days"
logs index="winnow-logs-v0_1" retention="30 days"
edges index="winnow-edges-v0_3" retention="7 days"
```

Pass with `--config`:

```
./result/bin/winnow --config /path/to/winnow.kdl
```

If no `--config` is given, the server looks for `./winnow.kdl` in the working directory. If no file is found, bare defaults are used.

**Serve section** (optional):

The `serve` block controls which components run and on which ports. By default (no `serve` block), both the collector (port 4318) and API (port 8080) are enabled.

```kdl
// Explicit ports (these are the defaults)
serve {
    collector http_port=4318
    api http_port=8080
}
```

Each component also accepts `number_of_workers` (default: 6) to control the number of HTTP worker threads.

This is useful for production deployments where you want to scale the collector (high-throughput ingest) and API (user-facing queries) independently as separate processes.

```kdl
// Collector-only instance
serve {
    collector http_port=4318
}

// API-only instance
serve {
    api http_port=8080
}

// Both on default ports
serve {
    collector
    api
}
```

When a component is disabled, its routes return 404. A `serve` block with no children is an error.

**Environment variables** (override config file values):

```
QUICKWIT_URL            Quickwit base URL (default: http://localhost:7280)
WINNOW_TRACES_INDEX     Quickwit index for traces (default: winnow-traces-v0_1)
WINNOW_LOGS_INDEX       Quickwit index for logs (default: winnow-logs-v0_1)
WINNOW_EDGES_INDEX      Quickwit index for service edges (default: winnow-edges-v0_3)
```

**Startup behavior:**

- If an index doesn't exist, the server creates it (with retention policy if configured).
- If an index already exists, the server validates its schema against the expected field mappings. On a mismatch (wrong field type, missing field, wrong tokenizer) the server exits with an error. Retention mismatches produce a warning but don't prevent startup.

## Development

### Prerequisites

Everything is managed by Nix. Enter the dev shell:

```
nix develop
```

This provides Zig, Node.js, pnpm, protoc, and all other tools needed for development.

### Building locally

Inside the dev shell:

```
cd backend
zig build gen-proto   # generate Zig code from .proto files
zig build             # compile the server
zig build run         # compile and run
zig build test        # run tests
```

The frontend uses Vite with a dev proxy. In a separate terminal:

```
cd frontend
pnpm install
pnpm dev
```

This starts Vite on port 5173 and proxies `/api` and `/v1` requests to the backend on port 8080. During development you work against the Vite dev server and iterate on frontend and backend independently.

### Testing the single binary locally

To test the production build locally without going through `nix build`:

```
cd frontend && pnpm build && cd ..
cd backend
ln -sfn ../../frontend/dist src/frontend-dist
bash ../scripts/embed-frontend.sh src/frontend-dist src/static_assets.zig
zig build run
```

Then visit `http://localhost:8080`.

### Nix flake outputs

```
packages.default      Single binary with embedded frontend
packages.frontend     Frontend dist built via pnpm
devShells.default     Development environment with all tools
checks.integration    NixOS VM integration test (Linux only)
```

### Quickwit for development

A `docker-compose.yml` is provided for running Quickwit locally. The dev shell sets `QUICKWIT_URL=http://localhost:7290` (port 7290 to avoid collisions). A data generator is available as `generate-data` inside the dev shell.

## Project structure

```
backend/              Zig source code and build files
backend/proto/        Vendored OTLP .proto definitions
backend/src/          Server source (main.zig, api.zig, ingest.zig, etc.)
frontend/             React/TypeScript frontend
scripts/              Build and dev tooling scripts
tests/                NixOS VM integration tests
docs/                 Architecture docs, roadmap, and TODO
```

## License

TBD
