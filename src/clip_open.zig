//! Clip open polylines to a region: keep the parts of each polyline that
//! are inside the region.
//!
//! Infill patterns that are not straight lines (gyroid curves, honeycomb
//! zigzags) are made for the whole bounding box of a region, then clipped.
//!
//! The method:
//!
//! 1. Put the region edges in a uniform grid (as in `clip.zig`).
//! 2. For each segment of each polyline, find the region edges in the grid
//!    cells along the segment, and the points where they cross the
//!    segment. Split the segment at these points.
//! 3. A piece between two split points is wholly inside or wholly outside.
//!    The code tests the middle of each piece with a ray (the winding
//!    number, with the non-zero rule).
//! 4. Join pieces that are inside and that touch into one output polyline.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const scratch = @import("scratch.zig");
const Point = geom.Point;
const Paths = geom.Paths;

const Edge = struct { a: Point, b: Point };

/// Returns the parts of `lines` (open polylines) inside `region` (closed
/// polygons, non-zero rule). Parts shorter than `min_length` are removed.
pub fn clipPolylines(gpa: Allocator, region: Paths, lines: Paths, min_length: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    if (region.isEmpty() or lines.isEmpty()) return out;

    var arena_state = scratch.get(gpa);
    defer arena_state.release();
    const arena = arena_state.allocator();

    // Step 1.
    var edges: std.ArrayList(Edge) = .empty;
    var box = geom.Box.empty;
    var total: f64 = 0;
    for (0..region.count()) |i| {
        const poly = region.get(i);
        if (poly.len < 2) continue;
        var prev = poly[poly.len - 1];
        for (poly) |p| {
            if (!p.eql(prev)) {
                try edges.append(arena, .{ .a = prev, .b = p });
                box.extend(p);
                total += prev.dist(p);
            }
            prev = p;
        }
    }
    if (edges.items.len == 0) return out;
    const grid = try Grid.build(arena, edges.items, box, total / @as(f64, @floatFromInt(edges.items.len)));

    // Steps 2 to 4.
    var ts: std.ArrayList(f64) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var cur: std.ArrayList(Point) = .empty;
    for (0..lines.count()) |li| {
        const pl = lines.get(li);
        cur.clearRetainingCapacity();
        for (0..pl.len -| 1) |si| {
            const a = pl[si];
            const b = pl[si + 1];
            if (a.eql(b)) continue;
            // The split parameters along a -> b, from 0 to 1.
            ts.clearRetainingCapacity();
            seen.clearRetainingCapacity();
            try ts.append(arena, 0);
            try ts.append(arena, 1);
            var cells: std.ArrayList(usize) = .empty;
            try grid.cellsOf(arena, a, b, &cells);
            for (cells.items) |cell| {
                for (grid.edgesIn(cell)) |ei| {
                    const gop = try seen.getOrPut(arena, ei);
                    if (gop.found_existing) continue;
                    if (crossParam(a, b, edges.items[ei])) |t| try ts.append(arena, t);
                }
            }
            std.mem.sortUnstable(f64, ts.items, {}, std.sort.asc(f64));
            var k: usize = 0;
            while (k + 1 < ts.items.len) : (k += 1) {
                const t0 = ts.items[k];
                const t1 = ts.items[k + 1];
                if (t1 - t0 < 1e-12) continue;
                const p0 = lerp(a, b, t0);
                const p1 = lerp(a, b, t1);
                const mid_x = (@as(f64, @floatFromInt(p0.x)) + @as(f64, @floatFromInt(p1.x))) / 2;
                const mid_y = (@as(f64, @floatFromInt(p0.y)) + @as(f64, @floatFromInt(p1.y))) / 2;
                if (grid.inside(edges.items, mid_x, mid_y)) {
                    if (cur.items.len == 0 or !cur.items[cur.items.len - 1].eql(p0)) {
                        try flush(gpa, &out, &cur, min_length);
                        try cur.append(arena, p0);
                    }
                    try cur.append(arena, p1);
                } else {
                    try flush(gpa, &out, &cur, min_length);
                }
            }
        }
        try flush(gpa, &out, &cur, min_length);
    }
    return out;
}

fn flush(gpa: Allocator, out: *Paths, cur: *std.ArrayList(Point), min_length: i64) !void {
    defer cur.clearRetainingCapacity();
    if (cur.items.len < 2) return;
    var len: f64 = 0;
    for (cur.items[1..], 0..) |p, i| len += cur.items[i].dist(p);
    if (len < @as(f64, @floatFromInt(min_length))) return;
    try out.append(gpa, cur.items);
}

fn lerp(a: Point, b: Point, t: f64) Point {
    return .{
        .x = a.x + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(b.x - a.x)) * t))),
        .y = a.y + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(b.y - a.y)) * t))),
    };
}

/// The parameter t (0 to 1) along a -> b where the edge e crosses it, or
/// null if it does not cross. A touch at an end of e counts once (the
/// half-open rule is not needed here: a split point that is not a real
/// crossing makes two pieces with the same inside test).
fn crossParam(a: Point, b: Point, e: Edge) ?f64 {
    const d1 = geom.cross3(e.a, e.b, a);
    const d2 = geom.cross3(e.a, e.b, b);
    const d3 = geom.cross3(a, b, e.a);
    const d4 = geom.cross3(a, b, e.b);
    if ((d1 > 0 and d2 > 0) or (d1 < 0 and d2 < 0)) return null;
    if ((d3 > 0 and d4 > 0) or (d3 < 0 and d4 < 0)) return null;
    if (d1 == d2) return null; // on one line: no single crossing
    return @as(f64, @floatFromInt(d1)) / @as(f64, @floatFromInt(d1 - d2));
}

/// A uniform grid of region edges, with a winding test.
const Grid = struct {
    origin: Point,
    cell: f64,
    nx: i64,
    ny: i64,
    starts: []u32,
    items: []u32,

    fn key(g: Grid, cx: i64, cy: i64) usize {
        return @intCast(cy * g.nx + cx);
    }

    fn cellX(g: Grid, x: f64) i64 {
        return std.math.clamp(@as(i64, @intFromFloat(@floor((x - @as(f64, @floatFromInt(g.origin.x))) / g.cell))), 0, g.nx - 1);
    }

    fn cellY(g: Grid, y: f64) i64 {
        return std.math.clamp(@as(i64, @intFromFloat(@floor((y - @as(f64, @floatFromInt(g.origin.y))) / g.cell))), 0, g.ny - 1);
    }

    fn build(arena: Allocator, edges: []const Edge, box: geom.Box, mean: f64) !Grid {
        const w: f64 = @floatFromInt(box.max.x - box.min.x + 1);
        const h: f64 = @floatFromInt(box.max.y - box.min.y + 1);
        const cell = @max(mean * 2, @max(w, h) / 1024.0, 1.0);
        var g: Grid = .{
            .origin = box.min,
            .cell = cell,
            .nx = @as(i64, @intFromFloat(@floor(w / cell))) + 1,
            .ny = @as(i64, @intFromFloat(@floor(h / cell))) + 1,
            .starts = &.{},
            .items = &.{},
        };
        const n: usize = @intCast(g.nx * g.ny);
        g.starts = try arena.alloc(u32, n + 1);
        @memset(g.starts, 0);
        // Each edge goes in each cell of its bounding box. Region edges are
        // short (outline edges), so the box is a few cells. Count, then
        // fill (compressed sparse rows).
        for (edges) |e| {
            const r = g.boxCells(e.a, e.b);
            var cy = r[2];
            while (cy <= r[3]) : (cy += 1) {
                var cx = r[0];
                while (cx <= r[1]) : (cx += 1) g.starts[g.key(cx, cy) + 1] += 1;
            }
        }
        for (1..g.starts.len) |k| g.starts[k] += g.starts[k - 1];
        g.items = try arena.alloc(u32, g.starts[n]);
        const fill = try arena.dupe(u32, g.starts[0..n]);
        for (edges, 0..) |e, i| {
            const r = g.boxCells(e.a, e.b);
            var cy = r[2];
            while (cy <= r[3]) : (cy += 1) {
                var cx = r[0];
                while (cx <= r[1]) : (cx += 1) {
                    const k = g.key(cx, cy);
                    g.items[fill[k]] = @intCast(i);
                    fill[k] += 1;
                }
            }
        }
        return g;
    }

    /// The cell range of the bounding box of a -> b: x0, x1, y0, y1.
    fn boxCells(g: Grid, a: Point, b: Point) [4]i64 {
        return .{
            g.cellX(@floatFromInt(@min(a.x, b.x))),
            g.cellX(@floatFromInt(@max(a.x, b.x))),
            g.cellY(@floatFromInt(@min(a.y, b.y))),
            g.cellY(@floatFromInt(@max(a.y, b.y))),
        };
    }

    fn edgesIn(g: Grid, k: usize) []const u32 {
        return g.items[g.starts[k]..g.starts[k + 1]];
    }

    /// The cells of the bounding box of segment a -> b. The infill
    /// segments are short, so this is a few cells.
    fn cellsOf(g: Grid, arena: Allocator, a: Point, b: Point, out: *std.ArrayList(usize)) !void {
        const r = g.boxCells(a, b);
        var cy = r[2];
        while (cy <= r[3]) : (cy += 1) {
            var cx = r[0];
            while (cx <= r[1]) : (cx += 1) try out.append(arena, g.key(cx, cy));
        }
    }

    /// True if (x, y) is inside the region (non-zero winding). A ray goes
    /// to the right, through the cells of its row, and adds the direction
    /// of each edge that it crosses. An edge counts if min y <= y < max y.
    fn inside(g: Grid, edges: []const Edge, x: f64, y: f64) bool {
        const cy = g.cellY(y);
        var wind: i32 = 0;
        var cx = g.cellX(x);
        while (cx < g.nx) : (cx += 1) {
            for (g.edgesIn(g.key(cx, cy))) |ei| {
                const e = edges[ei];
                const ay: f64 = @floatFromInt(e.a.y);
                const by: f64 = @floatFromInt(e.b.y);
                const lo = @min(ay, by);
                const hi = @max(ay, by);
                if (!(lo <= y and y < hi)) continue;
                const ax: f64 = @floatFromInt(e.a.x);
                const bx: f64 = @floatFromInt(e.b.x);
                const xc = ax + (y - ay) / (by - ay) * (bx - ax);
                if (xc <= x) continue;
                // Count the edge only in the cell that holds its crossing,
                // so that an edge in more than one cell counts once.
                if (g.cellX(xc) != cx) continue;
                wind += if (by > ay) 1 else -1;
            }
        }
        return wind != 0;
    }
};

const testing = std.testing;

test "clip a zigzag to a square with a hole" {
    const gpa = testing.allocator;
    var region: Paths = .empty;
    defer region.deinit(gpa);
    try region.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    try region.append(gpa, &.{ .init(4_000, 4_000), .init(4_000, 6_000), .init(6_000, 6_000), .init(6_000, 4_000) });
    var lines: Paths = .empty;
    defer lines.deinit(gpa);
    // A horizontal line through the hole, from outside to outside.
    try lines.append(gpa, &.{ .init(-1000, 5000), .init(11_000, 5000) });
    // A zigzag across the whole square, below the hole.
    try lines.append(gpa, &.{ .init(-1000, 1000), .init(2000, 3000), .init(5000, 1000), .init(8000, 3000), .init(11_000, 1000) });
    var r = try clipPolylines(gpa, region, lines, 0);
    defer r.deinit(gpa);
    // The line: two parts (0 to 4 mm and 6 to 10 mm). The zigzag: one part.
    try testing.expectEqual(@as(usize, 3), r.count());
    var total: f64 = 0;
    for (0..r.count()) |i| {
        const pl = r.get(i);
        for (pl[1..], 0..) |p, k| total += pl[k].dist(p);
        for (pl) |p| try testing.expect(p.x >= 0 and p.x <= 10_000);
    }
    // 8 mm of line, plus the zigzag from x = 0 to x = 10 mm: 4 sloped legs
    // with a slope of 2/3, cut at the square sides.
    const leg = @sqrt(3000.0 * 3000.0 + 2000.0 * 2000.0);
    const zig = (10_000.0 / 3000.0) * leg;
    try testing.expectApproxEqRel(8000.0 + zig, total, 0.001);
}
