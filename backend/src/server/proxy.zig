const std = @import("std");

pub fn proxy(
    io: std.Io,
    allocator: std.mem.Allocator,
    req: *std.http.Server.Request,
    upstream: std.Uri,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);

    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host") or
            std.ascii.eqlIgnoreCase(h.name, "connection") or
            std.ascii.eqlIgnoreCase(h.name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(h.name, "expect"))
            continue;
        try headers.append(allocator, h);
    }

    var uri = upstream;
    uri.path = .{ .percent_encoded = req.head.target };

    var ureq = try client.request(req.head.method, uri, .{
        .extra_headers = headers.items,
    });
    defer ureq.deinit();

    // Preserve the incoming request's framing.
    ureq.transfer_encoding = switch (req.head.transfer_encoding) {
        .chunked => .chunked,
        .none => .none,
    };

    var in_buf: [16 * 1024]u8 = undefined;
    var in = try req.readerExpectContinue(&in_buf);

    if (req.head.method.requestHasBody()) {
        var out_buf: [16 * 1024]u8 = undefined;
        var out = try ureq.sendBody(&out_buf);

        _ = try in.streamRemaining(&out.writer);
        try out.end();
    } else {
        try ureq.sendBodiless();
    }

    var response_buf: [16 * 1024]u8 = undefined;
    var response = try ureq.receiveHead(&response_buf);

    var response_headers: std.ArrayList(std.http.Header) = .empty;
    defer response_headers.deinit(allocator);

    var rh = response.head.iterateHeaders();
    while (rh.next()) |h|
        try response_headers.append(allocator, h);

    var out_buf: [16 * 1024]u8 = undefined;
    var out = try req.respondStreaming(&out_buf, .{
        .content_length = response.head.content_length,
        .respond_options = .{
            .status = response.head.status,
            .extra_headers = response_headers.items,
        },
    });

    var body_buf: [16 * 1024]u8 = undefined;
    _ = try response.reader(&body_buf).streamRemaining(&out.writer);
    try out.end();
}
