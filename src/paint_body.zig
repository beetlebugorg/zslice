//! The paint of a body of a range of layers: the filament of a selected
//! segment of a print, as paint on the mesh of its part.
//!
//! A drag over layers in a shell selects one body of a part (a tube that
//! rises from a lid, see View.connectedPaths). Its printed lines on each
//! layer are its footprint: the union of the lines, each as wide as its
//! bead. This module paints the triangles of the mesh of the part that lie
//! on that footprint, with paint.paintTriangle. The paint then colors the
//! body in each later slice (paint_split.zig), so the color follows a
//! later change of the walls, the layer height, the place, or the turn of
//! the part.
//!
//! The rules for a piece of a triangle:
//!
//! - It must lie in the z range of the layers. A steep piece must not
//!   reach the cut plane (the middle) of the layer under the first layer
//!   or over the last layer, so it colors no layer out of the range.
//! - A steep piece (the side of the body) must be within one bead width
//!   of the center of a line of its layer. The outer wall is half a bead
//!   inside the surface, so the side of the body is near it, and the
//!   other half bead is a margin for the slope of the surface.
//! - A flat piece (|nz| > 0.7, as paint_split.zig) must be inside the
//!   footprint (within half a bead of a line, less a small margin). A
//!   top or a bottom of the body is inside its footprint, and the face of
//!   another body next to it (a lid around the tube) is not.
//!
//! A grid of the lines of each layer makes each test a few distance
//! tests.
//!
//! The beads come from the view (zs_view_connected_beads), in the frame
//! of the part on the bed (zs_app_part_mesh): `stride` floats each, the
//! part, the layer, the top z of the bead, its height, its ends a and b,
//! and its width.
//!
//! References (see docs/references/): the paint of PrusaSlicer and Bambu
//! Studio (prusaslicer.md, "Paint in 3MF files": the form of the paint),
//! and the multi-material segmentation (the flat and steep pieces of
//! paint_split.zig). The rule that turns the lines of a body into paint is
//! new.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const paint_mod = @import("paint.zig");
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const V3 = paint_mod.V3;

/// The floats of one bead: part, layer, z (top), h, ax, ay, bx, by, w.
pub const stride = 9;

/// The cell of the grid of a layer (mm).
const cell: f32 = 1.0;

/// The margin of a flat piece inside the footprint (mm).
const flat_margin: f32 = 0.02;

const Seg = struct { ax: f32, ay: f32, bx: f32, by: f32, hw: f32 };

const Layer = struct {
    index: u32,
    z0: f32,
    z1: f32,
    /// The box of the lines, grown by a bead width.
    box: [4]f32,
    nx: u32,
    ny: u32,
    /// The lines of cell k: segs[cell_start[k]..cell_start[k + 1]] of
    /// `cell_segs`.
    cell_start: []u32,
    cell_segs: []u32,
    segs: []Seg,
};

pub const Body = struct {
    gpa: Allocator,
    /// The layers, from the bottom up.
    layers: []Layer = &.{},
    /// The z range of the pieces: the cut planes under the first layer and
    /// over the last one (see the header).
    z_lo: f32 = 0,
    z_hi: f32 = 0,

    pub fn deinit(b: *Body) void {
        for (b.layers) |*l| {
            b.gpa.free(l.cell_start);
            b.gpa.free(l.cell_segs);
            b.gpa.free(l.segs);
        }
        b.gpa.free(b.layers);
        b.* = undefined;
    }

    /// The body of the beads of part `part` in `beads` (see `stride`).
    /// No beads of the part: a body with no layers.
    pub fn init(gpa: Allocator, beads: []const f32, part: u32) Allocator.Error!Body {
        var b: Body = .{ .gpa = gpa };
        errdefer b.deinit();
        const n = beads.len / stride;
        // The layers of the part, sorted.
        var idx: std.ArrayList(u32) = .empty;
        defer idx.deinit(gpa);
        for (0..n) |i| {
            const q = beads[i * stride ..][0..stride];
            if (!(q[0] >= 0) or @as(u32, @intFromFloat(q[0])) != part or !(q[8] > 0) or !(q[3] > 0)) continue;
            try idx.append(gpa, @intCast(i));
        }
        if (idx.items.len == 0) return b;
        const Ctx = struct {
            beads: []const f32,
            fn less(c: @This(), x: u32, y: u32) bool {
                return c.beads[x * stride + 1] < c.beads[y * stride + 1];
            }
        };
        std.mem.sort(u32, idx.items, Ctx{ .beads = beads }, Ctx.less);
        var layers: std.ArrayList(Layer) = .empty;
        defer layers.deinit(gpa);
        errdefer for (layers.items) |*l| {
            gpa.free(l.cell_start);
            gpa.free(l.cell_segs);
            gpa.free(l.segs);
        };
        var i: usize = 0;
        while (i < idx.items.len) {
            const li = beads[idx.items[i] * stride + 1];
            var j = i;
            while (j < idx.items.len and beads[idx.items[j] * stride + 1] == li) j += 1;
            try layers.append(gpa, try layerOf(gpa, beads, idx.items[i..j]));
            i = j;
        }
        b.layers = try layers.toOwnedSlice(gpa);
        std.mem.sort(Layer, b.layers, {}, struct {
            fn less(_: void, x: Layer, y: Layer) bool {
                return x.z1 < y.z1;
            }
        }.less);
        const first = b.layers[0];
        const last = b.layers[b.layers.len - 1];
        b.z_lo = first.z0 - 0.5 * (first.z1 - first.z0);
        b.z_hi = last.z1 + 0.5 * (last.z1 - last.z0);
        return b;
    }

    fn layerOf(gpa: Allocator, beads: []const f32, list: []const u32) Allocator.Error!Layer {
        var z1: f32 = -std.math.inf(f32);
        var h: f32 = std.math.inf(f32);
        var box: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        const segs = try gpa.alloc(Seg, list.len);
        errdefer gpa.free(segs);
        for (list, segs) |k, *s| {
            const q = beads[k * stride ..][0..stride];
            z1 = @max(z1, q[2]);
            h = @min(h, q[3]);
            s.* = .{ .ax = q[4], .ay = q[5], .bx = q[6], .by = q[7], .hw = 0.5 * q[8] };
            const r = 2 * s.hw;
            box[0] = @min(box[0], @min(s.ax, s.bx) - r);
            box[1] = @min(box[1], @min(s.ay, s.by) - r);
            box[2] = @max(box[2], @max(s.ax, s.bx) + r);
            box[3] = @max(box[3], @max(s.ay, s.by) + r);
        }
        const nx: u32 = @intFromFloat(@min(4096, @floor((box[2] - box[0]) / cell) + 1));
        const ny: u32 = @intFromFloat(@min(4096, @floor((box[3] - box[1]) / cell) + 1));
        const n_cells = @as(usize, nx) * ny;
        const start = try gpa.alloc(u32, n_cells + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        // Two passes: the counts, then the lists.
        for (segs) |s| {
            const r = cellRange(box, nx, ny, s);
            var y = r[1];
            while (y <= r[3]) : (y += 1) {
                var x = r[0];
                while (x <= r[2]) : (x += 1) start[y * nx + x + 1] += 1;
            }
        }
        for (1..n_cells + 1) |k| start[k] += start[k - 1];
        const lists = try gpa.alloc(u32, start[n_cells]);
        errdefer gpa.free(lists);
        const fill = try gpa.dupe(u32, start[0..n_cells]);
        defer gpa.free(fill);
        for (segs, 0..) |s, si| {
            const r = cellRange(box, nx, ny, s);
            var y = r[1];
            while (y <= r[3]) : (y += 1) {
                var x = r[0];
                while (x <= r[2]) : (x += 1) {
                    const c = y * nx + x;
                    lists[fill[c]] = @intCast(si);
                    fill[c] += 1;
                }
            }
        }
        return .{
            .index = @intFromFloat(beads[list[0] * stride + 1]),
            .z0 = z1 - h,
            .z1 = z1,
            .box = box,
            .nx = nx,
            .ny = ny,
            .cell_start = start,
            .cell_segs = lists,
            .segs = segs,
        };
    }

    /// The cells (x0, y0, x1, y1) of a box in the grid of a layer.
    fn cells(box: [4]f32, nx: u32, ny: u32, b: [4]f32) [4]u32 {
        const f = struct {
            fn f(v: f32, lo: f32, n: u32) u32 {
                const k = @floor((v - lo) / cell);
                if (!(k > 0)) return 0;
                return @intFromFloat(@min(k, @as(f32, @floatFromInt(n - 1))));
            }
        }.f;
        return .{ f(b[0], box[0], nx), f(b[1], box[1], ny), f(b[2], box[0], nx), f(b[3], box[1], ny) };
    }

    fn cellRange(box: [4]f32, nx: u32, ny: u32, s: Seg) [4]u32 {
        const r = 2 * s.hw;
        return cells(box, nx, ny, .{ @min(s.ax, s.bx) - r, @min(s.ay, s.by) - r, @max(s.ax, s.bx) + r, @max(s.ay, s.by) + r });
    }

    /// True if the point (x, y) is within the radius of a line of layer l:
    /// half its width and `extra` (flat) or its width (steep).
    fn near(l: *const Layer, x: f32, y: f32, flat: bool) bool {
        if (x < l.box[0] or y < l.box[1] or x > l.box[2] or y > l.box[3]) return false;
        const c = cells(l.box, l.nx, l.ny, .{ x, y, x, y });
        const k = c[1] * l.nx + c[0];
        for (l.cell_segs[l.cell_start[k]..l.cell_start[k + 1]]) |si| {
            const s = l.segs[si];
            const r = if (flat) s.hw - flat_margin else 2 * s.hw;
            if (dist2(x, y, s) <= r * r) return true;
        }
        return false;
    }

    /// True if a line of layer l may be within its radius of the box b.
    fn touches(l: *const Layer, b: [4]f32) bool {
        if (b[2] < l.box[0] or b[3] < l.box[1] or b[0] > l.box[2] or b[1] > l.box[3]) return false;
        const c = cells(l.box, l.nx, l.ny, b);
        var y = c[1];
        while (y <= c[3]) : (y += 1) {
            var x = c[0];
            while (x <= c[2]) : (x += 1) {
                const k = y * l.nx + x;
                for (l.cell_segs[l.cell_start[k]..l.cell_start[k + 1]]) |si| {
                    const s = l.segs[si];
                    const r = 2 * s.hw;
                    if (@min(s.ax, s.bx) - r <= b[2] and @max(s.ax, s.bx) + r >= b[0] and @min(s.ay, s.by) - r <= b[3] and @max(s.ay, s.by) + r >= b[1]) return true;
                }
            }
        }
        return false;
    }

    /// True if the point p is on the footprint of a layer of the body that
    /// holds its z.
    fn inside(b: *const Body, p: V3, flat: bool) bool {
        const eps: f32 = 1e-3;
        for (b.layers) |*l| {
            if (p[2] < l.z0 - eps) break;
            if (p[2] > l.z1 + eps) continue;
            if (near(l, p[0], p[1], flat)) return true;
        }
        return false;
    }

    fn isFlat(v: [3]V3) bool {
        const e1 = sub(v[1], v[0]);
        const e2 = sub(v[2], v[0]);
        const n = V3{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (!(len > 0)) return false;
        return @abs(n[2] / len) > 0.7;
    }

    fn zRange(v: [3]V3) [2]f32 {
        return .{ @min(v[0][2], @min(v[1][2], v[2][2])), @max(v[0][2], @max(v[1][2], v[2][2])) };
    }

    /// The test of paint.paintTriangle: 2 if the triangle is all on the
    /// body, 0 if no part of it can be, else 1.
    pub fn cover(b: *const Body, v: [3]V3) u8 {
        if (b.layers.len == 0) return 0;
        const z = zRange(v);
        if (z[1] < b.z_lo or z[0] > b.z_hi) return 0;
        const box = [4]f32{
            @min(v[0][0], @min(v[1][0], v[2][0])), @min(v[0][1], @min(v[1][1], v[2][1])),
            @max(v[0][0], @max(v[1][0], v[2][0])), @max(v[0][1], @max(v[1][1], v[2][1])),
        };
        var any = false;
        for (b.layers) |*l| {
            if (z[1] < l.z0 - 1e-3) break;
            if (z[0] > l.z1 + 1e-3) continue;
            if (touches(l, box)) {
                any = true;
                break;
            }
        }
        if (!any) return 0;
        if (z[0] <= b.z_lo or z[1] >= b.z_hi) return 1;
        // All in: the corners, the middles of the sides, and the center.
        const flat = isFlat(v);
        const pts = [7]V3{ v[0], v[1], v[2], mid(v[0], v[1]), mid(v[1], v[2]), mid(v[2], v[0]), center(v) };
        for (pts) |p| if (!b.inside(p, flat)) return 1;
        return 2;
    }

    /// The test of a small piece on the edge (see the header).
    pub fn holds(b: *const Body, v: [3]V3) bool {
        const z = zRange(v);
        if (z[0] <= b.z_lo or z[1] >= b.z_hi) return false;
        return b.inside(center(v), isFlat(v));
    }
};

fn dist2(x: f32, y: f32, s: Seg) f32 {
    const dx = s.bx - s.ax;
    const dy = s.by - s.ay;
    const len2 = dx * dx + dy * dy;
    var t: f32 = 0;
    if (len2 > 0) t = std.math.clamp(((x - s.ax) * dx + (y - s.ay) * dy) / len2, 0, 1);
    const ex = s.ax + t * dx - x;
    const ey = s.ay + t * dy - y;
    return ex * ex + ey * ey;
}

fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mid(a: V3, b: V3) V3 {
    return .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 };
}

fn center(v: [3]V3) V3 {
    return .{ (v[0][0] + v[1][0] + v[2][0]) / 3, (v[0][1] + v[1][1] + v[2][1]) / 3, (v[0][2] + v[1][2] + v[2][2]) / 3 };
}

/// Paints the body of part `part` in `beads` on `mesh` (the mesh of the
/// part on the bed) with `state`. Returns the count of triangles whose
/// paint changed.
pub fn paintBody(p: *paint_mod.Paint, gpa: Allocator, mesh: *const Mesh, beads: []const f32, part: u32, state: u8) Allocator.Error!usize {
    var body = try Body.init(gpa, beads, part);
    defer body.deinit();
    if (body.layers.len == 0) return 0;
    // Pieces as fine as half the thinnest layer, to place the ends of the
    // range.
    var h: f32 = std.math.inf(f32);
    for (body.layers) |l| h = @min(h, l.z1 - l.z0);
    const fine = @max(0.05, 0.5 * h);
    var changed: usize = 0;
    for (0..mesh.faces.items.len) |t| {
        if (try paint_mod.paintTriangle(p, gpa, mesh, t, &body, state, fine)) changed += 1;
    }
    return changed;
}

// ---- tests ----

const testing = std.testing;

/// A box of size sx, sy, sz with its corner at (x, y, 0): 12 triangles,
/// outward.
fn addBox(m: *Mesh, gpa: Allocator, x: f32, y: f32, sx: f32, sy: f32, sz: f32) !void {
    const base: u32 = @intCast(m.vertices.items.len);
    for (0..8) |k| try m.vertices.append(gpa, .{
        .x = x + if (k & 1 != 0) sx else 0,
        .y = y + if (k & 2 != 0) sy else 0,
        .z = if (k & 4 != 0) sz else 0,
    });
    const f = [_][3]u32{
        .{ 0, 2, 1 }, .{ 1, 2, 3 }, // bottom
        .{ 4, 5, 6 }, .{ 5, 7, 6 }, // top
        .{ 0, 1, 4 }, .{ 1, 5, 4 }, // y-
        .{ 2, 6, 3 }, .{ 3, 6, 7 }, // y+
        .{ 0, 4, 2 }, .{ 2, 4, 6 }, // x-
        .{ 1, 3, 5 }, .{ 3, 7, 5 }, // x+
    };
    for (f) |t| try m.faces.append(gpa, .{ base + t[0], base + t[1], base + t[2] });
}

/// The beads of the outer wall of a square tube at (x, y) of size s, on
/// layers lo to hi of height 0.2 (the wall center is 0.2 inside).
fn wallBeads(gpa: Allocator, out: *std.ArrayList(f32), x: f32, y: f32, s: f32, lo: u32, hi: u32) !void {
    const w: f32 = 0.4;
    const a = [_][2]f32{ .{ x + 0.2, y + 0.2 }, .{ x + s - 0.2, y + 0.2 }, .{ x + s - 0.2, y + s - 0.2 }, .{ x + 0.2, y + s - 0.2 } };
    var l = lo;
    while (l <= hi) : (l += 1) {
        const z: f32 = 0.2 * @as(f32, @floatFromInt(l + 1));
        for (0..4) |k| {
            const p = a[k];
            const q = a[(k + 1) % 4];
            try out.appendSlice(gpa, &.{ 0, @floatFromInt(l), z, 0.2, p[0], p[1], q[0], q[1], w });
        }
    }
}

/// The z range of the painted leaves of a mesh with `state`, and their
/// count.
const Seen = struct {
    lo: f32 = std.math.inf(f32),
    hi: f32 = -std.math.inf(f32),
    xmax: f32 = -std.math.inf(f32),
    n: usize = 0,
    state: u8,
    fn f(s: *Seen, a: V3, b: V3, c: V3, st: u8) void {
        if (st != s.state) return;
        s.n += 1;
        for ([_]V3{ a, b, c }) |q| {
            s.lo = @min(s.lo, q[2]);
            s.hi = @max(s.hi, q[2]);
            s.xmax = @max(s.xmax, q[0]);
        }
    }
};

test "paint_body: the lines of a body paint its sides in the range, and no other body" {
    const gpa = testing.allocator;
    var m: Mesh = .empty;
    defer m.deinit(gpa);
    // A tube (a 4 mm column, 10 mm tall) and a box next to it, 1 mm away.
    try addBox(&m, gpa, 0, 0, 4, 4, 10);
    try addBox(&m, gpa, 5, 0, 4, 4, 10);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    // Layers 10 to 19: z 2.0 to 4.0.
    try wallBeads(gpa, &beads, 0, 0, 4, 10, 19);
    var p: paint_mod.Paint = .{};
    defer p.deinit(gpa);
    const n = try paintBody(&p, gpa, &m, beads.items, 0, 2);
    try testing.expect(n > 0);
    var seen: Seen = .{ .state = 2 };
    for (0..m.faces.items.len) |t| p.leaves(&m, t, &seen, Seen.f);
    try testing.expect(seen.n > 0);
    // The paint stays in z 1.9 to 4.1 (the cut planes of layers 9 and 20)
    // and covers most of it.
    try testing.expect(seen.lo >= 1.9 and seen.lo <= 2.1);
    try testing.expect(seen.hi <= 4.1 and seen.hi >= 3.9);
    // The box next to it has no paint.
    try testing.expect(seen.xmax <= 4.01);
    for (12..24) |t| try testing.expectEqual(@as(u8, 0), p.stateOf(t));
    // The top and the bottom of the tube are out of the range: no paint.
    try testing.expectEqual(@as(u8, 0), p.stateOf(2));
    try testing.expectEqual(@as(u8, 0), p.stateOf(0));

    // Again: no change.
    try testing.expectEqual(@as(usize, 0), try paintBody(&p, gpa, &m, beads.items, 0, 2));
    // The beads of another part: no change.
    try testing.expectEqual(@as(usize, 0), try paintBody(&p, gpa, &m, beads.items, 1, 3));
}

test "paint_body: a range to the top of a body paints its top, inside the footprint" {
    const gpa = testing.allocator;
    var m: Mesh = .empty;
    defer m.deinit(gpa);
    // A 4 mm column, 2 mm tall: layers 0 to 9.
    try addBox(&m, gpa, 0, 0, 4, 4, 2);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    try wallBeads(gpa, &beads, 0, 0, 4, 5, 9);
    // The top layer is solid: lines across it.
    var y: f32 = 0.6;
    while (y < 3.5) : (y += 0.4) try beads.appendSlice(gpa, &.{ 0, 9, 2.0, 0.2, 0.2, y, 3.8, y, 0.4 });
    var p: paint_mod.Paint = .{};
    defer p.deinit(gpa);
    _ = try paintBody(&p, gpa, &m, beads.items, 0, 3);
    // Most of the top (faces 2 and 3, 16 mm²) is painted; the bottom is
    // not.
    var area: Area = .{ .state = 3 };
    p.leaves(&m, 2, &area, Area.f);
    p.leaves(&m, 3, &area, Area.f);
    try testing.expect(area.a > 15 and area.a <= 16);
    try testing.expectEqual(@as(u8, 0), p.stateOf(0));
    try testing.expectEqual(@as(u8, 0), p.stateOf(1));
}

/// The area of the leaves with `state`.
const Area = struct {
    a: f32 = 0,
    state: u8,
    fn f(s: *Area, a: V3, b: V3, c: V3, st: u8) void {
        if (st != s.state) return;
        const e1 = sub(b, a);
        const e2 = sub(c, a);
        const n = V3{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        s.a += 0.5 * @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    }
};
