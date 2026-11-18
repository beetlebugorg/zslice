//! Physics of a part on the bed: its mass, its center of mass, the area it
//! stands on, and the roll of a part that cannot stand until it rests
//! (specs: hands-on support and physics).
//!
//! - The center of mass comes from the closed mesh: the sum of the signed
//!   tetrahedra of each face with the origin (a solid of even density).
//! - The part stands on the points of its mesh at its lowest z (within
//!   0.05 mm). Their convex hull on the bed is the foot.
//! - The part stands if its center of mass, seen from above, is in the
//!   foot. Else it rolls over the edge of the foot that the center of mass
//!   is past: it turns about that edge, the center of mass going down,
//!   until another point of the part reaches the bed. Then the test runs
//!   again on the new foot. A part on a point or on an edge rolls the
//!   same way, toward its center of mass.
//! - The roll ends on a face (or a set of points) that holds the part. The
//!   result is the rotation of the whole roll.
//!
//! This is the model of one rigid part on a flat bed. A full game physics
//! engine (collisions between parts, bounces) is more than a slicer needs,
//! and costs size and speed (see specs/28).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

pub const V = [3]f64;
pub const M3 = [3]V;

const identity: M3 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn dot(a: V, b: V) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn mulV(m: M3, v: V) V {
    return .{ dot(m[0], v), dot(m[1], v), dot(m[2], v) };
}
fn mulM(a: M3, b: M3) M3 {
    var r: M3 = undefined;
    for (0..3) |i| for (0..3) |j| {
        r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    };
    return r;
}

/// The volume (mm³) and the center of mass of a closed mesh.
pub fn massOf(mesh: *const Mesh) struct { volume: f64, center: V } {
    var vol: f64 = 0;
    var c: V = .{ 0, 0, 0 };
    const vs = mesh.vertices.items;
    for (mesh.faces.items) |f| {
        const a = V{ vs[f[0]].x, vs[f[0]].y, vs[f[0]].z };
        const b = V{ vs[f[1]].x, vs[f[1]].y, vs[f[1]].z };
        const d = V{ vs[f[2]].x, vs[f[2]].y, vs[f[2]].z };
        const v6 = dot(a, cross(b, d));
        vol += v6;
        for (0..3) |k| c[k] += v6 * (a[k] + b[k] + d[k]);
    }
    if (@abs(vol) < 1e-12) {
        // No volume (an open surface): the mean of the points.
        var m: V = .{ 0, 0, 0 };
        for (vs) |v| m = .{ m[0] + v.x, m[1] + v.y, m[2] + v.z };
        const n: f64 = @floatFromInt(@max(1, vs.len));
        return .{ .volume = 0, .center = .{ m[0] / n, m[1] / n, m[2] / n } };
    }
    return .{ .volume = vol / 6, .center = .{ c[0] / (4 * vol), c[1] / (4 * vol), c[2] / (4 * vol) } };
}

const P2 = [2]f64;

/// The convex hull of points, counterclockwise (Andrew's monotone chain).
fn hull2(a: Allocator, pts: []P2) Allocator.Error![]P2 {
    std.sort.block(P2, pts, {}, struct {
        fn lt(_: void, p: P2, q: P2) bool {
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    }.lt);
    if (pts.len < 3) return a.dupe(P2, pts);
    const out = try a.alloc(P2, 2 * pts.len);
    defer a.free(out);
    var k: usize = 0;
    const turn = struct {
        fn f(o: P2, p: P2, q: P2) f64 {
            return (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0]);
        }
    }.f;
    for (pts) |p| {
        while (k >= 2 and turn(out[k - 2], out[k - 1], p) <= 1e-9) k -= 1;
        out[k] = p;
        k += 1;
    }
    const lower = k + 1;
    var i = pts.len - 1;
    while (i > 0) {
        i -= 1;
        const p = pts[i];
        while (k >= lower and turn(out[k - 2], out[k - 1], p) <= 1e-9) k -= 1;
        out[k] = p;
        k += 1;
    }
    return a.dupe(P2, out[0 .. k - 1]);
}

pub const Settle = struct {
    /// The rotation of the roll (rows), from the part as it was to the part
    /// at rest; the identity if it stands.
    rot: M3,
    /// The number of rolls (0: the part stands).
    rolls: u32,
    /// The angle of the whole roll, degrees (for an animation).
    degrees: f64,
};

/// How far the center of mass is inside the foot (mm; negative: outside),
/// for points `pts` (x, y, z) and the center `c`. `edge` gets the axis of
/// the roll when outside: a point on the bed and a unit direction.
fn footMargin(a: Allocator, pts: []const V, c: V, eps: f64, edge: *[2]V) Allocator.Error!f64 {
    var zmin: f64 = std.math.inf(f64);
    for (pts) |p| zmin = @min(zmin, p[2]);
    var foot: std.ArrayList(P2) = .empty;
    defer foot.deinit(a);
    for (pts) |p| if (p[2] < zmin + eps) try foot.append(a, .{ p[0], p[1] });
    const h = try hull2(a, foot.items);
    defer a.free(h);
    if (h.len == 1) {
        // On a point: roll toward the center of mass.
        const dx = c[0] - h[0][0];
        const dy = c[1] - h[0][1];
        const l = @sqrt(dx * dx + dy * dy);
        if (l < 1e-6) return 0;
        // The axis: through the point, at right angles to the way down.
        edge.* = .{ .{ h[0][0], h[0][1], zmin }, .{ -dy / l, dx / l, 0 } };
        return -l;
    }
    if (h.len == 2) {
        // On an edge: roll to the side of the center of mass.
        const ex = h[1][0] - h[0][0];
        const ey = h[1][1] - h[0][1];
        const l = @sqrt(ex * ex + ey * ey);
        const side = (ex * (c[1] - h[0][1]) - ey * (c[0] - h[0][0])) / l;
        if (@abs(side) < 1e-6) return 0;
        // The roll lowers the side to the right of the axis: the axis
        // points so that the center of mass is on its right.
        const dir: V = if (side > 0) .{ -ex / l, -ey / l, 0 } else .{ ex / l, ey / l, 0 };
        edge.* = .{ .{ h[0][0], h[0][1], zmin }, dir };
        return -@abs(side);
    }
    // A polygon: the least distance of the center to an edge, inside.
    var worst: f64 = std.math.inf(f64);
    for (h, 0..) |p, i| {
        const q = h[(i + 1) % h.len];
        const ex = q[0] - p[0];
        const ey = q[1] - p[1];
        const l = @sqrt(ex * ex + ey * ey);
        if (l < 1e-9) continue;
        // Counterclockwise: inside is on the left.
        const d = (ex * (c[1] - p[1]) - ey * (c[0] - p[0])) / l;
        if (d < worst) {
            worst = d;
            // The roll about this edge: the center goes out over it, to
            // the right of the edge; the axis points along the edge, so
            // that the side of the center is on its right.
            edge.* = .{ .{ p[0], p[1], zmin }, .{ ex / l, ey / l, 0 } };
        }
    }
    return worst;
}

/// A rotation about a unit axis by `t` radians (Rodrigues).
fn rotation(k: V, t: f64) M3 {
    const c = @cos(t);
    const s = @sin(t);
    const u = 1 - c;
    return .{
        .{ c + k[0] * k[0] * u, k[0] * k[1] * u - k[2] * s, k[0] * k[2] * u + k[1] * s },
        .{ k[1] * k[0] * u + k[2] * s, c + k[1] * k[1] * u, k[1] * k[2] * u - k[0] * s },
        .{ k[2] * k[0] * u - k[1] * s, k[2] * k[1] * u + k[0] * s, c + k[2] * k[2] * u },
    };
}

/// Rolls the part (its mesh as it is on the bed, z up) until it rests.
pub fn settle(a: Allocator, mesh: *const Mesh) Allocator.Error!Settle {
    const vs = mesh.vertices.items;
    if (vs.len == 0) return .{ .rot = identity, .rolls = 0, .degrees = 0 };
    // The points of the convex hull are enough, but all points work; a
    // large mesh uses each n-th point for the search of the next contact
    // and all points for the foot.
    const pts = try a.alloc(V, vs.len);
    defer a.free(pts);
    for (vs, pts) |v, *p| p.* = .{ v.x, v.y, v.z };
    var c = massOf(mesh).center;
    var rot = identity;
    var rolls: u32 = 0;
    var degrees: f64 = 0;
    const eps = 0.05;
    while (rolls < 24) {
        var edge: [2]V = undefined;
        const m = try footMargin(a, pts, c, eps, &edge);
        if (m >= -1e-3) break;
        // Turn about the edge so that the center of mass goes down: the
        // axis direction k is set so that the side of the center (right
        // of the edge) turns down. The angle is the least turn that brings
        // another point to the bed.
        const o = edge[0];
        const k = edge[1];
        var best: f64 = std.math.pi;
        for (pts) |p| {
            const r = sub(p, o);
            // The part of r at right angles to the axis: across (in the
            // bed, away from the foot) and up.
            const along = dot(r, k);
            const q = V{ r[0] - along * k[0], r[1] - along * k[1], r[2] };
            const out = cross(k, V{ 0, 0, 1 });
            const u = dot(q, out);
            const w = q[2];
            if (u < 1e-6 or w < eps) continue;
            best = @min(best, std.math.atan2(w, u));
        }
        if (best >= std.math.pi - 1e-9) break;
        // The sign: turning by +t about k must lower the side of `out`.
        var r = rotation(k, best);
        const test_p = mulV(r, cross(k, V{ 0, 0, 1 }));
        if (test_p[2] > 0) r = rotation(k, -best);
        for (pts) |*p| p.* = add3(mulV(r, sub(p.*, o)), o);
        c = add3(mulV(r, sub(c, o)), o);
        rot = mulM(r, rot);
        rolls += 1;
        degrees += std.math.radiansToDegrees(best);
    }
    return .{ .rot = rot, .rolls = rolls, .degrees = degrees };
}

fn add3(a: V, b: V) V {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

/// The side of the part that goes on the bed after `settle`: the outward
/// normal (in the coordinates of the mesh before the roll) that points
/// down at rest.
pub fn downOf(s: Settle) V {
    // rot maps the old frame to the new; down in the new frame is -z, and
    // in the old frame it is the transpose of rot times -z.
    return .{ -s.rot[2][0], -s.rot[2][1], -s.rot[2][2] };
}

const testing = std.testing;

fn boxMesh(gpa: Allocator, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) !Mesh {
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, x0, y0, z0, x1, y1, z1);
    return b.finish();
}

test "physics: a cube on a face stands" {
    var m = try boxMesh(testing.allocator, 0, 0, 0, 10, 10, 10);
    defer m.deinit(testing.allocator);
    const mp = massOf(&m);
    try testing.expectApproxEqAbs(@as(f64, 1000), mp.volume, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 5), mp.center[2], 1e-9);
    const s = try settle(testing.allocator, &m);
    try testing.expectEqual(@as(u32, 0), s.rolls);
}

test "physics: a tall board on its thin edge, turned, falls flat" {
    const gpa = testing.allocator;
    // A board 40 x 4 x 2 mm, turned 30 degrees about X so it stands on one
    // long edge: its center is past that edge. It falls onto a large face.
    var m = try boxMesh(gpa, -20, -2, -1, 20, 2, 1);
    defer m.deinit(gpa);
    const t = std.math.degreesToRadians(60.0);
    for (m.vertices.items) |*v| {
        const y = v.y;
        const z = v.z;
        v.y = @floatCast(@cos(t) * y - @sin(t) * z);
        v.z = @floatCast(@sin(t) * y + @cos(t) * z);
    }
    const s = try settle(gpa, &m);
    try testing.expect(s.rolls >= 1);
    // At rest, the side down is a large face: the normal of the 40 x 4 face
    // (±z of the board before the turn about X, so it has no x part).
    const d = downOf(s);
    try testing.expect(@abs(d[0]) < 1e-6);
    // The new foot holds it: settle again gives no roll.
    var m2 = try m.clone(gpa);
    defer m2.deinit(gpa);
    for (m2.vertices.items) |*v| {
        const p = mulV(s.rot, .{ v.x, v.y, v.z });
        v.* = .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]), .z = @floatCast(p[2]) };
    }
    const s2 = try settle(gpa, &m2);
    try testing.expectEqual(@as(u32, 0), s2.rolls);
}

test "physics: a tall board tipped 30 degrees falls flat, the way it leans" {
    const gpa = testing.allocator;
    // A board 40 x 4 x 30 mm on its 40 x 4 face, tipped 30 degrees about
    // X: its center of mass is past its foot. It falls forward onto its
    // 40 x 30 face (60 degrees more), and does not stand up again.
    var m = try boxMesh(gpa, -20, -2, 0, 20, 2, 30);
    defer m.deinit(gpa);
    const t = std.math.degreesToRadians(30.0);
    for (m.vertices.items) |*v| {
        const y = v.y;
        const z = v.z;
        v.y = @floatCast(@cos(t) * y - @sin(t) * z);
        v.z = @floatCast(@sin(t) * y + @cos(t) * z);
    }
    const s = try settle(gpa, &m);
    try testing.expectApproxEqAbs(@as(f64, 60), s.degrees, 0.5);
    // At rest it is 4 mm high.
    var zmax: f64 = -1e9;
    var zmin: f64 = 1e9;
    for (m.vertices.items) |v| {
        const q = mulV(s.rot, .{ v.x, v.y, v.z });
        zmax = @max(zmax, q[2]);
        zmin = @min(zmin, q[2]);
    }
    try testing.expectApproxEqAbs(@as(f64, 4), zmax - zmin, 0.01);
}
