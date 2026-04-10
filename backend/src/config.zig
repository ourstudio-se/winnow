const std = @import("std");
const kdl = @import("kdl");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.config);

const default_number_of_workers_per_server = 6;

pub const IndexSettings = struct {
    index_id: []const u8,
    retention: ?[]const u8 = null,
};

pub const ServeCollectorConfig = struct {
    number_of_workers: usize = 6,
    http_port: u16 = 4318,
};
pub const ServeApiConfig = struct {
    number_of_workers: usize = 6,
    http_port: u16 = 8080,
};

pub const ServeConfig = struct {
    collector: ?ServeCollectorConfig = .{},
    api: ?ServeApiConfig = .{},
};

pub const Config = struct {
    quickwit_url: []const u8,
    traces: IndexSettings,
    logs: IndexSettings,
    edges: IndexSettings,
    serve: ServeConfig = .{},
    /// Tracks which strings were heap-allocated (need freeing).
    owned: OwnedStrings = .{},

    const OwnedStrings = struct {
        quickwit_url: bool = false,
        traces_index_id: bool = false,
        traces_retention: bool = false,
        logs_index_id: bool = false,
        logs_retention: bool = false,
        edges_index_id: bool = false,
        edges_retention: bool = false,
    };

    pub fn deinit(self: Config, allocator: Allocator) void {
        if (self.owned.quickwit_url) allocator.free(self.quickwit_url);
        if (self.owned.traces_index_id) allocator.free(self.traces.index_id);
        if (self.owned.traces_retention) allocator.free(self.traces.retention.?);
        if (self.owned.logs_index_id) allocator.free(self.logs.index_id);
        if (self.owned.logs_retention) allocator.free(self.logs.retention.?);
        if (self.owned.edges_index_id) allocator.free(self.edges.index_id);
        if (self.owned.edges_retention) allocator.free(self.edges.retention.?);
    }
};

pub const defaults = Config{
    .quickwit_url = "http://localhost:7280",
    .traces = .{ .index_id = "winnow-traces-v0_1" },
    .logs = .{ .index_id = "winnow-logs-v0_1" },
    .edges = .{ .index_id = "winnow-edges-v0_3" },
};

pub const CliResult = struct {
    config_path: ?[]const u8,
    explicit: bool,
};

/// Parse CLI arguments for --config flag.
pub fn parseCli(allocator: Allocator) !CliResult {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip argv[0]
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            const val = args.next() orelse {
                log.err("--config requires a path argument", .{});
                return error.InvalidArgs;
            };
            return .{ .config_path = try allocator.dupe(u8, val), .explicit = true };
        }
        // Unknown flag
        if (std.mem.startsWith(u8, arg, "-")) {
            log.err("unknown flag: {s}", .{arg});
            return error.InvalidArgs;
        }
    }

    return .{ .config_path = null, .explicit = false };
}

/// Load config: defaults < KDL file < env vars.
/// If `cli_config_path` is null and `explicit` is false, tries ./winnow.kdl as fallback.
pub fn load(allocator: Allocator, cli_config_path: ?[]const u8, explicit: bool) !Config {
    var cfg = defaults;

    // Determine config file path
    const config_path: ?[]const u8 = cli_config_path orelse blk: {
        if (!explicit) {
            // Try ./winnow.kdl as implicit fallback
            std.fs.cwd().access("winnow.kdl", .{}) catch break :blk null;
            break :blk "winnow.kdl";
        }
        break :blk null;
    };

    // Parse KDL file if found
    if (config_path) |path| {
        const file_content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| {
            log.err("failed to read config file '{s}': {}", .{ path, err });
            return error.ConfigFileError;
        };
        defer allocator.free(file_content);

        cfg = parseKdl(allocator, file_content, cfg) catch |err| {
            log.err("failed to parse config file '{s}': {}", .{ path, err });
            return error.ConfigParseError;
        };

        log.info("loaded config from '{s}'", .{path});
    }

    // Override with env vars
    if (std.process.getEnvVarOwned(allocator, "QUICKWIT_URL")) |url| {
        if (cfg.owned.quickwit_url) allocator.free(cfg.quickwit_url);
        cfg.quickwit_url = url;
        cfg.owned.quickwit_url = true;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "WINNOW_TRACES_INDEX")) |idx| {
        if (cfg.owned.traces_index_id) allocator.free(cfg.traces.index_id);
        cfg.traces.index_id = idx;
        cfg.owned.traces_index_id = true;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "WINNOW_LOGS_INDEX")) |idx| {
        if (cfg.owned.logs_index_id) allocator.free(cfg.logs.index_id);
        cfg.logs.index_id = idx;
        cfg.owned.logs_index_id = true;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "WINNOW_EDGES_INDEX")) |idx| {
        if (cfg.owned.edges_index_id) allocator.free(cfg.edges.index_id);
        cfg.edges.index_id = idx;
        cfg.owned.edges_index_id = true;
    } else |_| {}

    return cfg;
}

/// Parse KDL content and overlay onto existing config.
fn parseKdl(allocator: Allocator, source: []const u8, base: Config) !Config {
    var cfg = base;
    errdefer cfg.deinit(allocator);

    var doc = kdl.parse(allocator, source) catch {
        return error.ConfigParseError;
    };
    defer doc.deinit();

    var root_iter = doc.rootIterator();
    while (root_iter.next()) |node| {
        const name = doc.getString(doc.nodes.getName(node));

        if (std.mem.eql(u8, name, "quickwit")) {
            if (getStringProp(&doc, node, "url")) |url| {
                const duped = try allocator.dupe(u8, url);
                if (cfg.owned.quickwit_url) allocator.free(cfg.quickwit_url);
                cfg.quickwit_url = duped;
                cfg.owned.quickwit_url = true;
            }
        } else if (std.mem.eql(u8, name, "traces")) {
            if (getStringProp(&doc, node, "index")) |idx| {
                const duped = try allocator.dupe(u8, idx);
                if (cfg.owned.traces_index_id) allocator.free(cfg.traces.index_id);
                cfg.traces.index_id = duped;
                cfg.owned.traces_index_id = true;
            }
            if (getStringProp(&doc, node, "retention")) |ret| {
                const duped = try allocator.dupe(u8, ret);
                if (cfg.owned.traces_retention) allocator.free(cfg.traces.retention.?);
                cfg.traces.retention = duped;
                cfg.owned.traces_retention = true;
            }
        } else if (std.mem.eql(u8, name, "logs")) {
            if (getStringProp(&doc, node, "index")) |idx| {
                const duped = try allocator.dupe(u8, idx);
                if (cfg.owned.logs_index_id) allocator.free(cfg.logs.index_id);
                cfg.logs.index_id = duped;
                cfg.owned.logs_index_id = true;
            }
            if (getStringProp(&doc, node, "retention")) |ret| {
                const duped = try allocator.dupe(u8, ret);
                if (cfg.owned.logs_retention) allocator.free(cfg.logs.retention.?);
                cfg.logs.retention = duped;
                cfg.owned.logs_retention = true;
            }
        } else if (std.mem.eql(u8, name, "edges")) {
            if (getStringProp(&doc, node, "index")) |idx| {
                const duped = try allocator.dupe(u8, idx);
                if (cfg.owned.edges_index_id) allocator.free(cfg.edges.index_id);
                cfg.edges.index_id = duped;
                cfg.owned.edges_index_id = true;
            }
            if (getStringProp(&doc, node, "retention")) |ret| {
                const duped = try allocator.dupe(u8, ret);
                if (cfg.owned.edges_retention) allocator.free(cfg.edges.retention.?);
                cfg.edges.retention = duped;
                cfg.owned.edges_retention = true;
            }
        } else if (std.mem.eql(u8, name, "serve")) {
            // Start with both disabled; only listed children are enabled
            cfg.serve = .{
                .api = null,
                .collector = null,
            };
            var has_children = false;

            var child_iter = doc.childIterator(node);
            while (child_iter.next()) |child| {
                const child_name = std.meta.stringToEnum(enum {
                    api,
                    collector,
                }, doc.getString(doc.nodes.getName(child))) orelse return error.ConfigParseError;

                const number_of_workers: usize = if (getIntProp(&doc, child, "number_of_workers")) |p|
                    std.math.cast(u16, p) orelse return error.ConfigParseError
                else
                    default_number_of_workers_per_server;

                const http_port: ?u16 = if (getIntProp(&doc, child, "http_port")) |p|
                    std.math.cast(u16, p) orelse return error.ConfigParseError
                else
                    null;

                has_children = true;

                switch (child_name) {
                    .api => {
                        cfg.serve.api = .{
                            .number_of_workers = number_of_workers,
                        };
                        if (http_port) |hp| {
                            cfg.serve.api.?.http_port = hp;
                        }
                    },
                    .collector => {
                        cfg.serve.collector = .{
                            .number_of_workers = number_of_workers,
                        };
                        if (http_port) |hp| {
                            cfg.serve.collector.?.http_port = hp;
                        }
                    },
                }
            }

            if (!has_children) {
                return error.ConfigParseError;
            }
        }
    }

    return cfg;
}

/// Get a string property value from a KDL node.
fn getStringProp(doc: *const kdl.Document, node: kdl.NodeHandle, key: []const u8) ?[]const u8 {
    const prop_range = doc.nodes.getPropRange(node);
    const props = doc.values.getProperties(prop_range);
    for (props) |prop| {
        const prop_name = doc.getString(prop.name);
        if (std.mem.eql(u8, prop_name, key)) {
            switch (prop.value) {
                .string => |s| return doc.getString(s),
                else => return null,
            }
        }
    }
    return null;
}

/// Get an integer property value from a KDL node.
/// Also accepts string values and parses them as integers (e.g. port="4318").
fn getIntProp(doc: *const kdl.Document, node: kdl.NodeHandle, key: []const u8) ?i128 {
    const prop_range = doc.nodes.getPropRange(node);
    const props = doc.values.getProperties(prop_range);
    for (props) |prop| {
        const prop_name = doc.getString(prop.name);
        if (std.mem.eql(u8, prop_name, key)) {
            switch (prop.value) {
                .integer => |i| return i,
                .string => |s| {
                    const str = doc.getString(s);
                    return std.fmt.parseInt(i128, str, 10) catch null;
                },
                else => return null,
            }
        }
    }
    return null;
}

// -- Tests --

test "parseKdl full config" {
    const allocator = std.testing.allocator;
    const source =
        \\quickwit url="http://example.com:7280"
        \\traces index="my-traces" retention="90 days"
        \\logs index="my-logs" retention="30 days"
        \\edges index="my-edges" retention="7 days"
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("http://example.com:7280", cfg.quickwit_url);
    try std.testing.expectEqualStrings("my-traces", cfg.traces.index_id);
    try std.testing.expectEqualStrings("90 days", cfg.traces.retention.?);
    try std.testing.expectEqualStrings("my-logs", cfg.logs.index_id);
    try std.testing.expectEqualStrings("30 days", cfg.logs.retention.?);
    try std.testing.expectEqualStrings("my-edges", cfg.edges.index_id);
    try std.testing.expectEqualStrings("7 days", cfg.edges.retention.?);
}

test "parseKdl partial config uses defaults" {
    const allocator = std.testing.allocator;
    const source =
        \\traces retention="60 days"
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    // URL and index IDs should be defaults
    try std.testing.expectEqualStrings("http://localhost:7280", cfg.quickwit_url);
    try std.testing.expectEqualStrings("winnow-traces-v0_1", cfg.traces.index_id);
    try std.testing.expectEqualStrings("winnow-logs-v0_1", cfg.logs.index_id);
    try std.testing.expectEqualStrings("winnow-edges-v0_3", cfg.edges.index_id);
    // Retention should be set
    try std.testing.expectEqualStrings("60 days", cfg.traces.retention.?);
    try std.testing.expect(cfg.logs.retention == null);
    try std.testing.expect(cfg.edges.retention == null);
}

test "parseKdl empty config uses all defaults" {
    const allocator = std.testing.allocator;
    const cfg = try parseKdl(allocator, "", defaults);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings(defaults.quickwit_url, cfg.quickwit_url);
    try std.testing.expectEqualStrings(defaults.traces.index_id, cfg.traces.index_id);
    try std.testing.expectEqualStrings(defaults.logs.index_id, cfg.logs.index_id);
    try std.testing.expectEqualStrings(defaults.edges.index_id, cfg.edges.index_id);
    try std.testing.expect(cfg.traces.retention == null);
    try std.testing.expect(cfg.logs.retention == null);
    try std.testing.expect(cfg.edges.retention == null);
}

test "defaults have expected values" {
    try std.testing.expectEqualStrings("http://localhost:7280", defaults.quickwit_url);
    try std.testing.expectEqualStrings("winnow-traces-v0_1", defaults.traces.index_id);
    try std.testing.expectEqualStrings("winnow-logs-v0_1", defaults.logs.index_id);
    try std.testing.expectEqualStrings("winnow-edges-v0_3", defaults.edges.index_id);
    try std.testing.expect(defaults.traces.retention == null);
    try std.testing.expect(defaults.logs.retention == null);
    try std.testing.expect(defaults.edges.retention == null);
    // Default serve: both enabled on 8080
    try std.testing.expect(defaults.serve.collector != null);
    try std.testing.expect(defaults.serve.api != null);
    try std.testing.expectEqual(@as(u16, 4318), defaults.serve.collector.?.http_port);
    try std.testing.expectEqual(@as(u16, 8080), defaults.serve.api.?.http_port);
}

test "parseKdl serve block with both components and ports" {
    const allocator = std.testing.allocator;
    const source =
        \\serve {
        \\    collector http_port=4318
        \\    api http_port=8080
        \\}
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.serve.collector != null);
    try std.testing.expect(cfg.serve.api != null);
    try std.testing.expectEqual(@as(u16, 4318), cfg.serve.collector.?.http_port);
    try std.testing.expectEqual(@as(u16, 8080), cfg.serve.api.?.http_port);
}

test "parseKdl serve block with only collector" {
    const allocator = std.testing.allocator;
    const source =
        \\serve {
        \\    collector http_port=4318
        \\}
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.serve.collector != null);
    try std.testing.expect(cfg.serve.api == null);
    try std.testing.expectEqual(@as(u16, 4318), cfg.serve.collector.?.http_port);
}

test "parseKdl serve block with no children is error" {
    const allocator = std.testing.allocator;
    const source =
        \\serve {
        \\}
    ;

    const result = parseKdl(allocator, source, defaults);
    try std.testing.expectError(error.ConfigParseError, result);
}

test "parseKdl no serve block uses defaults" {
    const allocator = std.testing.allocator;
    const source =
        \\quickwit url="http://example.com:7280"
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    // Should keep default serve config: both on 8080
    try std.testing.expect(cfg.serve.collector != null);
    try std.testing.expect(cfg.serve.api != null);
    try std.testing.expectEqual(@as(u16, 4318), cfg.serve.collector.?.http_port);
    try std.testing.expectEqual(@as(u16, 8080), cfg.serve.api.?.http_port);
}

test "parseKdl serve block with port as string" {
    const allocator = std.testing.allocator;
    const source =
        \\serve {
        \\    collector http_port="4318"
        \\    api http_port="9090"
        \\}
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.serve.collector != null);
    try std.testing.expect(cfg.serve.api != null);
    try std.testing.expectEqual(@as(u16, 4318), cfg.serve.collector.?.http_port);
    try std.testing.expectEqual(@as(u16, 9090), cfg.serve.api.?.http_port);
}

test "parseKdl serve block with default port" {
    const allocator = std.testing.allocator;
    const source =
        \\serve {
        \\    collector
        \\    api
        \\}
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.serve.collector != null);
    try std.testing.expect(cfg.serve.api != null);
    try std.testing.expectEqual(@as(u16, 4318), cfg.serve.collector.?.http_port);
    try std.testing.expectEqual(@as(u16, 8080), cfg.serve.api.?.http_port);
}
