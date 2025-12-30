const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests containing this text");
    var test_filters: []const []const u8 = &.{};
    if (test_filter) |filter| {
        test_filters = &.{filter};
    }

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ops_mod = b.addModule("ops", .{
        .root_source_file = b.path("src/ops.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });
    const lib_mod = b.addModule("par2", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ops", .module = ops_mod },
        },
    });
    const lib = b.addLibrary(.{
        .name = "par2",
        .root_module = lib_mod,
        .linkage = .static,
    });
    lib.installHeadersDirectory(b.path("include"), "", .{});
    b.installArtifact(lib);
    const lib_shared = b.addLibrary(.{
        .name = "par2",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    lib_shared.installHeadersDirectory(b.path("include"), "", .{});
    const install_shared = b.addInstallArtifact(lib_shared, .{});
    b.getInstallStep().dependOn(&install_shared.step);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "par2", .module = lib_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "ops", .module = ops_mod },
        },
    });
    const cli = b.addExecutable(.{
        .name = "par2-cli",
        .root_module = cli_mod,
    });
    cli.linkLibrary(lib);
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    const prng_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/prng_gen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });
    const prng = b.addExecutable(.{
        .name = "prng-gen",
        .root_module = prng_mod,
    });
    const install_prng = b.addInstallArtifact(prng, .{});
    b.getInstallStep().dependOn(&install_prng.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "par2", .module = lib_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "ops", .module = ops_mod },
        },
    });
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .filters = test_filters,
    });
    const install_tests = b.addInstallArtifact(tests, .{});
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&install_cli.step);
    test_step.dependOn(&install_prng.step);
    test_step.dependOn(&install_shared.step);
    test_step.dependOn(&run_tests.step);

    const test_compile_step = b.step("test-compile", "Compile unit tests without running");
    test_compile_step.dependOn(&install_tests.step);

    const test_direct_bin = b.pathJoin(&.{ b.install_path, "bin", "test" });
    const run_tests_direct = b.addSystemCommand(&.{test_direct_bin});
    run_tests_direct.step.dependOn(&install_tests.step);
    run_tests_direct.step.dependOn(&install_cli.step);
    run_tests_direct.step.dependOn(&install_prng.step);
    run_tests_direct.step.dependOn(&install_shared.step);

    const test_direct_step = b.step("test-direct", "Run unit tests directly (no zig --listen)");
    test_direct_step.dependOn(&run_tests_direct.step);
}
