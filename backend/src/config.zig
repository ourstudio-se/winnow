const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const kdl = @import("kdl");
const std = @import("std");

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

    pub const StrategyType = enum {
        bearer,
        cookie,
    };

    pub const StrategyCookieOptions = struct {
        cookie_name: []const u8,
    };

    pub const Strategy = union(StrategyType) {
        bearer: struct {},
        cookie: StrategyCookieOptions,
    };

    pub const InnerConfig = union(Kind) {
        module: AuthConfig.ModuleConfig,
    };

    strategy: Strategy,
    name: []const u8,
    inner_config: InnerConfig,
};

pub const ServeConfig = struct {
    pub const RoleConfig = struct {
        pub const RoleType = enum {
            api,
            collector,
            ui,
        };

        pub const APIInner = struct {};
        pub const CollectorInner = struct {};
        pub const UIInner = struct {
            login_url: ?[]const u8 = null,
            logout_url: ?[]const u8 = null,
            api_url: ?[]const u8 = null,
        };

        pub const Inner = union(RoleType) {
            api: APIInner,
            collector: CollectorInner,
            ui: UIInner,
        };

        authorizer_name: ?[]const u8 = null,
        inner: Inner,
    };

    pub const Roles = struct {
        api: ?RoleConfig = null,
        collector: ?RoleConfig = null,
        ui: ?RoleConfig = null,
    };

    number_of_workers: usize = 6,
    http_port: u16 = 8080,
    roles: Roles = .{},
};

pub const Config = struct {
    quickwit_url: []const u8,
    traces: IndexSettings,
    logs: IndexSettings,
    edges: IndexSettings,
    serve: std.AutoHashMapUnmanaged(u16, ServeConfig) = .{},
    modules: std.StringHashMapUnmanaged(ModuleConfig) = .{},
    auth: std.StringHashMapUnmanaged(AuthConfig) = .{},
    ensure_indices: bool,
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
    .ensure_indices = false,
};

pub const default_api_ui_config = ServeConfig{
    .http_port = 8080,
    .roles = .{
        .api = .{ .inner = .{ .api = .{} } },
        .ui = .{ .inner = .{ .ui = .{} } },
    },
};
pub const default_collector_config = ServeConfig{
    .http_port = 4318,
    .roles = .{
        .collector = .{ .inner = .{ .collector = .{} } },
    },
};

/// Get an integer property value from a KDL node.
pub fn deinit(provider: *ConfigProvider) void {
    provider.config.serve.deinit(provider.allocator);
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
    errdefer provider.deinit();

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

    // Initialize default server roles if none are specified
    if (provider.config.serve.size == 0) {
        try provider.config.serve.put(provider.allocator, default_api_ui_config.http_port, default_api_ui_config);
        try provider.config.serve.put(provider.allocator, default_collector_config.http_port, default_collector_config);
    }
}

pub fn loadFromKdlSource(provider: *ConfigProvider, kdl_source: []const u8) Error!void {
    var reader = std.Io.Reader.fixed(kdl_source);
    var kdl_doc = kdl.parseReader(provider.allocator, &reader) catch |err| {
        log.err("Failed to parse config file: {}", .{err});

        return Error.ConfigParseError;
    };
    errdefer kdl_doc.deinit();

    try provider.parseKdlRoot(&kdl_doc);

    // Provider now owns the document
    provider.kdl_doc = kdl_doc;
}

fn parseKdlAuthInnerConfigNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle, inner_config: *?AuthConfig.InnerConfig) Error!void {
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

fn parseKdlAuthModuleConfigNode(_: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle, inner_config: *?AuthConfig.InnerConfig) Error!void {
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

fn parseKdlAuthNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
    const childNodeType = enum {
        login_url,
        logout_url,
        config,
        strategy,
        cookie_name,
    };

    const auth_name = getStringProp(doc, node, "name") orelse {
        return Error.ConfigParseError;
    };

    var login_url: ?[]const u8 = null;
    var logout_url: ?[]const u8 = null;
    var strategy_type: ?AuthConfig.StrategyType = null;
    var inner_config: ?AuthConfig.InnerConfig = null;
    var cookie_name: ?[]const u8 = null;

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
                strategy_type = std.meta.stringToEnum(AuthConfig.StrategyType, strategy_raw) orelse {
                    log.err("Unknown strategy in auth block {s}: {s}", .{ auth_name, strategy_raw });
                    return Error.ConfigParseError;
                };
            },
            .cookie_name => {
                cookie_name = getStringArg(doc, child, 0) orelse {
                    return Error.ConfigParseError;
                };
            },
        }
    }

    const strategy = if (strategy_type) |t| switch (t) {
        .bearer => AuthConfig.Strategy{
            .bearer = .{},
        },
        .cookie => AuthConfig.Strategy{
            .cookie = .{
                .cookie_name = cookie_name orelse {
                    log.err("Cookie strategy must have cookie_name parameter set on auth block {s}", .{auth_name});
                    return Error.ConfigParseError;
                },
            },
        },
    } else {
        log.err("Missing strategy in auth block {s}", .{auth_name});
        return Error.ConfigParseError;
    };

    const auth = AuthConfig{
        .name = auth_name,
        .inner_config = inner_config orelse {
            log.err("Missing config in auth block {s}", .{auth_name});
            return Error.ConfigParseError;
        },
        .strategy = strategy,
    };

    try provider.config.auth.put(provider.allocator, auth_name, auth);
}

fn parseKdlEdgesNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "index")) |idx| {
        provider.config.edges.index_id = idx;
    }
    if (getStringProp(doc, node, "retention")) |ret| {
        provider.config.edges.retention = ret;
    }
}

fn parseKdlLogsNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "index")) |idx| {
        provider.config.logs.index_id = idx;
    }
    if (getStringProp(doc, node, "retention")) |ret| {
        provider.config.logs.retention = ret;
    }
}

fn parseKdlModuleInnerConfigNode(
    provider: *ConfigProvider,
    doc: *const kdl.Document,
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

fn parseKdlModuleNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
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

fn parseKdlQuickwitNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
    if (getStringProp(doc, node, "url")) |url| {
        provider.config.quickwit_url = url;
    }
}

fn parseKdlRoot(provider: *ConfigProvider, doc: *const kdl.Document) Error!void {
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

fn parseKdlServeNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
    var has_children = false;

    var serve = ServeConfig{};

    if (getIntProp(doc, node, "http_port")) |http_port| {
        serve.http_port = std.math.cast(u16, http_port) orelse {
            log.err("http_port must be a numeric value", .{});
            return Error.ConfigParseError;
        };
    }

    if (getIntProp(doc, node, "number_of_workers")) |number_of_workers| {
        serve.number_of_workers = std.math.cast(u16, number_of_workers) orelse {
            log.err("number_of_workers must be a numeric value", .{});
            return Error.ConfigParseError;
        };
    }

    var child_iter = doc.childIterator(node);
    while (child_iter.next()) |child| {
        try provider.parseKdlServeRoleNode(doc, child, &serve.roles);
        has_children = true;
    }

    if (!has_children) {
        if (!builtin.is_test) {
            // Cheap workaround to let our tests pass
            log.err("serve node must have at least one role", .{});
        }
        return Error.ConfigParseError;
    }

    try provider.config.serve.put(provider.allocator, serve.http_port, serve);
}

fn parseKdlServeRoleNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle, roles: *ServeConfig.Roles) Error!void {
    const nodeType = enum {
        api,
        collector,
        ui,
    };

    const node_type = std.meta.stringToEnum(
        nodeType,
        doc.getString(doc.nodes.getName(node)),
    ) orelse {
        log.err("Unknown serve role: {s}", .{doc.getString(doc.nodes.getName(node))});
        return Error.ConfigParseError;
    };

    const authorizer_name = getStringProp(doc, node, "auth");

    switch (node_type) {
        .api => {
            roles.api = .{ .authorizer_name = authorizer_name, .inner = .{ .api = .{} } };
            provider.config.ensure_indices = true;
        },
        .collector => {
            roles.collector = .{ .authorizer_name = authorizer_name, .inner = .{ .collector = .{} } };
            provider.config.ensure_indices = true;
        },
        .ui => {
            // TODO(2026-09-11, Max Bolotin): Pyramid of doom!
            var ui_role_config = ServeConfig.RoleConfig{ .authorizer_name = authorizer_name, .inner = .{ .ui = .{} } };
            var child_it = doc.childIterator(node);
            while (child_it.next()) |child| {
                const childType = enum {
                    login_url,
                    logout_url,
                    api_url,
                };

                const child_name = doc.getString(doc.nodes.getName(child));
                const child_type = std.meta.stringToEnum(childType, child_name) orelse {
                    log.err("Unknown config parameter for role {s}: {s}:", .{ @tagName(node_type), child_name });
                    return Error.ConfigParseError;
                };

                switch (child_type) {
                    .api_url => {
                        if (getStringArg(doc, child, 0)) |value| {
                            ui_role_config.inner.ui.api_url = value;
                        } else {
                            log.err("Missing argument value for role option {s}.{s}", .{ @tagName(node_type), @tagName(child_type) });
                            return Error.ConfigParseError;
                        }
                    },
                    .login_url => {
                        if (getStringArg(doc, child, 0)) |value| {
                            ui_role_config.inner.ui.login_url = value;
                        } else {
                            log.err("Missing argument value for role option {s}.{s}", .{ @tagName(node_type), @tagName(child_type) });
                            return Error.ConfigParseError;
                        }
                    },
                    .logout_url => {
                        if (getStringArg(doc, child, 0)) |value| {
                            ui_role_config.inner.ui.logout_url = value;
                        } else {
                            log.err("Missing argument value for role option {s}.{s}", .{ @tagName(node_type), @tagName(child_type) });
                            return Error.ConfigParseError;
                        }
                    },
                }
            }
            roles.ui = ui_role_config;
        },
    }
}

fn parseKdlTracesNode(provider: *ConfigProvider, doc: *const kdl.Document, node: kdl.NodeHandle) Error!void {
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
}

test "parseKdl serve block with both components and port" {
    const allocator = std.testing.allocator;
    const source =
        \\serve http_port=9999 {
        \\    collector
        \\    api
        \\}
    ;

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

    const serve = cfg.serve.get(9999) orelse unreachable;

    try std.testing.expectEqual(@as(u16, 9999), serve.http_port);
    try std.testing.expect(serve.roles.collector != null);
    try std.testing.expect(serve.roles.api != null);
}

test "parseKdl serve block with only collector" {
    const allocator = std.testing.allocator;
    const source =
        \\serve http_port=4318 {
        \\    collector
        \\}
    ;

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

    const serve = cfg.serve.get(4318) orelse unreachable;

    try std.testing.expect(serve.roles.collector != null);
    try std.testing.expect(serve.roles.api == null);
    try std.testing.expectEqual(@as(u16, 4318), serve.http_port);
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

test "parseKdl serve block with port as string" {
    const allocator = std.testing.allocator;
    const source =
        \\serve http_port="4318" {
        \\    collector
        \\    api
        \\}
    ;

    var provider: ConfigProvider = .initProvider(allocator);
    try provider.loadFromKdlSource(source);

    const cfg = provider.config;

    defer provider.deinit();

    const serve = cfg.serve.get(4318) orelse unreachable;

    try std.testing.expect(serve.roles.collector != null);
    try std.testing.expect(serve.roles.api != null);
    try std.testing.expectEqual(@as(u16, 4318), serve.http_port);
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

    const serve = cfg.serve.get(8080) orelse unreachable;

    try std.testing.expect(serve.roles.collector != null);
    try std.testing.expect(serve.roles.api != null);
    try std.testing.expectEqual(@as(u16, 8080), serve.http_port);
}
