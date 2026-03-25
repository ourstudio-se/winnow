# Winnow

An opinionated observability UI built on [Quickwit](https://quickwit.io). Accepts OpenTelemetry traces and logs, stores everything in Quickwit, and provides a single unified interface for navigating your system.

Born from frustration with Grafana's approach to observability. Instead of a general-purpose dashboarding tool that supports every backend and visualization, Winnow does fewer things and does them well. One storage backend, one interface, no configuration pages.

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
./result/bin/telemetry-experiment
```

By default the server listens on port 8080 and expects Quickwit at `http://localhost:7280`. Configure via environment variables:

```
QUICKWIT_URL=http://quickwit.example.com:7280 ./result/bin/telemetry-experiment
```

You can also run without cloning, directly from a flake reference:

```
nix run github:user/telemetry-experiment
```

### Sending data

Point any OpenTelemetry SDK at the server's OTLP HTTP endpoint:

```
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:8080
```

The server accepts `POST /v1/traces` and `POST /v1/logs` in OTLP protobuf format.

### Configuration

All configuration is via environment variables.

```
QUICKWIT_URL            Quickwit base URL (default: http://localhost:7280)
OTEL_TRACES_INDEX       Quickwit index for traces (default: otel-traces-v0_9)
OTEL_LOGS_INDEX         Quickwit index for logs (default: otel-logs-v0_9)
```

The server creates the required Quickwit indexes on startup if they don't already exist.

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
