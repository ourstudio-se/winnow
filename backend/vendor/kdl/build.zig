const std = @import("std");

// Minimal build script for the vendored kdl package: exposes the `kdl` module
// and its internal module graph (mirrors upstream build/modules.zig), without
// upstream's bench/fuzz/test scaffolding which doesn't compile under Zig 0.16.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util_module = b.addModule("util", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const events_module = b.addModule("events", .{
        .root_source_file = b.path("src/stream/stream_events.zig"),
        .target = target,
        .optimize = optimize,
    });

    const types_module = b.addModule("types", .{
        .root_source_file = b.path("src/stream/stream_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const values_module = b.addModule("values", .{
        .root_source_file = b.path("src/stream/value_builder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "types", .module = types_module },
        },
    });

    const simd_module = b.addModule("simd", .{
        .root_source_file = b.path("src/simd.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "events", .module = events_module },
            .{ .name = "types", .module = types_module },
            .{ .name = "values", .module = values_module },
        },
    });

    const stream_module = b.addModule("stream", .{
        .root_source_file = b.path("src/stream/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "simd", .module = simd_module },
            .{ .name = "events", .module = events_module },
            .{ .name = "types", .module = types_module },
            .{ .name = "values", .module = values_module },
        },
    });

    _ = b.addModule("kdl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "stream", .module = stream_module },
            .{ .name = "simd", .module = simd_module },
        },
    });
}
