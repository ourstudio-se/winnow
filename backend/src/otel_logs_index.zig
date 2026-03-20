/// Quickwit index configuration for OpenTelemetry logs.
/// Matches the otel-logs-v0_9 schema from Quickwit's built-in OTLP support.
pub const index_id = "otel-logs-v0_9";

pub const config =
    \\{
    \\  "version": "0.9",
    \\  "index_id": "otel-logs-v0_9",
    \\  "doc_mapping": {
    \\    "mode": "strict",
    \\    "tag_fields": ["service_name"],
    \\    "field_mappings": [
    \\      {
    \\        "name": "timestamp_nanos",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "observed_timestamp_nanos",
    \\        "type": "u64"
    \\      },
    \\      {
    \\        "name": "service_name",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "severity_text",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "severity_number",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "body",
    \\        "type": "json",
    \\        "tokenizer": "default"
    \\      },
    \\      {
    \\        "name": "attributes",
    \\        "type": "json",
    \\        "tokenizer": "raw"
    \\      },
    \\      {
    \\        "name": "dropped_attributes_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
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
    \\        "name": "trace_flags",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "resource_attributes",
    \\        "type": "json",
    \\        "tokenizer": "raw"
    \\      },
    \\      {
    \\        "name": "resource_dropped_attributes_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "scope_name",
    \\        "type": "text",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "scope_version",
    \\        "type": "text",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "scope_attributes",
    \\        "type": "json",
    \\        "indexed": false
    \\      },
    \\      {
    \\        "name": "scope_dropped_attributes_count",
    \\        "type": "u64",
    \\        "indexed": false
    \\      }
    \\    ]
    \\  },
    \\  "indexing_settings": {
    \\    "commit_timeout_secs": 5
    \\  },
    \\  "search_settings": {
    \\    "default_search_fields": ["body"]
    \\  }
    \\}
;
