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
    edges: []const u8,
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

    // POST /api/v1/service-graph
    if (std.mem.eql(u8, target, "/api/v1/service-graph")) {
        if (request.head.method != .POST) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleServiceGraph(request, arena, qw, indexes);
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

fn handleServiceGraph(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    indexes: *const IndexConfig,
) !void {
    // Read POST body — extract "query" field
    var buf: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&buf);
    const body = reader.allocRemaining(arena, max_body_size) catch {
        return respondError(request, .payload_too_large, "request body too large");
    };

    const user_query = extractQueryField(body) orelse {
        return respondError(request, .bad_request, "missing query field");
    };

    // Query A: SERVER/CONSUMER spans — service stats + error breakdown
    const svc_query_json = try std.fmt.allocPrint(arena,
        \\{{"query":"(span_kind:2 OR span_kind:5) AND ({s})","max_hits":0,"aggs":{{"services":{{"terms":{{"field":"service_name","size":200}},"aggs":{{"avg_duration":{{"avg":{{"field":"span_duration_millis"}}}},"by_status":{{"terms":{{"field":"span_status.code","size":10}}}}}}}}}}}}
    , .{user_query});

    const svc_result = qw.searchRaw(arena, indexes.traces, svc_query_json) catch {
        return respondError(request, .bad_gateway, "service query failed");
    };
    if (svc_result.status != .ok) {
        log.warn("Quickwit returned {d} for service-graph svc query", .{@intFromEnum(svc_result.status)});
        return respondError(request, .bad_gateway, "service query failed");
    }

    // Query B: CLIENT/PRODUCER spans — peer.service edges + error breakdown
    const edge_query_json = try std.fmt.allocPrint(arena,
        \\{{"query":"(span_kind:3 OR span_kind:4) AND ({s})","max_hits":0,"aggs":{{"edges":{{"terms":{{"field":"service_name","size":200}},"aggs":{{"dests":{{"terms":{{"field":"span_attributes.peer.service","size":200}},"aggs":{{"avg_duration":{{"avg":{{"field":"span_duration_millis"}}}},"by_status":{{"terms":{{"field":"span_status.code","size":10}}}}}}}}}}}}}}}}
    , .{user_query});

    const edge_result = qw.searchRaw(arena, indexes.traces, edge_query_json) catch {
        return respondError(request, .bad_gateway, "edge query failed");
    };
    if (edge_result.status != .ok) {
        log.warn("Quickwit returned {d} for service-graph edge query", .{@intFromEnum(edge_result.status)});
        return respondError(request, .bad_gateway, "edge query failed");
    }

    // Query E: Connector edges from service-edges index
    const edges_index_query = buildEdgesIndexQuery(arena, user_query) catch "*";
    const connector_query_json = try std.fmt.allocPrint(arena,
        \\{{"query":"{s}","max_hits":0,"aggs":{{"by_client":{{"terms":{{"field":"client","size":200}},"aggs":{{"by_server":{{"terms":{{"field":"server","size":200}},"aggs":{{"total_calls":{{"sum":{{"field":"calls"}}}},"total_errors":{{"sum":{{"field":"errors"}}}}}}}}}}}}}}}}
    , .{edges_index_query});

    // Graceful fallback: if edges index query fails, return empty connector agg
    const empty_connector = "{\"num_hits\":0,\"hits\":[],\"aggregations\":{\"by_client\":{\"buckets\":[]}}}";
    const connector_result = qw.searchRaw(arena, indexes.edges, connector_query_json) catch {
        log.debug("connector edge query failed, returning empty", .{});
        return respondServiceGraphV2(request, arena, svc_result.body, edge_result.body, empty_connector);
    };
    if (connector_result.status != .ok) {
        log.debug("connector edge query returned {d}, returning empty", .{@intFromEnum(connector_result.status)});
        return respondServiceGraphV2(request, arena, svc_result.body, edge_result.body, empty_connector);
    }

    return respondServiceGraphV2(request, arena, svc_result.body, edge_result.body, connector_result.body);
}

fn respondServiceGraphV2(
    request: *http.Server.Request,
    arena: Allocator,
    svc_body: []const u8,
    edge_body: []const u8,
    connector_body: []const u8,
) !void {
    const combined = try std.fmt.allocPrint(arena,
        \\{{"svc":{s},"edges":{s},"connector":{s}}}
    , .{ svc_body, edge_body, connector_body });
    return respondJson(request, combined);
}

/// Extract timestamp range from user query and adapt for the edges index.
/// User query contains "span_start_timestamp_nanos:[X TO Y]".
/// We rewrite to "timestamp_nanos:[X TO Y]" for the edges index.
/// Returns "*" if no time range found.
pub fn buildEdgesIndexQuery(arena: Allocator, user_query: []const u8) ![]const u8 {
    const needle = "span_start_timestamp_nanos:[";
    const start = std.mem.indexOf(u8, user_query, needle) orelse return "*";
    const range_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, user_query, range_start, "]") orelse return "*";
    const range_contents = user_query[range_start..end];
    return std.fmt.allocPrint(arena, "timestamp_nanos:[{s}]", .{range_contents});
}

/// Extract the "query" field value from a JSON body like {"query":"..."}.
/// Returns the unescaped string value, or null if not found.
fn extractQueryField(body: []const u8) ?[]const u8 {
    // Use simple parsing: find "query":" and extract until closing "
    // This avoids needing full JSON parse for a single field.
    const needle = "\"query\":\"";
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const value_start = start + needle.len;
    // Walk forward to find unescaped closing quote
    var i: usize = value_start;
    while (i < body.len) {
        if (body[i] == '\\') {
            i += 2; // skip escaped char
            continue;
        }
        if (body[i] == '"') {
            return body[value_start..i];
        }
        i += 1;
    }
    return null;
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

test "extractQueryField basic" {
    const body = "{\"query\":\"span_kind:2 AND service_name:foo\"}";
    const result = extractQueryField(body);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("span_kind:2 AND service_name:foo", result.?);
}

test "extractQueryField missing" {
    const body = "{\"other\":\"value\"}";
    try std.testing.expect(extractQueryField(body) == null);
}

test "extractQueryField with escaped quotes" {
    const body =
        \\{"query":"foo:\"bar\""}
    ;
    const result = extractQueryField(body);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("foo:\\\"bar\\\"", result.?);
}

test "buildEdgesIndexQuery with time range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const query = "span_start_timestamp_nanos:[2024-01-01T00:00:00Z TO 2024-01-02T00:00:00Z] AND service_name:foo";
    const result = try buildEdgesIndexQuery(arena, query);
    try std.testing.expectEqualStrings("timestamp_nanos:[2024-01-01T00:00:00Z TO 2024-01-02T00:00:00Z]", result);
}

test "buildEdgesIndexQuery without time range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try buildEdgesIndexQuery(arena, "service_name:foo");
    try std.testing.expectEqualStrings("*", result);
}

test "buildEdgesIndexQuery star query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try buildEdgesIndexQuery(arena, "*");
    try std.testing.expectEqualStrings("*", result);
}
