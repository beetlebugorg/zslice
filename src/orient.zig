//! The best orientation of a part: the turn that puts it on the bed with
//! the least area that needs support.
//!
//! The candidates are the six axis directions and the directions of the
//! largest flat areas of the mesh (face normals, grouped). For each
//! candidate, the part is turned so that the direction points down. The
//! cost is the sum of:
//!
//! - the area of the faces that need support (they face down more than the
//!   support angle allows, and they are not on the bed), weighted by how
//!   much they face down;
//! - less half the area on the bed (adhesion);
//! - the islands: each low point or low edge of the part that is not on
//!   the bed (all its neighbors are higher) starts in the air and needs a
//!   support column: 15 mm² for each, plus 3 mm² for each mm of its height
//!   over the bed. A part on an edge or a corner (turned 45°) has faces that
//!   need no support, but its low corners do;
//! - a small contact: when the area on the bed is less than 10 % of the
//!   footprint, the part stands on a thin edge and can fall over; the
//!   missing area counts;
//! - the height (a tie-break: a lower part prints faster and is more
//!   stable). This is the method of "auto
//! orientation" in other slicers (for example the Tweaker method in Cura
//! and PrusaSlicer, see docs/references/slicer-techniques.md); the code is new.

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
    /// The low points and edges that are not on the bed.
    islands: u32 = 0,
    /// The cost of the islands and of a small contact, in mm² (see the
    /// header).
    island_cost: f64 = 0,
    contact_cost: f64 = 0,
    cost: f64,
};

/// The neighbors of each vertex (the other vertices of its faces), for the
/// low points of `score`. It does not change with the orientation.
pub const Adjacency = struct {
    start: []u32,
    list: []u32,
    /// The normal of each vertex: the sum of the normals of its faces,
    /// weighted by their area (not unit length).
    normal: []V,
    /// For each vertex, how much its most downward face faces down (-n_z
    /// of the unit normal) in the orientation of the last score: a buffer
    /// of `scoreWith`.
    down: []f64,
    /// Buffers of the island search: a stack, and a stamp for each vertex
    /// (the search that saw it last).
    stack: []u32,
    seen: []u32,
    stamp: u32 = 0,

    pub fn init(gpa: Allocator, mesh: *const Mesh) Allocator.Error!Adjacency {
        const n = mesh.vertices.items.len;
        const start = try gpa.alloc(u32, n + 1);
        @memset(start, 0);
        for (mesh.faces.items) |f| for (f) |v| {
            start[v + 1] += 2;
        };
        for (1..n + 1) |i| start[i] += start[i - 1];
        const list = try gpa.alloc(u32, start[n]);
        const fill = try gpa.alloc(u32, n);
        defer gpa.free(fill);
        @memcpy(fill, start[0..n]);
        for (mesh.faces.items) |f| for (0..3) |k| {
            const v = f[k];
            list[fill[v]] = f[(k + 1) % 3];
            list[fill[v] + 1] = f[(k + 2) % 3];
            fill[v] += 2;
        };
        const normal = try gpa.alloc(V, n);
        @memset(normal, .{ 0, 0, 0 });
        for (mesh.faces.items) |f| {
            const a = vec(mesh.vertices.items[f[0]]);
            const fn_ = cross(sub(vec(mesh.vertices.items[f[1]]), a), sub(vec(mesh.vertices.items[f[2]]), a));
            for (f) |v| normal[v] = .{ normal[v][0] + fn_[0], normal[v][1] + fn_[1], normal[v][2] + fn_[2] };
        }
        const seen = try gpa.alloc(u32, n);
        @memset(seen, 0);
        return .{ .start = start, .list = list, .normal = normal, .down = try gpa.alloc(f64, n), .stack = try gpa.alloc(u32, n), .seen = seen };
    }

    pub fn deinit(a: *Adjacency, gpa: Allocator) void {
        gpa.free(a.start);
        gpa.free(a.list);
        gpa.free(a.normal);
        gpa.free(a.down);
        gpa.free(a.stack);
        gpa.free(a.seen);
    }

    fn of(a: Adjacency, v: usize) []const u32 {
        return a.list[a.start[v]..a.start[v + 1]];
    }
};

/// The cost of the orientation that puts `d` down. `adj` (the neighbors of
/// the vertices) and `zs` (one value for each vertex) are from the caller;
/// with no `adj`, the islands are not counted.
pub fn score(mesh: *const Mesh, d: V, support_angle: f64) Score {
    return scoreWith(mesh, null, &.{}, d, support_angle);
}

pub fn scoreWith(mesh: *const Mesh, adj_in: ?*Adjacency, zs: []f64, d: V, support_angle: f64) Score {
    const adj: ?Adjacency = if (adj_in) |a| a.* else null;
    const m = downMatrix(d);
    // The lowest point in the turned part, the height, and the footprint.
    var zlo: f64 = std.math.inf(f64);
    var zhi: f64 = -std.math.inf(f64);
    var xlo: f64 = std.math.inf(f64);
    var xhi: f64 = -std.math.inf(f64);
    var ylo: f64 = std.math.inf(f64);
    var yhi: f64 = -std.math.inf(f64);
    for (mesh.vertices.items, 0..) |v, i| {
        const p = mul(m, vec(v));
        zlo = @min(zlo, p[2]);
        zhi = @max(zhi, p[2]);
        xlo = @min(xlo, p[0]);
        xhi = @max(xhi, p[0]);
        ylo = @min(ylo, p[1]);
        yhi = @max(yhi, p[1]);
        if (i < zs.len) zs[i] = p[2];
    }
    // A face needs support if its normal is nearer to down than the
    // support angle from the horizontal: -n_z > sin(angle).
    const limit = @sin(std.math.degreesToRadians(support_angle));
    var overhang: f64 = 0;
    var contact: f64 = 0;
    const on_bed = 0.05;
    if (adj) |ad| @memset(ad.down, -1);
    for (mesh.faces.items) |f| {
        const a = vec(mesh.vertices.items[f[0]]);
        const b = vec(mesh.vertices.items[f[1]]);
        const c = vec(mesh.vertices.items[f[2]]);
        const n = cross(sub(b, a), sub(c, a));
        const l = len(n);
        if (l == 0) continue;
        const area = l / 2;
        const nz = dot(m[2], n) / l;
        if (adj) |ad| for (f) |v| {
            ad.down[v] = @max(ad.down[v], -nz);
        };
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
    var sc: Score = .{ .dir = d, .overhang = overhang, .contact = contact, .height = height, .cost = 0 };
    // The islands: the low points that are not on the bed. A low edge or a
    // low flat spot is many low vertices at one height: they count once
    // (the vertices of one island are joined by the neighbors at the same
    // height).
    if (adj_in) |ad| if (zs.len == mesh.vertices.items.len) {
        // A height difference under this is level: a part turned by a
        // fraction of a degree keeps its flat edges.
        const eps = 0.02;
        // How far up the search from a low point goes: a dip of the facets
        // of a curved surface that is shallower than this is no island.
        const rise = 0.3;
        for (0..zs.len) |i| {
            const z = zs[i];
            if (z - zlo < on_bed or ad.seen[i] == ad.stamp +% 1) continue;
            var low = true;
            for (ad.of(i)) |nb| if (zs[nb] < z - eps) {
                low = false;
                break;
            };
            if (!low) continue;
            // The surface at the point must face down: the plastic is above
            // it. The bottom of a hole is low too, but the plastic is under
            // it.
            const vn = ad.normal[i];
            const vl = len(vn);
            if (vl == 0 or dot(m[2], vn) / vl > -0.3) continue;
            // A low point on a face that needs support is in the overhang
            // area already. An island is a point or an edge whose faces all
            // need no support (a part on a corner or an edge).
            if (ad.down[i] > limit) continue;
            // Fill the surface from the point up to `rise` higher. A lower
            // point in reach: a ripple. The filled vertices are not low
            // points of their own (one island counts once).
            ad.stamp +%= 1;
            const st = ad.stamp;
            var top: usize = 0;
            ad.stack[0] = @intCast(i);
            top = 1;
            ad.seen[i] = st;
            var island = true;
            var steps: usize = 0;
            while (top > 0 and island) {
                top -= 1;
                const v = ad.stack[top];
                for (ad.of(v)) |nb| {
                    if (ad.seen[nb] == st) continue;
                    if (zs[nb] < z - eps) {
                        island = false;
                        break;
                    }
                    if (zs[nb] > z + rise) continue;
                    ad.seen[nb] = st;
                    ad.stack[top] = nb;
                    top += 1;
                }
                steps += 1;
                if (steps > 20000) break;
            }
            if (!island) continue;
            sc.islands += 1;
            sc.island_cost += 15 + 3 * (z - zlo);
        }
        // The next score starts with a new stamp.
        ad.stamp +%= 1;
    };
    const footprint = (xhi - xlo) * (yhi - ylo);
    sc.contact_cost = @max(0, 0.1 * footprint - contact);
    sc.cost = overhang - 0.5 * contact + sc.island_cost + sc.contact_cost + height;
    return sc;
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
    return search(gpa, mesh, support_angle, axis, .cost);
}

/// What a search compares: the full cost, or the overhang area first (the
/// cost breaks a tie of 1 mm²).
pub const By = enum { cost, overhang };

/// As `best`, with the order of `by`.
pub fn bestBy(gpa: Allocator, mesh: *const Mesh, support_angle: f64, by: By) Allocator.Error!Score {
    return search(gpa, mesh, support_angle, null, by);
}

fn better(a: Score, b: Score, by: By) bool {
    return switch (by) {
        .cost => a.cost < b.cost,
        .overhang => a.overhang < b.overhang - 1 or (@abs(a.overhang - b.overhang) <= 1 and a.cost < b.cost),
    };
}

fn search(gpa: Allocator, mesh: *const Mesh, support_angle: f64, axis: ?V, by: By) Allocator.Error!Score {
    var adj = try Adjacency.init(gpa, mesh);
    defer adj.deinit(gpa);
    const zs = try gpa.alloc(f64, mesh.vertices.items.len);
    defer gpa.free(zs);
    var cands: std.ArrayList(V) = .empty;
    defer cands.deinit(gpa);
    try candidates(gpa, mesh, axis, &cands);
    const sc = struct {
        fn f(mm: *const Mesh, a: *Adjacency, z: []f64, d: V, ang: f64) Score {
            return scoreWith(mm, a, z, d, ang);
        }
    }.f;
    if (axis != null) {
        // No "keep as it is" rule: the part must turn if it is not strong
        // along the axis now.
        var top = sc(mesh, &adj, zs, cands.items[0], support_angle);
        for (cands.items[1..]) |d| {
            const s2 = sc(mesh, &adj, zs, d, support_angle);
            if (better(s2, top, by)) top = s2;
        }
        return top;
    }
    var top = sc(mesh, &adj, zs, cands.items[0], support_angle);
    const keep = top.cost;
    for (cands.items[1..]) |d| {
        const s2 = sc(mesh, &adj, zs, d, support_angle);
        if (better(s2, top, by)) top = s2;
    }
    // Keep the file orientation unless the new one saves 1 % of the cost
    // (or 1 mm2).
    if (keep - top.cost < @max(1, @abs(keep) * 0.01)) return sc(mesh, &adj, zs, cands.items[0], support_angle);
    return top;
}

/// The candidate directions to put down: the file orientation first, the
/// six axis directions, and the normals of the largest flat areas. With an
/// axis, only the ones at a right angle to it, and a ring around it.
pub fn candidates(gpa: Allocator, mesh: *const Mesh, axis: ?V, cands: *std.ArrayList(V)) Allocator.Error!void {
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
    }
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
