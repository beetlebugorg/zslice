//! Tree support: thin branches that hold up the overhangs and grow down to
//! the bed (or to the part), and join on the way.
//!
//! Grid support fills all the space under an overhang. A tree touches the
//! overhang only at points, so it uses less plastic, comes off more
//! easily, and leaves fewer marks on the part. The method:
//!
//! 1. Tips. The top layers under an overhang (from support.zig, step 1)
//!    are the interface: a dense pad, as in grid support. The tips start
//!    under the pad. A tip goes on each point of a fixed triangle grid in
//!    the overhang (`support_tree_spacing` apart, the same grid on all
//!    layers, so that the tips of a slope line up), and on points along the
//!    edge of the overhang, one spacing apart, so that the edges of the pad
//!    have support too. Under a slope, the overhang is a strip thinner than
//!    a tip, so the edge points go along the strip itself. An island with
//!    no tip gets one. An edge point or an island point is skipped if a tip
//!    of the same layer or of the layers just above is near: on a slope,
//!    each layer adds only a thin strip. A tip near the part moves out
//!    until it has room for its radius. The pad above spans the gap.
//! 2. Down, one layer at a time. Each branch is a node: a center and a
//!    radius. In one layer, a node moves at most h * tan(branch angle).
//!    It moves toward its nearest node, if the two can meet within a few
//!    spacings. Two nodes that touch join into one thicker node, if the
//!    new circle holds the two old circles; two thick branches first come
//!    nearer. So the branches of an overhang join into a few strong trunks.
//!    To reach the bed (not rest on the part), a branch also stays out of
//!    the avoidance area of each layer: the points from which no branch
//!    can reach the bed. Layer 0 avoids the part. Layer j avoids the part
//!    and the layers under it (the Z gap), and the avoidance of layer j - 1
//!    moved in by one step: a point deeper in it than one step cannot get
//!    out in time. A branch in the avoidance area moves out of it, if it
//!    can in one step. So a branch over the part bends out and around the
//!    part, and goes down beside it to the bed. (Cura's tree support uses
//!    an avoidance area in the same way; see REFERENCES.md.)
//! 3. The radius grows as the branch goes down (stronger near the bed),
//!    and a join keeps the area of the two branches. The radius gets
//!    smaller again where the space is narrow, down to the tip radius. So
//!    a branch can go down a deep, narrow hole. Near the bed, a branch to
//!    the bed gets wider at 45 degrees, up to the foot radius, so that it
//!    holds on the bed. A branch keeps the XY gap
//!    from the part; its top layers keep only the smaller gap under an
//!    overhang, so that the tips under a slope stay. A branch beside the
//!    part with no room for its radius goes on, and the gap cuts its
//!    circle. A branch in the gap stops: it rests on the part (it stops
//!    the Z gap above it), or, with bed-only support, it is removed. Each
//!    branch keeps the branch that it joins. So the branches above it that
//!    do not join a branch to the bed go too.
//! 4. Taper, from the bed up. A circle must be in the circle of its branch
//!    on the layer under it, moved out by two tip radii. So where a branch
//!    gets thin in a narrow space, the branch above it gets thin too, as a
//!    cone, and no part of a branch hangs in the air.
//! 5. The area of each layer is the union of the circles of its nodes.
//!    support.zig then adds the interface, and the layer plan prints the
//!    area as it prints grid support.
//!
//! The near nodes come from a grid of cells, and the edges of the part
//! from an edge index (geom.EdgeIndex), so a layer with many branches
//! stays fast. The unions of the circles run on all threads.
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
const Point = geom.Point;
const Paths = geom.Paths;

const Node = struct {
    x: f64,
    y: f64,
    /// The radius, in µm.
    r: f64,
    alive: bool = true,
    /// The branch can still reach the bed (it is out of the avoidance
    /// area, or one step from its edge). A branch that can does not join or
    /// follow a branch that cannot, so it does not end on the part.
    free: bool = true,
    /// The layers since the tip.
    age: u32 = 0,
    /// The branch of the node (see `Branches`).
    id: u32 = no_branch,
};

const no_branch = std.math.maxInt(u32);

/// The avoidance area is made on every 5th layer (see `avoidance`).
const avoid_every: usize = 5;

/// The branches, for the bed-only rule: a branch reaches the bed if its
/// node is on layer 0, or if it joins a branch that reaches the bed.
const Branches = struct {
    /// The branch that each branch joins, or `no_branch`.
    into: std.ArrayList(u32) = .empty,
    bed: std.ArrayList(bool) = .empty,

    fn reaches(b: *const Branches, id: u32) bool {
        var k = id;
        while (k != no_branch) : (k = b.into.items[k]) {
            if (b.bed.items[k]) return true;
        }
        return false;
    }
};

/// A tip of an earlier layer, for the spacing of new tips.
const Tip = struct { x: f64, y: f64, layer: usize };

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
    /// The radius of a branch on the bed, µm (see `grow`).
    foot: f64 = 0,
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
) Allocator.Error![]Paths {
    const n = outlines.len;
    const out = try gpa.alloc(Paths, n);
    for (out) |*o| o.* = .empty;
    errdefer {
        for (out) |*o| o.deinit(gpa);
        gpa.free(out);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each layer adds its disks; the union comes at the end.
    const disks = try arena.alloc(std.ArrayList(Disk), n);
    for (disks) |*c| c.* = .empty;
    var branches: Branches = .{};
    const avoid = try avoidance(gpa, arena, threads, layers, need, blocked, tips_below, params);

    var nodes: std.ArrayList(Node) = .empty;
    var recent: std.ArrayList(Tip) = .empty;
    // The pad of the edge indexes: a node looks for edges at most this far.
    const pad = 2 * params.max_r + params.spacing;
    var j: usize = n;
    while (j > 0) {
        j -= 1;
        var layer_state = std.heap.ArenaAllocator.init(gpa);
        defer layer_state.deinit();
        const la = layer_state.allocator();
        const h = geom.fromMm(layers[j].height);
        const step = @as(f64, @floatFromInt(h)) * params.tan_angle;
        // New tips: the overhang of layer src has its tips on layer j.
        const src = j + tips_below;
        if (src < n and !need[src].isEmpty()) try addTips(arena, la, &nodes, &recent, need[src], near[j], j, step, params);
        if (nodes.items.len == 0) continue;
        for (nodes.items) |*nd| if (nd.id == no_branch) {
            nd.id = @intCast(branches.into.items.len);
            try branches.into.append(arena, no_branch);
            try branches.bed.append(arena, false);
        };
        const bidx = try index(la, blocked[j], pad);
        const nidx = try index(la, near[j], pad);
        const aidx = try index(la, avoid[j], pad);

        // 1. Toward the nearest node: two branches that are near join on
        // the way down, into a thicker branch.
        try attract(la, nodes.items, step, params, aidx);
        // The avoidance of this layer is the computed avoidance of a layer
        // under it, moved in by `slack` (see `avoidance`).
        var slack: f64 = 0;
        for (j - j % avoid_every + 1..j + 1) |q| slack += @as(f64, @floatFromInt(geom.fromMm(layers[q].height))) * params.tan_angle;
        for (nodes.items) |*nd| {
            if (!nd.alive) continue;
            nd.age +|= 1;
            // 2. Out of the avoidance area, toward the bed, if one step is
            // enough. Else the branch goes on, and rests on the part.
            nd.free = true;
            if (aidx) |ai| if (ai.inside(pointOf(nd))) {
                const e = ai.nearestPoint(nd.x, nd.y, pad);
                const depth = if (e) |ee| ee[2] - slack else std.math.inf(f64);
                if (depth > 0) {
                    nd.free = depth <= step * 1.5 + 1;
                    if (nd.free) {
                        const dx = e.?[0] - nd.x;
                        const dy = e.?[1] - nd.y;
                        const d = @max(@sqrt(dx * dx + dy * dy), 1e-6);
                        // Just past the edge.
                        nd.x += dx / d * (depth + 20);
                        nd.y += dy / d * (depth + 20);
                    }
                }
            };
            // 3. The radius grows with the drop, but not over the free
            // space. Near the tip, the branch keeps the XY gap under an
            // overhang only, so the tips under a slope stay.
            nd.r = @min(params.max_r, nd.r + params.growth * @as(f64, @floatFromInt(h)));
            // The foot: near the bed, a branch to the bed gets wider at 45
            // degrees, up to `foot`, so that it holds on the bed.
            if (nd.free) {
                const z: f64 = @floatFromInt(geom.fromMm(layers[j].z));
                nd.r = @max(nd.r, params.foot - z);
            }
            const fence = if (nd.age <= params.tip_layers) nidx else bidx;
            if (!fit(nd, fence, pad, step, params.tip)) {
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
        while (k <= params.z_gap + 1 and k <= j) : (k += 1) {
            const oi = (try index(la, outlines[j - k], 0)) orelse continue;
            for (nodes.items) |*nd| {
                if (nd.alive and oi.inside(pointOf(nd))) nd.alive = false;
            }
        }
        try join(la, nodes.items, params.max_r, 2 * params.tip, &branches);
        // 4. The circles of this layer.
        for (nodes.items) |nd| if (nd.alive) {
            try disks[j].append(arena, .{ .x = nd.x, .y = nd.y, .r = nd.r, .id = nd.id });
            if (j == 0) branches.bed.items[nd.id] = true;
        };
        // Drop the nodes that ended.
        var keep: usize = 0;
        for (nodes.items) |nd| if (nd.alive) {
            nodes.items[keep] = nd;
            keep += 1;
        };
        nodes.items.len = keep;
    }
    try taper(arena, disks, &branches, 2 * params.tip, params.tip);
    // The circles of each layer. Bed only: the circles of the branches that
    // do not reach the bed go.
    const circles = try arena.alloc(Paths, n);
    for (circles, disks) |*c, ds| {
        c.* = .empty;
        for (ds.items) |d| {
            if (params.bed_only and !branches.reaches(d.id)) continue;
            try c.append(arena, try circle(arena, d.x, d.y, d.r));
        }
    }
    // The union of the circles of each layer, minus the part, on all
    // threads.
    const Union = struct {
        gpa: Allocator,
        circles: []const Paths,
        blocked: []const Paths,
        out: []Paths,
        fn run(c: *const @This(), i: usize) !void {
            if (c.circles[i].isEmpty()) return;
            var a = std.heap.ArenaAllocator.init(c.gpa);
            defer a.deinit();
            const u = try clip.unionAll(a.allocator(), c.circles[i], .non_zero);
            const free = try clip.difference(a.allocator(), u, c.blocked[i]);
            c.out[i] = try free.clone(c.gpa);
        }
    };
    const uc: Union = .{ .gpa = gpa, .circles = circles, .blocked = blocked, .out = out };
    @import("parallel.zig").forEach(threads, n, &uc, Union.run) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return out;
}

/// A circle of a branch on one layer.
const Disk = struct { x: f64, y: f64, r: f64, id: u32 };

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
                if (into == no_branch) break :blk null;
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

/// Adds the tips of the overhang `area` on layer j: the points of a fixed
/// triangle grid in the area (the same grid on all layers, so that the
/// tips of a slope line up), points along the edge of the area, and one
/// point in each island that has no tip. An edge point or an island point
/// is not added if a tip of this layer or of the layers just above is
/// nearer than 0.6 spacings: on a slope, each layer adds only a thin
/// strip.
fn addTips(
    a: Allocator,
    la: Allocator,
    nodes: *std.ArrayList(Node),
    recent: *std.ArrayList(Tip),
    need: Paths,
    near: Paths,
    j: usize,
    step: f64,
    params: Params,
) Allocator.Error!void {
    _ = step;
    const sp = params.spacing;
    // The tips of the layers within one spacing of height above.
    const reach: usize = 16;
    var keep: usize = 0;
    for (recent.items) |t| if (t.layer <= j + reach) {
        recent.items[keep] = t;
        keep += 1;
    };
    recent.items.len = keep;
    const area = try clip.difference(la, need, near);
    if (area.isEmpty()) return;
    const first = nodes.items.len;
    const b = area.bounds();
    const ai = try geom.EdgeIndex.init(la, area, 0);
    // The grid. Odd rows move by half a spacing (a triangle grid); the
    // rows are sqrt(3) / 2 spacings apart.
    const row_h = sp * 0.8660254037844386;
    var row: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(b.min.y)) / row_h));
    const row_end: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(b.max.y)) / row_h));
    while (row <= row_end) : (row += 1) {
        const y = @as(f64, @floatFromInt(row)) * row_h;
        const shift = if (@mod(row, 2) == 0) 0 else sp / 2;
        var col: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(b.min.x)) / sp) - 1);
        const col_end: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(b.max.x)) / sp) + 1);
        while (col <= col_end) : (col += 1) {
            const x = @as(f64, @floatFromInt(col)) * sp + shift;
            if (ai.inside(.{ .x = @intFromFloat(x), .y = @intFromFloat(y) })) {
                try nodes.append(a, .{ .x = x, .y = y, .r = params.tip });
            }
        }
    }
    // The edge: points along the area moved in by the tip radius. A strip
    // thinner than a tip (under a slope) has no inner area, so then the
    // points go along the edge of the area itself.
    const min_d = 0.6 * sp;
    const inner = try offset_mod.offset(la, area, -@as(i64, @intFromFloat(params.tip)), .{});
    try edgeTips(a, nodes, first, recent.items, inner, sp, min_d, params.tip);
    try edgeTips(a, nodes, first, recent.items, area, sp, min_d, params.tip);
    // Islands with no tip: a tip at a point inside each one.
    for (0..area.count()) |k| {
        const poly = area.get(k);
        if (geom.area2(poly) <= 0) continue; // a hole
        var has = false;
        for (nodes.items[first..]) |nd| {
            if (insidePoly(poly, nd.x, nd.y)) {
                has = true;
                break;
            }
        }
        if (has) continue;
        const p = pointInside(poly) orelse continue;
        if (hasTipNear(nodes.items[first..], recent.items, p[0], p[1], min_d)) continue;
        try nodes.append(a, .{ .x = p[0], .y = p[1], .r = params.tip });
    }
    // A tip near the part moves out, so that it has room for its radius.
    // The pad above spans the gap.
    const pad = 2 * params.max_r + params.spacing;
    if (try index(la, near, pad)) |ni| {
        for (nodes.items[first..]) |*nd| _ = fit(nd, ni, pad, 2 * params.tip, params.tip);
    }
    for (nodes.items[first..]) |nd| try recent.append(a, .{ .x = nd.x, .y = nd.y, .layer = j });
}

/// Adds a tip at points along the loops of `paths`, one spacing apart,
/// where no tip of this layer (from `first`) or of the recent layers is
/// nearer than `min_d`.
fn edgeTips(
    a: Allocator,
    nodes: *std.ArrayList(Node),
    first: usize,
    recent: []const Tip,
    paths: Paths,
    sp: f64,
    min_d: f64,
    tip: f64,
) Allocator.Error!void {
    for (0..paths.count()) |k| {
        const poly = paths.get(k);
        var walked: f64 = sp; // a point at the start of each loop
        for (poly, 0..) |p, i| {
            const q = poly[(i + 1) % poly.len];
            const px: f64 = @floatFromInt(p.x);
            const py: f64 = @floatFromInt(p.y);
            const ex = @as(f64, @floatFromInt(q.x)) - px;
            const ey = @as(f64, @floatFromInt(q.y)) - py;
            const len = @sqrt(ex * ex + ey * ey);
            var t: f64 = 0;
            while (t < len) {
                const left = sp - walked;
                if (left > len - t) {
                    walked += len - t;
                    break;
                }
                t += left;
                walked = 0;
                const x = px + ex * t / len;
                const y = py + ey * t / len;
                if (!hasTipNear(nodes.items[first..], recent, x, y, min_d)) {
                    try nodes.append(a, .{ .x = x, .y = y, .r = tip });
                }
            }
        }
    }
}

fn hasTipNear(new: []const Node, recent: []const Tip, x: f64, y: f64, d: f64) bool {
    const d2 = d * d;
    for (new) |nd| {
        if ((nd.x - x) * (nd.x - x) + (nd.y - y) * (nd.y - y) < d2) return true;
    }
    for (recent) |t| {
        if ((t.x - x) * (t.x - x) + (t.y - y) * (t.y - y) < d2) return true;
    }
    return false;
}

/// The nodes of a layer in cells of a square grid, for the search of the
/// near nodes.
const Cells = struct {
    size: f64,
    /// The cell key of each entry, sorted, and the node of each entry.
    keys: []u64,
    ids: []u32,

    fn key(cx: i64, cy: i64) u64 {
        const ux: u64 = @bitCast(cx +% (1 << 31));
        const uy: u64 = @bitCast(cy +% (1 << 31));
        return (ux << 32) | (uy & 0xffff_ffff);
    }

    fn cellOf(c: Cells, v: f64) i64 {
        return @intFromFloat(@floor(v / c.size));
    }

    fn build(a: Allocator, nodes: []const Node, size: f64) Allocator.Error!Cells {
        var c: Cells = .{ .size = size, .keys = &.{}, .ids = &.{} };
        var count: usize = 0;
        for (nodes) |nd| if (nd.alive) {
            count += 1;
        };
        const pairs = try a.alloc([2]u64, count);
        var k: usize = 0;
        for (nodes, 0..) |nd, i| if (nd.alive) {
            pairs[k] = .{ key(c.cellOf(nd.x), c.cellOf(nd.y)), i };
            k += 1;
        };
        std.mem.sort([2]u64, pairs, {}, struct {
            fn lt(_: void, x: [2]u64, y: [2]u64) bool {
                return x[0] < y[0];
            }
        }.lt);
        c.keys = try a.alloc(u64, count);
        c.ids = try a.alloc(u32, count);
        for (pairs, 0..) |p, i| {
            c.keys[i] = p[0];
            c.ids[i] = @intCast(p[1]);
        }
        return c;
    }

    /// The entries of one cell.
    fn cell(c: Cells, cx: i64, cy: i64) []const u32 {
        const kk = key(cx, cy);
        var lo: usize = 0;
        var hi: usize = c.keys.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (c.keys[mid] < kk) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < c.keys.len and c.keys[end] == kk) end += 1;
        return c.ids[lo..end];
    }
};

/// Moves each node toward its nearest node (of the same kind, free or
/// not) by at most one step, if the two can meet within a few spacings.
/// The targets come from the positions before the moves. A free node does
/// not move into the avoidance area.
fn attract(a: Allocator, nodes: []Node, step: f64, params: Params, avoid: ?geom.EdgeIndex) Allocator.Error!void {
    const reach = 4 * params.spacing + 2 * params.max_r;
    const cells = try Cells.build(a, nodes, reach);
    const moves = try a.alloc([2]f64, nodes.len);
    for (nodes, 0..) |*nd, i| {
        moves[i] = .{ 0, 0 };
        if (!nd.alive) continue;
        const cx = cells.cellOf(nd.x);
        const cy = cells.cellOf(nd.y);
        var best: ?usize = null;
        var best_d: f64 = std.math.inf(f64);
        var gx = cx - 1;
        while (gx <= cx + 1) : (gx += 1) {
            var gy = cy - 1;
            while (gy <= cy + 1) : (gy += 1) {
                for (cells.cell(gx, gy)) |o| {
                    if (o == i) continue;
                    const on = nodes[o];
                    if (on.free != nd.free) continue;
                    const d = @sqrt((on.x - nd.x) * (on.x - nd.x) + (on.y - nd.y) * (on.y - nd.y));
                    if (d < best_d) {
                        best_d = d;
                        best = o;
                    }
                }
            }
        }
        const o = best orelse continue;
        const on = nodes[o];
        if (best_d < 1e-6 or best_d > 4 * params.spacing + nd.r + on.r) continue;
        // Both nodes move, so each goes at most half the way.
        const m = @min(step, best_d / 2);
        moves[i] = .{ (on.x - nd.x) / best_d * m, (on.y - nd.y) / best_d * m };
    }
    for (nodes, moves) |*nd, mv| {
        if (mv[0] == 0 and mv[1] == 0) continue;
        const to: Point = .{ .x = @intFromFloat(nd.x + mv[0]), .y = @intFromFloat(nd.y + mv[1]) };
        // A free branch does not move into the avoidance area: the move
        // out of it takes the whole step of the layer.
        if (avoid) |ai| if (nd.free and ai.inside(to) and !ai.inside(pointOf(nd))) continue;
        nd.x += mv[0];
        nd.y += mv[1];
    }
}

/// Joins nodes that touch (the center of one is in the other): the new
/// node is at the middle (weighted by the area of each), with the radius of
/// the same area, up to `max_r`. Two nodes join only if the new circle
/// holds each old circle, up to `slack`: else the new layer has support
/// under only a part of the layer above.
fn join(a: Allocator, nodes: []Node, max_r: f64, slack: f64, branches: *Branches) Allocator.Error!void {
    var big: f64 = 1;
    for (nodes) |nd| big = @max(big, nd.r);
    const cells = try Cells.build(a, nodes, 2 * big);
    for (nodes, 0..) |*nd, i| {
        if (!nd.alive) continue;
        const cx = cells.cellOf(nd.x);
        const cy = cells.cellOf(nd.y);
        var gx = cx - 1;
        while (gx <= cx + 1) : (gx += 1) {
            var gy = cy - 1;
            while (gy <= cy + 1) : (gy += 1) {
                for (cells.cell(gx, gy)) |o| {
                    if (o <= i) continue;
                    const b = &nodes[o];
                    if (!b.alive or b.free != nd.free) continue;
                    const dx = b.x - nd.x;
                    const dy = b.y - nd.y;
                    const touch = @max(nd.r, b.r);
                    if (dx * dx + dy * dy > touch * touch) continue;
                    const wa = nd.r * nd.r;
                    const wb = b.r * b.r;
                    const x = (nd.x * wa + b.x * wb) / (wa + wb);
                    const y = (nd.y * wa + b.y * wb) / (wa + wb);
                    const r = @min(max_r, @sqrt(wa + wb));
                    // The new circle must hold the two circles above it,
                    // up to `slack`. Two thick branches first come nearer.
                    if (@sqrt((x - nd.x) * (x - nd.x) + (y - nd.y) * (y - nd.y)) + nd.r > r + slack) continue;
                    if (@sqrt((x - b.x) * (x - b.x) + (y - b.y) * (y - b.y)) + b.r > r + slack) continue;
                    nd.x = x;
                    nd.y = y;
                    nd.r = r;
                    nd.age = @min(nd.age, b.age);
                    branches.into.items[b.id] = nd.id;
                    b.alive = false;
                }
            }
        }
    }
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
/// and makes its radius smaller where the space is narrow, down to `tip`.
/// Returns false if there is no room.
fn fit(nd: *Node, fence: ?geom.EdgeIndex, pad: f64, step: f64, tip: f64) bool {
    const fi = fence orelse return true;
    var moved: f64 = 0;
    var iter: usize = 0;
    while (iter < 4) : (iter += 1) {
        const inside = fi.inside(pointOf(nd));
        const near = fi.nearestPoint(nd.x, nd.y, pad) orelse return !inside;
        const clearance = if (inside) -near[2] else near[2];
        if (clearance >= nd.r) return true;
        // Narrow space: a thinner branch fits without a move.
        if (clearance >= tip) {
            nd.r = clearance;
            return true;
        }
        // Move away from the nearest edge point, out of the part.
        if (moved >= step) return false;
        var dx = nd.x - near[0];
        var dy = nd.y - near[1];
        var d = @sqrt(dx * dx + dy * dy);
        if (d < 1) {
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
            dx /= d;
            dy /= d;
        }
        const want = @min(step - moved, (if (inside) near[2] else 0) + tip - (if (inside) 0 else near[2]) + 1);
        d = @max(want, 1);
        nd.x += dx * d;
        nd.y += dy * d;
        moved += d;
    }
    return false;
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

test "edge tips go along a strip thinner than a tip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A strip 0.2 mm wide and 20 mm long: no inner area.
    const strip = try squarePaths(a, 0, 0, 20_000, 200);
    var nodes: std.ArrayList(Node) = .empty;
    try edgeTips(a, &nodes, 0, &.{}, strip, 3000, 1800, 500);
    // A tip about each 3 mm along the strip.
    try testing.expect(nodes.items.len >= 6);
    for (nodes.items) |nd| try testing.expect(nd.y >= 0 and nd.y <= 200);
}

test "join keeps two thick branches apart until they are near" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var branches: Branches = .{};
    for (0..2) |_| {
        try branches.into.append(a, no_branch);
        try branches.bed.append(a, false);
    }
    // Two nodes at the largest radius, 4 mm apart: one circle of 5 mm
    // cannot hold both.
    var nodes = [_]Node{
        .{ .x = 0, .y = 0, .r = 5000, .id = 0 },
        .{ .x = 4000, .y = 0, .r = 5000, .id = 1 },
    };
    try join(a, &nodes, 5000, 1000, &branches);
    try testing.expect(nodes[0].alive and nodes[1].alive);
    // Two thin nodes join into one.
    nodes = .{
        .{ .x = 0, .y = 0, .r = 500, .id = 0 },
        .{ .x = 400, .y = 0, .r = 500, .id = 1 },
    };
    try join(a, &nodes, 5000, 1000, &branches);
    try testing.expect(nodes[0].alive and !nodes[1].alive);
    try testing.expectEqual(@as(u32, 0), branches.into.items[1]);
}

test "taper makes a branch over a thin disk thin, as a cone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var branches: Branches = .{};
    try branches.into.append(a, no_branch);
    try branches.bed.append(a, true);
    const disks = try a.alloc(std.ArrayList(Disk), 4);
    for (disks) |*d| d.* = .empty;
    // A branch of radius 5 mm with a thin layer (1 mm) at layer 1.
    const radii = [_]f64{ 5000, 1000, 5000, 5000 };
    for (disks, radii) |*d, r| try d.append(a, .{ .x = 0, .y = 0, .r = r, .id = 0 });
    try taper(a, disks, &branches, 1000, 500);
    try testing.expectEqual(@as(f64, 5000), disks[0].items[0].r);
    try testing.expectEqual(@as(f64, 1000), disks[1].items[0].r);
    try testing.expectEqual(@as(f64, 2000), disks[2].items[0].r);
    try testing.expectEqual(@as(f64, 3000), disks[3].items[0].r);
}
