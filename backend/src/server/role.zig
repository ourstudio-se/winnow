const ConfigProvider = @import("../config.zig");
const Worker = @import("worker.zig");
const api = @import("../api.zig");
const auth = @import("auth.zig");
const http_errors = @import("http_errors.zig");
const ingest = @import("../ingest.zig");
const proxy = @import("proxy.zig");
const quickwit = @import("../quickwit.zig");
const static = @import("static.zig");
const std = @import("std");

pub const Role = @This();

pub const RouteFn = *const fn (
    *const anyopaque,
    *Worker,
    *std.http.Server.Request,
    Worker.Context,
) void;
pub const DestroyFn = *const fn (*const anyopaque, std.mem.Allocator) void;

pub const VTable = struct {
    route: RouteFn,
    destroy: DestroyFn,
};

authorizer: ?auth.Authorizer,
user_data: *const anyopaque,
vtable: VTable,

pub fn init(user_data: *const anyopaque, vtable: VTable, authorizer: ?auth.Authorizer) Role {
    return .{ .user_data = user_data, .vtable = vtable, .authorizer = authorizer };
}

pub fn preflight(role: Role, req: *std.http.Server.Request) bool {
    return if (role.authorizer) |a| return a.check(req) else true;
}

pub fn route(
    role: Role,
    worker: *Worker,
    req: *std.http.Server.Request,
    ctx: Worker.Context,
) void {
    return role.vtable.route(role.user_data, worker, req, ctx);
}

pub fn destroy(role: Role, allocator: std.mem.Allocator) void {
    if (role.authorizer) |a| {
        a.destroy(allocator);
    }
    return role.vtable.destroy(role.user_data, allocator);
}

pub const UIRole = struct {
    const log = std.log.scoped(.ui);
    const Config = ConfigProvider.ServeConfig.RoleConfig.UIInner;

    interface: Role,
    config: Config,

    pub fn create(authorizer: ?auth.Authorizer, ui_config: Config, allocator: std.mem.Allocator) error{OutOfMemory}!*@This() {
        const ui_role = try allocator.create(@This());
        ui_role.* = .{
            .interface = .init(
                ui_role,
                .{
                    .route = @This().route,
                    .destroy = @This().destroy,
                },
                authorizer,
            ),
            .config = ui_config,
        };
        return ui_role;
    }

    pub fn destroy(user_data: *const anyopaque, allocator: std.mem.Allocator) void {
        const ui_role: *const @This() = @ptrCast(@alignCast(user_data));
        allocator.destroy(ui_role);
    }

    pub fn route(
        user_data: *const anyopaque,
        worker: *Worker,
        req: *std.http.Server.Request,
        ctx: Worker.Context,
    ) void {
        const ui_role: *const @This() = @ptrCast(@alignCast(user_data));

        const pathType = enum {
            @"/api/v1/ui-config",
            @"*",
        };

        const path = std.meta.stringToEnum(pathType, req.head.target) orelse .@"*";

        switch (path) {
            .@"/api/v1/ui-config" => {
                if (!requireHttpMethod(req, &.{.GET})) {
                    return;
                }

                api.handleUiConfig(
                    req,
                    ctx.arena,
                    ui_role.config.login_url_str,
                    ui_role.config.logout_url_str,
                ) catch |err| {
                    log.err("ui-config error: {}", .{err});
                };
            },
            .@"*" => {
                if (std.mem.startsWith(u8, req.head.target, "/api/")) {
                    if (ui_role.config.api_url) |api_url| {
                        proxy.proxy(worker.server.io, ctx.arena, req, api_url) catch |err| {
                            log.err("proxying request: {}", .{err});
                        };
                    } else {
                        return http_errors.sendNotFound(req);
                    }
                } else {
                    if (!requireHttpMethod(req, &.{.GET})) {
                        http_errors.sendNotFound(req);
                        return;
                    }

                    static.handleStatic(req) catch |err| {
                        log.err("static error: {}", .{err});
                    };
                }
            },
        }
    }
};

pub fn GenericRole(Impl: type) type {
    return struct {
        pub const user_data_token: struct {} = .{};

        pub const route = Impl.route;

        interface: Role,

        pub fn init(authorizer: ?auth.Authorizer) @This() {
            return .{
                .interface = .init(
                    &user_data_token,
                    .{
                        .route = @This().route,
                        .destroy = @This().destroy,
                    },
                    authorizer,
                ),
            };
        }

        pub fn destroy(_: *const anyopaque, _: std.mem.Allocator) void {}
    };
}

pub const ApiRole = GenericRole(struct {
    const log = std.log.scoped(.api);

    fn route(
        _: *const anyopaque,
        worker: *Worker,
        req: *std.http.Server.Request,
        ctx: Worker.Context,
    ) void {
        api.handleApi(req, ctx.arena, ctx.qw, &worker.server.opts.indices) catch |err| {
            log.err("api error: {}", .{err});
        };
    }
});

pub const CollectorRole = GenericRole(struct {
    const log = std.log.scoped(.collector);

    fn route(
        _: *const anyopaque,
        worker: *Worker,
        req: *std.http.Server.Request,
        ctx: Worker.Context,
    ) void {
        if (!requireHttpMethod(req, &.{.POST})) {
            http_errors.sendNotFound(req);
            return;
        }

        const pathType = enum {
            @"/v1/traces",
            @"/v1/logs",
            @"/v1/metrics",
        };

        const path = std.meta.stringToEnum(pathType, req.head.target) orelse return;

        switch (path) {
            .@"/v1/traces" => {
                ingest.handleTraces(req, ctx.arena, ctx.qw, worker.server.opts.indices.traces) catch |err| {
                    log.err("ingest error: {}", .{err});
                };
            },
            .@"/v1/logs" => {
                ingest.handleLogs(req, ctx.arena, ctx.qw, worker.server.opts.indices.logs) catch |err| {
                    log.err("log ingest error: {}", .{err});
                };
            },
            .@"/v1/metrics" => {
                ingest.handleMetrics(req, ctx.arena, ctx.qw, worker.server.opts.indices.edges) catch |err| {
                    log.err("metrics ingest error: {}", .{err});
                };
            },
        }
    }
});

fn requireHttpMethod(request: *std.http.Server.Request, methods: []const std.http.Method) bool {
    for (methods) |method| {
        if (request.head.method == method) {
            return true;
        }
    }
    http_errors.sendMethodNotAllowed(request, methods);
    return false;
}
