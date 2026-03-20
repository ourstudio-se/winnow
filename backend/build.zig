const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Protobuf dependency ---
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    // --- Generate Zig from .proto files ---
    const gen_proto = b.step("gen-proto", "Generate Zig code from .proto files");

    // Build protoc-gen-zig from the dependency's source.
    // We build it ourselves rather than using RunProtocStep.create() or
    // protobuf_dep.artifact() because: (1) RunProtocStep resolves internal
    // paths relative to our project, and (2) the artifact name is ambiguous.
    const protoc_gen_zig = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = protobuf_dep.path("bootstrapped-generator/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "protobuf",
                .module = protobuf_dep.module("protobuf"),
            }},
        }),
    });

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "src/proto" });
    mkdir.setCwd(b.path("."));

    const run_protoc = b.addSystemCommand(&.{
        "protoc",
        "--zig_out=src/proto",
        "-Iproto",
        "proto/opentelemetry/proto/collector/trace/v1/trace_service.proto",
        "proto/opentelemetry/proto/collector/logs/v1/logs_service.proto",
    });
    run_protoc.addPrefixedFileArg("--plugin=protoc-gen-zig=", protoc_gen_zig.getEmittedBin());
    run_protoc.setCwd(b.path("."));
    run_protoc.step.dependOn(&mkdir.step);

    const zig_fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "src/proto" });
    zig_fmt.setCwd(b.path("."));
    zig_fmt.step.dependOn(&run_protoc.step);

    gen_proto.dependOn(&zig_fmt.step);

    // --- Main executable ---
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("protobuf", protobuf_dep.module("protobuf"));

    const exe = b.addExecutable(.{ .name = "telemetry-experiment", .root_module = exe_mod });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("protobuf", protobuf_dep.module("protobuf"));

    const unit_tests = b.addTest(.{ .root_module = test_mod });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
