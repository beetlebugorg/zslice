//! Line infill: fill a region with parallel lines.
//!
//! The method is a scanline fill:
//!
//! 1. Turn the region by -angle, so that the lines become horizontal.
//! 2. Put the lines at y = k * spacing for each integer k. All layers use the
//!    same grid, so the lines of one layer are on top of the lines of the
//!    layer below. This makes infill columns that are strong.
//! 3. For each polygon edge, find the lines that it crosses. Record each
//!    crossing: the line k, the x, and the edge direction (up or down).
//! 4. Sort the crossings by line, then by x. Go along each line from left to
//!    right and add the directions (a winding number). Where the winding
//!    number is not zero, the line is inside the region. Each inside span is
//!    one infill line.
//! 5. Turn the lines back by +angle.
//!
//! An edge counts for a line at y if min_y <= y < max_y (half open). A
//! line that goes through a vertex then crosses exactly one of the two
//! edges at the vertex.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const Point = geom.Point;
const Paths = geom.Paths;

const Crossing = struct { k: i64, x: i64, dir: i8 };

/// Returns the infill lines, each as a path of two points. `spacing` is the
/// distance between lines, in units. Lines shorter than `min_length` are
/// removed. The caller owns the result.
pub fn lines(gpa: Allocator, region: Paths, spacing: i64, angle_deg: f64, min_length: i64) Allocator.Error!Paths {
    return linesPhase(gpa, region, spacing, angle_deg, 0, min_length);
}

/// `lines`, with the grid moved by `phase` units: the lines are at
/// y = k * spacing + phase in the turned frame.
pub fn linesPhase(gpa: Allocator, region: Paths, spacing: i64, angle_deg: f64, phase: i64, min_length: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    if (region.isEmpty() or spacing <= 0) return out;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = angle_deg * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);

    // Steps 1 and 3.
    var xs: std.ArrayList(Crossing) = .empty;
    for (0..region.count()) |pi| {
        const poly = region.get(pi);
        if (poly.len < 3) continue;
        var prev = rotate(poly[poly.len - 1], c, -s);
        for (poly) |p_raw| {
            const p = rotate(p_raw, c, -s);
            defer prev = p;
            if (p.y == prev.y) continue;
            const lo = if (prev.y < p.y) prev else p;
            const hi = if (prev.y < p.y) p else prev;
            const dir: i8 = if (prev.y < p.y) 1 else -1;
            // Lines with lo.y <= k * spacing + phase < hi.y.
            const ph = @mod(phase, spacing);
            var k = std.math.divCeil(i64, lo.y - ph, spacing) catch unreachable;
            while (k * spacing + ph < hi.y) : (k += 1) {
                const y = k * spacing + ph;
                const t = @as(f64, @floatFromInt(y - lo.y)) / @as(f64, @floatFromInt(hi.y - lo.y));
                const x = @as(f64, @floatFromInt(lo.x)) + t * @as(f64, @floatFromInt(hi.x - lo.x));
                try xs.append(arena, .{ .k = k, .x = @intFromFloat(@round(x)), .dir = dir });
            }
        }
    }

    // Step 4.
    std.mem.sortUnstable(Crossing, xs.items, {}, struct {
        fn lt(_: void, l: Crossing, r: Crossing) bool {
            if (l.k != r.k) return l.k < r.k;
            return l.x < r.x;
        }
    }.lt);
    var i: usize = 0;
    while (i < xs.items.len) {
        const k = xs.items[i].k;
        var wind: i32 = 0;
        var start_x: i64 = 0;
        while (i < xs.items.len and xs.items[i].k == k) : (i += 1) {
            const was_inside = wind != 0;
            wind += xs.items[i].dir;
            const is_inside = wind != 0;
            if (!was_inside and is_inside) start_x = xs.items[i].x;
            if (was_inside and !is_inside) {
                const end_x = xs.items[i].x;
                if (end_x - start_x >= min_length) {
                    // Step 5.
                    const y = k * spacing + @mod(phase, spacing);
                    try out.append(gpa, &.{
                        rotate(.{ .x = start_x, .y = y }, c, s),
                        rotate(.{ .x = end_x, .y = y }, c, s),
                    });
                }
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Gyroid

/// The gyroid line length for each unit of area is this constant divided by
/// the period. The test "gyroid density" measures it. The period for a
/// density d and a line width w is then gyroid_k * w / d, so that the lines
/// fill the fraction d of the area.
pub const gyroid_k: f64 = 2.43;

/// Gyroid infill: the lines where the gyroid surface
/// sin(x) cos(y) + sin(y) cos(z) + sin(z) cos(x) = 0 cuts the layer at height
/// z (mm), with x, y, z scaled by 2 pi / period. The lines of each layer
/// move with z, so the infill is one connected surface in 3D. It is strong
/// in all directions.
///
/// For a fixed x, the equation is a cos(y) + b sin(y) = c with a = sin(x),
/// b = cos(z), and c = -sin(z) cos(x). That is R cos(y - phi) = c, with
/// R = hypot(a, b) and phi = atan2(b, a), so y = phi +- acos(c / R) + 2 pi k.
/// The code samples x, makes one polyline for each branch (+ or -) and
/// each k, and clips the polylines to the region. Where |c| > R there is no
/// y, and the polyline ends.
pub fn gyroid(gpa: Allocator, region: Paths, period_mm: f64, z_mm: f64, min_length: i64) Allocator.Error!Paths {
    if (region.isEmpty() or !(period_mm > 0)) return .empty;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const box = region.bounds();
    const w = 2 * std.math.pi / period_mm;
    const zt = w * z_mm;
    // Solve for y as a function of x if |cos z| >= |sin z|, else for x as a
    // function of y. Then |c| <= |sin z| <= |cos z| <= R (or the same with
    // the roles swapped), so a solution exists for each sample, and the
    // curves have no gaps. The equation is symmetric: with x and y swapped,
    // the roles of sin z and cos z swap.
    const by_x = @abs(@cos(zt)) >= @abs(@sin(zt));
    // In the solved frame: u is the sample axis, v is the solved axis.
    const cu = if (by_x) @cos(zt) else @sin(zt); // the coefficient b
    const su = if (by_x) @sin(zt) else @cos(zt); // the factor of c
    const u_lo = geom.toMm(if (by_x) box.min.x else box.min.y) - period_mm;
    const u_hi = geom.toMm(if (by_x) box.max.x else box.max.y) + period_mm;
    const v_lo = geom.toMm(if (by_x) box.min.y else box.min.x);
    const v_hi = geom.toMm(if (by_x) box.max.y else box.max.x);
    // 24 samples for each period are enough for a smooth curve.
    const step = period_mm / 24.0;
    const n: usize = @intFromFloat(@ceil((u_hi - u_lo) / step));
    const k0: i64 = @intFromFloat(@floor(v_lo * w / (2 * std.math.pi)) - 1);
    const k1: i64 = @intFromFloat(@ceil(v_hi * w / (2 * std.math.pi)) + 1);

    var curves: Paths = .empty;
    for ([_]f64{ 1, -1 }) |branch| {
        var k = k0;
        while (k <= k1) : (k += 1) {
            var prev_phi: ?f64 = null;
            for (0..n + 1) |i| {
                const u = u_lo + @as(f64, @floatFromInt(i)) * step;
                // by_x: a = sin(x), b = cos(z), c = -sin(z) cos(x).
                // by y: a = sin(y), b = sin(z), c = -cos(z) cos(y).
                const a = @sin(w * u);
                const c = -su * @cos(w * u);
                const r = std.math.hypot(a, cu);
                if (r < 1e-9 or @abs(c) > r) {
                    try curves.endPath(arena, 2);
                    prev_phi = null;
                    continue;
                }
                var phi = std.math.atan2(cu, a);
                // Keep phi continuous along the curve.
                if (prev_phi) |pp| {
                    while (phi - pp > std.math.pi) phi -= 2 * std.math.pi;
                    while (pp - phi > std.math.pi) phi += 2 * std.math.pi;
                }
                prev_phi = phi;
                const v_rad = phi + branch * std.math.acos(std.math.clamp(c / r, -1, 1)) + 2 * std.math.pi * @as(f64, @floatFromInt(k));
                const p: Point = if (by_x)
                    .{ .x = geom.fromMm(u), .y = geom.fromMm(v_rad / w) }
                else
                    .{ .x = geom.fromMm(v_rad / w), .y = geom.fromMm(u) };
                try curves.appendPoint(arena, p);
            }
            try curves.endPath(arena, 2);
        }
    }
    return @import("clip_open.zig").clipPolylines(gpa, region, curves, min_length);
}

// ---------------------------------------------------------------------------
// Concentric

/// Concentric infill: closed loops that follow the outline of the region,
/// `spacing` units apart. The first loop is half a spacing inside. The
/// result has closed loops (not lines).
pub fn concentric(gpa: Allocator, region: Paths, spacing: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    var d = @divTrunc(spacing, 2);
    while (true) : (d += spacing) {
        var loop = try @import("offset.zig").offset(gpa, region, -d, .{});
        defer loop.deinit(gpa);
        if (loop.isEmpty()) break;
        try out.appendAll(gpa, loop);
    }
    return out;
}

/// Turns p around the origin by the angle with cosine c and sine s.
fn rotate(p: Point, c: f64, s: f64) Point {
    const x: f64 = @floatFromInt(p.x);
    const y: f64 = @floatFromInt(p.y);
    return .{
        .x = @intFromFloat(@round(x * c - y * s)),
        .y = @intFromFloat(@round(x * s + y * c)),
    };
}

const testing = std.testing;

test "horizontal lines in a square" {
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var l = try lines(gpa, sq, 1000, 0, 0);
    defer l.deinit(gpa);
    // y = 0, 1000, ..., 9000. y = 10000 is outside the half-open range.
    try testing.expectEqual(@as(usize, 10), l.count());
    for (0..l.count()) |i| {
        const seg = l.get(i);
        try testing.expectEqual(@as(u64, 10_000), @abs(seg[1].x - seg[0].x));
    }
}

test "lines skip a hole" {
    const gpa = testing.allocator;
    var p: Paths = .empty;
    defer p.deinit(gpa);
    try p.append(gpa, &.{ .init(0, 0), .init(30_000, 0), .init(30_000, 30_000), .init(0, 30_000) });
    try p.append(gpa, &.{ .init(10_000, 10_000), .init(10_000, 20_000), .init(20_000, 20_000), .init(20_000, 10_000) });
    var l = try lines(gpa, p, 5000, 0, 0);
    defer l.deinit(gpa);
    // y = 0, 5000, 25000: one line each. y = 10000, 15000: two lines each.
    // y = 20000 is at the top edge of the hole, which is half open, so the
    // line goes through: one line.
    try testing.expectEqual(@as(usize, 8), l.count());
}

test "diagonal lines cover the square" {
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var l = try lines(gpa, sq, 500, 45, 0);
    defer l.deinit(gpa);
    // The total line length times the spacing is close to the area.
    var total: f64 = 0;
    for (0..l.count()) |i| total += l.get(i)[0].dist(l.get(i)[1]);
    try testing.expectApproxEqRel(@as(f64, 100.0), total * 500 / 1e6, 0.05);
}

test "gyroid density" {
    // The line length for each unit of area, times the period, is gyroid_k.
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(40_000, 0), .init(40_000, 40_000), .init(0, 40_000) });
    const period = 5.0;
    var sum: f64 = 0;
    const zs = [_]f64{ 0.1, 0.9, 1.7, 2.6, 3.3, 4.2 };
    for (zs) |z| {
        var g = try gyroid(gpa, sq, period, z, 0);
        defer g.deinit(gpa);
        try testing.expect(g.count() > 0);
        var len: f64 = 0;
        for (0..g.count()) |i| {
            const pl = g.get(i);
            for (pl[1..], 0..) |p, k| len += pl[k].dist(p);
        }
        sum += len / 1000.0 / 1600.0 * period;
    }
    try testing.expectApproxEqRel(gyroid_k, sum / zs.len, 0.03);
}

test "concentric loops" {
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var c = try concentric(gpa, sq, 1000);
    defer c.deinit(gpa);
    // Loops at 0.5, 1.5, 2.5, 3.5, 4.5 mm in.
    try testing.expectEqual(@as(usize, 5), c.count());
}

test "line phase moves the lines" {
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var l = try linesPhase(gpa, sq, 1000, 0, 250, 0);
    defer l.deinit(gpa);
    try testing.expectEqual(@as(usize, 10), l.count());
    try testing.expectEqual(@as(i64, 250), l.get(0)[0].y);
}
