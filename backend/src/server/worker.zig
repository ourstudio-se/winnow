const Quickwit = @import("../quickwit.zig").Quickwit;
const Server = @import("server.zig");
const api = @import("../api.zig");
const ingest = @import("../ingest.zig");
const static = @import("static.zig");
const http_errors = @import("http_errors.zig");
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

    // Each worker thread gets its own HTTP client — std.http.Client is not
    // thread-safe and must not be shared across threads.
    var http_client: std.http.Client = .{ .allocator = worker.server.allocator };
    defer http_client.deinit();
    const qw = Quickwit.init(&http_client, worker.server.opts.qw.base_url);

    while (worker.server.queue.pop()) |conn| {
        defer _ = arena.reset(.{ .retain_with_limit = arena_retain_size });
        worker.handleConnection(arena.allocator(), conn, qw);
    }

    std.log.debug("[THREAD {d}] Worker finished", .{std.Thread.getCurrentId()});
}

fn handleConnection(worker: *Worker, arena: std.mem.Allocator, conn: std.net.Server.Connection, qw: Quickwit) void {
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
        @"*",
    };

    const path = std.meta.stringToEnum(pathType, request.head.target) orelse .@"*";

    const role = worker.server.opts.roles;

    switch (path) {
        .@"/v1/traces" => {
            if (!role.collector) return http_errors.sendNotFound(&request);
            if (request.head.method == .POST) {
                ingest.handleTraces(&request, arena, qw, worker.server.opts.indices.traces) catch |err| {
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
            if (!role.collector) return http_errors.sendNotFound(&request);
            if (request.head.method == .POST) {
                ingest.handleLogs(&request, arena, qw, worker.server.opts.indices.logs) catch |err| {
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
        .@"*" => {
            // "*" is not an actual path, just a wildcard catchall on the path type
            if (std.mem.eql(u8, request.head.target, "*")) return http_errors.sendNotFound(&request);

            if (!role.api) return http_errors.sendNotFound(&request);
            if (std.mem.startsWith(u8, request.head.target, "/api/")) {
                api.handleApi(&request, arena, qw, &worker.server.opts.indices) catch |err| {
                    std.log.err("api error: {}", .{err});
                };
            } else {
                static.handleStatic(&request) catch |err| {
                    std.log.err("static error: {}", .{err});
                };
            }
        },
    }
}
