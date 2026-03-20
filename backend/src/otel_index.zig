/// Quickwit index configuration for OpenTelemetry traces.
/// Matches the otel-traces-v0_9 schema from Quickwit's built-in OTLP support.
pub const index_id = "otel-traces-v0_9";

pub const config =
    \\{
    \\  "version": "0.9",
    \\  "index_id": "otel-traces-v0_9",
    \\  "doc_mapping": {
    \\    "mode": "strict",
    \\    "tag_fields": ["service_name"],
    \\    "field_mappings": [
    \\      {
    \\        "name": "trace_id",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_id",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "parent_span_id",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": false
    \\      },
    \\      {
    \\        "name": "service_name",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "resource_attributes",
    \\        "type": "json",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "resource_dropped_attributes_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "span_name",
    \\        "type": "text",
    \\        "tokenizer": "default",
    \\        "fast": false
    \\      },
    \\      {
    \\        "name": "span_kind",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_start_timestamp_nanos",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_end_timestamp_nanos",
    \\        "type": "u64",
    \\        "fast": false
    \\      },
    \\      {
    \\        "name": "span_duration_millis",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_attributes",
    \\        "type": "json",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_dropped_attributes_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "span_dropped_events_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "span_dropped_links_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "span_status",
    \\        "type": "json",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "events",
    \\        "type": "array<json>"
    \\      },
    \\      {
    \\        "name": "event_names",
    \\        "type": "array<text>",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "links",
    \\        "type": "array<json>"
    \\      },
    \\      {
    \\        "name": "is_root",
    \\        "type": "bool",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_fingerprint",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      }
    \\    ]
    \\  },
    \\  "indexing_settings": {
    \\    "commit_timeout_secs": 5
    \\  },
    \\  "search_settings": {
    \\    "default_search_fields": ["service_name", "span_name", "event_names"]
    \\  }
    \\}
;
