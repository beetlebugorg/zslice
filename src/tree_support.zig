//! Tree support: planned trees of straight branches that hold up the
//! overhangs and go down to the bed (or to the part).
//!
//! Grid support fills all the space under an overhang. A tree touches the
//! overhang only at points, so it uses less plastic, comes off more
//! easily, and leaves fewer marks on the part. Each tree is planned before
//! it is built, so equal overhangs get equal trees: a tree depends on the
//! shape of its overhang and of the part near it, and on no order of
//! nodes or threads. The method:
//!
//! 1. Regions. The tip area of a layer is the overhang of the layer
//!    `tips_below` layers up (from support.zig, step 1), minus the part.
//!    Each island of a tip area is a polygon. Two islands are in the same
//!    region if they are at most half a tip spacing apart and at most 3
//!    layers apart. So the thin strips of the layers of a slope make one
//!    region, and two ledges side by side make two regions.
//! 2. Tips. Each region has an anchor: the centroid of its islands
//!    (weighted by area). The tips go on a triangle grid around the
//!    anchor, `support_tree_spacing` apart. A grid point in an island
//!    gets a tip on the layer of that island. A grid point just outside
//!    the region (up to 0.6 spacings) gets a tip at the nearest point of
//!    the region, moved in by a tip radius, so that the edges of the pads
//!    have support. Tips nearer than half a spacing join at their mean
//!    point (all tips of a group at once, so no order counts). An island
//!    with no tip gets one. A tip near the part moves out until it has
//!    room for its radius. The pad above spans the gap. The grid is
//!    symmetric about the anchor: a mirror or a move of the part moves
//!    the tips with it.
//! 3. The plan. The tips of a region join in levels. Level k puts the
//!    branches in square cells of side sqrt(2) * 2^k spacings, on a
//!    lattice centered on the anchor. The branches of a cell join at
//!    their centroid (weighted by their tips), on the highest layer where
//!    each of them can reach it with a straight segment that leans at
//!    most the branch angle (`plan_lean`). Then, in rounds, the branches that
//!    are each other's nearest branch join (`pairs`); a branch with
//!    several nearest branches at the same distance joins them all, so a
//!    mirror of the part gives the mirror of the plan. Last, the trunks of
//!    all regions join in the same rounds, if they are near (`forest`)
//!    and if the join is high enough to save plastic (`worth`).
//!    A join must have room (`fits`): it is above the foot, out of the
//!    part by its radius, out of the avoidance area (see 4.), and each
//!    segment to it stays out of the part. If the centroid has no room,
//!    the join tries lower layers (1 mm apart), then the place of the
//!    heaviest branch (the others lean to it), then a push out of the
//!    part. A cell or a pair that cannot join keeps its branches apart.
//!    The branches that are left at the end are the trunks. So a tree is
//!    a few levels of straight branches into one trunk, at a place that
//!    the shape of the overhang sets, and no node order counts.
//! 4. Build, one layer at a time from the top down. Each branch is a node:
//!    a center and a radius. A node goes in a straight line to its join,
//!    and arrives on the layer of the join; a trunk goes straight down.
//!    On the join layer, the branches of the join become one node at
//!    their mean point. A branch that was pushed away and is not yet in
//!    the circle of its join follows it, and joins when it is. Two trunks
//!    whose circles are less than 3 spacings apart (for example after a
//!    bend around the part) move toward each other, if they can meet over
//!    the foot, and join when one circle holds the other (`touch`).
//!    To reach the bed (not rest on the part), a branch stays out of the
//!    avoidance area of each layer: the points from which no branch can
//!    reach the bed. Layer 0 avoids the part. Layer j avoids the part
//!    and the layers under it (the Z gap), and the avoidance of layer j - 1
//!    moved in by one step: a point deeper in it than one step cannot get
//!    out in time. A branch in the avoidance area moves out of it, if it
//!    can in one step. So a branch over the part bends out and around the
//!    part, and goes down beside it to the bed. (Cura's tree support uses
//!    an avoidance area in the same way; see REFERENCES.md.)
//!    A branch keeps the XY gap from the part (`fit` moves it before it
//!    makes it thinner); its top layers keep only the smaller gap under
//!    an overhang, so that the tips under a slope stay. A branch in the
//!    gap stops: it rests on the part (it stops the Z gap above it), or,
//!    with bed-only support, it is removed. The last circle of a branch on
//!    the part gets smaller where it reaches past the edge of the part, so
//!    that it does not hang in the air.
//! 5. The size, from physics. A hollow branch is a tube fixed at the bed.
//!    The nozzle pushes on its top from the side; the radius at each
//!    height keeps the bend of the highest tip over it under a set amount
//!    (`Params.bend`), and the tube must not buckle under the push down
//!    of the nozzle (`Params.buckle`). Under a tip, a branch gets wider at
//!    45 degrees to at least `min_r`. A join has the radius of its widest
//!    branch, and its centers meet, so there is no collar. The foot of a
//!    branch on the bed gets wider at 45 degrees, to a radius that holds
//!    the push of the nozzle at the top against the pull off the bed
//!    (`Params.peel`). Then each branch is made at least as thick as the
//!    branch above it (`steady`), and, from the bed up, a circle must be
//!    in the circle under it moved out by two tip radii (`taper`), so no
//!    part of a branch hangs in the air.
//! 6. The skeleton. Each branch becomes a chain of nodes with straight
//!    segments between them (support_skeleton.zig): a node where the
//!    path bends, and the nodes of the joins. The area of each layer is
//!    the union of the circles of the segments, minus the part.
//!    support.zig then adds the interface. The layer plan prints a tree
//!    hollow: one wall loop, with its seam at the rear, and no lines. A
//!    hollow branch uses less plastic and prints faster. Some circles
//!    print filled (the loop and the support lines): the `fill_layers`
//!    layers over the bed layer, so that the foot is stiff, and the
//!    `fill_layers` layers under each tip, under the pad. (Cura prints a
//!    tree with one wall and no lines; see REFERENCES.md.)
//!
//! The edges of the part come from an edge index (geom.EdgeIndex), made
//! once per layer. The unions of the circles run on all threads. A fast
//! mode for a drag (fewer layers, a wider spacing) can use the same plan
//! with a larger layer step.
//!
//! The idea of tree support is common in FDM slicers (Cura "tree support",
//! PrusaSlicer "organic" support; see REFERENCES.md). The method and the
//! code here are new.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const offset_mod = @import("offset.zig");
const clip = @import("clip.zig");
const settings_mod = @import("settings.zig");
const slicer = @import("slicer.zig");
const skel_mod = @import("support_skeleton.zig");
const Point = geom.Point;
const Paths = geom.Paths;

const none = skel_mod.none;

const Node = struct {
    x: f64,
    y: f64,
    /// The radius of this layer, in µm (`want`, or less in a narrow
    /// space).
    r: f64,
    /// The radius that the branch should have here, µm (see 5. in the
    /// header). A narrow space makes `r` smaller on one layer only.
    want: f64 = 0,
    /// The layer of the highest tip of the branch (or of a branch that
    /// joins it), for the bend rule.
    top: u32 = 0,
    alive: bool = true,
    /// The branch can still reach the bed (it is out of the avoidance
    /// area, or one step from its edge).
    free: bool = true,
    /// The layers since the tip.
    age: u32 = 0,
    /// The branch of the node (see `Branches`).
    id: u32 = none,
    /// The node of the plan that this branch follows.
    plan: u32 = none,
    /// The branch missed its join on the join layer, and follows the
    /// joined branch until it is in its circle.
    chase: bool = false,
};

/// The avoidance area is made on every 5th layer (see `avoidance`).
const avoid_every: usize = 5;

/// The branches: a branch ends where it joins another branch (`into`).
const Branches = struct {
    into: std.ArrayList(u32) = .empty,
};

/// A node of the plan (step 3): a tip, or a join of branches.
const PlanNode = struct {
    x: f64,
    y: f64,
    /// The layer of the tip, or of the join.
    layer: u32,
    /// The join that this branch goes to, or `none` (a trunk).
    parent: u32 = none,
    /// The number of tips over it.
    weight: f64 = 1,
    /// The layer of the highest tip over it.
    top: u32,
    /// The branch can reach the bed: a tip out of the avoidance area, or
    /// a join of such branches.
    free: bool = true,
};

/// An island of the tip area of a layer (step 1).
const Island = struct {
    j: u32,
    poly: []const Point,
    box: geom.Box,
    area: f64,
    cx: f64,
    cy: f64,
};

pub const Params = struct {
    /// The radius of a tip, µm.
    tip: f64,
    /// The largest radius, µm.
    max_r: f64,
    /// The radius grows by this for each µm that a branch goes down.
    growth: f64,
    /// tan of the branch angle from vertical.
    tan_angle: f64,
    /// The distance of the tips, µm.
    spacing: f64,
    /// Empty layers between a branch and the part under it.
    z_gap: usize,
    /// Branches must reach the bed.
    bed_only: bool,
    /// The top layers of a branch keep only the XY gap under an overhang
    /// (`near`); the layers below keep the full XY gap (`blocked`).
    tip_layers: u32 = 3,
    /// The least radius of a branch on the bed, µm.
    foot: f64 = 0,
    /// A branch prints hollow (a wall loop only), but these layers are
    /// filled: the layers at its foot over the bed layer, and the layers
    /// under its tip.
    fill_layers: u32 = 3,
    /// A branch joins its join when its circle is in the circle of the
    /// join, up to this distance, µm.
    join_slack: f64 = 250,
    /// The bend rule. A branch is a tube fixed at the bed, and the nozzle
    /// pushes on its top layer from the side. With a tip at L mm over a
    /// point of the branch, the radius there must be at least
    /// cbrt(bend * L^3) mm, so that the tip bends by at most a set amount:
    /// a thin-walled tube of radius r and wall t bends by
    /// F L^3 / (3 E pi r^3 t). bend = F / (3 E pi t d), with F the push of
    /// the nozzle, E the stiffness of the plastic, and d the bend that the
    /// print allows (see support.zig). 0: no bend rule.
    bend: f64 = 0,
    /// The buckling rule. A tube fixed at the bed and free at the top
    /// buckles under a load P at P = pi^2 E I / (4 L^2), with I = pi r^3 t.
    /// The radius must be at least cbrt(buckle * L^2) mm, with
    /// buckle = 4 P s / (pi^3 E t) and s a safety factor. 0: no rule.
    buckle: f64 = 0,
    /// The foot rule. The push F of the nozzle at a height H pulls the
    /// foot off the bed with a moment F H. A disk of radius R holds a
    /// moment of pi R^3 sigma / 4, with sigma the hold of the bed. So the
    /// foot radius is at least cbrt(peel * H) mm, with
    /// peel = 4 F / (pi sigma). 0: no rule.
    peel: f64 = 0,
    /// The least radius of a branch under its tip layers, µm. A branch
    /// with no room for it rests on the part, or stops.
    min_r: f64 = 0,
    /// Trunks whose circles are at most this many spacings apart move
    /// toward each other and join (see `touch`).
    touch: f64 = 3,
    /// The trunks of regions at most this many spacings apart are
    /// planned together, so that they can join.
    forest: f64 = 8,
    /// A join of the trunks of two regions must be at least this many
    /// times as high over the bed as its segments reach out (the sum of
    /// two segments): a low join of two trees saves little, and makes
    /// long slanted segments.
    worth: f64 = 1.5,
    /// The plan leans a segment at most this part of the branch angle,
    /// so that a branch has room to move around the part.
    plan_lean: f64 = 1,
};

/// The tree areas of each layer: `body` is the union of the circles, and
/// `filled` the part of it that prints with lines (see `Params.fill_layers`).
pub const Areas = struct {
    body: []Paths,
    filled: []Paths,
};

/// The edge indexes of a set of layer areas, made when first needed.
const Indexes = struct {
    a: Allocator,
    src: []const Paths,
    pad: f64,
    /// Layers share the index of layer j - j % every (for the avoidance
    /// area, which is the same on those layers).
    every: usize = 1,
    cache: []?geom.EdgeIndex,
    built: []bool,

    fn init(a: Allocator, src: []const Paths, pad: f64, every: usize) Allocator.Error!Indexes {
        const c = try a.alloc(?geom.EdgeIndex, src.len);
        const b = try a.alloc(bool, src.len);
        @memset(b, false);
        return .{ .a = a, .src = src, .pad = pad, .every = every, .cache = c, .built = b };
    }

    fn get(x: *Indexes, layer: usize) Allocator.Error!?geom.EdgeIndex {
        const j = layer - layer % x.every;
        if (!x.built[j]) {
            x.cache[j] = try index(x.a, x.src[j], x.pad);
            x.built[j] = true;
        }
        return x.cache[j];
    }
};

/// The tree areas of each layer. `need[i]` is the overhang of layer i,
/// `blocked[i]` the outline of layer i moved out by the XY gap, `near[i]`
/// the outline moved out by the smaller XY gap under an overhang, and
/// `tips_below` the number of layers from an overhang down to its tips
/// (1 + Z gap + interface layers). The result has one Paths for each
/// layer, in `gpa`.
pub fn grow(
    gpa: Allocator,
    threads: usize,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    need: []const Paths,
    blocked: []const Paths,
    near: []const Paths,
    tips_below: usize,
    params: Params,
) Allocator.Error!Areas {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sk = try plan(gpa, arena, threads, outlines, layers, need, blocked, near, tips_below, params);
    defer sk.deinit(gpa);
    return areasOf(gpa, arena, threads, &sk, blocked, params);
}

/// The skeleton of the trees (steps 1 to 6), in `gpa`.
pub fn plan(
    gpa: Allocator,
    arena: Allocator,
    threads: usize,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    need: []const Paths,
    blocked: []const Paths,
    near: []const Paths,
    tips_below: usize,
    params: Params,
) Allocator.Error!skel_mod.Skeleton {
    const n = outlines.len;
    const avoid = try avoidance(gpa, arena, threads, layers, need, blocked, tips_below, params);
    // The pad of the edge indexes: a node looks for edges at most this far.
    const pad = 2 * params.max_r + params.spacing;
    var ctx: Ctx = .{
        .a = arena,
        .layers = layers,
        .z = try arena.alloc(f64, n),
        .blocked = try .init(arena, blocked, pad, 1),
        .near = try .init(arena, near, pad, 1),
        .avoid = try .init(arena, avoid, pad, avoid_every),
        .params = params,
        .pad = pad,
    };
    for (layers, ctx.z) |l, *z| z.* = @floatFromInt(geom.fromMm(l.z));
    var nodes: std.ArrayList(PlanNode) = .empty;
    try planAll(&ctx, &nodes, need, near, tips_below);
    return build(gpa, &ctx, outlines, nodes.items);
}

/// The data that the steps share.
const Ctx = struct {
    a: Allocator,
    layers: []const slicer.Layer,
    /// The z of each layer, µm.
    z: []f64,
    blocked: Indexes,
    near: Indexes,
    avoid: Indexes,
    params: Params,
    pad: f64,

    /// The highest layer at or under the height zt (µm), or null if zt is
    /// under the first layer.
    fn layerAt(c: *const Ctx, zt: f64) ?u32 {
        if (zt < c.z[0]) return null;
        var lo: usize = 0;
        var hi: usize = c.z.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (c.z[mid] <= zt) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// The radius that the physics rules give a branch on layer j under
    /// a tip on layer `top` (see 5. in the header), µm.
    fn physics(c: *const Ctx, top: u32, j: usize) f64 {
        const p = c.params;
        const l_mm = (c.z[top] - c.z[j]) / 1000;
        var r: f64 = 0;
        if (p.bend > 0) r = @max(r, 1000 * std.math.cbrt(p.bend * l_mm * l_mm * l_mm));
        if (p.buckle > 0) r = @max(r, 1000 * std.math.cbrt(p.buckle * l_mm * l_mm));
        return r;
    }
};

/// Steps 1 to 3: the regions, the tips, and the plan of each region.
fn planAll(c: *Ctx, nodes: *std.ArrayList(PlanNode), need: []const Paths, near: []const Paths, tips_below: usize) Allocator.Error!void {
    const a = c.a;
    const n = need.len;
    const sp = c.params.spacing;
    // Step 1: the islands of the tip areas, from the bottom layer up.
    var isl: std.ArrayList(Island) = .empty;
    for (0..n) |j| {
        const src = j + tips_below;
        if (src >= n or need[src].isEmpty()) continue;
        const area = try clip.difference(a, need[src], near[j]);
        for (0..area.count()) |k| {
            const poly = area.get(k);
            if (geom.area2(poly) <= 0) continue; // a hole
            var box: geom.Box = .empty;
            for (poly) |p| box.extend(p);
            const ct = centroid(poly);
            try isl.append(a, .{ .j = @intCast(j), .poly = poly, .box = box, .area = ct[2], .cx = ct[0], .cy = ct[1] });
        }
    }
    const islands = isl.items;
    if (islands.len == 0) return;
    // The regions: islands near in XY and in z join (union-find).
    const link_d = 0.5 * sp;
    const link_layers: u32 = 3;
    const up = try a.alloc(u32, islands.len);
    for (up, 0..) |*u, i| u.* = @intCast(i);
    for (islands, 0..) |p, i| {
        for (islands[i + 1 ..], i + 1..) |q, k| {
            if (q.j > p.j + link_layers) break;
            if (!boxesNear(p.box, q.box, link_d)) continue;
            if (!polysNear(p.poly, p.box, q.poly, q.box, link_d)) continue;
            unite(up, @intCast(i), @intCast(k));
        }
    }
    // The islands of each region, in the order of the first island.
    const region_of = try a.alloc(u32, islands.len);
    var regions: std.ArrayList(std.ArrayList(u32)) = .empty;
    const slot = try a.alloc(u32, islands.len);
    @memset(slot, none);
    for (0..islands.len) |i| {
        const root = find(up, @intCast(i));
        if (slot[root] == none) {
            slot[root] = @intCast(regions.items.len);
            try regions.append(a, .empty);
        }
        region_of[i] = slot[root];
        try regions.items[slot[root]].append(a, @intCast(i));
    }
    for (regions.items) |members| {
        const first: u32 = @intCast(nodes.items.len);
        // The anchor: the centroid of the islands.
        var sa: f64 = 0;
        var sx: f64 = 0;
        var sy: f64 = 0;
        var box: geom.Box = .empty;
        for (members.items) |m| {
            const s = islands[m];
            sa += s.area;
            sx += s.area * s.cx;
            sy += s.area * s.cy;
            box.extend(s.box.min);
            box.extend(s.box.max);
        }
        const ax = if (sa > 0) sx / sa else islands[members.items[0]].cx;
        const ay = if (sa > 0) sy / sa else islands[members.items[0]].cy;
        try regionTips(c, nodes, islands, members.items, ax, ay, box);
        const units = try a.alloc(u32, nodes.items.len - first);
        for (units, first..) |*u, i| u.* = @intCast(i);
        try planRegion(c, nodes, units, ax, ay);
    }
    // The trunks of near regions join too: the trunks at most
    // `forest_d` apart make a group (union-find), and each group is
    // planned as a region, around the centroid of its trunks.
    var roots: std.ArrayList(u32) = .empty;
    for (nodes.items, 0..) |nd, i| if (nd.parent == none) try roots.append(a, @intCast(i));
    try pairs(c, nodes, &roots, c.params.forest * sp, c.params.worth);
}

/// Joins in rounds: in each round, the branches that are each other's
/// nearest branch (at most `max_d` apart) join. A branch with two or more
/// nearest branches at the same distance joins all of them that have it
/// as their nearest too (a group of at most 4), so no order counts, and a
/// mirror of the part gives the mirror of the plan. A join must have room
/// (see `join`).
fn pairs(c: *Ctx, nodes: *std.ArrayList(PlanNode), units: *std.ArrayList(u32), max_d: f64, worth: f64) Allocator.Error!void {
    const a = c.a;
    // The pairs that cannot join: they do not count as nearest again.
    var no: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    const Pair = struct {
        fn key(u: u32, v: u32) [2]u32 {
            return if (u < v) .{ u, v } else .{ v, u };
        }
    };
    var round: usize = 0;
    while (round < 64 and units.items.len > 1) : (round += 1) {
        const us = units.items;
        const m = us.len;
        const nn = try a.alloc(f64, m);
        const ok = struct {
            fn f(ns: []const PlanNode, nop: *const std.AutoHashMapUnmanaged([2]u32, void), u: u32, v: u32) bool {
                if (ns[u].free != ns[v].free) return false;
                return !nop.contains(Pair.key(u, v));
            }
        }.f;
        for (us, 0..) |u, i| {
            nn[i] = std.math.inf(f64);
            for (us, 0..) |v, k| {
                if (k == i or !ok(nodes.items, &no, u, v)) continue;
                const d = planDist(nodes.items[u], nodes.items[v]);
                if (d <= max_d) nn[i] = @min(nn[i], d);
            }
        }
        const up = try a.alloc(u32, m);
        for (up, 0..) |*x, i| x.* = @intCast(i);
        for (us, 0..) |u, i| {
            if (nn[i] == std.math.inf(f64)) continue;
            for (us[i + 1 ..], i + 1..) |v, k| {
                if (!ok(nodes.items, &no, u, v)) continue;
                const d = planDist(nodes.items[u], nodes.items[v]);
                if (d <= nn[i] * (1 + 1e-3) + 5 and d <= nn[k] * (1 + 1e-3) + 5) unite(up, @intCast(i), @intCast(k));
            }
        }
        const slot = try a.alloc(u32, m);
        @memset(slot, none);
        var groups: std.ArrayList(std.ArrayList(u32)) = .empty;
        for (us, 0..) |u, i| {
            const g = find(up, @intCast(i));
            if (slot[g] == none) {
                slot[g] = @intCast(groups.items.len);
                try groups.append(a, .empty);
            }
            try groups.items[slot[g]].append(a, u);
        }
        var next: std.ArrayList(u32) = .empty;
        var changed = false;
        for (groups.items) |g| {
            if (g.items.len >= 2) {
                var span: f64 = 0;
                for (g.items) |u| for (g.items) |v| {
                    span = @max(span, planDist(nodes.items[u], nodes.items[v]));
                };
                const tried = g.items.len <= 4;
                if (tried) if (try join(c, nodes, g.items, @max(2 * span, 4 * c.params.spacing), worth)) |p| {
                    try next.append(a, p);
                    changed = true;
                    continue;
                };
                // No join: these pairs do not try again.
                for (g.items, 0..) |u, i| for (g.items[i + 1 ..]) |v| {
                    try no.put(a, Pair.key(u, v), {});
                };
                changed = true;
            }
            try next.appendSlice(a, g.items);
        }
        units.* = next;
        if (!changed) break;
    }
}

/// Checks a join of `kids` at (mx, my) on layer ml: room for its
/// radius out of the part, out of the avoidance area (if a branch is
/// free), and each segment out of the part.
fn fits(c: *Ctx, nodes: *std.ArrayList(PlanNode), kids: []const u32, ml: u32, mx: f64, my: f64, top: u32, free: bool) Allocator.Error!Why {
    const p = c.params;
    const at: Point = .{ .x = @intFromFloat(mx), .y = @intFromFloat(my) };
    const r = @max(@max(p.min_r, p.tip), c.physics(top, ml));
    if (try c.blocked.get(ml)) |bi| {
        if (bi.inside(at)) return .part;
        if (bi.nearestPoint(mx, my, c.pad)) |e| if (e[2] < r) return .part;
    }
    // A join in the avoidance area cannot reach the bed. Branches that
    // rest on the part can join there.
    if (free) if (try c.avoid.get(ml)) |ai| if (ai.inside(at)) return .avoid;
    for (kids) |k| {
        const nd = nodes.items[k];
        const span: f64 = @floatFromInt(nd.layer - ml);
        var l = nd.layer - 1;
        while (l > ml) : (l -|= 2) {
            const t = @as(f64, @floatFromInt(nd.layer - l)) / span;
            const pt: Point = .{ .x = @intFromFloat(nd.x + (mx - nd.x) * t), .y = @intFromFloat(nd.y + (my - nd.y) * t) };
            const fence = if (nd.layer - l <= p.tip_layers) try c.near.get(l) else try c.blocked.get(l);
            if (fence) |fi| if (fi.inside(pt)) return .strut;
            // A branch that can reach the bed stays out of the avoidance
            // area on the way.
            if (nd.free and nd.layer - l > p.tip_layers) if (try c.avoid.get(l)) |ai| if (ai.inside(pt)) return .avoid;
            if (l < 2) break;
        }
    }
    return .ok;
}

fn planDist(p: PlanNode, q: PlanNode) f64 {
    return @sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y));
}

/// Step 2: the tips of one region, on the grid around the anchor (ax, ay).
fn regionTips(c: *Ctx, nodes: *std.ArrayList(PlanNode), islands: []const Island, members: []const u32, ax: f64, ay: f64, box: geom.Box) Allocator.Error!void {
    const a = c.a;
    const sp = c.params.spacing;
    const reach = 0.6 * sp;
    const tip = c.params.tip;
    const row_h = sp * 0.8660254037844386;
    var found: std.ArrayList(PlanNode) = .empty;
    var layers_in: std.ArrayList(u32) = .empty;
    const x0: f64 = @as(f64, @floatFromInt(box.min.x)) - reach;
    const x1: f64 = @as(f64, @floatFromInt(box.max.x)) + reach;
    const y0: f64 = @as(f64, @floatFromInt(box.min.y)) - reach;
    const y1: f64 = @as(f64, @floatFromInt(box.max.y)) + reach;
    var row: i64 = @intFromFloat(@floor((y0 - ay) / row_h));
    const row_end: i64 = @intFromFloat(@ceil((y1 - ay) / row_h));
    while (row <= row_end) : (row += 1) {
        const y = ay + @as(f64, @floatFromInt(row)) * row_h;
        const shift: f64 = if (@mod(row, 2) == 0) 0 else sp / 2;
        var col: i64 = @intFromFloat(@floor((x0 - ax - shift) / sp));
        const col_end: i64 = @intFromFloat(@ceil((x1 - ax - shift) / sp));
        while (col <= col_end) : (col += 1) {
            const x = ax + shift + @as(f64, @floatFromInt(col)) * sp;
            // The islands that hold the point: a tip on the lowest, and on
            // each island well over the one under it (a second surface,
            // over the part).
            layers_in.clearRetainingCapacity();
            for (members) |m| {
                const s = islands[m];
                if (!inBox(s.box, x, y, 0)) continue;
                if (insidePoly(s.poly, x, y)) try layers_in.append(a, s.j);
            }
            if (layers_in.items.len > 0) {
                std.mem.sort(u32, layers_in.items, {}, std.sort.asc(u32));
                var last: u32 = 0;
                for (layers_in.items, 0..) |j, k| {
                    if (k > 0 and j <= last + 3) continue;
                    try found.append(a, .{ .x = x, .y = y, .layer = j, .top = j });
                    last = j;
                }
                continue;
            }
            // Out of the region: the nearest point of an island, moved in.
            var best_d: f64 = reach;
            var best: ?struct { x: f64, y: f64, j: u32, m: u32 } = null;
            for (members) |m| {
                const s = islands[m];
                if (!inBox(s.box, x, y, reach)) continue;
                const q = nearestOnPoly(s.poly, x, y);
                if (q[2] < best_d or (best != null and q[2] == best_d and s.j < best.?.j)) {
                    best_d = q[2];
                    best = .{ .x = q[0], .y = q[1], .j = s.j, .m = m };
                }
            }
            const b = best orelse continue;
            const d = @max(best_d, 1e-6);
            const dx = (b.x - x) / d;
            const dy = (b.y - y) / d;
            var px = b.x + dx * tip;
            var py = b.y + dy * tip;
            if (!insidePoly(islands[b.m].poly, px, py)) {
                px = b.x + dx * 20;
                py = b.y + dy * 20;
            }
            try found.append(a, .{ .x = px, .y = py, .layer = b.j, .top = b.j });
        }
    }
    // Tips nearer than half a spacing (and at most 3 layers apart) join
    // at their mean point, on the lowest layer of the group.
    const tips = found.items;
    const up = try a.alloc(u32, tips.len);
    for (up, 0..) |*u, i| u.* = @intCast(i);
    const order = try a.alloc(u32, tips.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, tips, struct {
        fn lt(t: []const PlanNode, p: u32, q: u32) bool {
            return t[p].x < t[q].x or (t[p].x == t[q].x and p < q);
        }
    }.lt);
    const merge_d = 0.5 * sp;
    for (order, 0..) |p, i| {
        for (order[i + 1 ..]) |q| {
            if (tips[q].x - tips[p].x >= merge_d) break;
            const dy = tips[q].y - tips[p].y;
            const dx = tips[q].x - tips[p].x;
            if (dx * dx + dy * dy >= merge_d * merge_d) continue;
            const dj = @as(i64, tips[q].layer) - @as(i64, tips[p].layer);
            if (@abs(dj) > 3) continue;
            unite(up, p, q);
        }
    }
    const first = nodes.items.len;
    const slot = try a.alloc(u32, tips.len);
    @memset(slot, none);
    const count = try a.alloc(f64, tips.len);
    for (tips, 0..) |t, i| {
        const root = find(up, @intCast(i));
        if (slot[root] == none) {
            slot[root] = @intCast(nodes.items.len);
            try nodes.append(a, .{ .x = 0, .y = 0, .layer = t.layer, .top = t.layer });
            count[slot[root] - first] = 0;
        }
        const nd = &nodes.items[slot[root]];
        nd.x += t.x;
        nd.y += t.y;
        nd.layer = @min(nd.layer, t.layer);
        nd.top = nd.layer;
        count[slot[root] - first] += 1;
    }
    for (nodes.items[first..], 0..) |*nd, k| {
        nd.x /= count[k];
        nd.y /= count[k];
    }
    // An island with no tip in it or near it gets one.
    const end = nodes.items.len;
    for (members) |m| {
        const s = islands[m];
        var has = false;
        for (nodes.items[first..end]) |nd| {
            const dj = @as(i64, nd.layer) - @as(i64, s.j);
            if (@abs(dj) > 3) continue;
            if (insidePoly(s.poly, nd.x, nd.y) or nearestOnPoly(s.poly, nd.x, nd.y)[2] < reach) {
                has = true;
                break;
            }
        }
        if (has) continue;
        const p = pointInside(s.poly) orelse continue;
        try nodes.append(a, .{ .x = p[0], .y = p[1], .layer = s.j, .top = s.j });
    }
    // A tip near the part moves out, so that it has room for its radius.
    for (nodes.items[first..]) |*nd| {
        const ni = try c.near.get(nd.layer);
        var tmp: Node = .{ .x = nd.x, .y = nd.y, .r = tip };
        _ = fit(&tmp, ni, c.pad, 2 * tip, tip);
        nd.x = tmp.x;
        nd.y = tmp.y;
        if (try c.avoid.get(nd.layer)) |ai| nd.free = !ai.inside(.{ .x = @intFromFloat(nd.x), .y = @intFromFloat(nd.y) });
    }
}

/// Step 3: the plan of the tips `nodes[first..]` of one region.
fn planRegion(c: *Ctx, nodes: *std.ArrayList(PlanNode), start: []const u32, ax: f64, ay: f64) Allocator.Error!void {
    const a = c.a;
    var units: std.ArrayList(u32) = .empty;
    try units.appendSlice(a, start);
    defer pairs(c, nodes, &units, std.math.inf(f64), 0) catch {};
    var next: std.ArrayList(u32) = .empty;
    const Keyed = struct { cx: i64, cy: i64, i: u32 };
    var keyed: std.ArrayList(Keyed) = .empty;
    var cell = std.math.sqrt2 * c.params.spacing;
    var level: usize = 0;
    while (level < 7 and units.items.len > 1) : ({
        level += 1;
        cell *= 2;
    }) {
        keyed.clearRetainingCapacity();
        for (units.items) |u| {
            const nd = nodes.items[u];
            try keyed.append(a, .{
                .cx = @intFromFloat(@floor((nd.x - ax) / cell + 0.5)),
                .cy = @intFromFloat(@floor((nd.y - ay) / cell + 0.5)),
                .i = u,
            });
        }
        std.mem.sort(Keyed, keyed.items, {}, struct {
            fn lt(_: void, p: Keyed, q: Keyed) bool {
                if (p.cx != q.cx) return p.cx < q.cx;
                if (p.cy != q.cy) return p.cy < q.cy;
                return p.i < q.i;
            }
        }.lt);
        next.clearRetainingCapacity();
        var s: usize = 0;
        while (s < keyed.items.len) {
            var e = s + 1;
            while (e < keyed.items.len and keyed.items[e].cx == keyed.items[s].cx and keyed.items[e].cy == keyed.items[s].cy) e += 1;
            const group = keyed.items[s..e];
            s = e;
            if (group.len > 1) {
                const kids = try a.alloc(u32, group.len);
                for (kids, group) |*k, g| k.* = g.i;
                if (try join(c, nodes, kids, cell, 0)) |p| {
                    try next.append(a, p);
                    continue;
                }
            }
            for (group) |g| try next.append(a, g.i);
        }
        std.mem.swap(std.ArrayList(u32), &units, &next);
    }
}

/// Why a join has no room (see `fits`).
const Why = enum { ok, part, avoid, strut };

/// Plans a join of the branches `kids`: returns the new node, or null if
/// the join has no room (see 3. in the header).
fn join(c: *Ctx, nodes: *std.ArrayList(PlanNode), kids: []const u32, cell: f64, worth: f64) Allocator.Error!?u32 {
    var w: f64 = 0;
    var mx: f64 = 0;
    var my: f64 = 0;
    var heavy: u32 = none;
    var second: f64 = 0;
    for (kids) |k| {
        const nd = nodes.items[k];
        w += nd.weight;
        mx += nd.weight * nd.x;
        my += nd.weight * nd.y;
        if (heavy == none or nd.weight > nodes.items[heavy].weight) {
            if (heavy != none) second = @max(second, nodes.items[heavy].weight);
            heavy = k;
        } else second = @max(second, nd.weight);
    }
    if (try joinAt(c, nodes, kids, cell, worth, mx / w, my / w)) |j| return j;
    // The centroid has no room: the branches can join the heaviest one,
    // which goes on straight down. Only a clear heaviest branch, so that a
    // mirror of the part gives the mirror of the plan.
    if (nodes.items[heavy].weight >= 1.5 * second) {
        const h = nodes.items[heavy];
        return joinAt(c, nodes, kids, cell, worth, h.x, h.y);
    }
    return null;
}

/// A join of `kids` that starts from the point (x, y) (see `join`).
fn joinAt(c: *Ctx, nodes: *std.ArrayList(PlanNode), kids: []const u32, cell: f64, worth: f64, x: f64, y: f64) Allocator.Error!?u32 {
    const p = c.params;
    const tan_plan = p.tan_angle * p.plan_lean;
    var w: f64 = 0;
    var mx = x;
    var my = y;
    var top: u32 = 0;
    var free = false;
    for (kids) |k| {
        const nd = nodes.items[k];
        free = free or nd.free;
        w += nd.weight;
        top = @max(top, nd.top);
    }
    // The foot: no join in the layers under 1 mm.
    const floor_layer = c.layerAt(1000) orelse 0;
    // The highest layer where all branches reach the point.
    var ml: u32 = std.math.maxInt(u32);
    for (kids) |k| {
        const nd = nodes.items[k];
        if (nd.layer == 0) return null;
        const d = @sqrt((nd.x - mx) * (nd.x - mx) + (nd.y - my) * (nd.y - my));
        var l = c.layerAt(c.z[nd.layer] - d / tan_plan) orelse return null;
        l = @min(l, nd.layer - 1);
        ml = @min(ml, l);
    }
    // A join must save more branch than its segments cost: the trunk
    // under it is at least as long as the segments reach out.
    var reach: f64 = 0;
    for (kids) |k| {
        const nd = nodes.items[k];
        reach = @max(reach, @sqrt((nd.x - mx) * (nd.x - mx) + (nd.y - my) * (nd.y - my)));
    }
    const least_z = worth * 2 * reach;
    // Try that layer, and then layers lower down (1 mm apart, up to 8 mm),
    // where the part is out of the way.
    var why: Why = .part;
    var drop: usize = 0;
    while (drop <= 8) : (drop += 1) {
        const lz = c.z[ml] - @as(f64, @floatFromInt(drop)) * 1000;
        const l = if (drop == 0) ml else (c.layerAt(lz) orelse break);
        if (l <= floor_layer) break;
        if (c.z[l] < least_z) break;
        why = try fits(c, nodes, kids, l, mx, my, top, free);
        if (why == .ok) {
            ml = l;
            break;
        }
    }
    if (why != .ok) {
        // Push the join out of the part, on the highest layer, as far as
        // its radius needs.
        if (ml <= floor_layer or c.z[ml] < least_z) return null;
        const r = @max(@max(p.min_r, p.tip), c.physics(top, ml));
        const bi = (try c.blocked.get(ml)) orelse return null;
        const inside = bi.inside(.{ .x = @intFromFloat(mx), .y = @intFromFloat(my) });
        const ee = bi.nearestPoint(mx, my, c.pad) orelse return null;
        var dx = mx - ee[0];
        var dy = my - ee[1];
        const dd = @sqrt(dx * dx + dy * dy);
        if (dd < 1) return null;
        if (inside) {
            dx = -dx;
            dy = -dy;
        }
        const nx = ee[0] + dx / dd * (r + 100);
        const ny = ee[1] + dy / dd * (r + 100);
        if (@sqrt((nx - mx) * (nx - mx) + (ny - my) * (ny - my)) > cell / 4) return null;
        mx = nx;
        my = ny;
        // The branches reach the new point a little lower.
        for (kids) |k| {
            const nd = nodes.items[k];
            const d = @sqrt((nd.x - mx) * (nd.x - mx) + (nd.y - my) * (nd.y - my));
            var l = c.layerAt(c.z[nd.layer] - d / tan_plan) orelse return null;
            l = @min(l, nd.layer - 1);
            ml = @min(ml, l);
        }
        if (ml <= floor_layer or c.z[ml] < least_z) return null;
        why = try fits(c, nodes, kids, ml, mx, my, top, free);
        if (why != .ok) return null;
    }
    const idx: u32 = @intCast(nodes.items.len);
    try nodes.append(c.a, .{ .x = mx, .y = my, .layer = ml, .weight = w, .top = top, .free = free });
    for (kids) |k| nodes.items[k].parent = idx;
    return idx;
}

/// Steps 4 to 6: builds the trees of the plan, one layer at a time from
/// the top down, and makes the skeleton.
fn build(gpa: Allocator, c: *Ctx, outlines: []const Paths, pl: []const PlanNode) Allocator.Error!skel_mod.Skeleton {
    const a = c.a;
    const p = c.params;
    const n = outlines.len;
    // The plan nodes by layer, from the top down.
    const order = try a.alloc(u32, pl.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, pl, struct {
        fn lt(t: []const PlanNode, x: u32, y: u32) bool {
            return t[x].layer > t[y].layer or (t[x].layer == t[y].layer and x < y);
        }
    }.lt);
    const disks = try a.alloc(std.ArrayList(Disk), n);
    for (disks) |*d| d.* = .empty;
    var branches: Branches = .{};
    var nodes: std.ArrayList(Node) = .empty;
    // The node of each plan node, while it is alive.
    const node_of = try a.alloc(u32, pl.len);
    @memset(node_of, none);
    var oi: usize = 0;
    var j: usize = n;
    var kids: std.ArrayList(u32) = .empty;
    while (j > 0) {
        j -= 1;
        const h = geom.fromMm(c.layers[j].height);
        const step = @as(f64, @floatFromInt(h)) * p.tan_angle;
        // 1. Each node goes toward its join (or down), then the tips and
        // the joins of this layer start.
        const aidx = try c.avoid.get(j);
        // The avoidance of this layer is the computed avoidance of a layer
        // under it, moved in by `slack` (see `avoidance`).
        var slack: f64 = 0;
        for (j - j % avoid_every + 1..j + 1) |q| slack += @as(f64, @floatFromInt(geom.fromMm(c.layers[q].height))) * p.tan_angle;
        const av: Avoid = .{ .idx = aidx, .slack = slack, .pad = c.pad };
        for (nodes.items) |*nd| if (nd.alive) {
            var tx: f64 = nd.x;
            var ty: f64 = nd.y;
            var left: f64 = 1;
            const par = pl[nd.plan].parent;
            if (nd.chase) {
                const k = if (par != none) node_of[par] else none;
                if (k != none) {
                    tx = nodes.items[k].x;
                    ty = nodes.items[k].y;
                }
            } else if (par != none and pl[par].layer <= j) {
                tx = pl[par].x;
                ty = pl[par].y;
                left = @floatFromInt(j + 1 - pl[par].layer);
            }
            var dx = (tx - nd.x) / left;
            var dy = (ty - nd.y) / left;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > step) {
                dx *= step / d;
                dy *= step / d;
            }
            // A free branch does not move into the avoidance area: it
            // follows its join when it is out of the way.
            if (nd.free and av.into(nd.x, nd.y, nd.x + dx, nd.y + dy)) {
                if (!nd.chase and par != none) nd.chase = true;
                continue;
            }
            nd.x += dx;
            nd.y += dy;
        };
        while (oi < order.len and pl[order[oi]].layer > j) oi += 1;
        const start = oi;
        while (oi < order.len and pl[order[oi]].layer == j) oi += 1;
        for (order[start..oi]) |q| {
            const pn = pl[q];
            // A tip, or a join of the nodes that go to it.
            kids.clearRetainingCapacity();
            for (nodes.items, 0..) |nd, k| {
                if (nd.alive and !nd.chase and pl[nd.plan].parent == q) try kids.append(a, @intCast(k));
            }
            const is_tip = pn.layer == pn.top and kids.items.len == 0;
            if (!is_tip and kids.items.len == 0) continue;
            var nn: Node = .{ .x = pn.x, .y = pn.y, .r = p.tip, .top = pn.top, .plan = q, .id = @intCast(branches.into.items.len) };
            if (kids.items.len > 0) {
                var w: f64 = 0;
                var sx: f64 = 0;
                var sy: f64 = 0;
                nn.age = std.math.maxInt(u32);
                nn.r = 0;
                for (kids.items) |k| {
                    const kd = nodes.items[k];
                    const kw = pl[kd.plan].weight;
                    w += kw;
                    sx += kw * kd.x;
                    sy += kw * kd.y;
                    nn.r = @max(nn.r, kd.r);
                    nn.want = @max(nn.want, kd.want);
                    nn.top = @max(nn.top, kd.top);
                    nn.age = @min(nn.age, kd.age);
                }
                nn.x = sx / w;
                nn.y = sy / w;
            }
            try branches.into.append(a, none);
            node_of[q] = @intCast(nodes.items.len);
            try nodes.append(a, nn);
            // The branches in the circle of the join end here; the others
            // follow it.
            for (kids.items) |k| {
                const kd = &nodes.items[k];
                const dd = @sqrt((kd.x - nn.x) * (kd.x - nn.x) + (kd.y - nn.y) * (kd.y - nn.y));
                if (dd + kd.r <= nn.r + p.join_slack) {
                    kd.alive = false;
                    branches.into.items[kd.id] = nn.id;
                } else kd.chase = true;
            }
        }
        if (nodes.items.len == 0) continue;
        const bidx = try c.blocked.get(j);
        const nidx = try c.near.get(j);
        for (nodes.items) |*nd| {
            if (!nd.alive) continue;
            nd.age +|= 1;
            // 2. Out of the avoidance area, toward the bed, if one step is
            // enough. Else the branch goes on, and rests on the part.
            nd.free = true;
            if (aidx) |ai| if (ai.inside(pointOf(nd))) {
                const e = ai.nearestPoint(nd.x, nd.y, c.pad);
                const depth = if (e) |ee| ee[2] - slack else std.math.inf(f64);
                if (depth > 0) {
                    nd.free = depth <= step * 1.5 + 1;
                    if (nd.free) {
                        const dx = e.?[0] - nd.x;
                        const dy = e.?[1] - nd.y;
                        const d = @max(@sqrt(dx * dx + dy * dy), 1e-6);
                        nd.x += dx / d * (depth + 20);
                        nd.y += dy / d * (depth + 20);
                    }
                }
            };
            // 3. The radius from physics (see 5. in the header).
            if (nd.want == 0) nd.want = nd.r;
            nd.want = @min(p.max_r, @max(nd.want, c.physics(nd.top, j)));
            if (nd.age > p.tip_layers and p.min_r > 0) {
                const cone = p.tip + @as(f64, @floatFromInt((nd.age - p.tip_layers) * h));
                nd.want = @min(p.max_r, @max(nd.want, @min(p.min_r, cone)));
            }
            nd.r = nd.want;
            // The foot: near the bed, a branch to the bed gets wider at 45
            // degrees to the foot radius. A short branch needs a smaller
            // foot: a fifth of its height, but at least 1 mm, so that the
            // bed layer has lines under it.
            if (nd.free) {
                const z = c.z[j];
                const top_z = c.z[nd.top];
                var foot = @max(p.foot, nd.want + 1000);
                if (p.peel > 0) foot = @max(foot, 1000 * std.math.cbrt(p.peel * top_z / 1000));
                foot = @min(foot, @max(1000, top_z / 5));
                nd.r = @max(nd.r, foot - z);
            }
            const fence = if (nd.age <= p.tip_layers) nidx else bidx;
            const floor = if (nd.age <= p.tip_layers) p.tip else @max(p.tip, @min(p.min_r, nd.want));
            if (!fit(nd, fence, c.pad, step, floor)) {
                // No room for the radius. Beside the part, the branch goes
                // on, and the gap cuts its circle. In the gap, it stops: it
                // rests on the part, or (bed only) it is removed.
                if (fence) |fi| {
                    if (fi.inside(pointOf(nd))) nd.alive = false;
                }
            }
        }
        // A branch over the part rests on it: the Z gap above the part.
        var k: usize = 1;
        while (k <= p.z_gap + 1 and k <= j) : (k += 1) {
            const oix = (try index(a, outlines[j - k], c.pad)) orelse continue;
            for (nodes.items) |*nd| {
                if (!nd.alive or !oix.inside(pointOf(nd))) continue;
                nd.alive = false;
                // The circle above rests on the part: it gets smaller if it
                // reaches past the edge, so that no part of it hangs.
                if (j + 1 < n) for (disks[j + 1].items) |*d| if (d.id == nd.id) {
                    const e = oix.nearestPoint(d.x, d.y, c.pad) orelse break;
                    d.r = @max(p.tip, @min(d.r, e[2] + p.tip / 2));
                    break;
                };
            }
        }
        // A branch that follows its join ends when it is in its circle.
        for (nodes.items) |*nd| {
            if (!nd.alive or !nd.chase) continue;
            const par = pl[nd.plan].parent;
            const q = if (par != none) node_of[par] else none;
            if (q == none or !nodes.items[q].alive) continue;
            const o = nodes.items[q];
            const dd = @sqrt((nd.x - o.x) * (nd.x - o.x) + (nd.y - o.y) * (nd.y - o.y));
            if (dd + nd.r <= o.r + p.join_slack) {
                nd.alive = false;
                branches.into.items[nd.id] = o.id;
            }
        }
        // Trunks that touch join (see `touch`).
        try touch(a, nodes.items, pl, &branches, step, p.join_slack, p.touch * p.spacing, j -| p.fill_layers, av);
        // 4. The circles of this layer.
        for (nodes.items) |nd| if (nd.alive) {
            try disks[j].append(a, .{ .x = nd.x, .y = nd.y, .r = nd.r, .id = nd.id });
        };
        // Drop the nodes that ended.
        var keep: usize = 0;
        for (nodes.items) |nd| if (nd.alive) {
            nodes.items[keep] = nd;
            keep += 1;
        };
        nodes.items.len = keep;
        @memset(node_of, none);
        for (nodes.items, 0..) |nd, q| node_of[nd.plan] = @intCast(q);
    }
    try steady(a, disks, &branches);
    try taper(a, disks, &branches, 2 * p.tip, p.tip);
    return skeletonOf(gpa, a, disks, &branches);
}

/// The avoidance area of one layer: the edge index of a computed layer,
/// moved in by `slack` (see `avoidance`).
const Avoid = struct {
    idx: ?geom.EdgeIndex,
    slack: f64,
    pad: f64,

    /// How far (x, y) is in the area, µm; 0 or less: out of it.
    fn depth(av: Avoid, x: f64, y: f64) f64 {
        const ai = av.idx orelse return 0;
        if (!ai.inside(.{ .x = @intFromFloat(x), .y = @intFromFloat(y) })) return 0;
        const e = ai.nearestPoint(x, y, av.pad) orelse return std.math.inf(f64);
        return e[2] - av.slack;
    }

    /// True if a move from (x0, y0) to (x1, y1) goes into the area, or
    /// deeper into it.
    fn into(av: Avoid, x0: f64, y0: f64, x1: f64, y1: f64) bool {
        const d1 = av.depth(x1, y1);
        return d1 > 0 and d1 > av.depth(x0, y0);
    }
};

/// Trunks (branches with no join in the plan) whose circles are less
/// than `reach` apart move toward each other by up to one step, if they
/// can meet in `layers_left` layers, and join when the circle of one
/// holds the other (up to `slack`). The plan joins only along straight
/// segments; a trunk that goes around the part can come to touch another
/// trunk, and two touching trunks are one thick trunk with a groove.
/// The moves come from the positions before the moves, and the joins
/// from groups (union-find), so no order of the nodes counts. A group
/// goes on as its widest circle (the mean of the widest, if there are
/// two).
fn touch(a: Allocator, nodes: []Node, pl: []const PlanNode, branches: *Branches, step: f64, slack: f64, reach: f64, layers_left: usize, av: Avoid) Allocator.Error!void {
    var roots: std.ArrayList(u32) = .empty;
    for (nodes, 0..) |nd, i| if (nd.alive and (pl[nd.plan].parent == none or nd.chase)) try roots.append(a, @intCast(i));
    const rs = roots.items;
    if (rs.len < 2) return;
    const moves = try a.alloc([2]f64, rs.len);
    for (moves) |*m| m.* = .{ 0, 0 };
    for (rs, 0..) |i, x| for (rs[x + 1 ..], x + 1..) |k, y| {
        const p = nodes[i];
        const q = nodes[k];
        if (p.free != q.free) continue;
        const dx = q.x - p.x;
        const dy = q.y - p.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d >= p.r + q.r + reach or d < 1e-6) continue;
        // Only if they can meet over the foot: each goes one step a layer.
        const gap = @max(0, d - @abs(p.r - q.r) - slack);
        if (gap / (2 * step) > @as(f64, @floatFromInt(layers_left))) continue;
        // Each goes half the way, at most one step in all.
        const m = @min(step, d / 2) / d;
        moves[x][0] += dx * m;
        moves[x][1] += dy * m;
        moves[y][0] -= dx * m;
        moves[y][1] -= dy * m;
    };
    for (rs, moves) |i, m| {
        const len = @sqrt(m[0] * m[0] + m[1] * m[1]);
        const f = if (len > step) step / len else 1;
        const nd = &nodes[i];
        // A free trunk does not move into the avoidance area.
        if (nd.free and av.into(nd.x, nd.y, nd.x + m[0] * f, nd.y + m[1] * f)) continue;
        nd.x += m[0] * f;
        nd.y += m[1] * f;
    }
    const up = try a.alloc(u32, rs.len);
    for (up, 0..) |*u, x| u.* = @intCast(x);
    var any = false;
    for (rs, 0..) |i, x| for (rs[x + 1 ..], x + 1..) |k, y| {
        const p = nodes[i];
        const q = nodes[k];
        if (p.free != q.free) continue;
        const d = @sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
        if (d + @min(p.r, q.r) > @max(p.r, q.r) + slack) continue;
        unite(up, @intCast(x), @intCast(y));
        any = true;
    };
    if (!any) return;
    for (rs, 0..) |_, x| {
        if (find(up, @intCast(x)) != x) continue;
        // The group of x: the widest circle goes on.
        var big: f64 = 0;
        for (rs, 0..) |k, y| if (find(up, @intCast(y)) == x) {
            big = @max(big, nodes[k].r);
        };
        var keep: u32 = none;
        var n_big: f64 = 0;
        var sx: f64 = 0;
        var sy: f64 = 0;
        for (rs, 0..) |k, y| if (find(up, @intCast(y)) == x and nodes[k].r >= big - 1) {
            if (keep == none) keep = k;
            n_big += 1;
            sx += nodes[k].x;
            sy += nodes[k].y;
        };
        const kn = &nodes[keep];
        kn.x = sx / n_big;
        kn.y = sy / n_big;
        for (rs, 0..) |k, y| if (find(up, @intCast(y)) == x and k != keep) {
            const o = &nodes[k];
            kn.want = @max(kn.want, o.want);
            kn.top = @max(kn.top, o.top);
            kn.age = @min(kn.age, o.age);
            o.alive = false;
            branches.into.items[o.id] = kn.id;
        };
    }
}

/// Step 6: the skeleton of the branches. Each branch is a chain from its
/// top layer down; its last node links to the node of the branch that it
/// joins, on the layer under it.
fn skeletonOf(gpa: Allocator, a: Allocator, disks: []const std.ArrayList(Disk), branches: *const Branches) Allocator.Error!skel_mod.Skeleton {
    const nb = branches.into.items.len;
    const pts = try a.alloc(std.ArrayList(skel_mod.Disk), nb);
    for (pts) |*x| x.* = .empty;
    const top = try a.alloc(u32, nb);
    var j = disks.len;
    while (j > 0) {
        j -= 1;
        for (disks[j].items) |d| {
            if (pts[d.id].items.len == 0) top[d.id] = @intCast(j);
            try pts[d.id].append(a, .{ .x = d.x, .y = d.y, .r = d.r });
        }
    }
    // The layers where a branch joins another: its node stays.
    const keep = try a.alloc([]bool, nb);
    for (keep, pts) |*k, ps| {
        k.* = try a.alloc(bool, ps.items.len);
        @memset(k.*, false);
    }
    for (0..nb) |b| {
        const into = branches.into.items[b];
        if (into == none or pts[b].items.len == 0 or pts[into].items.len == 0) continue;
        const last = top[b] - @as(u32, @intCast(pts[b].items.len - 1));
        if (last == 0 or top[into] < last - 1) continue;
        const at = top[into] - (last - 1);
        if (at < keep[into].len) keep[into][at] = true;
    }
    const has_kid = try a.alloc(bool, nb);
    @memset(has_kid, false);
    for (branches.into.items) |into| if (into != none) {
        has_kid[into] = true;
    };
    var sk: skel_mod.Skeleton = .{};
    errdefer sk.deinit(gpa);
    const first = try a.alloc(u32, nb);
    const end = try a.alloc(u32, nb);
    for (0..nb) |b| {
        first[b] = @intCast(sk.nodes.items.len);
        if (pts[b].items.len > 0) {
            const is_tip = !has_kid[b];
            _ = try sk.addChain(gpa, top[b], pts[b].items, keep[b], is_tip, 30);
        }
        end[b] = @intCast(sk.nodes.items.len);
    }
    for (0..nb) |b| {
        const into = branches.into.items[b];
        if (into == none or end[b] == first[b]) continue;
        const last = end[b] - 1;
        const want = sk.nodes.items[last].layer -| 1;
        for (first[into]..end[into]) |q| {
            if (sk.nodes.items[q].layer == want) {
                sk.nodes.items[last].down = @intCast(q);
                break;
            }
        }
    }
    return sk;
}

/// The areas of each layer from a skeleton: the union of the circles,
/// minus the part, on all threads. Bed only: the trees that do not reach
/// the bed go.
pub fn areasOf(gpa: Allocator, a: Allocator, threads: usize, sk: *const skel_mod.Skeleton, blocked: []const Paths, params: Params) Allocator.Error!Areas {
    const n = blocked.len;
    const out = try gpa.alloc(Paths, n);
    for (out) |*o| o.* = .empty;
    errdefer {
        for (out) |*o| o.deinit(gpa);
        gpa.free(out);
    }
    const filled = try gpa.alloc(Paths, n);
    for (filled) |*o| o.* = .empty;
    errdefer {
        for (filled) |*o| o.deinit(gpa);
        gpa.free(filled);
    }
    var keep: ?[]bool = null;
    if (params.bed_only) {
        const k = try a.alloc(bool, sk.nodes.items.len);
        for (sk.nodes.items, k) |nd, *x| x.* = nd.down == none and nd.layer == 0;
        keep = k;
    }
    const ds = try sk.disks(a, n, params.fill_layers, keep);
    const circles = try a.alloc(Paths, n);
    const fills = try a.alloc(Paths, n);
    for (circles, fills, ds) |*cc, *f, list| {
        cc.* = .empty;
        f.* = .empty;
        for (list.items) |d| {
            const pts = try circle(a, d.x, d.y, d.r);
            try cc.append(a, pts);
            if (d.fill) try f.append(a, pts);
        }
    }
    const Union = struct {
        gpa: Allocator,
        circles: []const Paths,
        fills: []const Paths,
        blocked: []const Paths,
        out: []Paths,
        filled: []Paths,
        fn run(cx: *const @This(), i: usize) !void {
            if (cx.circles[i].isEmpty()) return;
            var ar = std.heap.ArenaAllocator.init(cx.gpa);
            defer ar.deinit();
            const u = try clip.unionAll(ar.allocator(), cx.circles[i], .non_zero);
            const free = try clip.difference(ar.allocator(), u, cx.blocked[i]);
            cx.out[i] = try free.clone(cx.gpa);
            if (cx.fills[i].isEmpty()) return;
            const fu = try clip.unionAll(ar.allocator(), cx.fills[i], .non_zero);
            const ff = try clip.difference(ar.allocator(), fu, cx.blocked[i]);
            cx.filled[i] = try ff.clone(cx.gpa);
        }
    };
    const uc: Union = .{ .gpa = gpa, .circles = circles, .fills = fills, .blocked = blocked, .out = out, .filled = filled };
    @import("parallel.zig").forEach(threads, n, &uc, Union.run) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return .{ .body = out, .filled = filled };
}

fn find(up: []u32, i: u32) u32 {
    var k = i;
    while (up[k] != k) {
        up[k] = up[up[k]];
        k = up[k];
    }
    return k;
}

/// Joins the sets of i and k; the smaller index is the root, so the
/// result does not depend on the order of the calls.
fn unite(up: []u32, i: u32, k: u32) void {
    const ri = find(up, i);
    const rk = find(up, k);
    if (ri == rk) return;
    if (ri < rk) up[rk] = ri else up[ri] = rk;
}

/// The centroid (x, y) and the area of a polygon, µm.
fn centroid(poly: []const Point) [3]f64 {
    var s: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    const ox: f64 = @floatFromInt(poly[0].x);
    const oy: f64 = @floatFromInt(poly[0].y);
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        const px = @as(f64, @floatFromInt(p.x)) - ox;
        const py = @as(f64, @floatFromInt(p.y)) - oy;
        const qx = @as(f64, @floatFromInt(q.x)) - ox;
        const qy = @as(f64, @floatFromInt(q.y)) - oy;
        const cr = px * qy - qx * py;
        s += cr;
        sx += (px + qx) * cr;
        sy += (py + qy) * cr;
    }
    if (@abs(s) < 1e-9) return .{ ox, oy, 0 };
    return .{ ox + sx / (3 * s), oy + sy / (3 * s), @abs(s) / 2 };
}

fn inBox(b: geom.Box, x: f64, y: f64, d: f64) bool {
    return x >= @as(f64, @floatFromInt(b.min.x)) - d and x <= @as(f64, @floatFromInt(b.max.x)) + d and
        y >= @as(f64, @floatFromInt(b.min.y)) - d and y <= @as(f64, @floatFromInt(b.max.y)) + d;
}

fn boxesNear(p: geom.Box, q: geom.Box, d: f64) bool {
    const di: i64 = @intFromFloat(d);
    return p.min.x - di <= q.max.x and q.min.x - di <= p.max.x and p.min.y - di <= q.max.y and q.min.y - di <= p.max.y;
}

/// True if two polygons are at most d apart.
fn polysNear(p: []const Point, pb: geom.Box, q: []const Point, qb: geom.Box, d: f64) bool {
    if (insidePoly(q, @floatFromInt(p[0].x), @floatFromInt(p[0].y))) return true;
    if (insidePoly(p, @floatFromInt(q[0].x), @floatFromInt(q[0].y))) return true;
    for ([2][]const Point{ p, q }, [2][]const Point{ q, p }, [2]geom.Box{ qb, pb }) |from, to, tb| {
        for (from) |v| {
            const x: f64 = @floatFromInt(v.x);
            const y: f64 = @floatFromInt(v.y);
            if (!inBox(tb, x, y, d)) continue;
            if (nearestOnPoly(to, x, y)[2] <= d) return true;
        }
    }
    return false;
}

/// The nearest point of the edges of a polygon to (x, y), and its
/// distance.
fn nearestOnPoly(poly: []const Point, x: f64, y: f64) [3]f64 {
    var best: [3]f64 = .{ x, y, std.math.inf(f64) };
    for (poly, 0..) |pa, i| {
        const pb = poly[(i + 1) % poly.len];
        const ax: f64 = @floatFromInt(pa.x);
        const ay: f64 = @floatFromInt(pa.y);
        const abx = @as(f64, @floatFromInt(pb.x)) - ax;
        const aby = @as(f64, @floatFromInt(pb.y)) - ay;
        const len2 = abx * abx + aby * aby;
        const t = if (len2 > 0) @max(0, @min(((x - ax) * abx + (y - ay) * aby) / len2, 1)) else 0;
        const px = ax + t * abx;
        const py = ay + t * aby;
        const d = @sqrt((x - px) * (x - px) + (y - py) * (y - py));
        if (d < best[2]) best = .{ px, py, d };
    }
    return best;
}

/// Makes each branch at least as thick as the branch above it, from the
/// top down: a disk gets the radius of the disks above it that go on in
/// it (its own branch, and the branches that join it). So a branch never
/// gets thinner on the way down: no thin neck under a thick part, and no
/// collar where a branch joins. Where the part is near, the XY gap cuts
/// the circle later (support.zig).
fn steady(a: Allocator, disks: []std.ArrayList(Disk), branches: *const Branches) Allocator.Error!void {
    var at: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var j = disks.len;
    while (j > 1) {
        j -= 1;
        if (disks[j].items.len == 0 or disks[j - 1].items.len == 0) continue;
        at.clearRetainingCapacity();
        for (disks[j - 1].items, 0..) |d, k| try at.put(a, d.id, @intCast(k));
        for (disks[j].items) |d| {
            const k = at.get(d.id) orelse blk: {
                const into = branches.into.items[d.id];
                if (into == none) break :blk null;
                break :blk at.get(into);
            } orelse continue;
            const u = &disks[j - 1].items[k];
            u.r = @max(u.r, d.r);
        }
    }
}

/// A circle of a branch on one layer.
const Disk = struct { x: f64, y: f64, r: f64, id: u32, fill: bool = false };

/// Makes the disks of a branch thinner where the disk under them is
/// thinner, from the bed up: a disk must be in the disk under it moved
/// out by `slack`, so that no part of a branch hangs in the air. A branch
/// gets thin in a narrow space; with this, the branch above it gets thin
/// again by `slack` on each layer, as a cone. A disk keeps at least the
/// radius `tip`.
fn taper(a: Allocator, disks: []std.ArrayList(Disk), branches: *const Branches, slack: f64, tip: f64) Allocator.Error!void {
    var at: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (1..disks.len) |j| {
        if (disks[j].items.len == 0 or disks[j - 1].items.len == 0) continue;
        at.clearRetainingCapacity();
        for (disks[j - 1].items, 0..) |d, k| try at.put(a, d.id, @intCast(k));
        for (disks[j].items) |*d| {
            // The same branch, or the branch that it joins, on the layer
            // under it.
            const k = at.get(d.id) orelse blk: {
                const into = branches.into.items[d.id];
                if (into == none) break :blk null;
                break :blk at.get(into);
            } orelse continue;
            const u = disks[j - 1].items[k];
            const dist = @sqrt((d.x - u.x) * (d.x - u.x) + (d.y - u.y) * (d.y - u.y));
            d.r = @max(tip, @min(d.r, u.r + slack - dist));
        }
    }
}

fn pointOf(nd: *const Node) Point {
    return .{ .x = @intFromFloat(nd.x), .y = @intFromFloat(nd.y) };
}

fn index(a: Allocator, paths: Paths, pad: f64) Allocator.Error!?geom.EdgeIndex {
    if (paths.isEmpty()) return null;
    return try geom.EdgeIndex.init(a, paths, @intFromFloat(pad));
}

/// The avoidance area of each layer (see 2. in the header), up to the
/// highest tip, in `arena`. The base of a layer (the part, the layers of
/// the Z gap under it, and the tip radius around them) does not depend on
/// other layers, so the bases are made on all threads; then each layer
/// adds the layer under it, moved in by one step. Simplified outlines keep
/// the offsets fast.
fn avoidance(
    gpa: Allocator,
    arena: Allocator,
    threads: usize,
    layers: []const slicer.Layer,
    need: []const Paths,
    blocked: []const Paths,
    tips_below: usize,
    params: Params,
) Allocator.Error![]Paths {
    const n = need.len;
    var top: usize = 0;
    var any = false;
    for (need, 0..) |nd, src| if (!nd.isEmpty() and src >= tips_below) {
        top = @max(top, src - tips_below);
        any = true;
    };
    const avoid = try arena.alloc(Paths, n);
    for (avoid) |*x| x.* = .empty;
    if (!any) return avoid;
    const bases = try gpa.alloc(Paths, n);
    for (bases) |*x| x.* = .empty;
    defer {
        for (bases) |*x| x.deinit(gpa);
        gpa.free(bases);
    }
    const Base = struct {
        gpa: Allocator,
        blocked: []const Paths,
        bases: []Paths,
        z_gap: usize,
        tip: i64,
        fn run(c: *const @This(), i: usize) !void {
            var arena_b = std.heap.ArenaAllocator.init(c.gpa);
            defer arena_b.deinit();
            const ab = arena_b.allocator();
            var base = c.blocked[i];
            var k: usize = 1;
            while (k <= c.z_gap + 1 and k <= i) : (k += 1) base = try clip.unite(ab, base, c.blocked[i - k]);
            var grown = try offset_mod.offset(ab, base, c.tip, .{});
            @import("support.zig").simplifyAll(&grown, 30);
            c.bases[i] = try grown.clone(c.gpa);
        }
    };
    // Every `every` layers: a base, and the avoidance of the layer `every`
    // under it, moved in by `every` steps. The chain of offsets is the slow
    // part. A layer between uses the avoidance of the computed layer under
    // it, and the test of a node moves its edge in by the steps between
    // (the slack in `grow`): with no slack, the edge would jump by 5 steps
    // on every 5th layer, too far for a branch to follow.
    const every = avoid_every;
    const m = top / every + 1;
    const Sel = struct {
        base: *const Base,
        every: usize,
        fn run(c: *const @This(), k: usize) !void {
            try Base.run(c.base, k * c.every);
        }
    };
    const bc: Base = .{ .gpa = gpa, .blocked = blocked, .bases = bases, .z_gap = params.z_gap, .tip = @intFromFloat(params.tip) };
    const sc: Sel = .{ .base = &bc, .every = every };
    @import("parallel.zig").forEach(threads, m, &sc, Sel.run) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    avoid[0] = try bases[0].clone(arena);
    var i: usize = every;
    while (i <= top) : (i += every) {
        var drop: f64 = 0;
        for (i - every + 1..i + 1) |q| drop += @floatFromInt(geom.fromMm(layers[q].height));
        const shrunk = try offset_mod.offset(arena, avoid[i - every], -@as(i64, @intFromFloat(drop * params.tan_angle)), .{});
        var u = try clip.unite(arena, bases[i], shrunk);
        @import("support.zig").simplifyAll(&u, 30);
        avoid[i] = u;
    }
    for (0..top + 1) |q| if (q % every != 0) {
        avoid[q] = avoid[q - q % every];
    };
    return avoid;
}

fn insidePoly(poly: []const Point, x: f64, y: f64) bool {
    var ps: Paths = .empty;
    ps.points.items = @constCast(poly);
    var ends = [_]u32{@intCast(poly.len)};
    ps.ends.items = &ends;
    return geom.insideAny(ps, .{ .x = @intFromFloat(x), .y = @intFromFloat(y) });
}

/// A point inside a polygon: the centroid if it is inside, else the middle
/// of the widest scan line through the centroid height.
fn pointInside(poly: []const Point) ?[2]f64 {
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (poly) |p| {
        cx += @floatFromInt(p.x);
        cy += @floatFromInt(p.y);
    }
    cx /= @floatFromInt(poly.len);
    cy /= @floatFromInt(poly.len);
    if (insidePoly(poly, cx, cy)) return .{ cx, cy };
    // The crossings of the line y = cy.
    var xs: [64]f64 = undefined;
    var nx: usize = 0;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const ay: f64 = @floatFromInt(a.y);
        const by: f64 = @floatFromInt(b.y);
        if ((ay <= cy) != (by <= cy) and nx < xs.len) {
            const t = (cy - ay) / (by - ay);
            xs[nx] = @as(f64, @floatFromInt(a.x)) + t * @as(f64, @floatFromInt(b.x - a.x));
            nx += 1;
        }
    }
    std.mem.sort(f64, xs[0..nx], {}, std.sort.asc(f64));
    var best: ?[2]f64 = null;
    var best_w: f64 = 0;
    var i: usize = 0;
    while (i + 1 < nx) : (i += 2) {
        if (xs[i + 1] - xs[i] > best_w) {
            best_w = xs[i + 1] - xs[i];
            best = .{ (xs[i] + xs[i + 1]) / 2, cy };
        }
    }
    return best;
}

/// Moves a node out of the part (the area of `fence`) by at most `step`,
/// so that its radius fits. Only if the move is not enough does the
/// radius get smaller, down to `floor`. Returns false if there is no room
/// for `floor`.
fn fit(nd: *Node, fence: ?geom.EdgeIndex, pad: f64, step: f64, floor: f64) bool {
    const fi = fence orelse return true;
    var moved: f64 = 0;
    var iter: usize = 0;
    while (true) : (iter += 1) {
        const inside = fi.inside(pointOf(nd));
        const near = fi.nearestPoint(nd.x, nd.y, pad) orelse return !inside;
        const clearance = if (inside) -near[2] else near[2];
        if (clearance >= nd.r) return true;
        if (moved >= step or iter >= 6) {
            // No more move on this layer: a thinner branch, if it can.
            if (clearance >= floor) {
                nd.r = clearance;
                return true;
            }
            return false;
        }
        // Move away from the nearest edge point, out of the part.
        var dx = nd.x - near[0];
        var dy = nd.y - near[1];
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 1) {
            // On the edge: the way out is a direction to a point out of
            // the fence.
            const dir = outward(fi, nd.x, nd.y) orelse return false;
            dx = dir[0];
            dy = dir[1];
        } else {
            if (inside) {
                dx = -dx;
                dy = -dy;
            }
            dx /= dist;
            dy /= dist;
        }
        const d = @max(1, @min(step - moved, nd.r - clearance + 1));
        nd.x += dx * d;
        nd.y += dy * d;
        moved += d;
    }
}

/// A unit direction from (x, y), a point on the edge of `fi`, to a point
/// out of the area, or null.
fn outward(fi: geom.EdgeIndex, x: f64, y: f64) ?[2]f64 {
    for (0..16) |k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 16.0;
        const c = @cos(t);
        const sn = @sin(t);
        if (!fi.inside(.{ .x = @intFromFloat(x + 20 * c), .y = @intFromFloat(y + 20 * sn) })) return .{ c, sn };
    }
    return null;
}

/// A circle as a counterclockwise polygon with 16 points.
fn circle(a: Allocator, x: f64, y: f64, r: f64) Allocator.Error![]Point {
    const pts = try a.alloc(Point, 16);
    for (pts, 0..) |*p, i| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 16.0;
        p.* = .{ .x = @intFromFloat(@round(x + r * @cos(t))), .y = @intFromFloat(@round(y + r * @sin(t))) };
    }
    return pts;
}

const testing = std.testing;

fn squarePaths(a: Allocator, x0: i64, y0: i64, x1: i64, y1: i64) !Paths {
    var p: Paths = .empty;
    try p.append(a, &.{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) });
    return p;
}

test "fit moves a node on the edge of the part out of it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const part = try squarePaths(a, 0, 0, 10_000, 10_000);
    const fi = (try index(a, part, 5000)).?;
    // On the edge x = 10 mm, as a tip on the edge of a pad is.
    var nd: Node = .{ .x = 10_000, .y = 5000, .r = 500 };
    try testing.expect(fit(&nd, fi, 5000, 1000, 500));
    try testing.expect(nd.x >= 10_499 and @abs(nd.y - 5000) < 1);
}

test "a branch never gets thinner on the way down" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var branches: Branches = .{};
    try branches.into.append(a, none);
    const disks = try a.alloc(std.ArrayList(Disk), 5);
    for (disks) |*d| d.* = .empty;
    // A thin neck (1 mm at layer 1) under a thick collar (5 mm at layer 2),
    // and a thin tip on top: the neck gets the collar's radius.
    const radii = [_]f64{ 3000, 1000, 5000, 2000, 1000 };
    for (disks, radii) |*d, r| try d.append(a, .{ .x = 0, .y = 0, .r = r, .id = 0 });
    try steady(a, disks, &branches);
    try taper(a, disks, &branches, 1000, 500);
    const want = [_]f64{ 5000, 5000, 5000, 2000, 1000 };
    for (disks, want) |d, w| try testing.expectEqual(w, d.items[0].r);
}
