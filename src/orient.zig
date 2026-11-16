//! The best orientation of a part: the turn that puts it on the bed with
//! the least area that needs support.
//!
//! The candidates are the six axis directions and the directions of the
//! largest flat areas of the mesh (face normals, grouped). For each
//! candidate, the part is turned so that the direction points down. The
//! cost is the area of the faces that need support (they face down more
//! than the support angle allows, and they are not on the bed), less half
//! the area on the bed (adhesion), plus the height (a tie-break: a lower
//! part prints faster and is more stable). This is the method of "auto
//! orientation" in other slicers (for example the Tweaker method in Cura
//! and PrusaSlicer, see REFERENCES.md); the code is new.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

const V = [3]f64;

fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn cross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn dot(a: V, b: V) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn len(a: V) f64 {
    return @sqrt(dot(a, a));
}
fn vec(v: mesh_mod.Vec3) V {
    return .{ v.x, v.y, v.z };
}

/// A rotation matrix (rows) that turns the unit vector `d` to (0, 0, -1).
pub fn downMatrix(d: V) [3]V {
    const down = V{ 0, 0, -1 };
    const c = dot(d, down);
    if (c > 1 - 1e-12) return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    // d is up: a half turn around x.
    if (c < -1 + 1e-12) return .{ .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 0, -1 } };
    const axis_raw = cross(d, down);
    const s = len(axis_raw);
    const k = V{ axis_raw[0] / s, axis_raw[1] / s, axis_raw[2] / s };
    // Rodrigues: R = I + sin K + (1 - cos) K^2.
    const t = 1 - c;
    return .{
        .{ c + k[0] * k[0] * t, k[0] * k[1] * t - k[2] * s, k[0] * k[2] * t + k[1] * s },
        .{ k[1] * k[0] * t + k[2] * s, c + k[1] * k[1] * t, k[1] * k[2] * t - k[0] * s },
        .{ k[2] * k[0] * t - k[1] * s, k[2] * k[1] * t + k[0] * s, c + k[2] * k[2] * t },
    };
}

fn mul(m: [3]V, p: V) V {
    return .{ dot(m[0], p), dot(m[1], p), dot(m[2], p) };
}

pub const Score = struct {
    dir: V,
    overhang: f64,
    contact: f64,
    height: f64,
    cost: f64,
};

/// The cost of the orientation that puts `d` down.
pub fn score(mesh: *const Mesh, d: V, support_angle: f64) Score {
    const m = downMatrix(d);
    // The lowest point in the turned part, and the height.
    var zlo: f64 = std.math.inf(f64);
    var zhi: f64 = -std.math.inf(f64);
    for (mesh.vertices.items) |v| {
        const z = dot(m[2], vec(v));
        zlo = @min(zlo, z);
        zhi = @max(zhi, z);
    }
    // A face needs support if its normal is nearer to down than the
    // support angle from the horizontal: -n_z > sin(angle).
    const limit = @sin(std.math.degreesToRadians(support_angle));
    var overhang: f64 = 0;
    var contact: f64 = 0;
    const on_bed = 0.05;
    for (mesh.faces.items) |f| {
        const a = vec(mesh.vertices.items[f[0]]);
        const b = vec(mesh.vertices.items[f[1]]);
        const c = vec(mesh.vertices.items[f[2]]);
        const n = cross(sub(b, a), sub(c, a));
        const l = len(n);
        if (l == 0) continue;
        const area = l / 2;
        const nz = dot(m[2], n) / l;
        if (-nz <= limit) continue;
        const za = dot(m[2], a) - zlo;
        const zb = dot(m[2], b) - zlo;
        const zc = dot(m[2], c) - zlo;
        if (za < on_bed and zb < on_bed and zc < on_bed) {
            contact += area;
        } else {
            overhang += area * -nz;
        }
    }
    const height = zhi - zlo;
    return .{ .dir = d, .overhang = overhang, .contact = contact, .height = height, .cost = overhang - 0.5 * contact + height };
}

/// The direction to put down for the least support. The first candidate
/// is the current orientation, and a new one must be clearly better, so a
/// part that is good as it is stays as it is.
pub fn best(gpa: Allocator, mesh: *const Mesh, support_angle: f64) Allocator.Error!Score {
    return bestAlong(gpa, mesh, support_angle, null);
}

/// As `best`, for a part that must be strong along the unit vector
/// `axis`: a printed part is weakest across its layers, so the axis must
/// lie in the plane of the layers. Only the directions at a right angle to
/// the axis can go down: the candidates of `best` that are, and 24
/// directions around the axis.
pub fn bestAlong(gpa: Allocator, mesh: *const Mesh, support_angle: f64, axis: ?V) Allocator.Error!Score {
    var cands: std.ArrayList(V) = .empty;
    defer cands.deinit(gpa);
    try cands.appendSlice(gpa, &.{ .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } });
    // The normals of the largest flat areas: group the faces by their
    // normal (rounded), and add up the area of each group.
    var groups: std.AutoHashMapUnmanaged([3]i32, struct { n: V, area: f64 }) = .empty;
    defer groups.deinit(gpa);
    for (mesh.faces.items) |f| {
        const a = vec(mesh.vertices.items[f[0]]);
        const n = cross(sub(vec(mesh.vertices.items[f[1]]), a), sub(vec(mesh.vertices.items[f[2]]), a));
        const l = len(n);
        if (l == 0) continue;
        const u = V{ n[0] / l, n[1] / l, n[2] / l };
        const key = [3]i32{ @intFromFloat(@round(u[0] * 50)), @intFromFloat(@round(u[1] * 50)), @intFromFloat(@round(u[2] * 50)) };
        const gop = try groups.getOrPut(gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .n = .{ 0, 0, 0 }, .area = 0 };
        gop.value_ptr.n = .{ gop.value_ptr.n[0] + n[0] / 2, gop.value_ptr.n[1] + n[1] / 2, gop.value_ptr.n[2] + n[2] / 2 };
        gop.value_ptr.area += l / 2;
    }
    const Group = struct { n: V, area: f64 };
    var list: std.ArrayList(Group) = .empty;
    defer list.deinit(gpa);
    var it = groups.valueIterator();
    while (it.next()) |g| try list.append(gpa, .{ .n = g.n, .area = g.area });
    std.mem.sort(Group, list.items, {}, struct {
        fn gt(_: void, a: Group, b: Group) bool {
            return a.area > b.area;
        }
    }.gt);
    for (list.items[0..@min(list.items.len, 24)]) |g| {
        const l = len(g.n);
        if (l == 0) continue;
        try cands.append(gpa, .{ g.n[0] / l, g.n[1] / l, g.n[2] / l });
    }
    if (axis) |ax| {
        // Keep only the candidates at a right angle to the axis, and add a
        // ring of directions around it.
        var kept: usize = 0;
        for (cands.items) |d| if (@abs(dot(d, ax)) < 0.05) {
            cands.items[kept] = d;
            kept += 1;
        };
        cands.items.len = kept;
        // Two unit vectors at right angles to the axis.
        const helper: V = if (@abs(ax[2]) < 0.9) .{ 0, 0, 1 } else .{ 1, 0, 0 };
        const c1 = cross(ax, helper);
        const l1 = len(c1);
        const e1 = V{ c1[0] / l1, c1[1] / l1, c1[2] / l1 };
        const e2 = cross(ax, e1);
        for (0..24) |k| {
            const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 24.0;
            try cands.append(gpa, .{ e1[0] * @cos(t) + e2[0] * @sin(t), e1[1] * @cos(t) + e2[1] * @sin(t), e1[2] * @cos(t) + e2[2] * @sin(t) });
        }
        // No "keep as it is" rule: the part must turn if it is not strong
        // along the axis now.
        var top = score(mesh, cands.items[0], support_angle);
        for (cands.items[1..]) |d| {
            const s = score(mesh, d, support_angle);
            if (s.cost < top.cost) top = s;
        }
        return top;
    }
    var top = score(mesh, cands.items[0], support_angle);
    const keep = top.cost;
    for (cands.items[1..]) |d| {
        const s = score(mesh, d, support_angle);
        if (s.cost < top.cost) top = s;
    }
    // Keep the file orientation unless the new one saves 1 % of the cost
    // (or 1 mm2).
    if (keep - top.cost < @max(1, @abs(keep) * 0.01)) return score(mesh, cands.items[0], support_angle);
    return top;
}

/// Turns the mesh so that `d` points down.
pub fn apply(mesh: *Mesh, d: V) void {
    const m = downMatrix(d);
    for (mesh.vertices.items) |*v| {
        const p = mul(m, vec(v.*));
        v.* = .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]), .z = @floatCast(p[2]) };
    }
}

const testing = std.testing;

test "orient: a T stands on its top bar" {
    // A T shape upside down: a thin post on the bed, with a wide bar on
    // top. The bar needs support. Turned over, it stands on the bar.
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 20);
    try mesh_mod.shapes.addBox(&b, 0, 0, 20, 20, 20, 24);
    var m = try b.finish();
    defer m.deinit(gpa);
    const s = try best(gpa, &m, 50);
    try testing.expectApproxEqAbs(@as(f64, 1), s.dir[2], 1e-6);
    // The top face of the post is inside the bar (the two boxes are not
    // joined), so 16 mm2 is left.
    try testing.expect(s.overhang < 17);
    apply(&m, s.dir);
    const bb = m.bounds();
    // The bar is at the bottom now: the part is 20 wide at its lowest z.
    try testing.expectApproxEqAbs(@as(f64, 24), bb.max[2] - bb.min[2], 1e-6);

    // A box is good as it is.
    var b2: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b2, 0, 0, 0, 30, 20, 10);
    var box = try b2.finish();
    defer box.deinit(gpa);
    const s2 = try best(gpa, &box, 50);
    try testing.expectApproxEqAbs(@as(f64, -1), s2.dir[2], 1e-6);
}

test "orient: the down matrix" {
    const ds = [_]V{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 }, .{ 0.6, 0, 0.8 } };
    for (ds) |d| {
        const p = mul(downMatrix(d), d);
        try testing.expectApproxEqAbs(@as(f64, 0), p[0], 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0), p[1], 1e-9);
        try testing.expectApproxEqAbs(@as(f64, -1), p[2], 1e-9);
    }
}

test "orient: strong along x keeps x in the layers" {
    // A long bar along z (a post): strong along z means it lies down.
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 5, 5, 40);
    var m = try b.finish();
    defer m.deinit(gpa);
    const s = try bestAlong(gpa, &m, 50, .{ 0, 0, 1 });
    // The down direction is at a right angle to z.
    try testing.expect(@abs(s.dir[2]) < 0.05);
    try testing.expectApproxEqAbs(@as(f64, 5), s.height, 0.01);
}
