//! Island detection: shapes that start in the air.
//!
//! An island is a polygon of the outline of a layer (an outer boundary,
//! with its area) that has nothing under it: no outline of the layer
//! below, and no support of the layer below, under any part of it. A
//! correct part has islands only on layer 0 (on the bed). An island on a
//! higher layer prints in the air: it falls, or makes a string. It comes
//! from an overhang with no support (a mushroom cap with support off), or
//! from a slicing error. The app shows each island with its layer and its
//! place, so the user can add support there or check the model.
//!
//! The test of a polygon: its area inside the outline and the support of
//! the layer below (both grown by a quarter of a line width, so that a
//! wall that steps in a little still counts as on the layer below). If
//! that is less than 1 % of its area, it is an island. Each layer is
//! independent, so the layers run on all threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const slicer = @import("slicer.zig");
const support_mod = @import("support.zig");
const parallel = @import("parallel.zig");
const Paths = geom.Paths;

pub const Island = struct {
    /// The layer index (from 0).
    layer: u32,
    /// The center of the box of the polygon, mm.
    x: f64,
    y: f64,
    /// The area of the polygon, mm².
    area: f64,
};

/// The islands of all layers, in layer order. Polygons smaller than
/// `min_area` (mm²) do not count. The caller owns the result.
pub fn find(
    gpa: Allocator,
    outlines: []const Paths,
    support: []const support_mod.SupportLayer,
    grow: i64,
    min_area: f64,
    threads: usize,
) anyerror![]Island {
    return findSome(gpa, outlines, support, grow, min_area, threads, null, &.{});
}

/// As `find`, for the layers with `redo[i]` only; the islands of the other
/// layers come from `old` (the islands of the same outlines, with the same
/// support under those layers: a support edit finds again only the layers
/// over the support that changed).
pub fn findSome(
    gpa: Allocator,
    outlines: []const Paths,
    support: []const support_mod.SupportLayer,
    grow: i64,
    min_area: f64,
    threads: usize,
    redo: ?[]const bool,
    old: []const Island,
) anyerror![]Island {
    const n = outlines.len;
    if (n < 2) return &.{};
    const per = try gpa.alloc(std.ArrayList(Island), n);
    for (per) |*p| p.* = .empty;
    defer {
        for (per) |*p| p.deinit(gpa);
        gpa.free(per);
    }
    const Ctx = struct {
        gpa: Allocator,
        outlines: []const Paths,
        support: []const support_mod.SupportLayer,
        per: []std.ArrayList(Island),
        grow: i64,
        min_area: f64,
        redo: ?[]const bool,
        fn run(c: *const @This(), k: usize) anyerror!void {
            const i = k + 1;
            if (c.redo) |r| if (!r[i]) return;
            if (c.outlines[i].isEmpty()) return;
            var arena = std.heap.ArenaAllocator.init(c.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var under = c.outlines[i - 1];
            if (c.support.len > i - 1) {
                const s = c.support[i - 1];
                if (!s.body.isEmpty()) under = try clip.unite(a, under, s.body);
                if (!s.interface.isEmpty()) under = try clip.unite(a, under, s.interface);
            }
            const base = try offset_mod.offset(a, under, c.grow, .{});
            const o = c.outlines[i];
            for (0..o.count()) |p| {
                const poly = o.get(p);
                if (geom.area2(poly) <= 0) continue; // a hole
                const area = geom.areaMm2(poly);
                if (area < c.min_area) continue;
                var one: Paths = .empty;
                try one.append(a, poly);
                const on = try clip.intersect(a, one, base);
                if (on.areaMm2() >= 0.01 * area) continue;
                var box = geom.Box.empty;
                for (poly) |q| box.extend(q);
                try c.per[i].append(c.gpa, .{
                    .layer = @intCast(i),
                    .x = geom.toMm(@divTrunc(box.min.x + box.max.x, 2)),
                    .y = geom.toMm(@divTrunc(box.min.y + box.max.y, 2)),
                    .area = area,
                });
            }
        }
    };
    const ctx: Ctx = .{ .gpa = gpa, .outlines = outlines, .support = support, .per = per, .grow = grow, .min_area = min_area, .redo = redo };
    try parallel.forEach(threads, n - 1, &ctx, Ctx.run);
    if (redo) |r| for (old) |isl| {
        if (isl.layer < n and !r[isl.layer]) try per[isl.layer].append(gpa, isl);
    };
    var out: std.ArrayList(Island) = .empty;
    errdefer out.deinit(gpa);
    for (per) |p| try out.appendSlice(gpa, p.items);
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;
const mesh_mod = @import("mesh.zig");

test "islands: a mushroom cap with no support is an island; with support it is not" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    // A cap that does not touch the post: it starts in the air at z 5.
    try mesh_mod.shapes.addBox(&b, 20, 0, 5, 40, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const layers = try slicer.layerTable(gpa, 7, 0.3, 0.2);
    defer gpa.free(layers);
    var idx = try slicer.FaceIndex.build(gpa, &m, layers, 0);
    defer idx.deinit(gpa);
    const outlines = try gpa.alloc(Paths, layers.len);
    defer {
        for (outlines) |*o| o.deinit(gpa);
        gpa.free(outlines);
    }
    for (outlines, 0..) |*o, li| o.* = try slicer.sliceAt(gpa, &m, idx.get(li), layers[li].sliceZ(), 5, 1000);
    const found = try find(gpa, outlines, &.{}, 100, 0.5, 2);
    defer gpa.free(found);
    // One island: the first layer of the cap, at its center.
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectApproxEqAbs(@as(f64, 30), found[0].x, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 400), found[0].area, 10);
    try testing.expect(layers[found[0].layer].z > 5);
}
