//! Physics of a part on the bed: its mass, its center of mass, the area it
//! stands on, and the roll of a part that cannot stand until it rests.
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
//! - A push from the side (the nozzle, see bond.zig) can knock a part over
//!   that stands on its weight: `knock` turns it about the edge of its
//!   foot on the side of the push, and then it rolls as above.
//! - Supports hold a part too: the tops of the supports under it add to
//!   its foot (`holdMargin`). A part whose center of mass is past the
//!   foot and the supports cannot stand.
//!
//! This is the model of one rigid part on a flat bed. A full game physics
//! engine (collisions between parts, bounces) is more than a slicer needs,
//! and costs size and speed.
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

/// How far the center of mass of the part is inside the area that holds
/// it (mm; less than 0: outside): the convex hull of the points of the
/// mesh at its lowest z, and of `props` (the tops of the supports under
/// the part, x and y on the bed). A part on supports stands if its center
/// of mass is over that area.
pub fn holdMargin(a: Allocator, mesh: *const Mesh, props: []const [2]f64) Allocator.Error!f64 {
    const vs = mesh.vertices.items;
    if (vs.len == 0) return 0;
    const pts = try a.alloc(V, vs.len + props.len);
    defer a.free(pts);
    var zmin: f64 = std.math.inf(f64);
    for (vs, pts[0..vs.len]) |v, *p| {
        p.* = .{ v.x, v.y, v.z };
        zmin = @min(zmin, v.z);
    }
    for (props, pts[vs.len..]) |q, *p| p.* = .{ q[0], q[1], zmin };
    var edge: [2]V = undefined;
    return footMargin(a, pts, massOf(mesh).center, 0.05, &edge);
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
    const pts = try pointsOf(a, mesh);
    defer a.free(pts);
    var s: Settle = .{ .rot = identity, .rolls = 0, .degrees = 0 };
    var c = massOf(mesh).center;
    try rollOn(a, pts, &c, &s);
    return s;
}

/// Knocks the part over toward `dir` (a unit vector on the bed), as the
/// push of the nozzle does: it turns about the edge of its foot on that
/// side until another point reaches the bed, and then rolls until it
/// rests (as `settle`).
pub fn knock(a: Allocator, mesh: *const Mesh, dir: [2]f64) Allocator.Error!Settle {
    var s: Settle = .{ .rot = identity, .rolls = 0, .degrees = 0 };
    if (mesh.vertices.items.len == 0) return s;
    const pts = try pointsOf(a, mesh);
    defer a.free(pts);
    var c = massOf(mesh).center;
    // The pivot: the point of the foot farthest toward dir.
    var zmin: f64 = std.math.inf(f64);
    for (pts) |p| zmin = @min(zmin, p[2]);
    var o: V = pts[0];
    var far: f64 = -std.math.inf(f64);
    for (pts) |p| if (p[2] < zmin + settle_eps and p[0] * dir[0] + p[1] * dir[1] > far) {
        far = p[0] * dir[0] + p[1] * dir[1];
        o = .{ p[0], p[1], zmin };
    };
    // The axis: the side of dir is on its right (see `rollAbout`).
    if (!rollAbout(pts, &c, o, .{ -dir[1], dir[0], 0 }, &s)) return s;
    try rollOn(a, pts, &c, &s);
    return s;
}

/// A point of the mesh within this height (mm) of its lowest point is on
/// the bed.
const settle_eps = 0.05;

fn pointsOf(a: Allocator, mesh: *const Mesh) Allocator.Error![]V {
    // The points of the convex hull are enough, but all points work.
    const vs = mesh.vertices.items;
    const pts = try a.alloc(V, vs.len);
    for (vs, pts) |v, *p| p.* = .{ v.x, v.y, v.z };
    return pts;
}

/// Rolls the points `pts` (center of mass `c`) until they rest, and adds
/// each roll to `s`.
fn rollOn(a: Allocator, pts: []V, c: *V, s: *Settle) Allocator.Error!void {
    while (s.rolls < 24) {
        var edge: [2]V = undefined;
        const m = try footMargin(a, pts, c.*, settle_eps, &edge);
        if (m >= -1e-3) break;
        if (!rollAbout(pts, c, edge[0], edge[1], s)) break;
    }
}

/// Turns the points about the axis through `o` with direction `k` so that
/// the side to the right of the axis (cross(k, z)) goes down, by the least
/// angle that brings another point to the bed. False: no point comes
/// down (the turn does not end).
fn rollAbout(pts: []V, c: *V, o: V, k: V, s: *Settle) bool {
    const eps = settle_eps;
    const out = cross(k, V{ 0, 0, 1 });
    var best: f64 = std.math.pi;
    for (pts) |p| {
        const r = sub(p, o);
        // The part of r at right angles to the axis: across (in the
        // bed, away from the foot) and up.
        const along = dot(r, k);
        const q = V{ r[0] - along * k[0], r[1] - along * k[1], r[2] };
        const u = dot(q, out);
        const w = q[2];
        // A point behind the axis (u < 0) needs more than 90 degrees.
        if (w < eps) continue;
        best = @min(best, std.math.atan2(w, u));
    }
    if (best >= std.math.pi - 1e-9) return false;
    // The sign: turning by +t about k must lower the side of `out`.
    var r = rotation(k, best);
    const test_p = mulV(r, out);
    if (test_p[2] > 0) r = rotation(k, -best);
    for (pts) |*p| p.* = add3(mulV(r, sub(p.*, o)), o);
    c.* = add3(mulV(r, sub(c.*, o)), o);
    s.rot = mulM(r, s.rot);
    s.rolls += 1;
    s.degrees += std.math.radiansToDegrees(best);
    return true;
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

test "a part on a post stands on a prop under its far end, and not on a prop on the other side" {
    const gpa = testing.allocator;
    // A post of 2 x 2 mm, 5 mm high, under a slab of 20 x 4 mm that hangs
    // out 14 mm to the right: the center of mass is past the post.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 2, 2, 5);
    try mesh_mod.shapes.addBox(&b, -4, -1, 5, 16, 3, 9);
    var m = try b.finish();
    defer m.deinit(gpa);
    try testing.expect(try holdMargin(gpa, &m, &.{}) < 0);
    // A prop under the far end holds it.
    try testing.expect(try holdMargin(gpa, &m, &.{.{ 14, 1 }}) > 0);
    // A prop on the other side does not.
    try testing.expect(try holdMargin(gpa, &m, &.{.{ -3, 1 }}) < 0);
}

test "physics: a pin knocked over toward +x lies on its side there" {
    const gpa = testing.allocator;
    var m = try boxMesh(gpa, 0, 0, 0, 4, 4, 40);
    defer m.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), (try settle(gpa, &m)).rolls);
    const s = try knock(gpa, &m, .{ 1, 0 });
    try testing.expectApproxEqAbs(@as(f64, 90), s.degrees, 0.5);
    // At rest it is 4 mm high, and it lies toward +x.
    var zmax: f64 = -1e9;
    var zmin: f64 = 1e9;
    var xmax: f64 = -1e9;
    for (m.vertices.items) |v| {
        const q = mulV(s.rot, .{ v.x, v.y, v.z });
        zmax = @max(zmax, q[2]);
        zmin = @min(zmin, q[2]);
        xmax = @max(xmax, q[0]);
    }
    try testing.expectApproxEqAbs(@as(f64, 4), zmax - zmin, 0.01);
    try testing.expect(xmax > 30);
}
