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
//!
//!    The code does not intersect the outlines above and below for each
//!    layer. It uses the top surface of each layer j (outline j minus
//!    outline j + 1) and its bottom surface (outline j minus outline
//!    j - 1). A point of layer i that is not inside all outlines up to
//!    layer i + t leaves the part at some layer j between i and i + t - 1:
//!    it is in the top surface of layer j. So the skin of layer i (before
//!    the clean-up) is the inner area intersected with the top surfaces of
//!    layers i to i + t - 1 and the bottom surfaces of layers i - b + 1 to
//!    i. The surfaces come from one boolean for each pair of layers, and
//!    t + b layers use each of them. The code intersects the inner area
//!    with each surface on its own, and joins the parts. (On a wall that
//!    is almost vertical, the surfaces of the layers are thin strips on
//!    top of each other, and one boolean of all of them has many
//!    crossings.) Most parts are empty, so this step is fast.
//! 4. Sparse infill is the inner area minus the skin.
//! 5. Fill. Skin gets lines one line width apart. The direction turns 90
//!    degrees on each layer. Sparse infill gets lines further apart, from
//!    the density. Each fill region first moves in by half a line width
//!    (so that the plastic touches the walls), then out by the overlap
//!    (so that the plastic bonds to the walls).
//! 6. Ironing (if on). The top surfaces of the layer are the outline minus
//!    the outline of the layer above. The nozzle goes over them again with
//!    close lines, turned 90 degrees from the skin lines of this layer.
//! 7. Skirt and brim (first layers only). The brim is loops around the
//!    outer boundaries of the first layer (not around holes), one line
//!    width apart, to `brim_width`. The skirt is loops around the first
//!    layer and the brim, at `skirt_distance`.
//! 8. Support (see support.zig): one boundary loop and lines in a fixed
//!    direction for the support body, and dense lines across them for the
//!    interface.
//! 9. Order. The plan prints the skirt and the brim first (outermost loop
//!    first), then the support, then the inner walls, then the outer wall, then the skin,
//!    then the infill, then the ironing. Inside each group, the next path is
//!    the nearest one to the current nozzle position (a greedy nearest
//!    neighbor search). A loop starts at its vertex nearest to the nozzle.
//!    A line starts at its nearer end.
//!
//! Each layer only reads the outlines of the other layers, so many layers
//! can be planned at the same time on different threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const scratch = @import("scratch.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const infill = @import("infill.zig");
const settings_mod = @import("settings.zig");
const slicer = @import("slicer.zig");
const support_mod = @import("support.zig");
const Point = geom.Point;
const Paths = geom.Paths;
const Feature = settings_mod.Feature;
const Resolved = settings_mod.Resolved;

pub const Path = struct {
    feature: Feature,
    closed: bool,
    /// The line width of this path in mm, or 0 for the width of the layer
    /// (a thin wall has a narrower line).
    width: f32 = 0,
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
    /// The settings of this layer, with its overrides. The emitter uses
    /// them for the speeds. Valid while the job lives.
    resolved: ?*const Resolved = null,
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
    /// The support areas of each layer, or an empty slice (no support).
    support: []const support_mod.SupportLayer = &.{},
    /// The memo of each layer (see `Memo`), or an empty slice (no cache).
    /// Each layer has its own memo, so plans of different layers can run
    /// on different threads.
    cache: []Memo = &.{},
    /// The generation of the slice (see `Memo`).
    gen: u32 = 0,
    /// The top and bottom surfaces of each layer (see `surfaces`), or empty
    /// slices. Without them, `regions` makes the surfaces that it needs.
    tops: []const Paths = &.{},
    bottoms: []const Paths = &.{},
    /// The settings of each layer with overrides: 0 for `resolved`, k for
    /// `layer_resolved[k - 1]`. Empty: all layers use `resolved`.
    layer_set: []const u16 = &.{},
    layer_resolved: []const Resolved = &.{},

    /// The settings of layer i, with its overrides.
    pub fn resolvedAt(ctx: Context, i: usize) *const Resolved {
        if (i < ctx.layer_set.len and ctx.layer_set[i] > 0) return &ctx.layer_resolved[ctx.layer_set[i] - 1];
        return ctx.resolved;
    }
};

/// The areas of a layer (steps 1 to 4): the wall loops, the skin area, and
/// the sparse infill area. The memory belongs to a `Memo`.
pub const Regions = struct {
    /// The wall loops, outer wall first.
    walls: []Paths = &.{},
    skin: Paths = .empty,
    sparse: Paths = .empty,
    /// Thin walls: loops in the parts thinner than one line width, and the
    /// line width of each loop (mm).
    thin: Paths = .empty,
    thin_width: []const f32 = &.{},
    /// The inputs of the skin and sparse areas, for `Memo.fill`.
    key: [6]i64 = @splat(0),
};

/// The results of steps 1 to 4 of one layer, kept between slices. Steps 1
/// to 4 are the slow part of a plan (polygon offsets and booleans). Each
/// result has the values that made it (its key), so a new slice uses each
/// result whose key is the same and makes only the others:
///
/// - An offset of the outline, by its distance. The walls and the inner
///   area are offsets. A change of the wall count keeps the walls that
///   stay, and a change of the infill keeps all.
/// - The thin walls, by the line width.
/// - The part of the inner area on the top or bottom surface of a layer
///   (see the file comment), by the inner offset and the layer. A change
///   of the top thickness adds or removes layers, and keeps the parts.
/// - The skin and sparse areas, by the inner offset, the top and bottom
///   layer counts, and the widths of the skin steps.
/// - The area under the band above, for the flow infill, by the band.
/// - The fill regions: the skin and sparse areas moved by the fill inset,
///   by the key of the area and the inset.
///
/// All results are for one outline. A new outline (for example, a new
/// layer height) needs a new memo. Each result has the generation of the
/// last slice that used it (see `Job.gen` in engine.zig), so that `keep`
/// can drop old results.
pub const Memo = struct {
    arena: std.heap.ArenaAllocator,
    offsets: std.ArrayList(OffsetEntry) = .empty,
    thins: std.ArrayList(ThinEntry) = .empty,
    parts: std.ArrayList(PartEntry) = .empty,
    skins: std.ArrayList(SkinEntry) = .empty,
    bands: std.ArrayList(BandEntry) = .empty,
    fills: std.ArrayList(FillEntry) = .empty,

    const OffsetEntry = struct {
        delta: i64,
        paths: Paths,
        gen: u32,
        /// The seam vertex of each loop for `seam_mode` (for a wall).
        seam_mode: ?settings_mod.SeamMode = null,
        seams: []u32 = &.{},
    };
    const ThinEntry = struct { w: i64, thin: Paths, widths: []f32, gen: u32 };
    const PartEntry = struct { delta: i64, layer: u32, top: bool, paths: Paths, gen: u32 };
    const SkinEntry = struct { key: [6]i64, skin: Paths, sparse: Paths, gen: u32 };
    const BandEntry = struct { band: u32, paths: Paths, gen: u32 };
    const FillEntry = struct { key: [6]i64, skin: bool, delta: i64, paths: Paths, gen: u32 };

    pub fn init(gpa: Allocator) Memo {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Memo) void {
        self.arena.deinit();
    }

    /// A new memo with the results that a slice of generation `min_gen` or
    /// later used. The copy also frees the memory of the dropped results.
    pub fn keep(self: *const Memo, gpa: Allocator, min_gen: u32) Allocator.Error!Memo {
        var out: Memo = .init(gpa);
        errdefer out.deinit();
        const a = out.arena.allocator();
        for (self.offsets.items) |e| if (e.gen >= min_gen) {
            var c = e;
            c.paths = try e.paths.clone(a);
            c.seams = try a.dupe(u32, e.seams);
            try out.offsets.append(a, c);
        };
        for (self.thins.items) |e| if (e.gen >= min_gen) {
            var c = e;
            c.thin = try e.thin.clone(a);
            c.widths = try a.dupe(f32, e.widths);
            try out.thins.append(a, c);
        };
        for (self.parts.items) |e| if (e.gen >= min_gen) {
            var c = e;
            c.paths = try e.paths.clone(a);
            try out.parts.append(a, c);
        };
        for (self.skins.items) |e| if (e.gen >= min_gen) {
            var c = e;
            c.skin = try e.skin.clone(a);
            c.sparse = try e.sparse.clone(a);
            try out.skins.append(a, c);
        };
        for (self.bands.items) |e| if (e.gen >= min_gen) {
            var c = e;
            c.paths = try e.paths.clone(a);
            try out.bands.append(a, c);
        };
        for (self.fills.items) |e| if (e.gen >= min_gen) {
            var c = e;
            c.paths = try e.paths.clone(a);
            try out.fills.append(a, c);
        };
        return out;
    }

    /// The outline moved by `delta`.
    fn offset(self: *Memo, outline: Paths, delta: i64, gen: u32) Allocator.Error!Paths {
        for (self.offsets.items) |*e| if (e.delta == delta) {
            e.gen = gen;
            return e.paths;
        };
        const a = self.arena.allocator();
        const paths = try offset_mod.offset(a, outline, delta, .{});
        try self.offsets.append(a, .{ .delta = delta, .paths = paths, .gen = gen });
        return paths;
    }

    /// The seam vertex of each loop of `walls` (a result of `offset`), from
    /// the memo or new. Null if `walls` is not in the memo.
    fn seams(self: *Memo, walls: Paths, rule: Seam) Allocator.Error!?[]const u32 {
        for (self.offsets.items) |*e| {
            if (e.paths.points.items.ptr != walls.points.items.ptr or e.paths.count() != walls.count()) continue;
            if (e.seam_mode != rule.mode) {
                e.seams = try self.arena.allocator().alloc(u32, walls.count());
                try seamIndices(walls, rule, e.seams);
                e.seam_mode = rule.mode;
            }
            return e.seams;
        }
        return null;
    }

    /// The skin (or sparse) area of `reg` moved by `delta`.
    pub fn fill(self: *Memo, reg: Regions, skin: bool, delta: i64, gen: u32) Allocator.Error!Paths {
        for (self.fills.items) |*e| if (e.skin == skin and e.delta == delta and std.mem.eql(i64, &e.key, &reg.key)) {
            e.gen = gen;
            return e.paths;
        };
        const a = self.arena.allocator();
        const paths = try offset_mod.offset(a, if (skin) reg.skin else reg.sparse, delta, .{});
        try self.fills.append(a, .{ .key = reg.key, .skin = skin, .delta = delta, .paths = paths, .gen = gen });
        return paths;
    }

    /// The inner area (the outline moved by `delta`) on the top (or bottom)
    /// surface of layer j.
    fn part(self: *Memo, inner: Paths, delta: i64, j: usize, top: bool, surface: Paths, gen: u32) Allocator.Error!Paths {
        for (self.parts.items) |*e| if (e.delta == delta and e.layer == j and e.top == top) {
            e.gen = gen;
            return e.paths;
        };
        const a = self.arena.allocator();
        const paths = try clip.intersect(a, inner, surface);
        try self.parts.append(a, .{ .delta = delta, .layer = @intCast(j), .top = top, .paths = paths, .gen = gen });
        return paths;
    }

    /// For the flow infill: the area of all the layers of the band above
    /// layer i (an intersection of their outlines).
    fn underBand(self: *Memo, outlines: []const Paths, i: usize, band: u32, gen: u32) Allocator.Error!Paths {
        for (self.bands.items) |*e| if (e.band == band) {
            e.gen = gen;
            return e.paths;
        };
        const a = self.arena.allocator();
        var scratch_state = scratch.get(a);
        defer scratch_state.release();
        const u = try stackedIntersection(scratch_state.allocator(), outlines, i, band, .up);
        const paths = if (u) |v| try v.clone(a) else Paths.empty;
        try self.bands.append(a, .{ .band = band, .paths = paths, .gen = gen });
        return paths;
    }
};

/// Steps 1 to 4 for layer i, with the results in `memo`. The list of walls
/// goes in `list_alloc`. `gpa` must be thread-safe if more than one thread
/// calls it at the same time.
pub fn regions(gpa: Allocator, ctx: Context, i: usize, memo: *Memo, list_alloc: Allocator) Allocator.Error!Regions {
    const r = ctx.resolvedAt(i);
    const p = r.settings.project;
    const first = i == 0;
    const w = geom.fromMm(if (first) r.first_layer_line_width else r.line_width);
    var reg: Regions = .{};
    const a = memo.arena.allocator();
    var scratch_state = scratch.get(gpa);
    defer scratch_state.release();
    const s = scratch_state.allocator();
    const outline = ctx.outlines[i];
    if (outline.isEmpty()) return reg;
    const gen = ctx.gen;

    // Step 1.
    const walls = try list_alloc.alloc(Paths, p.wall_count);
    var wall_n: usize = 0;
    for (walls, 0..) |*wall, k| {
        wall.* = try memo.offset(outline, -(@divTrunc(w, 2) + @as(i64, @intCast(k)) * w), gen);
        if (wall.isEmpty()) break;
        wall_n += 1;
    }
    reg.walls = walls[0..wall_n];

    // Thin walls: the parts of the outline that an opening of half a line
    // width removes. Each gets a loop t/4 inside it, with a line of width
    // t/2, where t (2 area / perimeter) is its thickness: the two sides of
    // the loop fill the part.
    if (p.thin_walls and p.wall_count > 0) thin: {
        for (memo.thins.items) |*e| if (e.w == w) {
            e.gen = gen;
            reg.thin = e.thin;
            reg.thin_width = e.widths;
            break :thin;
        };
        var thin_loops: Paths = .empty;
        const thick = try offset_mod.opening(s, outline, @divTrunc(w, 2), .{});
        const thin = try clip.difference(s, outline, thick);
        var widths: std.ArrayList(f32) = .empty;
        for (0..thin.count()) |k| {
            const poly = thin.get(k);
            const area2 = geom.area2(poly);
            if (area2 <= 0) continue; // a hole
            var perim: f64 = 0;
            for (poly, 0..) |q, qi| {
                const r2 = poly[(qi + 1) % poly.len];
                perim += std.math.hypot(@as(f64, @floatFromInt(r2.x - q.x)), @as(f64, @floatFromInt(r2.y - q.y)));
            }
            const t = @as(f64, @floatFromInt(area2)) / perim; // area2 is twice the area
            // Thinner than 0.1 mm (noise), or a short piece: skip.
            if (t < 100 or perim < 4 * @as(f64, @floatFromInt(w))) continue;
            var one: Paths = .empty;
            try one.append(s, poly);
            const loop = try offset_mod.offset(s, one, -@as(i64, @intFromFloat(t / 4)), .{});
            const use = if (loop.isEmpty()) one else loop;
            for (0..use.count()) |j| {
                try thin_loops.append(a, use.get(j));
                try widths.append(a, @floatCast(@min(geom.toMm(@intFromFloat(t / 2)), geom.toMm(w))));
            }
        }
        reg.thin = thin_loops;
        reg.thin_width = widths.items;
        try memo.thins.append(a, .{ .w = w, .thin = thin_loops, .widths = widths.items, .gen = gen });
    }

    // Step 2. With no walls, the offset of 0 is the outline.
    const inner_delta = -@as(i64, @intCast(p.wall_count)) * w;
    const inner = try memo.offset(outline, inner_delta, gen);

    // Steps 3 and 4.
    if (inner.isEmpty()) return reg;
    const removal = @divTrunc(geom.fromMm(p.skin_removal_width), 2);
    const expand = geom.fromMm(p.skin_expand_distance);
    const solid = @divTrunc(geom.fromMm(p.solid_infill_width), 2);
    const skin_key = [6]i64{ inner_delta, r.top_layers, r.bottom_layers, removal, expand, solid };
    reg.key = skin_key;
    if (r.top_layers == 0 and r.bottom_layers == 0) {
        reg.sparse = inner;
        return reg;
    }
    for (memo.skins.items) |*e| {
        if (std.mem.eql(i64, &e.key, &skin_key)) {
            e.gen = gen;
            reg.skin = e.skin;
            reg.sparse = e.sparse;
            return reg;
        }
    }
    // The parts of the inner area on the surfaces near the layer (see the
    // file comment). The parts can overlap, so a union joins them if there
    // is more than one.
    var exposed: Paths = .empty;
    var sets: usize = 0;
    const n = ctx.outlines.len;
    for (0..r.top_layers) |m| {
        const j = i + m;
        if (j >= n) break;
        const t = if (ctx.tops.len > 0) ctx.tops[j] else (try surfaces(s, ctx.outlines, j))[0];
        const piece = try memo.part(inner, inner_delta, j, true, t, gen);
        if (!piece.isEmpty()) sets += 1;
        try exposed.appendAll(s, piece);
    }
    for (0..r.bottom_layers) |m| {
        if (m > i) break;
        const j = i - m;
        const t = if (ctx.bottoms.len > 0) ctx.bottoms[j] else (try surfaces(s, ctx.outlines, j))[1];
        const piece = try memo.part(inner, inner_delta, j, false, t, gen);
        if (!piece.isEmpty()) sets += 1;
        try exposed.appendAll(s, piece);
    }
    const raw_skin = if (sets > 1) try clip.unionAll(s, exposed, .non_zero) else exposed;
    // 1. Remove slivers narrower than the removal width.
    const kept = if (removal > 0) try offset_mod.opening(s, raw_skin, removal, .{}) else raw_skin;
    // 2. Expand into the sparse area, inside the walls.
    var skin = if (expand > 0 and !kept.isEmpty())
        try clip.intersect(s, try offset_mod.offset(s, kept, expand, .{}), inner)
    else
        kept;
    // 3. Sparse areas too narrow for infill lines print solid.
    var sparse = try clip.difference(s, inner, skin);
    if (solid > 0 and !sparse.isEmpty()) {
        const wide = try offset_mod.opening(s, sparse, solid, .{});
        const narrow = try clip.difference(s, sparse, wide);
        if (!narrow.isEmpty()) {
            skin = try clip.unite(s, skin, narrow);
            sparse = wide;
        }
    }
    reg.skin = try skin.clone(a);
    reg.sparse = try sparse.clone(a);
    try memo.skins.append(a, .{ .key = skin_key, .skin = reg.skin, .sparse = reg.sparse, .gen = gen });
    return reg;
}


/// Plans layer `i`. `gpa` must be thread-safe if more than one thread plans
/// layers at the same time. Call `deinit` on the result.
pub fn plan(gpa: Allocator, ctx: Context, i: usize) Allocator.Error!LayerPlan {
    const r = ctx.resolvedAt(i);
    const p = r.settings.project;
    const layer = ctx.layers[i];
    const first = i == 0;
    const width_mm = if (first) r.first_layer_line_width else r.line_width;
    const w = geom.fromMm(width_mm);

    var lp: LayerPlan = .{
        .arena = .init(gpa),
        .index = @intCast(i),
        .resolved = r,
        .z = layer.z,
        .height = layer.height,
        .width = width_mm,
    };
    errdefer lp.deinit();
    const a = lp.arena.allocator();

    // Intermediate shapes go in a scratch arena, freed at the end.
    var scratch_state = scratch.get(gpa);
    defer scratch_state.release();
    const s = scratch_state.allocator();

    const outline = ctx.outlines[i];
    lp.outline = try outline.clone(a);

    // Support. A layer can have support and no part, so this comes before
    // the check for an empty outline.
    var sup_walls: Paths = .empty;
    var sup_lines: Paths = .empty;
    var sup_iface: Paths = .empty;
    if (ctx.support.len > 0) {
        const sl = ctx.support[i];
        if (!sl.body.isEmpty()) {
            // One boundary loop holds the ends of the lines together. The
            // lines have one direction on all layers, so that they stack.
            sup_walls = try offset_mod.offset(s, sl.body, -@divTrunc(w, 2), .{});
            const inside = try offset_mod.offset(s, sl.body, -w + @divTrunc(w, 5), .{});
            sup_lines = try infill.lines(s, inside, geom.fromMm(width_mm / p.support_density), 0, w);
        }
        if (!sl.interface.isEmpty()) {
            const region = try offset_mod.offset(s, sl.interface, -@divTrunc(w, 2), .{});
            sup_iface = try infill.lines(s, region, geom.fromMm(width_mm / p.support_interface_density), 90, w);
        }
    }
    if (outline.isEmpty()) {
        var pos: Point = .init(0, 0);
        try addOrdered(s, a, &lp, &pos, sup_walls, true, .support);
        try addOrdered(s, a, &lp, &pos, sup_lines, false, .support);
        try addOrdered(s, a, &lp, &pos, sup_iface, false, .support_interface);
        return lp;
    }

    // Steps 1 to 4: with the memo of the job, or with a new memo.
    var own: ?Memo = null;
    defer if (own) |*o| o.deinit();
    const memo: *Memo = if (ctx.cache.len > i) &ctx.cache[i] else blk: {
        own = .init(gpa);
        break :blk &own.?;
    };
    const reg = try regions(gpa, ctx, i, memo, s);
    // The flow infill needs the area under the band above.
    var under_band: ?Paths = null;
    if (p.infill_pattern == .flow and p.infill_density > 0 and !reg.sparse.isEmpty()) {
        const band_mm = @max(2.0, 3 * p.top_thickness);
        const band: u32 = @intFromFloat(@ceil(band_mm / p.layer_height));
        under_band = try memo.underBand(ctx.outlines, i, band, ctx.gen);
    }
    const walls = reg.walls;
    const wall_n = walls.len;
    const sparse = reg.sparse;

    // Step 5.
    const skin_inset = -@divTrunc(w, 2) + geom.fromMm(p.skin_overlap * width_mm);
    const skin_region = try memo.fill(reg, true, skin_inset, ctx.gen);
    // Lines have no direction, so the angle is modulo 180 degrees.
    const skin_angle = @mod(p.skin_angle + p.skin_angle_step * @as(f64, @floatFromInt(i)), 180);
    var skin_lines: Paths = .empty;
    var skin_loops: Paths = .empty;
    switch (p.skin_pattern) {
        // `lines`: the lines join into zigzag paths at the walls, as the
        // nozzle prints a solid surface: back and forth, with no travel and
        // no retraction between the lines. `monotonic` keeps its own order.
        .lines => {
            const set = try infill.lines(s, skin_region, w, skin_angle, w);
            skin_lines = try infill.connect(s, skin_region, set, w, skin_angle);
        },
        .monotonic => skin_lines = try infill.lines(s, skin_region, w, skin_angle, w),
        .concentric => skin_loops = try infill.concentric(s, skin_region, w),
    }

    var sparse_lines: Paths = .empty;
    var sparse_loops: Paths = .empty;
    if (p.infill_density > 0 and !sparse.isEmpty()) {
        const inset = -@divTrunc(w, 2) + geom.fromMm(p.infill_overlap * width_mm);
        const region = try memo.fill(reg, false, inset, ctx.gen);
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
            .triangles, .cubic => {
                // Three line sets, so each set is 3 times as far apart as
                // one set of the same density.
                const spacing = geom.fromMm(3 * width_mm / p.infill_density);
                const step: f64 = if (p.infill_pattern == .triangles) 60 else 120;
                // Cubic: each set moves along its normal by the layer
                // height, so the lines of the layers make planes at 45
                // degrees, and three such planes make cubes on a corner.
                const phase: i64 = if (p.infill_pattern == .cubic) geom.fromMm(layer.z) else 0;
                for (0..3) |k| {
                    var set = try infill.linesPhase(s, region, spacing, p.infill_angle + step * @as(f64, @floatFromInt(k)), phase, w);
                    try sparse_lines.appendAll(s, set);
                    set.deinit(s);
                }
            },
            .gyroid => {
                const period = infill.gyroid_k * width_mm / p.infill_density;
                sparse_lines = try infill.gyroid(s, region, period, layer.z, w);
            },
            .concentric => {
                const spacing = geom.fromMm(width_mm / p.infill_density);
                sparse_loops = try infill.concentric(s, region, spacing);
            },
            .honeycomb => {
                sparse_lines = try infill.honeycomb(s, region, w, p.infill_density, p.infill_angle, w);
            },
            .zigzag, .flow => {
                const angle = p.infill_angle + @as(f64, if (i % 2 == 0) 0 else 90);
                const spacing = geom.fromMm(width_mm / p.infill_density);
                if (p.infill_pattern == .zigzag) {
                    const set = try infill.lines(s, region, spacing, angle, w);
                    sparse_lines = try infill.connect(s, region, set, spacing, angle);
                } else {
                    // The band under the top surfaces: the area that is not
                    // under all of the next layers of the band.
                    var near: Paths = .empty;
                    var far = region;
                    if (under_band) |u| if (!u.isEmpty()) {
                        near = try clip.difference(s, region, u);
                        far = try clip.intersect(s, region, u);
                    } else {
                        // Near the top of the part: all of it is the band.
                        near = region;
                        far = .empty;
                    };
                    const dense = @max(@divTrunc(spacing, 2), w);
                    const far_set = try infill.lines(s, far, spacing, angle, w);
                    sparse_lines = try infill.connect(s, far, far_set, spacing, angle);
                    if (!near.isEmpty()) {
                        // The near band uses the same grid at half the
                        // spacing, so its lines meet the far lines.
                        const near_set = try infill.lines(s, near, dense, angle, w);
                        const joined = try infill.connect(s, near, near_set, dense, angle);
                        try sparse_lines.appendAll(s, joined);
                    }
                }
            },
        }
    }

    // Step 6.
    var ironing_lines: Paths = .empty;
    if (p.ironing and !first) {
        const above: Paths = if (i + 1 < ctx.outlines.len) ctx.outlines[i + 1] else .empty;
        const top = try clip.difference(s, outline, above);
        const region = try offset_mod.offset(s, top, -geom.fromMm(p.ironing_inset), .{});
        // Ironing goes back and forth too, in one path for each area.
        const spacing = geom.fromMm(p.ironing_spacing);
        const set = try infill.lines(s, region, spacing, skin_angle + 90, 0);
        ironing_lines = try infill.connect(s, region, set, spacing, skin_angle + 90);
    }

    // Step 7.
    var rings: std.ArrayList(Paths) = .empty;
    if (i < p.skirt_layers or (first and p.brim_width > 0)) {
        const w0 = geom.fromMm(r.first_layer_line_width);
        const base = try outerBoundaries(s, ctx.outlines[0]);
        const brim_n: usize = if (p.brim_width > 0) @intFromFloat(@ceil(p.brim_width / r.first_layer_line_width - 1e-6)) else 0;
        const brim_edge = @as(i64, @intCast(brim_n)) * w0;
        // The skirt, outermost loop first.
        if (i < p.skirt_layers) {
            var k: usize = p.skirt_loops;
            while (k > 0) {
                k -= 1;
                const d = brim_edge + geom.fromMm(p.skirt_distance) + @divTrunc(w, 2) + @as(i64, @intCast(k)) * w;
                try rings.append(s, try offset_mod.offset(s, base, d, .{ .join = .round }));
            }
        }
        // The brim, outermost loop first, so that it ends at the part.
        if (first) {
            var k: usize = brim_n;
            while (k > 0) {
                k -= 1;
                const d = @divTrunc(w0, 2) + @as(i64, @intCast(k)) * w0;
                try rings.append(s, try offset_mod.offset(s, base, d, .{ .join = .round }));
            }
        }
    }

    // Step 9.
    var pos: Point = if (outline.points.items.len > 0) outline.points.items[0] else .init(0, 0);
    // The index of the layer below, made when a hidden seam needs it.
    var below: BelowIndex = .{ .s = s, .outline = if (i > 0) ctx.outlines[i - 1] else .empty };
    const seam: Seam = .{ .mode = p.seam, .layer = i, .below = &below, .memo = memo };
    for (rings.items) |ring| try addOrdered(s, a, &lp, &pos, ring, true, .skirt);
    try addOrdered(s, a, &lp, &pos, sup_walls, true, .support);
    try addOrdered(s, a, &lp, &pos, sup_lines, false, .support);
    try addOrdered(s, a, &lp, &pos, sup_iface, false, .support_interface);
    var k = wall_n;
    while (k > 1) {
        k -= 1;
        try addOrderedSeam(s, a, &lp, &pos, walls[k], true, .inner_wall, seam);
    }
    if (wall_n > 0) try addOrderedSeam(s, a, &lp, &pos, walls[0], true, .outer_wall, seam);
    try addThin(a, &lp, &pos, &reg);
    if (p.skin_pattern == .monotonic) {
        try addMonotonic(s, a, &lp, &pos, skin_lines, skin_angle, .skin);
    } else {
        try addOrdered(s, a, &lp, &pos, skin_lines, false, .skin);
    }
    try addOrdered(s, a, &lp, &pos, skin_loops, true, .skin);
    try addOrdered(s, a, &lp, &pos, sparse_lines, false, .infill);
    try addOrdered(s, a, &lp, &pos, sparse_loops, true, .infill);
    try addOrdered(s, a, &lp, &pos, ironing_lines, false, .ironing);
    return lp;
}

/// The vertex where a wall loop starts (its seam). See `Project.seam`.
///
/// For `sharpest`, each vertex gets the turn angle of the loop at that
/// vertex. The material is on the left, so a right turn is an inside
/// (concave) corner. An inside corner hides the seam best, so it scores
/// more than an outside corner of the same angle. Only corners of at least
/// 25 degrees count: a curve made of many short edges has small turns, and
/// its seam goes to the rear.
fn seamIndex(path: []const Point, mode: settings_mod.SeamMode, salt: u64) usize {
    switch (mode) {
        .nearest => unreachable,
        .hidden => return hiddenIndex(path, null),
        .rear => return rearIndex(path),
        .random => {
            var prng = std.Random.DefaultPrng.init(salt);
            return prng.random().uintLessThan(usize, path.len);
        },
        .sharpest => {
            const min_turn = 25.0 * std.math.pi / 180.0;
            var best: ?usize = null;
            var best_score: f64 = 0;
            for (path, 0..) |v, i| {
                const u = path[(i + path.len - 1) % path.len];
                const w = path[(i + 1) % path.len];
                const ax: f64 = @floatFromInt(v.x - u.x);
                const ay: f64 = @floatFromInt(v.y - u.y);
                const bx: f64 = @floatFromInt(w.x - v.x);
                const by: f64 = @floatFromInt(w.y - v.y);
                const turn = std.math.atan2(ax * by - ay * bx, ax * bx + ay * by);
                if (@abs(turn) < min_turn) continue;
                const score = if (turn < 0) 2.0 * -turn else turn;
                // A tie goes to the vertex further back (larger y), then
                // further left, so that similar layers pick the same corner.
                const better = best == null or score > best_score + 1e-9 or
                    (@abs(score - best_score) <= 1e-9 and rearBefore(v, path[best.?]));
                if (better) {
                    best = i;
                    best_score = score;
                }
            }
            return best orelse rearIndex(path);
        },
    }
}

/// The hidden seam: the vertex with the best score.
///
/// - The turn of the loop at the vertex, over about 1 mm on each side, so
///   that a corner of many short segments (a curved CAD export) is still a
///   corner. An inside corner hides the seam best: the blob is in the
///   corner, and the eye does not see it. An outside corner hides it less.
/// - Toward the back (a larger y): the front of a part faces the user.
/// - A vertex that is not over the layer below (an overhang) loses: the
///   seam blob would sag there.
/// A tie goes to the vertex further back, so similar layers pick the same
/// vertex, and the seam is one straight line.
fn hiddenIndex(path: []const Point, below: ?*const InsideIndex) usize {
    const n = path.len;
    if (n < 3) return 0;
    const reach: f64 = 1000; // 1 mm, in µm
    var ymin = path[0].y;
    var ymax = path[0].y;
    for (path) |q| {
        ymin = @min(ymin, q.y);
        ymax = @max(ymax, q.y);
    }
    const yspan: f64 = @floatFromInt(@max(ymax - ymin, 1));
    var best: usize = 0;
    var best_score: f64 = -std.math.inf(f64);
    for (path, 0..) |v, i| {
        // The points about 1 mm back and 1 mm on along the loop (or the
        // next vertex, for a short loop).
        const back = walkFrom(path, i, reach, false);
        const on = walkFrom(path, i, reach, true);
        const ax: f64 = @floatFromInt(v.x - back.x);
        const ay: f64 = @floatFromInt(v.y - back.y);
        const bx: f64 = @floatFromInt(on.x - v.x);
        const by: f64 = @floatFromInt(on.y - v.y);
        // Counterclockwise loops: a right turn (negative) is an inside
        // corner.
        const turn = std.math.atan2(ax * by - ay * bx, ax * bx + ay * by);
        var score: f64 = if (turn < 0) 3.0 * -turn else 0.6 * turn;
        score += 0.35 * @as(f64, @floatFromInt(v.y - ymin)) / yspan;
        if (below) |b| if (!b.inside(v)) {
            score -= 2;
        };
        const better = score > best_score + 1e-9 or (@abs(score - best_score) <= 1e-9 and rearBefore(v, path[best]));
        if (better) {
            best = i;
            best_score = score;
        }
    }
    return best;
}

/// The first point at least `dist` µm along the loop from vertex i (on, or
/// back), or the farthest vertex if the loop is short.
fn walkFrom(path: []const Point, i: usize, dist: f64, forward: bool) Point {
    const n = path.len;
    var j = i;
    var run: f64 = 0;
    var steps: usize = 0;
    while (steps + 1 < n) : (steps += 1) {
        const next = if (forward) (j + 1) % n else (j + n - 1) % n;
        run += std.math.hypot(@as(f64, @floatFromInt(path[next].x - path[j].x)), @as(f64, @floatFromInt(path[next].y - path[j].y)));
        j = next;
        if (run >= dist) break;
        if (steps + 2 >= n / 2) break;
    }
    return path[j];
}

/// The edges of a set of polygons in bands of y, for a fast test if a point
/// is inside (a winding number other than 0). A horizontal ray from the
/// point crosses only edges whose y range holds the y of the point, and
/// these edges are all in the band of that y. Each edge goes in each band
/// that its y range touches.
const InsideIndex = struct {
    min: i64,
    width: i64,
    /// Band k has the edges from starts[k] to starts[k + 1].
    starts: []u32,
    edges: [][2]Point,

    fn init(s: Allocator, paths: Paths) Allocator.Error!InsideIndex {
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        for (paths.points.items) |q| {
            lo = @min(lo, q.y);
            hi = @max(hi, q.y);
        }
        const n = paths.points.items.len;
        const want: usize = std.math.clamp(2 * std.math.sqrt(n), 1, 4096);
        const span: i64 = @max(hi - lo + 1, 1);
        const width: i64 = @max(1, @divFloor(span + @as(i64, @intCast(want)) - 1, @as(i64, @intCast(want))));
        const bands: usize = @intCast(@divFloor(span + width - 1, width));
        var idx: InsideIndex = .{ .min = lo, .width = width, .starts = try s.alloc(u32, bands + 1), .edges = &.{} };
        @memset(idx.starts, 0);
        // Two passes over the edges: count, then fill.
        var fill: []u32 = &.{};
        defer s.free(fill);
        for (0..2) |pass| {
            if (pass == 1) {
                for (1..idx.starts.len) |k| idx.starts[k] += idx.starts[k - 1];
                idx.edges = try s.alloc([2]Point, idx.starts[bands]);
                fill = try s.dupe(u32, idx.starts[0..bands]);
            }
            for (0..paths.count()) |k| {
                const poly = paths.get(k);
                for (poly, 0..) |a, i| {
                    const b = poly[(i + 1) % poly.len];
                    if (a.y == b.y) continue;
                    const b0 = idx.band(@min(a.y, b.y));
                    const b1 = idx.band(@max(a.y, b.y) - 1);
                    for (b0..b1 + 1) |bi| {
                        if (pass == 0) {
                            idx.starts[bi + 1] += 1;
                        } else {
                            idx.edges[fill[bi]] = .{ a, b };
                            fill[bi] += 1;
                        }
                    }
                }
            }
        }
        return idx;
    }

    fn band(idx: InsideIndex, y: i64) usize {
        const k = @divFloor(y - idx.min, idx.width);
        return @intCast(std.math.clamp(k, 0, @as(i64, @intCast(idx.starts.len - 2))));
    }

    fn inside(idx: InsideIndex, p: Point) bool {
        const k = idx.band(p.y);
        var winding: i32 = 0;
        for (idx.edges[idx.starts[k]..idx.starts[k + 1]]) |e| {
            const a = e[0];
            const b = e[1];
            if (a.y <= p.y) {
                if (b.y > p.y and cross3(a, b, p) > 0) winding += 1;
            } else if (b.y <= p.y and cross3(a, b, p) < 0) winding -= 1;
        }
        return winding != 0;
    }
};

fn cross3(a: Point, b: Point, p: Point) i128 {
    return @as(i128, b.x - a.x) * @as(i128, p.y - a.y) - @as(i128, p.x - a.x) * @as(i128, b.y - a.y);
}

fn rearBefore(a: Point, b: Point) bool {
    return a.y > b.y or (a.y == b.y and a.x < b.x);
}

/// The vertex with the largest y. A tie goes to the smallest x.
fn rearIndex(path: []const Point) usize {
    var best: usize = 0;
    for (path, 0..) |q, i| {
        if (rearBefore(q, path[best])) best = i;
    }
    return best;
}

/// The outer boundaries (counterclockwise loops) of a set of polygons,
/// without the holes.
fn outerBoundaries(s: Allocator, paths: Paths) Allocator.Error!Paths {
    var out: Paths = .empty;
    for (0..paths.count()) |j| {
        const poly = paths.get(j);
        if (geom.area2(poly) > 0) try out.append(s, poly);
    }
    return out;
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

/// The top surface of layer j (its outline minus the outline above) and its
/// bottom surface (its outline minus the outline below). The first layer has
/// nothing below it and the last layer nothing above it, so their surfaces
/// are the whole outline. The caller owns the results.
pub fn surfaces(gpa: Allocator, outlines: []const Paths, j: usize) Allocator.Error![2]Paths {
    var top = if (j + 1 < outlines.len) blk: {
        var pair = try surfacePair(gpa, outlines, j);
        pair[1].deinit(gpa);
        break :blk pair[0];
    } else try outlines[j].clone(gpa);
    errdefer top.deinit(gpa);
    const bottom = if (j > 0) blk: {
        var pair = try surfacePair(gpa, outlines, j - 1);
        pair[0].deinit(gpa);
        break :blk pair[1];
    } else try outlines[j].clone(gpa);
    return .{ top, bottom };
}

/// The top surface of layer j and the bottom surface of layer j + 1, from
/// one boolean. The caller owns the results.
pub fn surfacePair(gpa: Allocator, outlines: []const Paths, j: usize) Allocator.Error![2]Paths {
    return clip.differences(gpa, outlines[j], outlines[j + 1]);
}

/// Adds the paths of `set` to the plan in greedy nearest-neighbor order.
/// Adds parallel lines in monotonic order: from one side of the area to the
/// other, by their place across the line direction. Each line starts at its
/// end nearer to the nozzle, so the nozzle goes back and forth. Each line
/// then lies against the line before it on the same side, and the surface
/// has an even look. The side to start from is the side nearer to the
/// nozzle.
fn addMonotonic(s: Allocator, a: Allocator, lp: *LayerPlan, pos: *Point, set: Paths, angle_deg: f64, feature: Feature) Allocator.Error!void {
    const n = set.count();
    if (n == 0) return;
    const rad = angle_deg * std.math.pi / 180.0;
    // The normal of the lines.
    const nx = -@sin(rad);
    const ny = @cos(rad);
    const Key = struct { across: f64, along: f64, i: usize };
    const keys = try s.alloc(Key, n);
    const ax = @cos(rad);
    const ay = @sin(rad);
    for (keys, 0..) |*k, i| {
        const path = set.get(i);
        const mx = (@as(f64, @floatFromInt(path[0].x)) + @as(f64, @floatFromInt(path[path.len - 1].x))) / 2;
        const my = (@as(f64, @floatFromInt(path[0].y)) + @as(f64, @floatFromInt(path[path.len - 1].y))) / 2;
        k.* = .{ .across = mx * nx + my * ny, .along = mx * ax + my * ay, .i = i };
    }
    std.mem.sort(Key, keys, {}, struct {
        fn lt(_: void, x: Key, y: Key) bool {
            if (x.across != y.across) return x.across < y.across;
            return x.along < y.along;
        }
    }.lt);
    // Start from the side nearer to the nozzle.
    const p_across = @as(f64, @floatFromInt(pos.x)) * nx + @as(f64, @floatFromInt(pos.y)) * ny;
    const reverse = @abs(p_across - keys[n - 1].across) < @abs(p_across - keys[0].across);
    for (0..n) |k| {
        const key = keys[if (reverse) n - 1 - k else k];
        const path = set.get(key.i);
        const flip = pos.distSq(path[path.len - 1]) < pos.distSq(path[0]);
        if (flip) {
            const rev = try s.alloc(Point, path.len);
            for (path, 0..) |q, j| rev[path.len - 1 - j] = q;
            try lp.points.append(a, rev);
            pos.* = rev[rev.len - 1];
        } else {
            try lp.points.append(a, path);
            pos.* = path[path.len - 1];
        }
        try lp.paths.append(a, .{ .feature = feature, .closed = false });
    }
}

fn addOrdered(s: Allocator, a: Allocator, lp: *LayerPlan, pos: *Point, set: Paths, closed: bool, feature: Feature) Allocator.Error!void {
    return addOrderedSeam(s, a, lp, pos, set, closed, feature, null);
}

const Seam = struct {
    mode: settings_mod.SeamMode,
    layer: usize,
    /// The outline of the layer below: the hidden seam avoids a point over
    /// air.
    below: *BelowIndex,
    /// The memo that keeps the seams of the walls of the layer.
    memo: ?*Memo = null,
};

/// The index of the outline below (see `InsideIndex`), made on the first
/// use.
const BelowIndex = struct {
    s: Allocator,
    outline: Paths,
    index: ?InsideIndex = null,

    /// The index, or null if there is no layer below.
    fn get(self: *BelowIndex) Allocator.Error!?*const InsideIndex {
        if (self.outline.isEmpty()) return null;
        if (self.index == null) self.index = try .init(self.s, self.outline);
        return &self.index.?;
    }
};

/// The seam vertex of each loop of `set` for `rule` (see `Seam`).
fn seamIndices(set: Paths, rule: Seam, out: []u32) Allocator.Error!void {
    const below = if (rule.mode == .hidden) try rule.below.get() else null;
    for (out, 0..) |*v, j| v.* = @intCast(if (rule.mode == .hidden)
        hiddenIndex(set.get(j), below)
    else
        seamIndex(set.get(j), rule.mode, rule.layer *% 1_000_003 +% j));
}

/// `addOrdered`, with a seam rule for loops. With a rule, each loop starts at
/// its seam vertex (see `seamIndex`), and the greedy order uses the distance
/// to that vertex.
fn addOrderedSeam(s: Allocator, a: Allocator, lp: *LayerPlan, pos: *Point, set: Paths, closed: bool, feature: Feature, seam: ?Seam) Allocator.Error!void {
    const n = set.count();
    if (n == 0) return;
    const used = try s.alloc(bool, n);
    @memset(used, false);
    var fixed: ?[]const u32 = null;
    if (closed) if (seam) |rule| if (rule.mode != .nearest) {
        fixed = if (rule.memo) |m| try m.seams(set, rule) else null;
        if (fixed == null) {
            const f = try s.alloc(u32, n);
            try seamIndices(set, rule, f);
            fixed = f;
        }
    };
    for (0..n) |_| {
        var best: usize = 0;
        var best_d: i128 = std.math.maxInt(i128);
        var best_at: usize = 0;
        for (0..n) |j| {
            if (used[j]) continue;
            const path = set.get(j);
            if (fixed) |f| {
                const d = pos.distSq(path[f[j]]);
                if (d < best_d) {
                    best_d = d;
                    best = j;
                    best_at = f[j];
                }
            } else if (closed) {
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
            // Start at the seam vertex.
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

/// Adds the thin wall loops, each with its own line width.
fn addThin(a: Allocator, lp: *LayerPlan, pos: *Point, reg: *const Regions) Allocator.Error!void {
    for (0..reg.thin.count()) |k| {
        const loop = reg.thin.get(k);
        try lp.points.append(a, loop);
        try lp.paths.append(a, .{ .feature = .outer_wall, .closed = true, .width = reg.thin_width[k] });
        pos.* = loop[0];
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
        .ironing, .skirt, .support, .support_interface => unreachable,
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
        // The lines join into zigzag paths: count the points.
        n += lp.points.get(pi).len;
        // No ironing line goes over the upper box, and each line stays the
        // inset away from the outside edge.
        for (lp.points.get(pi)) |q| {
            const over_upper = q.x > 5000 + inset and q.x < 15000 - inset and q.y > 5000 + inset and q.y < 15000 - inset;
            try testing.expect(!over_upper);
            try testing.expect(q.x >= inset - 2 and q.x <= 20000 - inset + 2);
        }
    }
    try testing.expect(n > 200);

    // Layer 5 (z 1.1) is inside the lower box: no ironing.
    var mid = try plan(gpa, ctx, 5);
    defer mid.deinit();
    for (mid.paths.items) |path| try testing.expect(path.feature != .ironing);
}

test "skirt and brim on the first layer" {
    const gpa = testing.allocator;
    const mesh = @import("mesh.zig");
    var m = try mesh.shapes.box(gpa, 20, 20, 2);
    defer m.deinit(gpa);
    var st: settings_mod.Settings = .{};
    st.project.brim_width = 3;
    st.project.skirt_loops = 2;
    st.project.skirt_distance = 3;
    const r = try st.resolve();
    const layers = try slicer.layerTable(gpa, 2, 0.3, 0.2);
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

    var lp = try plan(gpa, ctx, 0);
    defer lp.deinit();
    // The first paths are the skirt and the brim: 2 skirt loops, then
    // ceil(3 / 0.5) = 6 brim loops, before any wall.
    var n: usize = 0;
    while (n < lp.paths.items.len and lp.paths.items[n].feature == .skirt) n += 1;
    try testing.expectEqual(@as(usize, 8), n);
    // The outermost skirt loop: brim edge 3 mm + distance 3 mm + half a
    // line width (0.25 mm) + one line width (0.5 mm) for the second loop.
    var box = geom.Box.empty;
    for (lp.points.get(0)) |q| box.extend(q);
    try testing.expectApproxEqAbs(@as(f64, -6.75), geom.toMm(box.min.x), 0.01);
    // The last brim loop is half a line width from the part.
    box = geom.Box.empty;
    for (lp.points.get(7)) |q| box.extend(q);
    try testing.expectApproxEqAbs(@as(f64, -0.25), geom.toMm(box.min.x), 0.01);

    // Layer 1 has no skirt (skirt_layers is 1) and no brim.
    var l1 = try plan(gpa, ctx, 1);
    defer l1.deinit();
    for (l1.paths.items) |path| try testing.expect(path.feature != .skirt);
}

test "seam placement" {
    // An L shape (counterclockwise) has one inside corner, at (10, 10).
    const l = [_]Point{ .init(0, 0), .init(20_000, 0), .init(20_000, 10_000), .init(10_000, 10_000), .init(10_000, 20_000), .init(0, 20_000) };
    try testing.expectEqual(@as(usize, 3), seamIndex(&l, .sharpest, 0));
    // The rear: the largest y, then the smallest x.
    try testing.expectEqual(@as(usize, 5), seamIndex(&l, .rear, 0));
    // A square has only outside corners: the rear one wins the tie.
    const sq = [_]Point{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) };
    try testing.expectEqual(@as(usize, 3), seamIndex(&sq, .sharpest, 0));
    // A fine circle has no corner of 25 degrees: the seam goes to the rear.
    var circle: [360]Point = undefined;
    for (&circle, 0..) |*q, i| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 360.0;
        q.* = .{ .x = @intFromFloat(@round(10_000 * @cos(a))), .y = @intFromFloat(@round(10_000 * @sin(a))) };
    }
    try testing.expectEqual(@as(usize, 90), seamIndex(&circle, .sharpest, 0));
    // Random is the same for the same salt.
    try testing.expectEqual(seamIndex(&circle, .random, 7), seamIndex(&circle, .random, 7));
}

test "hidden seam" {
    // The L: the inside corner.
    const l = [_]Point{ .init(0, 0), .init(20_000, 0), .init(20_000, 10_000), .init(10_000, 10_000), .init(10_000, 20_000), .init(0, 20_000) };
    try testing.expectEqual(@as(usize, 3), hiddenIndex(&l, null));
    // An L with the inside corner made of 20 short segments (a round
    // fillet of 0.5 mm): still in the corner.
    var fillet: std.ArrayList(Point) = .empty;
    defer fillet.deinit(testing.allocator);
    try fillet.appendSlice(testing.allocator, &.{ .init(0, 0), .init(20_000, 0), .init(20_000, 10_000) });
    for (0..21) |k| {
        const a = std.math.pi / 2.0 * @as(f64, @floatFromInt(k)) / 20.0;
        // From (10.5, 10) around the center (10.5, 10.5) to (10, 10.5).
        try fillet.append(testing.allocator, .{ .x = @intFromFloat(@round(10_500 - 500 * @sin(a))), .y = @intFromFloat(@round(10_500 - 500 * @cos(a))) });
    }
    try fillet.appendSlice(testing.allocator, &.{ .init(10_000, 20_000), .init(0, 20_000) });
    const fi = hiddenIndex(fillet.items, null);
    try testing.expect(fi >= 3 and fi <= 23);
    // A circle: no corner, so the back.
    var circle: [360]Point = undefined;
    for (&circle, 0..) |*q, i| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 360.0;
        q.* = .{ .x = @intFromFloat(@round(10_000 * @cos(a))), .y = @intFromFloat(@round(10_000 * @sin(a))) };
    }
    try testing.expectEqual(@as(usize, 90), hiddenIndex(&circle, null));
    // A square over a layer below that has only its left half: the seam
    // goes to a back corner over the support (the left one).
    const sq = [_]Point{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) };
    var below: Paths = .empty;
    defer below.deinit(testing.allocator);
    try below.append(testing.allocator, &.{ .init(-1000, -1000), .init(5_000, -1000), .init(5_000, 11_000), .init(-1000, 11_000) });
    const index: InsideIndex = try .init(testing.allocator, below);
    defer testing.allocator.free(index.starts);
    defer testing.allocator.free(index.edges);
    try testing.expectEqual(@as(usize, 3), hiddenIndex(&sq, &index));
}

test "monotonic skin: the lines go from one side to the other" {
    const gpa = testing.allocator;
    var lp: LayerPlan = .{ .arena = .init(gpa), .index = 0, .z = 0.2, .height = 0.2, .width = 0.4 };
    defer lp.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(gpa);
    defer scratch_arena.deinit();
    const s = scratch_arena.allocator();
    // Four horizontal lines (angle 0) out of order: y = 2, 0, 3, 1.
    var set: Paths = .empty;
    for ([_]i64{ 2, 0, 3, 1 }) |y| try set.append(s, &.{ .init(0, y * 1000), .init(10000, y * 1000) });
    var pos: Point = .init(0, -5000);
    try addMonotonic(s, lp.arena.allocator(), &lp, &pos, set, 0, .skin);
    // From the side of the nozzle (low y), in order, back and forth.
    var last_y: i64 = -1;
    for (0..4) |i| {
        const path = lp.points.get(i);
        try testing.expect(path[0].y > last_y);
        last_y = path[0].y;
        // Each line starts at the end nearer to the end of the line before.
        if (i > 0) {
            const prev = lp.points.get(i - 1);
            try testing.expectEqual(prev[prev.len - 1].x, path[0].x);
        }
    }
}


test "thin walls: a sheet thinner than a line prints" {
    const gpa = testing.allocator;
    const mesh = @import("mesh.zig");
    // A sheet 0.3 mm thick (a line is 0.44 mm), 20 mm long, 5 mm tall.
    var b: mesh.Builder = .init(gpa);
    try mesh.shapes.addBox(&b, 0, 0, 0, 20, 0.3, 5);
    var m = try b.finish();
    defer m.deinit(gpa);
    var st: settings_mod.Settings = .{};
    const r = try st.resolve();
    const layers = try slicer.layerTable(gpa, 5, 0.3, 0.2);
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
    var lp = try plan(gpa, ctx, 10);
    defer lp.deinit();
    var thin: usize = 0;
    for (lp.paths.items) |path| {
        if (path.feature == .outer_wall and path.width > 0) {
            thin += 1;
            try testing.expect(path.width > 0.1 and path.width < 0.2);
        }
    }
    try testing.expect(thin >= 1);
    // Off: nothing.
    st.project.thin_walls = false;
    const r2 = try st.resolve();
    const ctx2: Context = .{ .resolved = &r2, .layers = layers, .outlines = outlines };
    var lp2 = try plan(gpa, ctx2, 10);
    defer lp2.deinit();
    for (lp2.paths.items) |path| try testing.expect(path.feature != .outer_wall);
}

test "the skin from the surfaces is the inner area minus the supported area" {
    const gpa = testing.allocator;
    const mesh = @import("mesh.zig");
    var m = try mesh.shapes.demo(gpa);
    defer m.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const layers = try slicer.layerTable(a, 14, 0.3, 0.2);
    var idx = try slicer.FaceIndex.build(a, &m, layers, 0);
    const outlines = try a.alloc(Paths, layers.len);
    for (outlines, 0..) |*o, li| o.* = try slicer.sliceAt(a, &m, idx.get(li), layers[li].sliceZ(), 5, 1000);
    const t = 4;
    const b = 3;
    for (0..layers.len) |i| {
        const inner = try offset_mod.offset(a, outlines[i], -880, .{});
        // The direct way: the intersection of the outlines above and below.
        var supported: Paths = .empty;
        if (i + t < layers.len and i >= b) {
            supported = outlines[i - b];
            for (i - b + 1..i + t + 1) |k| if (k != i) {
                supported = try clip.intersect(a, supported, outlines[k]);
            };
        }
        const want = try clip.difference(a, inner, supported);
        // From the surfaces.
        var exposed: Paths = .empty;
        for (0..t) |k| if (i + k < layers.len) try exposed.appendAll(a, (try surfaces(a, outlines, i + k))[0]);
        for (0..b) |k| if (k <= i) try exposed.appendAll(a, (try surfaces(a, outlines, i - k))[1]);
        const got = try clip.intersect(a, inner, exposed);
        try testing.expectApproxEqAbs(want.areaMm2(), got.areaMm2(), 0.01);
    }
}

