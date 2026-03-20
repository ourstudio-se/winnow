const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Io = std.Io;

const log = std.log.scoped(.quickwit);

pub const Quickwit = struct {
    http_client: *http.Client,
    base_url: []const u8,

    pub const IndexExistsError = error{ OutOfMemory, HttpError, UnexpectedStatus };
    pub const CreateIndexError = error{ OutOfMemory, HttpError, CreateIndexFailed };
    pub const EnsureIndexError = IndexExistsError || CreateIndexError;
    pub const IngestError = error{ OutOfMemory, HttpError, IngestFailed };
    pub const SearchError = error{ OutOfMemory, HttpError, SearchFailed };

    pub const SearchResult = struct {
        body: []const u8,
        status: http.Status,
    };

    /// Borrows the http client and base URL — does not own either.
    /// Caller is responsible for the http client lifetime.
    pub fn init(http_client: *http.Client, base_url: []const u8) Quickwit {
        return .{ .http_client = http_client, .base_url = base_url };
    }

    // -- Index management --

    pub fn indexExists(self: Quickwit, arena: Allocator, index_id: []const u8) IndexExistsError!bool {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/indexes/{s}", .{ self.base_url, index_id });

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
        }) catch |err| {
            log.err("indexExists: {}", .{err});
            return error.HttpError;
        };

        return switch (result.status) {
            .ok => true,
            .not_found => false,
            else => {
                log.err("indexExists: unexpected status {d}", .{@intFromEnum(result.status)});
                return error.UnexpectedStatus;
            },
        };
    }

    pub fn createIndex(self: Quickwit, arena: Allocator, config_json: []const u8) CreateIndexError!void {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/indexes", .{self.base_url});

        var response_buf: Io.Writer.Allocating = .init(arena);

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = config_json,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_buf.writer,
        }) catch |err| {
            log.err("createIndex: {}", .{err});
            return error.HttpError;
        };

        if (result.status != .ok) {
            const body = response_buf.writer.buffer[0..response_buf.writer.end];
            log.err("createIndex failed ({d}): {s}", .{ @intFromEnum(result.status), body });
            return error.CreateIndexFailed;
        }
    }

    pub fn ensureIndex(self: Quickwit, arena: Allocator, index_id: []const u8, config_json: []const u8) EnsureIndexError!void {
        if (try self.indexExists(arena, index_id)) {
            log.info("index '{s}' already exists", .{index_id});
            return;
        }
        log.info("creating index '{s}'", .{index_id});
        try self.createIndex(arena, config_json);
    }

    // -- Ingest --

    pub fn ingest(self: Quickwit, arena: Allocator, index_id: []const u8, ndjson_body: []const u8) IngestError!void {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/{s}/ingest", .{ self.base_url, index_id });

        var response_buf: Io.Writer.Allocating = .init(arena);

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = ndjson_body,
            .headers = .{ .content_type = .{ .override = "application/x-ndjson" } },
            .response_writer = &response_buf.writer,
        }) catch |err| {
            log.err("ingest: {}", .{err});
            return error.HttpError;
        };

        if (result.status != .ok) {
            const body = response_buf.writer.buffer[0..response_buf.writer.end];
            log.err("ingest failed ({d}): {s}", .{ @intFromEnum(result.status), body });
            return error.IngestFailed;
        }
    }

    // -- Search --

    /// Returns the raw response body, allocated in `arena`.
    pub fn search(self: Quickwit, arena: Allocator, index_id: []const u8, query_json: []const u8) SearchError![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/{s}/search", .{ self.base_url, index_id });

        var response_buf: Io.Writer.Allocating = .init(arena);

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = query_json,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_buf.writer,
        }) catch |err| {
            log.err("search: {}", .{err});
            return error.HttpError;
        };

        if (result.status != .ok) {
            const body = response_buf.writer.buffer[0..response_buf.writer.end];
            log.err("search failed ({d}): {s}", .{ @intFromEnum(result.status), body });
            return error.SearchFailed;
        }

        return response_buf.writer.buffer[0..response_buf.writer.end];
    }

    /// Like search(), but returns the raw response body and HTTP status
    /// instead of failing on non-200. Used by the search proxy to forward
    /// Quickwit's response (including errors) to the frontend.
    pub fn searchRaw(self: Quickwit, arena: Allocator, index_id: []const u8, query_json: []const u8) error{ OutOfMemory, HttpError }!SearchResult {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/{s}/search", .{ self.base_url, index_id });

        var response_buf: Io.Writer.Allocating = .init(arena);

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = query_json,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_buf.writer,
        }) catch |err| {
            log.err("searchRaw: {}", .{err});
            return error.HttpError;
        };

        return .{
            .body = response_buf.writer.buffer[0..response_buf.writer.end],
            .status = result.status,
        };
    }
};

// -- Tests --

test "init" {
    var http_client: http.Client = .{ .allocator = std.testing.allocator };
    defer http_client.deinit();
    const qw = Quickwit.init(&http_client, "http://localhost:7280");
    try std.testing.expectEqualStrings("http://localhost:7280", qw.base_url);
}

test "allocPrint url formats" {
    const allocator = std.testing.allocator;

    const index_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/indexes/{s}", .{ "http://localhost:7280", "otel-traces-v0_9" });
    defer allocator.free(index_url);
    try std.testing.expectEqualStrings("http://localhost:7280/api/v1/indexes/otel-traces-v0_9", index_url);

    const ingest_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/{s}/ingest", .{ "http://localhost:7280", "otel-traces-v0_9" });
    defer allocator.free(ingest_url);
    try std.testing.expectEqualStrings("http://localhost:7280/api/v1/otel-traces-v0_9/ingest", ingest_url);

    const search_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/{s}/search", .{ "http://localhost:7280", "otel-traces-v0_9" });
    defer allocator.free(search_url);
    try std.testing.expectEqualStrings("http://localhost:7280/api/v1/otel-traces-v0_9/search", search_url);
}
