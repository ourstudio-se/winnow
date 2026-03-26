const std = @import("std");
const kdl = @import("kdl");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.config);

pub const IndexSettings = struct {
    index_id: []const u8,
    retention: ?[]const u8 = null,
};

pub const Config = struct {
    quickwit_url: []const u8,
    traces: IndexSettings,
    logs: IndexSettings,
    /// Tracks which strings were heap-allocated (need freeing).
    owned: OwnedStrings = .{},

    const OwnedStrings = struct {
        quickwit_url: bool = false,
        traces_index_id: bool = false,
        traces_retention: bool = false,
        logs_index_id: bool = false,
        logs_retention: bool = false,
    };

    pub fn deinit(self: Config, allocator: Allocator) void {
        if (self.owned.quickwit_url) allocator.free(self.quickwit_url);
        if (self.owned.traces_index_id) allocator.free(self.traces.index_id);
        if (self.owned.traces_retention) allocator.free(self.traces.retention.?);
        if (self.owned.logs_index_id) allocator.free(self.logs.index_id);
        if (self.owned.logs_retention) allocator.free(self.logs.retention.?);
    }
};

pub const defaults = Config{
    .quickwit_url = "http://localhost:7280",
    .traces = .{ .index_id = "winnow-traces-v0_1" },
    .logs = .{ .index_id = "winnow-logs-v0_1" },
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

// -- Tests --

test "parseKdl full config" {
    const allocator = std.testing.allocator;
    const source =
        \\quickwit url="http://example.com:7280"
        \\traces index="my-traces" retention="90 days"
        \\logs index="my-logs" retention="30 days"
    ;

    const cfg = try parseKdl(allocator, source, defaults);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("http://example.com:7280", cfg.quickwit_url);
    try std.testing.expectEqualStrings("my-traces", cfg.traces.index_id);
    try std.testing.expectEqualStrings("90 days", cfg.traces.retention.?);
    try std.testing.expectEqualStrings("my-logs", cfg.logs.index_id);
    try std.testing.expectEqualStrings("30 days", cfg.logs.retention.?);
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
    // Retention should be set
    try std.testing.expectEqualStrings("60 days", cfg.traces.retention.?);
    try std.testing.expect(cfg.logs.retention == null);
}

test "parseKdl empty config uses all defaults" {
    const allocator = std.testing.allocator;
    const cfg = try parseKdl(allocator, "", defaults);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings(defaults.quickwit_url, cfg.quickwit_url);
    try std.testing.expectEqualStrings(defaults.traces.index_id, cfg.traces.index_id);
    try std.testing.expectEqualStrings(defaults.logs.index_id, cfg.logs.index_id);
    try std.testing.expect(cfg.traces.retention == null);
    try std.testing.expect(cfg.logs.retention == null);
}

test "defaults have expected values" {
    try std.testing.expectEqualStrings("http://localhost:7280", defaults.quickwit_url);
    try std.testing.expectEqualStrings("winnow-traces-v0_1", defaults.traces.index_id);
    try std.testing.expectEqualStrings("winnow-logs-v0_1", defaults.logs.index_id);
    try std.testing.expect(defaults.traces.retention == null);
    try std.testing.expect(defaults.logs.retention == null);
}
