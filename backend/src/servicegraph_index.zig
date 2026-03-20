/// Quickwit index configuration for service graph edge documents.
/// Each CLIENT/PRODUCER span produces one edge doc linking source → dest.
pub const index_id = "servicegraph";

pub const config =
    \\{
    \\  "version": "0.9",
    \\  "index_id": "servicegraph",
    \\  "doc_mapping": {
    \\    "mode": "strict",
    \\    "tag_fields": ["source", "dest"],
    \\    "field_mappings": [
    \\      {
    \\        "name": "source",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "dest",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "operation",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "span_kind",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "duration_ms",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "is_error",
    \\        "type": "bool",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "timestamp_nanos",
    \\        "type": "u64",
    \\        "fast": true
    \\      },
    \\      {
    \\        "name": "trace_id",
    \\        "type": "text",
    \\        "tokenizer": "raw",
    \\        "fast": false
    \\      }
    \\    ]
    \\  },
    \\  "indexing_settings": {
    \\    "commit_timeout_secs": 5
    \\  },
    \\  "search_settings": {
    \\    "default_search_fields": ["source", "dest"]
    \\  }
    \\}
;
