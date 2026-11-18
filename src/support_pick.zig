//! The overhang at a point: the support tool lights the overhang under the
//! pointer, and a click puts support under it.
//!
//! An overhang is a connected set of faces of the mesh that face down: the
//! z of the unit normal is under -down (`downFor`: from the support angle)
//! and the face is above the bed. Two faces are connected when they share
//! an edge. The search:
//!
//! 1. The faces that face down, from the mesh of the part (its pose and
//!    scale are in the mesh; the turn about z keeps the z of a normal).
//!    `Prep` keeps them, and the faces across their edges, for each mesh.
//! 2. The seed: the face that faces down nearest to the point on the bed,
//!    within `max_dist`.
//! 3. The region: the faces connected to the seed (a flood over shared
//!    edges).
//! 4. The outline: the convex hull of the vertices of the region on the
//!    bed (x, y), grown by `grow` mm so the edges of the overhang are in
//!    it, and the z range of the region. Support of the area kinds grows
//!    under the faces in the polygon that face down (see
//!    app/support_areas.zig), so a hull over a concave overhang adds no
//!    support under the faces that do not face down.
//!
//! The hull is the monotone chain of A. M. Andrew (see REFERENCES.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vec3 = mesh_mod.Vec3;

/// Faces lower than this over the bed (mm) stand on the bed.
pub const bed_z = 0.2;
/// The outline grows by this much (mm).
pub const grow = 0.6;
/// The most points of an outline (support_areas.max_points).
pub const max_points = 256;

pub const Region = struct {
    /// The outline on the bed, with the z of the region at each point
    /// (x, y, z in mm), in gpa.
    points: [][3]f64,
    z_lo: f64,
    z_hi: f64,
    /// The count of faces in the region, and their area (mm²).
    faces: usize,
    area: f64,

    pub fn deinit(r: *Region, gpa: Allocator) void {
        gpa.free(r.points);
    }
};

/// The 4x3 transform of a part to the bed (plate.Part.transform).
fn apply(t: [12]f64, v: Vec3) [3]f64 {
    const x: f64 = v.x;
    const y: f64 = v.y;
    const z: f64 = v.z;
    return .{ x * t[0] + y * t[3] + z * t[6] + t[9], x * t[1] + y * t[4] + z * t[7] + t[10], x * t[2] + y * t[5] + z * t[8] + t[11] };
}

fn cross2(o: [2]f64, a: [2]f64, b: [2]f64) f64 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

fn segDist2(p: [2]f64, a: [2]f64, b: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l = dx * dx + dy * dy;
    const u = if (l > 0) std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l, 0, 1) else 0;
    const ex = a[0] + u * dx - p[0];
    const ey = a[1] + u * dy - p[1];
    return ex * ex + ey * ey;
}

/// The squared distance on the bed from p to a triangle: 0 inside it.
fn triDist2(p: [2]f64, a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    const d1 = cross2(a, b, p);
    const d2 = cross2(b, c, p);
    const d3 = cross2(c, a, p);
    const neg = d1 < 0 or d2 < 0 or d3 < 0;
    const pos = d1 > 0 or d2 > 0 or d3 > 0;
    if (!(neg and pos)) return 0;
    return @min(segDist2(p, a, b), @min(segDist2(p, b, c), segDist2(p, c, a)));
}

fn lessXY(_: void, a: [2]f64, b: [2]f64) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

/// The convex hull of the points (counterclockwise), in gpa.
pub fn hull(gpa: Allocator, pts: [][2]f64) Allocator.Error![][2]f64 {
    std.mem.sort([2]f64, pts, {}, lessXY);
    if (pts.len < 3) return gpa.dupe([2]f64, pts);
    var h = try gpa.alloc([2]f64, 2 * pts.len);
    var k: usize = 0;
    for (pts) |p| {
        while (k >= 2 and cross2(h[k - 2], h[k - 1], p) <= 0) k -= 1;
        h[k] = p;
        k += 1;
    }
    const lower = k + 1;
    var i = pts.len - 1;
    while (i > 0) {
        i -= 1;
        const p = pts[i];
        while (k >= lower and cross2(h[k - 2], h[k - 1], p) <= 0) k -= 1;
        h[k] = p;
        k += 1;
    }
    return gpa.realloc(h, k - 1);
}

/// The data of a mesh for picks, made once for each mesh: the z of the
/// unit normal of each face, the faces that face down more than
/// `prep_down`, and for each of them the face across each edge (or
/// `none`). A turn about z and a move keep it; a new mesh needs a new one.
pub const Prep = struct {
    /// The mesh it was made from, to see a change.
    key: [3]usize,
    nz: []f32,
    down: []u32,
    /// For down[i]: the faces across its 3 edges.
    across: [][3]u32,

    pub const none = std.math.maxInt(u32);
    /// Faces that face down less than this are never part of an overhang.
    pub const prep_down = 0.05;

    pub fn keyOf(mesh: *const Mesh) [3]usize {
        return .{ @intFromPtr(mesh.faces.items.ptr), mesh.faces.items.len, @intFromPtr(mesh.vertices.items.ptr) };
    }

    pub fn init(gpa: Allocator, mesh: *const Mesh) Allocator.Error!Prep {
        const faces = mesh.faces.items;
        const verts = mesh.vertices.items;
        const nz = try gpa.alloc(f32, faces.len);
        errdefer gpa.free(nz);
        var down: std.ArrayList(u32) = .empty;
        errdefer down.deinit(gpa);
        for (faces, nz, 0..) |f, *o, i| {
            const v0 = verts[f[0]];
            const v1 = verts[f[1]];
            const v2 = verts[f[2]];
            const e1 = [3]f64{ v1.x - v0.x, v1.y - v0.y, v1.z - v0.z };
            const e2 = [3]f64{ v2.x - v0.x, v2.y - v0.y, v2.z - v0.z };
            const n = [3]f64{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
            const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
            o.* = if (len > 0) @floatCast(n[2] / len) else 0;
            if (o.* < -prep_down) try down.append(gpa, @intCast(i));
        }
        var edges: std.AutoHashMapUnmanaged(u64, [2]u32) = .empty;
        defer edges.deinit(gpa);
        try edges.ensureTotalCapacity(gpa, @intCast(down.items.len * 3 + 8));
        for (down.items) |fi| {
            const f = faces[fi];
            for (0..3) |j| {
                const g = edges.getOrPutAssumeCapacity(edgeKey(f[j], f[(j + 1) % 3]));
                if (!g.found_existing) g.value_ptr.* = .{ fi, none } else if (g.value_ptr[1] == none) g.value_ptr[1] = fi;
            }
        }
        const across = try gpa.alloc([3]u32, down.items.len);
        errdefer gpa.free(across);
        for (down.items, across) |fi, *o| {
            const f = faces[fi];
            for (0..3) |j| {
                const pair = edges.get(edgeKey(f[j], f[(j + 1) % 3])).?;
                o[j] = if (pair[0] == fi) pair[1] else pair[0];
            }
        }
        return .{ .key = keyOf(mesh), .nz = nz, .down = try down.toOwnedSlice(gpa), .across = across };
    }

    pub fn deinit(pr: *Prep, gpa: Allocator) void {
        gpa.free(pr.nz);
        gpa.free(pr.down);
        gpa.free(pr.across);
    }
};

fn edgeKey(x: u32, y: u32) u64 {
    return (@as(u64, @min(x, y)) << 32) | @max(x, y);
}

/// The z of the unit normal under which a face is part of an overhang, for
/// a support angle (degrees from vertical, project.support_angle): faces
/// more than 10° less steep than the angle, and at least 20° past vertical.
pub fn downFor(support_angle: f64) f64 {
    const deg = std.math.clamp(support_angle - 10, 20, 80);
    return @sin(std.math.degreesToRadians(deg));
}

/// The overhang of the mesh (with transform t to the bed) nearest to the
/// bed point p, within max_dist mm on the bed and under p.z + max_dist.
/// A face is part of it when the z of its normal is under -down (see
/// downFor). Null: no overhang there.
pub fn pick(gpa: Allocator, mesh: *const Mesh, pr: *const Prep, t: [12]f64, p: [3]f64, max_dist: f64, down: f64) Allocator.Error!?Region {
    const faces = mesh.faces.items;
    const verts = mesh.vertices.items;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 1 and 2: the seed, from the faces that face down.
    var seed: ?usize = null; // an index into pr.down
    var seed_d = max_dist * max_dist;
    var seed_z = std.math.inf(f64);
    const tz = t[11];
    for (pr.down, 0..) |fi, k| {
        if (pr.nz[fi] >= -down) continue;
        const f = faces[fi];
        const cz = (@as(f64, verts[f[0]].z) + verts[f[1]].z + verts[f[2]].z) / 3 + tz;
        if (cz < bed_z or cz > p[2] + max_dist) continue;
        const v0 = apply(t, verts[f[0]]);
        const v1 = apply(t, verts[f[1]]);
        const v2 = apply(t, verts[f[2]]);
        const d = triDist2(.{ p[0], p[1] }, .{ v0[0], v0[1] }, .{ v1[0], v1[1] }, .{ v2[0], v2[1] });
        // The nearest face; of faces at the same distance (the point is over
        // each of them), the one nearest in z.
        const dz = @abs(cz - p[2]);
        if (d < seed_d or (d == seed_d and dz < seed_z)) {
            seed_d = d;
            seed_z = dz;
            seed = k;
        }
    }
    const s = seed orelse return null;

    // 3: the flood over shared edges, between faces that face down.
    const slot = try a.alloc(u32, faces.len);
    @memset(slot, Prep.none);
    for (pr.down, 0..) |fi, k| slot[fi] = @intCast(k);
    const in = try a.alloc(bool, pr.down.len);
    @memset(in, false);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, @intCast(s));
    in[s] = true;
    var count: usize = 0;
    var area: f64 = 0;
    var z_lo = std.math.inf(f64);
    var z_hi = -std.math.inf(f64);
    var pts: std.ArrayList([2]f64) = .empty;
    var zs: std.ArrayList(f64) = .empty;
    while (stack.pop()) |k| {
        count += 1;
        const f = faces[pr.down[k]];
        var v: [3][3]f64 = undefined;
        for (0..3) |j| {
            v[j] = apply(t, verts[f[j]]);
            try pts.append(a, .{ v[j][0], v[j][1] });
            try zs.append(a, v[j][2]);
            z_lo = @min(z_lo, v[j][2]);
            z_hi = @max(z_hi, v[j][2]);
        }
        area += @abs(cross2(.{ v[0][0], v[0][1] }, .{ v[1][0], v[1][1] }, .{ v[2][0], v[2][1] })) / 2;
        for (pr.across[k]) |o| {
            if (o == Prep.none) continue;
            const ok = slot[o];
            if (ok == Prep.none or in[ok] or pr.nz[o] >= -down) continue;
            in[ok] = true;
            try stack.append(a, ok);
        }
    }

    // 4: the hull, grown, with the z of the nearest vertex at each point.
    const h = try hull(a, pts.items);
    if (h.len < 3) return null;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (h) |q| {
        cx += q[0];
        cy += q[1];
    }
    cx /= @floatFromInt(h.len);
    cy /= @floatFromInt(h.len);
    const step = (h.len + max_points - 1) / max_points;
    const n_out = (h.len + step - 1) / step;
    const out = try gpa.alloc([3]f64, n_out);
    errdefer gpa.free(out);
    for (out, 0..) |*o, k| {
        const q = h[k * step];
        const dx = q[0] - cx;
        const dy = q[1] - cy;
        const d = @sqrt(dx * dx + dy * dy);
        const g = if (d > 0) grow / d else 0;
        // The z of the region vertex at this hull point.
        var z = z_lo;
        var best = std.math.inf(f64);
        for (pts.items, zs.items) |r, rz| {
            const e = (r[0] - q[0]) * (r[0] - q[0]) + (r[1] - q[1]) * (r[1] - q[1]);
            if (e < best) {
                best = e;
                z = rz;
            }
        }
        o.* = .{ q[0] + dx * g, q[1] + dy * g, z };
    }
    return .{ .points = out, .z_lo = z_lo, .z_hi = z_hi, .faces = count, .area = area };
}

const testing = std.testing;

/// A table: a top slab 20 x 20 at z 10 to 12 on one leg 4 x 4 in the
/// middle. The underside of the slab is the overhang.
fn table(gpa: Allocator) !Mesh {
    var m: Mesh = .empty;
    errdefer m.deinit(gpa);
    const box = struct {
        fn add(mm: *Mesh, g: Allocator, x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32) !void {
            const b: u32 = @intCast(mm.vertices.items.len);
            const xs = [2]f32{ x0, x1 };
            const ys = [2]f32{ y0, y1 };
            const zz = [2]f32{ z0, z1 };
            for (0..8) |i| try mm.vertices.append(g, .{ .x = xs[i & 1], .y = ys[(i >> 1) & 1], .z = zz[i >> 2] });
            const quads = [6][4]u32{ .{ 0, 2, 3, 1 }, .{ 4, 5, 7, 6 }, .{ 0, 1, 5, 4 }, .{ 2, 6, 7, 3 }, .{ 0, 4, 6, 2 }, .{ 1, 3, 7, 5 } };
            for (quads) |q| {
                try mm.faces.append(g, .{ b + q[0], b + q[1], b + q[2] });
                try mm.faces.append(g, .{ b + q[0], b + q[2], b + q[3] });
            }
        }
    }.add;
    try box(&m, gpa, 8, 8, 0, 12, 12, 10);
    try box(&m, gpa, 0, 0, 10, 20, 20, 12);
    return m;
}

test "support pick: the underside of a table top" {
    const gpa = testing.allocator;
    var m = try table(gpa);
    defer m.deinit(gpa);
    const t = [12]f64{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 100, 50, 0 };
    // A point on the top of the slab, near its edge.
    var pr = try Prep.init(gpa, &m);
    defer pr.deinit(gpa);
    var r = (try pick(gpa, &m, &pr, t, .{ 118, 52, 12 }, 6, downFor(50))).?;
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), r.faces);
    try testing.expectApproxEqAbs(@as(f64, 400), r.area, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 10), r.z_lo, 1e-6);
    try testing.expectEqual(@as(usize, 4), r.points.len);
    for (r.points) |q| {
        try testing.expect(q[0] < 100 - 0.3 or q[0] > 120 + 0.3);
        try testing.expectEqual(@as(f64, 10), q[2]);
    }
    // Far from the slab: no overhang.
    try testing.expect((try pick(gpa, &m, &pr, t, .{ 200, 200, 12 }, 6, downFor(50))) == null);
}

test "support pick: the hull" {
    var pts = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 0, 2 }, .{ 1, 0 } };
    const h = try hull(testing.allocator, &pts);
    defer testing.allocator.free(h);
    try testing.expectEqual(@as(usize, 4), h.len);
}
