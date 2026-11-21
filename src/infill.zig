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
//!
//! References (see docs/references/): the solid fill of PrusaSlicer, which
//! fills neighbor surfaces as one area, so that no two lines lie on a
//! shared border (`fittedLines`, see docs/references/prusaslicer.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip_open = @import("clip_open.zig");
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
// Solid lines fitted to each island

/// Lines of a solid fill (skin), with the width of each line in mm.
pub const Fitted = struct {
    lines: Paths,
    widths: []f32,
    /// The piece of each line (see `fittedLines`), the island of each
    /// piece (an index into `islands`), and the islands of the region. The
    /// joins of the lines stay inside one piece.
    piece: []u32,
    piece_island: []u32,
    islands: []Paths,
};

/// True if p is inside the polygon (even-odd rule).
fn insidePoly(poly: []const Point, p: Point) bool {
    var in = false;
    var prev = poly[poly.len - 1];
    for (poly) |q| {
        defer prev = q;
        if ((q.y > p.y) != (prev.y > p.y)) {
            const x = @as(f64, @floatFromInt(prev.x)) + @as(f64, @floatFromInt(p.y - prev.y)) / @as(f64, @floatFromInt(q.y - prev.y)) * @as(f64, @floatFromInt(q.x - prev.x));
            if (@as(f64, @floatFromInt(p.x)) < x) in = !in;
        }
    }
    return in;
}

/// The islands of `region`: each outer polygon (positive area) with the
/// holes in it. The caller owns the result.
pub fn islandsOf(gpa: Allocator, region: Paths) Allocator.Error![]Paths {
    var outers: std.ArrayList(usize) = .empty;
    defer outers.deinit(gpa);
    for (0..region.count()) |k| if (geom.areaMm2(region.get(k)) > 0) try outers.append(gpa, k);
    const out = try gpa.alloc(Paths, outers.items.len);
    for (out) |*o| o.* = .empty;
    errdefer {
        for (out) |*o| o.deinit(gpa);
        gpa.free(out);
    }
    for (outers.items, 0..) |k, i| try out[i].append(gpa, region.get(k));
    // Each hole goes in the smallest outer polygon that has its first point.
    for (0..region.count()) |k| {
        const hole = region.get(k);
        if (hole.len == 0 or geom.areaMm2(hole) >= 0) continue;
        var best: ?usize = null;
        var best_area: f64 = std.math.inf(f64);
        for (outers.items, 0..) |ok, i| {
            const outer = region.get(ok);
            if (!insidePoly(outer, hole[0])) continue;
            const a = geom.areaMm2(outer);
            if (a < best_area) {
                best = i;
                best_area = a;
            }
        }
        if (best) |i| try out[i].append(gpa, hole);
    }
    return out;
}

/// The crossings of the island with the scan line at `y` of the turned
/// frame (x values, sorted), in `out`.
fn crossings(isl: Paths, c: f64, s: f64, y: f64, out: *std.ArrayList(f64), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (0..isl.count()) |k| {
        const poly = isl.get(k);
        if (poly.len < 3) continue;
        var prev = poly[poly.len - 1];
        for (poly) |q| {
            defer prev = q;
            const px: f64 = @floatFromInt(prev.x);
            const py: f64 = @floatFromInt(prev.y);
            const qx: f64 = @floatFromInt(q.x);
            const qy: f64 = @floatFromInt(q.y);
            // The turned frame: x along the lines, y across them.
            const ay = -px * s + py * c;
            const by = -qx * s + qy * c;
            if ((ay <= y) == (by <= y)) continue;
            const ax = px * c + py * s;
            const bx = qx * c + qy * s;
            try out.append(gpa, ax + (y - ay) / (by - ay) * (bx - ax));
        }
    }
    std.mem.sort(f64, out.items, {}, std.sort.asc(f64));
}

/// The lines of a solid fill of `region` (the area of the line centers),
/// fitted to each piece of each island. A piece is a part of an island
/// with one run of the outline on each side of each scan line: the island
/// cut at the height (across the lines) of each vertex, with the slabs
/// joined where the next slab has the same number of intervals. In a piece
/// the first and the last line lie on its edges across the lines, and the
/// lines between them are evenly spaced: the spacing is the extent of the
/// piece over the nearest whole number of line widths, and the width of
/// each line is that spacing (within 0.8 and 1.25 of `width`). On one grid
/// for the whole layer, a narrow strip along the lines can have a gap at a
/// wall of up to one line width. Only the spacing changes: no narrow line
/// fills a gap. Two pieces that meet at a border across the lines (at a
/// hole or a step in the outline) do not both put a line on it: the
/// shorter of the two lines gives way (see the comment in the code). The
/// memory is in `gpa`, an arena.
pub fn fittedLines(gpa: Allocator, region: Paths, width: i64, angle_deg: f64, min_length: i64) Allocator.Error!Fitted {
    var out: Paths = .empty;
    var widths: std.ArrayList(f32) = .empty;
    var piece_of: std.ArrayList(u32) = .empty;
    var piece_island: std.ArrayList(u32) = .empty;
    const islands = try islandsOf(gpa, region);
    const a = angle_deg * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    const w: f64 = @floatFromInt(width);
    var xs: std.ArrayList(f64) = .empty;
    var ys: std.ArrayList(f64) = .empty;
    // The lines of one island in the turned frame, before they go out.
    const Cand = struct { y: f64, x0: f64, x1: f64, bead: f32, pid: u32 };
    var cand: std.ArrayList(Cand) = .empty;
    var order: std.ArrayList(u32) = .empty;
    for (islands, 0..) |isl, ii| {
        cand.clearRetainingCapacity();
        // The heights of the vertices: the slabs are between them.
        ys.clearRetainingCapacity();
        for (isl.points.items) |p| try ys.append(gpa, @as(f64, @floatFromInt(p.x)) * -s + @as(f64, @floatFromInt(p.y)) * c);
        std.mem.sort(f64, ys.items, {}, std.sort.asc(f64));
        var n_ys: usize = 0;
        for (ys.items) |y| if (n_ys == 0 or y - ys.items[n_ys - 1] > 0.5) {
            ys.items[n_ys] = y;
            n_ys += 1;
        };
        if (n_ys < 2) continue;
        const slabs = n_ys - 1;
        // The intervals of each slab at its middle: their number, and the
        // first piece id of the slab.
        const counts = try gpa.alloc(u32, slabs);
        const first_id = try gpa.alloc(u32, slabs);
        var total: u32 = 0;
        for (0..slabs) |k| {
            try crossings(isl, c, s, (ys.items[k] + ys.items[k + 1]) / 2, &xs, gpa);
            counts[k] = @intCast(xs.items.len / 2);
            first_id[k] = total;
            total += counts[k];
        }
        // Union of the intervals k of slabs j and j + 1 when the two slabs
        // have the same number of intervals.
        const parent = try gpa.alloc(u32, total);
        for (parent, 0..) |*q, k| q.* = @intCast(k);
        const find = struct {
            fn f(par: []u32, x: u32) u32 {
                var r = x;
                while (par[r] != r) r = par[r];
                var y = x;
                while (par[y] != r) {
                    const next = par[y];
                    par[y] = r;
                    y = next;
                }
                return r;
            }
        }.f;
        // The two intervals must also meet at the boundary: their ends just
        // below and just above it are less than half a line apart. An edge
        // along the lines (a step in the outline) ends a piece.
        var below: std.ArrayList(f64) = .empty;
        for (0..slabs - 1) |k| if (counts[k] == counts[k + 1]) {
            const yb = ys.items[k + 1];
            const d = @min(@min(yb - ys.items[k], ys.items[k + 2] - yb) / 4, @max(1.0, w * 0.01));
            try crossings(isl, c, s, yb - d, &below, gpa);
            try crossings(isl, c, s, yb + d, &xs, gpa);
            if (below.items.len != xs.items.len or below.items.len != 2 * counts[k]) continue;
            for (0..counts[k]) |m| {
                if (@abs(below.items[2 * m] - xs.items[2 * m]) > w / 2 or @abs(below.items[2 * m + 1] - xs.items[2 * m + 1]) > w / 2) continue;
                const ra = find(parent, first_id[k] + @as(u32, @intCast(m)));
                const rb = find(parent, first_id[k + 1] + @as(u32, @intCast(m)));
                if (ra != rb) parent[rb] = ra;
            }
        };
        // The extent of each piece across the lines.
        const lo = try gpa.alloc(f64, total);
        const hi = try gpa.alloc(f64, total);
        @memset(lo, std.math.inf(f64));
        @memset(hi, -std.math.inf(f64));
        for (0..slabs) |k| for (0..counts[k]) |m| {
            const r = find(parent, first_id[k] + @as(u32, @intCast(m)));
            lo[r] = @min(lo[r], ys.items[k]);
            hi[r] = @max(hi[r], ys.items[k + 1]);
        };
        // The lines of each piece.
        for (0..total) |r| {
            if (parent[r] != r) continue;
            const eps = @max(1.0, w * 0.01);
            const extent = hi[r] - lo[r] - 2 * eps;
            if (!(extent > 0)) continue;
            var n = @round(extent / w);
            var spacing: f64 = if (n >= 1) extent / n else 0;
            if (n >= 1 and spacing > 1.25 * w) {
                n += 1;
                spacing = extent / n;
            }
            const bead: f32 = @floatCast(geom.toMm(@intFromFloat(@round(if (n >= 1) std.math.clamp(spacing, 0.8 * w, 1.25 * w) else w))));
            const pid: u32 = @intCast(piece_island.items.len);
            try piece_island.append(gpa, @intCast(ii));
            const count: usize = if (n >= 1) @intFromFloat(n + 1) else 1;
            for (0..count) |q| {
                const y = if (n >= 1) lo[r] + eps + @as(f64, @floatFromInt(q)) * spacing else (lo[r] + hi[r]) / 2;
                // The slab of y, and the interval of this piece in it.
                var k: usize = 0;
                while (k + 1 < slabs and ys.items[k + 1] <= y) k += 1;
                var m: ?usize = null;
                for (0..counts[k]) |mm| if (find(parent, first_id[k] + @as(u32, @intCast(mm))) == r) {
                    m = mm;
                    break;
                };
                const mi = m orelse continue;
                try crossings(isl, c, s, y, &xs, gpa);
                if (2 * mi + 1 >= xs.items.len) continue;
                const x0 = xs.items[2 * mi];
                const x1 = xs.items[2 * mi + 1];
                if (x1 - x0 < @as(f64, @floatFromInt(min_length))) continue;
                try cand.append(gpa, .{ .y = y, .x0 = x0, .x1 = x1, .bead = bead, .pid = pid });
            }
        }
        // The border of two pieces: each piece has a line on it, so two
        // beads lie on top of each other there (a raised ridge on the
        // skin). Of two lines of different pieces that lie on the same
        // scan line (less than half a line apart) and overlap along it,
        // the shorter line loses the overlap. The longer line covers the
        // border, and the next line of the other piece is one spacing
        // away, as in the middle of a piece.
        try order.resize(gpa, cand.items.len);
        for (order.items, 0..) |*o, k| o.* = @intCast(k);
        std.mem.sort(u32, order.items, cand.items, struct {
            fn lt(cs: []const Cand, l: u32, r: u32) bool {
                return cs[l].y < cs[r].y;
            }
        }.lt);
        for (order.items, 0..) |ki, oi| {
            for (order.items[oi + 1 ..]) |kj| {
                const li = &cand.items[ki];
                const lj = &cand.items[kj];
                if (lj.y - li.y >= w / 2) break;
                if (li.pid == lj.pid or li.x1 <= li.x0 or lj.x1 <= lj.x0) continue;
                if (@min(li.x1, lj.x1) <= @max(li.x0, lj.x0)) continue;
                const long, const short = if (li.x1 - li.x0 >= lj.x1 - lj.x0) .{ li, lj } else .{ lj, li };
                // The shorter line is not longer, so at most one part of
                // it is outside the longer line.
                if (short.x0 < long.x0) short.x1 = long.x0 else short.x0 = long.x1;
                if (short.x1 - short.x0 < @max(w, @as(f64, @floatFromInt(min_length)))) short.x1 = short.x0;
            }
        }
        for (cand.items) |l| {
            if (l.x1 <= l.x0) continue;
            // Back to the frame of the region.
            const p0: Point = .{ .x = @intFromFloat(@round(l.x0 * c - l.y * s)), .y = @intFromFloat(@round(l.x0 * s + l.y * c)) };
            const p1: Point = .{ .x = @intFromFloat(@round(l.x1 * c - l.y * s)), .y = @intFromFloat(@round(l.x1 * s + l.y * c)) };
            try out.append(gpa, &.{ p0, p1 });
            try widths.append(gpa, l.bead);
            try piece_of.append(gpa, l.pid);
        }
    }
    return .{ .lines = out, .widths = widths.items, .piece = piece_of.items, .piece_island = piece_island.items, .islands = islands };
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
    return connectWith(gpa, region, set, spacing, angle_deg, true, false);
}

/// `connect`, with each zigzag from the other end of its first line (the
/// high end along the lines). The zigzag then ends on the other side too,
/// if its number of lines is even. The retractless skin (`tour`) picks the
/// one of the two that joins best.
pub fn connectHigh(gpa: Allocator, region: Paths, set: Paths, spacing: i64, angle_deg: f64) Allocator.Error!Paths {
    return connectWith(gpa, region, set, spacing, angle_deg, true, true);
}

/// `connect`, with `straight` false: a line end that is not on the
/// boundary of the region gets no link (no straight link inside). The
/// extra lines of the flow band use it: they join only by walks along
/// the walls, and never along the inner edge of the band.
pub fn connectWith(gpa: Allocator, region: Paths, set: Paths, spacing: i64, angle_deg: f64, straight: bool, start_high: bool) Allocator.Error!Paths {
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
        try chain.append(arena, if (start_high) first.p1 else first.p0);
        try chain.append(arena, if (start_high) first.p0 else first.p1);
        var end_x = if (start_high) first.x0 else first.x1;
        var end_y = first.y;
        var end_p = if (start_high) first.p0 else first.p1;
        var end_at = if (start_high) first.at0 else first.at1;
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
                    else if (!straight) continue else blk: {
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

/// The paths of a retractless skin (see `tour`), with a line width (mm)
/// for each point.
pub const Tour = struct { paths: Paths, widths: []f32 };

/// Retractless skin: joins the zigzags of the pieces of one island (`set`,
/// with the line width of each zigzag in `set_w`) into as few paths as it
/// can. The zigzags with the same `group` are two ways to fill the same
/// piece (see `connectHigh`): the path uses one of them. The tour prints
/// each group once, so the nozzle travels and retracts less. From the end of a zigzag,
/// the path goes on to an end of another zigzag by a walk along the
/// boundary of `region` (the island), and prints on the way. A walk is at
/// most `max_link` long. Where no walk fits, a new path starts, and the
/// nozzle travels there.
///
/// The order: the next zigzag is ready if it can be, then it has a way on
/// from its other end (a walk to a zigzag that is left), then it has the
/// shortest walk. A zigzag is ready when the zigzags just below it (across
/// the lines, at the angle `angle_deg`) are done. So at a hole the path
/// fills both sides of the hole before it goes on over the hole. The way
/// on picks the end where the path goes into a zigzag, so that the path
/// does not stop at its other end. A
/// walk can go over the line ends of a zigzag that is printed already.
/// The caller prints each walk at half the line width (see
/// `layer.thinLinks`), so it adds no ridge along the wall. The memory is
/// in `gpa`, an arena.
pub fn tour(gpa: Allocator, region: Paths, set: Paths, set_w: []const f32, group: []const u32, n_groups: usize, spacing: i64, angle_deg: f64, max_link: i64) Allocator.Error!Tour {
    var out: Paths = .empty;
    var widths: std.ArrayList(f32) = .empty;
    const n = set.count();
    if (n == 0) return .{ .paths = out, .widths = widths.items };
    const a = angle_deg * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    const bound: Boundary = try .init(gpa, region);
    // Each zigzag: its ends on the boundary, and its box in the turned
    // frame (the lines are along x there).
    const Zig = struct { at: [2]?Spot, lo: Point, hi: Point };
    const gdone = try gpa.alloc(bool, n_groups);
    @memset(gdone, false);
    const zs = try gpa.alloc(Zig, n);
    for (zs, 0..) |*z, i| {
        const path = set.get(i);
        var lo: Point = .{ .x = std.math.maxInt(i64), .y = std.math.maxInt(i64) };
        var hi: Point = .{ .x = std.math.minInt(i64), .y = std.math.minInt(i64) };
        for (path) |q| {
            const t = rotate(q, c, -s);
            lo = .{ .x = @min(lo.x, t.x), .y = @min(lo.y, t.y) };
            hi = .{ .x = @max(hi.x, t.x), .y = @max(hi.y, t.y) };
        }
        z.* = .{ .at = .{ bound.locate(path[0]), bound.locate(path[path.len - 1]) }, .lo = lo, .hi = hi };
    }
    // The zigzags just below each zigzag: the top of the one is within two
    // spacings of the bottom of the other, and they overlap along x.
    var below_start = try gpa.alloc(u32, n + 1);
    var below: std.ArrayList(u32) = .empty;
    for (zs, 0..) |z, i| {
        below_start[i] = @intCast(below.items.len);
        for (zs, 0..) |d, j| {
            if (group[i] == group[j] or d.hi.y > z.lo.y + @divTrunc(spacing, 2)) continue;
            if (z.lo.y - d.hi.y > 2 * spacing) continue;
            if (d.hi.x < z.lo.x or z.hi.x < d.lo.x) continue;
            try below.append(gpa, @intCast(j));
        }
    }
    below_start[n] = @intCast(below.items.len);
    const limit: f64 = @floatFromInt(max_link);
    var walk: std.ArrayList(Point) = .empty;
    var best_walk: std.ArrayList(Point) = .empty;
    var scratch_walk: std.ArrayList(Point) = .empty;
    var left = n_groups;
    while (left > 0) {
        // A new path: the lowest zigzag that is left, from its lower end.
        var first: usize = 0;
        var first_y: i64 = std.math.maxInt(i64);
        for (zs, 0..) |z, i| if (!gdone[group[i]] and z.lo.y < first_y) {
            first_y = z.lo.y;
            first = i;
        };
        const fp = set.get(first);
        var rev = rotate(fp[fp.len - 1], c, -s).y < rotate(fp[0], c, -s).y;
        var cur = first;
        while (true) {
            gdone[group[cur]] = true;
            left -= 1;
            const path = set.get(cur);
            const bead = set_w[cur];
            if (rev) {
                var k = path.len;
                while (k > 0) {
                    k -= 1;
                    try out.points.append(gpa, path[k]);
                }
            } else try out.points.appendSlice(gpa, path);
            try widths.appendNTimes(gpa, bead, path.len);
            const end = (if (rev) zs[cur].at[0] else zs[cur].at[1]) orelse break;
            const end_p = if (rev) path[0] else path[path.len - 1];
            // The next zigzag: ready first, then one with a way on from its
            // other end (to a zigzag that is left), then the shortest walk.
            var best: ?usize = null;
            var best_rev = false;
            var best_rank: u2 = 0;
            var best_len: f64 = limit + 1;
            for (zs, 0..) |z, j| {
                if (gdone[group[j]]) continue;
                var ready = true;
                for (below.items[below_start[j]..below_start[j + 1]]) |d| if (!gdone[group[d]]) {
                    ready = false;
                    break;
                };
                const jp = set.get(j);
                for (0..2) |k| {
                    const to = z.at[k] orelse continue;
                    const q = if (k == 0) jp[0] else jp[jp.len - 1];
                    if (Point.dist(end_p, q) > limit) continue;
                    walk.clearRetainingCapacity();
                    const len = (try bound.walk(gpa, end, to, limit, &walk)) orelse continue;
                    const rank_ready: u2 = if (ready) 2 else 0;
                    if (rank_ready + 1 < best_rank) continue;
                    if (rank_ready + 1 == best_rank and len >= best_len) continue;
                    // The look ahead: from the other end of j, a walk to
                    // an end of another zigzag that is left.
                    const exit = z.at[1 - k];
                    const exit_p = if (k == 0) jp[jp.len - 1] else jp[0];
                    var on = left == 1;
                    if (exit) |x| for (zs, 0..) |m, mi| {
                        if (on) break;
                        if (gdone[group[mi]] or group[mi] == group[j]) continue;
                        const mp = set.get(mi);
                        for (0..2) |mk| {
                            const mt = m.at[mk] orelse continue;
                            if (Point.dist(exit_p, if (mk == 0) mp[0] else mp[mp.len - 1]) > limit) continue;
                            scratch_walk.clearRetainingCapacity();
                            if ((try bound.walk(gpa, x, mt, limit, &scratch_walk)) != null) {
                                on = true;
                                break;
                            }
                        }
                    };
                    const rank = rank_ready + @intFromBool(on);
                    if (rank > best_rank or (rank == best_rank and len < best_len) or best == null) {
                        best = j;
                        best_rev = k == 1;
                        best_rank = rank;
                        best_len = len;
                        best_walk.clearRetainingCapacity();
                        try best_walk.appendSlice(gpa, walk.items);
                    }
                }
            }
            const next = best orelse break;
            // The walk between the two ends prints with the width of the
            // next zigzag.
            if (best_walk.items.len > 2) {
                const mid = best_walk.items[1 .. best_walk.items.len - 1];
                try out.points.appendSlice(gpa, mid);
                try widths.appendNTimes(gpa, set_w[next], mid.len);
            }
            cur = next;
            rev = best_rev;
        }
        try out.ends.append(gpa, @intCast(out.points.items.len));
    }
    return .{ .paths = out, .widths = widths.items };
}

/// A line for each island of `region` that `have` misses: one line along
/// the length of the island, through its middle (the main axis of its
/// points, from their covariance). A sparse infill with a wide spacing
/// (10 % grid: 11 mm) misses a narrow island on most layers, and a lone
/// short piece goes, so the island stays empty and the top over it sags.
/// The line is the same on each layer of the same island, so the lines
/// stack into a rib. Islands smaller than 3 x 3 line widths, and lines
/// shorter than `min_len`, are left out. The memory is in `gpa`, an arena.
pub fn spines(gpa: Allocator, region: Paths, have: Paths, width: i64, min_len: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    const islands = try islandsOf(gpa, region);
    const w: f64 = @floatFromInt(width);
    for (islands) |isl| {
        if (isl.isEmpty()) continue;
        var area: f64 = 0;
        for (0..isl.count()) |k| area += geom.areaMm2(isl.get(k));
        const wmm = geom.toMm(width);
        if (area < 9 * wmm * wmm) continue;
        // Does a line of `have` cross the island? A point of a line inside
        // it, or the middle of a segment.
        const idx: geom.EdgeIndex = try .init(gpa, isl, width);
        var hit = false;
        outer: for (0..have.count()) |k| {
            const path = have.get(k);
            // A line along the edge of the island (a joint of the lines
            // along the wall) counts too.
            for (path, 0..) |q, i| {
                if (idx.inside(q) or idx.near(q, width)) {
                    hit = true;
                    break :outer;
                }
                if (i + 1 < path.len) {
                    const m: Point = .{ .x = @divTrunc(q.x + path[i + 1].x, 2), .y = @divTrunc(q.y + path[i + 1].y, 2) };
                    if (idx.inside(m) or idx.near(m, width)) {
                        hit = true;
                        break :outer;
                    }
                }
            }
        }
        if (hit) continue;
        // The main axis of the outer boundary.
        const outer_poly = isl.get(0);
        var mx: f64 = 0;
        var my: f64 = 0;
        for (outer_poly) |q| {
            mx += @floatFromInt(q.x);
            my += @floatFromInt(q.y);
        }
        const nf: f64 = @floatFromInt(outer_poly.len);
        mx /= nf;
        my /= nf;
        var cxx: f64 = 0;
        var cxy: f64 = 0;
        var cyy: f64 = 0;
        var reach: f64 = 0;
        for (outer_poly) |q| {
            const dx = @as(f64, @floatFromInt(q.x)) - mx;
            const dy = @as(f64, @floatFromInt(q.y)) - my;
            cxx += dx * dx;
            cxy += dx * dy;
            cyy += dy * dy;
            reach = @max(reach, @sqrt(dx * dx + dy * dy));
        }
        const ang = 0.5 * std.math.atan2(2 * cxy, cxx - cyy);
        const ux = @cos(ang) * (reach + w);
        const uy = @sin(ang) * (reach + w);
        var line: Paths = .empty;
        try line.append(gpa, &.{
            .{ .x = @intFromFloat(@round(mx - ux)), .y = @intFromFloat(@round(my - uy)) },
            .{ .x = @intFromFloat(@round(mx + ux)), .y = @intFromFloat(@round(my + uy)) },
        });
        const pieces = try clip_open.clipPolylines(gpa, isl, line, min_len);
        // The longest piece (a bent island can cut the line in two).
        var best: ?usize = null;
        var best_len: f64 = 0;
        for (0..pieces.count()) |k| {
            const pc = pieces.get(k);
            const l = Point.dist(pc[0], pc[pc.len - 1]);
            if (l > best_len) {
                best_len = l;
                best = k;
            }
        }
        if (best) |k| try out.append(gpa, pieces.get(k));
    }
    return out;
}

/// Joins open paths of any shape (gyroid curves, honeycomb rows) where
/// they end on the boundary of the region: from the end of a path, the
/// chain goes on to the nearest free end of another path (that path is
/// turned if needed) by a walk along the boundary, if the walk is at most
/// `max_walk` long. Then a path that is still alone and shorter than
/// `min_len` goes: a lone short piece costs a travel for little infill.
pub fn joinPaths(gpa: Allocator, region: Paths, set: Paths, max_walk: i64, min_len: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    const n = set.count();
    if (n == 0) return out;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bound: Boundary = try .init(arena, region);
    const End = struct { at: ?Spot, p: Point };
    const ends = try arena.alloc([2]End, n);
    const used = try arena.alloc(bool, n);
    @memset(used, false);
    for (0..n) |i| {
        const p = set.get(i);
        ends[i] = .{ .{ .at = bound.locate(p[0]), .p = p[0] }, .{ .at = bound.locate(p[p.len - 1]), .p = p[p.len - 1] } };
    }
    const limit: f64 = @floatFromInt(max_walk);
    // The ends in a grid of cells as wide as the walk limit: a walk of the
    // limit ends at most one cell away, so a search looks at 9 cells.
    const cell: i64 = @max(max_walk, 1);
    const Key = struct { x: i64, y: i64 };
    var grid: std.AutoHashMapUnmanaged(Key, std.ArrayList(u32)) = .empty;
    for (ends, 0..) |pair, i| for (pair, 0..) |e, k| {
        if (e.at == null) continue;
        const key: Key = .{ .x = @divFloor(e.p.x, cell), .y = @divFloor(e.p.y, cell) };
        const slot = try grid.getOrPut(arena, key);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, @intCast(2 * i + k));
    };
    const Cand = struct { d: f64, code: u32 };
    var cands: std.ArrayList(Cand) = .empty;
    var chain: std.ArrayList(Point) = .empty;
    var walk: std.ArrayList(Point) = .empty;
    var best_walk: std.ArrayList(Point) = .empty;
    for (0..n) |first| {
        if (used[first]) continue;
        used[first] = true;
        chain.clearRetainingCapacity();
        try chain.appendSlice(arena, set.get(first));
        var pieces: usize = 1;
        // Grow the chain at its end, then (turned) at its start.
        for (0..2) |side| {
            if (side == 1) std.mem.reverse(Point, chain.items);
            var tail: End = .{ .at = bound.locate(chain.items[chain.items.len - 1]), .p = chain.items[chain.items.len - 1] };
            while (tail.at) |from| {
                var best: ?usize = null;
                var best_rev = false;
                var best_len: f64 = limit + 1;
                const cx = @divFloor(tail.p.x, cell);
                const cy = @divFloor(tail.p.y, cell);
                // The candidates by straight distance: the walk is at least
                // that long, so the search stops when no closer end can win.
                cands.clearRetainingCapacity();
                for (0..9) |c9| {
                    const key: Key = .{ .x = cx + @as(i64, @intCast(c9 % 3)) - 1, .y = cy + @as(i64, @intCast(c9 / 3)) - 1 };
                    const list = grid.get(key) orelse continue;
                    for (list.items) |code| {
                        if (used[code / 2]) continue;
                        const d = Point.dist(tail.p, ends[code / 2][code % 2].p);
                        if (d <= limit) try cands.append(arena, .{ .d = d, .code = code });
                    }
                }
                std.mem.sort(Cand, cands.items, {}, struct {
                    fn lt(_: void, l: Cand, r: Cand) bool {
                        return l.d < r.d;
                    }
                }.lt);
                for (cands.items) |cand| {
                    if (cand.d >= best_len) break;
                    const j: usize = cand.code / 2;
                    const e: usize = cand.code % 2;
                    const to = ends[j][e].at.?;
                    walk.clearRetainingCapacity();
                    const len = (try bound.walk(arena, from, to, @min(limit, best_len), &walk)) orelse continue;
                    if (len < best_len) {
                        best = j;
                        best_rev = e == 1;
                        best_len = len;
                        best_walk.clearRetainingCapacity();
                        try best_walk.appendSlice(arena, walk.items);
                    }
                }
                const b = best orelse break;
                used[b] = true;
                pieces += 1;
                if (best_walk.items.len > 2) try chain.appendSlice(arena, best_walk.items[1 .. best_walk.items.len - 1]);
                const piece = set.get(b);
                const start = chain.items.len;
                try chain.appendSlice(arena, piece);
                if (best_rev) std.mem.reverse(Point, chain.items[start..]);
                tail = ends[b][if (best_rev) 0 else 1];
            }
        }
        if (pieces == 1) {
            var len: f64 = 0;
            for (chain.items[0 .. chain.items.len - 1], chain.items[1..]) |u, v| len += Point.dist(u, v);
            if (len < @as(f64, @floatFromInt(min_len))) continue;
        }
        try out.append(gpa, chain.items);
    }
    return out;
}

/// The paths of `set` without the lone short lines: a path of two points
/// shorter than `min_len`.
pub fn dropLone(gpa: Allocator, set: Paths, min_len: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    const lim: f64 = @floatFromInt(min_len);
    for (0..set.count()) |i| {
        const p = set.get(i);
        if (p.len == 2 and Point.dist(p[0], p[1]) < lim) continue;
        try out.append(gpa, p);
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
    /// The width of a band is 1 << shift: the band of a y is a shift, with
    /// no division.
    shift: u6,
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
        const span: u64 = @intCast(@max(hi - lo + 1, 1));
        // The smallest power of two width that gives at most `want` bands.
        var shift: u6 = 0;
        while ((span - 1) >> shift >= want) shift += 1;
        const bands: usize = @intCast(((span - 1) >> shift) + 1);
        var b: Boundary = .{ .region = region, .min = lo, .shift = shift, .starts = try arena.alloc(u32, bands + 1), .edges = &.{} };
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
                    const q = poly[if (i + 1 == poly.len) 0 else i + 1];
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

    inline fn band(b: *const Boundary, y: i64) usize {
        const k = (y - b.min) >> b.shift;
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
            const v = poly[if (e[1] + 1 == poly.len) 0 else e[1] + 1];
            const ux: f64 = @floatFromInt(v.x - u.x);
            const uy: f64 = @floatFromInt(v.y - u.y);
            const px: f64 = @floatFromInt(p.x - u.x);
            const py: f64 = @floatFromInt(p.y - u.y);
            const len2 = ux * ux + uy * uy;
            const t = if (len2 > 0) geom.fmax(0, geom.fmin((px * ux + py * uy) / len2, 1)) else 0;
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
                i = if (i + 1 == m) 0 else i + 1;
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
                i = if (i == 0) m - 1 else i - 1;
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
///
/// Two rows that touch both have the flat side between them, so a flat
/// side prints twice, and the cells have thick walls on two of their six
/// sides. With `single`, each wall prints once: the even rows are whole
/// zigzags, and the odd rows give only their slanted sides, each as its
/// own line. All walls then have one width (for example for a grille),
/// but a cell has more line starts.
pub fn honeycomb(gpa: Allocator, region: Paths, width: i64, density: f64, angle_deg: f64, min_length: i64) Allocator.Error!Paths {
    return honeycombWith(gpa, region, width, density, angle_deg, min_length, false);
}

pub fn honeycombWith(gpa: Allocator, region: Paths, width: i64, density: f64, angle_deg: f64, min_length: i64, single: bool) Allocator.Error!Paths {
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
            var pts: [5]Point = undefined;
            for (zs, 0..) |z, k| {
                const y = if (odd) base + h - z[1] else base + z[1];
                pts[k] = rotate(.{ .x = @intFromFloat(@round(x + z[0])), .y = @intFromFloat(@round(y)) }, c, s);
            }
            if (single and odd) {
                // The slanted sides only: the rise, and the fall to the
                // start of the next period.
                const y_end = base + h;
                pts[4] = rotate(.{ .x = @intFromFloat(@round(x + period)), .y = @intFromFloat(@round(y_end)) }, c, s);
                try rows.append(arena, try arena.dupe(Point, pts[1..3]));
                try rows.append(arena, try arena.dupe(Point, pts[3..5]));
                continue;
            }
            try row.appendSlice(arena, pts[0..4]);
        }
        if (single and odd) continue;
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
                const r = @import("geom.zig").hypot(a, cu);
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
        for (p[0 .. p.len - 1], p[1..]) |a, b| len += @import("geom.zig").hypot(@as(f64, @floatFromInt(b.x - a.x)), @as(f64, @floatFromInt(b.y - a.y)));
    }
    // The flat sides are in two rows, so the line is about 4/3 of the
    // single grid. Within 40 % of 0.2 x 4/3.
    const density = len * 400 / (60_000.0 * 60_000.0);
    try testing.expect(density > 0.2 and density < 0.2 * 4.0 / 3.0 * 1.4);
}

test "honeycomb: with single walls, each wall prints once at the target density" {
    const gpa = testing.allocator;
    var region: Paths = .empty;
    defer region.deinit(gpa);
    try region.append(gpa, &.{ .init(0, 0), .init(60_000, 0), .init(60_000, 60_000), .init(0, 60_000) });
    var cells = try honeycombWith(gpa, region, 400, 0.2, 0, 0, true);
    defer cells.deinit(gpa);
    var len: f64 = 0;
    // No segment lies on another segment.
    var segs: std.ArrayList([2]Point) = .empty;
    defer segs.deinit(gpa);
    for (0..cells.count()) |i| {
        const p = cells.get(i);
        for (p[0 .. p.len - 1], p[1..]) |a, b| {
            len += @import("geom.zig").hypot(@as(f64, @floatFromInt(b.x - a.x)), @as(f64, @floatFromInt(b.y - a.y)));
            const key: [2]Point = if (a.x < b.x or (a.x == b.x and a.y < b.y)) .{ a, b } else .{ b, a };
            for (segs.items) |sg| {
                const mid: Point = .{ .x = @divTrunc(key[0].x + key[1].x, 2), .y = @divTrunc(key[0].y + key[1].y, 2) };
                const smid: Point = .{ .x = @divTrunc(sg[0].x + sg[1].x, 2), .y = @divTrunc(sg[0].y + sg[1].y, 2) };
                try testing.expect(mid.distSq(smid) > 100 * 100);
            }
            try segs.append(gpa, key);
        }
    }
    // The single grid: within 10 % of 0.2 (the edges of the square cut
    // some cells).
    const density = len * 400 / (60_000.0 * 60_000.0);
    try testing.expect(density > 0.2 * 0.9 and density < 0.2 * 1.1);
}

test "fittedLines: a narrow strip along the lines gets a line on each edge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    // A U shape: two strips 2.3 mm wide (the area of the line centers),
    // 20 mm long, along x, joined at the left by a block. The lines go
    // along x (angle 0). One grid for all would leave a gap at a wall.
    var region: Paths = .empty;
    try region.append(gpa, &.{ .init(0, 0), .init(20_000, 0), .init(20_000, 2_300), .init(5_000, 2_300), .init(5_000, 7_700), .init(20_000, 7_700), .init(20_000, 10_000), .init(0, 10_000) });
    const fit = try fittedLines(gpa, region, 500, 0, 500);
    // The lines of the lower strip (y < 2.3 mm, x > 5 mm): first and last
    // on the edges, evenly spaced.
    var ys: std.ArrayList(i64) = .empty;
    for (0..fit.lines.count()) |k| {
        const l = fit.lines.get(k);
        if (l[0].y < 2_300 and @max(l[0].x, l[1].x) > 15_000) try ys.append(gpa, l[0].y);
    }
    std.mem.sort(i64, ys.items, {}, std.sort.asc(i64));
    try testing.expect(ys.items.len >= 4);
    try testing.expect(ys.items[0] < 30);
    try testing.expect(ys.items[ys.items.len - 1] > 2_270);
    const step = ys.items[1] - ys.items[0];
    for (ys.items[1..], ys.items[0 .. ys.items.len - 1]) |b, a| try testing.expect(@abs(b - a - step) <= 2);
    // The widths stay near the line width.
    for (fit.widths) |wd| try testing.expect(wd >= 0.4 - 1e-6 and wd <= 0.625 + 1e-6);
}

/// The bead area of the lines of `fit` (lines along x, each as wide in y
/// as its width) in the box x0..x1, y0..y1, over the area of the box.
fn beadShare(fit: Fitted, x0: i64, x1: i64, y0: i64, y1: i64) f64 {
    var sum: f64 = 0;
    for (0..fit.lines.count()) |k| {
        const l = fit.lines.get(k);
        const half: f64 = fit.widths[k] * 500;
        const y: f64 = @floatFromInt(l[0].y);
        const oy = @min(y + half, @as(f64, @floatFromInt(y1))) - @max(y - half, @as(f64, @floatFromInt(y0)));
        const ox = @min(@max(l[0].x, l[1].x), x1) - @max(@min(l[0].x, l[1].x), x0);
        if (oy > 0 and ox > 0) sum += oy * @as(f64, @floatFromInt(ox));
    }
    return sum / @as(f64, @floatFromInt((x1 - x0) * (y1 - y0)));
}

test "fittedLines: two pieces that share a border have no line on top of a line there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    // A square of 40 mm (the area of the line centers) with a hole of
    // 10 mm in the middle. The lines go along x (angle 0). The strips to
    // the left and the right of the hole are pieces of their own. They
    // share a border at y = 15 mm and y = 25 mm with the pieces below and
    // above the hole.
    var region: Paths = .empty;
    try region.append(gpa, &.{ .init(0, 0), .init(40_000, 0), .init(40_000, 40_000), .init(0, 40_000) });
    try region.append(gpa, &.{ .init(15_000, 15_000), .init(15_000, 25_000), .init(25_000, 25_000), .init(25_000, 15_000) });
    const w = 420;
    const fit = try fittedLines(gpa, region, w, 0, w);
    try testing.expect(fit.piece_island.len >= 4);
    // No line lies on another line: two lines less than half a width
    // apart do not overlap along x.
    for (0..fit.lines.count()) |i| for (i + 1..fit.lines.count()) |j| {
        const a = fit.lines.get(i);
        const b = fit.lines.get(j);
        if (@abs(a[0].y - b[0].y) >= w / 2) continue;
        const lo = @max(@min(a[0].x, a[1].x), @min(b[0].x, b[1].x));
        const hi = @min(@max(a[0].x, a[1].x), @max(b[0].x, b[1].x));
        try testing.expect(hi <= lo);
    };
    // The bead area for each area in a band of one line width on each
    // side of a border, beside the hole, is within 10 % of the inside of
    // a piece.
    const inside = beadShare(fit, 2_000, 13_000, 5_000, 10_000);
    try testing.expect(inside > 0.9 and inside < 1.1);
    for ([_]i64{ 15_000, 25_000 }) |y| for ([_][2]i64{ .{ 2_000, 13_000 }, .{ 27_000, 38_000 } }) |xr| {
        const band = beadShare(fit, xr[0], xr[1], y - w, y + w);
        try testing.expect(@abs(band - inside) < 0.1 * inside);
    };
}
