const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const otlp = @import("proto/opentelemetry/proto/collector/trace/v1.pb.zig");
const trace_pb = @import("proto/opentelemetry/proto/trace/v1.pb.zig");
const common_pb = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_pb = @import("proto/opentelemetry/proto/resource/v1.pb.zig");

const EdgeDoc = struct {
    source: []const u8,
    dest: []const u8,
    operation: []const u8,
    span_kind: u64,
    duration_ms: u64,
    is_error: bool,
    timestamp_nanos: u64,
    trace_id: []const u8,
};

/// Extract service graph edge documents from an OTLP trace batch.
/// Returns NDJSON bytes (may be empty if no edges found).
pub fn extractEdges(
    arena: Allocator,
    request: otlp.ExportTraceServiceRequest,
) ![]const u8 {
    var ndjson: Io.Writer.Allocating = .init(arena);

    for (request.resource_spans.items) |rs| {
        const service_name = extractServiceName(rs.resource);

        for (rs.scope_spans.items) |ss| {
            for (ss.spans.items) |span| {
                // Only CLIENT (3) and PRODUCER (4) spans produce edges
                const kind = span.kind;
                if (kind != .SPAN_KIND_CLIENT and kind != .SPAN_KIND_PRODUCER) continue;

                // Resolve destination via attribute fallback chain
                const dest = findStringAttribute(span.attributes.items, "peer.service") orelse
                    findStringAttribute(span.attributes.items, "server.address") orelse
                    findStringAttribute(span.attributes.items, "net.peer.name") orelse
                    findStringAttribute(span.attributes.items, "http.host") orelse
                    continue;

                const duration_ms = if (span.end_time_unix_nano >= span.start_time_unix_nano)
                    (span.end_time_unix_nano - span.start_time_unix_nano) / 1_000_000
                else
                    0;

                const is_error = if (span.status) |s|
                    s.code == .STATUS_CODE_ERROR
                else
                    false;

                const doc = EdgeDoc{
                    .source = service_name,
                    .dest = dest,
                    .operation = span.name,
                    .span_kind = @intCast(@intFromEnum(kind)),
                    .duration_ms = duration_ms,
                    .is_error = is_error,
                    .timestamp_nanos = span.start_time_unix_nano,
                    .trace_id = try hexEncode(arena, span.trace_id),
                };

                try std.json.Stringify.value(doc, .{}, &ndjson.writer);
                try ndjson.writer.writeAll("\n");
            }
        }
    }

    return ndjson.writer.buffered();
}

fn findStringAttribute(attrs: []const common_pb.KeyValue, key: []const u8) ?[]const u8 {
    for (attrs) |kv| {
        if (std.mem.eql(u8, kv.key, key)) {
            if (kv.value) |any_val| {
                if (any_val.value) |val| {
                    switch (val) {
                        .string_value => |s| return s,
                        else => {},
                    }
                }
            }
        }
    }
    return null;
}

fn extractServiceName(resource: ?resource_pb.Resource) []const u8 {
    const res = resource orelse return "unknown";
    return findStringAttribute(res.attributes.items, "service.name") orelse "unknown";
}

fn hexEncode(arena: Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return "";
    const charset = "0123456789abcdef";
    const out = try arena.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

// -- Tests --

test "extractEdges: CLIENT span with peer.service produces edge" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var span_attrs: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    try span_attrs.append(arena, .{
        .key = "peer.service",
        .value = .{ .value = .{ .string_value = "backend-db" } },
    });

    var spans: std.ArrayListUnmanaged(trace_pb.Span) = .empty;
    try spans.append(arena, .{
        .trace_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .span_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .name = "db-query",
        .kind = .SPAN_KIND_CLIENT,
        .start_time_unix_nano = 1000000000,
        .end_time_unix_nano = 1005000000,
        .attributes = span_attrs,
    });

    var svc_attr: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    try svc_attr.append(arena, .{
        .key = "service.name",
        .value = .{ .value = .{ .string_value = "my-service" } },
    });

    var scope_spans: std.ArrayListUnmanaged(trace_pb.ScopeSpans) = .empty;
    try scope_spans.append(arena, .{ .spans = spans });

    var resource_spans: std.ArrayListUnmanaged(trace_pb.ResourceSpans) = .empty;
    try resource_spans.append(arena, .{
        .resource = .{ .attributes = svc_attr },
        .scope_spans = scope_spans,
    });

    const request = otlp.ExportTraceServiceRequest{ .resource_spans = resource_spans };
    const ndjson = try extractEdges(arena, request);

    try std.testing.expect(ndjson.len > 0);
    try std.testing.expect(ndjson[ndjson.len - 1] == '\n');

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, ndjson[0 .. ndjson.len - 1], .{});
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("my-service", obj.get("source").?.string);
    try std.testing.expectEqualStrings("backend-db", obj.get("dest").?.string);
    try std.testing.expectEqualStrings("db-query", obj.get("operation").?.string);
    try std.testing.expectEqual(@as(i64, 3), obj.get("span_kind").?.integer);
    try std.testing.expectEqual(@as(i64, 5), obj.get("duration_ms").?.integer);
    try std.testing.expect(!obj.get("is_error").?.bool);
}

test "extractEdges: SERVER span produces no edges" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var spans: std.ArrayListUnmanaged(trace_pb.Span) = .empty;
    try spans.append(arena, .{
        .trace_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .span_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .name = "handle-request",
        .kind = .SPAN_KIND_SERVER,
        .start_time_unix_nano = 1000000000,
        .end_time_unix_nano = 1005000000,
    });

    var scope_spans: std.ArrayListUnmanaged(trace_pb.ScopeSpans) = .empty;
    try scope_spans.append(arena, .{ .spans = spans });

    var resource_spans: std.ArrayListUnmanaged(trace_pb.ResourceSpans) = .empty;
    try resource_spans.append(arena, .{
        .resource = null,
        .scope_spans = scope_spans,
    });

    const request = otlp.ExportTraceServiceRequest{ .resource_spans = resource_spans };
    const ndjson = try extractEdges(arena, request);

    try std.testing.expectEqualStrings("", ndjson);
}

test "extractEdges: CLIENT span without dest attributes produces no edges" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var spans: std.ArrayListUnmanaged(trace_pb.Span) = .empty;
    try spans.append(arena, .{
        .trace_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .span_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .name = "outgoing-call",
        .kind = .SPAN_KIND_CLIENT,
        .start_time_unix_nano = 1000000000,
        .end_time_unix_nano = 1005000000,
    });

    var scope_spans: std.ArrayListUnmanaged(trace_pb.ScopeSpans) = .empty;
    try scope_spans.append(arena, .{ .spans = spans });

    var resource_spans: std.ArrayListUnmanaged(trace_pb.ResourceSpans) = .empty;
    try resource_spans.append(arena, .{
        .resource = null,
        .scope_spans = scope_spans,
    });

    const request = otlp.ExportTraceServiceRequest{ .resource_spans = resource_spans };
    const ndjson = try extractEdges(arena, request);

    try std.testing.expectEqualStrings("", ndjson);
}

test "findStringAttribute: found" {
    var attrs_buf: [1]common_pb.KeyValue = .{
        .{ .key = "peer.service", .value = .{ .value = .{ .string_value = "db" } } },
    };
    try std.testing.expectEqualStrings("db", findStringAttribute(&attrs_buf, "peer.service").?);
}

test "findStringAttribute: missing" {
    var attrs_buf: [1]common_pb.KeyValue = .{
        .{ .key = "other.attr", .value = .{ .value = .{ .string_value = "val" } } },
    };
    try std.testing.expect(findStringAttribute(&attrs_buf, "peer.service") == null);
}

test "findStringAttribute: empty" {
    try std.testing.expect(findStringAttribute(&.{}, "peer.service") == null);
}
