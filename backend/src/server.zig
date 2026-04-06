const std = @import("std");
const api = @import("api.zig");
const ingest = @import("ingest.zig");
const Quickwit = @import("quickwit.zig").Quickwit;
const static_assets = @import("static_assets.zig");

const ServerRoles = packed struct {
    api: bool = false,
    collector: bool = false,
};

fn Queue(T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            data: T,
            next: ?*Node,
        };

        closed: std.atomic.Value(bool),

        allocator: std.mem.Allocator,
        m: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        head: ?*Node = null,
        tail: ?*Node = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .closed = std.atomic.Value(bool).init(false),
                .m = .{},
                .cond = .{},
                .head = null,
                .tail = null,
            };
        }

        fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
            const queue = try allocator.create(Self);
            queue.* = Self.init(allocator);
            return queue;
        }

        fn close(queue: *Self) void {
            queue.closed.store(true, .release);
            queue.cond.broadcast();
        }

        fn destroy(queue: *Self) void {
            defer queue.allocator.destroy(queue);
            var n = queue.head;

            while (n) |node| {
                const next = node.next;
                queue.allocator.destroy(node);
                n = next;
            }
        }

        fn push(queue: *Self, data: T) error{ QueueClosed, OutOfMemory }!void {
            queue.m.lock();
            defer queue.m.unlock();

            if (queue.closed.load(.acquire)) {
                return error.QueueClosed;
            }

            var node = try queue.allocator.create(Node);
            node.next = null;
            node.data = data;
            if (queue.tail) |tail| {
                tail.next = node;
            }
            queue.tail = node;

            if (queue.head == null) {
                queue.head = queue.tail;
            }

            queue.cond.signal();
        }

        fn pop(queue: *Self) ?T {
            queue.m.lock();
            defer queue.m.unlock();

            while (queue.head == null) {
                if (queue.closed.load(.acquire)) return null;
                queue.cond.wait(&queue.m);
            }

            const head = queue.head.?;

            const next = head.next;
            const data = head.data;

            queue.allocator.destroy(head);

            queue.head = next;

            if (queue.head == null) {
                queue.tail = null;
            }

            return data;
        }
    };
}

const Worker = struct {
    server: *Server,

    fn run(worker: *Worker) void {
        var arena = std.heap.ArenaAllocator.init(worker.server.allocator);
        defer arena.deinit();

        while (worker.server.queue.pop()) |conn| {
            defer _ = arena.reset(.{ .retain_with_limit = 8192 });
            worker.handleConnection(arena.allocator(), conn);
        }

        std.log.debug("[THREAD {d}] Worker finished", .{std.Thread.getCurrentId()});
    }

    fn handleConnection(worker: *Worker, arena: std.mem.Allocator, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;

        var reader = std.net.Stream.Reader.init(conn.stream, &read_buf);
        var writer = std.net.Stream.Writer.init(conn.stream, &write_buf);
        var http_server = std.http.Server.init(reader.interface(), &writer.interface);

        var request = http_server.receiveHead() catch |err| {
            std.log.err("failed to receive request: {}", .{err});
            return;
        };

        std.log.debug("request received - {s}, ctx: {}", .{ request.head.target, worker.server.opts.roles });

        // Route (gated by server role)
        const role = worker.server.opts.roles;
        if (std.mem.eql(u8, request.head.target, "/v1/traces")) {
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
        } else if (std.mem.eql(u8, request.head.target, "/v1/logs")) {
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
        } else if (std.mem.startsWith(u8, request.head.target, "/api/")) {
            if (!role.api) return sendNotFound(&request);
            api.handleApi(&request, arena, worker.server.opts.qw, &worker.server.opts.indices) catch |err| {
                std.log.err("api error: {}", .{err});
            };
        } else {
            if (!role.api) return sendNotFound(&request);
            handleStatic(&request) catch |err| {
                std.log.err("static error: {}", .{err});
            };
        }
    }
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
queue: *Queue(std.net.Server.Connection),
workers: []Worker,

pub fn init(allocator: std.mem.Allocator, opts: ServerOpts, queue: *Queue(std.net.Server.Connection), workers: []Worker) Server {
    return Server{
        .allocator = allocator,
        .opts = opts,
        .queue = queue,
        .workers = workers,
    };
}

pub fn create(allocator: std.mem.Allocator, opts: ServerOpts) error{OutOfMemory}!*Server {
    const server = try allocator.create(Server);
    const queue = try Queue(std.net.Server.Connection).create(allocator);
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

    var pool: std.Thread.Pool = undefined;

    pool.init(.{
        .allocator = server.allocator,
        .n_jobs = server.opts.number_of_workers,
    }) catch |err| {
        std.log.err("failed to init server thread pool: {}", .{err});
        @panic("unrecoverable error in server init");
    };

    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    defer wg.wait();

    for (server.workers) |*worker| {
        pool.spawnWg(&wg, Worker.run, .{worker});
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

test {
    _ = Queue(std.net.Server.Connection);
    _ = Worker;
    _ = Server;
}
