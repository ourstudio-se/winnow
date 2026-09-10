const quickwit_mod = @import("../quickwit.zig");
const HttpClient = quickwit_mod.HttpClient;
const Quickwit = quickwit_mod.Quickwit;
const Server = @import("server.zig");
const Module = @import("module.zig");
const api = @import("../api.zig");
const ingest = @import("../ingest.zig");
const static = @import("static.zig");
const http_errors = @import("http_errors.zig");
const std = @import("std");

const log = std.log.scoped(.worker);

const Worker = @This();

const RequestRole = enum {
    api,
    collector,
    static,
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

    while (worker.server.queue.pop(io)) |stream| {
        defer _ = arena.reset(.{ .retain_with_limit = arena_retain_size });
        worker.handleConnection(arena.allocator(), stream, qw);
    }

    std.log.debug("[THREAD {d}] Worker finished", .{std.Thread.getCurrentId()});
}

fn handleConnection(worker: *Worker, arena: std.mem.Allocator, stream: std.Io.net.Stream, qw: Quickwit) void {
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

    // std.log.debug("request received - {s}, ctx: {}", .{ request.head.target, worker.server.opts.roles });

    const pathType = enum {
        @"/v1/traces",
        @"/v1/logs",
        @"/v1/metrics",
        @"/api/v1/ui-config",
        @"*",
    };

    const path = std.meta.stringToEnum(pathType, request.head.target) orelse .@"*";

    const role = worker.server.opts.roles;

    const req_role: RequestRole = switch (path) {
        .@"/v1/traces", .@"/v1/logs", .@"/v1/metrics" => .collector,
        // ui-config must be reachable while logged out (it carries the login
        // URL), so it gets the static classification: api role, no auth.
        .@"/api/v1/ui-config" => .static,
        .@"*" => if (std.mem.startsWith(u8, request.head.target, "/api/")) .api else .static,
    };

    // Preflight checks
    switch (req_role) {
        .collector => {
            if (!role.collector) return http_errors.sendNotFound(&request);
            if (worker.server.role_auth.collector) |auth| if (!auth.check(&request)) return;
        },
        .api => {
            if (!role.api) return http_errors.sendNotFound(&request);
            if (worker.server.role_auth.api) |auth| if (!auth.check(&request)) return;
        },
        .static => {
            if (!role.api) return http_errors.sendNotFound(&request);
        },
    }

    switch (path) {
        .@"/v1/traces" => {
            if (!requireHttpMethod(&request, .POST)) {
                return;
            }
            ingest.handleTraces(&request, arena, qw, worker.server.opts.indices.traces) catch |err| {
                std.log.err("ingest error: {}", .{err});
            };
        },
        .@"/v1/logs" => {
            if (!requireHttpMethod(&request, .POST)) {
                return;
            }
            ingest.handleLogs(&request, arena, qw, worker.server.opts.indices.logs) catch |err| {
                std.log.err("log ingest error: {}", .{err});
            };
        },
        .@"/v1/metrics" => {
            if (!requireHttpMethod(&request, .POST)) {
                return;
            }
            ingest.handleMetrics(&request, arena, qw, worker.server.opts.indices.edges) catch |err| {
                std.log.err("metrics ingest error: {}", .{err});
            };
        },
        .@"/api/v1/ui-config" => {
            if (!requireHttpMethod(&request, .GET)) {
                return;
            }
            const auth_cfg = worker.server.opts.authorizers.api;
            api.handleUiConfig(
                &request,
                arena,
                if (auth_cfg) |cfg| cfg.login_url else null,
                if (auth_cfg) |cfg| cfg.logout_url else null,
            ) catch |err| {
                std.log.err("ui-config error: {}", .{err});
            };
        },
        .@"*" => {
            // "*" is not an actual path, just a wildcard catchall on the path type
            if (std.mem.eql(u8, request.head.target, "*")) return http_errors.sendNotFound(&request);

            switch (req_role) {
                .api => {
                    api.handleApi(&request, arena, qw, &worker.server.opts.indices) catch |err| {
                        std.log.err("api error: {}", .{err});
                    };
                },
                .static => {
                    static.handleStatic(&request) catch |err| {
                        std.log.err("static error: {}", .{err});
                    };
                },
                .collector => unreachable,
            }
        },
    }
}

fn requireHttpMethod(request: *std.http.Server.Request, method: std.http.Method) bool {
    if (request.head.method == method) {
        return true;
    }
    http_errors.sendMethodNotAllowed(request, method);
    return false;
}
