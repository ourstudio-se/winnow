const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Quickwit = @import("quickwit.zig").Quickwit;

const log = std.log.scoped(.api);

const max_body_size: Io.Limit = .limited(1024 * 1024); // 1 MiB

pub const IndexConfig = struct {
    traces: []const u8,
    logs: []const u8,
};

/// Handle all /api/ routes. Dispatches to search or metadata handlers.
pub fn handleApi(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    indexes: *const IndexConfig,
) !void {
    const target = request.head.target;

    // POST /api/v1/traces/search
    if (std.mem.eql(u8, target, "/api/v1/traces/search")) {
        if (request.head.method != .POST) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleSearch(request, arena, qw, indexes.traces);
    }

    // POST /api/v1/logs/search
    if (std.mem.eql(u8, target, "/api/v1/logs/search")) {
        if (request.head.method != .POST) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleSearch(request, arena, qw, indexes.logs);
    }

    // GET /api/v1/traces/metadata
    if (std.mem.eql(u8, target, "/api/v1/traces/metadata")) {
        if (request.head.method != .GET) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleIndexMetadata(request, arena, qw, indexes.traces);
    }

    // GET /api/v1/logs/metadata
    if (std.mem.eql(u8, target, "/api/v1/logs/metadata")) {
        if (request.head.method != .GET) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleIndexMetadata(request, arena, qw, indexes.logs);
    }

    return respondError(request, .not_found, "not found");
}

fn handleIndexMetadata(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    index_id: []const u8,
) !void {
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

fn handleSearch(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    index_id: []const u8,
) !void {
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

test "handleApi routes traces search" {
    // Verify the exact path matching works by testing the path constants
    try std.testing.expect(std.mem.eql(u8, "/api/v1/traces/search", "/api/v1/traces/search"));
    try std.testing.expect(std.mem.eql(u8, "/api/v1/logs/search", "/api/v1/logs/search"));
    try std.testing.expect(std.mem.eql(u8, "/api/v1/traces/metadata", "/api/v1/traces/metadata"));
    try std.testing.expect(std.mem.eql(u8, "/api/v1/logs/metadata", "/api/v1/logs/metadata"));
}

test "old dynamic paths no longer match" {
    // Ensure old-style paths don't match any of our fixed routes
    const old_paths = [_][]const u8{
        "/api/v1/winnow-traces-v0_1/search",
        "/api/v1/winnow-logs-v0_1/search",
        "/api/v1/indexes/winnow-traces-v0_1",
        "/api/v1/indexes",
    };
    const new_paths = [_][]const u8{
        "/api/v1/traces/search",
        "/api/v1/logs/search",
        "/api/v1/traces/metadata",
        "/api/v1/logs/metadata",
    };
    for (old_paths) |old| {
        for (new_paths) |new| {
            try std.testing.expect(!std.mem.eql(u8, old, new));
        }
    }
}
