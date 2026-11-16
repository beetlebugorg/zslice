//! Polygon boolean operations: union, intersection, difference, and xor.
//!
//! A slicer uses these operations at almost every step. Examples:
//!
//! - The union of the loops from the mesh gives the layer outline.
//! - The difference between a layer and the layer above gives the top skin.
//! - The offset in `offset.zig` makes loops that cross themselves. A union
//!   with the "positive" fill rule removes the bad parts.
//!
//! The method is "planar arrangement and winding numbers":
//!
//! 1. Put all edges of both operands in one list. Each edge records its
//!    operand (subject or clip) and its direction.
//! 2. Find each point where two edges touch or cross. Split the edges at
//!    these points. After this step, two edges can only meet at their end
//!    points.
//! 3. Merge edges that have the same two end points. Each merged edge keeps
//!    a "winding delta" for each operand: the number of times an operand
//!    goes along it forward, minus the number of times it goes backward.
//!    Overlapping boundaries (two squares that share a side) are now one
//!    edge. A merged edge with a delta of zero for both operands is not a
//!    boundary, so the code removes it.
//! 4. For each edge, find the winding number of each operand on the two
//!    sides of the edge. The code walks the faces of the arrangement: the
//!    winding number changes by the delta of an edge when a walk crosses it
//!    (see `computeWinding`).
//! 5. The fill rule turns a winding number into "inside" or "outside" for
//!    each operand. The operation (union, ...) combines the two operands.
//!    An edge is in the output if one side is inside and the other side is
//!    outside. The code turns the edge so that the inside is on its left.
//! 6. Join the output edges into closed loops.
//!
//! The method is simpler than the sweep-line method that Clipper uses
//! (Vatti, see REFERENCES.md), and it gives correct output for any input: self-intersecting
//! polygons, shared edges, and polygons that touch at one point.
//!
//! References (see REFERENCES.md): winding numbers and fill rules, the
//! uniform grid with the Amanatides-Woo walk, the half-edge structure
//! (DCEL), iterated snap rounding, the slab index, and the CSR layout.
//!
//! Known limit: a crossing point is rounded to the nearest micrometer. The
//! rounded point can move an edge by up to 0.7 micrometers, and in rare
//! cases the moved edge crosses a third edge. A slicer cannot print detail
//! that small, so the code does not correct it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const Point = geom.Point;
const Paths = geom.Paths;
const cross3 = geom.cross3;
const dot3 = geom.dot3;

pub const Op = enum { union_, intersection, difference, xor };

/// The rule that decides if a point is inside, from its winding number.
pub const FillRule = enum {
    /// Inside if the winding number is odd.
    even_odd,
    /// Inside if the winding number is not zero.
    non_zero,
    /// Inside if the winding number is more than zero.
    positive,
};

/// Returns the result of `subject <op> clip`. The output has
/// counterclockwise outer boundaries and clockwise holes. The caller owns
/// the result.
pub fn boolean(gpa: Allocator, subject: Paths, clip: Paths, op: Op, rule: FillRule) Allocator.Error!Paths {
    // All temporary memory comes from one arena and is freed in one step.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Step 1: collect the edges.
    var edges: std.ArrayList(InEdge) = .empty;
    try addEdges(arena, &edges, subject, 0);
    try addEdges(arena, &edges, clip, 1);
    if (edges.items.len == 0) return .empty;

    // Steps 2 and 3: split the edges and merge equal edges. A split point
    // is rounded to the grid, and the rounded point can make a new crossing.
    // So the code repeats the steps on the result until a pass finds no
    // split points ("iterated snap rounding"). Most inputs need one or two
    // passes. A later pass only tests the pairs with a new edge: two edges
    // that did not change were tested in the pass before.
    var cur: []InEdge = edges.items;
    var merged: []Merged = &.{};
    var pass: usize = 0;
    while (true) : (pass += 1) {
        var splits: std.ArrayList(Split) = .empty;
        try findIntersections(arena, cur, &splits);
        merged = try splitAndMerge(arena, cur, splits.items);
        if (splits.items.len == 0 or pass == max_passes) break;
        cur = try arena.alloc(InEdge, merged.len);
        for (merged, cur) |m, *e| e.* = .{ .a = m.lo, .b = m.hi, .d = m.d, .fresh = m.fresh };
    }
    if (merged.len == 0) return .empty;

    // Step 4: winding numbers on each side of each edge.
    try computeWinding(arena, merged);

    // Step 5: keep the boundary edges, with the inside on the left.
    var out_edges: std.ArrayList(DirEdge) = .empty;
    for (merged) |e| {
        const in_left = isInside(e.left, op, rule);
        const in_right = isInside(.{ e.left[0] - e.d[0], e.left[1] - e.d[1] }, op, rule);
        if (in_left == in_right) continue;
        if (in_left) {
            try out_edges.append(arena, .{ .a = e.lo, .b = e.hi });
        } else {
            try out_edges.append(arena, .{ .a = e.hi, .b = e.lo });
        }
    }

    // Step 6: join the edges into loops.
    return chainLoops(gpa, arena, out_edges.items);
}

/// The union of all polygons in `paths`, with the given fill rule.
pub fn unionAll(gpa: Allocator, paths: Paths, rule: FillRule) Allocator.Error!Paths {
    return boolean(gpa, paths, .empty, .union_, rule);
}

pub fn unite(gpa: Allocator, a: Paths, b: Paths) Allocator.Error!Paths {
    return boolean(gpa, a, b, .union_, .non_zero);
}

pub fn intersect(gpa: Allocator, a: Paths, b: Paths) Allocator.Error!Paths {
    if (a.isEmpty() or b.isEmpty()) return .empty;
    return boolean(gpa, a, b, .intersection, .non_zero);
}

pub fn difference(gpa: Allocator, a: Paths, b: Paths) Allocator.Error!Paths {
    if (a.isEmpty()) return .empty;
    if (b.isEmpty()) return a.clone(gpa);
    return boolean(gpa, a, b, .difference, .non_zero);
}

// ---------------------------------------------------------------------------
// Step 1

/// Output loops with less than this area (times two, in square units) are
/// removed: 200 is 100 square micrometers.
const min_loop_area2 = 200;

/// The most find-and-split passes. The limit stops a loop on bad input.
const max_passes = 8;

/// An input edge. `d` is the winding delta of each operand along a -> b.
const InEdge = struct {
    a: Point,
    b: Point,
    d: [2]i32,
    /// False if the edge is the same as in the pass before (no split
    /// point). Two such edges were tested in that pass and do not cross,
    /// so the next pass does not test them again.
    fresh: bool = true,

    fn minX(e: InEdge) i64 {
        return @min(e.a.x, e.b.x);
    }
    fn maxX(e: InEdge) i64 {
        return @max(e.a.x, e.b.x);
    }
};

fn addEdges(arena: Allocator, edges: *std.ArrayList(InEdge), paths: Paths, operand: u1) !void {
    for (0..paths.count()) |i| {
        const poly = paths.get(i);
        if (poly.len < 2) continue;
        var prev = poly[poly.len - 1];
        for (poly) |p| {
            if (!p.eql(prev)) {
                var e: InEdge = .{ .a = prev, .b = p, .d = .{ 0, 0 } };
                e.d[operand] = 1;
                try edges.append(arena, e);
            }
            prev = p;
        }
    }
}

// ---------------------------------------------------------------------------
// Step 2

const Split = struct { edge: u32, p: Point };

/// Finds the split points with a uniform grid. Each edge goes into each
/// grid cell that it passes through (a walk along the edge, cell by cell,
/// so a long edge gets only the cells on its line, and not each cell of its
/// bounding box). Two edges can touch only if they share a cell, so the
/// code tests only the pairs in each cell. The cell size is the mean edge
/// length, so most edges are in one or two cells.
///
/// A pair that shares more than one cell is tested more than once. The
/// split step removes the repeated points.
fn findIntersections(arena: Allocator, edges: []const InEdge, splits: *std.ArrayList(Split)) !void {
    if (edges.len < 2) return;
    var box = geom.Box.empty;
    var total: f64 = 0;
    for (edges) |e| {
        box.extend(e.a);
        box.extend(e.b);
        total += e.a.dist(e.b);
    }
    const span: f64 = @floatFromInt(@max(box.max.x - box.min.x, box.max.y - box.min.y) + 1);
    // The mean edge length, but not so small that the grid has more than
    // about 4096 cells on a side.
    const cell = @max(total / @as(f64, @floatFromInt(edges.len)), span / 4096.0, 1.0);

    // The number of cells on each side. The walk can add a cell one step
    // past the box (at a corner), so each side gets 2 more.
    const grid: Grid = .{
        .origin = box.min,
        .cell = cell,
        .rows = @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(box.max.y - box.min.y)) / cell))) + 2,
        .cols = @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(box.max.x - box.min.x)) / cell))) + 2,
    };

    var entries: std.ArrayList(CellEntry) = .empty;
    try entries.ensureTotalCapacity(arena, edges.len * 2);
    var all_fresh = true;
    for (edges) |e| all_fresh = all_fresh and e.fresh;
    if (all_fresh) {
        for (edges, 0..) |e, i| try walkCells(arena, &entries, e.a, e.b, grid, @intCast(i));
    } else {
        // A later pass: only pairs with a fresh edge can cross. So the grid
        // gets the cells of the fresh edges, and the other edges only in
        // those cells.
        var marked = try std.DynamicBitSetUnmanaged.initEmpty(arena, grid.rows * grid.cols);
        for (edges, 0..) |e, i| {
            if (!e.fresh) continue;
            const start = entries.items.len;
            try walkCells(arena, &entries, e.a, e.b, grid, @intCast(i));
            for (entries.items[start..]) |c| marked.set(c.cell);
        }
        if (entries.items.len == 0) return;
        // The order of the entries in a cell does not change the result
        // (see splitAndMerge), so the other edges can come after them.
        for (edges, 0..) |e, i| {
            if (e.fresh) continue;
            const start = entries.items.len;
            try walkCells(arena, &entries, e.a, e.b, grid, @intCast(i));
            var keep = start;
            for (entries.items[start..]) |c| {
                if (!marked.isSet(c.cell)) continue;
                entries.items[keep] = c;
                keep += 1;
            }
            entries.shrinkRetainingCapacity(keep);
        }
    }

    // Sort by cell. The radix sort keeps the order of the entries in each
    // cell.
    try radixSortByCell(arena, entries.items, grid.rows * grid.cols);

    var i: usize = 0;
    const items = entries.items;
    while (i < items.len) {
        var j = i + 1;
        while (j < items.len and items[j].cell == items[i].cell) : (j += 1) {}
        // The edges in this cell: items[i..j]. The entries of one edge are
        // next to each other. In a later pass, the fresh edges come first.
        var x = i;
        while (x < j) : (x += 1) {
            if (x > i and items[x].edge == items[x - 1].edge) continue;
            const ei = items[x].edge;
            const e = edges[ei];
            // The rest are old edges, and two old edges do not cross.
            if (!e.fresh) break;
            var y = x + 1;
            while (y < j) : (y += 1) {
                if (items[y].edge == items[y - 1].edge) continue;
                const fi = items[y].edge;
                const f = edges[fi];
                if (@max(f.a.x, f.b.x) < e.minX() or @min(f.a.x, f.b.x) > e.maxX()) continue;
                if (@max(f.a.y, f.b.y) < @min(e.a.y, e.b.y) or @min(f.a.y, f.b.y) > @max(e.a.y, e.b.y)) continue;
                // The crossing point is rounded along the first edge, so
                // the edge with the lower index always goes first.
                if (ei < fi) {
                    try intersectPair(arena, splits, ei, e, fi, f);
                } else {
                    try intersectPair(arena, splits, fi, f, ei, e);
                }
            }
        }
        i = j;
    }
}

const CellEntry = struct { cell: u32, edge: u32 };

const Grid = struct {
    origin: Point,
    cell: f64,
    rows: u32,
    cols: u32,

    /// The index of a cell: column major, so the order is by x, then y.
    fn key(g: Grid, cx: i64, cy: i64) u32 {
        return @as(u32, @intCast(cx)) * g.rows + @as(u32, @intCast(cy));
    }
};

/// Sorts the entries by cell, and keeps the order of entries in the same
/// cell. The method is a least significant digit radix sort: one stable
/// counting sort for each 11 bits of the cell index, from the low bits to
/// the high bits. It costs O(n) for each digit, and a cell index has at
/// most 3 digits.
fn radixSortByCell(arena: Allocator, items: []CellEntry, cell_count: u32) !void {
    if (items.len < 2) return;
    const bits = 11;
    const radix = 1 << bits;
    var src = items;
    var dst = try arena.alloc(CellEntry, items.len);
    var shift: u5 = 0;
    var passes: usize = 0;
    while (true) {
        var count: [radix + 1]u32 = @splat(0);
        for (src) |e| count[((e.cell >> shift) & (radix - 1)) + 1] += 1;
        for (1..radix + 1) |k| count[k] += count[k - 1];
        for (src) |e| {
            const d = (e.cell >> shift) & (radix - 1);
            dst[count[d]] = e;
            count[d] += 1;
        }
        std.mem.swap([]CellEntry, &src, &dst);
        passes += 1;
        if (shift + bits >= 32 or (cell_count - 1) >> (shift + bits) == 0) break;
        shift += bits;
    }
    if (src.ptr != items.ptr) @memcpy(items, src);
}

/// Adds the cells that the segment from a to b passes through (the
/// Amanatides-Woo grid walk). Where the segment goes through a cell corner,
/// both side cells are added too, so that a rounding error cannot skip a
/// cell. Cell coordinates are relative to `origin`, so they are not
/// negative.
fn walkCells(arena: Allocator, out: *std.ArrayList(CellEntry), a: Point, b: Point, g: Grid, edge: u32) !void {
    const origin = g.origin;
    const cell = g.cell;
    const ax = @as(f64, @floatFromInt(a.x - origin.x)) / cell;
    const ay = @as(f64, @floatFromInt(a.y - origin.y)) / cell;
    const bx = @as(f64, @floatFromInt(b.x - origin.x)) / cell;
    const by = @as(f64, @floatFromInt(b.y - origin.y)) / cell;
    var cx: i64 = @intFromFloat(@floor(ax));
    var cy: i64 = @intFromFloat(@floor(ay));
    const ex: i64 = @intFromFloat(@floor(bx));
    const ey: i64 = @intFromFloat(@floor(by));
    try out.append(arena, .{ .cell = g.key(cx, cy), .edge = edge });
    if (cx == ex and cy == ey) return;

    const dx = bx - ax;
    const dy = by - ay;
    const sx: i64 = if (dx > 0) 1 else -1;
    const sy: i64 = if (dy > 0) 1 else -1;
    const inf = std.math.inf(f64);
    var t_max_x = if (dx != 0) (@as(f64, @floatFromInt(cx + @as(i64, if (dx > 0) 1 else 0))) - ax) / dx else inf;
    var t_max_y = if (dy != 0) (@as(f64, @floatFromInt(cy + @as(i64, if (dy > 0) 1 else 0))) - ay) / dy else inf;
    const t_dx = if (dx != 0) @abs(1 / dx) else inf;
    const t_dy = if (dy != 0) @abs(1 / dy) else inf;
    var steps = @abs(ex - cx) + @abs(ey - cy) + 2;
    while (steps > 0 and !(cx == ex and cy == ey)) : (steps -= 1) {
        const diff = t_max_x - t_max_y;
        // A corner needs both steps to be finite: an axis-aligned edge has
        // one infinite value, and inf - inf would look like a corner.
        const corner = std.math.isFinite(t_max_x) and std.math.isFinite(t_max_y) and
            @abs(diff) <= 1e-9 * @max(1.0, @abs(t_max_x));
        if (corner) {
            // Through a corner: add both side cells. A side cell outside the
            // grid (a negative coordinate) has no edges, so it is skipped.
            if (cx + sx >= 0) try out.append(arena, .{ .cell = g.key(cx + sx, cy), .edge = edge });
            if (cy + sy >= 0) try out.append(arena, .{ .cell = g.key(cx, cy + sy), .edge = edge });
            cx += sx;
            cy += sy;
            t_max_x += t_dx;
            t_max_y += t_dy;
        } else if (diff < 0) {
            cx += sx;
            t_max_x += t_dx;
        } else {
            cy += sy;
            t_max_y += t_dy;
        }
        if (cx < 0 or cy < 0) break;
        try out.append(arena, .{ .cell = g.key(cx, cy), .edge = edge });
    }
}

/// True if p is on the open segment from a to b. The caller has already
/// found that p is on the line through a and b.
fn strictlyBetween(a: Point, b: Point, p: Point) bool {
    if (p.eql(a) or p.eql(b)) return false;
    return dot3(a, b, p) > 0 and dot3(b, a, p) > 0;
}

fn intersectPair(arena: Allocator, splits: *std.ArrayList(Split), ei: u32, e: InEdge, fi: u32, f: InEdge) !void {
    const p1 = e.a;
    const p2 = e.b;
    const q1 = f.a;
    const q2 = f.b;
    const d1 = cross3(q1, q2, p1);
    const d2 = cross3(q1, q2, p2);
    const d3 = cross3(p1, p2, q1);
    const d4 = cross3(p1, p2, q2);

    // Each end point that is on the other edge (but not at its ends) splits
    // the other edge. This covers "T" junctions and edges that overlap on
    // one line.
    if (d1 == 0 and strictlyBetween(q1, q2, p1)) try splits.append(arena, .{ .edge = fi, .p = p1 });
    if (d2 == 0 and strictlyBetween(q1, q2, p2)) try splits.append(arena, .{ .edge = fi, .p = p2 });
    if (d3 == 0 and strictlyBetween(p1, p2, q1)) try splits.append(arena, .{ .edge = ei, .p = q1 });
    if (d4 == 0 and strictlyBetween(p1, p2, q2)) try splits.append(arena, .{ .edge = ei, .p = q2 });

    // A proper crossing: the ends of each edge are on opposite sides of the
    // other edge.
    const crosses_e = (d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0);
    const crosses_f = (d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0);
    if (crosses_e and crosses_f) {
        // The crossing is at p1 + t * (p2 - p1), with t = d1 / (d1 - d2).
        const den = d1 - d2;
        const ip = Point{
            .x = p1.x + roundDiv(@as(i128, p2.x - p1.x) * d1, den),
            .y = p1.y + roundDiv(@as(i128, p2.y - p1.y) * d1, den),
        };
        if (!ip.eql(p1) and !ip.eql(p2)) try splits.append(arena, .{ .edge = ei, .p = ip });
        if (!ip.eql(q1) and !ip.eql(q2)) try splits.append(arena, .{ .edge = fi, .p = ip });
    }
}

/// num / den, rounded to the nearest integer.
fn roundDiv(num: i128, den: i128) i64 {
    var n = num;
    var d = den;
    if (d < 0) {
        n = -n;
        d = -d;
    }
    const half = @divTrunc(d, 2);
    const q = if (n >= 0) @divTrunc(n + half, d) else -@divTrunc(-n + half, d);
    return @intCast(q);
}

// ---------------------------------------------------------------------------
// Step 3

/// An edge after the split and merge. `lo` is the smaller end point in
/// (x, y) order. `d` is the winding delta of each operand along lo -> hi.
/// `left` is the winding number of each operand on the left of lo -> hi.
const Merged = struct {
    lo: Point,
    hi: Point,
    d: [2]i32,
    left: [2]i32 = .{ 0, 0 },
    /// True if the edge comes from a split (see InEdge.fresh).
    fresh: bool = false,
};

fn splitAndMerge(arena: Allocator, edges: []const InEdge, splits: []Split) ![]Merged {
    // Sort the split points by edge, then by position along the edge.
    std.mem.sortUnstable(Split, splits, edges, struct {
        fn lt(es: []const InEdge, a: Split, b: Split) bool {
            if (a.edge != b.edge) return a.edge < b.edge;
            const e = es[a.edge];
            const da = dot3(e.a, e.b, a.p);
            const db = dot3(e.a, e.b, b.p);
            if (da != db) return da < db;
            // A rounded crossing point can be off the line, so two points
            // can have the same place along the edge. The point order
            // makes the result the same for each input order.
            return a.p.lessThan(b.p);
        }
    }.lt);

    var subs: std.ArrayList(Merged) = .empty;
    try subs.ensureTotalCapacity(arena, edges.len + splits.len);
    var k: usize = 0;
    for (edges, 0..) |e, i| {
        var prev = e.a;
        const split = k < splits.len and splits[k].edge == i;
        while (k < splits.len and splits[k].edge == i) : (k += 1) {
            try addSub(arena, &subs, prev, splits[k].p, e.d, true);
            prev = splits[k].p;
        }
        try addSub(arena, &subs, prev, e.b, e.d, split);
    }

    // Sort by end points, then add up the deltas of equal edges.
    std.mem.sortUnstable(Merged, subs.items, {}, struct {
        fn lt(_: void, a: Merged, b: Merged) bool {
            if (!a.lo.eql(b.lo)) return a.lo.lessThan(b.lo);
            return a.hi.lessThan(b.hi);
        }
    }.lt);
    var out: usize = 0;
    var i: usize = 0;
    const items = subs.items;
    while (i < items.len) {
        var m = items[i];
        var j = i + 1;
        while (j < items.len and items[j].lo.eql(m.lo) and items[j].hi.eql(m.hi)) : (j += 1) {
            m.d[0] += items[j].d[0];
            m.d[1] += items[j].d[1];
            m.fresh = m.fresh or items[j].fresh;
        }
        if (m.d[0] != 0 or m.d[1] != 0) {
            items[out] = m;
            out += 1;
        }
        i = j;
    }
    return items[0..out];
}

fn addSub(arena: Allocator, subs: *std.ArrayList(Merged), a: Point, b: Point, d: [2]i32, fresh: bool) !void {
    if (a.eql(b)) return;
    const m: Merged = if (a.lessThan(b))
        .{ .lo = a, .hi = b, .d = d, .fresh = fresh }
    else
        .{ .lo = b, .hi = a, .d = .{ -d[0], -d[1] }, .fresh = fresh };
    try subs.append(arena, m);
}

// ---------------------------------------------------------------------------
// Step 4

/// A bucket index along y, for the non-horizontal edges. Each edge is in
/// each "slab" (band of y) that its range touches. A horizontal ray query
/// looks only at the edges in one slab.
const SlabIndex = struct {
    min: i64,
    width: i64,
    starts: []u32,
    items: []u32,

    fn slab(s: SlabIndex, v: i64) usize {
        const i = @divFloor(v - s.min, s.width);
        return @intCast(std.math.clamp(i, 0, @as(i64, @intCast(s.starts.len - 2))));
    }

    fn get(s: SlabIndex, v: i64) []const u32 {
        const i = s.slab(v);
        return s.items[s.starts[i]..s.starts[i + 1]];
    }

    fn build(arena: Allocator, edges: []const Merged) !SlabIndex {
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        var n: usize = 0;
        for (edges) |e| {
            const r = range(e) orelse continue;
            lo = @min(lo, r[0]);
            hi = @max(hi, r[1]);
            n += 1;
        }
        if (n == 0) {
            const starts = try arena.alloc(u32, 2);
            starts[0] = 0;
            starts[1] = 0;
            return .{ .min = 0, .width = 1, .starts = starts, .items = &.{} };
        }
        const want: usize = std.math.clamp(2 * std.math.sqrt(n), 1, 4096);
        const span: i64 = hi - lo + 1;
        const width: i64 = @max(1, @divFloor(span + @as(i64, @intCast(want)) - 1, @as(i64, @intCast(want))));
        const slabs: usize = @intCast(@divFloor(span + width - 1, width));
        var s: SlabIndex = .{ .min = lo, .width = width, .starts = try arena.alloc(u32, slabs + 1), .items = &.{} };
        @memset(s.starts, 0);
        for (edges) |e| {
            const r = range(e) orelse continue;
            for (s.slab(r[0])..s.slab(r[1]) + 1) |k| s.starts[k + 1] += 1;
        }
        for (1..s.starts.len) |k| s.starts[k] += s.starts[k - 1];
        s.items = try arena.alloc(u32, s.starts[slabs]);
        const fill = try arena.dupe(u32, s.starts[0..slabs]);
        for (edges, 0..) |e, i| {
            const r = range(e) orelse continue;
            for (s.slab(r[0])..s.slab(r[1]) + 1) |k| {
                s.items[fill[k]] = @intCast(i);
                fill[k] += 1;
            }
        }
        return s;
    }

    fn range(e: Merged) ?[2]i64 {
        if (e.lo.y == e.hi.y) return null;
        return .{ @min(e.lo.y, e.hi.y), @max(e.lo.y, e.hi.y) };
    }
};

/// The winding numbers just left of v, from the edges that a horizontal ray
/// from v to the left crosses. An edge counts if min y <= v.y < max y (half
/// open) and v is strictly right of it. The result is the winding number at
/// a point just left of v and just above the ray.
fn windingLeftOf(edges: []const Merged, index: SlabIndex, v: Point) [2]i32 {
    var sum: [2]i32 = .{ 0, 0 };
    for (index.get(v.y)) |fi| {
        const f = edges[fi];
        const up = f.lo.y < f.hi.y;
        const u = if (up) f.lo else f.hi;
        const w = if (up) f.hi else f.lo;
        if (!(u.y <= v.y and v.y < w.y)) continue;
        if (cross3(u, w, v) < 0) {
            // An edge that goes down, on the left of the point, adds +1
            // (the left side of a counterclockwise square).
            const s: i32 = if (up) 1 else -1;
            sum[0] -= f.d[0] * s;
            sum[1] -= f.d[1] * s;
        }
    }
    return sum;
}

/// Finds the winding numbers on the left of each edge, from the faces of
/// the arrangement.
///
/// 1. Make two half-edges for each edge: lo -> hi and hi -> lo. The face of
///    a half-edge is the region on its left.
/// 2. At each vertex, sort the outgoing half-edges by angle. The next
///    half-edge around a face is then known: at the end vertex, take the
///    outgoing half-edge just clockwise from the way back.
/// 3. Walk each face cycle, and give each face an ID.
/// 4. Crossing an edge from its right to its left adds its delta to the
///    winding number. So within one connected component, a walk from face to
///    face gives each face its winding number relative to one face.
/// 5. One ray for each component makes the numbers absolute: the face just
///    left of the leftmost vertex of the component gets the winding number
///    of the other components at that point (see `windingLeftOf`).
///
/// The cost is O(n log n) for the sort, plus one ray for each component.
fn computeWinding(arena: Allocator, edges: []Merged) !void {
    const m = edges.len;
    const h_count = 2 * m;

    // Steps 1 and 2.
    const order = try arena.alloc(u32, h_count);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        edges: []const Merged,
        fn origin(c: @This(), h: u32) Point {
            const e = c.edges[h >> 1];
            return if (h & 1 == 0) e.lo else e.hi;
        }
        fn dir(c: @This(), h: u32) Point {
            const e = c.edges[h >> 1];
            return if (h & 1 == 0) e.hi.sub(e.lo) else e.lo.sub(e.hi);
        }
        fn lt(c: @This(), a: u32, b: u32) bool {
            const oa = c.origin(a);
            const ob = c.origin(b);
            if (!oa.eql(ob)) return oa.lessThan(ob);
            return angleLess(c.dir(a), c.dir(b));
        }
    };
    const ctx: Ctx = .{ .edges = edges };
    std.mem.sortUnstable(u32, order, ctx, Ctx.lt);
    const pos = try arena.alloc(u32, h_count);
    const group_start = try arena.alloc(u32, h_count);
    const group_len = try arena.alloc(u32, h_count);
    {
        var k: usize = 0;
        while (k < h_count) {
            var j = k + 1;
            const o = ctx.origin(order[k]);
            while (j < h_count and ctx.origin(order[j]).eql(o)) : (j += 1) {}
            for (k..j) |q| {
                pos[order[q]] = @intCast(q);
                group_start[q] = @intCast(k);
                group_len[q] = @intCast(j - k);
            }
            k = j;
        }
    }

    // Step 3.
    const no_face = std.math.maxInt(u32);
    const face = try arena.alloc(u32, h_count);
    @memset(face, no_face);
    var face_first: std.ArrayList(u32) = .empty;
    for (0..h_count) |start| {
        if (face[start] != no_face) continue;
        const f: u32 = @intCast(face_first.items.len);
        try face_first.append(arena, @intCast(start));
        var h: u32 = @intCast(start);
        while (face[h] == no_face) {
            face[h] = f;
            // next(h): at the end of h, the outgoing half-edge just
            // clockwise from the twin of h.
            const k = pos[h ^ 1];
            const g = group_start[k];
            const len = group_len[k];
            h = order[g + (k - g + len - 1) % len];
        }
    }

    // Steps 4 and 5.
    const nf = face_first.items.len;
    const wind = try arena.alloc([2]i32, nf);
    const known = try arena.alloc(bool, nf);
    @memset(known, false);
    var index: ?SlabIndex = null;
    var queue: std.ArrayList(u32) = .empty;
    var comp: std.ArrayList(u32) = .empty;
    for (0..nf) |seed| {
        if (known[seed]) continue;
        queue.clearRetainingCapacity();
        comp.clearRetainingCapacity();
        known[seed] = true;
        wind[seed] = .{ 0, 0 };
        try queue.append(arena, @intCast(seed));
        // The leftmost vertex of the component, and its most
        // counterclockwise outgoing half-edge.
        var lead: u32 = face_first.items[seed];
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const f = queue.items[qi];
            try comp.append(arena, f);
            var h = face_first.items[f];
            while (true) {
                if (ctx.origin(h).lessThan(ctx.origin(lead)) or
                    (ctx.origin(h).eql(ctx.origin(lead)) and crossV(ctx.dir(lead), ctx.dir(h)) > 0)) lead = h;
                // The face on the other side of h is the face of its twin.
                // The left of lo -> hi has the winding of its right plus d.
                const g = face[h ^ 1];
                if (!known[g]) {
                    const d = edges[h >> 1].d;
                    known[g] = true;
                    wind[g] = if (h & 1 == 0)
                        .{ wind[f][0] - d[0], wind[f][1] - d[1] }
                    else
                        .{ wind[f][0] + d[0], wind[f][1] + d[1] };
                    try queue.append(arena, g);
                }
                const k = pos[h ^ 1];
                const gs = group_start[k];
                const len = group_len[k];
                h = order[gs + (k - gs + len - 1) % len];
                if (h == face_first.items[f]) break;
            }
        }
        // Make the numbers of this component absolute.
        if (index == null) index = try SlabIndex.build(arena, edges);
        const v = ctx.origin(lead);
        const outside = windingLeftOf(edges, index.?, v);
        const rel = wind[face[lead]];
        const shift = [2]i32{ outside[0] - rel[0], outside[1] - rel[1] };
        for (comp.items) |f| wind[f] = .{ wind[f][0] + shift[0], wind[f][1] + shift[1] };
    }

    for (edges, 0..) |*e, i| e.left = wind[face[2 * i]];
}

/// The order of directions by angle, counterclockwise from +x. Exact: it
/// uses only signs of integer products.
fn angleLess(a: Point, b: Point) bool {
    const ha = upperHalf(a);
    const hb = upperHalf(b);
    if (ha != hb) return ha;
    return crossV(a, b) > 0;
}

/// True for angles in [0, 180) degrees.
fn upperHalf(v: Point) bool {
    return v.y > 0 or (v.y == 0 and v.x > 0);
}

// ---------------------------------------------------------------------------
// Step 5

fn filled(w: i32, rule: FillRule) bool {
    return switch (rule) {
        .even_odd => @rem(w, 2) != 0,
        .non_zero => w != 0,
        .positive => w > 0,
    };
}

fn isInside(w: [2]i32, op: Op, rule: FillRule) bool {
    const a = filled(w[0], rule);
    const b = filled(w[1], rule);
    return switch (op) {
        .union_ => a or b,
        .intersection => a and b,
        .difference => a and !b,
        .xor => a != b,
    };
}

// ---------------------------------------------------------------------------
// Step 6

const DirEdge = struct { a: Point, b: Point, used: bool = false };

/// Joins directed edges into closed loops. At each vertex, the number of
/// edges in is equal to the number of edges out, so a walk along unused
/// edges always comes back to its start. Where more than one edge goes out
/// (two loops touch at the vertex), the walk takes the sharpest left turn.
fn chainLoops(gpa: Allocator, arena: Allocator, edges: []DirEdge) Allocator.Error!Paths {
    std.mem.sortUnstable(DirEdge, edges, {}, struct {
        fn lt(_: void, a: DirEdge, b: DirEdge) bool {
            return a.a.lessThan(b.a);
        }
    }.lt);

    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    var loop: std.ArrayList(Point) = .empty;

    for (0..edges.len) |start| {
        if (edges[start].used) continue;
        loop.clearRetainingCapacity();
        const origin = edges[start].a;
        var cur = start;
        var closed = false;
        while (true) {
            edges[cur].used = true;
            try loop.append(arena, edges[cur].a);
            const v = edges[cur].b;
            if (v.eql(origin)) {
                closed = true;
                break;
            }
            const next = pickNext(edges, edges[cur].a, v) orelse break;
            cur = next;
        }
        if (!closed) continue;
        const n = geom.simplifyClosed(loop.items, 0);
        if (n < 3) continue;
        // Loops with almost no area come from rounded crossing points. They
        // are too small to print, and later steps work better without them.
        if (@abs(geom.area2(loop.items[0..n])) < min_loop_area2) continue;
        try out.append(gpa, loop.items[0..n]);
    }
    return out;
}

fn pickNext(edges: []const DirEdge, from: Point, v: Point) ?usize {
    // Binary search for the first edge that starts at v.
    var lo: usize = 0;
    var hi: usize = edges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (edges[mid].a.lessThan(v)) lo = mid + 1 else hi = mid;
    }
    const u = v.sub(from);
    var best: ?usize = null;
    var i = lo;
    while (i < edges.len and edges[i].a.eql(v)) : (i += 1) {
        if (edges[i].used) continue;
        if (best == null or turnsMoreLeft(u, edges[i].b.sub(v), edges[best.?].b.sub(v))) best = i;
    }
    return best;
}

/// True if the turn from direction u to direction a is more to the left
/// than the turn from u to b. A turn angle is in (-180, 180] degrees. The
/// test is exact: it uses only signs of integer cross and dot products.
fn turnsMoreLeft(u: Point, a: Point, b: Point) bool {
    const ha = leftHalf(u, a);
    const hb = leftHalf(u, b);
    if (ha != hb) return ha;
    // In the same half, a turns more left than b if a is counterclockwise
    // from b.
    return crossV(b, a) > 0;
}

/// True if the turn from u to w is in (0, 180] degrees.
fn leftHalf(u: Point, w: Point) bool {
    const c = crossV(u, w);
    return c > 0 or (c == 0 and dotV(u, w) < 0);
}

fn crossV(a: Point, b: Point) i128 {
    return @as(i128, a.x) * b.y - @as(i128, a.y) * b.x;
}

fn dotV(a: Point, b: Point) i128 {
    return @as(i128, a.x) * b.x + @as(i128, a.y) * b.y;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn rect(gpa: Allocator, paths: *Paths, x0: i64, y0: i64, x1: i64, y1: i64) !void {
    try paths.append(gpa, &.{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) });
}

test "union of two overlapping squares" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    var b: Paths = .empty;
    defer b.deinit(gpa);
    try rect(gpa, &a, 0, 0, 2000, 2000);
    try rect(gpa, &b, 1000, 1000, 3000, 3000);
    var r = try unite(gpa, a, b);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectApproxEqAbs(@as(f64, 7.0), r.areaMm2(), 1e-9);
    try testing.expectEqual(@as(usize, 8), r.get(0).len);
}

test "intersection and difference of two squares" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    var b: Paths = .empty;
    defer b.deinit(gpa);
    try rect(gpa, &a, 0, 0, 2000, 2000);
    try rect(gpa, &b, 1000, 1000, 3000, 3000);
    var i = try intersect(gpa, a, b);
    defer i.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 1.0), i.areaMm2(), 1e-9);
    var d = try difference(gpa, a, b);
    defer d.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 3.0), d.areaMm2(), 1e-9);
}

test "difference of equal squares is empty" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    try rect(gpa, &a, 0, 0, 2000, 2000);
    var d = try difference(gpa, a, a);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), d.count());
}

test "squares that share a side merge into one rectangle" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    try rect(gpa, &a, 0, 0, 1000, 1000);
    try rect(gpa, &a, 1000, 0, 2000, 1000);
    var r = try unionAll(gpa, a, .non_zero);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectEqual(@as(usize, 4), r.get(0).len);
    try testing.expectApproxEqAbs(@as(f64, 2.0), r.areaMm2(), 1e-9);
}

test "a hole cut from a square" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    var b: Paths = .empty;
    defer b.deinit(gpa);
    try rect(gpa, &a, 0, 0, 3000, 3000);
    try rect(gpa, &b, 1000, 1000, 2000, 2000);
    var d = try difference(gpa, a, b);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), d.count());
    try testing.expectApproxEqAbs(@as(f64, 8.0), d.areaMm2(), 1e-9);
    // One loop is counterclockwise (outer) and one is clockwise (hole).
    const s0 = geom.area2(d.get(0)) > 0;
    const s1 = geom.area2(d.get(1)) > 0;
    try testing.expect(s0 != s1);
}

test "a clockwise input becomes counterclockwise" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, &.{ .init(0, 0), .init(0, 1000), .init(1000, 1000), .init(1000, 0) });
    var r = try unionAll(gpa, a, .non_zero);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expect(geom.area2(r.get(0)) > 0);
}

test "a bow tie with the positive rule keeps one triangle" {
    const gpa = testing.allocator;
    var a: Paths = .empty;
    defer a.deinit(gpa);
    // The left lobe is counterclockwise and the right lobe is clockwise.
    try a.append(gpa, &.{ .init(0, 0), .init(2000, 2000), .init(2000, 0), .init(0, 2000) });
    var pos = try unionAll(gpa, a, .positive);
    defer pos.deinit(gpa);
    var nz = try unionAll(gpa, a, .non_zero);
    defer nz.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), pos.count());
    try testing.expectEqual(@as(usize, 2), nz.count());
    try testing.expectApproxEqAbs(@as(f64, 1.0), pos.areaMm2(), 1e-9);
}

test "many random squares: union area is exact" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var a: Paths = .empty;
    defer a.deinit(gpa);
    var sum: f64 = 0;
    for (0..200) |_| {
        const x = rand.intRangeAtMost(i64, 0, 50_000);
        const y = rand.intRangeAtMost(i64, 0, 50_000);
        const s = rand.intRangeAtMost(i64, 500, 5_000);
        try rect(gpa, &a, x, y, x + s, y + s);
        sum += geom.toMm(s) * geom.toMm(s);
    }
    var r = try unionAll(gpa, a, .non_zero);
    defer r.deinit(gpa);
    const area = r.areaMm2();
    try testing.expect(area > 0 and area <= sum + 1e-6);
    // The exact area of the union, by coordinate compression: each cell of
    // the grid of all rectangle edges is in the union or not.
    // A regression test: a grid walk bug lost crossings of axis-aligned
    // edges, and the union lost 156 mm^2 here.
    try testing.expectApproxEqAbs(exactUnionArea(a), area, 1e-6);
    // The union of the union with itself has the same area.
    var r2 = try unite(gpa, r, r);
    defer r2.deinit(gpa);
    try testing.expectApproxEqAbs(area, r2.areaMm2(), 1e-6);
    // Each part of the union is inside the union, so a - union is empty.
    var d = try difference(gpa, a, r);
    defer d.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 0), d.areaMm2(), 1e-6);
}

fn exactUnionArea(rects: Paths) f64 {
    var xs: [400]i64 = undefined;
    var ys: [400]i64 = undefined;
    const n = rects.count();
    for (0..n) |i| {
        const r = rects.get(i);
        xs[2 * i] = r[0].x;
        xs[2 * i + 1] = r[2].x;
        ys[2 * i] = r[0].y;
        ys[2 * i + 1] = r[2].y;
    }
    std.mem.sortUnstable(i64, xs[0 .. 2 * n], {}, std.sort.asc(i64));
    std.mem.sortUnstable(i64, ys[0 .. 2 * n], {}, std.sort.asc(i64));
    var area: f64 = 0;
    for (0..2 * n - 1) |i| {
        if (xs[i] == xs[i + 1]) continue;
        for (0..2 * n - 1) |j| {
            if (ys[j] == ys[j + 1]) continue;
            const cx = xs[i] + xs[i + 1];
            const cy = ys[j] + ys[j + 1];
            for (0..n) |k| {
                const r = rects.get(k);
                if (cx > 2 * r[0].x and cx < 2 * r[2].x and cy > 2 * r[0].y and cy < 2 * r[2].y) {
                    area += geom.toMm(xs[i + 1] - xs[i]) * geom.toMm(ys[j + 1] - ys[j]);
                    break;
                }
            }
        }
    }
    return area;
}

test "random polygon pairs: union + intersection = A + B" {
    // A test from the code review: 1 in 20000 random pairs lost a loop. The
    // area identity finds a lost or extra loop.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var bad: usize = 0;
    for (0..3000) |_| {
        var a: Paths = .empty;
        defer a.deinit(gpa);
        var b: Paths = .empty;
        defer b.deinit(gpa);
        for ([_]*Paths{ &a, &b }) |p| {
            const n = rand.intRangeAtMost(usize, 3, 7);
            for (0..n) |_| try p.appendPoint(gpa, .init(rand.intRangeAtMost(i64, 0, 10_000), rand.intRangeAtMost(i64, 0, 10_000)));
            try p.endPath(gpa, 3);
        }
        // Normalize each input (random polygons cross themselves).
        var na = try unionAll(gpa, a, .non_zero);
        defer na.deinit(gpa);
        var nb = try unionAll(gpa, b, .non_zero);
        defer nb.deinit(gpa);
        var u = try unite(gpa, na, nb);
        defer u.deinit(gpa);
        var x = try intersect(gpa, na, nb);
        defer x.deinit(gpa);
        const lhs = u.areaMm2() + x.areaMm2();
        const rhs = na.areaMm2() + nb.areaMm2();
        if (@abs(lhs - rhs) > 0.01) bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
