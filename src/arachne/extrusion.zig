//! Variable-width extrusion lines, and the steps that clean them up.
//!
//! An extrusion line is a list of junctions. Each junction has a point,
//! the bead width at that point, and the index of its wall (0 is the outer
//! wall). An "odd" line is a single bead in the middle of a part (a gap
//! filler); it has no direction. An even line is one side of a wall loop,
//! and keeps its direction.
//!
//! - `stitch` joins the pieces of each wall that Arachne makes, end to end,
//!   into longer lines and closed loops. From the end of the chain, it
//!   takes the nearest end of another piece (with a grid of the ends). It
//!   reverses only odd pieces. A chain whose end comes back to its start
//!   closes into a loop.
//! - `simplify` removes junctions that change the shape by less than the
//!   maximum deviation and that sit on short segments. It keeps a junction
//!   if its removal changes the extruded area by more than the maximum
//!   area deviation (a width change along a straight line).
//!
//! This file is a port to Zig of CuraEngine
//! (https://github.com/Ultimaker/CuraEngine, commit
//! 5eff812d2124b2eb93f832e92d33ccdba721135b): `ExtrusionJunction`,
//! `ExtrusionLine` (`src/types/geometry/ExtrusionLine.cpp`),
//! `PolylineStitcher` (`src/types/geometry/PolylineStitcher.cpp`), and the
//! extrusion line parts of `Simplify` (`src/types/geometry/Simplify.cpp`).
//!
//! Copyright (c) 2026 UltiMaker. CuraEngine is released under the terms of
//! the AGPLv3 or higher. This port is part of zslice (AGPL-3.0-or-later).
//! See docs/references/cura.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("../geom.zig");
const Point = geom.Point;

pub const Junction = struct {
    /// The center of the line at this junction.
    p: Point,
    /// The width of the line at this junction, in micrometers.
    w: i64,
    /// The wall of the junction: 0 is the outer wall.
    perimeter_index: u32,

    pub fn eql(a: Junction, b: Junction) bool {
        return a.p.eql(b.p) and a.w == b.w and a.perimeter_index == b.perimeter_index;
    }
};

pub const Line = struct {
    junctions: std.ArrayList(Junction) = .empty,
    /// The wall of the line: 0 is the outer wall.
    inset_idx: u32,
    /// A single bead along the middle of a part (a gap filler).
    is_odd: bool,
    /// The line is a loop: the last junction connects to the first.
    is_closed: bool = false,

    pub fn items(l: Line) []Junction {
        return l.junctions.items;
    }

    pub fn length(l: Line) i64 {
        const js = l.junctions.items;
        if (js.len == 0) return 0;
        var len: i64 = 0;
        for (js[1..], js[0 .. js.len - 1]) |b, a| len += vSize(b.p.sub(a.p));
        if (l.is_closed) len += vSize(js[0].p.sub(js[js.len - 1].p));
        return len;
    }

    /// True if the line, with the segment from its last junction back to
    /// its first, is shorter than `check_length`.
    pub fn shorterThan(l: Line, check_length: i64) bool {
        const js = l.junctions.items;
        if (js.len == 0) return true;
        var p0 = js[js.len - 1].p;
        var len: i64 = 0;
        for (js) |j| {
            len += vSize(p0.sub(j.p));
            if (len >= check_length) return false;
            p0 = j.p;
        }
        return true;
    }

    pub fn minWidth(l: Line) i64 {
        var m: i64 = std.math.maxInt(i64);
        for (l.junctions.items) |j| m = @min(m, j.w);
        return m;
    }

    pub fn reverse(l: *Line) void {
        std.mem.reverse(Junction, l.junctions.items);
    }
};

/// The lines of one wall (CuraEngine `VariableWidthLines`).
pub const Lines = std.ArrayList(Line);

/// The length of a vector, rounded (CuraEngine `vSize`).
pub fn vSize(v: Point) i64 {
    const x: f64 = @floatFromInt(v.x);
    const y: f64 = @floatFromInt(v.y);
    return @intFromFloat(@round(@sqrt(x * x + y * y)));
}

pub fn vSize2(v: Point) i64 {
    return v.x * v.x + v.y * v.y;
}

/// A uniform grid of the end points of lines, for the nearest end search.
const EndGrid = struct {
    const Entry = struct { key: u64, line: u32, at_end: bool };
    cell: i64,
    entries: []Entry,

    fn key(cell: i64, p: Point) u64 {
        const cx: i64 = @divFloor(p.x, cell);
        const cy: i64 = @divFloor(p.y, cell);
        const ux: u64 = @bitCast(cx);
        const uy: u64 = @bitCast(cy);
        return (ux *% 0x9E3779B97F4A7C15) ^ uy;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.key != b.key) return a.key < b.key;
        if (a.line != b.line) return a.line < b.line;
        return @intFromBool(a.at_end) < @intFromBool(b.at_end);
    }

    fn init(a: Allocator, lines: []const Line, cell: i64) Allocator.Error!EndGrid {
        const entries = try a.alloc(Entry, 2 * lines.len);
        for (lines, 0..) |l, i| {
            const js = l.junctions.items;
            entries[2 * i] = .{ .key = key(cell, js[0].p), .line = @intCast(i), .at_end = false };
            entries[2 * i + 1] = .{ .key = key(cell, js[js.len - 1].p), .line = @intCast(i), .at_end = true };
        }
        std.mem.sort(Entry, entries, {}, lessThan);
        return .{ .cell = cell, .entries = entries };
    }

    /// The entries of the cell of `p`.
    fn cellOf(g: EndGrid, k: u64) []const Entry {
        var lo: usize = 0;
        var hi: usize = g.entries.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (g.entries[mid].key < k) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < g.entries.len and g.entries[end].key == k) end += 1;
        return g.entries[lo..end];
    }
};

/// Joins the lines of one wall into longer lines (`result_lines`) and
/// loops (`result_loops`). Only gaps of at most `max_stitch_distance` are
/// joined; ends closer than `snap_distance` are the same point.
pub fn stitch(a: Allocator, lines: []const Line, result_lines: *Lines, result_loops: *Lines, max_stitch_distance: i64, snap_distance: i64) Allocator.Error!void {
    if (lines.len == 0) return;
    for (lines) |l| std.debug.assert(l.junctions.items.len > 0);
    const grid = try EndGrid.init(a, lines, @max(max_stitch_distance, 1));
    const processed = try a.alloc(bool, lines.len);
    @memset(processed, false);
    for (lines, 0..) |line, line_idx| {
        if (processed[line_idx]) continue;
        processed[line_idx] = true;
        var should_close = line.is_odd;
        var chain: Line = .{ .inset_idx = line.inset_idx, .is_odd = line.is_odd, .is_closed = line.is_closed };
        try chain.junctions.appendSlice(a, line.junctions.items);
        var closest_is_closing_polygon = false;
        for ([_]bool{ false, true }) |go_in_reverse_direction| {
            // First extend the chain forward, so that it rarely needs a
            // reverse.
            if (go_in_reverse_direction) chain.reverse();
            var chain_length = chain.length();
            while (true) {
                const from = chain.junctions.items[chain.junctions.items.len - 1].p;
                var closest: ?EndGrid.Entry = null;
                var closest_distance: i64 = std.math.maxInt(i64);
                const r = max_stitch_distance;
                const c0x = @divFloor(from.x - r, grid.cell);
                const c1x = @divFloor(from.x + r, grid.cell);
                const c0y = @divFloor(from.y - r, grid.cell);
                const c1y = @divFloor(from.y + r, grid.cell);
                var cx = c0x;
                search: while (cx <= c1x) : (cx += 1) {
                    var cy = c0y;
                    while (cy <= c1y) : (cy += 1) {
                        const k = EndGrid.key(grid.cell, .{ .x = cx * grid.cell, .y = cy * grid.cell });
                        for (grid.cellOf(k)) |nearby| {
                            const nl = lines[nearby.line];
                            const np = if (nearby.at_end) nl.junctions.items[nl.junctions.items.len - 1].p else nl.junctions.items[0].p;
                            // A hash collision can put another cell here.
                            if (@divFloor(np.x, grid.cell) != cx or @divFloor(np.y, grid.cell) != cy) continue;
                            var is_closing_segment = false;
                            var dist = vSize(np.sub(from));
                            if (dist > max_stitch_distance) continue;
                            if (vSize2(np.sub(chain.junctions.items[0].p)) < snap_distance * snap_distance) {
                                // Do not close a small loop: it can be part of
                                // a larger line. Do not make 2-point loops.
                                if (chain_length + dist < 3 * max_stitch_distance or chain.junctions.items.len <= 2) continue;
                                is_closing_segment = true;
                                // Prefer to continue a line over a close, so
                                // that zigzags do not close. Prefer to close
                                // a loop of even lines.
                                if (!should_close) dist += 10 else dist -= 10;
                            } else if (processed[nearby.line]) {
                                continue;
                            }
                            var would_reverse = nearby.at_end;
                            would_reverse = would_reverse != go_in_reverse_direction;
                            if (!nl.is_odd and would_reverse) continue;
                            if (chain.is_odd != nl.is_odd) continue;
                            if (dist < closest_distance) {
                                closest_distance = dist;
                                closest = nearby;
                                closest_is_closing_polygon = is_closing_segment;
                            }
                            // A good enough next line.
                            if (dist < snap_distance) break :search;
                        }
                    }
                }
                const c = closest orelse break;
                if (closest_is_closing_polygon) break;
                const nl = lines[c.line];
                const njs = nl.junctions.items;
                const segment_dist = vSize(chain.junctions.items[chain.junctions.items.len - 1].p.sub(if (c.at_end) njs[njs.len - 1].p else njs[0].p));
                const old_size = chain.junctions.items.len;
                const skip: usize = @intFromBool(segment_dist < snap_distance);
                if (!c.at_end) {
                    try chain.junctions.appendSlice(a, njs[skip..]);
                } else {
                    var o = njs.len - skip;
                    while (o > 0) {
                        o -= 1;
                        try chain.junctions.append(a, njs[o]);
                    }
                }
                for (old_size..chain.junctions.items.len) |q| chain_length += vSize(chain.junctions.items[q].p.sub(chain.junctions.items[q - 1].p));
                // An even line joined to an odd line does not close.
                should_close = should_close and !nl.is_odd;
                std.debug.assert(!processed[c.line]);
                processed[c.line] = true;
            }
            if (closest_is_closing_polygon) {
                // Keep the original direction.
                if (go_in_reverse_direction) chain.reverse();
                break;
            }
        }
        if (closest_is_closing_polygon) {
            try result_loops.append(a, chain);
        } else {
            // The second pass reversed the chain. A line that must keep its
            // direction goes back.
            if (!line.is_odd) chain.reverse();
            try result_lines.append(a, chain);
        }
    }
}

/// The parameters of `simplify` (CuraEngine `meshfix_maximum_resolution`,
/// `meshfix_maximum_deviation`, and
/// `meshfix_maximum_extrusion_area_deviation`).
pub const SimplifyParams = struct {
    max_resolution: i64 = 500,
    max_deviation: i64 = 25,
    max_area_deviation: i64 = 50000,
};

const min_resolution: i64 = 5;

/// The line with fewer junctions. The result is empty if the line is too
/// small: fewer than 3 junctions for a loop, 2 for an open line.
pub fn simplify(a: Allocator, line: Line, sp: SimplifyParams) Allocator.Error!Line {
    const is_closed = line.is_closed;
    const min_size: usize = if (is_closed) 3 else 2;
    var empty: Line = .{ .inset_idx = line.inset_idx, .is_odd = line.is_odd, .is_closed = line.is_closed };
    if (detectSmall(line.junctions.items, min_size)) return empty;
    if (line.junctions.items.len == min_size) {
        try empty.junctions.appendSlice(a, line.junctions.items);
        return empty;
    }
    const result = try a.dupe(Junction, line.junctions.items);
    const n = result.len;
    const to_delete = try a.alloc(bool, n);
    @memset(to_delete, false);
    const Item = struct { idx: usize, imp: i64 };
    const Cmp = struct {
        fn order(_: void, x: Item, y: Item) std.math.Order {
            if (x.imp != y.imp) return std.math.order(x.imp, y.imp);
            return std.math.order(x.idx, y.idx);
        }
    };
    var queue: std.PriorityQueue(Item, void, Cmp.order) = .empty;
    var current_removed: i64 = -1;
    while (@as(i64, @intCast(n)) - current_removed > min_size and current_removed != 0) {
        current_removed = 0;
        for (0..n) |i| {
            if (to_delete[i]) continue;
            try queue.push(a, .{ .idx = i, .imp = importance(result, to_delete, i, is_closed, sp) });
        }
        while (queue.count() > 0 and @as(i64, @intCast(n)) - current_removed > min_size) {
            const v = queue.pop().?;
            // The importance can have changed since the push. Use it only if
            // it is the same.
            const imp = importance(result, to_delete, v.idx, is_closed, sp);
            if (imp != v.imp) {
                try queue.push(a, .{ .idx = v.idx, .imp = imp });
                continue;
            }
            if (imp <= sp.max_deviation * sp.max_deviation) {
                if (remove(result, to_delete, v.idx, imp, is_closed, sp)) current_removed += 1;
            }
        }
    }
    for (result, to_delete) |j, d| {
        if (!d) try empty.junctions.append(a, j);
    }
    if (detectSmall(empty.junctions.items, min_size)) empty.junctions.clearRetainingCapacity();
    return empty;
}

fn detectSmall(js: []const Junction, min_size: usize) bool {
    if (js.len < min_size) return true;
    if (js.len == min_size) {
        const pa = js[0].p;
        const pb = js[1].p;
        const pc = js[js.len - 1].p;
        const m = @max(@max(vSize2(pb.sub(pa)), vSize2(pc.sub(pa))), vSize2(pc.sub(pb)));
        if (m < min_resolution * min_resolution) return true;
    }
    return false;
}

fn nextNotDeleted(index: usize, to_delete: []const bool) usize {
    const size = to_delete.len;
    var i = (index + 1) % size;
    while (to_delete[i]) i = (i + 1) % size;
    return i;
}

fn previousNotDeleted(index: usize, to_delete: []const bool) usize {
    const size = to_delete.len;
    var i = (index + size - 1) % size;
    while (to_delete[i]) i = (i + size - 1) % size;
    return i;
}

/// The change of the extruded area if `vertex` goes and the line from
/// `before` to `after` gets the mean width (by length) of the two segments.
fn areaDeviation(before: Junction, vertex: Junction, after: Junction) i64 {
    const ab_length = vSize(vertex.p.sub(before.p));
    const bc_length = vSize(after.p.sub(vertex.p));
    const ac_length = vSize(after.p.sub(before.p));
    // A segment of length 0 is not printed: no deviation.
    if (ab_length == 0 or ac_length == 0 or bc_length == 0) return 0;
    const width_diff = @max(@abs(vertex.w - before.w), @abs(after.w - vertex.w));
    if (width_diff > 1) {
        const ab_weight = @divTrunc(before.w + vertex.w, 2);
        const bc_weight = @divTrunc(vertex.w + after.w, 2);
        const weighted_average_width = @divTrunc(ab_length * ab_weight + bc_length * bc_weight, ac_length);
        return @as(i64, @intCast(@abs(ab_weight - weighted_average_width))) * ab_length + @as(i64, @intCast(@abs(bc_weight - weighted_average_width))) * bc_length;
    }
    // A very small width change: the width of the longer segment.
    const wd: i64 = @intCast(width_diff);
    return if (ab_length > bc_length) wd * bc_length else wd * ab_length;
}

fn importance(js: []const Junction, to_delete: []const bool, index: usize, is_closed: bool, sp: SimplifyParams) i64 {
    const n = js.len;
    // The ends of an open line stay.
    if (!is_closed and (index == 0 or index == n - 1)) return std.math.maxInt(i64);
    const before_index = previousNotDeleted(index, to_delete);
    const after_index = nextNotDeleted(index, to_delete);
    const area_deviation = areaDeviation(js[before_index], js[index], js[after_index]);
    // The removal flattens a width change too much.
    if (area_deviation > sp.max_area_deviation) return std.math.maxInt(i64);
    const vertex = js[index].p;
    const before = js[before_index].p;
    const after = js[after_index].p;
    const deviation2 = dist2FromLine(vertex, before, after);
    // A deviation this small always goes.
    if (deviation2 <= min_resolution * min_resolution) return deviation2;
    // Long segments on both sides: keep it.
    if (vSize2(before.sub(vertex)) > sp.max_resolution * sp.max_resolution and vSize2(after.sub(vertex)) > sp.max_resolution * sp.max_resolution) return std.math.maxInt(i64);
    return deviation2;
}

fn remove(js: []Junction, to_delete: []bool, vertex: usize, deviation2: i64, is_closed: bool, sp: SimplifyParams) bool {
    // Below the minimum resolution, a vertex always goes, also between long
    // segments.
    if (deviation2 <= min_resolution * min_resolution) {
        to_delete[vertex] = true;
        return true;
    }
    const before = previousNotDeleted(vertex, to_delete);
    const after = nextNotDeleted(vertex, to_delete);
    const vp = js[vertex].p;
    const bp = js[before].p;
    const ap = js[after].p;
    const length2_before = vSize2(vp.sub(bp));
    const length2_after = vSize2(vp.sub(ap));
    const mr2 = sp.max_resolution * sp.max_resolution;
    // Both segments are short: no long line moves.
    if (length2_before <= mr2 and length2_after <= mr2) {
        to_delete[vertex] = true;
        return true;
    }
    // One segment is long and the other short. Replace the short segment
    // with the crossing of the two segments around it.
    var before_from: Point = undefined;
    var before_to: Point = undefined;
    var after_from: Point = undefined;
    var after_to: Point = undefined;
    if (length2_before <= length2_after) {
        if (!is_closed and before == 0) return false;
        const before_before = previousNotDeleted(before, to_delete);
        before_from = js[before_before].p;
        before_to = js[before].p;
        after_from = js[vertex].p;
        after_to = js[after].p;
    } else {
        if (!is_closed and after == js.len - 1) return false;
        const after_after = nextNotDeleted(after, to_delete);
        before_from = js[before].p;
        before_to = js[vertex].p;
        after_from = js[after].p;
        after_to = js[after_after].p;
    }
    const intersection = lineLineIntersection(before_from, before_to, after_from, after_to) orelse return false;
    const intersection_deviation = dist2FromLineSegment(before_to, intersection, after_from);
    if (intersection_deviation <= sp.max_deviation * sp.max_deviation) {
        to_delete[vertex] = true;
        const at = if (length2_before <= length2_after) before else after;
        // The mean width of the two sides.
        js[at] = .{ .p = intersection, .w = @divTrunc(js[before].w + js[after].w, 2), .perimeter_index = js[before].perimeter_index };
        return true;
    }
    return false;
}

/// The squared distance from p to the line through a and b (CuraEngine
/// `LinearAlg2D::getDist2FromLine`).
pub fn dist2FromLine(p: Point, a: Point, b: Point) i64 {
    const vab = b.sub(a);
    const vap = p.sub(a);
    const ab_len2: f64 = @floatFromInt(vSize2(vab));
    if (ab_len2 == 0) return vSize2(vap);
    const dott: f64 = @floatFromInt(geom.mulAdd(vab.x, vap.x, vab.y, vap.y));
    const ap_len2: f64 = @floatFromInt(vSize2(vap));
    const ax_len2 = dott * dott / ab_len2;
    const px_len2 = ap_len2 - ax_len2;
    return @intFromFloat(@max(0.0, px_len2));
}

/// The squared distance from p to the segment from a to b (CuraEngine
/// `LinearAlg2D::getDist2FromLineSegment`, with p as the second argument).
pub fn dist2FromLineSegment(a: Point, p: Point, b: Point) i64 {
    const vab = b.sub(a);
    const vap = p.sub(a);
    const ab_len2: i128 = geom.mulAdd(vab.x, vab.x, vab.y, vab.y);
    const dott: i128 = geom.mulAdd(vab.x, vap.x, vab.y, vap.y);
    if (dott <= 0) return vSize2(vap);
    if (dott >= ab_len2) return vSize2(p.sub(b));
    // The closest point on the segment.
    const t = @as(f64, @floatFromInt(dott)) / @as(f64, @floatFromInt(ab_len2));
    const qx = @as(f64, @floatFromInt(a.x)) + @as(f64, @floatFromInt(vab.x)) * t;
    const qy = @as(f64, @floatFromInt(a.y)) + @as(f64, @floatFromInt(vab.y)) * t;
    const dx = @as(f64, @floatFromInt(p.x)) - qx;
    const dy = @as(f64, @floatFromInt(p.y)) - qy;
    return @intFromFloat(dx * dx + dy * dy);
}

/// The crossing of the lines through a1 a2 and b1 b2, or null if they are
/// parallel.
pub fn lineLineIntersection(a1: Point, a2: Point, b1: Point, b2: Point) ?Point {
    const x1: f64 = @floatFromInt(a1.x);
    const y1: f64 = @floatFromInt(a1.y);
    const x2: f64 = @floatFromInt(a2.x);
    const y2: f64 = @floatFromInt(a2.y);
    const x3: f64 = @floatFromInt(b1.x);
    const y3: f64 = @floatFromInt(b1.y);
    const x4: f64 = @floatFromInt(b2.x);
    const y4: f64 = @floatFromInt(b2.y);
    const d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
    if (d == 0) return null;
    const t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d;
    const x = x1 + t * (x2 - x1);
    const y = y1 + t * (y2 - y1);
    if (!(@abs(x) < 1e15 and @abs(y) < 1e15)) return null;
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

const testing = std.testing;

fn testLine(a: Allocator, pts: []const [2]i64, odd: bool) !Line {
    var l: Line = .{ .inset_idx = 0, .is_odd = odd };
    for (pts) |q| try l.junctions.append(a, .{ .p = .{ .x = q[0], .y = q[1] }, .w = 400, .perimeter_index = 0 });
    return l;
}

test "stitch joins pieces into a loop" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A square in four pieces, one piece reversed. The even pieces keep
    // their direction, so the reversed one stays a line.
    var lines: Lines = .empty;
    try lines.append(a, try testLine(a, &.{ .{ 0, 0 }, .{ 10000, 0 } }, false));
    try lines.append(a, try testLine(a, &.{ .{ 10000, 0 }, .{ 10000, 10000 } }, false));
    try lines.append(a, try testLine(a, &.{ .{ 10000, 10000 }, .{ 0, 10000 } }, false));
    try lines.append(a, try testLine(a, &.{ .{ 0, 10000 }, .{ 0, 0 } }, false));
    var out_lines: Lines = .empty;
    var out_loops: Lines = .empty;
    try stitch(a, lines.items, &out_lines, &out_loops, 399, 10);
    try testing.expectEqual(@as(usize, 0), out_lines.items.len);
    try testing.expectEqual(@as(usize, 1), out_loops.items.len);
    // As in CuraEngine, the loop ends with its first point again.
    try testing.expectEqual(@as(usize, 5), out_loops.items[0].junctions.items.len);
}

test "simplify removes collinear junctions and keeps width changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try testLine(a, &.{ .{ 0, 0 }, .{ 100, 1 }, .{ 200, 0 }, .{ 300, 0 } }, true);
    const s = try simplify(a, l, .{});
    try testing.expectEqual(@as(usize, 2), s.junctions.items.len);
    // A large width change in the middle of a long line stays.
    l = try testLine(a, &.{ .{ 0, 0 }, .{ 10000, 0 }, .{ 20000, 0 } }, true);
    l.junctions.items[2].w = 800;
    const s2 = try simplify(a, l, .{});
    try testing.expectEqual(@as(usize, 3), s2.junctions.items.len);
}
