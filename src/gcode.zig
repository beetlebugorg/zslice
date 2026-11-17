//! G-code output: from layer plans to printer commands.
//!
//! - A travel move (G0) goes to the start of each path. A travel longer
//!   than `retract_min_travel` first pulls the filament back (retraction),
//!   so that the nozzle does not ooze on the way.
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
//! - Comments mark each layer (";LAYER:n") and each feature
//!   (";TYPE:WALL-OUTER"). These follow the CuraEngine convention (see
//!   REFERENCES.md), which G-code viewers and printdeck read.
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

        pub const retract: i32 = -1;
        pub const unknown: i32 = -2;
    };

    pub fn clear(t: *Prepared) void {
        t.paths.clearRetainingCapacity();
        t.way_points.clearRetainingCapacity();
        t.lengths.clearRetainingCapacity();
        t.index = null;
        if (t.arena) |*a| _ = a.reset(.retain_capacity);
        t.plan_moves.clearRetainingCapacity();
        t.have_plan = false;
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
        const cell = @max(@sqrt(w * h / @as(f64, @floatFromInt(n))), 1);
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
        const lo_x = @min(px, qx) - margin;
        const hi_x = @max(px, qx) + margin;
        const last_col: f64 = @floatFromInt(idx.cols - 1);
        const last_row: f64 = @floatFromInt(idx.rows - 1);
        const c0 = @floor((lo_x - idx.x0) / idx.cell);
        const c1 = @floor((hi_x - idx.x0) / idx.cell);
        if (c1 < 0 or c0 > last_col) return;
        const first: usize = @intFromFloat(@max(c0, 0));
        const end: usize = @intFromFloat(@min(c1, last_col));
        const dx = qx - px;
        for (first..end + 1) |cx| {
            const col_lo = idx.x0 + @as(f64, @floatFromInt(cx)) * idx.cell;
            var ya = py;
            var yb = qy;
            if (dx != 0) {
                const xa = std.math.clamp(col_lo, @min(px, qx), @max(px, qx));
                const xb = std.math.clamp(col_lo + idx.cell, @min(px, qx), @max(px, qx));
                ya = py + (xa - px) * (qy - py) / dx;
                yb = py + (xb - px) * (qy - py) / dx;
            }
            const r0 = @floor((@min(ya, yb) - margin - idx.y0) / idx.cell);
            const r1 = @floor((@max(ya, yb) + margin - idx.y0) / idx.cell);
            if (r1 < 0 or r0 > last_row) continue;
            const ry0: usize = @intFromFloat(@max(r0, 0));
            const ry1: usize = @intFromFloat(@min(r1, last_row));
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
            const d = std.math.hypot(x - em.x, y - em.y);
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
    }
    // Room for the way of the first travel, which the dry run adds.
    try out.way_points.ensureUnusedCapacity(gpa, max_way);
}

pub const Error = Writer.Error || std.mem.Allocator.Error;

pub const Emitter = struct {
    /// The memory of the move list of a layer.
    gpa: std.mem.Allocator,
    /// The first pass of `layer`: each move goes into this list, and its
    /// time comes later from the planner.
    collect: ?*std.ArrayList(motion.Move) = null,
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

    pub fn init(gpa: std.mem.Allocator, w: *Writer, r: *const Resolved) Emitter {
        return .{ .gpa = gpa, .w = w, .r = r, .lr = r };
    }

    pub fn begin(self: *Emitter, layer_count: usize) Writer.Error!void {
        const s = self.r.settings;
        try self.w.print(";FLAVOR:Marlin\n;Generated by zslice\n", .{});
        try self.w.print(";MACHINE:{s}\n;FILAMENT:{s}\n", .{ s.machine.name, s.filament.name });
        try self.w.print(";LAYER_COUNT:{d}\n", .{layer_count});
        try self.writeTemplate(s.machine.start_gcode);
        try self.w.writeAll("\nM83 ; relative extrusion\nM107\n");
        self.fan = 0;
        // The corner speed, once, with acceleration control.
        const m = s.machine;
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
        };
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
        }
        try writeNum(self.w, a, 0);
        try self.w.writeAll("\n");
    }

    /// The time of an XY move of length d at speed v: in the first pass,
    /// the move goes into the list; in the second pass, its planned time
    /// goes into the statistics.
    fn addMove(self: *Emitter, dx: f64, dy: f64, d: f64, v: f64, e_ratio: f64) Error!void {
        const a = if (self.accel > 0) self.accel else self.r.settings.machine.max_accel;
        if (self.collect) |list| {
            try list.append(self.gpa, .{ .dir = .{ dx / d, dy / d }, .len = d, .speed = v, .accel = a, .e_ratio = e_ratio, .stop_before = self.stop });
        } else if (self.next_move < self.planned.len) {
            self.stats.print_time_s += self.planned[self.next_move].time;
            self.next_move += 1;
        } else {
            self.stats.print_time_s += motion.restTime(d, v, a);
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
            .marlin => .{ .corner_speed = m.corner_speed, .min_cruise_ratio = 0, .extruder_corner_speed = 5 },
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
            .marlin => 1,
        };
        return motion.restTime(len, m.retract_speed, m.max_accel * ratio);
    }

    /// A Z move from rest to rest.
    fn zMove(self: *Emitter, dz: f64) void {
        const m = self.r.settings.machine;
        self.stats.print_time_s += motion.restTime(@abs(dz), m.max_z_speed, m.max_z_accel);
        self.stop = true;
    }

    pub fn end(self: *Emitter) Writer.Error!void {
        try self.retract();
        try self.writeTemplate(self.r.settings.machine.end_gcode);
        try self.w.writeAll("\n");
        const st = &self.stats;
        const r = self.r.settings.filament.diameter / 2;
        const volume_cm3 = st.filament_mm * std.math.pi * r * r / 1000.0;
        st.filament_g = volume_cm3 * self.r.settings.filament.density;
        try self.w.writeAll(";Filament used: ");
        try writeNum(self.w, st.filament_mm / 1000.0, 3);
        try self.w.writeAll("m\n;Filament weight: ");
        try writeNum(self.w, st.filament_g, 2);
        try self.w.writeAll("g\n;Estimated time: ");
        try writeNum(self.w, st.print_time_s, 0);
        try self.w.writeAll("s\n");
        try self.writeSettings();
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
        // The temperatures: the start G-code sets the values of the first
        // layer. A layer with other values sets them, with no wait.
        const nozzle = if (lp.index == 0) g.filament.first_layer_nozzle_temp else s.filament.nozzle_temp;
        if (nozzle != (self.nozzle_temp orelse g.filament.first_layer_nozzle_temp)) {
            try self.w.writeAll("M104 S");
            try writeNum(self.w, nozzle, 0);
            try self.w.writeAll("\n");
        }
        self.nozzle_temp = nozzle;
        if (s.filament.bed_temp != (self.bed_temp orelse g.filament.bed_temp)) {
            try self.w.writeAll("M140 S");
            try writeNum(self.w, s.filament.bed_temp, 0);
            try self.w.writeAll("\n");
        }
        self.bed_temp = s.filament.bed_temp;
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
        var moves: std.ArrayList(motion.Move) = .empty;
        defer moves.deinit(self.gpa);
        var discard: Writer.Discarding = .init(&.{});
        var probe = self.*;
        probe.w = &discard.writer;
        probe.dry = true;
        probe.record = null;
        probe.collect = &moves;
        probe.keep_ways = self.dry;
        try probe.paths(lp, 1, false);
        const lim = self.limits();
        const fixed = probe.stats.print_time_s - self.stats.print_time_s;
        const layer_time = fixed + motion.plan(moves.items, lim);

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
                        return motion.plan(ms, l);
                    }
                }.at;
                const want = s.filament.min_layer_time - fixed;
                var lo: f64 = 0;
                var hi: f64 = 1;
                if (time(moves.items, full, lo, s.filament.min_speed, lim) >= want) {
                    for (0..24) |_| {
                        const mid = (lo + hi) / 2;
                        if (time(moves.items, full, mid, s.filament.min_speed, lim) >= want) lo = mid else hi = mid;
                    }
                }
                slow = lo;
                _ = time(moves.items, full, slow, s.filament.min_speed, lim);
            }
        }

        // The dry run keeps the plan for the text run.
        if (self.dry) if (self.prep) |pr| {
            pr.plan_moves.clearRetainingCapacity();
            try pr.plan_moves.appendSlice(self.gpa, moves.items);
            pr.plan_slow = slow;
            pr.plan_time = layer_time;
            pr.have_plan = true;
        };
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

    /// The fan of a layer: off on the first layers, the boost speed on a
    /// layer that prints in less than `fan_boost_time`, else the fan speed.
    fn coolingFan(self: *Emitter, lp: *const LayerPlan, layer_time: f64) Error!void {
        const g = self.r.settings;
        const s = self.lr.settings;
        const ratio = if (lp.index < g.filament.fan_off_layers)
            0
        else if (layer_time < s.filament.fan_boost_time)
            s.filament.fan_max_speed
        else
            s.filament.fan_speed;
        self.layer_fan = @intFromFloat(@round(255 * ratio));
        try self.setFan(self.layer_fan);
    }

    /// The speed of an extrusion with the full speed `full` on a layer that
    /// prints slower by the ratio `k` < 1 (see `layer`).
    fn slowSpeed(full: f64, k: f64, min_speed: f64) f64 {
        return if (k < 1) @max(full * k, @min(full, min_speed)) else full;
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
        self.zMove(lp.z - self.z);
        self.z = lp.z;
        try self.w.writeAll("G0 Z");
        try writeNum(self.w, self.z, 3);
        try self.w.writeAll(" F");
        try writeNum(self.w, s.machine.max_z_speed * 60, 0);
        try self.w.writeAll("\n");
        self.feed = -1;
        self.stats.layer_count += 1;

        // The filament length for 1 mm of line.
        const e_per_mm = flow.beadArea(lp.width, lp.height) / self.r.filament_area * s.filament.flow_ratio;

        for (lp.paths.items, 0..) |path, i| {
            const pts = lp.points.get(i);
            if (pts.len == 0) {
                if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = self.stats.print_time_s, .end_time = self.stats.print_time_s, .area = 0 });
                continue;
            }
            const retractions = self.stats.retractions;
            try self.setAccel(lr.accel(null, first));
            self.path_index = i;
            try self.travel(geom.toMm(pts[0].x), geom.toMm(pts[0].y));
            self.layer_start = false;
            // A path in a modifier volume has the settings of the volume.
            const path_r = lp.pathResolved(path) orelse lr;
            try self.setAccel(path_r.accel(path.feature, first));
            const retracted = self.stats.retractions != retractions;
            if (self.feature != path.feature) {
                self.feature = path.feature;
                if (!self.dry) try self.w.print(";TYPE:{s}\n", .{typeName(path.feature)});
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
            for (widths) |pw| speed_width = @max(speed_width, pw);
            // The layer index in the job of the part, for the speed ramp of
            // the first layers (see LayerPlan.layerOf).
            const full = path_r.speedAt(path.feature, speed_width, h, lp.layerOf(path));
            const speed = slowSpeed(full, slow, s.filament.min_speed);
            const start_time = self.stats.print_time_s;
            // Ironing lines use a fraction of the flow of a normal line.
            // A path with its own width (a thin wall) or height has its own
            // flow.
            // The flow ratio of the part of the path (see LayerPlan.append).
            const fr = path_r.settings.filament.flow_ratio;
            const base_e = if (path.width > 0 or path.height > 0) flow.beadArea(if (path.width > 0) path.width else lp.width, h) / self.r.filament_area * fr else if (fr == s.filament.flow_ratio) e_per_mm else flow.beadArea(lp.width, lp.height) / self.r.filament_area * fr;
            const e = switch (path.feature) {
                .ironing => base_e * path_r.settings.project.ironing_flow,
                .infill => base_e * path_r.settings.project.infill_flow,
                .bridge => base_e * path_r.settings.project.bridge_flow,
                else => base_e,
            };
            const x0 = geom.toMm(pts[0].x);
            const y0 = geom.toMm(pts[0].y);
            if (path.z_start != layer_mod.Path.planar) {
                const area = try self.nonPlanar(lp, path, pts, speed, fr);
                if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = start_time, .end_time = self.stats.print_time_s, .area = area, .retracted = retracted, .slowed = slow < 1 or lapped });
                continue;
            }
            if (widths.len > 0) {
                // The width of each segment is the mean of its ends.
                const e_scale = fr / self.r.filament_area;
                var area_len: f64 = 0;
                var len_sum: f64 = 0;
                const n = pts.len + @as(usize, @intFromBool(path.closed and pts.len > 2));
                for (1..n) |k| {
                    const j = k % pts.len;
                    const sw = (@as(f64, widths[k - 1]) + widths[j]) / 2;
                    const area = flow.beadArea(sw, h);
                    const x = geom.toMm(pts[j].x);
                    const y = geom.toMm(pts[j].y);
                    const d = std.math.hypot(x - self.x, y - self.y);
                    area_len += area * d;
                    len_sum += d;
                    try self.extrudeLen(x, y, d, area * e_scale, speed);
                }
                const mean_area = if (len_sum > 0) area_len / len_sum else flow.beadArea(widths[0], h);
                if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = start_time, .end_time = self.stats.print_time_s, .area = mean_area * fr, .retracted = retracted, .slowed = slow < 1 or lapped });
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
            if (self.record) |rec| rec.appendAssumeCapacity(.{ .start_time = start_time, .end_time = self.stats.print_time_s, .area = e * self.r.filament_area, .retracted = retracted, .slowed = slow < 1 or lapped });
        }
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
            if (@abs(dz) > 0) v = @min(v, m.max_z_speed * d / @abs(dz));
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
            try self.w.writeAll(line.text());
            const accel = if (self.accel > 0) self.accel else m.max_accel;
            const a = if (@abs(dz) > 0) @min(accel, m.max_z_accel * d / @abs(dz)) else accel;
            try self.addMove3(dx, dy, dz, d, v, a, e / d);
            self.x = x;
            self.y = y;
            cz = z;
            self.stats.filament_mm += e;
            len_sum += d;
            area_sum += d * area;
        }
        self.extruded = true;
        try self.zTo(self.z);
        return if (len_sum > 0) area_sum / len_sum * flow_ratio else data[0].area * flow_ratio;
    }

    /// A Z move to z, from rest to rest, with no extrusion. The emitter
    /// keeps `self.z` as the z of the layer.
    fn zTo(self: *Emitter, z: f64) Writer.Error!void {
        // The nozzle is at the z of the layer, or at the z of the last
        // point of a path that is not planar.
        const from = self.nozzle_z orelse self.z;
        if (@abs(z - from) < 1e-6) return;
        self.zMove(z - from);
        const f = @round(self.r.settings.machine.max_z_speed * 60);
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
    fn addMove3(self: *Emitter, dx: f64, dy: f64, dz: f64, d: f64, v: f64, a: f64, e_ratio: f64) Error!void {
        if (self.collect) |list| {
            try list.append(self.gpa, .{ .dir = .{ dx / d, dy / d }, .dir_z = dz / d, .len = d, .speed = v, .accel = a, .e_ratio = e_ratio, .stop_before = self.stop });
        } else if (self.next_move < self.planned.len) {
            self.stats.print_time_s += self.planned[self.next_move].time;
            self.next_move += 1;
        } else {
            self.stats.print_time_s += motion.restTime(d, v, a);
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
        const d = std.math.hypot(x - self.x, y - self.y);
        if (d < 1e-4) return d;
        self.x = x;
        self.y = y;
        return d;
    }

    fn coolingLap(self: *Emitter, lp: *const LayerPlan, seconds: f64) Writer.Error!void {
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
            const d = std.math.hypot(x - self.x, y - self.y);
            if (d / speed > left) {
                // The last move: only as far as the time goes.
                const f = left * speed / d;
                x = self.x + (x - self.x) * f;
                y = self.y + (y - self.y) * f;
            }
            const step = std.math.hypot(x - self.x, y - self.y);
            try self.w.writeAll("G0 X");
            try writeNum(self.w, x + self.r.settings.machine.origin_x, 3);
            try self.w.writeAll(" Y");
            try writeNum(self.w, y + self.r.settings.machine.origin_y, 3);
            try self.writeFeed(speed);
            try self.w.writeAll("\n");
            self.x = x;
            self.y = y;
            self.stats.print_time_s += step / speed;
            self.stats.travel_mm += step;
            left -= step / speed;
            if (step < 1e-6) break;
        }
        try self.setFan(fan);
    }

    fn setFan(self: *Emitter, value: i32) Writer.Error!void {
        if (value == self.fan) return;
        self.fan = value;
        if (value == 0) {
            try self.w.writeAll("M107\n");
        } else {
            try self.w.print("M106 S{d}\n", .{value});
        }
    }

    fn retract(self: *Emitter) Writer.Error!void {
        return self.retractHop(true);
    }

    /// A retraction, and a z hop if `hop` and `z_hop` is on.
    fn retractHop(self: *Emitter, hop: bool) Writer.Error!void {
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
        self.stats.print_time_s += self.retractTime(len);
        self.stop = true;
        const hop_len = self.lr.settings.project.z_hop;
        if (hop and hop_len > 0) {
            self.zMove(hop_len);
            try self.w.writeAll("G0 Z");
            try writeNum(self.w, self.z + hop_len, 3);
            try self.w.writeAll("\n");
            self.hopped = true;
            self.hop_len = hop_len;
        }
    }

    fn unretract(self: *Emitter) Writer.Error!void {
        if (!self.retracted) return;
        if (self.hopped) {
            self.zMove(self.hop_len);
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
        self.stats.print_time_s += self.retractTime(len);
        self.stop = true;
    }

    fn travel(self: *Emitter, x: f64, y: f64) Error!void {
        const d = std.math.hypot(x - self.x, y - self.y);
        if (d < 1e-4) return;
        if (d > self.lr.settings.project.retract_min_travel) {
            // Combing: a way inside the part needs no retraction (see
            // `findWay`).
            var way: [max_way][2]f64 = undefined;
            if (self.wayOf(x, y, d, &way)) |w| {
                for (w) |q| try self.move(q[0], q[1]);
            } else try self.retractHop(!self.layer_start and self.hopFor(x, y));
        }
        try self.move(x, y);
    }

    /// True if a travel to x, y with a retraction lifts the nozzle: always
    /// without `z_hop_only_crossing`, else only if the straight line
    /// crosses an edge of the layer outline. The z hop is the one of the
    /// layer (see `lr`).
    fn hopFor(self: *const Emitter, x: f64, y: f64) bool {
        const p = self.lr.settings.project;
        if (!p.z_hop_only_crossing or p.z_hop <= 0) return true;
        const outline = self.outline orelse return true;
        const a: geom.Point = .{ .x = geom.fromMm(self.x), .y = geom.fromMm(self.y) };
        const b: geom.Point = .{ .x = geom.fromMm(x), .y = geom.fromMm(y) };
        var hit: usize = 0;
        return !self.clearOf(outline.*, self.boxes[0..self.n_boxes], a, b, &hit);
    }

    /// The combing way to x, y (see `comb`): from `prep` if it has the
    /// way from the nozzle position, else found now. In a dry run, a way
    /// that is found now goes into `prep`.
    fn wayOf(self: *Emitter, x: f64, y: f64, d: f64, buf: *[max_way][2]f64) ?[]const [2]f64 {
        const pr = self.prep orelse {
            const n = self.findWay(x, y, d, buf) orelse return null;
            return buf[0..n];
        };
        const i = self.path_index;
        const unknown = Prepared.PathPrep.unknown;
        const no_way = Prepared.PathPrep.retract;
        if (i < pr.paths.items.len) {
            const t = pr.paths.items[i];
            if (t.n != unknown and t.from[0] == self.x and t.from[1] == self.y) {
                if (t.n == no_way) return null;
                return pr.way_points.items[t.start..][0..@intCast(t.n)];
            }
        }
        const found = self.findWay(x, y, d, buf);
        if (self.dry and self.keep_ways and i < pr.paths.items.len) {
            // Keep the way for the text of the layer. The list of
            // waypoints has room for one way (see `prepare`).
            const t = &pr.paths.items[i];
            t.from = .{ self.x, self.y };
            if (found) |n| {
                if (pr.way_points.unusedCapacitySlice().len >= n) {
                    t.start = @intCast(pr.way_points.items.len);
                    t.n = @intCast(n);
                    pr.way_points.appendSliceAssumeCapacity(buf[0..n]);
                } else t.n = unknown;
            } else t.n = no_way;
        }
        const n = found orelse return null;
        return buf[0..n];
    }

    /// A travel move in a straight line, with no retraction.
    fn move(self: *Emitter, x: f64, y: f64) Error!void {
        const d = std.math.hypot(x - self.x, y - self.y);
        if (d < 1e-4) return;
        const speed = self.r.settings.machine.travel_speed;
        var line: Line = .{ .skip = self.dry };
        line.add("G0 X");
        line.num(x + self.r.settings.machine.origin_x, 3);
        line.add(" Y");
        line.num(y + self.r.settings.machine.origin_y, 3);
        self.addFeed(&line, speed);
        line.add("\n");
        try self.w.writeAll(line.text());
        try self.addMove(x - self.x, y - self.y, d, speed, 0);
        self.x = x;
        self.y = y;
        self.stats.travel_mm += d;
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
            const l = std.math.hypot(q[0] - px, q[1] - py);
            if (l > 1e-6) {
                moves[k] = .{ .dir = .{ (q[0] - px) / l, (q[1] - py) / l }, .len = l, .speed = m.travel_speed, .accel = a };
                k += 1;
            }
            px = q[0];
            py = q[1];
        }
        const t_way = motion.plan(moves[0..k], self.limits());
        const hop = self.lr.settings.project.z_hop;
        const stop = 2 * self.retractTime(self.lr.retract_length) + if (hop > 0) 2 * motion.restTime(hop, m.max_z_speed, m.max_z_accel) else 0;
        return t_way > motion.restTime(d, m.travel_speed, a) + stop;
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
        const k = @min(d / @max(1 + dot, 1e-9), 3 * d / @max(std.math.hypot(n1[0] + n2[0], n1[1] + n2[1]), 1e-9));
        return .{
            .x = v.x + @as(i64, @intFromFloat(@round((n1[0] + n2[0]) * k))),
            .y = v.y + @as(i64, @intFromFloat(@round((n1[1] + n2[1]) * k))),
        };
    }

    fn unit(a: geom.Point, b: geom.Point) [2]f64 {
        const dx: f64 = @floatFromInt(b.x - a.x);
        const dy: f64 = @floatFromInt(b.y - a.y);
        const l = @max(std.math.hypot(dx, dy), 1e-9);
        return .{ dx / l, dy / l };
    }

    fn dist(a: geom.Point, b: geom.Point) f64 {
        return std.math.hypot(geom.toMm(a.x - b.x), geom.toMm(a.y - b.y));
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
        return self.extrudeLen(x, y, std.math.hypot(x - self.x, y - self.y), e_per_mm, speed);
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
        try self.w.writeAll(line.text());
        try self.addMove(x - self.x, y - self.y, d, speed, e_per_mm);
        self.x = x;
        self.y = y;
        self.stats.filament_mm += e;
        self.extruded = true;
    }

    /// `writeFeed`, into a line.
    fn addFeed(self: *Emitter, line: *Line, speed: f64) void {
        const f = @round(speed * 60);
        if (f == self.feed) return;
        self.feed = f;
        line.add(" F");
        line.num(f, 0);
    }

    fn writeFeed(self: *Emitter, speed: f64) Writer.Error!void {
        const f = @round(speed * 60);
        if (f == self.feed) return;
        self.feed = f;
        try self.w.writeAll(" F");
        try writeNum(self.w, f, 0);
    }

    /// Writes `text` and replaces {nozzle_temp}, {first_layer_nozzle_temp},
    /// and {bed_temp}.
    /// Writes `text` and replaces the variables that `Machine.start_gcode`
    /// lists. An unknown {name} stays as it is.
    fn writeTemplate(self: *Emitter, text: []const u8) Writer.Error!void {
        const s = self.r.settings;
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            try self.w.writeAll(rest[0..open]);
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
                rest = rest[open..];
                break;
            };
            const key = rest[open + 1 .. close];
            rest = rest[close + 1 ..];
            const Num = struct { name: []const u8, value: f64, decimals: u8 };
            const first_speed = self.r.speed(.inner_wall, self.r.first_layer_line_width, s.project.first_layer_height, true);
            const nums = [_]Num{
                .{ .name = "nozzle_temp", .value = s.filament.nozzle_temp, .decimals = 0 },
                .{ .name = "first_layer_nozzle_temp", .value = s.filament.first_layer_nozzle_temp, .decimals = 0 },
                .{ .name = "bed_temp", .value = s.filament.bed_temp, .decimals = 0 },
                .{ .name = "standby_temp", .value = s.filament.standby_temp, .decimals = 0 },
                .{ .name = "layer_height", .value = s.project.layer_height, .decimals = 3 },
                .{ .name = "first_layer_height", .value = s.project.first_layer_height, .decimals = 3 },
                .{ .name = "first_layer_speed", .value = first_speed, .decimals = 0 },
                .{ .name = "nozzle_diameter", .value = s.machine.nozzle_diameter, .decimals = 3 },
                .{ .name = "filament_diameter", .value = s.filament.diameter, .decimals = 3 },
            };
            const texts = [_][2][]const u8{
                .{ "filament_name", s.filament.name },
                .{ "machine_name", s.machine.name },
                .{ "job_name", s.engine.job_name },
            };
            const done = blk: {
                for (nums) |n| if (std.mem.eql(u8, key, n.name)) {
                    switch (n.decimals) {
                        0 => try writeNum(self.w, n.value, 0),
                        else => try writeNum(self.w, n.value, 3),
                    }
                    break :blk true;
                };
                for (texts) |t| if (std.mem.eql(u8, key, t[0])) {
                    try self.w.writeAll(t[1]);
                    break :blk true;
                };
                break :blk false;
            };
            if (!done) {
                try self.w.writeByte('{');
                try self.w.writeAll(key);
                try self.w.writeByte('}');
            }
        }
        try self.w.writeAll(rest);
    }
};

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
        var n: i64 = @intFromFloat(@round(v * scale));
        if (n < 0) {
            l.add("-");
            n = -n;
        }
        var u: u64 = @intCast(n);
        // At least decimals + 1 digits, with leading zeros.
        var digits: [24]u8 = undefined;
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
        l.add(digits[at..int_end]);
        if (decimals == 0) return;
        var frac_end: usize = digits.len;
        while (frac_end > int_end and digits[frac_end - 1] == '0') frac_end -= 1;
        if (frac_end == int_end) return;
        l.add(".");
        l.add(digits[int_end..frac_end]);
    }
};

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
    const d = std.math.hypot(x - em.x, y - em.y);
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
