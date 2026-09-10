const std = @import("std");
const Server = @import("server.zig");
const Module = @import("module.zig");
const http_errors = @import("http_errors.zig");

const log = std.log.scoped(.auth);

pub const AuthResult = enum(i32) {
    ok = 0,
    unauthorized = 1,
    unauthenticated = 2,
    unexpected_error = 3,
    token_error = 100,
};

pub const Authorizer = struct {
    pub const CheckFn = *const fn (*const anyopaque, *std.http.Server.Request) AuthResult;
    pub const DestroyFn = *const fn (*const anyopaque, std.mem.Allocator) void;

    pub const VTable = struct {
        check: CheckFn,
        destroy: DestroyFn,
    };

    vtable: VTable,
    user_data: *const anyopaque,

    pub fn init(user_data: *const anyopaque, checkFn: CheckFn, destroyFn: DestroyFn) Authorizer {
        return .{
            .vtable = .{
                .check = checkFn,
                .destroy = destroyFn,
            },
            .user_data = user_data,
        };
    }

    pub fn check(cl: Authorizer, req: *std.http.Server.Request) bool {
        return handleAuthResult(req, cl.vtable.check(cl.user_data, req));
    }

    pub fn destroy(cl: Authorizer, allocator: std.mem.Allocator) void {
        cl.vtable.destroy(cl.user_data, allocator);
    }
};

pub fn extractBearerToken(request: *std.http.Server.Request) ![]const u8 {
    const prefix = "Bearer ";
    const bearer_prefix_length = prefix.len;

    var header_it = request.iterateHeaders();
    while (header_it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "Authorization") or header.value.len < bearer_prefix_length) {
            continue;
        }
        const value_prefix = header.value[0..bearer_prefix_length];
        if (std.ascii.eqlIgnoreCase(value_prefix, prefix)) {
            const slice = header.value[bearer_prefix_length..];
            return slice;
        }
    }

    return "";
}

pub fn extractCookie(request: *std.http.Server.Request, cookie_name: []const u8) ![]const u8 {
    const cookie_str: []const u8 = blk: {
        var header_it = request.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Cookie")) {
                break :blk header.value;
            }
        }
        break :blk null;
    } orelse {
        return "";
    };

    var cookies_it = std.mem.splitScalar(u8, cookie_str, ';');
    while (cookies_it.next()) |cookie_raw| {
        const sep = '=';
        const key_raw = std.mem.sliceTo(cookie_raw, sep);
        if (key_raw.len == cookie_raw.len) {
            continue;
        }
        const key = std.mem.trim(u8, key_raw, " ");
        if (!std.ascii.eqlIgnoreCase(key, cookie_name)) {
            continue;
        }
        const value = std.mem.trim(u8, cookie_raw[key_raw.len + 1 ..], " ");
        return value;
    }

    return "";
}

fn handleAuthResult(request: *std.http.Server.Request, result: AuthResult) bool {
    return switch (result) {
        .ok => true,
        .unauthorized => {
            http_errors.sendForbidden(request);
            return false;
        },
        .unauthenticated => {
            http_errors.sendUnauthorized(request);
            return false;
        },
        .token_error, .unexpected_error => {
            http_errors.sendInternalServerError(request);
            return false;
        },
    };
}
