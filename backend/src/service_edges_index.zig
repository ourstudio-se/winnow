/// Quickwit index schema for precomputed service-to-service edges.
/// Populated by the OTel Collector's servicegraph connector metrics.
const index_schema = @import("index_schema.zig");

pub const schema = index_schema.IndexSchema{
    .field_mappings = &field_mappings,
    .tag_fields = &.{ "client", "server" },
    .default_search_fields = &.{ "client", "server" },
    .timestamp_field = "timestamp_nanos",
};

pub const field_mappings = [_]index_schema.FieldMapping{
    .{ .name = "timestamp_nanos", .type = "datetime", .fast = true, .input_formats = &.{"unix_timestamp"}, .output_format = "unix_timestamp_nanos", .fast_precision = "milliseconds" },
    .{ .name = "client", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "server", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "connection_type", .type = "text", .tokenizer = "raw", .fast = true },
    .{ .name = "calls", .type = "u64", .fast = true },
    .{ .name = "errors", .type = "u64", .fast = true },
    .{ .name = "client_fingerprint", .type = "array<text>", .tokenizer = "raw", .fast = true },
    .{ .name = "server_fingerprint", .type = "array<text>", .tokenizer = "raw", .fast = true },
};

const std = @import("std");

test "edges schema field count" {
    try std.testing.expectEqual(8, field_mappings.len);
}

test "edges schema buildIndexConfig" {
    const allocator = std.testing.allocator;
    const json = try index_schema.buildIndexConfig(allocator, "winnow-edges-v0_3", schema, null);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("winnow-edges-v0_3", root.get("index_id").?.string);

    const doc_mapping = root.get("doc_mapping").?.object;
    const mappings = doc_mapping.get("field_mappings").?.array;
    try std.testing.expectEqual(8, mappings.items.len);

    // Verify timestamp_field
    try std.testing.expectEqualStrings("timestamp_nanos", doc_mapping.get("timestamp_field").?.string);

    // Verify tag_fields
    const tags = doc_mapping.get("tag_fields").?.array;
    try std.testing.expectEqual(2, tags.items.len);
    try std.testing.expectEqualStrings("client", tags.items[0].string);
    try std.testing.expectEqualStrings("server", tags.items[1].string);
}
