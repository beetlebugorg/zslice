//! Clocks and counts for the stages of one slice.
//!
//! `zslice bench --stages` turns the clocks on. Each stage reads a clock at
//! its start and adds the difference at its end. A stage can run on many
//! threads, so each sum is an atomic value. The CPU time is the time of the
//! thread that ran the stage, so a sum over threads can exceed the wall time.
//!
//! With `on` false, `now` reads no clock and `add` and `tick` do nothing.
//! A slice then pays one relaxed load for each call. The clocks work on
//! Linux. On each other target `now` returns zeros, and the counts still
//! work. No slice result reads this file.
//!
//! Some stages are inside others: `mesh_cut`, `support`, and `islands` are
//! inside `init`. Do not add the rows of the table.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const plate_job = @import("plate_job.zig");

/// The stages of one slice, in the order of the work.
pub const Stage = enum { start, init, mesh_cut, support, islands, plan, prepare, decode, run, link, text, encode, out_sink, scene };

/// The counts that have no clock.
pub const Count = enum { booleans, boolean_points, offsets, offset_points, levels_run, texts_made };

const n_stages = @typeInfo(Stage).@"enum".fields.len;
const n_counts = @typeInfo(Count).@"enum".fields.len;

/// True while the clocks run.
pub var on: std.atomic.Value(bool) = .init(false);

// A sum is a `usize`: wasm32 has no 64-bit atomic. Only Linux reads the
// clocks, and a count of a slice fits in 32 bits.
var wall: [n_stages]std.atomic.Value(usize) = @splat(.init(0));
var cpu: [n_stages]std.atomic.Value(usize) = @splat(.init(0));
var calls: [n_stages]std.atomic.Value(usize) = @splat(.init(0));
var counts: [n_counts]std.atomic.Value(usize) = @splat(.init(0));

/// `plate_job.plans_made` at the last `reset`, and the plans of the slices
/// between a `pause` and a `unpause`.
var plans_base: usize = 0;
var plans_at_pause: usize = 0;
var was_on: bool = false;
var paused: bool = false;

/// One reading of the two clocks, in nanoseconds.
pub const Time = struct { wall: u64 = 0, cpu: u64 = 0 };

fn clock(id: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(id, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// The two clocks now, or zeros with the clocks off.
pub fn now() Time {
    if (comptime builtin.os.tag != .linux) return .{};
    if (!on.load(.monotonic)) return .{};
    return .{ .wall = clock(.MONOTONIC), .cpu = clock(.THREAD_CPUTIME_ID) };
}

/// Adds the time since `t0` to a stage. A `t0` from before the clocks
/// started counts as no time.
pub fn add(s: Stage, t0: Time) void {
    if (!on.load(.monotonic)) return;
    const i = @intFromEnum(s);
    _ = calls[i].fetchAdd(1, .monotonic);
    if (comptime builtin.os.tag != .linux) return;
    if (t0.wall == 0) return;
    const t1 = now();
    _ = wall[i].fetchAdd(@truncate(t1.wall -| t0.wall), .monotonic);
    _ = cpu[i].fetchAdd(@truncate(t1.cpu -| t0.cpu), .monotonic);
}

/// Adds `n` to a count.
pub fn tick(c: Count, n: usize) void {
    if (!on.load(.monotonic)) return;
    _ = counts[@intFromEnum(c)].fetchAdd(n, .monotonic);
}

/// Sets all sums to zero.
pub fn reset() void {
    for (&wall, &cpu, &calls) |*w, *c, *k| {
        w.store(0, .monotonic);
        c.store(0, .monotonic);
        k.store(0, .monotonic);
    }
    for (&counts) |*c| c.store(0, .monotonic);
    plans_base = plate_job.plans_made.load(.monotonic);
}

/// Stops the sums for a slice that the table leaves out.
pub fn pause() void {
    if (paused) return;
    paused = true;
    was_on = on.swap(false, .monotonic);
    plans_at_pause = plate_job.plans_made.load(.monotonic);
}

/// Starts the sums again after `pause`. With no `pause`, it does nothing.
pub fn unpause() void {
    if (!paused) return;
    paused = false;
    plans_base += plate_job.plans_made.load(.monotonic) - plans_at_pause;
    on.store(was_on, .monotonic);
}

/// The calls of a stage since the last `reset`.
pub fn callsOf(s: Stage) usize {
    return calls[@intFromEnum(s)].load(.monotonic);
}

/// A count since the last `reset`.
pub fn countOf(c: Count) usize {
    return counts[@intFromEnum(c)].load(.monotonic);
}

/// The layer plans since the last `reset`.
pub fn plansMade() usize {
    const plans_now = if (paused) plans_at_pause else plate_job.plans_made.load(.monotonic);
    return plans_now - plans_base;
}

/// One decimal for a mean, and no decimal for a whole number.
fn mean(x: usize, slices: f64) f64 {
    return @round(@as(f64, @floatFromInt(x)) / slices * 10) / 10;
}

/// Prints the table for one slice: the mean of `slices` slices.
pub fn print(w: *std.Io.Writer, slices: f64) std.Io.Writer.Error!void {
    for (0..n_stages) |i| {
        const k = calls[i].load(.monotonic);
        if (k == 0) continue;
        const name = @tagName(@as(Stage, @enumFromInt(i)));
        const wall_ms = @as(f64, @floatFromInt(wall[i].load(.monotonic))) / 1e6 / slices;
        const cpu_ms = @as(f64, @floatFromInt(cpu[i].load(.monotonic))) / 1e6 / slices;
        try w.print("  {s:<9} wall {d:>8.2} ms  cpu {d:>8.2} ms  calls {d:>8.1}\n", .{ name, wall_ms, cpu_ms, @as(f64, @floatFromInt(k)) / slices });
    }
    const plans = plansMade();
    try w.print("  plans {d}  levels_run {d}  texts_made {d}  booleans {d}  offsets {d}\n", .{
        mean(plans, slices),
        mean(counts[@intFromEnum(Count.levels_run)].load(.monotonic), slices),
        mean(counts[@intFromEnum(Count.texts_made)].load(.monotonic), slices),
        mean(counts[@intFromEnum(Count.booleans)].load(.monotonic), slices),
        mean(counts[@intFromEnum(Count.offsets)].load(.monotonic), slices),
    });
}

test "the clocks read nothing while they are off" {
    try std.testing.expect(!on.load(.monotonic));
    const t = now();
    try std.testing.expectEqual(@as(u64, 0), t.wall);
    add(.plan, t);
    tick(.booleans, 3);
    try std.testing.expectEqual(@as(usize, 0), calls[@intFromEnum(Stage.plan)].load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), counts[@intFromEnum(Count.booleans)].load(.monotonic));
}
