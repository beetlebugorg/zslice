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
const scratch = @import("scratch.zig");
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

    var arena_state = scratch.get(gpa);
    defer arena_state.release();
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
// Connected lines

/// Joins parallel lines (from `lines`, with the same spacing and angle)
/// into zigzag paths: at the end of a line, the path goes on to the nearest
/// end of a line on the next scan line. The link follows the boundary of
/// the region, the shorter way around, so it runs along the walls and
/// never cuts across the open infill. A link longer than 2.5 spacings is
/// not made. The nozzle then prints many lines with no travel and no
/// retraction between them, and the links along the walls tie the lines
/// to the walls.
pub fn connect(gpa: Allocator, region: Paths, set: Paths, spacing: i64, angle_deg: f64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    const n = set.count();
    if (n == 0 or spacing <= 0) return out;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = angle_deg * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);

    // Each line in the turned frame (one y, and x0 < x1, for the order and
    // the search), with its ends in the frame of the region and their
    // places on the boundary.
    const Line = struct {
        y: i64,
        x0: i64,
        x1: i64,
        p0: Point,
        p1: Point,
        at0: ?Spot,
        at1: ?Spot,
        used: bool = false,
    };
    const bound: Boundary = try .init(arena, region);
    const ls = try arena.alloc(Line, n);
    for (ls, 0..) |*l, i| {
        const p = set.get(i);
        const q0 = rotate(p[0], c, -s);
        const q1 = rotate(p[p.len - 1], c, -s);
        const lo_first = q0.x <= q1.x;
        const p0 = if (lo_first) p[0] else p[p.len - 1];
        const p1 = if (lo_first) p[p.len - 1] else p[0];
        l.* = .{ .y = q0.y, .x0 = @min(q0.x, q1.x), .x1 = @max(q0.x, q1.x), .p0 = p0, .p1 = p1, .at0 = bound.locate(p0), .at1 = bound.locate(p1) };
    }
    std.mem.sort(Line, ls, {}, struct {
        fn lt(_: void, l: Line, r: Line) bool {
            if (l.y != r.y) return l.y < r.y;
            return l.x0 < r.x0;
        }
    }.lt);
    const max_walk: f64 = 2.5 * @as(f64, @floatFromInt(spacing));
    // For the ends that are not on the boundary: the old test of a
    // straight link.
    const index: geom.EdgeIndex = try .init(arena, region, link_tolerance);
    var chain: std.ArrayList(Point) = .empty;
    var walk: std.ArrayList(Point) = .empty;
    var best_walk: std.ArrayList(Point) = .empty;
    for (ls, 0..) |*first, fi| {
        if (first.used) continue;
        chain.clearRetainingCapacity();
        first.used = true;
        try chain.append(arena, first.p0);
        try chain.append(arena, first.p1);
        var end_x = first.x1;
        var end_y = first.y;
        var end_p = first.p1;
        var end_at = first.at1;
        var at = fi;
        while (true) {
            // The lines of the next scan line come after `at` in the order.
            var best: ?usize = null;
            var best_from_low = true;
            var best_len: f64 = max_walk + 1;
            var j = at + 1;
            while (j < ls.len and ls[j].y <= end_y) : (j += 1) {}
            while (j < ls.len and ls[j].y - end_y <= spacing + @divTrunc(spacing, 4)) : (j += 1) {
                if (ls[j].used or ls[j].y == end_y) continue;
                // A quick test first: an end far along the lines is out.
                if (@min(iabs(ls[j].x0 - end_x), iabs(ls[j].x1 - end_x)) > 3 * spacing) continue;
                for ([_]bool{ true, false }) |low| {
                    const to_p = if (low) ls[j].p0 else ls[j].p1;
                    const to_at = if (low) ls[j].at0 else ls[j].at1;
                    walk.clearRetainingCapacity();
                    const len = if (end_at != null and to_at != null)
                        (try bound.walk(arena, end_at.?, to_at.?, max_walk, &walk)) orelse continue
                    else blk: {
                        // Not on the boundary: a straight link inside.
                        const e: Point = .{ .x = end_x, .y = end_y };
                        const t: Point = .{ .x = if (low) ls[j].x0 else ls[j].x1, .y = ls[j].y };
                        if (!linkInside(&index, e, t, c, s)) continue;
                        try walk.append(arena, end_p);
                        try walk.append(arena, to_p);
                        break :blk Point.dist(end_p, to_p);
                    };
                    if (len < best_len) {
                        best = j;
                        best_from_low = low;
                        best_len = len;
                        best_walk.clearRetainingCapacity();
                        try best_walk.appendSlice(arena, walk.items);
                    }
                }
            }
            const b = best orelse break;
            ls[b].used = true;
            // The points of the walk between the two ends.
            if (best_walk.items.len > 2) try chain.appendSlice(arena, best_walk.items[1 .. best_walk.items.len - 1]);
            const l = ls[b];
            try chain.append(arena, if (best_from_low) l.p0 else l.p1);
            try chain.append(arena, if (best_from_low) l.p1 else l.p0);
            end_x = if (best_from_low) l.x1 else l.x0;
            end_y = l.y;
            end_p = if (best_from_low) l.p1 else l.p0;
            end_at = if (best_from_low) l.at1 else l.at0;
            at = b;
        }
        try out.append(gpa, chain.items);
    }
    return out;
}

/// A place on the boundary of a region: polygon `poly`, on the edge from
/// point `edge` to the next point, at `pos`.
const Spot = struct { poly: u32, edge: u32, pos: Point, t: f64 };

/// The edges of a region in bands of y, with their polygon and their
/// index, to find the place of a point on the boundary, and to walk along
/// the boundary from one place to another.
const Boundary = struct {
    region: Paths,
    min: i64,
    width: i64,
    starts: []u32,
    edges: [][2]u32, // polygon, edge

    fn init(arena: Allocator, region: Paths) Allocator.Error!Boundary {
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        for (region.points.items) |q| {
            lo = @min(lo, q.y - link_tolerance);
            hi = @max(hi, q.y + link_tolerance);
        }
        const pts = region.points.items.len;
        const want: usize = std.math.clamp(2 * std.math.sqrt(pts), 1, 4096);
        const span: i64 = @max(hi - lo + 1, 1);
        const width: i64 = @max(1, @divFloor(span + @as(i64, @intCast(want)) - 1, @as(i64, @intCast(want))));
        const bands: usize = @intCast(@divFloor(span + width - 1, width));
        var b: Boundary = .{ .region = region, .min = lo, .width = width, .starts = try arena.alloc(u32, bands + 1), .edges = &.{} };
        @memset(b.starts, 0);
        var fill: []u32 = &.{};
        for (0..2) |pass| {
            if (pass == 1) {
                for (1..b.starts.len) |k| b.starts[k] += b.starts[k - 1];
                b.edges = try arena.alloc([2]u32, b.starts[bands]);
                fill = try arena.dupe(u32, b.starts[0..bands]);
            }
            for (0..region.count()) |k| {
                const poly = region.get(k);
                for (poly, 0..) |p, i| {
                    const q = poly[(i + 1) % poly.len];
                    const b0 = b.band(@min(p.y, q.y) - link_tolerance);
                    const b1 = b.band(@max(p.y, q.y) + link_tolerance);
                    for (b0..b1 + 1) |bi| {
                        if (pass == 0) {
                            b.starts[bi + 1] += 1;
                        } else {
                            b.edges[fill[bi]] = .{ @intCast(k), @intCast(i) };
                            fill[bi] += 1;
                        }
                    }
                }
            }
        }
        return b;
    }

    fn band(b: Boundary, y: i64) usize {
        const k = @divFloor(y - b.min, b.width);
        return @intCast(std.math.clamp(k, 0, @as(i64, @intCast(b.starts.len - 2))));
    }

    /// The place of p on the boundary: the nearest edge within the
    /// tolerance, or null.
    fn locate(b: Boundary, p: Point) ?Spot {
        const k = b.band(p.y);
        var best: ?Spot = null;
        var best_d: f64 = @floatFromInt(link_tolerance * link_tolerance);
        for (b.edges[b.starts[k]..b.starts[k + 1]]) |e| {
            const poly = b.region.get(e[0]);
            const u = poly[e[1]];
            const v = poly[(e[1] + 1) % poly.len];
            const ux: f64 = @floatFromInt(v.x - u.x);
            const uy: f64 = @floatFromInt(v.y - u.y);
            const px: f64 = @floatFromInt(p.x - u.x);
            const py: f64 = @floatFromInt(p.y - u.y);
            const len2 = ux * ux + uy * uy;
            const t = if (len2 > 0) std.math.clamp((px * ux + py * uy) / len2, 0, 1) else 0;
            const dx = px - t * ux;
            const dy = py - t * uy;
            const d = dx * dx + dy * dy;
            if (d <= best_d) {
                best_d = d;
                best = .{ .poly = e[0], .edge = e[1], .pos = p, .t = t };
            }
        }
        return best;
    }

    /// The walk along the boundary from `from` to `to`, the shorter way
    /// around: its points (both ends too) go in `out`, and the result is
    /// its length. Null if the two places are on different polygons, or
    /// the walk is longer than `limit`.
    fn walk(b: Boundary, arena: Allocator, from: Spot, to: Spot, limit: f64, out: *std.ArrayList(Point)) Allocator.Error!?f64 {
        if (from.poly != to.poly) return null;
        const poly = b.region.get(from.poly);
        const m = poly.len;
        // The same edge, with `to` ahead of `from`: a straight link (the
        // way back around the polygon is the long one).
        const same = from.edge == to.edge;
        // Forward: from.pos, the points after from.edge up to to.edge,
        // to.pos.
        var fwd: f64 = 0;
        var fwd_ok = true;
        if (same and to.t >= from.t) {
            fwd = Point.dist(from.pos, to.pos);
        } else {
            var prev = from.pos;
            var i = (from.edge + 1) % m;
            var steps: usize = 0;
            while (true) : (steps += 1) {
                fwd += Point.dist(prev, poly[i]);
                prev = poly[i];
                if (fwd > limit or steps > m) {
                    fwd_ok = false;
                    break;
                }
                if (i == to.edge) break;
                i = (i + 1) % m;
            }
            if (fwd_ok) fwd += Point.dist(prev, to.pos);
        }
        if (fwd > limit) fwd_ok = false;
        // Backward: from.pos, the points from from.edge down to the point
        // after to.edge, to.pos.
        var bwd: f64 = 0;
        var bwd_ok = true;
        if (same and to.t <= from.t) {
            bwd = Point.dist(from.pos, to.pos);
        } else {
            var prev = from.pos;
            var i: usize = from.edge;
            const stop = (to.edge + 1) % m;
            var steps: usize = 0;
            while (true) : (steps += 1) {
                bwd += Point.dist(prev, poly[i]);
                prev = poly[i];
                if (bwd > limit or steps > m) {
                    bwd_ok = false;
                    break;
                }
                if (i == stop) break;
                i = (i + m - 1) % m;
            }
            if (bwd_ok) bwd += Point.dist(prev, to.pos);
        }
        if (bwd > limit) bwd_ok = false;
        if (!fwd_ok and !bwd_ok) return null;
        const forward = fwd_ok and (!bwd_ok or fwd <= bwd);
        try out.append(arena, from.pos);
        if (forward and !(same and to.t >= from.t)) {
            var i = (from.edge + 1) % m;
            while (true) {
                try out.append(arena, poly[i]);
                if (i == to.edge) break;
                i = (i + 1) % m;
            }
        } else if (!forward and !(same and to.t <= from.t)) {
            var i: usize = from.edge;
            const stop = (to.edge + 1) % m;
            while (true) {
                try out.append(arena, poly[i]);
                if (i == stop) break;
                i = (i + m - 1) % m;
            }
        }
        try out.append(arena, to.pos);
        return if (forward) fwd else bwd;
    }
};

fn iabs(x: i64) i64 {
    return if (x < 0) -x else x;
}

/// True if the link from p to q (in the turned frame) stays inside the
/// region: three points along it are inside.
fn linkInside(index: *const geom.EdgeIndex, p: Point, q: Point, c: f64, s: f64) bool {
    for ([_]f64{ 0.25, 0.5, 0.75 }) |t| {
        const m: Point = .{
            .x = p.x + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(q.x - p.x)) * t))),
            .y = p.y + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(q.y - p.y)) * t))),
        };
        const q2 = rotate(m, c, s);
        // A link along a wall lies on the boundary: on it counts as in.
        if (!index.inside(q2) and !index.near(q2, link_tolerance)) return false;
    }
    return true;
}

/// A link point this near the boundary counts as inside.
const link_tolerance = 50;

// ---------------------------------------------------------------------------
// Honeycomb

/// Hexagon cells: zigzag rows, each row the mirror of the row before, so
/// that two rows touch along the flat sides and make hexagons. The same
/// rows on all layers make walls of hexagon tubes. A hexagon grid with a
/// side s has 2 / (sqrt(3) s) of line for each unit of area, so the side
/// for a density d and a line width w is 2 w / (sqrt(3) d).
pub fn honeycomb(gpa: Allocator, region: Paths, width: i64, density: f64, angle_deg: f64, min_length: i64) Allocator.Error!Paths {
    if (region.isEmpty() or !(density > 0)) return .empty;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const side: f64 = 2.0 * @as(f64, @floatFromInt(width)) / (@sqrt(3.0) * density);
    const h = side * @sqrt(3.0) / 2.0;
    const a = angle_deg * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    // The box of the region in the turned frame.
    var lo: Point = .{ .x = std.math.maxInt(i64), .y = std.math.maxInt(i64) };
    var hi: Point = .{ .x = std.math.minInt(i64), .y = std.math.minInt(i64) };
    for (region.points.items) |p| {
        const q = rotate(p, c, -s);
        lo = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) };
        hi = .{ .x = @max(hi.x, q.x), .y = @max(hi.y, q.y) };
    }
    const x0: f64 = @as(f64, @floatFromInt(lo.x)) - 3 * side;
    const x1: f64 = @as(f64, @floatFromInt(hi.x)) + 3 * side;
    const j0: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(lo.y)) / h) - 1);
    const j1: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(hi.y)) / h) + 1);
    // Snap the start to the grid, so that all layers have the same cells.
    const period = 3 * side;
    const xs = @floor(x0 / period) * period;
    var rows: Paths = .empty;
    var row: std.ArrayList(Point) = .empty;
    var j = j0;
    while (j <= j1) : (j += 1) {
        row.clearRetainingCapacity();
        const base = @as(f64, @floatFromInt(j)) * h;
        const odd = @mod(j, 2) != 0;
        var x = xs;
        while (x <= x1) : (x += period) {
            // One period: low flat, rise, high flat, fall.
            const zs = [_][2]f64{ .{ 0, 0 }, .{ side, 0 }, .{ 1.5 * side, h }, .{ 2.5 * side, h } };
            for (zs) |z| {
                const y = if (odd) base + h - z[1] else base + z[1];
                try row.append(arena, rotate(.{ .x = @intFromFloat(@round(x + z[0])), .y = @intFromFloat(@round(y)) }, c, s));
            }
        }
        try rows.append(arena, row.items);
    }
    return @import("clip_open.zig").clipPolylines(gpa, region, rows, min_length);
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
    var arena_state = scratch.get(gpa);
    defer arena_state.release();
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

test "connect: the lines of a square join into one zigzag" {
    const gpa = testing.allocator;
    var region: Paths = .empty;
    defer region.deinit(gpa);
    try region.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var set = try lines(gpa, region, 1000, 0, 0);
    defer set.deinit(gpa);
    try testing.expect(set.count() >= 9);
    var joined = try connect(gpa, region, set, 1000, 0);
    defer joined.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), joined.count());
    try testing.expectEqual(set.count() * 2, joined.get(0).len);
    // An L shape that a scan line crosses twice: still few paths, and each
    // link stays inside.
    var l: Paths = .empty;
    defer l.deinit(gpa);
    try l.append(gpa, &.{ .init(0, 0), .init(20_000, 0), .init(20_000, 5_000), .init(5_000, 5_000), .init(5_000, 20_000), .init(0, 20_000) });
    var lset = try lines(gpa, l, 1000, 90, 0);
    defer lset.deinit(gpa);
    var lj = try connect(gpa, l, lset, 1000, 90);
    defer lj.deinit(gpa);
    try testing.expect(lj.count() <= 3);
    // Each link (a segment that is not along a scan line) follows the
    // boundary: its middle is on an edge, so it never cuts the inside.
    var idx: geom.EdgeIndex = try .init(gpa, l, link_tolerance);
    defer idx.deinit(gpa);
    var links: usize = 0;
    for (0..lj.count()) |k| {
        const path = lj.get(k);
        for (path[0 .. path.len - 1], path[1..]) |u, v| {
            if (u.x == v.x) continue; // along a scan line (angle 90)
            links += 1;
            try testing.expect(idx.near(.{ .x = @divTrunc(u.x + v.x, 2), .y = @divTrunc(u.y + v.y, 2) }, link_tolerance));
        }
    }
    try testing.expect(links > 10);
}

test "honeycomb: the density is near the target" {
    const gpa = testing.allocator;
    var region: Paths = .empty;
    defer region.deinit(gpa);
    try region.append(gpa, &.{ .init(0, 0), .init(60_000, 0), .init(60_000, 60_000), .init(0, 60_000) });
    var cells = try honeycomb(gpa, region, 400, 0.2, 0, 0);
    defer cells.deinit(gpa);
    var len: f64 = 0;
    for (0..cells.count()) |i| {
        const p = cells.get(i);
        for (p[0 .. p.len - 1], p[1..]) |a, b| len += std.math.hypot(@as(f64, @floatFromInt(b.x - a.x)), @as(f64, @floatFromInt(b.y - a.y)));
    }
    // The flat sides are in two rows, so the line is about 4/3 of the
    // single grid. Within 40 % of 0.2 x 4/3.
    const density = len * 400 / (60_000.0 * 60_000.0);
    try testing.expect(density > 0.2 and density < 0.2 * 4.0 / 3.0 * 1.4);
}
