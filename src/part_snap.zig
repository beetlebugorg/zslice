//! Smart guides for a part that moves on the bed: the snap of its
//! footprint to the other parts and to the center of the bed.
//!
//! The footprint is the box of the part seen from above. On each axis
//! (X, then Y, each on its own), the left edge, the center, and the right
//! edge of the box are the points that snap. The targets are the edges
//! and the centers of the boxes of the other parts, and the center of
//! the bed. The pair with the least distance within the tolerance wins,
//! and the box moves by that distance. Each pair that is then in line
//! (within 1e-6 mm) gives a guide: a line on the bed along the other
//! axis, from the box to the target box. A shell draws the guides while
//! the drag goes on (zs_view_set_guides), as the smart guides of the
//! labels (label_snap.zig).
//!
//! References (see docs/references/papers-and-algorithms.md): the smart
//! guides of drawing tools; the idea, no code.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

/// A box on the bed: x0, y0, x1, y1 (mm).
pub const Box = [4]f64;

/// A guide: a line on the bed from (x0, y0) to (x1, y1), mm.
pub const Guide = [4]f64;

/// The most guides of one snap.
pub const max_guides = 12;

pub const Result = struct {
    /// The move of the box (mm) that the snap adds.
    dx: f64 = 0,
    dy: f64 = 0,
    guides: [max_guides]Guide = undefined,
    n: usize = 0,

    pub fn slice(r: *const Result) []const Guide {
        return r.guides[0..r.n];
    }
};

/// The three points of a box on an axis: the low edge, the center, and
/// the high edge.
fn points(b: Box, axis: usize) [3]f64 {
    const lo = b[axis];
    const hi = b[axis + 2];
    return .{ lo, (lo + hi) / 2, hi };
}

/// The snap of `box` to the boxes of `others` and to the center of a bed
/// of size `bed` (mm), within `tol` mm on each axis.
pub fn snap(box: Box, others: []const Box, bed: [2]f64, tol: f64) Result {
    var r: Result = .{};
    if (!(tol > 0)) return r;
    var shift: [2]f64 = .{ 0, 0 };
    for (0..2) |axis| {
        var best: ?f64 = null;
        const mine = points(box, axis);
        for (mine) |p| {
            const center = bed[axis] / 2;
            if (@abs(center - p) <= tol and (best == null or @abs(center - p) < @abs(best.?))) best = center - p;
            for (others) |o| for (points(o, axis)) |t| {
                const d = t - p;
                if (@abs(d) <= tol and (best == null or @abs(d) < @abs(best.?))) best = d;
            };
        }
        shift[axis] = best orelse 0;
    }
    r.dx = shift[0];
    r.dy = shift[1];
    // The guides of the box after the snap.
    const moved: Box = .{ box[0] + r.dx, box[1] + r.dy, box[2] + r.dx, box[3] + r.dy };
    for (0..2) |axis| {
        if (shift[axis] == 0 and !anyLine(moved, others, bed, axis)) continue;
        const other = 1 - axis;
        const mine = points(moved, axis);
        for (mine) |p| {
            // The center of the bed: a line across the whole bed.
            if (@abs(p - bed[axis] / 2) < 1e-6) add(&r, axis, p, 0, bed[other]);
            for (others) |o| for (points(o, axis)) |t| {
                if (@abs(t - p) >= 1e-6) continue;
                const lo = @min(moved[other], o[other]);
                const hi = @max(moved[other + 2], o[other + 2]);
                add(&r, axis, p, lo, hi);
            };
        }
    }
    return r;
}

/// True if a point of the box is in line with a target on the axis.
fn anyLine(b: Box, others: []const Box, bed: [2]f64, axis: usize) bool {
    for (points(b, axis)) |p| {
        if (@abs(p - bed[axis] / 2) < 1e-6) return true;
        for (others) |o| for (points(o, axis)) |t| if (@abs(t - p) < 1e-6) return true;
    }
    return false;
}

/// A guide at `at` on `axis`, from `lo` to `hi` along the other axis. A
/// guide on the same line grows to cover both.
fn add(r: *Result, axis: usize, at: f64, lo: f64, hi: f64) void {
    const g: Guide = if (axis == 0) .{ at, lo, at, hi } else .{ lo, at, hi, at };
    for (r.guides[0..r.n]) |*h| {
        const same = if (axis == 0) h[0] == h[2] and @abs(h[0] - at) < 1e-6 else h[1] == h[3] and @abs(h[1] - at) < 1e-6;
        if (!same) continue;
        if (axis == 0) {
            h[1] = @min(h[1], lo);
            h[3] = @max(h[3], hi);
        } else {
            h[0] = @min(h[0], lo);
            h[2] = @max(h[2], hi);
        }
        return;
    }
    if (r.n == max_guides) return;
    r.guides[r.n] = g;
    r.n += 1;
}

const testing = std.testing;

test "snap: the edge of a box goes to the edge of another box" {
    // A box 10 wide at x 21.5 to 31.5, near a box that ends at x 20: the
    // left edge does not snap to the right edge (1.5 mm > tol 1), but the
    // box that starts at 20.6 does.
    const other = [_]Box{.{ 0, 0, 20, 10 }};
    const far = snap(.{ 21.5, 40, 31.5, 50 }, &other, .{ 220, 220 }, 1);
    try testing.expectEqual(@as(f64, 0), far.dx);
    const near = snap(.{ 20.6, 40, 30.6, 50 }, &other, .{ 220, 220 }, 1);
    try testing.expectApproxEqAbs(@as(f64, -0.6), near.dx, 1e-9);
    try testing.expectEqual(@as(f64, 0), near.dy);
    // One guide: the line x = 20 from the other box to this one.
    try testing.expectEqual(@as(usize, 1), near.n);
    const g = near.guides[0];
    try testing.expectApproxEqAbs(@as(f64, 20), g[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), g[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), g[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50), g[3], 1e-9);
}

test "snap: the center of the bed, and the nearest target wins" {
    // A box centered at 110.4, 109.7 on a 220 bed: both centers snap.
    const r = snap(.{ 100.4, 99.7, 120.4, 119.7 }, &.{}, .{ 220, 220 }, 1);
    try testing.expectApproxEqAbs(@as(f64, -0.4), r.dx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.3), r.dy, 1e-9);
    // Two guides across the bed: x = 110 and y = 110.
    try testing.expectEqual(@as(usize, 2), r.n);
    try testing.expectEqual(Guide{ 110, 0, 110, 220 }, r.guides[0]);
    try testing.expectEqual(Guide{ 0, 110, 220, 110 }, r.guides[1]);
    // Two targets: the nearer one (the center of the other box at 50.2)
    // wins over its edge.
    const o = [_]Box{.{ 40, 0, 60.4, 10 }};
    const c = snap(.{ 45, 30, 55, 40 }, &o, .{ 220, 220 }, 1);
    try testing.expectApproxEqAbs(@as(f64, 0.2), c.dx, 1e-9);
}

test "snap: no snap out of the tolerance, and none with tol 0" {
    const o = [_]Box{.{ 0, 0, 20, 10 }};
    const r = snap(.{ 30, 30, 40, 40 }, &o, .{ 220, 220 }, 1);
    try testing.expectEqual(@as(f64, 0), r.dx);
    try testing.expectEqual(@as(f64, 0), r.dy);
    try testing.expectEqual(@as(usize, 0), r.n);
    const off = snap(.{ 20.5, 40, 30.5, 50 }, &o, .{ 220, 220 }, 0);
    try testing.expectEqual(@as(f64, 0), off.dx);
}
