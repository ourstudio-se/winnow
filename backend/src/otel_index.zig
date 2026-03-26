/// Quickwit index schema for OpenTelemetry traces.
/// Based on the otel-traces-v0_9 schema from Quickwit's built-in OTLP support.
const index_schema = @import("index_schema.zig");

pub const schema = index_schema.IndexSchema{
    .field_mappings = &field_mappings,
    .tag_fields = &.{"service_name"},
    .default_search_fields = &.{ "service_name", "span_name", "event_names" },
};

pub const field_mappings = [_]index_schema.FieldMapping{
    .{ .name = "trace_id", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "span_id", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "parent_span_id", .type = "text", .tokenizer = "raw", .fast = false },
    .{ .name = "service_name", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "resource_attributes", .type = "json", .tokenizer = "raw", .fast = true },
    .{ .name = "resource_dropped_attributes_count", .type = "u64", .indexed = false },
    .{ .name = "span_name", .type = "text", .tokenizer = "default", .fast = false },
    .{ .name = "span_kind", .type = "u64", .fast = true },
    .{ .name = "span_start_timestamp_nanos", .type = "u64", .fast = true },
    .{ .name = "span_end_timestamp_nanos", .type = "u64", .fast = false },
    .{ .name = "span_duration_millis", .type = "u64", .fast = true },
    .{ .name = "span_attributes", .type = "json", .tokenizer = "raw", .fast = true },
    .{ .name = "span_dropped_attributes_count", .type = "u64", .indexed = false },
    .{ .name = "span_dropped_events_count", .type = "u64", .indexed = false },
    .{ .name = "span_dropped_links_count", .type = "u64", .indexed = false },
    .{ .name = "span_status", .type = "json", .fast = true },
    .{ .name = "events", .type = "array<json>" },
    .{ .name = "event_names", .type = "array<text>", .tokenizer = "raw", .fast = true },
    .{ .name = "links", .type = "array<json>" },
    .{ .name = "is_root", .type = "bool", .fast = true },
    .{ .name = "span_fingerprint", .type = "text", .tokenizer = "raw", .fast = true },
};

const std = @import("std");

test "trace schema field count" {
    try std.testing.expectEqual(21, field_mappings.len);
}

test "trace schema buildIndexConfig" {
    const allocator = std.testing.allocator;
    const json = try index_schema.buildIndexConfig(allocator, "winnow-traces-v0_1", schema, null);
    defer allocator.free(json);

    // Verify valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("winnow-traces-v0_1", root.get("index_id").?.string);

    const mappings = root.get("doc_mapping").?.object.get("field_mappings").?.array;
    try std.testing.expectEqual(21, mappings.items.len);
}
