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

pub const AuthClosure = struct {
    pub const FunctionPtr = *const fn (*std.http.Server.Request, *anyopaque) AuthResult;

    f: FunctionPtr,
    ctx: *anyopaque,

    pub fn init(f: FunctionPtr, ctx: *anyopaque) AuthClosure {
        return .{
            .f = f,
            .ctx = ctx,
        };
    }

    pub fn check(cl: AuthClosure, req: *std.http.Server.Request) bool {
        return handleAuthResult(req, cl.f(req, cl.ctx));
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
