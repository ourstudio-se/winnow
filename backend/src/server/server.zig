const std = @import("std");
const api = @import("../api.zig");
const ingest = @import("../ingest.zig");
const Quickwit = @import("../quickwit.zig").Quickwit;
const static_assets = @import("static_assets.zig");
const tsq = @import("../thread_safe_queue.zig");
const Worker = @import("worker.zig");

const ServerRoles = packed struct {
    api: bool = false,
    collector: bool = false,
};

const Server = @This();

const ServerOpts = struct {
    indices: api.IndexConfig,
    number_of_workers: usize,
    port: u16,
    qw: Quickwit,
    roles: ServerRoles,
};

allocator: std.mem.Allocator,
opts: ServerOpts,
queue: *tsq.ThreadSafeQueue(std.net.Server.Connection),
workers: []Worker,

pub fn init(allocator: std.mem.Allocator, opts: ServerOpts, queue: *tsq.ThreadSafeQueue(std.net.Server.Connection), workers: []Worker) Server {
    return Server{
        .allocator = allocator,
        .opts = opts,
        .queue = queue,
        .workers = workers,
    };
}

pub fn create(allocator: std.mem.Allocator, opts: ServerOpts) error{OutOfMemory}!*Server {
    const server = try allocator.create(Server);
    const queue = try tsq.ThreadSafeQueue(std.net.Server.Connection).create(allocator);
    const workers = try allocator.alloc(Worker, opts.number_of_workers);

    for (0..opts.number_of_workers) |i| {
        workers[i] = .{
            .server = server,
        };
    }

    server.* = init(allocator, opts, queue, workers);

    return server;
}

pub fn destroy(server: *Server) void {
    server.queue.destroy();
    server.allocator.free(server.workers);
    server.allocator.destroy(server);
}

pub fn close(server: *Server) void {
    std.log.debug("[THREAD {d}] Closing server for port {d}...", .{ std.Thread.getCurrentId(), server.opts.port });
    server.queue.close();
}

pub fn listen(server: *Server) !std.net.Server {
    {
        // Log what we are doing
        var roleAl = try std.ArrayList(u8).initCapacity(server.allocator, 255);
        defer roleAl.deinit(server.allocator);

        if (server.opts.roles.api) {
            try roleAl.appendSlice(server.allocator, "api");
        }

        if (server.opts.roles.collector) {
            if (roleAl.items.len > 0) {
                try roleAl.appendSlice(server.allocator, " + ");
            }
            try roleAl.appendSlice(server.allocator, "collector");
        }

        const rolestr = try roleAl.toOwnedSlice(server.allocator);
        defer server.allocator.free(rolestr);

        std.log.info("{s} listening on http://0.0.0.0:{d}", .{ rolestr, server.opts.port });
    }

    const address = std.net.Address.parseIp("0.0.0.0", server.opts.port) catch unreachable;
    return address.listen(.{ .reuse_address = true });
}

pub fn run(server: *Server) void {
    var listener = server.listen() catch |err| {
        std.log.err("failed to listen to addr: {}", .{err});
        @panic("unrecoverable error in server init");
    };
    defer listener.deinit();

    var wg: std.Thread.WaitGroup = .{};
    defer wg.wait();

    for (server.workers) |*worker| {
        wg.spawnManager(Worker.run, .{worker});
    }

    mainloop: while (true) {
        var poll_fd: [1]std.posix.pollfd = .{.{
            .fd = listener.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const connection_ready = std.posix.poll(&poll_fd, 100) catch |err| {
            std.log.err("polling error: {}", .{err});
            continue :mainloop;
        } > 0;

        if (server.queue.closed.load(.acquire)) {
            break :mainloop;
        }

        if (!connection_ready) {
            continue :mainloop;
        }

        const conn = listener.accept() catch |err| {
            std.log.err("accept error: {}", .{err});
            continue;
        };

        server.queue.push(conn) catch |err| {
            // Since no worker has handled the connection, we need to close it here
            conn.stream.close();

            switch (err) {
                error.QueueClosed => {
                    std.log.debug("[THREAD {d}] Queue is closed, gracefully exit server", .{std.Thread.getCurrentId()});
                    break :mainloop;
                },
                else => {
                    std.log.err("failed to push request to queue: {}", .{err});
                    break :mainloop;
                },
            }
        };
    }

    std.log.debug("cleaning up server", .{});
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

test {
    _ = tsq.ThreadSafeQueue(std.net.Server.Connection);
    _ = Worker;
    _ = Server;
}
