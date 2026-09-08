const std = @import("std");
const kdl = @import("kdl");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.config);

const default_number_of_workers_per_server = 6;

pub const Error = error{
    ConfigParseError,
    ConfigFileError,
    InvalidArgs,
    OutOfMemory,
};

pub const IndexSettings = struct {
    index_id: []const u8,
    retention: ?[]const u8 = null,
};

pub const ServeCollectorConfig = struct {
    number_of_workers: usize = 6,
    http_port: u16 = 4318,
    authorizer: ?[]const u8 = null,
};
pub const ServeApiConfig = struct {
    number_of_workers: usize = 6,
    http_port: u16 = 8080,
    authorizer: ?[]const u8 = null,
};

pub const ModuleConfig = struct {
    pub const Store = std.StringArrayHashMapUnmanaged([]const u8);

    name: []const u8,
    dll_path: []const u8,
    config: Store,

    pub fn deinit(module_config: *ModuleConfig, allocator: std.mem.Allocator) void {
        module_config.config.deinit(allocator);
    }
};

pub const AuthConfig = struct {
    pub const ModuleConfig = struct {
        module_name: []const u8,
    };

    pub const Kind = enum {
        module,
    };

    pub const Strategy = enum {
        bearer,
    };

    pub const InnerConfig = union(Kind) {
        module: AuthConfig.ModuleConfig,
    };

    strategy: Strategy,
    name: []const u8,
    login_url: []const u8,
    logout_url: []const u8,
    inner_config: InnerConfig,
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
    modules: std.StringHashMapUnmanaged(ModuleConfig) = .{},
    auth: std.StringHashMapUnmanaged(AuthConfig) = .{},
};

pub const ConfigProvider = @This();

kdl_doc: ?kdl.Document = null,
allocator: std.mem.Allocator,
config: Config = defaults,

pub const defaults = Config{
    .quickwit_url = "http://localhost:7280",
    .traces = .{ .index_id = "winnow-traces-v0_1" },
    .logs = .{ .index_id = "winnow-logs-v0_1" },
    .edges = .{ .index_id = "winnow-edges-v0_3" },
};

/// Get an integer property value from a KDL node.
pub fn deinit(provider: *ConfigProvider) void {
    provider.config.auth.deinit(provider.allocator);

    var module_it = provider.config.modules.valueIterator();
    while (module_it.next()) |module| {
        module.deinit(provider.allocator);
    }

    provider.config.modules.deinit(provider.allocator);

    if (provider.kdl_doc) |*doc| {
        doc.deinit();
    }
}

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

fn getStringArg(doc: *const kdl.Document, node: kdl.NodeHandle, idx: usize) ?[]const u8 {
    const arg_range = doc.nodes.getArgRange(node);
    if (idx >= arg_range.count) {
        return null;
    }
    const args = doc.values.getArguments(arg_range);
    const arg = args[idx];
    return switch (arg.value) {
        .string => |s| doc.getString(s),
        else => null,
    };
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

pub fn initProvider(allocator: std.mem.Allocator) ConfigProvider {
    return .{ .allocator = allocator };
}

pub fn loadFromEnviron(provider: *ConfigProvider, environ_map: *std.process.Environ.Map) Error!void {
    // Override with env vars
    if (environ_map.get("QUICKWIT_URL")) |url| {
        provider.config.quickwit_url = url;
    }

    if (environ_map.get("WINNOW_TRACES_INDEX")) |idx| {
        provider.config.traces.index_id = idx;
    }

    if (environ_map.get("WINNOW_LOGS_INDEX")) |idx| {
        provider.config.logs.index_id = idx;
    }

    if (environ_map.get("WINNOW_EDGES_INDEX")) |idx| {
        provider.config.edges.index_id = idx;
    }
}

pub fn loadFromIo(provider: *ConfigProvider, init: std.process.Init) Error!void {
    const config_path: ?[]const u8 = blk: {
        var args = init.minimal.args.iterate();

        // Skip argv[0]
        _ = args.next();

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config")) {
                const val = args.next() orelse {
                    log.err("--config requires a path argument", .{});
                    return Error.InvalidArgs;
                };
                break :blk val;
            }
            // Unknown flag
            if (std.mem.startsWith(u8, arg, "-")) {
                log.err("unknown flag: {s}", .{arg});
                return Error.InvalidArgs;
            }
        }

        std.Io.Dir.cwd().access(init.io, "winnow.kdl", .{}) catch break :blk null;
        break :blk "winnow.kdl";
    };

    var kdl_source: ?[]const u8 = null;
    if (config_path) |path| {
        kdl_source = std.Io.Dir.cwd().readFileAlloc(init.io, path, provider.allocator, .limited(64 * 1024)) catch |err| {
            log.err("failed to read config file '{s}': {}", .{ path, err });
            return Error.ConfigFileError;
        };
    }
    defer if (kdl_source) |source| provider.allocator.free(source);

    if (kdl_source) |source| try provider.loadFromKdlSource(source);

    try provider.loadFromEnviron(init.environ_map);
}

pub fn loadFromKdlSource(provider: *ConfigProvider, kdl_source: []const u8) Error!void {
    var reader = std.Io.Reader.fixed(kdl_source);
    provider.kdl_doc = kdl.parseReader(provider.allocator, &reader) catch |err| {
        log.err("Failed to parse config file: {}", .{err});

        return Error.ConfigParseError;
    };

    try provider.parseKdlRoot();
}

fn parseKdlAuthInnerConfigNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle, inner_config: *?AuthConfig.InnerConfig) Error!void {
    const configKind = enum {
        module,
    };

    const kind = std.meta.stringToEnum(
        configKind,
        getStringProp(doc, node, "kind") orelse {
            log.err("auth.config block must have \"kind\" parameter", .{});
            return Error.ConfigParseError;
        },
    ) orelse {
        return Error.ConfigParseError;
    };

    switch (kind) {
        .module => {
            try provider.parseKdlAuthModuleConfigNode(doc, node, inner_config);
        },
    }
}

fn parseKdlAuthModuleConfigNode(_: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle, inner_config: *?AuthConfig.InnerConfig) Error!void {
    const childType = enum {
        module,
    };

    var module_name: ?[]const u8 = null;

    var child_it = doc.childIterator(node);
    while (child_it.next()) |child| {
        const child_type = std.meta.stringToEnum(childType, doc.getString(doc.nodes.getName(child))) orelse {
            return Error.ConfigParseError;
        };

        switch (child_type) {
            .module => {
                module_name = getStringArg(doc, child, 0);
            },
        }
    }

    inner_config.* = AuthConfig.InnerConfig{
        .module = .{
            .module_name = module_name orelse {
                return Error.ConfigParseError;
            },
        },
    };
}

fn parseKdlAuthNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    const childNodeType = enum {
        login_url,
        logout_url,
        config,
        strategy,
    };

    const auth_name = getStringProp(doc, node, "name") orelse {
        return Error.ConfigParseError;
    };

    var login_url: ?[]const u8 = null;
    var logout_url: ?[]const u8 = null;
    var strategy: ?AuthConfig.Strategy = null;
    var inner_config: ?AuthConfig.InnerConfig = null;

    var child_it = doc.childIterator(node);
    while (child_it.next()) |child| {
        const node_type = std.meta.stringToEnum(childNodeType, doc.getString(doc.nodes.getName(child))) orelse {
            log.err("Unknown auth child: {s}", .{doc.getString(doc.nodes.getName(child))});
            return Error.ConfigParseError;
        };

        switch (node_type) {
            .login_url => {
                login_url = getStringArg(doc, child, 0) orelse {
                    return Error.ConfigParseError;
                };
            },
            .logout_url => {
                logout_url = getStringArg(doc, child, 0) orelse {
                    return Error.ConfigParseError;
                };
            },
            .config => {
                try provider.parseKdlAuthInnerConfigNode(doc, child, &inner_config);
            },
            .strategy => {
                const strategy_raw = getStringArg(doc, child, 0) orelse {
                    log.err("Strategy in auth block {s} is missing an argument", .{auth_name});
                    return Error.ConfigParseError;
                };
                strategy = std.meta.stringToEnum(AuthConfig.Strategy, strategy_raw) orelse {
                    log.err("Unknown strategy in auth block {s}: {s}", .{ auth_name, strategy_raw });
                    return Error.ConfigParseError;
                };
            },
        }
    }

    const auth = AuthConfig{
        .name = auth_name,
        .inner_config = inner_config orelse {
            log.err("Missing config in auth block {s}", .{auth_name});
            return Error.ConfigParseError;
        },
        .login_url = login_url orelse {
            log.err("Missing login_url in auth block {s}", .{auth_name});
            return Error.ConfigParseError;
        },
        .logout_url = logout_url orelse {
            log.err("Missing logout_url in auth block {s}", .{auth_name});
            return Error.ConfigParseError;
        },
        .strategy = strategy orelse {
            log.err("Missing strategy in auth block {s}", .{auth_name});
            return Error.ConfigParseError;
        },
    };

    try provider.config.auth.put(provider.allocator, auth_name, auth);
}

fn parseKdlEdgesNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "index")) |idx| {
        provider.config.edges.index_id = idx;
    }
    if (getStringProp(doc, node, "retention")) |ret| {
        provider.config.edges.retention = ret;
    }
}

fn parseKdlLogsNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "index")) |idx| {
        provider.config.logs.index_id = idx;
    }
    if (getStringProp(doc, node, "retention")) |ret| {
        provider.config.logs.retention = ret;
    }
}

fn parseKdlModuleInnerConfigNode(
    provider: *ConfigProvider,
    doc: *kdl.Document,
    node: kdl.NodeHandle,
    inner_config_map: *std.StringArrayHashMapUnmanaged([]const u8),
) Error!void {
    var it = doc.childIterator(node);
    while (it.next()) |child| {
        const child_name = doc.getString(doc.nodes.getName(child));

        const child_value = getStringArg(doc, child, 0) orelse {
            return Error.ConfigParseError;
        };

        try inner_config_map.put(provider.allocator, child_name, child_value);
    }
}

fn parseKdlModuleNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    const module_name = getStringProp(doc, node, "name") orelse {
        return Error.ConfigParseError;
    };

    var dll_path: ?[]const u8 = null;
    var module_inner_config = std.StringArrayHashMapUnmanaged([]const u8){};

    const childNodeType = enum {
        dll,
        config,
    };

    var it = doc.childIterator(node);
    while (it.next()) |child| {
        const node_type = std.meta.stringToEnum(childNodeType, doc.getString(doc.nodes.getName(child))) orelse {
            log.err("Unknown module child: {s}", .{doc.getString(doc.nodes.getName(child))});
            return Error.ConfigParseError;
        };

        switch (node_type) {
            .dll => {
                dll_path = getStringArg(doc, child, 0);
            },
            .config => {
                try provider.parseKdlModuleInnerConfigNode(doc, child, &module_inner_config);
            },
        }
    }

    const dll_path_final = dll_path orelse {
        return Error.ConfigParseError;
    };

    const module_config = ModuleConfig{
        .name = module_name,
        .dll_path = dll_path_final,
        .config = module_inner_config,
    };

    try provider.config.modules.put(provider.allocator, module_name, module_config);
}

fn parseKdlQuickwitNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "url")) |url| {
        provider.config.quickwit_url = url;
    }
}

fn parseKdlRoot(provider: *ConfigProvider) Error!void {
    if (provider.kdl_doc == null) {
        return;
    }
    var doc = &provider.kdl_doc.?;

    const rootNodeType = enum {
        serve,
        auth,
        module,
        traces,
        logs,
        edges,
        quickwit,
    };

    var root_iter = doc.rootIterator();
    while (root_iter.next()) |node| {
        const node_name = doc.getString(doc.nodes.getName(node));
        const node_type = std.meta.stringToEnum(rootNodeType, node_name) orelse {
            log.warn("Skipping unknown node {s}", .{node_name});
            continue;
        };

        switch (node_type) {
            .serve => {
                try provider.parseKdlServeNode(doc, node);
            },
            .auth => {
                try provider.parseKdlAuthNode(doc, node);
            },
            .module => {
                try provider.parseKdlModuleNode(doc, node);
            },
            .traces => {
                try provider.parseKdlTracesNode(doc, node);
            },
            .logs => {
                try provider.parseKdlLogsNode(doc, node);
            },
            .edges => {
                try provider.parseKdlEdgesNode(doc, node);
            },
            .quickwit => {
                try provider.parseKdlQuickwitNode(doc, node);
            },
        }
    }
}

fn parseKdlServeNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    provider.config.serve = .{
        .api = null,
        .collector = null,
    };
    var has_children = false;

    var child_iter = doc.childIterator(node);
    while (child_iter.next()) |child| {
        try provider.parseKdlServeVariantNode(doc, child);
        has_children = true;
    }

    if (!has_children) {
        return Error.ConfigParseError;
    }
}

fn parseKdlServeVariantNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    const nodeType = enum {
        api,
        collector,
    };

    const node_type = std.meta.stringToEnum(
        nodeType,
        doc.getString(doc.nodes.getName(node)),
    ) orelse {
        log.err("Unknown serve type: {s}", .{doc.getString(doc.nodes.getName(node))});
        return Error.ConfigParseError;
    };

    const number_of_workers: usize = if (getIntProp(doc, node, "number_of_workers")) |p|
        std.math.cast(u16, p) orelse return Error.ConfigParseError
    else
        default_number_of_workers_per_server;

    const http_port: ?u16 = if (getIntProp(doc, node, "http_port")) |p|
        std.math.cast(u16, p) orelse return Error.ConfigParseError
    else
        null;

    const authorizer_name = getStringProp(doc, node, "auth") orelse null;

    switch (node_type) {
        .api => {
            provider.config.serve.api = .{
                .number_of_workers = number_of_workers,
                .authorizer = authorizer_name,
            };
            if (http_port) |hp| {
                provider.config.serve.api.?.http_port = hp;
            }
        },
        .collector => {
            provider.config.serve.collector = .{
                .number_of_workers = number_of_workers,
                .authorizer = authorizer_name,
            };
            if (http_port) |hp| {
                provider.config.serve.collector.?.http_port = hp;
            }
        },
    }
}

fn parseKdlTracesNode(provider: *ConfigProvider, doc: *kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "index")) |idx| {
        provider.config.traces.index_id = idx;
    }
    if (getStringProp(doc, node, "retention")) |ret| {
        provider.config.traces.retention = ret;
    }
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

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    defer provider.deinit();

    const cfg = provider.config;

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

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    defer provider.deinit();

    const cfg = provider.config;

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
    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource("");

    defer provider.deinit();

    const cfg = provider.config;

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

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

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

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

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

    var provider: ConfigProvider = .initProvider(allocator);
    const result = provider.loadFromKdlSource(source);

    defer provider.deinit();
    try std.testing.expectError(error.ConfigParseError, result);
}

test "parseKdl no serve block uses defaults" {
    const allocator = std.testing.allocator;
    const source =
        \\quickwit url="http://example.com:7280"
    ;

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

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

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

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

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

    try std.testing.expect(cfg.serve.collector != null);
    try std.testing.expect(cfg.serve.api != null);
    try std.testing.expectEqual(@as(u16, 4318), cfg.serve.collector.?.http_port);
    try std.testing.expectEqual(@as(u16, 8080), cfg.serve.api.?.http_port);
}
