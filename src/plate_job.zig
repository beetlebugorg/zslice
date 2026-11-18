//! The slice of a plate: each part is its own engine job, and the G-code
//! merges the layers of all parts by z.
//!
//! 1. The parts. Each part has its mesh on the bed, its own changes of
//!    the settings (over the settings of the plate), its modifier volumes,
//!    and its support marks. The settings of a part are the settings of
//!    the plate with its changes, except the settings that are the same
//!    for the whole plate (see settings.isPlateSetting): the temperatures,
//!    the fan and the cooling, the travel and the retraction, the first
//!    layer height, the skirt, and the brim.
//! 2. Groups. Parts with the same mesh (the same faces, and the same
//!    vertices after a move in X and Y), the same changes, and no volumes
//!    and no marks are copies. A group of copies slices once: one engine
//!    job (see engine.Job), for the first part of the group. The paths of
//!    each other copy are the paths of that job, moved by the distance
//!    between the parts.
//! 3. Placement. All parts move by one offset, from the box of all parts
//!    and the placement setting, so they keep their places on the plate.
//! 4. Levels. The top z of each layer of each job, sorted, makes the
//!    levels of the plate. Two layers closer than `z_eps` are one level.
//!    Level n is ";LAYER:n" in the G-code. A part with thicker layers
//!    prints only at the levels of its own layers, so the nozzle only goes
//!    up. A level has the settings of the plate at its z (with the
//!    overrides of the user); its height is the largest layer height of
//!    its parts.
//! 5. Order. On each level, the first part is the one nearest to the
//!    last part of the level before, and each next part is the nearest
//!    one to the part before it (the centers of the boxes of the parts).
//!    The plans of the parts do not depend on the order, so the levels
//!    plan in parallel.
//! 6. The plan of a level: the skirt and the brim around all parts (on
//!    the first levels), then the plan of each part, moved to its place
//!    (see layer.LayerPlan.append). Each path keeps the settings of its
//!    part, its width, its height, and the layer index in its job, so the
//!    emitter prints it with its own speed and flow. The cooling, the fan,
//!    the retraction, and the time of a level come from the plate.
//!
//! A plate with one part and no settings of its own gives the same G-code
//! as one job of its mesh: then the plan of a level is the plan of the
//! job, with its own skirt and brim.
//!
//! References (see REFERENCES.md): the greedy nearest-neighbor order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom.zig");
const mesh_mod = @import("mesh.zig");
const settings_mod = @import("settings.zig");
const engine = @import("engine.zig");
const layer_mod = @import("layer.zig");
const support_mod = @import("support.zig");
const islands_mod = @import("islands.zig");
const parallel = @import("parallel.zig");
const Mesh = mesh_mod.Mesh;
const Settings = settings_mod.Settings;
const Resolved = settings_mod.Resolved;
const LayerPlan = layer_mod.LayerPlan;
const Job = engine.Job;
const Error = engine.Error;
const Paths = geom.Paths;

/// Two layer tops closer than this (mm) are one level.
pub const z_eps = 1e-4;

/// The largest distance (mm) between a vertex of a part and the vertex of
/// another part, after the move, for the parts to be copies.
const copy_tolerance = 1e-3;

/// One part of the plate for `PlateJob.init`.
pub const PartInput = struct {
    /// The mesh of the part on the bed (the coordinates of the plate).
    mesh: *const Mesh,
    /// The changes of the settings of the part, over the settings of the
    /// plate. The changes of the settings of the plate (see
    /// settings.isPlateSetting) do not apply. The strings must live as
    /// long as the job.
    changes: []const settings_mod.Change = &.{},
    /// The modifier volumes of the part, in the coordinates of the plate.
    modifiers: []const Job.ModifierInput = &.{},
    /// The support marks of the part (see support.Mark).
    marks: []const support_mod.Mark = &.{},
    /// The id of the part for the toolpaths (for example, its index on
    /// the plate).
    part: u32,
};

/// A part on the plate: the group whose job slices it, and its move from
/// the part of that job.
pub const Instance = struct {
    part: u32,
    group: u32,
    /// The move in X and Y, in the units of geom.
    dx: i64 = 0,
    dy: i64 = 0,
    /// The center of the box of the part (mm), for the order of the parts.
    center: [2]f64,
};

/// A group of copies: one job.
pub const Group = struct {
    job: Job,
    /// The part whose mesh the job slices.
    part: u32,
    /// The level of each layer of the job.
    layer_level: []u32,
};

/// One part on one level: its instance, and the layer of its job.
pub const Entry = struct { instance: u32, layer: u32 };

pub const Level = struct {
    /// The top z of the level (mm).
    z: f64,
    /// The largest layer height of the parts on the level (mm).
    height: f64,
    /// The parts of the level, in print order: entries[first..end].
    first: u32,
    end: u32,
};

pub const Options = struct {
    /// Overrides for z ranges (see settings.Override and Job.Options).
    overrides: []const settings_mod.Override = &.{},
    monitor: engine.Monitor = .{},
    /// The plate job before, for its work: the job of a group takes the
    /// work of the old job of the same part (see Job.initReuse). The
    /// caller knows that each part has the same mesh as before. Free the
    /// old job after the call.
    old: ?*PlateJob = null,
    /// See Job.keep_memos.
    keep_memos: bool = true,
};

pub const PlateJob = struct {
    gpa: Allocator,
    /// The settings of the plate.
    resolved: Resolved,
    monitor: engine.Monitor,
    threads: usize,
    groups: []Group = &.{},
    instances: []Instance = &.{},
    levels: []Level = &.{},
    entries: []Entry = &.{},
    /// The settings of each level with overrides: 0 for `resolved`, k
    /// for `level_resolved[k - 1]`.
    level_set: []u16 = &.{},
    level_resolved: []Resolved = &.{},
    /// The first layers of all parts at their places, for the skirt and
    /// the brim around them. Empty for a plate of one part: its job makes
    /// them.
    outline0: Paths = .empty,
    /// The shapes that start in the air (see islands.zig), of all parts,
    /// at their places, with the index of their level.
    islands: []islands_mod.Island = &.{},

    /// Slices each group of parts (steps 1 to 4 of the engine for each
    /// job), and finds the levels.
    pub fn init(gpa: Allocator, settings: Settings, parts: []const PartInput, opts: Options) Error!PlateJob {
        if (parts.len == 0) return error.EmptyMesh;
        const r = settings.resolve() catch return error.InvalidSettings;
        var pj: PlateJob = .{
            .gpa = gpa,
            .resolved = r,
            .monitor = opts.monitor,
            .threads = parallel.threadCount(settings.engine.threads),
        };
        errdefer pj.deinit();

        // Step 3: one offset for all parts. One part places itself, as a
        // job of one mesh does.
        const boxes = try gpa.alloc(mesh_mod.Bounds3, parts.len);
        defer gpa.free(boxes);
        var all: mesh_mod.Bounds3 = .{ .min = @splat(std.math.inf(f64)), .max = @splat(-std.math.inf(f64)) };
        for (parts, boxes) |p, *b| {
            if (p.mesh.faces.items.len == 0) return error.EmptyMesh;
            b.* = p.mesh.bounds();
            for (0..3) |k| {
                all.min[k] = @min(all.min[k], b.min[k]);
                all.max[k] = @max(all.max[k], b.max[k]);
            }
        }
        const m = settings.machine;
        const offset: ?[2]f64 = if (parts.len == 1) null else engine.placementOffset(settings.project.placement, all.min, all.max, m.bed_size_x, m.bed_size_y, engine.ringMargin(&r));

        // Step 2: the groups of copies.
        pj.instances = try gpa.alloc(Instance, parts.len);
        var reps: std.ArrayList(usize) = .empty;
        defer reps.deinit(gpa);
        const keys = try gpa.alloc(u64, parts.len);
        defer gpa.free(keys);
        for (parts, keys) |p, *k| k.* = shapeKey(p.mesh);
        for (parts, 0..) |p, i| {
            const b = boxes[i];
            var inst: Instance = .{ .part = p.part, .group = @intCast(reps.items.len), .center = .{ (b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2 } };
            for (reps.items, 0..) |ri, g| {
                if (!copies(parts[ri], p, keys[ri], keys[i], boxes[ri], b)) continue;
                inst.group = @intCast(g);
                inst.dx = geom.fromMm(b.min[0] - boxes[ri].min[0]);
                inst.dy = geom.fromMm(b.min[1] - boxes[ri].min[1]);
                break;
            }
            if (inst.group == reps.items.len) try reps.append(gpa, i);
            pj.instances[i] = inst;
        }

        // The job of each group.
        var groups: std.ArrayList(Group) = .empty;
        errdefer {
            for (groups.items) |*g| {
                g.job.deinit();
                gpa.free(g.layer_level);
            }
            groups.deinit(gpa);
        }
        try groups.ensureTotalCapacity(gpa, reps.items.len);
        const n_groups = reps.items.len;
        for (reps.items, 0..) |ri, g| {
            const p = parts[ri];
            var s = settings;
            for (p.changes) |c| {
                if (settings_mod.isPlateSetting(c.name)) continue;
                s.set(c.name, c.value) catch return error.InvalidSettings;
            }
            var old_job: ?*Job = null;
            if (opts.old) |o| for (o.groups) |*og| if (og.part == p.part) {
                old_job = &og.job;
                break;
            };
            var scaled: Scaled = .{ .inner = opts.monitor, .base = @as(f64, @floatFromInt(g)) / @as(f64, @floatFromInt(n_groups)), .span = 1 / @as(f64, @floatFromInt(n_groups)) };
            const monitor: engine.Monitor = .{ .ctx = &scaled, .progress = if (opts.monitor.progress != null) Scaled.progress else null, .cancel = opts.monitor.cancel };
            var job = try Job.initOpts(gpa, p.mesh, s, .{
                .overrides = opts.overrides,
                .marks = p.marks,
                .monitor = monitor,
                .old = old_job,
                .offset = offset,
                .rings = parts.len == 1,
            });
            errdefer job.deinit();
            // The scaled monitor lives only in this call.
            job.monitor = opts.monitor;
            job.keep_memos = opts.keep_memos;
            if (p.modifiers.len > 0) try job.setModifiers(p.modifiers);
            const layer_level = try gpa.alloc(u32, job.layers.len);
            groups.appendAssumeCapacity(.{ .job = job, .part = p.part, .layer_level = layer_level });
        }
        pj.groups = try groups.toOwnedSlice(gpa);

        try pj.makeLevels(settings, opts.overrides);
        try pj.makeOutline0();
        try pj.makeIslands();
        return pj;
    }

    /// Frees the memos of the job of each group (see Job.dropMemos).
    pub fn dropMemos(self: *PlateJob) void {
        for (self.groups) |*g| g.job.dropMemos();
    }

    pub fn deinit(self: *PlateJob) void {
        const gpa = self.gpa;
        for (self.groups) |*g| {
            g.job.deinit();
            gpa.free(g.layer_level);
        }
        gpa.free(self.groups);
        gpa.free(self.instances);
        gpa.free(self.levels);
        gpa.free(self.entries);
        gpa.free(self.level_set);
        gpa.free(self.level_resolved);
        self.outline0.deinit(gpa);
        gpa.free(self.islands);
        self.* = undefined;
    }

    /// True if the plate prints as the one job of one part: then a level
    /// is a layer of that job.
    pub fn single(self: *const PlateJob) bool {
        return self.instances.len == 1;
    }

    /// The number of levels: the layer count of the G-code.
    pub fn layerCount(self: *const PlateJob) usize {
        return self.levels.len;
    }

    /// The outline of one part on a level: the outline of the layer of its
    /// job, and the move of the part (in the units of geom).
    pub const PartOutline = struct { paths: *const Paths, dx: i64, dy: i64 };

    /// The outline of part k of level i (k from 0 to the count of the
    /// parts on the level), or null after the last part. The outlines of
    /// all parts are the material of the level, for a 2D view. The
    /// outlines stay valid as long as the job.
    pub fn levelOutline(self: *const PlateJob, i: usize, k: usize) ?PartOutline {
        if (i >= self.levels.len) return null;
        const lv = self.levels[i];
        if (lv.first + k >= lv.end) return null;
        const e = self.entries[lv.first + k];
        const inst = self.instances[e.instance];
        const job = &self.groups[inst.group].job;
        if (e.layer >= job.outlines.len) return null;
        return .{ .paths = &job.outlines[e.layer], .dx = inst.dx, .dy = inst.dy };
    }

    /// Step 4 and 5: the levels, their parts in print order, and the
    /// settings of each level.
    fn makeLevels(self: *PlateJob, settings: Settings, overrides: []const settings_mod.Override) Error!void {
        const gpa = self.gpa;
        const Top = struct { z: f64, group: u32, layer: u32 };
        var tops: std.ArrayList(Top) = .empty;
        defer tops.deinit(gpa);
        for (self.groups, 0..) |g, gi| for (g.job.layers, 0..) |l, li| {
            try tops.append(gpa, .{ .z = l.z, .group = @intCast(gi), .layer = @intCast(li) });
        };
        std.mem.sort(Top, tops.items, {}, struct {
            fn lt(_: void, x: Top, y: Top) bool {
                if (x.z != y.z) return x.z < y.z;
                return x.group < y.group;
            }
        }.lt);
        var levels: std.ArrayList(Level) = .empty;
        defer levels.deinit(gpa);
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        // The layer of each group on the level that is being made, or
        // none.
        const at = try gpa.alloc(?u32, self.groups.len);
        defer gpa.free(at);
        const done = try gpa.alloc(bool, self.instances.len);
        defer gpa.free(done);
        var last: [2]f64 = self.instances[0].center;
        var k: usize = 0;
        while (k < tops.items.len) {
            const z = tops.items[k].z;
            @memset(at, null);
            var height: f64 = 0;
            const level: u32 = @intCast(levels.items.len);
            while (k < tops.items.len and tops.items[k].z - z < z_eps) : (k += 1) {
                const t = tops.items[k];
                at[t.group] = t.layer;
                self.groups[t.group].layer_level[t.layer] = level;
                height = @max(height, self.groups[t.group].job.layers[t.layer].height);
            }
            // The parts of the level, the nearest first.
            const first: u32 = @intCast(entries.items.len);
            for (self.instances, done) |inst, *d| d.* = at[inst.group] == null;
            while (true) {
                var best: ?usize = null;
                var best_d: f64 = std.math.inf(f64);
                for (self.instances, 0..) |inst, ii| {
                    if (done[ii]) continue;
                    const d = @import("geom.zig").hypot(inst.center[0] - last[0], inst.center[1] - last[1]);
                    if (d < best_d) {
                        best_d = d;
                        best = ii;
                    }
                }
                const ii = best orelse break;
                done[ii] = true;
                last = self.instances[ii].center;
                try entries.append(gpa, .{ .instance = @intCast(ii), .layer = at[self.instances[ii].group].? });
            }
            try levels.append(gpa, .{ .z = z, .height = height, .first = first, .end = @intCast(entries.items.len) });
        }
        self.levels = try levels.toOwnedSlice(gpa);
        self.entries = try entries.toOwnedSlice(gpa);

        // The settings of each level, with the overrides that cover it.
        if (self.single() or overrides.len == 0) return;
        self.level_set = try gpa.alloc(u16, self.levels.len);
        @memset(self.level_set, 0);
        var masks: std.ArrayList(u64) = .empty;
        defer masks.deinit(gpa);
        var list: std.ArrayList(Resolved) = .empty;
        errdefer list.deinit(gpa);
        for (self.levels, 0..) |lv, i| {
            var mask: u64 = 0;
            for (overrides, 0..) |o, ok| if (ok < 64 and o.covers(lv.z)) {
                mask |= @as(u64, 1) << @intCast(ok);
            };
            if (mask == 0) continue;
            if (std.mem.indexOfScalar(u64, masks.items, mask)) |f| {
                self.level_set[i] = @intCast(f + 1);
                continue;
            }
            const s = settings_mod.withOverrides(settings, overrides, lv.z) catch return error.InvalidSettings;
            try list.append(gpa, s.resolve() catch return error.InvalidSettings);
            try masks.append(gpa, mask);
            self.level_set[i] = @intCast(list.items.len);
        }
        self.level_resolved = try list.toOwnedSlice(gpa);
    }

    /// The first layers of all parts at their places (see `outline0`).
    fn makeOutline0(self: *PlateJob) Allocator.Error!void {
        if (self.single()) return;
        for (self.instances) |inst| {
            const job = &self.groups[inst.group].job;
            if (job.outlines.len == 0) continue;
            const o = job.outlines[0];
            const base: u32 = @intCast(self.outline0.points.items.len);
            for (o.points.items) |q| try self.outline0.points.append(self.gpa, .init(q.x + inst.dx, q.y + inst.dy));
            for (o.ends.items) |e| try self.outline0.ends.append(self.gpa, base + e);
        }
    }

    fn makeIslands(self: *PlateJob) Allocator.Error!void {
        var list: std.ArrayList(islands_mod.Island) = .empty;
        errdefer list.deinit(self.gpa);
        for (self.instances) |inst| {
            const g = &self.groups[inst.group];
            for (g.job.islands) |isl| {
                var c = isl;
                c.layer = g.layer_level[isl.layer];
                c.x += geom.toMm(inst.dx);
                c.y += geom.toMm(inst.dy);
                try list.append(self.gpa, c);
            }
        }
        std.mem.sort(islands_mod.Island, list.items, {}, struct {
            fn lt(_: void, x: islands_mod.Island, y: islands_mod.Island) bool {
                return x.layer < y.layer;
            }
        }.lt);
        self.islands = try list.toOwnedSlice(self.gpa);
    }

    /// The settings of level i: the plate with the overrides at its z.
    pub fn levelResolved(self: *const PlateJob, i: usize) *const Resolved {
        if (self.single()) return self.groups[0].job.resolvedAt(i);
        if (i < self.level_set.len and self.level_set[i] > 0) return &self.level_resolved[self.level_set[i] - 1];
        return &self.resolved;
    }

    /// The instance of part `part`, or null.
    pub fn instanceOf(self: *const PlateJob, part: u32) ?*const Instance {
        for (self.instances) |*inst| if (inst.part == part) return inst;
        return null;
    }

    /// The job that slices part `part`, or null.
    pub fn jobOf(self: *const PlateJob, part: u32) ?*const Job {
        const inst = self.instanceOf(part) orelse return null;
        return &self.groups[inst.group].job;
    }

    /// The layer of the job of part `part` on level `level`, or null if the
    /// part has no layer there.
    pub fn localLayer(self: *const PlateJob, part: u32, level: usize) ?usize {
        if (level >= self.levels.len) return null;
        const lv = self.levels[level];
        for (self.entries[lv.first..lv.end]) |e| {
            if (self.instances[e.instance].part == part) return e.layer;
        }
        return null;
    }

    /// The settings of the paths of part `part` on level `level`, in its
    /// modifier volume `modifier` - 1 (0: in no volume). The settings of
    /// the level for `no_part` or a part with no layer there.
    pub fn pathResolved(self: *const PlateJob, part: u32, level: usize, modifier: usize) *const Resolved {
        const job = self.jobOf(part) orelse return self.levelResolved(level);
        const li = self.localLayer(part, level) orelse return self.levelResolved(level);
        return job.pathResolved(li, modifier);
    }

    /// The box of all outlines of all parts at their places (mm): min x,
    /// min y, max x, max y, or null.
    pub fn bounds(self: *const PlateJob) ?[4]f64 {
        var box = geom.Box.empty;
        for (self.instances) |inst| for (self.groups[inst.group].job.outlines) |o| {
            const b = o.bounds();
            if (b.isEmpty()) continue;
            box.extend(.init(b.min.x + inst.dx, b.min.y + inst.dy));
            box.extend(.init(b.max.x + inst.dx, b.max.y + inst.dy));
        };
        if (box.isEmpty()) return null;
        return .{ geom.toMm(box.min.x), geom.toMm(box.min.y), geom.toMm(box.max.x), geom.toMm(box.max.y) };
    }

    /// The plan context of each group, with no combined areas (each plan
    /// makes the area of its group). The caller frees the slice.
    fn contexts(self: *const PlateJob) Allocator.Error![]layer_mod.Context {
        const ctxs = try self.gpa.alloc(layer_mod.Context, self.groups.len);
        for (self.groups, ctxs) |*g, *c| c.* = g.job.planContext();
        return ctxs;
    }

    /// The plan of level i. Call `deinit` on the result.
    pub fn planLayer(self: *const PlateJob, i: usize) Allocator.Error!LayerPlan {
        const ctxs = try self.contexts();
        defer self.gpa.free(ctxs);
        return self.planLevel(self.gpa, ctxs, i);
    }

    /// Step 6: the plan of level i, from the plans of the layers of the
    /// groups on it, with the plan contexts `ctxs`.
    fn planLevel(self: *const PlateJob, gpa: Allocator, ctxs: []const layer_mod.Context, i: usize) Allocator.Error!LayerPlan {
        const lv = self.levels[i];
        if (self.single()) {
            const e = self.entries[lv.first];
            var lp = try layer_mod.plan(gpa, ctxs[0], e.layer);
            lp.part = self.instances[0].part;
            return lp;
        }
        const r = self.levelResolved(i);
        const start: geom.Point = if (self.outline0.points.items.len > 0) self.outline0.points.items[0] else .init(0, 0);
        var lp = try layer_mod.ringPlan(gpa, r, self.outline0, i, start);
        errdefer lp.deinit();
        lp.z = lv.z;
        lp.height = lv.height;
        if (lp.paths.items.len == 0) lp.width = 0;
        // The plan of each group on this level, made once for all its
        // copies.
        const plans = try gpa.alloc(?LayerPlan, self.groups.len);
        defer gpa.free(plans);
        @memset(plans, null);
        defer for (plans) |*p| if (p.*) |*q| q.deinit();
        for (self.entries[lv.first..lv.end]) |e| {
            const inst = self.instances[e.instance];
            if (plans[inst.group] == null) plans[inst.group] = try layer_mod.plan(gpa, ctxs[inst.group], e.layer);
            try lp.append(&plans[inst.group].?, inst.dx, inst.dy, inst.part, e.layer);
        }
        return lp;
    }

    /// Writes the G-code of all levels (step 5 of the engine).
    pub fn writeGcode(self: *const PlateJob, out: *Writer) Error!engine.Stats {
        return self.writeGcodeWith(out, null);
    }

    /// `writeGcode`, and each level plan also goes to `sink`.
    pub fn writeGcodeWith(self: *const PlateJob, out: *Writer, sink: ?Job.LayerSink) Error!engine.Stats {
        return self.writeRange(out, sink, 0, self.levels.len);
    }

    /// The G-code of the levels lo to hi - 1 alone, lowered so that level
    /// lo prints on the bed (a debug print: "print this layer", or a few
    /// layers to check them before a long print). Each level keeps its
    /// height, its lines, and its speeds.
    pub fn writeLevels(self: *const PlateJob, out: *Writer, lo: usize, hi: usize) Error!engine.Stats {
        return self.writeRange(out, null, @min(lo, self.levels.len), @min(@max(hi, lo + 1), self.levels.len));
    }

    fn writeRange(self: *const PlateJob, out: *Writer, sink: ?Job.LayerSink, lo: usize, hi: usize) Error!engine.Stats {
        const gpa = self.gpa;
        // The drop of the levels: level lo prints at its own height above
        // the bed.
        const drop = if (lo == 0 or lo >= self.levels.len) 0 else self.levels[lo].z - self.levels[lo].height;
        const ctxs = try self.contexts();
        defer gpa.free(ctxs);
        const combined = try gpa.alloc([]Paths, self.groups.len);
        @memset(combined, &.{});
        defer {
            for (combined) |c| {
                for (c) |*p| p.deinit(gpa);
                gpa.free(c);
            }
            gpa.free(combined);
        }
        for (self.groups, ctxs, combined) |*g, *c, *cb| {
            // A cancel stops a layer plan early.
            c.cancel = self.monitor.cancel;
            cb.* = try g.job.combinedAreas(c.*);
            c.combined = cb.*;
        }
        var keep = true;
        for (self.groups) |g| keep = keep and g.job.keep_memos;
        const Ctx = struct {
            pj: *const PlateJob,
            ctxs: []const layer_mod.Context,
            lo: usize,
            drop: f64,
            fn plan(ctx: *const anyopaque, g: Allocator, i: usize) Allocator.Error!LayerPlan {
                const c: *const @This() = @ptrCast(@alignCast(ctx));
                var lp = try c.pj.planLevel(g, c.ctxs, c.lo + i);
                if (c.lo > 0) {
                    lp.z -= c.drop;
                    lp.index = @intCast(i);
                }
                return lp;
            }
            fn done(ctx: *const anyopaque, g: Allocator, i: usize) void {
                const c: *const @This() = @ptrCast(@alignCast(ctx));
                const lv = c.pj.levels[c.lo + i];
                for (c.pj.entries[lv.first..lv.end]) |e| {
                    engine.dropMemo(g, c.ctxs[c.pj.instances[e.instance].group].cache, e.layer);
                }
            }
        };
        const ctx: Ctx = .{ .pj = self, .ctxs = ctxs, .lo = lo, .drop = drop };
        const src: engine.PlanSource = .{
            .ctx = &ctx,
            .plan = Ctx.plan,
            .done = if (keep) null else Ctx.done,
            .resolved = if (self.single()) &self.groups[0].job.resolved else &self.resolved,
            .layers = hi - lo,
        };
        return engine.emitAll(gpa, src, self.threads, self.monitor, out, sink);
    }
};

/// The progress of one job of `n`, as a part of the progress of all.
const Scaled = struct {
    inner: engine.Monitor,
    base: f64,
    span: f64,

    fn progress(ctx: ?*anyopaque, fraction: f64) void {
        const s: *Scaled = @ptrCast(@alignCast(ctx.?));
        const f = s.inner.progress orelse return;
        // A job reports pass 1 as 0 to pass1_share of the slice.
        f(s.inner.ctx, s.base * engine.pass1_share + fraction * s.span);
    }
};

/// A hash of the faces and the vertex count of a mesh: copies have the
/// same key.
fn shapeKey(m: *const Mesh) u64 {
    var h = std.hash.Wyhash.init(0x9a7e);
    h.update(std.mem.asBytes(&m.vertices.items.len));
    h.update(std.mem.sliceAsBytes(m.faces.items));
    return h.final();
}

/// True if part `q` is a copy of part `p`: the same changes, no volumes
/// and no marks, and the same mesh after the move from the box of p to the
/// box of q.
fn copies(p: PartInput, q: PartInput, kp: u64, kq: u64, bp: mesh_mod.Bounds3, bq: mesh_mod.Bounds3) bool {
    if (kp != kq) return false;
    if (p.modifiers.len > 0 or q.modifiers.len > 0 or p.marks.len > 0 or q.marks.len > 0) return false;
    if (p.changes.len != q.changes.len) return false;
    for (p.changes, q.changes) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.value, y.value)) return false;
    }
    const vp = p.mesh.vertices.items;
    const vq = q.mesh.vertices.items;
    if (vp.len != vq.len) return false;
    for (0..3) |k| if (@abs((bp.max[k] - bp.min[k]) - (bq.max[k] - bq.min[k])) > copy_tolerance) return false;
    for (vp, vq) |a, b| {
        const d = [3]f64{
            (b.x - bq.min[0]) - (a.x - bp.min[0]),
            (b.y - bq.min[1]) - (a.y - bp.min[1]),
            (b.z - bq.min[2]) - (a.z - bp.min[2]),
        };
        if (@abs(d[0]) > copy_tolerance or @abs(d[1]) > copy_tolerance or @abs(d[2]) > copy_tolerance) return false;
    }
    return true;
}

const testing = std.testing;

fn testBox(x0: f64, y0: f64, x1: f64, y1: f64, h: f64) !Mesh {
    var b: mesh_mod.Builder = .init(testing.allocator);
    try mesh_mod.shapes.addBox(&b, x0, y0, 0, x1, y1, h);
    return b.finish();
}

fn gcodeOf(pj: *const PlateJob) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    _ = try pj.writeGcode(&out.writer);
    return out.toOwnedSlice();
}

test "plate job: one part gives the G-code of one job" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    var job = try Job.init(gpa, &m, s);
    defer job.deinit();
    var a: Writer.Allocating = .init(gpa);
    defer a.deinit();
    _ = try job.writeGcode(&a.writer);
    var pj = try PlateJob.init(gpa, s, &.{.{ .mesh = &m, .part = 0 }}, .{});
    defer pj.deinit();
    const b = try gcodeOf(&pj);
    defer gpa.free(b);
    try testing.expectEqualStrings(a.written(), b);
}

/// The paths of `feature` kinds of each part on level `level`.
fn wallsOfParts(pj: *const PlateJob, level: usize) ![2]usize {
    var lp = try pj.planLayer(level);
    defer lp.deinit();
    var n = [2]usize{ 0, 0 };
    for (lp.paths.items) |p| {
        if (p.feature != .outer_wall and p.feature != .inner_wall) continue;
        const part = lp.partOf(p);
        if (part < 2) n[part] += 1;
    }
    return n;
}

test "plate job: two parts with their own wall counts" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 5);
    defer m1.deinit(gpa);
    var m2 = try testBox(40, 0, 60, 20, 5);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0, .changes = &.{.{ .name = "project.wall_count", .value = "2" }} },
        // A plate setting of a part does not apply.
        .{ .mesh = &m2, .part = 1, .changes = &.{ .{ .name = "project.wall_count", .value = "5" }, .{ .name = "filament.nozzle_temp", .value = "250" } } },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{});
    defer pj.deinit();
    try testing.expectEqual(@as(usize, 2), pj.groups.len);
    try testing.expectEqual(@as(f64, s.filament.nozzle_temp), pj.jobOf(1).?.resolved.settings.filament.nozzle_temp);
    const n = try wallsOfParts(&pj, 8);
    try testing.expectEqual(@as(usize, 2), n[0]);
    try testing.expectEqual(@as(usize, 5), n[1]);
    // The skirt goes around the parts of the plate, and not in the plans
    // of the parts. The parts are far apart, so each has its own loop.
    var lp0 = try pj.planLayer(0);
    defer lp0.deinit();
    var skirt: usize = 0;
    for (lp0.paths.items) |p| if (p.feature == .skirt) {
        skirt += 1;
        try testing.expectEqual(LayerPlan.no_part, lp0.partOf(p));
    };
    try testing.expectEqual(@as(usize, 2 * s.project.skirt_loops), skirt);
    const g = try gcodeOf(&pj);
    defer gpa.free(g);
    try testing.expect(std.mem.indexOf(u8, g, ";LAYER:0\n") != null);
}

test "plate job: parts with layer heights 0.1 and 0.2 merge by z" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 2);
    defer m1.deinit(gpa);
    var m2 = try testBox(40, 0, 60, 20, 2);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.project.first_layer_height = 0.2;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0, .changes = &.{.{ .name = "project.layer_height", .value = "0.1" }} },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.layer_height", .value = "0.2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{});
    defer pj.deinit();
    const thin = pj.jobOf(0).?.layers.len;
    const thick = pj.jobOf(1).?.layers.len;
    try testing.expect(thin > thick);
    // The levels are the layers of the thin part; the thick part prints
    // on every other level.
    try testing.expectEqual(thin, pj.layerCount());
    for (0..pj.layerCount()) |i| {
        try testing.expectEqual(@as(?usize, i), pj.localLayer(0, i));
        const local = pj.localLayer(1, i);
        if (i % 2 == 0) {
            try testing.expectEqual(@as(?usize, i / 2), local);
        } else {
            try testing.expect(local == null);
        }
        if (i > 0) try testing.expect(pj.levels[i].z > pj.levels[i - 1].z);
    }
    // The G-code has one ;LAYER: for each level, and its Z only goes up.
    const g = try gcodeOf(&pj);
    defer gpa.free(g);
    var layers: usize = 0;
    var z: f64 = 0;
    var lines = std.mem.splitScalar(u8, g, '\n');
    var in_layers = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) {
            layers += 1;
            in_layers = true;
        }
        if (!in_layers or !std.mem.startsWith(u8, line, "G0 Z")) continue;
        const end = std.mem.indexOfScalar(u8, line[4..], ' ') orelse line.len - 4;
        const lz = try std.fmt.parseFloat(f64, line[4..][0..end]);
        // A z hop goes up and back down to the z of the layer.
        try testing.expect(lz >= z - 1e-9 or lz >= z - s.project.z_hop - 1e-9);
        z = @max(z, lz - s.project.z_hop);
    }
    try testing.expectEqual(pj.layerCount(), layers);
    // The thick part has beads of its own height.
    var lp = try pj.planLayer(2);
    defer lp.deinit();
    for (lp.paths.items) |p| {
        const part = lp.partOf(p);
        if (part == 1 and p.feature == .outer_wall) try testing.expectApproxEqAbs(@as(f32, 0.2), p.height, 1e-4);
        if (part == 0 and p.feature == .outer_wall) try testing.expectApproxEqAbs(@as(f32, 0.1), p.height, 1e-4);
    }
}

test "plate job: copies slice once" {
    const gpa = testing.allocator;
    var meshes: [4]Mesh = undefined;
    for (&meshes, 0..) |*m, k| m.* = try testBox(@as(f64, @floatFromInt(k)) * 30 + 0.37, 10, @as(f64, @floatFromInt(k)) * 30 + 20.37, 30, 4);
    defer for (&meshes) |*m| m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.project.placement = .file;
    var parts: [4]PartInput = undefined;
    for (&parts, 0..) |*p, k| p.* = .{ .mesh = &meshes[k], .part = @intCast(k) };
    var pj = try PlateJob.init(gpa, s, &parts, .{});
    defer pj.deinit();
    // One job for the four copies.
    try testing.expectEqual(@as(usize, 1), pj.groups.len);
    try testing.expectEqual(@as(usize, 4), pj.instances.len);
    // Each copy has its walls at its own place.
    var lp = try pj.planLayer(5);
    defer lp.deinit();
    var outer = [_]usize{0} ** 4;
    for (lp.paths.items, 0..) |p, i| {
        if (p.feature != .outer_wall) continue;
        const part = lp.partOf(p);
        outer[part] += 1;
        const x = geom.toMm(lp.points.get(i)[0].x);
        const x0 = @as(f64, @floatFromInt(part)) * 30 + 0.37;
        try testing.expect(x > x0 - 1 and x < x0 + 21);
    }
    for (outer) |o| try testing.expectEqual(@as(usize, 1), o);
    // The outline of the level: one ring for each copy, at its place,
    // the same as the outline of the plan.
    // The parts are in print order: sort them by x.
    var rings: usize = 0;
    var k: usize = 0;
    var xs = [_]f64{0} ** 4;
    while (pj.levelOutline(5, k)) |o| : (k += 1) {
        for (0..o.paths.count()) |ri| {
            xs[k] = geom.toMm(o.paths.get(ri)[0].x + o.dx);
            rings += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), k);
    std.mem.sort(f64, &xs, {}, std.sort.asc(f64));
    for (xs, 0..) |x, i| {
        const x0 = @as(f64, @floatFromInt(i)) * 30 + 0.37;
        try testing.expect(x > x0 - 1 and x < x0 + 21);
    }
    try testing.expectEqual(lp.outline.count(), rings);
    try testing.expectEqual(@as(?PlateJob.PartOutline, null), pj.levelOutline(pj.layerCount(), 0));
    // A copy with other settings slices on its own.
    parts[3].changes = &.{.{ .name = "project.infill_density", .value = "0.5" }};
    var pj2 = try PlateJob.init(gpa, s, &parts, .{ .old = &pj });
    defer pj2.deinit();
    try testing.expectEqual(@as(usize, 2), pj2.groups.len);
}

test "plate job: a debug print of a few layers starts on the bed" {
    const gpa = std.testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var s: settings_mod.Settings = .{};
    s.engine.threads = 1;
    const parts = [_]PartInput{.{ .mesh = &mesh, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{});
    defer pj.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try pj.writeLevels(&out.writer, 20, 23);
    const text = out.written();
    // 3 layers, the first at its own height over the bed.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, ";LAYER:"));
    var lowest: f64 = 1e9;
    var it = std.mem.splitScalar(u8, text, '\n');
    var in_layers = false;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) in_layers = true;
        if (!in_layers) continue;
        if (std.mem.indexOf(u8, line, " Z")) |k| {
            const rest = line[k + 2 ..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            const z = std.fmt.parseFloat(f64, rest[0..end]) catch continue;
            lowest = @min(lowest, z);
        }
    }
    try std.testing.expect(lowest < 0.5);
}

