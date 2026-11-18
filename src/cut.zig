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
//! Pegs (`Pegs`): to join the two parts after the print, the cut can put
//! holes for pegs in both caps. Each hole goes into the solid of each part
//! as a closed well (a ring wall and an end disc), and the pegs print as
//! parts of their own. A peg goes only where its hole, with a wall around
//! it, lies inside the solid of the cut, and the depth of each well stops
//! 1 mm before the next surface of the mesh under or over the cut.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Vec3 = mesh_mod.Vec3;

/// The pegs of a cut.
pub const Pegs = struct {
    /// The count: 0 none, or the most to place (the largest outline of the
    /// cut gets them, as far apart as possible).
    count: u8 = 0,
    /// The diameter of a peg, mm.
    diameter: f64 = 5,
    /// The gap between a peg and its hole, mm (on the radius).
    clearance: f64 = 0.15,
    /// The most depth of a hole in each part, mm.
    depth: f64 = 8,
};

/// A placed peg: its center on the cut, and the depth of its hole in each
/// part (mm). A peg for the plate is a cylinder of the peg diameter and
/// the length below + above - 1 mm.
pub const Peg = struct { x: f64, y: f64, below: f64, above: f64 };

pub const Result = struct {
    below: Mesh,
    above: Mesh,
    /// The pegs that the cut placed (gpa), or empty.
    pegs: []Peg = &.{},

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.below.deinit(gpa);
        r.above.deinit(gpa);
        gpa.free(r.pegs);
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
    return cutZPegs(gpa, mesh, z_in, .{});
}

/// `cutZ`, with holes for pegs.
pub fn cutZPegs(gpa: Allocator, mesh: Mesh, z_in: f64, pegs: Pegs) Allocator.Error!Result {
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
    const placed = try capCut(gpa, segs.items, z, &below, &above, mesh, pegs);
    errdefer gpa.free(placed);
    return .{ .below = try finishOrEmpty(&below), .above = try finishOrEmpty(&above), .pegs = placed };
}

const peg_sides = 24;

/// The distance from (x, y, z) along -z (down < 0) or +z to the nearest
/// face of the mesh, or inf.
fn rayDist(mesh: Mesh, x: f32, y: f32, z: f32, up: bool) f32 {
    var best: f32 = std.math.inf(f32);
    const vs = mesh.vertices.items;
    for (mesh.faces.items) |f| {
        const a = vs[f[0]];
        const b = vs[f[1]];
        const c = vs[f[2]];
        // The point (x, y) in the triangle, seen from above.
        const d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
        if (d == 0) continue;
        const l0 = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / d;
        const l1 = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / d;
        const l2 = 1 - l0 - l1;
        if (l0 < 0 or l1 < 0 or l2 < 0) continue;
        const fz = l0 * a.z + l1 * b.z + l2 * c.z;
        const dist = if (up) fz - z else z - fz;
        if (dist > 1e-4 and dist < best) best = dist;
    }
    return best;
}

/// The distance from q to the polygon edges.
fn edgeDist(poly: []const P2, q: P2) f32 {
    var best: f32 = std.math.inf(f32);
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        const l2 = ex * ex + ey * ey;
        const t = if (l2 > 0) std.math.clamp(((q[0] - a[0]) * ex + (q[1] - a[1]) * ey) / l2, 0, 1) else 0;
        const dx = a[0] + ex * t - q[0];
        const dy = a[1] + ey * t - q[1];
        best = @min(best, @sqrt(dx * dx + dy * dy));
    }
    return best;
}

/// The places of the pegs in an outline with its holes: the points of a
/// grid where a hole of radius r and a wall of 2 mm fit, as far apart as
/// possible (the first two: the farthest pair).
fn pegPlaces(gpa: Allocator, outer: []const P2, holes: []const []P2, r: f32, count: u8) Allocator.Error![]P2 {
    var lo = P2{ std.math.inf(f32), std.math.inf(f32) };
    var hi = P2{ -std.math.inf(f32), -std.math.inf(f32) };
    for (outer) |q| {
        lo = .{ @min(lo[0], q[0]), @min(lo[1], q[1]) };
        hi = .{ @max(hi[0], q[0]), @max(hi[1], q[1]) };
    }
    const keep = r + 2;
    var cands: std.ArrayList(P2) = .empty;
    defer cands.deinit(gpa);
    const step: f32 = @max(1, @max(hi[0] - lo[0], hi[1] - lo[1]) / 40);
    var y = lo[1] + keep;
    while (y <= hi[1] - keep) : (y += step) {
        var x = lo[0] + keep;
        while (x <= hi[0] - keep) : (x += step) {
            const q = P2{ x, y };
            if (!inside(outer, q) or edgeDist(outer, q) < keep) continue;
            var ok = true;
            for (holes) |h| if (inside(h, q) or edgeDist(h, q) < keep) {
                ok = false;
            };
            if (ok) try cands.append(gpa, q);
        }
    }
    var out: std.ArrayList(P2) = .empty;
    errdefer out.deinit(gpa);
    if (cands.items.len == 0 or count == 0) return out.toOwnedSlice(gpa);
    // The farthest pair, then each next point farthest from the chosen.
    var best_d: f32 = -1;
    var pa: usize = 0;
    var pb: usize = 0;
    for (cands.items, 0..) |a, i| for (cands.items[i + 1 ..], i + 1..) |b, j| {
        const d = (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]);
        if (d > best_d) {
            best_d = d;
            pa = i;
            pb = j;
        }
    };
    try out.append(gpa, cands.items[pa]);
    if (count >= 2 and pb != pa and best_d >= (2 * keep) * (2 * keep)) try out.append(gpa, cands.items[pb]);
    while (out.items.len < count) {
        var far: f32 = -1;
        var at: usize = 0;
        for (cands.items, 0..) |c, i| {
            var m: f32 = std.math.inf(f32);
            for (out.items) |o| m = @min(m, (c[0] - o[0]) * (c[0] - o[0]) + (c[1] - o[1]) * (c[1] - o[1]));
            if (m > far) {
                far = m;
                at = i;
            }
        }
        if (far < (2 * keep) * (2 * keep)) break;
        try out.append(gpa, cands.items[at]);
    }
    return out.toOwnedSlice(gpa);
}

/// The ring of a peg hole, clockwise (a hole).
fn pegRing(c: P2, r: f32) [peg_sides]P2 {
    var out: [peg_sides]P2 = undefined;
    for (&out, 0..) |*q, k| {
        const a = -2 * std.math.pi * @as(f32, @floatFromInt(k)) / peg_sides;
        q.* = .{ c[0] + r * @cos(a), c[1] + r * @sin(a) };
    }
    return out;
}

/// The well of a peg hole in one part: the ring wall from the cut at z to
/// z + dz (dz < 0: down into the lower part), and the end disc. The faces
/// point into the hole.
fn addWell(b: *mesh_mod.Builder, ring: []const P2, c: P2, z: f32, dz: f32) void {
    const end = z + dz;
    for (ring, 0..) |p, k| {
        const q = ring[(k + 1) % ring.len];
        // The ring is clockwise from above.
        const tp = Vec3{ .x = p[0], .y = p[1], .z = z };
        const tq = Vec3{ .x = q[0], .y = q[1], .z = z };
        const ep = Vec3{ .x = p[0], .y = p[1], .z = end };
        const eq_ = Vec3{ .x = q[0], .y = q[1], .z = end };
        const mid = Vec3{ .x = c[0], .y = c[1], .z = end };
        if (dz < 0) {
            addTri(b, tp, ep, eq_);
            addTri(b, tp, eq_, tq);
            // The floor faces up: counterclockwise from above.
            addTri(b, mid, eq_, ep);
        } else {
            addTri(b, tp, eq_, ep);
            addTri(b, tp, tq, eq_);
            // The roof faces down.
            addTri(b, mid, ep, eq_);
        }
    }
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

/// Joins the segments into loops, and adds the caps (with the holes and
/// the wells of the pegs). Returns the pegs, in gpa.
fn capCut(gpa: Allocator, segs: []const [2]Vec3, z: f32, below: *mesh_mod.Builder, above: *mesh_mod.Builder, mesh: Mesh, pegs: Pegs) Allocator.Error![]Peg {
    var placed: std.ArrayList(Peg) = .empty;
    errdefer placed.deinit(gpa);
    if (segs.len == 0) return placed.toOwnedSlice(gpa);
    const hole_r: f32 = @floatCast(pegs.diameter / 2 + pegs.clearance);
    // The pegs go into the largest outline.
    var largest: ?usize = null;
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
    if (pegs.count > 0) {
        var big: f64 = 0;
        for (loops.items, 0..) |l, i| if (depth[i] % 2 == 0 and @abs(area(l)) > big) {
            big = @abs(area(l));
            largest = i;
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
        // The pegs of this outline: a hole in the cap and a well in each
        // part, where the depth allows.
        if (largest == i) {
            const spots = try pegPlaces(gpa, outer, holes.items, hole_r, pegs.count);
            defer gpa.free(spots);
            for (spots) |c| {
                var dn: f32 = @floatCast(pegs.depth);
                var upd: f32 = @floatCast(pegs.depth);
                const probe = [_]P2{ c, .{ c[0] + hole_r, c[1] }, .{ c[0] - hole_r, c[1] }, .{ c[0], c[1] + hole_r }, .{ c[0], c[1] - hole_r } };
                for (probe) |q| {
                    dn = @min(dn, rayDist(mesh, q[0], q[1], z, false) - 1);
                    upd = @min(upd, rayDist(mesh, q[0], q[1], z, true) - 1);
                }
                if (dn < 2 or upd < 2) continue;
                const ring = pegRing(c, hole_r);
                const h = try gpa.dupe(P2, &ring);
                try holes.append(gpa, h);
                addWell(below, &ring, c, z, -dn);
                addWell(above, &ring, c, z, upd);
                try placed.append(gpa, .{ .x = c[0], .y = c[1], .below = dn, .above = upd });
            }
            std.mem.sort([]P2, holes.items, {}, struct {
                fn lt(_: void, a: []P2, b: []P2) bool {
                    return maxX(a) > maxX(b);
                }
            }.lt);
        }
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
    return placed.toOwnedSlice(gpa);
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

test "cut: pegs in a box" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 60, 30, 40);
    var m = try b.finish();
    defer m.deinit(gpa);
    var r = try cutZPegs(gpa, m, 20, .{ .count = 2, .diameter = 5, .depth = 8 });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), r.pegs.len);
    try testing.expectApproxEqAbs(@as(f64, 8), r.pegs[0].below, 1e-4);
    // The pegs are far apart along the long side.
    try testing.expect(@abs(r.pegs[0].x - r.pegs[1].x) > 30);
    // Both parts stay closed, and lose the volume of the wells.
    try testing.expect(try closed(gpa, r.below));
    try testing.expect(try closed(gpa, r.above));
    const well = std.math.pi * 2.65 * 2.65 * 8 * 2;
    try testing.expect(volume(r.below) < 60 * 30 * 20 - well * 0.9 and volume(r.below) > 60 * 30 * 20 - well * 1.1);
}

test "cut: no peg where the part is thin" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 60, 30, 4);
    var m = try b.finish();
    defer m.deinit(gpa);
    // 2 mm under and over the cut: a hole of 2 - 1 mm is too short.
    var r = try cutZPegs(gpa, m, 2, .{ .count = 2 });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.pegs.len);
}

