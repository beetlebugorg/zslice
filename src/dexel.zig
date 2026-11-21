//! Layers as line cuts: the part cut in two directions.
//!
//! A layer plane cuts the part into an outline. A second family of planes
//! (vertical sheets, one line width apart, along the direction of the
//! fill lines) cuts the outline again. The result of both cuts is, for
//! each sheet, a list of intervals: the pieces of the line that are in
//! the part. This is a fill line before it is trimmed, straight from the
//! shape.
//!
//! The intervals of all layers are on the same sheets. So a boolean of
//! two layers is a merge of two sorted lists for each sheet, with no
//! polygon boolean:
//!
//! - The solid skin of layer i is its intervals minus the intervals that
//!   are in all the layers above it within the top thickness and below
//!   it within the bottom thickness.
//! - The sparse infill is the rest.
//!
//! The result is exact on each sheet: the ends of the intervals are the
//! true crossings of the sheet and the outlines. Between the sheets
//! there is no data, and a fill line needs none. What the intervals do
//! not give: an offset (the walls, the inset of the fill from the walls)
//! and the clean-up of thin pieces. Those need the distance to the
//! outline (see field.zig).
//!
//! The skin lines turn 90 degrees on each layer, so each layer is cut in
//! both directions: the sheets of its own direction for its lines, and
//! the sheets of the other direction for the skin of its neighbors.
//!
//! `bench --only dexel` measures this method against the polygon
//! booleans (see specs/100 in the project notes). The planner does not
//! use it yet.
//!
//! References (see docs/references/papers-and-algorithms.md): the dexel
//! (depth element) and ray representations of a solid.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const Paths = geom.Paths;

/// The intervals of a shape on a family of lines. Line k of the family is
/// the line with v = k * pitch, where (u, v) are the coordinates turned
/// by the angle of the family: u along the lines, v across them.
pub const Lines = struct {
    /// The index of the first line with data.
    k0: i64 = 0,
    /// start[i] to start[i + 1]: the values of line k0 + i in `u`.
    start: []u32 = &.{},
    /// The ends of the intervals of each line, in order: u[2 j] to
    /// u[2 j + 1] is in the shape.
    u: []f64 = &.{},

    pub fn count(l: Lines) usize {
        return if (l.start.len == 0) 0 else l.start.len - 1;
    }

    /// The intervals of line k (empty if the family has no such line).
    pub fn line(l: Lines, k: i64) []const f64 {
        if (k < l.k0 or k >= l.k0 + @as(i64, @intCast(l.count()))) return &.{};
        const i: usize = @intCast(k - l.k0);
        return l.u[l.start[i]..l.start[i + 1]];
    }

    /// The sum of the lengths of all intervals.
    pub fn length(l: Lines) f64 {
        var sum: f64 = 0;
        var j: usize = 0;
        while (j + 1 < l.u.len) : (j += 2) sum += l.u[j + 1] - l.u[j];
        return sum;
    }
};

/// Cuts `shape` (the non-zero rule) with the lines of the family with
/// the direction `angle` (radians) and the distance `pitch` between
/// lines. A scanline: each edge gives one crossing for each line that it
/// spans, and a sort of the crossings of a line gives its intervals.
pub fn cut(a: Allocator, shape: Paths, angle: f64, pitch: f64) Allocator.Error!Lines {
    const c = @cos(angle);
    const s = @sin(angle);
    var v_min = std.math.inf(f64);
    var v_max = -std.math.inf(f64);
    for (shape.points.items) |p| {
        const v = -@as(f64, @floatFromInt(p.x)) * s + @as(f64, @floatFromInt(p.y)) * c;
        v_min = @min(v_min, v);
        v_max = @max(v_max, v);
    }
    if (!(v_min <= v_max)) return .{};
    const k0: i64 = @intFromFloat(@ceil(v_min / pitch));
    const k1: i64 = @intFromFloat(@floor(v_max / pitch));
    if (k1 < k0) return .{};
    const n: usize = @intCast(k1 - k0 + 1);
    const X = struct { u: f64, w: i8 };
    const start = try a.alloc(u32, n + 1);
    @memset(start, 0);
    var list: []X = &.{};
    for (0..2) |pass| {
        for (0..shape.count()) |pi| {
            const poly = shape.get(pi);
            var pu: f64 = undefined;
            var pv: f64 = undefined;
            {
                const p = poly[poly.len - 1];
                pu = @as(f64, @floatFromInt(p.x)) * c + @as(f64, @floatFromInt(p.y)) * s;
                pv = -@as(f64, @floatFromInt(p.x)) * s + @as(f64, @floatFromInt(p.y)) * c;
            }
            for (poly) |q| {
                const qu = @as(f64, @floatFromInt(q.x)) * c + @as(f64, @floatFromInt(q.y)) * s;
                const qv = -@as(f64, @floatFromInt(q.x)) * s + @as(f64, @floatFromInt(q.y)) * c;
                defer {
                    pu = qu;
                    pv = qv;
                }
                if (pv == qv) continue;
                // The lines with lo <= v < hi.
                const lo = @min(pv, qv);
                const hi = @max(pv, qv);
                var k: i64 = @intFromFloat(@ceil(lo / pitch));
                while (@as(f64, @floatFromInt(k)) * pitch < hi) : (k += 1) {
                    const i: usize = @intCast(k - k0);
                    if (i >= n) break;
                    if (pass == 0) {
                        start[i + 1] += 1;
                        continue;
                    }
                    const t = (@as(f64, @floatFromInt(k)) * pitch - pv) / (qv - pv);
                    list[start[i]] = .{ .u = pu + t * (qu - pu), .w = if (qv > pv) 1 else -1 };
                    start[i] += 1;
                }
            }
        }
        if (pass == 0) {
            for (1..n + 1) |i| start[i] += start[i - 1];
            list = try a.alloc(X, start[n]);
        }
    }
    // After the fill, start[i] is the end of line i. Sort each line, and
    // keep the crossings where the winding number leaves or reaches 0.
    const u = try a.alloc(f64, list.len);
    const out_start = try a.alloc(u32, n + 1);
    var at: u32 = 0;
    for (0..n) |i| {
        out_start[i] = at;
        const row = list[(if (i == 0) 0 else start[i - 1])..start[i]];
        std.mem.sortUnstable(X, row, {}, struct {
            fn lt(_: void, x: X, y: X) bool {
                return x.u < y.u;
            }
        }.lt);
        var wsum: i32 = 0;
        for (row) |x| {
            const was = wsum != 0;
            wsum += x.w;
            if (was != (wsum != 0)) {
                u[at] = x.u;
                at += 1;
            }
        }
        // A line through a vertex can give an odd count: drop the last.
        if ((at - out_start[i]) % 2 == 1) at -= 1;
    }
    out_start[n] = at;
    return .{ .k0 = k0, .start = out_start, .u = u[0..at] };
}

pub const Op = enum { intersection, difference };

/// `x <op> y` for each line: a merge of the two sorted lists of each
/// line. The result has the lines of `x`.
pub fn boolean(a: Allocator, x: Lines, y: Lines, op: Op) Allocator.Error!Lines {
    const n = x.count();
    if (n == 0) return .{};
    const start = try a.alloc(u32, n + 1);
    // Each end of the result is an end of x or of y.
    const u = try a.alloc(f64, x.u.len + y.u.len);
    var at: u32 = 0;
    for (0..n) |i| {
        start[i] = at;
        const xs = x.u[x.start[i]..x.start[i + 1]];
        const ys = y.line(x.k0 + @as(i64, @intCast(i)));
        var xi: usize = 0;
        var yi: usize = 0;
        var in_x = false;
        var in_y = false;
        while (xi < xs.len) {
            // The next end, of x or of y. An odd index is the end of an
            // interval.
            const take_x = yi >= ys.len or xs[xi] <= ys[yi];
            const pos = if (take_x) xs[xi] else ys[yi];
            const was = in_x and (in_y == (op == .intersection));
            if (take_x) {
                in_x = xi % 2 == 0;
                xi += 1;
            } else {
                in_y = yi % 2 == 0;
                yi += 1;
            }
            const now = in_x and (in_y == (op == .intersection));
            if (was == now) continue;
            // An interval of no length (two ends at one place) goes away.
            if (!now and at > start[i] and u[at - 1] == pos) {
                at -= 1;
            } else {
                u[at] = pos;
                at += 1;
            }
        }
    }
    start[n] = at;
    return .{ .k0 = x.k0, .start = start, .u = u[0..at] };
}

const testing = std.testing;

test "dexel: the cut of a square with a hole, and the booleans of two cuts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sq: Paths = .empty;
    try sq.append(a, &.{ .init(0, 0), .init(1000, 0), .init(1000, 1000), .init(0, 1000) });
    try sq.append(a, &.{ .init(400, 400), .init(400, 600), .init(600, 600), .init(600, 400) });
    const l = try cut(a, sq, 0, 100);
    // Lines 0 to 9 (line 10 is on the top edge: the cut has lo <= v < hi).
    try testing.expectEqual(@as(usize, 11), l.count());
    try testing.expectEqualSlices(f64, &.{ 0, 1000 }, l.line(2));
    try testing.expectEqualSlices(f64, &.{ 0, 400, 600, 1000 }, l.line(5));
    // 10 lines of 1000, less 2 lines of 200 in the hole (lines 4 and 5).
    try testing.expectApproxEqAbs(@as(f64, 10 * 1000 - 2 * 200), l.length(), 1e-6);

    var other: Paths = .empty;
    try other.append(a, &.{ .init(500, -100), .init(2000, -100), .init(2000, 550), .init(500, 550) });
    const m = try cut(a, other, 0, 100);
    const both = try boolean(a, l, m, .intersection);
    try testing.expectEqualSlices(f64, &.{ 500, 1000 }, both.line(2));
    try testing.expectEqualSlices(f64, &.{ 600, 1000 }, both.line(5));
    try testing.expectEqualSlices(f64, &.{}, both.line(6));
    const rest = try boolean(a, l, m, .difference);
    try testing.expectEqualSlices(f64, &.{ 0, 500 }, rest.line(2));
    try testing.expectEqualSlices(f64, &.{ 0, 400 }, rest.line(5));
    try testing.expectEqualSlices(f64, &.{ 0, 1000 }, rest.line(6));
    try testing.expectApproxEqAbs(l.length(), both.length() + rest.length(), 1e-6);

    // The same square at 45 degrees: the area from the lines is the area
    // of the shape to within one line.
    const d = try cut(a, sq, std.math.pi / 4.0, 50);
    try testing.expectApproxEqAbs(@as(f64, 1000 * 1000 - 200 * 200), d.length() * 50, 1000 * 50);
}
