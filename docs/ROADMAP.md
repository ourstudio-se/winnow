# Roadmap

## Iteration 1: "It Works"

Get the basic loop running: ingest traces and logs, display them, show a service graph.

- [ ] Nix flake with devShell (Zig, Node, Quickwit)
- [ ] Zig project skeleton with HTTP server (std.http or httpz)
- [ ] OTLP HTTP receiver (traces + logs) that stores in Quickwit
- [ ] Frontend skeleton (React + shadcn, Vite)
- [ ] Service Map view — read servicegraph index, render node graph
- [ ] Traces view — search Quickwit, display trace timeline
- [ ] Logs view — search Quickwit logs, link to associated traces
- [ ] Backend serves frontend assets

## Iteration 2: "It's Useful"

Replace Grafana in the fsg-mono telemetry stack.

- [ ] Jaeger gRPC SpanReader — Quickwit-backed trace reads
- [ ] Jaeger gRPC DependenciesReader — from service graph index
- [ ] Headless mode (Jaeger API only, no UI)
- [ ] Service Detail view — per-service metrics over time
- [ ] Connected navigation (service map → traces → logs → spans, all clickable)
- [ ] Docker image build (Nix-based, FROM scratch)

## Iteration 3: "It's Good"

Polish, alerting, multi-tenancy groundwork.

- [ ] Alerting (evaluate: embedded Alertmanager vs custom)
- [ ] Configurable metrics storage backend (local / S3 / GCS / Azure)
- [ ] Multi-tenant data isolation (prep for SaaS)
- [ ] Saved views / bookmarks (not "dashboards" — just saved filter states)
- [ ] Error aggregation (group similar errors, show frequency)

## Iteration 4: "It's a Product"

- [ ] Auth (OIDC/OAuth2)
- [ ] Team/org management
- [ ] Usage-based billing hooks
- [ ] Public documentation
- [ ] Landing page
