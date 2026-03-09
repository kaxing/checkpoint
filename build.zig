const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const zstd_dep = b.dependency("zstd", .{ .target = target, .optimize = optimize });
    exe.linkLibrary(zstd_dep.artifact("zstd"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run check");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const hash_mod = b.createModule(.{ .root_source_file = b.path("src/hash.zig") });

    const chunker_mod = b.createModule(.{ .root_source_file = b.path("src/chunker.zig") });

    const tree_module = b.createModule(.{ .root_source_file = b.path("src/tree.zig") });
    tree_module.addImport("hash.zig", hash_mod);

    const compress_mod = b.createModule(.{ .root_source_file = b.path("src/compress.zig"), .link_libc = true, .target = target });
    compress_mod.linkLibrary(zstd_dep.artifact("zstd"));

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test-coverage/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("hash", hash_mod);
    unit_tests.root_module.addImport("chunker", chunker_mod);
    unit_tests.root_module.addImport("tree", tree_module);
    unit_tests.root_module.addImport("compress", compress_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
