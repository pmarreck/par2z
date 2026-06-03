const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests containing this text");
    var test_filters: []const []const u8 = &.{};
    if (test_filter) |filter| {
        test_filters = &.{filter};
    }

    // SIMD optimization control: disable with -Dno-simd=true
    const no_simd = b.option(bool, "no-simd", "Disable SIMD optimizations (PMULL/PCLMULQDQ)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "disable_simd", no_simd);

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addOptions("build_options", build_options);
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
            .{ .name = "core", .module = core_mod },
        },
    });
    lib_mod.link_libc = true;
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
        .name = "par2z-cli",
        .root_module = cli_mod,
    });
    cli.root_module.linkLibrary(lib);
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);
    const install_luajit = b.addInstallFile(b.path("tools/par2z-cli-luajit"), "par2z/bin/par2z-cli-luajit");
    b.getInstallStep().dependOn(&install_luajit.step);

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
    const install_prng = b.addInstallArtifact(prng, .{
        .dest_dir = .{ .override = .{ .custom = "par2z/bin" } },
    });
    b.getInstallStep().dependOn(&install_prng.step);

    // Microbenchmark runner for the gf16/crc32 kernels (timing only — not tests).
    const microbench_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/microbench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });
    const microbench = b.addExecutable(.{
        .name = "microbench",
        .root_module = microbench_mod,
    });
    const run_microbench = b.addRunArtifact(microbench);
    if (b.args) |args| run_microbench.addArgs(args);
    const bench_micro_step = b.step("bench-micro", "Run gf16/crc32 microbenchmarks");
    bench_micro_step.dependOn(&run_microbench.step);

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
    const install_tests = b.addInstallArtifact(tests, .{
        .dest_dir = .{ .override = .{ .custom = "par2z/bin" } },
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&install_cli.step);
    test_step.dependOn(&install_prng.step);
    test_step.dependOn(&install_shared.step);
    test_step.dependOn(&run_tests.step);

    const test_compile_step = b.step("test-compile", "Compile unit tests without running");
    test_compile_step.dependOn(&install_tests.step);

    const test_direct_bin = b.pathJoin(&.{ b.install_path, "par2z", "bin", "test" });
    const run_tests_direct = b.addSystemCommand(&.{test_direct_bin});
    run_tests_direct.step.dependOn(&install_tests.step);
    run_tests_direct.step.dependOn(&install_cli.step);
    run_tests_direct.step.dependOn(&install_prng.step);
    run_tests_direct.step.dependOn(&install_shared.step);

    const test_direct_step = b.step("test-direct", "Run unit tests directly (no zig --listen)");
    test_direct_step.dependOn(&run_tests_direct.step);

    // Core-module inline unit tests. These live in src/core/*.zig and are NOT
    // reachable from the tests/tests.zig binary (separate module), so they need
    // their own test artifact to actually run.
    const core_tests = b.addTest(.{
        .name = "test-core",
        .root_module = core_mod,
        .filters = test_filters,
    });
    const install_core_tests = b.addInstallArtifact(core_tests, .{
        .dest_dir = .{ .override = .{ .custom = "par2z/bin" } },
    });
    const core_test_bin = b.pathJoin(&.{ b.install_path, "par2z", "bin", "test-core" });
    const run_core_tests = b.addSystemCommand(&.{core_test_bin});
    run_core_tests.step.dependOn(&install_core_tests.step);
    const test_core_step = b.step("test-core", "Run core-module inline unit tests");
    test_core_step.dependOn(&run_core_tests.step);

    // Core inline tests are part of the canonical suite — gate `test` and
    // `test-direct` (what ./test runs) on them too.
    test_step.dependOn(&run_core_tests.step);
    test_direct_step.dependOn(&run_core_tests.step);

    // ops-module inline unit tests (path-safety, arg/format helpers).
    const ops_tests = b.addTest(.{
        .name = "test-ops",
        .root_module = ops_mod,
        .filters = test_filters,
    });
    const install_ops_tests = b.addInstallArtifact(ops_tests, .{
        .dest_dir = .{ .override = .{ .custom = "par2z/bin" } },
    });
    const ops_test_bin = b.pathJoin(&.{ b.install_path, "par2z", "bin", "test-ops" });
    const run_ops_tests = b.addSystemCommand(&.{ops_test_bin});
    run_ops_tests.step.dependOn(&install_ops_tests.step);
    const test_ops_step = b.step("test-ops", "Run ops-module inline unit tests");
    test_ops_step.dependOn(&run_ops_tests.step);

    // cli-module inline unit tests (argument parsing).
    const cli_tests = b.addTest(.{
        .name = "test-cli",
        .root_module = cli_mod,
        .filters = test_filters,
    });
    cli_tests.root_module.linkLibrary(lib);
    const install_cli_tests = b.addInstallArtifact(cli_tests, .{
        .dest_dir = .{ .override = .{ .custom = "par2z/bin" } },
    });
    const cli_test_bin = b.pathJoin(&.{ b.install_path, "par2z", "bin", "test-cli" });
    const run_cli_tests = b.addSystemCommand(&.{cli_test_bin});
    run_cli_tests.step.dependOn(&install_cli_tests.step);
    const test_cli_step = b.step("test-cli", "Run cli-module inline unit tests");
    test_cli_step.dependOn(&run_cli_tests.step);

    test_step.dependOn(&run_ops_tests.step);
    test_direct_step.dependOn(&run_ops_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_direct_step.dependOn(&run_cli_tests.step);

    // Production release build (always ReleaseFast)
    const release_core_mod = b.addModule("core-release", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const release_ops_mod = b.addModule("ops-release", .{
        .root_source_file = b.path("src/ops.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "core", .module = release_core_mod },
        },
    });
    const release_lib_mod = b.addModule("par2-release", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "ops", .module = release_ops_mod },
            .{ .name = "core", .module = release_core_mod },
        },
    });
    const release_lib = b.addLibrary(.{
        .name = "par2",
        .root_module = release_lib_mod,
        .linkage = .static,
    });
    const release_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "par2", .module = release_lib_mod },
            .{ .name = "core", .module = release_core_mod },
            .{ .name = "ops", .module = release_ops_mod },
        },
    });
    const release_cli = b.addExecutable(.{
        .name = "par2z-cli",
        .root_module = release_cli_mod,
    });
    release_cli.root_module.linkLibrary(release_lib);
    const install_release_cli = b.addInstallArtifact(release_cli, .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
    });
    const install_release_lib = b.addInstallArtifact(release_lib, .{
        .dest_dir = .{ .override = .{ .custom = "release/lib" } },
    });
    const release_step = b.step("release", "Build production CLI and library (ReleaseFast)");
    release_step.dependOn(&install_release_cli.step);
    release_step.dependOn(&install_release_lib.step);

    // Fuzz targets (for AFL++ on Linux)
    const fuzz_step = b.step("fuzz", "Build fuzz targets for AFL++");
    inline for (.{ "fuzz_packet", "fuzz_recovery" }) |name| {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("fuzz/" ++ name ++ ".zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "ops", .module = ops_mod },
            },
        });
        const fuzz_exe = b.addExecutable(.{
            .name = name,
            .root_module = fuzz_mod,
        });
        const install_fuzz = b.addInstallArtifact(fuzz_exe, .{
            .dest_dir = .{ .override = .{ .custom = "fuzz" } },
        });
        fuzz_step.dependOn(&install_fuzz.step);
    }

    // Cross-compile targets for static binaries (OS-architecture naming)
    // Note: aarch64 and arm64 are the same; using aarch64 for Zig consistency
    addStaticCliVariant(b, optimize, .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    }, "bin-static/macos-aarch64", build_options);
    addStaticCliVariant(b, optimize, .{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    }, "bin-static/macos-x86_64", build_options);
    addStaticCliVariant(b, optimize, .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    }, "bin-static/linux-x86_64", build_options);
    addStaticCliVariant(b, optimize, .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    }, "bin-static/linux-aarch64", build_options);
    addStaticCliVariant(b, optimize, .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    }, "bin-static/windows-x86_64", build_options);
    addStaticCliVariant(b, optimize, .{
        .cpu_arch = .aarch64,
        .os_tag = .windows,
    }, "bin-static/windows-aarch64", build_options);
}

fn addStaticCliVariant(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target_query: std.Target.Query,
    install_subdir: []const u8,
    build_options: *std.Build.Step.Options,
) void {
    const target = b.resolveTargetQuery(target_query);
    const core_mod = b.addModule(b.fmt("core-{s}", .{install_subdir}), .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addOptions("build_options", build_options);
    const ops_mod = b.addModule(b.fmt("ops-{s}", .{install_subdir}), .{
        .root_source_file = b.path("src/ops.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });
    const lib_mod = b.addModule(b.fmt("par2-{s}", .{install_subdir}), .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ops", .module = ops_mod },
            .{ .name = "core", .module = core_mod },
        },
    });
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
        .name = "par2z-cli",
        .root_module = cli_mod,
    });
    cli.root_module.link_libc = true;
    const install_cli = b.addInstallArtifact(cli, .{
        .dest_dir = .{ .override = .{ .custom = install_subdir } },
    });
    b.getInstallStep().dependOn(&install_cli.step);
}
