//! io_singleton.zig — captures `std.Io` once for the par2z library/CLI process.
//!
//! Per the codescan/dirtree firsthand notes in `ZIG_0.15_TO_0.16_MIGRATION.md`:
//! par2z is a library + CLI with deep file I/O coupling (~250 std.fs sites).
//! A pure "thread io as parameter" port would change every public function
//! signature, break the C FFI shape, and explode call-site changes. For a
//! CLI/library whose I/O happens during the call's lifetime (no async, no
//! futures), an io singleton is a defensible pragmatic shortcut — the safety
//! guarantee that the migration doc warns about ("io stays alive longer than
//! any code that uses it") is satisfied by construction.
//!
//! Initialised lazily on first call to `getOrInit()`. CLI code paths can call
//! `set(io)` from `main` to install the canonical `init.io` from Juicy Main;
//! library callers, tests, and any path that hasn't run through main get a
//! fallback `Io.Threaded.global_single_threaded.io()`. This is safe even for
//! multi-threaded code because `Io.Threaded.global_single_threaded` only
//! restricts `io.concurrent`-style fan-out, not file/dir/sync operations
//! (see bzip2z firsthand note "global_single_threaded is safe for mutex/futex").

const std = @import("std");
const builtin = @import("builtin");

var cached_io: ?std.Io = null;
var cached_env: ?*const std.process.Environ.Map = null;

// Fallback threaded io used by tests and library callers that don't go through
// Juicy Main. `global_single_threaded` ships with `Allocator.failing` which means
// any I/O path that internally allocates (e.g. `process.spawn`'s argv buffer,
// `Io.File.MultiReader`'s pipe buffers) fails immediately with OOM. So we keep
// our own lazily-initialised Threaded backed by `std.heap.c_allocator` for the
// no-Juicy-Main path. The migration-doc bzip2z note that "global_single_threaded
// is safe for sync primitives" is true for mutex/futex but NOT for spawn/process
// — they need a real allocator.
var fallback_threaded: ?std.Io.Threaded = null;
var fallback_init_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0); // 0=uninit, 1=initing, 2=ready

/// Install the canonical io (typically from `init.io` in Juicy Main).
pub fn set(io: std.Io) void {
    cached_io = io;
}

pub fn setEnvMap(map: *const std.process.Environ.Map) void {
    cached_env = map;
}

fn getFallbackIo() std.Io {
    // 3-state atomic guard per the docscan firsthand note (replaces removed Thread.Mutex).
    while (true) {
        const cur = fallback_init_state.load(.acquire);
        if (cur == 2) return fallback_threaded.?.io();
        if (cur == 0 and fallback_init_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
            fallback_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
            fallback_init_state.store(2, .release);
            return fallback_threaded.?.io();
        }
        // Another thread is initialising; spin briefly.
        std.atomic.spinLoopHint();
    }
}

/// Return the cached io if set; otherwise fall back to a c_allocator-backed
/// Threaded io. Always safe to call.
pub fn getOrInit() std.Io {
    if (cached_io) |io| return io;
    return getFallbackIo();
}

pub fn getEnv(name: []const u8) ?[]const u8 {
    if (cached_env) |map| return map.get(name);
    return null;
}

// =============================================================================
// Convenience helpers that mirror the 0.15 std.fs API shape, but use the
// cached io internally. Lets us mechanically sweep `std.fs.cwd().X(args)` ->
// `core.io_singleton.cwdX(args)` without per-callsite io plumbing.
// =============================================================================

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn openFile(dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return dir.openFile(getOrInit(), sub_path, options);
}

pub fn createFile(dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return dir.createFile(getOrInit(), sub_path, flags);
}

pub fn openDir(dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return dir.openDir(getOrInit(), sub_path, options);
}

pub fn closeDir(dir: *std.Io.Dir) void {
    dir.close(getOrInit());
}

pub fn closeFile(file: std.Io.File) void {
    file.close(getOrInit());
}

pub fn statFile(dir: std.Io.Dir, sub_path: []const u8) !std.Io.File.Stat {
    return dir.statFile(getOrInit(), sub_path, .{});
}

pub fn fileStat(file: std.Io.File) !std.Io.File.Stat {
    return file.stat(getOrInit());
}

pub fn deleteTree(dir: std.Io.Dir, sub_path: []const u8) !void {
    return dir.deleteTree(getOrInit(), sub_path);
}

pub fn deleteFile(dir: std.Io.Dir, sub_path: []const u8) !void {
    return dir.deleteFile(getOrInit(), sub_path);
}

pub fn deleteDir(dir: std.Io.Dir, sub_path: []const u8) !void {
    return dir.deleteDir(getOrInit(), sub_path);
}

pub fn makeDir(dir: std.Io.Dir, sub_path: []const u8) !void {
    return dir.createDir(getOrInit(), sub_path, .default_dir);
}

pub fn makePath(dir: std.Io.Dir, sub_path: []const u8) !void {
    return dir.createDirPath(getOrInit(), sub_path);
}

pub fn access(dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return dir.access(getOrInit(), sub_path, options);
}

pub fn accessAbsolute(absolute_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.accessAbsolute(getOrInit(), absolute_path, options);
}

pub fn openDirAbsolute(absolute_path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(getOrInit(), absolute_path, options);
}

pub fn realpathAlloc(dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) ![:0]u8 {
    return dir.realPathFileAlloc(getOrInit(), sub_path, allocator);
}

/// Drop-in replacement for `std.fs.Dir.readFileAlloc(alloc, sub_path, max)`.
pub fn readFileAlloc(
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    sub_path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return dir.readFileAlloc(getOrInit(), sub_path, allocator, .limited(max_bytes));
}

/// Read entire file to allocated slice. 0.15: `file.readToEndAlloc(alloc, max)`.
pub fn fileReadToEndAlloc(
    file: std.Io.File,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(getOrInit(), &buf);
    return r.interface.allocRemaining(allocator, .limited(max_bytes));
}

/// Drop-in for 0.15 `file.writeStreamingAll(io_singleton.getOrInit(), data)`.
pub fn fileWriteAll(file: std.Io.File, data: []const u8) !void {
    return file.writeStreamingAll(getOrInit(), data);
}

/// Drop-in for 0.15 `file.pread(buf, offset)`. Returns bytes read.
pub fn filePread(file: std.Io.File, buffer: []u8, offset: u64) !usize {
    return file.readPositionalAll(getOrInit(), buffer, offset);
}

/// Drop-in for 0.15 `file.pwriteAll(bytes, offset)`.
pub fn filePwriteAll(file: std.Io.File, bytes: []const u8, offset: u64) !void {
    return file.writePositionalAll(getOrInit(), bytes, offset);
}

/// Drop-in for 0.15 `file.getEndPos()`.
pub fn fileGetEndPos(file: std.Io.File) !u64 {
    return (try file.stat(getOrInit())).size;
}

pub fn fileSetLength(file: std.Io.File, new_length: u64) !void {
    return file.setLength(getOrInit(), new_length);
}

// =============================================================================
// Process helpers — wrap 0.16 std.process.run / Child.spawn so call sites can
// keep the 0.15 shape `runChild(opts_struct)` without per-call io plumbing.
// =============================================================================

pub const RunChildOptions = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    max_output_bytes: usize = 50 * 1024 * 1024,
};

pub const RunChildResult = std.process.RunResult;

pub fn runChild(opts: RunChildOptions) !RunChildResult {
    return std.process.run(opts.allocator, getOrInit(), .{
        .argv = opts.argv,
        .environ_map = opts.environ_map,
        .cwd = if (opts.cwd) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = .limited(opts.max_output_bytes),
        .stderr_limit = .limited(opts.max_output_bytes),
    });
}

/// 0.15-compat shim for `std.process.Child.init(argv, allocator)`.
/// Returns the new 0.16 Child handle via `spawn` immediately; pre-set behaviors
/// (stdout_behavior = .Pipe etc.) must be wired through SpawnOptions instead.
pub const ChildInitOptions = struct {
    argv: []const []const u8,
    allocator: std.mem.Allocator,
    stdout: std.process.SpawnOptions.StdIo = .inherit,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
    stdin: std.process.SpawnOptions.StdIo = .inherit,
};

pub fn spawnChild(opts: ChildInitOptions) !std.process.Child {
    _ = opts.allocator; // 0.16 spawn doesn't take an allocator for the child handle itself.
    return std.process.spawn(getOrInit(), .{
        .argv = opts.argv,
        .stdout = opts.stdout,
        .stderr = opts.stderr,
        .stdin = opts.stdin,
    });
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // Cached map (from Juicy Main) takes precedence — but it's snapshotted at startup,
    // so for test-mutated env vars we fall back to libc's getenv which reads the live
    // process environment block. Without this fallback, runtime setenv() in tests
    // would never be visible to envFlagSet / envMuteDefaults.
    if (cached_env) |map| {
        if (map.get(name)) |v| return try allocator.dupe(u8, v);
    }
    if (@hasDecl(std.c, "getenv")) {
        // Build a null-terminated name. Stack-allocate a small buffer for short keys.
        var buf: [256]u8 = undefined;
        if (name.len + 1 > buf.len) return error.EnvironmentVariableNotFound;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const name_z: [*:0]const u8 = @ptrCast(&buf);
        if (std.c.getenv(name_z)) |val_ptr| {
            const val = std.mem.span(val_ptr);
            return try allocator.dupe(u8, val);
        }
    }
    return error.EnvironmentVariableNotFound;
}
