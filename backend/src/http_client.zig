const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.http_client);

/// A thin wrapper around std.http.Client that retries on connection errors.
///
/// std.http.Client maintains a connection pool. When the upstream server
/// restarts, pooled connections become stale — but the client has no way
/// to detect this until a request fails. This wrapper catches connection-
/// related errors, resets the pool (deinit + reinit), and retries once.
pub const HttpClient = struct {
    inner: *http.Client,

    pub const Result = struct {
        body: []const u8,
        status: http.Status,
    };

    pub const Error = error{ OutOfMemory, HttpError };

    pub fn init(inner: *http.Client) HttpClient {
        return .{ .inner = inner };
    }

    pub fn get(self: HttpClient, arena: Allocator, url: []const u8) Error!Result {
        for (0..2) |attempt| {
            var buf: Io.Writer.Allocating = .init(arena);
            const result = self.inner.fetch(.{
                .location = .{ .url = url },
                .method = .GET,
                .response_writer = &buf.writer,
            }) catch |err| {
                if (attempt == 0 and isRetryable(err)) {
                    log.warn("GET: {} — retrying", .{err});
                    self.resetPool();
                    continue;
                }
                log.err("GET: {}", .{err});
                return error.HttpError;
            };
            return .{
                .body = buf.writer.buffer[0..buf.writer.end],
                .status = result.status,
            };
        }
        unreachable;
    }

    pub fn post(self: HttpClient, arena: Allocator, url: []const u8, payload: []const u8, content_type: []const u8) Error!Result {
        for (0..2) |attempt| {
            var buf: Io.Writer.Allocating = .init(arena);
            const result = self.inner.fetch(.{
                .location = .{ .url = url },
                .method = .POST,
                .payload = payload,
                .headers = .{ .content_type = .{ .override = content_type } },
                .response_writer = &buf.writer,
            }) catch |err| {
                if (attempt == 0 and isRetryable(err)) {
                    log.warn("POST: {} — retrying", .{err});
                    self.resetPool();
                    continue;
                }
                log.err("POST: {}", .{err});
                return error.HttpError;
            };
            return .{
                .body = buf.writer.buffer[0..buf.writer.end],
                .status = result.status,
            };
        }
        unreachable;
    }

    /// Drop all pooled connections by deiniting and reiniting the inner client.
    fn resetPool(self: HttpClient) void {
        const alloc = self.inner.allocator;
        self.inner.deinit();
        self.inner.* = .{ .allocator = alloc };
        log.warn("reset connection pool", .{});
    }

    /// Errors that indicate a stale or broken connection — resetting the
    /// pool and retrying has a reasonable chance of success.
    fn isRetryable(err: anyerror) bool {
        return switch (err) {
            // Stale pooled connection or upstream went away
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.HttpConnectionClosing,
            error.NetworkUnreachable,
            error.UnexpectedConnectFailure,
            // I/O failure on dead socket
            error.ReadFailed,
            error.WriteFailed,
            // Connection dropped mid-response
            error.HttpRequestTruncated,
            error.HttpChunkTruncated,
            => true,

            // Everything else is deterministic or local — retrying won't help:
            // OOM, bad URL, DNS resolution, TLS config, protocol errors, etc.
            else => false,
        };
    }
};

// -- Tests --

test "isRetryable classifies connection errors" {
    // Connection errors → retryable
    try std.testing.expect(HttpClient.isRetryable(error.ConnectionRefused));
    try std.testing.expect(HttpClient.isRetryable(error.ConnectionResetByPeer));
    try std.testing.expect(HttpClient.isRetryable(error.HttpConnectionClosing));
    try std.testing.expect(HttpClient.isRetryable(error.WriteFailed));
    try std.testing.expect(HttpClient.isRetryable(error.ReadFailed));
    try std.testing.expect(HttpClient.isRetryable(error.ConnectionTimedOut));
    try std.testing.expect(HttpClient.isRetryable(error.HttpRequestTruncated));
    try std.testing.expect(HttpClient.isRetryable(error.HttpChunkTruncated));
}

test "isRetryable rejects local/deterministic errors" {
    // Local/deterministic errors → not retryable
    try std.testing.expect(!HttpClient.isRetryable(error.OutOfMemory));
    try std.testing.expect(!HttpClient.isRetryable(error.UnknownHostName));
    try std.testing.expect(!HttpClient.isRetryable(error.InvalidPort));
}
