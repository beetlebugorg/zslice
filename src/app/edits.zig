//! The edits of the user on the lines of a slice (the segment editor): a
//! line that does not print, or a line with more or less plastic. They
//! stay apart from the slice, and apply to each new slice:
//!
//! - Each line of a layer plan has a key (`pathKey`): the z of its layer,
//!   its feature, and its points, rounded to 10 µm. A line that a new
//!   slice makes again in the same place has the same key.
//! - Before the writer prints a layer, `apply` looks up the key of each
//!   line. A delete takes the line out; a flow edit changes its width
//!   (and so its plastic).
//! - The match is strict: a line that moves or changes even a little has
//!   another key. Its edit then does not apply, and says so (`applied`),
//!   and it applies again when the same line comes back (for example after
//!   an undo of a setting).
//!
//! The preview, the time, and the G-code all come from the edited plans,
//! so they agree.
//!
//! A filament edit gives one line, or one segment of a line, its own
//! filament. Its key does not hold it, because a move changes each point.
//! It has an `Anchor`: the stable id of the part, a stamp of the shape, and
//! points in the frame of the mesh of the part.
//!
//! - A move or a turn about z keeps the anchor. `Place` maps it to the bed.
//! - A mirror moves the anchor with the part (`mirrorAnchors`).
//! - Another shape (a scale, a tilt) has another stamp, so the edit waits.
//! - A match needs one line of the same feature, on the same layer, within
//!   `match_um` of each anchor point, and with the same length. Zero or two
//!   matches: the edit waits, and no line changes.
//! - A segment edit cuts its line into pieces at the segment ends. A closed
//!   loop opens there. Each piece keeps the width, the height, the region,
//!   and the flow of its line, so the plastic stays the same.
//! - `LayerPlan.groupByFilament` runs after the edits. So the colored lines
//!   of a layer print together, with the fewest filament changes.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const layer_mod = @import("../layer.zig");
const geom = @import("../geom.zig");
const LayerPlan = layer_mod.LayerPlan;

pub const Kind = enum(u8) {
    /// The line does not print.
    delete = 0,
    /// The line prints with `value` times its plastic (its width).
    flow = 1,
    /// A drop of plastic at (x, y) on the layer at z: a short closed
    /// loop of diameter `value` mm, to fill a small gap.
    dot = 2,
    /// The line, or one segment of it (see `Anchor`), prints with filament
    /// `value` (from 1).
    filament = 3,
};

/// The most points of an anchor. A long line keeps samples along it.
pub const max_anchor = 48;
/// The most distance from an anchor point to its line (µm). The view keeps
/// its points in f32, which is about 15 µm at the far side of a large bed.
pub const match_um: f64 = 50;

/// Where a filament edit lives, in the frame of the mesh of its part (µm).
pub const Anchor = struct {
    part: u64,
    /// The shape of the part (see `shapeStamp`).
    stamp: u64,
    feature: u8,
    /// True for a whole line. False for the segment from pts[0] to pts[1].
    whole: bool,
    n: u8,
    /// The length of the line or the segment (µm).
    length: f64,
    pts: [max_anchor][3]i32 = undefined,

    fn hash(a: *const Anchor) u64 {
        var h = std.hash.Wyhash.init(3);
        h.update(std.mem.asBytes(&a.part));
        h.update(std.mem.asBytes(&a.stamp));
        h.update(&.{ a.feature, @intFromBool(a.whole), a.n });
        h.update(std.mem.sliceAsBytes(a.pts[0..a.n]));
        return h.final();
    }
};

/// A part at a slice: its index on the plate, its stable id, the stamp of
/// its shape, and its transform (plate.Part.transform: a turn about z and
/// a shift).
pub const Place = struct {
    index: u32,
    id: u64,
    stamp: u64,
    m: [12]f64,

    /// A point of the mesh (µm) on the bed (µm).
    pub fn toBed(pl: *const Place, q: [3]i32) [3]f64 {
        const x: f64 = @as(f64, @floatFromInt(q[0])) / 1000;
        const y: f64 = @as(f64, @floatFromInt(q[1])) / 1000;
        const z: f64 = @as(f64, @floatFromInt(q[2])) / 1000;
        const m = pl.m;
        return .{
            (m[0] * x + m[3] * y + m[6] * z + m[9]) * 1000,
            (m[1] * x + m[4] * y + m[7] * z + m[10]) * 1000,
            (m[2] * x + m[5] * y + m[8] * z + m[11]) * 1000,
        };
    }

    /// A point on the bed (mm) in the frame of the mesh (µm).
    pub fn toMesh(pl: *const Place, q: [3]f64) [3]i32 {
        const m = pl.m;
        const dx = q[0] - m[9];
        const dy = q[1] - m[10];
        const x = m[0] * dx + m[1] * dy;
        const y = m[3] * dx + m[4] * dy;
        const z = q[2] - m[11];
        return .{ @intFromFloat(@round(x * 1000)), @intFromFloat(@round(y * 1000)), @intFromFloat(@round(z * 1000)) };
    }
};

/// The stamp of a shape: the pose, the scale, the counts, and the box of
/// its mesh. A move and a turn about z keep it.
pub fn shapeStamp(pose: [3][3]f64, scale: [3]f64, verts: usize, faces: usize, lo: [3]f64, hi: [3]f64) u64 {
    var h = std.hash.Wyhash.init(5);
    h.update(std.mem.asBytes(&pose));
    h.update(std.mem.asBytes(&scale));
    h.update(std.mem.asBytes(&[2]u64{ verts, faces }));
    for ([_][3]f64{ lo, hi }) |b| for (b) |x| {
        const q: i64 = @intFromFloat(@round(x * 1000));
        h.update(std.mem.asBytes(&q));
    };
    return h.final();
}

/// A place on a line: segment `seg`, a fraction `t` along it.
const Param = struct { seg: usize, t: f64 };
const Near = struct { at: Param, d2: f64 };

fn segCount(pts: []const geom.Point, closed: bool) usize {
    return pts.len - 1 + @as(usize, @intFromBool(closed and pts.len > 2));
}

fn fx(v: i64) f64 {
    return @floatFromInt(v);
}

fn nearest(pts: []const geom.Point, closed: bool, q: [2]f64) ?Near {
    if (pts.len < 2) return null;
    var best: ?Near = null;
    for (0..segCount(pts, closed)) |k| {
        const a = pts[k];
        const b = pts[(k + 1) % pts.len];
        const dx = fx(b.x - a.x);
        const dy = fx(b.y - a.y);
        const l2 = dx * dx + dy * dy;
        const t = if (l2 > 0) std.math.clamp(((q[0] - fx(a.x)) * dx + (q[1] - fx(a.y)) * dy) / l2, 0, 1) else 0;
        const ex = fx(a.x) + t * dx - q[0];
        const ey = fx(a.y) + t * dy - q[1];
        const d2 = ex * ex + ey * ey;
        if (best == null or d2 < best.?.d2) best = .{ .at = .{ .seg = k, .t = t }, .d2 = d2 };
    }
    return best;
}

fn lineLength(pts: []const geom.Point, closed: bool) f64 {
    if (pts.len < 2) return 0;
    var sum: f64 = 0;
    for (0..segCount(pts, closed)) |k| sum += geom.Point.dist(pts[k], pts[(k + 1) % pts.len]);
    return sum;
}

/// The distance along a line from its start to a place.
fn along(pts: []const geom.Point, at: Param) f64 {
    var sum: f64 = 0;
    for (0..at.seg) |k| sum += geom.Point.dist(pts[k], pts[k + 1]);
    return sum + at.t * geom.Point.dist(pts[at.seg], pts[(at.seg + 1) % pts.len]);
}

fn pointAt(pts: []const geom.Point, at: Param) geom.Point {
    const a = pts[at.seg];
    const b = pts[(at.seg + 1) % pts.len];
    return .{ .x = a.x + @as(i64, @intFromFloat(@round(fx(b.x - a.x) * at.t))), .y = a.y + @as(i64, @intFromFloat(@round(fx(b.y - a.y) * at.t))) };
}

/// The match of an anchor on path i of a plan, or null. For a segment, the
/// places of its ends, in print order.
fn matchPath(plan: *const LayerPlan, i: usize, a: *const Anchor, bed: []const [3]f64) ?[2]Param {
    const path = plan.paths.items[i];
    if (@intFromEnum(path.feature) != a.feature) return null;
    const pts = plan.points.get(i);
    if (pts.len < 2) return null;
    const tol2 = match_um * match_um;
    var ends: [2]Param = undefined;
    for (bed, 0..) |q, k| {
        const n = nearest(pts, path.closed, .{ q[0], q[1] }) orelse return null;
        if (n.d2 > tol2) return null;
        if (k < 2) ends[k] = n.at;
    }
    const total = lineLength(pts, path.closed);
    if (a.whole) return if (@abs(total - a.length) <= @max(200, a.length * 0.01)) ends else null;
    var d = along(pts, ends[1]) - along(pts, ends[0]);
    if (path.closed and pts.len > 2) {
        // The short way around the loop, from the first end to the second.
        if (d < 0) d += total;
        if (d > total / 2) {
            std.mem.swap(Param, &ends[0], &ends[1]);
            d = total - d;
        }
    } else if (d < 0) {
        std.mem.swap(Param, &ends[0], &ends[1]);
        d = -d;
    }
    if (d <= 0) return null;
    return if (@abs(d - a.length) <= @max(2 * match_um, a.length * 0.01)) ends else null;
}

pub const Edit = struct {
    key: u64,
    kind: Kind,
    value: f32 = 1,
    /// The layer of the line when the edit was made, for a list.
    layer: u32 = 0,
    /// A drop: its place (mm, on the bed) and the z of its layer (mm).
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    /// A filament edit: the place of its line.
    anchor: ?Anchor = null,
    /// The last slice found the line (set by `apply`).
    applied: std.atomic.Value(bool) = .init(false),
};

/// The key of path i of a plan.
pub fn pathKey(plan: *const LayerPlan, i: usize) u64 {
    var h = std.hash.Wyhash.init(0);
    const z: i64 = @intFromFloat(@round(plan.z * 100));
    h.update(std.mem.asBytes(&z));
    const f: u8 = @intFromEnum(plan.paths.items[i].feature);
    h.update(std.mem.asBytes(&f));
    // The rounded points go to the hash in blocks. The hash reads a
    // stream of bytes, so a block gives the key of one update for each
    // point, with fewer calls. The view makes the keys of all paths in
    // layer order, on one thread, after each slice.
    var block: [64][2]i64 = undefined;
    var n: usize = 0;
    for (plan.points.get(i)) |p| {
        block[n] = .{ @divFloor(p.x + 5, 10), @divFloor(p.y + 5, 10) };
        n += 1;
        if (n == block.len) {
            h.update(std.mem.sliceAsBytes(&block));
            n = 0;
        }
    }
    h.update(std.mem.sliceAsBytes(block[0..n]));
    return h.final();
}

pub const Edits = struct {
    list: std.ArrayList(Edit) = .empty,
    /// The parts of the slice that runs, for the filament edits. The app
    /// owns the slice.
    places: []const Place = &.{},
    /// The state of each key after the last slice (see `remember`).
    memo: std.AutoHashMapUnmanaged(u64, bool) = .empty,

    pub fn deinit(e: *Edits, gpa: Allocator) void {
        e.list.deinit(gpa);
        e.memo.deinit(gpa);
    }

    /// The key of a drop: its layer and its place, so a second drop at the
    /// same place replaces the first.
    pub fn dotKey(z: f32, x: f32, y: f32) u64 {
        var h = std.hash.Wyhash.init(1);
        const q = [3]i64{ @intFromFloat(@round(z * 100)), @intFromFloat(@round(x * 100)), @intFromFloat(@round(y * 100)) };
        h.update(std.mem.asBytes(&q));
        return h.final();
    }

    /// Adds or changes the filament edit of an anchor. Returns its index.
    pub fn putFilament(e: *Edits, gpa: Allocator, a: Anchor, filament: u32, layer: u32) Allocator.Error!usize {
        const key = a.hash();
        try e.put(gpa, .{ .key = key, .kind = .filament, .value = @floatFromInt(filament), .layer = layer, .anchor = a });
        for (e.list.items, 0..) |*x, i| if (x.key == key) return i;
        unreachable;
    }

    pub fn placeOf(e: *const Edits, id: u64) ?*const Place {
        for (e.places) |*p| if (p.id == id) return p;
        return null;
    }

    /// The anchors of part `id` after a mirror along a bed axis. `old` and
    /// `new` are the places before and after, and (cx, cy) moves to
    /// (nx, ny) on the bed.
    pub fn mirrorAnchors(e: *Edits, old: Place, new: Place, axis: u1, c: [2]f64, n: [2]f64) void {
        for (e.list.items) |*x| {
            const a = if (x.anchor) |*q| q else continue;
            if (a.part != old.id or a.stamp != old.stamp) continue;
            for (a.pts[0..a.n]) |*q| {
                const b = old.toBed(q.*);
                var mm = [3]f64{ b[0] / 1000 - c[0], b[1] / 1000 - c[1], b[2] / 1000 };
                mm[axis] = -mm[axis];
                q.* = new.toMesh(.{ mm[0] + n[0], mm[1] + n[1], mm[2] });
            }
            a.stamp = new.stamp;
            x.key = a.hash();
        }
    }

    /// The z (mm) on the bed and the filament of each filament edit whose
    /// part has its shape: `f(ctx, z, filament)`.
    pub fn eachFilament(e: *const Edits, ctx: anytype, f: fn (@TypeOf(ctx), f64, u32) void) void {
        for (e.list.items) |*x| {
            const a = if (x.anchor) |*q| q else continue;
            const pl = e.placeOf(a.part) orelse continue;
            if (pl.stamp != a.stamp) continue;
            f(ctx, pl.toBed(a.pts[0])[2] / 1000, @intFromFloat(x.value));
        }
    }

    /// Adds an edit, or changes the edit of the same line.
    pub fn put(e: *Edits, gpa: Allocator, edit: Edit) Allocator.Error!void {
        for (e.list.items) |*x| if (x.key == edit.key) {
            x.kind = edit.kind;
            x.value = edit.value;
            x.anchor = edit.anchor;
            return;
        };
        try e.list.append(gpa, edit);
    }

    pub fn remove(e: *Edits, i: usize) void {
        if (i < e.list.items.len) _ = e.list.orderedRemove(i);
    }

    /// After a slice: the state of each edit, by its key.
    pub fn remember(e: *Edits, gpa: Allocator) void {
        e.memo.clearRetainingCapacity();
        for (e.list.items) |*x| e.memo.put(gpa, x.key, x.applied.load(.acquire)) catch return;
    }

    /// Before a slice that keeps the moves of the last one: each edit
    /// gets the state of its key in that slice. An edit list from undo or
    /// a file has new edits with the old keys.
    pub fn recall(e: *Edits) void {
        for (e.list.items) |*x| if (e.memo.get(x.key)) |v| x.applied.store(v, .release);
    }

    /// Before a slice: no edit has applied yet.
    pub fn resetApplied(e: *Edits) void {
        for (e.list.items) |*x| x.applied.store(false, .release);
    }

    fn find(e: *const Edits, key: u64) ?*Edit {
        for (e.list.items) |*x| if (x.key == key) return @constCast(x);
        return null;
    }

    /// Applies the edits to a plan, in its arena. Any thread can call it
    /// for its own plan.
    pub fn apply(e: *const Edits, plan: *LayerPlan) Allocator.Error!void {
        if (e.list.items.len == 0) return;
        const a = plan.arena.allocator();
        // The drops of this layer: a small closed loop each, at the end of
        // the layer.
        for (e.list.items) |*d| {
            if (d.kind != .dot or @abs(@as(f64, d.z) - plan.z) > 0.005) continue;
            const r = geom.fromMm(@max(0.05, (d.value - @as(f32, @floatCast(plan.width))) / 2));
            const cx = geom.fromMm(d.x);
            const cy = geom.fromMm(d.y);
            var loop: [8]geom.Point = undefined;
            for (&loop, 0..) |*q, k| {
                const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 8;
                q.* = .{ .x = cx + @as(i64, @intFromFloat(@as(f64, @floatFromInt(r)) * @cos(t))), .y = cy + @as(i64, @intFromFloat(@as(f64, @floatFromInt(r)) * @sin(t))) };
            }
            try plan.paths.append(a, .{ .feature = .skin, .closed = true });
            try plan.points.append(a, &loop);
            d.applied.store(true, .release);
        }
        var deleted = false;
        for (plan.paths.items, 0..) |*p, i| {
            const edit = e.find(pathKey(plan, i)) orelse continue;
            if (edit.kind == .dot or edit.kind == .filament) continue;
            edit.applied.store(true, .release);
            switch (edit.kind) {
                .delete => deleted = true,
                .flow => {
                    const w: f32 = if (p.width > 0) p.width else @floatCast(plan.width);
                    p.width = w * std.math.clamp(edit.value, 0.1, 3);
                },
                .dot, .filament => {},
            }
        }
        if (deleted) try e.dropDeleted(plan, null);
        try e.applyFilaments(plan);
    }

    /// The plan again, without the deleted lines. With `only`, a line must
    /// have its flag in `only` to go.
    fn dropDeleted(e: *const Edits, plan: *LayerPlan, only: ?[]const bool) Allocator.Error!void {
        const a = plan.arena.allocator();
        var paths: std.ArrayList(layer_mod.Path) = .empty;
        var points: geom.Paths = .empty;
        for (plan.paths.items, 0..) |p, i| {
            if (only == null or only.?[i]) if (e.find(pathKey(plan, i))) |edit| if (edit.kind == .delete) continue;
            try paths.append(a, p);
            try points.append(a, plan.points.get(i));
        }
        plan.paths = paths;
        plan.points = points;
    }

    /// The filament edits of this plan. Whole lines first, so a segment
    /// edit on a colored line wins.
    fn applyFilaments(e: *const Edits, plan: *LayerPlan) Allocator.Error!void {
        var split = false;
        var pieces: std.ArrayList(bool) = .empty;
        const a = plan.arena.allocator();
        for ([_]bool{ true, false }) |whole| for (e.list.items) |*x| {
            const anchor = if (x.anchor) |*q| q else continue;
            if (anchor.whole != whole) continue;
            const pl = e.placeOf(anchor.part) orelse continue;
            if (pl.stamp != anchor.stamp) continue;
            var bed: [max_anchor][3]f64 = undefined;
            for (anchor.pts[0..anchor.n], 0..) |q, k| bed[k] = pl.toBed(q);
            if (@abs(bed[0][2] / 1000 - plan.z) > 0.005) continue;
            var hit: ?usize = null;
            var ends: [2]Param = undefined;
            var count: usize = 0;
            for (0..plan.paths.items.len) |i| {
                if (plan.partOf(plan.paths.items[i]) != pl.index) continue;
                const m = matchPath(plan, i, anchor, bed[0..anchor.n]) orelse continue;
                hit = i;
                ends = m;
                count += 1;
            }
            if (count != 1) continue;
            // A segment of a line with a height at each point stays whole:
            // the edit waits.
            if (!whole and plan.paths.items[hit.?].z_start != layer_mod.Path.planar) continue;
            const filament: u8 = @intCast(std.math.clamp(@as(i64, @intFromFloat(x.value)), 1, 255));
            const i = hit.?;
            if (whole) {
                plan.paths.items[i].pick = filament;
                x.applied.store(true, .release);
                continue;
            }
            if (plan.paths.items[i].pick == filament) {
                x.applied.store(true, .release);
                continue;
            }
            if (!split) {
                try pieces.appendNTimes(a, false, plan.paths.items.len);
                split = true;
            }
            // A cut that does not keep the line leaves the plan as it is,
            // and the edit waits.
            if (try cutSegment(plan, i, ends, filament, &pieces)) x.applied.store(true, .release);
        };
        if (!split) return;
        // An edit of the user on a piece: the key of the piece.
        var deleted = false;
        for (plan.paths.items, 0..) |*p, i| {
            if (!pieces.items[i]) continue;
            const edit = e.find(pathKey(plan, i)) orelse continue;
            switch (edit.kind) {
                .delete => deleted = true,
                .flow => {
                    const w: f32 = if (p.width > 0) p.width else @floatCast(plan.width);
                    p.width = w * std.math.clamp(edit.value, 0.1, 3);
                },
                else => continue,
            }
            edit.applied.store(true, .release);
        }
        if (deleted) try e.dropDeleted(plan, pieces.items);
    }
};

/// Cuts path i at the places `ends` into the line before, the segment
/// with `filament`, and the line after. A closed loop opens at the segment:
/// one piece goes around from its end to its start. Pieces of a line with
/// a width at each point get their widths. Returns false, with the plan
/// unchanged, if the pieces do not keep the length of the line.
fn cutSegment(plan: *LayerPlan, i: usize, ends: [2]Param, filament: u8, pieces: *std.ArrayList(bool)) Allocator.Error!bool {
    const a = plan.arena.allocator();
    const path = plan.paths.items[i];
    const pts = plan.points.get(i);
    const widths: []const f32 = if (path.w_start != layer_mod.Path.planar) plan.point_w.items[path.w_start..][0..pts.len] else &.{};
    const Piece = struct { pts: std.ArrayList(geom.Point) = .empty, w: std.ArrayList(f32) = .empty, pick: u8 };
    const widthAt = struct {
        fn f(ws: []const f32, at: Param) f32 {
            return ws[at.seg] + (ws[(at.seg + 1) % ws.len] - ws[at.seg]) * @as(f32, @floatCast(at.t));
        }
    }.f;
    const n = segCount(pts, path.closed);
    // The walk from one place to the next place, forward. On a loop, a
    // walk that ends behind its start in one segment goes all the way.
    const walk = struct {
        fn f(al: Allocator, p: *Piece, ps: []const geom.Point, ws: []const f32, segs: usize, from: Param, to: Param) Allocator.Error!void {
            try p.pts.append(al, pointAt(ps, from));
            if (ws.len > 0) try p.w.append(al, widthAt(ws, from));
            var left = (to.seg + segs - from.seg) % segs;
            if (left == 0 and to.t < from.t) left = segs;
            var k = from.seg;
            while (left > 0) : (left -= 1) {
                k = (k + 1) % segs;
                try p.pts.append(al, ps[k]);
                if (ws.len > 0) try p.w.append(al, ws[k]);
            }
            try p.pts.append(al, pointAt(ps, to));
            if (ws.len > 0) try p.w.append(al, widthAt(ws, to));
        }
    }.f;
    var list: [3]Piece = undefined;
    var count: usize = 0;
    const start: Param = .{ .seg = 0, .t = 0 };
    const finish: Param = .{ .seg = n - 1, .t = 1 };
    if (path.closed and pts.len > 2) {
        list[0] = .{ .pick = filament };
        try walk(a, &list[0], pts, widths, n, ends[0], ends[1]);
        list[1] = .{ .pick = path.pick };
        try walk(a, &list[1], pts, widths, n, ends[1], ends[0]);
        count = 2;
    } else {
        if (along(pts, ends[0]) > 1) {
            list[count] = .{ .pick = path.pick };
            try walk(a, &list[count], pts, widths, n, start, ends[0]);
            count += 1;
        }
        list[count] = .{ .pick = filament };
        try walk(a, &list[count], pts, widths, n, ends[0], ends[1]);
        count += 1;
        if (lineLength(pts, false) - along(pts, ends[1]) > 1) {
            list[count] = .{ .pick = path.pick };
            try walk(a, &list[count], pts, widths, n, ends[1], finish);
            count += 1;
        }
    }
    // The check before any change: the colored piece exists, and the
    // pieces together are as long as the line.
    var sum: f64 = 0;
    var colored = false;
    for (list[0..count]) |*piece| {
        if (try dedupe(a, piece) < 2) continue;
        sum += lineLength(piece.pts.items, false);
        colored = colored or piece.pick == filament;
    }
    if (!colored or @abs(sum - lineLength(pts, path.closed)) > 5 * @as(f64, @floatFromInt(pts.len + 2))) return false;
    var paths: std.ArrayList(layer_mod.Path) = .empty;
    var points: geom.Paths = .empty;
    var flags: std.ArrayList(bool) = .empty;
    for (plan.paths.items, 0..) |p, k| {
        if (k != i) {
            try paths.append(a, p);
            try points.append(a, plan.points.get(k));
            try flags.append(a, pieces.items[k]);
            continue;
        }
        for (list[0..count]) |*piece| {
            if (piece.pts.items.len < 2) continue;
            var q = path;
            q.closed = false;
            q.pick = piece.pick;
            if (widths.len > 0) {
                q.w_start = @intCast(plan.point_w.items.len);
                try plan.point_w.appendSlice(a, piece.w.items);
            }
            try paths.append(a, q);
            try points.append(a, piece.pts.items);
            try flags.append(a, true);
        }
    }
    plan.paths = paths;
    plan.points = points;
    pieces.* = flags;
    return true;
}

/// Takes out the points of a piece that repeat the point before. Returns
/// the count of points left.
fn dedupe(_: Allocator, piece: anytype) Allocator.Error!usize {
    var w: usize = 0;
    for (piece.pts.items, 0..) |q, k| {
        if (w > 0 and piece.pts.items[w - 1].x == q.x and piece.pts.items[w - 1].y == q.y) continue;
        piece.pts.items[w] = q;
        if (piece.w.items.len > 0) piece.w.items[w] = piece.w.items[k];
        w += 1;
    }
    piece.pts.items.len = w;
    if (piece.w.items.len > 0) piece.w.items.len = w;
    return w;
}

const testing = std.testing;

test "edits: delete a line, and change the flow of another" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    const a = plan.arena.allocator();
    const lines = [_][2]geom.Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 10000, .y = 0 } },
        .{ .{ .x = 0, .y = 1000 }, .{ .x = 10000, .y = 1000 } },
        .{ .{ .x = 0, .y = 2000 }, .{ .x = 10000, .y = 2000 } },
    };
    for (lines) |l| {
        try plan.paths.append(a, .{ .feature = .infill, .closed = false });
        try plan.points.append(a, &l);
    }
    var e: Edits = .{};
    defer e.deinit(gpa);
    try e.put(gpa, .{ .key = pathKey(&plan, 1), .kind = .delete });
    try e.put(gpa, .{ .key = pathKey(&plan, 2), .kind = .flow, .value = 1.5 });
    // A line of another layer: it does not apply.
    try e.put(gpa, .{ .key = 12345, .kind = .delete });
    try e.apply(&plan);
    try testing.expectEqual(@as(usize, 2), plan.paths.items.len);
    try testing.expectEqual(@as(i64, 0), plan.points.get(0)[0].y);
    try testing.expectEqual(@as(i64, 2000), plan.points.get(1)[0].y);
    try testing.expectApproxEqAbs(@as(f32, 0.6), plan.paths.items[1].width, 1e-6);
    try testing.expect(e.list.items[0].applied.load(.acquire));
    try testing.expect(!e.list.items[2].applied.load(.acquire));
}

test "edits: the key of a path is the hash of its rounded points, one by one" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    const a = plan.arena.allocator();
    var rng: std.Random.DefaultPrng = .init(7);
    const r = rng.random();
    // Paths of 1 to 300 points: shorter and longer than a block.
    for ([_]usize{ 1, 2, 63, 64, 65, 128, 300 }) |len| {
        try plan.paths.append(a, .{ .feature = .outer_wall, .closed = true });
        const pts = try a.alloc(geom.Point, len);
        for (pts) |*q| q.* = .{ .x = r.intRangeAtMost(i64, -300_000, 300_000), .y = r.intRangeAtMost(i64, -300_000, 300_000) };
        try plan.points.append(a, pts);
    }
    for (0..plan.paths.items.len) |i| {
        var h = std.hash.Wyhash.init(0);
        const z: i64 = 80;
        h.update(std.mem.asBytes(&z));
        const f: u8 = @intFromEnum(plan.paths.items[i].feature);
        h.update(std.mem.asBytes(&f));
        for (plan.points.get(i)) |p| {
            const q = [2]i64{ @divFloor(p.x + 5, 10), @divFloor(p.y + 5, 10) };
            h.update(std.mem.asBytes(&q));
        }
        try testing.expectEqual(h.final(), pathKey(&plan, i));
    }
}

test "edits: a line segment of a loop, given against its direction, cuts once and keeps the length" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4, .part = 0 };
    defer plan.deinit();
    const a = plan.arena.allocator();
    const loop = [_]geom.Point{ .{ .x = 0, .y = 0 }, .{ .x = 20000, .y = 0 }, .{ .x = 20000, .y = 10000 }, .{ .x = 0, .y = 10000 } };
    try plan.paths.append(a, .{ .feature = .outer_wall, .closed = true });
    try plan.points.append(a, &loop);
    const total = lineLength(&loop, true);
    const places = [_]Place{.{ .index = 0, .id = 7, .stamp = 9, .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 } }};
    var e: Edits = .{ .places = &places };
    defer e.deinit(gpa);
    // From the end of the first side to its start: against the loop.
    var an: Anchor = .{ .part = 7, .stamp = 9, .feature = @intFromEnum(@as(@TypeOf(plan.paths.items[0].feature), .outer_wall)), .whole = false, .n = 2, .length = 20000 };
    an.pts[0] = .{ 20000, 0, 800 };
    an.pts[1] = .{ 0, 0, 800 };
    _ = try e.putFilament(gpa, an, 2, 3);
    try e.apply(&plan);
    try testing.expect(e.list.items[0].applied.load(.acquire));
    try testing.expectEqual(@as(usize, 2), plan.paths.items.len);
    var sum: f64 = 0;
    var colored: f64 = 0;
    for (plan.paths.items, 0..) |p, i| {
        const l = lineLength(plan.points.get(i), false);
        sum += l;
        if (p.pick == 2) colored += l;
    }
    try testing.expectApproxEqAbs(total, sum, 1);
    try testing.expectApproxEqAbs(@as(f64, 20000), colored, 1);
}

test "edits: a line cut with no length leaves the plan as it is" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    const a = plan.arena.allocator();
    const loop = [_]geom.Point{ .{ .x = 0, .y = 0 }, .{ .x = 20000, .y = 0 }, .{ .x = 20000, .y = 10000 }, .{ .x = 0, .y = 10000 } };
    try plan.paths.append(a, .{ .feature = .outer_wall, .closed = true });
    try plan.points.append(a, &loop);
    var pieces: std.ArrayList(bool) = .empty;
    try pieces.append(a, false);
    // Both ends at one place: the two ends of a bad swap.
    const at: Param = .{ .seg = 1, .t = 1 };
    try testing.expect(!try cutSegment(&plan, 0, .{ at, at }, 2, &pieces));
    try testing.expectEqual(@as(usize, 1), plan.paths.items.len);
    try testing.expect(plan.paths.items[0].closed);
    try testing.expectEqual(@as(usize, 4), plan.points.get(0).len);
}

test "edits: a drop of plastic on its layer" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    var e: Edits = .{};
    defer e.deinit(gpa);
    try e.put(gpa, .{ .key = Edits.dotKey(0.8, 10, 12), .kind = .dot, .value = 1.2, .x = 10, .y = 12, .z = 0.8 });
    try e.put(gpa, .{ .key = Edits.dotKey(1.0, 10, 12), .kind = .dot, .value = 1.2, .x = 10, .y = 12, .z = 1.0 });
    try e.apply(&plan);
    try testing.expectEqual(@as(usize, 1), plan.paths.items.len);
    try testing.expect(plan.paths.items[0].closed);
    try testing.expect(e.list.items[0].applied.load(.acquire));
    try testing.expect(!e.list.items[1].applied.load(.acquire));
    // Around (10, 12): the loop has a radius of (1.2 - 0.4) / 2 mm.
    const p0 = plan.points.get(0)[0];
    try testing.expectApproxEqAbs(@as(f64, 10.4), geom.toMm(p0.x), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 12), geom.toMm(p0.y), 0.01);
}

