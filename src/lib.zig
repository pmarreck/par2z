const std = @import("std");
const ops = @import("ops");

pub const version_string: []const u8 = "par2-cleanroom 0.1.0";

pub const Par2Error = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    io_error = 2,
    out_of_memory = 3,
    internal_error = 4,
    unsupported = 5,
    not_found = 6,
    data_corrupt = 7,
};

pub const Par2CreateHandle = opaque {};
pub const Par2VerifyHandle = opaque {};
pub const Par2RecoverHandle = opaque {};

pub const Par2AllocFn = *const fn (ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const Par2ReallocFn = *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const Par2FreeFn = *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, alignment: usize) callconv(.c) void;

pub const Par2Allocator = extern struct {
    ctx: ?*anyopaque = null,
    alloc: ?Par2AllocFn = null,
    realloc: ?Par2ReallocFn = null,
    free: ?Par2FreeFn = null,
};

pub const Par2ReadAtFn = *const fn (ctx: ?*anyopaque, offset: u64, out: [*]u8, len: usize) callconv(.c) usize;

pub const Par2WriteFn = *const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) usize;
pub const Par2CloseFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

pub const Par2Output = extern struct {
    ctx: ?*anyopaque = null,
    write: ?Par2WriteFn = null,
    close: ?Par2CloseFn = null,
};

pub const Par2OpenOutputFn = *const fn (ctx: ?*anyopaque, path: [*:0]const u8, out: *Par2Output) callconv(.c) Par2Error;

pub const Par2CreateOptions = extern struct {
    block_size: u64 = 0,
    block_count: u64 = 0,
    redundancy_percent: u64 = 0,
    recovery_blocks: u64 = 0,
    first_recovery_block: u64 = 0,
    uniform_recovery: u32 = 0,
    limit_recovery: u32 = 0,
    recovery_file_count: u64 = 0,
    include_input_slices: u32 = 0,
    emit_packed: u32 = 0,
    emit_rfsc: u32 = 1,
    include_volume_meta: u32 = 1,
    thread_count: u32 = 0,
    memory_mb: u64 = 0,
    basepath: ?[*:0]const u8 = null,
    comment: ?[*:0]const u8 = null,
    allocator: Par2Allocator = .{},
};

pub const Par2VerifyOptions = extern struct {
    memory_mb: u64 = 0,
    basepath: ?[*:0]const u8 = null,
    allocator: Par2Allocator = .{},
};

pub const Par2RecoverOptions = extern struct {
    memory_mb: u64 = 0,
    allow_unsafe_paths: u32 = 0,
    thread_count: u32 = 0,
    basepath: ?[*:0]const u8 = null,
    allocator: Par2Allocator = .{},
};

const AllocState = struct {
    callbacks: Par2Allocator,
    fallback: std.mem.Allocator,

    pub fn allocator(self: *AllocState) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *AllocState = @ptrCast(@alignCast(ctx));
        if (self.callbacks.alloc) |cb| {
            const ptr = cb(self.callbacks.ctx, len, alignment.toByteUnits());
            return @ptrCast(ptr);
        }
        return self.fallback.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocState = @ptrCast(@alignCast(ctx));
        if (self.callbacks.realloc != null) {
            return false;
        }
        return self.fallback.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *AllocState = @ptrCast(@alignCast(ctx));
        if (self.callbacks.realloc) |cb| {
            const ptr = cb(self.callbacks.ctx, buf.ptr, buf.len, new_len, alignment.toByteUnits());
            return @ptrCast(ptr);
        }
        return self.fallback.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *AllocState = @ptrCast(@alignCast(ctx));
        if (self.callbacks.free) |cb| {
            cb(self.callbacks.ctx, buf.ptr, buf.len, alignment.toByteUnits());
            return;
        }
        self.fallback.rawFree(buf, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const COpenCtx = struct {
    open_fn: Par2OpenOutputFn,
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
};

const COutputState = struct {
    output: Par2Output,
    allocator: std.mem.Allocator,
};

fn anyErrorFromPar2(code: Par2Error) anyerror {
    return switch (code) {
        .ok => error.InvalidInput,
        .invalid_argument => error.InvalidInput,
        .io_error => error.IoError,
        .out_of_memory => error.OutOfMemory,
        .internal_error => error.InternalError,
        .unsupported => error.Unsupported,
        .not_found => error.NotFound,
        .data_corrupt => error.DataCorrupt,
    };
}

fn cOutputWrite(ctx: *anyopaque, data: []const u8) anyerror!usize {
    const state: *COutputState = @ptrCast(@alignCast(ctx));
    if (state.output.write) |write_fn| {
        const n = write_fn(state.output.ctx, data.ptr, data.len);
        if (n == 0 and data.len != 0) return error.IoError;
        return n;
    }
    return error.InvalidInput;
}

fn cOutputClose(ctx: *anyopaque) void {
    const state: *COutputState = @ptrCast(@alignCast(ctx));
    if (state.output.close) |close_fn| {
        close_fn(state.output.ctx);
    }
    state.allocator.destroy(state);
}

fn openOutputC(ctx: *anyopaque, path: []const u8) anyerror!ops.OutputTarget {
    const open_ctx: *COpenCtx = @ptrCast(@alignCast(ctx));
    const path_z = open_ctx.allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer open_ctx.allocator.free(path_z);
    var out: Par2Output = .{};
    const rc = open_ctx.open_fn(open_ctx.ctx, path_z, &out);
    if (rc != .ok) return anyErrorFromPar2(rc);
    if (out.write == null) return error.InvalidInput;
    const state = open_ctx.allocator.create(COutputState) catch return error.OutOfMemory;
    state.* = .{ .output = out, .allocator = open_ctx.allocator };
    return .{ .ctx = state, .writeFn = cOutputWrite, .closeFn = cOutputClose };
}

const CreateHandle = struct {
    alloc_state: AllocState,
    allocator: std.mem.Allocator,
    options: ops.CreateOptions,
    data_paths: std.ArrayList([]const u8),
    par2_path: ?[]const u8,
    basepath: ?[]const u8,
    comment: ?[]const u8,
    memory_inputs: bool,
    par2_data: ?[]const u8,
    output_open: ?Par2OpenOutputFn,
    output_ctx: ?*anyopaque,
    temp_dir: ?[]const u8,
    temp_paths: std.ArrayList([]const u8),
    last_error: ?[]u8,
};

const VerifyHandle = struct {
    alloc_state: AllocState,
    allocator: std.mem.Allocator,
    options: ops.VerifyOptions,
    data_paths: std.ArrayList([]const u8),
    par2_path: ?[]const u8,
    basepath: ?[]const u8,
    par2_data: ?[]const u8,
    memory_inputs: bool,
    temp_dir: ?[]const u8,
    temp_paths: std.ArrayList([]const u8),
    last_error: ?[]u8,
};

const RecoverHandle = struct {
    alloc_state: AllocState,
    allocator: std.mem.Allocator,
    options: ops.RecoverOptions,
    data_paths: std.ArrayList([]const u8),
    par2_path: ?[]const u8,
    basepath: ?[]const u8,
    par2_data: ?[]const u8,
    memory_inputs: bool,
    output_dir: ?[]const u8,
    output_open: ?Par2OpenOutputFn,
    output_ctx: ?*anyopaque,
    temp_dir: ?[]const u8,
    temp_paths: std.ArrayList([]const u8),
    last_error: ?[]u8,
};

pub fn zigVersion() []const u8 {
    return version_string;
}

pub export fn par2_version() [*:0]const u8 {
    return "par2-cleanroom 0.1.0";
}

fn hasCallbacks(alloc: Par2Allocator) bool {
    return alloc.alloc != null or alloc.realloc != null or alloc.free != null;
}

fn initAllocState(alloc: Par2Allocator) AllocState {
    return .{ .callbacks = alloc, .fallback = std.heap.c_allocator };
}

fn allocHandle(comptime T: type, alloc_state: *AllocState) ?*T {
    const alignment = @alignOf(T);
    const size = @sizeOf(T);
    if (alloc_state.callbacks.alloc) |cb| {
        const ptr = cb(alloc_state.callbacks.ctx, size, alignment) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }
    return std.heap.c_allocator.create(T) catch return null;
}

fn freeHandle(comptime T: type, alloc_state: *AllocState, handle: *T) void {
    const alignment = @alignOf(T);
    const size = @sizeOf(T);
    if (alloc_state.callbacks.free) |cb| {
        cb(alloc_state.callbacks.ctx, handle, size, alignment);
        return;
    }
    std.heap.c_allocator.destroy(handle);
}

fn setLastError(allocator: std.mem.Allocator, slot: *?[]u8, msg: []const u8) void {
    if (slot.*) |old| allocator.free(old);
    const buf = allocator.alloc(u8, msg.len + 1) catch {
        slot.* = null;
        return;
    };
    @memcpy(buf[0..msg.len], msg);
    buf[msg.len] = 0;
    slot.* = buf;
}

fn errorCodeFrom(err: anyerror) Par2Error {
    switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidInput => return .invalid_argument,
        error.IoError => return .io_error,
        error.NotFound => return .not_found,
        else => return .internal_error,
    }
}

fn ensureTempDir(allocator: std.mem.Allocator, temp_dir: *?[]const u8) ![]const u8 {
    if (temp_dir.*) |path| return path;
    const base = std.process.getEnvVarOwned(allocator, "TMPDIR") catch "/tmp";
    defer if (!std.mem.eql(u8, base, "/tmp")) allocator.free(base);
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        const suffix = std.crypto.random.int(u64);
        const path = try std.fmt.allocPrint(allocator, "{s}/par2capi-{x}", .{ base, suffix });
        std.fs.cwd().makeDir(path) catch |e| {
            if (e == error.PathAlreadyExists) {
                allocator.free(path);
                continue;
            }
            allocator.free(path);
            return e;
        };
        temp_dir.* = path;
        return path;
    }
    return error.IoError;
}

fn hasTraversalSegment(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

fn writeTempFile(allocator: std.mem.Allocator, temp_dir: []const u8, name: []const u8, data: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(name)) return error.InvalidInput;
    if (hasTraversalSegment(name)) return error.InvalidInput;
    const out_path = try std.fs.path.join(allocator, &.{ temp_dir, name });
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) try std.fs.cwd().makePath(dir);
    }
    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
    return out_path;
}

fn writeTempFileFromStream(allocator: std.mem.Allocator, temp_dir: []const u8, name: []const u8, len: u64, read_at: Par2ReadAtFn, ctx: ?*anyopaque) ![]const u8 {
    if (std.fs.path.isAbsolute(name)) return error.InvalidInput;
    if (hasTraversalSegment(name)) return error.InvalidInput;
    const out_path = try std.fs.path.join(allocator, &.{ temp_dir, name });
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) try std.fs.cwd().makePath(dir);
    }
    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    var offset: u64 = 0;
    var buf: [32768]u8 = undefined;
    while (offset < len) {
        const remain = len - offset;
        const chunk = @min(remain, buf.len);
        const read_len = read_at(ctx, offset, &buf, @as(usize, @intCast(chunk)));
        if (read_len == 0) return error.IoError;
        try file.writeAll(buf[0..read_len]);
        offset += read_len;
    }
    return out_path;
}

fn castCreate(handle: *Par2CreateHandle) *CreateHandle {
    return @ptrCast(@alignCast(handle));
}

fn castVerify(handle: *Par2VerifyHandle) *VerifyHandle {
    return @ptrCast(@alignCast(handle));
}

fn castRecover(handle: *Par2RecoverHandle) *RecoverHandle {
    return @ptrCast(@alignCast(handle));
}

pub export fn par2_create_new(opts: ?*const Par2CreateOptions, out_handle: ?*?*Par2CreateHandle) Par2Error {
    if (out_handle == null) return .invalid_argument;
    var alloc_state = initAllocState(if (opts) |o| o.allocator else .{});
    const handle = allocHandle(CreateHandle, &alloc_state) orelse return .out_of_memory;
    const basepath = if (opts) |o| o.basepath else null;
    const comment = if (opts) |o| o.comment else null;
    const memory_mb = if (opts) |o| o.memory_mb else 0;
    const thread_count = if (opts) |o| o.thread_count else 0;
    const block_size = if (opts) |o| o.block_size else 0;
    const block_count = if (opts) |o| o.block_count else 0;
    const redundancy_percent = if (opts) |o| o.redundancy_percent else 5;
    const recovery_blocks = if (opts) |o| o.recovery_blocks else 0;
    const first_recovery_block = if (opts) |o| o.first_recovery_block else 0;
    const uniform_recovery = if (opts) |o| o.uniform_recovery != 0 else false;
    const limit_recovery = if (opts) |o| o.limit_recovery != 0 else false;
    const recovery_file_count = if (opts) |o| o.recovery_file_count else 0;
    const include_input_slices = if (opts) |o| o.include_input_slices != 0 else false;
    const emit_packed = if (opts) |o| o.emit_packed != 0 else false;
    const emit_rfsc = if (opts) |o| o.emit_rfsc != 0 else true;
    const include_volume_meta = if (opts) |o| o.include_volume_meta != 0 else true;

    handle.* = .{
        .alloc_state = alloc_state,
        .allocator = std.heap.c_allocator,
        .options = .{
            .block_size = if (block_size == 0) null else block_size,
            .block_count = if (block_count == 0) null else block_count,
            .redundancy_percent = if (redundancy_percent == 0) null else redundancy_percent,
            .recovery_blocks = if (recovery_blocks == 0) null else recovery_blocks,
            .first_recovery_block = if (first_recovery_block == 0) null else first_recovery_block,
            .uniform_recovery = uniform_recovery,
            .limit_recovery = limit_recovery,
            .recovery_file_count = if (recovery_file_count == 0) null else recovery_file_count,
            .par2_path = "",
            .data_paths = &.{},
            .mute_defaults = true,
            .comment = null,
            .include_input_slices = include_input_slices,
            .emit_packed = emit_packed,
            .emit_rfsc = emit_rfsc,
            .include_volume_meta = include_volume_meta,
            .basepath = null,
            .verbosity = -1,
            .memory_mb = if (memory_mb == 0) null else memory_mb,
            .recurse = false,
            .thread_count = if (thread_count == 0) null else thread_count,
            .output_open = null,
        },
        .data_paths = std.ArrayList([]const u8).empty,
        .par2_path = null,
        .basepath = null,
        .comment = null,
        .memory_inputs = false,
        .par2_data = null,
        .output_open = null,
        .output_ctx = null,
        .temp_dir = null,
        .temp_paths = std.ArrayList([]const u8).empty,
        .last_error = null,
    };
    handle.allocator = if (hasCallbacks(handle.alloc_state.callbacks)) handle.alloc_state.allocator() else std.heap.c_allocator;
    if (basepath) |bp| {
        handle.basepath = handle.allocator.dupe(u8, std.mem.span(bp)) catch null;
    }
    if (comment) |c| {
        handle.comment = handle.allocator.dupe(u8, std.mem.span(c)) catch null;
        handle.options.comment = handle.comment;
    }
    out_handle.?.* = @ptrCast(handle);
    return .ok;
}

pub export fn par2_create_destroy(handle: ?*Par2CreateHandle) void {
    if (handle == null) return;
    var h = castCreate(handle.?);
    const allocator = h.allocator;
    if (h.last_error) |msg| allocator.free(msg);
    for (h.data_paths.items) |p| allocator.free(p);
    if (h.temp_dir) |d| {
        _ = std.fs.cwd().deleteTree(d) catch {};
        allocator.free(d);
    }
    if (h.basepath) |bp| allocator.free(bp);
    if (h.comment) |c| allocator.free(c);
    h.data_paths.deinit(allocator);
    h.temp_paths.deinit(allocator);
    freeHandle(CreateHandle, &h.alloc_state, h);
}

pub export fn par2_create_add_path(handle: ?*Par2CreateHandle, path: ?[*:0]const u8) Par2Error {
    if (handle == null or path == null) return .invalid_argument;
    var h = castCreate(handle.?);
    if (h.memory_inputs) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const p = h.allocator.dupe(u8, std.mem.span(path.?)) catch return .out_of_memory;
    h.data_paths.append(h.allocator, p) catch return .out_of_memory;
    return .ok;
}

pub export fn par2_create_add_memory(handle: ?*Par2CreateHandle, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) Par2Error {
    if (handle == null or name == null or data == null) return .invalid_argument;
    var h = castCreate(handle.?);
    if (h.data_paths.items.len > 0) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp dir creation failed");
        return errorCodeFrom(e);
    };
    const name_slice = std.mem.span(name.?);
    const data_slice = data.?[0..len];
    const temp_path = writeTempFile(h.allocator, temp_dir, name_slice, data_slice) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp file write failed");
        return errorCodeFrom(e);
    };
    h.data_paths.append(h.allocator, temp_path) catch return .out_of_memory;
    h.memory_inputs = true;
    return .ok;
}

pub export fn par2_create_add_stream(handle: ?*Par2CreateHandle, name: ?[*:0]const u8, len: u64, read_at: ?Par2ReadAtFn, ctx: ?*anyopaque) Par2Error {
    if (handle == null or name == null or read_at == null) return .invalid_argument;
    var h = castCreate(handle.?);
    if (h.data_paths.items.len > 0) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp dir creation failed");
        return errorCodeFrom(e);
    };
    const name_slice = std.mem.span(name.?);
    const temp_path = writeTempFileFromStream(h.allocator, temp_dir, name_slice, len, read_at.?, ctx) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp file write failed");
        return errorCodeFrom(e);
    };
    h.data_paths.append(h.allocator, temp_path) catch return .out_of_memory;
    h.memory_inputs = true;
    return .ok;
}

pub export fn par2_create_set_output_path(handle: ?*Par2CreateHandle, par2_path: ?[*:0]const u8) Par2Error {
    if (handle == null or par2_path == null) return .invalid_argument;
    var h = castCreate(handle.?);
    const p = h.allocator.dupe(u8, std.mem.span(par2_path.?)) catch return .out_of_memory;
    h.par2_path = p;
    return .ok;
}

pub export fn par2_create_set_output_open(handle: ?*Par2CreateHandle, open_fn: ?Par2OpenOutputFn, ctx: ?*anyopaque) Par2Error {
    if (handle == null) return .invalid_argument;
    var h = castCreate(handle.?);
    h.output_open = open_fn;
    h.output_ctx = ctx;
    return .ok;
}

pub export fn par2_create_run(handle: ?*Par2CreateHandle) Par2Error {
    if (handle == null) return .invalid_argument;
    var h = castCreate(handle.?);
    if (h.par2_path == null) return .invalid_argument;
    var output_open: ?ops.OutputOpener = null;
    var open_ctx: COpenCtx = undefined;
    if (h.output_open) |open_fn| {
        open_ctx = .{ .open_fn = open_fn, .ctx = h.output_ctx, .allocator = h.allocator };
        output_open = .{ .ctx = &open_ctx, .openFn = openOutputC };
    }
    const basepath = if (h.memory_inputs) h.temp_dir else h.basepath;
    const opts = ops.CreateOptions{
        .block_size = h.options.block_size,
        .block_count = h.options.block_count,
        .redundancy_percent = h.options.redundancy_percent,
        .recovery_blocks = h.options.recovery_blocks,
        .first_recovery_block = h.options.first_recovery_block,
        .uniform_recovery = h.options.uniform_recovery,
        .limit_recovery = h.options.limit_recovery,
        .recovery_file_count = h.options.recovery_file_count,
        .par2_path = h.par2_path.?,
        .data_paths = h.data_paths.items,
        .mute_defaults = h.options.mute_defaults,
        .comment = h.options.comment,
        .include_input_slices = h.options.include_input_slices,
        .emit_packed = h.options.emit_packed,
        .emit_rfsc = h.options.emit_rfsc,
        .include_volume_meta = h.options.include_volume_meta,
        .basepath = basepath,
        .verbosity = h.options.verbosity,
        .memory_mb = h.options.memory_mb,
        .recurse = h.options.recurse,
        .thread_count = h.options.thread_count,
        .output_open = output_open,
    };
    ops.create(h.allocator, opts) catch |e| {
        setLastError(h.allocator, &h.last_error, @errorName(e));
        return errorCodeFrom(e);
    };
    return .ok;
}

pub export fn par2_create_last_error(handle: ?*Par2CreateHandle) ?[*:0]const u8 {
    if (handle == null) return null;
    const h = castCreate(handle.?);
    return if (h.last_error) |msg| @ptrCast(msg.ptr) else null;
}

pub export fn par2_verify_new(opts: ?*const Par2VerifyOptions, out_handle: ?*?*Par2VerifyHandle) Par2Error {
    if (out_handle == null) return .invalid_argument;
    var alloc_state = initAllocState(if (opts) |o| o.allocator else .{});
    const handle = allocHandle(VerifyHandle, &alloc_state) orelse return .out_of_memory;
    const basepath = if (opts) |o| o.basepath else null;
    const memory_mb = if (opts) |o| o.memory_mb else 0;
    handle.* = .{
        .alloc_state = alloc_state,
        .allocator = std.heap.c_allocator,
        .options = .{
            .par2_path = "",
            .data_paths = &.{},
            .basepath = null,
            .verbosity = -1,
            .memory_mb = if (memory_mb == 0) null else memory_mb,
        },
        .data_paths = std.ArrayList([]const u8).empty,
        .par2_path = null,
        .basepath = null,
        .par2_data = null,
        .memory_inputs = false,
        .temp_dir = null,
        .temp_paths = std.ArrayList([]const u8).empty,
        .last_error = null,
    };
    handle.allocator = if (hasCallbacks(handle.alloc_state.callbacks)) handle.alloc_state.allocator() else std.heap.c_allocator;
    if (basepath) |bp| {
        handle.basepath = handle.allocator.dupe(u8, std.mem.span(bp)) catch null;
    }
    out_handle.?.* = @ptrCast(handle);
    return .ok;
}

pub export fn par2_verify_destroy(handle: ?*Par2VerifyHandle) void {
    if (handle == null) return;
    var h = castVerify(handle.?);
    const allocator = h.allocator;
    if (h.last_error) |msg| allocator.free(msg);
    for (h.data_paths.items) |p| allocator.free(p);
    if (h.temp_dir) |d| {
        _ = std.fs.cwd().deleteTree(d) catch {};
        allocator.free(d);
    }
    if (h.basepath) |bp| allocator.free(bp);
    h.data_paths.deinit(allocator);
    h.temp_paths.deinit(allocator);
    freeHandle(VerifyHandle, &h.alloc_state, h);
}

pub export fn par2_verify_set_par2_path(handle: ?*Par2VerifyHandle, par2_path: ?[*:0]const u8) Par2Error {
    if (handle == null or par2_path == null) return .invalid_argument;
    var h = castVerify(handle.?);
    if (h.par2_data != null) return .invalid_argument;
    const p = h.allocator.dupe(u8, std.mem.span(par2_path.?)) catch return .out_of_memory;
    h.par2_path = p;
    return .ok;
}

pub export fn par2_verify_set_par2_data(handle: ?*Par2VerifyHandle, data: ?[*]const u8, len: usize) Par2Error {
    if (handle == null or data == null) return .invalid_argument;
    var h = castVerify(handle.?);
    if (h.par2_path != null) return .invalid_argument;
    h.par2_data = data.?[0..len];
    return .ok;
}

pub export fn par2_verify_add_path(handle: ?*Par2VerifyHandle, path: ?[*:0]const u8) Par2Error {
    if (handle == null or path == null) return .invalid_argument;
    var h = castVerify(handle.?);
    if (h.memory_inputs) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const p = h.allocator.dupe(u8, std.mem.span(path.?)) catch return .out_of_memory;
    h.data_paths.append(h.allocator, p) catch return .out_of_memory;
    return .ok;
}

pub export fn par2_verify_add_memory(handle: ?*Par2VerifyHandle, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) Par2Error {
    if (handle == null or name == null or data == null) return .invalid_argument;
    var h = castVerify(handle.?);
    if (h.data_paths.items.len > 0) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp dir creation failed");
        return errorCodeFrom(e);
    };
    const name_slice = std.mem.span(name.?);
    const data_slice = data.?[0..len];
    const temp_path = writeTempFile(h.allocator, temp_dir, name_slice, data_slice) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp file write failed");
        return errorCodeFrom(e);
    };
    h.data_paths.append(h.allocator, temp_path) catch return .out_of_memory;
    h.memory_inputs = true;
    return .ok;
}

pub export fn par2_verify_add_stream(handle: ?*Par2VerifyHandle, name: ?[*:0]const u8, len: u64, read_at: ?Par2ReadAtFn, ctx: ?*anyopaque) Par2Error {
    if (handle == null or name == null or read_at == null) return .invalid_argument;
    var h = castVerify(handle.?);
    if (h.data_paths.items.len > 0) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp dir creation failed");
        return errorCodeFrom(e);
    };
    const name_slice = std.mem.span(name.?);
    const temp_path = writeTempFileFromStream(h.allocator, temp_dir, name_slice, len, read_at.?, ctx) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp file write failed");
        return errorCodeFrom(e);
    };
    h.data_paths.append(h.allocator, temp_path) catch return .out_of_memory;
    h.memory_inputs = true;
    return .ok;
}

pub export fn par2_verify_run(handle: ?*Par2VerifyHandle) Par2Error {
    if (handle == null) return .invalid_argument;
    var h = castVerify(handle.?);
    var par2_path = h.par2_path;
    if (par2_path == null and h.par2_data != null) {
        const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
            setLastError(h.allocator, &h.last_error, "temp dir creation failed");
            return errorCodeFrom(e);
        };
        const temp_path = writeTempFile(h.allocator, temp_dir, "input.par2", h.par2_data.?) catch |e| {
            setLastError(h.allocator, &h.last_error, "temp file write failed");
            return errorCodeFrom(e);
        };
        par2_path = temp_path;
    }
    if (par2_path == null) {
        setLastError(h.allocator, &h.last_error, "missing par2 path");
        return .invalid_argument;
    }
    const basepath = if (h.memory_inputs) h.temp_dir else h.basepath;
    const opts = ops.VerifyOptions{
        .par2_path = par2_path.?,
        .data_paths = h.data_paths.items,
        .basepath = basepath,
        .verbosity = 0,
        .memory_mb = h.options.memory_mb,
    };
    ops.verify(h.allocator, opts) catch |e| {
        setLastError(h.allocator, &h.last_error, @errorName(e));
        return errorCodeFrom(e);
    };
    return .ok;
}

pub export fn par2_verify_last_error(handle: ?*Par2VerifyHandle) ?[*:0]const u8 {
    if (handle == null) return null;
    const h = castVerify(handle.?);
    return if (h.last_error) |msg| @ptrCast(msg.ptr) else null;
}

pub export fn par2_recover_new(opts: ?*const Par2RecoverOptions, out_handle: ?*?*Par2RecoverHandle) Par2Error {
    if (out_handle == null) return .invalid_argument;
    var alloc_state = initAllocState(if (opts) |o| o.allocator else .{});
    const handle = allocHandle(RecoverHandle, &alloc_state) orelse return .out_of_memory;
    const basepath = if (opts) |o| o.basepath else null;
    const memory_mb = if (opts) |o| o.memory_mb else 0;
    const allow_unsafe = if (opts) |o| o.allow_unsafe_paths != 0 else false;
    const thread_count = if (opts) |o| o.thread_count else 0;
    handle.* = .{
        .alloc_state = alloc_state,
        .allocator = std.heap.c_allocator,
        .options = .{
            .stdout_only = false,
            .out_dir = null,
            .par2_path = "",
            .data_paths = &.{},
            .allow_unsafe_paths = allow_unsafe,
            .basepath = null,
            .verbosity = -1,
            .memory_mb = if (memory_mb == 0) null else memory_mb,
            .output_open = null,
        },
        .data_paths = std.ArrayList([]const u8).empty,
        .par2_path = null,
        .basepath = null,
        .par2_data = null,
        .memory_inputs = false,
        .output_dir = null,
        .output_open = null,
        .output_ctx = null,
        .temp_dir = null,
        .temp_paths = std.ArrayList([]const u8).empty,
        .last_error = null,
    };
    handle.allocator = if (hasCallbacks(handle.alloc_state.callbacks)) handle.alloc_state.allocator() else std.heap.c_allocator;
    if (basepath) |bp| {
        handle.basepath = handle.allocator.dupe(u8, std.mem.span(bp)) catch null;
    }
    _ = thread_count;
    out_handle.?.* = @ptrCast(handle);
    return .ok;
}

pub export fn par2_recover_destroy(handle: ?*Par2RecoverHandle) void {
    if (handle == null) return;
    var h = castRecover(handle.?);
    const allocator = h.allocator;
    if (h.last_error) |msg| allocator.free(msg);
    for (h.data_paths.items) |p| allocator.free(p);
    if (h.temp_dir) |d| {
        _ = std.fs.cwd().deleteTree(d) catch {};
        allocator.free(d);
    }
    if (h.basepath) |bp| allocator.free(bp);
    if (h.output_dir) |d| allocator.free(d);
    h.data_paths.deinit(allocator);
    h.temp_paths.deinit(allocator);
    freeHandle(RecoverHandle, &h.alloc_state, h);
}

pub export fn par2_recover_set_par2_path(handle: ?*Par2RecoverHandle, par2_path: ?[*:0]const u8) Par2Error {
    if (handle == null or par2_path == null) return .invalid_argument;
    var h = castRecover(handle.?);
    if (h.par2_data != null) return .invalid_argument;
    const p = h.allocator.dupe(u8, std.mem.span(par2_path.?)) catch return .out_of_memory;
    h.par2_path = p;
    return .ok;
}

pub export fn par2_recover_set_par2_data(handle: ?*Par2RecoverHandle, data: ?[*]const u8, len: usize) Par2Error {
    if (handle == null or data == null) return .invalid_argument;
    var h = castRecover(handle.?);
    if (h.par2_path != null) return .invalid_argument;
    h.par2_data = data.?[0..len];
    return .ok;
}

pub export fn par2_recover_add_path(handle: ?*Par2RecoverHandle, path: ?[*:0]const u8) Par2Error {
    if (handle == null or path == null) return .invalid_argument;
    var h = castRecover(handle.?);
    if (h.memory_inputs) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const p = h.allocator.dupe(u8, std.mem.span(path.?)) catch return .out_of_memory;
    h.data_paths.append(h.allocator, p) catch return .out_of_memory;
    return .ok;
}

pub export fn par2_recover_add_memory(handle: ?*Par2RecoverHandle, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) Par2Error {
    if (handle == null or name == null or data == null) return .invalid_argument;
    var h = castRecover(handle.?);
    if (h.data_paths.items.len > 0) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp dir creation failed");
        return errorCodeFrom(e);
    };
    const name_slice = std.mem.span(name.?);
    const data_slice = data.?[0..len];
    const temp_path = writeTempFile(h.allocator, temp_dir, name_slice, data_slice) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp file write failed");
        return errorCodeFrom(e);
    };
    h.data_paths.append(h.allocator, temp_path) catch return .out_of_memory;
    h.memory_inputs = true;
    return .ok;
}

pub export fn par2_recover_add_stream(handle: ?*Par2RecoverHandle, name: ?[*:0]const u8, len: u64, read_at: ?Par2ReadAtFn, ctx: ?*anyopaque) Par2Error {
    if (handle == null or name == null or read_at == null) return .invalid_argument;
    var h = castRecover(handle.?);
    if (h.data_paths.items.len > 0) {
        setLastError(h.allocator, &h.last_error, "cannot mix path and memory inputs");
        return .invalid_argument;
    }
    const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp dir creation failed");
        return errorCodeFrom(e);
    };
    const name_slice = std.mem.span(name.?);
    const temp_path = writeTempFileFromStream(h.allocator, temp_dir, name_slice, len, read_at.?, ctx) catch |e| {
        setLastError(h.allocator, &h.last_error, "temp file write failed");
        return errorCodeFrom(e);
    };
    h.data_paths.append(h.allocator, temp_path) catch return .out_of_memory;
    h.memory_inputs = true;
    return .ok;
}

pub export fn par2_recover_set_output_dir(handle: ?*Par2RecoverHandle, out_dir: ?[*:0]const u8) Par2Error {
    if (handle == null or out_dir == null) return .invalid_argument;
    var h = castRecover(handle.?);
    const p = h.allocator.dupe(u8, std.mem.span(out_dir.?)) catch return .out_of_memory;
    h.output_dir = p;
    return .ok;
}

pub export fn par2_recover_set_output_open(handle: ?*Par2RecoverHandle, open_fn: ?Par2OpenOutputFn, ctx: ?*anyopaque) Par2Error {
    if (handle == null) return .invalid_argument;
    var h = castRecover(handle.?);
    h.output_open = open_fn;
    h.output_ctx = ctx;
    return .ok;
}

pub export fn par2_recover_run(handle: ?*Par2RecoverHandle) Par2Error {
    if (handle == null) return .invalid_argument;
    var h = castRecover(handle.?);
    var output_open: ?ops.OutputOpener = null;
    var open_ctx: COpenCtx = undefined;
    if (h.output_open) |open_fn| {
        open_ctx = .{ .open_fn = open_fn, .ctx = h.output_ctx, .allocator = h.allocator };
        output_open = .{ .ctx = &open_ctx, .openFn = openOutputC };
    }
    var par2_path = h.par2_path;
    if (par2_path == null and h.par2_data != null) {
        const temp_dir = ensureTempDir(h.allocator, &h.temp_dir) catch |e| {
            setLastError(h.allocator, &h.last_error, "temp dir creation failed");
            return errorCodeFrom(e);
        };
        const temp_path = writeTempFile(h.allocator, temp_dir, "input.par2", h.par2_data.?) catch |e| {
            setLastError(h.allocator, &h.last_error, "temp file write failed");
            return errorCodeFrom(e);
        };
        par2_path = temp_path;
    }
    if (par2_path == null) return .invalid_argument;
    const basepath = if (h.memory_inputs) h.temp_dir else h.basepath;
    const out_dir = if (h.output_dir) |d| d else blk: {
        if (std.fs.path.dirname(par2_path.?)) |dir| break :blk dir;
        break :blk ".";
    };
    const opts = ops.RecoverOptions{
        .stdout_only = false,
        .out_dir = out_dir,
        .par2_path = par2_path.?,
        .data_paths = h.data_paths.items,
        .allow_unsafe_paths = h.options.allow_unsafe_paths,
        .basepath = basepath,
        .verbosity = h.options.verbosity,
        .memory_mb = h.options.memory_mb,
        .output_open = output_open,
    };
    ops.recover(h.allocator, h.allocator, opts) catch |e| {
        setLastError(h.allocator, &h.last_error, @errorName(e));
        return errorCodeFrom(e);
    };
    return .ok;
}

pub export fn par2_recover_last_error(handle: ?*Par2RecoverHandle) ?[*:0]const u8 {
    if (handle == null) return null;
    const h = castRecover(handle.?);
    return if (h.last_error) |msg| @ptrCast(msg.ptr) else null;
}
