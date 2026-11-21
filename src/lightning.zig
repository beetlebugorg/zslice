//! Lightning infill: thin branches that hold up the top surfaces from
//! inside, and leave the rest of the inside empty. A display part needs
//! infill only under its tops, so it prints faster and uses less
//! plastic. The part is less strong.
//!
//! The branches of each layer are a forest: a set of trees of straight
//! segments. Each tree has one anchor: a point on the edge of the infill
//! area (at a wall, or at skin). The layers go from the top down, and each
//! layer starts with the trees of the layer above:
//!
//! 1. Prune. Each free end of a tree gets shorter by d = h tan(angle),
//!    along its branch. So the branches lean toward their anchor, and a
//!    tree gets smaller on each layer down, until it is gone. A point of
//!    a branch moves at most d from one layer to the next, so the line of
//!    each layer lies on the line of the layer below, or hangs over it by
//!    at most d: an overhang of `angle` from vertical.
//! 2. Straighten. A point of a branch with two neighbors moves toward the
//!    straight line between them, by at most d. A branch that bent around
//!    an obstacle gets straight again, and shorter.
//! 3. Clip. The trees are cut to the infill area of this layer. A part of
//!    a branch out of the area is over a wall or skin, which holds it. A
//!    piece that loses its anchor gets a new anchor where the cut is.
//!    An anchor that is now away from the edge (the area got larger) gets
//!    a straight line to the nearest point of the edge.
//! 4. Need. A point of this layer needs support if the layer above prints
//!    solid over it: it is in the infill area of this layer, but not in
//!    the infill area of the layer above. Skin, top support lines, and
//!    walls bridge a distance r = s / 2 (s: the line spacing of the
//!    density), so a point within r of the edge of the area, or of a
//!    branch, has support.
//! 5. Grow. Sample points on a fixed grid in the area that needs support,
//!    from the point nearest to the edge to the point farthest from it.
//!    A point that is not within r of a branch gets a new branch: a
//!    straight line to the nearest point of a branch or of the edge,
//!    whichever is nearer. The disc around the point up to that nearest
//!    point has no edge in it, so the line stays inside the area.
//!
//! The printed paths of a layer are the trees after step 5. Steps 1 to 3
//! need the trees of the layer above, so the layers go one after the
//! other; the infill areas and the areas that need support (step 4) are
//! made before, on all threads.
//!
//! Prior art (see docs/references/): Vanek et al., "Clever Support" (SGP
//! 2014); the tree supports of Meshmixer and of Cura (2017 to 2018); the
//! "Support Cubic" infill of PrusaSlicer 2.3 (2020 to 2021); Tricard,
//! Claux, and Lefebvre, "Ribbed Support Vaults for 3D Printing of Hollowed
//! Objects" (Computer Graphics Forum, 2020); and the lightning infill of
//! Cura 4.12 (December 2021). zslice follows the method as these sources
//! describe it. The code is new: no code of CuraEngine is copied.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const clip_open = @import("clip_open.zig");
const offset_mod = @import("offset.zig");
const infill = @import("infill.zig");
const parallel = @import("parallel.zig");
const Point = geom.Point;
const Paths = geom.Paths;

/// The input of one layer.
pub const Layer = struct {
    /// The area of the lightning infill (the infill area of the layer,
    /// moved in by the inset). Empty if the layer has no lightning infill.
    region: Paths = .empty,
    /// The distance that the solid lines above bridge, µm: half the line
    /// spacing of the density.
    reach: i64 = 0,
    /// The line width, µm.
    width: i64 = 400,
    /// The layer height, µm.
    height: i64 = 200,
};

/// The branches of each layer, as open paths. `tan_angle` is the tan of
/// the angle of the branches from vertical. The result has one Paths for
/// each layer, in `gpa`. Returns error.Canceled if `cancel` becomes true.
pub fn grow(gpa: Allocator, threads: usize, layers: []const Layer, tan_angle: f64, cancel: ?*const std.atomic.Value(bool)) (Allocator.Error || error{Canceled})![]Paths {
    const n = layers.len;
    const out = try gpa.alloc(Paths, n);
    for (out) |*o| o.* = .empty;
    errdefer {
        for (out) |*o| o.deinit(gpa);
        gpa.free(out);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Step 4 for all layers, on all threads.
    const need = try arena.alloc(Paths, n);
    for (need) |*x| x.* = .empty;
    const Need = struct {
        gpa: Allocator,
        layers: []const Layer,
        need: []Paths,
        cancel: ?*const std.atomic.Value(bool),
        fn run(c: *const @This(), i: usize) !void {
            if (c.cancel) |cc| if (cc.load(.acquire)) return error.Canceled;
            c.need[i] = try needArea(c.gpa, c.layers, i);
        }
    };
    const nc: Need = .{ .gpa = gpa, .layers = layers, .need = need, .cancel = cancel };
    defer for (need) |*x| x.deinit(gpa);
    parallel.forEach(threads, n, &nc, Need.run) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => unreachable,
    };

    // The grids cover the box of all layers.
    var box: geom.Box = .empty;
    var cell: i64 = std.math.maxInt(i64);
    for (layers) |l| {
        if (l.region.isEmpty()) continue;
        const b = l.region.bounds();
        box.extend(b.min);
        box.extend(b.max);
        cell = @min(cell, @max(l.reach, l.width));
    }
    if (box.isEmpty()) return out;
    const extent = @max(box.max.x - box.min.x, box.max.y - box.min.y);
    cell = @max(cell, @divTrunc(extent, 1024) + 1, 100);

    var forest: Forest = .{ .arena = arena };
    var bound: Grid = try .init(arena, box, cell);
    var tree: Grid = try .init(arena, box, cell);

    var i = n;
    while (i > 0) {
        i -= 1;
        if (cancel) |cc| if (cc.load(.acquire)) return error.Canceled;
        const l = layers[i];
        if (l.region.isEmpty()) {
            forest.clear();
            continue;
        }
        // The drop from the layer above to this layer.
        const h = if (i + 1 < n) layers[i + 1].height else l.height;
        const d = @as(f64, @floatFromInt(h)) * tan_angle;
        // Steps 1 and 2.
        if (forest.edges.items.len > 0) try forest.pruneAndStraighten(d);
        // Step 3.
        bound.clear();
        for (0..l.region.count()) |k| {
            const poly = l.region.get(k);
            for (poly, 0..) |p, q| _ = try bound.add(.{ p, poly[(q + 1) % poly.len] });
        }
        if (forest.edges.items.len > 0) {
            var chains: Paths = .empty;
            try forest.chains(arena, &chains);
            const pieces = try clip_open.clipPolylines(arena, l.region, chains, 0);
            try forest.rebuild(pieces);
            try forest.anchor(&bound, @divTrunc(l.width, 4));
        }
        // Step 5.
        if (!need[i].isEmpty()) {
            tree.clear();
            for (forest.edges.items) |e| _ = try tree.add(.{ forest.pts.items[e[0]], forest.pts.items[e[1]] });
            try forest.support(arena, need[i], &bound, &tree, l.reach);
        }
        if (forest.edges.items.len > 0) try forest.walks(gpa, &out[i]);
    }
    return out;
}

/// Step 4 for layer i: the area of layer i that the layer above prints
/// solid over, and that is farther than the reach from the edge of the
/// infill area. A strip of a line width along the infill area of the
/// layer above also has support (the edge of the lines above).
fn needArea(gpa: Allocator, layers: []const Layer, i: usize) Allocator.Error!Paths {
    const l = layers[i];
    if (l.region.isEmpty()) return .empty;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const inner = try offset_mod.offset(a, l.region, -l.reach, .{});
    if (inner.isEmpty()) return .empty;
    const above: Paths = if (i + 1 < layers.len) layers[i + 1].region else .empty;
    if (above.isEmpty()) return inner.clone(gpa);
    // Most layers have their inner area under the area above: then the
    // first difference is empty, and the offset of the area above is not
    // needed.
    const out = try clip.difference(a, inner, above);
    if (out.isEmpty()) return .empty;
    const grown = try offset_mod.offset(a, above, l.width, .{});
    const d = try clip.difference(a, out, grown);
    return d.clone(gpa);
}

/// The trees of one layer: points and the segments between them.
const Forest = struct {
    arena: Allocator,
    pts: std.ArrayList(Point) = .empty,
    /// The anchor of each tree: a point on the edge of the area.
    anchor_of: std.ArrayList(bool) = .empty,
    edges: std.ArrayList([2]u32) = .empty,

    fn clear(f: *Forest) void {
        f.pts.clearRetainingCapacity();
        f.anchor_of.clearRetainingCapacity();
        f.edges.clearRetainingCapacity();
    }

    fn addPoint(f: *Forest, p: Point, is_anchor: bool) Allocator.Error!u32 {
        try f.pts.append(f.arena, p);
        try f.anchor_of.append(f.arena, is_anchor);
        return @intCast(f.pts.items.len - 1);
    }

    /// The neighbors of each point, as compressed rows: the edges of point
    /// v are `adj[start[v]..start[v + 1]]` (edge indices).
    const Adj = struct { start: []u32, adj: []u32 };

    fn adjacency(f: *Forest, a: Allocator) Allocator.Error!Adj {
        const np = f.pts.items.len;
        const start = try a.alloc(u32, np + 1);
        @memset(start, 0);
        for (f.edges.items) |e| {
            start[e[0] + 1] += 1;
            start[e[1] + 1] += 1;
        }
        for (1..np + 1) |k| start[k] += start[k - 1];
        const adj = try a.alloc(u32, start[np]);
        const fill = try a.dupe(u32, start[0..np]);
        for (f.edges.items, 0..) |e, k| {
            adj[fill[e[0]]] = @intCast(k);
            fill[e[0]] += 1;
            adj[fill[e[1]]] = @intCast(k);
            fill[e[1]] += 1;
        }
        return .{ .start = start, .adj = adj };
    }

    /// Steps 1 and 2. Each point of a branch moves at most d: a point that
    /// the pruning removes is within d of the new end of its branch.
    fn pruneAndStraighten(f: *Forest, d: f64) Allocator.Error!void {
        var scratch_state = std.heap.ArenaAllocator.init(f.arena);
        defer scratch_state.deinit();
        const a = scratch_state.allocator();
        const np = f.pts.items.len;
        const g = try f.adjacency(a);
        const deg = try a.alloc(u32, np);
        for (0..np) |v| deg[v] = g.start[v + 1] - g.start[v];
        const edge_alive = try a.alloc(bool, f.edges.items.len);
        @memset(edge_alive, true);
        const alive = try a.alloc(bool, np);
        @memset(alive, true);
        // The farthest that a removed point is from this point, along the
        // branch. A later move of the point adds to it.
        const slack = try a.alloc(f64, np);
        @memset(slack, 0);
        const done = try a.alloc(bool, np);
        @memset(done, false);
        const pos = try a.alloc([2]f64, np);
        for (f.pts.items, pos) |p, *q| q.* = .{ @floatFromInt(p.x), @floatFromInt(p.y) };

        // Step 1.
        for (0..np) |v0| {
            if (deg[v0] != 1 or f.anchor_of.items[v0] or done[v0]) continue;
            var cur: u32 = @intCast(v0);
            while (true) {
                done[cur] = true;
                const budget = d - slack[cur];
                if (budget <= 0) break;
                // The one edge of `cur` that is left.
                var e_found: ?u32 = null;
                for (g.adj[g.start[cur]..g.start[cur + 1]]) |e| if (edge_alive[e]) {
                    e_found = e;
                    break;
                };
                const e = e_found orelse break;
                const ed = f.edges.items[e];
                const nb = if (ed[0] == cur) ed[1] else ed[0];
                const dx = pos[nb][0] - pos[cur][0];
                const dy = pos[nb][1] - pos[cur][1];
                const len = @sqrt(dx * dx + dy * dy);
                if (len > budget) {
                    pos[cur][0] += dx / len * budget;
                    pos[cur][1] += dy / len * budget;
                    slack[cur] = d;
                    break;
                }
                alive[cur] = false;
                edge_alive[e] = false;
                deg[nb] -= 1;
                slack[nb] = @max(slack[nb], slack[cur] + len);
                if (f.anchor_of.items[nb]) {
                    if (deg[nb] == 0) alive[nb] = false;
                    break;
                }
                if (deg[nb] != 1) break;
                cur = nb;
            }
        }
        // Step 2.
        for (0..np) |v| {
            if (!alive[v] or f.anchor_of.items[v] or deg[v] != 2) continue;
            var nbs: [2]u32 = undefined;
            var k: usize = 0;
            for (g.adj[g.start[v]..g.start[v + 1]]) |e| if (edge_alive[e]) {
                const ed = f.edges.items[e];
                nbs[k] = if (ed[0] == v) ed[1] else ed[0];
                k += 1;
            };
            const room = d - slack[v];
            if (room <= 0) continue;
            const t = closest(pos[nbs[0]], pos[nbs[1]], pos[v]);
            const dx = t[0] - pos[v][0];
            const dy = t[1] - pos[v][1];
            const len = @sqrt(dx * dx + dy * dy);
            if (len < 1) continue;
            const m = @min(room, len);
            pos[v][0] += dx / len * m;
            pos[v][1] += dy / len * m;
        }
        // The points and the edges that are left.
        const map = try a.alloc(u32, np);
        var pts: std.ArrayList(Point) = .empty;
        var anchors: std.ArrayList(bool) = .empty;
        for (0..np) |v| {
            if (!alive[v]) continue;
            map[v] = @intCast(pts.items.len);
            try pts.append(f.arena, .{ .x = @intFromFloat(@round(pos[v][0])), .y = @intFromFloat(@round(pos[v][1])) });
            try anchors.append(f.arena, f.anchor_of.items[v]);
        }
        var edges: std.ArrayList([2]u32) = .empty;
        for (f.edges.items, 0..) |e, k| {
            if (!edge_alive[k] or !alive[e[0]] or !alive[e[1]]) continue;
            try edges.append(f.arena, .{ map[e[0]], map[e[1]] });
        }
        f.pts = pts;
        f.anchor_of = anchors;
        f.edges = edges;
    }

    /// The forest as polylines: each polyline goes from a point that is
    /// not a plain middle point (an end, a fork, or an anchor) through the
    /// middle points to the next such point. A middle point on the
    /// straight line of its neighbors (within 5 µm) is left out.
    fn chains(f: *Forest, a: Allocator, out: *Paths) Allocator.Error!void {
        var scratch_state = std.heap.ArenaAllocator.init(f.arena);
        defer scratch_state.deinit();
        const s = scratch_state.allocator();
        const g = try f.adjacency(s);
        const used = try s.alloc(bool, f.edges.items.len);
        @memset(used, false);
        const pts = f.pts.items;
        const middle = struct {
            fn is(ff: *const Forest, gg: Adj, v: u32) bool {
                return !ff.anchor_of.items[v] and gg.start[v + 1] - gg.start[v] == 2;
            }
        }.is;
        var line: std.ArrayList(Point) = .empty;
        // Two passes: from the ends and forks, then the loops (none in a
        // forest, but a loop must not get lost).
        for (0..2) |pass| {
            for (0..pts.len) |v0| {
                if (pass == 0 and middle(f, g, @intCast(v0))) continue;
                for (g.adj[g.start[v0]..g.start[v0 + 1]]) |e0| {
                    if (used[e0]) continue;
                    line.clearRetainingCapacity();
                    try line.append(s, pts[v0]);
                    var v: u32 = @intCast(v0);
                    var e = e0;
                    while (true) {
                        used[e] = true;
                        const ed = f.edges.items[e];
                        const w = if (ed[0] == v) ed[1] else ed[0];
                        // Leave out the last point if it is on the line from
                        // the point before it to w.
                        if (line.items.len >= 2) {
                            const p0 = line.items[line.items.len - 2];
                            const p1 = line.items[line.items.len - 1];
                            if (lineDist(p0, pts[w], p1) < 5) line.items.len -= 1;
                        }
                        try line.append(s, pts[w]);
                        v = w;
                        if (!middle(f, g, w)) break;
                        var next: ?u32 = null;
                        for (g.adj[g.start[w]..g.start[w + 1]]) |e2| if (!used[e2]) {
                            next = e2;
                        };
                        e = next orelse break;
                    }
                    try out.append(a, line.items);
                }
            }
        }
    }

    /// The forest as few printed paths: each path starts at an end of a
    /// tree, and at a fork it goes on along the branch that turns least,
    /// until it reaches an end. A tree with k ends then needs about k / 2
    /// paths, with no travel inside a path.
    fn walks(f: *Forest, a: Allocator, out: *Paths) Allocator.Error!void {
        var scratch_state = std.heap.ArenaAllocator.init(f.arena);
        defer scratch_state.deinit();
        const s = scratch_state.allocator();
        const g = try f.adjacency(s);
        const used = try s.alloc(bool, f.edges.items.len);
        @memset(used, false);
        const left = try s.alloc(u32, f.pts.items.len);
        for (left, 0..) |*x, v| x.* = g.start[v + 1] - g.start[v];
        const pts = f.pts.items;
        var line: std.ArrayList(Point) = .empty;
        // Two passes: from the ends (one edge left), then from any point
        // with an edge left.
        for (0..2) |pass| {
            for (0..pts.len) |v0| {
                while (left[v0] > 0 and (pass == 1 or left[v0] == 1)) {
                    line.clearRetainingCapacity();
                    try line.append(s, pts[v0]);
                    var v: u32 = @intCast(v0);
                    var prev: ?Point = null;
                    while (left[v] > 0) {
                        // The unused edge that turns least.
                        var best: ?u32 = null;
                        var best_cos: f64 = -2;
                        for (g.adj[g.start[v]..g.start[v + 1]]) |e| {
                            if (used[e]) continue;
                            const ed = f.edges.items[e];
                            const w = if (ed[0] == v) ed[1] else ed[0];
                            const c = if (prev) |q| cosTurn(q, pts[v], pts[w]) else 0;
                            if (best == null or c > best_cos) {
                                best = e;
                                best_cos = c;
                            }
                        }
                        const e = best.?;
                        used[e] = true;
                        const ed = f.edges.items[e];
                        const w = if (ed[0] == v) ed[1] else ed[0];
                        left[v] -= 1;
                        left[w] -= 1;
                        // A plain middle point on the straight line goes.
                        if (line.items.len >= 2 and !f.anchor_of.items[v] and g.start[v + 1] - g.start[v] == 2) {
                            const p0 = line.items[line.items.len - 2];
                            if (lineDist(p0, pts[w], pts[v]) < 5) line.items.len -= 1;
                        }
                        try line.append(s, pts[w]);
                        prev = pts[v];
                        v = w;
                    }
                    try out.append(a, line.items);
                }
            }
        }
    }

    /// Makes the forest from the clipped polylines. A point that was a
    /// point of the forest before keeps its anchor mark. Then each tree
    /// keeps one anchor: an old anchor if it has one, else a new end (a
    /// point where the clip cut a branch), else any point.
    fn rebuild(f: *Forest, pieces: Paths) Allocator.Error!void {
        var scratch_state = std.heap.ArenaAllocator.init(f.arena);
        defer scratch_state.deinit();
        const s = scratch_state.allocator();
        var old: std.AutoHashMapUnmanaged(Point, bool) = .empty;
        for (f.pts.items, f.anchor_of.items) |p, an| {
            const gop = try old.getOrPut(s, p);
            if (!gop.found_existing) gop.value_ptr.* = an else gop.value_ptr.* = gop.value_ptr.* or an;
        }
        var ids: std.AutoHashMapUnmanaged(Point, u32) = .empty;
        var pts: std.ArrayList(Point) = .empty;
        var anchors: std.ArrayList(bool) = .empty;
        var cut: std.ArrayList(bool) = .empty;
        var edges: std.ArrayList([2]u32) = .empty;
        for (0..pieces.count()) |k| {
            const pl = pieces.get(k);
            var prev: ?u32 = null;
            for (pl) |p| {
                const gop = try ids.getOrPut(s, p);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(pts.items.len);
                    try pts.append(f.arena, p);
                    const was = old.get(p);
                    try anchors.append(f.arena, was orelse false);
                    try cut.append(s, was == null);
                }
                const id = gop.value_ptr.*;
                if (prev) |q| if (q != id) try edges.append(f.arena, .{ q, id });
                prev = id;
            }
        }
        // One anchor for each tree.
        const parent = try s.alloc(u32, pts.items.len);
        for (parent, 0..) |*x, k| x.* = @intCast(k);
        for (edges.items) |e| {
            const ra = find(parent, e[0]);
            const rb = find(parent, e[1]);
            if (ra != rb) parent[ra] = rb;
        }
        // The chosen point of each tree, and its rank: 2 an old anchor, 1
        // a cut, 0 another point.
        const best = try s.alloc(?u32, pts.items.len);
        @memset(best, null);
        const rank = try s.alloc(u8, pts.items.len);
        for (0..pts.items.len) |k| {
            const r = find(parent, @intCast(k));
            const my: u8 = if (anchors.items[k]) 2 else if (cut.items[k]) 1 else 0;
            if (best[r] == null or my > rank[r]) {
                best[r] = @intCast(k);
                rank[r] = my;
            }
        }
        for (0..pts.items.len) |k| anchors.items[k] = best[find(parent, @intCast(k))].? == k;
        f.pts = pts;
        f.anchor_of = anchors;
        f.edges = edges;
    }

    /// The end of step 3: an anchor more than `tol` from the edge gets a
    /// line to the nearest point of the edge, which becomes the anchor.
    fn anchor(f: *Forest, bound: *Grid, tol: i64) Allocator.Error!void {
        const np = f.pts.items.len;
        for (0..np) |v| {
            if (!f.anchor_of.items[v]) continue;
            const p = f.pts.items[v];
            const near = bound.nearest(p, std.math.inf(f64)) orelse continue;
            if (near.d <= @as(f64, @floatFromInt(tol))) continue;
            f.anchor_of.items[v] = false;
            const q = try f.addPoint(near.p, true);
            try f.edges.append(f.arena, .{ @intCast(v), q });
        }
    }

    /// Step 5.
    fn support(f: *Forest, a: Allocator, need: Paths, bound: *Grid, tree: *Grid, reach: i64) Allocator.Error!void {
        var scratch_state = std.heap.ArenaAllocator.init(a);
        defer scratch_state.deinit();
        const s = scratch_state.allocator();
        // The sample points: a fixed grid of step reach / 2, so that
        // layers with the same need get the same branches.
        const step = @max(@divTrunc(reach, 2), 50);
        const rows = try infill.lines(s, need, step, 0, 0);
        const Cand = struct { p: Point, d: f64, q: Point };
        var cands: std.ArrayList(Cand) = .empty;
        for (0..rows.count()) |k| {
            const r = rows.get(k);
            const x0 = @min(r[0].x, r[1].x);
            const x1 = @max(r[0].x, r[1].x);
            var x = (std.math.divCeil(i64, x0, step) catch unreachable) * step;
            while (x <= x1) : (x += step) {
                const p: Point = .{ .x = x, .y = r[0].y };
                const near = bound.nearest(p, std.math.inf(f64)) orelse continue;
                try cands.append(s, .{ .p = p, .d = near.d, .q = near.p });
            }
        }
        // Nearest to the edge first, so that the trees grow from the edge
        // in. A tie goes by the place, so that the order is the same on
        // each run.
        std.mem.sort(Cand, cands.items, {}, struct {
            fn lt(_: void, l: Cand, r: Cand) bool {
                if (l.d != r.d) return l.d < r.d;
                if (l.p.y != r.p.y) return l.p.y < r.p.y;
                return l.p.x < r.p.x;
            }
        }.lt);
        const rf: f64 = @floatFromInt(reach);
        for (cands.items) |c| {
            if (tree.within(c.p, rf)) continue;
            const p = try f.addPoint(c.p, false);
            const near = tree.nearest(c.p, c.d);
            if (near != null and near.?.d < c.d) {
                // Join the nearest branch: at one of its points, or at a new
                // point on the segment.
                const hit = near.?;
                const e = f.edges.items[hit.item];
                const u = f.pts.items[e[0]];
                const v = f.pts.items[e[1]];
                const j: u32 = if (u.dist(hit.p) < 20) e[0] else if (v.dist(hit.p) < 20) e[1] else blk: {
                    const m = try f.addPoint(hit.p, false);
                    f.edges.items[hit.item] = .{ e[0], m };
                    tree.set(hit.item, .{ u, hit.p });
                    try f.edges.append(f.arena, .{ m, e[1] });
                    _ = try tree.add(.{ hit.p, v });
                    break :blk m;
                };
                try f.edges.append(f.arena, .{ p, j });
                _ = try tree.add(.{ c.p, f.pts.items[j] });
            } else {
                // A new tree, anchored at the edge.
                const q = try f.addPoint(c.q, true);
                try f.edges.append(f.arena, .{ p, q });
                _ = try tree.add(.{ c.p, c.q });
            }
        }
    }
};

fn find(parent: []u32, x0: u32) u32 {
    var x = x0;
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

/// The point of the segment a-b nearest to p.
fn closest(a: [2]f64, b: [2]f64, p: [2]f64) [2]f64 {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const l2 = ex * ex + ey * ey;
    const t = if (l2 > 0) std.math.clamp(((p[0] - a[0]) * ex + (p[1] - a[1]) * ey) / l2, 0, 1) else 0;
    return .{ a[0] + t * ex, a[1] + t * ey };
}

/// The cosine of the turn at b, on the way from a over b to c: 1 straight
/// on, -1 back.
fn cosTurn(a: Point, b: Point, c: Point) f64 {
    const ux: f64 = @floatFromInt(b.x - a.x);
    const uy: f64 = @floatFromInt(b.y - a.y);
    const vx: f64 = @floatFromInt(c.x - b.x);
    const vy: f64 = @floatFromInt(c.y - b.y);
    const l = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    return if (l > 0) (ux * vx + uy * vy) / l else 0;
}

fn toF(p: Point) [2]f64 {
    return .{ @floatFromInt(p.x), @floatFromInt(p.y) };
}

/// The distance from p to the segment a-b.
fn lineDist(a: Point, b: Point, p: Point) f64 {
    const q = closest(toF(a), toF(b), toF(p));
    return @import("geom.zig").hypot(q[0] - @as(f64, @floatFromInt(p.x)), q[1] - @as(f64, @floatFromInt(p.y)));
}

/// Segments in a uniform grid of square cells, for the nearest segment
/// to a point. A long segment goes in each cell along it.
const Grid = struct {
    arena: Allocator,
    x0: i64,
    y0: i64,
    cell: i64,
    nx: usize,
    ny: usize,
    /// The first entry of each cell, or `none`.
    head: []u32,
    next: std.ArrayList(u32) = .empty,
    item: std.ArrayList(u32) = .empty,
    segs: std.ArrayList([2]Point) = .empty,
    /// The last query that saw each segment, so that a query looks at a
    /// segment once.
    seen: std.ArrayList(u32) = .empty,
    query: u32 = 0,

    const none = std.math.maxInt(u32);

    fn init(arena: Allocator, box: geom.Box, cell: i64) Allocator.Error!Grid {
        const x0 = box.min.x - cell;
        const y0 = box.min.y - cell;
        const nx: usize = @intCast(@divFloor(box.max.x - x0, cell) + 2);
        const ny: usize = @intCast(@divFloor(box.max.y - y0, cell) + 2);
        const head = try arena.alloc(u32, nx * ny);
        @memset(head, none);
        return .{ .arena = arena, .x0 = x0, .y0 = y0, .cell = cell, .nx = nx, .ny = ny, .head = head };
    }

    fn clear(g: *Grid) void {
        @memset(g.head, none);
        g.next.clearRetainingCapacity();
        g.item.clearRetainingCapacity();
        g.segs.clearRetainingCapacity();
        g.seen.clearRetainingCapacity();
    }

    fn cx(g: *const Grid, x: i64) usize {
        return @intCast(std.math.clamp(@divFloor(x - g.x0, g.cell), 0, @as(i64, @intCast(g.nx - 1))));
    }

    fn cy(g: *const Grid, y: i64) usize {
        return @intCast(std.math.clamp(@divFloor(y - g.y0, g.cell), 0, @as(i64, @intCast(g.ny - 1))));
    }

    fn put(g: *Grid, c: usize, id: u32) Allocator.Error!void {
        if (g.head[c] != none and g.item.items[g.head[c]] == id) return;
        try g.next.append(g.arena, g.head[c]);
        try g.item.append(g.arena, id);
        g.head[c] = @intCast(g.item.items.len - 1);
    }

    fn index(g: *Grid, id: u32, s: [2]Point) Allocator.Error!void {
        // Pieces no longer than a cell: each touches at most 4 cells.
        const len = s[0].dist(s[1]);
        const parts: usize = @intFromFloat(@ceil(len / @as(f64, @floatFromInt(g.cell))) + 1);
        var prev = s[0];
        for (1..parts + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(parts));
            const p: Point = .{
                .x = s[0].x + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(s[1].x - s[0].x)) * t))),
                .y = s[0].y + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(s[1].y - s[0].y)) * t))),
            };
            const xa = g.cx(@min(prev.x, p.x));
            const xb = g.cx(@max(prev.x, p.x));
            const ya = g.cy(@min(prev.y, p.y));
            const yb = g.cy(@max(prev.y, p.y));
            for (ya..yb + 1) |y| for (xa..xb + 1) |x| try g.put(y * g.nx + x, id);
            prev = p;
        }
    }

    fn add(g: *Grid, s: [2]Point) Allocator.Error!u32 {
        const id: u32 = @intCast(g.segs.items.len);
        try g.segs.append(g.arena, s);
        try g.seen.append(g.arena, 0);
        try g.index(id, s);
        return id;
    }

    /// Makes segment `id` shorter (a part of the old segment): its cells
    /// stay as they are.
    fn set(g: *Grid, id: u32, s: [2]Point) void {
        g.segs.items[id] = s;
    }

    const Hit = struct { item: u32, p: Point, d: f64 };

    fn visit(g: *Grid, c: usize, p: Point, best: *?Hit) void {
        var e = g.head[c];
        while (e != none) : (e = g.next.items[e]) {
            const id = g.item.items[e];
            if (g.seen.items[id] == g.query) continue;
            g.seen.items[id] = g.query;
            const s = g.segs.items[id];
            const q = closest(toF(s[0]), toF(s[1]), toF(p));
            const d = @import("geom.zig").hypot(q[0] - @as(f64, @floatFromInt(p.x)), q[1] - @as(f64, @floatFromInt(p.y)));
            if (best.* == null or d < best.*.?.d) best.* = .{ .item = id, .p = .{ .x = @intFromFloat(@round(q[0])), .y = @intFromFloat(@round(q[1])) }, .d = d };
        }
    }

    /// The nearest point of a segment to p, if one is within `limit`.
    fn nearest(g: *Grid, p: Point, limit: f64) ?Hit {
        if (g.segs.items.len == 0) return null;
        g.query +%= 1;
        if (g.query == 0) {
            @memset(g.seen.items, 0);
            g.query = 1;
        }
        const px = g.cx(p.x);
        const py = g.cy(p.y);
        const cf: f64 = @floatFromInt(g.cell);
        var best: ?Hit = null;
        var k: usize = 0;
        const kmax = @max(g.nx, g.ny);
        while (k <= kmax) : (k += 1) {
            // The cells of ring k around (px, py).
            const y_lo = if (py >= k) py - k else 0;
            const y_hi = @min(py + k, g.ny - 1);
            const x_lo = if (px >= k) px - k else 0;
            const x_hi = @min(px + k, g.nx - 1);
            for (y_lo..y_hi + 1) |y| {
                const edge_row = y + k == py or y == py + k;
                if (edge_row) {
                    for (x_lo..x_hi + 1) |x| g.visit(y * g.nx + x, p, &best);
                } else {
                    if (px >= k) g.visit(y * g.nx + px - k, p, &best);
                    if (px + k < g.nx and k > 0) g.visit(y * g.nx + px + k, p, &best);
                }
            }
            // A cell of ring k + 1 is at least k cells from p.
            const ring_d = @as(f64, @floatFromInt(k)) * cf;
            if (best) |b| if (b.d <= ring_d) break;
            if (ring_d > limit) break;
        }
        if (best) |b| if (b.d > limit) return null;
        return best;
    }

    /// True if a segment is within r of p.
    fn within(g: *Grid, p: Point, r: f64) bool {
        if (g.segs.items.len == 0) return false;
        const ri: i64 = @intFromFloat(@ceil(r));
        const xa = g.cx(p.x - ri);
        const xb = g.cx(p.x + ri);
        const ya = g.cy(p.y - ri);
        const yb = g.cy(p.y + ri);
        for (ya..yb + 1) |y| for (xa..xb + 1) |x| {
            var e = g.head[y * g.nx + x];
            while (e != none) : (e = g.next.items[e]) {
                const s = g.segs.items[g.item.items[e]];
                if (lineDist(s[0], s[1], p) <= r) return true;
            }
        };
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn square(a: Allocator, x0: i64, y0: i64, x1: i64, y1: i64) !Paths {
    var p: Paths = .empty;
    try p.append(a, &.{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) });
    return p;
}

fn pathLen(set: Paths) f64 {
    var len: f64 = 0;
    for (0..set.count()) |k| {
        const pl = set.get(k);
        for (pl[0 .. pl.len - 1], pl[1..]) |u, v| len += u.dist(v);
    }
    return len;
}

/// True if p is within `tol` of a segment of `set`.
fn nearSet(set: Paths, p: Point, tol: f64) bool {
    for (0..set.count()) |k| {
        const pl = set.get(k);
        for (pl[0 .. pl.len - 1], pl[1..]) |u, v| if (lineDist(u, v, p) <= tol) return true;
    }
    return false;
}

fn nearEdge(region: Paths, p: Point, tol: f64) bool {
    for (0..region.count()) |k| {
        const poly = region.get(k);
        for (poly, 0..) |u, q| if (lineDist(u, poly[(q + 1) % poly.len], p) <= tol) return true;
    }
    return false;
}

test "lightning: a box with a top" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 300 layers of 0.2 mm. The infill area is a 40 mm square on layers
    // 3 to 289; layers 290 to 299 are the top skin.
    const n = 300;
    const ls = try a.alloc(Layer, n);
    const sq = try square(a, 0, 0, 40_000, 40_000);
    const reach = 2000;
    for (ls, 0..) |*l, i| l.* = .{ .region = if (i >= 3 and i < 290) sq else .empty, .reach = reach, .width = 400, .height = 200 };
    const tan40 = @tan(40.0 * std.math.pi / 180.0);
    const out = try grow(testing.allocator, 1, ls, tan40, null);
    defer {
        for (out) |*o| o.deinit(testing.allocator);
        testing.allocator.free(out);
    }
    // The top layer of the infill: each point of the area that needs
    // support is within the reach (and a grid step) of a branch or the edge.
    const top = out[289];
    try testing.expect(top.count() > 0);
    var y: i64 = 0;
    while (y <= 40_000) : (y += 700) {
        var x: i64 = 0;
        while (x <= 40_000) : (x += 700) {
            const p: Point = .init(x, y);
            try testing.expect(nearSet(top, p, reach * 1.6) or nearEdge(sq, p, reach * 1.6));
        }
    }
    // Far below the top, the trees are gone. A path from the edge to the
    // end of a branch is at most 30 mm long (half the side, and its
    // bends), and it gets shorter by h tan(40) on each layer.
    const drop: usize = @intFromFloat(@ceil(30_000.0 / (200.0 * tan40)));
    try testing.expect(289 > drop);
    for (3..289 - drop) |i| try testing.expectEqual(@as(usize, 0), out[i].count());
    // Less line below: the trees get smaller.
    try testing.expect(pathLen(out[250]) < pathLen(out[289]));
    // Each branch stays in the area, and each point of a branch has a
    // branch or the edge of the area under it, within h tan(40) (with a
    // little for the rounding).
    const reach_down = 200 * tan40 + 15;
    for (4..290) |i| {
        for (0..out[i].count()) |k| {
            const pl = out[i].get(k);
            for (pl[0 .. pl.len - 1], pl[1..]) |u, v| {
                for (0..11) |q| {
                    const t = @as(f64, @floatFromInt(q)) / 10;
                    const p: Point = .{
                        .x = u.x + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(v.x - u.x)) * t))),
                        .y = u.y + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(v.y - u.y)) * t))),
                    };
                    try testing.expect(geom.insideAny(sq, p) or nearEdge(sq, p, 5));
                    try testing.expect(nearSet(out[i - 1], p, reach_down) or nearEdge(sq, p, reach_down));
                }
            }
        }
    }
}

test "lightning: a small top on a large box" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A 40 mm box up to layer 49, then a 10 mm tower on its middle up to
    // layer 99. The tower top needs support only under its own top
    // (it is narrower than two reaches, so its walls hold it).
    const n = 100;
    const ls = try a.alloc(Layer, n);
    const big = try square(a, 0, 0, 40_000, 40_000);
    const small = try square(a, 15_000, 15_000, 25_000, 25_000);
    for (ls, 0..) |*l, i| l.* = .{
        .region = if (i < 3) .empty else if (i < 45) big else if (i < 50) .empty else if (i < 95) small else .empty,
        .reach = 2000,
        .width = 400,
        .height = 200,
    };
    const out = try grow(testing.allocator, 2, ls, @tan(40.0 * std.math.pi / 180.0), null);
    defer {
        for (out) |*o| o.deinit(testing.allocator);
        testing.allocator.free(out);
    }
    try testing.expect(out[94].count() > 0);
    try testing.expect(out[44].count() > 0);
    // Under the tower, its trees end before the box: the skin of the box
    // top holds them, and the box infill starts again below.
    for (45..50) |i| try testing.expectEqual(@as(usize, 0), out[i].count());
    // All branches of the tower stay in the tower.
    for (50..95) |i| for (0..out[i].count()) |k| for (out[i].get(k)) |p| {
        try testing.expect(p.x >= 14_990 and p.x <= 25_010 and p.y >= 14_990 and p.y <= 25_010);
    };
}
