//! G-code output: from layer plans to printer commands.
//!
//! - A travel move (G0) goes to the start of each path. A travel longer
//!   than `retract_min_travel` first pulls the filament back (retraction),
//!   so that the nozzle does not ooze on the way. A travel from one tree
//!   support path to the next has no retraction if it crosses no edge of
//!   the part: the support comes off, and a tree has many small islands.
//! - An extrusion move (G1 with E) goes along each path. The E value is the
//!   length of filament to push, in mm. The plastic that comes out of the
//!   nozzle is a bead with a flat top and bottom and round sides (see
//!   flow.zig). Its volume is the bead area times the length. The filament
//!   has the cross section of a circle, so the filament length is that
//!   volume divided by the circle area. The output uses relative E (M83):
//!   each E is the amount for that move only.
//! - A path that is not planar (slope smoothing, see slope.zig) has a z
//!   and a bead area at each point. The nozzle goes down to its first
//!   point, each move has X, Y, Z, and E, and the nozzle goes back up to
//!   the z of the layer at its end. Z limits the speed and the
//!   acceleration of these moves (`max_z_speed`, `max_z_accel`).
//! - A path can have its own settings (a modifier volume, or a part of a
//!   plate: see LayerPlan.region_resolved). Its speed, its acceleration,
//!   and its flow come from them. The travel, the retraction, the cooling,
//!   and the fan come from the settings of the layer.
//! - A plate can have many filaments (see filaments.zig). Each path
//!   prints with the filament of its settings (`project.filament`). Before
//!   a path of another filament, the emitter changes the filament: the
//!   change G-code of the machine, or M600 (PAUSE on Klipper), or a tool
//!   change Tn. The change takes `change_time`, and a tool change flushes
//!   the old color out (the flush counts in the filament of the new slot).
//! - Comments mark each layer (";LAYER:n") and each feature
//!   (";TYPE:WALL-OUTER"). These follow the CuraEngine convention (see
//!   docs/references/), which G-code viewers and printdeck read.
//!
//! Time: the emitter writes each layer in two passes. The first pass makes
//! the moves of the layer with no text, and the motion planner (see
//! motion.zig) gives the time of each move, with the acceleration and the
//! junction speeds. The second pass writes the moves and adds up their
//! times. Retractions, Z moves, and z hops are stops: each is a move from
//! rest to rest.
//!
//! Cooling: a layer shorter than `min_layer_time` prints slower (but not
//! below `min_speed`). The emitter finds the slowest speed ratio that
//! still gives the layer `min_layer_time` with the planner (a bisection),
//! so the layer prints no slower than it must. A layer shorter than
//! `fan_boost_time` gets the fan at `fan_max_speed`.
//!
//! Combing: a travel inside the part goes around the holes, with no
//! retraction (see `Emitter.comb`). The test of a straight travel looks at
//! the outline edges in a grid (see `CombIndex`).
//!
//! The work of a layer that does not depend on the layers before it (the
//! combing ways, the move lengths) is done on a planning thread before the
//! dry run (see `Prepared` and engine.zig).
//!
//! The emitter also adds up statistics: filament used and a time estimate.

const std = @import("std");
const Writer = std.Io.Writer;
const geom = @import("geom.zig");
const flow = @import("flow.zig");
const motion = @import("motion.zig");
const layer_mod = @import("layer.zig");
const settings_mod = @import("settings.zig");
const expr = @import("expr.zig");
const gcode_vars = @import("gcode_vars.zig");
const filaments = @import("filaments.zig");
const Feature = settings_mod.Feature;
const Resolved = settings_mod.Resolved;
const LayerPlan = layer_mod.LayerPlan;

pub const Stats = struct {
    layer_count: u32 = 0,
    /// Filament length, in mm.
    filament_mm: f64 = 0,
    /// Filament weight, in grams.
    filament_g: f64 = 0,
    /// The estimated print time, in seconds, with the acceleration (see
    /// motion.zig).
    print_time_s: f64 = 0,
    travel_mm: f64 = 0,
    retractions: u32 = 0,
    /// The filament changes (see filaments.zig).
    changes: u32 = 0,
    /// The filament length (mm) of each slot of the plate, with the flush
    /// of the changes to it.
    slot_mm: [filaments.max_slots]f64 = @splat(0),
    /// The layers of each prime tower (see `Towers`).
    tower_layers: [Towers.max]u32 = @splat(0),
    /// The purge (mm³) that did not fit in the rows of a tower layer.
    tower_short_mm3: f64 = 0,
    /// The weight (g) of each slot (see `Emitter.end`).
    slot_g: [filaments.max_slots]f64 = @splat(0),
    /// The filament length (mm) that the changes flushed, of all slots.
    flush_mm: f64 = 0,
    /// The filament length (mm) of the flush that went into the hidden
    /// lines after the changes (see `Emitter.hiddenRun`). The lines count
    /// in `filament_mm`, and this part is not in `flush_mm`.
    flush_hidden_mm: f64 = 0,
};

/// What the emitter records for each path of a layer, if `record` is set.
pub const PathInfo = struct {
    /// The print time (s) from the start of the print to the start of the
    /// extrusion of the path (after the travel to it).
    start_time: f64,
    /// The print time (s) from the start of the print to the end of the path.
    end_time: f64,
    /// The cross-section area (mm^2) of the deposited bead, with the flow
    /// ratio and the ironing flow.
    area: f64,
    /// The travel to the path retracted the filament (and lifted the
    /// nozzle by z_hop, if z_hop is on).
    retracted: bool = false,
    /// The layer prints slower than planned, to cool (min_layer_time).
    slowed: bool = false,
    /// The fan while the path prints, from 0 (off) to 255.
    fan: u8 = 0,
    /// The slot of the filament of the path, from 0.
    tool: u8 = 0,
};

/// The most waypoints of a combing travel.
const max_way = 64;
/// The most polygons that one combing travel goes along.
const max_walks = 8;

/// The work of a layer that does not depend on the layers before it,
/// done on a planning thread before the dry run (see `prepare`):
///
/// - The combing way of each travel. The travel to path i starts at the
///   end of path i - 1, so its way is known as soon as the layer is
///   planned. The dry run finds the way of the first travel of the layer
///   and keeps it for the text.
/// - The length of each extrusion move, from the first point of its path.
///
/// The emitter uses a way or a length only if the nozzle is at the start
/// point that it was found from, so the G-code stays the same.
///
/// A dry run also keeps each answer that a travel gets from the outline
/// of the layer: the wipe arc, the z hop, and the travel between tree
/// supports. With the ways, these are all that the emitter reads from the
/// outline. So a later run of the same layer needs no outline (see
/// `replay` and stream.zig).
pub const Prepared = struct {
    /// One entry for each path of the layer.
    paths: std.ArrayList(PathPrep) = .empty,
    /// The waypoints of all ways.
    way_points: std.ArrayList([2]f64) = .empty,
    /// The length of the extrusion move to each point of `LayerPlan.points`
    /// (0 for the first point of a path).
    lengths: std.ArrayList(f64) = .empty,
    /// The edges of the outline, for fast combing tests, or null.
    index: ?CombIndex = null,
    /// The memory of `index`.
    arena: ?std.heap.ArenaAllocator = null,
    /// The plan of the layer from the dry run: the moves with their
    /// planned times, the speed ratio of a short layer, and the layer
    /// time. The text run of the same layer starts from the same state, so
    /// it takes them and does not plan again (see `Emitter.layer`).
    plan_moves: std.ArrayList(motion.Move) = .empty,
    plan_slow: f64 = 1,
    plan_time: f64 = 0,
    have_plan: bool = false,
    /// The layer comes from a stored stream (see stream.zig): it has no
    /// outline. The emitter then uses only the kept ways and answers. A
    /// question with no kept answer sets `Emitter.need_plan`.
    replay: bool = false,
    /// The nozzle position after the last path, and the feature of that
    /// path, or null for a layer with no path. The run of the next layer
    /// starts from them (see `Entry`).
    end: ?[2]f64 = null,
    end_feature: ?Feature = null,

    pub const PathPrep = struct {
        /// The nozzle position that the way of the travel starts from.
        from: [2]f64,
        /// The waypoints of the way: way_points[start..][0..n]. `n` is
        /// `retract` if no way goes inside the outline, and `unknown` if
        /// the way was not found.
        start: u32 = 0,
        n: i32 = unknown,
        /// The length of the move that closes the path, or 0.
        close: f64 = 0,
        /// The center of the wipe arc of the retraction before the travel:
        /// way_points[wipe], `retract` if no arc fits, or `unknown`.
        wipe: i32 = unknown,
        /// The travel with a retraction lifts the nozzle (see
        /// `Emitter.hopFor`).
        hop: Fact = .unknown,
        /// The travel crosses no edge of the part (see
        /// `Emitter.supportHop`).
        support_hop: Fact = .unknown,

        pub const retract: i32 = -1;
        pub const unknown: i32 = -2;
    };

    /// An answer from the outline of the layer, kept for a run with no
    /// outline (see `replay`).
    pub const Fact = enum(u8) { unknown, no, yes };

    pub fn clear(t: *Prepared) void {
        t.paths.clearRetainingCapacity();
        t.way_points.clearRetainingCapacity();
        t.lengths.clearRetainingCapacity();
        t.index = null;
        if (t.arena) |*a| _ = a.reset(.retain_capacity);
        t.plan_moves.clearRetainingCapacity();
        t.have_plan = false;
        t.replay = false;
        t.end = null;
        t.end_feature = null;
    }

    pub fn deinit(t: *Prepared, gpa: std.mem.Allocator) void {
        t.paths.deinit(gpa);
        t.way_points.deinit(gpa);
        t.lengths.deinit(gpa);
        t.plan_moves.deinit(gpa);
        if (t.arena) |*a| a.deinit();
    }
};

/// The edges of a layer outline in a uniform grid, and in bands of y, for
/// the combing test (see `Emitter.combClear`). The test of a segment then
/// looks only at the edges in the cells that the segment passes, and the
/// inside test only at the edges in the band of the point.
pub const CombIndex = struct {
    x0: f64,
    y0: f64,
    cell: f64,
    cols: usize,
    rows: usize,
    /// Cell c has the edges from starts[c] to starts[c + 1].
    starts: []u32,
    edges: []Edge,
    bands: geom.EdgeIndex,

    const Edge = struct { a: geom.Point, b: geom.Point, poly: u32 };

    /// A cell coordinate is grown by this many units on each side, so
    /// that a rounding error cannot skip a cell.
    const margin: f64 = 2;

    pub fn init(a: std.mem.Allocator, outline: geom.Paths) std.mem.Allocator.Error!CombIndex {
        const box = outline.bounds();
        const n = @max(outline.points.items.len, 1);
        const w: f64 = @floatFromInt(@max(box.max.x - box.min.x, 1));
        const h: f64 = @floatFromInt(@max(box.max.y - box.min.y, 1));
        // About one edge for each cell.
        const cell = geom.fmax(@sqrt(w * h / @as(f64, @floatFromInt(n))), 1);
        var idx: CombIndex = .{
            .x0 = @floatFromInt(box.min.x),
            .y0 = @floatFromInt(box.min.y),
            .cell = cell,
            .cols = @as(usize, @intFromFloat(w / cell)) + 1,
            .rows = @as(usize, @intFromFloat(h / cell)) + 1,
            .starts = &.{},
            .edges = &.{},
            .bands = try .init(a, outline, 0),
        };
        idx.starts = try a.alloc(u32, idx.cols * idx.rows + 1);
        @memset(idx.starts, 0);
        // Two passes over the edges: count, then fill.
        const Count = struct {
            idx: *CombIndex,
            fn visit(c: @This(), cell_i: usize) void {
                c.idx.starts[cell_i + 1] += 1;
            }
        };
        for (0..outline.count()) |k| {
            const poly = outline.get(k);
            for (poly, 0..) |p, i| idx.cells(p, poly[(i + 1) % poly.len], Count{ .idx = &idx });
        }
        for (1..idx.starts.len) |c| idx.starts[c] += idx.starts[c - 1];
        idx.edges = try a.alloc(Edge, idx.starts[idx.starts.len - 1]);
        const fill = try a.dupe(u32, idx.starts[0 .. idx.starts.len - 1]);
        const Fill = struct {
            idx: *CombIndex,
            fill: []u32,
            e: Edge,
            fn visit(c: @This(), cell_i: usize) void {
                c.idx.edges[c.fill[cell_i]] = c.e;
                c.fill[cell_i] += 1;
            }
        };
        for (0..outline.count()) |k| {
            const poly = outline.get(k);
            for (poly, 0..) |p, i| {
                const q = poly[(i + 1) % poly.len];
                idx.cells(p, q, Fill{ .idx = &idx, .fill = fill, .e = .{ .a = p, .b = q, .poly = @intCast(k) } });
            }
        }
        return idx;
    }

    /// Calls `v.visit` with each cell that the segment from p to q can
    /// touch: in each column of the grid, the cells of the y range of the
    /// segment in that column, grown by `margin`.
    fn cells(idx: *const CombIndex, p: geom.Point, q: geom.Point, v: anytype) void {
        const px: f64 = @floatFromInt(p.x);
        const py: f64 = @floatFromInt(p.y);
        const qx: f64 = @floatFromInt(q.x);
        const qy: f64 = @floatFromInt(q.y);
        const lo_x = geom.fmin(px, qx) - margin;
        const hi_x = geom.fmax(px, qx) + margin;
        const last_col: f64 = @floatFromInt(idx.cols - 1);
        const last_row: f64 = @floatFromInt(idx.rows - 1);
        const c0 = @floor((lo_x - idx.x0) / idx.cell);
        const c1 = @floor((hi_x - idx.x0) / idx.cell);
        if (c1 < 0 or c0 > last_col) return;
        const first: usize = @intFromFloat(geom.fmax(c0, 0));
        const end: usize = @intFromFloat(geom.fmin(c1, last_col));
        const dx = qx - px;
        for (first..end + 1) |cx| {
            const col_lo = idx.x0 + @as(f64, @floatFromInt(cx)) * idx.cell;
            var ya = py;
            var yb = qy;
            if (dx != 0) {
                const xa = std.math.clamp(col_lo, geom.fmin(px, qx), geom.fmax(px, qx));
                const xb = std.math.clamp(col_lo + idx.cell, geom.fmin(px, qx), geom.fmax(px, qx));
                ya = py + (xa - px) * (qy - py) / dx;
                yb = py + (xb - px) * (qy - py) / dx;
            }
            const r0 = @floor((geom.fmin(ya, yb) - margin - idx.y0) / idx.cell);
            const r1 = @floor((geom.fmax(ya, yb) + margin - idx.y0) / idx.cell);
            if (r1 < 0 or r0 > last_row) continue;
            const ry0: usize = @intFromFloat(geom.fmax(r0, 0));
            const ry1: usize = @intFromFloat(geom.fmin(r1, last_row));
            for (ry0..ry1 + 1) |cy| v.visit(cx * idx.rows + cy);
        }
    }

    /// `Emitter.combClear`, with the index: the same result.
    fn clear(idx: *const CombIndex, a: geom.Point, b: geom.Point, hit: *usize) bool {
        const Find = struct {
            idx: *const CombIndex,
            a: geom.Point,
            b: geom.Point,
            best: *usize,
            fn visit(c: @This(), cell_i: usize) void {
                for (c.idx.edges[c.idx.starts[cell_i]..c.idx.starts[cell_i + 1]]) |e| {
                    if (e.poly < c.best.* and crosses(c.a, c.b, e.a, e.b)) c.best.* = e.poly;
                }
            }
        };
        var best: usize = std.math.maxInt(usize);
        idx.cells(a, b, Find{ .idx = idx, .a = a, .b = b, .best = &best });
        hit.* = best;
        if (best != std.math.maxInt(usize)) return false;
        const m: geom.Point = .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2) };
        return idx.bands.inside(m);
    }
};

/// True if the segments a-b and c-e cross at one point inside both.
fn crosses(a: geom.Point, b: geom.Point, c: geom.Point, e: geom.Point) bool {
    const s1 = std.math.sign(geom.cross3(a, b, c));
    const s2 = std.math.sign(geom.cross3(a, b, e));
    if (s1 * s2 >= 0) return false;
    const s3 = std.math.sign(geom.cross3(c, e, a));
    const s4 = std.math.sign(geom.cross3(c, e, b));
    return s3 * s4 < 0;
}

/// Fills `out` for `lp` (see `Prepared`), with the emitter settings `r`.
/// The values are the same as the ones that `Emitter.layer` finds.
pub fn prepare(gpa: std.mem.Allocator, r: *const Resolved, lp: *const LayerPlan, out: *Prepared) std.mem.Allocator.Error!void {
    out.clear();
    try out.paths.ensureTotalCapacity(gpa, lp.paths.items.len);
    try out.lengths.resize(gpa, lp.points.points.items.len);
    var em: Emitter = .{ .gpa = gpa, .w = undefined, .r = r, .lr = lp.resolved orelse r };
    em.setOutline(lp);
    const p = em.lr.settings.project;
    if (p.combing and !lp.outline.isEmpty()) {
        if (out.arena == null) out.arena = .init(gpa);
        out.index = try CombIndex.init(out.arena.?.allocator(), lp.outline);
        em.comb_index = &out.index.?;
    }
    // The nozzle position, as `layer` moves it. It is not known before
    // the first path.
    var known = false;
    for (lp.paths.items, 0..) |path, i| {
        const pts = lp.points.get(i);
        var t: Prepared.PathPrep = .{ .from = .{ em.x, em.y } };
        if (pts.len == 0) {
            out.paths.appendAssumeCapacity(t);
            continue;
        }
        const x = geom.toMm(pts[0].x);
        const y = geom.toMm(pts[0].y);
        if (known) {
            const d = @import("geom.zig").hypot(x - em.x, y - em.y);
            if (d >= 1e-4 and d > p.retract_min_travel) {
                var way: [max_way][2]f64 = undefined;
                if (em.findWay(x, y, d, &way)) |n| {
                    t.start = @intCast(out.way_points.items.len);
                    t.n = @intCast(n);
                    try out.way_points.appendSlice(gpa, way[0..n]);
                } else t.n = Prepared.PathPrep.retract;
            }
        }
        known = true;
        // The extrusion moves start at the first point. They skip the
        // points nearer than 1e-4 mm, as in `extrude`.
        const base: usize = if (i == 0) 0 else lp.points.ends.items[i - 1];
        const lengths = out.lengths.items[base..][0..pts.len];
        lengths[0] = 0;
        em.x = x;
        em.y = y;
        for (pts[1..], lengths[1..]) |q, *l| l.* = em.stepTo(geom.toMm(q.x), geom.toMm(q.y));
        if (path.closed and pts.len > 2) t.close = em.stepTo(x, y);
        out.paths.appendAssumeCapacity(t);
        out.end = .{ em.x, em.y };
        out.end_feature = path.feature;
    }
    // Room for the way of the first travel, which the dry run adds.
    try out.way_points.ensureUnusedCapacity(gpa, max_way);
}

pub const Error = Writer.Error || std.mem.Allocator.Error;

/// The prime tower of a print with tool changes (Project.prime_tower): a
/// square of `size` mm at (x, y) on the bed. Each change purges into it
/// in rows of lines; each layer up to `last_layer` that has no change
/// prints a light layer of it (its loop and a diagonal), so the tower
/// grows with the print and the purge of a later layer has a base.
pub const Tower = struct {
    x: f64,
    y: f64,
    size: f64,
    last_layer: usize,
    /// The family of its materials (see filaments.family), for the view.
    family: [8]u8 = .{0} ** 8,
    /// The number of layers with a purge into it (a tower of `Towers`
    /// with stacked layers).
    purges: usize = 0,
    /// Its depth in y (mm): `size`, or more for the rows that the most
    /// purge of one layer needs (see PlateJob.towers). 0: `size`.
    depth: f64 = 0,

    pub fn ySize(t: Tower) f64 {
        return if (t.depth > t.size) t.depth else t.size;
    }
};

/// The prime towers of a print: one, or one for each family of materials
/// (Project.prime_tower_split), and the tower of each filament slot.
pub const Towers = struct {
    pub const max = 4;
    list: [max]Tower = undefined,
    n: usize = 0,
    /// The tower of each slot (index in `list`).
    of_slot: [filaments.max_slots]u8 = .{0} ** filaments.max_slots,
    /// Each tower grows only on the layers with a purge into it, and the
    /// nozzle goes down to its top: more than one tower, or a filament
    /// for the support (its changes are known only as the G-code is
    /// written, so a tower with light layers cannot know its last layer).
    stack: bool = false,
    pub fn stacked(t: *const Towers) bool {
        return t.stack or t.n > 1;
    }

    pub fn items(t: *const Towers) []const Tower {
        return t.list[0..t.n];
    }
};

/// The most rows of a tower on one layer.
pub const max_tower_rows = 512;

/// The prime volume (mm³) of a change into the tower when the change
/// G-code of the machine flushes into a chute (Bambu Lab).
pub const tower_prime_mm3 = 15;

/// The least flush (mm³) of a change after the hidden lines take their
/// part (see `Emitter.hiddenRun`): the prime of the tower of a Bambu Lab
/// printer, so the nozzle is full before the first hidden line. A change
/// whose flush is less than this keeps its flush.
pub const min_flush_mm3 = tower_prime_mm3;

/// The slot of the filament of the last path of a layer plan, with the
/// settings `r` of the print and the filaments `slots` of the plate.
pub fn endTool(lp: *const LayerPlan, r: *const Resolved, slots: []const settings_mod.Filament) u32 {
    if (slots.len < 2) return 0;
    var i = lp.paths.items.len;
    while (i > 0) {
        i -= 1;
        if (lp.points.get(i).len == 0) continue;
        const path = lp.paths.items[i];
        const pr = lp.pathResolved(path) orelse lp.resolved orelse r;
        return filaments.pathSlot(path.feature, pr.settings.project, slots.len);
    }
    return 0;
}

/// The emitter state that a layer run reads from the layer before it.
/// A planning thread runs a layer early from a guess of this state (see
/// engine.zig). The link pass then compares the guess with the real state.
pub const Entry = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    feature: ?Feature = null,
    extruded: bool = false,
    /// The slot of the filament in the nozzle (see `Emitter.tool`).
    tool: u32 = 0,
};

/// The emitter state after an early run of a layer, for the layer after
/// it. `retract_len`, `hop_len`, and `accel` are `unset` if the layer did
/// not set them.
pub const Exit = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    nozzle_z: ?f64 = null,
    retracted: bool = false,
    retract_len: f64 = 0,
    hopped: bool = false,
    hop_len: f64 = 0,
    nozzle_temp: ?f64 = null,
    bed_temp: ?f64 = null,
    extruded: bool = false,
    feature: ?Feature = null,
    accel: f64 = 0,
    stop: bool = true,
    feed: f64 = -1,
    width: f64 = 0.4,
    layer_start: bool = false,
    lr: ?*const Resolved = null,
    retractions: u32 = 0,
    tool: u32 = 0,

    pub const unset: f64 = -1;
};

/// What an early run of a layer keeps for the link pass (see `link`).
/// The print time, the filament length, and the travel length are float
/// sums over all moves of the print. The link pass adds the terms of
/// each layer in the order of the emitter, so the sums are the same bit
/// for bit.
pub const Terms = struct {
    /// Each term of the print time. The first `probe` terms are from the
    /// first pass of the layer (retractions and Z moves, at full speed).
    time: std.ArrayList(f64) = .empty,
    probe: usize = 0,
    filament: std.ArrayList(f64) = .empty,
    travel: std.ArrayList(f64) = .empty,
    /// The planned time of the moves at full speed.
    full_time: f64 = 0,
    /// The layer was shorter than `min_layer_time`.
    short: bool = false,
    /// The speed search compared planned times with the time it wants.
    /// `below` is the largest time that was less, and `above` the smallest
    /// time that was not. Each wanted time between them gives the same
    /// speed ratio.
    below: f64 = -std.math.inf(f64),
    above: f64 = std.math.inf(f64),
    /// A path rule ran. A rule can read the fan, and the fan depends on
    /// the exact time of the layers before.
    rules: bool = false,

    pub fn clear(g: *Terms) void {
        g.time.clearRetainingCapacity();
        g.filament.clearRetainingCapacity();
        g.travel.clearRetainingCapacity();
        g.* = .{ .time = g.time, .filament = g.filament, .travel = g.travel };
    }

    pub fn deinit(g: *Terms, gpa: std.mem.Allocator) void {
        g.time.deinit(gpa);
        g.filament.deinit(gpa);
        g.travel.deinit(gpa);
    }
};

pub const Emitter = struct {
    /// The memory of the move list of a layer.
    gpa: std.mem.Allocator,
    /// The first pass of `layer`: each move goes into this list, and its
    /// time comes later from the planner.
    collect: ?*std.ArrayList(motion.Move) = null,
    /// A run of a layer from a stream needed the outline (see
    /// Prepared.replay). The result of the run is not valid: the caller
    /// plans the layer and runs it again.
    need_plan: bool = false,
    /// If set, the run keeps the terms of its sums here (see `Terms`).
    terms: ?*Terms = null,
    /// The second pass: the planned moves of the layer, and the next one.
    planned: []const motion.Move = &.{},
    next_move: usize = 0,
    /// The next move starts at rest (after a retraction or a Z move).
    stop: bool = true,
    /// A dry run keeps the combing ways that it finds in `prep`. The first
    /// pass of the text of a layer does not.
    keep_ways: bool = true,
    /// If set, `layer` puts one PathInfo for each path here. The caller
    /// reserves the space (one item for each path) before `layer`.
    record: ?*std.ArrayList(PathInfo) = null,
    w: *Writer,
    /// The settings of the print.
    r: *const Resolved,
    /// The settings of the layer that `layer` writes, with its overrides.
    /// The flow, the cooling, the retraction, the z hop, and the combing
    /// come from it.
    lr: *const Resolved,
    x: f64 = 0,
    y: f64 = 0,
    /// The z of the layer.
    z: f64 = 0,
    /// The z of the nozzle in a path that is not planar, or null at the
    /// z of the layer.
    nozzle_z: ?f64 = null,
    retracted: bool = false,
    /// The length of the last retraction. The push back after it uses the
    /// same length, also if the next layer has another one.
    retract_len: f64 = 0,
    /// The nozzle is up by `hop_len` after a retraction.
    hopped: bool = false,
    hop_len: f64 = 0,
    /// The last nozzle and bed temperatures, or null before the first
    /// layer (the start G-code sets them).
    nozzle_temp: ?f64 = null,
    bed_temp: ?f64 = null,
    /// The next travel is the first of the layer: after the layer change,
    /// which lifts the nozzle, so it has no z hop.
    layer_start: bool = false,
    /// The outline of the layer that `layer` writes, its line width, and
    /// the boxes of its polygons (for combing).
    outline: ?*const geom.Paths = null,
    width: f64 = 0.4,
    boxes: [256][4]i64 = undefined,
    n_boxes: usize = 0,
    /// The prepared work of the layer (see `Prepared`), or null. In a dry
    /// run, `layer` adds the way of the first travel.
    prep: ?*Prepared = null,
    /// The path that `layer` writes.
    path_index: usize = 0,
    /// The G-code has the blocks of Bambu Studio (see bambuBlocks): the
    /// end closes its executable block.
    bambu_blocks: bool = false,
    /// The combing index of the layer, or null.
    comb_index: ?*const CombIndex = null,
    /// The travel acceleration of the layer, for the time of a combing
    /// way (see `walkTooLong`).
    travel_accel: f64 = 0,
    /// True after the first extrusion. Before it, a retraction has no use.
    extruded: bool = false,
    /// The last fan value written (0 to 255), or -1 before the first.
    fan: i32 = -1,
    /// The fan of the layer (coolingFan), for after a bridge, or -1.
    layer_fan: i32 = -1,
    /// The path rules (project.path_rules), parsed once for each text:
    /// the text they come from, and their trees in `rules_buf`.
    rules_text: []const u8 = "",
    rules: [max_rules]Rule = undefined,
    rules_n: usize = 0,
    rules_buf: [16 * 1024]u8 = undefined,
    /// The last feed rate written, in mm/min.
    feed: f64 = -1,
    feature: ?Feature = null,
    stats: Stats = .{},
    /// A dry run: the emitter changes its state and its statistics as
    /// usual, and does not format the moves. With a writer that discards
    /// all text, a dry run finds the state at the start of each layer
    /// quickly. Then a copy of the emitter with that state can write the
    /// text of the layer on another thread (see engine.zig).
    dry: bool = false,
    /// The acceleration now (mm/s²).
    accel: f64 = 0,
    /// The box of the first layer in G-code coordinates, for the
    /// variables of the start G-code (first_layer_print_min), or null.
    first_layer_box: ?[4]f64 = null,
    layer_count: usize = 0,
    /// The filaments of the plate: slot k is `slots[k]`, and slot 0 is the
    /// filament of the settings. Empty or one: the print has one
    /// filament, and the emitter makes no change.
    slots: []const settings_mod.Filament = &.{},
    /// The slot of the filament in the nozzle, from 0. The start G-code
    /// loads slot 0.
    tool: u32 = 0,
    /// The layer that `layer` writes, for the change G-code.
    layer_index: usize = 0,
    /// The prime towers (see `Towers`), none for no tower.
    towers: Towers = .{},
    /// For each tower: the layer whose rows `tower_rows` counts, the z of
    /// its top and of the layer it prints now, and its layer count.
    tower_layer: [Towers.max]usize = .{std.math.maxInt(usize)} ** Towers.max,
    tower_rows: [Towers.max]u32 = .{0} ** Towers.max,
    tower_top: [Towers.max]f64 = .{0} ** Towers.max,
    tower_z: [Towers.max]f64 = .{0} ** Towers.max,
    tower_count: [Towers.max]usize = .{0} ** Towers.max,
    /// The height and the line width of the layer that `paths` writes.
    layer_h: f64 = 0.2,
    layer_w: f64 = 0.4,

    const max_rules = 16;
    const Rule = struct { target: enum { speed, flow, fan }, node: *const expr.Node };

    /// The variables of a path for its rules.
    const RuleEnv = struct {
        feature: []const u8,
        layer: f64,
        z: f64,
        part: f64,
        speed: f64,
        width: f64,
        height: f64,
        length: f64,
        fan: f64,

        fn lookup(ctx: ?*const anyopaque, name: []const u8) ?expr.Value {
            const v: *const RuleEnv = @ptrCast(@alignCast(ctx.?));
            const eq = std.mem.eql;
            if (eq(u8, name, "feature")) return .{ .text = v.feature };
            inline for (.{ "layer", "z", "part", "speed", "width", "height", "length", "fan" }) |f| {
                if (eq(u8, name, f)) return .{ .num = @field(v, f) };
            }
            return null;
        }
    };

    /// The speed, the flow factor, and the fan (or null) of a path after
    /// the path rules `text` (see Project.path_rules).
    fn applyRules(self: *Emitter, text: []const u8, path: layer_mod.Path, pts: []const geom.Point, lp: *const LayerPlan, speed: f64, width: f64, height: f64) struct { speed: f64, flow: f64 = 1, fan: ?f64 = null } {
        if (text.len == 0) return .{ .speed = speed };
        if (text.ptr != self.rules_text.ptr or text.len != self.rules_text.len) {
            self.rules_text = text;
            self.rules_n = 0;
            var fba = std.heap.FixedBufferAllocator.init(&self.rules_buf);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                if (self.rules_n == max_rules) break;
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const eqi = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const name = std.mem.trim(u8, line[0..eqi], " ");
                const target = std.meta.stringToEnum(@FieldType(Rule, "target"), name) orelse continue;
                var diag: expr.Diagnostic = .{};
                const node = expr.parse(fba.allocator(), std.mem.trim(u8, line[eqi + 1 ..], " "), &diag) catch continue;
                self.rules[self.rules_n] = .{ .target = target, .node = node };
                self.rules_n += 1;
            }
        }
        if (self.rules_n == 0) return .{ .speed = speed };
        if (self.terms) |g| g.rules = true;
        var len: f64 = 0;
        for (1..pts.len) |k| len += geom.toMm(@intFromFloat(pts[k - 1].dist(pts[k])));
        var env: RuleEnv = .{
            .feature = @tagName(path.feature),
            .layer = @floatFromInt(lp.index),
            .z = lp.z,
            .part = @floatFromInt(lp.partOf(path)),
            .speed = speed,
            .width = width,
            .height = height,
            .length = len,
            .fan = @as(f64, @floatFromInt(@max(self.fan, 0))) / 255,
        };
        var out: @TypeOf(self.applyRules(text, path, pts, lp, speed, width, height)) = .{ .speed = speed };
        for (self.rules[0..self.rules_n]) |rule| {
            const v = expr.eval(rule.node, .{ .ctx = &env, .lookup = RuleEnv.lookup }) catch continue;
            const n = switch (v) {
                .num => |x| x,
                .text => continue,
            };
            if (!std.math.isFinite(n)) continue;
            switch (rule.target) {
                .speed => {
                    out.speed = @max(n, 1);
                    env.speed = out.speed;
                },
                .flow => out.flow = @max(n, 0),
                .fan => {
                    out.fan = n;
                    env.fan = n;
                },
            }
        }
        return out;
    }

    /// The state that the run of the next layer reads (see `Entry`).
    pub fn entry(self: *const Emitter) Entry {
        return .{ .x = self.x, .y = self.y, .z = self.z, .feature = self.feature, .extruded = self.extruded, .tool = self.tool };
    }

    /// True if the emitter is in the state `e`, with the filament not
    /// retracted and the nozzle at the z of the layer.
    pub fn at(self: *const Emitter, e: Entry) bool {
        return self.x == e.x and self.y == e.y and self.z == e.z and self.feature == e.feature and
            self.extruded == e.extruded and self.tool == e.tool and !self.retracted and !self.hopped and self.nozzle_z == null;
    }

    /// Puts the emitter in the state `e` for an early run of a layer. The
    /// values that the layer sets before it reads them are `Exit.unset`.
    pub fn setEntry(self: *Emitter, e: Entry) void {
        self.x = e.x;
        self.y = e.y;
        self.z = e.z;
        self.feature = e.feature;
        self.extruded = e.extruded;
        self.tool = e.tool;
        self.retracted = false;
        self.hopped = false;
        self.nozzle_z = null;
        self.retract_len = Exit.unset;
        self.hop_len = Exit.unset;
        self.accel = Exit.unset;
        self.stats = .{};
    }

    pub fn exit(self: *const Emitter) Exit {
        return .{
            .x = self.x,
            .y = self.y,
            .z = self.z,
            .nozzle_z = self.nozzle_z,
            .retracted = self.retracted,
            .retract_len = self.retract_len,
            .hopped = self.hopped,
            .hop_len = self.hop_len,
            .nozzle_temp = self.nozzle_temp,
            .bed_temp = self.bed_temp,
            .extruded = self.extruded,
            .feature = self.feature,
            .accel = self.accel,
            .stop = self.stop,
            .feed = self.feed,
            .width = self.width,
            .layer_start = self.layer_start,
            .lr = self.lr,
            .retractions = self.stats.retractions,
            .tool = self.tool,
        };
    }

    /// The link pass of a layer: joins an early run of `lp` (its exit
    /// state `x`, its terms `g`, and its plan in `pr`) to the real state
    /// at the start of the layer. The caller checked `at` with the entry
    /// state of the run. On success, the emitter is in the state after the
    /// layer, as after `layer` in a dry run, and `pr` has the exact layer
    /// time for the text. False: the exact times give another result than
    /// the run found, and the emitter did not change. Then the caller
    /// runs `layer`.
    pub fn link(self: *Emitter, lp: *const LayerPlan, x: *const Exit, g: *const Terms, pr: *Prepared) bool {
        if (g.rules) return false;
        // The terms have no slot of each filament length: a print of many
        // filaments runs each layer.
        if (self.slots.len > 1) return false;
        const lr = lp.resolved orelse self.r;
        const f = lr.settings.filament;
        // The time of the retractions and the Z moves is a difference of
        // two sums that start at the time of the print.
        var t = self.stats.print_time_s;
        for (g.time.items[0..g.probe]) |v| t += v;
        const fixed = t - self.stats.print_time_s;
        const layer_time = fixed + g.full_time;
        const short = layer_time < f.min_layer_time;
        if (short != g.short) return false;
        if (short) {
            // The cooling lap moves the nozzle for a time that comes from
            // the exact layer time.
            if (f.cooling_mode == .lap) return false;
            const want = f.min_layer_time - fixed;
            if (!(g.below < want and want <= g.above)) return false;
        }
        pr.plan_time = layer_time;
        const st = &self.stats;
        for (g.time.items[g.probe..]) |v| st.print_time_s += v;
        for (g.filament.items) |v| st.filament_mm += v;
        for (g.travel.items) |v| st.travel_mm += v;
        st.retractions += x.retractions;
        st.layer_count += 1;
        self.lr = x.lr.?;
        self.x = x.x;
        self.y = x.y;
        self.z = x.z;
        self.nozzle_z = x.nozzle_z;
        self.retracted = x.retracted;
        if (x.retract_len != Exit.unset) self.retract_len = x.retract_len;
        self.hopped = x.hopped;
        if (x.hop_len != Exit.unset) self.hop_len = x.hop_len;
        self.nozzle_temp = x.nozzle_temp;
        self.bed_temp = x.bed_temp;
        self.extruded = x.extruded;
        self.feature = x.feature;
        if (x.accel != Exit.unset) self.accel = x.accel;
        self.stop = x.stop;
        self.feed = x.feed;
        self.width = x.width;
        self.layer_start = x.layer_start;
        // The fan of the layer, as `coolingFan` sets it.
        self.layer_fan = @intFromFloat(@round(255 * layerFan(self.r.settings.filament, f, lp.index, layer_time)));
        self.fan = self.layer_fan;
        return true;
    }

    /// The G-code of the maker of a Bambu Lab printer in its newest form:
    /// a profile keeps a copy of the start, the end, and the change G-code
    /// of the library at the time it was saved, and the firmware wants the
    /// one of the current Bambu Studio (an X2D cancelled a print with the
    /// older start G-code). The text of the profile, if the user wrote it
    /// (it lacks the banner line of the maker's text), stays.
    fn makerTemplate(model: []const u8, text: []const u8, which: enum { start, end, change }) []const u8 {
        const printers = @import("printers.zig");
        const now = switch (which) {
            .start => printers.bambuTemplate(model, .start),
            .end => printers.bambuTemplate(model, .end),
            .change => printers.changeGcode(model),
        } orelse return text;
        // The banner: the first line that starts with ";=====".
        var it = std.mem.splitScalar(u8, now, '\n');
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \r");
            if (!std.mem.startsWith(u8, l, ";=====")) continue;
            return if (std.mem.indexOf(u8, text, l) != null) now else text;
        }
        return text;
    }

    const blank16 = "0" ++ " " ** 15;
    /// The progress line of a layer before finishBambuProgress: "M73 P0 R0"
    /// and spaces, 20 characters.
    pub const progress_blank = "M73 P0 R0" ++ " " ** 11;

    /// Fills in the progress line of each layer of a Bambu Lab G-code (see
    /// bambuLayer): "M73 P<percent> R<minutes left>", from the start time
    /// of each layer (s) and the print time. In place, in the order of the
    /// layers; a text with fewer lines keeps the rest.
    pub fn finishBambuProgress(text: []u8, layer_start: []const f64, total: f64) void {
        if (!std.mem.startsWith(u8, text, "; HEADER_BLOCK_START\n")) return;
        const key = "\n" ++ progress_blank ++ "\n";
        var pos: usize = 0;
        for (layer_start) |t| {
            const found = std.mem.indexOfPos(u8, text, pos, key) orelse return;
            const field = text[found + 1 ..][0..progress_blank.len];
            const done = if (total > 0) std.math.clamp(t / total, 0, 1) else 0;
            const pct: u32 = @intFromFloat(@floor(done * 100));
            const left: u64 = @intFromFloat(@ceil(@max(0, @min(total - t, 1e9)) / 60));
            @memset(field, ' ');
            _ = std.fmt.bufPrint(field, "M73 P{d} R{d}", .{ pct, left }) catch {};
            pos = found + key.len - 1;
        }
    }
    const blank64 = "0" ++ " " ** 63;

    /// Fills in the fields of the header block of a Bambu Lab G-code (see
    /// bambuBlocks) with the stats of the print: the print time, the
    /// filament of each slot, and the top z. In place: each field keeps its
    /// width, with spaces after the value. A text with no header block
    /// stays.
    pub fn finishBambuHeader(text: []u8, st: Stats, slots: usize, filament_area: f64, max_z: f64) void {
        if (!std.mem.startsWith(u8, text, "; HEADER_BLOCK_START\n")) return;
        const head_end = std.mem.indexOf(u8, text, "; HEADER_BLOCK_END") orelse return;
        const head = text[0..head_end];
        const put = struct {
            fn f(h: []u8, key: []const u8, comptime width: usize, comptime fmt: []const u8, args: anytype) void {
                const pos = std.mem.indexOf(u8, h, key) orelse return;
                const field = h[pos + key.len ..][0..width];
                @memset(field, ' ');
                _ = std.fmt.bufPrint(field, fmt, args) catch {};
            }
        }.f;
        var tbuf: [16]u8 = undefined;
        const t = clockText(&tbuf, st.print_time_s);
        put(head, "; model printing time: ", 16, "{s}", .{t});
        put(head, "; total estimated time: ", 16, "{s}", .{t});
        put(head, "; max_z_height: ", 16, "{d:.2}", .{max_z});
        const n = @max(@min(slots, filaments.max_slots), 1);
        var lb: [64]u8 = undefined;
        var vb: [64]u8 = undefined;
        var wb: [64]u8 = undefined;
        var lw: Writer = .fixed(&lb);
        var vw: Writer = .fixed(&vb);
        var ww: Writer = .fixed(&wb);
        for (0..n) |k| {
            const mm = if (slots < 2) st.filament_mm else st.slot_mm[k];
            const g = if (slots < 2) st.filament_g else st.slot_g[k];
            const sep = if (k > 0) "," else "";
            lw.print("{s}{d:.2}", .{ sep, mm }) catch {};
            vw.print("{s}{d:.2}", .{ sep, mm * filament_area / 1000 }) catch {};
            ww.print("{s}{d:.2}", .{ sep, g }) catch {};
        }
        put(head, "; total filament length [mm] : ", 64, "{s}", .{lw.buffered()});
        put(head, "; total filament volume [cm^3] : ", 64, "{s}", .{vw.buffered()});
        put(head, "; total filament weight [g] : ", 64, "{s}", .{ww.buffered()});
    }

    /// "1h 12m 43s", as Bambu Studio writes a time.
    fn clockText(buf: []u8, seconds: f64) []const u8 {
        // An infinite time does not fit a u64: up to 1e12 s.
        const s: u64 = @intFromFloat(@min(@max(0, @round(seconds)), 1e12));
        const h = s / 3600;
        const m = (s % 3600) / 60;
        const sec = s % 60;
        return (if (h > 0) std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ h, m, sec }) else if (m > 0) std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, sec }) else std.fmt.bufPrint(buf, "{d}s", .{sec})) catch "0s";
    }

    /// For a Bambu Lab printer: the header block and the config block of
    /// Bambu Studio at the top of the G-code. Its firmware reads them, and
    /// it compares the hotends of the config block with its own (a print
    /// stopped with "the hotend quantity or model does not match the
    /// sliced file" when they were missing). The values are those of
    /// Metadata/project_settings.config (see bambu.zig).
    fn bambuBlocks(self: *Emitter, layer_count: usize) Writer.Error!void {
        const s = self.r.settings;
        const m = s.machine;
        const b = @import("printers.zig").bambu(m.model) orelse return;
        const w = self.w;
        self.bambu_blocks = true;
        const n: u32 = @max(b.nozzles, m.nozzles);
        const fils: []const settings_mod.Filament = if (self.slots.len > 0) self.slots else &.{s.filament};
        const list = struct {
            fn f(out: *Writer, key: []const u8, count: u32, text: []const u8) Writer.Error!void {
                try out.print("; {s} = ", .{key});
                for (0..count) |k| try out.print("{s}{s}", .{ if (k > 0) "," else "", text });
                try out.writeByte('\n');
            }
        }.f;
        try w.writeAll("; HEADER_BLOCK_START\n; zslice\n");
        // The times and the filament of the print come after the slice: a
        // field of fixed width here, that finishBambuHeader fills in.
        try w.writeAll("; model printing time: " ++ blank16 ++ "; total estimated time: " ++ blank16 ++ "\n");
        try w.print("; total layer number: {d}\n", .{layer_count});
        try w.writeAll("; total filament length [mm] : " ++ blank64 ++ "\n");
        try w.writeAll("; total filament volume [cm^3] : " ++ blank64 ++ "\n");
        try w.writeAll("; total filament weight [g] : " ++ blank64 ++ "\n");
        try w.writeAll("; max_z_height: " ++ blank16 ++ "\n");
        try w.writeAll("; filament_diameter: ");
        for (fils, 0..) |f, k| try w.print("{s}{d}", .{ if (k > 0) "," else "", f.diameter });
        try w.writeAll("\n; filament_density: ");
        for (fils, 0..) |f, k| try w.print("{s}{d}", .{ if (k > 0) "," else "", f.density });
        try w.writeAll("\n; filament: ");
        for (fils, 0..) |_, k| try w.print("{s}{d}", .{ if (k > 0) "," else "", k + 1 });
        try w.writeAll("\n; HEADER_BLOCK_END\n\n; CONFIG_BLOCK_START\n");
        // zslice's keys go to a buffer; then the config block of a Bambu
        // Studio file of this model (printers.bambuConfig) goes out in its
        // order, with zslice's value for each key that zslice has, and the
        // keys of zslice that it lacks after it.
        var ours: Writer.Allocating = .init(self.gpa);
        defer ours.deinit();
        const cw = &ours.writer;
        // The keys of the extruders and the hotends of a Bambu Studio file
        // (02.09, the X2D): one value for each extruder, then one for each
        // filament. No nozzle_type: Studio writes none.
        const vol = if (m.nozzle_flow == .high_flow) "High Flow" else "Standard";
        var types: [2][]const u8 = .{ "Direct Drive", "Direct Drive" };
        {
            var it = std.mem.splitScalar(u8, b.types, ';');
            var k: usize = 0;
            while (it.next()) |t| : (k += 1) if (k < 2) {
                types[k] = t;
            };
        }
        var dbuf: [32]u8 = undefined;
        const dia = std.fmt.bufPrint(&dbuf, "{d}", .{m.nozzle_diameter}) catch "0.4";
        try cw.print("; curr_bed_type = {s}\n", .{m.bed_type.studioName()});
        try cw.writeAll("; default_nozzle_volume_type = ");
        {
            var it = std.mem.splitScalar(u8, b.volumes, ';');
            var k: usize = 0;
            while (it.next()) |t| : (k += 1) try cw.print("{s}{s}", .{ if (k > 0) "," else "", t });
        }
        try cw.writeByte('\n');
        try list(cw, "extruder_max_nozzle_count", n, "1");
        try list(cw, "extruder_nozzle_count", n, "1");
        try list(cw, "extruder_nozzle_diameter", n, dia);
        try cw.writeAll("; extruder_nozzle_slot = ");
        for (0..n) |k| try cw.print("{s}{d}", .{ if (k > 0) "," else "", k });
        try cw.writeAll("\n; extruder_nozzle_stats = ");
        for (0..n) |k| try cw.print("{s}{s}#1", .{ if (k > 0) ";" else "", vol });
        try cw.writeAll("\n; extruder_nozzle_stats_new = ");
        for (0..n) |k| try cw.print("{s}{s}#1", .{ if (k > 0) ";" else "", vol });
        try cw.writeByte('\n');
        try list(cw, "extruder_nozzle_volume_type", n, vol);
        try list(cw, "extruder_offset", n, "0x0");
        try cw.writeAll("; extruder_type = ");
        for (0..n) |k| try cw.print("{s}{s}", .{ if (k > 0) "," else "", types[@min(k, 1)] });
        try cw.writeByte('\n');
        if (b.variants.len > 0) {
            try cw.writeAll("; extruder_variant_list = ");
            var it = std.mem.splitScalar(u8, b.variants, '|');
            var k: usize = 0;
            while (it.next()) |t| : (k += 1) try cw.print("{s}\"{s}\"", .{ if (k > 0) ";" else "", t });
            try cw.writeByte('\n');
        }
        // Each filament: the variant of its extruder, its extruder (from
        // 1), and its nozzle (from 0).
        try cw.writeAll("; filament_extruder_variant = ");
        for (fils, 0..) |f, k| try cw.print("{s}\"{s} {s}\"", .{ if (k > 0) ";" else "", types[if (n >= 2) @min(f.nozzle, 1) else 0], vol });
        try cw.writeAll("\n; filament_map = ");
        for (fils, 0..) |f, k| try cw.print("{s}{d}", .{ if (k > 0) "," else "", if (n >= 2) @as(u32, @min(f.nozzle, 1)) + 1 else 1 });
        try cw.writeAll("\n; filament_nozzle_map = ");
        for (fils, 0..) |f, k| try cw.print("{s}{d}", .{ if (k > 0) "," else "", if (n >= 2) @as(u32, @min(f.nozzle, 1)) else 0 });
        try cw.writeAll("\n; filament_type = ");
        for (fils, 0..) |f, k| try cw.print("{s}{f}", .{ if (k > 0) ";" else "", oneLine(f.material) });
        try cw.writeAll("\n; filament_colour = ");
        for (fils, 0..) |f, k| try cw.print("{s}{f}", .{ if (k > 0) ";" else "", oneLine(f.color) });
        try cw.writeAll("\n; handle_hotend_as_extruder = 0\n; has_filament_switcher = 0\n");
        try cw.print("; initial_layer_print_height = {d}\n; layer_height = {d}\n", .{ s.project.first_layer_height, s.project.layer_height });
        try cw.writeAll("; master_extruder_id = 1\n; multi_nozzle_diameter_mode = 0\n");
        try list(cw, "nozzle_diameter", n, dia);
        try list(cw, "nozzle_volume_type", n, vol);
        // Two extruders of one nozzle each (the X2D, the H2D): the firmware
        // numbers them the other way (the start G-code heats
        // T{filament_map % 2}). The H2C changes nozzles from a rack.
        if (n >= 2 and !std.mem.eql(u8, b.code, "O1C2")) try cw.writeAll("; physical_extruder_map = 1,0\n");
        for ([_][]const u8{ "print_extruder_id", "printer_extruder_id" }) |key| {
            try cw.print("; {s} = ", .{key});
            for (0..n) |k| try cw.print("{s}{d}", .{ if (k > 0) "," else "", k + 1 });
            try cw.writeByte('\n');
        }
        for ([_][]const u8{ "print_extruder_variant", "printer_extruder_variant" }) |key| {
            try cw.print("; {s} = ", .{key});
            for (0..n) |k| try cw.print("{s}\"{s} {s}\"", .{ if (k > 0) ";" else "", types[@min(k, 1)], vol });
            try cw.writeByte('\n');
        }
        try cw.print("; printer_model = {s}\n; printer_settings_id = {s} {s} nozzle\n; printer_technology = FFF\n; printer_variant = {s}\n", .{ b.name, b.name, dia, dia });
        try cw.writeAll("; single_extruder_multi_material = 1\n");
        try mergeConfig(w, ours.written(), @import("printers.zig").bambuConfig(m.model) orelse "");
        try w.writeAll("; CONFIG_BLOCK_END\n\n");
    }

    /// Writes the config block lines of `base` ("; key = value" lines), with
    /// the line of `ours` for each key that `ours` has, then the lines of
    /// `ours` whose key `base` lacks.
    fn mergeConfig(w: *Writer, ours: []const u8, base: []const u8) Writer.Error!void {
        const keyOf = struct {
            fn f(line: []const u8) []const u8 {
                if (!std.mem.startsWith(u8, line, "; ")) return "";
                const eq = std.mem.indexOf(u8, line, " = ") orelse return "";
                return line[2..eq];
            }
        }.f;
        const find = struct {
            fn f(text: []const u8, key: []const u8) ?[]const u8 {
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |l| if (key.len > 0 and std.mem.eql(u8, keyOf(l), key)) return l;
                return null;
            }
        }.f;
        var it = std.mem.splitScalar(u8, base, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try w.writeAll(find(ours, keyOf(line)) orelse line);
            try w.writeByte('\n');
        }
        var oit = std.mem.splitScalar(u8, ours, '\n');
        while (oit.next()) |line| {
            if (line.len == 0) continue;
            if (base.len > 0 and find(base, keyOf(line)) != null) continue;
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }

    pub fn init(gpa: std.mem.Allocator, w: *Writer, r: *const Resolved) Emitter {
        return .{ .gpa = gpa, .w = w, .r = r, .lr = r };
    }

    pub fn begin(self: *Emitter, layer_count: usize) Writer.Error!void {
        const s = self.r.settings;
        const m = s.machine;
        self.layer_count = layer_count;
        // A Bambu Lab printer reads the header and the config block from
        // the first line of the file, as Bambu Studio writes them, then the
        // executable block (a file that started with ";FLAVOR" stopped with
        // "the hotend quantity or model does not match the sliced file").
        try self.bambuBlocks(layer_count);
        if (self.bambu_blocks) try self.w.writeAll("; EXECUTABLE_BLOCK_START\n");
        try self.w.print(";FLAVOR:{s}\n;Generated by zslice\n", .{switch (m.gcode_flavor) {
            .marlin, .klipper => "Marlin",
            .reprap => "RepRap",
            .repetier => "Repetier",
        }});
        try self.w.print(";MACHINE:{f}\n;FILAMENT:{f}\n", .{ oneLine(s.machine.name), oneLine(s.filament.name) });
        try self.w.print(";LAYER_COUNT:{d}\n", .{layer_count});
        // The start G-code goes into a buffer first: zslice heats before
        // it if it does not heat.
        var start: Writer.Allocating = .init(self.gpa);
        defer start.deinit();
        const got = try self.writeTemplate(&start.writer, makerTemplate(m.model, s.machine.start_gcode, .start), .start);
        const first = s.filament.first_layer_nozzle_temp;
        if (got.bed == null and !got.macro_bed) {
            try self.w.writeAll("M190 S");
            try writeNum(self.w, s.filament.firstBedTemp(), 0);
            try self.w.writeAll(" ; zslice: the start G-code does not heat the bed\n");
        }
        if (got.nozzle == null and !got.macro_nozzle) {
            try self.w.writeAll("M109 S");
            try writeNum(self.w, first, 0);
            try self.w.writeAll(" ; zslice: the start G-code does not heat the nozzle\n");
        }
        try self.w.writeAll(start.written());
        // The G-code of the filament, after the start G-code of the machine.
        if (s.filament.start_gcode.len > 0) {
            try self.w.writeAll("\n");
            _ = try self.writeTemplate(self.w, s.filament.start_gcode, .start);
        }
        // The end of the start G-code, as Bambu Studio writes it: the
        // marker, then the units, relative extrusion, and the spaghetti
        // detector on.
        if (self.bambu_blocks) try self.w.writeAll("\n; MACHINE_START_GCODE_END\nM400\nG90\nG21\nM83 ; use relative distances for extrusion\nM981 S1 P20000 ;open spaghetti detector\n");
        // A start G-code that leaves another temperature: the first layer
        // sets the right one and waits (see `layer`).
        if (got.nozzle) |t| if (!got.macro_nozzle) {
            self.nozzle_temp = t;
        };
        if (got.bed) |t| if (!got.macro_bed) {
            self.bed_temp = t;
        };
        try self.w.writeAll("\nM83 ; relative extrusion\n");
        try self.w.writeAll(self.fanOff());
        self.fan = 0;
        // The corner speed, once, with acceleration control.
        if (m.accel_control) switch (m.gcode_flavor) {
            .marlin => {
                try self.w.writeAll("M205 X");
                try writeNum(self.w, m.corner_speed, 2);
                try self.w.writeAll(" Y");
                try writeNum(self.w, m.corner_speed, 2);
                try self.w.writeAll(" ; corner speed (jerk)\n");
            },
            .klipper => {
                try self.w.writeAll("SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=");
                try writeNum(self.w, m.corner_speed, 2);
                try self.w.writeAll("\n");
            },
            .reprap => {
                // RepRapFirmware: the jerk in mm/min.
                try self.w.writeAll("M566 X");
                try writeNum(self.w, m.corner_speed * 60, 0);
                try self.w.writeAll(" Y");
                try writeNum(self.w, m.corner_speed * 60, 0);
                try self.w.writeAll(" ; corner speed (jerk)\n");
            },
            .repetier => {
                try self.w.writeAll("M207 X");
                try writeNum(self.w, m.corner_speed, 2);
                try self.w.writeAll(" ; corner speed (jerk)\n");
            },
        };
        try self.pressureAdvance(s.filament.pressure_advance);
    }

    /// The acceleration for the next moves. With acceleration control, a
    /// new value goes into the G-code (M204 S, or SET_VELOCITY_LIMIT ACCEL).
    fn setAccel(self: *Emitter, a: f64) Writer.Error!void {
        if (a == self.accel) return;
        self.accel = a;
        const m = self.r.settings.machine;
        if (!m.accel_control or self.dry) return;
        switch (m.gcode_flavor) {
            .marlin => try self.w.writeAll("M204 S"),
            .klipper => try self.w.writeAll("SET_VELOCITY_LIMIT ACCEL="),
            .reprap => {
                try self.w.writeAll("M204 P");
                try writeNum(self.w, a, 0);
                try self.w.writeAll(" T");
            },
            .repetier => {
                try self.w.writeAll("M201 X");
                try writeNum(self.w, a, 0);
                try self.w.writeAll(" Y");
            },
        }
        try writeNum(self.w, a, 0);
        try self.w.writeAll("\n");
    }

    /// The time of an XY move of length d at speed v: in the first pass,
    /// the move goes into the list; in the second pass, its planned time
    /// goes into the statistics.
    /// The limits of the axes of the machine, for the time estimate (the
    /// firmware applies them; the G-code keeps its speeds).
    fn axes(self: *const Emitter) motion.Axes {
        const m = self.r.settings.machine;
        return .{
            .corexy = m.kinematics == .corexy,
            // Klipper limits the head in all directions alike.
            .motors = m.gcode_flavor != .klipper,
            .accel = if (m.gcode_flavor == .klipper) .{ 0, 0 } else .{ m.max_accel_x, m.max_accel_y },
            .speed = if (m.gcode_flavor == .klipper) .{ 0, 0 } else .{ m.max_speed_x, m.max_speed_y },
        };
    }

    fn addMove(self: *Emitter, dx: f64, dy: f64, d: f64, v0: f64, e_ratio: f64) Error!void {
        const a0 = if (self.accel > 0) self.accel else self.r.settings.machine.max_accel;
        const va = self.axes().cap(dx / d, dy / d, v0, a0);
        const v = va[0];
        const a = va[1];
        if (self.collect) |list| {
            try list.append(self.gpa, .{ .dir = .{ dx / d, dy / d }, .len = d, .speed = v, .accel = a, .e_ratio = e_ratio, .stop_before = self.stop });
        } else if (self.next_move < self.planned.len) {
            try self.addTime(self.planned[self.next_move].time);
            self.next_move += 1;
        } else {
            try self.addTime(motion.restTime(d, v, a));
        }
        self.stop = false;
    }

    /// The planner limits of the machine. Klipper has a minimum cruise
    /// ratio of 0.5 and an extruder corner speed of 1 mm/s by default;
    /// Marlin has no cruise ratio and an extruder jerk of 5 mm/s.
    fn limits(self: *const Emitter) motion.Limits {
        const m = self.r.settings.machine;
        return switch (m.gcode_flavor) {
            .klipper => .{ .corner_speed = m.corner_speed, .min_cruise_ratio = 0.5, .extruder_corner_speed = 1 },
            .marlin, .reprap, .repetier => .{ .corner_speed = m.corner_speed, .min_cruise_ratio = 0, .extruder_corner_speed = 5 },
        };
    }

    /// The time of a retraction (or the push back after it), from rest to
    /// rest. The acceleration of the filament: Klipper limits it to the
    /// machine acceleration times 4 nozzle diameters squared over the
    /// filament area (its default `max_extrude_only_accel`); Marlin has the
    /// retract acceleration, about the machine acceleration.
    fn retractTime(self: *const Emitter, len: f64) f64 {
        const m = self.r.settings.machine;
        const ratio = switch (m.gcode_flavor) {
            .klipper => @min(1, 4 * m.nozzle_diameter * m.nozzle_diameter / self.r.filament_area),
            .marlin, .reprap, .repetier => 1,
        };
        return motion.restTime(len, m.retract_speed, m.max_accel * ratio);
    }

    /// A Z move from rest to rest.
    fn zMove(self: *Emitter, dz: f64) Error!void {
        const m = self.r.settings.machine;
        try self.addTime(motion.restTime(@abs(dz), m.max_z_speed, m.max_z_accel));
        self.stop = true;
    }

    /// Adds `t` to the print time. A run with `terms` also keeps `t`: the
    /// link pass adds the same terms in the same order (see `link`).
    fn addTime(self: *Emitter, t: f64) Error!void {
        self.stats.print_time_s += t;
        if (self.terms) |g| try g.time.append(self.gpa, t);
    }

    /// Adds `e` to the filament length (see `addTime`). The first pass of
    /// a layer keeps no term: its sums are not the sums of the print.
    fn addFilament(self: *Emitter, e: f64) Error!void {
        self.stats.filament_mm += e;
        self.stats.slot_mm[self.tool] += e;
        if (self.terms) |g| if (self.collect == null) try g.filament.append(self.gpa, e);
    }

    /// Adds `d` to the travel length (see `addFilament`).
    fn addTravel(self: *Emitter, d: f64) Error!void {
        self.stats.travel_mm += d;
        if (self.terms) |g| if (self.collect == null) try g.travel.append(self.gpa, d);
    }

    pub fn end(self: *Emitter) Error!void {
        try self.retract();
        const st = &self.stats;
        const r = self.r.settings.filament.diameter / 2;
        const volume_cm3 = st.filament_mm * std.math.pi * r * r / 1000.0;
        st.filament_g = volume_cm3 * self.r.settings.filament.density;
        if (self.slots.len > 1) {
            // Each slot has its own density.
            st.filament_g = 0;
            for (self.slots, 0..) |f, k| {
                if (k >= filaments.max_slots) break;
                const rk = f.diameter / 2;
                st.slot_g[k] = st.slot_mm[k] * std.math.pi * rk * rk / 1000.0 * f.density;
                st.filament_g += st.slot_g[k];
            }
        } else {
            // A layer that `link` reuses adds to filament_mm only.
            st.slot_mm[0] = st.filament_mm;
            st.slot_g[0] = st.filament_g;
        }
        // The end of the print, as Bambu Studio writes it before the end
        // G-code: the spaghetti detector off (the camera of the printer
        // also uses it as the end of the last layer), and the marker.
        if (self.bambu_blocks) try self.w.writeAll("M981 S0 P20000 ; close spaghetti detector\n; FEATURE: Custom\n; MACHINE_END_GCODE_START\n");
        // The G-code of the filament, before the end G-code of the machine.
        if (self.r.settings.filament.end_gcode.len > 0) {
            _ = try self.writeTemplate(self.w, self.r.settings.filament.end_gcode, .end);
            try self.w.writeAll("\n");
        }
        _ = try self.writeTemplate(self.w, makerTemplate(self.r.settings.machine.model, self.r.settings.machine.end_gcode, .end), .end);
        try self.w.writeAll("\n");
        try self.w.writeAll(";Filament used: ");
        try writeNum(self.w, st.filament_mm / 1000.0, 3);
        try self.w.writeAll("m\n;Filament weight: ");
        try writeNum(self.w, st.filament_g, 2);
        try self.w.writeAll("g\n;Estimated time: ");
        try writeNum(self.w, st.print_time_s, 0);
        try self.w.writeAll("s\n");
        try self.writeSettings();
        if (self.bambu_blocks) try self.w.writeAll("; EXECUTABLE_BLOCK_END\n");
    }

    /// The settings of the print that differ from the defaults, as
    /// comments at the end of the file: a print can be checked against
    /// its settings, and a profile can be made from them.
    fn writeSettings(self: *Emitter) Writer.Error!void {
        try self.w.writeAll(";zslice settings (the ones that differ from the defaults):\n");
        var buf: [16 * 1024]u8 = undefined;
        inline for (.{ .machine, .filament, .project }) |g| {
            var fw: std.Io.Writer = .fixed(&buf);
            // A full buffer cuts the list: the comments are only a record.
            @import("profile.zig").writeChanged(self.r.settings, g, &fw) catch {};
            var lines = std.mem.splitScalar(u8, fw.buffered(), '\n');
            // A text of more than one line (the start and the end G-code)
            // is in the file already, as G-code: it is left out.
            var in_text = false;
            while (lines.next()) |line| {
                if (in_text) {
                    if (std.mem.endsWith(u8, line, "\'\'\'")) in_text = false;
                    continue;
                }
                if (std.mem.indexOf(u8, line, "= \'\'\'")) |_| {
                    // Open until a line that ends it, unless it ends here.
                    in_text = std.mem.count(u8, line, "\'\'\'") == 1;
                    continue;
                }
                if (line.len == 0 or line[0] == '#') continue;
                try self.w.print(";  {s}.{s}\n", .{ @tagName(g), line });
            }
        }
    }

    pub fn layer(self: *Emitter, lp: *const LayerPlan) Error!void {
        self.lr = lp.resolved orelse self.r;
        const g = self.r.settings;
        const s = self.lr.settings;
        if (!self.dry) try self.w.print(";LAYER:{d}\n", .{lp.index});
        self.layer_index = lp.index;
        if (!self.dry) try self.bambuLayer(lp);
        // The temperatures: the start G-code sets the values of the first
        // layer. A layer with other values sets them, with no wait.
        const nozzle = self.toolTemp(lp.index == 0, s);
        // On the first layer, a value other than the one of the start
        // G-code waits (M109, M190): the print starts at its temperature.
        if (nozzle != (self.nozzle_temp orelse g.filament.first_layer_nozzle_temp)) {
            try self.w.writeAll(if (lp.index == 0) "M109 S" else "M104 S");
            try writeNum(self.w, nozzle, 0);
            try self.w.writeAll("\n");
        }
        self.nozzle_temp = nozzle;
        // The bed: the first layer temperature on layer 0, then the
        // temperature of each layer.
        const bed = if (lp.index == 0) s.filament.firstBedTemp() else s.filament.bed_temp;
        if (bed != (self.bed_temp orelse g.filament.firstBedTemp())) {
            try self.w.writeAll(if (lp.index == 0) "M190 S" else "M140 S");
            try writeNum(self.w, bed, 0);
            try self.w.writeAll("\n");
        }
        self.bed_temp = bed;
        // The text run of a layer takes the plan of its dry run (see
        // Prepared.plan_moves).
        if (!self.dry) if (self.prep) |pr| if (pr.have_plan) {
            const layer_time = pr.plan_time;
            try self.coolingFan(lp, layer_time);
            const lap = s.filament.cooling_mode == .lap;
            const short = layer_time < s.filament.min_layer_time;
            self.planned = pr.plan_moves.items;
            self.next_move = 0;
            defer self.planned = &.{};
            try self.paths(lp, pr.plan_slow, lap and short);
            std.debug.assert(self.next_move == pr.plan_moves.items.len);
            if (lap and lp.index >= g.filament.fan_off_layers and short) {
                try self.coolingLap(lp, s.filament.min_layer_time - layer_time);
            }
            return;
        };
        // The first pass: the moves of the layer at full speed, with no
        // text, on a copy of the emitter.
        // A dry run collects the moves in the list that the text run
        // reads (see Prepared.plan_moves): the list keeps its memory from
        // layer to layer, and the moves need no copy.
        var own_moves: std.ArrayList(motion.Move) = .empty;
        defer own_moves.deinit(self.gpa);
        const keep_plan: ?*Prepared = if (self.dry) self.prep else null;
        const moves: *std.ArrayList(motion.Move) = if (keep_plan) |pr| &pr.plan_moves else &own_moves;
        moves.clearRetainingCapacity();
        var discard: Writer.Discarding = .init(&.{});
        var probe = self.*;
        probe.w = &discard.writer;
        probe.dry = true;
        probe.record = null;
        probe.collect = moves;
        probe.keep_ways = self.dry;
        try probe.paths(lp, 1, false);
        if (probe.need_plan) self.need_plan = true;
        const lim = self.limits();
        const fixed = probe.stats.print_time_s - self.stats.print_time_s;
        const full_time = motion.plan(moves.items, lim);
        const layer_time = fixed + full_time;
        if (self.terms) |t| {
            t.probe = t.time.items.len;
            t.full_time = full_time;
            t.short = layer_time < s.filament.min_layer_time;
        }

        try self.coolingFan(lp, layer_time);
        var slow: f64 = 1;
        const lap = s.filament.cooling_mode == .lap;
        const short = layer_time < s.filament.min_layer_time;
        if (!lap and short) {
            // The extrusion moves get the speed of `paths` for a ratio:
            // a bisection finds the largest ratio that gives the layer
            // `min_layer_time`.
            const full = try self.gpa.alloc(f64, moves.items.len);
            defer self.gpa.free(full);
            var any = false;
            for (moves.items, full) |m, *f| {
                f.* = m.speed;
                if (m.e_ratio > 0) any = true;
            }
            if (any) {
                const time = struct {
                    fn at(ms: []motion.Move, fs: []const f64, k: f64, min_speed: f64, l: motion.Limits) f64 {
                        for (ms, fs) |*m, f| m.speed = if (m.e_ratio > 0) slowSpeed(f, k, min_speed) else f;
                        // The first plan of the layer set the corner limits.
                        return motion.planAgain(ms, l);
                    }
                }.at;
                const want = s.filament.min_layer_time - fixed;
                var lo: f64 = 0;
                var hi: f64 = 1;
                // The bounds of the wanted time that give the same result
                // (see Terms.below).
                var below = -std.math.inf(f64);
                var above = std.math.inf(f64);
                const t0 = time(moves.items, full, lo, s.filament.min_speed, lim);
                if (t0 >= want) {
                    above = t0;
                    for (0..24) |_| {
                        const mid = (lo + hi) / 2;
                        const t = time(moves.items, full, mid, s.filament.min_speed, lim);
                        if (t >= want) {
                            lo = mid;
                            above = geom.fmin(above, t);
                        } else {
                            hi = mid;
                            below = geom.fmax(below, t);
                        }
                    }
                } else below = t0;
                if (self.terms) |t| {
                    t.below = below;
                    t.above = above;
                }
                slow = lo;
                _ = time(moves.items, full, slow, s.filament.min_speed, lim);
            }
        }

        // The dry run keeps the plan for the text run.
        if (keep_plan) |pr| {
            pr.plan_slow = slow;
            pr.plan_time = layer_time;
            pr.have_plan = true;
        }
        // The second pass: the text, with the planned time of each move.
        self.planned = moves.items;
        self.next_move = 0;
        defer self.planned = &.{};
        try self.paths(lp, slow, lap and short);
        std.debug.assert(self.next_move == moves.items.len);
        if (lap and lp.index >= g.filament.fan_off_layers and short) {
            try self.coolingLap(lp, s.filament.min_layer_time - layer_time);
        }
    }

    /// The nozzle temperature of the filament in the nozzle: of the layer
    /// settings `s` for slot 0, else of its slot.
    fn toolTemp(self: *const Emitter, first: bool, s: settings_mod.Settings) f64 {
        if (self.tool == 0 or self.tool >= self.slots.len) {
            return if (first) self.r.settings.filament.first_layer_nozzle_temp else s.filament.nozzle_temp;
        }
        const f = self.slots[self.tool];
        return if (first) f.first_layer_nozzle_temp else f.nozzle_temp;
    }

    /// The slot of the filament of a path of `feature` with the settings
    /// `r` (the support filament for support).
    pub fn toolOf(self: *const Emitter, feature: settings_mod.Feature, r: *const Resolved) u32 {
        if (self.slots.len < 2) return 0;
        return filaments.pathSlot(feature, r.settings.project, self.slots.len);
    }

    /// A filament change to slot `next` before path `i` of `lp`, which
    /// starts at (x, y) mm. The text is the change G-code of the machine,
    /// or the command of the flavor (see filaments.zig). The change takes
    /// `change_time`, and a tool change flushes the old color out. The
    /// hidden lines from path `i` on (see `hiddenRun`) take a part of the
    /// flush, down to `min_flush_mm3`.
    fn changeTool(self: *Emitter, lp: *const LayerPlan, i: usize, next: u32, x: f64, y: f64, first: bool) Error!void {
        const g = self.r.settings;
        const m = g.machine;
        const from = self.slots[self.tool];
        const to = self.slots[next];
        try self.retractHop(false);
        self.stats.changes += 1;
        const full_mm3 = if (m.filament_change == .tool) filaments.flushVolume(from.color, to.color, m.flush_volume, g.project.flush_multiplier) else 0;
        const hidden_mm3 = if (full_mm3 > min_flush_mm3) @min(self.hiddenRun(lp, i, self.tool, next), full_mm3 - min_flush_mm3) else 0;
        const flush_mm3 = full_mm3 - hidden_mm3;
        const flush_mm = flush_mm3 / self.r.filament_area;
        self.stats.flush_hidden_mm += hidden_mm3 / self.r.filament_area;
        const old_temp = self.nozzle_temp orelse from.nozzle_temp;
        const new_temp = if (first) to.first_layer_nozzle_temp else to.nozzle_temp;
        if (!self.dry) {
            try self.w.print("; filament change {d}: filament {d} to filament {d}\n", .{ self.stats.changes, self.tool + 1, next + 1 });
            if (m.change_gcode.len > 0) {
                try self.writeChange(makerTemplate(m.model, m.change_gcode, .change), next, flush_mm, old_temp, new_temp, x, y);
            } else {
                switch (m.filament_change) {
                    .pause => try self.w.writeAll(if (m.gcode_flavor == .klipper) "PAUSE ; change the filament, then resume\n" else "M600 ; change the filament\n"),
                    .tool => try self.w.print("T{d}\n", .{next}),
                }
                if (new_temp != old_temp) {
                    try self.w.writeAll("M109 S");
                    try writeNum(self.w, new_temp, 0);
                    try self.w.writeAll("\n");
                }
            }
            // The change can move the nozzle up: back to the layer.
            try self.w.writeAll("G0 Z");
            try writeNum(self.w, self.z, 3);
            try self.w.writeAll("\n");
        }
        try self.addTime(m.change_time);
        self.stop = true;
        self.stats.flush_mm += flush_mm;
        // With a tower and no change G-code, the flush goes into the tower
        // (its lines count the filament); else into the chute.
        const into_tower = self.towers.n > 0 and m.filament_change == .tool and m.change_gcode.len == 0;
        if (!into_tower) {
            self.stats.filament_mm += flush_mm;
            self.stats.slot_mm[next] += flush_mm;
        }
        self.tool = next;
        self.nozzle_temp = new_temp;
        // The change loads the new filament to the nozzle tip.
        self.retracted = false;
        self.hopped = false;
        self.feed = -1;
        self.feature = null;
        self.accel = Exit.unset;
        self.fan = -1;
        if (self.towers.n > 0 and m.filament_change == .tool) {
            try self.towerPurge(self.towers.of_slot[@min(next, filaments.max_slots - 1)], if (into_tower) flush_mm3 else tower_prime_mm3, first);
        }
    }

    /// True if path `path` of slot `to` is a hidden line for the flush of
    /// a change from slot `from` (see Project.flush_into_hidden): the
    /// support body, or the sparse infill of a part with walls if the two
    /// filaments are of one family (see filaments.family). A path with
    /// path rules, or with a z or a width that changes along it, is not.
    fn hiddenFor(self: *const Emitter, lp: *const LayerPlan, path: layer_mod.Path, from: u32, to: u32) bool {
        const g = self.r.settings;
        if (!g.project.flush_into_hidden or g.machine.filament_change != .tool) return false;
        if (path.z_start != layer_mod.Path.planar or path.w_start != layer_mod.Path.planar) return false;
        const pr = lp.pathResolved(path) orelse lp.resolved orelse self.r;
        if (pr.settings.project.path_rules.len > 0) return false;
        // A root of a painted feature: inside the part on all sides.
        if (path.hidden) return self.sameFamily(from, to);
        return switch (path.feature) {
            .support => true,
            .infill => pr.settings.project.wall_count > 0 and self.sameFamily(from, to),
            else => false,
        };
    }

    fn sameFamily(self: *const Emitter, a: u32, b: u32) bool {
        if (a >= self.slots.len or b >= self.slots.len) return false;
        var fa: [8]u8 = undefined;
        var fb: [8]u8 = undefined;
        return std.mem.eql(u8, filaments.family(self.slots[a].material, &fa), filaments.family(self.slots[b].material, &fb));
    }

    /// The plastic (mm³) of path `i` of `lp`, as `paths` prints it: its
    /// length times its bead area, with no path rule.
    fn pathVolume(self: *const Emitter, lp: *const LayerPlan, i: usize) f64 {
        const pts = lp.points.get(i);
        if (pts.len < 2) return 0;
        const path = lp.paths.items[i];
        const lr = lp.resolved orelse self.r;
        const path_r = lp.pathResolved(path) orelse lr;
        const e_per_mm = flow.beadArea(lp.width, lp.height) / self.r.filament_area * lr.settings.filament.flow_ratio;
        const e = self.pathE(lp, path, path_r, lr, e_per_mm);
        // The lengths of the moves, as `extrude` finds them.
        var x = geom.toMm(pts[0].x);
        var y = geom.toMm(pts[0].y);
        var len: f64 = 0;
        const n = pts.len + @as(usize, @intFromBool(path.closed and pts.len > 2));
        for (1..n) |k| {
            const q = pts[k % pts.len];
            const qx = geom.toMm(q.x);
            const qy = geom.toMm(q.y);
            const d = geom.hypot(qx - x, qy - y);
            if (d < 1e-4) continue;
            len += d;
            x = qx;
            y = qy;
        }
        return len * e * self.r.filament_area;
    }

    /// The plastic (mm³) of the hidden lines (see `hiddenFor`) of a change
    /// from slot `from` to slot `to` before path `i`: the paths from `i` on
    /// that are hidden lines of `to`, up to the first path that is not.
    pub fn hiddenRun(self: *const Emitter, lp: *const LayerPlan, i: usize, from: u32, to: u32) f64 {
        const lr = lp.resolved orelse self.r;
        var v: f64 = 0;
        for (lp.paths.items[i..], i..) |path, k| {
            if (lp.points.get(k).len == 0) continue;
            if (self.toolOf(path.feature, lp.pathResolved(path) orelse lr) != to) break;
            if (!self.hiddenFor(lp, path, from, to)) break;
            v += self.pathVolume(lp, k);
        }
        return v;
    }

    /// Puts the paths of a layer of many filaments (see LayerPlan.rank) in
    /// print order, for the filament in the nozzle now (`tool`). The
    /// filaments of the layer print one after the other, in the order of
    /// `blockOrder`. After a change, a filament first prints its hidden
    /// lines (see `hiddenFor`). The rest keeps the order of the plan. The
    /// combing ways and the move lengths in `pr` move with their paths.
    /// The result depends only on the plan and on `tool`, so a plan from a
    /// stream gets the same order again.
    pub fn orderLayer(self: *Emitter, lp: *LayerPlan, pr: *Prepared) std.mem.Allocator.Error!void {
        const n = lp.paths.items.len;
        if (self.slots.len < 2 or n < 2 or lp.rank.len != n or pr.paths.items.len != n) return;
        if (pr.lengths.items.len != lp.points.points.items.len) return;
        const gpa = self.gpa;
        const lr = lp.resolved orelse self.r;
        const tool = try gpa.alloc(u32, n);
        defer gpa.free(tool);
        var present = [_]bool{false} ** filaments.max_slots;
        for (lp.paths.items, tool) |path, *t| {
            t.* = @min(self.toolOf(path.feature, lp.pathResolved(path) orelse lr), filaments.max_slots - 1);
            present[t.*] = true;
        }
        var blocks: [filaments.max_slots]u32 = undefined;
        const order = self.blockOrder(lp, present, &blocks);
        // The key of each path: the place of its filament in `order`, then
        // its hidden lines first after a change, then its rank.
        var place = [_]u32{0} ** filaments.max_slots;
        var before = [_]u32{0} ** filaments.max_slots;
        var prev = self.tool;
        for (order, 0..) |t, k| {
            place[t] = @intCast(k);
            before[t] = prev;
            prev = t;
        }
        const key = try gpa.alloc(u64, n);
        defer gpa.free(key);
        for (lp.paths.items, tool, lp.rank, key) |path, t, r, *k| {
            const changed = before[t] != t;
            const late: u64 = @intFromBool(!(changed and self.hiddenFor(lp, path, before[t], t)));
            k.* = (@as(u64, place[t]) << 40) | (late << 32) | r;
        }
        const idx = try gpa.alloc(u32, n);
        defer gpa.free(idx);
        for (idx, 0..) |*d, k| d.* = @intCast(k);
        std.mem.sort(u32, idx, key, struct {
            fn lt(c: []const u64, a: u32, b: u32) bool {
                return c[a] < c[b];
            }
        }.lt);
        var same = true;
        for (idx, 0..) |d, k| same = same and d == k;
        if (same) return;
        // The new lists of the plan (in its arena: a plan from a stream
        // reads the memory of the stream), and of the prepared work.
        const a = lp.arena.allocator();
        const new_paths = try a.alloc(layer_mod.Path, n);
        const rank = try a.alloc(u32, n);
        const ends = try a.alloc(u32, n);
        const points = try a.alloc(geom.Point, lp.points.points.items.len);
        const preps = try gpa.alloc(Prepared.PathPrep, n);
        defer gpa.free(preps);
        const lengths = try gpa.alloc(f64, pr.lengths.items.len);
        defer gpa.free(lengths);
        var pos: usize = 0;
        for (idx, 0..) |src, k| {
            const p0: usize = if (src == 0) 0 else lp.points.ends.items[src - 1];
            const p1: usize = lp.points.ends.items[src];
            @memcpy(points[pos..][0 .. p1 - p0], lp.points.points.items[p0..p1]);
            @memcpy(lengths[pos..][0 .. p1 - p0], pr.lengths.items[p0..p1]);
            pos += p1 - p0;
            ends[k] = @intCast(pos);
            new_paths[k] = lp.paths.items[src];
            rank[k] = lp.rank[src];
            preps[k] = pr.paths.items[src];
        }
        lp.paths = .{ .items = new_paths, .capacity = n };
        lp.points = .{ .points = .{ .items = points, .capacity = points.len }, .ends = .{ .items = ends, .capacity = n } };
        lp.rank = rank;
        @memcpy(pr.paths.items, preps);
        @memcpy(pr.lengths.items, lengths);
        // The end of the last path with points.
        var k = n;
        while (k > 0) {
            k -= 1;
            const pts = lp.points.get(k);
            if (pts.len == 0) continue;
            const q = if (lp.paths.items[k].closed and pts.len > 2) pts[0] else pts[pts.len - 1];
            pr.end = .{ geom.toMm(q.x), geom.toMm(q.y) };
            pr.end_feature = lp.paths.items[k].feature;
            break;
        }
    }

    /// The hidden lines of each filament of a layer (see `hiddenFor`), in
    /// mm³: `all` after a change from a filament of the same family,
    /// `support` (the support body) after a change from another family.
    pub const Hidden = struct {
        all: [filaments.max_slots]f64 = @splat(0),
        support: [filaments.max_slots]f64 = @splat(0),
    };

    /// The hidden lines of each filament of `lp` (see `Hidden`).
    pub fn layerHidden(self: *const Emitter, lp: *const LayerPlan) Hidden {
        var h: Hidden = .{};
        const lr = lp.resolved orelse self.r;
        for (lp.paths.items, 0..) |path, i| {
            const t = self.toolOf(path.feature, lp.pathResolved(path) orelse lr);
            if (t >= filaments.max_slots or !self.hiddenFor(lp, path, t, t)) continue;
            const v = self.pathVolume(lp, i);
            h.all[t] += v;
            if (path.feature == .support) h.support[t] += v;
        }
        return h;
    }

    /// The cost of a change from slot `a` to slot `b` for the flush
    /// planner (see filaments.bestOrder), with the hidden lines `h` of the
    /// layer: the time of the change (`change_time`) plus the time of its
    /// flush at the flow limit of the filament (`max_flow`). The flush is
    /// the one of `changeTool`: less by the hidden lines of `b`, down to
    /// `min_flush_mm3`. So an order with one more change wins only if it
    /// saves more flush than the nozzle can push out in `change_time`:
    /// it saves time and plastic.
    pub fn changeCost(self: *const Emitter, h: *const Hidden, a: u32, b: u32) filaments.Cost {
        const g = self.r.settings;
        const m = g.machine;
        var flush: f64 = 0;
        if (m.filament_change == .tool and a < self.slots.len and b < self.slots.len) {
            flush = filaments.flushVolume(self.slots[a].color, self.slots[b].color, m.flush_volume, g.project.flush_multiplier);
            if (flush > min_flush_mm3) {
                const hidden = if (self.sameFamily(a, b)) h.all[b] else h.support[b];
                flush -= @min(hidden, flush - min_flush_mm3);
            }
        }
        const rate = @max(g.filament.max_flow, 0.5);
        return .{ .seconds = m.change_time + flush / rate, .changes = 1 };
    }

    /// The order of the filaments of a layer (`present`), into `buf`: the
    /// order of the flush planner (see filaments.bestOrder) from the
    /// filament in the nozzle. The rule of LayerPlan.groupByFilament (up
    /// by slot on even layers, down on odd layers) breaks the ties.
    fn blockOrder(self: *const Emitter, lp: *const LayerPlan, present: [filaments.max_slots]bool, buf: *[filaments.max_slots]u32) []const u32 {
        var rule: [filaments.max_slots]u32 = undefined;
        var n: usize = 0;
        for (0..filaments.max_slots) |k| {
            const t = if (lp.index % 2 == 1) filaments.max_slots - 1 - k else k;
            if (!present[t]) continue;
            rule[n] = @intCast(t);
            n += 1;
        }
        const h = self.layerHidden(lp);
        const Ctx = struct {
            em: *const Emitter,
            h: *const Hidden,
            pub fn cost(c: @This(), a: u32, b: u32) filaments.Cost {
                return c.em.changeCost(c.h, a, b);
            }
        };
        filaments.bestOrder(self.tool, rule[0..n], Ctx{ .em = self, .h = &h }, buf[0..n]);
        return buf[0..n];
    }

    /// A plain retraction before a move to the tower (no wipe, no z hop:
    /// the tower is away from the part).
    fn towerRetract(self: *Emitter) Error!void {
        const len = self.lr.retract_length;
        if (self.retracted or !self.extruded or len <= 0) return;
        try self.w.writeAll("G1 E-");
        try writeNum(self.w, len, 4);
        try self.w.writeAll(" F");
        try writeNum(self.w, self.r.settings.machine.retract_speed * 60, 0);
        try self.w.writeAll("\n");
        self.retracted = true;
        self.retract_len = len;
        self.feed = -1;
        self.stats.retractions += 1;
        try self.addTime(self.retractTime(len));
        self.stop = true;
    }

    /// Lines of tower k at the z of its layer: a travel to (x0, y0) at the
    /// z of the print, then extrusions through `pts`. A stacked tower
    /// below the print: the nozzle goes down to its layer, and back up.
    fn towerLines(self: *Emitter, k: usize, pts: []const [2]f64, first: bool) Error!void {
        if (pts.len < 2) return;
        if (!self.dry) try self.w.writeAll(";TYPE:PRIME-TOWER\n");
        if (!self.dry and self.bambu_blocks) try self.w.writeAll("; FEATURE: Prime tower\n");
        self.feature = null;
        try self.towerRetract();
        try self.move(pts[0][0], pts[0][1]);
        const tz = self.tower_z[k];
        const down = self.z - tz;
        if (down > 1e-6) {
            try self.zMove(down);
            try self.w.writeAll("G0 Z");
            try writeNum(self.w, tz, 3);
            try self.w.writeAll("\n");
        }
        try self.unretract();
        // A stacked layer is as high as the gap to the top of the tower.
        const h = if (self.towers.stacked()) tz - self.tower_top[k] else self.layer_h;
        const t_first = first or (self.towers.stacked() and self.tower_count[k] == 1);
        const e = flow.beadArea(self.layer_w, h) / self.r.filament_area;
        const speed = self.lr.speed(.skirt, self.layer_w, h, t_first);
        for (pts[1..]) |q| try self.extrude(q[0], q[1], e, speed);
        self.extruded = true;
        if (down > 1e-6) {
            try self.towerRetract();
            try self.zMove(down);
            try self.w.writeAll("G0 Z");
            try writeNum(self.w, self.z, 3);
            try self.w.writeAll("\n");
        }
    }

    /// Starts layer `self.layer_index` of tower k, once for each layer:
    /// its rows from 0, and its z. A stacked tower puts its layer on its
    /// top (the first one on the bed, as high as a first layer); one tower
    /// prints at the z of the print.
    fn towerLayer(self: *Emitter, k: usize) void {
        if (self.tower_layer[k] == self.layer_index) return;
        self.tower_layer[k] = self.layer_index;
        self.tower_rows[k] = 0;
        self.tower_top[k] = if (self.tower_count[k] == 0) 0 else self.tower_z[k];
        self.tower_z[k] = if (!self.towers.stacked())
            self.z
        else if (self.tower_count[k] == 0)
            @min(self.z, self.r.settings.project.first_layer_height)
        else
            @min(self.z, self.tower_top[k] + self.layer_h);
        self.tower_count[k] += 1;
        self.stats.tower_layers[k] = @intCast(self.tower_count[k]);
    }

    /// Purges `volume` mm³ into tower k: rows of lines across it, from
    /// the row after the last one of this layer.
    fn towerPurge(self: *Emitter, k: usize, volume: f64, first: bool) Error!void {
        const t = self.towers.list[k];
        self.towerLayer(k);
        const w = self.layer_w;
        const x0 = t.x - t.size / 2;
        const x1 = t.x + t.size / 2;
        const y0 = t.y - t.ySize() / 2;
        // The rows of one layer: a row never prints over another one of
        // the same layer. A purge past the last row stops there (counted
        // in Stats.tower_short_mm3); the depth of the tower makes room
        // for the most purge of a layer (PlateJob.towers).
        const rows_max: u32 = @min(max_tower_rows, @max(1, @as(u32, @intFromFloat(t.ySize() / w))));
        const h = if (self.towers.stacked()) self.tower_z[k] - self.tower_top[k] else self.layer_h;
        const area = flow.beadArea(w, @max(h, 0.01));
        var len = volume / area;
        var pts: [2 * max_tower_rows + 2][2]f64 = undefined;
        var n: usize = 0;
        while (len > 1e-9 and self.tower_rows[k] < rows_max) {
            const row = self.tower_rows[k];
            const y = y0 + (@as(f64, @floatFromInt(row)) + 0.5) * w;
            const ltr = row % 2 == 0;
            // The last row is as long as the purge that is left.
            const run = @min(len, t.size);
            pts[n] = .{ if (ltr) x0 else x1, y };
            pts[n + 1] = .{ if (ltr) x0 + run else x1 - run, y };
            n += 2;
            len -= run;
            self.tower_rows[k] += 1;
        }
        if (len > 1e-9) self.stats.tower_short_mm3 += len * area;
        try self.towerLines(k, pts[0..n], first);
    }

    /// A light layer of the tower on a layer with no change: its loop and
    /// a diagonal.
    fn towerSparse(self: *Emitter, k: usize, first: bool) Error!void {
        const t = self.towers.list[k];
        const h = t.size / 2;
        const d = t.ySize() / 2;
        const pts = [_][2]f64{ .{ t.x - h, t.y - d }, .{ t.x + h, t.y - d }, .{ t.x + h, t.y + d }, .{ t.x - h, t.y + d }, .{ t.x - h, t.y - d }, .{ t.x + h, t.y + d } };
        try self.towerLines(k, &pts, first);
    }

    /// Writes the change G-code of the machine with the facts of the
    /// change (see gcode_vars.Context.change).
    fn writeChange(self: *Emitter, text: []const u8, next: u32, flush_mm: f64, old_temp: f64, new_temp: f64, x: f64, y: f64) Writer.Error!void {
        const m = self.r.settings.machine;
        const ctx: gcode_vars.Context = .{
            .r = self.r,
            .layer_count = self.layer_count,
            .max_layer_z = self.z,
            .layer_z = self.z,
            .object_model = m.gcode_flavor == .reprap,
            .slots = self.slots,
            .tool = self.tool,
            .layer_index = self.layer_index,
            .change = .{ .next = next, .flush_mm = flush_mm, .count = self.stats.changes, .old_temp = old_temp, .new_temp = new_temp, .after = .{ x + m.origin_x, y + m.origin_y, self.z } },
        };
        _ = gcode_vars.render(self.gpa, self.w, text, &ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.WriteFailed,
            error.WriteFailed => return error.WriteFailed,
        };
        try self.w.writeAll("\n");
    }

    /// The fan of a layer: off on the first layers, the boost speed on a
    /// layer that prints in less than `fan_boost_time`, else the fan speed.
    /// On the layers of the ramp (`fan_ramp_layers`), a part of it.
    fn coolingFan(self: *Emitter, lp: *const LayerPlan, layer_time: f64) Error!void {
        const g = self.r.settings;
        const s = self.lr.settings;
        self.layer_fan = @intFromFloat(@round(255 * layerFan(g.filament, s.filament, lp.index, layer_time)));
        try self.setFan(self.layer_fan);
    }

    /// The fan of layer `index` (0 to 1): `plate` gives the layers with the
    /// fan off and the ramp, `here` the speeds of the layer.
    fn layerFan(plate: settings_mod.Filament, here: settings_mod.Filament, index: usize, layer_time: f64) f64 {
        if (index < plate.fan_off_layers) return 0;
        const full = if (layer_time < here.fan_boost_time) here.fan_max_speed else here.fan_speed;
        return full * fanRamp(@intCast(index - plate.fan_off_layers), plate.fan_ramp_layers);
    }

    /// The part of the fan speed on layer `k` after the layers with the fan
    /// off: (k + 1) / (ramp + 1) on the ramp, then 1.
    fn fanRamp(k: u32, ramp: u32) f64 {
        if (k >= ramp) return 1;
        return @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(ramp + 1));
    }

    /// The speed of an extrusion with the full speed `full` on a layer that
    /// prints slower by the ratio `k` < 1 (see `layer`).
    fn slowSpeed(full: f64, k: f64, min_speed: f64) f64 {
        return if (k < 1) geom.fmax(full * k, geom.fmin(full, min_speed)) else full;
    }

    /// The moves of a layer: the layer change, and each path with the
    /// travel to it. The extrusions print slower by the ratio `slow`.
    /// `lapped`: the layer gets a cooling lap (for the path records).
    fn paths(self: *Emitter, lp: *const LayerPlan, slow: f64, lapped: bool) Error!void {
        // The settings of the layer (see `lr`).
        const lr = lp.resolved orelse self.r;
        self.lr = lr;
        const s = lr.settings;
        const first = lp.index == 0;

        // Go up to the new layer. The retraction has no z hop: the layer
        // change moves the nozzle up, and the travel to the first path
        // goes at the height of the new layer.
        if (s.project.retract_layer_change) try self.retractHop(false);
        // The travel to the first path has no z hop either.
        self.layer_start = true;
        self.setOutline(lp);
        defer self.outline = null;
        self.comb_index = if (self.prep) |pr| (if (pr.index) |*ix| ix else null) else null;
        defer self.comb_index = null;
        try self.zMove(lp.z - self.z);
        self.z = lp.z;
        try self.w.writeAll("G0 Z");
        try writeNum(self.w, self.z, 3);
        try self.w.writeAll(" F");
        try writeNum(self.w, s.machine.max_z_speed * 60, 0);
        try self.w.writeAll("\n");
        self.feed = -1;
        self.stats.layer_count += 1;

        self.layer_h = lp.height;
        self.layer_w = lp.width;
        // The filament length for 1 mm of line.
        const e_per_mm = flow.beadArea(lp.width, lp.height) / self.r.filament_area * s.filament.flow_ratio;

        for (lp.paths.items, 0..) |path, i| {
            const pts = lp.points.get(i);
            if (pts.len == 0) {
                if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = self.stats.print_time_s, .end_time = self.stats.print_time_s, .area = 0 });
                continue;
            }
            const retractions = self.stats.retractions;
            // A path of another filament: a filament change first.
            const next_tool = self.toolOf(path.feature, lp.pathResolved(path) orelse lr);
            if (next_tool != self.tool) try self.changeTool(lp, i, next_tool, geom.toMm(pts[0].x), geom.toMm(pts[0].y), first);
            try self.setAccel(lr.accel(null, first));
            self.path_index = i;
            try self.travel(geom.toMm(pts[0].x), geom.toMm(pts[0].y), path.feature);
            self.layer_start = false;
            // A path in a modifier volume has the settings of the volume.
            const path_r = lp.pathResolved(path) orelse lr;
            try self.setAccel(path_r.accel(path.feature, first));
            const retracted = self.stats.retractions != retractions;
            if (self.feature != path.feature) {
                self.feature = path.feature;
                if (!self.dry) try self.w.print(";TYPE:{s}\n", .{typeName(path.feature)});
                // The name of Bambu Studio too, for a Bambu Lab printer.
                if (!self.dry and self.bambu_blocks) try self.w.print("; FEATURE: {s}\n", .{studioName(path.feature)});
            }
            // The fan of a bridge, and the fan of the layer after it.
            if (!self.dry) {
                if (path.feature == .bridge) {
                    try self.setFan(@intFromFloat(@round(255 * path_r.settings.project.bridge_fan)));
                } else if (self.layer_fan >= 0) {
                    try self.setFan(self.layer_fan);
                }
            }
            // A path with its own height (combined infill) has a larger
            // bead, so its flow limit gives a lower speed.
            const h: f64 = if (path.height > 0) path.height else lp.height;
            // A path whose width changes along it (Arachne): the flow limit
            // of its widest point.
            const widths: []const f32 = if (path.w_start != layer_mod.Path.planar) lp.point_w.items[path.w_start..][0..pts.len] else &.{};
            // The line width of the layer of the path: of its part, on a
            // plate of many parts (see LayerPlan.append).
            var speed_width = lp.width;
            if (path.region > 0 and path.region <= lp.region_layer.len) {
                speed_width = if (lp.layerOf(path) == 0) path_r.first_layer_line_width else path_r.line_width;
            }
            for (widths) |pw| speed_width = geom.fmax(speed_width, pw);
            // The layer index in the job of the part, for the speed ramp of
            // the first layers (see LayerPlan.layerOf).
            const full = path_r.speedAt(path.feature, speed_width, h, lp.layerOf(path));
            // The path rules of the settings (project.path_rules).
            const rr = self.applyRules(path_r.settings.project.path_rules, path, pts, lp, slowSpeed(full, slow, s.filament.min_speed), if (path.width > 0) path.width else speed_width, h);
            const speed = rr.speed;
            if (rr.fan) |f| if (!self.dry) try self.setFan(@intFromFloat(@round(255 * std.math.clamp(f, 0, 1))));
            const start_time = self.stats.print_time_s;
            // Ironing lines use a fraction of the flow of a normal line.
            // A path with its own width (a thin wall) or height has its own
            // flow.
            // The flow ratio of the part of the path (see LayerPlan.append).
            const fr = path_r.settings.filament.flow_ratio;
            const e = rr.flow * self.pathE(lp, path, path_r, lr, e_per_mm);
            const x0 = geom.toMm(pts[0].x);
            const y0 = geom.toMm(pts[0].y);
            if (path.z_start != layer_mod.Path.planar) {
                const area = try self.nonPlanar(lp, path, pts, speed, fr);
                if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = start_time, .end_time = self.stats.print_time_s, .area = area, .retracted = retracted, .slowed = slow < 1 or lapped, .fan = fanByte(self.fan), .tool = @intCast(self.tool) });
                continue;
            }
            if (widths.len > 0) {
                // The width of each segment is the mean of its ends.
                const e_scale = rr.flow * fr / self.r.filament_area;
                var area_len: f64 = 0;
                var len_sum: f64 = 0;
                const n = pts.len + @as(usize, @intFromBool(path.closed and pts.len > 2));
                for (1..n) |k| {
                    const j = k % pts.len;
                    const sw = (@as(f64, widths[k - 1]) + widths[j]) / 2;
                    const area = flow.beadArea(sw, h);
                    const x = geom.toMm(pts[j].x);
                    const y = geom.toMm(pts[j].y);
                    const d = @import("geom.zig").hypot(x - self.x, y - self.y);
                    area_len += area * d;
                    len_sum += d;
                    try self.extrudeLen(x, y, d, area * e_scale, speed);
                }
                const mean_area = if (len_sum > 0) area_len / len_sum else flow.beadArea(widths[0], h);
                if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = start_time, .end_time = self.stats.print_time_s, .area = mean_area * fr, .retracted = retracted, .slowed = slow < 1 or lapped, .fan = fanByte(self.fan), .tool = @intCast(self.tool) });
                try self.wallWipe(path, pts, path_r.settings.project.outer_wall_wipe, speed);
                continue;
            }
            if (self.prep != null and self.x == x0 and self.y == y0) {
                // The lengths of the moves from this start are known.
                const pr = self.prep.?;
                const base: usize = if (i == 0) 0 else lp.points.ends.items[i - 1];
                const lengths = pr.lengths.items[base..][0..pts.len];
                for (pts[1..], lengths[1..]) |q, d| try self.extrudeLen(geom.toMm(q.x), geom.toMm(q.y), d, e, speed);
                if (path.closed and pts.len > 2) try self.extrudeLen(x0, y0, pr.paths.items[i].close, e, speed);
            } else {
                for (pts[1..]) |q| try self.extrude(geom.toMm(q.x), geom.toMm(q.y), e, speed);
                if (path.closed and pts.len > 2) try self.extrude(x0, y0, e, speed);
            }
            if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = start_time, .end_time = self.stats.print_time_s, .area = e * self.r.filament_area, .retracted = retracted, .slowed = slow < 1 or lapped, .fan = fanByte(self.fan), .tool = @intCast(self.tool) });
            try self.wallWipe(path, pts, path_r.settings.project.outer_wall_wipe, speed);
        }
        // The tower grows on each layer up to the last change: a light
        // layer where this layer had no change.
        // Stacked towers have no light layers.
        if (self.towers.n == 1 and !self.towers.stacked()) {
            const t = self.towers.list[0];
            if (lp.index <= t.last_layer and self.tower_layer[0] != lp.index) {
                self.towerLayer(0);
                try self.towerSparse(0, first);
            }
        }
    }

    /// The filament length (mm) for 1 mm of a planar path of one width,
    /// before the path rules. `lr`: the settings of the layer, and
    /// `e_per_mm` the length for 1 mm of a line of the layer with them.
    fn pathE(self: *const Emitter, lp: *const LayerPlan, path: layer_mod.Path, path_r: *const Resolved, lr: *const Resolved, e_per_mm: f64) f64 {
        const s = lr.settings;
        const h: f64 = if (path.height > 0) path.height else lp.height;
        const fr = path_r.settings.filament.flow_ratio;
        const base_e = if (path.width > 0 or path.height > 0) flow.beadArea(if (path.width > 0) path.width else lp.width, h) / self.r.filament_area * fr else if (fr == s.filament.flow_ratio) e_per_mm else flow.beadArea(lp.width, lp.height) / self.r.filament_area * fr;
        return switch (path.feature) {
            .ironing => base_e * path_r.settings.project.ironing_flow,
            .infill => base_e * path_r.settings.project.infill_flow,
            .bridge => base_e * path_r.settings.project.bridge_flow,
            else => base_e,
        };
    }

    /// After a closed outer wall: the nozzle moves on along the start of
    /// the wall for `wipe_len` mm with no plastic (Project.outer_wall_wipe),
    /// at the speed of the wall.
    fn wallWipe(self: *Emitter, path: layer_mod.Path, pts: []const geom.Point, wipe_len: f64, speed: f64) Error!void {
        if (!(wipe_len > 0) or path.feature != .outer_wall or !path.closed or pts.len < 3) return;
        var left = wipe_len;
        for (pts[1..]) |q| {
            const x = geom.toMm(q.x);
            const y = geom.toMm(q.y);
            const d = @import("geom.zig").hypot(x - self.x, y - self.y);
            if (d < 1e-4) continue;
            if (d >= left) {
                const t = left / d;
                try self.wipeMove(self.x + (x - self.x) * t, self.y + (y - self.y) * t, speed);
                return;
            }
            try self.wipeMove(x, y, speed);
            left -= d;
        }
    }

    /// A move with no plastic at `speed`, on the line of a path.
    fn wipeMove(self: *Emitter, x: f64, y: f64, speed: f64) Error!void {
        const d = @import("geom.zig").hypot(x - self.x, y - self.y);
        if (d < 1e-4) return;
        var line: Line = .{ .skip = self.dry };
        line.add("G1 X");
        line.num(x + self.r.settings.machine.origin_x, 3);
        line.add(" Y");
        line.num(y + self.r.settings.machine.origin_y, 3);
        self.addFeed(&line, speed);
        line.add("\n");
        try line.put(self.w);
        try self.addMove(x - self.x, y - self.y, d, speed, 0);
        self.x = x;
        self.y = y;
        try self.addTravel(d);
    }

    /// A path with a z and a bead area at each point (slope smoothing):
    /// the nozzle goes down to the first point, moves with X, Y, Z, and E
    /// along the path, and goes back up to the z of the layer. The speed
    /// of each move is at most the speed at which Z moves at
    /// `max_z_speed`, and its acceleration at most the one at which Z
    /// moves at `max_z_accel`. Returns the mean deposited bead area (mm²),
    /// by length.
    fn nonPlanar(self: *Emitter, lp: *const LayerPlan, path: layer_mod.Path, pts: []const geom.Point, speed: f64, flow_ratio: f64) Error!f64 {
        const m = self.r.settings.machine;
        const data = lp.point_z.items[path.z_start..][0..pts.len];
        const e_scale = flow_ratio / self.r.filament_area;
        try self.unretract();
        try self.zTo(data[0].z);
        var cz: f64 = data[0].z;
        var len_sum: f64 = 0;
        var area_sum: f64 = 0;
        const n = pts.len + @as(usize, @intFromBool(path.closed and pts.len > 2));
        for (1..n) |k| {
            const j = k % pts.len;
            const prev = data[k - 1];
            const x = geom.toMm(pts[j].x);
            const y = geom.toMm(pts[j].y);
            const z: f64 = data[j].z;
            const dx = x - self.x;
            const dy = y - self.y;
            const dz = z - cz;
            const d = @sqrt(dx * dx + dy * dy + dz * dz);
            if (d < 1e-4) continue;
            const area = (@as(f64, prev.area) + data[j].area) / 2;
            const e = d * area * e_scale;
            var v = speed;
            if (@abs(dz) > 0) v = geom.fmin(v, m.max_z_speed * d / @abs(dz));
            var line: Line = .{ .skip = self.dry };
            line.add("G1 X");
            line.num(x + m.origin_x, 3);
            line.add(" Y");
            line.num(y + m.origin_y, 3);
            line.add(" Z");
            line.num(z, 3);
            line.add(" E");
            line.num(e, 5);
            self.addFeed(&line, v);
            line.add("\n");
            try line.put(self.w);
            const accel = if (self.accel > 0) self.accel else m.max_accel;
            const a = if (@abs(dz) > 0) geom.fmin(accel, m.max_z_accel * d / @abs(dz)) else accel;
            try self.addMove3(dx, dy, dz, d, v, a, e / d);
            self.x = x;
            self.y = y;
            cz = z;
            try self.addFilament(e);
            len_sum += d;
            area_sum += d * area;
        }
        self.extruded = true;
        try self.zTo(self.z);
        return if (len_sum > 0) area_sum / len_sum * flow_ratio else data[0].area * flow_ratio;
    }

    /// A Z move to z, from rest to rest, with no extrusion. The emitter
    /// keeps `self.z` as the z of the layer.
    fn zTo(self: *Emitter, z: f64) Error!void {
        // The nozzle is at the z of the layer, or at the z of the last
        // point of a path that is not planar.
        const from = self.nozzle_z orelse self.z;
        if (@abs(z - from) < 1e-6) return;
        try self.zMove(z - from);
        const f = geom.round(self.r.settings.machine.max_z_speed * 60);
        if (!self.dry) {
            try self.w.writeAll("G1 Z");
            try writeNum(self.w, z, 3);
            try self.w.writeAll(" F");
            try writeNum(self.w, f, 0);
            try self.w.writeAll("\n");
        }
        self.feed = f;
        self.nozzle_z = if (@abs(z - self.z) < 1e-9) null else z;
    }

    /// `addMove` for a move with a Z part, and its own acceleration.
    fn addMove3(self: *Emitter, dx: f64, dy: f64, dz: f64, d: f64, v0: f64, a0: f64, e_ratio: f64) Error!void {
        const va = self.axes().cap(dx / d, dy / d, v0, a0);
        const v = va[0];
        const a = va[1];
        if (self.collect) |list| {
            try list.append(self.gpa, .{ .dir = .{ dx / d, dy / d }, .dir_z = dz / d, .len = d, .speed = v, .accel = a, .e_ratio = e_ratio, .stop_before = self.stop });
        } else if (self.next_move < self.planned.len) {
            try self.addTime(self.planned[self.next_move].time);
            self.next_move += 1;
        } else {
            try self.addTime(motion.restTime(d, v, a));
        }
        self.stop = false;
    }

    /// The cooling lap: the nozzle goes up 1 mm, and moves around the box
    /// of the layer with the fan at full for `seconds`. The part fan blows
    /// on the plastic of the layer all the time.
    /// The outline of `lp` and its line width, for combing, and the boxes
    /// of the outline polygons, for fast combing tests (none for an outline
    /// of more polygons than the buffer holds).
    fn setOutline(self: *Emitter, lp: *const LayerPlan) void {
        self.outline = &lp.outline;
        self.width = lp.width;
        self.travel_accel = (lp.resolved orelse self.r).accel(null, lp.index == 0);
        self.n_boxes = 0;
        if (lp.outline.count() <= self.boxes.len) {
            for (0..lp.outline.count()) |k| {
                var bx = [4]i64{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
                for (lp.outline.get(k)) |q| bx = .{ @min(bx[0], q.x), @min(bx[1], q.y), @max(bx[2], q.x), @max(bx[3], q.y) };
                self.boxes[k] = bx;
            }
            self.n_boxes = lp.outline.count();
        }
    }

    /// Moves the nozzle position as `extrude` to x, y does, with no
    /// output. Returns the length of the move.
    fn stepTo(self: *Emitter, x: f64, y: f64) f64 {
        const d = @import("geom.zig").hypot(x - self.x, y - self.y);
        if (d < 1e-4) return d;
        self.x = x;
        self.y = y;
        return d;
    }

    fn coolingLap(self: *Emitter, lp: *const LayerPlan, seconds: f64) Error!void {
        const box = lp.points.bounds();
        if (box.isEmpty()) return;
        try self.retract();
        try self.w.writeAll(";TYPE:COOLING-LAP\n");
        const fan = self.fan;
        try self.setFan(@intFromFloat(@round(255 * self.lr.settings.filament.fan_max_speed)));
        try self.w.writeAll("G0 Z");
        try writeNum(self.w, self.z + 1, 3);
        try self.w.writeAll("\n");
        // A slow lap: the air has time on each spot, and the head does not
        // shake the part.
        const speed = @min(self.r.settings.machine.travel_speed, 40);
        const corners = [_][2]f64{
            .{ geom.toMm(box.min.x), geom.toMm(box.min.y) }, .{ geom.toMm(box.max.x), geom.toMm(box.min.y) },
            .{ geom.toMm(box.max.x), geom.toMm(box.max.y) }, .{ geom.toMm(box.min.x), geom.toMm(box.max.y) },
        };
        var left = seconds;
        var k: usize = 0;
        while (left > 0.05) : (k += 1) {
            const c = corners[k % 4];
            var x = c[0];
            var y = c[1];
            const d = @import("geom.zig").hypot(x - self.x, y - self.y);
            if (d / speed > left) {
                // The last move: only as far as the time goes.
                const f = left * speed / d;
                x = self.x + (x - self.x) * f;
                y = self.y + (y - self.y) * f;
            }
            const step = @import("geom.zig").hypot(x - self.x, y - self.y);
            try self.w.writeAll("G0 X");
            try writeNum(self.w, x + self.r.settings.machine.origin_x, 3);
            try self.w.writeAll(" Y");
            try writeNum(self.w, y + self.r.settings.machine.origin_y, 3);
            try self.writeFeed(speed);
            try self.w.writeAll("\n");
            self.x = x;
            self.y = y;
            try self.addTime(step / speed);
            try self.addTravel(step);
            left -= step / speed;
            if (step < 1e-6) break;
        }
        try self.setFan(fan);
    }

    /// The command that turns the part fan off. Bambu Studio writes
    /// "M106 S0" for a Bambu Lab printer, and never M107.
    fn fanOff(self: *const Emitter) []const u8 {
        return if (self.bambu_blocks) "M106 S0\n" else "M107\n";
    }

    fn setFan(self: *Emitter, value: i32) Writer.Error!void {
        if (value == self.fan) return;
        self.fan = value;
        if (value == 0) {
            try self.w.writeAll(self.fanOff());
        } else {
            try self.w.print("M106 S{d}\n", .{value});
        }
    }

    fn retract(self: *Emitter) Error!void {
        return self.retractHop(true);
    }

    /// The arc of a wipe (see `Project.retract_wipe`): its center, inside
    /// the layer, or null if no arc fits.
    fn wipeCenter(self: *Emitter, r: f64, margin: f64) Error!?[2]f64 {
        if (self.outline == null) return null;
        const no_arc = Prepared.PathPrep.retract;
        if (self.known()) |t| if (t.wipe != Prepared.PathPrep.unknown) {
            return if (t.wipe == no_arc) null else self.prep.?.way_points.items[@intCast(t.wipe)];
        };
        if (self.needsOutline()) return null;
        const c = self.findWipeCenter(r, margin);
        if (self.answers()) |t| {
            if (c) |q| {
                const pr = self.prep.?;
                t.wipe = @intCast(pr.way_points.items.len);
                try pr.way_points.append(self.gpa, q);
            } else t.wipe = no_arc;
        }
        return c;
    }

    /// The kept answers for the travel to the path that `layer` writes,
    /// or null if they are not from the nozzle position.
    fn known(self: *const Emitter) ?*Prepared.PathPrep {
        const pr = self.prep orelse return null;
        if (self.path_index >= pr.paths.items.len) return null;
        const t = &pr.paths.items[self.path_index];
        return if (t.from[0] == self.x and t.from[1] == self.y) t else null;
    }

    /// Where a dry run keeps the answers for the travel to the path, or
    /// null (see `keep_ways`). Answers from another nozzle position go.
    fn answers(self: *const Emitter) ?*Prepared.PathPrep {
        if (!self.dry or !self.keep_ways) return null;
        const pr = self.prep orelse return null;
        if (self.path_index >= pr.paths.items.len) return null;
        const t = &pr.paths.items[self.path_index];
        if (t.from[0] != self.x or t.from[1] != self.y) t.* = .{ .from = .{ self.x, self.y }, .close = t.close };
        return t;
    }

    /// True if the layer has no outline (see Prepared.replay). Then the
    /// run is not valid from here on.
    fn needsOutline(self: *Emitter) bool {
        const pr = self.prep orelse return false;
        if (!pr.replay) return false;
        self.need_plan = true;
        return true;
    }

    fn findWipeCenter(self: *const Emitter, r: f64, margin: f64) ?[2]f64 {
        const outline = self.outline orelse return null;
        // Each direction from the nozzle, until the whole arc and a margin
        // around it are inside.
        for (0..8) |k| {
            const a = std.math.pi * @as(f64, @floatFromInt(k)) / 4;
            const c = [2]f64{ self.x + r * @cos(a), self.y + r * @sin(a) };
            var ok = true;
            for (0..12) |j| {
                const t = 2 * std.math.pi * @as(f64, @floatFromInt(j)) / 12;
                const q = geom.Point{ .x = geom.fromMm(c[0] + (r + margin) * @cos(t)), .y = geom.fromMm(c[1] + (r + margin) * @sin(t)) };
                if (!geom.insideAny(outline.*, q)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return c;
        }
        return null;
    }

    /// A retraction on an arc inside the part: 270 degrees around a center
    /// one radius from the nozzle, in 9 moves, each with its part of the
    /// retraction. False if no arc fits (then the caller retracts plainly).
    fn wipeRetract(self: *Emitter, len: f64) Error!bool {
        // After a line in the part: the arc check keeps the nozzle inside
        // the layer. The support and the skirt are outside the part.
        const f = self.feature orelse return false;
        if (f == .support or f == .support_interface or f == .skirt) return false;
        const r = 0.4;
        const c = try self.wipeCenter(r, self.width_mm() / 2) orelse return false;
        const steps = 9;
        const sweep = 1.5 * std.math.pi;
        const arc = r * sweep;
        // The arc lasts as long as the retraction, at most the travel speed.
        const t = len / self.r.settings.machine.retract_speed;
        const speed = @min(self.r.settings.machine.travel_speed, arc / @max(t, 1e-3));
        const a0 = std.math.atan2(self.y - c[1], self.x - c[0]);
        try self.w.writeAll(";WIPE\n");
        for (1..steps + 1) |k| {
            const a = a0 + sweep * @as(f64, @floatFromInt(k)) / steps;
            const x = c[0] + r * @cos(a);
            const y = c[1] + r * @sin(a);
            try self.w.writeAll("G1 X");
            try writeNum(self.w, x + self.r.settings.machine.origin_x, 3);
            try self.w.writeAll(" Y");
            try writeNum(self.w, y + self.r.settings.machine.origin_y, 3);
            try self.w.writeAll(" E-");
            try writeNum(self.w, len / steps, 4);
            if (k == 1) {
                try self.w.writeAll(" F");
                try writeNum(self.w, speed * 60, 0);
            }
            try self.w.writeAll("\n");
            self.x = x;
            self.y = y;
        }
        try self.addTime(@max(arc / speed, self.retractTime(len)));
        return true;
    }

    fn width_mm(self: *const Emitter) f64 {
        return self.width;
    }

    /// A retraction, and a z hop if `hop` and `z_hop` is on.
    fn retractHop(self: *Emitter, hop: bool) Error!void {
        const len = self.lr.retract_length;
        if (self.retracted or !self.extruded or len <= 0) return;
        const wiped = self.lr.settings.project.retract_wipe and try self.wipeRetract(len);
        if (!wiped) {
            try self.w.writeAll("G1 E-");
            try writeNum(self.w, len, 4);
            try self.w.writeAll(" F");
            try writeNum(self.w, self.r.settings.machine.retract_speed * 60, 0);
            try self.w.writeAll("\n");
        }
        self.retracted = true;
        self.retract_len = len;
        self.feed = -1;
        self.stats.retractions += 1;
        if (!wiped) try self.addTime(self.retractTime(len));
        self.stop = true;
        const hop_len = self.lr.settings.project.z_hop;
        if (hop and hop_len > 0) {
            try self.zMove(hop_len);
            try self.w.writeAll("G0 Z");
            try writeNum(self.w, self.z + hop_len, 3);
            try self.w.writeAll("\n");
            self.hopped = true;
            self.hop_len = hop_len;
        }
    }

    fn unretract(self: *Emitter) Error!void {
        if (!self.retracted) return;
        if (self.hopped) {
            try self.zMove(self.hop_len);
            try self.w.writeAll("G0 Z");
            try writeNum(self.w, self.z, 3);
            try self.w.writeAll("\n");
            self.hopped = false;
        }
        const len = self.retract_len;
        try self.w.writeAll("G1 E");
        try writeNum(self.w, len, 4);
        try self.w.writeAll(" F");
        try writeNum(self.w, self.r.settings.machine.retract_speed * 60, 0);
        try self.w.writeAll("\n");
        self.retracted = false;
        self.feed = -1;
        try self.addTime(self.retractTime(len));
        self.stop = true;
    }

    fn travel(self: *Emitter, x: f64, y: f64, next: Feature) Error!void {
        const d = @import("geom.zig").hypot(x - self.x, y - self.y);
        if (d < 1e-4) return;
        if (d > self.lr.settings.project.retract_min_travel and !self.supportHop(x, y, next)) {
            // Combing: a way inside the part needs no retraction (see
            // `findWay`).
            var way: [max_way][2]f64 = undefined;
            if (try self.wayOf(x, y, d, &way)) |w| {
                for (w) |q| try self.move(q[0], q[1]);
            } else try self.retractHop(!self.layer_start and self.hopFor(x, y));
        }
        try self.move(x, y);
    }

    /// True if a travel to x, y goes from one tree support path to the
    /// next with no retraction: the straight line crosses no edge of the
    /// part. The support comes off, so a string there does no harm, and
    /// a tree layer has many small islands.
    fn supportHop(self: *Emitter, x: f64, y: f64, next: Feature) bool {
        if (self.lr.settings.project.support_style != .tree) return false;
        if (!isSupport(self.feature) or !isSupport(next)) return false;
        const outline = self.outline orelse return true;
        if (self.known()) |t| if (t.support_hop != .unknown) return t.support_hop == .yes;
        if (self.needsOutline()) return false;
        const a: geom.Point = .{ .x = geom.fromMm(self.x), .y = geom.fromMm(self.y) };
        const b: geom.Point = .{ .x = geom.fromMm(x), .y = geom.fromMm(y) };
        var hit: usize = 0;
        // No crossing leaves `hit` at its largest value.
        _ = self.clearOf(outline.*, self.boxes[0..self.n_boxes], a, b, &hit);
        const free = hit == std.math.maxInt(usize);
        if (self.answers()) |t| t.support_hop = if (free) .yes else .no;
        return free;
    }

    fn isSupport(f: ?Feature) bool {
        const k = f orelse return false;
        return k == .support or k == .support_interface;
    }

    /// True if a travel to x, y with a retraction lifts the nozzle: always
    /// without `z_hop_only_crossing`, else only if the straight line
    /// crosses an edge of the layer outline. The z hop is the one of the
    /// layer (see `lr`).
    fn hopFor(self: *Emitter, x: f64, y: f64) bool {
        const p = self.lr.settings.project;
        if (!p.z_hop_only_crossing or p.z_hop <= 0) return true;
        const outline = self.outline orelse return true;
        if (self.known()) |t| if (t.hop != .unknown) return t.hop == .yes;
        if (self.needsOutline()) return true;
        const a: geom.Point = .{ .x = geom.fromMm(self.x), .y = geom.fromMm(self.y) };
        const b: geom.Point = .{ .x = geom.fromMm(x), .y = geom.fromMm(y) };
        var hit: usize = 0;
        const hop = !self.clearOf(outline.*, self.boxes[0..self.n_boxes], a, b, &hit);
        if (self.answers()) |t| t.hop = if (hop) .yes else .no;
        return hop;
    }

    /// The combing way to x, y (see `comb`): from `prep` if it has the
    /// way from the nozzle position, else found now. In a dry run, a way
    /// that is found now goes into `prep`.
    fn wayOf(self: *Emitter, x: f64, y: f64, d: f64, buf: *[max_way][2]f64) Error!?[]const [2]f64 {
        const unknown = Prepared.PathPrep.unknown;
        const no_way = Prepared.PathPrep.retract;
        if (self.known()) |t| if (t.n != unknown) {
            if (t.n == no_way) return null;
            return self.prep.?.way_points.items[t.start..][0..@intCast(t.n)];
        };
        if (self.needsOutline()) return null;
        const found = self.findWay(x, y, d, buf);
        if (self.answers()) |t| {
            // Keep the way for the text of the layer.
            if (found) |n| {
                const pr = self.prep.?;
                t.start = @intCast(pr.way_points.items.len);
                t.n = @intCast(n);
                try pr.way_points.appendSlice(self.gpa, buf[0..n]);
            } else t.n = no_way;
        }
        const n = found orelse return null;
        return buf[0..n];
    }

    /// The pressure advance command of the firmware (as OrcaSlicer
    /// `GCodeWriter::set_pressure_advance` writes it), or nothing for 0.
    fn pressureAdvance(self: *Emitter, pa: f64) Writer.Error!void {
        if (!(pa > 0)) return;
        if (self.bambu_blocks) {
            try self.w.writeAll("M900 K");
            try writeNum(self.w, pa, 4);
            try self.w.writeAll(" L1000 M10 ; pressure advance\n");
            return;
        }
        switch (self.r.settings.machine.gcode_flavor) {
            .klipper => {
                try self.w.writeAll("SET_PRESSURE_ADVANCE ADVANCE=");
                try writeNum(self.w, pa, 4);
                try self.w.writeAll("\n");
            },
            .reprap => {
                try self.w.writeAll("M572 D0 S");
                try writeNum(self.w, pa, 4);
                try self.w.writeAll(" ; pressure advance\n");
            },
            .repetier => {
                // Repetier M233: X (quadratic) and Y (linear) get the value.
                try self.w.writeAll("M233 X");
                try writeNum(self.w, pa, 4);
                try self.w.writeAll(" Y");
                try writeNum(self.w, pa, 4);
                try self.w.writeAll(" ; pressure advance\n");
            },
            .marlin => {
                try self.w.writeAll("M900 K");
                try writeNum(self.w, pa, 4);
                try self.w.writeAll(" ; linear advance\n");
            },
        }
    }

    /// The speed of a travel move: `first_layer_travel_speed` on the first
    /// layer, if it is set, else `travel_speed`.
    fn travelSpeed(self: *const Emitter) f64 {
        const m = self.r.settings.machine;
        return if (self.layer_index == 0 and m.first_layer_travel_speed > 0) m.first_layer_travel_speed else m.travel_speed;
    }

    /// A travel move in a straight line, with no retraction.
    fn move(self: *Emitter, x: f64, y: f64) Error!void {
        const d = @import("geom.zig").hypot(x - self.x, y - self.y);
        if (d < 1e-4) return;
        const speed = self.travelSpeed();
        var line: Line = .{ .skip = self.dry };
        line.add("G0 X");
        line.num(x + self.r.settings.machine.origin_x, 3);
        line.add(" Y");
        line.num(y + self.r.settings.machine.origin_y, 3);
        self.addFeed(&line, speed);
        line.add("\n");
        try line.put(self.w);
        try self.addMove(x - self.x, y - self.y, d, speed, 0);
        self.x = x;
        self.y = y;
        try self.addTravel(d);
    }

    /// The combing way to x, y, or null (retract). First the way of
    /// `comb` with the box corners only. If there is none, a way along the
    /// edges of the part replaces the retraction, if it takes less time.
    fn findWay(self: *const Emitter, x: f64, y: f64, d: f64, way: *[max_way][2]f64) ?usize {
        if (self.comb(x, y, d, way, false)) |n| return n;
        const n = self.comb(x, y, d, way, true) orelse return null;
        if (self.walkTooLong(x, y, d, way[0..n])) return null;
        return n;
    }

    /// Combing: a way from the nozzle to x, y inside the outline of the
    /// layer, so the travel needs no retraction. Null: no way (retract).
    /// Else the number of waypoints before x, y in `way`. From each point,
    /// the way goes straight to x, y if it can. Else it goes around the
    /// polygon that the straight line crosses first (a hole, or a bay of
    /// the outer boundary):
    ///
    /// 1. Only if `walks`: along the polygon, one line width inside the
    ///    material, from the first crossing to the last crossing of the
    ///    line with the polygon, on the shorter side. The way skips each
    ///    vertex that it can (a straight move to a later vertex that
    ///    crosses no edge). The travel uses this way only where the way
    ///    with step 2 alone fails, and only if it takes less time than a
    ///    retraction (see `walkTooLong`).
    /// 2. If that fails, through the corner of the box of the polygon
    ///    (grown by one line width) that it can reach and that is nearest
    ///    to the end.
    ///
    /// A way longer than 3 times the straight line (plus 5 mm) does not
    /// count.
    fn comb(self: *const Emitter, x: f64, y: f64, d: f64, way: *[max_way][2]f64, walks: bool) ?usize {
        const p = self.lr.settings.project;
        if (!p.combing) return null;
        if (p.combing_max_distance > 0 and d > p.combing_max_distance) return null;
        const outline = self.outline orelse return null;
        const b: geom.Point = .{ .x = geom.fromMm(x), .y = geom.fromMm(y) };
        const boxes = self.boxes[0..self.n_boxes];
        const g = geom.fromMm(self.width);
        const limit = 3 * d + 5;
        var cur: geom.Point = .{ .x = geom.fromMm(self.x), .y = geom.fromMm(self.y) };
        var used: f64 = 0;
        var n: usize = 0;
        var seen: [max_way]geom.Point = undefined;
        var walked: [max_walks]usize = undefined;
        var n_walked: usize = 0;
        while (true) {
            var hit: usize = 0;
            if (self.clearOf(outline.*, boxes, cur, b, &hit)) return if (used + dist(cur, b) <= limit) n else null;
            if (n == max_way or hit >= boxes.len) return null;
            // The polygon with the crossing nearest to cur.
            const first = firstCrossing(outline.*, boxes, cur, b) orelse return null;
            // Step 1, once for each polygon.
            const again = for (walked[0..n_walked]) |k| {
                if (k == first.poly) break true;
            } else false;
            if (walks and !again and n_walked < max_walks) {
                walked[n_walked] = first.poly;
                n_walked += 1;
                const before = n;
                if (self.walkAround(outline.*, boxes, first, cur, b, g, way, &n, &used, limit)) {
                    if (n > before) {
                        cur = .{ .x = geom.fromMm(way[n - 1][0]), .y = geom.fromMm(way[n - 1][1]) };
                        continue;
                    }
                } else {
                    n = before;
                }
            }
            // Step 2.
            const bx = boxes[hit];
            const corners = [4]geom.Point{
                .{ .x = bx[0] - g, .y = bx[1] - g }, .{ .x = bx[2] + g, .y = bx[1] - g },
                .{ .x = bx[2] + g, .y = bx[3] + g }, .{ .x = bx[0] - g, .y = bx[3] + g },
            };
            var best: ?geom.Point = null;
            var best_cost: f64 = std.math.inf(f64);
            var ignore: usize = 0;
            for (corners) |c| {
                var dup = false;
                for (seen[0..n]) |q| if (q.x == c.x and q.y == c.y) {
                    dup = true;
                };
                if (dup) continue;
                const cost = dist(cur, c) + dist(c, b);
                if (cost >= best_cost) continue;
                if (!self.clearOf(outline.*, boxes, cur, c, &ignore)) continue;
                best = c;
                best_cost = cost;
            }
            const c = best orelse return null;
            used += dist(cur, c);
            if (used > limit) return null;
            seen[n] = c;
            way[n] = .{ geom.toMm(c.x), geom.toMm(c.y) };
            n += 1;
            cur = c;
        }
    }

    /// True if the way (the waypoints, then x, y) takes longer than a
    /// retraction, the push back, and the z hop, with the straight travel.
    /// The planner gives both times, from rest to rest.
    fn walkTooLong(self: *const Emitter, x: f64, y: f64, d: f64, way: []const [2]f64) bool {
        const m = self.r.settings.machine;
        const a = if (self.travel_accel > 0) self.travel_accel else m.max_accel;
        var moves: [max_way + 1]motion.Move = undefined;
        var k: usize = 0;
        var px = self.x;
        var py = self.y;
        for (0..way.len + 1) |i| {
            const q = if (i < way.len) way[i] else [2]f64{ x, y };
            const l = @import("geom.zig").hypot(q[0] - px, q[1] - py);
            if (l > 1e-6) {
                moves[k] = .{ .dir = .{ (q[0] - px) / l, (q[1] - py) / l }, .len = l, .speed = self.travelSpeed(), .accel = a };
                k += 1;
            }
            px = q[0];
            py = q[1];
        }
        const t_way = motion.plan(moves[0..k], self.limits());
        const hop = self.lr.settings.project.z_hop;
        const stop = 2 * self.retractTime(self.lr.retract_length) + if (hop > 0) 2 * motion.restTime(hop, m.max_z_speed, m.max_z_accel) else 0;
        return t_way > motion.restTime(d, self.travelSpeed(), a) + stop;
    }

    const Crossing = struct {
        poly: usize,
        /// The edges (from vertex i to i + 1) of the first and the last
        /// crossing along the line.
        first_edge: usize,
        last_edge: usize,
    };

    /// The polygon whose edge the segment a-b crosses nearest to a, with
    /// its first and last crossed edge. Null: no crossing.
    fn firstCrossing(outline: geom.Paths, boxes: []const [4]i64, a: geom.Point, b: geom.Point) ?Crossing {
        const lo_x = @min(a.x, b.x);
        const hi_x = @max(a.x, b.x);
        const lo_y = @min(a.y, b.y);
        const hi_y = @max(a.y, b.y);
        var best: ?Crossing = null;
        var best_t: f64 = std.math.inf(f64);
        for (0..outline.count()) |k| {
            if (boxes.len == outline.count()) {
                const bx = boxes[k];
                if (bx[2] < lo_x or bx[0] > hi_x or bx[3] < lo_y or bx[1] > hi_y) continue;
            }
            const poly = outline.get(k);
            var t_min: f64 = std.math.inf(f64);
            var t_max: f64 = -std.math.inf(f64);
            var e_min: usize = 0;
            var e_max: usize = 0;
            for (poly, 0..) |c, i| {
                const e = poly[(i + 1) % poly.len];
                const c1 = geom.cross3(a, b, c);
                const c2 = geom.cross3(a, b, e);
                if (std.math.sign(c1) * std.math.sign(c2) >= 0) continue;
                const s3 = std.math.sign(geom.cross3(c, e, a));
                const s4 = std.math.sign(geom.cross3(c, e, b));
                if (s3 * s4 >= 0) continue;
                // The parameter along a-b of the crossing.
                const fc: f64 = @floatFromInt(geom.cross3(c, e, a));
                const fe: f64 = @floatFromInt(geom.cross3(c, e, b));
                const t = fc / (fc - fe);
                if (t < t_min) {
                    t_min = t;
                    e_min = i;
                }
                if (t > t_max) {
                    t_max = t;
                    e_max = i;
                }
            }
            if (t_min < best_t) {
                best_t = t_min;
                best = .{ .poly = k, .first_edge = e_min, .last_edge = e_max };
            }
        }
        return best;
    }

    /// Step 1 of `comb`: the way from cur along the polygon of `cr`, past
    /// its last crossing. Adds the waypoints to `way`. False: no way.
    fn walkAround(self: *const Emitter, outline: geom.Paths, boxes: []const [4]i64, cr: Crossing, cur: geom.Point, b: geom.Point, inset: i64, way: *[max_way][2]f64, n: *usize, used: *f64, limit: f64) bool {
        const poly = outline.get(cr.poly);
        const m = poly.len;
        if (m < 3) return false;
        // Forward: the vertices after the first crossed edge, up to the
        // start of the last crossed edge. Backward: the vertices from the
        // start of the first crossed edge down to the end of the last.
        const n_fwd = (cr.last_edge + m - cr.first_edge) % m;
        const n_bwd = (cr.first_edge + m - cr.last_edge) % m;
        var len_fwd: f64 = 0;
        var len_bwd: f64 = 0;
        for (0..n_fwd) |j| len_fwd += dist(poly[(cr.first_edge + 1 + j) % m], poly[(cr.first_edge + 2 + j) % m]);
        for (0..n_bwd) |j| len_bwd += dist(poly[(cr.first_edge + m - j) % m], poly[(cr.first_edge + 2 * m - 1 - j) % m]);
        const fwd = len_fwd <= len_bwd;
        const count = if (fwd) n_fwd else n_bwd;
        if (count == 0) return false;
        var anchor = cur;
        var pending: ?geom.Point = null;
        var ignore: usize = 0;
        for (0..count) |j| {
            const vi = if (fwd) (cr.first_edge + 1 + j) % m else (cr.first_edge + m - j) % m;
            const q = insetVertex(poly, vi, inset);
            if (self.clearOf(outline, boxes, anchor, q, &ignore)) {
                pending = q;
                continue;
            }
            // Keep the last vertex that the anchor sees.
            const keep = pending orelse return false;
            if (n.* == max_way) return false;
            used.* += dist(anchor, keep);
            if (used.* > limit) return false;
            way[n.*] = .{ geom.toMm(keep.x), geom.toMm(keep.y) };
            n.* += 1;
            anchor = keep;
            pending = null;
            if (self.clearOf(outline, boxes, anchor, b, &ignore)) return true;
            if (!self.clearOf(outline, boxes, anchor, q, &ignore)) return false;
            pending = q;
        }
        const keep = pending orelse return true;
        if (n.* == max_way) return false;
        used.* += dist(anchor, keep);
        if (used.* > limit) return false;
        way[n.*] = .{ geom.toMm(keep.x), geom.toMm(keep.y) };
        n.* += 1;
        return true;
    }

    /// Vertex i of a polygon, moved by `inset` to the left of the polygon
    /// direction: into the material for an outer boundary
    /// (counterclockwise) and for a hole (clockwise). The move goes along
    /// the bisector of the two edges, at most 3 times `inset` long.
    fn insetVertex(poly: []const geom.Point, i: usize, inset: i64) geom.Point {
        const m = poly.len;
        const u = poly[(i + m - 1) % m];
        const v = poly[i];
        const w = poly[(i + 1) % m];
        const e1 = unit(u, v);
        const e2 = unit(v, w);
        const n1 = [2]f64{ -e1[1], e1[0] };
        const n2 = [2]f64{ -e2[1], e2[0] };
        const dot = n1[0] * n2[0] + n1[1] * n2[1];
        const d: f64 = @floatFromInt(inset);
        const k = geom.fmin(d / geom.fmax(1 + dot, 1e-9), 3 * d / geom.fmax(@import("geom.zig").hypot(n1[0] + n2[0], n1[1] + n2[1]), 1e-9));
        return .{
            .x = v.x + @as(i64, @intFromFloat(geom.round((n1[0] + n2[0]) * k))),
            .y = v.y + @as(i64, @intFromFloat(geom.round((n1[1] + n2[1]) * k))),
        };
    }

    fn unit(a: geom.Point, b: geom.Point) [2]f64 {
        const dx: f64 = @floatFromInt(b.x - a.x);
        const dy: f64 = @floatFromInt(b.y - a.y);
        const l = geom.fmax(@import("geom.zig").hypot(dx, dy), 1e-9);
        return .{ dx / l, dy / l };
    }

    fn dist(a: geom.Point, b: geom.Point) f64 {
        return @import("geom.zig").hypot(geom.toMm(a.x - b.x), geom.toMm(a.y - b.y));
    }

    /// `combClear`, with the combing index if the emitter has one.
    fn clearOf(self: *const Emitter, outline: geom.Paths, boxes: []const [4]i64, a: geom.Point, b: geom.Point, hit: *usize) bool {
        if (self.comb_index) |idx| return idx.clear(a, b, hit);
        return combClear(outline, boxes, a, b, hit);
    }

    /// True if the segment a-b crosses no edge of the outline and its middle
    /// is inside. Else `hit` is the polygon of the first crossed edge.
    /// `boxes` (x0, y0, x1, y1 of each polygon, or empty) skips the polygons
    /// far from the segment.
    fn combClear(outline: geom.Paths, boxes: []const [4]i64, a: geom.Point, b: geom.Point, hit: *usize) bool {
        hit.* = std.math.maxInt(usize);
        const lo_x = @min(a.x, b.x);
        const hi_x = @max(a.x, b.x);
        const lo_y = @min(a.y, b.y);
        const hi_y = @max(a.y, b.y);
        const m: geom.Point = .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2) };
        var winding: i32 = 0;
        for (0..outline.count()) |k| {
            const poly = outline.get(k);
            if (boxes.len == outline.count()) {
                const bx = boxes[k];
                // The winding at m needs the polygons right of m in its y
                // band; the crossings need the polygons that touch the box.
                const touch = !(bx[2] < lo_x or bx[0] > hi_x or bx[3] < lo_y or bx[1] > hi_y);
                const ray = bx[2] >= m.x and bx[1] <= m.y and bx[3] >= m.y;
                if (!touch and !ray) continue;
            }
            for (poly, 0..) |c, i| {
                const e = poly[(i + 1) % poly.len];
                const s1 = std.math.sign(geom.cross3(a, b, c));
                const s2 = std.math.sign(geom.cross3(a, b, e));
                if (s1 * s2 < 0) {
                    const s3 = std.math.sign(geom.cross3(c, e, a));
                    const s4 = std.math.sign(geom.cross3(c, e, b));
                    if (s3 * s4 < 0) {
                        hit.* = k;
                        return false;
                    }
                }
                if (c.y <= m.y) {
                    if (e.y > m.y and geom.cross3(c, e, m) > 0) winding += 1;
                } else if (e.y <= m.y and geom.cross3(c, e, m) < 0) winding -= 1;
            }
        }
        return winding != 0;
    }

    fn extrude(self: *Emitter, x: f64, y: f64, e_per_mm: f64, speed: f64) Error!void {
        return self.extrudeLen(x, y, @import("geom.zig").hypot(x - self.x, y - self.y), e_per_mm, speed);
    }

    /// `extrude`, with `d`, the distance from the nozzle to x, y.
    fn extrudeLen(self: *Emitter, x: f64, y: f64, d: f64, e_per_mm: f64, speed: f64) Error!void {
        if (d < 1e-4) return;
        try self.unretract();
        const e = d * e_per_mm;
        var line: Line = .{ .skip = self.dry };
        line.add("G1 X");
        line.num(x + self.r.settings.machine.origin_x, 3);
        line.add(" Y");
        line.num(y + self.r.settings.machine.origin_y, 3);
        line.add(" E");
        line.num(e, 5);
        self.addFeed(&line, speed);
        line.add("\n");
        try line.put(self.w);
        try self.addMove(x - self.x, y - self.y, d, speed, e_per_mm);
        self.x = x;
        self.y = y;
        try self.addFilament(e);
        self.extruded = true;
    }

    /// `writeFeed`, into a line.
    fn addFeed(self: *Emitter, line: *Line, speed: f64) void {
        const f = geom.round(speed * 60);
        if (f == self.feed) return;
        self.feed = f;
        line.add(" F");
        line.num(f, 0);
    }

    fn writeFeed(self: *Emitter, speed: f64) Writer.Error!void {
        const f = geom.round(speed * 60);
        if (f == self.feed) return;
        self.feed = f;
        try self.w.writeAll(" F");
        try writeNum(self.w, f, 0);
    }

    /// Writes a start or an end G-code with the values of its variables
    /// (see gcode_vars.zig), and tells the temperatures that it sets.
    /// The layer change of a Bambu Lab printer, as Bambu Studio writes it:
    /// the markers of the layer, then the layer change G-code of the maker
    /// (its fans of the chamber, and M73 L and M991, which tell the printer
    /// each new layer: its progress and its first layer inspection).
    fn bambuLayer(self: *Emitter, lp: *const LayerPlan) Writer.Error!void {
        if (!self.bambu_blocks) return;
        const s = self.r.settings;
        const text = @import("printers.zig").bambuTemplate(s.machine.model, .layer) orelse return;
        // The progress and the time left, for the screen of the printer: a
        // field of fixed width that finishBambuProgress fills in after the
        // slice, when the times of all layers are known.
        try self.w.writeAll(progress_blank ++ "\n");
        try self.w.writeAll("; CHANGE_LAYER\n; Z_HEIGHT: ");
        try writeNum(self.w, lp.z, 3);
        try self.w.writeAll("\n; LAYER_HEIGHT: ");
        try writeNum(self.w, lp.height, 3);
        try self.w.writeByte('\n');
        const ctx: gcode_vars.Context = .{
            .r = self.r,
            .phase = .start,
            .layer_count = self.layer_count,
            .layer_z = lp.z,
            .layer_index = lp.index,
            .slots = self.slots,
            .tool = self.tool,
            .first_layer_box = self.first_layer_box,
        };
        _ = gcode_vars.render(self.gpa, self.w, text, &ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.WriteFailed,
            error.WriteFailed => return error.WriteFailed,
        };
        try self.w.writeByte('\n');
    }

    fn writeTemplate(self: *Emitter, w: *Writer, text: []const u8, phase: gcode_vars.Phase) Writer.Error!gcode_vars.Result {
        const s = self.r.settings;
        const n = self.layer_count;
        // The top of the print: in the end G-code, the z of the nozzle.
        const top = if (n == 0) 0 else s.project.first_layer_height + @as(f64, @floatFromInt(n - 1)) * s.project.layer_height;
        const ctx: gcode_vars.Context = .{
            .r = self.r,
            .phase = phase,
            .layer_count = n,
            .max_layer_z = if (phase == .end) self.z else top,
            .layer_z = if (phase == .end) self.z else 0,
            .first_layer_box = self.first_layer_box,
            .object_model = s.machine.gcode_flavor == .reprap,
            .filament_mm = self.stats.filament_mm,
            .filament_g = self.stats.filament_g,
            .print_time_s = self.stats.print_time_s,
        };
        return gcode_vars.render(self.gpa, w, text, &ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.WriteFailed,
            error.WriteFailed => return error.WriteFailed,
        };
    }
};

/// A text for a comment line, with a space for each line end. A name of
/// an imported profile with a line end would start a command of its own.
const OneLine = struct {
    text: []const u8,
    pub fn format(o: OneLine, w: *Writer) Writer.Error!void {
        for (o.text) |c| try w.writeByte(if (c == '\n' or c == '\r') ' ' else c);
    }
};

fn oneLine(text: []const u8) OneLine {
    return .{ .text = text };
}

/// The fan value of the emitter (-1: not set yet) as a byte.
fn fanByte(fan: i32) u8 {
    return @intCast(std.math.clamp(fan, 0, 255));
}

/// The name of a feature in the G-code of Bambu Studio ("; FEATURE: ").
fn studioName(f: Feature) []const u8 {
    return switch (f) {
        .outer_wall => "Outer wall",
        .inner_wall => "Inner wall",
        .skin => "Internal solid infill",
        .infill => "Sparse infill",
        .ironing, .slope_ironing => "Ironing",
        .skirt => "Skirt",
        .support => "Support",
        .support_interface => "Support interface",
        .slope_smoothing => "Top surface",
        .bridge => "Bridge",
    };
}

fn typeName(f: Feature) []const u8 {
    return switch (f) {
        .outer_wall => "WALL-OUTER",
        .inner_wall => "WALL-INNER",
        .skin => "SKIN",
        .infill => "FILL",
        .ironing => "IRONING",
        .skirt => "SKIRT",
        .support => "SUPPORT",
        .support_interface => "SUPPORT-INTERFACE",
        .slope_smoothing => "SLOPE-SMOOTHING",
        .slope_ironing => "SLOPE-IRONING",
        .bridge => "BRIDGE",
    };
}

/// Writes v with at most `decimals` decimal places and no trailing zeros.
/// It uses integer math: it is faster than the general float formatter,
/// and G-code needs no more than 5 decimal places.
pub fn writeNum(w: *Writer, v: f64, comptime decimals: u5) Writer.Error!void {
    var line: Line = .{};
    line.num(v, decimals);
    try w.writeAll(line.text());
}

/// "00" to "99", for two digits at a time.
const digit_pairs: [200]u8 = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + i / 10;
        t[2 * i + 1] = '0' + i % 10;
    }
    break :blk t;
};

/// A line of G-code on the stack. A move goes to the writer in one call,
/// and not in one call for each word and number.
const Line = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    /// True in a dry run: the line stays empty.
    skip: bool = false,

    fn text(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }

    fn add(l: *Line, t: []const u8) void {
        if (l.skip) return;
        @memcpy(l.buf[l.len..][0..t.len], t);
        l.len += t.len;
    }

    /// Adds the first `n` bytes of `t`. A copy with a length that is known
    /// only when the code runs is a call into the host in wasm. A copy of
    /// a fixed size is a few moves. So this copies all of `t`, and counts
    /// only `n` bytes.
    fn addDigits(l: *Line, t: *const [digit_room]u8, n: usize) void {
        if (l.skip) return;
        if (l.len + digit_room <= l.buf.len) {
            l.buf[l.len..][0..digit_room].* = t.*;
        } else {
            @memcpy(l.buf[l.len..][0..n], t[0..n]);
        }
        l.len += n;
    }

    /// The most digits of a number.
    const digit_room = 24;

    /// Writes the line to `w` (see `addDigits`: the copy has a fixed size
    /// if the buffer of the writer has room for it).
    fn put(l: *const Line, w: *Writer) Writer.Error!void {
        if (w.buffer.len - w.end >= l.buf.len) {
            w.buffer[w.end..][0..l.buf.len].* = l.buf;
            w.end += l.len;
        } else {
            try w.writeAll(l.text());
        }
    }

    /// v with at most `decimals` decimal places and no trailing zeros (see
    /// `writeNum`). The digits of the scaled integer go into a buffer from
    /// the end, two at a time from a table.
    fn num(l: *Line, v: f64, comptime decimals: u5) void {
        if (l.skip) return;
        const scale: f64 = comptime blk: {
            var p: f64 = 1;
            for (0..decimals) |_| p *= 10;
            break :blk p;
        };
        var n: i64 = @intFromFloat(geom.round(v * scale));
        if (n < 0) {
            l.add("-");
            n = -n;
        }
        var u: u64 = @intCast(n);
        // At least decimals + 1 digits, with leading zeros. The digits are
        // in the first half of the buffer. The second half is room for the
        // fixed size copies of `addDigits`.
        var buf: [2 * digit_room]u8 = undefined;
        const digits = buf[0..digit_room];
        var at: usize = digits.len;
        while (u >= 100) {
            const pair: usize = @intCast((u % 100) * 2);
            u /= 100;
            at -= 2;
            digits[at..][0..2].* = digit_pairs[pair..][0..2].*;
        }
        if (u >= 10) {
            at -= 2;
            digits[at..][0..2].* = digit_pairs[@as(usize, @intCast(u)) * 2 ..][0..2].*;
        } else {
            at -= 1;
            digits[at] = '0' + @as(u8, @intCast(u));
        }
        while (digits.len - at < decimals + 1) {
            at -= 1;
            digits[at] = '0';
        }
        const int_end = digits.len - decimals;
        l.addDigits(buf[at..][0..digit_room], int_end - at);
        if (decimals == 0) return;
        var frac_end: usize = digits.len;
        while (frac_end > int_end and digits[frac_end - 1] == '0') frac_end -= 1;
        if (frac_end == int_end) return;
        l.add(".");
        l.addDigits(buf[int_end..][0..digit_room], frac_end - int_end);
    }
};

test "a name with a line end stays in its comment line" {
    const gpa = std.testing.allocator;
    var m = try @import("mesh.zig").shapes.box(gpa, 5, 5, 1);
    defer m.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: @import("settings.zig").Settings = .{};
    s.engine.threads = 1;
    s.machine.name = "TAZ\nM104 S350";
    s.filament.name = "PLA\rG28 X";
    _ = try @import("engine.zig").slice(gpa, &m, s, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(!std.mem.startsWith(u8, line, "M104 S350"));
        try std.testing.expect(!std.mem.startsWith(u8, line, "G28 X"));
    }
    try std.testing.expect(std.mem.indexOf(u8, text, ";MACHINE:TAZ M104 S350\n") != null);
}

test "a filament material or color with a line end stays in the Bambu config block" {
    const gpa = std.testing.allocator;
    var m = try @import("mesh.zig").shapes.box(gpa, 5, 5, 1);
    defer m.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: @import("settings.zig").Settings = .{};
    s.engine.threads = 1;
    s.machine.model = "bambu-lab-x2d";
    s.filament.material = "PLA\nM104 S350";
    s.filament.color = "#ffffff\rG28 X";
    _ = try @import("engine.zig").slice(gpa, &m, s, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "; CONFIG_BLOCK_START\n") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(!std.mem.startsWith(u8, line, "M104 S350"));
        try std.testing.expect(!std.mem.startsWith(u8, line, "G28 X"));
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "; filament_type = PLA M104 S350\n") != null);
}

test "writeNum" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeNum(&w, 110.0, 3);
    try w.writeByte(' ');
    try writeNum(&w, 1.23456, 3);
    try w.writeByte(' ');
    try writeNum(&w, -0.5, 4);
    try w.writeByte(' ');
    try writeNum(&w, 0.000004, 5);
    try w.writeByte(' ');
    try writeNum(&w, 3600, 0);
    try std.testing.expectEqualStrings("110 1.235 -0.5 0 3600", w.buffered());
}

test "the combing index gives the same answers as combClear" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A square with two holes, and a triangle.
    var outline: geom.Paths = .empty;
    try outline.append(a, &.{ .init(0, 0), .init(40_000, 0), .init(40_000, 30_000), .init(0, 30_000) });
    try outline.append(a, &.{ .init(5000, 5000), .init(5000, 12_000), .init(15_000, 12_000), .init(15_000, 5000) });
    try outline.append(a, &.{ .init(25_000, 10_000), .init(28_000, 20_000), .init(32_000, 9000) });
    try outline.append(a, &.{ .init(45_000, 0), .init(60_000, 2000), .init(50_000, 25_000) });
    const idx = try CombIndex.init(a, outline);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..20_000) |k| {
        // Random points, and points on the vertices and the grid lines.
        var pts: [2]geom.Point = undefined;
        for (&pts) |*p| {
            p.* = if (k % 3 == 0)
                outline.points.items[rnd.uintLessThan(usize, outline.points.items.len)]
            else
                .init(rnd.intRangeAtMost(i64, -2000, 62_000), rnd.intRangeAtMost(i64, -2000, 32_000));
        }
        var h1: usize = 0;
        var h2: usize = 0;
        const want = Emitter.combClear(outline, &.{}, pts[0], pts[1], &h1);
        const got = idx.clear(pts[0], pts[1], &h2);
        try std.testing.expectEqual(want, got);
        if (!want) try std.testing.expectEqual(h1, h2);
    }
}

test "combing goes along a round ring, where the box of the hole is outside the part" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A ring: outer radius 20 mm, hole radius 18 mm. The corners of the
    // box of the hole are outside the outer circle.
    var outline: geom.Paths = .empty;
    const n = 96;
    var outer: [n]geom.Point = undefined;
    var hole: [n]geom.Point = undefined;
    for (0..n) |i| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / n;
        outer[i] = .{ .x = geom.fromMm(50 + 20 * @cos(t)), .y = geom.fromMm(50 + 20 * @sin(t)) };
        // The hole goes clockwise.
        hole[i] = .{ .x = geom.fromMm(50 + 18 * @cos(-t)), .y = geom.fromMm(50 + 18 * @sin(-t)) };
    }
    try outline.append(a, &outer);
    try outline.append(a, &hole);
    var r = try (settings_mod.Settings{}).resolve();
    r.settings.project.combing = true;
    var discard: Writer.Discarding = .init(&.{});
    var em: Emitter = .init(gpa, &discard.writer, &r);
    em.outline = &outline;
    em.width = 0.4;
    em.n_boxes = 2;
    for (0..2) |k| {
        var bx = [4]i64{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
        for (outline.get(k)) |q| bx = .{ @min(bx[0], q.x), @min(bx[1], q.y), @max(bx[2], q.x), @max(bx[3], q.y) };
        em.boxes[k] = bx;
    }
    // From the left side of the ring to a point on the upper right.
    em.x = 31;
    em.y = 50;
    const x: f64 = 50 + 19 * @cos(1.0);
    const y: f64 = 50 + 19 * @sin(1.0);
    const d = @import("geom.zig").hypot(x - em.x, y - em.y);
    var way: [max_way][2]f64 = undefined;
    try std.testing.expect(em.comb(x, y, d, &way, false) == null);
    const k = em.comb(x, y, d, &way, true) orelse return error.TestUnexpectedResult;
    try std.testing.expect(k > 0);
    // Each leg stays in the ring.
    var p: geom.Point = .{ .x = geom.fromMm(em.x), .y = geom.fromMm(em.y) };
    for (0..k + 1) |i| {
        const q: geom.Point = if (i < k) .{ .x = geom.fromMm(way[i][0]), .y = geom.fromMm(way[i][1]) } else .{ .x = geom.fromMm(x), .y = geom.fromMm(y) };
        var hit: usize = 0;
        try std.testing.expect(Emitter.combClear(outline, em.boxes[0..2], p, q, &hit));
        p = q;
    }
}

test "a path with a width for each point extrudes the bead of each segment" {
    const gpa = std.testing.allocator;
    const r = try (settings_mod.Settings{}).resolve();
    var lp: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.9, .height = 0.2, .width = 0.44, .resolved = &r };
    defer lp.deinit();
    const a = lp.arena.allocator();
    // An open line of two 10 mm segments: 0.4 mm to 0.6 mm, then 0.6 mm.
    try lp.outline.append(a, &.{ .{ .x = 0, .y = -5000 }, .{ .x = 30000, .y = -5000 }, .{ .x = 30000, .y = 5000 }, .{ .x = 0, .y = 5000 } });
    try lp.points.append(a, &.{ .{ .x = 0, .y = 0 }, .{ .x = 10000, .y = 0 }, .{ .x = 20000, .y = 0 } });
    try lp.point_w.appendSlice(a, &.{ 0.4, 0.6, 0.6 });
    try lp.paths.append(a, .{ .feature = .inner_wall, .closed = false, .w_start = 0 });
    var discard: Writer.Discarding = .init(&.{});
    var em: Emitter = .init(gpa, &discard.writer, &r);
    em.x = 0;
    em.y = 0;
    em.extruded = true;
    try em.layer(&lp);
    const want = 10 * (flow.beadArea(0.5, 0.2) + flow.beadArea(0.6, 0.2)) / r.filament_area * r.settings.filament.flow_ratio;
    // The widths are f32.
    try std.testing.expectApproxEqRel(want, em.stats.filament_mm, 1e-6);
}

test "a travel between tree support paths retracts only if it crosses the part" {
    const gpa = std.testing.allocator;
    const Case = struct { style: settings_mod.SupportStyle, wall: bool, retractions: u32 };
    const cases = [_]Case{
        .{ .style = .tree, .wall = false, .retractions = 0 },
        .{ .style = .grid, .wall = false, .retractions = 1 },
        .{ .style = .tree, .wall = true, .retractions = 1 },
    };
    for (cases) |c| {
        var st: settings_mod.Settings = .{};
        st.project.support_style = c.style;
        const r = try st.resolve();
        var lp: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.9, .height = 0.2, .width = 0.5, .resolved = &r };
        defer lp.deinit();
        const a = lp.arena.allocator();
        // A wall of the part between the two support loops, or a part
        // far away.
        const x0: i64 = if (c.wall) 9000 else 50000;
        try lp.outline.append(a, &.{ .{ .x = x0, .y = -50000 }, .{ .x = x0 + 2000, .y = -50000 }, .{ .x = x0 + 2000, .y = 50000 }, .{ .x = x0, .y = 50000 } });
        for ([_]i64{ 0, 20000 }) |x| {
            try lp.points.append(a, &.{ .{ .x = x, .y = 0 }, .{ .x = x + 1000, .y = 0 }, .{ .x = x + 1000, .y = 1000 }, .{ .x = x, .y = 1000 } });
            try lp.paths.append(a, .{ .feature = .support, .closed = true });
        }
        var discard: Writer.Discarding = .init(&.{});
        var em: Emitter = .init(gpa, &discard.writer, &r);
        em.x = 0;
        em.y = 0;
        em.extruded = true;
        try em.layer(&lp);
        try std.testing.expectEqual(c.retractions, em.stats.retractions);
    }
}

test "maker template: an old X2D start G-code of a profile becomes the current one" {
    const old = ";======== X2D start gcode==========\n;===== 2026/06/05 =====\nM140 S60\n";
    const now = Emitter.makerTemplate("bambu-lab-x2d", old, .start);
    try std.testing.expect(std.mem.indexOf(u8, now, "2026/10/20") != null);
    // A start G-code of the user stays.
    const mine = "G28\nM109 S210\n";
    try std.testing.expectEqualStrings(mine, Emitter.makerTemplate("bambu-lab-x2d", mine, .start));
    // Another printer: as it is.
    try std.testing.expectEqualStrings(old, Emitter.makerTemplate("creality-ender-3", old, .start));
}

test "bambu header: a print time of no finite value fills its field" {
    const head = "; HEADER_BLOCK_START\n; model printing time: " ++ Emitter.blank16 ++ "\n; HEADER_BLOCK_END\n";
    var buf: [head.len]u8 = head.*;
    for ([_]f64{ std.math.inf(f64), std.math.nan(f64), 1e300 }) |sec| {
        var st: Stats = .{};
        st.print_time_s = sec;
        Emitter.finishBambuHeader(&buf, st, 1, 2.405, 1);
        try std.testing.expectEqual(head.len, buf.len);
    }
}

test "bambu header: the times, the filament, and the top fill their fields" {
    const gpa = std.testing.allocator;
    const head = "; HEADER_BLOCK_START\n; zslice\n; model printing time: " ++ Emitter.blank16 ++ "; total estimated time: " ++ Emitter.blank16 ++ "\n; total layer number: 10\n; total filament length [mm] : " ++ Emitter.blank64 ++ "\n; total filament volume [cm^3] : " ++ Emitter.blank64 ++ "\n; total filament weight [g] : " ++ Emitter.blank64 ++ "\n; max_z_height: " ++ Emitter.blank16 ++ "\n; HEADER_BLOCK_END\n";
    const text = try gpa.dupe(u8, head);
    defer gpa.free(text);
    var st: Stats = .{};
    st.print_time_s = 4363;
    st.slot_mm[0] = 12491.95;
    st.slot_mm[1] = 227.74;
    st.slot_g[0] = 37.26;
    st.slot_g[1] = 0.68;
    Emitter.finishBambuHeader(text, st, 2, 2.405, 31.08);
    try std.testing.expectEqual(head.len, text.len);
    try std.testing.expect(std.mem.indexOf(u8, text, "; model printing time: 1h 12m 43s") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "; total filament weight [g] : 37.26,0.68 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "; max_z_height: 31.08 ") != null);
}

test "bambu progress: each layer gets its percent and its minutes left" {
    const gpa = std.testing.allocator;
    const p = Emitter.progress_blank;
    const head = "; HEADER_BLOCK_START\n; HEADER_BLOCK_END\n;LAYER:0\n" ++ p ++ "\nG1\n;LAYER:1\n" ++ p ++ "\nG1\n";
    const text = try gpa.dupe(u8, head);
    defer gpa.free(text);
    Emitter.finishBambuProgress(text, &.{ 0, 1800 }, 3600);
    try std.testing.expectEqual(head.len, text.len);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nM73 P0 R60 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nM73 P50 R30 ") != null);
}
