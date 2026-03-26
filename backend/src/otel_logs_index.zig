/// Quickwit index schema for OpenTelemetry logs.
/// Based on the otel-logs-v0_9 schema from Quickwit's built-in OTLP support.
const index_schema = @import("index_schema.zig");

pub const schema = index_schema.IndexSchema{
    .field_mappings = &field_mappings,
    .tag_fields = &.{"service_name"},
    .default_search_fields = &.{"body"},
};

pub const field_mappings = [_]index_schema.FieldMapping{
    .{ .name = "timestamp_nanos", .type = "u64", .fast = true },
    .{ .name = "observed_timestamp_nanos", .type = "u64" },
    .{ .name = "service_name", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "severity_text", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "severity_number", .type = "u64", .fast = true },
    .{ .name = "body", .type = "json", .tokenizer = "default" },
    .{ .name = "attributes", .type = "json", .tokenizer = "raw" },
    .{ .name = "dropped_attributes_count", .type = "u64", .indexed = false },
    .{ .name = "trace_id", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "span_id", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "trace_flags", .type = "u64", .indexed = false },
    .{ .name = "resource_attributes", .type = "json", .tokenizer = "raw" },
    .{ .name = "resource_dropped_attributes_count", .type = "u64", .indexed = false },
    .{ .name = "scope_name", .type = "text", .indexed = false },
    .{ .name = "scope_version", .type = "text", .indexed = false },
    .{ .name = "scope_attributes", .type = "json", .indexed = false },
    .{ .name = "scope_dropped_attributes_count", .type = "u64", .indexed = false },
};

const std = @import("std");

test "logs schema field count" {
    try std.testing.expectEqual(17, field_mappings.len);
}

test "logs schema buildIndexConfig" {
    const allocator = std.testing.allocator;
    const json = try index_schema.buildIndexConfig(allocator, "winnow-logs-v0_1", schema, "30 days");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("winnow-logs-v0_1", root.get("index_id").?.string);

    const mappings = root.get("doc_mapping").?.object.get("field_mappings").?.array;
    try std.testing.expectEqual(17, mappings.items.len);

    // Verify retention is present
    const ret = root.get("retention").?.object;
    try std.testing.expectEqualStrings("30 days", ret.get("period").?.string);
}
