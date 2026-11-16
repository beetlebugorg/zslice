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
//!    sides of the edge. The code casts a ray from the middle of the edge and
//!    adds the deltas of the edges the ray crosses.
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
    // passes.
    var cur: []InEdge = edges.items;
    var merged: []Merged = &.{};
    var pass: usize = 0;
    while (true) : (pass += 1) {
        var splits: std.ArrayList(Split) = .empty;
        try findIntersections(arena, cur, &splits);
        merged = try splitAndMerge(arena, cur, splits.items);
        if (splits.items.len == 0 or pass == max_passes) break;
        cur = try arena.alloc(InEdge, merged.len);
        for (merged, cur) |m, *e| e.* = .{ .a = m.lo, .b = m.hi, .d = m.d };
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

/// The most find-and-split passes. The limit stops a loop on bad input.
const max_passes = 8;

/// An input edge. `d` is the winding delta of each operand along a -> b.
const InEdge = struct {
    a: Point,
    b: Point,
    d: [2]i32,

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

/// Finds the split points with "sweep and prune". The edges are sorted by
/// their minimum x. A sweep goes from left to right and keeps a list of the
/// edges that the sweep position is in ("active"). Only active edges can
/// touch the new edge, so the code tests only those pairs. A layer of a
/// typical part has few edges at one x, so the test count stays small.
fn findIntersections(arena: Allocator, edges: []const InEdge, splits: *std.ArrayList(Split)) !void {
    const order = try arena.alloc(u32, edges.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sortUnstable(u32, order, edges, struct {
        fn lt(es: []const InEdge, a: u32, b: u32) bool {
            return es[a].minX() < es[b].minX();
        }
    }.lt);

    var active: std.ArrayList(u32) = .empty;
    for (order) |ei| {
        const e = edges[ei];
        const x = e.minX();
        const e_min_y = @min(e.a.y, e.b.y);
        const e_max_y = @max(e.a.y, e.b.y);
        // Remove the edges that end before this edge starts.
        var keep: usize = 0;
        for (active.items) |fi| {
            if (edges[fi].maxX() >= x) {
                active.items[keep] = fi;
                keep += 1;
            }
        }
        active.shrinkRetainingCapacity(keep);

        for (active.items) |fi| {
            const f = edges[fi];
            if (@max(f.a.y, f.b.y) < e_min_y or @min(f.a.y, f.b.y) > e_max_y) continue;
            try intersectPair(arena, splits, ei, e, fi, f);
        }
        try active.append(arena, ei);
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
};

fn splitAndMerge(arena: Allocator, edges: []const InEdge, splits: []Split) ![]Merged {
    // Sort the split points by edge, then by position along the edge.
    std.mem.sortUnstable(Split, splits, edges, struct {
        fn lt(es: []const InEdge, a: Split, b: Split) bool {
            if (a.edge != b.edge) return a.edge < b.edge;
            const e = es[a.edge];
            return dot3(e.a, e.b, a.p) < dot3(e.a, e.b, b.p);
        }
    }.lt);

    var subs: std.ArrayList(Merged) = .empty;
    try subs.ensureTotalCapacity(arena, edges.len + splits.len);
    var k: usize = 0;
    for (edges, 0..) |e, i| {
        var prev = e.a;
        while (k < splits.len and splits[k].edge == i) : (k += 1) {
            try addSub(arena, &subs, prev, splits[k].p, e.d);
            prev = splits[k].p;
        }
        try addSub(arena, &subs, prev, e.b, e.d);
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
        }
        if (m.d[0] != 0 or m.d[1] != 0) {
            items[out] = m;
            out += 1;
        }
        i = j;
    }
    return items[0..out];
}

fn addSub(arena: Allocator, subs: *std.ArrayList(Merged), a: Point, b: Point, d: [2]i32) !void {
    if (a.eql(b)) return;
    const m: Merged = if (a.lessThan(b))
        .{ .lo = a, .hi = b, .d = d }
    else
        .{ .lo = b, .hi = a, .d = .{ -d[0], -d[1] } };
    try subs.append(arena, m);
}

// ---------------------------------------------------------------------------
// Step 4

/// A bucket index along one axis. The axis range is cut into equal "slabs".
/// Each edge is in each slab that its range touches. A ray query looks only
/// at the edges in one slab.
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

    /// `axis` 0 indexes the non-vertical edges by x. `axis` 1 indexes the
    /// non-horizontal edges by y.
    fn build(arena: Allocator, edges: []const Merged, axis: u1) !SlabIndex {
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        var n: usize = 0;
        for (edges) |e| {
            const r = range(e, axis) orelse continue;
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
        // Count, then fill (compressed sparse rows).
        for (edges) |e| {
            const r = range(e, axis) orelse continue;
            for (s.slab(r[0])..s.slab(r[1]) + 1) |k| s.starts[k + 1] += 1;
        }
        for (1..s.starts.len) |k| s.starts[k] += s.starts[k - 1];
        s.items = try arena.alloc(u32, s.starts[slabs]);
        const fill = try arena.dupe(u32, s.starts[0..slabs]);
        for (edges, 0..) |e, i| {
            const r = range(e, axis) orelse continue;
            for (s.slab(r[0])..s.slab(r[1]) + 1) |k| {
                s.items[fill[k]] = @intCast(i);
                fill[k] += 1;
            }
        }
        return s;
    }

    fn range(e: Merged, axis: u1) ?[2]i64 {
        if (axis == 0) {
            if (e.lo.x == e.hi.x) return null;
            return .{ e.lo.x, e.hi.x };
        }
        if (e.lo.y == e.hi.y) return null;
        return .{ @min(e.lo.y, e.hi.y), @max(e.lo.y, e.hi.y) };
    }
};

fn double(p: Point) Point {
    return .{ .x = p.x * 2, .y = p.y * 2 };
}

/// Finds the winding numbers on the left of each edge.
///
/// The test point m is the middle of the edge. The code doubles all
/// coordinates so that m stays an integer.
///
/// - For a non-vertical edge, a ray goes down from m. Each non-vertical edge
///   below m adds its delta. An edge that goes in +x with the inside above
///   it (the bottom of a counterclockwise square) adds +1. The sum is the
///   winding number below the edge, on its right side.
/// - For a vertical edge, a ray goes left from m. The rule is the same, but
///   for x and y swapped. The sum is the winding number on the left side.
///
/// Each edge range is half open, [min, max). A ray that goes through a
/// vertex then counts only one of the two edges at that vertex.
fn computeWinding(arena: Allocator, edges: []Merged) !void {
    const by_x = try SlabIndex.build(arena, edges, 0);
    const by_y = try SlabIndex.build(arena, edges, 1);

    for (edges, 0..) |*e, ei| {
        const mx2 = e.lo.x + e.hi.x;
        const my2 = e.lo.y + e.hi.y;
        const m = Point{ .x = mx2, .y = my2 };
        var sum: [2]i32 = .{ 0, 0 };
        if (e.lo.x != e.hi.x) {
            for (by_x.get(@divFloor(mx2, 2))) |fi| {
                if (fi == ei) continue;
                const f = edges[fi];
                if (f.lo.x == f.hi.x) continue;
                if (!(2 * f.lo.x <= mx2 and mx2 < 2 * f.hi.x)) continue;
                // f goes in +x. m is above f if m is on the left of f.
                if (cross3(double(f.lo), double(f.hi), m) > 0) {
                    sum[0] += f.d[0];
                    sum[1] += f.d[1];
                }
            }
            // `sum` is the winding below, on the right of lo -> hi.
            e.left = .{ sum[0] + e.d[0], sum[1] + e.d[1] };
        } else {
            for (by_y.get(@divFloor(my2, 2))) |fi| {
                if (fi == ei) continue;
                const f = edges[fi];
                if (f.lo.y == f.hi.y) continue;
                const up = f.lo.y < f.hi.y;
                const u = if (up) f.lo else f.hi;
                const v = if (up) f.hi else f.lo;
                if (!(2 * u.y <= my2 and my2 < 2 * v.y)) continue;
                // f goes up from u to v. m is right of f if cross < 0.
                if (cross3(double(u), double(v), m) < 0) {
                    // An edge that goes down, on the left of the point,
                    // adds +1 (the left side of a counterclockwise square).
                    const s: i32 = if (up) 1 else -1;
                    sum[0] -= f.d[0] * s;
                    sum[1] -= f.d[1] * s;
                }
            }
            // A vertical edge goes in +y from lo to hi. `sum` is the
            // winding on its left.
            e.left = sum;
        }
    }
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
        if (geom.area2(loop.items[0..n]) == 0) continue;
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
    var best: ?usize = null;
    var best_turn: f64 = -10;
    const ux: f64 = @floatFromInt(v.x - from.x);
    const uy: f64 = @floatFromInt(v.y - from.y);
    var i = lo;
    while (i < edges.len and edges[i].a.eql(v)) : (i += 1) {
        if (edges[i].used) continue;
        const wx: f64 = @floatFromInt(edges[i].b.x - v.x);
        const wy: f64 = @floatFromInt(edges[i].b.y - v.y);
        // The signed turn angle from the incoming direction. Positive is left.
        const turn = std.math.atan2(ux * wy - uy * wx, ux * wx + uy * wy);
        if (turn > best_turn) {
            best_turn = turn;
            best = i;
        }
    }
    return best;
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

test "many random squares: union area is inside the expected range" {
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
    // The union of the union with itself has the same area.
    var r2 = try unite(gpa, r, r);
    defer r2.deinit(gpa);
    try testing.expectApproxEqAbs(area, r2.areaMm2(), 1e-6);
    // Each part of the union is inside the union, so a - union is empty.
    var d = try difference(gpa, a, r);
    defer d.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 0), d.areaMm2(), 1e-6);
}
