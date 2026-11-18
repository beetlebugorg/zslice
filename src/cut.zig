//! A cut of a mesh with a horizontal plane at z: two closed meshes, the
//! part below the plane and the part above it, each with a cap on the cut.
//!
//! 1. Each triangle goes to the side of its vertices. A triangle that
//!    crosses the plane splits at the two points where its edges cross: a
//!    triangle on the side of its lone vertex, and two triangles on the
//!    other side. A vertex on the plane counts as above it.
//! 2. Each split gives a segment of the cut. The segments join into loops
//!    at their end points (the same float values, so the caps share the
//!    vertices of the split triangles, and the meshes stay closed).
//! 3. The loops nest: a loop inside an even count of loops is an outline,
//!    and the others are holes. Each outline gets its holes, a bridge
//!    from each hole to the outline makes one polygon, and ear clipping
//!    makes the triangles of the cap (as the "earcut" method, which joins
//!    holes the same way). The cap of the lower part faces up, the cap of
//!    the upper part faces down.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vec3 = mesh_mod.Vec3;

pub const Result = struct {
    below: Mesh,
    above: Mesh,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.below.deinit(gpa);
        r.above.deinit(gpa);
    }
};

const P2 = [2]f32;

fn key(p: Vec3) u64 {
    const x: u32 = @bitCast(p.x);
    const y: u32 = @bitCast(p.y);
    return (@as(u64, x) << 32) | y;
}

/// The point where the edge a-b crosses the plane z. The same edge gives the
/// same point from both of its triangles (the order of a and b is fixed).
fn cross(a0: Vec3, b0: Vec3, z: f32) Vec3 {
    // A fixed order: the lower vertex first.
    const lo_first = a0.z < b0.z or (a0.z == b0.z and (a0.x < b0.x or (a0.x == b0.x and a0.y < b0.y)));
    const a = if (lo_first) a0 else b0;
    const b = if (lo_first) b0 else a0;
    const t = (z - a.z) / (b.z - a.z);
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t, .z = z };
}

/// Cuts `mesh` at height z. Either result can be empty (all of the mesh on
/// one side).
pub fn cutZ(gpa: Allocator, mesh: Mesh, z_in: f64) Allocator.Error!Result {
    const z: f32 = @floatCast(z_in);
    var below: mesh_mod.Builder = .init(gpa);
    defer below.deinit();
    var above: mesh_mod.Builder = .init(gpa);
    defer above.deinit();
    // The segments of the cut, as the lower mesh sees them: a, then b.
    var segs: std.ArrayList([2]Vec3) = .empty;
    defer segs.deinit(gpa);
    const vs = mesh.vertices.items;
    for (mesh.faces.items) |f| {
        const t = [3]Vec3{ vs[f[0]], vs[f[1]], vs[f[2]] };
        const up = [3]bool{ t[0].z >= z, t[1].z >= z, t[2].z >= z };
        const n_up = @as(u8, @intFromBool(up[0])) + @intFromBool(up[1]) + @intFromBool(up[2]);
        if (n_up == 3) {
            addTri(&above, t[0], t[1], t[2]);
            continue;
        }
        if (n_up == 0) {
            addTri(&below, t[0], t[1], t[2]);
            continue;
        }
        // The lone vertex: the one on its own side. Turn the triangle so it
        // is first (the winding stays).
        const lone_up = n_up == 1;
        var k: usize = 0;
        while (up[k] != lone_up) k += 1;
        const a = t[k];
        const b = t[(k + 1) % 3];
        const c = t[(k + 2) % 3];
        const pab = cross(a, b, z);
        const pac = cross(a, c, z);
        const lone_side = if (lone_up) &above else &below;
        const other = if (lone_up) &below else &above;
        addTri(lone_side, a, pab, pac);
        addTri(other, pab, b, c);
        addTri(other, pab, c, pac);
        // The segment on the lower mesh: its edge on the cut runs from pac
        // to pab when the lone vertex is below (a, pab, pac winds the lower
        // piece), and from pab to pac when it is above.
        try segs.append(gpa, if (lone_up) .{ pab, pac } else .{ pac, pab });
    }
    try capCut(gpa, segs.items, z, &below, &above);
    return .{ .below = try finishOrEmpty(&below), .above = try finishOrEmpty(&above) };
}

fn addTri(b: *mesh_mod.Builder, p: Vec3, q: Vec3, r: Vec3) void {
    // Drop a triangle with no area (a vertex on the plane).
    if ((p.x == q.x and p.y == q.y and p.z == q.z) or (q.x == r.x and q.y == r.y and q.z == r.z) or (p.x == r.x and p.y == r.y and p.z == r.z)) return;
    b.addTriangle(p, q, r) catch {};
}

fn finishOrEmpty(b: *mesh_mod.Builder) Allocator.Error!Mesh {
    return b.finish() catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => .empty,
    };
}

/// Joins the segments into loops, and adds the caps.
fn capCut(gpa: Allocator, segs: []const [2]Vec3, z: f32, below: *mesh_mod.Builder, above: *mesh_mod.Builder) Allocator.Error!void {
    if (segs.len == 0) return;
    var next: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer next.deinit(gpa);
    for (segs, 0..) |s, i| try next.put(gpa, key(s[0]), i);
    const used = try gpa.alloc(bool, segs.len);
    defer gpa.free(used);
    @memset(used, false);
    var loops: std.ArrayList([]P2) = .empty;
    defer {
        for (loops.items) |l| gpa.free(l);
        loops.deinit(gpa);
    }
    for (segs, 0..) |_, start| {
        if (used[start]) continue;
        var pts: std.ArrayList(P2) = .empty;
        errdefer pts.deinit(gpa);
        var i = start;
        while (!used[i]) {
            used[i] = true;
            try pts.append(gpa, .{ segs[i][0].x, segs[i][0].y });
            i = next.get(key(segs[i][1])) orelse break;
        }
        if (pts.items.len >= 3) try loops.append(gpa, try pts.toOwnedSlice(gpa)) else pts.deinit(gpa);
    }
    // The depth of each loop: the count of loops around it.
    const depth = try gpa.alloc(usize, loops.items.len);
    defer gpa.free(depth);
    for (loops.items, 0..) |l, i| {
        depth[i] = 0;
        for (loops.items, 0..) |o, j| if (i != j and inside(o, l[0])) {
            depth[i] += 1;
        };
    }
    for (loops.items, 0..) |outer, i| {
        if (depth[i] % 2 != 0) continue;
        // An outline counterclockwise, its holes clockwise.
        var poly: std.ArrayList(P2) = .empty;
        defer poly.deinit(gpa);
        try poly.appendSlice(gpa, outer);
        if (area(poly.items) < 0) std.mem.reverse(P2, poly.items);
        // The holes of this outline: one level deeper, inside it.
        var holes: std.ArrayList([]P2) = .empty;
        defer {
            for (holes.items) |h| gpa.free(h);
            holes.deinit(gpa);
        }
        for (loops.items, 0..) |h, j| {
            if (depth[j] != depth[i] + 1 or !inside(outer, h[0])) continue;
            const c = try gpa.dupe(P2, h);
            if (area(c) > 0) std.mem.reverse(P2, c);
            try holes.append(gpa, c);
        }
        // The holes from the right: each bridge then stays clear of the
        // holes joined before it.
        std.mem.sort([]P2, holes.items, {}, struct {
            fn lt(_: void, a: []P2, b: []P2) bool {
                return maxX(a) > maxX(b);
            }
        }.lt);
        for (holes.items) |h| try bridge(gpa, &poly, h);
        var tris: std.ArrayList([3]P2) = .empty;
        defer tris.deinit(gpa);
        try earClip(gpa, poly.items, &tris);
        for (tris.items) |t| {
            const a = Vec3{ .x = t[0][0], .y = t[0][1], .z = z };
            const b = Vec3{ .x = t[1][0], .y = t[1][1], .z = z };
            const c = Vec3{ .x = t[2][0], .y = t[2][1], .z = z };
            // Counterclockwise from above: faces up, the top of the lower part.
            addTri(below, a, b, c);
            addTri(above, a, c, b);
        }
    }
}

fn area(p: []const P2) f64 {
    var s: f64 = 0;
    for (p, 0..) |a, i| {
        const b = p[(i + 1) % p.len];
        s += @as(f64, a[0]) * b[1] - @as(f64, b[0]) * a[1];
    }
    return s / 2;
}

fn maxX(p: []const P2) f32 {
    var m: f32 = -std.math.inf(f32);
    for (p) |q| m = @max(m, q[0]);
    return m;
}

fn inside(poly: []const P2, q: P2) bool {
    var in = false;
    var j = poly.len - 1;
    for (poly, 0..) |a, i| {
        const b = poly[j];
        if ((a[1] > q[1]) != (b[1] > q[1]) and q[0] < (b[0] - a[0]) * (q[1] - a[1]) / (b[1] - a[1]) + a[0]) in = !in;
        j = i;
    }
    return in;
}

/// Joins a hole into the polygon: from the rightmost point of the hole to
/// the nearest point of the polygon to its right that it can see, and back.
fn bridge(gpa: Allocator, poly: *std.ArrayList(P2), hole: []const P2) Allocator.Error!void {
    var hi: usize = 0;
    for (hole, 0..) |q, i| if (q[0] > hole[hi][0]) {
        hi = i;
    };
    const m = hole[hi];
    // The nearest polygon vertex to the right of m whose segment to m
    // crosses no edge of the polygon.
    var best: ?usize = null;
    var best_d: f32 = std.math.inf(f32);
    for (poly.items, 0..) |p, i| {
        if (p[0] < m[0]) continue;
        const d = (p[0] - m[0]) * (p[0] - m[0]) + (p[1] - m[1]) * (p[1] - m[1]);
        if (d >= best_d) continue;
        if (crossesAny(poly.items, m, p, i)) continue;
        best = i;
        best_d = d;
    }
    // No clear vertex: the nearest vertex (a cap with a flaw is better than
    // no cap).
    const at = best orelse blk: {
        var k: usize = 0;
        var kd: f32 = std.math.inf(f32);
        for (poly.items, 0..) |p, i| {
            const d = (p[0] - m[0]) * (p[0] - m[0]) + (p[1] - m[1]) * (p[1] - m[1]);
            if (d < kd) {
                kd = d;
                k = i;
            }
        }
        break :blk k;
    };
    // poly[0..at], poly[at], hole from hi around to hi, poly[at], poly[at+1..]
    var out: std.ArrayList(P2) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, poly.items[0 .. at + 1]);
    for (0..hole.len + 1) |k| try out.append(gpa, hole[(hi + k) % hole.len]);
    try out.appendSlice(gpa, poly.items[at..]);
    poly.deinit(gpa);
    poly.* = out;
}

fn segCross(a: P2, b: P2, c: P2, d: P2) bool {
    const o = struct {
        fn f(p: P2, q: P2, r: P2) f32 {
            return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
        }
    }.f;
    const d1 = o(c, d, a);
    const d2 = o(c, d, b);
    const d3 = o(a, b, c);
    const d4 = o(a, b, d);
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

fn crossesAny(poly: []const P2, a: P2, b: P2, skip: usize) bool {
    for (poly, 0..) |p, i| {
        const j = (i + 1) % poly.len;
        if (i == skip or j == skip) continue;
        if (segCross(a, b, p, poly[j])) return true;
    }
    return false;
}

/// Ear clipping of a simple counterclockwise polygon (holes joined by
/// bridges). O(n²) for each ear: the caps of a cut are small.
fn earClip(gpa: Allocator, poly: []const P2, out: *std.ArrayList([3]P2)) Allocator.Error!void {
    var idx: std.ArrayList(usize) = .empty;
    defer idx.deinit(gpa);
    for (0..poly.len) |i| try idx.append(gpa, i);
    var guard: usize = 0;
    var i: usize = 0;
    while (idx.items.len > 3 and guard < idx.items.len * 4 + 16) {
        const n = idx.items.len;
        const a = poly[idx.items[(i + n - 1) % n]];
        const b = poly[idx.items[i % n]];
        const c = poly[idx.items[(i + 1) % n]];
        if (isEar(poly, idx.items, a, b, c)) {
            try out.append(gpa, .{ a, b, c });
            _ = idx.orderedRemove(i % n);
            guard = 0;
            if (i > 0) i -= 1;
        } else {
            i = (i + 1) % n;
            guard += 1;
        }
    }
    if (idx.items.len == 3) try out.append(gpa, .{ poly[idx.items[0]], poly[idx.items[1]], poly[idx.items[2]] });
}

fn isEar(poly: []const P2, idx: []const usize, a: P2, b: P2, c: P2) bool {
    // Convex at b (counterclockwise).
    const turn = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    if (turn <= 0) return false;
    for (idx) |k| {
        const p = poly[k];
        if (eq(p, a) or eq(p, b) or eq(p, c)) continue;
        if (inTri(p, a, b, c)) return false;
    }
    return true;
}

fn eq(p: P2, q: P2) bool {
    return p[0] == q[0] and p[1] == q[1];
}

fn inTri(p: P2, a: P2, b: P2, c: P2) bool {
    const s1 = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
    const s2 = (c[0] - b[0]) * (p[1] - b[1]) - (c[1] - b[1]) * (p[0] - b[0]);
    const s3 = (a[0] - c[0]) * (p[1] - c[1]) - (a[1] - c[1]) * (p[0] - c[0]);
    return s1 >= 0 and s2 >= 0 and s3 >= 0;
}

// ---- tests ----

const testing = std.testing;

/// The volume of a closed mesh (the divergence theorem); positive for
/// outward faces.
fn volume(m: Mesh) f64 {
    var v: f64 = 0;
    for (m.faces.items) |f| {
        const a = m.vertices.items[f[0]];
        const b = m.vertices.items[f[1]];
        const c = m.vertices.items[f[2]];
        v += (@as(f64, a.x) * (@as(f64, b.y) * c.z - @as(f64, b.z) * c.y) - @as(f64, a.y) * (@as(f64, b.x) * c.z - @as(f64, b.z) * c.x) + @as(f64, a.z) * (@as(f64, b.x) * c.y - @as(f64, b.y) * c.x)) / 6;
    }
    return v;
}

/// True if each edge of the mesh has exactly one face on each side.
fn closed(gpa: Allocator, m: Mesh) !bool {
    var edges: std.AutoHashMapUnmanaged([2]u32, i32) = .empty;
    defer edges.deinit(gpa);
    for (m.faces.items) |f| for (0..3) |k| {
        const a = f[k];
        const b = f[(k + 1) % 3];
        const e = if (a < b) [2]u32{ a, b } else [2]u32{ b, a };
        const g = try edges.getOrPut(gpa, e);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += if (a < b) 1 else -1;
    };
    var it = edges.valueIterator();
    while (it.next()) |v| if (v.* != 0) return false;
    return true;
}

test "cut: a box at half its height" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 10, 20, 30);
    var m = try b.finish();
    defer m.deinit(gpa);
    var r = try cutZ(gpa, m, 12);
    defer r.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 10 * 20 * 12), volume(r.below), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 10 * 20 * 18), volume(r.above), 1e-3);
    try testing.expect(try closed(gpa, r.below));
    try testing.expect(try closed(gpa, r.above));
}

test "cut: a tube has a cap with a hole" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addTube(&b, 0, 0, 10, 6, 0, 20, 48);
    var m = try b.finish();
    defer m.deinit(gpa);
    const whole = volume(m);
    var r = try cutZ(gpa, m, 5);
    defer r.deinit(gpa);
    try testing.expectApproxEqRel(whole * 0.25, volume(r.below), 1e-3);
    try testing.expectApproxEqRel(whole * 0.75, volume(r.above), 1e-3);
    try testing.expect(try closed(gpa, r.below));
    try testing.expect(try closed(gpa, r.above));
}

test "cut: a plane under the mesh leaves it whole" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 1, 10, 10, 5);
    var m = try b.finish();
    defer m.deinit(gpa);
    var r = try cutZ(gpa, m, 0.5);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.below.faces.items.len);
    try testing.expectEqual(@as(usize, 12), r.above.faces.items.len);
}
