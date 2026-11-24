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
//! Sequential printing (`project.print_sequence = by_object`): steps 4
//! and 5 make the levels of one part at a time, the parts in the order of
//! their ids (the plate list). A part is all the instances with its id:
//! the jobs of the filaments of a painted part print together. The first
//! level of each part after the first has a lift: the z over all the
//! parts before it, so the head goes up, over to the new part, and then
//! down (see gcode.Emitter.paths). Such a plate has no prime tower and no
//! move streams.
//!
//! A plate with one part and no settings of its own gives the same G-code
//! as one job of its mesh: then the plan of a level is the plan of the
//! job, with its own skirt and brim.
//!
//! The prime towers (see `PlateJob.towers`): for a print with tool
//! changes, one tower (or one for each family of materials), as large as
//! the most purge of one layer, and the last level with a change into
//! each. The tower grows on each level up to it.
//!
//! References (see docs/references/papers-and-algorithms.md): the greedy nearest-neighbor order.
//! Sequential printing: the head clearance model of PrusaSlicer and
//! OrcaSlicer (see docs/references/prusaslicer.md).
//! The prime tower: see docs/references/prusaslicer.md and
//! docs/references/bambu-studio.md. A part that sinks into the bed
//! (bed_z 0): see docs/references/prusaslicer.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom.zig");
const mesh_mod = @import("mesh.zig");
const settings_mod = @import("settings.zig");
const engine = @import("engine.zig");
const gcode_mod = @import("gcode.zig");
const layer_mod = @import("layer.zig");
const stream_mod = @import("stream.zig");
const support_mod = @import("support.zig");
const islands_mod = @import("islands.zig");
const parallel = @import("parallel.zig");
const filaments_mod = @import("filaments.zig");
const paint_mod = @import("paint.zig");
const paint_split = @import("paint_split.zig");
const body_region = @import("body_region.zig");
const label_mod = @import("label.zig");
const Mesh = mesh_mod.Mesh;
const Settings = settings_mod.Settings;
const Resolved = settings_mod.Resolved;
const LayerPlan = layer_mod.LayerPlan;
const Job = engine.Job;
const Error = engine.Error;
const Paths = geom.Paths;
const clip = @import("clip.zig");

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
    /// The filament picks of some layers of the part, the oldest first, in
    /// the coordinates of the plate (see body_region.zig).
    picks: []const body_region.Pick = &.{},
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
    /// The labels of the part (see label.zig), in the coordinates of the
    /// plate (see plate.Part.placeLabel). A part with labels slices as a
    /// painted part: one more job for each label. They must live as long
    /// as the job.
    labels: []const label_mod.Label = &.{},
    /// The name of the part, for the object labels of the G-code (see
    /// Machine.label_objects). It must live as long as the job.
    name: []const u8 = "",
};

/// A part on the plate: the group whose job slices it, and its move from
/// the part of that job.
pub const Instance = struct {
    part: u32,
    group: u32,
    /// The name of the part (see PartInput.name).
    name: []const u8 = "",
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
    /// The split of the painted part, and the index of the filament of
    /// the job in it.
    split: ?*const paint_split.Split = null,
    paint_index: usize = 0,
    /// The level of each layer of the job.
    layer_level: []u32,
    /// The filament picks of the part, cut at the layers of the job.
    picks: []const LayerPick = &.{},
};

/// A filament pick, cut at each layer of a job (see `PlateJob.markPicks`).
const LayerPick = struct { outlines: []const Paths, filament: u8 };

/// The top of a layer of a group (see `PlateJob.makeLevels`).
const Top_ = struct { z: f64, group: u32, layer: u32 };

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
    /// Sequential printing: the z that the head goes up to before it goes
    /// to this level (over the parts that it printed), or 0.
    lift: f64 = 0,
};

/// The margin over the highest printed part for the travel to the next
/// part in sequential printing (mm).
pub const lift_margin = 2.0;

/// A part that the app left out of the slice: lower than half of the
/// first layer, so no layer cuts it (see App and checks.fitIssues).
pub const LeftOut = struct {
    name: [48]u8 = undefined,
    name_len: usize = 0,
    /// Its height (mm) and the center of its box on the bed.
    height: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,

    pub fn of(name: []const u8, height: f64, x: f64, y: f64) LeftOut {
        var o: LeftOut = .{ .height = height, .x = x, .y = y };
        o.name_len = @min(name.len, o.name.len);
        @memcpy(o.name[0..o.name_len], name[0..o.name_len]);
        return o;
    }

    pub fn nameOf(o: *const LeftOut) []const u8 {
        return o.name[0..o.name_len];
    }
};

pub const Options = struct {
    /// The parts that the app left out of the slice (at most 8 stay).
    left_out: []const LeftOut = &.{},
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
    /// The parts print one at a time (see the file comment).
    sequential: bool = false,
    /// The parts left out of the slice (Options.left_out).
    left_out: [8]LeftOut = undefined,
    left_out_n: usize = 0,
    /// The filaments of the plate: slot 0 is the filament of the
    /// settings, then `Options.filaments`. One: no filament change.
    slots: []settings_mod.Filament = &.{},
    /// The paint splits of the painted parts, and the memory of the
    /// changes of their jobs.
    splits: []*paint_split.Split = &.{},
    arena: ?std.heap.ArenaAllocator = null,
    /// The slots of the filament picks on each level, as a mask, or empty
    /// with no pick.
    level_picks: []u32 = &.{},

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
        // The nozzle of each filament: a part on the second nozzle gets
        // its line width.
        const slot_nozzles = settings_mod.SlotNozzles.of(pj.slots);
        pj.resolved = settings.resolveFor(slot_nozzles) catch return error.InvalidSettings;
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
            var inst: Instance = .{ .part = p.part, .name = p.name, .group = @intCast(reps.items.len), .center = .{ (b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2 } };
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
                .slots = slot_nozzles,
                // The bed is at z 0: a part with a lift floats or sinks
                // (plate.Part.z).
                .bed_z = 0,
            });
            errdefer job.deinit();
            // The scaled monitor lives only in this call.
            job.monitor = opts.monitor;
            job.keep_memos = opts.keep_memos;
            if (p.modifiers.len > 0) try job.setModifiers(p.modifiers);
            // The picks of the part, cut as the job cuts its mesh. One
            // filament on the plate: a pick has no effect.
            var layer_picks: []LayerPick = &.{};
            if (p.picks.len > 0 and pj.slots.len > 1) {
                if (pj.arena == null) pj.arena = .init(gpa);
                const pa = pj.arena.?.allocator();
                layer_picks = try pa.alloc(LayerPick, p.picks.len);
                for (p.picks, layer_picks) |pk, *lp| lp.* = .{ .outlines = try job.sliceExtra(pa, pk.mesh), .filament = pk.filament };
            }
            const layer_level = try gpa.alloc(u32, job.layers.len);
            groups.appendAssumeCapacity(.{ .job = job, .part = p.part, .layer_level = layer_level, .painted = p.paint_split != null, .split = p.paint_split, .paint_index = p.paint_index, .picks = layer_picks });
        }
        pj.groups = try groups.toOwnedSlice(gpa);

        pj.left_out_n = @min(opts.left_out.len, pj.left_out.len);
        @memcpy(pj.left_out[0..pj.left_out_n], opts.left_out[0..pj.left_out_n]);
        pj.sequential = settings.project.print_sequence == .by_object and !pj.single();
        try pj.makeLevels(settings, opts.overrides, slot_nozzles);
        try pj.makeLevelPicks();
        try pj.makeOutline0();
        try pj.makeIslands();
        // A sequential plate has no move streams: a stream starts where the
        // level before it ends, and a lift moves the head between parts.
        if (opts.streams) |extra| if (!pj.sequential) {
            pj.stamp = planStamp(settings, parts, opts.overrides, keys, boxes, extra ^ slot_nozzles.key());
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
        };
        return pj;
    }

    /// Frees the memos of the job of each group (see Job.dropMemos).
    pub fn dropMemos(self: *PlateJob) void {
        for (self.groups) |*g| g.job.dropMemos();
    }

    /// `dropMemos`, but the memos go to `out` (in the gpa of the job), and
    /// the caller frees them.
    pub fn takeMemos(self: *PlateJob, out: *std.ArrayList(layer_mod.Memo)) Allocator.Error!void {
        for (self.groups) |*g| try g.job.takeMemos(out);
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
        gpa.free(self.level_picks);
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
    fn makeLevels(self: *PlateJob, settings: Settings, overrides: []const settings_mod.Override, slot_nozzles: settings_mod.SlotNozzles) Error!void {
        const gpa = self.gpa;
        var tops: std.ArrayList(Top_) = .empty;
        defer tops.deinit(gpa);
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
        // The parts of each pass: all parts (by layer), or one part a pass
        // (sequential), in the order of their ids.
        const in_pass = try gpa.alloc(bool, self.instances.len);
        defer gpa.free(in_pass);
        const use_group = try gpa.alloc(bool, self.groups.len);
        defer gpa.free(use_group);
        var next_part: ?u32 = null;
        if (self.sequential) {
            for (self.instances) |inst| next_part = if (next_part) |p| @min(p, inst.part) else inst.part;
        }
        // The top of the parts that printed before (sequential).
        var printed_top: f64 = 0;
        while (true) {
            const part = next_part;
            for (self.instances, in_pass) |inst, *ip| ip.* = part == null or inst.part == part.?;
            @memset(use_group, false);
            for (self.instances, in_pass) |inst, ip| if (ip) {
                use_group[inst.group] = true;
            };
            tops.clearRetainingCapacity();
            for (self.groups, 0..) |g, gi| if (use_group[gi]) for (g.job.layers, 0..) |l, li| {
                try tops.append(gpa, .{ .z = l.z, .group = @intCast(gi), .layer = @intCast(li) });
            };
            const pass_first = levels.items.len;
            try self.levelsOf(tops.items, in_pass, at, done, &levels, &entries, &last, &tool);
            if (part == null) break;
            if (pass_first > 0 and pass_first < levels.items.len) levels.items[pass_first].lift = @min(printed_top + lift_margin, @max(settings.machine.max_height, printed_top));
            for (levels.items[pass_first..]) |lv| printed_top = @max(printed_top, lv.z);
            // The next part id.
            var nxt: ?u32 = null;
            for (self.instances) |inst| if (inst.part > part.?) {
                nxt = if (nxt) |p| @min(p, inst.part) else inst.part;
            };
            next_part = nxt orelse break;
        }
        self.levels = try levels.toOwnedSlice(gpa);
        self.entries = try entries.toOwnedSlice(gpa);
        try self.levelSettings(settings, overrides, slot_nozzles);
    }

    /// The levels of the parts with `in_pass` from the layer tops `tops`
    /// (step 4 and 5 of the file comment), after the levels so far.
    fn levelsOf(self: *PlateJob, tops: []Top_, in_pass: []const bool, at: []?u32, done: []bool, levels: *std.ArrayList(Level), entries: *std.ArrayList(Entry), last: *[2]f64, tool: *u32) Error!void {
        const gpa = self.gpa;
        const Top = Top_;
        std.mem.sort(Top, tops, {}, struct {
            fn lt(_: void, x: Top, y: Top) bool {
                if (x.z != y.z) return x.z < y.z;
                return x.group < y.group;
            }
        }.lt);
        var k: usize = 0;
        while (k < tops.len) {
            const z = tops[k].z;
            @memset(at, null);
            var height: f64 = 0;
            const level: u32 = @intCast(levels.items.len);
            while (k < tops.len and tops[k].z - z < z_eps) : (k += 1) {
                const t = tops[k];
                at[t.group] = t.layer;
                self.groups[t.group].layer_level[t.layer] = level;
                height = @max(height, self.groups[t.group].job.layers[t.layer].height);
            }
            // The parts of the level, the nearest first. With many
            // filaments, the parts of the filament in the nozzle come
            // first, so a level changes the filament at most once for
            // each filament on it.
            const first: u32 = @intCast(entries.items.len);
            for (self.instances, done, in_pass) |inst, *d, ip| d.* = !ip or at[inst.group] == null;
            while (true) {
                var best: ?usize = null;
                var best_d: f64 = std.math.inf(f64);
                var best_same = false;
                for (self.instances, 0..) |inst, ii| {
                    if (done[ii]) continue;
                    const d = @import("geom.zig").hypot(inst.center[0] - last[0], inst.center[1] - last[1]);
                    const same = self.toolAt(inst.group, at[inst.group].?) == tool.*;
                    if ((same and !best_same) or (same == best_same and d < best_d)) {
                        best_d = d;
                        best = ii;
                        best_same = same;
                    }
                }
                const ii = best orelse break;
                done[ii] = true;
                last.* = self.instances[ii].center;
                tool.* = self.toolAt(self.instances[ii].group, at[self.instances[ii].group].?);
                try entries.append(gpa, .{ .instance = @intCast(ii), .layer = at[self.instances[ii].group].? });
            }
            try levels.append(gpa, .{ .z = z, .height = height, .first = first, .end = @intCast(entries.items.len) });
        }
    }

    /// The settings of each level, with the overrides that cover it.
    fn levelSettings(self: *PlateJob, settings: Settings, overrides: []const settings_mod.Override, slot_nozzles: settings_mod.SlotNozzles) Error!void {
        const gpa = self.gpa;
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
            try list.append(gpa, s.resolveFor(slot_nozzles) catch return error.InvalidSettings);
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
        // A pick changes the filament on its level, and the level after
        // it can change back.
        for (self.level_picks, 0..) |m, i| if (m != 0) {
            last = @max(last orelse 0, @min(i + 1, self.levels.len - 1));
        };
        return last;
    }

    /// The highest level with support of any part, or null for none: a
    /// support filament can change on each level up to it.
    pub fn supportTop(self: *const PlateJob) ?usize {
        var top: ?usize = null;
        for (self.groups) |g| {
            var j = g.job.support.len;
            while (j > 0) {
                j -= 1;
                const sl = g.job.support[j];
                if (sl.body.ends.items.len == 0 and sl.interface.ends.items.len == 0 and sl.filled.ends.items.len == 0) continue;
                if (j < g.layer_level.len) top = @max(top orelse 0, g.layer_level[j]);
                break;
            }
        }
        return top;
    }

    /// The highest level with sparse infill of any part, or null for
    /// none: an infill filament of its own (Project.infill_filament) can
    /// change on each level up to it. The top skin layers of each part
    /// have no sparse infill.
    pub fn infillTop(self: *const PlateJob) ?usize {
        var top: ?usize = null;
        for (self.groups) |g| {
            const n = g.job.layers.len;
            if (n == 0) continue;
            const skin = g.job.resolvedAt(n - 1).top_layers;
            if (n <= skin) continue;
            const j = n - 1 - skin;
            if (j < g.layer_level.len) top = @max(top orelse 0, g.layer_level[j]);
        }
        return top;
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
        // A family gets a tower if a filament of it is ever changed to,
        // and the tower grows up to the last level with such a change: a
        // level whose filament differs from the one before, or a level of
        // more filaments (its order of filaments can change), and each
        // level with own support filaments up to the top of the support.
        const p = s.project;
        const sup = filaments_mod.pathSlot(.support, p, n_slots);
        const iface = filaments_mod.pathSlot(.support_interface, p, n_slots);
        // The infill of its own filament (project.infill_filament) changes
        // the filament inside a layer too, up to the top of the infill.
        const fill = filaments_mod.lineSlot(.infill, true, p, n_slots);
        const own_infill = ownInfill(p, n_slots);
        const own_support = p.support != .off and (p.support_filament > 0 or p.support_interface_filament > 0);
        const sup_top = if (own_support) self.supportTop() else null;
        const fill_top = if (own_infill) self.infillTop() else null;
        var last: [gcode.Towers.max]?usize = @splat(null);
        {
            var prev: ?u32 = null;
            for (self.levels, 0..) |lv, i| {
                var mask: u32 = 0;
                for (self.entries[lv.first..lv.end]) |e| {
                    mask |= @as(u32, 1) << @intCast(@min(self.toolAt(self.instances[e.instance].group, e.layer), n_slots - 1));
                }
                if (i < self.level_picks.len) mask |= self.level_picks[i];
                if (sup_top) |top| if (i <= top) {
                    mask |= (@as(u32, 1) << @intCast(sup)) | (@as(u32, 1) << @intCast(iface));
                };
                if (fill_top) |top| if (i <= top) {
                    mask |= @as(u32, 1) << @intCast(fill);
                };
                if (mask == 0) continue;
                const change = if (prev) |pm| (pm != mask or @popCount(mask) > 1) else @popCount(mask) > 1;
                if (change) for (0..n_slots) |k| if (mask & (@as(u32, 1) << @intCast(k)) != 0) {
                    last[out.of_slot[k]] = i;
                };
                prev = mask;
            }
        }
        for (last, 0..) |l, k| used[k] = l != null;
        // Number the used families from 0, in slot order.
        var map = [_]u8{0} ** gcode.Towers.max;
        var n: usize = 0;
        for (0..fam_n) |k| if (used[k]) {
            map[k] = @intCast(n);
            var t = one;
            t.last_layer = last[k].?;
            t.height = self.levels[t.last_layer].z;
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
        // The size of each tower: room for the most purge of one layer
        // (see `towerNeed`). The tower holds the most of all layers.
        const m = s.machine;
        const w = if (self.resolved.line_width > 0) self.resolved.line_width else 0.45;
        const h = @max(0.01, @min(p.layer_height, p.first_layer_height));
        const into = self.towerInto();
        const tm = self.towerMasks();
        var most = [_]f64{0} ** gcode.Towers.max;
        var tool: u32 = 0; // The start G-code loads filament 1.
        for (0..self.levels.len) |li| {
            const mask = self.levelMask(li, tm);
            if (mask == 0) continue;
            const got = needAfter(mask, li, tool, &into, &out.of_slot, n_slots);
            for (0..n) |k| most[k] = @max(most[k], got.need[k]);
            tool = got.last;
        }
        // A tower as wide as Project.prime_tower_width, or wider for a
        // large purge: a square of the area of the purge inside its wall,
        // then as deep as its rows (at most `max_tower_rows`). A tower
        // with ribs stays square, as in Bambu Studio. Side by side to the
        // left, a gap of one width between them.
        const wall = 2 * @as(f64, @floatFromInt(@max(1, p.prime_tower_wall_loops))) * w;
        var right = if (n > 0) out.list[0].x + out.list[0].size / 2 else 0;
        for (out.list[0..n], 0..) |*t, k| {
            const area = most[k] / (flowArea(w, h) / w);
            t.size = @max(t.size, @sqrt(area) + wall);
            const rows = @ceil(most[k] / ((t.size - wall) * flowArea(w, h)));
            t.depth = @min(@max(t.size, rows * w + wall), @as(f64, @floatFromInt(gcode.max_tower_rows)) * w + wall);
            if (t.rib) {
                // Square: each step makes the rows longer, so fewer.
                var guard: usize = 0;
                while (t.depth > t.size + 1e-9 and guard < 200) : (guard += 1) {
                    t.size = @min(t.depth, t.size + w);
                    const r2 = @ceil(most[k] / ((t.size - wall) * flowArea(w, h)));
                    t.depth = @max(t.size, r2 * w + wall);
                }
                t.depth = t.size;
            }
            if (k > 0) t.x = right - t.size / 2;
            right = t.x - t.size / 2 - @max(t.size, 10);
            if (p.prime_tower_x < 0 and k == 0) {
                t.x = towerEdge(m) - t.size / 2 - 10;
                right = t.x - t.size / 2 - @max(t.size, 10);
            }
            if (p.prime_tower_y < 0) t.y = m.bed_size_y - t.depth / 2 - 10;
        }
        out.need_ctx = self;
        out.need_fn = towerNeed;
        return out;
    }

    /// The levels that can change the filament of the support or of the
    /// sparse infill (see `towers`).
    const TowerMasks = struct { support_mask: u32, sup_top: ?usize, fill_mask: u32, fill_top: ?usize, n_slots: usize };

    fn towerMasks(self: *const PlateJob) TowerMasks {
        const p = self.resolved.settings.project;
        const n_slots = @max(1, @min(self.slots.len, filaments_mod.max_slots));
        const sup = filaments_mod.pathSlot(.support, p, n_slots);
        const iface = filaments_mod.pathSlot(.support_interface, p, n_slots);
        const fill = filaments_mod.lineSlot(.infill, true, p, n_slots);
        const own_support = p.support != .off and (p.support_filament > 0 or p.support_interface_filament > 0);
        const sup_top = if (own_support) self.supportTop() else null;
        const fill_top = if (ownInfill(p, n_slots)) self.infillTop() else null;
        return .{
            .support_mask = if (sup_top != null) (@as(u32, 1) << @intCast(sup)) | (@as(u32, 1) << @intCast(iface)) else 0,
            .sup_top = sup_top,
            .fill_mask = if (fill_top != null) @as(u32, 1) << @intCast(fill) else 0,
            .fill_top = fill_top,
            .n_slots = n_slots,
        };
    }

    /// The filaments of level `li`, as a mask of slots.
    fn levelMask(self: *const PlateJob, li: usize, tm: TowerMasks) u32 {
        var mask: u32 = if (li <= tm.sup_top orelse 0) tm.support_mask else 0;
        if (li <= tm.fill_top orelse 0) mask |= tm.fill_mask;
        const lv = self.levels[li];
        for (self.entries[lv.first..lv.end]) |e| {
            const t = self.toolAt(self.instances[e.instance].group, e.layer);
            mask |= @as(u32, 1) << @intCast(@min(t, tm.n_slots - 1));
        }
        if (li < self.level_picks.len) mask |= self.level_picks[li];
        return mask;
    }

    /// The most purge (mm³) of a change into each slot: the prime after a
    /// change G-code (gcode.tower_prime_mm3), or the largest flush into
    /// it from another slot.
    fn towerInto(self: *const PlateJob) [filaments_mod.max_slots]f64 {
        const gcode = @import("gcode.zig");
        const s = self.resolved.settings;
        const n_slots = @min(self.slots.len, filaments_mod.max_slots);
        var into = [_]f64{0} ** filaments_mod.max_slots;
        for (self.slots[0..n_slots], 0..) |to, i| {
            into[i] = gcode.tower_prime_mm3;
            if (s.machine.change_gcode.len == 0) for (self.slots[0..n_slots], 0..) |from, j2| {
                if (i != j2) into[i] = @max(into[i], filaments_mod.flushVolume(from.color, to.color, s.machine.flush_volume, s.project.flush_multiplier));
            };
        }
        return into;
    }

    /// The purge (mm³) into each tower on a level of filaments `mask`
    /// (level `li`), after a level that ended with slot `tool`. The level
    /// prints its filaments up by slot on even levels and down on odd
    /// levels (LayerPlan.groupByFilament), so it changes into each of its
    /// filaments but the first one if that one is `tool`. Returns the
    /// purge and the slot that the level ends with.
    fn needAfter(mask: u32, li: usize, tool: u32, into: *const [filaments_mod.max_slots]f64, of_slot: *const [filaments_mod.max_slots]u8, n_slots: usize) struct { need: [@import("gcode.zig").Towers.max]f64, last: u32 } {
        var need = [_]f64{0} ** @import("gcode.zig").Towers.max;
        var t = tool;
        for (0..n_slots) |k| {
            const i: u32 = @intCast(if (li % 2 == 0) k else n_slots - 1 - k);
            if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (i != t) need[of_slot[i]] += into[i];
            t = i;
        }
        return .{ .need = need, .last = t };
    }

    /// The purge (mm³) into each tower on level `level` (see
    /// gcode.Towers.needAt): the layer before gives it a solid base.
    fn towerNeed(ctx: ?*const anyopaque, of_slot: *const [filaments_mod.max_slots]u8, level: usize) [@import("gcode.zig").Towers.max]f64 {
        const self: *const PlateJob = @ptrCast(@alignCast(ctx.?));
        if (level >= self.levels.len) return @splat(0);
        const tm = self.towerMasks();
        const into = self.towerInto();
        const n_slots = @min(self.slots.len, filaments_mod.max_slots);
        // The slot that the last level with paths before it ended with.
        var tool: u32 = 0;
        var j = level;
        while (j > 0) {
            j -= 1;
            const m = self.levelMask(j, tm);
            if (m == 0) continue;
            tool = needAfter(m, j, 0, &into, of_slot, n_slots).last;
            break;
        }
        return needAfter(self.levelMask(level, tm), level, tool, &into, of_slot, n_slots).need;
    }

    /// The sparse infill has a filament of its own (see
    /// Project.infill_filament): a change can come on any layer.
    fn ownInfill(p: settings_mod.Project, n_slots: usize) bool {
        if (n_slots < 2 or !(p.infill_density > 0) or p.infill_filament == 0) return false;
        return filaments_mod.slotOf(p.infill_filament, n_slots) != filaments_mod.slotOf(p.filament, n_slots);
    }

    /// The right edge of the place of a tower near the right side: the
    /// side of the bed, or the edge of the reach of a nozzle of a printer
    /// with more than one (the left nozzle of the H2D stops 25 mm from the
    /// right side), so each nozzle reaches the tower.
    fn towerEdge(m: settings_mod.Machine) f64 {
        var edge = m.bed_size_x;
        if (m.nozzles < 2) return edge;
        if (m.nozzle1_max_x > 0) edge = @min(edge, m.nozzle1_max_x);
        for (1..@min(m.nozzles, settings_mod.max_nozzles)) |k| {
            if (m.nozzle[k].max_x > 0) edge = @min(edge, m.nozzle[k].max_x);
        }
        return edge;
    }

    /// The prime tower of the print (see gcode.Tower), or null: a tool
    /// change printer with the tower on, and a filament change in the
    /// print. With own support filaments, a change can come on any layer.
    pub fn tower(self: *const PlateJob) ?@import("gcode.zig").Tower {
        const s = self.resolved.settings;
        if (s.machine.filament_change != .tool or !s.project.prime_tower) return null;
        // A sequential plate: the levels of one part go down to the bed
        // again, and a tower cannot rise with them.
        if (self.sequential) return null;
        const p = s.project;
        const two = self.slots.len > 1;
        const own_support = p.support != .off and (p.support_filament > 0 or p.support_interface_filament > 0) and two;
        const sup_top = if (own_support) self.supportTop() else null;
        const fill_top = if (two and ownInfill(p, self.slots.len)) self.infillTop() else null;
        var last = self.lastChange();
        for ([_]?usize{ sup_top, fill_top }) |t| if (t) |v| {
            last = @max(last orelse 0, v);
        };
        if (last == null) return null;
        const size = s.project.prime_tower_width;
        const margin = 10;
        return .{
            .x = if (s.project.prime_tower_x >= 0) s.project.prime_tower_x else towerEdge(s.machine) - size / 2 - margin,
            .y = if (s.project.prime_tower_y >= 0) s.project.prime_tower_y else s.machine.bed_size_y - size / 2 - margin,
            .size = size,
            .last_layer = last.?,
            .walls = @max(1, p.prime_tower_wall_loops),
            .rib = p.prime_tower_rib_wall,
            .rib_width = p.prime_tower_rib_width,
            .rib_extra = p.prime_tower_extra_rib_length,
            .fillet = p.prime_tower_fillet_wall,
            .height = if (last.? < self.levels.len) self.levels[last.?].z else 0,
            .layer_h = p.layer_height,
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
        const no_paint: paint_mod.Paint = .{};
        for (parts) |p| {
            // A raised or cut label changes the shape: also with one
            // filament.
            var shape_labels = false;
            for (p.labels) |l| shape_labels = shape_labels or l.mode != .ink;
            const one = self.slots.len < 2;
            const paint = if (one) &no_paint else p.paint orelse &no_paint;
            if ((paint.isEmpty() and p.labels.len == 0) or (one and !shape_labels)) {
                try out.append(gpa, p);
                continue;
            }
            // The filament of the part.
            var base: u32 = settings.project.filament;
            for (p.changes) |c| if (std.mem.eql(u8, c.name, "project.filament")) {
                base = std.fmt.parseInt(u32, std.mem.trim(u8, c.value, " "), 10) catch base;
            };
            if (self.arena == null) self.arena = .init(gpa);
            const a = self.arena.?.allocator();
            // With one filament, each label is of the filament of the part.
            var labels = p.labels;
            if (one) {
                const copy = try a.dupe(label_mod.Label, p.labels);
                for (copy) |*l| l.filament = @min(base, 255);
                labels = copy;
            }
            const split = try gpa.create(paint_split.Split);
            split.* = paint_split.Split.initLabels(gpa, p.mesh, paint, @intCast(@min(base, 255)), labels) catch |e| {
                gpa.destroy(split);
                return e;
            };
            if (split.states.len < 2 and split.labels.len == 0) {
                split.deinit();
                gpa.destroy(split);
                try out.append(gpa, p);
                continue;
            }
            try splits.append(gpa, split);
            // The plateaus of raised top labels go into the mesh of each
            // job of the part.
            var mesh = p.mesh;
            if (try split.plateauMesh(a, p.mesh)) |m| {
                const mp = try a.create(Mesh);
                mp.* = m;
                mesh = mp;
            }
            for (split.states, 0..) |st, k| {
                var q = p;
                q.mesh = mesh;
                q.paint_split = split;
                q.paint_index = k;
                if (k > 0) {
                    // A label prints its band with Arachne lines: one line
                    // for each line width of its depth, and no infill.
                    const lab = if (split.label_of.len > k) split.label_of[k] else null;
                    const extra: usize = if (lab != null) 4 else 1;
                    const ch = try a.alloc(settings_mod.Change, p.changes.len + extra);
                    @memcpy(ch[0..p.changes.len], p.changes);
                    ch[p.changes.len] = .{ .name = "project.filament", .value = try std.fmt.allocPrint(a, "{d}", .{st}) };
                    if (lab) |li| {
                        const w = self.resolved.line_width;
                        // A raised label: the walls fill its relief.
                        const lb = &p.labels[li];
                        const d = if (lb.mode == .raised) lb.reliefMm() else lb.depth;
                        const walls: u32 = if (d > 0) @max(1, @as(u32, @intFromFloat(@ceil(d / w - 1e-6)))) else 1;
                        ch[p.changes.len + 1] = .{ .name = "project.wall_generator", .value = "arachne" };
                        ch[p.changes.len + 2] = .{ .name = "project.wall_count", .value = try std.fmt.allocPrint(a, "{d}", .{walls}) };
                        ch[p.changes.len + 3] = .{ .name = "project.infill_density", .value = "0" };
                    }
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
    /// The first filament slot that the print uses on each nozzle (0 the
    /// first, 1 the second, and on), in print order, or null for a nozzle
    /// that prints nothing. Support filaments do not count (Bambu
    /// Studio's first_non_support_filaments). The start G-code of a
    /// two-nozzle Bambu Lab printer prepares this filament for each nozzle
    /// (M620.17): a filament that the print does not use has no tray in
    /// the AMS mapping, and the print stops. A tool changer heats only the
    /// nozzles with a filament (is_extruder_used of PrusaSlicer).
    pub fn firstOfNozzles(self: *const PlateJob) [settings_mod.max_nozzles]?u32 {
        var out: [settings_mod.max_nozzles]?u32 = .{null} ** settings_mod.max_nozzles;
        if (self.slots.len < 2) return out;
        const m = self.resolved.settings.machine;
        const many = m.nozzles >= 2;
        // The nozzles that have a filament of the plate: the search stops
        // when each has its first.
        var left: usize = 0;
        if (many) {
            var seen: [settings_mod.max_nozzles]bool = .{false} ** settings_mod.max_nozzles;
            for (self.slots) |f| seen[m.nozzleIndex(f.nozzle)] = true;
            for (seen) |b| left += @intFromBool(b);
        } else left = 1;
        for (self.levels, 0..) |lv, li| {
            for (self.entries[lv.first..lv.end]) |e| {
                const t = self.toolAt(self.instances[e.instance].group, e.layer);
                const n: usize = if (many and t < self.slots.len) m.nozzleIndex(self.slots[t].nozzle) else 0;
                if (out[n] == null) {
                    out[n] = t;
                    left -|= 1;
                    if (left == 0) return out;
                }
            }
            // The filaments of the picks on this level.
            const mask = if (li < self.level_picks.len) self.level_picks[li] else 0;
            if (mask != 0) for (0..self.slots.len) |k| {
                if (mask & (@as(u32, 1) << @intCast(k)) == 0) continue;
                const n: usize = if (many) m.nozzleIndex(self.slots[k].nozzle) else 0;
                if (out[n] == null) {
                    out[n] = @intCast(k);
                    left -|= 1;
                    if (left == 0) return out;
                }
            };
        }
        return out;
    }

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
            self.markPicks(&lp, 0, e.layer);
            return lp;
        }
        const r = self.levelResolved(i);
        const start: geom.Point = if (self.outline0.points.items.len > 0) self.outline0.points.items[0] else .init(0, 0);
        var lp = try layer_mod.ringPlan(gpa, r, self.outline0, i, start);
        errdefer lp.deinit();
        lp.z = lv.z;
        lp.height = lv.height;
        lp.lift = lv.lift;
        if (self.sequential and lv.end > lv.first) lp.part_layer = self.entries[lv.first].layer;
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
                self.markRoot(&p, inst.group, e.layer);
                self.markPicks(&p, inst.group, e.layer);
                try lp.append(&p, inst.dx, inst.dy, inst.part, e.layer);
                continue;
            }
            if (plans[inst.group] == null) {
                plans[inst.group] = try layer_mod.plan(gpa, ctx, e.layer);
                self.markRoot(&plans[inst.group].?, inst.group, e.layer);
                self.markPicks(&plans[inst.group].?, inst.group, e.layer);
            }
            try lp.append(&plans[inst.group].?, inst.dx, inst.dy, inst.part, e.layer);
        }
        // The paths of the parts have their own widths (see
        // LayerPlan.append). The skirt, the brim, and the prime tower have
        // the width of the plate, also next to a part of a wider line (a
        // part on a second nozzle of another size).
        if (lp.paths.items.len > 0) lp.width = if (i == 0) r.first_layer_line_width else r.line_width;
        return lp;
    }

    /// The slots of the picks on each level: a pick counts on a level if
    /// its cut and the outline of its job are there.
    fn makeLevelPicks(self: *PlateJob) Allocator.Error!void {
        var any = false;
        for (self.groups) |g| any = any or g.picks.len > 0;
        if (!any) return;
        self.level_picks = try self.gpa.alloc(u32, self.levels.len);
        @memset(self.level_picks, 0);
        const n_slots = @min(self.slots.len, filaments_mod.max_slots);
        for (self.groups) |g| for (g.picks) |pk| {
            const bit = @as(u32, 1) << @intCast(filaments_mod.slotOf(pk.filament, n_slots));
            for (pk.outlines, g.job.outlines, g.layer_level) |area, o, lv| {
                if (!area.isEmpty() and !o.isEmpty()) self.level_picks[lv] |= bit;
            }
        };
    }

    /// The filament edits of single lines count on their levels, as the
    /// picks do: the prime tower and the first filaments then know them.
    /// An edit whose line is gone counts too. It can make the tower one
    /// change taller, and it never leaves a change without a tower.
    pub fn markLineEdits(self: *PlateJob, e: *const @import("app/edits.zig").Edits) Allocator.Error!void {
        if (self.slots.len < 2) return;
        var any = false;
        for (e.list.items) |x| any = any or x.anchor != null;
        if (!any) return;
        if (self.level_picks.len == 0) {
            self.level_picks = try self.gpa.alloc(u32, self.levels.len);
            @memset(self.level_picks, 0);
        }
        const Mark = struct {
            pj: *PlateJob,
            fn add(m: @This(), z: f64, filament: u32) void {
                const n_slots = @min(m.pj.slots.len, filaments_mod.max_slots);
                const bit = @as(u32, 1) << @intCast(filaments_mod.slotOf(filament, n_slots));
                for (m.pj.levels, 0..) |lv, i| if (@abs(lv.z - z) <= 0.005) {
                    m.pj.level_picks[i] |= bit;
                };
            }
        };
        e.eachFilament(Mark{ .pj = self }, Mark.add);
    }

    /// Gives each line of the plan of layer `layer` of group `g` the
    /// filament of the newest pick that holds most of its length. The
    /// lines stay as they are. Skirt, brim, and support have no pick.
    fn markPicks(self: *const PlateJob, p: *LayerPlan, g: usize, layer: usize) void {
        const picks = self.groups[g].picks;
        if (picks.len == 0) return;
        for (p.paths.items, 0..) |*path, k| {
            switch (path.feature) {
                .skirt, .support, .support_interface => continue,
                else => {},
            }
            const pts = p.points.get(k);
            var j = picks.len;
            while (j > 0) {
                j -= 1;
                if (layer >= picks[j].outlines.len) continue;
                const area = picks[j].outlines[layer];
                if (area.isEmpty() or !mostlyInside(area, pts, path.closed)) continue;
                path.pick = picks[j].filament;
                break;
            }
        }
    }

    /// Marks the paths of the plan of layer `layer` of group `g` hidden
    /// if the layer of the group is all the root of a painted feature
    /// (see paint_split.Split.anchor): the flush of a change can go into
    /// them.
    fn markRoot(self: *const PlateJob, p: *LayerPlan, g: usize, layer: usize) void {
        const gr = &self.groups[g];
        const sp = gr.split orelse return;
        if (!sp.rootOnly(layer, gr.paint_index)) return;
        for (p.paths.items) |*path| path.hidden = switch (path.feature) {
            .outer_wall, .inner_wall, .infill, .skin => true,
            else => false,
        };
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
        // The object labels: one object for each part, around all its
        // instances (a painted part has one for each filament).
        var objects: std.ArrayList(gcode_mod.Object) = .empty;
        defer {
            for (objects.items) |o| gpa.free(o.name);
            objects.deinit(gpa);
        }
        const m = self.resolved.settings.machine;
        if (m.label_objects) for (self.instances) |inst| {
            const box = engine.outlineBox(ctxs[inst.group].outlines, inst.dx, inst.dy, m) orelse continue;
            var found = false;
            for (objects.items) |*o| if (o.id == inst.part) {
                o.box = .{ @min(o.box[0], box[0]), @min(o.box[1], box[1]), @max(o.box[2], box[2]), @max(o.box[3], box[3]) };
                found = true;
            };
            if (!found) try objects.append(gpa, .{ .id = inst.part, .name = try engine.objectName(gpa, inst.name, inst.part), .box = box });
        };
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
            .objects = objects.items,
            .first_of_nozzles = self.firstOfNozzles(),
        };
        return engine.emitAll(gpa, src, self.threads, self.monitor, out, sink);
    }
};

/// True if at least half of the length of a line is inside `area`. Each
/// segment counts at sample points at most 2 mm apart.
fn mostlyInside(area: Paths, pts: []const geom.Point, closed: bool) bool {
    if (pts.len == 0) return false;
    if (pts.len == 1) return geom.insideAny(area, pts[0]);
    var total: f64 = 0;
    var inside: f64 = 0;
    const n_seg = if (closed) pts.len else pts.len - 1;
    for (0..n_seg) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % pts.len];
        const len = geom.Point.dist(a, b) * geom.toMm(1);
        if (!(len > 0)) continue;
        const n: usize = @intFromFloat(@min(6, @floor(len / 2) + 1));
        for (0..n) |s| {
            const t = (@as(f64, @floatFromInt(s)) + 0.5) / @as(f64, @floatFromInt(n));
            const q: geom.Point = .init(a.x + @as(i64, @intFromFloat(t * @as(f64, @floatFromInt(b.x - a.x)))), a.y + @as(i64, @intFromFloat(t * @as(f64, @floatFromInt(b.y - a.y)))));
            if (geom.insideAny(area, q)) inside += len / @as(f64, @floatFromInt(n));
        }
        total += len;
    }
    return total > 0 and inside >= 0.5 * total;
}

/// The area of a bead of width `w` and height `h` (see flow.beadArea).
fn flowArea(w: f64, h: f64) f64 {
    return @import("flow.zig").beadArea(w, h);
}

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
    // The settings of the paths tier: each setting but the patch
    // settings and the app preferences (settings_tiers.zig).
    @import("form.zig").hashSettings(&h, &settings, .paths);
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
        hv(&h, p.labels.len);
        for (p.labels) |*l| label_mod.hash(l, &h);
        hv(&h, b.min);
        hv(&h, b.max);
        changes(&h, p.changes);
        // The picks change the filament of the lines of a plan.
        hv(&h, p.picks.len);
        for (p.picks) |pk| {
            hv(&h, pk.filament);
            hv(&h, shapeKey(pk.mesh));
            h.update(std.mem.sliceAsBytes(pk.mesh.vertices.items));
        }
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
    if (p.picks.len > 0 or q.picks.len > 0) return false;
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

test "plate job: the start G-code loads the first filament of the print, not filament 1" {
    // A plate of filament 4 only on a Bambu Lab X2D: Bambu Studio loads
    // filament 4 in the start G-code (M620 S3A, T3). A load of filament 1
    // (T0) stopped the X2D in PREPARE ("Failed to get AMS mapping
    // table"): the print command maps filament 4 only.
    const gpa = testing.allocator;
    const bambu = @import("bambu.zig");
    var m = try testBox(0, 0, 6, 6, 1);
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.machine.model = "bambu-lab-x2d";
    s.machine.filament_change = .tool;
    s.project.filament = 4;
    // The load of the start G-code of the X2D (BambuStudio resources).
    s.machine.start_gcode = "  M620 S[initial_no_support_filament_id]A H[initial_no_support_hotend] B\n  T[initial_no_support_filament_id] H[initial_no_support_hotend]\nM620.17 T0 L{first_filaments[0]}";
    var more: [3]settings_mod.Filament = .{ s.filament, s.filament, s.filament };
    more[2].color = "#ffff00";
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &more });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    try testing.expectEqual(@as(u32, 0), st.changes);
    try testing.expect(st.slot_g[3] > 0 and st.slot_g[0] == 0);
    try testing.expect(std.mem.indexOf(u8, g, "M620 S3A") != null);
    try testing.expect(std.mem.indexOf(u8, g, "M620 S0A") == null);
    try testing.expect(std.mem.indexOf(u8, g, "\n  T3 H") != null);
    try testing.expect(std.mem.indexOf(u8, g, "M620.17 T0 L3") != null);
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " ");
        try testing.expect(!std.mem.startsWith(u8, t, "T0 ") and !std.mem.eql(u8, t, "T0"));
    }
    // The 3MF lists filament 4 in the layers.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const lists = try bambu.layerFilamentLists(arena.allocator(), g);
    try testing.expect(std.mem.indexOf(u8, lists, "filament_list=\"3\"") != null);
    try testing.expect(std.mem.indexOf(u8, lists, "filament_list=\"0") == null);
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
    // No root under the letter (see the test of the anchors).
    s.project.paint_anchor_depth = 0;
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

/// The count of the filament changes on each layer of a G-code text
/// (the comments ";LAYER:n" and "; filament change"), for the cost of a
/// label. The caller owns the result.
pub fn changesPerLayer(gpa: Allocator, gcode: []const u8) Allocator.Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var layer: ?usize = null;
    var it = std.mem.splitScalar(u8, gcode, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) {
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, line[7..], " \r"), 10) catch continue;
            if (n > 1 << 20) continue;
            layer = n;
            if (out.items.len <= n) try out.appendNTimes(gpa, 0, n + 1 - out.items.len);
        } else if (std.mem.startsWith(u8, line, "; filament change ")) {
            if (layer) |n| out.items[n] += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A box 20 x 20 x 10 with the label "IH" 5 mm tall in filament 2 on its
/// +x side (see label.zig).
fn labelBox(gpa: Allocator) !struct { mesh: Mesh, label: label_mod.Label } {
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 10);
    errdefer m.deinit(gpa);
    m.translate(90, 90, 0);
    const items = try gpa.alloc(label_mod.Item, 1);
    errdefer gpa.free(items);
    items[0] = .{ .shape = .{ .text = .{ .text = try gpa.dupe(u8, "IH"), .size = 5 } } };
    return .{ .mesh = m, .label = .{ .id = 1, .name = try gpa.dupe(u8, ""), .origin = .{ 110, 100, 5 }, .normal = .{ 1, 0, 0 }, .right = .{ 0, 1, 0 }, .filament = 2, .items = items } };
}

test "plate job: a label prints in its own filament on its layers" {
    const gpa = testing.allocator;
    var lb = try labelBox(gpa);
    defer lb.mesh.deinit(gpa);
    defer lb.label.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    var red = s.filament;
    red.color = "#ff0000";
    const parts = [_]PartInput{.{ .mesh = &lb.mesh, .part = 0, .labels = &.{lb.label} }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{red} });
    defer pj.deinit();
    // Two jobs: the part and the label.
    try testing.expectEqual(@as(usize, 2), pj.groups.len);
    const job = &pj.groups[1].job;
    const r = job.resolved.settings.project;
    try testing.expectEqual(@as(u32, 2), r.filament);
    try testing.expectEqual(settings_mod.WallGenerator.arachne, r.wall_generator);
    try testing.expectEqual(@as(u32, 1), r.wall_count);
    try testing.expectEqual(@as(f64, 0), r.infill_density);
    // The label job prints only within one line width of the +x side, on
    // the layers from z 2.5 to 7.5.
    const box = pj.groups[0].job.outlines[20].bounds();
    const w = pj.groups[0].job.resolved.line_width;
    var label_layers: usize = 0;
    for (job.outlines, job.layers) |o, l| {
        if (o.isEmpty()) continue;
        label_layers += 1;
        // The cut of the layer (its middle) is within z 2.5 to 7.5.
        try testing.expect(l.sliceZ() > 2.5 - 1e-6 and l.sliceZ() < 7.5 + 1e-6);
        const b = o.bounds();
        try testing.expect(b.min.x >= box.max.x - geom.fromMm(w + 0.005));
    }
    try testing.expect(label_layers >= 24 and label_layers <= 26);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    // T1 only on the layers of the label: each change is on one of them.
    const per = try changesPerLayer(gpa, out.written());
    defer gpa.free(per);
    var on_label: u32 = 0;
    for (per, 0..) |c, i| {
        if (c == 0) continue;
        const z = pj.levels[i].z;
        try testing.expect(z > 2.3 and z < 7.9);
        on_label += c;
    }
    try testing.expectEqual(st.changes, on_label);
    // A change to the label and one back on most layers of the label.
    try testing.expect(st.changes >= label_layers and st.changes <= 2 * label_layers + 1);
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    var layer: usize = 0;
    var t1: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) layer = try std.fmt.parseInt(usize, line[7..], 10);
        if (std.mem.startsWith(u8, line, "T1") and (line.len == 2 or line[2] == ' ')) {
            t1 += 1;
            try testing.expect(pj.levels[layer].z > 2.3 and pj.levels[layer].z < 7.9);
        }
    }
    try testing.expect(t1 > 0);
}

/// The plate job of the label box with one change of its label: the mode,
/// the relief, the filament, and the place.
fn modeJob(gpa: Allocator, lb: anytype, mode: label_mod.Mode, filament: u32, top: bool, slots: usize) !PlateJob {
    lb.label.mode = mode;
    lb.label.relief = 0.8;
    lb.label.filament = filament;
    if (top) {
        lb.label.origin = .{ 100, 100, 10 };
        lb.label.normal = .{ 0, 0, 1 };
        lb.label.right = .{ 1, 0, 0 };
    }
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    var red = s.filament;
    red.color = "#ff0000";
    const parts = [_]PartInput{.{ .mesh = &lb.mesh, .part = 0, .labels = &.{lb.label} }};
    return PlateJob.init(gpa, s, &parts, .{ .filaments = if (slots > 1) &.{red} else &.{} });
}

/// The area (mm²) of the union of the outlines of all jobs on layer i.
fn layerArea(gpa: Allocator, pj: *const PlateJob, i: usize) !f64 {
    var all: Paths = .empty;
    defer all.deinit(gpa);
    for (pj.groups) |*g| if (i < g.job.outlines.len) try all.appendAll(gpa, g.job.outlines[i]);
    var u = try clip.unionAll(gpa, all, .non_zero);
    defer u.deinit(gpa);
    return u.areaMm2();
}

test "plate job: raised, cut, and ink labels" {
    const gpa = testing.allocator;
    var lb = try labelBox(gpa);
    defer lb.mesh.deinit(gpa);
    defer lb.label.deinit(gpa);
    // Layer 25 (z 5) is in the middle of the label; layer 5 is under it.
    const mid = 25;
    const low = 5;
    var plain = try modeJob(gpa, &lb, .ink, 1, false, 1);
    const a_mid = try layerArea(gpa, &plain, mid);
    const x_max = plain.groups[0].job.outlines[mid].bounds().max.x;
    const n_layers = plain.groups[0].job.outlines.len;
    plain.deinit();
    try testing.expectApproxEqAbs(@as(f64, 400), a_mid, 1);

    // Raised, one filament: lines out of the +x wall by the relief, on
    // the layers of the label only.
    {
        var pj = try modeJob(gpa, &lb, .raised, 1, false, 1);
        defer pj.deinit();
        try testing.expectEqual(@as(usize, 1), pj.groups.len);
        const o = pj.groups[0].job.outlines;
        try testing.expect(o[mid].bounds().max.x > x_max + geom.fromMm(0.7));
        try testing.expect(try layerArea(gpa, &pj, mid) > a_mid + 1);
        try testing.expectEqual(x_max, o[low].bounds().max.x);
    }
    // Cut, one filament: the shape out of the wall, the same box.
    {
        var pj = try modeJob(gpa, &lb, .cut, 1, false, 1);
        defer pj.deinit();
        try testing.expectEqual(@as(usize, 1), pj.groups.len);
        const am = try layerArea(gpa, &pj, mid);
        try testing.expect(am < a_mid - 1);
        try testing.expectApproxEqAbs(@as(f64, 400), try layerArea(gpa, &pj, low), 1);
    }
    // Ink, two filaments: the same area; the label job has a part of it.
    {
        var pj = try modeJob(gpa, &lb, .ink, 2, false, 2);
        defer pj.deinit();
        try testing.expectEqual(@as(usize, 2), pj.groups.len);
        try testing.expectApproxEqAbs(a_mid, try layerArea(gpa, &pj, mid), 0.5);
        try testing.expect(!pj.groups[1].job.outlines[mid].isEmpty());
    }
    // Raised in filament 2: the label job is out of the wall.
    {
        var pj = try modeJob(gpa, &lb, .raised, 2, false, 2);
        defer pj.deinit();
        try testing.expectEqual(@as(usize, 2), pj.groups.len);
        const lo = pj.groups[1].job.outlines[mid];
        try testing.expect(!lo.isEmpty());
        try testing.expect(lo.bounds().min.x >= x_max - geom.fromMm(0.01));
        try testing.expectEqual(x_max, pj.groups[0].job.outlines[mid].bounds().max.x);
        // Only on the layers of the label: the outlines and the G-code.
        const job = &pj.groups[1].job;
        for (job.outlines, job.layers) |o, l| {
            if (o.isEmpty()) continue;
            try testing.expect(l.sliceZ() > 2.3 and l.sliceZ() < 7.7);
        }
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try pj.writeGcode(&out.writer);
        const per = try changesPerLayer(gpa, out.written());
        defer gpa.free(per);
        for (per, 0..) |c, i| if (c > 0) try testing.expect(pj.levels[i].z > 2.3 and pj.levels[i].z < 7.9);
    }
    // Cut in filament 2: less area, and the floor of the cut in the label.
    {
        var pj = try modeJob(gpa, &lb, .cut, 2, false, 2);
        defer pj.deinit();
        try testing.expect(try layerArea(gpa, &pj, mid) < a_mid - 1);
        const lo = pj.groups[1].job.outlines[mid];
        try testing.expect(!lo.isEmpty());
        try testing.expect(lo.bounds().max.x < x_max - geom.fromMm(0.7));
    }
    // Raised on the top face: a plateau over the part (more layers).
    {
        var pj = try modeJob(gpa, &lb, .raised, 1, true, 1);
        defer pj.deinit();
        const o = pj.groups[0].job.outlines;
        try testing.expect(o.len >= n_layers + 3);
        try testing.expect(!o[o.len - 1].isEmpty());
        try testing.expect(o[o.len - 1].areaMm2() < 100);
    }
    // Cut into the top face: the top layers lose the shape, and the floor
    // of the cut is a top.
    {
        var pj = try modeJob(gpa, &lb, .cut, 1, true, 1);
        defer pj.deinit();
        const job = &pj.groups[0].job;
        try testing.expectEqual(n_layers, job.outlines.len);
        try testing.expect(job.outlines[n_layers - 1].areaMm2() < 400 - 1);
        var floor = false;
        for (job.tops[0 .. n_layers - 1]) |t| floor = floor or !t.isEmpty();
        try testing.expect(floor);
    }
}

test "plate job: a part with no label slices as before" {
    const gpa = testing.allocator;
    var lb = try labelBox(gpa);
    defer lb.mesh.deinit(gpa);
    defer lb.label.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    var red = s.filament;
    red.color = "#ff0000";
    // A label in the filament of the part does nothing.
    lb.label.filament = 1;
    const with = [_]PartInput{.{ .mesh = &lb.mesh, .part = 0, .labels = &.{lb.label} }};
    const without = [_]PartInput{.{ .mesh = &lb.mesh, .part = 0 }};
    var outs: [2]Writer.Allocating = .{ .init(gpa), .init(gpa) };
    defer for (&outs) |*o| o.deinit();
    for ([_][]const PartInput{ &with, &without }, &outs) |parts, *o| {
        var pj = try PlateJob.init(gpa, s, parts, .{ .filaments = &.{red} });
        defer pj.deinit();
        try testing.expectEqual(@as(usize, 1), pj.groups.len);
        _ = try pj.writeGcode(&o.writer);
    }
    try testing.expectEqualStrings(outs[1].written(), outs[0].written());
}

/// A black plaque 40 x 30 x 4 with a white raised frame and a white
/// cross 2 mm tall on its top, painted (see the test of the anchors). A
/// tab of the frame hangs 4 mm out over the front edge.
fn plaque(gpa: Allocator, paint: *paint_mod.Paint) !Mesh {
    var b: mesh_mod.Builder = .init(gpa);
    defer b.deinit();
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 40, 30, 4);
    const base_faces = 12;
    // The frame, 3 mm wide.
    try mesh_mod.shapes.addBox(&b, 0, 0, 4, 40, 3, 6);
    try mesh_mod.shapes.addBox(&b, 0, 27, 4, 40, 30, 6);
    try mesh_mod.shapes.addBox(&b, 0, 3, 4, 3, 27, 6);
    try mesh_mod.shapes.addBox(&b, 37, 3, 4, 40, 27, 6);
    // The cross, 4 mm wide.
    try mesh_mod.shapes.addBox(&b, 10, 13, 4, 30, 17, 6);
    try mesh_mod.shapes.addBox(&b, 18, 6, 4, 22, 24, 6);
    // The tab over the front edge.
    try mesh_mod.shapes.addBox(&b, 16, -4, 4, 24, 3, 6);
    const m = try b.finish();
    for (base_faces..m.faces.items.len) |i| try paint.setTriangle(gpa, i, 2);
    return m;
}

/// The facts of the G-code of a plate for the test of the anchors.
const AnchorFacts = struct {
    /// The tops of the layers with white (T1) lines under the top of the
    /// plaque (z 4).
    root_layers: usize = 0,
    root_min_z: f64 = 1e9,
    /// The box of the white lines under z 4 (G-code mm).
    box: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 },
    /// The box of all lines on the layer at z 3.6.
    part: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 },
};

fn anchorFacts(g: []const u8) AnchorFacts {
    var f: AnchorFacts = .{};
    var tool: u8 = 0;
    var z: f64 = 0;
    var last_root_z: f64 = -1;
    var tower = false;
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        if (line.len == 2 and line[0] == 'T') tool = line[1] - '0';
        if (std.mem.startsWith(u8, line, ";TYPE:")) tower = std.mem.eql(u8, line[6..], "PRIME-TOWER");
        if (!std.mem.startsWith(u8, line, "G1") and !std.mem.startsWith(u8, line, "G0")) continue;
        var x: ?f64 = null;
        var y: ?f64 = null;
        var e = false;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |wd| {
            if (wd[0] == ';') break;
            const v = std.fmt.parseFloat(f64, wd[1..]) catch continue;
            switch (wd[0]) {
                'X' => x = v,
                'Y' => y = v,
                'Z' => z = v,
                'E' => e = v > 0,
                else => {},
            }
        }
        if (!e or x == null or y == null or std.mem.startsWith(u8, line, "G0")) continue;
        if (tower) continue;
        if (@abs(z - 3.6) < 1e-3) {
            f.part = .{ @min(f.part[0], x.?), @min(f.part[1], y.?), @max(f.part[2], x.?), @max(f.part[3], y.?) };
        }
        if (tool != 1 or z > 4 + 1e-3) continue;
        if (z != last_root_z) {
            f.root_layers += 1;
            last_root_z = z;
        }
        f.root_min_z = @min(f.root_min_z, z);
        f.box = .{ @min(f.box[0], x.?), @min(f.box[1], y.?), @max(f.box[2], x.?), @max(f.box[3], y.?) };
    }
    return f;
}

test "plate job: a painted feature on a part grows a root into its infill" {
    const gpa = testing.allocator;
    var paint: paint_mod.Paint = .{};
    defer paint.deinit(gpa);
    var m = try plaque(gpa, &paint);
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.filament.color = "#000000";
    // Layer tops at 0.2, 0.4, and on: the top of the plaque is a top.
    s.project.first_layer_height = 0.2;
    var white = s.filament;
    white.color = "#ffffff";
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0, .paint = &paint }};

    s.project.paint_anchor_depth = 0;
    var pj0 = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pj0.deinit();
    const g0 = try gcodeOf(&pj0);
    defer gpa.free(g0);
    const f0 = anchorFacts(g0);
    try testing.expectEqual(@as(usize, 0), f0.root_layers);
    try testing.expectEqual(@as(f64, 0), pj0.splits[0].anchor_mm3);

    s.project.paint_anchor_depth = 1.0;
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pj.deinit();
    const g = try gcodeOf(&pj);
    defer gpa.free(g);
    const f = anchorFacts(g);
    // The root: white lines on the 5 layers (1 mm) under the top of the
    // plaque, and none deeper.
    try testing.expectEqual(@as(usize, 5), f.root_layers);
    try testing.expectApproxEqAbs(@as(f64, 3.2), f.root_min_z, 1e-3);
    try testing.expect(pj.splits[0].anchor_mm3 > 50);
    // Inside the walls of the plaque: two walls of 0.44 mm and the
    // margin, and the half line of the root wall.
    const r = pj.groups[0].job.resolved.line_width;
    const inset = 2 * r + engine.Job.anchor_margin + r / 2 - 1e-3;
    try testing.expect(f.box[0] >= f.part[0] - r / 2 + inset);
    try testing.expect(f.box[1] >= f.part[1] - r / 2 + inset);
    try testing.expect(f.box[2] <= f.part[2] + r / 2 - inset);
    try testing.expect(f.box[3] <= f.part[3] + r / 2 - inset);
    // The tab over the air gets no root out of the plaque, and the
    // outside of the plaque is the same: the box of the layer at z 3.6.
    for (0..4) |k| try testing.expectApproxEqAbs(f0.part[k], f.part[k], 1e-3);

    // The outer walls of the black plaque on the root layers are the
    // same as without the root.
    var checked: usize = 0;
    for (pj.levels, 0..) |lv, i| {
        if (lv.z < 3.1 or lv.z > 4.01) continue;
        var a = try pj0.planLayer(i);
        defer a.deinit();
        var b = try pj.planLayer(i);
        defer b.deinit();
        for (a.paths.items, 0..) |p, pi| {
            if (p.feature != .outer_wall) continue;
            const pts = a.points.get(pi);
            var found = false;
            for (b.paths.items, 0..) |q, qi| {
                if (q.feature != .outer_wall) continue;
                if (std.mem.eql(u8, std.mem.sliceAsBytes(pts), std.mem.sliceAsBytes(b.points.get(qi)))) found = true;
            }
            try testing.expect(found);
            checked += 1;
        }
    }
    try testing.expect(checked >= 5);

    // The core: a smaller root, under the middle of the feature.
    s.project.paint_anchor_shape = .core;
    var pjc = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pjc.deinit();
    const core = pjc.splits[0].anchor_mm3;
    try testing.expect(core > 0 and core < pj.splits[0].anchor_mm3);

    // The cost: a filament change on each layer of the root.
    var out0: Writer.Allocating = .init(gpa);
    defer out0.deinit();
    const st0 = try pj0.writeGcode(&out0.writer);
    var out1: Writer.Allocating = .init(gpa);
    defer out1.deinit();
    const st1 = try pj.writeGcode(&out1.writer);
    try testing.expect(st1.changes > st0.changes);
    try testing.expect(st1.changes <= st0.changes + 5);
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

test "plate job: object labels for Klipper and M486" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 5);
    defer m1.deinit(gpa);
    var m2 = try testBox(40, 0, 60, 20, 5);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.label_objects = true;
    s.machine.gcode_flavor = .klipper;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0, .name = "left box" },
        .{ .mesh = &m2, .part = 1, .name = "right" },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{});
    defer pj.deinit();
    const g = try gcodeOf(&pj);
    defer gpa.free(g);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, g, "EXCLUDE_OBJECT_DEFINE NAME="));
    try testing.expect(std.mem.indexOf(u8, g, "EXCLUDE_OBJECT_DEFINE NAME=left_box_0 CENTER=") != null);
    // Each layer opens and closes the label of each part once.
    const layers = std.mem.count(u8, g, ";LAYER:");
    try testing.expectEqual(layers, std.mem.count(u8, g, "EXCLUDE_OBJECT_START NAME=left_box_0\n"));
    try testing.expectEqual(layers, std.mem.count(u8, g, "EXCLUDE_OBJECT_START NAME=right_1\n"));
    try testing.expectEqual(std.mem.count(u8, g, "EXCLUDE_OBJECT_START"), std.mem.count(u8, g, "EXCLUDE_OBJECT_END"));
    // The definitions come before the first layer, and the skirt is
    // outside of all labels.
    try testing.expect(std.mem.indexOf(u8, g, "EXCLUDE_OBJECT_DEFINE").? < std.mem.indexOf(u8, g, ";LAYER:0\n").?);
    const l0 = std.mem.indexOf(u8, g, ";LAYER:0\n").?;
    const skirt = std.mem.indexOfPos(u8, g, l0, ";TYPE:SKIRT").?;
    const first = std.mem.indexOfPos(u8, g, l0, "EXCLUDE_OBJECT_START").?;
    try testing.expect(skirt < first);
    // Marlin: M486.
    s.machine.gcode_flavor = .marlin;
    var pm = try PlateJob.init(gpa, s, &parts, .{});
    defer pm.deinit();
    const gm = try gcodeOf(&pm);
    defer gpa.free(gm);
    try testing.expect(std.mem.indexOf(u8, gm, "M486 T2\n") != null);
    try testing.expectEqual(layers, std.mem.count(u8, gm, "M486 S1 ; right_1\n"));
    try testing.expectEqual(std.mem.count(u8, gm, "M486 S-1\n"), 2 * layers);
    // Off: no label.
    s.machine.label_objects = false;
    var po = try PlateJob.init(gpa, s, &parts, .{});
    defer po.deinit();
    const go = try gcodeOf(&po);
    defer gpa.free(go);
    try testing.expect(std.mem.indexOf(u8, go, "M486") == null);
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
        try testing.expect(lz >= z - 1e-9 or lz >= z - s.machine.z_hop - 1e-9);
        z = @max(z, lz - s.machine.z_hop);
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

test "plate job: one part at a time" {
    const gpa = testing.allocator;
    var m1 = try testBox(0, 0, 20, 20, 3);
    defer m1.deinit(gpa);
    var m2 = try testBox(60, 0, 80, 20, 5);
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.project.placement = .file;
    s.project.print_sequence = .by_object;
    // The higher part first in the list: it prints first.
    const parts = [_]PartInput{
        .{ .mesh = &m2, .part = 0, .name = "tall" },
        .{ .mesh = &m1, .part = 1, .name = "short" },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .streams = 1 });
    defer pj.deinit();
    try testing.expect(pj.sequential);
    try testing.expectEqual(@as(usize, 0), pj.streams.len);
    const n0 = pj.jobOf(0).?.layers.len;
    const n1 = pj.jobOf(1).?.layers.len;
    try testing.expectEqual(n0 + n1, pj.layerCount());
    // Each level has one part: all of part 0, then all of part 1.
    for (pj.levels, 0..) |lv, i| {
        try testing.expectEqual(@as(u32, 1), lv.end - lv.first);
        const inst = pj.instances[pj.entries[lv.first].instance];
        try testing.expectEqual(@as(u32, if (i < n0) 0 else 1), inst.part);
        try testing.expectEqual(i == n0, lv.lift > 0);
    }
    // The lift is over the top of the first part.
    try testing.expectApproxEqAbs(pj.levels[n0 - 1].z + lift_margin, pj.levels[n0].lift, 1e-9);
    const g = try gcodeOf(&pj);
    defer gpa.free(g);
    // The head goes up over the first part, over to the second, and down.
    const at = std.mem.indexOf(u8, g, " ; over the printed parts\n") orelse return error.TestUnexpectedResult;
    var buf: [32]u8 = undefined;
    const layer = std.mem.indexOf(u8, g, try std.fmt.bufPrint(&buf, ";LAYER:{d}\n", .{n0})).?;
    try testing.expect(at > layer);
    // The first layer of the second part has the fan off, as the first
    // layer of the print.
    const next = std.mem.indexOfPos(u8, g, at, ";LAYER:").?;
    try testing.expect(std.mem.indexOf(u8, g[at..next], "M106") == null);
    // By layer, the same plate prints both parts on each level.
    s.project.print_sequence = .by_layer;
    var pj2 = try PlateJob.init(gpa, s, &parts, .{});
    defer pj2.deinit();
    try testing.expect(!pj2.sequential);
    try testing.expectEqual(@max(n0, n1), pj2.layerCount());
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

/// The check of one Bambu Lab model of the library (see the test below):
/// a plate of two cubes of two filaments, the second on the second nozzle
/// of a model with two.
fn checkBambuModel(gpa: Allocator, lib: *const @import("printers.zig").Library, i: usize) !void {
    const printers = @import("printers.zig");
    const bambu = @import("bambu.zig");
    const zipfile = @import("zipfile.zig");
    const m = lib.models[i];
    const facts = printers.bambu(m.id) orelse return error.NoFacts;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var text: Writer.Allocating = .init(a);
    try lib.profileText(i, 0, &text.writer);
    var s: Settings = .{};
    s.engine.threads = 1;
    var diag: @import("profile.zig").Diagnostic = .{};
    try @import("profile.zig").apply(a, &s, .machine, m.id, text.written(), null, &diag);
    // Each model has the templates of Bambu Studio and a tool change.
    try testing.expect(printers.bambuTemplate(m.id, .layer) != null);
    try testing.expectEqual(settings_mod.FilamentChange.tool, s.machine.filament_change);
    const cx = s.machine.bed_size_x / 2;
    const cy = s.machine.bed_size_y / 2;
    var m1 = try testBox(cx - 15, cy - 5, cx - 5, cy + 5, 2);
    defer m1.deinit(gpa);
    var m2 = try testBox(cx + 5, cy - 5, cx + 15, cy + 5, 2);
    defer m2.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    if (facts.nozzles >= 2) second.nozzle = 1;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    try testing.expect(st.slot_g[0] > 0 and st.slot_g[1] > 0);

    // The blocks of Bambu Studio, and its marks of the start and the end.
    try testing.expect(std.mem.startsWith(u8, g, "; HEADER_BLOCK_START\n"));
    try testing.expect(std.mem.endsWith(u8, g, "; EXECUTABLE_BLOCK_END\n"));
    for ([_][]const u8{ "; CONFIG_BLOCK_START\n", "; CONFIG_BLOCK_END\n", "; EXECUTABLE_BLOCK_START\n", "; MACHINE_START_GCODE_END\n", "; MACHINE_END_GCODE_START\n", "M981 S1 P20000", "M981 S0 P20000" }) |mark| {
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, g, mark));
    }
    const exec = g[std.mem.indexOf(u8, g, "; EXECUTABLE_BLOCK_START\n").?..];
    const print_start = std.mem.indexOf(u8, exec, "; MACHINE_START_GCODE_END\n").?;
    const print_end = std.mem.indexOf(u8, exec, "; MACHINE_END_GCODE_START\n").?;

    // Each layer tells the printer its number (M73 L, M991).
    const layers = std.mem.count(u8, exec, "\n;LAYER:");
    try testing.expect(layers > 5);
    try testing.expectEqual(layers, std.mem.count(u8, exec, "\nM73 L"));
    // The end G-code ends the time lapse with "M991 S0 P-1".
    try testing.expectEqual(layers, std.mem.count(u8, exec, "\nM991 S0 P") - std.mem.count(u8, exec, "\nM991 S0 P-"));

    var lines = std.mem.splitScalar(u8, exec, '\n');
    var pos: usize = 0;
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    var tool: usize = 0;
    var relative = false;
    var in_change = false;
    while (lines.next()) |line| {
        defer pos += line.len + 1;
        // Each variable of the templates has a value, except the path of
        // the head to the purge (Studio plans it around the parts) and
        // the limit of the Y acceleration by the mass on the bed.
        if (std.mem.indexOf(u8, line, "zslice: no value for ")) |k| {
            const name = line[k + "zslice: no value for ".len ..];
            const ok = std.mem.startsWith(u8, name, "travel_point_") or std.mem.startsWith(u8, name, "curr_y_acceleration_limit");
            if (!ok) std.debug.print("{s}: {s}\n", .{ m.id, line });
            try testing.expect(ok);
        }
        const cmd = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, line, ';')) |c| line[0..c] else line, " \t\r");
        if (cmd.len == 0) continue;
        if (std.mem.indexOfAny(u8, cmd, "{}") != null) {
            std.debug.print("{s}: {s}\n", .{ m.id, line });
            return error.TestUnexpectedResult;
        }
        var words = std.mem.tokenizeScalar(u8, cmd, ' ');
        const op = words.next().?;
        // The moves of the change G-code of the maker go to its purge.
        if (std.mem.eql(u8, op, "M620") and std.mem.startsWith(u8, cmd, "M620 S")) in_change = true;
        if (std.mem.eql(u8, op, "M621") and std.mem.startsWith(u8, cmd, "M621 S")) in_change = false;
        if (std.mem.eql(u8, op, "G90")) relative = false;
        if (std.mem.eql(u8, op, "G91")) relative = true;
        if (op[0] == 'T' and op.len > 1) tool = std.fmt.parseInt(usize, op[1..], 10) catch tool;
        if (!(std.mem.eql(u8, op, "G0") or std.mem.eql(u8, op, "G1") or std.mem.eql(u8, op, "G2") or std.mem.eql(u8, op, "G3"))) continue;
        var e: f64 = 0;
        while (words.next()) |w| {
            if (w.len < 2) continue;
            const v = std.fmt.parseFloat(f64, w[1..]) catch continue;
            switch (w[0]) {
                'X' => x = if (relative) x + v else v,
                'Y' => y = if (relative) y + v else v,
                'Z' => z = if (relative) z + v else v,
                'E' => e = v,
                else => {},
            }
        }
        // The extrusions of the print stay on the bed, under the height,
        // and in the reach of the nozzle of their filament.
        if (e <= 0 or in_change or pos < print_start or pos > print_end) continue;
        const eps = 1e-3;
        try testing.expect(x >= -eps and x <= s.machine.bed_size_x + eps);
        try testing.expect(y >= -eps and y <= s.machine.bed_size_y + eps);
        try testing.expect(z > 0 and z <= s.machine.max_height + eps);
        if (facts.nozzles >= 2) {
            const nozzle: usize = if (tool == 1) 1 else 0;
            if (nozzle == 0 and facts.max_x[0] > 0) try testing.expect(x <= facts.max_x[0] + eps);
            if (nozzle == 1) try testing.expect(x >= facts.min_x[1] - eps);
        }
    }

    // The .gcode.3mf: the files of a Bambu Studio file, and the keys of
    // its slice_info.config in the order of Studio.
    const fils = [_]bambu.FilamentUse{
        .{ .id = 1, .kind = "PLA", .color = "#FFFFFF", .meters = st.slot_mm[0] / 1000, .grams = st.slot_g[0] },
        .{ .id = 2, .kind = "PLA", .color = "#D93A3A", .meters = st.slot_mm[1] / 1000, .grams = st.slot_g[1], .nozzle = if (facts.nozzles >= 2) 1 else 0 },
    };
    const file = try bambu.gcode3mfInfo(gpa, g, "two cubes", .{
        .filaments = &fils,
        .seconds = st.print_time_s,
        .nozzles = facts.nozzles,
        .model_id = facts.code,
        .nozzle = s.machine.nozzle_diameter,
        .printer_model = facts.name,
        .bed_type = s.machine.bed_type.studioName(),
        .extruder_types = facts.types,
        .default_volumes = facts.volumes,
        .variants = facts.variants,
        .base_project = printers.bambuProject(m.id) orelse "",
        .bbox = .{ cx - 15, cy - 5, cx + 15, cy + 5 },
        .layer_lists = try bambu.layerFilamentLists(a, g),
    });
    defer gpa.free(file);
    const entries = try zipfile.readAll(gpa, file);
    defer zipfile.freeAll(gpa, entries);
    const want = [_][]const u8{ "[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model", "Metadata/model_settings.config", "Metadata/plate_1.json", "Metadata/filament_sequence.json", "Metadata/plate_1.gcode", "Metadata/plate_1.gcode.md5", "Metadata/slice_info.config", "Metadata/project_settings.config" };
    for (want) |name| {
        var found = false;
        for (entries) |en| found = found or std.mem.eql(u8, en.name, name);
        if (!found) std.debug.print("{s}: no {s}\n", .{ m.id, name });
        try testing.expect(found);
    }
    for (entries) |en| {
        if (std.mem.eql(u8, en.name, "Metadata/plate_1.gcode")) try testing.expectEqualStrings(g, en.data);
        if (std.mem.eql(u8, en.name, "Metadata/plate_1.gcode.md5")) try testing.expectEqualStrings(&bambu.gcodeMd5(g), en.data);
        if (!std.mem.eql(u8, en.name, "Metadata/slice_info.config")) continue;
        var code: [64]u8 = undefined;
        const order = [_][]const u8{ "\"index\"", "\"extruder_type\"", "\"nozzle_volume_type\"", try std.fmt.bufPrint(&code, "\"printer_model_id\" value=\"{s}\"", .{facts.code}), "\"nozzle_diameters\"", "\"timelapse_type\"", "\"prediction\"", "\"weight\"", "\"pause_count\"", "\"first_layer_time\"", "\"outside\"", "\"support_used\"", "\"label_object_enabled\"", "\"support_material_on_wipe_tower\"", "\"enable_filament_dynamic_map\"", "\"has_filament_switcher\"", "\"multi_nozzle_diameter_mode\"", "\"filament_maps\"", "<object identify_id=", "<filament id=\"1\"", "<filament id=\"2\"", "<nozzle id=\"0\"", "<layer_filament_lists>", "</plate>" };
        var at: usize = 0;
        for (order) |key| {
            const k = std.mem.indexOfPos(u8, en.data, at, key) orelse {
                std.debug.print("{s}: slice_info.config: no {s} after {d}\n", .{ m.id, key, at });
                return error.TestUnexpectedResult;
            };
            at = k + key.len;
        }
        try testing.expect(std.mem.indexOf(u8, en.data, "used_m=\"0.00\"") == null);
    }
}

test "plate job: each Bambu Lab model of the library prints two filaments in the file of Bambu Studio" {
    const printers = @import("printers.zig");
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    const lib = try printers.Library.parse(gpa, printers.builtin_data);
    defer lib.deinit();
    var count: usize = 0;
    for (lib.models, 0..) |m, i| {
        if (!std.mem.startsWith(u8, m.id, "bambu-lab-")) continue;
        checkBambuModel(gpa, lib, i) catch |e| {
            std.debug.print("{s}: {s}\n", .{ m.id, @errorName(e) });
            return e;
        };
        count += 1;
    }
    // A1, A1 mini, A2L, H2C, H2D, H2D Pro, H2S, P1P, P1S, P2S, X1, X1
    // Carbon, X1E, X2D.
    try testing.expectEqual(@as(usize, 14), count);
}

/// The printer model that the start G-code of each Prusa model of the
/// library checks (M862.3 P "..."), as the printer firmware names it
/// (Prusa-Firmware-Buddy printer_model_data.hpp, Prusa-Firmware
/// util.cpp). The Cura models of the old Prusa i3 printers have no check.
const prusa_checks = [_][2][]const u8{
    .{ "prusa-core-one", "COREONE" },
    .{ "prusa-core-one-core-one", "COREONE" },
    .{ "prusa-core-one-core-one-mmu3", "COREONE" },
    .{ "prusa-core-one-hf", "COREONE" },
    .{ "prusa-core-one-indx-4t", "COREONEINDX" },
    .{ "prusa-core-one-indx-8t", "COREONEINDX" },
    .{ "prusa-core-one-l", "COREONEL" },
    .{ "prusa-core-one-l-hf", "COREONEL" },
    .{ "prusa-core-one-l-mmu3", "COREONEL" },
    .{ "prusa-core-one-mmu3", "COREONE" },
    .{ "prusa-signature-oak", "COREONEOAK" },
    .{ "prusa-i3", "" },
    .{ "prusa-i3-mk2", "" },
    .{ "prusa-i3-mk3-mk3s", "" },
    .{ "prusa-i3-xl", "" },
    .{ "prusa-mini", "MINI" },
    .{ "prusa-mini-mini", "MINI" },
    .{ "prusa-mini-mini-input-shaper", "MINI" },
    .{ "prusa-mini-is", "MINI" },
    .{ "prusa-mk3-5", "MK3.5" },
    .{ "prusa-mk3s", "MK3S" },
    .{ "prusa-mk4", "MK4" },
    .{ "prusa-mk4-mmu3-hf", "MK4" },
    .{ "prusa-mk4s-hf", "MK4S" },
    .{ "prusa-i3-mk2s", "MK2S" },
    .{ "prusa-i3-mk2s-mmu1", "MK2SMM" },
    .{ "prusa-i3-mk2-5", "MK2.5" },
    .{ "prusa-i3-mk2-5-mmu2", "MK2.5MMU2" },
    .{ "prusa-i3-mk2-5s", "MK2.5S" },
    .{ "prusa-i3-mk2-5s-mmu2s", "MK2.5SMMU2S" },
    .{ "prusa-i3-mk3", "MK3" },
    .{ "prusa-i3-mk3-mmu2", "MK3MMU2" },
    .{ "prusa-i3-mk3s-mk3s", "MK3S" },
    .{ "prusa-i3-mk3s-mk3s-mmu2s", "MK3SMMU2S" },
    .{ "prusa-i3-mk3s-mk3s-mmu3", "MK3SMMU3" },
    .{ "prusa-mk3-5-mk3-5s", "MK3.5" },
    .{ "prusa-mk3-5-mk3-5s-mmu3", "MK3.5" },
    .{ "prusa-mk3-9-input-shaper", "MK3.9" },
    .{ "prusa-mk3-9-mmu3", "MK3.9" },
    .{ "prusa-mk3-9s", "MK3.9S" },
    .{ "prusa-mk3-9s-mmu3", "MK3.9S" },
    .{ "prusa-mk4-input-shaper", "MK4" },
    .{ "prusa-mk4-mmu3", "MK4" },
    .{ "prusa-mk4s", "MK4S" },
    .{ "prusa-mk4s-mmu3", "MK4S" },
    .{ "prusa-xl", "XL" },
    .{ "prusa-xl-2t", "XL" },
    .{ "prusa-xl-5t", "XL" },
    .{ "prusa-xl-2t-input-shaper", "XL" },
    .{ "prusa-xl-5t-input-shaper", "XL" },
    .{ "prusa-xl-input-shaper", "XL" },
};

/// The check of one Prusa model of the library (see the test below): a
/// plate of two cubes of two filaments.
fn checkPrusaModel(gpa: Allocator, lib: *const @import("printers.zig").Library, i: usize, check: []const u8) !void {
    const m = lib.models[i];
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var text: Writer.Allocating = .init(a);
    try lib.profileText(i, 0, &text.writer);
    var s: Settings = .{};
    s.engine.threads = 1;
    var diag: @import("profile.zig").Diagnostic = .{};
    try @import("profile.zig").apply(a, &s, .machine, m.id, text.written(), null, &diag);
    // An MMU changes the filament with a T command, and a tool changer
    // (the XL, the CORE One INDX) changes to the tool of the second
    // filament; the other models pause for a change by hand (M600).
    const tools = s.machine.filament_change == .tool;
    try testing.expectEqual(m.tool_change or lib.toolsOf(i) != null, tools);
    const cx = s.machine.bed_size_x / 2;
    const cy = s.machine.bed_size_y / 2;
    var m1 = try testBox(cx - 15, cy - 5, cx - 5, cy + 5, 2);
    defer m1.deinit(gpa);
    var m2 = try testBox(cx + 5, cy - 5, cx + 15, cy + 5, 2);
    defer m2.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    second.material = "PETG";
    if (s.machine.nozzles >= 2) second.nozzle = 1;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    try testing.expect(st.slot_g[0] > 0 and st.slot_g[1] > 0);
    // A tool changer: one item of the statistics for each tool.
    const tool_types = if (s.machine.nozzles >= 2) "\n; filament_type = PLA;PETG" else "\n; filament_type = PLA;PETG\n";

    // The printer model check of the maker's start G-code.
    if (check.len > 0) {
        var want: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&want, "\nM862.3 P \"{s}\"", .{check});
        try testing.expect(std.mem.indexOf(u8, g, line) != null);
    } else try testing.expect(std.mem.indexOf(u8, g, "M862.3") == null);

    // The statistics that the Buddy firmware reads, one item for each
    // tool: two tools with an MMU, one tool with a pause.
    const used = std.mem.indexOf(u8, g, "\n; filament used [g] = ") orelse return error.TestUnexpectedResult;
    const used_line = g[used + 1 ..][0..std.mem.indexOfScalar(u8, g[used + 1 ..], '\n').?];
    try testing.expectEqual(tools, std.mem.indexOf(u8, used_line, ", ") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, g, "\n; estimated printing time (normal mode) = "));
    try testing.expect(std.mem.indexOf(u8, g, if (tools) tool_types else "\n; filament_type = PLA\n") != null);

    var lines = std.mem.splitScalar(u8, g, '\n');
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    var relative = false;
    var printing = false;
    var t1: usize = 0;
    var pauses: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:0")) printing = true;
        if (std.mem.startsWith(u8, line, ";Filament used:")) printing = false;
        // Each variable of the maker's G-code has a value.
        if (std.mem.indexOf(u8, line, "zslice: no value for ") != null) {
            std.debug.print("{s}: {s}\n", .{ m.id, line });
            return error.TestUnexpectedResult;
        }
        const cmd = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, line, ';')) |c| line[0..c] else line, " \t\r");
        if (cmd.len == 0) continue;
        if (std.mem.indexOfAny(u8, cmd, "{}[]") != null) {
            std.debug.print("{s}: {s}\n", .{ m.id, line });
            return error.TestUnexpectedResult;
        }
        var words = std.mem.tokenizeScalar(u8, cmd, ' ');
        const op = words.next().?;
        if (std.mem.eql(u8, cmd, "T1") or std.mem.startsWith(u8, cmd, "T1 ")) t1 += 1;
        if (std.mem.eql(u8, op, "M600")) pauses += 1;
        if (std.mem.eql(u8, op, "G90")) relative = false;
        if (std.mem.eql(u8, op, "G91")) relative = true;
        // The temperatures: off, or in the range of the nozzle (the maker's
        // G-code also sets 70 to 170 °C to wait or to probe) and the bed.
        const nozzle = std.mem.eql(u8, op, "M104") or std.mem.eql(u8, op, "M109");
        const bed = std.mem.eql(u8, op, "M140") or std.mem.eql(u8, op, "M190");
        if (nozzle or bed) while (words.next()) |w| {
            if (w.len < 2 or (w[0] != 'S' and w[0] != 'R')) continue;
            const v = try std.fmt.parseFloat(f64, w[1..]);
            if (nozzle) try testing.expect(v == 0 or (v >= 50 and v <= 300));
            if (bed) try testing.expect(v >= 0 and v <= 120);
        };
        if (!(std.mem.eql(u8, op, "G0") or std.mem.eql(u8, op, "G1"))) continue;
        var e: f64 = 0;
        while (words.next()) |w| {
            if (w.len < 2) continue;
            const v = std.fmt.parseFloat(f64, w[1..]) catch continue;
            switch (w[0]) {
                'X' => x = if (relative) x + v else v,
                'Y' => y = if (relative) y + v else v,
                'Z' => z = if (relative) z + v else v,
                'E' => e = v,
                else => {},
            }
        }
        // The extrusions of the print stay on the bed and under the height.
        if (e <= 0 or !printing) continue;
        const eps = 1e-3;
        try testing.expect(x >= -eps and x <= s.machine.bed_size_x + eps);
        try testing.expect(y >= -eps and y <= s.machine.bed_size_y + eps);
        try testing.expect(z > 0 and z <= s.machine.max_height + eps);
    }
    if (tools) {
        try testing.expect(t1 > 0);
        try testing.expectEqual(@as(usize, 0), pauses);
    } else {
        try testing.expectEqual(@as(usize, 0), t1);
        try testing.expect(pauses > 0);
    }
}

test "plate job: each Prusa model of the library prints two filaments with its checks" {
    const printers = @import("printers.zig");
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    const lib = try printers.Library.parse(gpa, printers.builtin_data);
    defer lib.deinit();
    var count: usize = 0;
    for (lib.models, 0..) |m, i| {
        if (!std.mem.startsWith(u8, m.id, "prusa-")) continue;
        const check = for (prusa_checks) |c| {
            if (std.mem.eql(u8, c[0], m.id)) break c[1];
        } else {
            std.debug.print("{s}: not in prusa_checks\n", .{m.id});
            return error.TestUnexpectedResult;
        };
        checkPrusaModel(gpa, lib, i, check) catch |e| {
            std.debug.print("{s}: {s}\n", .{ m.id, @errorName(e) });
            return e;
        };
        count += 1;
    }
    try testing.expectEqual(prusa_checks.len, count);
}

/// The firmware facts of each Creality model of the library: Klipper or
/// Marlin, CoreXY, and a start G-code that calls the START_PRINT macro.
const creality_checks = [_]struct { id: []const u8, klipper: bool, corexy: bool, macro: bool }{
    .{ .id = "creality-cr-5-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-5-pro-h", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-6-max", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-6-se", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-8", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-max", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-mini", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-s", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-s4", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-s5", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-s-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-se", .klipper = true, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-smart", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-smart-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-v2", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10-v3", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-10s-pro-v2", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-20", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-20-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-100", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-200b", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-m4", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-cr-m4-se", .klipper = true, .corexy = false, .macro = false },
    .{ .id = "creality-cr-x", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-2", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-2-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-ender-3-v2", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-bltouch", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-max", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-max-neo", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-neo", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-s1", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-s1-plus", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-s1-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-s1-sonic", .klipper = true, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-v2", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-v2-neo", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-v3", .klipper = true, .corexy = false, .macro = true },
    .{ .id = "creality-ender-3-v3-ke", .klipper = true, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-v3-plus", .klipper = true, .corexy = false, .macro = true },
    .{ .id = "creality-ender-3-v3-se", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-3-v4", .klipper = true, .corexy = false, .macro = true },
    .{ .id = "creality-ender-4", .klipper = false, .corexy = true, .macro = false },
    .{ .id = "creality-ender-5", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5-max", .klipper = true, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5-plus", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5-pro-2019", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5-s1", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5-s1-sonic", .klipper = true, .corexy = false, .macro = false },
    .{ .id = "creality-ender-5s", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-ender-6", .klipper = false, .corexy = true, .macro = false },
    .{ .id = "creality-ender-7", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-hi", .klipper = true, .corexy = false, .macro = true },
    .{ .id = "creality-k1", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1-max", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1-max-cfs-c", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1-se", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1-se-cfs-c", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1-cfs-c", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1c", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k1c-cfs-c", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k2", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k2-plus", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k2-pro", .klipper = true, .corexy = true, .macro = true },
    .{ .id = "creality-k2-se", .klipper = true, .corexy = false, .macro = true },
    .{ .id = "creality-sermoon-d3", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-sermoon-d3-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-sermoon-m300", .klipper = true, .corexy = false, .macro = true },
    .{ .id = "creality-sermoon-v1", .klipper = false, .corexy = false, .macro = true },
    .{ .id = "creality-sermoon-v1-v1-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-sermoon-v1-pro", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-sermoon-d1", .klipper = false, .corexy = false, .macro = false },
    .{ .id = "creality-sparkx-i7", .klipper = true, .corexy = false, .macro = true },
};

/// The check of one Creality model of the library (see the test below): a
/// plate of two cubes of two filaments.
fn checkCrealityModel(gpa: Allocator, lib: *const @import("printers.zig").Library, i: usize, klipper: bool, corexy: bool, macro: bool) !void {
    const m = lib.models[i];
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var text: Writer.Allocating = .init(a);
    try lib.profileText(i, 0, &text.writer);
    var s: Settings = .{};
    s.engine.threads = 1;
    var diag: @import("profile.zig").Diagnostic = .{};
    try @import("profile.zig").apply(a, &s, .machine, m.id, text.written(), null, &diag);
    try testing.expectEqual(klipper, m.flavor == .klipper);
    try testing.expectEqual(corexy, std.mem.eql(u8, m.kinematics, "corexy"));
    const tools = s.machine.filament_change == .tool;
    const cx = s.machine.bed_size_x / 2;
    const cy = s.machine.bed_size_y / 2;
    var m1 = try testBox(cx - 15, cy - 5, cx - 5, cy + 5, 2);
    defer m1.deinit(gpa);
    var m2 = try testBox(cx + 5, cy - 5, cx + 15, cy + 5, 2);
    defer m2.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    second.material = "PETG";
    if (s.machine.nozzles >= 2) second.nozzle = 1;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try pj.writeGcode(&out.writer);
    const g = out.written();
    try testing.expectEqual(macro, std.mem.indexOf(u8, g, "\nSTART_PRINT") != null);

    var lines = std.mem.splitScalar(u8, g, '\n');
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    var relative = false;
    var printing = false;
    var t1: usize = 0;
    var pauses: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:0")) {
            printing = true;
            // The print uses absolute positions after the start G-code.
            try testing.expect(!relative);
        }
        if (std.mem.startsWith(u8, line, ";Filament used:")) printing = false;
        try testing.expect(std.mem.indexOf(u8, line, "zslice: no value for ") == null);
        const cmd = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, line, ';')) |c| line[0..c] else line, " \t\r");
        if (cmd.len == 0) continue;
        try testing.expect(std.mem.indexOfAny(u8, cmd, "{}[]") == null);
        var words = std.mem.tokenizeScalar(u8, cmd, ' ');
        const op = words.next().?;
        if (std.mem.eql(u8, cmd, "T1") or std.mem.startsWith(u8, cmd, "T1 ")) t1 += 1;
        // A pause for a change by hand: PAUSE on Klipper, M600 on Marlin.
        if (std.mem.eql(u8, op, if (klipper) "PAUSE" else "M600")) pauses += 1;
        if (std.mem.eql(u8, op, "G90")) relative = false;
        if (std.mem.eql(u8, op, "G91")) relative = true;
        const nozzle = std.mem.eql(u8, op, "M104") or std.mem.eql(u8, op, "M109");
        const bed = std.mem.eql(u8, op, "M140") or std.mem.eql(u8, op, "M190");
        if (nozzle or bed) while (words.next()) |w| {
            if (w.len < 2 or w[0] != 'S') continue;
            const v = try std.fmt.parseFloat(f64, w[1..]);
            if (nozzle) try testing.expect(v == 0 or (v >= 50 and v <= 300));
            if (bed) try testing.expect(v >= 0 and v <= 120);
        };
        if (!(std.mem.eql(u8, op, "G0") or std.mem.eql(u8, op, "G1"))) continue;
        var e: f64 = 0;
        while (words.next()) |w| {
            if (w.len < 2) continue;
            const v = std.fmt.parseFloat(f64, w[1..]) catch continue;
            switch (w[0]) {
                'X' => x = if (relative) x + v else v,
                'Y' => y = if (relative) y + v else v,
                'Z' => z = if (relative) z + v else v,
                'E' => e = v,
                else => {},
            }
        }
        // The extrusions of the print stay on the bed and under the height.
        if (e <= 0 or !printing) continue;
        const eps = 1e-3;
        try testing.expect(x >= s.machine.origin_x - eps and x <= s.machine.origin_x + s.machine.bed_size_x + eps);
        try testing.expect(y >= s.machine.origin_y - eps and y <= s.machine.origin_y + s.machine.bed_size_y + eps);
        try testing.expect(z > 0 and z <= s.machine.max_height + eps);
    }
    if (tools) try testing.expect(t1 > 0) else try testing.expect(pauses > 0);
}

test "plate job: each Creality model of the library prints two filaments with its checks" {
    const printers = @import("printers.zig");
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    const lib = try printers.Library.parse(gpa, printers.builtin_data);
    defer lib.deinit();
    var count: usize = 0;
    for (lib.models, 0..) |m, i| {
        if (!std.mem.startsWith(u8, m.id, "creality-")) continue;
        const check = for (creality_checks) |c| {
            if (std.mem.eql(u8, c.id, m.id)) break c;
        } else {
            std.debug.print("{s}: not in creality_checks\n", .{m.id});
            return error.TestUnexpectedResult;
        };
        checkCrealityModel(gpa, lib, i, check.klipper, check.corexy, check.macro) catch |e| {
            std.debug.print("{s}: {s}\n", .{ m.id, @errorName(e) });
            return e;
        };
        count += 1;
    }
    try testing.expectEqual(creality_checks.len, count);
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
    // A gap of at least 10 mm between their edges.
    try testing.expect(@abs(tw.list[0].x - tw.list[1].x) - (tw.list[0].size + tw.list[1].size) / 2 >= 10 - 1e-9);
    try testing.expect(tw.of_slot[0] != tw.of_slot[1]);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    const g = out.written();
    // The interface prints with T1; the support body and the part with
    // T0. Each purge prints in the tower of its filament.
    var it = std.mem.splitScalar(u8, g, '\n');
    var tool: u8 = 0;
    var feature: []const u8 = "";
    var iface_t1: usize = 0;
    var iface_t0: usize = 0;
    var body_t1: usize = 0;
    var tower_x: [2]?f64 = .{ null, null };
    var purge = false;
    var after_change = false;
    var mixed = false;
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "T0")) tool = 0;
        if (std.mem.eql(u8, line, "T1")) tool = 1;
        if (std.mem.startsWith(u8, line, "; filament change")) after_change = true;
        if (std.mem.startsWith(u8, line, ";TYPE:")) {
            feature = line[6..];
            purge = after_change and std.mem.eql(u8, feature, "PRIME-TOWER");
            after_change = false;
        }
        if (std.mem.eql(u8, line, ";WIPE")) purge = false;
        const extrudes = std.mem.startsWith(u8, line, "G1 X") and std.mem.indexOf(u8, line, " E") != null;
        if (!extrudes) continue;
        if (std.mem.eql(u8, feature, "SUPPORT-INTERFACE")) {
            if (tool == 1) iface_t1 += 1 else iface_t0 += 1;
        }
        if (std.mem.eql(u8, feature, "SUPPORT") and tool == 1) body_t1 += 1;
        // The purge of a change: in the tower of its filament. The loop
        // and the grid of a tower can print with another filament.
        if (purge) {
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
    // No PETG purge on the PLA tower, no PLA purge on the PETG tower.
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

test "plate job: a tower holds the whole purge of a layer, row by row" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 10, 10, 3);
    var m = try b.finish();
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.project.flush_into_hidden = false;
    s.filament.color = "#000000";
    var white = s.filament;
    white.color = "#ffffff";
    // A black part and a white part: a black-white change on each layer,
    // the most flush.
    var b2: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b2, 30, 0, 0, 40, 10, 3);
    var m2 = try b2.finish();
    defer m2.deinit(gpa);
    const on2 = [_]settings_mod.Change{.{ .name = "project.filament", .value = "2" }};
    const parts = [_]PartInput{ .{ .mesh = &m, .part = 0 }, .{ .mesh = &m2, .part = 1, .changes = &on2 } };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{white} });
    defer pj.deinit();
    const tw = pj.towers();
    try testing.expect(tw.n == 1);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    try testing.expect(st.changes > 2);
    try testing.expect(st.flush_mm > 0);
    // The whole purge fits: nothing is short, and the tower is deeper
    // than wide when one layer needs more rows than a square holds.
    try testing.expectEqual(@as(f64, 0), st.tower_short_mm3);
    const per_layer = 2 * filaments_mod.flushVolume("#000000", "#ffffff", s.machine.flush_volume, s.project.flush_multiplier);
    // The rows fill the area inside the loop.
    const lw = pj.resolved.line_width;
    const square = (tw.list[0].size - 3 * lw) * (tw.list[0].size - 2 * lw) * s.project.layer_height;
    // A tower with ribs stays square, as in Bambu Studio.
    if (tw.list[0].rib) {
        try testing.expectEqual(tw.list[0].size, tw.list[0].ySize());
    } else if (per_layer > square) try testing.expect(tw.list[0].ySize() > tw.list[0].size);
    // No two purge rows of one layer at one y. The purge is the tower
    // block after a change, up to its wipe.
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    var purge = false;
    var after_change = false;
    var ys: std.ArrayList(i64) = .empty;
    defer ys.deinit(gpa);
    var last_y: i64 = std.math.minInt(i64);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) ys.clearRetainingCapacity();
        if (std.mem.startsWith(u8, line, "G0 ")) last_y = std.math.minInt(i64);
        if (std.mem.startsWith(u8, line, "; filament change")) after_change = true;
        if (std.mem.startsWith(u8, line, ";TYPE:")) {
            purge = after_change and std.mem.eql(u8, line[6..], "PRIME-TOWER");
            after_change = false;
        }
        if (std.mem.eql(u8, line, ";WIPE")) purge = false;
        if (!purge) continue;
        if (!std.mem.startsWith(u8, line, "G1 X") or std.mem.indexOf(u8, line, " E") == null) continue;
        const yi = std.mem.indexOf(u8, line, " Y") orelse continue;
        var e = yi + 2;
        while (e < line.len and line[e] != ' ') e += 1;
        const y = std.fmt.parseFloat(f64, line[yi + 2 .. e]) catch continue;
        // A row: a line along x, at the y of the line before it.
        const key: i64 = @intFromFloat(@round(y * 100));
        if (key == last_y) {
            try testing.expect(std.mem.indexOfScalar(i64, ys.items, key) == null);
            try ys.append(gpa, key);
        }
        last_y = key;
    }
}

test "plate job: one change late in the print gives a small tower" {
    const gpa = testing.allocator;
    // A plaque: filament 2 from z 2 mm, one change.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 40, 20, 3);
    var m = try b.finish();
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.project.flush_into_hidden = false;
    var red = s.filament;
    red.color = "#e03030";
    const ov = [_]settings_mod.Override{.{ .z_min = 2, .z_max = 10, .name = "project.filament", .value = "2" }};
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{red}, .overrides = &ov });
    defer pj.deinit();
    const tw = pj.towers();
    try testing.expectEqual(@as(usize, 1), tw.n);
    // Room for one flush into red on one layer, as near a square as it
    // can be: no long column.
    const t = tw.list[0];
    const flush = filaments_mod.flushVolume(s.filament.color, red.color, s.machine.flush_volume, s.project.flush_multiplier);
    const area = flush / s.project.layer_height;
    try testing.expect(t.size * t.ySize() <= @max(area * 1.5, s.project.prime_tower_width * s.project.prime_tower_width) + 1e-9);
    try testing.expect(t.ySize() <= t.size + 1);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    try testing.expectEqual(@as(u32, 1), st.changes);
    try testing.expectEqual(@as(f64, 0), st.tower_short_mm3);
}

/// The extrusion moves of a G-code of two tools (T0 and T1, no change
/// G-code): for each tool, the moves with X or Y and a positive E, as
/// text, the highest feed (mm/s) of them, and the sum of their E.
const ToolMoves = struct {
    lines: [2]std.ArrayList([]const u8) = .{ .empty, .empty },
    max_feed: [2]f64 = .{ 0, 0 },
    e: [2]f64 = .{ 0, 0 },

    fn init(a: Allocator, g: []const u8) !ToolMoves {
        var out: ToolMoves = .{};
        var tool: usize = 0;
        var feed: f64 = 0;
        var it = std.mem.splitScalar(u8, g, '\n');
        while (it.next()) |line| {
            if (line.len >= 2 and line[0] == 'T' and (line[1] == '0' or line[1] == '1')) tool = line[1] - '0';
            if (!std.mem.startsWith(u8, line, "G1 ") and !std.mem.startsWith(u8, line, "G0 ")) continue;
            var e: f64 = 0;
            var xy = false;
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            while (words.next()) |wd| switch (wd[0]) {
                'F' => feed = (std.fmt.parseFloat(f64, wd[1..]) catch 0) / 60,
                'E' => e = std.fmt.parseFloat(f64, wd[1..]) catch 0,
                'X', 'Y' => xy = true,
                else => {},
            };
            if (!xy or !(e > 0)) continue;
            try out.lines[tool].append(a, line);
            out.max_feed[tool] = @max(out.max_feed[tool], feed);
            out.e[tool] += e;
        }
        return out;
    }
};

/// Two boxes on a printer with two nozzles (T0 and T1, a plain tool
/// change): the first of filament 1 on the main nozzle, the second of
/// filament 2 on the second nozzle, with the settings `s`.
fn twoNozzleGcode(a: Allocator, s: Settings) ![]const u8 {
    const gpa = testing.allocator;
    var m1 = try testBox(60, 90, 90, 120, 6);
    defer m1.deinit(gpa);
    var m2 = try testBox(130, 90, 160, 120, 6);
    defer m2.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    second.nozzle = 1;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(a);
    _ = try pj.writeGcode(&out.writer);
    return out.written();
}

fn twoNozzleSettings() Settings {
    var s: Settings = .{};
    s.engine.threads = 1;
    s.machine.bed_size_x = 250;
    s.machine.bed_size_y = 250;
    s.machine.nozzles = 2;
    s.machine.filament_change = .tool;
    s.machine.max_speed = 200;
    s.filament.max_flow = 30;
    return s;
}

test "second nozzle: a speed limit of 50 mm/s slows only the lines of the second nozzle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = twoNozzleSettings();
    const before = try ToolMoves.init(a, try twoNozzleGcode(a, s));
    s.machine.nozzle[1].max_speed = 50;
    const after = try ToolMoves.init(a, try twoNozzleGcode(a, s));
    // Before, the second nozzle prints faster than 50 mm/s; after, no
    // line of it does (the F values of its lines).
    try testing.expect(before.max_feed[1] > 60);
    try testing.expect(after.max_feed[1] <= 50 + 1e-6);
    try testing.expect(after.lines[1].items.len > 100);
    // The lines of the main nozzle stay as they were.
    try testing.expect(after.max_feed[0] > 60);
    try testing.expectEqual(before.lines[0].items.len, after.lines[0].items.len);
    for (before.lines[0].items, after.lines[0].items) |x, y| try testing.expectEqualStrings(x, y);
    // A ratio of the speeds: half the speed of each line.
    s.machine.nozzle[1].max_speed = 0;
    s.machine.nozzle[1].speed = 0.5;
    const half = try ToolMoves.init(a, try twoNozzleGcode(a, s));
    try testing.expectApproxEqAbs(before.max_feed[1] / 2, half.max_feed[1], 0.02);
    try testing.expectEqual(before.lines[0].items.len, half.lines[0].items.len);
    // On a printer with one nozzle, the settings of the second change no line.
    var one = s;
    one.machine.nozzles = 1;
    one.machine.nozzle[1].speed = 0;
    const plain = try twoNozzleGcode(a, one);
    one.machine.nozzle[1].speed = 0.5;
    one.machine.nozzle[1].max_speed = 50;
    one.machine.nozzle[1].line_width = 0.6;
    one.machine.nozzle[1].retract_length = 3;
    // The G-code, but the list of the settings at its end.
    const body = struct {
        fn f(g: []const u8) []const u8 {
            return g[0 .. std.mem.indexOf(u8, g, ";zslice settings") orelse g.len];
        }
    }.f;
    try testing.expectEqualStrings(body(plain), body(try twoNozzleGcode(a, one)));
}

/// Two filaments: the second on the second nozzle.
fn twoSlots() settings_mod.SlotNozzles {
    var out: settings_mod.SlotNozzles = .{ .count = 2 };
    out.nozzle[1] = 1;
    return out;
}

test "second nozzle: its line width changes only its lines" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = twoNozzleSettings();
    const before = try ToolMoves.init(a, try twoNozzleGcode(a, s));
    s.machine.nozzle[1].line_width = 0.6;
    const after = try ToolMoves.init(a, try twoNozzleGcode(a, s));
    // The main nozzle: the same lines.
    try testing.expectEqual(before.lines[0].items.len, after.lines[0].items.len);
    for (before.lines[0].items, after.lines[0].items) |x, y| try testing.expectEqualStrings(x, y);
    // The second nozzle: other lines, fewer of them (wider lines fill the
    // part with fewer lines), and about the same plastic.
    try testing.expect(after.lines[1].items.len < before.lines[1].items.len);
    try testing.expectApproxEqRel(before.e[1], after.e[1], 0.15);
    // A diameter of its own: 1.1 times it with the automatic width.
    s.machine.nozzle[1].line_width = 0;
    s.machine.nozzle[1].diameter = 0.6;
    const r = try s.resolveFor(twoSlots());
    try testing.expectApproxEqAbs(@as(f64, 0.44), r.line_width, 1e-9);
    var on2 = s;
    on2.project.filament = 2;
    const r2 = try on2.resolveFor(twoSlots());
    try testing.expectApproxEqAbs(@as(f64, 0.66), r2.line_width, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.75), r2.first_layer_line_width, 1e-9);
    try testing.expectEqual(@as(f64, 0.6), r2.settings.machine.nozzle_diameter);
}

test "second nozzle: its retraction" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = twoNozzleSettings();
    s.machine.retract_length = 0.8;
    s.machine.nozzle[1].retract_length = 2;
    s.machine.nozzle[1].retract_speed = 20;
    const g = try twoNozzleGcode(a, s);
    // Each retraction of the second nozzle is 2 mm at 20 mm/s, and each
    // of the first 0.8 mm.
    var tool: usize = 0;
    var n = [2]usize{ 0, 0 };
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        if (line.len >= 2 and line[0] == 'T') tool = line[1] - '0';
        if (!std.mem.startsWith(u8, line, "G1 E-")) continue;
        n[tool] += 1;
        if (tool == 1) {
            try testing.expectEqualStrings("G1 E-2 F1200", line);
        } else try testing.expect(std.mem.startsWith(u8, line, "G1 E-0.8 F"));
    }
    try testing.expect(n[0] > 0 and n[1] > 0);
}

/// A box of `h` mm with sparse infill on a printer with two nozzles, its
/// infill of filament 2 on the second nozzle, with layers of 0.1 mm.
fn infillNozzleGcode(a: Allocator, infill_layers: u32) ![]const u8 {
    const gpa = testing.allocator;
    var m1 = try testBox(80, 80, 110, 110, 6);
    defer m1.deinit(gpa);
    var s = twoNozzleSettings();
    s.project.layer_height = 0.1;
    s.project.first_layer_height = 0.2;
    s.project.infill_density = 0.2;
    s.project.infill_pattern = .grid;
    s.project.infill_filament = 2;
    s.project.infill_layers = infill_layers;
    var second = s.filament;
    second.color = "#d93a3a";
    second.nozzle = 1;
    const parts = [_]PartInput{.{ .mesh = &m1, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(a);
    _ = try pj.writeGcode(&out.writer);
    return out.written();
}

/// For each layer of a G-code: the infill of the second nozzle (lines
/// of ";TYPE:FILL" after T1), the walls, the infill of the main nozzle,
/// the E of the infill of the second nozzle, and the tool changes.
const InfillLayers = struct {
    infill: std.ArrayList(bool) = .empty,
    walls: std.ArrayList(bool) = .empty,
    main_infill: bool = false,
    e: f64 = 0,
    changes: usize = 0,

    fn init(a: Allocator, g: []const u8) !InfillLayers {
        var out: InfillLayers = .{};
        var tool: usize = 0;
        var kind: []const u8 = "";
        var it = std.mem.splitScalar(u8, g, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, ";LAYER:")) {
                try out.infill.append(a, false);
                try out.walls.append(a, false);
            }
            if (line.len >= 2 and line[0] == 'T' and (line[1] == '0' or line[1] == '1')) {
                if (line[1] - '0' != tool) out.changes += 1;
                tool = line[1] - '0';
            }
            if (std.mem.startsWith(u8, line, ";TYPE:")) kind = line[6..];
            if (out.infill.items.len == 0 or !std.mem.startsWith(u8, line, "G1 X")) continue;
            const e_at = std.mem.indexOf(u8, line, " E") orelse continue;
            const k = out.infill.items.len - 1;
            if (std.mem.eql(u8, kind, "FILL")) {
                if (tool == 1) {
                    out.infill.items[k] = true;
                    out.e += std.fmt.parseFloat(f64, std.mem.trimEnd(u8, line[e_at + 2 ..], " ")) catch 0;
                } else out.main_infill = true;
            }
            if (std.mem.startsWith(u8, kind, "WALL")) {
                // The walls print with the main nozzle.
                try testing.expectEqual(@as(usize, 0), tool);
                out.walls.items[k] = true;
            }
        }
        return out;
    }
};

test "second nozzle: combined infill on the second nozzle every second layer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const each = try InfillLayers.init(a, try infillNozzleGcode(a, 1));
    const comb = try InfillLayers.init(a, try infillNozzleGcode(a, 2));
    // With the infill on each layer, the second nozzle prints all of it.
    try testing.expect(!each.main_infill);
    try testing.expectEqual(each.walls.items.len, comb.walls.items.len);
    var n_each: usize = 0;
    var n_comb: usize = 0;
    var last: ?usize = null;
    for (comb.walls.items, comb.infill.items, each.infill.items, 0..) |w, f, f1, k| {
        // The walls print on each layer.
        try testing.expect(w);
        n_each += @intFromBool(f1);
        if (!f) continue;
        n_comb += 1;
        // The tall beads: on every second layer.
        if (last) |l| try testing.expectEqual(@as(usize, 2), k - l);
        last = k;
    }
    try testing.expect(n_comb > 10);
    try testing.expect(n_comb * 2 <= n_each + 2);
    // The tall beads of 0.2 mm have the plastic of two layers of 0.1 mm:
    // about the same plastic in all.
    try testing.expectApproxEqRel(each.e, comb.e, 0.2);
    // Combined: one change to the second nozzle in each group, on its
    // top layer after the walls, and one back on the next layer. On each
    // layer: one change, as the order of the filaments turns on each
    // layer (walls then infill, then infill then walls).
    try testing.expect(comb.changes <= 2 * n_comb + 4);
    try testing.expect(each.changes + 4 >= n_each and each.changes <= n_each + 4);
}

/// The G-code of a plate of two boxes on the machine of the library
/// with id `id` (or a plain tool changer for "generic"): box 1 of
/// filament 1, and box 2 of filament 2 (on the second nozzle of a head
/// with two). With `late`, one box only, of filament 2 from z 3 mm: one
/// change, on layer 14.
fn towerPlate(gpa: Allocator, id: []const u8, late: bool, second_material: []const u8, sup: bool) ![]u8 {
    const printers = @import("printers.zig");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s: Settings = .{};
    s.engine.threads = 2;
    if (std.mem.eql(u8, id, "generic")) {
        s.machine.filament_change = .tool;
    } else {
        if (printers.builtin_data.len == 0) return error.SkipZigTest;
        const lib = try printers.Library.parse(gpa, printers.builtin_data);
        defer lib.deinit();
        const i = lib.find(id) orelse return error.NoModel;
        var text: Writer.Allocating = .init(a);
        try lib.profileText(i, 0, &text.writer);
        var diag: @import("profile.zig").Diagnostic = .{};
        try @import("profile.zig").apply(a, &s, .machine, id, text.written(), null, &diag);
    }
    const cx = s.machine.bed_size_x / 2;
    const cy = s.machine.bed_size_y / 2;
    var m1 = try testBox(cx - 25, cy - 10, cx - 5, cy + 10, 5);
    defer m1.deinit(gpa);
    var m2 = try testBox(cx + 5, cy - 10, cx + 25, cy + 10, 5);
    defer m2.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    second.material = second_material;
    if (s.machine.nozzles >= 2) second.nozzle = 1;
    if (sup) {
        // A shelf over air: support under it, with an interface of
        // filament 2.
        s.project.support = .everywhere;
        s.project.support_interface_filament = 2;
    }
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, cx - 25, cy - 10, 0, cx - 15, cy + 10, 5);
    try mesh_mod.shapes.addBox(&b, cx - 15, cy - 10, 3, cx + 5, cy + 10, 5);
    var shelf = try b.finish();
    defer shelf.deinit(gpa);
    const ov = [_]settings_mod.Override{.{ .z_min = 3, .z_max = 100, .name = "project.filament", .value = "2" }};
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    const one = [_]PartInput{.{ .mesh = if (sup) &shelf else &m1, .part = 0 }};
    var pj = if (late)
        try PlateJob.init(gpa, s, &one, .{ .filaments = &.{second}, .overrides = &ov })
    else if (sup)
        try PlateJob.init(gpa, s, &one, .{ .filaments = &.{second} })
    else
        try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    return gcodeOf(&pj);
}

/// The checks of the prime tower in G-code `g` with tool changes:
/// - each change goes to the tower before any line of the part: the
///   first feature after a change is the tower;
/// - each tower line prints at the z of the layer (no move down into the
///   tower; a z hop up and back to the layer is fine);
/// - each layer up to the last change has a layer of the tower.
/// Returns the count of changes.
fn checkTowerOrder(g: []const u8) !usize {
    var changes: usize = 0;
    var after_change = false;
    var in_tower = false;
    var layer: usize = 0;
    var layers_with_tower: usize = 0;
    var tower_this_layer = false;
    var last_change_layer: usize = 0;
    // The z of the layer: the first Z move after the layer mark.
    var layer_z: ?f64 = null;
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) {
            if (tower_this_layer) layers_with_tower += 1;
            tower_this_layer = false;
            layer = try std.fmt.parseInt(usize, line[7..], 10);
            in_tower = false;
            layer_z = null;
        } else if (std.mem.startsWith(u8, line, "; filament change")) {
            changes += 1;
            after_change = true;
            in_tower = false;
            last_change_layer = layer;
        } else if (std.mem.startsWith(u8, line, ";TYPE:")) {
            in_tower = std.mem.eql(u8, line[6..], "PRIME-TOWER");
            if (after_change and !in_tower) {
                std.debug.print("change {d}: {s} before the tower\n", .{ changes, line });
                return error.TestUnexpectedResult;
            }
            after_change = false;
            if (in_tower) tower_this_layer = true;
        } else if (std.mem.startsWith(u8, line, "G0 Z") or std.mem.startsWith(u8, line, "G1 Z")) {
            const end = std.mem.indexOfScalarPos(u8, line, 4, ' ') orelse line.len;
            const z = std.fmt.parseFloat(f64, line[4..end]) catch continue;
            if (layer_z == null) {
                layer_z = z;
            } else if (in_tower and z < layer_z.? - 1e-6) {
                std.debug.print("layer {d}: the nozzle goes down into the tower\n", .{layer});
                return error.TestUnexpectedResult;
            }
        }
    }
    if (tower_this_layer) layers_with_tower += 1;
    try testing.expect(changes > 0);
    try testing.expect(layers_with_tower >= last_change_layer + 1);
    return changes;
}

test "plate job: each change primes on the tower before the part, on each printer kind" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "bambu-lab-x2d", "bambu-lab-a1", "bambu-lab-x1-carbon", "generic" }) |id| {
        const g = try towerPlate(gpa, id, false, "PLA", false);
        defer gpa.free(g);
        const n = checkTowerOrder(g) catch |e| {
            std.debug.print("{s}\n", .{id});
            return e;
        };
        try testing.expect(n > 10);
        // A wipe on the tower after each prime.
        try testing.expect(std.mem.count(u8, g, ";WIPE\n") >= n);
    }
}

test "plate job: a first change on a late layer finds the tower at the height of the nozzle" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "bambu-lab-x2d", "generic" }) |id| {
        const g = try towerPlate(gpa, id, true, "PLA", false);
        defer gpa.free(g);
        // One change, on layer 14: the tower has a layer on each layer
        // before it (its loop and grid), so the change primes on its top.
        try testing.expectEqual(@as(usize, 1), try checkTowerOrder(g));
        const at = std.mem.indexOf(u8, g, "; filament change 1").?;
        try testing.expect(std.mem.count(u8, g[0..at], ";TYPE:PRIME-TOWER\n") >= 14);
    }
}

test "plate job: towers of two families grow on each layer, at the z of the print" {
    const gpa = testing.allocator;
    // PLA and PETG: a tower for each, and a PETG support interface. Each
    // change primes at the z of the layer.
    const g = try towerPlate(gpa, "generic", false, "PETG", false);
    defer gpa.free(g);
    _ = try checkTowerOrder(g);
    const g2 = try towerPlate(gpa, "generic", false, "PETG", true);
    defer gpa.free(g2);
    _ = try checkTowerOrder(g2);
}

test "plate job: a switch of the nozzles of the X2D: no flush, the idle nozzle waits, the new nozzle gets its temperature back" {
    const gpa = testing.allocator;
    const g = try towerPlate(gpa, "bambu-lab-x2d", false, "PLA", false);
    defer gpa.free(g);
    var it = std.mem.splitScalar(u8, g, '\n');
    var switches: usize = 0;
    var idle: usize = 0;
    var reheat: usize = 0;
    var to: u8 = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "; filament change")) {
            switches += 1;
            to = line[line.len - 1];
        }
        // Each nozzle holds its own filament: no color flush.
        if (std.mem.startsWith(u8, line, "M620.10 A1 ") and switches > 0) {
            try testing.expect(std.mem.indexOf(u8, line, " L0 ") != null);
        }
        // The idle nozzle: filament 1 is on the main nozzle (firmware
        // index 1), filament 2 on the second one (index 0). After a change
        // to filament 2, the main nozzle waits 10 °C below 210 °C.
        if (std.mem.startsWith(u8, line, "M104 T")) {
            idle += 1;
            const want: []const u8 = if (to == '2') "M104 T1 S" else "M104 T0 S";
            try testing.expect(std.mem.startsWith(u8, line, want));
            const t = try std.fmt.parseFloat(f64, line[9..std.mem.indexOfScalarPos(u8, line, 9, ' ').?]);
            try testing.expect(t >= 190 and t < 215);
        }
        if (std.mem.startsWith(u8, line, "M104 S") and std.mem.indexOf(u8, line, "cooling for the tower") != null) reheat += 1;
    }
    try testing.expect(switches > 10);
    try testing.expectEqual(switches, idle);
    try testing.expectEqual(switches, reheat);
    // A printer with one nozzle: no M104 T.
    const a1 = try towerPlate(gpa, "bambu-lab-a1", false, "PLA", false);
    defer gpa.free(a1);
    try testing.expect(std.mem.indexOf(u8, a1, "\nM104 T") == null);
}

test "plate job: infill on the second nozzle of the X2D: a tower on each layer up to the last infill change, no flush at a switch" {
    const printers = @import("printers.zig");
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lib = try printers.Library.parse(gpa, printers.builtin_data);
    defer lib.deinit();
    const id = "bambu-lab-x2d";
    var text: Writer.Allocating = .init(a);
    try lib.profileText(lib.find(id).?, 0, &text.writer);
    var s: Settings = .{};
    s.engine.threads = 2;
    var diag: @import("profile.zig").Diagnostic = .{};
    try @import("profile.zig").apply(a, &s, .machine, id, text.written(), null, &diag);
    s.project.infill_density = 0.2;
    s.project.infill_filament = 2;
    const cx = s.machine.bed_size_x / 2;
    const cy = s.machine.bed_size_y / 2;
    var m = try testBox(cx - 15, cy - 15, cx + 15, cy + 15, 5);
    defer m.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    second.nozzle = 1;
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    const tw = pj.towers();
    try testing.expectEqual(@as(usize, 1), tw.n);
    // The infill stops under the top skin: the tower stops at its last
    // change, below the top of the part.
    try testing.expect(tw.list[0].last_layer + 1 < pj.levels.len);
    const g = try gcodeOf(&pj);
    defer gpa.free(g);
    // Each change primes on the tower first, at the z of the layer, and
    // each layer up to the last change has a layer of the tower.
    const n = try checkTowerOrder(g);
    try testing.expect(n > 10);
    // Each nozzle holds its own filament: no flush at a switch.
    var it = std.mem.splitScalar(u8, g, '\n');
    var changes: usize = 0;
    var flushes: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "; filament change")) changes += 1;
        if (changes > 0 and std.mem.startsWith(u8, line, "M620.10 A1 ")) {
            flushes += 1;
            try testing.expect(std.mem.indexOf(u8, line, " L0 ") != null);
        }
    }
    try testing.expectEqual(changes, flushes);
}

/// The G-code of three boxes of three filaments on the Prusa XL 5T of
/// the library: filament 1 on nozzle 0 (215 °C), filament 2 on nozzle 3
/// (240 °C), and filament 3 on nozzle 1 (230 °C). Nozzle 3 has a tool
/// offset of 10 mm in X, and the next nozzle heats 30 s before a change.
fn xlGcode(a: Allocator) ![]const u8 {
    const gpa = testing.allocator;
    const printers = @import("printers.zig");
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    var s: Settings = .{};
    s.engine.threads = 2;
    const lib = try printers.Library.parse(gpa, printers.builtin_data);
    defer lib.deinit();
    const i = lib.find("prusa-xl-5t") orelse return error.NoModel;
    var text: Writer.Allocating = .init(a);
    try lib.profileText(i, 0, &text.writer);
    var diag: @import("profile.zig").Diagnostic = .{};
    try @import("profile.zig").apply(a, &s, .machine, "prusa-xl-5t", text.written(), null, &diag);
    s.machine.nozzle[3].offset_x = 10;
    s.machine.preheat_time = 30;
    s.filament.nozzle_temp = 215;
    s.filament.first_layer_nozzle_temp = 215;
    var m1 = try testBox(100, 150, 120, 170, 4);
    defer m1.deinit(gpa);
    var m2 = try testBox(150, 150, 170, 170, 4);
    defer m2.deinit(gpa);
    var m3 = try testBox(200, 150, 220, 170, 4);
    defer m3.deinit(gpa);
    var second = s.filament;
    second.color = "#d93a3a";
    second.nozzle = 3;
    second.nozzle_temp = 240;
    second.first_layer_nozzle_temp = 240;
    var third = s.filament;
    third.color = "#3a3ad9";
    third.nozzle = 1;
    third.nozzle_temp = 230;
    third.first_layer_nozzle_temp = 230;
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
        .{ .mesh = &m3, .part = 2, .changes = &.{.{ .name = "project.filament", .value = "3" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{ second, third } });
    defer pj.deinit();
    var out: Writer.Allocating = .init(a);
    _ = try pj.writeGcode(&out.writer);
    return out.written();
}

test "tool changer: an XL 5T prints three filaments on three tools" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try xlGcode(a);
    const has = struct {
        fn f(text: []const u8, want: []const u8) bool {
            return std.mem.indexOf(u8, text, want) != null;
        }
    }.f;
    // Tool changes to the nozzle of each filament, with the change
    // G-code of PrusaSlicer, and no pause.
    try testing.expect(!has(g, "M600"));
    try testing.expect(!has(g, "\nPAUSE"));
    try testing.expect(has(g, "\nT3 S1 L0 D0\n"));
    try testing.expect(has(g, "\nT1 S1 L0 D0\n"));
    try testing.expect(has(g, "; Change Tool0 -> Tool3"));
    // The temperature of each tool is the one of its filament: the
    // change G-code waits for it (temperature[next_extruder]).
    try testing.expect(has(g, "\nM109 S240 T3\n"));
    try testing.expect(has(g, "\nM109 S230 T1\n"));
    // The start G-code: the tools that the print uses, and the heaters
    // of the others off.
    try testing.expect(has(g, "M862.1 T0 P0.4"));
    try testing.expect(has(g, "M862.1 T1 P0.4"));
    try testing.expect(has(g, "M862.1 T3 P0.4"));
    try testing.expect(!has(g, "M862.1 T2 "));
    try testing.expect(has(g, "\nM104 T2 S0\n"));
    try testing.expect(has(g, "\nM104 T4 S0\n"));
    // The idle tool waits 110 °C below its temperature (the ooze
    // prevention of the XL print profiles of PrusaSlicer).
    try testing.expect(has(g, "\nM104 T0 S105 ; the nozzle waits\n"));
    try testing.expect(has(g, "\nM104 T3 S130 ; the nozzle waits\n"));
    // The next tool heats before its change.
    try testing.expect(has(g, " ; the next nozzle heats\n"));
    // The tower primes each tool after its change.
    const changes = try checkTowerOrder(g);
    try testing.expect(changes >= 4);
    // The tool offset of nozzle 3: its lines are 10 mm to the left of
    // its box (x 150 to 170), and the lines of the others are on their
    // boxes.
    var tool: u8 = 0;
    var min_x = [_]f64{std.math.inf(f64)} ** 5;
    var max_x = [_]f64{-std.math.inf(f64)} ** 5;
    var in_part = false;
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        if (line.len >= 2 and line[0] == 'T' and line[1] >= '0' and line[1] <= '4' and (line.len == 2 or line[2] == ' ')) tool = line[1] - '0';
        if (std.mem.startsWith(u8, line, ";TYPE:")) in_part = std.mem.indexOf(u8, line, "WALL") != null;
        if (!in_part or !std.mem.startsWith(u8, line, "G1 X")) continue;
        if (std.mem.indexOf(u8, line, " E") == null) continue;
        const end = std.mem.indexOfScalarPos(u8, line, 4, ' ') orelse line.len;
        const x = try std.fmt.parseFloat(f64, line[4..end]);
        min_x[tool] = @min(min_x[tool], x);
        max_x[tool] = @max(max_x[tool], x);
    }
    try testing.expect(min_x[0] > 99 and max_x[0] < 121);
    try testing.expect(min_x[3] > 139 and max_x[3] < 161);
    try testing.expect(min_x[1] > 199 and max_x[1] < 221);
}

test "tool changer: the moved settings of the second nozzle load into nozzle 1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s: Settings = .{};
    var diag: @import("profile.zig").Diagnostic = .{};
    try @import("profile.zig").apply(a, &s, .machine, "old", "nozzles = 2\nnozzle2_diameter = 0.6\nnozzle2_max_speed = 200\nnozzle2_min_x = 20.5\nnozzle2_retract_length = 2\n", null, &diag);
    try testing.expectEqual(@as(f64, 0.6), s.machine.nozzle[1].diameter);
    try testing.expectEqual(@as(f64, 200), s.machine.nozzle[1].max_speed);
    try testing.expectEqual(@as(f64, 20.5), s.machine.nozzle[1].min_x);
    try testing.expectEqual(@as(f64, 2), s.machine.nozzle[1].retract_length);
    // Saved again, the text has the new names, and loads the same.
    var out: Writer.Allocating = .init(a);
    try @import("profile.zig").writeChanged(s, .machine, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nnozzle.1.diameter = 0.6\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "nozzle2_") == null);
    var t: Settings = .{};
    try @import("profile.zig").apply(a, &t, .machine, "new", out.written(), null, &diag);
    try testing.expectEqual(s.machine.nozzle[1].diameter, t.machine.nozzle[1].diameter);
    try testing.expectEqual(s.machine.nozzle[1].min_x, t.machine.nozzle[1].min_x);
}

test "tool changer: two filaments on one nozzle change with a pause" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = twoNozzleSettings();
    s.machine.nozzles = 3;
    s.machine.tool_numbers = .nozzle;
    s.machine.standby_delta = -50;
    // Both filaments on nozzle 2: a pause, and no tool change.
    var m1 = try testBox(60, 90, 90, 120, 3);
    defer m1.deinit(gpa);
    var m2 = try testBox(130, 90, 160, 120, 3);
    defer m2.deinit(gpa);
    s.filament.nozzle = 2;
    var second = s.filament;
    second.color = "#d93a3a";
    const parts = [_]PartInput{
        .{ .mesh = &m1, .part = 0 },
        .{ .mesh = &m2, .part = 1, .changes = &.{.{ .name = "project.filament", .value = "2" }} },
    };
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj.deinit();
    var out: Writer.Allocating = .init(a);
    _ = try pj.writeGcode(&out.writer);
    const g = out.written();
    try testing.expect(std.mem.indexOf(u8, g, "M600") != null);
    try testing.expect(std.mem.indexOf(u8, g, "\nT1\n") == null);
    try testing.expect(std.mem.indexOf(u8, g, "the nozzle waits") == null);
    // Another nozzle for the second filament: T1 and its wait, the
    // standby of nozzle 2, and no pause.
    second.nozzle = 1;
    var pj2 = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{second} });
    defer pj2.deinit();
    var out2: Writer.Allocating = .init(a);
    _ = try pj2.writeGcode(&out2.writer);
    const g2 = out2.written();
    try testing.expect(std.mem.indexOf(u8, g2, "M600") == null);
    try testing.expect(std.mem.indexOf(u8, g2, "\nT1\nM109 T1 S") != null);
    try testing.expect(std.mem.indexOf(u8, g2, "\nM104 T2 S") != null);
}

test "tool changer: the XL and INDX models print two filaments with tool changes" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "prusa-xl-2t", "prusa-xl-5t", "prusa-core-one-indx-4t", "prusa-core-one-indx-8t" }) |id| {
        const g = try towerPlate(gpa, id, false, "PLA", false);
        defer gpa.free(g);
        errdefer std.debug.print("{s}\n", .{id});
        // No pause: a tool change to nozzle 1 for filament 2, and back.
        try testing.expect(std.mem.indexOf(u8, g, "M600") == null);
        var t1: usize = 0;
        var t0: usize = 0;
        var it = std.mem.splitScalar(u8, g, '\n');
        var in_print = false;
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (std.mem.startsWith(u8, line, ";LAYER:")) in_print = true;
            if (!in_print) continue;
            if (std.mem.eql(u8, line, "T1") or std.mem.startsWith(u8, line, "T1 ")) t1 += 1;
            if (std.mem.eql(u8, line, "T0") or std.mem.startsWith(u8, line, "T0 ")) t0 += 1;
        }
        try testing.expect(t1 >= 2 and t0 >= 2);
        try testing.expect(std.mem.indexOf(u8, g, "; filament change") != null);
    }
}

test "plate job: the waste of a print with a tower: the tower lines and the change time" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 40, 20, 3);
    var m = try b.finish();
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.filament_change = .tool;
    s.project.flush_into_hidden = false;
    var red = s.filament;
    red.color = "#e03030";
    const ov = [_]settings_mod.Override{.{ .z_min = 2, .z_max = 10, .name = "project.filament", .value = "2" }};
    const parts = [_]PartInput{.{ .mesh = &m, .part = 0 }};
    var pj = try PlateJob.init(gpa, s, &parts, .{ .filaments = &.{red}, .overrides = &ov });
    defer pj.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try pj.writeGcode(&out.writer);
    try testing.expectEqual(@as(u32, 1), st.changes);
    // A tool change with no change G-code flushes into the tower: no
    // chute, and the tower lines hold the flush.
    try testing.expectEqual(@as(f64, 0), st.chute_mm);
    try testing.expect(st.tower_mm >= st.flush_mm - 1e-6);
    try testing.expect(st.tower_mm < st.filament_mm);
    try testing.expectApproxEqAbs(s.machine.change_time, st.change_s, 1e-9);
}

/// The lines of the prime tower in a G-code, layer by layer: each line
/// with its ends, and true for a line of a prime (after a change, up to
/// its wipe).
pub const TowerLine = struct { layer: usize, a: [2]f64, b: [2]f64, prime: bool };

pub fn towerLinesOf(gpa: Allocator, g: []const u8) !std.ArrayList(TowerLine) {
    var out: std.ArrayList(TowerLine) = .empty;
    errdefer out.deinit(gpa);
    var layer: usize = 0;
    var pos: [2]f64 = .{ 0, 0 };
    var in_tower = false;
    var after_change = false;
    var prime = false;
    var it = std.mem.splitScalar(u8, g, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) {
            layer = try std.fmt.parseInt(usize, line[7..], 10);
            in_tower = false;
        } else if (std.mem.startsWith(u8, line, "; filament change")) {
            after_change = true;
            in_tower = false;
        } else if (std.mem.startsWith(u8, line, ";TYPE:")) {
            in_tower = std.mem.eql(u8, line[6..], "PRIME-TOWER");
            prime = in_tower and after_change;
            after_change = false;
        } else if (std.mem.eql(u8, line, ";WIPE")) {
            prime = false;
        }
        if (!(std.mem.startsWith(u8, line, "G0 ") or std.mem.startsWith(u8, line, "G1 "))) continue;
        var next = pos;
        var e: f64 = 0;
        var words = std.mem.tokenizeScalar(u8, line[3..], ' ');
        while (words.next()) |word| {
            if (word.len < 2) continue;
            const v = std.fmt.parseFloat(f64, word[1..]) catch continue;
            switch (word[0]) {
                'X' => next[0] = v,
                'Y' => next[1] = v,
                'E' => e = v,
                else => {},
            }
            if (word[0] == ';') break;
        }
        if (in_tower and e > 0 and (next[0] != pos[0] or next[1] != pos[1])) {
            try out.append(gpa, .{ .layer = layer, .a = pos, .b = next, .prime = prime });
        }
        pos = next;
    }
    return out;
}

test "plate job: the rib tower of an X2D: each prime row ends on the wall, and has a solid base" {
    const gpa = testing.allocator;
    const g = try towerPlate(gpa, "bambu-lab-x2d", false, "PLA", false);
    defer gpa.free(g);
    var lines = try towerLinesOf(gpa, g);
    defer lines.deinit(gpa);
    // Half the line width of the X2D (wider on the first layer), and a
    // little for the rounding of the G-code.
    const half_w = 0.25 + 0.02;
    var primes: usize = 0;
    var first_prime: ?usize = null;
    for (lines.items) |l| {
        if (!l.prime or @abs(l.a[1] - l.b[1]) > 1e-6) continue;
        primes += 1;
        if (first_prime == null) first_prime = l.layer;
        // Each end of a row is on a closed loop of the wall of its layer:
        // the end of the row is half a line width from a wall line.
        for ([_][2]f64{ l.a, l.b }) |p| {
            var best: f64 = std.math.inf(f64);
            for (lines.items) |q| {
                if (q.layer != l.layer or q.prime) continue;
                if (@abs(q.a[1] - q.b[1]) < 1e-6 and @abs(q.a[1] - p[1]) < 1e-3) continue;
                best = @min(best, segDist(q.a, q.b, p));
            }
            if (best > half_w) {
                std.debug.print("layer {d}: a row ends at {d:.3},{d:.3}, {d:.3} mm from the wall\n", .{ l.layer, p[0], p[1], best });
                return error.TestUnexpectedResult;
            }
        }
        // The layer below has a solid line at the y of the row (a row of
        // a prime or of the solid base) across it.
        // The first layer of the tower is solid, with wider lines: its
        // rows have other places, and its inner loop is under the first
        // rows of the layer above it.
        if (l.layer <= first_prime.? + 1) continue;
        var below = false;
        for (lines.items) |q| {
            if (q.layer + 1 != l.layer or @abs(q.a[1] - q.b[1]) > 1e-6) continue;
            if (@abs(q.a[1] - l.a[1]) > half_w) continue;
            if (@min(q.a[0], q.b[0]) <= @min(l.a[0], l.b[0]) + 0.05 and @max(q.a[0], q.b[0]) >= @max(l.a[0], l.b[0]) - 0.05) below = true;
        }
        if (!below) {
            std.debug.print("layer {d}: no solid base under the row at y {d:.3}\n", .{ l.layer, l.a[1] });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(primes > 50);
}

/// The distance from p to the segment a-b.
fn segDist(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const d: [2]f64 = .{ b[0] - a[0], b[1] - a[1] };
    const len2 = d[0] * d[0] + d[1] * d[1];
    const f = if (len2 > 0) std.math.clamp(((p[0] - a[0]) * d[0] + (p[1] - a[1]) * d[1]) / len2, 0, 1) else 0;
    return std.math.hypot(p[0] - a[0] - f * d[0], p[1] - a[1] - f * d[1]);
}
