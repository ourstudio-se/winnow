const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Quickwit = @import("quickwit.zig").Quickwit;

const log = std.log.scoped(.api);

const max_body_size: Io.Limit = .limited(1024 * 1024); // 1 MiB

/// Handle all /api/ routes. Dispatches to search proxy or index list.
pub fn handleApi(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    allowed_indexes: []const []const u8,
) !void {
    const target = request.head.target;

    // GET /api/v1/indexes
    if (std.mem.eql(u8, target, "/api/v1/indexes")) {
        if (request.head.method != .GET) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleIndexList(request, arena, allowed_indexes);
    }

    // GET /api/v1/indexes/{index}
    if (extractMetadataIndex(target)) |index_id| {
        if (request.head.method != .GET) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleIndexMetadata(request, arena, qw, allowed_indexes, index_id);
    }

    // POST /api/v1/{index}/search
    if (extractSearchIndex(target)) |index_id| {
        if (request.head.method != .POST) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleSearch(request, arena, qw, allowed_indexes, index_id);
    }

    return respondError(request, .not_found, "not found");
}

/// Extract index ID from "/api/v1/indexes/{index}" path.
/// Returns null if the path doesn't match or contains further slashes.
fn extractMetadataIndex(target: []const u8) ?[]const u8 {
    const prefix = "/api/v1/indexes/";

    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const index_id = target[prefix.len..];

    if (index_id.len == 0) return null;
    if (std.mem.indexOfScalar(u8, index_id, '/') != null) return null;
    return index_id;
}

fn handleIndexMetadata(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    allowed_indexes: []const []const u8,
    index_id: []const u8,
) !void {
    const allowed = for (allowed_indexes) |idx| {
        if (std.mem.eql(u8, idx, index_id)) break true;
    } else false;

    if (!allowed) {
        return respondError(request, .not_found, "index not found");
    }

    const result = qw.getIndexMetadata(arena, index_id) catch {
        return respondError(request, .bad_gateway, "metadata fetch failed");
    };

    if (result.status == .ok) {
        return respondJson(request, result.body);
    }

    log.warn("Quickwit returned {d} for index metadata {s}", .{ @intFromEnum(result.status), index_id });
    try request.respond(result.body, .{
        .status = .bad_gateway,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

/// Extract index ID from "/api/v1/{index}/search" path.
/// Returns null if the path doesn't match.
fn extractSearchIndex(target: []const u8) ?[]const u8 {
    const prefix = "/api/v1/";
    const suffix = "/search";

    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];

    if (!std.mem.endsWith(u8, rest, suffix)) return null;
    const index_id = rest[0 .. rest.len - suffix.len];

    if (index_id.len == 0) return null;
    return index_id;
}

fn handleSearch(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    allowed_indexes: []const []const u8,
    index_id: []const u8,
) !void {
    // Validate index is in allowed list
    const allowed = for (allowed_indexes) |idx| {
        if (std.mem.eql(u8, idx, index_id)) break true;
    } else false;

    if (!allowed) {
        return respondError(request, .not_found, "index not found");
    }

    // Read POST body
    var buf: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&buf);
    const body = reader.allocRemaining(arena, max_body_size) catch {
        return respondError(request, .payload_too_large, "request body too large");
    };

    // Forward to Quickwit
    const result = qw.searchRaw(arena, index_id, body) catch {
        return respondError(request, .bad_gateway, "search failed");
    };

    // Forward Quickwit's response (including error responses)
    if (result.status == .ok) {
        return respondJson(request, result.body);
    }

    // Non-200 from Quickwit — forward body with 502
    log.warn("Quickwit returned {d} for {s}", .{ @intFromEnum(result.status), index_id });
    try request.respond(result.body, .{
        .status = .bad_gateway,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn handleIndexList(
    request: *http.Server.Request,
    arena: Allocator,
    allowed_indexes: []const []const u8,
) !void {
    // Build JSON array: ["index1", "index2", ...]
    var buf: std.Io.Writer.Allocating = .init(arena);
    const writer = &buf.writer;
    try writer.writeByte('[');
    for (allowed_indexes, 0..) |idx, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(idx);
        try writer.writeByte('"');
    }
    try writer.writeByte(']');
    return respondJson(request, buf.writer.buffer[0..buf.writer.end]);
}

fn respondJson(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn respondError(request: *http.Server.Request, status: http.Status, msg: []const u8) !void {
    // Build {"error": "msg"} — msg is a known literal, no escaping needed
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch
        "{\"error\":\"internal error\"}";
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

// -- Tests --

test "extractMetadataIndex valid paths" {
    try std.testing.expectEqualStrings(
        "otel-traces-v0_9",
        extractMetadataIndex("/api/v1/indexes/otel-traces-v0_9").?,
    );
    try std.testing.expectEqualStrings(
        "servicegraph",
        extractMetadataIndex("/api/v1/indexes/servicegraph").?,
    );
}

test "extractMetadataIndex invalid paths" {
    try std.testing.expectEqual(null, extractMetadataIndex("/api/v1/indexes"));
    try std.testing.expectEqual(null, extractMetadataIndex("/api/v1/indexes/"));
    try std.testing.expectEqual(null, extractMetadataIndex("/api/v1/indexes/foo/bar"));
    try std.testing.expectEqual(null, extractMetadataIndex("/other/path"));
}

test "extractSearchIndex valid paths" {
    try std.testing.expectEqualStrings(
        "otel-traces-v0_9",
        extractSearchIndex("/api/v1/otel-traces-v0_9/search").?,
    );
    try std.testing.expectEqualStrings(
        "servicegraph",
        extractSearchIndex("/api/v1/servicegraph/search").?,
    );
    try std.testing.expectEqualStrings(
        "my-custom-index",
        extractSearchIndex("/api/v1/my-custom-index/search").?,
    );
}

test "extractSearchIndex invalid paths" {
    try std.testing.expectEqual(null, extractSearchIndex("/api/v1/indexes"));
    try std.testing.expectEqual(null, extractSearchIndex("/api/v1//search"));
    try std.testing.expectEqual(null, extractSearchIndex("/other/path"));
    try std.testing.expectEqual(null, extractSearchIndex("/api/v1/foo/notearch"));
}

test "allowed index validation" {
    const allowed = &[_][]const u8{ "otel-traces-v0_9", "otel-logs-v0_9", "servicegraph" };

    // Known indexes should be accepted
    for (allowed) |idx| {
        const found = for (allowed) |a| {
            if (std.mem.eql(u8, a, idx)) break true;
        } else false;
        try std.testing.expect(found);
    }

    // Unknown index should be rejected
    const found = for (allowed) |a| {
        if (std.mem.eql(u8, a, "secret-index")) break true;
    } else false;
    try std.testing.expect(!found);
}
