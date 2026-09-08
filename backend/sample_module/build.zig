const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addCSourceFile(.{
        .file = b.path("./src/jwt_verify.c"),
        .flags = &.{
            "-std=c11",
        },
    });

    mod.linkSystemLibrary("jwt", .{
        .use_pkg_config = .yes,
    });

    const library_opts = std.Build.LibraryOptions{
        .name = "winnow-sample-module",
        .root_module = mod,
        .linkage = .dynamic,
        // .use_llvm = true,
    };

    const lib = b.addLibrary(library_opts);
    b.installArtifact(lib);

    // ~~~ ZLS stuff ~~~
    // const lib_check = b.addLibrary(library_opts);
    // const check = b.step("check", "Check if the program compiles");
    // check.dependOn(&lib_check.step);
}
