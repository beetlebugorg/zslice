//! A distance field of one layer on a grid, and the regions of its labels.
//!
//! Some questions about a layer are hard for polygons and easy for a
//! field. "Which painted edge is nearest to this point?" needs many
//! offsets and booleans with polygons (see paint_split.zig). With a field
//! it is one number for each node of a grid.
//!
//! The field has one array for each state (a state is a kind of source,
//! for example a filament of the paint). Each array has, for each node of
//! the grid, the square of the distance from the node to the nearest
//! source of the state:
//!
//! 1. Stamp. Each source (a segment, or the edge of a flat shape) writes
//!    its exact distance to the nodes within a radius of it, and each
//!    node keeps the least value. The distance is to the real segment, so
//!    the value of a node has no grid error.
//! 2. Label. The caller gives each node the label of the state that wins
//!    there (see `Field.dist`).
//! 3. Regions (`regions`). The border between two labels crosses each grid
//!    edge between two nodes with different labels at one point: the
//!    point where the two states are at the same distance, from the
//!    values of the two nodes (a linear estimate). A cell with two labels
//!    gets one straight piece of border between its two points. A cell
//!    with three or four labels, or with a label at two opposite corners
//!    only, gets a piece from each point to the center of the cell. Each
//!    piece is an edge of the region of the label on its left. Two labels
//!    make the same points and the same pieces, so their regions have no
//!    gap and no overlap between them.
//!
//! Each step is a loop over nodes or cells with no order between them, so
//! the steps can run on a GPU: one pass that writes the distance of all
//! sources to all nodes, or a jump flood (see docs/references/).
//!
//! References (see docs/references/papers-and-algorithms.md): marching
//! squares (the 2D form of marching cubes), the center point for cells
//! with many materials, the chamfer distance, and the jump flood.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const Point = geom.Point;
const Paths = geom.Paths;

/// The value of a node that no source reached.
pub const far: f32 = 1e30;

/// The nodes of one step of `Field.stampSegment`: the width of a vector
/// of the CPU, or 4.
const lanes: comptime_int = std.simd.suggestVectorLength(f32) orelse 4;

pub const Field = struct {
    /// The position of node (0, 0), and the step between nodes (units).
    x0: i64,
    y0: i64,
    h: i64,
    nx: usize,
    ny: usize,
    states: usize,
    /// d2[s * nx * ny + r * nx + c]: the square of the distance (units²)
    /// from node (c, r) to the nearest source of state s, or `far`.
    d2: []f32,

    /// A field over `box` with the step `h`, with all nodes at `far`.
    pub fn init(a: Allocator, box: geom.Box, h: i64, states: usize) Allocator.Error!Field {
        const nx: usize = @intCast(@divFloor(box.max.x - box.min.x, h) + 2);
        const ny: usize = @intCast(@divFloor(box.max.y - box.min.y, h) + 2);
        const d2 = try a.alloc(f32, states * nx * ny);
        @memset(d2, far);
        return .{ .x0 = box.min.x, .y0 = box.min.y, .h = h, .nx = nx, .ny = ny, .states = states, .d2 = d2 };
    }

    pub fn nodes(f: *const Field) usize {
        return f.nx * f.ny;
    }

    pub fn of(f: *const Field, s: usize) []f32 {
        return f.d2[s * f.nodes() ..][0..f.nodes()];
    }

    /// The distance (units) of state s at node n.
    pub fn dist(f: *const Field, s: usize, n: usize) f32 {
        return @sqrt(f.d2[s * f.nodes() + n]);
    }

    pub fn point(f: *const Field, c: usize, r: usize) Point {
        return .init(f.x0 + @as(i64, @intCast(c)) * f.h, f.y0 + @as(i64, @intCast(r)) * f.h);
    }

    /// The nodes within `radius` of the box of two points: the first and
    /// one past the last column and row.
    fn window(f: *const Field, lo: Point, hi: Point, radius: i64) ?[4]usize {
        const c0 = @max(@divFloor(lo.x - radius - f.x0, f.h), 0);
        const r0 = @max(@divFloor(lo.y - radius - f.y0, f.h), 0);
        const c1 = @min(@divFloor(hi.x + radius - f.x0, f.h) + 2, @as(i64, @intCast(f.nx)));
        const r1 = @min(@divFloor(hi.y + radius - f.y0, f.h) + 2, @as(i64, @intCast(f.ny)));
        if (c0 >= c1 or r0 >= r1) return null;
        return .{ @intCast(c0), @intCast(c1), @intCast(r0), @intCast(r1) };
    }

    /// Writes the distance to the segment pa pb, less `head`, to the nodes
    /// of state s within `radius` of the box of the segment. With a head,
    /// the source wins against a source with no head at the same distance.
    /// The inner loop has no branch on the data, and works on one vector
    /// of nodes a step.
    pub fn stampSegment(f: *Field, s: usize, pa: Point, pb: Point, radius: i64, head: f32) void {
        const win = f.window(.init(@min(pa.x, pb.x), @min(pa.y, pb.y)), .init(@max(pa.x, pb.x), @max(pa.y, pb.y)), radius) orelse return;
        const hf: f32 = @floatFromInt(f.h);
        const ax: f32 = @floatFromInt(pa.x - f.x0);
        const ay: f32 = @floatFromInt(pa.y - f.y0);
        const dx: f32 = @floatFromInt(pb.x - pa.x);
        const dy: f32 = @floatFromInt(pb.y - pa.y);
        const l2 = dx * dx + dy * dy;
        const inv: f32 = if (l2 > 0) 1 / l2 else 0;
        const arr = f.of(s);
        const rad: f32 = @floatFromInt(radius);
        const x_lo = @min(ax, ax + dx);
        const x_hi = @max(ax, ax + dx);
        const y_lo = @min(ay, ay + dy);
        const y_hi = @max(ay, ay + dy);
        const V = @Vector(lanes, f32);
        const steps: V = comptime blk: {
            var v: [lanes]f32 = undefined;
            for (&v, 0..) |*x, i| x.* = @floatFromInt(i);
            break :blk v;
        };
        for (win[2]..win[3]) |r| {
            const row_y = @as(f32, @floatFromInt(r)) * hf;
            const py = row_y - ay;
            // The part of the row within the radius of the box of the
            // segment.
            const off = @max(@max(y_lo - row_y, row_y - y_hi), 0);
            if (off > rad) continue;
            const reach = @sqrt(rad * rad - off * off);
            const c0 = @max(@as(i64, @intFromFloat(@floor((x_lo - reach) / hf))), @as(i64, @intCast(win[0])));
            const c1 = @min(@as(i64, @intFromFloat(@ceil((x_hi + reach) / hf))) + 1, @as(i64, @intCast(win[1])));
            if (c0 >= c1) continue;
            const row = arr[r * f.nx ..][@intCast(c0)..@intCast(c1)];
            const x_first = @as(f32, @floatFromInt(c0)) * hf - ax;
            var i: usize = 0;
            while (i + lanes <= row.len) : (i += lanes) {
                const px = @as(V, @splat(x_first + @as(f32, @floatFromInt(i)) * hf)) + steps * @as(V, @splat(hf));
                const dot = px * @as(V, @splat(dx)) + @as(V, @splat(py * dy));
                const t = @min(@max(dot * @as(V, @splat(inv)), @as(V, @splat(0))), @as(V, @splat(1)));
                const ex = px - t * @as(V, @splat(dx));
                const ey = @as(V, @splat(py)) - t * @as(V, @splat(dy));
                var d = ex * ex + ey * ey;
                if (head != 0) {
                    const e = @max(@sqrt(d) - @as(V, @splat(head)), @as(V, @splat(0)));
                    d = e * e;
                }
                const cur: V = row[i..][0..lanes].*;
                row[i..][0..lanes].* = @min(cur, d);
            }
            while (i < row.len) : (i += 1) {
                const px = x_first + @as(f32, @floatFromInt(i)) * hf;
                const t = @min(@max((px * dx + py * dy) * inv, 0), 1);
                const ex = px - t * dx;
                const ey = py - t * dy;
                var d = ex * ex + ey * ey;
                if (head != 0) {
                    const e = @max(@sqrt(d) - head, 0);
                    d = e * e;
                }
                row[i] = @min(row[i], d);
            }
        }
    }

    /// Writes 0 to the nodes of state s in the triangle (counterclockwise).
    pub fn fillTriangle(f: *Field, s: usize, tri: [3]Point) void {
        var lo = tri[0];
        var hi = tri[0];
        for (tri[1..]) |p| {
            lo = .init(@min(lo.x, p.x), @min(lo.y, p.y));
            hi = .init(@max(hi.x, p.x), @max(hi.y, p.y));
        }
        const win = f.window(lo, hi, 0) orelse return;
        const arr = f.of(s);
        for (win[2]..win[3]) |r| {
            for (win[0]..win[1]) |c| {
                const p = f.point(c, r);
                if (geom.cross3(tri[0], tri[1], p) < 0 or geom.cross3(tri[1], tri[2], p) < 0 or geom.cross3(tri[2], tri[0], p) < 0) continue;
                arr[r * f.nx + c] = 0;
            }
        }
    }

    /// For each node: 1 if it is inside `shape` (the non-zero rule), else
    /// 0. A scanline for each row of nodes.
    pub fn inside(f: *const Field, a: Allocator, shape: Paths) Allocator.Error![]u8 {
        const mask = try a.alloc(u8, f.nodes());
        @memset(mask, 0);
        // The crossings of each row, as a count and then a filled list.
        const start = try a.alloc(u32, f.ny + 1);
        @memset(start, 0);
        const X = struct { x: f32, w: i8 };
        var list: []X = &.{};
        for (0..2) |pass| {
            for (0..shape.count()) |pi| {
                const poly = shape.get(pi);
                for (poly, 0..) |p, i| {
                    const q = poly[(i + 1) % poly.len];
                    if (p.y == q.y) continue;
                    const up = q.y > p.y;
                    const y_lo = @min(p.y, q.y);
                    const y_hi = @max(p.y, q.y);
                    // The rows with y_lo <= y < y_hi.
                    const r0 = @max(@divFloor(y_lo - f.y0 + f.h - 1, f.h), 0);
                    const r1 = @min(@divFloor(y_hi - f.y0 + f.h - 1, f.h), @as(i64, @intCast(f.ny)));
                    var r = r0;
                    while (r < r1) : (r += 1) {
                        const ru: usize = @intCast(r);
                        if (pass == 0) {
                            start[ru + 1] += 1;
                            continue;
                        }
                        const y = f.y0 + r * f.h;
                        const t = @as(f64, @floatFromInt(y - p.y)) / @as(f64, @floatFromInt(q.y - p.y));
                        const x = @as(f64, @floatFromInt(p.x - f.x0)) + t * @as(f64, @floatFromInt(q.x - p.x));
                        list[start[ru]] = .{ .x = @floatCast(x), .w = if (up) 1 else -1 };
                        start[ru] += 1;
                    }
                }
            }
            if (pass == 0) {
                for (1..f.ny + 1) |r| start[r] += start[r - 1];
                list = try a.alloc(X, start[f.ny]);
            }
        }
        // After the fill, start[r] is the end of row r.
        const hf: f32 = @floatFromInt(f.h);
        for (0..f.ny) |r| {
            const row = list[(if (r == 0) 0 else start[r - 1])..start[r]];
            if (row.len == 0) continue;
            std.mem.sortUnstable(X, row, {}, struct {
                fn lt(_: void, u: X, v: X) bool {
                    return u.x < v.x;
                }
            }.lt);
            var wsum: i32 = 0;
            var k: usize = 0;
            for (0..f.nx) |c| {
                const x = @as(f32, @floatFromInt(c)) * hf;
                while (k < row.len and row[k].x <= x) : (k += 1) wsum += row[k].w;
                mask[r * f.nx + c] = @intFromBool(wsum != 0);
            }
        }
        return mask;
    }

    /// The chamfer distance (units) from the nodes with `seed` true: two
    /// passes over the grid, each node from its neighbors before it, with
    /// the steps h and h sqrt(2). The error is at most 8 %.
    pub fn chamfer(f: *const Field, a: Allocator, seed: []const bool) Allocator.Error![]f32 {
        const out = try a.alloc(f32, f.nodes());
        for (out, seed) |*o, s| o.* = if (s) 0 else far;
        const hf: f32 = @floatFromInt(f.h);
        const hd = hf * std.math.sqrt2;
        const nx = f.nx;
        for (0..f.ny) |r| for (0..nx) |c| {
            const n = r * nx + c;
            var v = out[n];
            if (c > 0) v = @min(v, out[n - 1] + hf);
            if (r > 0) {
                v = @min(v, out[n - nx] + hf);
                if (c > 0) v = @min(v, out[n - nx - 1] + hd);
                if (c + 1 < nx) v = @min(v, out[n - nx + 1] + hd);
            }
            out[n] = v;
        };
        var r = f.ny;
        while (r > 0) {
            r -= 1;
            var c = nx;
            while (c > 0) {
                c -= 1;
                const n = r * nx + c;
                var v = out[n];
                if (c + 1 < nx) v = @min(v, out[n + 1] + hf);
                if (r + 1 < f.ny) {
                    v = @min(v, out[n + nx] + hf);
                    if (c + 1 < nx) v = @min(v, out[n + nx + 1] + hd);
                    if (c > 0) v = @min(v, out[n + nx - 1] + hd);
                }
                out[n] = v;
            }
        }
        return out;
    }
};

/// The regions of the labels 1 and up (see step 3 in the file comment),
/// as closed loops with the region on their left. `label[n]` is the label
/// of node n. `score[l * nodes + n]` is the value of label l at node n:
/// the label of a node has the least score there. The border between two
/// nodes is where the scores of their two labels are equal. `out[l]`
/// gets the loops of label l, from `gpa` (out[0] stays empty). The nodes
/// on the border of the grid must have the label 0.
pub fn regions(gpa: Allocator, a: Allocator, f: *const Field, label: []const u8, score: []const f32, out: []Paths) Allocator.Error!void {
    const n_nodes = f.nodes();
    const edges = try a.alloc(std.ArrayList(clip.DirEdge), out.len);
    @memset(edges, .empty);
    const nx = f.nx;
    const half = @divFloor(f.h, 2);
    const Ctx = struct {
        f: *const Field,
        label: []const u8,
        score: []const f32,
        n_nodes: usize,
        /// The border point between node n and the next node in x or in
        /// y. Both cells of the edge get the same point.
        fn cut(c: @This(), n: usize, col: usize, row: usize, horizontal: bool) Point {
            const m = if (horizontal) n + 1 else n + c.f.nx;
            const la = c.label[n];
            const lb = c.label[m];
            const f1 = c.score[la * c.n_nodes + n] - c.score[lb * c.n_nodes + n];
            const f2 = c.score[la * c.n_nodes + m] - c.score[lb * c.n_nodes + m];
            // A node with a label against its scores (see the caller):
            // the middle.
            var t: f32 = 0.5;
            if (f1 <= 0 and f2 >= 0 and f2 - f1 > 0) t = f1 / (f1 - f2);
            t = @min(@max(t, 0.02), 0.98);
            const p = c.f.point(col, row);
            const step: i64 = @intFromFloat(@round(t * @as(f32, @floatFromInt(c.f.h))));
            return if (horizontal) .init(p.x + step, p.y) else .init(p.x, p.y + step);
        }
    };
    const ctx: Ctx = .{ .f = f, .label = label, .score = score, .n_nodes = n_nodes };
    for (0..f.ny - 1) |r| {
        for (0..nx - 1) |c| {
            const n0 = r * nx + c;
            // The corners, counterclockwise.
            const l: [4]u8 = .{ label[n0], label[n0 + 1], label[n0 + nx + 1], label[n0 + nx] };
            if (l[0] == l[1] and l[1] == l[2] and l[2] == l[3]) continue;
            // Edge k goes from corner k to corner k + 1.
            var pts: [4]Point = undefined;
            var has: [4]bool = @splat(false);
            var count: usize = 0;
            if (l[0] != l[1]) {
                pts[0] = ctx.cut(n0, c, r, true);
                has[0] = true;
                count += 1;
            }
            if (l[1] != l[2]) {
                pts[1] = ctx.cut(n0 + 1, c + 1, r, false);
                has[1] = true;
                count += 1;
            }
            if (l[2] != l[3]) {
                pts[2] = ctx.cut(n0 + nx, c, r + 1, true);
                has[2] = true;
                count += 1;
            }
            if (l[3] != l[0]) {
                pts[3] = ctx.cut(n0, c, r, false);
                has[3] = true;
                count += 1;
            }
            if (count == 2) {
                // Two labels: one piece. The label of the first corner of
                // the edge is on the left of a piece that starts there.
                var e: [2]usize = undefined;
                var k: usize = 0;
                for (has, 0..) |hk, i| if (hk) {
                    e[k] = i;
                    k += 1;
                };
                const la = l[e[0]];
                const lb = l[(e[0] + 1) % 4];
                if (!pts[e[0]].eql(pts[e[1]])) {
                    if (la != 0 and la < out.len) try edges[la].append(a, .{ .a = pts[e[0]], .b = pts[e[1]] });
                    if (lb != 0 and lb < out.len) try edges[lb].append(a, .{ .a = pts[e[1]], .b = pts[e[0]] });
                }
                continue;
            }
            // More labels, or a label at two opposite corners: each
            // point joins the center.
            const p00 = f.point(c, r);
            const center: Point = .init(p00.x + half, p00.y + half);
            for (has, 0..) |hk, i| if (hk) {
                const la = l[i];
                const lb = l[(i + 1) % 4];
                if (pts[i].eql(center)) continue;
                if (la != 0 and la < out.len) try edges[la].append(a, .{ .a = pts[i], .b = center });
                if (lb != 0 and lb < out.len) try edges[lb].append(a, .{ .a = center, .b = pts[i] });
            };
        }
    }
    for (out, edges) |*o, e| o.* = if (e.items.len == 0) .empty else try clip.loopsFromEdges(gpa, e.items);
}

const testing = std.testing;

test "field: the distance to a segment, and the inside of a square" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Field.init(a, .{ .min = .init(0, 0), .max = .init(1000, 1000) }, 100, 1);
    f.stampSegment(0, .init(200, 500), .init(800, 500), 1000, 0);
    // Node (5, 8) is 300 above the segment; node (0, 5) is 200 left of it.
    try testing.expectApproxEqAbs(@as(f32, 300), f.dist(0, 8 * f.nx + 5), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), f.dist(0, 5 * f.nx + 0), 0.01);
    var sq: Paths = .empty;
    try sq.append(a, &.{ .init(250, 250), .init(750, 250), .init(750, 750), .init(250, 750) });
    const mask = try f.inside(a, sq);
    try testing.expectEqual(@as(u8, 1), mask[5 * f.nx + 5]);
    try testing.expectEqual(@as(u8, 0), mask[5 * f.nx + 2]);
    try testing.expectEqual(@as(u8, 0), mask[8 * f.nx + 5]);
}

test "field: the regions of three labels have no gap and no overlap" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Three point sources (labels 1 to 3): each node within 1000 of a
    // source gets the label of the nearest one, and the rest label 0.
    var f = try Field.init(a, .{ .min = .init(0, 0), .max = .init(4000, 4000) }, 100, 4);
    const src = [3]Point{ .init(1200, 1300), .init(2800, 1400), .init(2000, 2900) };
    for (src, 1..) |p, s| f.stampSegment(s, p, p, 5000, 0);
    const n = f.nodes();
    const label = try a.alloc(u8, n);
    const score = try a.alloc(f32, 4 * n);
    for (0..n) |i| {
        score[i] = 1000;
        var best: usize = 0;
        for (1..4) |s| {
            score[s * n + i] = f.dist(s, i);
            if (score[s * n + i] < score[best * n + i]) best = s;
        }
        label[i] = @intCast(best);
    }
    var out: [4]Paths = @splat(.empty);
    defer for (&out) |*o| o.deinit(gpa);
    try regions(gpa, a, &f, label, score, &out);
    try testing.expect(out[0].isEmpty());
    var sum: f64 = 0;
    var all: Paths = .empty;
    defer all.deinit(gpa);
    for (out[1..]) |o| {
        try testing.expectEqual(@as(usize, 1), o.count());
        sum += o.areaMm2();
        const next = try clip.unite(gpa, all, o);
        all.deinit(gpa);
        all = next;
    }
    // The regions share their borders: the union has the sum of the
    // areas, and each pair has an empty intersection.
    try testing.expectApproxEqAbs(sum, all.areaMm2(), 1e-6);
    for (1..4) |i| for (i + 1..4) |j| {
        var common = try clip.intersect(gpa, out[i], out[j]);
        defer common.deinit(gpa);
        try testing.expect(common.isEmpty());
    };
    // The border of a label is on the bisector of two sources, or on the
    // circle of 1000 around its source, to within a step (a point at the
    // center of a cell is up to 0.71 steps from the true border).
    for (out[1..], src) |o, own| for (o.get(0)) |p| {
        const d = p.dist(own);
        try testing.expect(d <= 1100);
        for (src) |other| try testing.expect(d <= p.dist(other) + 100);
    };
}
