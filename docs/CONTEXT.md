# Why This Exists

## Grafana Frustrations (Collected the Hard Way)

This project was born from weeks of trying to build a proper Application Insights-style
service dependency graph in Grafana. Here's what we learned:

### Node Graph Panel is Broken by Design
- The Node Graph panel requires fields with specific `field.name` values (`id`, `title`,
  `mainstat`, `secondarystat`, `color`, `arc__*`, `source`, `target`).
- It checks `field.name` ONLY, never `field.config.displayName`.
- Grafana's rename transformations (`renameByRegex`, `organize`) only change `displayName`,
  not `field.name`. So you literally cannot rename a field to make Node Graph recognize it.
  This is a known bug (#54844) that has been open for years.
- PromQL `label_replace` creates proper `field.name` columns, but only for string values.
  You cannot move a numeric sample value into a label. So you can set string mainstat
  but never numeric mainstat from raw PromQL.
- The `calculateField` transformation destroys the multi-frame structure that Node Graph
  requires (it merges frames).
- Documentation references a "fallback to first numeric field" for mainstat that doesn't
  exist in the actual shipped code (v12.3.3).

### The Tempo Workaround
- We eventually got it working by abusing the Tempo datasource's built-in service graph
  feature, which constructs proper Node Graph DataFrames server-side in TypeScript.
- The Tempo datasource queries Mimir (Prometheus) for OTel servicegraph connector metrics
  and builds frames with correct field names.
- But: the Tempo plugin hardcodes a broken "View traces" link (since we don't have a Tempo
  backend), and you can't disable it without patching Grafana source.

### Jaeger/Quickwit Integration is Half-Baked
- Grafana's Jaeger datasource has a "Dependency Graph" query type that calls Jaeger's
  `/api/dependencies` endpoint.
- Quickwit only implements Jaeger's `SpanReaderPlugin`, NOT `DependenciesReaderPlugin`.
  So the dependency graph is always empty.
- No Jaeger storage backend (Memory, Badger, Cassandra, ES) works with externally
  precomputed dependencies from the OTel servicegraph connector.

### First-Class vs Second-Class Datasources
- Grafana has "Drilldown" sidebar pages (Metrics, Logs, Traces, Profiles) that are
  hardcoded to work with Grafana's own stack (Mimir, Loki, Tempo, Pyroscope).
- If you use anything else (Quickwit, Jaeger, etc.), these pages are broken but still
  visible. You can disable them via feature toggles but it's not obvious.
- The Quickwit datasource plugin works for basic queries but is clearly a second-class
  citizen compared to Loki.

### General UX Problems
- Dashboards are not pinnable in the sidebar (the expandable "Dashboards" menu shows
  Playlists/Snapshots/Library panels, not your actual dashboards).
- There's a `pinNavItems` feature toggle for bookmarks, but it's off by default and
  not discoverable.
- The provisioning system is powerful but the gap between "provisioned" and "UI-managed"
  state creates constant confusion.
- Every feature has 5 ways to configure it, 3 of which conflict with each other.

## The Core Insight

Grafana is a general-purpose dashboarding tool that has grown to accommodate every
possible backend, visualization, and workflow. This generality is its strength for
power users but makes it actively hostile to anyone who just wants to understand
their system.

We want to build the opposite: an opinionated observability UI that does fewer things
but does them well, with Quickwit as a first-class storage backend.
