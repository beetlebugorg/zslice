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
//!    vertices after a move in X and Y), the same changes, no volumes, no
//!    marks, and no trees of the user are copies. A group of copies
//!    slices once: one engine job (see engine.Job), for the first part of
//!    the group. The paths of each other copy are the paths of that job,
//!    moved by the distance between the parts.
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
const stream_mod = @import("stream.zig");
const support_mod = @import("support.zig");
const islands_mod = @import("islands.zig");
const parallel = @import("parallel.zig");
const filaments_mod = @import("filaments.zig");
const paint_mod = @import("paint.zig");
const paint_split = @import("paint_split.zig");
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
    /// The trees of the user for the part, in the coordinates of the plate,
    /// and the key of the layers they were made for (see
    /// engine.Job.Options.trees), or null.
    trees: ?*const @import("support_skeleton.zig").Skeleton = null,
    trees_layers: u64 = 0,
    /// The id of the part for the toolpaths (for example, its index on
    /// the plate).
    part: u32,
    /// The paint of the triangles of `mesh` (see paint.zig), or null. A
    /// painted part slices as one job for each filament of its paint (see
    /// paint_split.zig). It must live as long as the job.
    paint: ?*const paint_mod.Paint = null,
    /// The split of a painted part, and the index of the filament of this
    /// input in it (set by `PlateJob.init`).
    paint_split: ?*paint_split.Split = null,
    paint_index: usize = 0,
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

/// The count of the level plans that the G-code writers made, for the
/// tests of the move streams.
pub var plans_made: std.atomic.Value(usize) = .init(0);

/// A group of copies: one job.
pub const Group = struct {
    job: Job,
    /// The part whose mesh the job slices.
    part: u32,
    /// The job slices one filament of a painted part.
    painted: bool = false,
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
    /// False: no search for the shapes that start in the air (`islands`
    /// stays empty). The G-code does not use them; a CLI slice needs none.
    islands: bool = true,
    /// Not null: the job keeps a move stream of each level (see
    /// `PlateJob.streams`), and gets the streams of the old job if the
    /// inputs of the plans are the same. The value is a hash of the
    /// inputs that the job does not get in `init`: the edits of the
    /// lines.
    streams: ?u64 = null,
    /// The filaments of the plate after the first: slot 2, 3, and on (see
    /// filaments.zig). The first is the filament of the settings. The
    /// strings must live as long as the job.
    filaments: []const settings_mod.Filament = &.{},
};

pub const PlateJob = struct {
    gpa: Allocator,
    /// The edits of the user on the lines (app/edits.zig), or null. The
    /// writer applies them to each layer plan.
    edits: ?*const @import("app/edits.zig").Edits = null,
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
    /// The move stream of each level (see stream.zig): the stored form of
    /// the print. `writeGcode` fills them. A level with a valid stream
    /// needs no plan: the G-code comes from the stream and the settings
    /// of this job. Empty without Options.streams.
    streams: []stream_mod.Stream = &.{},
    /// The key of the support of each level when its stream was made (see
    /// `supportKey`): the stamp leaves the support out, so an edit of the
    /// support (a tree, a mark, an area) plans only the levels whose
    /// support changed, and the level after each one.
    stream_support: []u64 = &.{},
    /// A hash of all inputs of the layer plans (see `planStamp`).
    stamp: u64 = 0,
    /// The filaments of the plate: slot 0 is the filament of the
    /// settings, then `Options.filaments`. One: no filament change.
    slots: []settings_mod.Filament = &.{},
    /// The paint splits of the painted parts, and the memory of the
    /// changes of their jobs.
    splits: []*paint_split.Split = &.{},
    arena: ?std.heap.ArenaAllocator = null,

    /// Slices each group of parts (steps 1 to 4 of the engine for each
    /// job), and finds the levels.
    pub fn init(gpa: Allocator, settings: Settings, parts_in: []const PartInput, opts: Options) Error!PlateJob {
        if (parts_in.len == 0) return error.EmptyMesh;
        const r = settings.resolve() catch return error.InvalidSettings;
        var pj: PlateJob = .{
            .gpa = gpa,
            .resolved = r,
            .monitor = opts.monitor,
            .threads = parallel.threadCount(settings.engine.threads),
        };
        errdefer pj.deinit();
        // A painted part: one input for each filament of its paint.
        var expanded: std.ArrayList(PartInput) = .empty;
        defer expanded.deinit(gpa);
        pj.slots = try gpa.alloc(settings_mod.Filament, 1 + @min(opts.filaments.len, filaments_mod.max_slots - 1));
        pj.slots[0] = settings.filament;
        for (pj.slots[1..], opts.filaments[0 .. pj.slots.len - 1]) |*d, f| d.* = f;
        try pj.expandPaint(settings, parts_in, &expanded);
        const parts = expanded.items;

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
            // A painted part slices again: its outlines are the regions of
            // its filaments.
            if (p.paint_split == null) if (opts.old) |o| for (o.groups) |*og| if (og.part == p.part and !og.painted) {
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
                .trees = p.trees,
                .trees_layers = p.trees_layers,
                .islands = opts.islands,
                .paint = if (p.paint_split) |sp| .{ .split = sp, .index = p.paint_index } else null,
            });
            errdefer job.deinit();
            // The scaled monitor lives only in this call.
            job.monitor = opts.monitor;
            job.keep_memos = opts.keep_memos;
            if (p.modifiers.len > 0) try job.setModifiers(p.modifiers);
            const layer_level = try gpa.alloc(u32, job.layers.len);
            groups.appendAssumeCapacity(.{ .job = job, .part = p.part, .layer_level = layer_level, .painted = p.paint_split != null });
        }
        pj.groups = try groups.toOwnedSlice(gpa);

        try pj.makeLevels(settings, opts.overrides);
        try pj.makeOutline0();
        try pj.makeIslands();
        if (opts.streams) |extra| {
            pj.stamp = planStamp(settings, parts, opts.overrides, keys, boxes, extra);
            const old_streams: ?*PlateJob = if (opts.old) |o| (if (o.stamp == pj.stamp and o.streams.len == pj.levels.len) o else null) else null;
            if (old_streams) |o| {
                // The same inputs of the plans: the streams are still right,
                // but for the levels whose support changed (writeRange).
                pj.streams = o.streams;
                o.streams = &.{};
                pj.stream_support = o.stream_support;
                o.stream_support = &.{};
            } else {
                pj.streams = try gpa.alloc(stream_mod.Stream, pj.levels.len);
                @memset(pj.streams, .{});
            }
            if (pj.stream_support.len != pj.levels.len) {
                gpa.free(pj.stream_support);
                pj.stream_support = try gpa.alloc(u64, pj.levels.len);
                @memset(pj.stream_support, 0);
            }
        }
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
        for (self.streams) |*s| s.deinit(gpa);
        gpa.free(self.streams);
        gpa.free(self.stream_support);
        gpa.free(self.slots);
        for (self.splits) |s| {
            s.deinit();
            gpa.destroy(s);
        }
        gpa.free(self.splits);
        if (self.arena) |*a| a.deinit();
        self.* = undefined;
    }

    /// True if a level has a move stream from the job before.
    pub fn hasStreams(self: *const PlateJob) bool {
        for (self.streams) |s| if (s.valid) return true;
        return false;
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
        var tool: u32 = 0;
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
            // The parts of the level, the nearest first. With many
            // filaments, the parts of the filament in the nozzle come
            // first, so a level changes the filament at most once for
            // each filament on it.
            const first: u32 = @intCast(entries.items.len);
            for (self.instances, done) |inst, *d| d.* = at[inst.group] == null;
            while (true) {
                var best: ?usize = null;
                var best_d: f64 = std.math.inf(f64);
                var best_same = false;
                for (self.instances, 0..) |inst, ii| {
                    if (done[ii]) continue;
                    const d = @import("geom.zig").hypot(inst.center[0] - last[0], inst.center[1] - last[1]);
                    const same = self.toolAt(inst.group, at[inst.group].?) == tool;
                    if ((same and !best_same) or (same == best_same and d < best_d)) {
                        best_d = d;
                        best = ii;
                        best_same = same;
                    }
                }
                const ii = best orelse break;
                done[ii] = true;
                last = self.instances[ii].center;
                tool = self.toolAt(self.instances[ii].group, at[self.instances[ii].group].?);
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

    /// The level of the last filament change of the print, or null: the
    /// filament of each entry in print order (see `toolAt`).
    pub fn lastChange(self: *const PlateJob) ?usize {
        if (self.slots.len < 2) return null;
        var last: ?usize = null;
        var tool: ?u32 = null;
        for (self.levels, 0..) |lv, i| for (self.entries[lv.first..lv.end]) |e| {
            const t = self.toolAt(self.instances[e.instance].group, e.layer);
            if (tool != null and tool.? != t) last = i;
            tool = t;
        };
        return last;
    }

    /// The prime towers of the print (see gcode.Towers): none with no
    /// tower or no change; one; or with Project.prime_tower_split, one for
    /// each family of materials that the print changes to, side by side
    /// to the left of the first one (a gap of a tower width).
    pub fn towers(self: *const PlateJob) @import("gcode.zig").Towers {
        const gcode = @import("gcode.zig");
        var out: gcode.Towers = .{};
        const one = self.tower() orelse return out;
        const s = self.resolved.settings;
        const n_slots = @min(self.slots.len, filaments_mod.max_slots);
        // The family of each slot, and the towers that a change goes to.
        var names: [gcode.Towers.max][8]u8 = undefined;
        var lens: [gcode.Towers.max]usize = undefined;
        var used = [_]bool{false} ** gcode.Towers.max;
        var fam_n: usize = 0;
        for (self.slots[0..n_slots], 0..) |f, i| {
            var buf: [8]u8 = undefined;
            const name = if (s.project.prime_tower_split) filaments_mod.family(f.material, &buf) else "ALL";
            var k: usize = 0;
            while (k < fam_n and !std.mem.eql(u8, names[k][0..lens[k]], name)) k += 1;
            if (k == fam_n) {
                if (fam_n == gcode.Towers.max) k = 0 else {
                    @memcpy(names[k][0..name.len], name);
                    lens[k] = name.len;
                    fam_n += 1;
                }
            }
            out.of_slot[i] = @intCast(k);
        }
        // A family gets a tower if a filament of it is ever changed to:
        // the support filaments (any layer), and the part changes.
        const p = s.project;
        const sup = filaments_mod.pathSlot(.support, p, n_slots);
        const iface = filaments_mod.pathSlot(.support_interface, p, n_slots);
        const own_support = p.support != .off and (p.support_filament > 0 or p.support_interface_filament > 0);
        if (own_support) {
            used[out.of_slot[sup]] = true;
            used[out.of_slot[iface]] = true;
        }
        var tool: ?u32 = null;
        for (self.levels) |lv| for (self.entries[lv.first..lv.end]) |e| {
            const t = self.toolAt(self.instances[e.instance].group, e.layer);
            if (tool != null and tool.? != t) used[out.of_slot[@min(t, n_slots - 1)]] = true;
            tool = t;
        };
        if (own_support) {
            // After the support, the print changes back to a part filament.
            var t2: ?u32 = null;
            for (self.levels) |lv| for (self.entries[lv.first..lv.end]) |e| {
                t2 = self.toolAt(self.instances[e.instance].group, e.layer);
                used[out.of_slot[@min(t2.?, n_slots - 1)]] = true;
            };
        }
        // Number the used families from 0, in slot order.
        var map = [_]u8{0} ** gcode.Towers.max;
        var n: usize = 0;
        for (0..fam_n) |k| if (used[k]) {
            map[k] = @intCast(n);
            var t = one;
            t.x = one.x - @as(f64, @floatFromInt(n)) * 2 * one.size;
            @memcpy(t.family[0..lens[k]], names[k][0..lens[k]]);
            out.list[n] = t;
            n += 1;
        };
        if (n == 0) {
            out.list[0] = one;
            n = 1;
        }
        out.n = n;
        for (out.of_slot[0..n_slots]) |*k| k.* = if (used[k.*]) map[k.*] else 0;
        out.stack = own_support;
        return out;
    }

    /// The prime tower of the print (see gcode.Tower), or null: a tool
    /// change printer with the tower on, and a filament change in the
    /// print. With own support filaments, a change can come on any layer.
    pub fn tower(self: *const PlateJob) ?@import("gcode.zig").Tower {
        const s = self.resolved.settings;
        if (s.machine.filament_change != .tool or !s.project.prime_tower) return null;
        const p = s.project;
        const own_support = p.support != .off and (p.support_filament > 0 or p.support_interface_filament > 0) and self.slots.len > 1;
        const last = self.lastChange() orelse (if (own_support) self.levels.len -| 1 else return null);
        const size = s.project.prime_tower_width;
        const margin = 10;
        return .{
            .x = if (s.project.prime_tower_x >= 0) s.project.prime_tower_x else s.machine.bed_size_x - size / 2 - margin,
            .y = if (s.project.prime_tower_y >= 0) s.project.prime_tower_y else s.machine.bed_size_y - size / 2 - margin,
            .size = size,
            .last_layer = last,
        };
    }

    /// The inputs of the parts, with one input for each filament of a
    /// painted part (see paint_split.zig). The filament of the part is the
    /// first; the input of each other filament has the change
    /// project.filament of its filament.
    fn expandPaint(self: *PlateJob, settings: Settings, parts: []const PartInput, out: *std.ArrayList(PartInput)) Error!void {
        const gpa = self.gpa;
        var splits: std.ArrayList(*paint_split.Split) = .empty;
        defer splits.deinit(gpa);
        errdefer for (splits.items) |s| {
            s.deinit();
            gpa.destroy(s);
        };
        for (parts) |p| {
            const paint = p.paint orelse {
                try out.append(gpa, p);
                continue;
            };
            if (paint.isEmpty() or self.slots.len < 2) {
                try out.append(gpa, p);
                continue;
            }
            // The filament of the part.
            var base: u32 = settings.project.filament;
            for (p.changes) |c| if (std.mem.eql(u8, c.name, "project.filament")) {
                base = std.fmt.parseInt(u32, std.mem.trim(u8, c.value, " "), 10) catch base;
            };
            const split = try gpa.create(paint_split.Split);
            split.* = paint_split.Split.init(gpa, p.mesh, paint, @intCast(@min(base, 255))) catch |e| {
                gpa.destroy(split);
                return e;
            };
            if (split.states.len < 2) {
                split.deinit();
                gpa.destroy(split);
                try out.append(gpa, p);
                continue;
            }
            try splits.append(gpa, split);
            if (self.arena == null) self.arena = .init(gpa);
            const a = self.arena.?.allocator();
            for (split.states, 0..) |st, k| {
                var q = p;
                q.paint_split = split;
                q.paint_index = k;
                if (k > 0) {
                    const ch = try a.alloc(settings_mod.Change, p.changes.len + 1);
                    @memcpy(ch[0..p.changes.len], p.changes);
                    ch[p.changes.len] = .{ .name = "project.filament", .value = try std.fmt.allocPrint(a, "{d}", .{st}) };
                    q.changes = ch;
                    // The marks and the trees of the user are of the part:
                    // the job of its own filament has them.
                    q.marks = &.{};
                    q.trees = null;
                    q.modifiers = &.{};
                }
                try out.append(gpa, q);
            }
        }
        self.splits = try splits.toOwnedSlice(gpa);
    }

    /// The slot of the filament of layer `layer` of the job of group `g`
    /// (see filaments.zig).
    pub fn toolAt(self: *const PlateJob, g: usize, layer: usize) u32 {
        if (self.slots.len < 2) return 0;
        return filaments_mod.slotOf(self.groups[g].job.resolvedAt(layer).settings.project.filament, self.slots.len);
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
        // The band of the skirt and the brim of the plate: the support of
        // each part keeps out of it (see layer.ringBand).
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const band = try layer_mod.ringBand(arena.allocator(), r, self.outline0, i);
        // The plan of each group on this level, made once for all its
        // copies. With support under the band, each copy has a plan of its
        // own: the band is at another place in the frame of each.
        const plans = try gpa.alloc(?LayerPlan, self.groups.len);
        defer gpa.free(plans);
        @memset(plans, null);
        defer for (plans) |*p| if (p.*) |*q| q.deinit();
        for (self.entries[lv.first..lv.end]) |e| {
            const inst = self.instances[e.instance];
            const ctx = ctxs[inst.group];
            if (band != null and hasSupport(ctx, e.layer)) {
                var own = ctx;
                own.ring_band = try moved(arena.allocator(), band.?, -inst.dx, -inst.dy);
                var p = try layer_mod.plan(gpa, own, e.layer);
                defer p.deinit();
                try lp.append(&p, inst.dx, inst.dy, inst.part, e.layer);
                continue;
            }
            if (plans[inst.group] == null) plans[inst.group] = try layer_mod.plan(gpa, ctx, e.layer);
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

    /// A hash of the support of level i: the support areas of each layer
    /// of each part on it.
    fn supportKey(self: *const PlateJob, i: usize) u64 {
        var h = std.hash.Wyhash.init(0x5a9);
        const lv = self.levels[i];
        for (self.entries[lv.first..lv.end]) |e| {
            const inst = self.instances[e.instance];
            const sup = self.groups[inst.group].job.support;
            h.update(std.mem.asBytes(&[_]u64{ inst.group, e.layer }));
            if (e.layer >= sup.len) continue;
            const sl = sup[e.layer];
            h.update(std.mem.asBytes(&@as(u8, @intFromBool(sl.hollow))));
            for ([_]*const geom.Paths{ &sl.body, &sl.interface, &sl.filled }) |ps| {
                h.update(std.mem.asBytes(&@as(u64, ps.count())));
                for (0..ps.count()) |k| h.update(std.mem.sliceAsBytes(ps.get(k)));
            }
        }
        return h.final();
    }

    /// The streams of the levels whose support changed since their stream
    /// was made go, and so does the stream of the level after each one (it
    /// starts where that level ends).
    fn dropChangedSupport(self: *const PlateJob) void {
        if (self.streams.len != self.levels.len or self.stream_support.len != self.levels.len) return;
        var drop_next = false;
        for (self.streams, self.stream_support, 0..) |*st, *key, i| {
            const now = self.supportKey(i);
            const changed = key.* != now;
            if (st.valid and (changed or drop_next)) {
                st.deinit(self.gpa);
                st.* = .{};
            }
            drop_next = changed;
            key.* = now;
        }
    }

    fn writeRange(self: *const PlateJob, out: *Writer, sink: ?Job.LayerSink, lo: usize, hi: usize) Error!engine.Stats {
        const gpa = self.gpa;
        if (lo == 0 and hi == self.levels.len) self.dropChangedSupport();
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
                _ = plans_made.fetchAdd(1, .monotonic);
                var lp = try c.pj.planLevel(g, c.ctxs, c.lo + i);
                if (c.pj.edits) |e| try e.apply(&lp);
                // The paths of one filament together (support of another
                // filament).
                try lp.groupByFilament(c.pj.levelResolved(c.lo + i), c.pj.slots.len);
                if (c.lo > 0) {
                    lp.z -= c.drop;
                    lp.index = @intCast(i);
                }
                return lp;
            }
            /// The settings of a plan from a stream (see stream.BindFn).
            fn bind(ctx: *const anyopaque, i: usize, lp: *LayerPlan, regions: []*const Resolved) void {
                const c: *const @This() = @ptrCast(@alignCast(ctx));
                const pj = c.pj;
                lp.resolved = pj.levelResolved(i);
                for (regions, lp.region_modifier, 0..) |*r, m, k| {
                    const part = if (k < lp.region_part.len) lp.region_part[k] else lp.part;
                    r.* = pj.pathResolved(part, i, if (m == LayerPlan.no_modifier) 0 else @as(usize, m) + 1);
                }
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
            // The streams are of the whole print.
            .streams = if (lo == 0 and hi == self.levels.len and self.streams.len == hi) self.streams else null,
            .bind = Ctx.bind,
            .slots = self.slots,
            .towers = if (lo == 0) self.towers() else .{},
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

/// A hash of the inputs of the layer plans and of the travels: all that a
/// move stream depends on (see stream.zig). The values of the patch
/// settings are not in it (see settings.patch_settings), so a job after
/// a change of one of them has the same stamp. A mesh adds its shape key
/// and its box: the caller of `PlateJob.init` gives an old job only if
/// each part has the same mesh.
fn planStamp(settings: Settings, parts: []const PartInput, overrides: []const settings_mod.Override, keys: []const u64, boxes: []const mesh_mod.Bounds3, extra: u64) u64 {
    var h = std.hash.Wyhash.init(0x57a3);
    const hv = settings_mod.hashValue;
    hv(&h, extra);
    settings_mod.hashPlanInputs(&settings, &h);
    const changes = struct {
        fn f(hh: *std.hash.Wyhash, list: []const settings_mod.Change) void {
            hv(hh, list.len);
            for (list) |c| {
                hv(hh, c.name);
                if (!settings_mod.isPatchSetting(c.name)) hv(hh, c.value);
            }
        }
    }.f;
    hv(&h, overrides.len);
    for (overrides) |o| {
        hv(&h, [2]f64{ o.z_min, o.z_max });
        hv(&h, o.name);
        if (!settings_mod.isPatchSetting(o.name)) hv(&h, o.value);
    }
    for (parts, keys, boxes) |p, k, b| {
        hv(&h, p.part);
        hv(&h, k);
        hv(&h, if (p.paint) |pp| pp.hash() else 0);
        hv(&h, p.paint_index);
        hv(&h, b.min);
        hv(&h, b.max);
        changes(&h, p.changes);
        hv(&h, p.modifiers.len);
        for (p.modifiers) |m| {
            const mb = m.mesh.bounds();
            hv(&h, shapeKey(m.mesh));
            hv(&h, mb.min);
            hv(&h, mb.max);
            hv(&h, m.order);
            changes(&h, m.changes);
        }
        // The marks and the trees change only the support: the support
        // key of each level (supportKey) covers them, so an edit of them
        // keeps the streams of the levels with the same support.
    }
    return h.final();
}

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
    if (p.paint_split != null or q.paint_split != null) return false;
    if (p.modifiers.len > 0 or q.modifiers.len > 0 or p.marks.len > 0 or q.marks.len > 0) return false;
    if (p.trees != null or q.trees != null) return false;
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

test "plate job: two filaments, a tool change for each change of the filament" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 3);
    defer m1.deinit(gpa);
    var m2 = try testBox(40, 0, 60, 20, 3);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    var red = s.filament;
    red.color = "#ff0000";
    red.nozzle_temp = 215;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{red} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    // Each level prints the filament in the nozzle first: one change on
    // each level, and none on the first part of the next level.
    const levels = pj.levels.len;
    try testing.expectEqual(@as(u32, @intCast(levels)), st.changes);
    try testing.expect(std.mem.indexOf(u8, g, "\nT1\n") != null);
    try testing.expect(std.mem.indexOf(u8, g, "\nT0\n") != null);
    try testing.expect(std.mem.indexOf(u8, g, "M109 S215") != null);
    // The prime tower: the flush of each change goes into it.
    try testing.expect(std.mem.indexOf(u8, g, ";TYPE:PRIME-TOWER") != null);
    // Each filament has its grams, with the flushes of the changes to it.
    try testing.expect(st.slot_g[0] > 0 and st.slot_g[1] > 0);
    try testing.expectApproxEqRel(st.filament_g, st.slot_g[0] + st.slot_g[1], 1e-9);
    try testing.expect(st.flush_mm > 0);

    // A pause: M600, and no flush.
    s.machine.filament_change = .pause;
    var pj2 = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{red} });
    defer pj2.deinit();
    var out2: Writer.Allocating = .init(gpa);
    defer out2.deinit();
    const st2 = try pj2.writeGcode(&out2.writer);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "M600") != null);
    try testing.expectEqual(@as(f64, 0), st2.flush_mm);

    // One filament for a z range: one change at the start of the range,
    // and one back after it.
    const one = [_]PartInput{.{ .mesh = &m1, .part = 0 }};
    const ov = [_]settings_mod.Override{.{ .z_min = 1, .z_max = 2, .name = "project.filament", .value = "2" }};
    var pj3 = try PlateJob.init(gpa, s, &one, .{ .filaments = &.{red}, .overrides = &ov });
    defer pj3.deinit();
    var out3: Writer.Allocating = .init(gpa);
    defer out3.deinit();
    const st3 = try pj3.writeGcode(&out3.writer);
    try testing.expectEqual(@as(u32, 2), st3.changes);
}

test "plate job: support with its own filament, one change on each layer" {
    const gpa = testing.allocator;
    // A post with a shelf on one side, 4 mm over the bed: support under
    // the shelf.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 8, 10, 6);
    try mesh_mod.shapes.addBox(&b, 8, 0, 4, 24, 10, 6);
    var m = try b.finish();
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.project.support = .everywhere;
    s.project.support_filament = 2;
    var white = s.filament;
    white.color = "#ffffff";
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    // The support lines print with filament 2 (T1), the part with T0.
    try testing.expect(st.slot_g[1] > 0 and st.slot_g[0] > 0);
    var it = std.mem.splitScalar(u8, g, '\n');
    var tool: u8 = 0;
    var support_t0: usize = 0;
    var support_t1: usize = 0;
    var feature: []const u8 = "";
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "T0")) tool = 0;
        if (std.mem.eql(u8, line, "T1")) tool = 1;
        if (std.mem.startsWith(u8, line, ";TYPE:")) feature = line[6..];
        // A line of support: a move in X or Y that extrudes (a retraction
        // after a change has no X).
        if (std.mem.eql(u8, feature, "SUPPORT") and std.mem.startsWith(u8, line, "G1 X") and std.mem.indexOf(u8, line, " E") != null) {
            if (tool == 0) support_t0 += 1 else support_t1 += 1;
        }
    }
    try testing.expect(support_t1 > 0);
    try testing.expectEqual(@as(usize, 0), support_t0);
    // A layer with support and part changes once: no more changes than
    // levels.
    try testing.expect(st.changes <= pj.levels.len);
    try testing.expect(st.changes >= 2);
}

test "plate job: a painted letter prints with its own filament" {
    const gpa = testing.allocator;
    // A base 30 x 20 x 3 and a block "letter" 6 x 6 x 2 on it, with all
    // the faces of the letter painted with filament 2.
    var b: mesh_mod.Builder = .init(gpa);
    defer b.deinit();
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 30, 20, 3);
    const base_faces = 12;
    try mesh_mod.shapes.addBox(&b, 12, 7, 3, 18, 13, 5);
    var m = try b.finish();
    defer m.deinit(gpa);
    var paint: paint_mod.Paint = .{};
    defer paint.deinit(gpa);
    for (base_faces..m.faces.items.len) |i| try paint.setTriangle(gpa, i, 2);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    var red = s.filament;
    red.color = "#ff0000";
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0, .paint = &paint }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{red} });
    defer pj.deinit();
    // Two jobs: the base filament and the letter filament.
    try testing.expectEqual(@as(usize, 2), pj.groups.len);
    const letter = &pj.groups[1].job;
    // The letter job prints only the letter: no outline on the base
    // layers, and on the letter layers the 6 x 6 mm square.
    var with_outline: usize = 0;
    for (letter.outlines, letter.layers) |o, l| {
        if (o.isEmpty()) continue;
        with_outline += 1;
        var area: f64 = 0;
        for (0..o.count()) |k| area += geom.areaMm2(o.get(k));
        if (l.z > 3.5) try testing.expectApproxEqAbs(@as(f64, 36), area, 1.5);
    }
    try testing.expect(with_outline >= 8 and with_outline <= 12);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    // The base layers print with filament 1, the letter layers with 2.
    try testing.expectEqual(@as(u32, 1), st.changes);
    try testing.expect(st.slot_g[1] > 0);
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


/// True if a plan context has support on layer i.
fn hasSupport(ctx: layer_mod.Context, i: usize) bool {
    if (i >= ctx.support.len) return false;
    const sl = ctx.support[i];
    return !sl.body.isEmpty() or !sl.interface.isEmpty();
}

/// Paths moved by (dx, dy) in the units of geom.
fn moved(a: Allocator, p: Paths, dx: i64, dy: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    for (0..p.count()) |k| {
        const src = p.get(k);
        const pts = try a.alloc(geom.Point, src.len);
        for (src, pts) |q, *d| d.* = .init(q.x + dx, q.y + dy);
        try out.append(a, pts);
    }
    return out;
}

/// The least distance (mm) between the points of the paths of feature `a`
/// and the segments of the paths of feature `b` in a plan.
fn leastGap(lp: *const LayerPlan, a: settings_mod.Feature, b: settings_mod.Feature) f64 {
    var best: f64 = std.math.inf(f64);
    for (lp.paths.items, 0..) |pa, i| {
        if (pa.feature != a) continue;
        for (lp.points.get(i)) |p| {
            for (lp.paths.items, 0..) |pb, j| {
                if (pb.feature != b) continue;
                const q = lp.points.get(j);
                for (q[0 .. q.len - 1], q[1..]) |u, v| {
                    const ux = geom.toMm(u.x);
                    const uy = geom.toMm(u.y);
                    const dx = geom.toMm(v.x) - ux;
                    const dy = geom.toMm(v.y) - uy;
                    const px = geom.toMm(p.x) - ux;
                    const py = geom.toMm(p.y) - uy;
                    const l2 = dx * dx + dy * dy;
                    const t = if (l2 > 0) std.math.clamp((px * dx + py * dy) / l2, 0, 1) else 0;
                    best = @min(best, @sqrt((px - t * dx) * (px - t * dx) + (py - t * dy) * (py - t * dy)));
                }
            }
        }
    }
    return best;
}

test "plate job: support keeps out of the brim of the plate" {
    const gpa = testing.allocator;
    // Two parts, each a box with a slab 10 mm out to +x at 2..4 mm: support
    // under the slab reaches the bed in the band of the brim.
    var meshes: [2]Mesh = undefined;
    for (&meshes, 0..) |*m, k| {
        const x0 = 30 + @as(f64, @floatFromInt(k)) * 60;
        var b: mesh_mod.Builder = .init(gpa);
        try mesh_mod.shapes.addBox(&b, x0, 50, 0, x0 + 10, 60, 6);
        try mesh_mod.shapes.addBox(&b, x0 + 10, 50, 2, x0 + 20, 60, 4);
        m.* = try b.finish();
    }
    defer for (&meshes) |*m| m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.placement = .file;
    s.project.support = .everywhere;
    s.project.brim_width = 5;
    var parts: [2]PartInput = undefined;
    for (&parts, 0..) |*p, k| p.* = .{ .mesh = &meshes[k], .part = @intCast(k) };
    var pj = try PlateJob.init(gpa, s, &parts, .{});
    defer pj.deinit();
    var lp = try pj.planLayer(0);
    defer lp.deinit();
    var support: usize = 0;
    var brim: usize = 0;
    for (lp.paths.items) |p| {
        if (p.feature == .support) support += 1;
        if (p.feature == .skirt) brim += 1;
    }
    try testing.expect(support > 0 and brim > 0);
    const r = try s.resolve();
    try testing.expect(leastGap(&lp, .support, .skirt) >= r.first_layer_line_width * 0.99);
}

test "plate job: no island search when the caller needs none, and the same G-code" {
    const gpa = testing.allocator;
    // A box, and a block in the air beside it, held by a bridge at the
    // top: the block starts in the air (an island) with support off.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 50, 50, 0, 60, 60, 10);
    try mesh_mod.shapes.addBox(&b, 70, 50, 6, 80, 60, 10);
    try mesh_mod.shapes.addBox(&b, 60, 50, 9, 70, 60, 10);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.placement = .file;
    const parts = [_]PartInput{.{ .mesh = &mesh, .part = 0 }};
    var with = try PlateJob.init(gpa, s, &parts, .{});
    defer with.deinit();
    var without = try PlateJob.init(gpa, s, &parts, .{ .islands = false });
    defer without.deinit();
    try testing.expect(with.islands.len > 0);
    try testing.expectEqual(@as(usize, 0), without.islands.len);
    const a = try gcodeOf(&with);
    defer gpa.free(a);
    const c = try gcodeOf(&without);
    defer gpa.free(c);
    try testing.expectEqualStrings(a, c);
}

test "plate job: the G-code of a Bambu Lab X2D has the config block of Bambu Studio" {
    const gpa = testing.allocator;
    var m = try testBox(0, 0, 10, 10, 1);
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.machine.model = "bambu-lab-x2d";
    s.machine.filament_change = .tool;
    var ext = s.filament;
    ext.nozzle = 1;
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{ext} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try pj.writeGcode(&out.writer);
    const g = out.written();
    // The blocks come first, as Bambu Studio writes them.
    try testing.expect(std.mem.startsWith(u8, g, "; HEADER_BLOCK_START\n"));
    try testing.expect(std.mem.indexOf(u8, g, "; CONFIG_BLOCK_END\n\n; EXECUTABLE_BLOCK_START\n;FLAVOR:Marlin") != null);
    try testing.expect(std.mem.endsWith(u8, g, "; EXECUTABLE_BLOCK_END\n"));
    for ([_][]const u8{
        "; HEADER_BLOCK_START\n",
        "; CONFIG_BLOCK_START\n",
        "; printer_model = Bambu Lab X2D\n",
        "; extruder_nozzle_stats = Standard#1;Standard#1\n",
        "; filament_nozzle_map = 0,1\n",
        "; filament_extruder_variant = \"Direct Drive Standard\";\"Bowden Standard\"\n",
        "; printer_extruder_variant = \"Direct Drive Standard\";\"Bowden Standard\"\n",
        "; extruder_type = Direct Drive,Bowden\n",
        "; filament_map = 1,2\n",
        "; printer_extruder_id = 1,2\n",
        "; physical_extruder_map = 1,0\n",
        "; curr_bed_type = Textured PEI Plate\n",
        "; CONFIG_BLOCK_END\n",
    }) |want| {
        if (std.mem.indexOf(u8, g, want) == null) {
            std.debug.print("missing: {s}", .{want});
            return error.TestUnexpectedResult;
        }
    }
    // A printer of another maker: no such block.
    s.machine.model = "creality-ender-3";
    var pj2 = try PlateJob.init(gpa, s, &parts, .{});
    defer pj2.deinit();
    var out2: Writer.Allocating = .init(gpa);
    defer out2.deinit();
    _ = try pj2.writeGcode(&out2.writer);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "CONFIG_BLOCK") == null);
}

test "plate job: a PLA part with a PETG support interface, and a tower for each" {
    const gpa = testing.allocator;
    // A post with a shelf on one side, 4 mm over the bed: support under
    // the shelf, with interface layers under it.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 8, 10, 6);
    try mesh_mod.shapes.addBox(&b, 8, 0, 4, 24, 10, 6);
    var m = try b.finish();
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.project.support = .everywhere;
    s.project.support_interface_filament = 2;
    var petg = s.filament;
    petg.material = "PETG";
    petg.color = "#2050e0";
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{petg} });
    defer pj.deinit();
    // Two towers: PLA and PETG, apart; filament 1 to the first.
    const tw = pj.towers();
    try testing.expectEqual(@as(usize, 2), tw.n);
    try testing.expect(tw.stacked());
    try testing.expect(@abs(tw.list[0].x - tw.list[1].x) >= tw.list[0].size * 2 - 1e-9);
    try testing.expect(tw.of_slot[0] != tw.of_slot[1]);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    // The interface prints with T1; the support body and the part with
    // T0. Each tower line prints with the filament of its tower.
    var it = std.mem.splitScalar(u8, g, '\n');
    var tool: u8 = 0;
    var feature: []const u8 = "";
    var iface_t1: usize = 0;
    var iface_t0: usize = 0;
    var body_t1: usize = 0;
    var tower_x: [2]?f64 = .{ null, null };
    var mixed = false;
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "T0")) tool = 0;
        if (std.mem.eql(u8, line, "T1")) tool = 1;
        if (std.mem.startsWith(u8, line, ";TYPE:")) feature = line[6..];
        const extrudes = std.mem.startsWith(u8, line, "G1 X") and std.mem.indexOf(u8, line, " E") != null;
        if (!extrudes) continue;
        if (std.mem.eql(u8, feature, "SUPPORT-INTERFACE")) {
            if (tool == 1) iface_t1 += 1 else iface_t0 += 1;
        }
        if (std.mem.eql(u8, feature, "SUPPORT") and tool == 1) body_t1 += 1;
        if (std.mem.eql(u8, feature, "PRIME-TOWER")) {
            const x = std.fmt.parseFloat(f64, line[4 .. std.mem.indexOfScalarPos(u8, line, 4, ' ') orelse line.len]) catch continue;
            // The tower of this tool: its x side of the gap between them.
            const mid = (tw.list[0].x + tw.list[1].x) / 2;
            const side: usize = if ((x > mid) == (tw.list[0].x > mid)) 0 else 1;
            if (side != tw.of_slot[tool]) mixed = true;
            tower_x[side] = x;
        }
    }
    try testing.expect(iface_t1 > 0);
    try testing.expectEqual(@as(usize, 0), iface_t0);
    try testing.expectEqual(@as(usize, 0), body_t1);
    try testing.expect(st.changes > 0);
    // No PETG on the PLA tower, no PLA on the PETG tower.
    try testing.expect(!mixed);
    try testing.expect(tower_x[0] != null and tower_x[1] != null);
    try testing.expect(st.tower_layers[0] > 0 and st.tower_layers[1] > 0);
}

test "plate job: a change flushes into the infill of the new filament" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 6);
    defer m1.deinit(gpa);
    var m2 = try testBox(40, 0, 60, 20, 6);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.filament.color = "#000000";
    var white = s.filament;
    white.color = "#ffffff";
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    const area = pj.resolved.filament_area;
    const m = pj.resolved.settings.machine;
    // Each change: its full flush, and the infill (FILL) right after its
    // tower lines. The hidden lines take the flush down to
    // gcode.min_flush_mm3, and the rest goes into the tower.
    var full_mm: f64 = 0;
    var hidden_mm: f64 = 0;
    var fill_e: f64 = 0;
    var full_mm3: f64 = 0;
    var in_run = false;
    var seen_tower = false;
    var walls_after = false;
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        const change = std.mem.startsWith(u8, line, "; filament change");
        if (change or std.mem.startsWith(u8, line, ";LAYER:")) {
            hidden_mm += @min(fill_e, @max(0, full_mm3 - @import("gcode.zig").min_flush_mm3) / area);
            fill_e = 0;
            full_mm3 = 0;
            in_run = false;
            seen_tower = false;
        }
        if (change) {
            const to_white = std.mem.endsWith(u8, line, "to filament 2");
            full_mm3 = filaments_mod.flushVolume(if (to_white) "#000000" else "#ffffff", if (to_white) "#ffffff" else "#000000", m.flush_volume, 1);
            full_mm += full_mm3 / area;
            continue;
        }
        if (std.mem.startsWith(u8, line, ";TYPE:")) {
            const t = line[6..];
            if (std.mem.eql(u8, t, "PRIME-TOWER")) {
                seen_tower = full_mm3 > 0;
            } else if (seen_tower and std.mem.eql(u8, t, "FILL")) {
                in_run = true;
                seen_tower = false;
            } else {
                if (in_run and std.mem.startsWith(u8, t, "WALL")) walls_after = true;
                in_run = false;
                seen_tower = false;
            }
            continue;
        }
        if (!in_run or !std.mem.startsWith(u8, line, "G1 X")) continue;
        const k = std.mem.indexOf(u8, line, " E") orelse continue;
        var end = k + 2;
        while (end < line.len and line[end] != ' ') end += 1;
        fill_e += try std.fmt.parseFloat(f64, line[k + 2 .. end]);
    }
    hidden_mm += @min(fill_e, @max(0, full_mm3 - @import("gcode.zig").min_flush_mm3) / area);
    try testing.expect(st.flush_hidden_mm > 0);
    try testing.expect(walls_after);
    // The full flush of each change is in the tower or in the infill.
    try testing.expectApproxEqRel(full_mm, st.flush_mm + st.flush_hidden_mm, 1e-9);
    // The infill takes its exact volume (E has 5 decimals).
    try testing.expectApproxEqAbs(hidden_mm, st.flush_hidden_mm, 1e-4 * @as(f64, @floatFromInt(st.changes)));

    // Off: the changes flush their full volume into the tower.
    s.project.flush_into_hidden = false;
    var pj2 = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pj2.deinit();
    var out2: Writer.Allocating = .init(gpa);
    defer out2.deinit();
    const st2 = try pj2.writeGcode(&out2.writer);
    try testing.expectEqual(@as(f64, 0), st2.flush_hidden_mm);
    try testing.expectEqual(st.changes, st2.changes);
    try testing.expectApproxEqRel(full_mm, st2.flush_mm, 1e-9);
}

test "plate job: a layer of two filaments from its move stream keeps its print order" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 4);
    defer m1.deinit(gpa);
    var m2 = try testBox(40, 0, 60, 20, 4);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.filament.color = "#000000";
    var white = s.filament;
    white.color = "#ffffff";
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white}, .streams = 0 });
    defer pj.deinit();
    const a = try gcodeOf(&pj);
    defer gpa.free(a);
    // The next job runs each layer from its stream: the paths in print
    // order, with their ranks. It makes no plan, and the same G-code.
    var pj2 = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white}, .streams = 0, .old = &pj });
    defer pj2.deinit();
    const plans = plans_made.load(.monotonic);
    const b = try gcodeOf(&pj2);
    defer gpa.free(b);
    try testing.expectEqual(plans, plans_made.load(.monotonic));
    try testing.expectEqualStrings(a, b);
}

test "plate job: the flush planner puts red between black and white" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 3);
    defer m1.deinit(gpa);
    var m2 = try testBox(30, 0, 50, 20, 3);
    defer m2.deinit(gpa);
    var m3 = try testBox(60, 0, 80, 20, 3);
    defer m3.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.filament.color = "#000000";
    var white = s.filament;
    white.color = "#ffffff";
    var red = s.filament;
    red.color = "#ff0000";
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
        .{ .mesh = &m3, .part = 2, .changes = &.{.{ .name = "project.filament", .value = "3" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{ white, red } });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    // Black to white flushes the most (see filaments.flushVolume). Each
    // layer goes black, red, white or white, red, black: two changes, and
    // none from black to white. The rule up and down by slot has one on
    // each even layer.
    try testing.expect(std.mem.indexOf(u8, g, "filament 1 to filament 2\n") == null);
    try testing.expectEqual(@as(u32, @intCast(2 * pj.levels.len)), st.changes);
}
