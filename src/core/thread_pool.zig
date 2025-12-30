const std = @import("std");

pub const PoolConfig = struct {
	n_jobs: ?usize = null,
	stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
};

var global_mutex: std.Thread.Mutex = .{};
var global_pool: std.Thread.Pool = undefined;
var global_pool_initialized: bool = false;
var global_config: PoolConfig = .{};
var external_pool: ?*std.Thread.Pool = null;
var external_max_jobs: ?usize = null;

pub fn configureGlobalPool(config: PoolConfig) !void {
	global_mutex.lock();
	defer global_mutex.unlock();
	external_pool = null;
	external_max_jobs = null;
	global_config = config;
	if (global_pool_initialized) {
		global_pool.deinit();
		global_pool_initialized = false;
	}
	_ = try initGlobalLocked();
}

pub fn setExternalPool(pool: ?*std.Thread.Pool, max_jobs: ?usize) void {
	global_mutex.lock();
	defer global_mutex.unlock();
	external_pool = pool;
	external_max_jobs = max_jobs;
}

pub fn getGlobalPool() !*std.Thread.Pool {
	global_mutex.lock();
	defer global_mutex.unlock();
	if (external_pool) |pool| return pool;
	return try initGlobalLocked();
}

pub fn maxJobs() ?usize {
	global_mutex.lock();
	defer global_mutex.unlock();
	if (external_pool != null) return external_max_jobs;
	return global_config.n_jobs;
}

fn initGlobalLocked() !*std.Thread.Pool {
	if (!global_pool_initialized) {
		try global_pool.init(.{
			.allocator = std.heap.page_allocator,
			.n_jobs = global_config.n_jobs,
			.stack_size = global_config.stack_size,
		});
		global_pool_initialized = true;
	}
	return &global_pool;
}
