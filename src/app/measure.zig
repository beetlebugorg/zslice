//! The measurements of a path at one of its segments, for the inspector:
//! the length of the segment, of the straight edge that it is a part of,
//! and of the whole path; the size of the path; and, when the path is a
//! circle or the segment is a part of an arc, the radius.
//!
//! A circle or an arc is found with a least-squares fit of a circle to the
//! points (the algebraic fit of Kåsa: minimize the sum of
//! (x² + y² + D x + E y + F)², a linear problem). The points fit when each
//! is within 2 % of the radius (at least 0.03 mm) of the circle. An arc
//! grows from the segment along the path while the points fit, and counts
//! when it has 5 points or more and turns 20° or more.
//!
//! An edge grows from the segment along the path while the direction
//! turns less than 2° from the segment.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub const Shape = enum(u8) { line = 0, circle = 1, arc = 2 };

pub const Measure = struct {
    /// The clicked segment, mm.
    segment_length: f64 = 0,
    /// The straight run of segments with the direction of the segment, mm.
    edge_length: f64 = 0,
    /// The whole path, mm.
    path_length: f64 = 0,
    closed: bool = false,
    /// The size of the path along x and y, mm.
    size: [2]f64 = .{ 0, 0 },
    shape: Shape = .line,
    /// For a circle or an arc: the radius and the center, mm; the angle of
    /// the arc, degrees (360 for a circle).
    radius: f64 = 0,
    center: [2]f64 = .{ 0, 0 },
    angle: f64 = 0,
};

const Pt = [2]f64;

fn dist(a: Pt, b: Pt) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

const Circle = struct { c: Pt, r: f64 };

/// The circle that fits the points best (Kåsa), or null for a line.
fn fitCircle(pts: []const Pt) ?Circle {
    if (pts.len < 3) return null;
    // Center the points (for the numbers), then solve the normal equations
    // of a x + b y + c = x² + y² for a, b, c.
    var mx: f64 = 0;
    var my: f64 = 0;
    for (pts) |p| {
        mx += p[0];
        my += p[1];
    }
    mx /= @floatFromInt(pts.len);
    my /= @floatFromInt(pts.len);
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var syy: f64 = 0;
    var sxz: f64 = 0;
    var syz: f64 = 0;
    var sz: f64 = 0;
    for (pts) |p| {
        const x = p[0] - mx;
        const y = p[1] - my;
        const z = x * x + y * y;
        sxx += x * x;
        sxy += x * y;
        syy += y * y;
        sxz += x * z;
        syz += y * z;
        sz += z;
    }
    // With centered points, the sums of x and y are 0: the equations are
    // [sxx sxy] [a] = [sxz], and c = sz / n.
    // [sxy syy] [b]   [syz]
    const det = sxx * syy - sxy * sxy;
    if (@abs(det) < 1e-12) return null;
    const a = (sxz * syy - syz * sxy) / det;
    const b = (sxx * syz - sxy * sxz) / det;
    const c = sz / @as(f64, @floatFromInt(pts.len));
    const cx = a / 2;
    const cy = b / 2;
    const r2 = c + cx * cx + cy * cy;
    if (r2 <= 0) return null;
    return .{ .c = .{ cx + mx, cy + my }, .r = @sqrt(r2) };
}

fn fits(cir: Circle, pts: []const Pt) bool {
    const tol = @max(0.02 * cir.r, 0.03);
    for (pts) |p| if (@abs(dist(p, cir.c) - cir.r) > tol) return false;
    return true;
}

/// The angle that the points turn around the center, degrees.
fn sweep(cir: Circle, pts: []const Pt) f64 {
    var total: f64 = 0;
    for (1..pts.len) |i| {
        const a0 = std.math.atan2(pts[i - 1][1] - cir.c[1], pts[i - 1][0] - cir.c[0]);
        const a1 = std.math.atan2(pts[i][1] - cir.c[1], pts[i][0] - cir.c[0]);
        var d = a1 - a0;
        while (d > std.math.pi) d -= 2 * std.math.pi;
        while (d < -std.math.pi) d += 2 * std.math.pi;
        total += d;
    }
    return @abs(total) * 180 / std.math.pi;
}

/// The measurements of the path with the points `pts` (closed: the last
/// point joins the first) at segment `seg` (from point seg to seg + 1).
/// The memory for the arc search is in `scratch`.
pub fn measure(scratch: std.mem.Allocator, pts: []const Pt, closed: bool, seg: usize) std.mem.Allocator.Error!Measure {
    var m: Measure = .{ .closed = closed };
    const n = pts.len;
    if (n < 2) return m;
    const nseg = if (closed) n else n - 1;
    const s = @min(seg, nseg - 1);
    const at = struct {
        fn f(p: []const Pt, i: usize) Pt {
            return p[i % p.len];
        }
    }.f;
    var lo: Pt = pts[0];
    var hi: Pt = pts[0];
    for (pts) |p| {
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    m.size = .{ hi[0] - lo[0], hi[1] - lo[1] };
    for (0..nseg) |i| m.path_length += dist(at(pts, i), at(pts, i + 1));
    const a = at(pts, s);
    const b = at(pts, s + 1);
    m.segment_length = dist(a, b);

    // The straight edge: the segments before and after with nearly the
    // same direction.
    m.edge_length = m.segment_length;
    if (m.segment_length > 1e-9) {
        const dir: Pt = .{ (b[0] - a[0]) / m.segment_length, (b[1] - a[1]) / m.segment_length };
        const cos_max = @cos(2.0 * std.math.pi / 180.0);
        var k: usize = 1;
        // Forward.
        while (k < nseg) : (k += 1) {
            if (!closed and s + k >= nseg) break;
            const p = at(pts, s + k);
            const q = at(pts, s + k + 1);
            const l = dist(p, q);
            if (l < 1e-9) continue;
            if ((dir[0] * (q[0] - p[0]) + dir[1] * (q[1] - p[1])) / l < cos_max) break;
            m.edge_length += l;
        }
        // Back.
        k = 1;
        while (k < nseg) : (k += 1) {
            if (!closed and k > s) break;
            const i = (s + nseg * 2 - k) % nseg;
            const p = at(pts, i);
            const q = at(pts, i + 1);
            const l = dist(p, q);
            if (l < 1e-9) continue;
            if ((dir[0] * (q[0] - p[0]) + dir[1] * (q[1] - p[1])) / l < cos_max) break;
            m.edge_length += l;
        }
        m.edge_length = @min(m.edge_length, m.path_length);
    }

    // A circle: a closed path whose points all fit one circle.
    if (closed and n >= 8) {
        if (fitCircle(pts)) |cir| if (fits(cir, pts)) {
            m.shape = .circle;
            m.radius = cir.r;
            m.center = cir.c;
            m.angle = 360;
            return m;
        };
    }
    // An arc: grow from the segment while the points fit.
    var run: std.ArrayList(Pt) = .empty;
    defer run.deinit(scratch);
    var first: usize = s; // the index of the first point of the run
    var count: usize = 2; // points in the run
    var best: ?Circle = null;
    var best_count: usize = 0;
    var grew = true;
    while (grew and count < n) {
        grew = false;
        // Try one more point after, then one more before.
        for ([_]bool{ true, false }) |after| {
            if (count >= n) break;
            if (!closed) {
                if (after and first + count >= n) continue;
                if (!after and first == 0) continue;
            }
            const nf = if (after) first else (first + n - 1) % n;
            run.clearRetainingCapacity();
            for (0..count + 1) |k| try run.append(scratch, at(pts, nf + k));
            if (run.items.len >= 4) {
                const cir = fitCircle(run.items) orelse continue;
                if (!fits(cir, run.items)) continue;
                best = cir;
                best_count = run.items.len;
            }
            first = nf;
            count += 1;
            grew = true;
        }
    }
    if (best) |cir| if (best_count >= 5) {
        run.clearRetainingCapacity();
        // The points of the best run: refit for the sweep.
        const ang = blk: {
            var pts_run: std.ArrayList(Pt) = .empty;
            defer pts_run.deinit(scratch);
            for (0..best_count) |k| try pts_run.append(scratch, at(pts, first + k));
            break :blk sweep(cir, pts_run.items);
        };
        if (ang >= 20 and cir.r < 1e4) {
            m.shape = .arc;
            m.radius = cir.r;
            m.center = cir.c;
            m.angle = @min(ang, 360);
        }
    };
    return m;
}

const testing = std.testing;

test "measure: a circle gives its radius, and a square its edges" {
    var circle: [36]Pt = undefined;
    for (&circle, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) * 2 * std.math.pi / 36;
        p.* = .{ 10 + 4 * @cos(t), 20 + 4 * @sin(t) };
    }
    const m = try measure(testing.allocator, &circle, true, 3);
    try testing.expectEqual(Shape.circle, m.shape);
    try testing.expectApproxEqAbs(@as(f64, 4), m.radius, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 8), m.size[0], 1e-6);

    // A square of 10 mm, with each edge in two segments.
    const sq = [_]Pt{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 10, 10 }, .{ 5, 10 }, .{ 0, 10 }, .{ 0, 5 } };
    const e = try measure(testing.allocator, &sq, true, 0);
    try testing.expectEqual(Shape.line, e.shape);
    try testing.expectApproxEqAbs(@as(f64, 5), e.segment_length, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), e.edge_length, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 40), e.path_length, 1e-9);
}

test "measure: an arc in an open path" {
    // A straight lead in, a half circle of radius 6, a straight lead out.
    var pts: [24]Pt = undefined;
    pts[0] = .{ -10, 0 };
    pts[1] = .{ -6, 0 };
    for (0..20) |i| {
        const t = std.math.pi - @as(f64, @floatFromInt(i + 1)) * std.math.pi / 21;
        pts[2 + i] = .{ 6 * @cos(t), 6 * @sin(t) };
    }
    pts[22] = .{ 6, 0 };
    pts[23] = .{ 10, 0 };
    const m = try measure(testing.allocator, &pts, false, 10);
    try testing.expectEqual(Shape.arc, m.shape);
    try testing.expectApproxEqAbs(@as(f64, 6), m.radius, 0.05);
    try testing.expect(m.angle > 150);
}
