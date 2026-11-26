//! A rigid-body engine for the parts on the bed: a part that cannot stand
//! falls, rolls, and comes to rest as a real solid does, and the view can
//! show each step of the fall.
//!
//! - **Mass.** The volume, the center of mass, and the inertia tensor of
//!   the closed mesh, from the signed tetrahedra of its faces with the
//!   origin (the method of D. Eberly, "Polyhedral Mass Properties"; see
//!   docs/references/physics-and-materials.md). The density is even: the walls and the infill differ,
//!   but the fall depends on the shape far more than on the infill.
//! - **Shape.** The points of the convex hull that touch the bed: the
//!   vertices of the mesh that are the farthest in 642 even directions (an
//!   icosphere). A part rests on its convex hull, and a flat face or a
//!   corner is always one of these points.
//! - **Solver.** Sequential impulses (E. Catto, "Iterative Dynamics with
//!   Temporal Coherence", GDC 2005; see docs/references/physics-and-materials.md): each contact with
//!   the bed gets a normal impulse and two friction impulses, the sums
//!   clamped (the normal sum at 0 or more, the friction in the cone of the
//!   normal sum), and a small push out of the bed (Baumgarte). The step is
//!   fixed (1/240 s), so a run is the same on each machine.
//! - **Rest.** A body sleeps when its speed stays low for 0.3 s. The units
//!   are mm, s, and the mass of 1 mm³ (the density cancels out).
//!
//! The world has one static plane, the bed (z = 0), and the bodies on it.
//! Contact between bodies is the next step (GJK and EPA on the hulls).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mesh = @import("mesh.zig").Mesh;

pub const V = [3]f64;
/// A rotation: w, x, y, z.
pub const Q = [4]f64;
pub const M3 = [3]V;

pub const gravity: f64 = 9810; // mm/s²
pub const step_dt: f64 = 1.0 / 240.0;
const iterations = 12;
const friction: f64 = 0.6;
/// The push out of the bed per step: this share of the depth.
const baumgarte: f64 = 0.2;
/// A depth this small (mm) gets no push, so a body at rest does not
/// jitter.
const slop: f64 = 0.005;
/// A point this close over the bed (mm) is a contact.
const margin: f64 = 0.02;
/// Sleep: speeds under these for `sleep_time`.
const sleep_v: f64 = 2; // mm/s
const sleep_w: f64 = 0.05; // rad/s
const sleep_time: f64 = 0.3;

fn add(a: V, b: V) V {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn scale(a: V, s: f64) V {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
fn dot(a: V, b: V) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn len(a: V) f64 {
    return @sqrt(dot(a, a));
}
fn mulMV(m: M3, v: V) V {
    return .{ dot(m[0], v), dot(m[1], v), dot(m[2], v) };
}
fn transpose(m: M3) M3 {
    return .{ .{ m[0][0], m[1][0], m[2][0] }, .{ m[0][1], m[1][1], m[2][1] }, .{ m[0][2], m[1][2], m[2][2] } };
}
fn mulMM(a: M3, b: M3) M3 {
    const bt = transpose(b);
    var r: M3 = undefined;
    for (0..3) |i| for (0..3) |j| {
        r[i][j] = dot(a[i], bt[j]);
    };
    return r;
}

fn inverse(m: M3) ?M3 {
    const c0 = cross(m[1], m[2]);
    const det = dot(m[0], c0);
    if (@abs(det) < 1e-30) return null;
    const c1 = cross(m[2], m[0]);
    const c2 = cross(m[0], m[1]);
    // The rows of the inverse are the columns of the cofactors.
    return transpose(.{ scale(c0, 1 / det), scale(c1, 1 / det), scale(c2, 1 / det) });
}

pub fn quatMul(a: Q, b: Q) Q {
    return .{
        a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
        a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
        a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
        a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
    };
}

fn quatNorm(q: Q) Q {
    const n = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return .{ q[0] / n, q[1] / n, q[2] / n, q[3] / n };
}

/// The rotation matrix (rows) of a unit quaternion.
pub fn quatMat(q: Q) M3 {
    const w = q[0];
    const x = q[1];
    const y = q[2];
    const z = q[3];
    return .{
        .{ 1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y) },
        .{ 2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x) },
        .{ 2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y) },
    };
}

/// The mass of a closed mesh of even density 1: its volume, center of
/// mass, and inertia tensor about the center of mass (Eberly).
pub const Mass = struct { volume: f64, center: V, inertia: M3 };

pub fn massOf(mesh: *const Mesh) Mass {
    // The integrals of 1, x, y, z, x², y², z², xy, yz, zx.
    var in = @as([10]f64, @splat(0));
    const vs = mesh.vertices.items;
    for (mesh.faces.items) |f| {
        const p0 = V{ vs[f[0]].x, vs[f[0]].y, vs[f[0]].z };
        const p1 = V{ vs[f[1]].x, vs[f[1]].y, vs[f[1]].z };
        const p2 = V{ vs[f[2]].x, vs[f[2]].y, vs[f[2]].z };
        const d = cross(sub(p1, p0), sub(p2, p0));
        var f1: V = undefined;
        var f2: V = undefined;
        var f3: V = undefined;
        var g0: V = undefined;
        var g1: V = undefined;
        var g2: V = undefined;
        for (0..3) |k| {
            const w0 = p0[k];
            const w1 = p1[k];
            const w2 = p2[k];
            const t0 = w0 + w1;
            const t1 = w0 * w0;
            const t2 = t1 + w1 * t0;
            f1[k] = t0 + w2;
            f2[k] = t2 + w2 * f1[k];
            f3[k] = w0 * t1 + w1 * t2 + w2 * f2[k];
            g0[k] = f2[k] + w0 * (f1[k] + w0);
            g1[k] = f2[k] + w1 * (f1[k] + w1);
            g2[k] = f2[k] + w2 * (f1[k] + w2);
        }
        in[0] += d[0] * f1[0];
        in[1] += d[0] * f2[0];
        in[2] += d[1] * f2[1];
        in[3] += d[2] * f2[2];
        in[4] += d[0] * f3[0];
        in[5] += d[1] * f3[1];
        in[6] += d[2] * f3[2];
        in[7] += d[0] * (p0[1] * g0[0] + p1[1] * g1[0] + p2[1] * g2[0]);
        in[8] += d[1] * (p0[2] * g0[1] + p1[2] * g1[1] + p2[2] * g2[1]);
        in[9] += d[2] * (p0[0] * g0[2] + p1[0] * g1[2] + p2[0] * g2[2]);
    }
    const mult = [_]f64{ 1.0 / 6.0, 1.0 / 24.0, 1.0 / 24.0, 1.0 / 24.0, 1.0 / 60.0, 1.0 / 60.0, 1.0 / 60.0, 1.0 / 120.0, 1.0 / 120.0, 1.0 / 120.0 };
    for (&in, mult) |*x, m| x.* *= m;
    const vol = in[0];
    if (!(@abs(vol) > 1e-12)) return .{ .volume = 0, .center = .{ 0, 0, 0 }, .inertia = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } } };
    const c = V{ in[1] / vol, in[2] / vol, in[3] / vol };
    // The inertia about the center of mass.
    const xx = in[5] + in[6] - vol * (c[1] * c[1] + c[2] * c[2]);
    const yy = in[4] + in[6] - vol * (c[2] * c[2] + c[0] * c[0]);
    const zz = in[4] + in[5] - vol * (c[0] * c[0] + c[1] * c[1]);
    const xy = -(in[7] - vol * c[0] * c[1]);
    const yz = -(in[8] - vol * c[1] * c[2]);
    const xz = -(in[9] - vol * c[2] * c[0]);
    return .{ .volume = vol, .center = c, .inertia = .{ .{ xx, xy, xz }, .{ xy, yy, yz }, .{ xz, yz, zz } } };
}

/// The 642 directions of an icosphere of 3 subdivisions, made once.
fn directions(a: Allocator) Allocator.Error![]V {
    const t = (1.0 + @sqrt(5.0)) / 2.0;
    var pts: std.ArrayList(V) = .empty;
    const base = [_]V{
        .{ -1, t, 0 }, .{ 1, t, 0 }, .{ -1, -t, 0 }, .{ 1, -t, 0 },
        .{ 0, -1, t }, .{ 0, 1, t }, .{ 0, -1, -t }, .{ 0, 1, -t },
        .{ t, 0, -1 }, .{ t, 0, 1 }, .{ -t, 0, -1 }, .{ -t, 0, 1 },
    };
    for (base) |p| try pts.append(a, scale(p, 1 / len(p)));
    var tris: std.ArrayList([3]u32) = .empty;
    try tris.appendSlice(a, &.{
        .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
        .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
        .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
        .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
    });
    for (0..3) |_| {
        var mid: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        var next: std.ArrayList([3]u32) = .empty;
        for (tris.items) |tr| {
            var m: [3]u32 = undefined;
            for (0..3) |k| {
                const x = tr[k];
                const y = tr[(k + 1) % 3];
                const key = (@as(u64, @min(x, y)) << 32) | @max(x, y);
                const g = try mid.getOrPut(a, key);
                if (!g.found_existing) {
                    const p = scale(add(pts.items[x], pts.items[y]), 0.5);
                    try pts.append(a, scale(p, 1 / len(p)));
                    g.value_ptr.* = @intCast(pts.items.len - 1);
                }
                m[k] = g.value_ptr.*;
            }
            try next.appendSlice(a, &.{ .{ tr[0], m[0], m[2] }, .{ tr[1], m[1], m[0] }, .{ tr[2], m[2], m[1] }, .{ m[0], m[1], m[2] } });
        }
        tris = next;
    }
    return pts.items;
}

pub const Grab = struct {
    local: V,
    target: V,
    /// The orientation that the hand holds: a part in the hand does not
    /// swing, and turns when the hand turns (turnHand).
    rot: Q = .{ 1, 0, 0, 0 },
    /// The spring: its frequency (Hz) and damping ratio.
    hz: f64 = 15,
    damping: f64 = 0.9,
};

fn skew(v: V) M3 {
    return .{ .{ 0, -v[2], v[1] }, .{ v[2], 0, -v[0] }, .{ -v[1], v[0], 0 } };
}

/// A rigid body on the bed.
pub const Body = struct {
    /// The points of the hull, in the body frame (from the center of
    /// mass), in gpa.
    points: []V,
    inv_mass: f64,
    /// The inverse inertia tensor in the body frame.
    inv_inertia: M3,
    /// The place of the center of mass and the turn of the body.
    pos: V,
    rot: Q,
    vel: V = .{ 0, 0, 0 },
    ang: V = .{ 0, 0, 0 },
    still: f64 = 0,
    asleep: bool = false,
    /// The impulse sums of each point in the last step (normal, x, y): a
    /// step starts from them (warm start), so the contacts of a body at
    /// rest do not fight each other, and it comes to rest.
    acc: [][3]f64,
    /// A grab of the user: a point of the body (in its frame, from the
    /// center of mass) that a soft spring pulls toward `target`, as a hand
    /// holds a part (the mouse joint of Box2D, in 3D). The body swings and
    /// turns about the point, and keeps its speed when the hand lets go.
    grab: ?Grab = null,

    /// A body from a mesh in the bed frame (its pose and place applied):
    /// the turn starts at none, so `rot` is the turn from the mesh.
    pub fn init(gpa: Allocator, mesh: *const Mesh) Allocator.Error!Body {
        const m = massOf(mesh);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const dirs = try directions(a);
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var pts: std.ArrayList(V) = .empty;
        const vs = mesh.vertices.items;
        // The farthest vertex in each direction: the vertices in the outer
        // loop, and 8 directions at a time in vectors. One direction at a
        // time over all vertices of a large part (an STL has 3 vertices
        // for each face) was a 30 ms stall at each grab.
        const lanes = 8;
        const VF = @Vector(lanes, f32);
        const VU = @Vector(lanes, u32);
        const groups = (dirs.len + lanes - 1) / lanes;
        const dx = try a.alloc(VF, groups);
        const dy = try a.alloc(VF, groups);
        const dz = try a.alloc(VF, groups);
        const best_d = try a.alloc(VF, groups);
        const best_i = try a.alloc(VU, groups);
        for (0..groups) |g| {
            var x: [lanes]f32 = @splat(0);
            var y: [lanes]f32 = @splat(0);
            var z: [lanes]f32 = @splat(0);
            for (0..lanes) |k| if (g * lanes + k < dirs.len) {
                const d = dirs[g * lanes + k];
                x[k] = @floatCast(d[0]);
                y[k] = @floatCast(d[1]);
                z[k] = @floatCast(d[2]);
            };
            dx[g] = x;
            dy[g] = y;
            dz[g] = z;
            best_d[g] = @splat(-std.math.inf(f32));
            best_i[g] = @splat(0);
        }
        for (vs, 0..) |v, i| {
            const vx: VF = @splat(@floatCast(v.x));
            const vy: VF = @splat(@floatCast(v.y));
            const vz: VF = @splat(@floatCast(v.z));
            const iv: VU = @splat(@intCast(i));
            for (0..groups) |g| {
                const e = dx[g] * vx + dy[g] * vy + dz[g] * vz;
                const more = e > best_d[g];
                best_d[g] = @select(f32, more, e, best_d[g]);
                best_i[g] = @select(u32, more, iv, best_i[g]);
            }
        }
        for (0..dirs.len) |di| {
            const row: [lanes]u32 = best_i[di / lanes];
            const best = row[di % lanes];
            if ((try seen.getOrPut(a, best)).found_existing) continue;
            const v = vs[best];
            try pts.append(a, sub(.{ v.x, v.y, v.z }, m.center));
        }
        const vol = @max(m.volume, 1e-9);
        const acc = try gpa.alloc([3]f64, pts.items.len);
        @memset(acc, .{ 0, 0, 0 });
        return .{
            .acc = acc,
            .points = try gpa.dupe(V, pts.items),
            .inv_mass = 1 / vol,
            .inv_inertia = inverse(m.inertia) orelse .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
            .pos = m.center,
            .rot = .{ 1, 0, 0, 0 },
        };
    }

    pub fn deinit(b: *Body, gpa: Allocator) void {
        gpa.free(b.points);
        gpa.free(b.acc);
    }

    fn invInertiaWorld(b: *const Body) M3 {
        const r = quatMat(b.rot);
        return mulMM(mulMM(r, b.inv_inertia), transpose(r));
    }

    /// One step of the fall on the bed (z = 0).
    /// Holds point `at` of the body (in the bed frame now) and pulls it to
    /// `target`.
    pub fn grabAt(b: *Body, at: V, target: V) void {
        const r = quatMat(b.rot);
        b.grab = .{ .local = mulMV(transpose(r), sub(at, b.pos)), .target = target, .rot = b.rot };
        b.wake();
    }

    /// Turns the orientation that the hand holds by `deg` degrees about
    /// the axis (in the bed frame).
    pub fn turnHand(b: *Body, axis: V, deg: f64) void {
        const g = &(b.grab orelse return);
        const l = len(axis);
        if (!(l > 0)) return;
        const h = std.math.degreesToRadians(deg) / 2;
        const k = @sin(h) / l;
        g.rot = quatNorm(quatMul(.{ @cos(h), axis[0] * k, axis[1] * k, axis[2] * k }, g.rot));
        b.wake();
    }

    pub fn wake(b: *Body) void {
        b.asleep = false;
        b.still = 0;
    }

    /// Tips the body over toward `dir` (a unit vector on the bed), as a
    /// push from the side does: a spin about the edge of its foot on that
    /// side. The spin has 1.2 times the speed that just lifts the center
    /// of mass over the edge (its energy m g h equals the lift).
    pub fn tip(b: *Body, dir: [2]f64) void {
        const r = quatMat(b.rot);
        var zmin: f64 = std.math.inf(f64);
        for (b.points) |p| zmin = @min(zmin, b.pos[2] + dot(r[2], p));
        // The pivot: the lowest point farthest toward dir.
        var o: V = b.pos;
        var far: f64 = -std.math.inf(f64);
        for (b.points) |p| {
            const w = add(b.pos, mulMV(r, p));
            if (w[2] > zmin + margin + 0.05) continue;
            const e = w[0] * dir[0] + w[1] * dir[1];
            if (e > far) {
                far = e;
                o = .{ w[0], w[1], zmin };
            }
        }
        // The axis: a turn about k moves the top toward dir.
        const k: V = .{ -dir[1], dir[0], 0 };
        const arm = sub(b.pos, o);
        const across = sub(arm, scale(k, dot(arm, k)));
        const lift = len(across) - across[2];
        // The moment of inertia about the edge: about the center of
        // mass, plus m d².
        const m = 1 / b.inv_mass;
        const inertia = inverse(b.invInertiaWorld()) orelse return;
        const i_edge = dot(k, mulMV(inertia, k)) + m * dot(across, across);
        if (!(i_edge > 0)) return;
        const w = 1.2 * @sqrt(2 * m * gravity * @max(lift, 0) / i_edge);
        b.ang = scale(k, w);
        b.vel = cross(b.ang, arm);
        b.wake();
    }

    pub fn step(b: *Body, dt: f64) void {
        if (b.asleep) return;
        b.vel[2] -= gravity * dt;
        const r = quatMat(b.rot);
        const iw = b.invInertiaWorld();
        // The grab: the soft constraint of the hand (Box2D, b2MouseJoint):
        // gamma softens it, beta pulls the point to the target, and the
        // force is at most 50 times the weight.
        var g_arm: V = .{ 0, 0, 0 };
        var g_mass: M3 = undefined;
        var g_bias: V = .{ 0, 0, 0 };
        var g_gamma: f64 = 0;
        var g_acc: V = .{ 0, 0, 0 };
        const g_max = 50 * gravity / b.inv_mass * dt;
        if (b.grab) |g| {
            const m = 1 / b.inv_mass;
            const omega = 2 * std.math.pi * g.hz;
            const k = m * omega * omega;
            const c = 2 * m * g.damping * omega;
            g_gamma = 1 / (dt * (c + dt * k));
            const beta = dt * k * g_gamma;
            g_arm = mulMV(r, g.local);
            const err = sub(add(b.pos, g_arm), g.target);
            g_bias = scale(err, beta);
            // K = 1/m I - [r] Iw [r] + gamma I.
            const sk = skew(g_arm);
            const kr = mulMM(mulMM(sk, iw), sk);
            var km: M3 = undefined;
            for (0..3) |i| for (0..3) |j| {
                km[i][j] = -kr[i][j] + (if (i == j) b.inv_mass + g_gamma else 0);
            };
            g_mass = inverse(km) orelse .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
        }
        // The contacts: the hull points at or under the bed.
        var arms: [64]V = undefined;
        var depth: [64]f64 = undefined;
        var which: [64]usize = undefined;
        var n: usize = 0;
        const tz = V{ 0, 0, 1 };
        const tx = V{ 1, 0, 0 };
        const ty = V{ 0, 1, 0 };
        for (b.points, b.acc, 0..) |p, *acc, pi| {
            const arm = mulMV(r, p);
            const z = b.pos[2] + arm[2];
            if (z > margin or n == arms.len) {
                acc.* = .{ 0, 0, 0 };
                continue;
            }
            arms[n] = arm;
            depth[n] = -z;
            which[n] = pi;
            n += 1;
            // The warm start: the impulses of the last step at this point.
            b.applyImpulse(iw, arm, .{ acc[1], acc[2], acc[0] });
        }
        // The hand holds the orientation: in each pass the turn speed is the
        // one that closes the turn to the held orientation in 1/30 s.
        var hold_ang: ?V = null;
        if (b.grab) |g| {
            var e = quatMul(g.rot, .{ b.rot[0], -b.rot[1], -b.rot[2], -b.rot[3] });
            if (e[0] < 0) e = .{ -e[0], -e[1], -e[2], -e[3] };
            hold_ang = .{ 2 * e[1] * 30, 2 * e[2] * 30, 2 * e[3] * 30 };
        }
        for (0..iterations) |_| {
            if (hold_ang) |w| b.ang = w;
            if (b.grab != null) {
                const cdot = add(b.vel, cross(b.ang, g_arm));
                var imp = mulMV(g_mass, scale(add(add(cdot, g_bias), scale(g_acc, g_gamma)), -1));
                const old = g_acc;
                g_acc = add(g_acc, imp);
                const l = len(g_acc);
                if (l > g_max) g_acc = scale(g_acc, g_max / l);
                imp = sub(g_acc, old);
                b.applyImpulse(iw, g_arm, imp);
            }
            for (0..n) |k| {
                const arm = arms[k];
                // The normal.
                {
                    const vrel = add(b.vel, cross(b.ang, arm));
                    const rn = cross(arm, tz);
                    const k_n = b.inv_mass + dot(rn, mulMV(iw, rn));
                    const bias = baumgarte / dt * @max(depth[k] - slop, 0);
                    var lambda = (-vrel[2] + bias) / k_n;
                    const acc = &b.acc[which[k]];
                    const old = acc[0];
                    acc[0] = @max(old + lambda, 0);
                    lambda = acc[0] - old;
                    b.applyImpulse(iw, arm, scale(tz, lambda));
                }
                // The friction, in x and in y, in the cone of the normal.
                for ([_]V{ tx, ty }, 0..) |t, j| {
                    const vrel = add(b.vel, cross(b.ang, arm));
                    const rt = cross(arm, t);
                    const k_t = b.inv_mass + dot(rt, mulMV(iw, rt));
                    var lambda = -dot(vrel, t) / k_t;
                    const acc = &b.acc[which[k]];
                    const lim = friction * acc[0];
                    const old = acc[1 + j];
                    acc[1 + j] = std.math.clamp(old + lambda, -lim, lim);
                    lambda = acc[1 + j] - old;
                    b.applyImpulse(iw, arm, scale(t, lambda));
                }
            }
        }
        // The hand damps the motion of a part that it holds.
        if (b.grab != null) b.vel = scale(b.vel, @exp(-4 * dt));
        // The motion.
        b.pos = add(b.pos, scale(b.vel, dt));
        const w = b.ang;
        const dq = quatMul(.{ 0, w[0], w[1], w[2] }, b.rot);
        b.rot = quatNorm(.{ b.rot[0] + 0.5 * dt * dq[0], b.rot[1] + 0.5 * dt * dq[1], b.rot[2] + 0.5 * dt * dq[2], b.rot[3] + 0.5 * dt * dq[3] });
        // Sleep, never while the hand holds it.
        if (b.grab == null and n > 0 and len(b.vel) < sleep_v and len(b.ang) < sleep_w) {
            b.still += dt;
            if (b.still >= sleep_time) {
                b.asleep = true;
                b.vel = .{ 0, 0, 0 };
                b.ang = .{ 0, 0, 0 };
            }
        } else b.still = 0;
    }

    fn applyImpulse(b: *Body, iw: M3, arm: V, j: V) void {
        b.vel = add(b.vel, scale(j, b.inv_mass));
        b.ang = add(b.ang, mulMV(iw, cross(arm, j)));
    }

    /// The direction in the frame of the mesh at the start that points
    /// down now: the side of the part on the bed.
    pub fn down(b: *const Body) V {
        return mulMV(transpose(quatMat(b.rot)), .{ 0, 0, -1 });
    }

    /// The lowest z of the hull now (mm).
    pub fn lowest(b: *const Body) f64 {
        const r = quatMat(b.rot);
        var lo = std.math.inf(f64);
        for (b.points) |p| lo = @min(lo, b.pos[2] + mulMV(r, p)[2]);
        return lo;
    }
};

/// Runs a fall until the body sleeps, or for `max_s` seconds. Returns the
/// time it took.
pub fn settle(b: *Body, max_s: f64) f64 {
    var t: f64 = 0;
    while (!b.asleep and t < max_s) : (t += step_dt) b.step(step_dt);
    return t;
}

const testing = std.testing;
const shapes = @import("mesh.zig").shapes;
const Builder = @import("mesh.zig").Builder;

fn box(gpa: Allocator, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) !Mesh {
    var b: Builder = .init(gpa);
    try shapes.addBox(&b, x0, y0, z0, x1, y1, z1);
    return b.finish();
}

fn turnX(m: *Mesh, deg: f64) void {
    const c = @cos(std.math.degreesToRadians(deg));
    const s = @sin(std.math.degreesToRadians(deg));
    var lo: f32 = std.math.inf(f32);
    for (m.vertices.items) |*v| {
        const y = v.y;
        const z = v.z;
        v.y = @floatCast(c * y - s * z);
        v.z = @floatCast(s * y + c * z);
        lo = @min(lo, v.z);
    }
    for (m.vertices.items) |*v| v.z -= lo;
}

test "rigid: the mass of a box" {
    var m = try box(testing.allocator, 0, 0, 0, 2, 4, 6);
    defer m.deinit(testing.allocator);
    const ms = massOf(&m);
    try testing.expectApproxEqAbs(@as(f64, 48), ms.volume, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), ms.center[2], 1e-9);
    // Ixx = V (b² + c²) / 12 for a box of sides a, b, c.
    try testing.expectApproxEqAbs(48.0 * (16.0 + 36.0) / 12.0, ms.inertia[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0), ms.inertia[0][1], 1e-6);
}

test "rigid: a box on a face stays where it is" {
    const gpa = testing.allocator;
    var m = try box(gpa, 0, 0, 0, 20, 20, 10);
    defer m.deinit(gpa);
    var b = try Body.init(gpa, &m);
    defer b.deinit(gpa);
    const t = settle(&b, 3);
    try testing.expect(b.asleep);
    try testing.expect(t < 1);
    try testing.expectApproxEqAbs(@as(f64, 0), b.lowest(), 0.02);
    try testing.expectApproxEqAbs(@as(f64, 10), b.pos[0], 0.01);
    const d = b.down();
    try testing.expectApproxEqAbs(@as(f64, -1), d[2], 1e-4);
}

test "rigid: a board on an edge falls flat" {
    const gpa = testing.allocator;
    var m = try box(gpa, 0, 0, 0, 40, 10, 4);
    defer m.deinit(gpa);
    turnX(&m, 40);
    var b = try Body.init(gpa, &m);
    defer b.deinit(gpa);
    _ = settle(&b, 5);
    try testing.expect(b.asleep);
    try testing.expectApproxEqAbs(@as(f64, 0), b.lowest(), 0.02);
    // It lies on a large face: its down side is a face normal of the box,
    // so it is flat (one axis of the frame of the box points down).
    const d = b.down();
    const flat = @max(@abs(d[1]), @abs(d[2]));
    const c = @cos(std.math.degreesToRadians(40.0));
    const s = @sin(std.math.degreesToRadians(40.0));
    // The box axes y and z, turned by 40 degrees about x.
    const ay = V{ 0, c, s };
    const az = V{ 0, -s, c };
    const best = @max(@abs(dot(d, ay)), @abs(dot(d, az)));
    _ = flat;
    try testing.expect(best > 0.999);
}

test "rigid: a tall block tipped past its balance falls; short of it, it stands" {
    const gpa = testing.allocator;
    // A block 10 x 10 x 40: it balances at 14 degrees (atan(5 / 20)).
    for ([_]struct { deg: f64, falls: bool }{ .{ .deg = 8, .falls = false }, .{ .deg = 20, .falls = true } }) |c| {
        var m = try box(gpa, 0, 0, 0, 10, 10, 40);
        defer m.deinit(gpa);
        turnX(&m, c.deg);
        var b = try Body.init(gpa, &m);
        defer b.deinit(gpa);
        _ = settle(&b, 6);
        try testing.expect(b.asleep);
        const d = b.down();
        const s = @sin(std.math.degreesToRadians(c.deg));
        const co = @cos(std.math.degreesToRadians(c.deg));
        const bottom = V{ 0, s, -co }; // the bottom face normal of the block
        const on_bottom = dot(d, bottom) > 0.999;
        try testing.expectEqual(!c.falls, on_bottom);
    }
}

test "rigid: a pin tipped toward +x falls over that way and lies flat" {
    const gpa = testing.allocator;
    var m = try box(gpa, 0, 0, 0, 4, 4, 40);
    defer m.deinit(gpa);
    var b = try Body.init(gpa, &m);
    defer b.deinit(gpa);
    b.tip(.{ 1, 0 });
    _ = settle(&b, 8);
    try testing.expect(b.asleep);
    // It lies on a long face, toward +x.
    try testing.expectApproxEqAbs(@as(f64, 0), b.down()[2], 1e-3);
    try testing.expect(b.pos[2] < 2.1);
    try testing.expect(b.pos[0] > 15);
}

test "rigid: the same run gives the same result" {
    const gpa = testing.allocator;
    var m = try box(gpa, 0, 0, 0, 30, 8, 5);
    defer m.deinit(gpa);
    turnX(&m, 55);
    var b1 = try Body.init(gpa, &m);
    defer b1.deinit(gpa);
    var b2 = try Body.init(gpa, &m);
    defer b2.deinit(gpa);
    _ = settle(&b1, 5);
    _ = settle(&b2, 5);
    try testing.expectEqualSlices(f64, &b1.rot, &b2.rot);
    try testing.expectEqualSlices(f64, &b1.pos, &b2.pos);
}

test "rigid: a grab lifts a box to the hand, and on release it falls and rests" {
    const gpa = testing.allocator;
    var m = try box(gpa, 0, 0, 0, 20, 20, 10);
    defer m.deinit(gpa);
    var b = try Body.init(gpa, &m);
    defer b.deinit(gpa);
    // Hold a top corner and lift it 30 mm, and move it 40 mm in x.
    b.grabAt(.{ 20, 20, 10 }, .{ 60, 20, 40 });
    var t: f64 = 0;
    while (t < 2) : (t += step_dt) b.step(step_dt);
    const r = quatMat(b.rot);
    const held = add(b.pos, mulMV(r, b.grab.?.local));
    // The spring stretches under the weight (g / omega² = 1.1 mm), and
    // the hand holds the box level by its corner.
    try testing.expect(dist3(held, .{ 60, 20, 40 }) < 3);
    try testing.expect(b.down()[2] < -0.98);
    // The hand turns it 90 degrees about z: it follows.
    b.turnHand(.{ 0, 0, 1 }, 90);
    t = 0;
    while (t < 1) : (t += step_dt) b.step(step_dt);
    const ax = mulMV(quatMat(b.rot), .{ 1, 0, 0 });
    try testing.expect(ax[1] > 0.97);
    // Let go: it falls, and rests on a face.
    b.grab = null;
    _ = settle(&b, 6);
    try testing.expect(b.asleep);
    try testing.expectApproxEqAbs(@as(f64, 0), b.lowest(), 0.02);
    const d = b.down();
    const best = @max(@abs(d[0]), @max(@abs(d[1]), @abs(d[2])));
    try testing.expect(best > 0.999);
}

fn dist3(a: V, b: V) f64 {
    return len(sub(a, b));
}
