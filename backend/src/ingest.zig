const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Io = std.Io;

const otlp = @import("proto/opentelemetry/proto/collector/trace/v1.pb.zig");
const logs_otlp = @import("proto/opentelemetry/proto/collector/logs/v1.pb.zig");
const metrics_otlp = @import("proto/opentelemetry/proto/collector/metrics/v1.pb.zig");
const trace_pb = @import("proto/opentelemetry/proto/trace/v1.pb.zig");
const logs_pb = @import("proto/opentelemetry/proto/logs/v1.pb.zig");
const metrics_pb = @import("proto/opentelemetry/proto/metrics/v1.pb.zig");
const common_pb = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_pb = @import("proto/opentelemetry/proto/resource/v1.pb.zig");
const Quickwit = @import("quickwit.zig").Quickwit;

const log = std.log.scoped(.ingest);

const max_body_size: Io.Limit = .limited(4 * 1024 * 1024); // 4 MiB

// -- Document types matching Quickwit index schema --

const SpanStatusDoc = struct {
    code: u64,
    message: []const u8,
};

const EventDoc = struct {
    time_unix_nano: u64,
    name: []const u8,
    attributes: std.json.Value,
};

const LinkDoc = struct {
    trace_id: []const u8,
    span_id: []const u8,
    trace_state: []const u8,
    attributes: std.json.Value,
};

const SpanDoc = struct {
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: []const u8,
    service_name: []const u8,
    resource_attributes: std.json.Value,
    resource_dropped_attributes_count: u32,
    span_name: []const u8,
    span_kind: u64,
    span_start_timestamp_nanos: u64,
    span_end_timestamp_nanos: u64,
    span_duration_millis: u64,
    span_attributes: std.json.Value,
    span_dropped_attributes_count: u32,
    span_dropped_events_count: u32,
    span_dropped_links_count: u32,
    span_status: ?SpanStatusDoc,
    events: []const EventDoc,
    event_names: []const []const u8,
    links: []const LinkDoc,
    is_root: bool,
    span_fingerprint: []const u8,
};

// -- Handler --

pub const HandleError = http.Server.Request.ExpectContinueError ||
    Io.Reader.LimitedAllocError ||
    error{ ReadFailed, DecodeFailed, TransformFailed, IngestFailed };

pub fn handleTraces(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    traces_index_id: []const u8,
) HandleError!void {
    // 1. Read request body
    var body_buf: [8192]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    const body = try body_reader.allocRemaining(arena, max_body_size);

    // 2. Decode protobuf
    var pb_reader: Io.Reader = .fixed(body);
    const otlp_request = otlp.ExportTraceServiceRequest.decode(&pb_reader, arena) catch |err| {
        log.err("protobuf decode failed: {}", .{err});
        respondError(request, .bad_request, "Bad Request: invalid protobuf\n");
        return error.DecodeFailed;
    };

    // 3. Transform to NDJSON
    const ndjson = transformToNdjson(arena, otlp_request) catch {
        log.err("span transform failed", .{});
        respondError(request, .internal_server_error, "Internal Server Error\n");
        return error.TransformFailed;
    };

    std.log.debug("ndjson: {s}", .{ndjson});

    // 4. Ingest into Quickwit
    if (ndjson.len > 0) {
        qw.ingest(arena, traces_index_id, ndjson) catch {
            log.err("quickwit ingest failed", .{});
            respondError(request, .bad_gateway, "Bad Gateway\n");
            return error.IngestFailed;
        };
    }

    // 5. Respond with empty ExportTraceServiceResponse (encodes to zero bytes)
    try request.respond("", .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-protobuf" },
        },
    });

    std.log.debug("finished ingesting trace", .{});
}

pub fn handleLogs(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    logs_index_id: []const u8,
) HandleError!void {
    // 1. Read request body
    var body_buf: [8192]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    const body = try body_reader.allocRemaining(arena, max_body_size);

    // 2. Decode protobuf
    var pb_reader: Io.Reader = .fixed(body);
    const otlp_request = logs_otlp.ExportLogsServiceRequest.decode(&pb_reader, arena) catch {
        log.err("log protobuf decode failed", .{});
        respondError(request, .bad_request, "Bad Request: invalid protobuf\n");
        return error.DecodeFailed;
    };

    // 3. Transform to NDJSON
    const ndjson = transformLogsToNdjson(arena, otlp_request) catch {
        log.err("log transform failed", .{});
        respondError(request, .internal_server_error, "Internal Server Error\n");
        return error.TransformFailed;
    };

    // 4. Ingest into Quickwit
    if (ndjson.len > 0) {
        qw.ingest(arena, logs_index_id, ndjson) catch {
            log.err("quickwit log ingest failed", .{});
            respondError(request, .bad_gateway, "Bad Gateway\n");
            return error.IngestFailed;
        };
    }

    // 5. Respond with empty ExportLogsServiceResponse (encodes to zero bytes)
    try request.respond("", .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-protobuf" },
        },
    });

    std.log.debug("finished ingesting logs", .{});
}

fn respondError(request: *http.Server.Request, status: http.Status, msg: []const u8) void {
    request.respond(msg, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    }) catch {};
}

// -- Transform pipeline --

pub fn transformToNdjson(
    arena: Allocator,
    request: otlp.ExportTraceServiceRequest,
) ![]const u8 {
    var ndjson: Io.Writer.Allocating = .init(arena);

    for (request.resource_spans.items) |rs| {
        const service_name = extractServiceName(rs.resource);
        const resource_attrs = try kvListToJsonValue(
            arena,
            if (rs.resource) |r| r.attributes.items else &.{},
        );
        const resource_dropped: u32 = if (rs.resource) |r| r.dropped_attributes_count else 0;

        for (rs.scope_spans.items) |ss| {
            for (ss.spans.items) |span| {
                const doc = try buildSpanDoc(arena, span, service_name, resource_attrs, resource_dropped);
                try std.json.Stringify.value(doc, .{ .emit_null_optional_fields = false }, &ndjson.writer);
                try ndjson.writer.writeAll("\n");
            }
        }
    }

    return ndjson.writer.buffered();
}

fn buildSpanDoc(
    arena: Allocator,
    span: trace_pb.Span,
    service_name: []const u8,
    resource_attrs: std.json.Value,
    resource_dropped: u32,
) !SpanDoc {
    const trace_id = try hexEncode(arena, span.trace_id);
    const span_id = try hexEncode(arena, span.span_id);
    const parent_span_id = try hexEncode(arena, span.parent_span_id);
    const span_kind: u64 = @intCast(@intFromEnum(span.kind));
    const duration_millis = if (span.end_time_unix_nano >= span.start_time_unix_nano)
        (span.end_time_unix_nano - span.start_time_unix_nano) / 1_000_000
    else
        0;

    const events = try buildEvents(arena, span.events.items);
    const event_names = try extractEventNames(arena, span.events.items);
    const links = try buildLinks(arena, span.links.items);
    const status_doc = if (span.status) |s| (if (s.code != .STATUS_CODE_UNSET) SpanStatusDoc{
        .code = @intCast(@intFromEnum(s.code)),
        .message = s.message,
    } else null) else null;

    std.log.debug("status_doc: {?}", .{status_doc});

    return .{
        .trace_id = trace_id,
        .span_id = span_id,
        .parent_span_id = parent_span_id,
        .service_name = service_name,
        .resource_attributes = resource_attrs,
        .resource_dropped_attributes_count = resource_dropped,
        .span_name = span.name,
        .span_kind = span_kind,
        .span_start_timestamp_nanos = span.start_time_unix_nano,
        .span_end_timestamp_nanos = span.end_time_unix_nano,
        .span_duration_millis = duration_millis,
        .span_attributes = try kvListToJsonValue(arena, span.attributes.items),
        .span_dropped_attributes_count = span.dropped_attributes_count,
        .span_dropped_events_count = span.dropped_events_count,
        .span_dropped_links_count = span.dropped_links_count,
        .span_status = status_doc,
        .events = events,
        .event_names = event_names,
        .links = links,
        .is_root = isRoot(span.parent_span_id),
        .span_fingerprint = try computeFingerprint(arena, service_name, span.name, span_kind),
    };
}

fn buildEvents(arena: Allocator, events: []const trace_pb.Span.Event) ![]const EventDoc {
    const docs = try arena.alloc(EventDoc, events.len);
    for (events, 0..) |evt, i| {
        docs[i] = .{
            .time_unix_nano = evt.time_unix_nano,
            .name = evt.name,
            .attributes = try kvListToJsonValue(arena, evt.attributes.items),
        };
    }
    return docs;
}

fn extractEventNames(arena: Allocator, events: []const trace_pb.Span.Event) ![]const []const u8 {
    const names = try arena.alloc([]const u8, events.len);
    for (events, 0..) |evt, i| {
        names[i] = evt.name;
    }
    return names;
}

fn buildLinks(arena: Allocator, links: []const trace_pb.Span.Link) ![]const LinkDoc {
    const docs = try arena.alloc(LinkDoc, links.len);
    for (links, 0..) |link, i| {
        docs[i] = .{
            .trace_id = try hexEncode(arena, link.trace_id),
            .span_id = try hexEncode(arena, link.span_id),
            .trace_state = link.trace_state,
            .attributes = try kvListToJsonValue(arena, link.attributes.items),
        };
    }
    return docs;
}

// -- Log transform pipeline --

const LogDoc = struct {
    timestamp_nanos: u64,
    observed_timestamp_nanos: u64,
    service_name: []const u8,
    severity_text: []const u8,
    severity_number: u64,
    body: std.json.Value,
    attributes: std.json.Value,
    dropped_attributes_count: u32,
    trace_id: ?[]const u8,
    span_id: ?[]const u8,
    trace_flags: u64,
    resource_attributes: std.json.Value,
    resource_dropped_attributes_count: u32,
    scope_name: ?[]const u8,
    scope_version: ?[]const u8,
    scope_attributes: ?std.json.Value,
    scope_dropped_attributes_count: ?u32,
};

pub fn transformLogsToNdjson(
    arena: Allocator,
    request: logs_otlp.ExportLogsServiceRequest,
) ![]const u8 {
    var ndjson: Io.Writer.Allocating = .init(arena);

    for (request.resource_logs.items) |rl| {
        const service_name = extractServiceName(rl.resource);
        const resource_attrs = try kvListToJsonValue(
            arena,
            if (rl.resource) |r| r.attributes.items else &.{},
        );
        const resource_dropped: u32 = if (rl.resource) |r| r.dropped_attributes_count else 0;

        for (rl.scope_logs.items) |sl| {
            const scope = sl.scope;
            const scope_name: ?[]const u8 = if (scope) |s| s.name else null;
            const scope_version: ?[]const u8 = if (scope) |s| s.version else null;
            const scope_attrs = if (scope) |s| try kvListToJsonValue(
                arena,
                s.attributes.items,
            ) else null;
            const scope_dropped: ?u32 = if (scope) |s| s.dropped_attributes_count else null;

            for (sl.log_records.items) |lr| {
                const timestamp_nanos = if (lr.time_unix_nano == 0) lr.observed_time_unix_nano else lr.time_unix_nano;

                const doc = LogDoc{
                    .timestamp_nanos = timestamp_nanos,
                    .observed_timestamp_nanos = lr.observed_time_unix_nano,
                    .service_name = service_name,
                    .severity_text = lr.severity_text,
                    .severity_number = @intCast(@intFromEnum(lr.severity_number)),
                    .body = try bodyToJsonObject(arena, lr.body),
                    .attributes = try kvListToJsonValue(arena, lr.attributes.items),
                    .dropped_attributes_count = lr.dropped_attributes_count,
                    .trace_id = if (lr.trace_id.len > 0) try hexEncode(arena, lr.trace_id) else null,
                    .span_id = if (lr.span_id.len > 0) try hexEncode(arena, lr.span_id) else null,
                    .trace_flags = @intCast(lr.flags),
                    .resource_attributes = resource_attrs,
                    .resource_dropped_attributes_count = resource_dropped,
                    .scope_name = scope_name,
                    .scope_version = scope_version,
                    .scope_attributes = scope_attrs,
                    .scope_dropped_attributes_count = scope_dropped,
                };
                try std.json.Stringify.value(doc, .{}, &ndjson.writer);
                try ndjson.writer.writeAll("\n");
            }
        }
    }

    return ndjson.writer.buffered();
}

// -- Metrics ingest (service-edges from servicegraph connector) --

const EdgeDoc = struct {
    timestamp_nanos: u64,
    client: []const u8,
    server: []const u8,
    connection_type: []const u8,
    calls: u64,
    errors: u64,
};

pub fn handleMetrics(
    request: *http.Server.Request,
    arena: Allocator,
    qw: Quickwit,
    edges_index_id: []const u8,
) HandleError!void {
    // 1. Read request body
    var body_buf: [8192]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    const body = try body_reader.allocRemaining(arena, max_body_size);

    // 2. Decode protobuf
    var pb_reader: Io.Reader = .fixed(body);
    const otlp_request = metrics_otlp.ExportMetricsServiceRequest.decode(&pb_reader, arena) catch {
        log.err("metrics protobuf decode failed", .{});
        respondError(request, .bad_request, "Bad Request: invalid protobuf\n");
        return error.DecodeFailed;
    };

    // 3. Transform to NDJSON
    const ndjson = transformMetricsToNdjson(arena, otlp_request) catch {
        log.err("metrics transform failed", .{});
        respondError(request, .internal_server_error, "Internal Server Error\n");
        return error.TransformFailed;
    };

    // 4. Ingest into Quickwit
    if (ndjson.len > 0) {
        qw.ingest(arena, edges_index_id, ndjson) catch {
            log.err("quickwit metrics ingest failed", .{});
            respondError(request, .bad_gateway, "Bad Gateway\n");
            return error.IngestFailed;
        };
    }

    // 5. Respond with empty ExportMetricsServiceResponse (encodes to zero bytes)
    try request.respond("", .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-protobuf" },
        },
    });
}

pub fn transformMetricsToNdjson(
    arena: Allocator,
    request: metrics_otlp.ExportMetricsServiceRequest,
) ![]const u8 {
    // Map to correlate total + failed metrics into one EdgeDoc per edge.
    // Key: "{timestamp}\0{client}\0{server}\0{connection_type}"
    var edge_map = std.StringHashMap(EdgeDoc).init(arena);

    for (request.resource_metrics.items) |rm| {
        for (rm.scope_metrics.items) |sm| {
            for (sm.metrics.items) |metric| {
                const is_total = std.mem.eql(u8, metric.name, "traces_service_graph_request_total");
                const is_failed = std.mem.eql(u8, metric.name, "traces_service_graph_request_failed_total");
                if (!is_total and !is_failed) continue;

                const data = metric.data orelse continue;
                const sum: metrics_pb.Sum = switch (data) {
                    .sum => |s| s,
                    else => continue,
                };

                for (sum.data_points.items) |dp| {
                    const client = extractMetricAttr(dp.attributes.items, "client") orelse continue;
                    const server = extractMetricAttr(dp.attributes.items, "server") orelse continue;
                    const connection_type = extractMetricAttr(dp.attributes.items, "connection_type") orelse "";
                    const timestamp = dp.time_unix_nano;

                    const val: u64 = if (dp.value) |v| switch (v) {
                        .as_int => |i| if (i >= 0) @intCast(i) else 0,
                        .as_double => |d| @intFromFloat(@max(d, 0)),
                    } else 0;

                    // Build map key
                    const key = try std.fmt.allocPrint(arena, "{d}\x00{s}\x00{s}\x00{s}", .{ timestamp, client, server, connection_type });

                    const gop = try edge_map.getOrPut(key);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{
                            .timestamp_nanos = timestamp,
                            .client = client,
                            .server = server,
                            .connection_type = connection_type,
                            .calls = 0,
                            .errors = 0,
                        };
                    }

                    if (is_total) {
                        gop.value_ptr.calls = val;
                    } else {
                        gop.value_ptr.errors = val;
                    }
                }
            }
        }
    }

    // Serialize edge docs to NDJSON
    var ndjson: Io.Writer.Allocating = .init(arena);
    var it = edge_map.valueIterator();
    while (it.next()) |doc| {
        try std.json.Stringify.value(doc.*, .{}, &ndjson.writer);
        try ndjson.writer.writeAll("\n");
    }

    return ndjson.writer.buffered();
}

fn extractMetricAttr(attrs: []const common_pb.KeyValue, key: []const u8) ?[]const u8 {
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

// -- Helpers --

/// Convert an OTel AnyValue body to a JSON object suitable for Quickwit's `json` field type.
/// Quickwit `json` fields require an object, so non-object values are wrapped as {"message": value}.
fn bodyToJsonObject(arena: Allocator, body: ?common_pb.AnyValue) !std.json.Value {
    const any = body orelse return .{ .object = std.json.ObjectMap.init(arena) };
    const val = try anyValueToJsonValue(arena, any);
    return switch (val) {
        .object => val,
        else => blk: {
            var obj = std.json.ObjectMap.init(arena);
            try obj.put("message", val);
            break :blk .{ .object = obj };
        },
    };
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

pub fn kvListToJsonValue(arena: Allocator, attrs: []const common_pb.KeyValue) !std.json.Value {
    var obj = std.json.ObjectMap.init(arena);
    try obj.ensureTotalCapacity(@intCast(attrs.len));
    for (attrs) |kv| {
        const val = if (kv.value) |v| try anyValueToJsonValue(arena, v) else .null;
        obj.putAssumeCapacity(kv.key, val);
    }
    return .{ .object = obj };
}

pub fn anyValueToJsonValue(arena: Allocator, any: common_pb.AnyValue) !std.json.Value {
    const v = any.value orelse return .null;
    return switch (v) {
        .string_value => |s| .{ .string = s },
        .bool_value => |b| .{ .bool = b },
        .int_value => |i| .{ .integer = i },
        .double_value => |d| .{ .float = d },
        .array_value => |arr| blk: {
            var items = std.json.Array.init(arena);
            try items.ensureTotalCapacity(arr.values.items.len);
            for (arr.values.items) |elem| {
                items.appendAssumeCapacity(try anyValueToJsonValue(arena, elem));
            }
            break :blk .{ .array = items };
        },
        .kvlist_value => |kvl| blk: {
            var obj = std.json.ObjectMap.init(arena);
            for (kvl.values.items) |kv| {
                const val = if (kv.value) |av| try anyValueToJsonValue(arena, av) else .null;
                try obj.put(kv.key, val);
            }
            break :blk .{ .object = obj };
        },
        .bytes_value => |b| .{ .string = try hexEncode(arena, b) },
        .string_value_strindex => .null,
    };
}

fn extractServiceName(resource: ?resource_pb.Resource) []const u8 {
    const res = resource orelse return "unknown";
    for (res.attributes.items) |kv| {
        if (std.mem.eql(u8, kv.key, "service.name")) {
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
    return "unknown";
}

fn isRoot(parent_span_id: []const u8) bool {
    if (parent_span_id.len == 0) return true;
    for (parent_span_id) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn computeFingerprint(arena: Allocator, service_name: []const u8, span_name: []const u8, span_kind: u64) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(service_name);
    hasher.update("\x00");
    hasher.update(span_name);
    hasher.update("\x00");
    hasher.update(std.mem.asBytes(&span_kind));
    return std.fmt.allocPrint(arena, "{x:0>16}", .{hasher.final()});
}

// -- Tests --

test "hexEncode" {
    const arena = std.testing.allocator;
    const result = try hexEncode(arena, &[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    defer arena.free(result);
    try std.testing.expectEqualStrings("0123456789abcdef", result);
}

test "hexEncode empty" {
    try std.testing.expectEqualStrings("", try hexEncode(std.testing.allocator, &.{}));
}

test "isRoot" {
    try std.testing.expect(isRoot(&.{}));
    try std.testing.expect(isRoot(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expect(!isRoot(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }));
}

test "extractServiceName found" {
    var attrs: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    defer attrs.deinit(std.testing.allocator);
    try attrs.append(std.testing.allocator, .{
        .key = "service.name",
        .value = .{ .value = .{ .string_value = "my-service" } },
    });
    const resource = resource_pb.Resource{ .attributes = attrs };
    try std.testing.expectEqualStrings("my-service", extractServiceName(resource));
}

test "extractServiceName missing" {
    try std.testing.expectEqualStrings("unknown", extractServiceName(null));
}

test "kvListToJsonValue" {
    const arena = std.testing.allocator;
    var attrs_buf: [2]common_pb.KeyValue = .{
        .{ .key = "http.method", .value = .{ .value = .{ .string_value = "GET" } } },
        .{ .key = "http.status_code", .value = .{ .value = .{ .int_value = 200 } } },
    };
    const result = try kvListToJsonValue(arena, &attrs_buf);
    defer {
        var obj = result.object;
        obj.deinit();
    }
    try std.testing.expectEqualStrings("GET", result.object.get("http.method").?.string);
    try std.testing.expectEqual(@as(i64, 200), result.object.get("http.status_code").?.integer);
}

test "anyValueToJsonValue bool" {
    const result = try anyValueToJsonValue(
        std.testing.allocator,
        .{ .value = .{ .bool_value = true } },
    );
    try std.testing.expect(result.bool);
}

test "transformToNdjson empty request" {
    const arena = std.testing.allocator;
    const request = otlp.ExportTraceServiceRequest{};
    const result = try transformToNdjson(arena, request);
    try std.testing.expectEqualStrings("", result);
}

test "transformToNdjson single span" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Build a minimal ExportTraceServiceRequest with one span
    var spans: std.ArrayListUnmanaged(trace_pb.Span) = .empty;
    try spans.append(arena, .{
        .trace_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .span_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .name = "test-span",
        .kind = .SPAN_KIND_SERVER,
        .start_time_unix_nano = 1000000000,
        .end_time_unix_nano = 1002000000,
    });

    var scope_spans: std.ArrayListUnmanaged(trace_pb.ScopeSpans) = .empty;
    try scope_spans.append(arena, .{ .spans = spans });

    var svc_attr: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    try svc_attr.append(arena, .{
        .key = "service.name",
        .value = .{ .value = .{ .string_value = "test-svc" } },
    });

    var resource_spans: std.ArrayListUnmanaged(trace_pb.ResourceSpans) = .empty;
    try resource_spans.append(arena, .{
        .resource = .{ .attributes = svc_attr },
        .scope_spans = scope_spans,
    });

    const request = otlp.ExportTraceServiceRequest{ .resource_spans = resource_spans };
    const ndjson = try transformToNdjson(arena, request);

    // Should produce exactly one JSON line
    try std.testing.expect(ndjson.len > 0);
    try std.testing.expect(ndjson[ndjson.len - 1] == '\n');

    // Parse it back to verify key fields
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, ndjson[0 .. ndjson.len - 1], .{});
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f", obj.get("trace_id").?.string);
    try std.testing.expectEqualStrings("0001020304050607", obj.get("span_id").?.string);
    try std.testing.expectEqualStrings("test-svc", obj.get("service_name").?.string);
    try std.testing.expectEqualStrings("test-span", obj.get("span_name").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("span_kind").?.integer);
    try std.testing.expectEqual(@as(i64, 2), obj.get("span_duration_millis").?.integer);
    try std.testing.expect(obj.get("is_root").?.bool);
}

test "transformLogsToNdjson empty request" {
    const arena = std.testing.allocator;
    const request = logs_otlp.ExportLogsServiceRequest{};
    const result = try transformLogsToNdjson(arena, request);
    try std.testing.expectEqualStrings("", result);
}

test "transformLogsToNdjson single log record" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Build a minimal ExportLogsServiceRequest with one log record
    var log_records: std.ArrayListUnmanaged(logs_pb.LogRecord) = .empty;
    try log_records.append(arena, .{
        .time_unix_nano = 1700000000000000000,
        .observed_time_unix_nano = 1700000000000000001,
        .severity_number = .SEVERITY_NUMBER_INFO,
        .severity_text = "INFO",
        .body = .{ .value = .{ .string_value = "test log message" } },
        .trace_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .span_id = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .flags = 1,
    });

    var scope_logs: std.ArrayListUnmanaged(logs_pb.ScopeLogs) = .empty;
    try scope_logs.append(arena, .{ .log_records = log_records });

    var svc_attr: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    try svc_attr.append(arena, .{
        .key = "service.name",
        .value = .{ .value = .{ .string_value = "test-svc" } },
    });

    var resource_logs: std.ArrayListUnmanaged(logs_pb.ResourceLogs) = .empty;
    try resource_logs.append(arena, .{
        .resource = .{ .attributes = svc_attr },
        .scope_logs = scope_logs,
    });

    const request = logs_otlp.ExportLogsServiceRequest{ .resource_logs = resource_logs };
    const ndjson = try transformLogsToNdjson(arena, request);

    // Should produce exactly one JSON line
    try std.testing.expect(ndjson.len > 0);
    try std.testing.expect(ndjson[ndjson.len - 1] == '\n');

    // Parse it back to verify key fields
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, ndjson[0 .. ndjson.len - 1], .{});
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("test-svc", obj.get("service_name").?.string);
    try std.testing.expectEqualStrings("INFO", obj.get("severity_text").?.string);
    try std.testing.expectEqual(@as(i64, 9), obj.get("severity_number").?.integer);
    // body is a string, so bodyToJsonObject wraps it as {"message": "..."}
    const body_obj = obj.get("body").?.object;
    try std.testing.expectEqualStrings("test log message", body_obj.get("message").?.string);
    try std.testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f", obj.get("trace_id").?.string);
    try std.testing.expectEqualStrings("0001020304050607", obj.get("span_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("trace_flags").?.integer);
    try std.testing.expectEqual(@as(i64, 1700000000000000000), obj.get("timestamp_nanos").?.integer);
}

test "transformMetricsToNdjson empty request" {
    const arena = std.testing.allocator;
    const request = metrics_otlp.ExportMetricsServiceRequest{};
    const result = try transformMetricsToNdjson(arena, request);
    try std.testing.expectEqualStrings("", result);
}

test "transformMetricsToNdjson servicegraph metrics" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Build data points for request_total
    var total_attrs: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    try total_attrs.append(arena, .{ .key = "client", .value = .{ .value = .{ .string_value = "frontend" } } });
    try total_attrs.append(arena, .{ .key = "server", .value = .{ .value = .{ .string_value = "backend" } } });
    try total_attrs.append(arena, .{ .key = "connection_type", .value = .{ .value = .{ .string_value = "" } } });

    var total_dps: std.ArrayListUnmanaged(metrics_pb.NumberDataPoint) = .empty;
    try total_dps.append(arena, .{
        .attributes = total_attrs,
        .time_unix_nano = 1700000000000000000,
        .value = .{ .as_int = 42 },
    });

    // Build data points for request_failed_total
    var failed_attrs: std.ArrayListUnmanaged(common_pb.KeyValue) = .empty;
    try failed_attrs.append(arena, .{ .key = "client", .value = .{ .value = .{ .string_value = "frontend" } } });
    try failed_attrs.append(arena, .{ .key = "server", .value = .{ .value = .{ .string_value = "backend" } } });
    try failed_attrs.append(arena, .{ .key = "connection_type", .value = .{ .value = .{ .string_value = "" } } });

    var failed_dps: std.ArrayListUnmanaged(metrics_pb.NumberDataPoint) = .empty;
    try failed_dps.append(arena, .{
        .attributes = failed_attrs,
        .time_unix_nano = 1700000000000000000,
        .value = .{ .as_int = 3 },
    });

    // Build metrics
    var metrics_list: std.ArrayListUnmanaged(metrics_pb.Metric) = .empty;
    try metrics_list.append(arena, .{
        .name = "traces_service_graph_request_total",
        .data = .{ .sum = .{ .data_points = total_dps } },
    });
    try metrics_list.append(arena, .{
        .name = "traces_service_graph_request_failed_total",
        .data = .{ .sum = .{ .data_points = failed_dps } },
    });

    var scope_metrics: std.ArrayListUnmanaged(metrics_pb.ScopeMetrics) = .empty;
    try scope_metrics.append(arena, .{ .metrics = metrics_list });

    var resource_metrics: std.ArrayListUnmanaged(metrics_pb.ResourceMetrics) = .empty;
    try resource_metrics.append(arena, .{ .scope_metrics = scope_metrics });

    const request = metrics_otlp.ExportMetricsServiceRequest{ .resource_metrics = resource_metrics };
    const ndjson = try transformMetricsToNdjson(arena, request);

    // Should produce exactly one JSON line (total + failed merged)
    try std.testing.expect(ndjson.len > 0);
    try std.testing.expect(ndjson[ndjson.len - 1] == '\n');

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, ndjson[0 .. ndjson.len - 1], .{});
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("frontend", obj.get("client").?.string);
    try std.testing.expectEqualStrings("backend", obj.get("server").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("calls").?.integer);
    try std.testing.expectEqual(@as(i64, 3), obj.get("errors").?.integer);
    try std.testing.expectEqual(@as(i64, 1700000000000000000), obj.get("timestamp_nanos").?.integer);
}

test "transformMetricsToNdjson ignores non-servicegraph metrics" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var metrics_list: std.ArrayListUnmanaged(metrics_pb.Metric) = .empty;
    try metrics_list.append(arena, .{
        .name = "http_server_duration",
        .data = .{ .sum = .{ .data_points = .empty } },
    });

    var scope_metrics: std.ArrayListUnmanaged(metrics_pb.ScopeMetrics) = .empty;
    try scope_metrics.append(arena, .{ .metrics = metrics_list });

    var resource_metrics: std.ArrayListUnmanaged(metrics_pb.ResourceMetrics) = .empty;
    try resource_metrics.append(arena, .{ .scope_metrics = scope_metrics });

    const request = metrics_otlp.ExportMetricsServiceRequest{ .resource_metrics = resource_metrics };
    const ndjson = try transformMetricsToNdjson(arena, request);
    try std.testing.expectEqualStrings("", ndjson);
}

test "extractMetricAttr" {
    var attrs_buf: [2]common_pb.KeyValue = .{
        .{ .key = "client", .value = .{ .value = .{ .string_value = "svc-a" } } },
        .{ .key = "server", .value = .{ .value = .{ .string_value = "svc-b" } } },
    };
    try std.testing.expectEqualStrings("svc-a", extractMetricAttr(&attrs_buf, "client").?);
    try std.testing.expectEqualStrings("svc-b", extractMetricAttr(&attrs_buf, "server").?);
    try std.testing.expect(extractMetricAttr(&attrs_buf, "missing") == null);
}
