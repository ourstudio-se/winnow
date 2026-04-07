const std = @import("std");
const static_assets = @import("static_assets.zig");

pub fn handleStatic(request: *std.http.Server.Request) !void {
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
