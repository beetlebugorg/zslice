//! A parallel loop: run `func(ctx, i)` for i in 0..n on several threads.
//!
//! Each thread takes the next index from one atomic counter. A thread that
//! finishes a fast item takes the next one at once, so the threads stay busy
//! when some items take longer than others. The first error stops the loop.
//!
//! On a target without threads (for example wasm32-freestanding), the loop
//! runs on the calling thread.

const std = @import("std");
const builtin = @import("builtin");

/// True if the target has the threads of the operating system.
pub const has_threads = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

/// True for the wasm module with threads. It cannot start a thread: the
/// host starts each thread (a Web Worker with an instance of the module on
/// the same memory), and the thread waits in `workerMain` for work.
pub const wasm_pool = !builtin.single_threaded and builtin.cpu.arch.isWasm();

/// True if `spawn` can give a thread.
pub const can_spawn = has_threads or wasm_pool;

/// A thread that runs one function: a new thread of the operating system,
/// or a thread of the wasm pool.
pub const Thread = if (has_threads) std.Thread else if (wasm_pool) *PoolThread else void;

pub fn spawn(comptime T: type, comptime func: fn (*T) void, arg: *T) error{NoThread}!Thread {
    if (has_threads) return std.Thread.spawn(.{}, func, .{arg}) catch error.NoThread;
    if (!wasm_pool) return error.NoThread;
    const run = struct {
        fn f(p: *anyopaque) void {
            func(@ptrCast(@alignCast(p)));
        }
    }.f;
    for (pool[0..pool_len.load(.acquire)]) |*t| {
        if (t.state.cmpxchgStrong(idle, claimed, .acquire, .monotonic) != null) continue;
        t.func = run;
        t.arg = arg;
        t.state.store(running, .release);
        wake(&t.state.raw);
        return t;
    }
    return error.NoThread;
}

pub fn join(t: Thread) void {
    if (has_threads) return t.join();
    if (!wasm_pool) return;
    while (true) {
        const s = t.state.load(.acquire);
        if (s == done) break;
        waitFor(&t.state.raw, s, -1);
    }
    t.state.store(idle, .release);
}

// The states of a thread of the wasm pool.
const absent = 0;
const idle = 1;
const claimed = 2;
const running = 3;
const done = 4;

pub const PoolThread = struct {
    state: std.atomic.Value(u32) = .init(absent),
    func: *const fn (*anyopaque) void = undefined,
    arg: *anyopaque = undefined,
};

pub const max_pool = 31;
var pool: [max_pool]PoolThread = @splat(.{});
/// The threads of the pool are pool[0..pool_len]. The host starts them in
/// order.
var pool_len: std.atomic.Value(u32) = .init(0);

/// The loop of thread `index` of the wasm pool. It does not return.
pub fn workerMain(index: u32) noreturn {
    const t = &pool[index];
    t.state.store(idle, .release);
    _ = pool_len.fetchMax(index + 1, .acq_rel);
    while (true) {
        const s = t.state.load(.acquire);
        if (s != running) {
            waitFor(&t.state.raw, s, -1);
            continue;
        }
        // Another thread can have made the memory larger while this one
        // was asleep (see wasm_heap.zig).
        @import("wasm_heap.zig").sync();
        t.func(t.arg);
        t.state.store(done, .release);
        wake(&t.state.raw);
    }
}

/// The threads of the wasm pool that wait for work or do work.
pub fn poolSize() u32 {
    return if (wasm_pool) pool_len.load(.acquire) else 0;
}

/// Sleeps while `ptr.*` is `expect`, until a `wake`, or for `timeout_ns`
/// (no limit if negative). Wasm with threads only.
fn waitFor(ptr: *const u32, expect: u32, timeout_ns: i64) void {
    _ = asm volatile (
        \\ local.get %[ptr]
        \\ local.get %[expect]
        \\ local.get %[timeout]
        \\ memory.atomic.wait32 0
        \\ local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [expect] "r" (expect),
          [timeout] "r" (timeout_ns),
    );
}

fn wake(ptr: *const u32) void {
    _ = asm volatile (
        \\ local.get %[ptr]
        \\ local.get %[waiters]
        \\ memory.atomic.notify 0
        \\ local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [waiters] "r" (@as(u32, std.math.maxInt(u32))),
    );
}

/// The number of threads to use: `requested`, or one for each CPU if
/// `requested` is 0.
pub fn threadCount(requested: u32) usize {
    if (wasm_pool) {
        // The host starts the threads: all CPUs but one, as below.
        const have = poolSize() + 1;
        return if (requested > 0) @min(requested, have) else have;
    }
    if (!has_threads) return 1;
    if (requested > 0) return requested;
    // One core stays free, so that the app (and the desktop) can answer
    // while a slice runs.
    const cpus = std.Thread.getCpuCount() catch 1;
    return if (cpus > 2) cpus - 1 else cpus;
}

pub fn forEach(threads: usize, n: usize, ctx: anytype, comptime func: fn (@TypeOf(ctx), usize) anyerror!void) anyerror!void {
    if (!can_spawn or threads <= 1 or n <= 1) {
        for (0..n) |i| try func(ctx, i);
        return;
    }

    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        err: anyerror = error.Unexpected,
        n: usize,
        ctx: @TypeOf(ctx),

        fn work(self: *@This()) void {
            while (!self.failed.load(.acquire)) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= self.n) return;
                func(self.ctx, i) catch |e| {
                    if (!self.failed.swap(true, .acq_rel)) self.err = e;
                    return;
                };
            }
        }
    };

    var shared: Shared = .{ .n = n, .ctx = ctx };
    var list: [64]Thread = undefined;
    const want = @min(threads, n, list.len) - 1;
    var spawned: usize = 0;
    while (spawned < want) : (spawned += 1) {
        list[spawned] = spawn(Shared, Shared.work, &shared) catch break;
    }
    // The calling thread also works.
    shared.work();
    for (list[0..spawned]) |t| join(t);
    if (shared.failed.load(.acquire)) return shared.err;
}

/// A counter that threads wait on: a thread reads the counter, checks its
/// condition, and waits until the counter changes. Another thread changes
/// the state, then calls `notify`. On Linux, the wait sleeps in the kernel
/// (a futex). On other systems, it gives the CPU to another thread.
pub const Signal = struct {
    seq: std.atomic.Value(u32) = .init(0),

    pub fn current(s: *const Signal) u32 {
        return s.seq.load(.acquire);
    }

    /// Waits until the counter is not `seen`, or at most 1 ms.
    pub fn wait(s: *Signal, seen: u32) void {
        if (builtin.os.tag == .linux) {
            const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = std.os.linux.futex_4arg(&s.seq.raw, .{ .cmd = .WAIT, .private = true }, seen, &ts);
        } else if (wasm_pool) {
            waitFor(&s.seq.raw, seen, 1_000_000);
        } else if (has_threads) {
            std.Thread.yield() catch {};
        }
    }

    pub fn notify(s: *Signal) void {
        _ = s.seq.fetchAdd(1, .release);
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.futex_3arg(&s.seq.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
        } else if (wasm_pool) {
            wake(&s.seq.raw);
        }
    }
};

test "forEach visits each index once" {
    var hits: [1000]std.atomic.Value(u32) = undefined;
    for (&hits) |*h| h.* = .init(0);
    try forEach(4, hits.len, &hits, struct {
        fn f(h: *[1000]std.atomic.Value(u32), i: usize) anyerror!void {
            _ = h[i].fetchAdd(1, .monotonic);
        }
    }.f);
    for (&hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
}

test "forEach returns the error" {
    const r = forEach(4, 100, {}, struct {
        fn f(_: void, i: usize) anyerror!void {
            if (i == 50) return error.TestFailure;
        }
    }.f);
    try std.testing.expectError(error.TestFailure, r);
}
