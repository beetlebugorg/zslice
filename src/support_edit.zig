//! The support editor: edits of tree support by hand.
//!
//! The trees of a part are a skeleton of nodes (support_skeleton.zig).
//! The user moves a node, changes its radius, moves or deletes a branch,
//! or adds a branch from a point on the bed to a point under the part.
//! Each edit keeps the rules of the planner (tree_support.zig), and
//! clamps the edit where it breaks one:
//!
//! - The part. The center of a node stays out of the part moved out by
//!   the XY gap, by at least the radius of a tip. A tip keeps only the
//!   smaller gap under an overhang, as in the plan. A node that the edit
//!   puts in the part moves out from the nearest edge.
//! - The lean. A segment leans at most the branch angle from vertical:
//!   its run is at most tan(angle) times its rise. A node that the edit
//!   puts too far goes to the nearest place that each of its segments
//!   allows (the discs around its neighbors, in turns, until they agree).
//! - The radius. A node is at least as wide as the rules of the plan need
//!   (5. in the header of tree_support.zig: the bend rule, the buckling
//!   rule, and `min_r` under the tip layers), and at most `max_r`.
//!
//! A rule that the trees broke before the edit does not stop the edit: a
//! limit is never tighter than the state before it. Each edit returns the
//! rules that clamped it (`Clamp`), so the view can show them.
//!
//! A new branch (`addBranch`) is planned as the planner plans a branch:
//! a tip with a straight head, then straight segments down to the foot,
//! sized by the rules, with a wider foot on the bed. Of three shapes (one
//! straight lean; a lean first, then down; down first, then a lean), it
//! takes the first one that stays out of the part.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const offset_mod = @import("offset.zig");
const tree = @import("tree_support.zig");
const skel = @import("support_skeleton.zig");
const Paths = geom.Paths;
const Skeleton = skel.Skeleton;
const none = skel.none;

/// The rules that clamped an edit.
pub const Clamp = struct {
    pub const part: u32 = 1;
    pub const lean: u32 = 2;
    pub const radius_min: u32 = 4;
    pub const radius_max: u32 = 8;
    /// A new branch: the foot moved nearer to the tip, so that the branch
    /// can reach it.
    pub const reach: u32 = 16;
};

pub const Error = Allocator.Error || error{ NoNode, NoRoom };

/// The part and the rules for the edits of the trees of one part.
pub const Ctx = struct {
    /// The memory of the context (an arena: the edge indexes stay in it).
    a: Allocator,
    params: tree.Params,
    /// The top z of each layer, and the height of each layer (µm).
    z: []const f64,
    h: []const f64,
    /// The outlines of the part on each layer (the frame of the job).
    outlines: []const Paths,
    /// The part moved out by the XY gap, and by the smaller gap under an
    /// overhang, if the slice has them (else made when needed).
    blocked: []const Paths = &.{},
    near: []const Paths = &.{},
    /// The XY gaps (units of geom).
    xy: i64,
    xy_under: i64,
    /// The layers from an overhang down to its tips.
    tips_below: u32,
    /// The place of the origin of the skeleton in the frame of the job
    /// (µm): the nodes are relative to it.
    ox: f64 = 0,
    oy: f64 = 0,
    fences: std.AutoHashMapUnmanaged(u64, ?geom.EdgeIndex) = .empty,

    /// The search distance of the edge indexes (µm).
    const pad: f64 = 20_000;

    pub fn layers(c: *const Ctx) usize {
        return c.z.len;
    }

    /// The fence of a layer: the part moved out by the XY gap (or the gap
    /// under an overhang, for a tip).
    fn fence(c: *Ctx, layer: u32, tip: bool) Allocator.Error!?geom.EdgeIndex {
        const key = @as(u64, layer) * 2 + @intFromBool(tip);
        if (c.fences.get(key)) |f| return f;
        const src = if (tip) c.near else c.blocked;
        const paths = if (src.len == c.outlines.len) src[layer] else try offset_mod.offset(c.a, c.outlines[layer], if (tip) c.xy_under else c.xy, .{});
        const f: ?geom.EdgeIndex = if (paths.isEmpty()) null else try geom.EdgeIndex.init(c.a, paths, @intFromFloat(pad));
        try c.fences.put(c.a, key, f);
        return f;
    }

    /// The distance of a point (relative to the origin) out of the fence
    /// of a layer: less than 0 in it. `pad` far from all edges.
    pub fn clearance(c: *Ctx, x: f64, y: f64, layer: u32, tip: bool) Allocator.Error!f64 {
        const f = (try c.fence(layer, tip)) orelse return pad;
        const px = x + c.ox;
        const py = y + c.oy;
        const in = f.inside(.{ .x = @intFromFloat(px), .y = @intFromFloat(py) });
        const e = f.nearestPoint(px, py, pad) orelse return if (in) -pad else pad;
        return if (in) -e[2] else e[2];
    }

    /// Moves a point out of the fence until it is `need` µm out of it, in
    /// a few steps away from the nearest edge. False if it cannot.
    fn pushOut(c: *Ctx, p: *[2]f64, layer: u32, tip: bool, need: f64) Allocator.Error!bool {
        const f = (try c.fence(layer, tip)) orelse return true;
        for (0..8) |_| {
            const px = p[0] + c.ox;
            const py = p[1] + c.oy;
            const in = f.inside(.{ .x = @intFromFloat(px), .y = @intFromFloat(py) });
            const e = f.nearestPoint(px, py, pad) orelse return !in;
            const d = if (in) -e[2] else e[2];
            if (d >= need - 1) return true;
            var dx = px - e[0];
            var dy = py - e[1];
            const l = @sqrt(dx * dx + dy * dy);
            if (l < 1) {
                // On the edge: a direction to a point out of the fence.
                const dir = outward(f, px, py) orelse return false;
                dx = dir[0];
                dy = dir[1];
            } else {
                dx /= l;
                dy /= l;
                if (in) {
                    dx = -dx;
                    dy = -dy;
                }
            }
            p[0] = e[0] - c.ox + dx * (need + 2);
            p[1] = e[1] - c.oy + dy * (need + 2);
        }
        return try c.clearance(p[0], p[1], layer, tip) >= need - 1;
    }

    /// The least radius that the rules give a node on layer j under a tip
    /// on layer `top` (see 5. in the header of tree_support.zig), µm.
    pub fn ruleRadius(c: *const Ctx, top: u32, j: u32) f64 {
        const p = c.params;
        var r = p.tip;
        if (top <= j) return r;
        const l_mm = (c.z[top] - c.z[j]) / 1000;
        if (p.bend > 0) r = @max(r, 1000 * std.math.cbrt(p.bend * l_mm * l_mm * l_mm));
        if (p.buckle > 0) r = @max(r, 1000 * std.math.cbrt(p.buckle * l_mm * l_mm));
        const age = top - j;
        if (age > p.tip_layers and p.min_r > 0) {
            const cone = p.tip + @as(f64, @floatFromInt(age - p.tip_layers)) * c.h[j];
            r = @max(r, @min(p.min_r, cone));
        }
        return @min(p.max_r, r);
    }

    /// The most a segment from layer `lo` up to layer `hi` can lean: its
    /// run, µm.
    pub fn reach(c: *const Ctx, lo: u32, hi: u32) f64 {
        if (hi <= lo) return 0;
        return (c.z[hi] - c.z[lo]) * c.params.tan_angle;
    }

    /// The least radius of node i by the rules.
    pub fn minRadius(c: *Ctx, sk: *const Skeleton, i: u32) Allocator.Error!f64 {
        const tops = try sk.topTips(c.a);
        const nd = sk.nodes.items[i];
        return c.ruleRadius(@max(tops[i], nd.layer), nd.layer);
    }
};

/// A unit direction from (x, y), a point on the edge of `f`, to a point
/// out of it, or null.
fn outward(f: geom.EdgeIndex, x: f64, y: f64) ?[2]f64 {
    for (0..16) |k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 16.0;
        if (!f.inside(.{ .x = @intFromFloat(x + 30 * @cos(t)), .y = @intFromFloat(y + 30 * @sin(t)) })) return .{ @cos(t), @sin(t) };
    }
    return null;
}

/// The neighbors of node i: its down node and the nodes over it.
fn neighbors(sk: *const Skeleton, a: Allocator, i: u32) Allocator.Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    const nd = sk.nodes.items[i];
    if (nd.down != none) try out.append(a, nd.down);
    for (sk.nodes.items, 0..) |o, k| if (o.down == i) try out.append(a, @intCast(k));
    return out.toOwnedSlice(a);
}

fn dist(ax: f64, ay: f64, bx: f64, by: f64) f64 {
    return @sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
}

/// The run of the segment between nodes i and k over its limit (0 if it
/// keeps the limit), µm.
fn overLean(c: *const Ctx, sk: *const Skeleton, i: u32, k: u32) f64 {
    const p = sk.nodes.items[i];
    const q = sk.nodes.items[k];
    const lo = @min(p.layer, q.layer);
    const hi = @max(p.layer, q.layer);
    return @max(0, dist(p.x, p.y, q.x, q.y) - c.reach(lo, hi));
}

/// The clearance that node i needs: a tip radius.
fn tipClear(c: *const Ctx) f64 {
    return c.params.tip;
}

/// Moves node i to (x, y) (relative to the origin), within the rules.
/// Returns the Clamp bits.
pub fn moveNode(c: *Ctx, sk: *Skeleton, i: u32, x: f64, y: f64) Error!u32 {
    if (i >= sk.nodes.items.len) return error.NoNode;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.NoNode;
    const nd = sk.nodes.items[i];
    const nb = try neighbors(sk, c.a, i);
    // The limit of each segment: its reach, or its run now if it is over.
    const lim = try c.a.alloc(f64, nb.len);
    for (nb, lim) |k, *l| {
        const o = sk.nodes.items[k];
        l.* = @max(c.reach(@min(o.layer, nd.layer), @max(o.layer, nd.layer)), dist(o.x, o.y, nd.x, nd.y));
    }
    var bits: u32 = 0;
    var p = [2]f64{ x, y };
    if (try leanFit(sk, nb, lim, &p)) bits |= Clamp.lean;
    // Out of the part, unless the node was in it before.
    const was = try c.clearance(nd.x, nd.y, nd.layer, nd.tip);
    const want = @min(tipClear(c), was);
    if (try c.clearance(p[0], p[1], nd.layer, nd.tip) < want - 1) {
        bits |= Clamp.part;
        if (!try c.pushOut(&p, nd.layer, nd.tip, want)) p = .{ nd.x, nd.y };
        // The way out can break a lean: then the node stays.
        for (nb, lim) |k, l| {
            const o = sk.nodes.items[k];
            if (dist(o.x, o.y, p[0], p[1]) > l + 1) {
                p = .{ nd.x, nd.y };
                bits |= Clamp.lean;
                break;
            }
        }
    }
    sk.nodes.items[i].x = p[0];
    sk.nodes.items[i].y = p[1];
    return bits;
}

/// Moves p into the disc of radius lim[k] around each neighbor nb[k], in
/// turns. Returns true if it moved p.
fn leanFit(sk: *const Skeleton, nb: []const u32, lim: []const f64, p: *[2]f64) Allocator.Error!bool {
    var moved = false;
    for (0..16) |_| {
        var all = true;
        for (nb, lim) |k, l| {
            const o = sk.nodes.items[k];
            const d = dist(o.x, o.y, p[0], p[1]);
            if (d <= l + 0.5) continue;
            all = false;
            moved = true;
            p[0] = o.x + (p[0] - o.x) * l / d;
            p[1] = o.y + (p[1] - o.y) * l / d;
        }
        if (all) break;
    }
    return moved;
}

/// Sets the radius of node i (µm), within the rules. Returns the Clamp
/// bits.
pub fn setRadius(c: *Ctx, sk: *Skeleton, i: u32, r: f64) Error!u32 {
    if (i >= sk.nodes.items.len or !std.math.isFinite(r)) return error.NoNode;
    const nd = &sk.nodes.items[i];
    const lo = @min(try c.minRadius(sk, i), nd.r);
    const hi = @max(c.params.max_r, nd.r);
    if (r < lo) {
        nd.r = lo;
        return Clamp.radius_min;
    }
    if (r > hi) {
        nd.r = hi;
        return Clamp.radius_max;
    }
    nd.r = r;
    return 0;
}

/// Moves the branch of node i by (dx, dy) µm, within the rules: as far
/// along the move as each rule allows. Returns the Clamp bits.
pub fn moveBranch(c: *Ctx, sk: *Skeleton, i: u32, dx: f64, dy: f64) Error!u32 {
    if (i >= sk.nodes.items.len or !std.math.isFinite(dx) or !std.math.isFinite(dy)) return error.NoNode;
    const br = try sk.branchOf(c.a, i);
    const in_br = try c.a.alloc(bool, sk.nodes.items.len);
    @memset(in_br, false);
    for (br) |k| in_br[k] = true;
    // The segments from the branch to the rest of the tree.
    var links: std.ArrayList([2]u32) = .empty;
    for (sk.nodes.items, 0..) |nd, k| {
        if (nd.down == none) continue;
        if (in_br[k] != in_br[nd.down]) try links.append(c.a, .{ @intCast(k), nd.down });
    }
    const x0 = try c.a.alloc([2]f64, br.len);
    for (br, x0) |k, *p| p.* = .{ sk.nodes.items[k].x, sk.nodes.items[k].y };
    // The state before: the lean of each link and the clearance of each
    // node. A rule holds at t if it is no worse than before.
    const lean0 = try c.a.alloc(f64, links.items.len);
    for (links.items, lean0) |l, *v| v.* = overLean(c, sk, l[0], l[1]);
    const clear0 = try c.a.alloc(f64, br.len);
    for (br, clear0) |k, *v| {
        const nd = sk.nodes.items[k];
        v.* = @min(tipClear(c), try c.clearance(nd.x, nd.y, nd.layer, nd.tip));
    }
    const Test = struct {
        fn at(cc: *Ctx, s: *Skeleton, b: []const u32, xs: []const [2]f64, ls: []const [2]u32, l0: []const f64, c0: []const f64, ddx: f64, ddy: f64, t: f64) Allocator.Error!u32 {
            for (b, xs) |k, p| {
                s.nodes.items[k].x = p[0] + ddx * t;
                s.nodes.items[k].y = p[1] + ddy * t;
            }
            var bad: u32 = 0;
            for (ls, l0) |l, v| if (overLean(cc, s, l[0], l[1]) > v + 1) {
                bad |= Clamp.lean;
            };
            for (b, c0) |k, v| {
                const nd = s.nodes.items[k];
                if (try cc.clearance(nd.x, nd.y, nd.layer, nd.tip) < v - 1) bad |= Clamp.part;
            }
            return bad;
        }
    };
    const full = try Test.at(c, sk, br, x0, links.items, lean0, clear0, dx, dy, 1);
    if (full == 0) return 0;
    // The largest part of the move that keeps the rules.
    var lo: f64 = 0;
    var hi: f64 = 1;
    for (0..12) |_| {
        const mid = (lo + hi) / 2;
        if (try Test.at(c, sk, br, x0, links.items, lean0, clear0, dx, dy, mid) == 0) lo = mid else hi = mid;
    }
    _ = try Test.at(c, sk, br, x0, links.items, lean0, clear0, dx, dy, lo);
    return full;
}

/// Deletes the branch of node i, and the branches over it. Returns the
/// count of nodes that went.
pub fn deleteBranch(a: Allocator, sk: *Skeleton, i: u32) Error!usize {
    if (i >= sk.nodes.items.len) return error.NoNode;
    return sk.removeBranch(a, i);
}

/// The result of `addBranch`.
pub const Added = struct {
    /// The tip node (the top of the new branch).
    tip: u32,
    clamp: u32,
};

/// Adds a branch from a foot on the bed (fx, fy) to the tip under the
/// point (tx, ty, tz) of the part (µm, relative to the origin; tz is the
/// height of the point on the part, µm). Returns the new tip node.
pub fn addBranch(gpa: Allocator, c: *Ctx, sk: *Skeleton, fx: f64, fy: f64, tx: f64, ty: f64, tz: f64) Error!Added {
    for ([_]f64{ fx, fy, tx, ty, tz }) |v| if (!std.math.isFinite(v)) return error.NoRoom;
    const p = c.params;
    const n: u32 = @intCast(c.layers());
    // The layer of the point: the first layer whose middle is at tz or
    // over it. The tip is `tips_below` layers under it.
    var over: u32 = 0;
    while (over < n and c.z[over] - c.h[over] / 2 < tz) over += 1;
    if (over >= n) over = n - 1;
    if (over < c.tips_below + 2) return error.NoRoom;
    const top = over - c.tips_below;
    var bits: u32 = 0;
    // The tip: out of the part by its radius.
    var tip = [2]f64{ tx, ty };
    if (try c.clearance(tip[0], tip[1], top, true) < p.tip - 1) {
        if (!try c.pushOut(&tip, top, true, p.tip)) return error.NoRoom;
        bits |= Clamp.part;
    }
    // The head stays straight; under it, the branch leans to the foot.
    const head: u32 = @min(p.head_layers, top);
    const lean_top = top - head;
    var foot = [2]f64{ fx, fy };
    const most = c.reach(0, lean_top);
    const d = dist(fx, fy, tip[0], tip[1]);
    if (d > most) {
        const k = if (d > 0) most / d else 0;
        foot = .{ tip[0] + (fx - tip[0]) * k, tip[1] + (fy - tip[1]) * k };
        bits |= Clamp.reach;
    }
    // The centers of each layer of the three shapes, from the top down,
    // and the count of layers in the part for each.
    const pts = try c.a.alloc([2]f64, top + 1);
    var best: ?[][2]f64 = null;
    var best_bad: usize = std.math.maxInt(usize);
    for (0..3) |shape| {
        try path(c, pts, shape, tip, foot, lean_top);
        var bad: usize = 0;
        for (pts, 0..) |q, k| {
            const j: u32 = top - @as(u32, @intCast(k));
            if (try c.clearance(q[0], q[1], j, k < head + 1) < p.tip - 1) bad += 1;
        }
        if (bad < best_bad) {
            best_bad = bad;
            best = try c.a.dupe([2]f64, pts);
        }
        if (bad == 0) break;
    }
    if (best_bad > 0) bits |= Clamp.part;
    const centers = best.?;
    // The radius of each layer, as the planner sizes a branch: the rules
    // under the tip, then a wider foot on the bed, and never thinner on
    // the way down.
    const disks = try c.a.alloc(skel.Disk, top + 1);
    var r_prev: f64 = 0;
    const top_z = c.z[top];
    for (centers, disks, 0..) |q, *dk, k| {
        const j: u32 = top - @as(u32, @intCast(k));
        var r = c.ruleRadius(top, j);
        const z = c.z[j];
        var foot_r = @max(p.foot, r + 1000);
        if (p.peel > 0) foot_r = @max(foot_r, 1000 * std.math.cbrt(p.peel * top_z / 1000));
        foot_r = @min(foot_r, @max(1000, top_z / 5));
        r = @max(r, foot_r - z);
        r = @max(r, r_prev);
        r_prev = r;
        dk.* = .{ .x = q[0], .y = q[1], .r = r };
    }
    const keep = try c.a.alloc(bool, disks.len);
    @memset(keep, false);
    // The last node of the head stays, so the head stays straight.
    if (head < keep.len) keep[head] = true;
    const first: u32 = @intCast(sk.nodes.items.len);
    _ = try sk.addChain(gpa, top, disks, keep, true, 30);
    return .{ .tip = first, .clamp = bits };
}

/// The centers of a branch on each layer from `pts.len - 1` down to 0:
/// the head over `lean_top` at the tip, then shape 0 one straight lean to
/// the foot, shape 1 a lean at the branch angle and then straight down,
/// shape 2 straight down and then a lean at the branch angle.
fn path(c: *const Ctx, pts: [][2]f64, shape: usize, tip: [2]f64, foot: [2]f64, lean_top: u32) Allocator.Error!void {
    const top: u32 = @intCast(pts.len - 1);
    const d = dist(tip[0], tip[1], foot[0], foot[1]);
    for (pts, 0..) |*q, k| {
        const j: u32 = top - @as(u32, @intCast(k));
        if (j >= lean_top or d < 1) {
            q.* = if (j >= lean_top) tip else foot;
            continue;
        }
        // The part of the run done at layer j.
        const f: f64 = switch (shape) {
            0 => (c.z[lean_top] - c.z[j]) / @max(1, c.z[lean_top] - c.z[0]),
            1 => @min(1, c.reach(j, lean_top) / d),
            else => 1 - @min(1, c.reach(0, j) / d),
        };
        q.* = .{ tip[0] + (foot[0] - tip[0]) * f, tip[1] + (foot[1] - tip[1]) * f };
    }
}

const testing = std.testing;

/// A test part: a box of 20 x 20 mm, 10 mm high, from (0, 0); a shelf of
/// 20 x 10 mm over y 20..30 from 6 mm to 8 mm. Layers of 0.2 mm.
const TestPart = struct {
    arena: std.heap.ArenaAllocator,
    ctx: Ctx,

    fn init(t: *TestPart) !void {
        t.* = .{ .arena = .init(testing.allocator), .ctx = undefined };
        const a = t.arena.allocator();
        const n = 50;
        const z = try a.alloc(f64, n);
        const h = try a.alloc(f64, n);
        const outl = try a.alloc(Paths, n);
        for (0..n) |j| {
            z[j] = @floatFromInt(200 * (j + 1));
            h[j] = 200;
            outl[j] = .empty;
            try outl[j].append(a, &.{ .init(0, 0), .init(20_000, 0), .init(20_000, 20_000), .init(0, 20_000) });
            if (z[j] > 6000 and z[j] <= 8000) try outl[j].append(a, &.{ .init(0, 20_000), .init(20_000, 20_000), .init(20_000, 30_000), .init(0, 30_000) });
        }
        t.ctx = .{
            .a = a,
            .params = .{ .tip = 400, .max_r = 5000, .growth = 0.1, .tan_angle = @tan(std.math.degreesToRadians(40.0)), .spacing = 3000, .z_gap = 1, .bed_only = false, .min_r = 1000, .bend = 0.01, .buckle = 0.01, .foot = 2500, .head_layers = 3 },
            .z = z,
            .h = h,
            .outlines = outl,
            .xy = 700,
            .xy_under = 200,
            .tips_below = 4,
        };
    }

    fn deinit(t: *TestPart) void {
        t.arena.deinit();
    }
};

test "add a branch: from the bed to the shelf, out of the part, in reach" {
    var t: TestPart = undefined;
    try t.init();
    defer t.deinit();
    const c = &t.ctx;
    var sk: Skeleton = .{};
    defer sk.deinit(testing.allocator);
    const got = try addBranch(testing.allocator, c, &sk, 10_000, 28_000, 10_000, 25_000, 6000);
    try testing.expectEqual(@as(u32, 0), got.clamp);
    const tipn = sk.nodes.items[got.tip];
    try testing.expect(tipn.tip);
    // The tip is 4 layers under the layer of the shelf bottom (layer 30).
    try testing.expectEqual(@as(u32, 26), tipn.layer);
    try testing.expectApproxEqAbs(@as(f64, 25_000), tipn.y, 1);
    // The foot is on the bed, at the place of the tap, and wider.
    const foot = sk.nodes.items[sk.root(got.tip)];
    try testing.expectEqual(@as(u32, 0), foot.layer);
    try testing.expectApproxEqAbs(@as(f64, 28_000), foot.y, 1);
    try testing.expect(foot.r > tipn.r);
    // Each segment keeps the angle, and a branch never gets thinner on
    // the way down.
    for (sk.nodes.items, 0..) |nd, k| {
        if (nd.down == none) continue;
        try testing.expect(overLean(c, &sk, @intCast(k), nd.down) < 1);
        try testing.expect(sk.nodes.items[nd.down].r >= nd.r);
    }
    // A foot too far: it moves nearer.
    const far = try addBranch(testing.allocator, c, &sk, 10_000, 80_000, 10_000, 25_000, 6000);
    try testing.expect(far.clamp & Clamp.reach != 0);
    // A point too low for a tip.
    try testing.expectError(error.NoRoom, addBranch(testing.allocator, c, &sk, 0, 0, 10_000, 25_000, 400));
}

test "move a node: the lean and the part clamp it" {
    var t: TestPart = undefined;
    try t.init();
    defer t.deinit();
    const c = &t.ctx;
    var sk: Skeleton = .{};
    defer sk.deinit(testing.allocator);
    // A node on layer 20 (4.2 mm) at y = 22 mm, over a foot at y = 22 mm.
    try sk.nodes.appendSlice(testing.allocator, &.{
        .{ .x = 10_000, .y = 22_000, .layer = 20, .r = 1000, .down = 1 },
        .{ .x = 10_000, .y = 22_000, .layer = 0, .r = 2500 },
    });
    // A small move keeps.
    try testing.expectEqual(@as(u32, 0), try moveNode(c, &sk, 0, 10_000, 23_000));
    try testing.expectEqual(@as(f64, 23_000), sk.nodes.items[0].y);
    // Far out: the segment leans at most the angle.
    try testing.expect(try moveNode(c, &sk, 0, 10_000, 60_000) & Clamp.lean != 0);
    try testing.expect(overLean(c, &sk, 0, 1) < 1);
    // Into the box: the node stays out of the part and its XY gap.
    try testing.expect(try moveNode(c, &sk, 0, 10_000, 21_000) & Clamp.part != 0);
    try testing.expect(try c.clearance(sk.nodes.items[0].x, sk.nodes.items[0].y, 20, false) >= c.params.tip - 2);
    // The radius: at least the rules, at most the largest.
    try testing.expectEqual(Clamp.radius_min, try setRadius(c, &sk, 0, 10));
    try testing.expectEqual(try c.minRadius(&sk, 0), sk.nodes.items[0].r);
    try testing.expectEqual(Clamp.radius_max, try setRadius(c, &sk, 0, 1e9));
    try testing.expectEqual(c.params.max_r, sk.nodes.items[0].r);
    try testing.expectEqual(@as(u32, 0), try setRadius(c, &sk, 0, 2000));
}

test "move a branch: as far as the rules allow" {
    var t: TestPart = undefined;
    try t.init();
    defer t.deinit();
    const c = &t.ctx;
    var sk: Skeleton = .{};
    defer sk.deinit(testing.allocator);
    // A tip branch (nodes 0, 1) and a tip (4) on a trunk (2, 3).
    try sk.nodes.appendSlice(testing.allocator, &.{
        .{ .x = 10_000, .y = 25_000, .layer = 25, .r = 400, .down = 1, .tip = true },
        .{ .x = 10_000, .y = 25_000, .layer = 21, .r = 800, .down = 2 },
        .{ .x = 10_000, .y = 25_000, .layer = 20, .r = 1000, .down = 3 },
        .{ .x = 10_000, .y = 25_000, .layer = 0, .r = 2500 },
        .{ .x = 9_900, .y = 25_000, .layer = 24, .r = 400, .down = 2, .tip = true },
    });
    // The tip branch: one layer over the trunk, so it can move by a run
    // of one layer only.
    const bits = try moveBranch(c, &sk, 0, 3000, 0);
    try testing.expect(bits & Clamp.lean != 0);
    try testing.expect(overLean(c, &sk, 1, 2) < 2);
    try testing.expect(sk.nodes.items[0].x > 10_000 and sk.nodes.items[0].x == sk.nodes.items[1].x);
    // The trunk moves toward the tip branch.
    try testing.expectEqual(@as(u32, 0), try moveBranch(c, &sk, 3, 100, 0));
    try testing.expectEqual(@as(f64, 10_100), sk.nodes.items[3].x);
    // The trunk goes with the branches over it.
    try testing.expectEqual(@as(usize, 5), try deleteBranch(testing.allocator, &sk, 3));
}
