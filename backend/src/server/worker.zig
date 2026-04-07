const Server = @import("server.zig");
const api = @import("../api.zig");
const ingest = @import("../ingest.zig");
const static_assets = @import("static_assets.zig");
const std = @import("std");

const Worker = @This();

// 8 KiB standard for buffered i/o on read/write. Used to assign static buffer sizes.
// This does not limit the size of the request/response, it is a sliding window for
// chunked TCP read/writes. It does effectively limit the HTTP header size to 8 KiB,
// which is standard and mirrors e.g. nginx defaults.
const read_io_buf_size = 8192;
const write_io_buf_size = 8192;

// The retained capacity of the request arena on reset. If all requests allocate less than or equal to
// this amount we are guaranteed to never have to go to the backing allocator asking for
// more memory. Low setting means we free memory more aggressively - which stops the
// worker from hogging more memory than it needs. High setting means less risk for
// expensive syscalls to expand arena size.
const arena_retain_size = 8192;

server: *Server,

pub fn run(worker: *Worker) void {
    var arena = std.heap.ArenaAllocator.init(worker.server.allocator);
    defer arena.deinit();

    while (worker.server.queue.pop()) |conn| {
        defer _ = arena.reset(.{ .retain_with_limit = arena_retain_size });
        worker.handleConnection(arena.allocator(), conn);
    }

    std.log.debug("[THREAD {d}] Worker finished", .{std.Thread.getCurrentId()});
}

fn handleConnection(worker: *Worker, arena: std.mem.Allocator, conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    var read_buf: [read_io_buf_size]u8 = undefined;
    var write_buf: [write_io_buf_size]u8 = undefined;

    var reader = std.net.Stream.Reader.init(conn.stream, &read_buf);
    var writer = std.net.Stream.Writer.init(conn.stream, &write_buf);
    var http_server = std.http.Server.init(reader.interface(), &writer.interface);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("failed to receive request: {}", .{err});
        return;
    };

    std.log.debug("request received - {s}, ctx: {}", .{ request.head.target, worker.server.opts.roles });

    const pathType = enum {
        @"/v1/traces",
        @"/v1/logs",
        @"/",
    };

    const path = std.meta.stringToEnum(pathType, request.head.target) orelse .@"/";

    const role = worker.server.opts.roles;

    switch (path) {
        .@"/v1/traces" => {
            if (!role.collector) return sendNotFound(&request);
            if (request.head.method == .POST) {
                ingest.handleTraces(&request, arena, worker.server.opts.qw, worker.server.opts.indices.traces) catch |err| {
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
        },
        .@"/v1/logs" => {
            if (!role.collector) return sendNotFound(&request);
            if (request.head.method == .POST) {
                ingest.handleLogs(&request, arena, worker.server.opts.qw, worker.server.opts.indices.logs) catch |err| {
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
        },
        .@"/" => {
            if (!role.api) return sendNotFound(&request);
            if (std.mem.startsWith(u8, request.head.target, "/api/")) {
                api.handleApi(&request, arena, worker.server.opts.qw, &worker.server.opts.indices) catch |err| {
                    std.log.err("api error: {}", .{err});
                };
            } else {
                handleStatic(&request) catch |err| {
                    std.log.err("static error: {}", .{err});
                };
            }
        },
    }
}

fn sendNotFound(request: *std.http.Server.Request) void {
    request.respond("Not Found\n", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    }) catch {};
}

fn handleStatic(request: *std.http.Server.Request) !void {
    // Strip query string for lookup
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (static_assets.lookup(path)) |asset| {
        const cache_header: std.http.Header = if (asset.cacheable)
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
