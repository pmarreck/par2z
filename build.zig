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
    cli.linkLibrary(lib);
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);
    const install_luajit = b.addInstallFile(b.path("tools/par2z-cli-luajit"), "bin/par2z-cli-luajit");
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

    // Production release build (always ReleaseFast)
    const release_core_mod = b.addModule("core-release", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = .ReleaseFast,
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
    release_cli.linkLibrary(release_lib);
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
