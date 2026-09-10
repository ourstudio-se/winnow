const Server = @import("server.zig");
const auth = @import("auth.zig");
const ConfigProvider = @import("../config.zig");
const std = @import("std");

const log = std.log.scoped(.module);

const FFI = struct {
    const GetConfigValueFunction = *const fn (
        module_cfg_store: *const anyopaque,
        key: StringView,
    ) callconv(.c) StringView;

    const LogFn = *const fn (
        message: StringView,
    ) callconv(.c) void;

    const ModuleInitContext = extern struct {
        module_cfg_store: *const anyopaque,
        getConfigValue: GetConfigValueFunction,
        logDebug: LogFn,
        logInfo: LogFn,
        logWarn: LogFn,
        logErr: LogFn,

        pub fn init(module_cfg_store: *const anyopaque) @This() {
            return .{
                .module_cfg_store = module_cfg_store,
                .getConfigValue = getConfigValue,
                .logDebug = logDebug,
                .logInfo = logInfo,
                .logWarn = logWarn,
                .logErr = logErr,
            };
        }
    };

    const StringView = extern struct {
        ptr: ?[*]const u8,
        len: usize,

        fn init(str: ?[]const u8) @This() {
            if (str) |s| {
                return .{
                    .ptr = s.ptr,
                    .len = s.len,
                };
            }

            return .{
                .ptr = null,
                .len = 0,
            };
        }

        fn slice(sv: @This()) []const u8 {
            if (sv.ptr) |ptr| {
                return ptr[0..sv.len];
            }
            return "";
        }
    };

    const OnModuleInit = *const fn (ctx: ModuleInitContext) callconv(.c) c_int;
    const OnModuleDeinit = *const fn () callconv(.c) void;
    const OnAuth = *const fn (bearer_token: StringView) callconv(.c) c_int;

    onModuleInit: ?OnModuleInit = null,
    onModuleDeinit: ?OnModuleDeinit = null,
    onAuth: ?OnAuth = null,

    fn logDebug(message: StringView) callconv(.c) void {
        log.debug("{s}", .{message.slice()});
    }

    fn logInfo(message: StringView) callconv(.c) void {
        log.info("{s}", .{message.slice()});
    }

    fn logWarn(message: StringView) callconv(.c) void {
        log.warn("{s}", .{message.slice()});
    }

    fn logErr(message: StringView) callconv(.c) void {
        log.err("{s}", .{message.slice()});
    }

    fn getConfigValue(
        module_cfg_store: *const anyopaque,
        key: StringView,
    ) callconv(.c) FFI.StringView {
        const store: *const ConfigProvider.ModuleConfig.Store = @ptrCast(@alignCast(module_cfg_store));
        const value_slice = store.get(key.slice()) orelse {
            return .{
                .ptr = null,
                .len = 0,
            };
        };

        return .{
            .ptr = value_slice.ptr,
            .len = value_slice.len,
        };
    }
};

pub const BearerAuthorizer = struct {
    module: *Module,

    pub fn create(module: *Module, allocator: std.mem.Allocator) error{OutOfMemory}!*BearerAuthorizer {
        const authorizer = try allocator.create(BearerAuthorizer);
        authorizer.* = .{
            .module = module,
        };
        return authorizer;
    }

    pub fn iface(authorizer: *const BearerAuthorizer) auth.Authorizer {
        return .{
            .user_data = authorizer,
            .vtable = .{
                .destroy = destroy,
                .check = check,
            },
        };
    }
    pub fn destroy(user_data: *const anyopaque, allocator: std.mem.Allocator) void {
        const authorizer: *const BearerAuthorizer = @ptrCast(@alignCast(user_data));
        allocator.destroy(authorizer);
    }

    pub fn check(user_data: *const anyopaque, req: *std.http.Server.Request) auth.AuthResult {
        const authorizer: *const BearerAuthorizer = @ptrCast(@alignCast(user_data));
        const token = auth.extractBearerToken(req) catch |err| {
            log.err("extracting bearer token: {}", .{err});
            return .token_error;
        };

        const result = authorizer.module.onAuth(token) catch |err| {
            log.err("module authorization error: {}", .{err});
            return .unexpected_error;
        } orelse {
            log.err("module does not implement on_auth", .{});
            return .unexpected_error;
        };

        return result.toAuthResult();
    }
};

pub const CookieAuthorizer = struct {
    module: *Module,
    cookie_name: []const u8,

    pub fn create(module: *Module, cookie_name: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!*CookieAuthorizer {
        const authorizer = try allocator.create(CookieAuthorizer);
        authorizer.* = .{
            .module = module,
            .cookie_name = cookie_name,
        };
        return authorizer;
    }

    pub fn iface(authorizer: *const CookieAuthorizer) auth.Authorizer {
        return .{
            .user_data = authorizer,
            .vtable = .{
                .destroy = destroy,
                .check = check,
            },
        };
    }

    pub fn destroy(user_data: *const anyopaque, allocator: std.mem.Allocator) void {
        const authorizer: *const CookieAuthorizer = @ptrCast(@alignCast(user_data));
        allocator.destroy(authorizer);
    }

    pub fn check(user_data: *const anyopaque, req: *std.http.Server.Request) auth.AuthResult {
        const authorizer: *const CookieAuthorizer = @ptrCast(@alignCast(user_data));
        const token = auth.extractCookie(req, authorizer.cookie_name) catch |err| {
            log.err("extracting cookie token: {}", .{err});
            return .token_error;
        };

        const result = authorizer.module.onAuth(token) catch |err| {
            log.err("module token authorization error: {}", .{err});
            return .unexpected_error;
        } orelse {
            log.err("module does not implement on_auth", .{});
            return .unexpected_error;
        };

        return result.toAuthResult();
    }
};

const BearerAuthUserData = struct {
    module: *Module,
};

const CookieAuthUserData = struct {
    module: *Module,
    cookie_name: []const u8,

    pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const user_data: @This() = @ptrCast(@alignCast(ptr));
        allocator.destroy(user_data);
    }
};

pub const ModuleInitResult = enum(c_int) {
    ok = 0,
    unexpected_error = 1,
};

pub const ModuleAuthResult = enum(c_int) {
    ok = 0,
    unauthorized = 1,
    unauthenticated = 2,
    unexpected_error = 3,

    pub fn toAuthResult(result: ModuleAuthResult) auth.AuthResult {
        return switch (result) {
            .ok => .ok,
            .unauthorized => .unauthorized,
            .unauthenticated => .unauthenticated,
            .unexpected_error => .unexpected_error,
        };
    }
};

const Module = @This();

pub const Error = error{
    FFILookupFailed,
    FFIOnModuleInitIllegalResultCode,
    FFIOnAuthIllegalResultCode,
    ModuleInitFailed,
};

name: []const u8,
ffi: FFI,
dll: std.DynLib,
config: *const ConfigProvider.ModuleConfig.Store,

pub fn init(
    name: []const u8,
    dll_path: []const u8,
    config: *const ConfigProvider.ModuleConfig.Store,
) (std.DynLib.Error || Error)!Module {
    var dll = try std.DynLib.open(dll_path);
    errdefer dll.close();

    var ffi = FFI{};

    if (dll.lookup(FFI.OnModuleInit, "on_module_init")) |on_module_init| {
        log.info("Registered on_module_init hook", .{});
        ffi.onModuleInit = on_module_init;
    }

    if (dll.lookup(FFI.OnModuleDeinit, "on_module_deinit")) |on_module_deinit| {
        log.info("Registered on_module_deinit hook", .{});
        ffi.onModuleDeinit = on_module_deinit;
    }

    if (dll.lookup(FFI.OnAuth, "on_auth")) |on_auth| {
        log.info("Registered on_auth hook", .{});
        ffi.onAuth = on_auth;
    }

    var module = Module{
        .dll = dll,
        .ffi = ffi,
        .name = name,
        .config = config,
    };

    const init_result = try module.onModuleInit() orelse .ok;
    switch (init_result) {
        .ok => {},
        .unexpected_error => {
            log.err("unexpected error on module init: {s}", .{module.name});
            return Error.ModuleInitFailed;
        },
    }

    return module;
}

pub fn deinit(module: *Module) void {
    module.onModuleDeinit();
    module.dll.close();
}

pub fn onModuleInit(
    module: *const Module,
) Error!?ModuleInitResult {
    const init_ctx: FFI.ModuleInitContext = .init(module.config);

    if (module.ffi.onModuleInit) |hook| {
        return std.enums.fromInt(ModuleInitResult, hook(init_ctx)) orelse Error.FFIOnModuleInitIllegalResultCode;
    }
    return null;
}

pub fn onModuleDeinit(module: *const Module) void {
    if (module.ffi.onModuleDeinit) |hook| {
        hook();
    }
}

pub fn onAuth(module: *const Module, token: []const u8) Error!?ModuleAuthResult {
    if (module.ffi.onAuth) |hook| {
        const token_sv: FFI.StringView = .init(token);
        const r = hook(token_sv);
        return std.enums.fromInt(ModuleAuthResult, r) orelse Error.FFIOnAuthIllegalResultCode;
    }
    return null;
}

pub fn getAuthorizer(
    module: *Module,
    strategy: ConfigProvider.AuthConfig.Strategy,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!auth.Authorizer {
    return switch (strategy) {
        .bearer => (try BearerAuthorizer.create(module, allocator)).iface(),
        .cookie => |cookie_opts| (try CookieAuthorizer.create(module, cookie_opts.cookie_name, allocator)).iface(),
    };
}
