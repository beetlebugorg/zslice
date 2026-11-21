//! Smart guides for the labels: the features of the face under a label,
//! and the snap of a label box to them, to other labels, and to the
//! centers of the face and of the part.
//!
//! The face: each triangle of the mesh in the plane of the label (its
//! normal within 2.5° of the normal of the label, and its points within
//! 0.1 mm of the plane) is part of the face. An edge that only one
//! triangle of the face has is an edge of the outline of the face. The
//! edges join into loops in the plane of the label (s along right, t
//! along up). A loop that turns counterclockwise (seen from the front)
//! is an outline, and the largest one is the outline of the face. A loop
//! that turns clockwise is a hole. A hole is round if each point is
//! within 6% of the mean distance from its center (and it has 6 points
//! or more). Else it is a rectangle if it fills 97% of its smallest
//! bounding rectangle (the edge directions of the loop give the
//! candidates). Else it is a hole of another shape, with its box.
//!
//! The snap (as the smart guides of design tools): a box of a label in
//! its plane moves, or one corner of it moves (a resize). On each axis,
//! the edges and the center of the box go to the nearest target within
//! the tolerance:
//!
//! - the edges and the centers of the other labels in the same plane;
//! - the center of a hole, and the edges of a rectangle in line with
//!   the axes of the label;
//! - the center of the face and the center of the part;
//! - an equal gap: the gap between two other labels, next to them or
//!   between them;
//! - for a resize: the width or the height of another label.
//!
//! Each snap gives a guide: a line in the plane from the target to the
//! box. A shell draws the guides as thin lines on the surface.
//!
//! References (see docs/references/papers-and-algorithms.md): the smart
//! guides of drawing tools; the idea, no code.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const label_mod = @import("label.zig");
const Mesh = mesh_mod.Mesh;

const dot = label_mod.dot;
const cross = label_mod.cross;

/// The frame of a plane: origin, normal, right (unit, at right angles).
pub const Frame = struct {
    origin: [3]f64,
    normal: [3]f64,
    right: [3]f64,

    pub fn up(f: Frame) [3]f64 {
        return cross(f.normal, f.right);
    }

    /// The point (s, t) of the plane in 3D.
    pub fn at(f: Frame, s: f64, t: f64) [3]f64 {
        const u = f.up();
        return .{ f.origin[0] + s * f.right[0] + t * u[0], f.origin[1] + s * f.right[1] + t * u[1], f.origin[2] + s * f.right[2] + t * u[2] };
    }

    /// The point p in the plane: (s, t).
    pub fn of(f: Frame, p: [3]f64) [2]f64 {
        const v: [3]f64 = .{ p[0] - f.origin[0], p[1] - f.origin[1], p[2] - f.origin[2] };
        return .{ dot(v, f.right), dot(v, f.up()) };
    }

    /// The same plane: normals within 2.5° and the origin of g within
    /// 0.2 mm of the plane of f.
    pub fn samePlane(f: Frame, g: Frame) bool {
        if (dot(f.normal, g.normal) < @cos(std.math.degreesToRadians(2.5))) return false;
        const v: [3]f64 = .{ g.origin[0] - f.origin[0], g.origin[1] - f.origin[1], g.origin[2] - f.origin[2] };
        return @abs(dot(v, f.normal)) < 0.2;
    }
};

/// A box in a plane: s0, t0, s1, t1 (mm).
pub const Box = [4]f64;

pub const HoleKind = enum { round, rect, other };

pub const Hole = struct {
    kind: HoleKind,
    center: [2]f64,
    /// The box in the plane.
    box: Box,
    /// A round hole: its radius.
    radius: f64 = 0,
    /// A rectangle: its sides, and the angle of the first side from +s
    /// (degrees, 0 to 90).
    size: [2]f64 = .{ 0, 0 },
    angle: f64 = 0,
};

/// The features of a face, in the plane of a frame.
pub const Face = struct {
    frame: Frame,
    /// The box and the center (of the area) of the outline of the face.
    box: Box,
    center: [2]f64,
    /// The center of the box of the part, in the plane.
    part_center: [2]f64,
    holes: []Hole,

    pub fn deinit(f: *Face, gpa: Allocator) void {
        gpa.free(f.holes);
        f.* = undefined;
    }
};

const P2 = [2]f64;

fn area(loop: []const P2) f64 {
    var a: f64 = 0;
    for (loop, 0..) |p, i| {
        const q = loop[(i + 1) % loop.len];
        a += p[0] * q[1] - q[0] * p[1];
    }
    return a / 2;
}

fn centroid(loop: []const P2) P2 {
    var cx: f64 = 0;
    var cy: f64 = 0;
    var a: f64 = 0;
    for (loop, 0..) |p, i| {
        const q = loop[(i + 1) % loop.len];
        const c = p[0] * q[1] - q[0] * p[1];
        a += c;
        cx += (p[0] + q[0]) * c;
        cy += (p[1] + q[1]) * c;
    }
    if (@abs(a) < 1e-12) return loop[0];
    return .{ cx / (3 * a), cy / (3 * a) };
}

fn boxOf(loop: []const P2) Box {
    var b: Box = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (loop) |p| b = .{ @min(b[0], p[0]), @min(b[1], p[1]), @max(b[2], p[0]), @max(b[3], p[1]) };
    return b;
}

/// The kind of a hole (a clockwise loop; see the header).
pub fn classify(loop: []const P2) Hole {
    const c = centroid(loop);
    const b = boxOf(loop);
    var h: Hole = .{ .kind = .other, .center = c, .box = b };
    if (loop.len >= 6) {
        var mean: f64 = 0;
        for (loop) |p| mean += std.math.hypot(p[0] - c[0], p[1] - c[1]);
        mean /= @floatFromInt(loop.len);
        var worst: f64 = 0;
        for (loop) |p| worst = @max(worst, @abs(std.math.hypot(p[0] - c[0], p[1] - c[1]) - mean));
        if (mean > 0 and worst / mean < 0.06) {
            h.kind = .round;
            h.radius = mean;
            return h;
        }
    }
    // The smallest bounding rectangle: one side along an edge.
    const a = @abs(area(loop));
    var least = std.math.inf(f64);
    var best_ang: f64 = 0;
    var best_size: [2]f64 = .{ 0, 0 };
    var best_center: P2 = c;
    for (loop, 0..) |p, i| {
        const q = loop[(i + 1) % loop.len];
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        const l = std.math.hypot(dx, dy);
        if (!(l > 1e-9)) continue;
        const ux = dx / l;
        const uy = dy / l;
        var lo: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
        var hi: [2]f64 = .{ -std.math.inf(f64), -std.math.inf(f64) };
        for (loop) |r| {
            const u = r[0] * ux + r[1] * uy;
            const v = -r[0] * uy + r[1] * ux;
            lo = .{ @min(lo[0], u), @min(lo[1], v) };
            hi = .{ @max(hi[0], u), @max(hi[1], v) };
        }
        const ra = (hi[0] - lo[0]) * (hi[1] - lo[1]);
        if (ra < least) {
            least = ra;
            const raw = std.math.radiansToDegrees(std.math.atan2(uy, ux));
            var size: [2]f64 = .{ hi[0] - lo[0], hi[1] - lo[1] };
            // The angle in 0 to 90: each turn of 90° swaps the sides.
            const k = @floor(raw / 90);
            const ang = raw - 90 * k;
            if (@mod(k, 2) != 0) std.mem.swap(f64, &size[0], &size[1]);
            best_ang = ang;
            best_size = size;
            const mu = (lo[0] + hi[0]) / 2;
            const mv = (lo[1] + hi[1]) / 2;
            best_center = .{ mu * ux - mv * uy, mu * uy + mv * ux };
        }
    }
    if (least < std.math.inf(f64) and a / least > 0.97) {
        h.kind = .rect;
        h.angle = best_ang;
        h.size = best_size;
        h.center = best_center;
    }
    return h;
}

/// The features of the face of `mesh` in the plane of `frame` (see the
/// header). null if no triangle is in the plane.
pub fn face(gpa: Allocator, mesh: *const Mesh, frame: Frame) Allocator.Error!?Face {
    const verts = mesh.vertices.items;
    const cos_max = @cos(std.math.degreesToRadians(2.5));
    // The directed edges of the face, by the keys of their points.
    const Edge = struct { a: u64, b: u64, pa: P2, pb: P2 };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var count: std.AutoHashMapUnmanaged([2]u64, u32) = .empty;
    defer count.deinit(gpa);
    const qkey = struct {
        fn f(v: mesh_mod.Vec3) u64 {
            // The point to 1 µm: equal points of two triangles meet.
            const x: u64 = @bitCast(@as(i64, @intFromFloat(@round(@as(f64, v.x) * 1000))));
            const y: u64 = @bitCast(@as(i64, @intFromFloat(@round(@as(f64, v.y) * 1000))));
            const z: u64 = @bitCast(@as(i64, @intFromFloat(@round(@as(f64, v.z) * 1000))));
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&x));
            h.update(std.mem.asBytes(&y));
            h.update(std.mem.asBytes(&z));
            return h.final();
        }
    }.f;
    for (mesh.faces.items) |t| {
        const p: [3][3]f64 = .{
            .{ verts[t[0]].x, verts[t[0]].y, verts[t[0]].z },
            .{ verts[t[1]].x, verts[t[1]].y, verts[t[1]].z },
            .{ verts[t[2]].x, verts[t[2]].y, verts[t[2]].z },
        };
        const n = label_mod.normalize(cross(.{ p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2] }, .{ p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2] })) orelse continue;
        if (dot(n, frame.normal) < cos_max) continue;
        var in = true;
        for (p) |q| {
            const v: [3]f64 = .{ q[0] - frame.origin[0], q[1] - frame.origin[1], q[2] - frame.origin[2] };
            if (@abs(dot(v, frame.normal)) > 0.1) in = false;
        }
        if (!in) continue;
        for (0..3) |e| {
            const a = qkey(verts[t[e]]);
            const b = qkey(verts[t[(e + 1) % 3]]);
            if (a == b) continue;
            try edges.append(gpa, .{ .a = a, .b = b, .pa = frame.of(p[e]), .pb = frame.of(p[(e + 1) % 3]) });
            const k: [2]u64 = .{ @min(a, b), @max(a, b) };
            const g = try count.getOrPut(gpa, k);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
        }
    }
    if (edges.items.len == 0) return null;
    // The edges of the outline: once in the face. Joined into loops.
    var next: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer next.deinit(gpa);
    var bound: std.ArrayList(Edge) = .empty;
    defer bound.deinit(gpa);
    for (edges.items) |e| {
        if (count.get(.{ @min(e.a, e.b), @max(e.a, e.b) }).? != 1) continue;
        try next.put(gpa, e.a, bound.items.len);
        try bound.append(gpa, e);
    }
    const used = try gpa.alloc(bool, bound.items.len);
    defer gpa.free(used);
    @memset(used, false);
    var holes: std.ArrayList(Hole) = .empty;
    errdefer holes.deinit(gpa);
    var best_area: f64 = 0;
    var out_box: Box = .{ 0, 0, 0, 0 };
    var out_center: P2 = .{ 0, 0 };
    var loop: std.ArrayList(P2) = .empty;
    defer loop.deinit(gpa);
    for (bound.items, 0..) |_, start| {
        if (used[start]) continue;
        loop.clearRetainingCapacity();
        var i = start;
        while (!used[i]) {
            used[i] = true;
            try loop.append(gpa, bound.items[i].pa);
            i = next.get(bound.items[i].b) orelse break;
        }
        if (loop.items.len < 3) continue;
        const a = area(loop.items);
        if (a > best_area) {
            best_area = a;
            out_box = boxOf(loop.items);
            out_center = centroid(loop.items);
        } else if (a < 0) {
            try holes.append(gpa, classify(loop.items));
        }
    }
    if (!(best_area > 0)) {
        holes.deinit(gpa);
        return null;
    }
    // Only the holes in the outline (a clockwise loop of another face in
    // the plane is not one).
    var k: usize = 0;
    for (holes.items) |h| {
        if (h.center[0] < out_box[0] or h.center[0] > out_box[2] or h.center[1] < out_box[1] or h.center[1] > out_box[3]) continue;
        holes.items[k] = h;
        k += 1;
    }
    holes.shrinkRetainingCapacity(k);
    const mb = mesh.bounds();
    const pc = frame.of(.{ (mb.min[0] + mb.max[0]) / 2, (mb.min[1] + mb.max[1]) / 2, (mb.min[2] + mb.max[2]) / 2 });
    return .{ .frame = frame, .box = out_box, .center = out_center, .part_center = pc, .holes = try holes.toOwnedSlice(gpa) };
}

// ---- the snap ----

pub const Op = enum { move, resize };

/// Another label: its frame and its box in its plane.
pub const Other = struct { frame: Frame, box: Box };

/// A line of a guide in the plane: s0, t0, s1, t1.
pub const Guide = [4]f64;

pub const Input = struct {
    op: Op = .move,
    /// The box of the label in its plane, after the move or the resize of
    /// the pointer.
    box: Box,
    /// The frame of the label (the plane of the box).
    frame: Frame,
    /// The snap distance (mm).
    tol: f64,
    /// The other labels: their frames and their boxes in their planes.
    others: []const Other = &.{},
    face: ?*const Face = null,
    /// A resize: the corner that moves (+1 the high side, -1 the low
    /// side, on s and t), and true to keep the aspect.
    corner: [2]i8 = .{ 1, 1 },
    aspect: bool = true,
};

pub const Result = struct {
    box: Box,
    /// The move of the box (a move: the same on all its edges).
    d: [2]f64 = .{ 0, 0 },
    guides: []Guide,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.guides);
        r.* = undefined;
    }
};

/// A target on one axis: the value, and the span of its guide on the
/// other axis.
const Target = struct {
    v: f64,
    lo: f64,
    hi: f64,
    /// A gap or a size: the span of its guide on the axis.
    gap: ?[2]f64 = null,
    /// Only for this value of the box: 0 the low edge, 1 the center, 2
    /// the high edge (null: any).
    edge: ?u2 = null,
};

/// The box of another plane in the plane of `f` (its corners).
fn boxIn(f: Frame, g: Frame, b: Box) Box {
    var out: Box = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for ([_][2]f64{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[2], b[3] }, .{ b[0], b[3] } }) |c| {
        const p = f.of(g.at(c[0], c[1]));
        out = .{ @min(out[0], p[0]), @min(out[1], p[1]), @max(out[2], p[0]), @max(out[3], p[1]) };
    }
    return out;
}

fn mid(lo: f64, hi: f64) f64 {
    return (lo + hi) / 2;
}

/// The best snap of one axis: the value of the box (its index in
/// `vals`) and the target, or null.
const Pick = struct { di: f64, t: Target, idx: u2 };

/// vals: the low edge, the center, and the high edge of the box on the
/// axis (null: not free to snap).
fn best(vals: [3]?f64, targets: []const Target, tol: f64) ?Pick {
    var out: ?Pick = null;
    for (targets) |t| for (vals, 0..) |vv, k| {
        const v = vv orelse continue;
        if (t.edge) |e| if (e != k) continue;
        const d = t.v - v;
        if (@abs(d) > tol) continue;
        if (out == null or @abs(d) < @abs(out.?.di) - 1e-9) out = .{ .di = d, .t = t, .idx = @intCast(k) };
    };
    return out;
}

/// The snap of a box (see the header). The caller owns the result.
pub fn snap(gpa: Allocator, in: Input) Allocator.Error!Result {
    var targets: [2]std.ArrayList(Target) = .{ .empty, .empty };
    defer for (&targets) |*t| t.deinit(gpa);
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(gpa);
    for (in.others) |o| {
        if (!in.frame.samePlane(o.frame)) continue;
        try boxes.append(gpa, boxIn(in.frame, o.frame, o.box));
    }
    // The edges and the centers of the other labels.
    for (boxes.items) |b| for (0..2) |ax| {
        const lo = b[1 - ax];
        const hi = b[3 - ax];
        for ([_]f64{ b[ax], mid(b[ax], b[ax + 2]), b[ax + 2] }) |v| try targets[ax].append(gpa, .{ .v = v, .lo = lo, .hi = hi });
    };
    // Equal gaps: two other labels in a row on an axis.
    for (boxes.items, 0..) |a, i| for (boxes.items, 0..) |b, j| {
        if (i == j) continue;
        for (0..2) |ax| {
            const g = b[ax] - a[ax + 2];
            if (!(g > 0)) continue;
            const lo = @min(a[1 - ax], b[1 - ax]);
            const hi = @max(a[3 - ax], b[3 - ax]);
            // After b (the low edge of the box), and before a (its high
            // edge).
            try targets[ax].append(gpa, .{ .v = b[ax + 2] + g, .lo = lo, .hi = hi, .gap = .{ a[ax + 2], b[ax] }, .edge = 0 });
            try targets[ax].append(gpa, .{ .v = a[ax] - g, .lo = lo, .hi = hi, .gap = .{ a[ax + 2], b[ax] }, .edge = 2 });
        }
    };
    if (in.face) |f| {
        const same = in.frame.samePlane(f.frame);
        const conv = struct {
            fn p(fr: Frame, g: Frame, q: [2]f64) [2]f64 {
                return fr.of(g.at(q[0], q[1]));
            }
        };
        if (same) {
            const fb = boxIn(in.frame, f.frame, f.box);
            const c = conv.p(in.frame, f.frame, f.center);
            for (0..2) |ax| try targets[ax].append(gpa, .{ .v = c[ax], .lo = fb[1 - ax], .hi = fb[3 - ax] });
            for (f.holes) |h| {
                const hb = boxIn(in.frame, f.frame, h.box);
                const hc = conv.p(in.frame, f.frame, h.center);
                for (0..2) |ax| {
                    try targets[ax].append(gpa, .{ .v = hc[ax], .lo = hb[1 - ax], .hi = hb[3 - ax] });
                    // The edges of a rectangle in line with the axes, and of
                    // a round hole.
                    const turn = @mod(std.math.radiansToDegrees(std.math.atan2(dot(f.frame.right, in.frame.up()), dot(f.frame.right, in.frame.right))) + h.angle, 90);
                    if (h.kind == .round or (h.kind == .rect and (turn < 1 or turn > 89))) {
                        try targets[ax].append(gpa, .{ .v = hb[ax], .lo = hb[1 - ax], .hi = hb[3 - ax] });
                        try targets[ax].append(gpa, .{ .v = hb[ax + 2], .lo = hb[1 - ax], .hi = hb[3 - ax] });
                    }
                }
            }
        }
        // The center of the part: on the plane through the part.
        const pc = conv.p(in.frame, f.frame, f.part_center);
        for (0..2) |ax| try targets[ax].append(gpa, .{ .v = pc[ax], .lo = pc[1 - ax], .hi = pc[1 - ax] });
    }

    var box = in.box;
    var d: [2]f64 = .{ 0, 0 };
    var picks: [2]?Pick = .{ null, null };
    switch (in.op) {
        .move => {
            for (0..2) |ax| {
                picks[ax] = best(.{ box[ax], mid(box[ax], box[ax + 2]), box[ax + 2] }, targets[ax].items, in.tol);
                if (picks[ax]) |p| d[ax] = p.di;
            }
            box = .{ box[0] + d[0], box[1] + d[1], box[2] + d[0], box[3] + d[1] };
        },
        .resize => {
            // The moving edge of each axis, and its anchor.
            var edge: [2]usize = undefined;
            var anchor: [2]f64 = undefined;
            for (0..2) |ax| {
                edge[ax] = if (in.corner[ax] > 0) ax + 2 else ax;
                anchor[ax] = if (in.corner[ax] > 0) box[ax] else box[ax + 2];
                // The size of another label: the edge at the anchor and
                // its size.
                const sign: f64 = if (in.corner[ax] > 0) 1 else -1;
                for (boxes.items) |b| try targets[ax].append(gpa, .{ .v = anchor[ax] + sign * (b[ax + 2] - b[ax]), .lo = b[1 - ax], .hi = b[3 - ax], .gap = .{ b[ax], b[ax + 2] } });
                var vals: [3]?f64 = .{ null, null, null };
                vals[if (in.corner[ax] > 0) 2 else 0] = box[edge[ax]];
                picks[ax] = best(vals, targets[ax].items, in.tol);
            }
            const size0: [2]f64 = .{ box[2] - box[0], box[3] - box[1] };
            if (in.aspect) {
                // One snap for both axes: the nearer one.
                var ax_pick: ?usize = null;
                for (0..2) |ax| if (picks[ax]) |p| {
                    if (ax_pick == null or @abs(p.di) < @abs(picks[ax_pick.?].?.di)) ax_pick = ax;
                };
                if (ax_pick) |ax| {
                    const k = if (size0[ax] > 1e-9) (size0[ax] + @abs(box[edge[ax]] + picks[ax].?.di - anchor[ax]) - @abs(box[edge[ax]] - anchor[ax])) / size0[ax] else 1;
                    picks[1 - ax] = null;
                    for (0..2) |a2| {
                        const ns = size0[a2] * k;
                        if (in.corner[a2] > 0) box[a2 + 2] = box[a2] + ns else box[a2] = box[a2 + 2] - ns;
                    }
                }
            } else {
                for (0..2) |ax| if (picks[ax]) |p| {
                    box[edge[ax]] += p.di;
                };
            }
        },
    }
    // The guides.
    var guides: std.ArrayList(Guide) = .empty;
    errdefer guides.deinit(gpa);
    for (0..2) |ax| if (picks[ax]) |p| {
        const lo = @min(p.t.lo, box[1 - ax]);
        const hi = @max(p.t.hi, box[3 - ax]);
        if (p.t.gap) |g| {
            // A gap or a size: a line along the axis at the middle of
            // the other axis.
            const m = mid(box[1 - ax], box[3 - ax]);
            try guides.append(gpa, if (ax == 0) .{ g[0], m, g[1], m } else .{ m, g[0], m, g[1] });
            if (p.t.edge) |e| {
                // An equal gap: the gap of the box too, the same length.
                const len = g[1] - g[0];
                const from = if (e == 0) box[ax] - len else box[ax + 2];
                try guides.append(gpa, if (ax == 0) .{ from, m, from + len, m } else .{ m, from, m, from + len });
            }
            continue;
        }
        const v = p.t.v;
        try guides.append(gpa, if (ax == 0) .{ v, lo, v, hi } else .{ lo, v, hi, v });
    };
    return .{ .box = box, .d = d, .guides = try guides.toOwnedSlice(gpa) };
}

// ---- tests ----

const testing = std.testing;

const front: Frame = .{ .origin = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 } };

test "label snap: a round hole and a square hole" {
    // A circle of 32 points (clockwise: a hole).
    var circle: [32]P2 = undefined;
    for (&circle, 0..) |*p, k| {
        const a = -2 * std.math.pi * @as(f64, @floatFromInt(k)) / 32;
        p.* = .{ 10 + 3 * @cos(a), 5 + 3 * @sin(a) };
    }
    const h = classify(&circle);
    try testing.expectEqual(HoleKind.round, h.kind);
    try testing.expectApproxEqAbs(@as(f64, 10), h.center[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), h.radius, 0.02);
    // A rectangle 4 x 2 turned by 30°.
    const a = std.math.degreesToRadians(30.0);
    var rect: [4]P2 = undefined;
    for ([_]P2{ .{ -2, -1 }, .{ -2, 1 }, .{ 2, 1 }, .{ 2, -1 } }, &rect) |q, *p| p.* = .{ 5 + q[0] * @cos(a) - q[1] * @sin(a), 1 + q[0] * @sin(a) + q[1] * @cos(a) };
    const r = classify(&rect);
    try testing.expectEqual(HoleKind.rect, r.kind);
    try testing.expectApproxEqAbs(@as(f64, 30), r.angle, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 4), r.size[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 2), r.size[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 5), r.center[0], 1e-6);
    // A triangle: neither.
    const t = classify(&.{ .{ 0, 0 }, .{ 0, 4 }, .{ 4, 0 } });
    try testing.expectEqual(HoleKind.other, t.kind);
}

test "label snap: the face of a plate with a square hole" {
    const gpa = testing.allocator;
    // The top of a plate 40 x 20 at z 2 with a hole 4 x 4 at (30, 10):
    // four quads from the outline to the hole.
    var b: mesh_mod.Builder = .init(gpa);
    defer b.deinit();
    const V = mesh_mod.Vec3;
    const o = [4]V{ .{ .x = 0, .y = 0, .z = 2 }, .{ .x = 40, .y = 0, .z = 2 }, .{ .x = 40, .y = 20, .z = 2 }, .{ .x = 0, .y = 20, .z = 2 } };
    const h = [4]V{ .{ .x = 28, .y = 8, .z = 2 }, .{ .x = 32, .y = 8, .z = 2 }, .{ .x = 32, .y = 12, .z = 2 }, .{ .x = 28, .y = 12, .z = 2 } };
    for (0..4) |k| {
        const j = (k + 1) % 4;
        try b.addTriangle(o[k], o[j], h[j]);
        try b.addTriangle(o[k], h[j], h[k]);
    }
    var m = try b.finish();
    defer m.deinit(gpa);
    const fr: Frame = .{ .origin = .{ 10, 10, 2 }, .normal = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 } };
    var f = (try face(gpa, &m, fr)).?;
    defer f.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, -10), f.box[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 30), f.box[2], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 10), f.part_center[0], 1e-3);
    try testing.expectEqual(@as(usize, 1), f.holes.len);
    try testing.expectEqual(HoleKind.rect, f.holes[0].kind);
    try testing.expectApproxEqAbs(@as(f64, 20), f.holes[0].center[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0), f.holes[0].center[1], 1e-3);
    // No face in another plane.
    try testing.expect((try face(gpa, &m, .{ .origin = .{ 0, 0, 5 }, .normal = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 } })) == null);
}

test "label snap: move to edges, centers, and equal gaps" {
    const gpa = testing.allocator;
    const others = [_]Other{
        .{ .frame = front, .box = .{ 0, 0, 10, 5 } },
        .{ .frame = front, .box = .{ 20, 0, 30, 5 } },
    };
    // The left edge 0.3 mm from the left edge of the first label, and
    // over the labels (no snap on t).
    var r = try snap(gpa, .{ .box = .{ 0.3, 10.2, 8.3, 14.2 }, .frame = front, .tol = 0.5, .others = &others });
    defer r.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, -0.3), r.d[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), r.box[0], 1e-9);
    try testing.expectEqual(@as(f64, 0), r.d[1]);
    try testing.expectEqual(@as(usize, 1), r.guides.len);
    // A vertical guide at s = 0 from the first label up to the box.
    try testing.expectEqual(@as(f64, 0), r.guides[0][0]);
    try testing.expectEqual(@as(f64, 0), r.guides[0][1]);
    try testing.expectApproxEqAbs(@as(f64, 14.2), r.guides[0][3], 1e-9);
    // Far from all: no snap.
    var far = try snap(gpa, .{ .box = .{ 50, 50, 55, 52 }, .frame = front, .tol = 0.5, .others = &others });
    defer far.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), far.guides.len);
    try testing.expectEqual([2]f64{ 0, 0 }, far.d);
    // An equal gap after the second label: the gap is 10, so s0 = 40.
    var gap = try snap(gpa, .{ .box = .{ 40.4, 0.1, 45.4, 5.3 }, .frame = front, .tol = 0.5, .others = &others });
    defer gap.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 40), gap.box[0], 1e-9);
    // Two guides of the gaps, each 10 long.
    var tens: usize = 0;
    for (gap.guides) |g| {
        if (@abs(@abs(g[2] - g[0]) - 10) < 1e-9 and g[1] == g[3]) tens += 1;
    }
    try testing.expectEqual(@as(usize, 2), tens);
    // Another plane: no snap to its labels.
    const side: Frame = .{ .origin = .{ 0, 0, 0 }, .normal = .{ 1, 0, 0 }, .right = .{ 0, 1, 0 } };
    var other_plane = try snap(gpa, .{ .box = .{ 0.3, 10.2, 8.3, 14.2 }, .frame = side, .tol = 0.5, .others = &others });
    defer other_plane.deinit(gpa);
    try testing.expectEqual([2]f64{ 0, 0 }, other_plane.d);
}

test "label snap: centered on a hole, on the face, and on the part" {
    const gpa = testing.allocator;
    var holes = [_]Hole{.{ .kind = .round, .center = .{ 20, 10 }, .box = .{ 17, 7, 23, 13 }, .radius = 3 }};
    const f: Face = .{ .frame = front, .box = .{ 0, 0, 40, 20 }, .center = .{ 20, 10 }, .part_center = .{ 20, 12 }, .holes = &holes };
    // The center of the box 0.4 mm from the center of the hole.
    var r = try snap(gpa, .{ .box = .{ 18.4, 8.6, 22.4, 11.4 }, .frame = front, .tol = 0.5, .face = &f });
    defer r.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, -0.4), r.d[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), r.d[1], 1e-9);
    // The center of the part on t (12), in a frame moved by 5 mm: the
    // face converts to the frame of the label.
    const moved: Frame = .{ .origin = .{ 5, 0, 0 }, .normal = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 } };
    var m = try snap(gpa, .{ .box = .{ 30, 10.2, 34, 13.4 }, .frame = moved, .tol = 0.5, .face = &f });
    defer m.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, -0.2), m.d[1], 1e-9);
}

test "label snap: resize to an edge and to the size of another label" {
    const gpa = testing.allocator;
    const others = [_]Other{.{ .frame = front, .box = .{ 0, 20, 12, 26 } }};
    // The upper right corner moves; the right edge is 0.3 from 12: the
    // aspect stays, so the height grows by the same factor.
    var r = try snap(gpa, .{ .op = .resize, .box = .{ 0, 0, 11.7, 3.9 }, .frame = front, .tol = 0.5, .others = &others, .corner = .{ 1, 1 } });
    defer r.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 12), r.box[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), r.box[3], 1e-9);
    // Free aspect: the height 5.8 snaps to the height 6 of the other
    // label (the box starts at t = 0), and the width stays.
    var f = try snap(gpa, .{ .op = .resize, .box = .{ 2, 0, 8, 5.8 }, .frame = front, .tol = 0.5, .others = &others, .corner = .{ 1, 1 }, .aspect = false });
    defer f.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 6), f.box[3], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8), f.box[2], 1e-9);
    // The lower left corner moves: the anchor is the upper right.
    var l = try snap(gpa, .{ .op = .resize, .box = .{ 0.2, -10, 30, 10 }, .frame = front, .tol = 0.5, .others = &others, .corner = .{ -1, -1 }, .aspect = false });
    defer l.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 0), l.box[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 30), l.box[2], 1e-9);
}
