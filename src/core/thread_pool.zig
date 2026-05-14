//! Thread pool shim for par2z.
//!
//! Zig 0.16 removed `std.Thread.Pool`, `std.Thread.WaitGroup`, and `std.Thread.Mutex`
//! (see `ZIG_0.15_TO_0.16_MIGRATION.md` -> "internal pool shim avoids plumbing io" /
//! "Thread.Mutex removed - for lazy-init globals" / "cheap drop-in via atomic SpinMutex").
//!
//! par2z's core is pure-compute (Reed-Solomon GF(2^16) work) and intentionally has
//! NO io plumbing. Threading `std.Io` through every encode/decode call just to
//! satisfy `std.Io.Mutex.lock(io)` / `std.Io.Group.async(io, ...)` would be invasive
//! and conceptually wrong. So we provide a small Pool/WaitGroup/Mutex set that
//! reproduces just the surface rs.zig and lib.zig use:
//!
//!   - Pool.init / Pool.deinit
//!   - Pool.spawnWg(&wg, function, args_tuple)
//!   - WaitGroup{}, WaitGroup.wait()
//!   - SpinMutex (lazy-init guard for the global pool; replaces std.Thread.Mutex)
//!
//! Workers idle by `Thread.yield()` (RS work units are large enough that the
//! polling overhead is negligible). `std.Thread.spawn`, `std.Thread.join`,
//! `std.Thread.getCpuCount`, and `std.atomic.Value` are all still present in 0.16.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Cheap atomic CAS spinlock — replacement for `std.Thread.Mutex` for short,
/// bounded critical sections. Per the migration doc, this is the right tradeoff
/// when the only blocker to migrating off `Thread.Mutex` is the cost of threading
/// `std.Io` through the call graph. par2z's mutex sites all guard ~few-instruction
/// state updates (last-error slot, lazy-init flag, error capture).
pub const SpinMutex = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

pub const WaitGroup = struct {
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn start(self: *WaitGroup) void {
        _ = self.counter.fetchAdd(1, .monotonic);
    }

    pub fn finish(self: *WaitGroup) void {
        _ = self.counter.fetchSub(1, .release);
    }

    pub fn wait(self: *WaitGroup) void {
        while (self.counter.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }
};

const Job = struct {
    run: *const fn (*Job) void,
    wg: ?*WaitGroup,
    next: ?*Job = null,
};

pub const Pool = struct {
    allocator: Allocator,
    workers: []std.Thread,
    mutex: SpinMutex = .{},
    queue_head: ?*Job = null,
    queue_tail: ?*Job = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const Options = struct {
        allocator: Allocator,
        n_jobs: ?usize = null,
        stack_size: usize = default_stack_size,
    };

    pub const default_stack_size = std.Thread.SpawnConfig.default_stack_size;

    pub fn init(self: *Pool, options: Options) !void {
        const n_default = std.Thread.getCpuCount() catch 1;
        const n = options.n_jobs orelse n_default;
        const worker_count = if (n == 0) 1 else n;
        self.* = .{
            .allocator = options.allocator,
            .workers = try options.allocator.alloc(std.Thread, worker_count),
        };
        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .release);
            for (self.workers[0..spawned]) |t| t.join();
            options.allocator.free(self.workers);
        }
        while (spawned < worker_count) : (spawned += 1) {
            self.workers[spawned] = try std.Thread.spawn(
                .{ .stack_size = options.stack_size },
                workerMain,
                .{self},
            );
        }
    }

    pub fn deinit(self: *Pool) void {
        self.shutdown.store(true, .release);
        for (self.workers) |t| t.join();
        self.allocator.free(self.workers);
        self.* = undefined;
    }

    fn pushJob(self: *Pool, job: *Job) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        job.next = null;
        if (self.queue_tail) |tail| {
            tail.next = job;
            self.queue_tail = job;
        } else {
            self.queue_head = job;
            self.queue_tail = job;
        }
    }

    fn popJob(self: *Pool) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue_head) |head| {
            self.queue_head = head.next;
            if (self.queue_head == null) self.queue_tail = null;
            return head;
        }
        return null;
    }

    fn workerMain(self: *Pool) void {
        while (true) {
            if (self.popJob()) |job| {
                // CRITICAL: capture wg BEFORE calling run — the run callback frees
                // its enclosing closure (which includes the Job struct), so reading
                // `job.wg` afterwards is a use-after-free.
                const maybe_wg = job.wg;
                job.run(job);
                if (maybe_wg) |wg| wg.finish();
            } else {
                if (self.shutdown.load(.acquire)) return;
                std.Thread.yield() catch {};
            }
        }
    }

    /// Heap-allocates a closure that holds `args` and a typed runner, then enqueues it.
    /// Mirrors `std.Thread.Pool.spawnWg` from 0.15. The closure is freed in the run-fn
    /// after the work completes, so this never leaks unless the worker panics.
    pub fn spawnWg(self: *Pool, wg: *WaitGroup, comptime func: anytype, args: anytype) void {
        const Args = @TypeOf(args);
        const Closure = struct {
            job: Job,
            args: Args,
            pool_alloc: Allocator,

            fn run(j: *Job) void {
                const closure: *@This() = @fieldParentPtr("job", j);
                const a = closure.pool_alloc;
                const local_args = closure.args;
                a.destroy(closure);
                @call(.auto, func, local_args);
            }
        };

        wg.start();
        const closure = self.allocator.create(Closure) catch {
            // OOM — run inline on this thread to preserve correctness.
            // (Matches the spirit of spawnWg's "best effort" semantics in 0.15.)
            @call(.auto, func, args);
            wg.finish();
            return;
        };
        closure.* = .{
            .job = .{ .run = Closure.run, .wg = wg },
            .args = args,
            .pool_alloc = self.allocator,
        };
        self.pushJob(&closure.job);
    }
};

// --- Global pool plumbing (per-process singleton, lazy-initialised) ---

pub const PoolConfig = struct {
    n_jobs: ?usize = null,
    stack_size: usize = Pool.default_stack_size,
};

var global_mutex: SpinMutex = .{};
var global_pool: Pool = undefined;
var global_pool_initialized: bool = false;
var global_config: PoolConfig = .{};
var external_pool: ?*Pool = null;
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

pub fn setExternalPool(pool: ?*Pool, max_jobs: ?usize) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    external_pool = pool;
    external_max_jobs = max_jobs;
}

pub fn getGlobalPool() !*Pool {
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

fn initGlobalLocked() !*Pool {
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
