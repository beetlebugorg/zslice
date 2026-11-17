//! Gap fill: lines in the narrow areas of a layer that no wall and no skin
//! line covers.
//!
//! Classic walls are offsets of the outline by whole line widths. Where
//! the part is narrower than a line, the next wall stops, and a strip
//! between two walls stays empty. The skin lines fit their area (see
//! infill.fittedLines), but a line shorter than one line width does not
//! print, so a narrow wedge of skin next to a wall can stay empty. These
//! areas are the gaps (see gaps.zig, which measures them).
//!
//! The gaps of a layer come from the plan (see layer.zig):
//!
//! - Between the classic walls: for wall k (k from 1), the area inside
//!   wall k - 1 (the outline moved in by k line widths) less the footprint
//!   of wall k (its center line grown by half a line width). The parts of
//!   the outline thinner than one line are for thin walls.
//! - In the skin: the skin area less the footprint of the skin lines (a
//!   rectangle along each segment, see `addFootprint`).
//!
//! An exact difference of the whole layer costs as much as a wall. But
//! most of a layer has no gap: each wall follows the wall before it, and
//! the skin lines reach the edge of the skin. A fast test (see
//! `farPoints`) finds the points on an edge with no wall or line near
//! them, and the exact difference is only in the boxes around them.
//!
//! Each gap gets a line along its middle, with the width of the gap at
//! each point. The lines come from Arachne (see arachne.zig) with one wall:
//! a gap narrower than about one line gets one line, and a wider gap a
//! loop. Arachne first removes the slivers narrower than a quarter of a
//! line. The areas smaller than a square of half a line, and the lines
//! shorter than a quarter of a line, do not print. The transition angle is
//! 45 degrees, so that a wedge also gets a line, and not only a strip with
//! parallel sides.
//!
//! This is the "gap fill" of PrusaSlicer and the "fill gaps between walls"
//! of Cura. The cut of a polygon to a box is the method of Sutherland and
//! Hodgman. See REFERENCES.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const arachne = @import("arachne.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const Paths = geom.Paths;
const Point = geom.Point;

/// The footprints grow by this much (micrometers) on each side, so that
/// two footprints side by side touch, and the round corners of an offset
/// leave no sliver.
pub const pad: i64 = 10;

/// The gap fill lines of a layer, with a line width (mm) for each point.
pub const Fill = struct {
    loops: Paths = .empty,
    loop_widths: []const f32 = &.{},
    lines: Paths = .empty,
    line_widths: []const f32 = &.{},

    pub fn isEmpty(f: Fill) bool {
        return f.loops.isEmpty() and f.lines.isEmpty();
    }

    pub fn clone(f: Fill, a: Allocator) Allocator.Error!Fill {
        return .{
            .loops = try f.loops.clone(a),
            .loop_widths = try a.dupe(f32, f.loop_widths),
            .lines = try f.lines.clone(a),
            .line_widths = try a.dupe(f32, f.line_widths),
        };
    }
};

/// Adds to `out` the footprint of the beads along `lines`: for each
/// segment, a rectangle as wide as the bead, with a square end of half a
/// bead at each end. A footprint is `grow` wider on each side, so that the
/// footprints of two lines next to each other touch. `widths` has the
/// width (mm) of each path; an empty `widths` gives each path `width`.
pub fn addFootprint(a: Allocator, out: *Paths, lines: Paths, widths: []const f32, width: i64, grow: i64) Allocator.Error!void {
    for (0..lines.count()) |k| {
        const pts = lines.get(k);
        const bead: f64 = if (widths.len > k) @as(f64, widths[k]) * geom.units_per_mm else @floatFromInt(width);
        for (1..pts.len) |j| try addSegment(a, out, pts[j - 1], pts[j], bead, grow);
    }
}

/// Adds to `out` the footprint of one segment from p0 to p1 with a bead
/// of `bead` micrometers (see `addFootprint`).
fn addSegment(a: Allocator, out: *Paths, p0: Point, p1: Point, bead: f64, grow: i64) Allocator.Error!void {
    const h = bead / 2 + @as(f64, @floatFromInt(grow));
    const dx: f64 = @floatFromInt(p1.x - p0.x);
    const dy: f64 = @floatFromInt(p1.y - p0.y);
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    // The direction along the segment and the normal, h long.
    const ux = dx / len * h;
    const uy = dy / len * h;
    const x0: f64 = @as(f64, @floatFromInt(p0.x)) - ux;
    const y0: f64 = @as(f64, @floatFromInt(p0.y)) - uy;
    const x1: f64 = @as(f64, @floatFromInt(p1.x)) + ux;
    const y1: f64 = @as(f64, @floatFromInt(p1.y)) + uy;
    // Counterclockwise: right side out, left side back.
    const quad = [4]Point{
        pt(x0 + uy, y0 - ux),
        pt(x1 + uy, y1 - ux),
        pt(x1 - uy, y1 + ux),
        pt(x0 - uy, y0 + ux),
    };
    try out.append(a, &quad);
}

/// The parts of `skin` (the skin area) that the skin `lines` do not cover.
/// `widths` has the width (mm) of each path of `lines`, and `angle_deg`
/// is the direction of the lines. The memory is in `a`, an arena.
///
/// The lines cover all of the skin but a sawtooth along its edge, except
/// where they stop: a line shorter than one line width does not print. A
/// fast test finds these places: the points along the edge of the skin
/// that are more than 3/4 of a line width from all lines. The exact
/// computation (the skin less the footprints of the lines) is only in a
/// box around each group of such points. The work is in a frame turned
/// so that the lines are along x: then each line is in one band of the
/// index of edges (see geom.EdgeIndex), and a box holds few lines.
pub fn skinGaps(a: Allocator, skin: Paths, lines: Paths, widths: []const f32, angle_deg: f64, w: i64) Allocator.Error!Paths {
    const rad = angle_deg * std.math.pi / 180.0;
    const c = @cos(rad);
    const sn = @sin(rad);
    // Each segment of the lines as a path of 2 points, for the index.
    var segs: Paths = .empty;
    var seg_w: std.ArrayList(f32) = .empty;
    for (0..lines.count()) |k| {
        const pts = lines.get(k);
        for (1..pts.len) |j| {
            try segs.append(a, &.{ turn(pts[j - 1], c, -sn), turn(pts[j], c, -sn) });
            try seg_w.append(a, if (widths.len > k) widths[k] else @floatCast(geom.toMm(w)));
        }
    }
    var area: Paths = .empty;
    for (0..skin.count()) |k| {
        for (skin.get(k)) |q| try area.appendPoint(a, turn(q, c, -sn));
        try area.endPath(a, 0);
    }
    var idx: ?geom.EdgeIndex = if (segs.isEmpty()) null else try .init(a, segs, w);
    const far = try farPoints(a, area, if (idx) |*x| x else null, @divTrunc(3 * w, 4), 0, w);
    if (far.len == 0) return .empty;
    // One boolean for all boxes: a boolean of a small set costs about as
    // much as its setup. Boxes that overlap give the same result.
    var near_area: Paths = .empty;
    var foot: Paths = .empty;
    var boxes: Paths = .empty;
    for (try boxesAround(a, far, w)) |box| {
        // The lines near the box, and their footprints.
        const near = grown(box, w);
        for (0..segs.count()) |k| {
            const sg = segs.get(k);
            if (@max(sg[0].x, sg[1].x) < near.min.x or @min(sg[0].x, sg[1].x) > near.max.x or
                @max(sg[0].y, sg[1].y) < near.min.y or @min(sg[0].y, sg[1].y) > near.max.y) continue;
            try addSegment(a, &foot, sg[0], sg[1], @as(f64, seg_w.items[k]) * geom.units_per_mm, pad);
        }
        try near_area.appendAll(a, try cutToBox(a, area, near));
        try boxes.appendAll(a, try boxPath(a, box));
    }
    const gap = try clip.intersect(a, try clip.difference(a, near_area, foot), boxes);
    // Back to the frame of the layer.
    var out: Paths = .empty;
    for (0..gap.count()) |k| {
        for (gap.get(k)) |q| try out.appendPoint(a, turn(q, c, sn));
        try out.endPath(a, 0);
    }
    return out;
}

/// The point p turned by the angle with cosine c and sine s.
fn turn(p: Point, c: f64, s: f64) Point {
    const x: f64 = @floatFromInt(p.x);
    const y: f64 = @floatFromInt(p.y);
    return pt(x * c - y * s, x * s + y * c);
}

/// The gaps at classic wall k: the area inside wall k - 1 (the outline
/// moved in by k line widths) less the footprint of wall k (its center
/// line grown by half a line width). `walls` has the center lines of the
/// walls, outer wall first; with k equal to `walls.len`, wall k is empty.
/// The result is in `a`, and the work in `s`.
///
/// Most walls follow the wall before them at all points: a fast test
/// (see `farPoints`) finds the places where they do not, and the exact
/// computation is only in a box around each group of such places. In the
/// box, the outline and the walls are cut to the box with a margin, so
/// that the cut edges change nothing in the box.
pub fn wallGap(a: Allocator, s: Allocator, outline: Paths, walls: []const Paths, k: usize, w: i64) Allocator.Error!Paths {
    const ref = if (k == 0) outline else walls[k - 1];
    const next = if (k < walls.len) walls[k] else Paths.empty;
    const d = if (k == 0) @divTrunc(w, 2) else w;
    var idx: ?geom.EdgeIndex = if (next.isEmpty()) null else try .init(s, next, d + @divTrunc(w, 8));
    const pts = try farPoints(s, ref, if (idx) |*x| x else null, d + @divTrunc(w, 8), d, w);
    if (pts.len == 0) return .empty;
    var out: Paths = .empty;
    const half = @divTrunc(w, 2);
    for (try boxesAround(s, pts, w)) |box| {
        // The cut edges move by half a line width in the offsets below.
        const big = grown(box, w);
        const inside = if (k == 0) try cutToBox(s, outline, big) else try offset_mod.offset(s, try cutToBox(s, ref, big), -half, .{});
        const foot = try offset_mod.offset(s, try cutToBox(s, next, big), half + pad, .{});
        const gap = try clip.difference(s, inside, foot);
        try out.appendAll(a, try clip.intersect(s, gap, try boxPath(s, box)));
    }
    return out;
}

/// Boxes around the groups of the points `pts`: the cells (4 line widths
/// square) that hold a point, joined where they touch (also at a corner),
/// and grown by one line width. The gap at a point can reach about one
/// line width past its cell.
fn boxesAround(s: Allocator, pts: []const Point, w: i64) Allocator.Error![]geom.Box {
    const cell = 4 * w;
    const Cell = struct { x: i64, y: i64, group: u32 = 0 };
    var cells: std.ArrayList(Cell) = .empty;
    for (pts) |p| {
        const c: Cell = .{ .x = @divFloor(p.x, cell), .y = @divFloor(p.y, cell) };
        for (cells.items) |o| {
            if (o.x == c.x and o.y == c.y) break;
        } else try cells.append(s, c);
    }
    for (cells.items, 0..) |*c, ci| c.group = @intCast(ci);
    var changed = true;
    while (changed) {
        changed = false;
        for (cells.items) |*c| for (cells.items) |o| {
            if (@abs(c.x - o.x) <= 1 and @abs(c.y - o.y) <= 1 and o.group < c.group) {
                c.group = o.group;
                changed = true;
            }
        };
    }
    var boxes: std.ArrayList(geom.Box) = .empty;
    for (cells.items, 0..) |c0, ci| {
        if (c0.group != ci) continue;
        var box = geom.Box.empty;
        for (cells.items) |c| if (c.group == ci) {
            box.extend(.init(c.x * cell, c.y * cell));
            box.extend(.init((c.x + 1) * cell, (c.y + 1) * cell));
        };
        try boxes.append(s, grown(box, w));
    }
    return boxes.items;
}

fn boxPath(s: Allocator, b: geom.Box) Allocator.Error!Paths {
    var out: Paths = .empty;
    try out.append(s, &.{ b.min, .init(b.max.x, b.min.y), b.max, .init(b.min.x, b.max.y) });
    return out;
}

fn grown(b: geom.Box, d: i64) geom.Box {
    return .{ .min = .init(b.min.x - d, b.min.y - d), .max = .init(b.max.x + d, b.max.y + d) };
}

/// Each polygon of `paths` cut to the box `b` (Sutherland and Hodgman).
/// A polygon that leaves the box and comes back gets an edge of zero
/// width along the side of the box, in the margin of `wallGap`.
fn cutToBox(s: Allocator, paths: Paths, b: geom.Box) Allocator.Error!Paths {
    var out: Paths = .empty;
    var cur: std.ArrayList(Point) = .empty;
    var nxt: std.ArrayList(Point) = .empty;
    for (0..paths.count()) |k| {
        const poly = paths.get(k);
        var pb = geom.Box.empty;
        for (poly) |q| pb.extend(q);
        if (pb.max.x < b.min.x or pb.min.x > b.max.x or pb.max.y < b.min.y or pb.min.y > b.max.y) continue;
        cur.clearRetainingCapacity();
        try cur.appendSlice(s, poly);
        for (0..4) |side| {
            nxt.clearRetainingCapacity();
            if (cur.items.len == 0) break;
            var prev = cur.items[cur.items.len - 1];
            for (cur.items) |q| {
                defer prev = q;
                const in_q = inSide(q, b, side);
                const in_p = inSide(prev, b, side);
                if (in_q != in_p) try nxt.append(s, crossSide(prev, q, b, side));
                if (in_q) try nxt.append(s, q);
            }
            std.mem.swap(std.ArrayList(Point), &cur, &nxt);
        }
        if (cur.items.len >= 3) try out.append(s, cur.items);
    }
    return out;
}

fn inSide(p: Point, b: geom.Box, side: usize) bool {
    return switch (side) {
        0 => p.x >= b.min.x,
        1 => p.x <= b.max.x,
        2 => p.y >= b.min.y,
        else => p.y <= b.max.y,
    };
}

fn crossSide(p: Point, q: Point, b: geom.Box, side: usize) Point {
    const px: f64 = @floatFromInt(p.x);
    const py: f64 = @floatFromInt(p.y);
    const qx: f64 = @floatFromInt(q.x);
    const qy: f64 = @floatFromInt(q.y);
    return switch (side) {
        0, 1 => blk: {
            const x: f64 = @floatFromInt(if (side == 0) b.min.x else b.max.x);
            break :blk pt(x, py + (x - px) / (qx - px) * (qy - py));
        },
        else => blk: {
            const y: f64 = @floatFromInt(if (side == 2) b.min.y else b.max.y);
            break :blk pt(px + (y - py) / (qy - py) * (qx - px), y);
        },
    };
}

/// The points along the loops of `ref`, at most half a line apart, that
/// are more than `tol` (micrometers) from the edges in `idx` (all points
/// if `idx` is null). For a wall, `ref` is the outline or the wall before
/// it, and `idx` has the loops of the wall, `d` inside `ref`: where the
/// wall follows `ref`, all points are `d` from it. At a convex corner of
/// `ref`, the points nearer to the corner than d tan(a / 2) (a: the turn
/// of the corner) are not tested: their distance to the wall is more than
/// `d` there.
fn farPoints(s: Allocator, ref: Paths, idx: ?*const geom.EdgeIndex, tol: i64, d: i64, w: i64) Allocator.Error![]const Point {
    var out: std.ArrayList(Point) = .empty;
    const step: f64 = @floatFromInt(@divTrunc(w, 2));
    const df: f64 = @floatFromInt(d);
    for (0..ref.count()) |k| {
        const poly = ref.get(k);
        const n = poly.len;
        if (n < 3) continue;
        for (0..n) |i| {
            const a = poly[i];
            const b = poly[(i + 1) % n];
            const len = a.dist(b);
            const s0 = df * cornerTan(poly[(i + n - 1) % n], a, b);
            const s1 = df * cornerTan(a, b, poly[(i + 2) % n]);
            if (s0 + s1 >= len) continue;
            const span = len - s0 - s1;
            const m = @max(1, @ceil(span / step));
            var j: f64 = 0;
            while (j <= m) : (j += 1) {
                const t = (s0 + span * j / m) / len;
                const p = pt(@as(f64, @floatFromInt(a.x)) + t * @as(f64, @floatFromInt(b.x - a.x)), @as(f64, @floatFromInt(a.y)) + t * @as(f64, @floatFromInt(b.y - a.y)));
                if (idx == null or !idx.?.near(p, tol)) try out.append(s, p);
            }
        }
    }
    return out.items;
}

/// tan(a / 2), with a the turn at `v` from `prev` to `next`, for a left
/// turn (a convex corner: the part is on the left of its loops). 0 for a
/// right turn, and a large value for a turn of more than 170 degrees.
fn cornerTan(prev: Point, v: Point, next: Point) f64 {
    const ax: f64 = @floatFromInt(v.x - prev.x);
    const ay: f64 = @floatFromInt(v.y - prev.y);
    const bx: f64 = @floatFromInt(next.x - v.x);
    const by: f64 = @floatFromInt(next.y - v.y);
    const cross = ax * by - ay * bx;
    if (cross <= 0) return 0;
    const angle = std.math.atan2(cross, ax * bx + ay * by);
    if (angle > std.math.degreesToRadians(170)) return 1e9;
    return @tan(angle / 2);
}

fn mid(p: Point, q: Point) Point {
    return .{ .x = @divTrunc(p.x + q.x, 2), .y = @divTrunc(p.y + q.y, 2) };
}

fn pt(x: f64, y: f64) Point {
    return .{ .x = @intFromFloat(geom.round(x)), .y = @intFromFloat(geom.round(y)) };
}

/// The gap fill lines of `gaps` (the areas to fill) for a line width of
/// `w` (micrometers). The memory is in `a`, an arena.
pub fn centerLines(a: Allocator, gaps: Paths, w: i64) Allocator.Error!Fill {
    if (gaps.isEmpty()) return .{};
    // Most gaps are small: the sawtooth of the skin line ends along a
    // wall, the corners of the walls. Arachne would remove them (see
    // `walls.generate`), but at a cost. An area smaller than a square of
    // half a line goes here. A hole stays if an area that stays can hold
    // it.
    const half = geom.toMm(@divTrunc(w, 2));
    const min_area = half * half;
    var kept: Paths = .empty;
    var box_of: std.ArrayList(geom.Box) = .empty;
    for (0..gaps.count()) |k| {
        const poly = gaps.get(k);
        if (geom.areaMm2(poly) < min_area) continue;
        try kept.append(a, poly);
        var b = geom.Box.empty;
        for (poly) |q| b.extend(q);
        try box_of.append(a, b);
    }
    if (kept.isEmpty()) return .{};
    for (0..gaps.count()) |k| {
        const poly = gaps.get(k);
        if (geom.area2(poly) >= 0) continue;
        var b = geom.Box.empty;
        for (poly) |q| b.extend(q);
        for (box_of.items) |o| if (o.min.x <= b.min.x and o.min.y <= b.min.y and o.max.x >= b.max.x and o.max.y >= b.max.y) {
            try kept.append(a, poly);
            break;
        };
    }
    const quarter = @divTrunc(w, 4);
    const params: arachne.walls.Params = .{
        .walls = .{
            .bead_width_0 = w,
            .bead_width_x = w,
            .inset_count = 1,
            .min_feature_size = quarter,
            .min_bead_width = quarter,
            .wall_transition_length = w,
            .wall_transition_angle_deg = 45,
            .min_even_wall_line_width = quarter,
            .min_odd_wall_line_width = quarter,
        },
    };
    const res = arachne.walls.generate(a, kept, params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A shape that the Voronoi diagram cannot take (a sliver, points
        // on a line): no gap fill there.
        else => return .{},
    };
    var out: Fill = .{};
    var loop_w: std.ArrayList(f32) = .empty;
    var line_w: std.ArrayList(f32) = .empty;
    for (res.insets) |inset| for (inset.items) |line| {
        var js = line.junctions.items;
        // A loop ends with its first point again.
        var closed = line.is_closed;
        if (closed and js.len > 1 and js[0].p.eql(js[js.len - 1].p)) js = js[0 .. js.len - 1];
        if (js.len < 2) continue;
        // Arachne joins the ends of a line that are near each other into
        // a loop. If the join goes out of the gap (across the tip of a
        // wall), the line stays open.
        if (closed and !geom.insideAny(kept, mid(js[js.len - 1].p, js[0].p))) closed = false;
        if (closed and js.len < 3) continue;
        // A line shorter than a quarter of a line width, or a loop shorter
        // than one line width, is a dot: skip it.
        var len: f64 = 0;
        for (1..js.len) |k| len += js[k - 1].p.dist(js[k].p);
        if (len < @as(f64, @floatFromInt(if (closed) w else quarter))) continue;
        const paths = if (closed) &out.loops else &out.lines;
        const widths = if (closed) &loop_w else &line_w;
        for (js) |j| {
            try paths.appendPoint(a, j.p);
            try widths.append(a, @floatCast(geom.toMm(j.w)));
        }
        try paths.endPath(a, 0);
    };
    out.loop_widths = loop_w.items;
    out.line_widths = line_w.items;
    return out;
}

const testing = std.testing;

test "a narrow strip gets one line along its middle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 10 mm long, 0.3 mm wide.
    var gaps: Paths = .empty;
    try gaps.append(a, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 300), .init(0, 300) });
    const f = try centerLines(a, gaps, 500);
    try testing.expect(f.loops.isEmpty());
    try testing.expectEqual(@as(usize, 1), f.lines.count());
    for (f.lines.get(0)) |p| try testing.expect(@abs(p.y - 150) <= 5);
    for (f.line_widths) |wd| try testing.expect(@abs(wd - 0.3) < 0.02);
}

test "a sliver gets no line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 0.1 mm wide: narrower than a quarter of a 0.5 mm line.
    var gaps: Paths = .empty;
    try gaps.append(a, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 100), .init(0, 100) });
    const f = try centerLines(a, gaps, 500);
    try testing.expect(f.isEmpty());
}

test "the footprint of a line is a rectangle with square ends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: Paths = .empty;
    try lines.append(a, &.{ .init(0, 0), .init(1000, 0) });
    var out: Paths = .empty;
    try addFootprint(a, &out, lines, &.{}, 400, 0);
    try testing.expectEqual(@as(usize, 1), out.count());
    try testing.expect(geom.area2(out.get(0)) > 0);
    // (1000 + 400) x 400.
    try testing.expectApproxEqAbs(@as(f64, 0.56), out.areaMm2(), 1e-6);
}

test "a crescent between two walls gets a line inside it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The gap where the inner walls of two holes meet: a V on one side,
    // an arc on the other, and two thin horns.
    var gaps: Paths = .empty;
    try gaps.append(a, &.{ .init(120896, 113312), .init(121460, 113922), .init(122500, 115520), .init(123540, 113922), .init(124104, 113312), .init(123543, 113920), .init(123090, 114614), .init(122759, 115373), .init(122555, 116174), .init(122500, 116842), .init(122445, 116174), .init(122241, 115373), .init(121910, 114614), .init(121457, 113920) });
    const f = try centerLines(a, gaps, 500);
    try testing.expect(!f.isEmpty());
    // No segment goes out of the gap.
    for ([_]Paths{ f.loops, f.lines }, [_]bool{ true, false }) |set, closed| {
        for (0..set.count()) |k| {
            const pts = set.get(k);
            const n = if (closed) pts.len else pts.len - 1;
            for (0..n) |j| try testing.expect(geom.insideAny(gaps, mid(pts[j], pts[(j + 1) % pts.len])));
        }
    }
}
