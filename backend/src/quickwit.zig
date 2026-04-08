const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;

pub const HttpClient = @import("http_client.zig").HttpClient;

const log = std.log.scoped(.quickwit);

pub const Quickwit = struct {
    client: HttpClient,
    base_url: []const u8,

    pub const IndexExistsError = error{ OutOfMemory, HttpError, UnexpectedStatus };
    pub const CreateIndexError = error{ OutOfMemory, HttpError, CreateIndexFailed };
    pub const EnsureIndexError = IndexExistsError || CreateIndexError;
    pub const IngestError = error{ OutOfMemory, HttpError, IngestFailed };
    pub const SearchError = error{ OutOfMemory, HttpError, SearchFailed };

    pub const SearchResult = HttpClient.Result;

    pub fn init(client: HttpClient, base_url: []const u8) Quickwit {
        return .{ .client = client, .base_url = base_url };
    }

    // -- Index management --

    pub fn indexExists(self: Quickwit, arena: Allocator, index_id: []const u8) IndexExistsError!bool {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/indexes/{s}", .{ self.base_url, index_id });
        const result = try self.client.get(arena, url);
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
        const result = try self.client.post(arena, url, config_json, "application/json");
        if (result.status != .ok) {
            log.err("createIndex failed ({d}): {s}", .{ @intFromEnum(result.status), result.body });
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
        const result = try self.client.post(arena, url, ndjson_body, "application/x-ndjson");
        if (result.status != .ok) {
            log.err("ingest failed ({d}): {s}", .{ @intFromEnum(result.status), result.body });
            return error.IngestFailed;
        }
    }

    // -- Search --

    /// Returns the raw response body, allocated in `arena`.
    pub fn search(self: Quickwit, arena: Allocator, index_id: []const u8, query_json: []const u8) SearchError![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/{s}/search", .{ self.base_url, index_id });
        const result = try self.client.post(arena, url, query_json, "application/json");
        if (result.status != .ok) {
            log.err("search failed ({d}): {s}", .{ @intFromEnum(result.status), result.body });
            return error.SearchFailed;
        }
        return result.body;
    }

    /// Returns the raw index metadata response from Quickwit.
    pub fn getIndexMetadata(self: Quickwit, arena: Allocator, index_id: []const u8) HttpClient.Error!SearchResult {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/indexes/{s}", .{ self.base_url, index_id });
        return self.client.get(arena, url);
    }

    /// Like search(), but returns the raw response body and HTTP status
    /// instead of failing on non-200. Used by the search proxy to forward
    /// Quickwit's response (including errors) to the frontend.
    pub fn searchRaw(self: Quickwit, arena: Allocator, index_id: []const u8, query_json: []const u8) HttpClient.Error!SearchResult {
        const url = try std.fmt.allocPrint(arena, "{s}/api/v1/{s}/search", .{ self.base_url, index_id });
        std.log.debug("search {s}: {s}", .{ index_id, query_json });
        return self.client.post(arena, url, query_json, "application/json");
    }
};

// -- Tests --

test "init" {
    var http_client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer http_client.deinit();
    const client = HttpClient.init(&http_client);
    const qw = Quickwit.init(client, "http://localhost:7280");
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
