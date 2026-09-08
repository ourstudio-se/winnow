const std = @import("std");

const log = std.log.scoped(.http_errors);

pub fn sendNotFound(request: *std.http.Server.Request) void {
    request.respond("Not Found\n", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    }) catch |err| {
        log.err("failed sending response: {}", .{err});
    };
}

pub fn sendForbidden(request: *std.http.Server.Request) void {
    request.respond("Forbidden\n", .{
        .status = .forbidden,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    }) catch |err| {
        log.err("failed sending response: {}", .{err});
    };
}

pub fn sendUnauthorized(request: *std.http.Server.Request) void {
    request.respond("Unauthorized\n", .{
        .status = .unauthorized,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    }) catch |err| {
        log.err("failed sending response: {}", .{err});
    };
}

pub fn sendInternalServerError(request: *std.http.Server.Request) void {
    request.respond("Internal Server Error\n", .{
        .status = .internal_server_error,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    }) catch |err| {
        log.err("failed sending response: {}", .{err});
    };
}

pub fn sendMethodNotAllowed(request: *std.http.Server.Request, allowed_method: std.http.Method) void {
    request.respond("Method Not Allowed\n", .{
        .status = .method_not_allowed,
        .extra_headers = &.{
            .{
                .name = "allow",
                .value = @tagName(allowed_method),
            },
            .{
                .name = "content-type",
                .value = "text/plain",
            },
        },
    }) catch |err| {
        log.err("failed sending response: {}", .{err});
    };
}
