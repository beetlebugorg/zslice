//! The bond of the first layer to the bed, and the test that a part stands
//! while it prints.
//!
//! physics.zig asks if a part stands on its own weight alone. A printed
//! part also sticks to the bed, and the nozzle pushes on it. This file
//! asks if the bond holds the part against these loads.
//!
//! - **The loads.** The weight W of the part acts at its center of mass.
//!   The nozzle pushes on the top of the part from the side with a force
//!   F, at the height H of the part (the worst case: the last layer). The
//!   part tips about a line on the bed: the edge of its first layer in
//!   the direction of the tip. The moment about that line is
//!   F H + W d, with d the distance of the center of mass past the line
//!   (less than 0: the weight holds the part down).
//! - **The bond.** The first layer and the brim stick to the bed with a
//!   tensile strength sigma (N/mm²). The part is a rigid plate that turns
//!   about the edge: the pull on the bond grows in a straight line from 0
//!   at the edge to the most at the far side, as in the bend of a beam.
//!   The bond lets go when that pull reaches sigma at the far side. So it
//!   holds a moment sigma I / c, with I the integral of y² over the
//!   bonded area and c the largest y (y is the distance from the edge).
//!   The brim on the side of the tip lies under the edge and does not
//!   pull, so only y > 0 counts.
//! - **The area.** The first layer is the section of the mesh at the
//!   middle of the first layer. A grid of cells holds it: a cell is in
//!   the first layer if its center is inside the section (even-odd rule
//!   along each row). The brim is the cells within the brim width of the
//!   first layer: outside it, in its holes, or both. A two-pass distance
//!   transform (steps of 1 and sqrt(2) cells) gives the distances.
//! - **The test.** The part stands if, in each of 72 directions on the
//!   bed, the moment is at most what the bond holds. The result also
//!   says if the part stands with no brim, and the least ratio of the
//!   hold to the moment (the margin).
//!
//! The numbers (see docs/references/, "Bond of the first layer"):
//!
//! - Pull-off tests of printed PLA and PETG give 0.4 to about 2 N/mm² on a
//!   metal bed (Campos-Jurado et al. 2025). PLA reaches up to 0.56 N/mm²
//!   with a tuned first layer (Laumann et al. 2023). zslice takes a usual
//!   0.3 N/mm² for PLA and ABS on PEI, and 0.45 N/mm² for PETG.
//! - On bare glass, PLA needs 0.27 times the force to push a part off as
//!   on a polymer film (Snapp et al. 2021). zslice uses this ratio for
//!   glass.
//! - ABS and PLA reach the same shear-off forces (Spoerk et al. 2018).
//! - No paper that we found measures the side push of the nozzle on a
//!   part. zslice takes 0.3 N, as for the tree support (support.zig).
//!
//! The model is simple: a rigid part and a rigid brim, an even bond, and
//! no warp. A real brim is a thin film and bends, so a wide brim holds
//! less than this model says.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const physics = @import("physics.zig");

/// The plastic of the part, for the strength of the bond.
pub const Material = enum { pla, petg, abs, other };

/// The surface of the bed.
pub const Bed = enum { smooth_pei, textured_pei, glass };

/// The material of a filament type name ("PLA", "PETG", "ABS", ...).
pub fn materialOf(name: []const u8) Material {
    if (std.ascii.startsWithIgnoreCase(name, "PETG")) return .petg;
    if (std.ascii.startsWithIgnoreCase(name, "PLA")) return .pla;
    if (std.ascii.startsWithIgnoreCase(name, "ABS")) return .abs;
    return .other;
}

/// The ratio of the bond on bare glass to the bond on a polymer film
/// (Snapp et al. 2021).
pub const glass_ratio = 0.27;

/// The tensile strength of the bond of the first layer to the bed, N/mm²,
/// for a usual print (a clean bed at the usual temperature).
pub fn strength(m: Material, b: Bed) f64 {
    const pei: f64 = switch (m) {
        .pla, .abs, .other => 0.3,
        .petg => 0.45,
    };
    // No measure of textured PEI was found: it gets the value of smooth
    // PEI.
    return switch (b) {
        .smooth_pei, .textured_pei => pei,
        .glass => pei * glass_ratio,
    };
}

/// The side push of the nozzle on the top of a part, N (as for the tree
/// support in support.zig).
pub const nozzle_push = 0.3;

/// The acceleration of gravity, m/s².
const gravity = 9.81;

pub const Options = struct {
    /// The tensile strength of the bond, N/mm².
    strength: f64 = 0.3,
    /// The density of the plastic, g/cm³.
    density: f64 = 1.24,
    /// The height of the first layer, mm.
    first_layer_height: f64 = 0.2,
    /// The side push of the nozzle, N.
    push: f64 = nozzle_push,
    /// The width of the brim, mm (0: no brim), and where it goes.
    brim_width: f64 = 0,
    brim_outside: bool = true,
    brim_inside: bool = false,
};

pub const Result = struct {
    /// The part stands, with the brim.
    stands: bool = true,
    /// The part stands with no brim.
    stands_bare: bool = true,
    /// The moment that tips the part (N mm) and the moment that the bond
    /// holds (N mm), in the worst direction.
    load: f64 = 0,
    hold: f64 = 0,
    /// The same hold with no brim.
    hold_bare: f64 = 0,
    /// The worst direction: the way the part tips, a unit vector on the
    /// bed.
    dir: [2]f64 = .{ 1, 0 },
    /// The least ratio of the hold to the moment (inf: nothing tips it).
    margin: f64 = std.math.inf(f64),
};

const directions = 72;
/// The most cells of the grid.
const max_cells = 512 * 512;

/// The test of the bond of a part (its mesh as it is on the bed, z up).
pub fn check(a: Allocator, mesh: *const Mesh, o: Options) Allocator.Error!Result {
    const vs = mesh.vertices.items;
    if (vs.len == 0) return .{};
    var zmin: f64 = std.math.inf(f64);
    var zmax: f64 = -std.math.inf(f64);
    for (vs) |v| {
        zmin = @min(zmin, v.z);
        zmax = @max(zmax, v.z);
    }
    const zs = zmin + @max(o.first_layer_height, 0.01) / 2;

    // The section at the middle of the first layer, as segments.
    var segs: std.ArrayList([4]f64) = .empty;
    defer segs.deinit(a);
    for (mesh.faces.items) |f| {
        var pts: [2][2]f64 = undefined;
        var n: usize = 0;
        for (0..3) |k| {
            const p = vs[f[k]];
            const q = vs[f[(k + 1) % 3]];
            const pz: f64 = p.z;
            const qz: f64 = q.z;
            if ((pz < zs) == (qz < zs)) continue;
            const t = (zs - pz) / (qz - pz);
            if (n < 2) pts[n] = .{ p.x + t * (@as(f64, q.x) - p.x), p.y + t * (@as(f64, q.y) - p.y) };
            n += 1;
        }
        if (n == 2) try segs.append(a, .{ pts[0][0], pts[0][1], pts[1][0], pts[1][1] });
    }
    if (segs.items.len == 0) return .{};

    // The loads in each direction. The pivot is the support line of the
    // section in that direction.
    const mp = physics.massOf(mesh);
    // mm³ times g/cm³ is 1e-3 g, so 1e-6 kg.
    const weight = @abs(mp.volume) * o.density * 1e-6 * gravity; // N
    const push_moment = o.push * (zmax - zmin);
    var loads: [directions]f64 = undefined;
    var pivots: [directions]f64 = undefined;
    var dirs: [directions][2]f64 = undefined;
    var any = false;
    for (0..directions) |k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / directions;
        const n = [2]f64{ @cos(t), @sin(t) };
        var h: f64 = -std.math.inf(f64);
        for (segs.items) |s| h = @max(h, @max(s[0] * n[0] + s[1] * n[1], s[2] * n[0] + s[3] * n[1]));
        const d = mp.center[0] * n[0] + mp.center[1] * n[1] - h;
        dirs[k] = n;
        pivots[k] = h;
        loads[k] = push_moment + weight * d;
        if (loads[k] > 0) any = true;
    }
    if (!any) return .{};

    // The grid: the box of the section and the brim around it.
    var x0: f64 = std.math.inf(f64);
    var y0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    var y1: f64 = -std.math.inf(f64);
    for (segs.items) |s| {
        x0 = @min(x0, @min(s[0], s[2]));
        x1 = @max(x1, @max(s[0], s[2]));
        y0 = @min(y0, @min(s[1], s[3]));
        y1 = @max(y1, @max(s[1], s[3]));
    }
    const brim = @max(o.brim_width, 0);
    const sx = x1 - x0 + 2 * brim;
    const sy = y1 - y0 + 2 * brim;
    const g = @max(@sqrt(@max(sx * sy, 1e-6) / (max_cells / 4)), @max(@max(sx, sy) / 4096, 0.002));
    x0 -= brim + 2 * g;
    y0 -= brim + 2 * g;
    const nx: usize = @intFromFloat(@ceil((sx + 4 * g) / g));
    const ny: usize = @intFromFloat(@ceil((sy + 4 * g) / g));
    const cells = try a.alloc(u8, nx * ny);
    defer a.free(cells);
    @memset(cells, 0);
    try fillSection(a, segs.items, x0, y0, g, nx, ny, cells);

    if (brim > 0 and (o.brim_outside or o.brim_inside)) {
        const dist = try a.alloc(f32, nx * ny);
        defer a.free(dist);
        for (cells, dist) |c, *d| d.* = if (c == part) 0 else std.math.inf(f32);
        chamfer(dist, nx, ny);
        const outer = try outside(a, cells, nx, ny);
        defer a.free(outer);
        const lim: f32 = @floatCast(brim / g);
        for (cells, dist, outer) |*c, d, out| {
            if (c.* == part or d > lim) continue;
            if ((out and o.brim_outside) or (!out and o.brim_inside)) c.* = brim_cell;
        }
    }

    var r: Result = .{};
    const area = g * g;
    for (0..directions) |k| {
        if (!(loads[k] > 0)) continue;
        const n = dirs[k];
        var s_all: f64 = 0;
        var c_all: f64 = 0;
        var s_bare: f64 = 0;
        var c_bare: f64 = 0;
        for (0..ny) |j| {
            const yc = y0 + (@as(f64, @floatFromInt(j)) + 0.5) * g;
            const row = cells[j * nx ..][0..nx];
            for (row, 0..) |c, i| {
                if (c == 0) continue;
                const xc = x0 + (@as(f64, @floatFromInt(i)) + 0.5) * g;
                const y = pivots[k] - (xc * n[0] + yc * n[1]);
                if (!(y > 0)) continue;
                s_all += y * y;
                c_all = @max(c_all, y);
                if (c == part) {
                    s_bare += y * y;
                    c_bare = @max(c_bare, y);
                }
            }
        }
        const hold = if (c_all > 0) o.strength * area * s_all / c_all else 0;
        const hold_bare = if (c_bare > 0) o.strength * area * s_bare / c_bare else 0;
        if (loads[k] > hold) r.stands = false;
        if (loads[k] > hold_bare) r.stands_bare = false;
        const ratio = hold / loads[k];
        if (ratio < r.margin) {
            r.margin = ratio;
            r.load = loads[k];
            r.hold = hold;
            r.hold_bare = hold_bare;
            r.dir = n;
        }
    }
    return r;
}

const part: u8 = 1;
const brim_cell: u8 = 2;

/// Marks the cells whose centers are inside the section (even-odd rule
/// along each row).
fn fillSection(a: Allocator, segs: []const [4]f64, x0: f64, y0: f64, g: f64, nx: usize, ny: usize, cells: []u8) Allocator.Error!void {
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(a);
    for (0..ny) |j| {
        const yc = y0 + (@as(f64, @floatFromInt(j)) + 0.5) * g;
        xs.clearRetainingCapacity();
        for (segs) |s| {
            if ((s[1] < yc) == (s[3] < yc)) continue;
            const t = (yc - s[1]) / (s[3] - s[1]);
            try xs.append(a, s[0] + t * (s[2] - s[0]));
        }
        std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
        var k: usize = 0;
        while (k + 1 < xs.items.len) : (k += 2) {
            // The cells with their centers in [xs[k], xs[k+1]].
            const fa = @ceil((xs.items[k] - x0) / g - 0.5);
            const fb = @floor((xs.items[k + 1] - x0) / g - 0.5);
            if (fb < fa) continue;
            const ia: usize = @intFromFloat(std.math.clamp(fa, 0, @as(f64, @floatFromInt(nx - 1))));
            const ib: usize = @intFromFloat(std.math.clamp(fb, 0, @as(f64, @floatFromInt(nx - 1))));
            @memset(cells[j * nx + ia .. j * nx + ib + 1], part);
        }
    }
}

/// The distance (in cells) of each cell to the nearest cell with 0: two
/// passes, with steps of 1 and sqrt(2).
fn chamfer(d: []f32, nx: usize, ny: usize) void {
    const s2: f32 = std.math.sqrt2;
    for (0..ny) |j| for (0..nx) |i| {
        var v = d[j * nx + i];
        if (i > 0) v = @min(v, d[j * nx + i - 1] + 1);
        if (j > 0) {
            v = @min(v, d[(j - 1) * nx + i] + 1);
            if (i > 0) v = @min(v, d[(j - 1) * nx + i - 1] + s2);
            if (i + 1 < nx) v = @min(v, d[(j - 1) * nx + i + 1] + s2);
        }
        d[j * nx + i] = v;
    };
    var j = ny;
    while (j > 0) {
        j -= 1;
        var i = nx;
        while (i > 0) {
            i -= 1;
            var v = d[j * nx + i];
            if (i + 1 < nx) v = @min(v, d[j * nx + i + 1] + 1);
            if (j + 1 < ny) {
                v = @min(v, d[(j + 1) * nx + i] + 1);
                if (i + 1 < nx) v = @min(v, d[(j + 1) * nx + i + 1] + s2);
                if (i > 0) v = @min(v, d[(j + 1) * nx + i - 1] + s2);
            }
            d[j * nx + i] = v;
        }
    }
}

/// The cells that are not in the part and that join the edge of the
/// grid: the outside of the part (the others are its holes).
fn outside(a: Allocator, cells: []const u8, nx: usize, ny: usize) Allocator.Error![]bool {
    const out = try a.alloc(bool, nx * ny);
    errdefer a.free(out);
    @memset(out, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(a);
    for (0..nx) |i| {
        try stack.append(a, i);
        try stack.append(a, (ny - 1) * nx + i);
    }
    for (0..ny) |j| {
        try stack.append(a, j * nx);
        try stack.append(a, j * nx + nx - 1);
    }
    while (stack.pop()) |c| {
        if (out[c] or cells[c] == part) continue;
        out[c] = true;
        const i = c % nx;
        const j = c / nx;
        if (i > 0) try stack.append(a, c - 1);
        if (i + 1 < nx) try stack.append(a, c + 1);
        if (j > 0) try stack.append(a, c - nx);
        if (j + 1 < ny) try stack.append(a, c + nx);
    }
    return out;
}

const testing = std.testing;

fn build(gpa: Allocator, boxes: []const [6]f64) !Mesh {
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    for (boxes) |x| try mesh_mod.shapes.addBox(&b, x[0], x[1], x[2], x[3], x[4], x[5]);
    return b.finish();
}

fn brimmed(w: f64) Options {
    return .{ .brim_width = w };
}

test "bond: a box stands with and without a brim" {
    const gpa = testing.allocator;
    var m = try build(gpa, &.{.{ 0, 0, 0, 20, 20, 20 }});
    defer m.deinit(gpa);
    for ([_]f64{ 0, 3, 8 }) |w| {
        const r = try check(gpa, &m, brimmed(w));
        try testing.expect(r.stands);
        try testing.expect(r.stands_bare);
        // A wide margin: the push makes 6 N mm, the bond holds about 800.
        try testing.expect(r.margin > 50);
    }
}

test "bond: the hold of a square foot is sigma b d² / 3" {
    const gpa = testing.allocator;
    // A post of 10 x 10 mm, 30 mm tall: the push makes 9 N mm. The bond
    // about an edge holds 0.3 * 10 * 10² / 3 = 100 N mm.
    var m = try build(gpa, &.{.{ 0, 0, 0, 10, 10, 30 }});
    defer m.deinit(gpa);
    const r = try check(gpa, &m, .{});
    try testing.expect(r.stands);
    // The worst direction is across an edge, not a corner (a corner
    // holds more).
    try testing.expectApproxEqRel(@as(f64, 100), r.hold, 0.03);
    // The weight holds a little: 3 cm³ of PLA, 5 mm inside the edge.
    const w = 3.0 * 1.24 * 1e-3 * 9.81;
    try testing.expectApproxEqRel(9 - 5 * w, r.load, 1e-3);
}

test "bond: a thin pin tips with no brim, and an 8 mm brim holds it" {
    const gpa = testing.allocator;
    // A pin of 4 x 4 mm, 40 mm tall: the push makes 12 N mm, the bare
    // foot holds 0.3 * 4 * 4² / 3 = 6.4 N mm.
    var m = try build(gpa, &.{.{ 0, 0, 0, 4, 4, 40 }});
    defer m.deinit(gpa);
    const bare = try check(gpa, &m, .{});
    try testing.expect(!bare.stands);
    try testing.expect(!bare.stands_bare);
    const r = try check(gpa, &m, brimmed(8));
    try testing.expect(r.stands);
    try testing.expect(!r.stands_bare);
    try testing.expect(r.hold > r.load and r.hold_bare < r.load);
}

test "bond: a tall thin pin tips even with a brim" {
    const gpa = testing.allocator;
    // A pin of 2 x 2 mm, 120 mm tall: the push makes 36 N mm. A 2 mm
    // brim holds about 10 N mm.
    var m = try build(gpa, &.{.{ 0, 0, 0, 2, 2, 120 }});
    defer m.deinit(gpa);
    const r = try check(gpa, &m, brimmed(2));
    try testing.expect(!r.stands);
    try testing.expect(r.load > 3 * r.hold);
}

test "bond: the cantilever of the stress parts stands, with or without a brim" {
    const gpa = testing.allocator;
    // A post of 10 x 10 x 20 mm and a slab of 50 x 10 x 3 mm on it: the
    // center of mass is 3.6 mm past the post. Its weight (43 mN) adds
    // 0.15 N mm to the 6.9 N mm of the push; the post holds 100 N mm.
    var m = try build(gpa, &.{ .{ 0, 0, 0, 10, 10, 20 }, .{ 0, 0, 20, 50, 10, 23 } });
    defer m.deinit(gpa);
    try testing.expect((try physics.settle(gpa, &m)).rolls > 0);
    const r = try check(gpa, &m, .{});
    try testing.expect(r.stands);
    try testing.expect(r.margin > 10);
}

test "bond: a board on its edge tips with no brim, and a brim holds it" {
    const gpa = testing.allocator;
    // A board of 40 x 10 x 4 mm turned 45 degrees about X: it stands on
    // a long edge, and its first layer is a strip 0.2 mm wide.
    var m = try build(gpa, &.{.{ 0, 0, 0, 40, 10, 4 }});
    defer m.deinit(gpa);
    const c = @cos(std.math.pi / 4.0);
    const s = @sin(std.math.pi / 4.0);
    for (m.vertices.items) |*v| {
        const y = v.y;
        const z = v.z;
        v.y = @floatCast(c * y - s * z);
        v.z = @floatCast(s * y + c * z);
    }
    try testing.expect(!(try check(gpa, &m, .{})).stands);
    const r = try check(gpa, &m, brimmed(8));
    try testing.expect(r.stands);
    try testing.expect(!r.stands_bare);
}

test "bond: a brim in the holes holds only a part with holes" {
    const gpa = testing.allocator;
    // A ring of 4 posts (a square tube 12 x 12 mm, walls 1 mm), 60 mm
    // tall: an inside brim fills the hole, an outside brim goes around.
    var m = try build(gpa, &.{
        .{ 0, 0, 0, 12, 1, 60 }, .{ 0, 11, 0, 12, 12, 60 },
        .{ 0, 1, 0, 1, 11, 60 }, .{ 11, 1, 0, 12, 11, 60 },
    });
    defer m.deinit(gpa);
    const bare = try check(gpa, &m, .{});
    const inside = try check(gpa, &m, .{ .brim_width = 8, .brim_outside = false, .brim_inside = true });
    const out = try check(gpa, &m, .{ .brim_width = 8 });
    try testing.expect(inside.hold > bare.hold * 1.2);
    try testing.expect(out.hold > inside.hold);
}

test "bond: strengths by material and bed" {
    try testing.expectEqual(Material.petg, materialOf("PETG"));
    try testing.expectEqual(Material.pla, materialOf("pla+"));
    try testing.expectEqual(Material.other, materialOf("TPU"));
    try testing.expectEqual(@as(f64, 0.3), strength(.pla, .smooth_pei));
    try testing.expect(strength(.pla, .glass) < strength(.pla, .textured_pei));
    try testing.expect(strength(.petg, .smooth_pei) > strength(.abs, .smooth_pei));
}
