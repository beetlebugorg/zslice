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

pub const has_threads = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

/// The number of threads to use: `requested`, or one for each CPU if
/// `requested` is 0.
pub fn threadCount(requested: u32) usize {
    if (!has_threads) return 1;
    if (requested > 0) return requested;
    // One core stays free, so that the app (and the desktop) can answer
    // while a slice runs.
    const cpus = std.Thread.getCpuCount() catch 1;
    return if (cpus > 2) cpus - 1 else cpus;
}

pub fn forEach(threads: usize, n: usize, ctx: anytype, comptime func: fn (@TypeOf(ctx), usize) anyerror!void) anyerror!void {
    if (!has_threads or threads <= 1 or n <= 1) {
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
    var pool: [64]std.Thread = undefined;
    const want = @min(threads, n, pool.len) - 1;
    var spawned: usize = 0;
    while (spawned < want) : (spawned += 1) {
        pool[spawned] = std.Thread.spawn(.{}, Shared.work, .{&shared}) catch break;
    }
    // The calling thread also works.
    shared.work();
    for (pool[0..spawned]) |t| t.join();
    if (shared.failed.load(.acquire)) return shared.err;
}

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
