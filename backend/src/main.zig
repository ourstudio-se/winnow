const std = @import("std");
const net = std.net;
const http = std.http;
const Allocator = std.mem.Allocator;
const otlp = @import("proto/opentelemetry/proto/collector/trace/v1.pb.zig");
const logs_otlp = @import("proto/opentelemetry/proto/collector/logs/v1.pb.zig");
const Quickwit = @import("quickwit.zig").Quickwit;
const otel_index = @import("otel_index.zig");
const otel_logs_index = @import("otel_logs_index.zig");
const index_schema = @import("index_schema.zig");
const ingest = @import("ingest.zig");
const api = @import("api.zig");
const static_assets = @import("static_assets.zig");

const IndexConfig = struct {
    traces: []const u8,
    logs: []const u8,
};

const Context = struct {
    qw: Quickwit,
    allocator: Allocator,
    indexes: IndexConfig,
};

const config_mod = @import("config.zig");
const schema_validation = @import("schema_validation.zig");

fn ensureOrValidateIndex(
    arena: Allocator,
    qw: Quickwit,
    index_id: []const u8,
    schema: index_schema.IndexSchema,
    retention: ?[]const u8,
) !void {
    if (qw.indexExists(arena, index_id) catch |err| {
        std.log.err("failed to check index '{s}': {}", .{ index_id, err });
        return err;
    }) {
        std.log.info("index '{s}' already exists, validating schema", .{index_id});

        const result = qw.getIndexMetadata(arena, index_id) catch |err| {
            std.log.err("failed to get metadata for '{s}': {}", .{ index_id, err });
            return err;
        };

        if (result.status != .ok) {
            std.log.err("unexpected status {d} fetching metadata for '{s}'", .{ @intFromEnum(result.status), index_id });
            return error.UnexpectedStatus;
        }

        const mismatches = schema_validation.validateSchema(arena, schema.field_mappings, result.body) catch |err| {
            std.log.err("schema validation failed for '{s}': {}", .{ index_id, err });
            return err;
        };

        if (mismatches.len > 0) {
            std.log.err("schema mismatch for index '{s}':", .{index_id});
            for (mismatches) |m| {
                switch (m) {
                    .missing_field => |name| std.log.err("  missing field: {s}", .{name}),
                    .type_mismatch => |info| std.log.err("  field '{s}': expected type '{s}', got '{s}'", .{ info.field, info.expected, info.actual }),
                    .tokenizer_mismatch => |info| std.log.err("  field '{s}': expected tokenizer '{s}', got '{s}'", .{ info.field, info.expected, info.actual }),
                }
            }
            return error.SchemaMismatch;
        }

        // Check retention (warn only)
        if (schema_validation.checkRetention(arena, retention, result.body) catch null) |ret_mismatch| {
            std.log.warn("retention mismatch for '{s}': configured '{s}', actual '{s}'", .{
                index_id,
                ret_mismatch.expected orelse "(none)",
                ret_mismatch.actual orelse "(none)",
            });
        }
    } else {
        std.log.info("creating index '{s}'", .{index_id});
        const config_json = try index_schema.buildIndexConfig(arena, index_id, schema, retention);
        qw.createIndex(arena, config_json) catch |err| {
            std.log.err("failed to create index '{s}': {}", .{ index_id, err });
            return err;
        };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args and load config
    const cli = config_mod.parseCli(allocator) catch {
        return;
    };
    defer if (cli.config_path) |p| allocator.free(p);

    const cfg = config_mod.load(allocator, cli.config_path, cli.explicit) catch |err| {
        std.log.err("failed to load config: {}", .{err});
        return err;
    };
    defer cfg.deinit(allocator);

    var http_client: http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const qw = Quickwit.init(&http_client, cfg.quickwit_url);

    std.log.info("connecting to Quickwit at {s}", .{cfg.quickwit_url});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // Traces index
        try ensureOrValidateIndex(arena.allocator(), qw, cfg.traces.index_id, otel_index.schema, cfg.traces.retention);

        // Logs index
        try ensureOrValidateIndex(arena.allocator(), qw, cfg.logs.index_id, otel_logs_index.schema, cfg.logs.retention);
    }

    // Start HTTP server
    const address = net.Address.parseIp("0.0.0.0", 8080) catch unreachable;
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.log.info("listening on http://0.0.0.0:8080", .{});

    const ctx = Context{
        .qw = qw,
        .allocator = allocator,
        .indexes = .{
            .traces = cfg.traces.index_id,
            .logs = cfg.logs.index_id,
        },
    };

    while (true) {
        const conn = try server.accept();
        _ = std.Thread.spawn(.{}, handleConnection, .{ conn, &ctx }) catch |err| {
            std.log.err("failed to spawn thread: {}", .{err});
            continue;
        };
    }
}

fn handleConnection(conn: net.Server.Connection, ctx: *const Context) void {
    defer conn.stream.close();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = net.Stream.Reader.init(conn.stream, &read_buf);
    var writer = net.Stream.Writer.init(conn.stream, &write_buf);
    var http_server = http.Server.init(reader.interface(), &writer.interface);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("failed to receive request: {}", .{err});
        return;
    };

    // Per-request arena
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    // Route
    if (std.mem.eql(u8, request.head.target, "/v1/traces")) {
        if (request.head.method == .POST) {
            ingest.handleTraces(&request, arena.allocator(), ctx.qw, ctx.indexes.traces) catch |err| {
                std.log.err("ingest error: {}", .{err});
            };
        } else {
            request.respond("Method Not Allowed\n", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            }) catch {};
        }
    } else if (std.mem.eql(u8, request.head.target, "/v1/logs")) {
        if (request.head.method == .POST) {
            ingest.handleLogs(&request, arena.allocator(), ctx.qw, ctx.indexes.logs) catch |err| {
                std.log.err("log ingest error: {}", .{err});
            };
        } else {
            request.respond("Method Not Allowed\n", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            }) catch {};
        }
    } else if (std.mem.startsWith(u8, request.head.target, "/api/")) {
        api.handleApi(&request, arena.allocator(), ctx.qw, &ctx.indexes) catch |err| {
            std.log.err("api error: {}", .{err});
        };
    } else {
        handleStatic(&request) catch |err| {
            std.log.err("static error: {}", .{err});
        };
    }
}

fn handleStatic(request: *http.Server.Request) !void {
    // Strip query string for lookup
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (static_assets.lookup(path)) |asset| {
        const cache_header: http.Header = if (asset.cacheable)
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

test "static asset lookup" {
    // Verify the lookup function exists and returns null for unknown paths
    const result = static_assets.lookup("/nonexistent");
    try std.testing.expect(result == null);

    // Root should resolve to index.html
    const root = static_assets.lookup("/");
    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings("text/html", root.?.content_type);
    try std.testing.expect(!root.?.cacheable);
}

test "otlp proto types are importable" {
    _ = otlp.ExportTraceServiceRequest;
    _ = otlp.ExportTraceServiceResponse;
}

test "otlp log proto types are importable" {
    _ = logs_otlp.ExportLogsServiceRequest;
    _ = logs_otlp.ExportLogsServiceResponse;
}

test {
    _ = Quickwit;
    _ = otel_index;
    _ = otel_logs_index;
    _ = index_schema;
    _ = config_mod;
    _ = schema_validation;
    _ = ingest;
    _ = api;
}
