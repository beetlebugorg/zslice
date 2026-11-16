//! Mesh slicing: cut the 3D mesh with horizontal planes and get the 2D
//! outline of each layer.
//!
//! For each layer:
//!
//! 1. The plane is at the middle of the layer height. The outline at the
//!    middle is the best estimate of the shape of the whole layer.
//! 2. Each triangle that crosses the plane gives one line segment. The code
//!    puts each vertex "above" (z > plane) or "below" (z <= plane). A vertex
//!    exactly on the plane is "below", so each crossing triangle has exactly
//!    two edges that cross, and the segment is never a point.
//! 3. The segment direction comes from the vertex order of the triangle. It
//!    goes from the edge that goes down through the plane to the edge that
//!    goes up. With outward normals, this makes outer loops
//!    counterclockwise and holes clockwise.
//! 4. Two triangles that share a mesh edge give segments that meet at the
//!    same point on that edge. The code joins the segments into loops by the
//!    edge ID (the two vertex indices), and not by the coordinates. An ID
//!    match is exact, and a coordinate match needs a tolerance.
//! 5. A mesh with holes gives open chains. The code joins the end of a chain
//!    to the nearest start of another chain, if it is near. A chain that
//!    stays open is removed.
//! 6. A union with the non-zero rule cleans the loops. It removes overlaps
//!    from meshes that intersect each other, and it turns loops from
//!    inside-out meshes the correct way.
//!
//! References (see REFERENCES.md): the cut plane at the middle of the
//! layer, joining segments by mesh edge ID, and the CSR layout of the face
//! index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const scratch = @import("scratch.zig");
const clip = @import("clip.zig");
const parallel = @import("parallel.zig");
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const Point = geom.Point;
const Paths = geom.Paths;

pub const Layer = struct {
    /// The z of the top of the layer, in mm. The nozzle prints at this z.
    z: f64,
    /// The layer height, in mm.
    height: f64,

    /// The z of the cut plane, in mm.
    pub fn sliceZ(self: Layer) f64 {
        return self.z - self.height / 2;
    }
};

/// Returns the layers for a part of height `part_height`, in mm.
pub fn layerTable(gpa: Allocator, part_height: f64, first_height: f64, height: f64) Allocator.Error![]Layer {
    var layers: std.ArrayList(Layer) = .empty;
    errdefer layers.deinit(gpa);
    if (part_height <= 0 or first_height <= 0 or height <= 0) return layers.toOwnedSlice(gpa);
    // Add a layer while its cut plane is inside the part. The z values come
    // from a multiply, and not from a sum, so that rounding errors do not
    // add up. The margin of 1 um makes a plane at the top of the part count
    // as outside: an STL stores float32 values, so a top at 0.4 mm is
    // 0.400000006 mm in the file.
    var i: usize = 0;
    while (true) : (i += 1) {
        const h = if (i == 0) first_height else height;
        const z = if (i == 0) first_height else first_height + @as(f64, @floatFromInt(i)) * height;
        if (z - h / 2 >= part_height - 1e-3) break;
        try layers.append(gpa, .{ .z = z, .height = h });
    }
    return layers.toOwnedSlice(gpa);
}

/// For each layer, the list of triangles that cross its plane. The lists
/// are in one array (compressed sparse rows): the triangles of layer i are
/// `items[starts[i]..starts[i + 1]]`. A triangle is only tested at the
/// planes that it crosses, so the cost of slicing all layers is close to
/// the number of segments.
pub const FaceIndex = struct {
    starts: []u32,
    items: []u32,

    pub fn deinit(self: *FaceIndex, gpa: Allocator) void {
        gpa.free(self.starts);
        gpa.free(self.items);
    }

    pub fn get(self: FaceIndex, layer: usize) []const u32 {
        return self.items[self.starts[layer]..self.starts[layer + 1]];
    }

    /// `z_offset` is the mesh z at print z = 0, and `z_scale` scales the
    /// mesh in z: print z = (mesh z - z_offset) * z_scale.
    pub fn build(gpa: Allocator, m: *const Mesh, layers: []const Layer, z_offset: f64) Allocator.Error!FaceIndex {
        return buildScaled(gpa, m, layers, z_offset, 1, 1);
    }

    /// `build`, with a z scale, on `threads` threads. The result is the
    /// same for each thread count.
    pub fn buildScaled(gpa: Allocator, m: *const Mesh, layers: []const Layer, z_offset: f64, z_scale: f64, threads: usize) Allocator.Error!FaceIndex {
        const starts = try gpa.alloc(u32, layers.len + 1);
        errdefer gpa.free(starts);
        @memset(starts, 0);
        if (layers.len == 0) return .{ .starts = starts, .items = try gpa.alloc(u32, 0) };

        // Three steps, each on all threads, in blocks of faces:
        // 1. The layer range of each face, and the face count of each layer
        //    in each block.
        // 2. The start of each layer, and of each block in each layer (a
        //    prefix sum, in layer order, then block order).
        // 3. Each block writes its faces into its part of each layer. The
        //    faces of a layer are then in face order, as with one thread.
        const faces = m.faces.items;
        const ranges = try gpa.alloc([2]u32, faces.len);
        defer gpa.free(ranges);
        const block = 8192;
        const nb = (faces.len + block - 1) / block;
        const nl = layers.len;
        // counts[b * nl + l]: the faces of block b in layer l, then the
        // write position of block b in layer l.
        const counts = try gpa.alloc(u32, nb * nl);
        defer gpa.free(counts);
        @memset(counts, 0);
        var items: []u32 = &.{};
        errdefer gpa.free(items);
        const Pass = struct {
            m: *const Mesh,
            layers: []const Layer,
            z_offset: f64,
            z_scale: f64,
            ranges: [][2]u32,
            counts: []u32,
            items: []u32 = &.{},
            fn count(c: *const @This(), bi: usize) anyerror!void {
                const lo = bi * block;
                const hi = @min(lo + block, c.ranges.len);
                const mine = c.counts[bi * c.layers.len ..][0..c.layers.len];
                for (c.m.faces.items[lo..hi], c.ranges[lo..hi]) |f, *r| {
                    r.* = layerRange(c.m, f, c.layers, c.z_offset, c.z_scale);
                    for (r[0]..r[1]) |l| mine[l] += 1;
                }
            }
            fn fill(c: *const @This(), bi: usize) anyerror!void {
                const lo = bi * block;
                const hi = @min(lo + block, c.ranges.len);
                const at = c.counts[bi * c.layers.len ..][0..c.layers.len];
                for (c.ranges[lo..hi], lo..) |r, fi| {
                    for (r[0]..r[1]) |l| {
                        c.items[at[l]] = @intCast(fi);
                        at[l] += 1;
                    }
                }
            }
        };
        var ctx: Pass = .{ .m = m, .layers = layers, .z_offset = z_offset, .z_scale = z_scale, .ranges = ranges, .counts = counts };
        parallel.forEach(threads, nb, &ctx, Pass.count) catch |e| return @as(Allocator.Error, @errorCast(e));
        var total: u32 = 0;
        for (0..nl) |l| {
            starts[l] = total;
            for (0..nb) |bi| {
                const c = counts[bi * nl + l];
                counts[bi * nl + l] = total;
                total += c;
            }
        }
        starts[nl] = total;
        items = try gpa.alloc(u32, total);
        ctx.items = items;
        parallel.forEach(threads, nb, &ctx, Pass.fill) catch |e| return @as(Allocator.Error, @errorCast(e));
        return .{ .starts = starts, .items = items };
    }

    /// The layers whose cut plane the face crosses, as [first, end). The
    /// range is empty if the face crosses no cut plane.
    fn layerRange(m: *const Mesh, f: [3]u32, layers: []const Layer, z_offset: f64, z_scale: f64) [2]u32 {
        const v = m.vertices.items;
        const z0: f64 = (@as(f64, @min(v[f[0]].z, @min(v[f[1]].z, v[f[2]].z))) - z_offset) * z_scale;
        const z1: f64 = (@as(f64, @max(v[f[0]].z, @max(v[f[1]].z, v[f[2]].z))) - z_offset) * z_scale;
        // A face crosses a plane at s if z0 <= s < z1 (see the
        // above/below rule in the file comment).
        const first = lowerBound(layers, z0);
        const end = lowerBound(layers, z1);
        if (first >= end) return .{ 0, 0 };
        return .{ @intCast(first), @intCast(end) };
    }

    /// The first layer whose cut plane is at or above z.
    fn lowerBound(layers: []const Layer, z: f64) usize {
        var lo: usize = 0;
        var hi: usize = layers.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (layers[mid].sliceZ() < z) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

const Segment = struct {
    start_key: u64,
    end_key: u64,
    start: Point,
    end: Point,
};

fn edgeKey(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, lo) << 32) | hi;
}

/// Returns the outline of the mesh at height z (mm), in micrometers. The
/// caller owns the result. `tolerance` (micrometers) is the simplify
/// tolerance, and `gap` (micrometers) is the largest gap that the code
/// closes in a mesh with holes.
pub fn sliceAt(gpa: Allocator, m: *const Mesh, faces: []const u32, z: f64, tolerance: i64, gap: i64) Allocator.Error!Paths {
    var arena_state = scratch.get(gpa);
    defer arena_state.release();
    const arena = arena_state.allocator();

    // Steps 2 and 3: one segment for each crossing triangle.
    var segs: std.ArrayList(Segment) = .empty;
    try segs.ensureTotalCapacity(arena, faces.len);
    const verts = m.vertices.items;
    for (faces) |fi| {
        const f = m.faces.items[fi];
        var above: [3]bool = undefined;
        for (0..3) |k| above[k] = verts[f[k]].z > z;
        if (above[0] == above[1] and above[1] == above[2]) continue;
        var seg: Segment = undefined;
        for (0..3) |k| {
            const u = f[k];
            const w = f[(k + 1) % 3];
            const au = above[k];
            const aw = above[(k + 1) % 3];
            if (au == aw) continue;
            const p = cut(verts[u], verts[w], z);
            if (au) {
                seg.start_key = edgeKey(u, w);
                seg.start = p;
            } else {
                seg.end_key = edgeKey(u, w);
                seg.end = p;
            }
        }
        segs.appendAssumeCapacity(seg);
    }

    // Step 4: join the segments into chains by edge ID.
    var by_start: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var by_end: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    try by_start.ensureTotalCapacity(arena, @intCast(segs.items.len));
    try by_end.ensureTotalCapacity(arena, @intCast(segs.items.len));
    for (segs.items, 0..) |s, i| {
        by_start.putAssumeCapacity(s.start_key, @intCast(i));
        by_end.putAssumeCapacity(s.end_key, @intCast(i));
    }

    const used = try arena.alloc(bool, segs.items.len);
    @memset(used, false);
    var loops: Paths = .empty;
    var open: Paths = .empty;
    var order: std.ArrayList(u32) = .empty;
    var back: std.ArrayList(u32) = .empty;
    for (0..segs.items.len) |si| {
        if (used[si]) continue;
        order.clearRetainingCapacity();
        back.clearRetainingCapacity();
        used[si] = true;
        const first_key = segs.items[si].start_key;

        // Walk forward until the chain comes back to its start (a loop) or
        // stops (an open chain).
        var cur: u32 = @intCast(si);
        var closed = false;
        try order.append(arena, cur);
        while (true) {
            const end_key = segs.items[cur].end_key;
            if (end_key == first_key) {
                closed = true;
                break;
            }
            const next = by_start.get(end_key) orelse break;
            if (used[next]) break;
            used[next] = true;
            try order.append(arena, next);
            cur = next;
        }

        // An open chain: also walk backward from the first segment, so that
        // the chain is as long as possible.
        if (!closed) {
            cur = @intCast(si);
            while (true) {
                const prev = by_end.get(segs.items[cur].start_key) orelse break;
                if (used[prev]) break;
                used[prev] = true;
                try back.append(arena, prev);
                cur = prev;
            }
        }

        const dest = if (closed) &loops else &open;
        var i = back.items.len;
        while (i > 0) {
            i -= 1;
            try dest.appendPoint(arena, segs.items[back.items[i]].start);
        }
        for (order.items) |k| try dest.appendPoint(arena, segs.items[k].start);
        if (!closed) try dest.appendPoint(arena, segs.items[order.items[order.items.len - 1]].end);
        try dest.endPath(arena, 2);
    }

    // Step 5: close the open chains.
    if (!open.isEmpty()) try closeChains(arena, open, &loops, gap);

    // Remove points that do not change the shape.
    var clean: Paths = .empty;
    for (0..loops.count()) |i| {
        const poly = loops.get(i);
        const n = geom.simplifyClosed(poly, tolerance);
        if (n >= 3) try clean.append(arena, poly[0..n]);
    }

    // Step 6.
    return clip.unionAll(gpa, clean, .non_zero);
}

/// The point where the edge from a to b crosses the plane at z.
fn cut(a: mesh_mod.Vec3, b: mesh_mod.Vec3, z: f64) Point {
    const az: f64 = a.z;
    const bz: f64 = b.z;
    const t = (z - az) / (bz - az);
    const x = @as(f64, a.x) + (@as(f64, b.x) - a.x) * t;
    const y = @as(f64, a.y) + (@as(f64, b.y) - a.y) * t;
    return .{ .x = geom.fromMm(x), .y = geom.fromMm(y) };
}

/// Joins open chains into loops. At the end of a chain, the code takes the
/// nearest of: the start of the same chain (this closes the loop), or the
/// start of another chain (this joins the two). A chain that has nothing
/// within `gap` is removed.
///
/// The search is linear, so the cost is O(n^2) for n open chains. A mesh
/// with a few holes gives a few open chains in each layer.
fn closeChains(arena: Allocator, open: Paths, loops: *Paths, gap: i64) !void {
    const n = open.count();
    const used = try arena.alloc(bool, n);
    @memset(used, false);
    const gap2: i128 = @as(i128, gap) * gap;
    var pts: std.ArrayList(Point) = .empty;
    for (0..n) |i| {
        if (used[i]) continue;
        used[i] = true;
        pts.clearRetainingCapacity();
        try pts.appendSlice(arena, open.get(i));
        while (true) {
            const end = pts.items[pts.items.len - 1];
            const self_d = end.distSq(pts.items[0]);
            var best: ?usize = null;
            var best_d: i128 = @min(self_d, gap2 + 1);
            for (0..n) |j| {
                if (used[j]) continue;
                const d = end.distSq(open.get(j)[0]);
                if (d < best_d) {
                    best_d = d;
                    best = j;
                }
            }
            if (best) |j| {
                used[j] = true;
                try pts.appendSlice(arena, open.get(j));
                continue;
            }
            if (self_d <= gap2 and pts.items.len > 2) try loops.append(arena, pts.items);
            break;
        }
    }
}

const testing = std.testing;

test "layer table" {
    const layers = try layerTable(testing.allocator, 1.0, 0.3, 0.2);
    defer testing.allocator.free(layers);
    // Tops at 0.3, 0.5, 0.7, 0.9, 1.1. The plane of the last is at 1.0, so
    // that layer is not added.
    try testing.expectEqual(@as(usize, 4), layers.len);
    try testing.expectApproxEqAbs(@as(f64, 0.15), layers[0].sliceZ(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.8), layers[3].sliceZ(), 1e-12);
}

test "slice a box" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.box(gpa, 20, 10, 5);
    defer m.deinit(gpa);
    const layers = try layerTable(gpa, 5, 0.2, 0.2);
    defer gpa.free(layers);
    var idx = try FaceIndex.build(gpa, &m, layers, 0);
    defer idx.deinit(gpa);
    try testing.expectEqual(@as(usize, 25), layers.len);
    var out = try sliceAt(gpa, &m, idx.get(10), layers[10].sliceZ(), 5, 1000);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), out.count());
    try testing.expectApproxEqAbs(@as(f64, 200.0), out.areaMm2(), 1e-6);
    try testing.expectEqual(@as(usize, 4), out.get(0).len);
}

test "slice a tube: an outer loop and a hole" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addTube(&b, 0, 0, 10, 5, 0, 10, 128);
    var m = try b.finish();
    defer m.deinit(gpa);
    const faces = try gpa.alloc(u32, m.faces.items.len);
    defer gpa.free(faces);
    for (faces, 0..) |*f, i| f.* = @intCast(i);
    var out = try sliceAt(gpa, &m, faces, 5, 1, 1000);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), out.count());
    // A 128-gon of radius R has area 64 R^2 sin(2 pi / 128).
    const k = 64.0 * @sin(2.0 * std.math.pi / 128.0);
    try testing.expectApproxEqAbs(k * (100.0 - 25.0), out.areaMm2(), 0.01);
}

test "a mesh with a seam that does not weld" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    // A box whose right side is 0.1 micrometers from the other faces. The
    // vertices do not weld, so the slice has open chains with small gaps.
    const v = struct {
        fn f(x: f32, y: f32, z: f32) mesh_mod.Vec3 {
            return .{ .x = x, .y = y, .z = z };
        }
    }.f;
    const e: f32 = 10.0001;
    try b.addQuad(v(0, 0, 0), v(0, 10, 0), v(10, 10, 0), v(10, 0, 0));
    try b.addQuad(v(0, 0, 10), v(10, 0, 10), v(10, 10, 10), v(0, 10, 10));
    try b.addQuad(v(0, 0, 0), v(10, 0, 0), v(10, 0, 10), v(0, 0, 10));
    try b.addQuad(v(0, 10, 0), v(0, 10, 10), v(10, 10, 10), v(10, 10, 0));
    try b.addQuad(v(0, 0, 0), v(0, 0, 10), v(0, 10, 10), v(0, 10, 0));
    try b.addQuad(v(e, 0, 0), v(e, 10, 0), v(e, 10, 10), v(e, 0, 10));
    var m = try b.finish();
    defer m.deinit(gpa);
    const faces = try gpa.alloc(u32, m.faces.items.len);
    defer gpa.free(faces);
    for (faces, 0..) |*f, i| f.* = @intCast(i);
    var out = try sliceAt(gpa, &m, faces, 5, 1, 1000);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), out.count());
    try testing.expectApproxEqAbs(@as(f64, 100.0), out.areaMm2(), 0.01);
}

test "the face index is the same on 1 thread and on 4 threads" {
    const gpa = std.testing.allocator;
    // Tubes with many faces (more than one block), at three heights.
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    try mesh_mod.shapes.addTube(&b, 0, 0, 20, 15, 0, 10, 3000);
    try mesh_mod.shapes.addTube(&b, 50, 0, 20, 15, 2, 6, 3000);
    try mesh_mod.shapes.addTube(&b, 0, 50, 20, 15, 5, 12.5, 3000);
    var m = try b.finish();
    defer m.deinit(gpa);
    const layers = try layerTable(gpa, 12.5, 0.3, 0.2);
    defer gpa.free(layers);
    var one = try FaceIndex.buildScaled(gpa, &m, layers, 0, 1, 1);
    defer one.deinit(gpa);
    var four = try FaceIndex.buildScaled(gpa, &m, layers, 0, 1, 4);
    defer four.deinit(gpa);
    try std.testing.expect(m.faces.items.len > 2 * 8192);
    try std.testing.expectEqualSlices(u32, one.starts, four.starts);
    try std.testing.expectEqualSlices(u32, one.items, four.items);
}
