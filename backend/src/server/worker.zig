const HttpClient = quickwit_mod.HttpClient;
const Module = @import("module.zig");
const Quickwit = quickwit_mod.Quickwit;
const Role = @import("role.zig");
const Server = @import("server.zig");
const api = @import("../api.zig");
const http_errors = @import("http_errors.zig");
const ingest = @import("../ingest.zig");
const quickwit_mod = @import("../quickwit.zig");
const static = @import("static.zig");
const std = @import("std");

const log = std.log.scoped(.worker);

const Worker = @This();

pub const Context = struct {
    arena: std.mem.Allocator,
    http_client: *std.http.Client,
    qw: Quickwit,
};

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
    const io = worker.server.io;

    var arena = std.heap.ArenaAllocator.init(worker.server.allocator);
    defer arena.deinit();

    // Each worker thread gets its own HTTP client — std.http.Client is not
    // thread-safe and must not be shared across threads.
    var http_client: std.http.Client = .{ .allocator = worker.server.allocator, .io = io };
    defer http_client.deinit();
    const client = HttpClient.init(&http_client);
    const qw = Quickwit.init(client, worker.server.opts.quickwit_url);

    const ctx: Context = .{
        .arena = arena.allocator(),
        .http_client = &http_client,
        .qw = qw,
    };

    while (worker.server.queue.pop(io)) |stream| {
        defer _ = arena.reset(.{ .retain_with_limit = arena_retain_size });
        worker.handleConnection(stream, ctx);
    }

    std.log.debug("[THREAD {d}] Worker finished", .{std.Thread.getCurrentId()});
}

fn handleConnection(worker: *Worker, stream: std.Io.net.Stream, ctx: Context) void {
    const io = worker.server.io;
    defer stream.close(io);

    var read_buf: [read_io_buf_size]u8 = undefined;
    var write_buf: [write_io_buf_size]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("failed to receive request: {}", .{err});
        return;
    };

    const pathType = enum {
        @"/v1/traces",
        @"/v1/logs",
        @"/v1/metrics",
        @"/api/v1/ui-config",
        @"*",
    };

    const path = std.meta.stringToEnum(pathType, request.head.target) orelse .@"*";

    const req_role: Role = switch (path) {
        .@"/v1/traces", .@"/v1/logs", .@"/v1/metrics" => worker.server.roles.collector,
        .@"/api/v1/ui-config" => worker.server.roles.ui,
        .@"*" => if (std.mem.startsWith(u8, request.head.target, "/api/")) (worker.server.roles.api orelse worker.server.roles.ui) else worker.server.roles.ui,
    } orelse {
        return http_errors.sendNotFound(&request);
    };

    if (!req_role.preflight(&request)) {
        return;
    }

    req_role.route(worker, &request, ctx);
}
