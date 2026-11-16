//! The plate: the parts on the bed, each with its place and its turn.
//!
//! Each part keeps its mesh as the file had it. Its place is the center of
//! its footprint (the box of the turned part, seen from above) in bed
//! coordinates, and its turn is around the vertical axis through the
//! center of its box. `combined` makes one mesh of all parts at their
//! places, each with its bottom at z = 0, for the engine. So the engine
//! slices a plate as it slices one part.
//!
//! A new part keeps the place of its file if it is on the bed there and
//! does not touch another part; else it goes to a free place, from the
//! center out. `arrange` packs all parts in rows, the largest first, with
//! a gap between them, and puts the rows in the middle of the bed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

pub const Part = struct {
    name: []u8,
    mesh: Mesh,
    /// The center of the footprint, in bed coordinates (mm).
    x: f64,
    y: f64,
    /// The turn around the vertical axis, in degrees.
    rot: f64 = 0,
    /// The footprint of the turned part, from its center: the half width
    /// and the half depth, and where the center of the box is from the
    /// turn center (so that x, y is the center of the footprint).
    half: [2]f64 = .{ 0, 0 },
    shift: [2]f64 = .{ 0, 0 },
    height: f64 = 0,

    fn turnCenter(p: *const Part) [2]f64 {
        const b = p.mesh.bounds();
        return .{ (b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2 };
    }

    /// Computes the footprint after a change of the turn.
    fn measure(p: *Part) void {
        const c = p.turnCenter();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        var lo = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        var hi = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
        var zlo: f64 = std.math.inf(f64);
        var zhi: f64 = -std.math.inf(f64);
        for (p.mesh.vertices.items) |v| {
            const dx = v.x - c[0];
            const dy = v.y - c[1];
            const rx = dx * ca - dy * sa;
            const ry = dx * sa + dy * ca;
            lo = .{ @min(lo[0], rx), @min(lo[1], ry) };
            hi = .{ @max(hi[0], rx), @max(hi[1], ry) };
            zlo = @min(zlo, v.z);
            zhi = @max(zhi, v.z);
        }
        p.half = .{ (hi[0] - lo[0]) / 2, (hi[1] - lo[1]) / 2 };
        p.shift = .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
        p.height = zhi - zlo;
    }

    /// The transform of the part from its file to the bed, as a 3MF
    /// transform (a 4x3 matrix for row vectors): the turn around the turn
    /// center, the move to the place, and the bottom to z = 0.
    pub fn transform(p: *const Part) [12]f64 {
        const c = p.turnCenter();
        const b = p.mesh.bounds();
        const a = std.math.degreesToRadians(p.rot);
        const ca = @cos(a);
        const sa = @sin(a);
        // x' = ca (x - cx) - sa (y - cy) - shift x + x0, and the same for y.
        return .{
            ca,  sa, 0,
            -sa, ca, 0,
            0,   0,  1,
            p.x - p.shift[0] - ca * c[0] + sa * c[1],
            p.y - p.shift[1] - sa * c[0] - ca * c[1],
            -b.min[2],
        };
    }

    /// The footprint box: x0, y0, x1, y1.
    pub fn footprint(p: *const Part) [4]f64 {
        return .{ p.x - p.half[0], p.y - p.half[1], p.x + p.half[0], p.y + p.half[1] };
    }
};

pub const Plate = struct {
    parts: std.ArrayList(Part) = .empty,

    pub fn deinit(self: *Plate, gpa: Allocator) void {
        for (self.parts.items) |*p| {
            p.mesh.deinit(gpa);
            gpa.free(p.name);
        }
        self.parts.deinit(gpa);
    }

    pub fn clear(self: *Plate, gpa: Allocator) void {
        self.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const Plate) usize {
        return self.parts.items.len;
    }

    /// Adds a part. The plate owns the mesh after the call (also on an
    /// error). `keep_file`: the part keeps the place of its file if it is
    /// on the bed there (with `gap` around it) and touches no other part.
    pub fn add(self: *Plate, gpa: Allocator, name: []const u8, mesh: Mesh, bed: [2]f64, gap: f64, keep_file: bool) Allocator.Error!usize {
        var m = mesh;
        const n = gpa.dupe(u8, name) catch |e| {
            m.deinit(gpa);
            return e;
        };
        var part: Part = .{ .name = n, .mesh = m, .x = 0, .y = 0 };
        part.measure();
        const b = m.bounds();
        part.x = (b.min[0] + b.max[0]) / 2;
        part.y = (b.min[1] + b.max[1]) / 2;
        if (!(keep_file and self.fits(&part, bed, gap, null))) {
            const spot = self.freeSpot(&part, bed, gap);
            part.x = spot[0];
            part.y = spot[1];
        }
        self.parts.append(gpa, part) catch |e| {
            part.mesh.deinit(gpa);
            gpa.free(part.name);
            return e;
        };
        return self.parts.items.len - 1;
    }

    pub fn remove(self: *Plate, gpa: Allocator, i: usize) void {
        if (i >= self.parts.items.len) return;
        var p = self.parts.orderedRemove(i);
        p.mesh.deinit(gpa);
        gpa.free(p.name);
    }

    pub fn move(self: *Plate, i: usize, x: f64, y: f64) void {
        if (i >= self.parts.items.len) return;
        self.parts.items[i].x = x;
        self.parts.items[i].y = y;
    }

    /// Sets the turn of a part, in degrees, around the center of its
    /// footprint (the part stays at the same place).
    pub fn rotate(self: *Plate, i: usize, deg: f64) void {
        if (i >= self.parts.items.len) return;
        const p = &self.parts.items[i];
        p.rot = @mod(deg, 360);
        p.measure();
    }

    /// The part whose footprint holds the point, or null. A smaller part
    /// wins, so a part next to a large one can be picked.
    pub fn partAt(self: *const Plate, x: f64, y: f64) ?usize {
        var best: ?usize = null;
        var best_area: f64 = std.math.inf(f64);
        for (self.parts.items, 0..) |*p, i| {
            const f = p.footprint();
            if (x < f[0] or x > f[2] or y < f[1] or y > f[3]) continue;
            const area = (f[2] - f[0]) * (f[3] - f[1]);
            if (area < best_area) {
                best = i;
                best_area = area;
            }
        }
        return best;
    }

    fn overlaps(self: *const Plate, part: *const Part, gap: f64, skip: ?usize) bool {
        const f = part.footprint();
        for (self.parts.items, 0..) |*o, i| {
            if (skip != null and skip.? == i) continue;
            if (o == part) continue;
            const g = o.footprint();
            if (f[0] < g[2] + gap and g[0] < f[2] + gap and f[1] < g[3] + gap and g[1] < f[3] + gap) return true;
        }
        return false;
    }

    fn fits(self: *const Plate, part: *const Part, bed: [2]f64, gap: f64, skip: ?usize) bool {
        const f = part.footprint();
        if (f[0] < gap or f[1] < gap or f[2] > bed[0] - gap or f[3] > bed[1] - gap) return false;
        return !self.overlaps(part, gap, skip);
    }

    /// A free place for a part: the center of the bed, or the nearest free
    /// place to it on a 5 mm grid. If there is none, the center.
    fn freeSpot(self: *const Plate, part: *const Part, bed: [2]f64, gap: f64) [2]f64 {
        var probe = part.*;
        const cx = bed[0] / 2;
        const cy = bed[1] / 2;
        const step = 5.0;
        const rings: usize = @intFromFloat(@ceil(@max(bed[0], bed[1]) / step));
        for (0..rings + 1) |r| {
            const rf: f64 = @floatFromInt(r);
            // The points of the square ring at distance r steps.
            var k: i64 = -@as(i64, @intCast(r));
            while (k <= @as(i64, @intCast(r))) : (k += 1) {
                const kf: f64 = @floatFromInt(k);
                const cands = [_][2]f64{
                    .{ cx + kf * step, cy - rf * step }, .{ cx + kf * step, cy + rf * step },
                    .{ cx - rf * step, cy + kf * step }, .{ cx + rf * step, cy + kf * step },
                };
                for (cands) |c| {
                    probe.x = c[0];
                    probe.y = c[1];
                    if (self.fits(&probe, bed, gap, null)) return c;
                }
            }
        }
        return .{ cx, cy };
    }

    /// Packs all parts in rows across the bed (the largest footprint
    /// first), with `gap` between them, and puts the block in the middle
    /// of the bed. Returns false if the parts do not all fit; they are then
    /// in rows past the bed edge.
    pub fn arrange(self: *Plate, gpa: Allocator, bed: [2]f64, gap: f64) Allocator.Error!bool {
        const n = self.parts.items.len;
        if (n == 0) return true;
        const order = try gpa.alloc(usize, n);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        const parts = self.parts.items;
        std.mem.sort(usize, order, parts, struct {
            fn lt(ps: []Part, a: usize, b: usize) bool {
                const ha = ps[a].half[1];
                const hb = ps[b].half[1];
                if (ha != hb) return ha > hb;
                return ps[a].half[0] > ps[b].half[0];
            }
        }.lt);
        // Shelves: a row is as deep as its first (deepest) part.
        var x: f64 = 0;
        var y: f64 = 0;
        var row_depth: f64 = 0;
        var width: f64 = 0;
        const room = bed[0] - 2 * gap;
        for (order) |i| {
            const p = &parts[i];
            const w = 2 * p.half[0];
            const d = 2 * p.half[1];
            if (x > 0 and x + w > room) {
                y += row_depth + gap;
                x = 0;
                row_depth = 0;
            }
            p.x = x + p.half[0];
            p.y = y + p.half[1];
            x += w + gap;
            row_depth = @max(row_depth, d);
            width = @max(width, x - gap);
        }
        const depth = y + row_depth;
        // The block in the middle of the bed.
        const ox = (bed[0] - width) / 2;
        const oy = (bed[1] - depth) / 2;
        for (parts) |*p| {
            p.x += ox;
            p.y += oy;
        }
        return width <= bed[0] - 2 * gap + 1e-6 and depth <= bed[1] - 2 * gap + 1e-6;
    }

    /// One mesh of all parts at their places, each with its bottom at
    /// z = 0. The caller owns the result.
    pub fn combined(self: *const Plate, gpa: Allocator) Allocator.Error!Mesh {
        var out: Mesh = .empty;
        errdefer out.deinit(gpa);
        for (self.parts.items) |*p| {
            const c = p.turnCenter();
            const b = p.mesh.bounds();
            const a = std.math.degreesToRadians(p.rot);
            const ca = @cos(a);
            const sa = @sin(a);
            const base: u32 = @intCast(out.vertices.items.len);
            try out.vertices.ensureUnusedCapacity(gpa, p.mesh.vertices.items.len);
            for (p.mesh.vertices.items) |v| {
                const dx = v.x - c[0];
                const dy = v.y - c[1];
                const rx = dx * ca - dy * sa - p.shift[0];
                const ry = dx * sa + dy * ca - p.shift[1];
                out.vertices.appendAssumeCapacity(.{
                    .x = @floatCast(p.x + rx),
                    .y = @floatCast(p.y + ry),
                    .z = @floatCast(v.z - b.min[2]),
                });
            }
            try out.faces.ensureUnusedCapacity(gpa, p.mesh.faces.items.len);
            for (p.mesh.faces.items) |f| out.faces.appendAssumeCapacity(.{ f[0] + base, f[1] + base, f[2] + base });
        }
        return out;
    }
};

const testing = std.testing;

fn box(gpa: Allocator, x0: f64, y0: f64, x1: f64, y1: f64, h: f64) !Mesh {
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, x0, y0, 0, x1, y1, h);
    return b.finish();
}

test "plate: file place, free place, arrange, and the combined mesh" {
    const gpa = testing.allocator;
    var plate: Plate = .{};
    defer plate.deinit(gpa);
    const bed = [2]f64{ 200, 200 };
    // A part on the bed in its file keeps its place.
    _ = try plate.add(gpa, "a", try box(gpa, 10, 10, 30, 20, 5), bed, 3, true);
    try testing.expectApproxEqAbs(@as(f64, 20), plate.parts.items[0].x, 1e-6);
    // The same part again: its file place is taken, so it goes elsewhere,
    // and does not touch the first.
    _ = try plate.add(gpa, "b", try box(gpa, 10, 10, 30, 20, 5), bed, 3, true);
    const fa = plate.parts.items[0].footprint();
    const fb = plate.parts.items[1].footprint();
    try testing.expect(fb[0] >= fa[2] + 3 - 1e-6 or fa[0] >= fb[2] + 3 - 1e-6 or fb[1] >= fa[3] + 3 - 1e-6 or fa[1] >= fb[3] + 3 - 1e-6);
    // A part around the origin goes to a free place on the bed.
    _ = try plate.add(gpa, "c", try box(gpa, -5, -5, 5, 5, 8), bed, 3, true);
    const fc = plate.parts.items[2].footprint();
    try testing.expect(fc[0] >= 3 and fc[1] >= 3);
    // A turn of 90 degrees swaps the width and the depth.
    plate.rotate(0, 90);
    try testing.expectApproxEqAbs(@as(f64, 5), plate.parts.items[0].half[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 10), plate.parts.items[0].half[1], 1e-4);
    // Arrange: all fit, and no two touch.
    try testing.expect(try plate.arrange(gpa, bed, 3));
    for (plate.parts.items, 0..) |*p, i| for (plate.parts.items[i + 1 ..]) |*q| {
        const f = p.footprint();
        const g = q.footprint();
        try testing.expect(!(f[0] < g[2] + 3 - 1e-6 and g[0] < f[2] + 3 - 1e-6 and f[1] < g[3] + 3 - 1e-6 and g[1] < f[3] + 3 - 1e-6));
    };
    // The combined mesh: all parts, bottoms at 0, and its box is the
    // union of the footprints.
    var m = try plate.combined(gpa);
    defer m.deinit(gpa);
    try testing.expectEqual(@as(usize, 36), m.faces.items.len);
    const b = m.bounds();
    try testing.expectApproxEqAbs(@as(f64, 0), b.min[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 8), b.max[2], 1e-4);
    // The picked part: the point at the center of part c.
    try testing.expectEqual(@as(?usize, 2), plate.partAt(plate.parts.items[2].x, plate.parts.items[2].y));
}
