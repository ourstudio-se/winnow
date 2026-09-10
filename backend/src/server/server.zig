const ConfigProvider = @import("../config.zig");
const Io = std.Io;
const Module = @import("module.zig");
const Worker = @import("worker.zig");
const api = @import("../api.zig");
const auth = @import("auth.zig");
const ingest = @import("../ingest.zig");
const net = std.Io.net;
const static_assets = @import("static_assets.zig");
const std = @import("std");
const tsq = @import("../thread_safe_queue.zig");

const log = std.log.scoped(.server);

const Error = error{
    AuthMissingModule,
    AuthModuleMissingHook,
};

const RolesEnabled = packed struct {
    api: bool = false,
    collector: bool = false,
};

const RoleAuth = struct {
    api: ?auth.Authorizer = null,
    collector: ?auth.Authorizer = null,
};

const RoleAuthorizerConfig = struct {
    api: ?*ConfigProvider.AuthConfig = null,
    collector: ?*ConfigProvider.AuthConfig = null,
};

const Server = @This();

const Opts = struct {
    roles: RolesEnabled,
    number_of_workers: usize,
    port: u16,
    quickwit_url: []const u8,
    indices: api.IndexConfig,
    authorizers: RoleAuthorizerConfig,
    modules: *std.StringHashMapUnmanaged(Module),
};

allocator: std.mem.Allocator,
io: Io,
opts: Opts,
queue: *tsq.ThreadSafeQueue(net.Stream),
workers: []Worker,
role_auth: RoleAuth,

pub fn init(
    allocator: std.mem.Allocator,
    io: Io,
    opts: Opts,
    queue: *tsq.ThreadSafeQueue(net.Stream),
    workers: []Worker,
    role_auth: RoleAuth,
) Server {
    return Server{
        .allocator = allocator,
        .io = io,
        .opts = opts,
        .queue = queue,
        .workers = workers,
        .role_auth = role_auth,
    };
}

pub fn create(allocator: std.mem.Allocator, io: Io, opts: Opts) (error{OutOfMemory} || Error)!*Server {
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);

    const queue = try tsq.ThreadSafeQueue(net.Stream).create(allocator);
    errdefer queue.destroy();

    const workers = try allocator.alloc(Worker, opts.number_of_workers);
    errdefer allocator.free(workers);

    for (0..opts.number_of_workers) |i| {
        workers[i] = .{
            .server = server,
        };
    }

    // Set up server auth

    var role_auth: RoleAuth = .{};
    errdefer {
        if (role_auth.api) |authorizer| authorizer.destroy(allocator);
        if (role_auth.collector) |authorizer| authorizer.destroy(allocator);
    }

    if (opts.authorizers.api) |api_authorizer| {
        switch (api_authorizer.inner_config) {
            .module => |auth_module_cfg| {
                const module = opts.modules.getPtr(auth_module_cfg.module_name) orelse {
                    return Error.AuthMissingModule;
                };
                if (module.ffi.onAuth == null) {
                    return Error.AuthModuleMissingHook;
                }
                role_auth.api = try module.getAuthorizer(api_authorizer.strategy, allocator);
            },
        }
    }

    if (opts.authorizers.collector) |collector_authorizer| {
        switch (collector_authorizer.inner_config) {
            .module => |auth_module_cfg| {
                const module = opts.modules.getPtr(auth_module_cfg.module_name) orelse {
                    return Error.AuthMissingModule;
                };
                if (module.ffi.onAuth == null) {
                    return Error.AuthModuleMissingHook;
                }
                role_auth.collector = try module.getAuthorizer(collector_authorizer.strategy, allocator);
            },
        }
    }

    server.* = init(allocator, io, opts, queue, workers, role_auth);

    return server;
}

pub fn destroy(server: *Server) void {
    server.queue.destroy();
    server.allocator.free(server.workers);

    if (server.role_auth.api) |authorizer| {
        authorizer.destroy(server.allocator);
    }

    if (server.role_auth.collector) |authorizer| {
        authorizer.destroy(server.allocator);
    }

    server.allocator.destroy(server);
}

pub fn close(server: *Server) void {
    log.debug("[THREAD {d}] Closing server for port {d}...", .{ std.Thread.getCurrentId(), server.opts.port });
    server.queue.close(server.io);
}

pub fn listen(server: *Server) !net.Server {
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

        log.info("{s} listening on http://0.0.0.0:{d}", .{ rolestr, server.opts.port });
    }

    const address = net.IpAddress.parse("0.0.0.0", server.opts.port) catch unreachable;
    return address.listen(server.io, .{ .reuse_address = true });
}

pub fn run(server: *Server) void {
    const io = server.io;

    var listener = server.listen() catch |err| {
        log.err("failed to listen to addr: {}", .{err});
        @panic("unrecoverable error in server init");
    };
    defer listener.deinit(io);

    var group: Io.Group = .init;
    defer group.await(io) catch {};

    for (server.workers) |*worker| {
        group.concurrent(io, Worker.run, .{worker}) catch |err| {
            log.err("failed to spawn worker: {}", .{err});
            @panic("unrecoverable error in server init");
        };
    }

    mainloop: while (true) {
        var poll_fd: [1]std.posix.pollfd = .{.{
            .fd = listener.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const connection_ready = std.posix.poll(&poll_fd, 100) catch |err| {
            log.err("polling error: {}", .{err});
            continue :mainloop;
        } > 0;

        if (server.queue.closed.load(.acquire)) {
            break :mainloop;
        }

        if (!connection_ready) {
            continue :mainloop;
        }

        const stream = listener.accept(io) catch |err| {
            log.err("accept error: {}", .{err});
            continue;
        };

        server.queue.push(io, stream) catch |err| {
            // Since no worker has handled the connection, we need to close it here
            stream.close(io);

            switch (err) {
                error.QueueClosed => {
                    log.debug("[THREAD {d}] Queue is closed, gracefully exit server", .{std.Thread.getCurrentId()});
                    break :mainloop;
                },
                else => {
                    log.err("failed to push request to queue: {}", .{err});
                    break :mainloop;
                },
            }
        };
    }

    log.debug("cleaning up server", .{});
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
    _ = tsq.ThreadSafeQueue(net.Stream);
    _ = Worker;
    _ = Server;
}
