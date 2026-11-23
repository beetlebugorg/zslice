//! The region of a body of a range of layers, as a modifier volume: the
//! settings of a selected segment of a print, for that segment only.
//!
//! A drag over layers in a shell selects one body of a part (a tube that
//! rises from a lid, see View.connectedPaths). The user can give the body
//! its own value of a layer setting (settings.region_settings: the infill,
//! its speed, and its flow). The body then becomes a modifier volume of
//! its part (plate.Volume, layer.Modifier), with the setting as its own.
//!
//! The volume is a stack of prisms, one for each layer of the body:
//!
//! 1. The footprint of the body on a layer is the union of its printed
//!    lines, each as a rectangle as wide as its bead, with the ends out by
//!    half a bead. The holes of the union go: a hole is a gap between the
//!    lines, or a hole of the part, and the modifier area stays inside the
//!    part anyway (layer.Modifier).
//! 2. Each outline of the footprint, simplified, rises from the bottom to
//!    the top of its layer. Ear clipping (cut.earClip) closes the top and
//!    the bottom. The prisms of two layers touch, so a cut plane at any
//!    height meets one of them: the slicer counts a point on the plane as
//!    over it.
//!
//! The slice of the volume at the middle of a layer is the footprint of
//! that layer, so the region follows the body as it grows and shrinks.
//!
//! The beads come from the view (zs_view_connected_beads), in the frame of
//! the part on the bed: `stride` floats each (part, layer, top z,
//! height, ends a and b, width).
//!
//! A filament pick of a range of layers is a volume of the same form, with
//! the metadata key `pick_key` (see App.paintBody). It changes no outline
//! and no line. The plate job cuts it at each layer, and each line of the
//! part that lies mostly in the cut gets the filament of the pick (see
//! PlateJob.markPicks). So a pick changes the lines of its layers and of
//! no other layer. The prism of a pick keeps the holes of the part, and it
//! leaves out the islands of the layer that no bead of the body touches
//! (a post inside a ring). A hole is a prism with its faces turned in.
//!
//! References (see docs/references/cura.md): the infill meshes of
//! CuraEngine (the modifier volume). The rule that turns the lines of a
//! body into a volume is new.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const mesh_mod = @import("mesh.zig");
const cut = @import("cut.zig");
const offset_mod = @import("offset.zig");
const slicer = @import("slicer.zig");
const Mesh = mesh_mod.Mesh;
const Paths = geom.Paths;
const Point = geom.Point;

/// The floats of one bead: part, layer, z (top), h, ax, ay, bx, by, w.
pub const stride = 9;

/// The metadata key of a filament pick: its value is the filament number.
pub const pick_key = "zslice:layer_pick";

/// A filament pick of a part for a slice: its volume on the bed and its
/// filament (from 1).
pub const Pick = struct { mesh: *const Mesh, filament: u8 };

/// The filament of a volume that is a pick, or null.
pub fn pickFilament(meta: anytype) ?u32 {
    for (meta) |m| if (std.mem.eql(u8, m.key, pick_key)) return std.fmt.parseInt(u32, std.mem.trim(u8, m.value, " "), 10) catch null;
    return null;
}

/// The tolerance of the simplified outline (mm).
const simplify_mm: f64 = 0.1;
/// An outline with less area is a crumb, and goes (mm²).
const min_area_mm2: f64 = 0.2;
/// The most points of an outline: ear clipping is O(n²) for each ear, and
/// the web app makes the volume on its worker while the user waits.
const max_points: usize = 128;

/// The part of the beads: the part of the first bead, or null with no
/// beads.
pub fn partOf(beads: []const f32) ?usize {
    if (beads.len < stride or beads[0] < 0) return null;
    return @intFromFloat(beads[0]);
}

/// The box of the beads (mm): x, y, and z from the bottom of the lowest
/// bead to the top of the highest, with half a bead at each side. Null
/// for no beads.
pub fn bounds(beads: []const f32) ?[2][3]f64 {
    if (beads.len < stride) return null;
    var lo: [3]f64 = @splat(std.math.inf(f64));
    var hi: [3]f64 = @splat(-std.math.inf(f64));
    var k: usize = 0;
    while (k + stride <= beads.len) : (k += stride) {
        const b = beads[k..][0..stride];
        const r: f64 = 0.5 * b[8];
        for ([_][2]f32{ .{ b[4], b[5] }, .{ b[6], b[7] } }) |q| for (0..2) |d| {
            lo[d] = @min(lo[d], q[d] - r);
            hi[d] = @max(hi[d], q[d] + r);
        };
        lo[2] = @min(lo[2], b[2] - b[3]);
        hi[2] = @max(hi[2], b[2]);
    }
    return .{ lo, hi };
}

/// The outlines of the footprint of the beads of one layer (their indices
/// in `idx`), counterclockwise, with no holes. The caller owns the result.
pub fn footprint(gpa: Allocator, beads: []const f32, idx: []const usize) Allocator.Error!Paths {
    var all = try beadUnion(gpa, beads, idx);
    defer all.deinit(gpa);
    return cleaned(gpa, all, false);
}

/// The union of the beads of one layer, each a rectangle with its ends
/// out by half a bead.
fn beadUnion(gpa: Allocator, beads: []const f32, idx: []const usize) Allocator.Error!Paths {
    var rects: Paths = .empty;
    defer rects.deinit(gpa);
    for (idx) |k| {
        const b = beads[k * stride ..][0..stride];
        const hw = 0.5 * b[8];
        if (!(hw > 0)) continue;
        var dx = b[6] - b[4];
        var dy = b[7] - b[5];
        const len = @sqrt(dx * dx + dy * dy);
        if (len > 1e-6) {
            dx /= len;
            dy /= len;
        } else {
            dx = 1;
            dy = 0;
        }
        // Out by half a bead at each end, and to each side.
        const ax = b[4] - dx * hw;
        const ay = b[5] - dy * hw;
        const bx = b[6] + dx * hw;
        const by = b[7] + dy * hw;
        const nx = -dy * hw;
        const ny = dx * hw;
        const pts = [4][2]f32{ .{ ax + nx, ay + ny }, .{ ax - nx, ay - ny }, .{ bx - nx, by - ny }, .{ bx + nx, by + ny } };
        for (pts) |q| try rects.appendPoint(gpa, .init(geom.fromMm(q[0]), geom.fromMm(q[1])));
        try rects.endPath(gpa, 3);
    }
    return clip.unionAll(gpa, rects, .non_zero);
}

/// The outlines of `all`, simplified, with no crumbs. `holes`: the holes
/// stay (clockwise); else they go.
fn cleaned(gpa: Allocator, all: Paths, holes: bool) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    var buf: std.ArrayList(Point) = .empty;
    defer buf.deinit(gpa);
    for (0..all.count()) |k| {
        const poly = all.get(k);
        const a = geom.areaMm2(poly);
        // A crumb goes, and a hole (clockwise) unless the caller keeps it.
        if (!((if (holes) @abs(a) else a) >= min_area_mm2)) continue;
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, poly);
        var tol = geom.fromMm(simplify_mm);
        var n = geom.simplifyClosed(buf.items, tol);
        while (n > max_points) {
            tol *= 2;
            n = geom.simplifyClosed(buf.items[0..n], tol);
        }
        if (n < 3) continue;
        try out.append(gpa, buf.items[0..n]);
    }
    return out;
}

/// The area of a pick on one layer: the filled footprint of the beads,
/// inside the cut of the part at `z` grown by half a bead (so the holes of
/// the part stay), less the islands of the cut that no bead touches. The
/// beads themselves always stay in it. The caller owns the result.
fn pickFootprint(gpa: Allocator, beads: []const f32, idx: []const usize, part: *const Mesh, faces: []const u32, z: f64, w: f64) Allocator.Error!Paths {
    var lines = try beadUnion(gpa, beads, idx);
    defer lines.deinit(gpa);
    var filled = try cleaned(gpa, lines, false);
    defer filled.deinit(gpa);
    var cut_z = try slicer.sliceAt(gpa, part, faces, z, 10, 50);
    defer cut_z.deinit(gpa);
    if (cut_z.isEmpty()) return filled.clone(gpa);
    var away: Paths = .empty;
    defer away.deinit(gpa);
    var one: Paths = .empty;
    defer one.deinit(gpa);
    for (0..cut_z.count()) |k| {
        const poly = cut_z.get(k);
        if (!(geom.areaMm2(poly) > 0)) continue;
        one.points.clearRetainingCapacity();
        one.ends.clearRetainingCapacity();
        try one.append(gpa, poly);
        var meet = try clip.intersect(gpa, one, lines);
        defer meet.deinit(gpa);
        if (meet.isEmpty()) try away.append(gpa, poly);
    }
    var grown = try offset_mod.offset(gpa, cut_z, geom.fromMm(0.5 * w), .{});
    defer grown.deinit(gpa);
    var inside = try clip.intersect(gpa, filled, grown);
    defer inside.deinit(gpa);
    var kept = try clip.difference(gpa, inside, away);
    defer kept.deinit(gpa);
    var all = try clip.unite(gpa, kept, lines);
    defer all.deinit(gpa);
    return cleaned(gpa, all, true);
}

/// The volume of the beads: a prism on each layer for each outline of its
/// footprint, in the frame of the beads (the part on the bed). The caller
/// owns the mesh. An empty mesh: no beads, or no footprint.
pub fn volume(gpa: Allocator, beads: []const f32) (Allocator.Error || mesh_mod.Error)!Mesh {
    return stack(gpa, beads, null);
}

/// The volume of a filament pick of the beads on `part`, the mesh of the
/// part on the bed (see the header).
pub fn pickVolume(gpa: Allocator, beads: []const f32, part: *const Mesh) (Allocator.Error || mesh_mod.Error)!Mesh {
    return stack(gpa, beads, part);
}

fn stack(gpa: Allocator, beads: []const f32, part: ?*const Mesh) (Allocator.Error || mesh_mod.Error)!Mesh {
    const n = beads.len / stride;
    // The beads of each layer, in the order of their layers.
    const order = try gpa.alloc(usize, n);
    defer gpa.free(order);
    for (order, 0..) |*o, k| o.* = k;
    std.mem.sort(usize, order, beads, struct {
        fn lt(bs: []const f32, x: usize, y: usize) bool {
            return bs[x * stride + 1] < bs[y * stride + 1];
        }
    }.lt);
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    var tris: std.ArrayList([3][2]f32) = .empty;
    defer tris.deinit(gpa);
    var ring: std.ArrayList([2]f32) = .empty;
    defer ring.deinit(gpa);
    var ccw: std.ArrayList([2]f32) = .empty;
    defer ccw.deinit(gpa);
    var faces: std.ArrayList(u32) = .empty;
    defer faces.deinit(gpa);
    var start: usize = 0;
    // The top of the layer before: the bottom of the next layer starts
    // there, with the same float, so no cut plane falls between them.
    var prev_top: f32 = -1;
    while (start < n) {
        const layer = beads[order[start] * stride + 1];
        var end = start;
        var top: f32 = 0;
        var h: f32 = 0;
        while (end < n and beads[order[end] * stride + 1] == layer) : (end += 1) {
            top = @max(top, beads[order[end] * stride + 2]);
            h = @max(h, beads[order[end] * stride + 3]);
        }
        defer start = end;
        var foot = if (part) |m| blk: {
            // The faces of the part that reach the middle of the layer.
            const zm = top - 0.5 * h;
            faces.clearRetainingCapacity();
            const vs = m.vertices.items;
            for (m.faces.items, 0..) |f, fi| {
                const lo = @min(vs[f[0]].z, vs[f[1]].z, vs[f[2]].z);
                const hi = @max(vs[f[0]].z, vs[f[1]].z, vs[f[2]].z);
                if (lo <= zm and hi >= zm) try faces.append(gpa, @intCast(fi));
            }
            var w: f32 = 0;
            for (order[start..end]) |o| w = @max(w, beads[o * stride + 8]);
            break :blk try pickFootprint(gpa, beads, order[start..end], m, faces.items, zm, w);
        } else try footprint(gpa, beads, order[start..end]);
        defer foot.deinit(gpa);
        const z0 = if (@abs(top - h - prev_top) < 0.01) prev_top else top - h;
        const z1 = top;
        prev_top = top;
        if (!(z1 > z0)) continue;
        for (0..foot.count()) |k| {
            const poly = foot.get(k);
            ring.clearRetainingCapacity();
            for (poly) |p| try ring.append(gpa, .{ @floatCast(geom.toMm(p.x)), @floatCast(geom.toMm(p.y)) });
            // The sides, out from the outline (counterclockwise).
            for (ring.items, 0..) |p, i| {
                const q = ring.items[(i + 1) % ring.items.len];
                try b.addTriangle(.{ .x = p[0], .y = p[1], .z = z0 }, .{ .x = q[0], .y = q[1], .z = z0 }, .{ .x = q[0], .y = q[1], .z = z1 });
                try b.addTriangle(.{ .x = p[0], .y = p[1], .z = z0 }, .{ .x = q[0], .y = q[1], .z = z1 }, .{ .x = p[0], .y = p[1], .z = z1 });
            }
            // The top faces up, the bottom faces down. Ear clipping needs
            // a counterclockwise ring, and the caps of a hole face the
            // other way.
            const hole = geom.areaMm2(poly) < 0;
            ccw.clearRetainingCapacity();
            try ccw.appendSlice(gpa, ring.items);
            if (hole) std.mem.reverse([2]f32, ccw.items);
            tris.clearRetainingCapacity();
            try cut.earClip(gpa, ccw.items, &tris);
            for (tris.items) |t| {
                const u = if (hole) t[2] else t[1];
                const v = if (hole) t[1] else t[2];
                try b.addTriangle(.{ .x = t[0][0], .y = t[0][1], .z = z1 }, .{ .x = u[0], .y = u[1], .z = z1 }, .{ .x = v[0], .y = v[1], .z = z1 });
                try b.addTriangle(.{ .x = t[0][0], .y = t[0][1], .z = z0 }, .{ .x = v[0], .y = v[1], .z = z0 }, .{ .x = u[0], .y = u[1], .z = z0 });
            }
        }
    }
    if (b.mesh.faces.items.len == 0) {
        b.deinit();
        return .empty;
    }
    return b.finish();
}

const testing = std.testing;

/// The beads of a square loop of side `s` at (x, y) on layers lo to hi
/// (0.2 mm each), part 0.
fn squareBeads(gpa: Allocator, x: f32, y: f32, s: f32, lo: usize, hi: usize) !std.ArrayList(f32) {
    var out: std.ArrayList(f32) = .empty;
    for (lo..hi + 1) |l| {
        const z: f32 = 0.2 * @as(f32, @floatFromInt(l + 1));
        const c = [_][2]f32{ .{ x, y }, .{ x + s, y }, .{ x + s, y + s }, .{ x, y + s } };
        for (0..4) |k| try out.appendSlice(gpa, &.{ 0, @floatFromInt(l), z, 0.2, c[k][0], c[k][1], c[(k + 1) % 4][0], c[(k + 1) % 4][1], 0.4 });
    }
    return out;
}

test "body region: the footprint of a loop is one filled square, out by half a bead" {
    const gpa = testing.allocator;
    var beads = try squareBeads(gpa, 10, 10, 6, 3, 3);
    defer beads.deinit(gpa);
    var f = try footprint(gpa, beads.items, &.{ 0, 1, 2, 3 });
    defer f.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), f.count());
    // 6.4 x 6.4 mm, with no hole.
    try testing.expectApproxEqAbs(@as(f64, 6.4 * 6.4), f.areaMm2(), 0.1);
}

test "body region: a prism on each layer, from its bottom to its top" {
    const gpa = testing.allocator;
    var beads = try squareBeads(gpa, 10, 10, 6, 5, 9);
    defer beads.deinit(gpa);
    var m = try volume(gpa, beads.items);
    defer m.deinit(gpa);
    const bx = m.bounds();
    try testing.expectApproxEqAbs(@as(f64, 1.0), bx.min[2], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), bx.max[2], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 9.8), bx.min[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 16.2), bx.max[0], 0.01);
    // 5 boxes: 12 triangles each (two for each side, two for each cap).
    try testing.expectEqual(@as(usize, 5 * 12), m.faces.items.len);
    try testing.expectEqual(@as(?usize, 0), partOf(beads.items));
    // No beads: no volume.
    var none = try volume(gpa, &.{});
    defer none.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), none.faces.items.len);
}

test "body region: the slice of the volume at the middle of a layer is the footprint" {
    const gpa = testing.allocator;
    var beads = try squareBeads(gpa, 10, 10, 6, 5, 9);
    defer beads.deinit(gpa);
    var m = try volume(gpa, beads.items);
    defer m.deinit(gpa);
    const layers = try slicer.layerTable(gpa, 3, 0.2, 0.2);
    defer gpa.free(layers);
    var index = try slicer.FaceIndex.build(gpa, &m, layers, 0);
    defer index.deinit(gpa);
    // Layer 6: from z 1.2 to 1.4, the bead layer 6.
    var o = try slicer.sliceAt(gpa, &m, index.get(6), layers[6].sliceZ(), 10, 50);
    defer o.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 6.4 * 6.4), o.areaMm2(), 0.2);
    // A cut plane on the top of a prism (layers of another height) meets
    // the prism over it.
    var top = try slicer.sliceAt(gpa, &m, index.get(7), 1.4, 10, 50);
    defer top.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 6.4 * 6.4), top.areaMm2(), 0.2);
}
