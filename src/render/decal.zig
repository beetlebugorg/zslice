//! The fill of a 2D outline as triangles, for the decals of the labels in
//! the 3D view (View.addLabel). A label outline (zs_label_outline) is a
//! set of closed paths: the outer paths counterclockwise, the holes
//! clockwise. The fill follows the nonzero rule, so a hole stays open.
//!
//! The method is a sweep in y. The y of each vertex cuts the plane into
//! slabs. In a slab, each edge that crosses it is one straight piece, and
//! the edges do not cross each other inside it (the outline of a union has
//! no crossings). So the fill of a slab is a row of trapezoids: walk the
//! edges from left to right, add the direction of each edge to the winding
//! number, and fill between an edge where the number leaves 0 and the edge
//! where it comes back to 0. A trapezoid that continues into the next slab
//! between the same two edges grows into it. So the count of trapezoids
//! stays near the count of edges, and not the count of edges times the
//! count of slabs. Each trapezoid is two triangles. The corners lie on the
//! edges, so the fill is exact.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

const Edge = struct {
    /// The low end (y0 < y1) and the high end.
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    /// +1 for an edge that goes up, -1 for one that goes down.
    dir: i32,

    fn xAt(e: Edge, y: f64) f64 {
        return e.x0 + (e.x1 - e.x0) * (y - e.y0) / (e.y1 - e.y0);
    }
};

/// A trapezoid between edges l and r, open from y.
const Open = struct { l: u32, r: u32, y: f64 };

/// Appends the triangles of the fill of the paths (`ends`: the end of each
/// path in `pts`, in points) to `out`, three points each.
pub fn fill(gpa: Allocator, pts: []const [2]f32, ends: []const u32, out: *std.ArrayList([2]f32)) Allocator.Error!void {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(gpa);
    var start: usize = 0;
    for (ends) |end_u| {
        const end = @min(@as(usize, end_u), pts.len);
        if (end < start + 3) {
            start = @max(start, end);
            continue;
        }
        for (start..end) |i| {
            const a = pts[i];
            const b = pts[if (i + 1 == end) start else i + 1];
            const ax: f64 = a[0];
            const ay: f64 = a[1];
            const bx: f64 = b[0];
            const by: f64 = b[1];
            if (!(std.math.isFinite(ax) and std.math.isFinite(ay))) continue;
            try ys.append(gpa, ay);
            if (ay == by or !(std.math.isFinite(bx) and std.math.isFinite(by))) continue;
            try edges.append(gpa, if (ay < by)
                .{ .x0 = ax, .y0 = ay, .x1 = bx, .y1 = by, .dir = 1 }
            else
                .{ .x0 = bx, .y0 = by, .x1 = ax, .y1 = ay, .dir = -1 });
        }
        start = end;
    }
    if (edges.items.len < 2) return;
    std.mem.sort(f64, ys.items, {}, std.sort.asc(f64));
    // The edges by their low end.
    const order = try gpa.alloc(u32, edges.items.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const byLow = struct {
        fn lt(e: []const Edge, a: u32, b: u32) bool {
            return e[a].y0 < e[b].y0;
        }
    }.lt;
    std.mem.sort(u32, order, @as([]const Edge, edges.items), byLow);

    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(gpa);
    var open: std.ArrayList(Open) = .empty;
    defer open.deinit(gpa);
    var next_open: std.ArrayList(Open) = .empty;
    defer next_open.deinit(gpa);
    var next: usize = 0;
    var k: usize = 0;
    while (k + 1 < ys.items.len) : (k += 1) {
        const ya = ys.items[k];
        const yb = ys.items[k + 1];
        if (!(yb > ya)) continue;
        // The edges that cross the slab.
        var w: usize = 0;
        for (active.items) |e| {
            if (edges.items[e].y1 > ya) {
                active.items[w] = e;
                w += 1;
            }
        }
        active.shrinkRetainingCapacity(w);
        while (next < order.len and edges.items[order[next]].y0 <= ya) : (next += 1) {
            if (edges.items[order[next]].y1 > ya) try active.append(gpa, order[next]);
        }
        // From left to right at the middle of the slab. The order changes
        // little from one slab to the next: an insertion sort.
        const ym = (ya + yb) / 2;
        const xs = active.items;
        var i: usize = 1;
        while (i < xs.len) : (i += 1) {
            const e = xs[i];
            const x = edges.items[e].xAt(ym);
            var j = i;
            while (j > 0 and edges.items[xs[j - 1]].xAt(ym) > x) : (j -= 1) xs[j] = xs[j - 1];
            xs[j] = e;
        }
        // The spans where the winding number is not 0.
        next_open.clearRetainingCapacity();
        var wind: i32 = 0;
        var left: u32 = 0;
        for (xs) |e| {
            const before = wind;
            wind += edges.items[e].dir;
            if (before == 0 and wind != 0) left = e;
            if (before != 0 and wind == 0) {
                var y0 = ya;
                for (open.items) |*o| {
                    if (o.l == left and o.r == e and !std.math.isNan(o.y)) {
                        y0 = o.y;
                        o.y = std.math.nan(f64);
                        break;
                    }
                }
                try next_open.append(gpa, .{ .l = left, .r = e, .y = y0 });
            }
        }
        // The trapezoids that do not continue end at ya.
        for (open.items) |o| if (!std.math.isNan(o.y)) try trapezoid(gpa, edges.items, o, ya, out);
        std.mem.swap(std.ArrayList(Open), &open, &next_open);
    }
    if (ys.items.len > 0) for (open.items) |o| try trapezoid(gpa, edges.items, o, ys.items[ys.items.len - 1], out);
}

fn trapezoid(gpa: Allocator, edges: []const Edge, o: Open, y1: f64, out: *std.ArrayList([2]f32)) Allocator.Error!void {
    if (!(y1 > o.y)) return;
    const l = edges[o.l];
    const r = edges[o.r];
    const a = [2]f32{ @floatCast(l.xAt(o.y)), @floatCast(o.y) };
    const b = [2]f32{ @floatCast(r.xAt(o.y)), @floatCast(o.y) };
    const c = [2]f32{ @floatCast(r.xAt(y1)), @floatCast(y1) };
    const d = [2]f32{ @floatCast(l.xAt(y1)), @floatCast(y1) };
    try out.appendSlice(gpa, &.{ a, b, c, a, c, d });
}

fn area(tris: []const [2]f32) f64 {
    var s: f64 = 0;
    var i: usize = 0;
    while (i + 2 < tris.len) : (i += 3) {
        const a = tris[i];
        const b = tris[i + 1];
        const c = tris[i + 2];
        s += @abs((@as(f64, b[0]) - a[0]) * (@as(f64, c[1]) - a[1]) - (@as(f64, c[0]) - a[0]) * (@as(f64, b[1]) - a[1])) / 2;
    }
    return s;
}

test "the fill of a square with a hole has the area of the ring" {
    const gpa = std.testing.allocator;
    // A square 10 x 10 (counterclockwise) with a hole 4 x 4 (clockwise).
    const pts = [_][2]f32{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 },
        .{ 3, 3 }, .{ 3, 7 },  .{ 7, 7 },   .{ 7, 3 },
    };
    const ends = [_]u32{ 4, 8 };
    var out: std.ArrayList([2]f32) = .empty;
    defer out.deinit(gpa);
    try fill(gpa, &pts, &ends, &out);
    try std.testing.expectApproxEqAbs(@as(f64, 100 - 16), area(out.items), 1e-4);
    // No triangle lies in the hole.
    var i: usize = 0;
    while (i < out.items.len) : (i += 3) {
        const cx = (out.items[i][0] + out.items[i + 1][0] + out.items[i + 2][0]) / 3;
        const cy = (out.items[i][1] + out.items[i + 1][1] + out.items[i + 2][1]) / 3;
        try std.testing.expect(!(cx > 3 and cx < 7 and cy > 3 and cy < 7));
    }
    // The slabs at y 3 and 7 split the sides, but the trapezoids of the
    // sides join: few triangles.
    try std.testing.expect(out.items.len <= 6 * 6);
}

test "the fill of a circle has the area of its polygon" {
    const gpa = std.testing.allocator;
    var pts: [360][2]f32 = undefined;
    for (&pts, 0..) |*p, i| {
        const a = @as(f64, @floatFromInt(i)) * std.math.pi / 180;
        p.* = .{ @floatCast(5 * @cos(a)), @floatCast(5 * @sin(a)) };
    }
    var shoelace: f64 = 0;
    for (0..pts.len) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % pts.len];
        shoelace += (@as(f64, a[0]) * b[1] - @as(f64, b[0]) * a[1]) / 2;
    }
    const ends = [_]u32{pts.len};
    var out: std.ArrayList([2]f32) = .empty;
    defer out.deinit(gpa);
    try fill(gpa, &pts, &ends, &out);
    try std.testing.expectApproxEqAbs(shoelace, area(out.items), 1e-3);
    // About one trapezoid for each pair of edges: not one for each slab
    // and each edge.
    try std.testing.expect(out.items.len / 6 < 2 * pts.len);
}

test "a bad outline gives no triangles" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([2]f32) = .empty;
    defer out.deinit(gpa);
    const pts = [_][2]f32{ .{ 0, 0 }, .{ 1, 1 }, .{ std.math.nan(f32), 0 } };
    try fill(gpa, &pts, &.{ 2, 3, 99 }, &out);
    try fill(gpa, &.{}, &.{}, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
