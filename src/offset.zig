//! Polygon offset: move each boundary of a shape in or out by a distance.
//!
//! The slicer uses an offset for each wall. The first wall is the layer
//! outline moved in by half a line width. Each next wall is one line width
//! further in. The area that is left in the middle is for infill.
//!
//! The method comes from Clipper2 (see REFERENCES.md):
//!
//! 1. Move each edge along its normal by the distance. The normal of an edge
//!    points to its right. With counterclockwise outer boundaries and
//!    clockwise holes, the right of each edge is outside the material. A
//!    positive distance makes the shape larger, and holes smaller.
//! 2. At each vertex, join the moved edges of the two sides:
//!    - If the corner opens away from the offset, the moved edges leave a
//!      gap. The join fills the gap with a miter (a sharp point), a round
//!      arc, or a bevel (a straight cut).
//!    - If the corner closes toward the offset, the moved edges cross. The
//!      code adds the two moved end points with the original vertex between
//!      them. This makes a small loop that turns the wrong way. The
//!      original vertex is necessary: without it, a shape that shrinks
//!      past its center turns inside out but keeps its direction, and the
//!      union in step 3 keeps it. One exception: at an almost straight
//!      corner between two edges longer than the offset distance, the
//!      crossing point alone is exact and safe (see `addJoin`).
//!
//! Before step 1, the code removes points that are within
//! `clean_tolerance` of a straight line (see `geom.simplifyClosed`). A curve
//! made of many very short edges gives many closing corners, and each one
//! makes a thin loop. Fewer points give fewer thin loops, and the union is
//! faster and more robust.
//! 3. A union with the "positive" fill rule removes all parts that turn the
//!    wrong way. These parts include the small loops from step 2 and all of
//!    a shape that the offset made smaller than zero.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const Point = geom.Point;
const Paths = geom.Paths;

pub const Join = enum { miter, round, bevel };

pub const Options = struct {
    join: Join = .miter,
    /// The maximum miter length, as a multiple of the offset distance. A
    /// sharper corner gets a bevel.
    miter_limit: f64 = 2.0,
    /// For round joins: the maximum distance between the arc and the
    /// straight segments that make it, in units.
    arc_tolerance: f64 = 5.0,
    /// Points of the input within this distance (units) of a straight line
    /// are removed before the offset.
    clean_tolerance: i64 = 5,
};

/// Moves the boundaries of `paths` by `delta` units. A positive delta makes
/// the shapes larger. The caller owns the result.
pub fn offset(gpa: Allocator, paths: Paths, delta: i64, opts: Options) Allocator.Error!Paths {
    if (paths.isEmpty()) return .empty;
    if (delta == 0) return paths.clone(gpa);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var raw: Paths = .empty;
    var normals: std.ArrayList([2]f64) = .empty;
    var lengths: std.ArrayList(f64) = .empty;
    const d: f64 = @floatFromInt(delta);

    var clean: std.ArrayList(Point) = .empty;
    for (0..paths.count()) |pi| {
        clean.clearRetainingCapacity();
        try clean.appendSlice(arena, paths.get(pi));
        const poly = clean.items[0..geom.simplifyClosed(clean.items, opts.clean_tolerance)];
        if (poly.len < 3) continue;

        // The unit normal of each edge i, from poly[i] to poly[i + 1].
        normals.clearRetainingCapacity();
        lengths.clearRetainingCapacity();
        for (poly, 0..) |p, i| {
            const q = poly[(i + 1) % poly.len];
            const dx: f64 = @floatFromInt(q.x - p.x);
            const dy: f64 = @floatFromInt(q.y - p.y);
            const len = @sqrt(dx * dx + dy * dy);
            try lengths.append(arena, len);
            if (len == 0) {
                try normals.append(arena, .{ 0, 0 });
            } else {
                try normals.append(arena, .{ dy / len, -dx / len });
            }
        }

        for (poly, 0..) |p, i| {
            const prev = (i + poly.len - 1) % poly.len;
            const n1 = normals.items[prev];
            const n2 = normals.items[i];
            const short = @min(lengths.items[prev], lengths.items[i]);
            try addJoin(arena, &raw, p, n1, n2, d, short, opts);
        }
        try raw.endPath(arena, 3);
    }

    return clip.unionAll(gpa, raw, .positive);
}

fn movePoint(p: Point, n: [2]f64, d: f64) Point {
    const px: f64 = @floatFromInt(p.x);
    const py: f64 = @floatFromInt(p.y);
    return .{
        .x = @intFromFloat(@round(px + n[0] * d)),
        .y = @intFromFloat(@round(py + n[1] * d)),
    };
}

/// `short` is the length of the shorter edge at the vertex.
fn addJoin(arena: Allocator, out: *Paths, p: Point, n1: [2]f64, n2: [2]f64, d: f64, short: f64, opts: Options) !void {
    const sin_a = n1[0] * n2[1] - n1[1] * n2[0];
    const cos_a = n1[0] * n2[0] + n1[1] * n2[1];

    // Almost straight: one point is enough.
    if (@abs(sin_a) < 1e-12 and cos_a > 0) {
        try out.appendPoint(arena, movePoint(p, n1, d));
        return;
    }

    // The corner closes toward the offset, it is almost straight (less than
    // 8 degrees), and both edges are longer than the offset distance. Then
    // one point at the crossing of the moved edges (the miter point) is
    // exact, and the loop through the vertex is not necessary: a shape
    // whose turns are all this small, with edges this long, has a radius of
    // more than 7 times the offset distance, so it cannot shrink past its
    // center. This removes most thin loops on curves, which make the union
    // slow.
    if (sin_a * d < 0 and cos_a > 0.99 and short > @abs(d)) {
        const k = d / (1 + cos_a);
        const px: f64 = @floatFromInt(p.x);
        const py: f64 = @floatFromInt(p.y);
        try out.appendPoint(arena, .{
            .x = @intFromFloat(@round(px + (n1[0] + n2[0]) * k)),
            .y = @intFromFloat(@round(py + (n1[1] + n2[1]) * k)),
        });
        return;
    }

    // The corner closes toward the offset. See step 2 in the file comment.
    if (sin_a * d < 0) {
        try out.appendPoint(arena, movePoint(p, n1, d));
        try out.appendPoint(arena, p);
        try out.appendPoint(arena, movePoint(p, n2, d));
        return;
    }

    switch (opts.join) {
        .miter => {
            // The miter point is on the bisector of the two normals, at the
            // distance d / cos(half angle). 1 + cos_a = 2 cos^2(half angle).
            if (1 + cos_a >= 2.0 / (opts.miter_limit * opts.miter_limit)) {
                const k = d / (1 + cos_a);
                const px: f64 = @floatFromInt(p.x);
                const py: f64 = @floatFromInt(p.y);
                try out.appendPoint(arena, .{
                    .x = @intFromFloat(@round(px + (n1[0] + n2[0]) * k)),
                    .y = @intFromFloat(@round(py + (n1[1] + n2[1]) * k)),
                });
            } else {
                try out.appendPoint(arena, movePoint(p, n1, d));
                try out.appendPoint(arena, movePoint(p, n2, d));
            }
        },
        .bevel => {
            try out.appendPoint(arena, movePoint(p, n1, d));
            try out.appendPoint(arena, movePoint(p, n2, d));
        },
        .round => {
            const angle = std.math.atan2(sin_a, cos_a);
            const r = @abs(d);
            // The largest angle step that keeps the chord within the tolerance.
            const step = if (opts.arc_tolerance >= r) std.math.pi / 2.0 else 2 * std.math.acos(1 - opts.arc_tolerance / r);
            const steps: usize = @intFromFloat(@max(1, @ceil(@abs(angle) / step)));
            const da = angle / @as(f64, @floatFromInt(steps));
            for (0..steps + 1) |s| {
                const a = da * @as(f64, @floatFromInt(s));
                const c = @cos(a);
                const sn = @sin(a);
                const n = [2]f64{ n1[0] * c - n1[1] * sn, n1[0] * sn + n1[1] * c };
                try out.appendPoint(arena, movePoint(p, n, d));
            }
        },
    }
}

/// Removes the parts of a shape that are thinner than 2 * r: shrink by r,
/// then grow by r. The name in image processing is "opening".
pub fn opening(gpa: Allocator, paths: Paths, r: i64, opts: Options) Allocator.Error!Paths {
    var small = try offset(gpa, paths, -r, opts);
    defer small.deinit(gpa);
    return offset(gpa, small, r, opts);
}

const testing = std.testing;

fn square(gpa: Allocator, size: i64) !Paths {
    var p: Paths = .empty;
    try p.append(gpa, &.{ .init(0, 0), .init(size, 0), .init(size, size), .init(0, size) });
    return p;
}

test "grow a square with miter joins" {
    const gpa = testing.allocator;
    var sq = try square(gpa, 10_000);
    defer sq.deinit(gpa);
    var r = try offset(gpa, sq, 1000, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectApproxEqAbs(@as(f64, 144.0), r.areaMm2(), 1e-6);
}

test "shrink a square" {
    const gpa = testing.allocator;
    var sq = try square(gpa, 10_000);
    defer sq.deinit(gpa);
    var r = try offset(gpa, sq, -1000, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectApproxEqAbs(@as(f64, 64.0), r.areaMm2(), 1e-6);
}

test "shrink a square to nothing" {
    const gpa = testing.allocator;
    var sq = try square(gpa, 10_000);
    defer sq.deinit(gpa);
    var r = try offset(gpa, sq, -6000, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.count());
}

test "grow with round joins approaches the exact area" {
    const gpa = testing.allocator;
    var sq = try square(gpa, 10_000);
    defer sq.deinit(gpa);
    var r = try offset(gpa, sq, 1000, .{ .join = .round, .arc_tolerance = 1 });
    defer r.deinit(gpa);
    // 100 + 4 * 10 * 1 + pi * 1^2
    try testing.expectApproxEqAbs(@as(f64, 140.0 + std.math.pi), r.areaMm2(), 0.01);
}

test "shrink an L shape: the inner corner gets a miter" {
    const gpa = testing.allocator;
    var l: Paths = .empty;
    defer l.deinit(gpa);
    try l.append(gpa, &.{ .init(0, 0), .init(20_000, 0), .init(20_000, 10_000), .init(10_000, 10_000), .init(10_000, 20_000), .init(0, 20_000) });
    var r = try offset(gpa, l, -1000, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectEqual(@as(usize, 6), r.get(0).len);
    // The L of arm width 8 mm: 18 * 8 + 8 * 10 = 224.
    try testing.expectApproxEqAbs(@as(f64, 224.0), r.areaMm2(), 1e-6);
}

test "shrink a square with a hole: the hole grows" {
    const gpa = testing.allocator;
    var p: Paths = .empty;
    defer p.deinit(gpa);
    try p.append(gpa, &.{ .init(0, 0), .init(30_000, 0), .init(30_000, 30_000), .init(0, 30_000) });
    // The hole is clockwise.
    try p.append(gpa, &.{ .init(10_000, 10_000), .init(10_000, 20_000), .init(20_000, 20_000), .init(20_000, 10_000) });
    var r = try offset(gpa, p, -1000, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), r.count());
    // 28^2 - 12^2
    try testing.expectApproxEqAbs(@as(f64, 640.0), r.areaMm2(), 1e-6);
}

test "offset a thin ring two times" {
    // A regression test: the second offset lost the outer loop, because
    // rounded crossing points of the thin spikes made new crossings.
    const gpa = testing.allocator;
    const mesh = @import("mesh.zig");
    const slicer = @import("slicer.zig");
    var b: mesh.Builder = .init(gpa);
    try mesh.shapes.addTube(&b, 0, 0, 5, 2.5, 0, 14, 64);
    var m = try b.finish();
    defer m.deinit(gpa);
    const faces = try gpa.alloc(u32, m.faces.items.len);
    defer gpa.free(faces);
    for (faces, 0..) |*f, i| f.* = @intCast(i);
    var o = try slicer.sliceAt(gpa, &m, faces, 6.1, 5, 1000);
    defer o.deinit(gpa);
    var inner = try offset(gpa, o, -880, .{});
    defer inner.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), inner.count());
    var reg = try offset(gpa, inner, -132, .{});
    defer reg.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), reg.count());
    try testing.expect(reg.areaMm2() > 0);
    // The outer loop by itself also gives one loop. (A clockwise hole loop
    // by itself encloses no material, so its offset is empty.)
    for (0..inner.count()) |i| {
        var one: Paths = .empty;
        defer one.deinit(gpa);
        try one.append(gpa, inner.get(i));
        var r = try offset(gpa, one, -132, .{ .join = .round });
        defer r.deinit(gpa);
        const outer = geom.area2(inner.get(i)) > 0;
        try testing.expectEqual(@as(usize, if (outer) 1 else 0), r.count());
    }
}

fn circle(gpa: Allocator, r: f64, n: usize) !Paths {
    var p: Paths = .empty;
    for (0..n) |i| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        try p.appendPoint(gpa, .{ .x = @intFromFloat(@round(r * @cos(a))), .y = @intFromFloat(@round(r * @sin(a))) });
    }
    try p.endPath(gpa, 3);
    return p;
}

test "a circle that shrinks past its center is empty" {
    // Regression tests from the code review: a shortcut at almost straight
    // closing corners made these shapes turn inside out and stay.
    const gpa = testing.allocator;
    const cases = [_][3]f64{ .{ 300, 64, -400 }, .{ 5000, 64, -6000 }, .{ 5000, 1024, -5001 } };
    for (cases) |c| {
        var p = try circle(gpa, c[0], @intFromFloat(c[1]));
        defer p.deinit(gpa);
        var r = try offset(gpa, p, @intFromFloat(c[2]), .{});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), r.count());
    }
}

test "dense circles give one loop" {
    // Regression tests from the code review: dense input gave many thin
    // loops with almost no area.
    const gpa = testing.allocator;
    const cases = [_]struct { r: f64, n: usize, d: i64, join: Join }{
        .{ .r = 5000, .n = 4096, .d = 400, .join = .miter },
        .{ .r = 5000, .n = 4096, .d = -400, .join = .round },
        .{ .r = 5000, .n = 1024, .d = -4900, .join = .miter },
    };
    for (cases) |c| {
        var p = try circle(gpa, c.r, c.n);
        defer p.deinit(gpa);
        var r = try offset(gpa, p, c.d, .{ .join = c.join });
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), r.count());
        const want = std.math.pi * std.math.pow(f64, (c.r + @as(f64, @floatFromInt(c.d))) / 1000, 2);
        // 1 %, plus the perimeter times 6 um: the input clean-up
        // (clean_tolerance, 5 um) can move each edge in by that much.
        const r_out = (c.r + @as(f64, @floatFromInt(c.d))) / 1000;
        try testing.expectApproxEqAbs(want, r.areaMm2(), 0.01 * want + 2 * std.math.pi * r_out * 0.006);
    }
}
