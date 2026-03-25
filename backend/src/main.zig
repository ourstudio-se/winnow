const std = @import("std");
const net = std.net;
const http = std.http;
const Allocator = std.mem.Allocator;
const otlp = @import("proto/opentelemetry/proto/collector/trace/v1.pb.zig");
const logs_otlp = @import("proto/opentelemetry/proto/collector/logs/v1.pb.zig");
const Quickwit = @import("quickwit.zig").Quickwit;
const otel_index = @import("otel_index.zig");
const otel_logs_index = @import("otel_logs_index.zig");
const ingest = @import("ingest.zig");
const api = @import("api.zig");
const static_assets = @import("static_assets.zig");

const IndexConfig = struct {
    traces: []const u8,
    logs: []const u8,
};

const Context = struct {
    qw: Quickwit,
    allocator: Allocator,
    indexes: IndexConfig,
    allowed_indexes: [2][]const u8,
};

const default_quickwit_url = "http://localhost:7280";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Quickwit client
    const quickwit_url = std.process.getEnvVarOwned(allocator, "QUICKWIT_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default_quickwit_url),
        else => return err,
    };
    defer allocator.free(quickwit_url);

    // Read configurable index names
    const traces_index = std.process.getEnvVarOwned(allocator, "OTEL_TRACES_INDEX") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, otel_index.index_id),
        else => return err,
    };
    defer allocator.free(traces_index);

    const logs_index = std.process.getEnvVarOwned(allocator, "OTEL_LOGS_INDEX") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, otel_logs_index.index_id),
        else => return err,
    };
    defer allocator.free(logs_index);

    var http_client: http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const qw = Quickwit.init(&http_client, quickwit_url);

    std.log.info("connecting to Quickwit at {s}", .{quickwit_url});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        qw.ensureIndex(arena.allocator(), traces_index, otel_index.config) catch |err| {
            std.log.err("failed to ensure traces index: {}", .{err});
            return err;
        };
        qw.ensureIndex(arena.allocator(), logs_index, otel_logs_index.config) catch |err| {
            std.log.err("failed to ensure logs index: {}", .{err});
            return err;
        };
    }

    // Start HTTP server
    const address = net.Address.parseIp("0.0.0.0", 8080) catch unreachable;
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.log.info("listening on http://0.0.0.0:8080", .{});

    const ctx = Context{
        .qw = qw,
        .allocator = allocator,
        .indexes = .{
            .traces = traces_index,
            .logs = logs_index,
        },
        .allowed_indexes = .{ traces_index, logs_index },
    };

    while (true) {
        const conn = try server.accept();
        _ = std.Thread.spawn(.{}, handleConnection, .{ conn, &ctx }) catch |err| {
            std.log.err("failed to spawn thread: {}", .{err});
            continue;
        };
    }
}

fn handleConnection(conn: net.Server.Connection, ctx: *const Context) void {
    defer conn.stream.close();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = net.Stream.Reader.init(conn.stream, &read_buf);
    var writer = net.Stream.Writer.init(conn.stream, &write_buf);
    var http_server = http.Server.init(reader.interface(), &writer.interface);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("failed to receive request: {}", .{err});
        return;
    };

    // Per-request arena
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    // Route
    if (std.mem.eql(u8, request.head.target, "/v1/traces")) {
        if (request.head.method == .POST) {
            ingest.handleTraces(&request, arena.allocator(), ctx.qw, ctx.indexes.traces) catch |err| {
                std.log.err("ingest error: {}", .{err});
            };
        } else {
            request.respond("Method Not Allowed\n", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            }) catch {};
        }
    } else if (std.mem.eql(u8, request.head.target, "/v1/logs")) {
        if (request.head.method == .POST) {
            ingest.handleLogs(&request, arena.allocator(), ctx.qw, ctx.indexes.logs) catch |err| {
                std.log.err("log ingest error: {}", .{err});
            };
        } else {
            request.respond("Method Not Allowed\n", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            }) catch {};
        }
    } else if (std.mem.startsWith(u8, request.head.target, "/api/")) {
        api.handleApi(&request, arena.allocator(), ctx.qw, &ctx.allowed_indexes) catch |err| {
            std.log.err("api error: {}", .{err});
        };
    } else {
        handleStatic(&request) catch |err| {
            std.log.err("static error: {}", .{err});
        };
    }
}

fn handleStatic(request: *http.Server.Request) !void {
    // Strip query string for lookup
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (static_assets.lookup(path)) |asset| {
        const cache_header: http.Header = if (asset.cacheable)
            .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" }
        else
            .{ .name = "cache-control", .value = "no-cache" };
        try request.respond(asset.content, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = asset.content_type },
                cache_header,
            },
        });
    } else {
        // SPA fallback: serve index.html for unrecognized paths (client-side routing)
        if (static_assets.lookup("/")) |index| {
            try request.respond(index.content, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html" },
                    .{ .name = "cache-control", .value = "no-cache" },
                },
            });
        } else {
            try request.respond("Not Found\n", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            });
        }
    }
}

test "static asset lookup" {
    // Verify the lookup function exists and returns null for unknown paths
    const result = static_assets.lookup("/nonexistent");
    try std.testing.expect(result == null);

    // Root should resolve to index.html
    const root = static_assets.lookup("/");
    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings("text/html", root.?.content_type);
    try std.testing.expect(!root.?.cacheable);
}

test "otlp proto types are importable" {
    _ = otlp.ExportTraceServiceRequest;
    _ = otlp.ExportTraceServiceResponse;
}

test "otlp log proto types are importable" {
    _ = logs_otlp.ExportLogsServiceRequest;
    _ = logs_otlp.ExportLogsServiceResponse;
}

test {
    _ = Quickwit;
    _ = otel_index;
    _ = otel_logs_index;
    _ = ingest;
    _ = api;
}
