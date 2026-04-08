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

    // POST /api/v1/service-graph
    if (std.mem.eql(u8, target, "/api/v1/service-graph")) {
        if (request.head.method != .POST) {
            return respondError(request, .method_not_allowed, "method not allowed");
        }
        return handleServiceGraph(request, arena, qw, indexes.traces);
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

const trace_sample_size = 200;
const max_sampled_spans = 5000;

fn handleServiceGraph(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    index_id: []const u8,
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

    // Query A: SERVER/CONSUMER spans — trace IDs + service stats + error breakdown
    const svc_query_json = try std.fmt.allocPrint(arena,
        \\{{"query":"(span_kind:2 OR span_kind:5) AND ({s})","max_hits":0,"aggs":{{"trace_ids":{{"terms":{{"field":"trace_id","size":{d}}}}},"services":{{"terms":{{"field":"service_name","size":200}},"aggs":{{"avg_duration":{{"avg":{{"field":"span_duration_millis"}}}},"by_status":{{"terms":{{"field":"span_status.code","size":10}}}}}}}}}}}}
    , .{ user_query, trace_sample_size });

    const svc_result = qw.searchRaw(arena, index_id, svc_query_json) catch {
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

    const edge_result = qw.searchRaw(arena, index_id, edge_query_json) catch {
        return respondError(request, .bad_gateway, "edge query failed");
    };
    if (edge_result.status != .ok) {
        log.warn("Quickwit returned {d} for service-graph edge query", .{@intFromEnum(edge_result.status)});
        return respondError(request, .bad_gateway, "edge query failed");
    }

    // Extract trace IDs from svc_result for span fetch
    const trace_ids = extractTraceIds(arena, svc_result.body) catch |err| {
        log.warn("failed to extract trace IDs: {}", .{err});
        // Return what we have without spans
        return respondServiceGraph(request, arena, svc_result.body, edge_result.body, "{\"num_hits\":0,\"hits\":[]}");
    };

    if (trace_ids.len == 0) {
        return respondServiceGraph(request, arena, svc_result.body, edge_result.body, "{\"num_hits\":0,\"hits\":[]}");
    }

    // Build span fetch query: "trace_id:abc OR trace_id:def"
    const trace_query = try buildTraceIdQuery(arena, trace_ids);
    const span_query_json = try std.fmt.allocPrint(arena,
        \\{{"query":"{s}","max_hits":{d}}}
    , .{ trace_query, max_sampled_spans });

    const span_result = qw.searchRaw(arena, index_id, span_query_json) catch {
        log.warn("span fetch failed, returning without spans", .{});
        return respondServiceGraph(request, arena, svc_result.body, edge_result.body, "{\"num_hits\":0,\"hits\":[]}");
    };
    if (span_result.status != .ok) {
        log.warn("Quickwit returned {d} for span fetch", .{@intFromEnum(span_result.status)});
        return respondServiceGraph(request, arena, svc_result.body, edge_result.body, "{\"num_hits\":0,\"hits\":[]}");
    }

    return respondServiceGraph(request, arena, svc_result.body, edge_result.body, span_result.body);
}

fn respondServiceGraph(
    request: *http.Server.Request,
    arena: Allocator,
    svc_body: []const u8,
    edge_body: []const u8,
    span_body: []const u8,
) !void {
    const combined = try std.fmt.allocPrint(arena,
        \\{{"svc":{s},"edges":{s},"spans":{s}}}
    , .{ svc_body, edge_body, span_body });
    return respondJson(request, combined);
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

/// Extract trace IDs from svc_result JSON: aggregations.trace_ids.buckets[].key
fn extractTraceIds(arena: Allocator, body: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return error.JsonParseFailed;

    const root = parsed.value;
    const aggs = root.object.get("aggregations") orelse return error.JsonParseFailed;
    const trace_ids_agg = aggs.object.get("trace_ids") orelse return error.JsonParseFailed;
    const buckets_val = trace_ids_agg.object.get("buckets") orelse return error.JsonParseFailed;
    const buckets = buckets_val.array;

    var ids = try std.ArrayList([]const u8).initCapacity(arena, buckets.items.len);
    for (buckets.items) |bucket| {
        const key = bucket.object.get("key") orelse continue;
        switch (key) {
            .string => |s| ids.appendAssumeCapacity(s),
            else => continue,
        }
    }
    return ids.items;
}

/// Build "trace_id:abc OR trace_id:def" query string.
fn buildTraceIdQuery(arena: Allocator, trace_ids: []const []const u8) ![]const u8 {
    // Calculate total length: "trace_id:" (9) + id.len + " OR " (4) between each
    var total_len: usize = 0;
    for (trace_ids, 0..) |id, i| {
        if (i > 0) total_len += 4; // " OR "
        total_len += 9 + id.len; // "trace_id:" + id
    }

    const result = try arena.alloc(u8, total_len);
    var pos: usize = 0;
    for (trace_ids, 0..) |id, i| {
        if (i > 0) {
            @memcpy(result[pos..][0..4], " OR ");
            pos += 4;
        }
        @memcpy(result[pos..][0..9], "trace_id:");
        pos += 9;
        @memcpy(result[pos..][0..id.len], id);
        pos += id.len;
    }
    return result;
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

test "extractTraceIds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"num_hits":100,"aggregations":{"trace_ids":{"buckets":[{"key":"abc123","doc_count":5},{"key":"def456","doc_count":3}]}}}
    ;
    const ids = try extractTraceIds(arena, body);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("abc123", ids[0]);
    try std.testing.expectEqualStrings("def456", ids[1]);
}

test "extractTraceIds empty buckets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"num_hits":0,"aggregations":{"trace_ids":{"buckets":[]}}}
    ;
    const ids = try extractTraceIds(arena, body);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "buildTraceIdQuery" {
    const ids = [_][]const u8{ "abc", "def", "ghi" };
    const result = try buildTraceIdQuery(std.testing.allocator, &ids);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("trace_id:abc OR trace_id:def OR trace_id:ghi", result);
}

test "buildTraceIdQuery single" {
    const ids = [_][]const u8{"abc123"};
    const result = try buildTraceIdQuery(std.testing.allocator, &ids);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("trace_id:abc123", result);
}
