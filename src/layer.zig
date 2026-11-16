//! The layer plan: from the outline of one layer to the paths of the nozzle.
//!
//! 1. Walls. Wall k is the outline moved in by (k + 1/2) line widths. The
//!    center of the line is on the loop, so the outer edge of the plastic
//!    of wall 0 is on the outline. Wall 0 is the outer wall.
//! 2. The inner area is the outline moved in by (wall count) line widths:
//!    the area inside the walls.
//! 3. Skin. A part of the inner area is skin (solid fill) if it is near a
//!    top or bottom surface. A point is "supported" if it is inside the
//!    outlines of the next `top_layers` layers above and the next
//!    `bottom_layers` layers below. Skin is the inner area minus the
//!    supported area. Skin thinner than half a line width is removed.
//! 4. Sparse infill is the inner area minus the skin.
//! 5. Fill. Skin gets lines one line width apart. The direction turns 90
//!    degrees on each layer. Sparse infill gets lines further apart, from
//!    the density. Each fill region first moves in by half a line width
//!    (so that the plastic touches the walls), then out by the overlap
//!    (so that the plastic bonds to the walls).
//! 6. Ironing (if on). The top surfaces of the layer are the outline minus
//!    the outline of the layer above. The nozzle goes over them again with
//!    close lines, turned 90 degrees from the skin lines of this layer.
//! 7. Order. The plan prints the inner walls first, then the outer wall,
//!    then the skin, then the infill, then the ironing. Inside each group, the next path is
//!    the nearest one to the current nozzle position (a greedy nearest
//!    neighbor search). A loop starts at its vertex nearest to the nozzle.
//!    A line starts at its nearer end.
//!
//! Each layer only reads the outlines of the other layers, so many layers
//! can be planned at the same time on different threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const infill = @import("infill.zig");
const settings_mod = @import("settings.zig");
const slicer = @import("slicer.zig");
const Point = geom.Point;
const Paths = geom.Paths;
const Feature = settings_mod.Feature;
const Resolved = settings_mod.Resolved;

pub const Path = struct {
    feature: Feature,
    closed: bool,
};

pub const LayerPlan = struct {
    arena: std.heap.ArenaAllocator,
    index: u32,
    /// The z of the nozzle, in mm.
    z: f64,
    /// The layer height, in mm.
    height: f64,
    /// The line width, in mm.
    width: f64,
    /// The outline of the layer.
    outline: Paths = .empty,
    /// One entry for each path in `points`, in print order.
    paths: std.ArrayList(Path) = .empty,
    points: Paths = .empty,

    pub fn deinit(self: *LayerPlan) void {
        self.arena.deinit();
    }

    pub fn count(self: LayerPlan) usize {
        return self.paths.items.len;
    }
};

pub const Context = struct {
    resolved: *const Resolved,
    layers: []const slicer.Layer,
    outlines: []const Paths,
};

/// Plans layer `i`. `gpa` must be thread-safe if more than one thread plans
/// layers at the same time. Call `deinit` on the result.
pub fn plan(gpa: Allocator, ctx: Context, i: usize) Allocator.Error!LayerPlan {
    const r = ctx.resolved;
    const p = r.settings.project;
    const layer = ctx.layers[i];
    const first = i == 0;
    const width_mm = if (first) r.first_layer_line_width else r.line_width;
    const w = geom.fromMm(width_mm);

    var lp: LayerPlan = .{
        .arena = .init(gpa),
        .index = @intCast(i),
        .z = layer.z,
        .height = layer.height,
        .width = width_mm,
    };
    errdefer lp.deinit();
    const a = lp.arena.allocator();

    // Intermediate shapes go in a scratch arena, freed at the end.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const s = scratch_state.allocator();

    const outline = ctx.outlines[i];
    lp.outline = try outline.clone(a);
    if (outline.isEmpty()) return lp;

    // Step 1.
    const walls = try s.alloc(Paths, p.wall_count);
    var wall_n: usize = 0;
    for (walls, 0..) |*wall, k| {
        wall.* = try offset_mod.offset(s, outline, -(@divTrunc(w, 2) + @as(i64, @intCast(k)) * w), .{});
        if (wall.isEmpty()) break;
        wall_n += 1;
    }

    // Step 2.
    const inner = if (p.wall_count == 0)
        try outline.clone(s)
    else
        try offset_mod.offset(s, outline, -@as(i64, @intCast(p.wall_count)) * w, .{});

    // Steps 3 and 4.
    var skin: Paths = .empty;
    var sparse: Paths = .empty;
    if (!inner.isEmpty()) {
        const above = try stackedIntersection(s, ctx.outlines, i, r.top_layers, .up);
        const below = try stackedIntersection(s, ctx.outlines, i, r.bottom_layers, .down);
        if (above == null and below == null) {
            sparse = inner;
        } else {
            const supported = if (above == null)
                below.?
            else if (below == null)
                above.?
            else
                try clip.intersect(s, above.?, below.?);
            const raw_skin = try clip.difference(s, inner, supported);
            skin = try offset_mod.opening(s, raw_skin, @divTrunc(w, 4), .{});
            sparse = try clip.difference(s, inner, skin);
        }
    }

    // Step 5.
    const skin_inset = -@divTrunc(w, 2) + geom.fromMm(p.skin_overlap * width_mm);
    const skin_region = try offset_mod.offset(s, skin, skin_inset, .{});
    const skin_angle = p.infill_angle + @as(f64, if (i % 2 == 0) 0 else 90);
    const skin_lines = try infill.lines(s, skin_region, w, skin_angle, w);

    var sparse_lines: Paths = .empty;
    if (p.infill_density > 0 and !sparse.isEmpty()) {
        const inset = -@divTrunc(w, 2) + geom.fromMm(p.infill_overlap * width_mm);
        const region = try offset_mod.offset(s, sparse, inset, .{});
        switch (p.infill_pattern) {
            .lines => {
                const spacing = geom.fromMm(width_mm / p.infill_density);
                const angle = p.infill_angle + @as(f64, if (i % 2 == 0) 0 else 90);
                sparse_lines = try infill.lines(s, region, spacing, angle, w);
            },
            .grid => {
                const spacing = geom.fromMm(2 * width_mm / p.infill_density);
                sparse_lines = try infill.lines(s, region, spacing, p.infill_angle, w);
                var cross = try infill.lines(s, region, spacing, p.infill_angle + 90, w);
                try sparse_lines.appendAll(s, cross);
                cross.deinit(s);
            },
        }
    }

    // Step 6.
    var ironing_lines: Paths = .empty;
    if (p.ironing and !first) {
        const above: Paths = if (i + 1 < ctx.outlines.len) ctx.outlines[i + 1] else .empty;
        const top = try clip.difference(s, outline, above);
        const region = try offset_mod.offset(s, top, -geom.fromMm(p.ironing_inset), .{});
        ironing_lines = try infill.lines(s, region, geom.fromMm(p.ironing_spacing), skin_angle + 90, 0);
    }

    // Step 7.
    var pos: Point = if (outline.points.items.len > 0) outline.points.items[0] else .init(0, 0);
    var k = wall_n;
    while (k > 1) {
        k -= 1;
        try addOrdered(s, a, &lp, &pos, walls[k], true, .inner_wall);
    }
    if (wall_n > 0) try addOrdered(s, a, &lp, &pos, walls[0], true, .outer_wall);
    try addOrdered(s, a, &lp, &pos, skin_lines, false, .skin);
    try addOrdered(s, a, &lp, &pos, sparse_lines, false, .infill);
    try addOrdered(s, a, &lp, &pos, ironing_lines, false, .ironing);
    return lp;
}

const Direction = enum { up, down };

/// The intersection of the outlines of the `n` layers above (or below)
/// layer i. Returns null if n is 0 (no limit). Returns an empty set if the
/// part ends before n layers.
fn stackedIntersection(s: Allocator, outlines: []const Paths, i: usize, n: u32, dir: Direction) Allocator.Error!?Paths {
    if (n == 0) return null;
    var acc: Paths = .empty;
    for (1..n + 1) |j| {
        const idx = switch (dir) {
            .up => if (i + j < outlines.len) i + j else return .empty,
            .down => if (i >= j) i - j else return .empty,
        };
        acc = if (j == 1) outlines[idx] else try clip.intersect(s, acc, outlines[idx]);
        if (acc.isEmpty()) return acc;
    }
    return acc;
}

/// Adds the paths of `set` to the plan in greedy nearest-neighbor order.
fn addOrdered(s: Allocator, a: Allocator, lp: *LayerPlan, pos: *Point, set: Paths, closed: bool, feature: Feature) Allocator.Error!void {
    const n = set.count();
    if (n == 0) return;
    const used = try s.alloc(bool, n);
    @memset(used, false);
    for (0..n) |_| {
        var best: usize = 0;
        var best_d: i128 = std.math.maxInt(i128);
        var best_at: usize = 0;
        for (0..n) |j| {
            if (used[j]) continue;
            const path = set.get(j);
            if (closed) {
                for (path, 0..) |q, qi| {
                    const d = pos.distSq(q);
                    if (d < best_d) {
                        best_d = d;
                        best = j;
                        best_at = qi;
                    }
                }
            } else {
                const d0 = pos.distSq(path[0]);
                const d1 = pos.distSq(path[path.len - 1]);
                if (d0 < best_d) {
                    best_d = d0;
                    best = j;
                    best_at = 0;
                }
                if (d1 < best_d) {
                    best_d = d1;
                    best = j;
                    best_at = path.len - 1;
                }
            }
        }
        used[best] = true;
        const path = set.get(best);
        if (closed) {
            // Start at the nearest vertex.
            for (0..path.len) |o| try lp.points.appendPoint(a, path[(best_at + o) % path.len]);
            pos.* = path[best_at];
        } else if (best_at == 0) {
            for (path) |q| try lp.points.appendPoint(a, q);
            pos.* = path[path.len - 1];
        } else {
            var o = path.len;
            while (o > 0) {
                o -= 1;
                try lp.points.appendPoint(a, path[o]);
            }
            pos.* = path[0];
        }
        try lp.points.endPath(a, 0);
        try lp.paths.append(a, .{ .feature = feature, .closed = closed });
    }
}

const testing = std.testing;

test "plan a layer of a box" {
    const gpa = testing.allocator;
    const mesh = @import("mesh.zig");
    var m = try mesh.shapes.box(gpa, 20, 20, 10);
    defer m.deinit(gpa);
    var st: settings_mod.Settings = .{};
    st.project.wall_count = 2;
    const r = try st.resolve();
    const layers = try slicer.layerTable(gpa, 10, 0.3, 0.2);
    defer gpa.free(layers);
    var idx = try slicer.FaceIndex.build(gpa, &m, layers, 0);
    defer idx.deinit(gpa);
    const outlines = try gpa.alloc(Paths, layers.len);
    defer {
        for (outlines) |*o| o.deinit(gpa);
        gpa.free(outlines);
    }
    for (outlines, 0..) |*o, li| o.* = try slicer.sliceAt(gpa, &m, idx.get(li), layers[li].sliceZ(), 5, 1000);

    const ctx: Context = .{ .resolved = &r, .layers = layers, .outlines = outlines };

    // A middle layer: two walls, no skin, sparse infill.
    var mid = try plan(gpa, ctx, 20);
    defer mid.deinit();
    var walls: usize = 0;
    var skin: usize = 0;
    var fill: usize = 0;
    for (mid.paths.items) |path| switch (path.feature) {
        .outer_wall, .inner_wall => walls += 1,
        .skin => skin += 1,
        .infill => fill += 1,
        .ironing => unreachable,
    };
    try testing.expectEqual(@as(usize, 2), walls);
    try testing.expectEqual(@as(usize, 0), skin);
    try testing.expect(fill > 0);
    // The outer wall is half a line width inside the outline.
    try testing.expectEqual(Feature.outer_wall, mid.paths.items[1].feature);
    const half = geom.fromMm(r.line_width / 2);
    var box = geom.Box.empty;
    for (mid.points.get(1)) |q| box.extend(q);
    try testing.expectEqual(half, box.min.x);

    // The first layer is all skin.
    var bottom = try plan(gpa, ctx, 0);
    defer bottom.deinit();
    for (bottom.paths.items) |path| try testing.expect(path.feature != .infill);
}

test "ironing covers only the top surface" {
    const gpa = testing.allocator;
    const mesh = @import("mesh.zig");
    // A 20 x 20 mm box with a 10 x 10 mm box on top. The top of the lower
    // box is a ring around the upper box.
    var b: mesh.Builder = .init(gpa);
    try mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 2);
    try mesh.shapes.addBox(&b, 5, 5, 2, 15, 15, 4);
    var m = try b.finish();
    defer m.deinit(gpa);
    var st: settings_mod.Settings = .{};
    st.project.ironing = true;
    const r = try st.resolve();
    const layers = try slicer.layerTable(gpa, 4, 0.3, 0.2);
    defer gpa.free(layers);
    var idx = try slicer.FaceIndex.build(gpa, &m, layers, 0);
    defer idx.deinit(gpa);
    const outlines = try gpa.alloc(Paths, layers.len);
    defer {
        for (outlines) |*o| o.deinit(gpa);
        gpa.free(outlines);
    }
    for (outlines, 0..) |*o, li| o.* = try slicer.sliceAt(gpa, &m, idx.get(li), layers[li].sliceZ(), 5, 1000);
    const ctx: Context = .{ .resolved = &r, .layers = layers, .outlines = outlines };

    // Layer 8 (z 0.3 + 8 x 0.2 = 1.9) is the top layer of the lower box.
    var lp = try plan(gpa, ctx, 8);
    defer lp.deinit();
    var n: usize = 0;
    const inset = geom.fromMm(st.project.ironing_inset);
    for (lp.paths.items, 0..) |path, pi| {
        if (path.feature != .ironing) continue;
        n += 1;
        // No ironing line goes over the upper box, and each line stays the
        // inset away from the outside edge.
        for (lp.points.get(pi)) |q| {
            const over_upper = q.x > 5000 + inset and q.x < 15000 - inset and q.y > 5000 + inset and q.y < 15000 - inset;
            try testing.expect(!over_upper);
            try testing.expect(q.x >= inset - 2 and q.x <= 20000 - inset + 2);
        }
    }
    try testing.expect(n > 100);

    // Layer 5 (z 1.1) is inside the lower box: no ironing.
    var mid = try plan(gpa, ctx, 5);
    defer mid.deinit();
    for (mid.paths.items) |path| try testing.expect(path.feature != .ironing);
}
