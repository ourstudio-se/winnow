const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FieldMapping = struct {
    name: []const u8,
    type: []const u8,
    tokenizer: ?[]const u8 = null,
    fast: ?bool = null,
    indexed: ?bool = null,
    input_formats: ?[]const []const u8 = null,
    output_format: ?[]const u8 = null,
    fast_precision: ?[]const u8 = null,
};

pub const IndexSchema = struct {
    field_mappings: []const FieldMapping,
    tag_fields: []const []const u8,
    default_search_fields: []const []const u8,
    timestamp_field: ?[]const u8 = null,
};

/// Build Quickwit index config JSON at runtime.
/// Caller owns the returned slice (allocated in `allocator`).
pub fn buildIndexConfig(
    allocator: Allocator,
    index_id: []const u8,
    schema: IndexSchema,
    retention: ?[]const u8,
) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    try w.writeAll("{\"version\":\"0.9\",\"index_id\":\"");
    try w.writeAll(index_id);
    try w.writeAll("\",\"doc_mapping\":{\"mode\":\"strict\",\"tag_fields\":[");

    for (schema.tag_fields, 0..) |tf, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(tf);
        try w.writeByte('"');
    }

    try w.writeAll("],\"field_mappings\":[");

    for (schema.field_mappings, 0..) |fm, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try w.writeAll(fm.name);
        try w.writeAll("\",\"type\":\"");
        try w.writeAll(fm.type);
        try w.writeByte('"');

        if (fm.tokenizer) |tok| {
            try w.writeAll(",\"tokenizer\":\"");
            try w.writeAll(tok);
            try w.writeByte('"');
        }

        if (fm.fast) |fast| {
            if (fast) {
                try w.writeAll(",\"fast\":true");
            } else {
                try w.writeAll(",\"fast\":false");
            }
        }

        if (fm.indexed) |indexed| {
            if (indexed) {
                try w.writeAll(",\"indexed\":true");
            } else {
                try w.writeAll(",\"indexed\":false");
            }
        }

        if (fm.input_formats) |formats| {
            try w.writeAll(",\"input_formats\":[");
            for (formats, 0..) |fmt, fi| {
                if (fi > 0) try w.writeByte(',');
                try w.writeByte('"');
                try w.writeAll(fmt);
                try w.writeByte('"');
            }
            try w.writeByte(']');
        }

        if (fm.output_format) |fmt| {
            try w.writeAll(",\"output_format\":\"");
            try w.writeAll(fmt);
            try w.writeByte('"');
        }

        if (fm.fast_precision) |prec| {
            try w.writeAll(",\"fast_precision\":\"");
            try w.writeAll(prec);
            try w.writeByte('"');
        }

        try w.writeByte('}');
    }

    try w.writeAll("]");

    if (schema.timestamp_field) |tsf| {
        try w.writeAll(",\"timestamp_field\":\"");
        try w.writeAll(tsf);
        try w.writeByte('"');
    }

    try w.writeAll("},\"indexing_settings\":{\"commit_timeout_secs\":5},\"search_settings\":{\"default_search_fields\":[");

    for (schema.default_search_fields, 0..) |sf, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(sf);
        try w.writeByte('"');
    }

    try w.writeAll("]}");

    if (retention) |period| {
        try w.writeAll(",\"retention\":{\"period\":\"");
        try w.writeAll(period);
        try w.writeAll("\",\"schedule\":\"daily\"}");
    }

    try w.writeByte('}');

    return try buf.toOwnedSlice();
}

// -- Tests --

test "buildIndexConfig minimal" {
    const allocator = std.testing.allocator;

    const schema = IndexSchema{
        .field_mappings = &.{
            .{ .name = "trace_id", .type = "text", .tokenizer = "raw", .fast = true },
            .{ .name = "count", .type = "u64", .indexed = false },
        },
        .tag_fields = &.{"service_name"},
        .default_search_fields = &.{"trace_id"},
    };

    const json = try buildIndexConfig(allocator, "test-index", schema, null);
    defer allocator.free(json);

    // Verify it's valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("0.9", root.get("version").?.string);
    try std.testing.expectEqualStrings("test-index", root.get("index_id").?.string);

    // No retention block
    try std.testing.expect(root.get("retention") == null);
}

test "buildIndexConfig with datetime and timestamp_field" {
    const allocator = std.testing.allocator;

    const schema = IndexSchema{
        .field_mappings = &.{
            .{ .name = "ts", .type = "datetime", .fast = true, .input_formats = &.{"unix_timestamp"}, .output_format = "unix_timestamp_nanos", .fast_precision = "milliseconds" },
            .{ .name = "body", .type = "text" },
        },
        .tag_fields = &.{},
        .default_search_fields = &.{"body"},
        .timestamp_field = "ts",
    };

    const json = try buildIndexConfig(allocator, "dt-index", schema, null);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const doc_mapping = root.get("doc_mapping").?.object;

    // timestamp_field
    try std.testing.expectEqualStrings("ts", doc_mapping.get("timestamp_field").?.string);

    // datetime field properties
    const fields = doc_mapping.get("field_mappings").?.array;
    const ts_field = fields.items[0].object;
    try std.testing.expectEqualStrings("datetime", ts_field.get("type").?.string);
    try std.testing.expectEqualStrings("unix_timestamp_nanos", ts_field.get("output_format").?.string);
    try std.testing.expectEqualStrings("milliseconds", ts_field.get("fast_precision").?.string);

    const input_fmts = ts_field.get("input_formats").?.array;
    try std.testing.expectEqual(1, input_fmts.items.len);
    try std.testing.expectEqualStrings("unix_timestamp", input_fmts.items[0].string);
}

test "buildIndexConfig with retention" {
    const allocator = std.testing.allocator;

    const schema = IndexSchema{
        .field_mappings = &.{
            .{ .name = "body", .type = "json", .tokenizer = "default" },
        },
        .tag_fields = &.{},
        .default_search_fields = &.{"body"},
    };

    const json = try buildIndexConfig(allocator, "my-logs", schema, "90 days");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const ret = root.get("retention").?.object;
    try std.testing.expectEqualStrings("90 days", ret.get("period").?.string);
    try std.testing.expectEqualStrings("daily", ret.get("schedule").?.string);
}
