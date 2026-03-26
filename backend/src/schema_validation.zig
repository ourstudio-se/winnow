const std = @import("std");
const Allocator = std.mem.Allocator;
const index_schema = @import("index_schema.zig");

const log = std.log.scoped(.schema_validation);

pub const Mismatch = union(enum) {
    missing_field: []const u8,
    type_mismatch: struct {
        field: []const u8,
        expected: []const u8,
        actual: []const u8,
    },
    tokenizer_mismatch: struct {
        field: []const u8,
        expected: []const u8,
        actual: []const u8,
    },
};

pub const RetentionMismatch = struct {
    expected: ?[]const u8,
    actual: ?[]const u8,
};

/// Validate that a Quickwit index has the expected schema.
/// `metadata_json` is the raw JSON response from GET /api/v1/indexes/{id}.
/// Returns a slice of mismatches (empty = valid).
pub fn validateSchema(
    arena: Allocator,
    expected: []const index_schema.FieldMapping,
    metadata_json: []const u8,
) ![]const Mismatch {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, metadata_json, .{}) catch {
        return error.InvalidMetadataJson;
    };
    // No deinit needed — arena allocator

    const root = parsed.value.object;
    const index_config = (root.get("index_config") orelse return error.InvalidMetadataJson).object;
    const doc_mapping = (index_config.get("doc_mapping") orelse return error.InvalidMetadataJson).object;
    const field_mappings_val = (doc_mapping.get("field_mappings") orelse return error.InvalidMetadataJson).array;

    // Build a lookup map of actual fields
    var actual_map = std.StringHashMap(std.json.Value).init(arena);
    for (field_mappings_val.items) |fm_val| {
        const fm_obj = fm_val.object;
        const name = (fm_obj.get("name") orelse continue).string;
        try actual_map.put(name, fm_val);
    }

    var mismatches: std.ArrayListUnmanaged(Mismatch) = .{};


    for (expected) |exp| {
        const actual_val = actual_map.get(exp.name) orelse {
            try mismatches.append(arena,.{ .missing_field = exp.name });
            continue;
        };
        const actual_obj = actual_val.object;

        // Check type
        const actual_type = (actual_obj.get("type") orelse {
            try mismatches.append(arena,.{ .missing_field = exp.name });
            continue;
        }).string;

        if (!std.mem.eql(u8, exp.type, actual_type)) {
            try mismatches.append(arena,.{ .type_mismatch = .{
                .field = exp.name,
                .expected = exp.type,
                .actual = actual_type,
            } });
        }

        // Check tokenizer (only if we expect one)
        if (exp.tokenizer) |expected_tok| {
            const actual_tok = if (actual_obj.get("tokenizer")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;

            if (actual_tok) |at| {
                if (!std.mem.eql(u8, expected_tok, at)) {
                    try mismatches.append(arena,.{ .tokenizer_mismatch = .{
                        .field = exp.name,
                        .expected = expected_tok,
                        .actual = at,
                    } });
                }
            }
        }
    }

    return mismatches.items;
}

/// Check if the retention policy matches the configured value.
/// Returns null if they match, a mismatch struct if different.
pub fn checkRetention(
    arena: Allocator,
    configured: ?[]const u8,
    metadata_json: []const u8,
) !?RetentionMismatch {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, metadata_json, .{}) catch {
        return error.InvalidMetadataJson;
    };

    const root = parsed.value.object;
    const index_config = (root.get("index_config") orelse return error.InvalidMetadataJson).object;

    const actual_period: ?[]const u8 = blk: {
        const retention = index_config.get("retention") orelse break :blk null;
        switch (retention) {
            .object => |obj| {
                const period = obj.get("period") orelse break :blk null;
                switch (period) {
                    .string => |s| break :blk s,
                    else => break :blk null,
                }
            },
            .null => break :blk null,
            else => break :blk null,
        }
    };

    // Compare
    if (configured == null and actual_period == null) return null;
    if (configured != null and actual_period != null) {
        if (std.mem.eql(u8, configured.?, actual_period.?)) return null;
    }

    return .{ .expected = configured, .actual = actual_period };
}

// -- Tests --

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

const test_metadata_base =
    \\{"index_config":{"index_id":"test","doc_mapping":{"field_mappings":[
;
const test_metadata_end =
    \\]}}}
;

test "validateSchema matching schema" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        test_metadata_base ++
        \\{"name":"trace_id","type":"text","tokenizer":"raw","fast":true},
        \\{"name":"count","type":"u64","indexed":false}
        ++ test_metadata_end;

    const expected = &[_]index_schema.FieldMapping{
        .{ .name = "trace_id", .type = "text", .tokenizer = "raw", .fast = true },
        .{ .name = "count", .type = "u64", .indexed = false },
    };

    const mismatches = try validateSchema(arena.allocator(), expected, metadata);
    try std.testing.expectEqual(0, mismatches.len);
}

test "validateSchema missing field" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        test_metadata_base ++
        \\{"name":"trace_id","type":"text","tokenizer":"raw"}
        ++ test_metadata_end;

    const expected = &[_]index_schema.FieldMapping{
        .{ .name = "trace_id", .type = "text", .tokenizer = "raw" },
        .{ .name = "span_id", .type = "text", .tokenizer = "raw" },
    };

    const mismatches = try validateSchema(arena.allocator(), expected, metadata);
    try std.testing.expectEqual(1, mismatches.len);
    switch (mismatches[0]) {
        .missing_field => |name| try std.testing.expectEqualStrings("span_id", name),
        else => return error.TestUnexpectedResult,
    }
}

test "validateSchema type mismatch" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        test_metadata_base ++
        \\{"name":"count","type":"i64"}
        ++ test_metadata_end;

    const expected = &[_]index_schema.FieldMapping{
        .{ .name = "count", .type = "u64" },
    };

    const mismatches = try validateSchema(arena.allocator(), expected, metadata);
    try std.testing.expectEqual(1, mismatches.len);
    switch (mismatches[0]) {
        .type_mismatch => |info| {
            try std.testing.expectEqualStrings("count", info.field);
            try std.testing.expectEqualStrings("u64", info.expected);
            try std.testing.expectEqualStrings("i64", info.actual);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "validateSchema tokenizer mismatch" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        test_metadata_base ++
        \\{"name":"body","type":"json","tokenizer":"raw"}
        ++ test_metadata_end;

    const expected = &[_]index_schema.FieldMapping{
        .{ .name = "body", .type = "json", .tokenizer = "default" },
    };

    const mismatches = try validateSchema(arena.allocator(), expected, metadata);
    try std.testing.expectEqual(1, mismatches.len);
    switch (mismatches[0]) {
        .tokenizer_mismatch => |info| {
            try std.testing.expectEqualStrings("body", info.field);
            try std.testing.expectEqualStrings("default", info.expected);
            try std.testing.expectEqualStrings("raw", info.actual);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "checkRetention matching" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        \\{"index_config":{"index_id":"test","doc_mapping":{"field_mappings":[]},
        \\"retention":{"period":"90 days","schedule":"daily"}}}
    ;

    const result = try checkRetention(arena.allocator(), "90 days", metadata);
    try std.testing.expect(result == null);
}

test "checkRetention mismatch" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        \\{"index_config":{"index_id":"test","doc_mapping":{"field_mappings":[]},
        \\"retention":{"period":"30 days","schedule":"daily"}}}
    ;

    const result = try checkRetention(arena.allocator(), "90 days", metadata);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("90 days", result.?.expected.?);
    try std.testing.expectEqualStrings("30 days", result.?.actual.?);
}

test "checkRetention no retention configured or actual" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        \\{"index_config":{"index_id":"test","doc_mapping":{"field_mappings":[]}}}
    ;

    const result = try checkRetention(arena.allocator(), null, metadata);
    try std.testing.expect(result == null);
}

test "checkRetention configured but not actual" {
    var arena = testArena();
    defer arena.deinit();
    const metadata =
        \\{"index_config":{"index_id":"test","doc_mapping":{"field_mappings":[]}}}
    ;

    const result = try checkRetention(arena.allocator(), "90 days", metadata);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("90 days", result.?.expected.?);
    try std.testing.expect(result.?.actual == null);
}
