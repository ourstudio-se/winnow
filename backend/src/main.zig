const Allocator = std.mem.Allocator;
const ConfigProvider = @import("config.zig");
const HttpClient = quickwit_mod.HttpClient;
const Module = @import("server/module.zig");
const Quickwit = quickwit_mod.Quickwit;
const Role = @import("server/role.zig");
const Server = @import("server/server.zig");
const api = @import("api.zig");
const auth = @import("server/auth.zig");
const http = std.http;
const index_schema = @import("index_schema.zig");
const ingest = @import("ingest.zig");
const logs_otlp = @import("proto/opentelemetry/proto/collector/logs/v1.pb.zig");
const otel_index = @import("otel_index.zig");
const otel_logs_index = @import("otel_logs_index.zig");
const otlp = @import("proto/opentelemetry/proto/collector/trace/v1.pb.zig");
const quickwit_mod = @import("quickwit.zig");
const schema_validation = @import("schema_validation.zig");
const service_edges_index = @import("service_edges_index.zig");
const std = @import("std");

var modules: std.StringHashMapUnmanaged(Module) = .{};
var servers_by_port: std.AutoHashMapUnmanaged(u16, *Server) = .{};
var shutting_down = std.atomic.Value(bool).init(false);

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    shutting_down.store(true, .release);
}

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

fn createAuthorizer(authorizer_cfg: ConfigProvider.AuthConfig, allocator: std.mem.Allocator) !auth.Authorizer {
    switch (authorizer_cfg.inner_config) {
        .module => |auth_module_cfg| {
            const module = modules.getPtr(auth_module_cfg.module_name) orelse {
                return error.AuthMissingModule;
            };
            if (module.ffi.onAuth == null) {
                return error.AuthModuleMissingHook;
            }
            return try module.getAuthorizer(authorizer_cfg.strategy, allocator);
        },
    }
}

fn createRole(config: *const ConfigProvider.Config, role_cfg: ConfigProvider.ServeConfig.RoleConfig, allocator: std.mem.Allocator) !Role {
    const authorizer_name = role_cfg.authorizer_name;
    const authorizer = if (authorizer_name) |name| blk: {
        const authorizer_cfg = config.auth.get(name) orelse {
            std.log.err("Referenced authorizer is not configured: {s}", .{name});
            return error.MissingAuthorizer;
        };
        break :blk try createAuthorizer(authorizer_cfg, allocator);
    } else null;

    return switch (role_cfg.inner) {
        .ui => |ui_inner| (try Role.UIRole.create(authorizer, ui_inner, allocator)).interface,
        .api => Role.ApiRole.init(authorizer).interface,
        .collector => Role.CollectorRole.init(authorizer).interface,
    };
}

pub fn main(init: std.process.Init) !void {
    // init.gpa is leak-checked in Debug builds; init.io is a thread-pool-backed
    // Io implementation shared by the whole process.
    const allocator = init.gpa;
    const io = init.io;

    var provider = ConfigProvider.initProvider(allocator);
    try provider.loadFromIo(init);

    defer {
        var servers_it = servers_by_port.valueIterator();
        while (servers_it.next()) |server| {
            server.*.destroy();
        }

        var modules_it = modules.valueIterator();
        while (modules_it.next()) |module| {
            module.deinit();
        }

        servers_by_port.deinit(allocator);
        defer modules.deinit(allocator);

        std.log.info("deiniting config provider", .{});
        provider.deinit();
    }

    var http_client: http.Client = .{ .allocator = allocator, .io = io };
    defer {
        std.log.debug("deiniting http client", .{});
        http_client.deinit();
    }

    const cfg = provider.config;

    // Determine serving topology from config
    const serve = cfg.serve;

    if (serve.size == 0) {
        std.log.err("no serve components enabled", .{});
        return error.NoComponentsEnabled;
    }

    std.log.info("connecting to Quickwit at {s}", .{cfg.quickwit_url});
    const client = HttpClient.init(&http_client);
    const qw = Quickwit.init(client, cfg.quickwit_url);

    // Only validate indices when non-ui roles are served
    if (cfg.ensure_indices) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // Traces index
        try ensureOrValidateIndex(arena.allocator(), qw, cfg.traces.index_id, otel_index.schema, cfg.traces.retention);

        // Logs index
        try ensureOrValidateIndex(arena.allocator(), qw, cfg.logs.index_id, otel_logs_index.schema, cfg.logs.retention);

        // Edges index
        try ensureOrValidateIndex(arena.allocator(), qw, cfg.edges.index_id, service_edges_index.schema, cfg.edges.retention);
    }

    const indices = api.IndexConfig{
        .traces = cfg.traces.index_id,
        .logs = cfg.logs.index_id,
        .edges = cfg.edges.index_id,
    };

    var graceful_shutdown: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };

    std.posix.sigaction(std.posix.SIG.INT, &graceful_shutdown, null);

    var module_cfg_it = cfg.modules.valueIterator();
    while (module_cfg_it.next()) |module_cfg| {
        std.log.info("🔌 Loading module {s} ({s})...", .{ module_cfg.name, module_cfg.dll_path });
        var module = try Module.init(module_cfg.name, module_cfg.dll_path, &module_cfg.config);
        errdefer module.deinit();

        try modules.put(allocator, module_cfg.name, module);
    }

    var serve_it = serve.valueIterator();
    while (serve_it.next()) |serve_cfg| {
        var roles: Server.Roles = .{};

        if (serve_cfg.roles.api) |role_cfg| {
            roles.api = try createRole(&cfg, role_cfg, allocator);
        }
        errdefer if (roles.api) |api_role| api_role.destroy(allocator);

        if (serve_cfg.roles.collector) |role_cfg| {
            roles.collector = try createRole(&cfg, role_cfg, allocator);
        }
        errdefer if (roles.collector) |collector_role| collector_role.destroy(allocator);

        if (serve_cfg.roles.ui) |role_cfg| {
            roles.ui = try createRole(&cfg, role_cfg, allocator);
        }
        errdefer if (roles.ui) |ui_role| ui_role.destroy(allocator);

        const server = try Server.create(
            allocator,
            io,
            .{
                .indices = indices,
                .number_of_workers = serve_cfg.number_of_workers,
                .port = serve_cfg.http_port,
                .quickwit_url = cfg.quickwit_url,
            },
            roles,
        );

        try servers_by_port.put(allocator, serve_cfg.http_port, server);
    }

    var group: std.Io.Group = .init;

    var server_iterator = servers_by_port.valueIterator();

    while (server_iterator.next()) |serverPtr| {
        try group.concurrent(io, Server.run, .{serverPtr.*});
    }

    while (true) {
        if (shutting_down.load(.acquire)) {
            break;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }

    // Tell server threads to close gracefully
    var servers_it = servers_by_port.valueIterator();
    while (servers_it.next()) |server_ptr| {
        server_ptr.*.close();
    }

    // Wait for server threads to clean up
    group.await(io) catch {};

    std.log.debug("exiting main thread", .{});
}

test "otlp proto types are importable" {
    _ = otlp.ExportTraceServiceRequest;
    _ = otlp.ExportTraceServiceResponse;
}

test "otlp log proto types are importable" {
    _ = logs_otlp.ExportLogsServiceRequest;
    _ = logs_otlp.ExportLogsServiceResponse;
}

test "otlp metrics proto types are importable" {
    const metrics_otlp = @import("proto/opentelemetry/proto/collector/metrics/v1.pb.zig");
    _ = metrics_otlp.ExportMetricsServiceRequest;
    _ = metrics_otlp.ExportMetricsServiceResponse;
}

test {
    _ = HttpClient;
    _ = Quickwit;
    _ = Server;
    _ = otel_index;
    _ = otel_logs_index;
    _ = service_edges_index;
    _ = index_schema;
    _ = ConfigProvider;
    _ = schema_validation;
    _ = ingest;
    _ = api;
}
