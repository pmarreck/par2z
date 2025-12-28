const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const lib_mod = b.addModule("par2", .{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
	});
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
			.{ .name = "par2", .module = lib_mod },
		},
	});
	const lib = b.addLibrary(.{
		.name = "par2",
		.root_module = lib_mod,
		.linkage = .static,
	});
	lib.installHeadersDirectory(b.path("include"), "", .{});
	b.installArtifact(lib);

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
	b.installArtifact(cli);

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
	b.installArtifact(prng);

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
	});
	const run_tests = b.addRunArtifact(tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_tests.step);
}
