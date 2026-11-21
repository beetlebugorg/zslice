//! The engine: runs all stages, from a mesh to G-code.
//!
//! 1. Resolve the settings (see `settings.zig`).
//! 2. Place the part: its bottom goes to z = 0. Its X and Y come from the
//!    file, or its center goes to the center of the bed (see
//!    `project.placement` and `placementOffset`).
//! 3. Make the layer table and the face index (see `slicer.zig`).
//! 4. Pass 1: slice the outline of each layer. The layers are independent,
//!    so this runs on all threads.
//! 5. Pass 2: plan the paths of each layer (see `layer.zig`) and write the
//!    G-code (see `gcode.zig`). The skin of a layer needs the outlines of
//!    the layers above and below it, so pass 2 starts after pass 1 ends.
//!    With combined infill, pass 2 first makes the combined area of each
//!    group of layers (see `Job.combinedAreas`).
//! 6. Modifier volumes (`Job.setModifiers`, optional): pass 1 cuts each
//!    volume at the layers of the job, with the same z and the same move
//!    as the part. The plans then give the area of each volume its own
//!    settings (see layer.Modifier). The idea is the infill mesh of
//!    CuraEngine (see docs/references/).
//!
//! A plate of many parts is one job for each part, and the G-code merges
//! their layers by z (see plate_job.zig). It uses step 5 of this file with
//! its own layer plans (see `PlanSource` and `emitAll`).
//!
//! Memory. The engine keeps the outlines of all layers until the end. They
//! are small: a few kilobytes per layer. The layer plans are much larger,
//! so pass 2 works in batches. It plans a batch of layers on all threads,
//! writes their G-code in layer order, then frees them before the next
//! batch. The peak memory is the outlines plus one batch of plans, and not
//! the plans of all layers. The G-code goes to the writer as it is made, so
//! the engine never holds the whole file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom.zig");
const scratch = @import("scratch.zig");
const mesh_mod = @import("mesh.zig");
const slicer = @import("slicer.zig");
const settings_mod = @import("settings.zig");
const layer_mod = @import("layer.zig");
const gcode = @import("gcode.zig");
const stream_mod = @import("stream.zig");
const parallel = @import("parallel.zig");
const support_mod = @import("support.zig");
const skel_mod = @import("support_skeleton.zig");
const lightning_mod = @import("lightning.zig");
const islands_mod = @import("islands.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const flow = @import("flow.zig");
const paint_split = @import("paint_split.zig");
const Mesh = mesh_mod.Mesh;
const Paths = geom.Paths;
const Settings = settings_mod.Settings;
const LayerPlan = layer_mod.LayerPlan;

pub const Stats = gcode.Stats;

/// Progress and cancel hooks for a slice. All fields are optional.
pub const Monitor = struct {
    ctx: ?*anyopaque = null,
    /// Gets the done fraction, 0 to 1, at most once for each percent. It
    /// can run on any thread of the slice, so it must be thread-safe.
    progress: ?*const fn (ctx: ?*anyopaque, fraction: f64) void = null,
    /// When this becomes true, the slice stops with `error.Canceled`.
    cancel: ?*const std.atomic.Value(bool) = null,

    fn canceled(m: Monitor) bool {
        const c = m.cancel orelse return false;
        return c.load(.acquire);
    }
};

/// Sends progress to a Monitor, at most once for each percent.
const Reporter = struct {
    monitor: Monitor,
    /// The fraction of the slice before this stage, and the size of this
    /// stage, as fractions of the whole slice.
    base: f64,
    span: f64,
    total: usize,
    done: std.atomic.Value(usize) = .init(0),
    last_percent: std.atomic.Value(u32) = .init(0),

    fn step(r: *Reporter, n: usize) void {
        const f = r.monitor.progress orelse return;
        const done = r.done.fetchAdd(n, .monotonic) + n;
        const fraction = r.base + r.span * @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(@max(r.total, 1)));
        const percent: u32 = @intFromFloat(@floor(fraction * 100));
        var last = r.last_percent.load(.monotonic);
        while (percent > last) {
            last = r.last_percent.cmpxchgWeak(last, percent, .monotonic, .monotonic) orelse {
                f(r.monitor.ctx, fraction);
                return;
            };
        }
    }
};

/// Pass 1 is about this fraction of the time of a slice.
/// The part of the progress of a slice that pass 1 reports.
pub const pass1_share = 0.3;

/// True if a part (or the parts of a plate) with these bounds can stand
/// on the bed: its size in X and in Y, with the shrinkage of the filament,
/// is at most the size of the bed. The CLI refuses a wider part, as the
/// engine refuses a part higher than the printer (error.PartTooLarge).
pub fn fitsBed(min: [3]f64, max: [3]f64, s: Settings) bool {
    const k = s.filament.shrinkage_xy;
    const eps = 1e-6;
    return (max[0] - min[0]) * k <= s.machine.bed_size_x + eps and (max[1] - min[1]) * k <= s.machine.bed_size_y + eps;
}

pub const Error = error{
    Canceled,
    InvalidSettings,
    EmptyMesh,
    PartTooLarge,
    /// The part is lower than half of the first layer: no cut plane of a
    /// layer is inside it.
    PartTooThin,
    WriteFailed,
} || Allocator.Error;

/// Slices `mesh` and writes the G-code to `out`. `gpa` must be thread-safe
/// unless `settings.engine.threads` is 1. The function does not change the
/// mesh. It does not flush `out`.
pub fn slice(gpa: Allocator, mesh: *const Mesh, settings: Settings, out: *Writer) Error!Stats {
    var job = try Job.init(gpa, mesh, settings);
    defer job.deinit();
    job.keep_memos = false;
    return job.writeGcode(out);
}

/// The layers and the outlines of a part (steps 3 and 4 of the engine),
/// with the mesh cut from z_base up (in the units of the mesh).
const Sliced = struct {
    layers: []slicer.Layer,
    outlines: []Paths,

    fn deinit(self: *Sliced, gpa: Allocator) void {
        for (self.outlines) |*o| o.deinit(gpa);
        gpa.free(self.outlines);
        gpa.free(self.layers);
    }
};

/// The overrides that change the outlines: the layer height and the XY
/// offsets. Pass 1 reads them (see `slicePart`).
fn isOutlineSetting(name: []const u8) bool {
    for ([_][]const u8{ "project.layer_height", "filament.xy_offset", "filament.hole_xy_offset" }) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn slicePart(gpa: Allocator, mesh: *const Mesh, settings: Settings, outline_overrides: []const settings_mod.Override, height: f64, z_base: f64, b: mesh_mod.Bounds3, dx: f64, dy: f64, threads: usize, monitor: Monitor) Error!Sliced {
        // Step 3. The layer height overrides give the spans of the layer
        // table (see slicer.HeightSpan).
        const f = settings.filament;
        var spans: std.ArrayList(slicer.HeightSpan) = .empty;
        defer spans.deinit(gpa);
        for (outline_overrides) |o| if (std.mem.eql(u8, o.name, "project.layer_height")) {
            var check = settings;
            check.set(o.name, o.value) catch return error.InvalidSettings;
            try spans.append(gpa, .{ .z_min = o.z_min, .z_max = o.z_max, .height = check.project.layer_height });
        };
        const layers = try slicer.layerTableSpans(gpa, height, settings.project.first_layer_height, settings.project.layer_height, spans.items);
        // The part center on the bed: the center of the XY shrinkage scale.
        const center_x = (b.min[0] + b.max[0]) / 2 + dx;
        const center_y = (b.min[1] + b.max[1]) / 2 + dy;
        errdefer gpa.free(layers);
        if (layers.len == 0) return error.PartTooThin;

        const outlines = try gpa.alloc(Paths, layers.len);
        for (outlines) |*o| o.* = .empty;
        errdefer {
            for (outlines) |*o| o.deinit(gpa);
            gpa.free(outlines);
        }
        // The XY offsets of each layer, with the overrides at its z.
        const xy_offsets = try gpa.alloc([2]i64, layers.len);
        defer gpa.free(xy_offsets);
        for (layers, xy_offsets) |l, *xo| {
            const ls = settings_mod.withOverrides(settings, outline_overrides, l.z) catch return error.InvalidSettings;
            xo.* = .{ geom.fromMm(ls.filament.xy_offset), geom.fromMm(ls.filament.hole_xy_offset) };
        }

        // Step 4.
        var index = try slicer.FaceIndex.buildScaled(gpa, mesh, layers, z_base, f.shrinkage_z, threads);
        defer index.deinit(gpa);
        var reporter: Reporter = .{ .monitor = monitor, .base = 0, .span = pass1_share, .total = layers.len };
        const Pass1 = struct {
            gpa: Allocator,
            mesh: *const Mesh,
            index: *const slicer.FaceIndex,
            layers: []const slicer.Layer,
            outlines: []Paths,
            z_offset: f64,
            dx: i64,
            dy: i64,
            tolerance: i64,
            gap: i64,
            reporter: *Reporter,
            z_scale: f64,
            xy_scale: f64,
            center_x: f64,
            center_y: f64,
            /// The XY offset and the hole offset of each layer.
            xy_offsets: []const [2]i64,
            first_offset: i64,

            fn run(c: *const @This(), i: usize) anyerror!void {
                if (c.reporter.monitor.canceled()) return error.Canceled;
                defer c.reporter.step(1);
                var o = try slicer.sliceAt(c.gpa, c.mesh, c.index.get(i), c.layers[i].sliceZ() / c.z_scale + c.z_offset, c.tolerance, c.gap);
                for (o.points.items) |*p| {
                    p.x += c.dx;
                    p.y += c.dy;
                }
                // Shrinkage: scale about the part center.
                if (c.xy_scale != 1) {
                    const cx = geom.fromMm(c.center_x);
                    const cy = geom.fromMm(c.center_y);
                    for (o.points.items) |*p| {
                        p.x = cx + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(p.x - cx)) * c.xy_scale)));
                        p.y = cy + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(p.y - cy)) * c.xy_scale)));
                    }
                }
                // XY offsets.
                const xy = c.xy_offsets[i][0] + (if (i == 0) c.first_offset else 0);
                const hole = c.xy_offsets[i][1];
                if (xy != 0 or hole != 0) {
                    const moved = try compensate(c.gpa, o, xy, hole);
                    o.deinit(c.gpa);
                    o = moved;
                }
                c.outlines[i] = o;
            }
        };
        const ctx: Pass1 = .{
            .gpa = gpa,
            .mesh = mesh,
            .index = &index,
            .layers = layers,
            .outlines = outlines,
            .z_offset = z_base,
            .dx = geom.fromMm(dx),
            .dy = geom.fromMm(dy),
            .tolerance = geom.fromMm(settings.engine.resolution),
            .gap = geom.fromMm(settings.engine.gap_closing),
            .reporter = &reporter,
            .z_scale = f.shrinkage_z,
            .xy_scale = f.shrinkage_xy,
            .center_x = center_x,
            .center_y = center_y,
            .xy_offsets = xy_offsets,
            .first_offset = geom.fromMm(settings.project.first_layer_xy_offset),
        };
        parallel.forEach(threads, layers.len, &ctx, Pass1.run) catch |e| return @as(Error, @errorCast(e));
        if (monitor.canceled()) return error.Canceled;
        return .{ .layers = layers, .outlines = outlines };
}

/// A slice job after pass 1: the resolved settings, the layer table, and
/// the outline of each layer. Use it to get the plan of one layer (for
/// example, for a preview) or to write the G-code. Do not move a Job after
/// `init`.
pub const Job = struct {
    gpa: Allocator,
    resolved: settings_mod.Resolved,
    monitor: Monitor = .{},
    threads: usize,
    layers: []slicer.Layer,
    outlines: []Paths,
    /// The support areas of each layer, or an empty slice.
    support: []support_mod.SupportLayer = &.{},
    /// The work of the support, for the next job with the same outlines
    /// (see support.Cache).
    support_cache: support_mod.Cache = .{},
    /// The trees of the tree support of the job: the trees of the user
    /// (Options.trees), or the trees of the plan. Empty with no trees.
    trees: skel_mod.Skeleton = .{},
    /// The key of the layers of the job (see `layersKey`).
    layers_key: u64 = 0,
    /// The job did not use the trees of the user: they were made for other
    /// layers (Options.trees_layers is not `layers_key`).
    trees_dropped: bool = false,
    /// The shapes that start in the air (see islands.zig).
    islands: []islands_mod.Island = &.{},
    /// A hash of the inputs of the island search besides the outlines (the
    /// support areas and the grow distance), or 0 before the search. A new
    /// job with the same outlines and the same key takes the islands of
    /// the old job: a change of the infill does not search again.
    islands_key: u64 = 0,
    /// The grow of the islands of this job (see islands.find).
    islands_grow: i64 = -1,
    /// A hash of the support of each layer (body and interface), for the
    /// islands of the next job (see islands.findSome).
    support_keys: []u64 = &.{},
    /// The intersections of runs of outlines, for the bands under the tops
    /// (see layer.BandTable). A job with the same outlines keeps it.
    bands: layer_mod.BandTable = .{},
    /// The top and bottom surfaces of each layer (see layer.surfaces), or
    /// empty slices if no layer has skin.
    tops: []Paths = &.{},
    bottoms: []Paths = &.{},
    /// The lightning branches of each layer (see lightning.zig), or an
    /// empty slice if no layer has lightning infill.
    lightning: []Paths = &.{},
    /// The memo of each layer (see layer.Memo): the results of the slow
    /// steps of a plan. A plan adds to it. `initReuse` takes the memos of
    /// an older job.
    memos: []layer_mod.Memo = &.{},
    /// A hash of all inputs of the outlines (see `outlineKey`). Two jobs of
    /// the same mesh with the same key have the same outlines.
    outline_key: u64 = 0,
    /// The generation of the job: one more than the job that it took its
    /// memos from (see layer.Memo).
    gen: u32 = 0,
    /// False for a job that slices once (the command line tool, `slice`):
    /// then the memo of each layer goes as soon as its plan is ready, and
    /// the memory does not grow with the layer count.
    keep_memos: bool = true,
    /// The settings of the layers with overrides (see layer.Context).
    layer_set: []u16 = &.{},
    layer_resolved: []settings_mod.Resolved = &.{},
    /// The infill group of each layer (see layer.InfillGroup), or an empty
    /// slice if no layer combines its infill.
    groups: []layer_mod.InfillGroup = &.{},
    /// Where pass 1 cut the mesh: the z of the mesh at the bottom of the
    /// first layer, and the move of the mesh in X and Y (mm). The
    /// modifier volumes are cut the same way.
    z_base: f64 = 0,
    dx: f64 = 0,
    dy: f64 = 0,
    /// The center of the XY shrinkage scale (mm).
    center: [2]f64 = .{ 0, 0 },
    /// The modifier volumes (see `setModifiers` and layer.Modifier).
    modifiers: []layer_mod.Modifier = &.{},
    /// The memory of the modifiers: their outlines, their settings, and
    /// the strings of their settings.
    mod_arena: ?std.heap.ArenaAllocator = null,
    /// False: the plans have no skirt and no brim (see layer.Context.rings).
    rings: bool = true,

    /// The options of `initOpts`.
    pub const Options = struct {
        /// Overrides for z ranges (see settings.Override). Only
        /// settings.layer_settings can have overrides. The strings must
        /// live as long as the job.
        overrides: []const settings_mod.Override = &.{},
        /// The support marks of the user (see support.Mark).
        marks: []const support_mod.Mark = &.{},
        monitor: Monitor = .{},
        /// An older job of the same mesh, for its work (see `initReuse`).
        old: ?*Job = null,
        /// The move of the mesh in X and Y (mm), or null: then the
        /// placement setting gives it (see `placementOffset`). A plate of
        /// many parts moves all parts by the same offset.
        offset: ?[2]f64 = null,
        /// See `rings`.
        rings: bool = true,
        /// The trees of the user (the support editor), in the frame of the
        /// job, in place of the plan of tree support, or null. They count
        /// only if `trees_layers` is the key of the layers of the job (see
        /// `layersKey`); else the job plans the trees, and sets
        /// `trees_dropped`.
        trees: ?*const skel_mod.Skeleton = null,
        trees_layers: u64 = 0,
        /// False: no search for the islands (`islands` stays empty). The
        /// G-code does not use them.
        islands: bool = true,
        /// One filament of a painted part (see paint_split.zig), or null:
        /// the outline of each layer is the region of that filament.
        paint: ?PaintClip = null,
    };

    /// The gap (mm) between the walls of a part and the root of a painted
    /// feature in it (see paint_split.Split.anchor): the walls stay whole.
    pub const anchor_margin = 0.1;

    pub const PaintClip = struct {
        split: *paint_split.Split,
        /// The index of the filament in `split.states`; 0 is the filament
        /// of the part, and its job has the support and the islands.
        index: usize,
    };

    /// Steps 1 to 4.
    pub fn init(gpa: Allocator, mesh: *const Mesh, settings: Settings) Error!Job {
        return initWith(gpa, mesh, settings, .{});
    }

    /// `init`, with progress and cancel hooks. `writeGcode` uses the same
    /// hooks.
    pub fn initWith(gpa: Allocator, mesh: *const Mesh, settings: Settings, monitor: Monitor) Error!Job {
        return initFull(gpa, mesh, settings, &.{}, monitor);
    }

    /// `initWith`, with overrides for z ranges (see settings.Override).
    /// Only settings.layer_settings can have overrides. The strings of the
    /// overrides must live as long as the job.
    pub fn initFull(gpa: Allocator, mesh: *const Mesh, settings: Settings, overrides: []const settings_mod.Override, monitor: Monitor) Error!Job {
        return initReuse(gpa, mesh, settings, overrides, &.{}, monitor, null);
    }

    /// `initFull`, and the job uses the work of `old`, a job of the same
    /// mesh (the caller knows). If the outlines are the same (the same
    /// `outline_key`), the job takes the outlines, the surfaces, and the
    /// memos of `old`, and skips pass 1. A change of a setting that does
    /// not change the outlines (walls, skin, infill, speeds) then slices
    /// again in much less time. `old` stays valid, but it has no outlines
    /// after this call. Free it after this call.
    /// `marks`: the support marks of the user (see support.Mark).
    pub fn initReuse(gpa: Allocator, mesh: *const Mesh, settings: Settings, overrides: []const settings_mod.Override, marks: []const support_mod.Mark, monitor: Monitor, old: ?*Job) Error!Job {
        return initOpts(gpa, mesh, settings, .{ .overrides = overrides, .marks = marks, .monitor = monitor, .old = old });
    }

    /// `initReuse`, with all options (see `Options`).
    pub fn initOpts(gpa: Allocator, mesh: *const Mesh, settings: Settings, opts: Options) Error!Job {
        const overrides = opts.overrides;
        for (overrides) |o| if (!settings_mod.isLayerSetting(o.name)) return error.InvalidSettings;
        var outline_overrides: std.ArrayList(settings_mod.Override) = .empty;
        defer outline_overrides.deinit(gpa);
        for (overrides) |o| if (isOutlineSetting(o.name)) try outline_overrides.append(gpa, o);
        var job = try initBase(gpa, mesh, settings, outline_overrides.items, opts.marks, opts.monitor, opts.old, opts.offset, opts.trees, opts.trees_layers, opts.islands);
        errdefer job.deinit();
        job.rings = opts.rings;
        if (overrides.len > 0) try job.resolveLayers(settings, overrides);
        // A layer can have another height than the layer height of its
        // settings (a span can move its top out of the range), so each
        // height must fit the line width of its layer.
        for (job.layers[1..], 1..) |l, i| if (l.height > job.resolvedAt(i).line_width + 1e-9) return error.InvalidSettings;
        if (job.tops.len == 0) try job.makeSurfaces();
        if (opts.paint) |pc| try job.clipToPaint(pc);
        job.bands.extend(gpa, job.outlines, layer_mod.bandLevels(job.planContext()), job.threads, job.monitor.cancel) catch |e| return @as(Error, @errorCast(e));
        try job.makeLightning();
        job.groups = try layer_mod.groups(gpa, job.planContext());
        // The work memory goes back to the operating system (see
        // scratch.zig).
        scratch.trim();
        return job;
    }

    /// Makes the outlines, the tops, and the bottoms of each layer the
    /// region of one filament of a painted part (see paint_split.zig). The
    /// first job of the part finds the regions of all filaments from its
    /// full outlines; the other jobs of the part use them. The surfaces
    /// come from the full outlines, so a region gets top skin only where
    /// the part has a top.
    fn clipToPaint(self: *Job, pc: PaintClip) Error!void {
        const gpa = self.gpa;
        const n = self.layers.len;
        const s = self.resolved.settings;
        if (!pc.split.done) {
            const cut = try gpa.alloc(f64, n);
            defer gpa.free(cut);
            for (self.layers, cut) |l, *z| z.* = l.sliceZ();
            const frame: paint_split.Frame = .{ .z_base = self.z_base, .z_scale = s.filament.shrinkage_z, .dx = self.dx, .dy = self.dy, .xy_scale = s.filament.shrinkage_xy, .center = self.center };
            // The root of a painted feature stays inside the walls of the
            // part, and a small margin (see paint_split.Split.anchor).
            const w = self.resolved.line_width;
            const roots: paint_split.Anchor = .{
                .depth = s.project.paint_anchor_depth,
                .inset = @as(f64, @floatFromInt(s.project.wall_count)) * w + anchor_margin,
                .shape = switch (s.project.paint_anchor_shape) {
                    .footprint => .footprint,
                    .core => .core,
                },
            };
            // The narrowest line of a label (see paint_split.Split.labelLayer):
            // the narrowest Arachne line (see layer.arachneParams).
            const p = s.project;
            const min_wall = if (p.min_wall_line_width > 0) p.min_wall_line_width else 0.85 * s.machine.nozzle_diameter;
            const min_bead = if (p.min_bead_width > 0) p.min_bead_width else min_wall;
            pc.split.cancel = self.monitor.cancel;
            pc.split.compute(self.outlines, cut, frame, w, s.project.top_thickness, s.project.bottom_thickness, self.threads, roots, min_bead) catch |e| return @as(Error, @errorCast(e));
        }
        if (pc.split.layers != n) return error.InvalidSettings;
        for (0..n) |i| {
            const region = pc.split.region(i, pc.index);
            const o = try region.clone(gpa);
            self.outlines[i].deinit(gpa);
            self.outlines[i] = o;
            if (i < self.tops.len and !self.tops[i].isEmpty()) {
                const t = try clip.intersect(gpa, self.tops[i], region.*);
                self.tops[i].deinit(gpa);
                self.tops[i] = t;
            }
            if (i < self.bottoms.len and !self.bottoms[i].isEmpty()) {
                const b = try clip.intersect(gpa, self.bottoms[i], region.*);
                self.bottoms[i].deinit(gpa);
                self.bottoms[i] = b;
            }
        }
        if (pc.index != 0) {
            // The support and the islands are of the whole part: the job
            // of its own filament prints them.
            for (self.support) |*l| {
                l.deinit(gpa);
                l.* = .{};
            }
            gpa.free(self.islands);
            self.islands = &.{};
        }
        // The outlines are not the outlines of the mesh: no later job
        // takes them (see `initReuse`).
        self.outline_key ^= 0x9a1e7 +% pc.index;
    }

    /// The top and bottom surfaces of all layers, on all threads. Layer pair
    /// (j, j + 1) gives the top surface of j and the bottom surface of
    /// j + 1.
    fn makeSurfaces(self: *Job) Error!void {
        var skin = self.resolved.top_layers > 0 or self.resolved.bottom_layers > 0;
        for (self.layer_resolved) |r| skin = skin or r.top_layers > 0 or r.bottom_layers > 0;
        if (!skin) return;
        const gpa = self.gpa;
        const n = self.layers.len;
        self.tops = try gpa.alloc(Paths, n);
        @memset(self.tops, .empty);
        self.bottoms = try gpa.alloc(Paths, n);
        @memset(self.bottoms, .empty);
        self.tops[n - 1] = try self.outlines[n - 1].clone(gpa);
        self.bottoms[0] = try self.outlines[0].clone(gpa);
        const Pass = struct {
            job: *Job,
            fn run(c: *const @This(), j: usize) anyerror!void {
                if (c.job.monitor.canceled()) return error.Canceled;
                const pair = try layer_mod.surfacePair(c.job.gpa, c.job.outlines, j);
                c.job.tops[j] = pair[0];
                c.job.bottoms[j + 1] = pair[1];
            }
        };
        const c: Pass = .{ .job = self };
        parallel.forEach(self.threads, n - 1, &c, Pass.run) catch |e| return @as(Error, @errorCast(e));
    }

    /// The lightning branches of all layers (see lightning.zig). The
    /// infill area of each layer comes first, on all threads, with the
    /// memo of the layer (the plan uses the same results again). Then the
    /// trees grow from the top layer down.
    fn makeLightning(self: *Job) Error!void {
        var any = self.resolved.settings.project.infill_pattern == .lightning;
        for (self.layer_resolved) |r| any = any or r.settings.project.infill_pattern == .lightning;
        if (!any) return;
        const gpa = self.gpa;
        const n = self.layers.len;
        const ins = try gpa.alloc(lightning_mod.Layer, n);
        defer gpa.free(ins);
        @memset(ins, .{});
        const Pass = struct {
            job: *Job,
            ins: []lightning_mod.Layer,
            fn run(c: *const @This(), i: usize) anyerror!void {
                const job = c.job;
                var ctx = job.planContext();
                ctx.cancel = job.monitor.cancel;
                const region = try layer_mod.lightningRegion(job.gpa, ctx, i, &job.memos[i]) orelse return error.Canceled;
                const r = job.resolvedAt(i);
                const p = r.settings.project;
                const width_mm = if (i == 0) r.first_layer_line_width else r.line_width;
                c.ins[i] = .{
                    .region = region,
                    .reach = if (p.infill_density > 0) geom.fromMm(width_mm / p.infill_density / 2) else 0,
                    .width = geom.fromMm(width_mm),
                    .height = geom.fromMm(job.layers[i].height),
                };
            }
        };
        const c: Pass = .{ .job = self, .ins = ins };
        parallel.forEach(self.threads, n, &c, Pass.run) catch |e| return @as(Error, @errorCast(e));
        const p = self.resolved.settings.project;
        const tan_angle = @tan(p.lightning_angle * std.math.pi / 180.0);
        self.lightning = lightning_mod.grow(gpa, self.threads, ins, tan_angle, self.monitor.cancel) catch |e| return @as(Error, @errorCast(e));
    }

    /// The settings of each layer: one Resolved for each set of overrides.
    fn resolveLayers(self: *Job, settings: Settings, overrides: []const settings_mod.Override) Error!void {
        const gpa = self.gpa;
        self.layer_set = try gpa.alloc(u16, self.layers.len);
        @memset(self.layer_set, 0);
        var sets: std.ArrayList(u64) = .empty;
        defer sets.deinit(gpa);
        var list: std.ArrayList(settings_mod.Resolved) = .empty;
        errdefer list.deinit(gpa);
        for (self.layers, 0..) |layer, i| {
            // A bit for each override that covers the layer.
            var mask: u64 = 0;
            for (overrides, 0..) |o, k| if (k < 64 and o.covers(layer.z)) {
                mask |= @as(u64, 1) << @intCast(k);
            };
            if (mask == 0) continue;
            const found = std.mem.indexOfScalar(u64, sets.items, mask);
            if (found) |f| {
                self.layer_set[i] = @intCast(f + 1);
                continue;
            }
            const s = settings_mod.withOverrides(settings, overrides, layer.z) catch return error.InvalidSettings;
            const r = s.resolve() catch return error.InvalidSettings;
            try sets.append(gpa, mask);
            try list.append(gpa, r);
            self.layer_set[i] = @intCast(list.items.len);
        }
        self.layer_resolved = try list.toOwnedSlice(gpa);
    }

    fn initBase(gpa: Allocator, mesh: *const Mesh, settings: Settings, outline_overrides: []const settings_mod.Override, marks: []const support_mod.Mark, monitor: Monitor, old: ?*Job, offset: ?[2]f64, trees: ?*const skel_mod.Skeleton, trees_layers: u64, find_islands: bool) Error!Job {
        // Step 1.
        const r = settings.resolve() catch return error.InvalidSettings;
        const threads = parallel.threadCount(settings.engine.threads);

        // Step 2.
        if (mesh.faces.items.len == 0) return error.EmptyMesh;
        const b = mesh.bounds();
        const f = settings.filament;
        const height = (b.max[2] - b.min[2]) * f.shrinkage_z;
        if (!(height > 0)) return error.EmptyMesh;
        const m = settings.machine;
        if (height > m.max_height) return error.PartTooLarge;
        // The skirt and the brim go around the part, so they must also be
        // on the bed for the file position.
        const pr = settings.project;
        const margin = ringMargin(&r);
        const dx, const dy = offset orelse placementOffset(pr.placement, b.min, b.max, m.bed_size_x, m.bed_size_y, margin);

        // The outlines depend only on the mesh and these values. If an
        // older job has the same key, its outlines are good.
        const key = outlineKey(settings, outline_overrides, height, b, dx, dy);
        var job: Job = .{
            .gpa = gpa,
            .resolved = r,
            .monitor = monitor,
            .threads = threads,
            .layers = &.{},
            .outlines = &.{},
            .outline_key = key,
        };
        errdefer job.deinit();

        job.dx = dx;
        job.dy = dy;
        job.center = .{ (b.min[0] + b.max[0]) / 2 + dx, (b.min[1] + b.max[1]) / 2 + dy };
        job.z_base = b.min[2];
        if (old) |o| if (o.outline_key == key and o.outlines.len > 0) {
            // The same outlines: take them, with the surfaces and the memos.
            job.z_base = o.z_base;
            job.layers = o.layers;
            o.layers = &.{};
            job.outlines = o.outlines;
            o.outlines = &.{};
            job.tops = o.tops;
            o.tops = &.{};
            job.bottoms = o.bottoms;
            o.bottoms = &.{};
            job.bands = o.bands;
            o.bands = .{};
            job.gen = o.gen +% 1;
            job.memos = try gpa.alloc(layer_mod.Memo, job.layers.len);
            for (job.memos) |*mm| mm.* = .init(gpa);
            // Keep the results that the old job or the job before it used.
            const min_gen = o.gen -| 1;
            for (job.memos, o.memos) |*mine, *theirs| {
                const kept = try theirs.keep(gpa, min_gen);
                mine.deinit();
                mine.* = kept;
            }
        };

        if (job.outlines.len == 0) {
            // Steps 3 and 4. If the first layers have no material (a tiny
            // tip of the mesh at the bottom, thinner than the resolution),
            // the print would start in the air: slice again from the first
            // layer with material, as the part sits on the bed there.
            var z_base = b.min[2];
            var sliced = try slicePart(gpa, mesh, settings, outline_overrides, height, z_base, b, dx, dy, threads, monitor);
            var empty: usize = 0;
            while (empty < sliced.outlines.len and sliced.outlines[empty].isEmpty()) empty += 1;
            if (empty == sliced.outlines.len) {
                sliced.deinit(gpa);
                return error.EmptyMesh;
            }
            if (empty > 0) {
                // The first cut plane with material becomes the cut plane of
                // the first layer.
                const lift = sliced.layers[empty].sliceZ() - settings.project.first_layer_height / 2;
                sliced.deinit(gpa);
                z_base = b.min[2] + lift / f.shrinkage_z;
                sliced = try slicePart(gpa, mesh, settings, outline_overrides, height - lift, z_base, b, dx, dy, threads, monitor);
            }
            job.z_base = z_base;
            job.layers = sliced.layers;
            job.outlines = sliced.outlines;
            job.memos = try gpa.alloc(layer_mod.Memo, job.layers.len);
            for (job.memos) |*mm| mm.* = .init(gpa);
        }

        // The support areas need the outlines of all layers. A job with the
        // same outlines gives its support work.
        if (old) |o| if (o.support_cache.outline_key == key) {
            job.support_cache = o.support_cache;
            o.support_cache = .{};
        };
        job.support_cache.outline_key = key;
        job.layers_key = layersKey(job.layers);
        var user = trees;
        if (user != null and trees_layers != job.layers_key) {
            user = null;
            job.trees_dropped = true;
        }
        job.support = support_mod.computeTrees(gpa, job.outlines, job.layers, &r, threads, marks, &job.support_cache, .{ .user = user, .out = &job.trees }) catch |e| return @as(Error, @errorCast(e));
        if (!find_islands) return job;
        const grow = @divTrunc(geom.fromMm(r.line_width), 4);
        job.islands_key = islandsKey(job.support, grow);
        if (old) |o| if (o.outline_key == key and o.islands_key == job.islands_key and o.islands_key != 0) {
            job.islands = o.islands;
            o.islands = &.{};
            job.support_keys = o.support_keys;
            o.support_keys = &.{};
            job.islands_grow = o.islands_grow;
            return job;
        };
        job.support_keys = gpa.alloc(u64, job.support.len) catch return error.OutOfMemory;
        for (job.support, job.support_keys) |l, *k| k.* = layerSupportKey(l);
        // The same outlines and the same grow: only the layers over a
        // layer whose support changed find their islands again.
        if (old) |o| if (o.outline_key == key and o.islands_grow == grow and o.support_keys.len == job.support_keys.len and job.outlines.len == job.support_keys.len) {
            const redo = gpa.alloc(bool, job.outlines.len) catch return error.OutOfMemory;
            defer gpa.free(redo);
            redo[0] = false;
            for (1..redo.len) |i| redo[i] = o.support_keys[i - 1] != job.support_keys[i - 1];
            job.islands = islands_mod.findSome(gpa, job.outlines, job.support, grow, 0.5, threads, redo, o.islands) catch |e| return @as(Error, @errorCast(e));
            job.islands_grow = grow;
            return job;
        };
        job.islands = islands_mod.find(gpa, job.outlines, job.support, grow, 0.5, threads) catch |e| return @as(Error, @errorCast(e));
        job.islands_grow = grow;
        return job;
    }

    /// A key of the layers: the top z and the height of each layer. The
    /// trees of the user (Options.trees) fit only the layers with the
    /// key that they were made for. Never 0.
    pub fn layersKey(layers: []const slicer.Layer) u64 {
        var h = std.hash.Wyhash.init(0x1a7e);
        h.update(std.mem.asBytes(&layers.len));
        for (layers) |l| h.update(std.mem.asBytes(&[2]f64{ l.z, l.height }));
        return h.final() | 1;
    }

    /// The key of the island search besides the outlines: a hash of the
    /// support areas and of the grow distance. Never 0.
    fn layerSupportKey(l: support_mod.SupportLayer) u64 {
        var h = std.hash.Wyhash.init(0x5e9);
        for ([_]geom.Paths{ l.body, l.interface }) |p| {
            h.update(std.mem.sliceAsBytes(p.points.items));
            h.update(std.mem.sliceAsBytes(p.ends.items));
        }
        return h.final();
    }

    fn islandsKey(support: []const support_mod.SupportLayer, grow: i64) u64 {
        var h = std.hash.Wyhash.init(0x15_1a_4d);
        h.update(std.mem.asBytes(&grow));
        h.update(std.mem.asBytes(&support.len));
        for (support) |l| for ([_]geom.Paths{ l.body, l.interface }) |p| {
            h.update(std.mem.sliceAsBytes(p.points.items));
            h.update(std.mem.sliceAsBytes(p.ends.items));
        };
        return h.final() | 1;
    }

    /// Moves the memos of `old` to this job if the outlines are the same.
    /// Returns true if it moved them. `initReuse` does more: it also skips
    /// pass 1.
    pub fn takeRegions(self: *Job, old: *Job) bool {
        if (old.outline_key != self.outline_key or old.memos.len != self.memos.len) return false;
        self.gen = old.gen +% 1;
        for (self.memos, old.memos) |*mine, *theirs| {
            mine.deinit();
            mine.* = theirs.*;
            theirs.* = .init(self.gpa);
        }
        return true;
    }

    /// Frees the memos of all layers (see `memos`). The job stays good: a
    /// later plan or job makes the slow steps again. For a job that waits
    /// (the slice of a plate that is not on view).
    pub fn dropMemos(self: *Job) void {
        for (0..self.memos.len) |i| dropMemo(self.gpa, self.memos, i);
    }

    /// `dropMemos`, but the memos go to `out` (in the gpa of the job), and
    /// the caller frees them. On an error, the memos that did not go stay.
    pub fn takeMemos(self: *Job, out: *std.ArrayList(layer_mod.Memo)) Allocator.Error!void {
        try out.ensureUnusedCapacity(self.gpa, self.memos.len);
        for (self.memos) |*m| {
            out.appendAssumeCapacity(m.*);
            m.* = .init(self.gpa);
        }
    }

    pub fn deinit(self: *Job) void {
        self.dropModifiers();
        self.gpa.free(self.groups);
        self.gpa.free(self.layer_set);
        self.gpa.free(self.layer_resolved);
        for (self.memos) |*mm| mm.deinit();
        self.gpa.free(self.memos);
        for (self.lightning) |*l| l.deinit(self.gpa);
        self.gpa.free(self.lightning);
        for (self.tops) |*t| t.deinit(self.gpa);
        self.gpa.free(self.tops);
        for (self.bottoms) |*b| b.deinit(self.gpa);
        self.bands.deinit(self.gpa);
        self.gpa.free(self.bottoms);
        if (self.support.len > 0) support_mod.deinitAll(self.gpa, self.support);
        self.support_cache.deinit(self.gpa);
        self.trees.deinit(self.gpa);
        self.gpa.free(self.islands);
        self.gpa.free(self.support_keys);
        for (self.outlines) |*o| o.deinit(self.gpa);
        self.gpa.free(self.outlines);
        self.gpa.free(self.layers);
    }

    pub fn layerCount(self: *const Job) usize {
        return self.layers.len;
    }

    pub fn planContext(self: *const Job) layer_mod.Context {
        return .{
            .resolved = &self.resolved,
            .layers = self.layers,
            .outlines = self.outlines,
            .infill_origin = .{ geom.fromMm(self.center[0]), geom.fromMm(self.center[1]) },
            .support = self.support,
            .cache = self.memos,
            .gen = self.gen,
            .tops = self.tops,
            .bottoms = self.bottoms,
            .layer_set = self.layer_set,
            .layer_resolved = self.layer_resolved,
            .lightning = self.lightning,
            .groups = self.groups,
            .bands = &self.bands,
            .modifiers = self.modifiers,
            .rings = self.rings,
        };
    }

    /// A modifier volume for `setModifiers`.
    pub const ModifierInput = struct {
        /// The volume, in the coordinates of the mesh of the job.
        mesh: *const Mesh,
        /// The settings of the volume. The job keeps a copy.
        changes: []const settings_mod.Change,
        /// Where two volumes overlap, the one with the higher order wins.
        order: i32 = 0,
        name: []const u8 = "",
    };

    fn dropModifiers(self: *Job) void {
        if (self.mod_arena) |*ar| ar.deinit();
        self.mod_arena = null;
        self.modifiers = &.{};
    }

    /// Sets the modifier volumes of the job (see layer.Modifier), in place
    /// of the ones before. Pass 1 cuts each volume at the layers of the
    /// job. The settings of a volume apply over the settings of each
    /// layer. Call it before the plans.
    pub fn setModifiers(self: *Job, mods: []const ModifierInput) Error!void {
        self.dropModifiers();
        if (mods.len == 0) return;
        self.mod_arena = .init(self.gpa);
        const a = self.mod_arena.?.allocator();
        // The winner of an overlap first: the higher order, then the
        // earlier volume.
        const order = try a.alloc(usize, mods.len);
        for (order, 0..) |*o, k| o.* = k;
        std.mem.sort(usize, order, mods, struct {
            fn lt(ms: []const ModifierInput, x: usize, y: usize) bool {
                if (ms[x].order != ms[y].order) return ms[x].order > ms[y].order;
                return x < y;
            }
        }.lt);
        const list = try a.alloc(layer_mod.Modifier, mods.len);
        for (order, list) |k, *m| {
            const in = mods[k];
            const changes = try a.alloc(settings_mod.Change, in.changes.len);
            for (in.changes, changes) |c, *d| d.* = .{ .name = try a.dupe(u8, c.name), .value = try a.dupe(u8, c.value) };
            const res = try a.alloc(settings_mod.Resolved, 1 + self.layer_resolved.len);
            for (res, 0..) |*r, set| {
                var st = if (set == 0) self.resolved.settings else self.layer_resolved[set - 1].settings;
                for (changes) |c| st.set(c.name, c.value) catch return error.InvalidSettings;
                r.* = st.resolve() catch return error.InvalidSettings;
            }
            m.* = .{ .outlines = try self.sliceExtra(a, in.mesh), .resolved = res, .name = try a.dupe(u8, in.name) };
        }
        self.modifiers = list;
    }

    /// The outline of `mesh` on each layer of the job, cut as pass 1 cuts
    /// the mesh of the job (the same z, move, and shrinkage, with no XY
    /// offsets). The result goes in `a`.
    fn sliceExtra(self: *const Job, a: Allocator, mesh: *const Mesh) Error![]Paths {
        const n = self.layers.len;
        const out = try a.alloc(Paths, n);
        @memset(out, .empty);
        if (mesh.faces.items.len == 0) return out;
        const s = self.resolved.settings;
        var index = try slicer.FaceIndex.buildScaled(self.gpa, mesh, self.layers, self.z_base, s.filament.shrinkage_z, self.threads);
        defer index.deinit(self.gpa);
        // The outlines go to `tmp` on the threads (gpa is thread-safe, the
        // arena is not), then to the arena.
        const tmp = try self.gpa.alloc(Paths, n);
        defer self.gpa.free(tmp);
        @memset(tmp, .empty);
        defer for (tmp) |*t| t.deinit(self.gpa);
        const Pass = struct {
            job: *const Job,
            mesh: *const Mesh,
            index: *const slicer.FaceIndex,
            out: []Paths,
            fn run(c: *const @This(), i: usize) anyerror!void {
                const job = c.job;
                if (job.monitor.canceled()) return error.Canceled;
                const st = job.resolved.settings;
                const o = try slicer.sliceAt(job.gpa, c.mesh, c.index.get(i), job.layers[i].sliceZ() / st.filament.shrinkage_z + job.z_base, geom.fromMm(st.engine.resolution), geom.fromMm(st.engine.gap_closing));
                const dx = geom.fromMm(job.dx);
                const dy = geom.fromMm(job.dy);
                const xy_scale = st.filament.shrinkage_xy;
                const cx = geom.fromMm(job.center[0]);
                const cy = geom.fromMm(job.center[1]);
                for (o.points.items) |*p| {
                    p.x += dx;
                    p.y += dy;
                    if (xy_scale != 1) {
                        p.x = cx + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(p.x - cx)) * xy_scale)));
                        p.y = cy + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(p.y - cy)) * xy_scale)));
                    }
                }
                c.out[i] = o;
            }
        };
        const c: Pass = .{ .job = self, .mesh = mesh, .index = &index, .out = tmp };
        parallel.forEach(self.threads, n, &c, Pass.run) catch |e| return @as(Error, @errorCast(e));
        for (tmp, out) |t, *o| o.* = try t.clone(a);
        return out;
    }

    /// The settings of layer i, with its overrides.
    pub fn resolvedAt(self: *const Job, i: usize) *const settings_mod.Resolved {
        if (i < self.layer_set.len and self.layer_set[i] > 0) return &self.layer_resolved[self.layer_set[i] - 1];
        return &self.resolved;
    }

    /// The settings of a path on layer i: of modifier volume k - 1 (see
    /// `modifiers`), or of the layer for k = 0.
    pub fn pathResolved(self: *const Job, i: usize, k: usize) *const settings_mod.Resolved {
        if (k == 0 or k > self.modifiers.len) return self.resolvedAt(i);
        const set: usize = if (i < self.layer_set.len) self.layer_set[i] else 0;
        return &self.modifiers[k - 1].resolved[set];
    }

    /// The combined area of each infill group (see layer.combinedArea), at
    /// the index of the last layer of the group, on all threads. Each
    /// group uses the memos of its own layers, so the plans then find the
    /// regions in their memos, and do not make them again. So a job that
    /// slices once (see `keep_memos`) holds the regions of all layers in
    /// the memos until their plans: a few percent more peak memory on the
    /// test parts, for a few percent more time (and not about 70 % more
    /// time to make the regions twice). Empty if no layer combines its
    /// infill. The caller owns the result.
    pub fn combinedAreas(self: *const Job, ctx: layer_mod.Context) Error![]Paths {
        if (self.groups.len == 0) return &.{};
        const gpa = self.gpa;
        const out = try gpa.alloc(Paths, self.groups.len);
        @memset(out, .empty);
        errdefer {
            for (out) |*c| c.deinit(gpa);
            gpa.free(out);
        }
        var lasts: std.ArrayList(u32) = .empty;
        defer lasts.deinit(gpa);
        for (self.groups, 0..) |g, i| if (g.last == i and g.count() > 1) try lasts.append(gpa, g.last);
        const Pass = struct {
            job: *const Job,
            ctx: layer_mod.Context,
            lasts: []const u32,
            out: []Paths,
            fn run(c: *const @This(), k: usize) anyerror!void {
                if (c.job.monitor.canceled()) return error.Canceled;
                const g = c.job.groups[c.lasts[k]];
                const gpa_ = c.job.gpa;
                c.out[g.last] = try layer_mod.combinedArea(gpa_, gpa_, c.ctx, g, null, null) orelse return error.Canceled;
            }
        };
        const c: Pass = .{ .job = self, .ctx = ctx, .lasts = lasts.items, .out = out };
        parallel.forEach(self.threads, lasts.items.len, &c, Pass.run) catch |e| return @as(Error, @errorCast(e));
        return out;
    }

    /// The plan of layer i. Call `deinit` on the result.
    pub fn planLayer(self: *const Job, i: usize) Allocator.Error!LayerPlan {
        return layer_mod.plan(self.gpa, self.planContext(), i);
    }

    /// Gets each layer plan before it is freed, in layer order, on the
    /// thread that writes the G-code. An app uses it to keep the paths of
    /// all layers for a 3D view, with no second planning pass.
    pub const LayerSink = struct {
        ctx: ?*anyopaque,
        /// `paths` has the end time and the bead area of each path of the
        /// plan, from the emitter.
        func: *const fn (ctx: ?*anyopaque, plan: *const LayerPlan, paths: []const gcode.PathInfo) anyerror!void,
    };

    /// Step 5.
    pub fn writeGcode(self: *const Job, out: *Writer) Error!Stats {
        return self.writeGcodeWith(out, null);
    }

    /// `writeGcode`, and each layer plan also goes to `sink`.
    pub fn writeGcodeWith(self: *const Job, out: *Writer, sink: ?LayerSink) Error!Stats {
        const gpa = self.gpa;
        var plan_ctx = self.planContext();
        // A cancel stops a layer plan early.
        plan_ctx.cancel = self.monitor.cancel;
        const combined = try self.combinedAreas(plan_ctx);
        defer {
            for (combined) |*c| c.deinit(gpa);
            gpa.free(combined);
        }
        plan_ctx.combined = combined;
        const Src = struct {
            fn plan(ctx: *const anyopaque, g: Allocator, i: usize) Allocator.Error!LayerPlan {
                const c: *const layer_mod.Context = @ptrCast(@alignCast(ctx));
                return layer_mod.plan(g, c.*, i);
            }
            fn done(ctx: *const anyopaque, g: Allocator, i: usize) void {
                const c: *const layer_mod.Context = @ptrCast(@alignCast(ctx));
                dropMemo(g, c.cache, i);
            }
        };
        const src: PlanSource = .{
            .ctx = &plan_ctx,
            .plan = Src.plan,
            .done = if (self.keep_memos) null else Src.done,
            .resolved = &self.resolved,
            .layers = self.layers.len,
        };
        return emitAll(gpa, src, self.threads, self.monitor, out, sink);
    }
};

/// Frees the memo of layer i (see Job.keep_memos).
pub fn dropMemo(gpa: Allocator, cache: []layer_mod.Memo, i: usize) void {
    if (cache.len <= i) return;
    cache[i].deinit();
    cache[i] = .init(gpa);
}

/// Where pass 2 gets its layer plans: from one job, or from the jobs of
/// the parts of a plate (see plate_job.zig).
pub const PlanSource = struct {
    ctx: *const anyopaque,
    /// The plan of layer i. Any thread can call it, for different layers
    /// at the same time.
    plan: *const fn (ctx: *const anyopaque, gpa: Allocator, i: usize) Allocator.Error!LayerPlan,
    /// Called after the plan of layer i is made, or null. It frees the
    /// memos that no later plan needs.
    done: ?*const fn (ctx: *const anyopaque, gpa: Allocator, i: usize) void = null,
    /// The settings of the print: the machine, the start and end G-code,
    /// and the settings of the layers with no settings of their own.
    resolved: *const settings_mod.Resolved,
    layers: usize,
    /// The stored stream of each layer (see stream.zig), or null. A layer
    /// with a valid stream gets its plan from the stream, with no call of
    /// `plan`. The pipeline stores the stream of each layer that it
    /// plans. Needs `bind`.
    streams: ?[]stream_mod.Stream = null,
    bind: ?stream_mod.BindFn = null,
    /// The filaments of the plate (see gcode.Emitter.slots).
    slots: []const settings_mod.Filament = &.{},
    /// The prime towers (see gcode.Towers).
    towers: gcode.Towers = .{},
};

/// True if a start or end G-code has a variable of the box of the first
/// layer (PrusaSlicer first_layer_print_min, OrcaSlicer
/// adaptive_bed_mesh_min).
fn usesFirstLayerBox(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "first_layer_print_") != null or std.mem.indexOf(u8, text, "adaptive_bed_mesh_") != null;
}

/// The box of the paths of the first layer in G-code coordinates (min x,
/// min y, max x, max y), or null if the layer has no paths. The plan of
/// layer 0 is made once more for it, before the start G-code.
fn firstLayerBox(gpa: Allocator, src: PlanSource) Allocator.Error!?[4]f64 {
    var lp = try src.plan(src.ctx, gpa, 0);
    defer lp.deinit();
    const pts = lp.points.points.items;
    if (pts.len == 0) return null;
    var lo = pts[0];
    var hi = pts[0];
    for (pts[1..]) |q| {
        lo.x = @min(lo.x, q.x);
        lo.y = @min(lo.y, q.y);
        hi.x = @max(hi.x, q.x);
        hi.y = @max(hi.y, q.y);
    }
    const m = src.resolved.settings.machine;
    return .{ geom.toMm(lo.x) + m.origin_x, geom.toMm(lo.y) + m.origin_y, geom.toMm(hi.x) + m.origin_x, geom.toMm(hi.y) + m.origin_y };
}

/// Step 5: plans each layer of `src` and writes the G-code. See
/// `Pipeline`.
pub fn emitAll(gpa: Allocator, src: PlanSource, threads: usize, monitor: Monitor, out: *Writer, sink: ?Job.LayerSink) Error!Stats {
    var em: gcode.Emitter = .init(gpa, out, src.resolved);
    em.slots = src.slots;
    em.towers = src.towers;
    var record: std.ArrayList(gcode.PathInfo) = .empty;
    defer record.deinit(gpa);
    if (sink != null) em.record = &record;
    const m = src.resolved.settings.machine;
    if (src.layers > 0 and (usesFirstLayerBox(m.start_gcode) or usesFirstLayerBox(m.end_gcode))) {
        em.first_layer_box = try firstLayerBox(gpa, src);
    }
    try em.begin(src.layers);

    var reporter: Reporter = .{ .monitor = monitor, .base = pass1_share, .span = 1 - pass1_share, .total = src.layers };
    // The planned layers wait in a ring of slots for the emitter. The
    // ring holds a few layers for each thread: enough to keep the
    // threads busy, and a small part of the memory of all plans.
    const window = @max(8, threads * 4);
    const slots = try gpa.alloc(Slot, window);
    defer gpa.free(slots);
    for (slots) |*sl| sl.* = .{ .text = .init(gpa) };
    defer for (slots) |*sl| sl.deinit(gpa);
    const guesses = try gpa.alloc(Guess, src.layers);
    defer gpa.free(guesses);
    for (guesses) |*g| g.* = .{};
    // The emitter after the start G-code: each early run starts from a
    // copy of it.
    const base = try gpa.create(gcode.Emitter);
    defer gpa.destroy(base);
    base.* = em;
    base.record = null;
    var pipe: Pipeline = .{ .gpa = gpa, .src = src, .slots = slots, .n = src.layers, .monitor = monitor, .record = sink != null, .out = out, .sink = sink, .reporter = &reporter, .guesses = guesses, .base = base };

    // All threads plan layers, run them early, write their text, and
    // send the texts out in layer order. This thread also links the
    // layers in order: the one step that no other thread can do.
    var pool: [64]parallel.Thread = undefined;
    var spawned: usize = 0;
    defer if (comptime parallel.can_spawn) {
        pipe.stop.store(true, .release);
        pipe.signal.notify();
        for (pool[0..spawned]) |t| parallel.join(t);
    };
    if (comptime parallel.can_spawn) {
        const want = @min(threads, pool.len + 1, src.layers) -| 1;
        while (spawned < want) : (spawned += 1) {
            pool[spawned] = parallel.spawn(Pipeline, Pipeline.work, &pipe) catch break;
        }
    }
    var discard: Writer.Discarding = .init(&.{});
    var dried: usize = 0;
    const n = src.layers;
    while (pipe.emitted.load(.acquire) < n) {
        if (pipe.failed()) |e| return e;
        if (monitor.canceled()) return error.Canceled;
        const seen = pipe.signal.current();
        var progress = false;
        // The link: the state at the start of each layer with an early
        // run. A layer with no early run, or with a run from another
        // state, gets a dry run here.
        while (dried < n and slots[dried % window].compiled.load(.acquire) == dried + 1) {
            const slot = &slots[dried % window];
            slot.start = em;
            slot.start.?.w = undefined;
            const linked = if (slot.assumed) |a| em.at(a) and em.link(&slot.plan.?, &slot.exit, &slot.terms, &slot.prep) else false;
            if (linked) {
                dried += 1;
                pipe.dried.store(dried, .release);
                pipe.signal.notify();
                progress = true;
                continue;
            }
            // A layer from a stream has no outline. If the dry run needs
            // it, the layer gets a plan, and the dry run starts again.
            const before = em;
            const out_w = em.w;
            while (true) {
                // The print order of a layer of many filaments, for the
                // filament in the nozzle (see gcode.Emitter.orderLayer).
                try em.orderLayer(&slot.plan.?, &slot.prep);
                em.w = &discard.writer;
                em.dry = true;
                em.record = null;
                em.prep = &slot.prep;
                const res = em.layer(&slot.plan.?);
                const again = em.need_plan;
                if (again) em = before;
                em.w = out_w;
                em.dry = false;
                em.prep = null;
                if (sink != null) em.record = &record;
                try res;
                if (!again) break;
                slot.start = em;
                slot.start.?.w = undefined;
                try pipe.planSlot(slot, dried);
            }
            dried += 1;
            pipe.dried.store(dried, .release);
            pipe.signal.notify();
            progress = true;
        }
        if (progress) continue;
        if (!pipe.outSome() and !pipe.writeOne() and !pipe.runOne() and !pipe.planOne()) pipe.signal.wait(seen);
    }
    if (pipe.failed()) |e| return e;
    try em.end();
    // The work memory of the booleans and offsets goes back to the
    // operating system (see scratch.zig).
    scratch.trim();
    return em.stats;
}

/// The room that the skirt and the brim need around the parts (mm), so
/// that they are on the bed too.
pub fn ringMargin(r: *const settings_mod.Resolved) f64 {
    const pr = r.settings.project;
    const fw = r.first_layer_line_width;
    const skirt = if (pr.skirt_loops > 0 and pr.skirt_layers > 0) pr.skirt_distance + @as(f64, @floatFromInt(pr.skirt_loops)) * fw else 0;
    return pr.brim_width + skirt + fw / 2;
}

/// A slot of the plan ring. `ready` is i + 1 when the plan of layer i is
/// in the slot, and `written` is i + 1 when its text is.
const Slot = struct {
    plan: ?LayerPlan = null,
    ready: std.atomic.Value(usize) = .init(0),
    /// The emitter at the start of the layer, after the dry runs of the
    /// layers before it.
    start: ?gcode.Emitter = null,
    text: Writer.Allocating,
    records: std.ArrayList(gcode.PathInfo) = .empty,
    /// The work of the layer that the planning thread does before the dry
    /// run (see gcode.Prepared).
    prep: gcode.Prepared = .{},
    /// i + 1 after the early run of layer i (see `Pipeline.runOne`).
    compiled: std.atomic.Value(usize) = .init(0),
    /// The state that the early run started from, or null if the layer
    /// had no early run.
    assumed: ?gcode.Entry = null,
    /// The state after the early run, and the terms of its sums.
    exit: gcode.Exit = .{},
    terms: gcode.Terms = .{},
    written: std.atomic.Value(usize) = .init(0),

    /// Frees the plan, and keeps the memory of the text for the next layer.
    fn clear(slot: *Slot) void {
        if (slot.plan) |*lp| lp.deinit();
        slot.plan = null;
        slot.start = null;
        slot.text.clearRetainingCapacity();
        slot.records.clearRetainingCapacity();
        slot.prep.clear();
        slot.assumed = null;
        slot.terms.clear();
    }

    fn deinit(slot: *Slot, gpa: Allocator) void {
        slot.clear();
        slot.text.deinit();
        slot.records.deinit(gpa);
        slot.prep.deinit(gpa);
        slot.terms.deinit(gpa);
    }
};

/// The state that the early run of the next layer starts from: a guess
/// from the plan of a layer (see gcode.Entry). `state` is 0 before the
/// plan, 1 with a guess, and 2 if the plan gives no guess.
const Guess = struct {
    state: std.atomic.Value(u8) = .init(0),
    entry: gcode.Entry = .{},
};

/// Pass 2, with the G-code in parallel. Four steps for each layer:
///
/// 1. Plan. Each thread takes the next layer from one counter and plans it
///    into its slot of the ring. Layer i uses slot i mod (ring size), so a
///    thread waits until layer i - (ring size) is out. The same thread
///    then finds the combing ways and the move lengths of the layer (see
///    gcode.Prepared).
/// 2. Early run. Any thread runs the emitter on the layer with no text:
///    the moves, their planned times, and the speed of a short layer.
///    The run starts from a guess of the state after the layer before:
///    the nozzle at the end of its last path (see `Guess`).
/// 3. Link, in layer order on the emitter thread: it checks the guess
///    against the real state, and adds the times, the filament, and the
///    travel of the layer to the sums of the print (see
///    gcode.Emitter.link). A layer with a wrong guess gets a dry run
///    here. The link is short: a few adds for each move.
/// 4. Text. Any thread writes the G-code text of a layer into its slot,
///    with a copy of the emitter from step 2. Any thread then sends the
///    texts out in layer order, one thread at a time (see `outSome`).
///
/// Each step depends only on the layer index and on the steps before it,
/// so the output is the same for each thread count.
const Pipeline = struct {
    gpa: Allocator,
    src: PlanSource,
    slots: []Slot,
    n: usize,
    monitor: Monitor,
    /// True if the sink needs the path records.
    record: bool,
    next: std.atomic.Value(usize) = .init(0),
    /// The next layer that a thread runs early.
    next_run: std.atomic.Value(usize) = .init(0),
    guesses: []Guess,
    base: *const gcode.Emitter,
    /// The number of layers with a link.
    dried: std.atomic.Value(usize) = .init(0),
    /// The next layer whose text a thread writes.
    next_text: std.atomic.Value(usize) = .init(0),
    /// The number of layers that are written out.
    emitted: std.atomic.Value(usize) = .init(0),
    /// Where the texts go, and who gets each layer after its text.
    out: *Writer,
    sink: ?Job.LayerSink,
    reporter: *Reporter,
    /// True while a thread sends texts out (see `outSome`).
    out_busy: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    /// The first error, as an error code, or 0.
    err_code: std.atomic.Value(u16) = .init(0),
    /// Changes when a plan or a text is ready, a slot is free, or an error
    /// happens.
    signal: parallel.Signal = .{},

    fn failed(p: *Pipeline) ?Error {
        const code = p.err_code.load(.acquire);
        if (code == 0) return null;
        return @errorCast(@errorFromInt(code));
    }

    fn work(p: *Pipeline) void {
        while (!p.stop.load(.acquire) and p.failed() == null) {
            if (p.next_text.load(.monotonic) >= p.n) return;
            const seen = p.signal.current();
            // The text first: a slot is free only after its text is out.
            if (!p.writeOne() and !p.outSome() and !p.runOne() and !p.planOne()) p.signal.wait(seen);
        }
    }

    /// Plans the next layer if its slot is free. Returns false if there
    /// was nothing to do now.
    fn planOne(p: *Pipeline) bool {
        const i = p.next.load(.monotonic);
        if (i >= p.n or i >= p.emitted.load(.acquire) + p.slots.len) return false;
        if (p.next.cmpxchgWeak(i, i + 1, .monotonic, .monotonic) != null) return true;
        if (p.monitor.canceled()) {
            p.fail(error.Canceled);
            return true;
        }
        const slot = &p.slots[i % p.slots.len];
        const stored: ?*const stream_mod.Stream = if (p.src.streams) |st| (if (st[i].valid) &st[i] else null) else null;
        if (stored) |st| {
            // The plan and the travel answers from the stream.
            slot.plan = st.decode(p.gpa, &slot.prep, p.src.bind.?, p.src.ctx, i) catch |e| {
                p.fail(e);
                return true;
            };
        } else {
            p.planSlot(slot, i) catch |e| {
                p.fail(e);
                return true;
            };
        }
        const g = &p.guesses[i];
        if (slot.prep.end) |e| {
            g.entry = .{ .x = e[0], .y = e[1], .z = slot.plan.?.z, .feature = slot.prep.end_feature, .extruded = true, .tool = gcode.endTool(&slot.plan.?, p.src.resolved, p.src.slots) };
            g.state.store(1, .release);
        } else g.state.store(2, .release);
        slot.ready.store(i + 1, .release);
        p.signal.notify();
        return true;
    }

    /// Plans layer i into its slot, with the work of the emitter that the
    /// layers before do not change (see gcode.prepare).
    fn planSlot(p: *Pipeline, slot: *Slot, i: usize) Error!void {
        if (slot.plan) |*old| old.deinit();
        slot.plan = null;
        slot.plan = try p.src.plan(p.src.ctx, p.gpa, i);
        if (p.monitor.canceled()) {
            // The plan can be one that stopped early.
            slot.plan.?.deinit();
            slot.plan = null;
            return error.Canceled;
        }
        try gcode.prepare(p.gpa, p.src.resolved, &slot.plan.?, &slot.prep);
        if (p.src.done) |done| done(p.src.ctx, p.gpa, i);
    }

    /// Runs the next planned layer early, from the guess of the layer
    /// before it. Returns false if there was nothing to do now.
    fn runOne(p: *Pipeline) bool {
        const i = p.next_run.load(.monotonic);
        if (i >= p.n) return false;
        const slot = &p.slots[i % p.slots.len];
        if (slot.ready.load(.acquire) != i + 1) return false;
        const state: u8 = if (i == 0) 1 else p.guesses[i - 1].state.load(.acquire);
        if (state == 0) return false;
        if (p.next_run.cmpxchgWeak(i, i + 1, .monotonic, .monotonic) != null) return true;
        slot.assumed = null;
        if (state == 1) {
            const entry = if (i == 0) p.base.entry() else p.guesses[i - 1].entry;
            const good = p.run(slot, entry) catch |e| {
                p.fail(e);
                return true;
            };
            if (good) slot.assumed = entry;
        }
        slot.compiled.store(i + 1, .release);
        p.signal.notify();
        return true;
    }

    /// False: the run needed the outline of a layer from a stream.
    fn run(p: *Pipeline, slot: *Slot, entry: gcode.Entry) Error!bool {
        var discard: Writer.Discarding = .init(&.{});
        var em = p.base.*;
        em.w = &discard.writer;
        em.dry = true;
        em.prep = &slot.prep;
        em.terms = &slot.terms;
        em.setEntry(entry);
        try em.layer(&slot.plan.?);
        slot.exit = em.exit();
        return !em.need_plan;
    }

    /// Writes the text of the next layer after its dry run. Returns false
    /// if there was nothing to do now.
    fn writeOne(p: *Pipeline) bool {
        const i = p.next_text.load(.monotonic);
        if (i >= p.dried.load(.acquire)) return false;
        if (p.next_text.cmpxchgWeak(i, i + 1, .monotonic, .monotonic) != null) return true;
        const slot = &p.slots[i % p.slots.len];
        p.text(slot) catch |e| {
            p.fail(e);
            return true;
        };
        // The stream of a planned layer, for the next slice.
        if (p.src.streams) |st| if (!slot.prep.replay) {
            st[i].deinit(p.gpa);
            st[i] = stream_mod.Stream.encode(p.gpa, &slot.plan.?, &slot.prep, p.src.bind.?, p.src.ctx, i) catch |e| {
                p.fail(e);
                return true;
            };
        };
        slot.written.store(i + 1, .release);
        p.signal.notify();
        return true;
    }

    /// Sends out the texts that are ready, in layer order, and gives each
    /// layer to the sink. One thread does this at a time, and any thread
    /// can: the emitter thread stays free for the dry runs. Returns false
    /// if no text was ready.
    fn outSome(p: *Pipeline) bool {
        var progress = false;
        while (true) {
            if (p.out_busy.swap(true, .acquire)) return progress;
            // Only the thread with `out_busy` changes `emitted`.
            var w = p.emitted.load(.monotonic);
            while (w < p.n and p.failed() == null and p.slots[w % p.slots.len].written.load(.acquire) == w + 1) {
                const slot = &p.slots[w % p.slots.len];
                p.out.writeAll(slot.text.written()) catch |e| {
                    p.fail(e);
                    break;
                };
                if (p.sink) |sk| sk.func(sk.ctx, &slot.plan.?, slot.records.items) catch |e| {
                    p.fail(@errorCast(e));
                    break;
                };
                slot.clear();
                w += 1;
                // The slot is free for layer w - 1 + (ring size).
                p.emitted.store(w, .release);
                p.signal.notify();
                p.reporter.step(1);
                progress = true;
            }
            p.out_busy.store(false, .release);
            // A text that became ready after the loop, while this thread
            // still was busy: its thread found `out_busy` set and left.
            if (w >= p.n or p.failed() != null or p.slots[w % p.slots.len].written.load(.acquire) != w + 1) return progress;
        }
    }

    fn text(p: *Pipeline, slot: *Slot) Error!void {
        var em = slot.start.?;
        em.w = &slot.text.writer;
        em.record = null;
        em.prep = &slot.prep;
        if (p.record) {
            try slot.records.ensureTotalCapacity(p.gpa, slot.plan.?.paths.items.len);
            em.record = &slot.records;
        }
        try em.layer(&slot.plan.?);
        // The run before this one had all answers from the same state.
        if (em.need_plan) return error.WriteFailed;
    }

    fn fail(p: *Pipeline, e: Error) void {
        _ = p.err_code.cmpxchgStrong(0, @intFromError(e), .acq_rel, .monotonic);
        p.signal.notify();
    }
};

/// A hash of all inputs of the outlines, except the mesh: the part height
/// and bottom, the placement, and the settings and overrides that pass 1
/// uses.
fn outlineKey(settings: Settings, outline_overrides: []const settings_mod.Override, height: f64, b: mesh_mod.Bounds3, dx: f64, dy: f64) u64 {
    var h = std.hash.Wyhash.init(0);
    const f = settings.filament;
    const p = settings.project;
    const e = settings.engine;
    const values = [_]f64{
        height,               b.min[0],             b.min[1],          b.min[2],
        b.max[0],             b.max[1],             b.max[2],          dx,
        dy,                   p.first_layer_height, p.layer_height,    f.shrinkage_z,
        f.shrinkage_xy,       f.xy_offset,          f.hole_xy_offset,  p.first_layer_xy_offset,
        e.resolution,         e.gap_closing,
    };
    h.update(std.mem.sliceAsBytes(&values));
    for (outline_overrides) |o| {
        h.update(std.mem.asBytes(&[2]f64{ o.z_min, o.z_max }));
        h.update(o.name);
        h.update("\x00");
        h.update(o.value);
        h.update("\x00");
    }
    return h.final();
}

/// Moves the outer boundaries of an outline by `xy`, and its holes by
/// `hole - xy` more (a positive `hole` makes the holes larger). A hole is a
/// clockwise loop.
fn compensate(gpa: Allocator, outline: Paths, xy: i64, hole: i64) Allocator.Error!Paths {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var outers: std.ArrayList([]const geom.Point) = .empty;
    var holes: std.ArrayList([]geom.Point) = .empty;
    for (0..outline.count()) |i| {
        const poly = outline.get(i);
        if (geom.area2(poly) > 0) {
            try outers.append(a, poly);
        } else {
            // The hole as a counterclockwise area, so that a positive
            // offset makes it larger.
            const rev = try a.dupe(geom.Point, poly);
            std.mem.reverse(geom.Point, rev);
            try holes.append(a, rev);
        }
    }
    if (holes.items.len == 0) {
        var all: Paths = .empty;
        for (outers.items) |o| try all.append(a, o);
        const grown = try offset_mod.offset(a, all, xy, .{});
        return grown.clone(gpa);
    }
    // Each hole belongs to the smallest outline around it. An island in a
    // hole (a box on a deck, in the hole of the hull outline) is an outline
    // of its own: the hole of the hull must not cut it. So each outline
    // gets only its own holes, and the results are joined.
    const one = struct {
        fn paths(al: Allocator, poly: []const geom.Point) Allocator.Error!Paths {
            var p: Paths = .empty;
            try p.append(al, poly);
            return p;
        }
    };
    const owner = try a.alloc(?usize, holes.items.len);
    for (holes.items, 0..) |h, hi| {
        owner[hi] = null;
        var best_area: i128 = std.math.maxInt(i128);
        for (outers.items, 0..) |o, oi| {
            const ar = geom.area2(o);
            if (ar >= best_area) continue;
            if (geom.insideAny(try one.paths(a, o), h[0])) {
                best_area = ar;
                owner[hi] = oi;
            }
        }
    }
    var result: Paths = .empty;
    for (outers.items, 0..) |o, oi| {
        var mine: Paths = .empty;
        for (holes.items, 0..) |h, hi| if (owner[hi] == oi) try mine.append(a, h);
        const grown = try offset_mod.offset(a, try one.paths(a, o), xy, .{});
        const part = if (mine.isEmpty()) grown else try clip.difference(a, grown, try offset_mod.offset(a, mine, hole - xy, .{}));
        try result.appendAll(a, part);
    }
    return clip.unionAll(gpa, result, .non_zero);
}

test "a part wider than the bed does not fit on it" {
    const s: Settings = .{};
    const bx = s.machine.bed_size_x;
    try std.testing.expect(fitsBed(.{ 0, 0, 0 }, .{ bx, 20, 5 }, s));
    try std.testing.expect(!fitsBed(.{ 0, 0, 0 }, .{ bx + 0.5, 20, 5 }, s));
    try std.testing.expect(!fitsBed(.{ -10, -200, 0 }, .{ 10, s.machine.bed_size_y - 199, 5 }, s));
    var shrink = s;
    shrink.filament.shrinkage_xy = 1.1;
    try std.testing.expect(!fitsBed(.{ 0, 0, 0 }, .{ bx - 1, 20, 5 }, shrink));
}

test "a hole offset does not remove an island in the hole" {
    const gpa = testing.allocator;
    // A 40 mm square with a 30 mm hole, and a 6 mm square island in the hole.
    var o: Paths = .empty;
    defer o.deinit(gpa);
    const sq = struct {
        fn f(x0: i64, y0: i64, x1: i64, y1: i64, ccw: bool) [4]geom.Point {
            const p = [4]geom.Point{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) };
            return if (ccw) p else .{ p[3], p[2], p[1], p[0] };
        }
    }.f;
    try o.append(gpa, &sq(0, 0, 40000, 40000, true));
    try o.append(gpa, &sq(5000, 5000, 35000, 35000, false));
    try o.append(gpa, &sq(17000, 17000, 23000, 23000, true));
    var out = try compensate(gpa, o, 0, 100);
    defer out.deinit(gpa);
    // The ring and the island: about 1600 - 900 - 6 mm2 (the hole grows by
    // 0.1 mm) + 36 mm2.
    try testing.expectApproxEqAbs(@as(f64, 1600 - 900 + 36), out.areaMm2(), 15);
    try testing.expectEqual(@as(usize, 3), out.count());
}

const testing = std.testing;

test "slice the demo part" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: Settings = .{};
    s.engine.threads = 4;
    // No skirt: the test checks the position of the part.
    s.project.skirt_loops = 0;
    const stats = try slice(gpa, &m, s, &out.writer);
    const text = out.written();
    // 14 mm: one 0.3 mm layer, then 0.2 mm layers. The tops are 0.3 to 13.9.
    // A top at 14.1 has its cut plane at 14.0, the top of the part, so that
    // layer is not added.
    try testing.expectEqual(@as(u32, 69), stats.layer_count);
    try testing.expect(stats.filament_mm > 100);
    try testing.expect(std.mem.indexOf(u8, text, ";LAYER:68\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, ";TYPE:WALL-OUTER\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, ";TYPE:SKIN\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, ";TYPE:FILL\n") != null);

    // Each X and Y is on the bed, and the part is centered.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var min_x: f64 = 1e9;
    var max_x: f64 = -1e9;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "G1 X")) continue;
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        _ = tok.next();
        const x = try std.fmt.parseFloat(f64, tok.next().?[1..]);
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
    }
    // The demo part is 40 mm wide (x 0 to 40), centered at x = 110. The
    // outer wall is half a line width inside.
    try testing.expectApproxEqAbs(@as(f64, 90 + 0.22), min_x, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 130 - 0.22), max_x, 0.01);
}

test "the same G-code with 1 thread and with 8 threads" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    var a: Writer.Allocating = .init(gpa);
    defer a.deinit();
    var b: Writer.Allocating = .init(gpa);
    defer b.deinit();
    var s: Settings = .{};
    s.engine.threads = 1;
    _ = try slice(gpa, &m, s, &a.writer);
    s.engine.threads = 8;
    _ = try slice(gpa, &m, s, &b.writer);
    try testing.expectEqualStrings(a.written(), b.written());
}

test "lightning infill: only under the top, and the same on 1 and 8 threads" {
    const gpa = testing.allocator;
    // A 20 mm box, 40 mm tall. A path of a tree from the wall to the end
    // of a branch is at most about 15 mm long, and it gets shorter by
    // 0.2 tan(40) mm on each layer, so the trees end within about 18 mm
    // under the top.
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 40);
    defer m.deinit(gpa);
    var s: Settings = .{};
    try s.set("project.infill_pattern", "lightning");
    var texts: [2][]u8 = undefined;
    for ([_]u32{ 1, 8 }, 0..) |threads, k| {
        s.engine.threads = threads;
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try slice(gpa, &m, s, &out.writer);
        texts[k] = try out.toOwnedSlice();
    }
    defer for (texts) |t| gpa.free(t);
    try testing.expectEqualStrings(texts[0], texts[1]);
    const layers = try layerTexts(gpa, texts[0]);
    defer gpa.free(layers);
    var fill_low: usize = 0;
    var fill_high: usize = 0;
    for (layers, 0..) |t, i| {
        const z = 0.3 + 0.2 * @as(f64, @floatFromInt(i));
        const has = std.mem.indexOf(u8, t, ";TYPE:FILL") != null;
        if (has and z < 20) fill_low += 1;
        if (has and z > 30 and z < 38) fill_high += 1;
    }
    try testing.expectEqual(@as(usize, 0), fill_low);
    try testing.expect(fill_high > 30);
    // Less plastic than the grid.
    var grid: Writer.Allocating = .init(gpa);
    defer grid.deinit();
    s.project.infill_pattern = .grid;
    _ = try slice(gpa, &m, s, &grid.writer);
    try testing.expect(extrusion(texts[0]) < 0.8 * extrusion(grid.written()));
}

test "the work of the planning threads gives the same G-code" {
    const gpa = testing.allocator;
    // The demo part has a tube: the travels comb around its hole.
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 4;
    s.project.combing = true;
    var job = try Job.init(gpa, &m, s);
    defer job.deinit();
    var a: Writer.Allocating = .init(gpa);
    defer a.deinit();
    _ = try job.writeGcode(&a.writer);
    // The emitter alone, with no work from the planning threads.
    var b: Writer.Allocating = .init(gpa);
    defer b.deinit();
    var em: gcode.Emitter = .init(gpa, &b.writer, &job.resolved);
    try em.begin(job.layerCount());
    for (0..job.layerCount()) |i| {
        var lp = try job.planLayer(i);
        defer lp.deinit();
        try em.layer(&lp);
    }
    try em.end();
    try testing.expectEqualStrings(b.written(), a.written());
}

test "progress goes to 100 % and cancel stops the slice" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    const Probe = struct {
        last: std.atomic.Value(u32) = .init(0),
        calls: std.atomic.Value(u32) = .init(0),
        fn f(ctx: ?*anyopaque, fraction: f64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.calls.fetchAdd(1, .monotonic);
            _ = self.last.fetchMax(@intFromFloat(@round(fraction * 100)), .monotonic);
        }
    };
    var probe: Probe = .{};
    var s: Settings = .{};
    s.engine.threads = 4;
    var job = try Job.initWith(gpa, &m, s, .{ .ctx = &probe, .progress = Probe.f });
    defer job.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    try testing.expectEqual(@as(u32, 100), probe.last.load(.monotonic));
    try testing.expect(probe.calls.load(.monotonic) <= 101);

    var cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Canceled, Job.initWith(gpa, &m, s, .{ .cancel = &cancel }));
}

test "a short layer prints slower" {
    const gpa = testing.allocator;
    // A 10 x 10 mm tower: at full speed, each layer takes less than
    // min_layer_time. (A smaller tower cannot reach 6 s even at min_speed,
    // and min_speed is a floor.)
    var m = try mesh_mod.shapes.box(gpa, 10, 10, 5);
    defer m.deinit(gpa);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: Settings = .{};
    s.project.skirt_loops = 0;
    s.engine.threads = 1;
    _ = try slice(gpa, &m, s, &out.writer);

    // The time of layer 10, from its G-code: the XY moves go through the
    // planner, and each other move (a retraction, a Z move) is a stop.
    const motion = @import("motion.zig");
    const mc = s.machine;
    var moves: std.ArrayList(motion.Move) = .empty;
    defer moves.deinit(gpa);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    var layer: i32 = -1;
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    var f: f64 = 1;
    var t: f64 = 0;
    var stop = true;
    var max_f: f64 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) layer = try std.fmt.parseInt(i32, line[7..], 10);
        if (!std.mem.startsWith(u8, line, "G0 ") and !std.mem.startsWith(u8, line, "G1 ")) continue;
        var nx = x;
        var ny = y;
        var nz = z;
        var e: f64 = 0;
        var tok = std.mem.tokenizeScalar(u8, line[3..], ' ');
        while (tok.next()) |w| {
            const v = std.fmt.parseFloat(f64, w[1..]) catch continue;
            switch (w[0]) {
                'X' => nx = v,
                'Y' => ny = v,
                'Z' => nz = v,
                'F' => f = v,
                'E' => e = v,
                else => {},
            }
        }
        const d = @import("geom.zig").hypot(nx - x, ny - y);
        if (layer == 10) {
            if (d > 0) {
                try moves.append(gpa, .{ .dir = .{ (nx - x) / d, (ny - y) / d }, .len = d, .speed = f / 60, .accel = mc.max_accel, .e_ratio = e / d, .stop_before = stop });
                stop = false;
                if (e > 0) max_f = @max(max_f, f);
            } else if (nz != z) {
                t += motion.restTime(@abs(nz - z), mc.max_z_speed, mc.max_z_accel);
                stop = true;
            } else if (e != 0) {
                t += motion.restTime(@abs(e), mc.retract_speed, mc.max_accel);
                stop = true;
            }
        }
        x = nx;
        y = ny;
        z = nz;
    }
    t += motion.plan(moves.items, .{ .corner_speed = mc.corner_speed, .extruder_corner_speed = 5 });
    // The layer takes min_layer_time (6 s), minus rounding, and no more
    // than it must.
    try testing.expect(t > 5.9);
    try testing.expect(t < 6.3);
    // And the walls are slower than the full outer wall speed (68 mm/s).
    try testing.expect(max_f < 68 * 60);
    // The fan is at the maximum on these short layers.
    try testing.expect(std.mem.indexOf(u8, out.written(), "M106 S255") != null);
}

test "slope smoothing and ironing: moves with Z between the layers, and back up after" {
    const gpa = testing.allocator;
    // The top rises 5 mm over 20 mm: each 0.2 mm layer steps 0.8 mm.
    var m = try mesh_mod.shapes.wedge(gpa, 20, 20, 1, 6);
    defer m.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.skirt_loops = 0;
    var off: Writer.Allocating = .init(gpa);
    defer off.deinit();
    const st_off = try slice(gpa, &m, s, &off.writer);
    s.project.slope_smoothing = true;
    // A tip that lets the nozzle go part of the way down.
    s.machine.nozzle_tip_radius = 0.35;
    var on: Writer.Allocating = .init(gpa);
    defer on.deinit();
    const st_on = try slice(gpa, &m, s, &on.writer);
    try testing.expect(std.mem.indexOf(u8, off.written(), "SLOPE-SMOOTHING") == null);
    try testing.expect(std.mem.indexOf(u8, on.written(), "SLOPE-IRONING") == null);
    // The same with slope ironing: more time, and the same beads.
    s.project.slope_ironing = true;
    var iron: Writer.Allocating = .init(gpa);
    defer iron.deinit();
    const st_iron = try slice(gpa, &m, s, &iron.writer);
    try testing.expect(st_iron.print_time_s > st_on.print_time_s);
    try testing.expect(st_on.print_time_s > st_off.print_time_s);
    try testing.expect(st_on.filament_mm > st_off.filament_mm);

    var lines = std.mem.splitScalar(u8, iron.written(), '\n');
    var layer_z: f64 = 0;
    var z: f64 = 0;
    var in_smooth = false;
    var in_iron = false;
    var iron_paths: usize = 0;
    var iron_e: f64 = 0;
    var iron_len: f64 = 0;
    var x: f64 = 0;
    var y: f64 = 0;
    var paths: usize = 0;
    var below: usize = 0;
    var e_sum: f64 = 0;
    const h = s.project.layer_height;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";TYPE:")) {
            in_smooth = std.mem.eql(u8, line, ";TYPE:SLOPE-SMOOTHING");
            in_iron = std.mem.eql(u8, line, ";TYPE:SLOPE-IRONING");
            if (in_smooth) paths += 1;
            if (in_iron) iron_paths += 1;
        }
        if (!std.mem.startsWith(u8, line, "G0 ") and !std.mem.startsWith(u8, line, "G1 ")) continue;
        var has_xy = false;
        var e: f64 = 0;
        const px = x;
        const py = y;
        var tok = std.mem.tokenizeScalar(u8, line[3..], ' ');
        while (tok.next()) |w| {
            const v = std.fmt.parseFloat(f64, w[1..]) catch continue;
            switch (w[0]) {
                'X' => {
                    has_xy = true;
                    x = v;
                },
                'Y' => {
                    has_xy = true;
                    y = v;
                },
                'Z' => z = v,
                'E' => e = v,
                else => {},
            }
        }
        // A layer change: a Z move with no X and Y outside a smoothing
        // path, upward.
        if (!in_smooth and !in_iron and !has_xy and z > layer_z + 1e-6) layer_z = z;
        if (has_xy and e > 0) {
            if (in_iron) {
                try testing.expect(z >= layer_z - 0.75 * h - 1e-3 and z <= layer_z + 1e-6);
                iron_e += e;
                iron_len += @import("geom.zig").hypot(x - px, y - py);
            } else if (in_smooth) {
                try testing.expect(z >= layer_z - h / 2 - 1e-3 and z <= layer_z + 1e-6);
                if (z < layer_z - 1e-3) below += 1;
                e_sum += e;
            } else {
                // All other extrusions are at the z of the layer.
                try testing.expectApproxEqAbs(layer_z, z, 1e-6);
            }
        }
        // Each travel is at the z of the layer, or above it (a z hop).
        if (has_xy and std.mem.startsWith(u8, line, "G0 ")) try testing.expect(z >= layer_z - 1e-6);
    }
    try testing.expect(paths > 10);
    try testing.expect(below > 10);
    // Ironing on each layer with a bead (one type comment for the passes
    // of a layer), with 10 % of the flow of a line.
    try testing.expectEqual(paths, iron_paths);
    {
        const r0 = try s.resolve();
        const e_line = flow.beadArea(r0.line_width, h) / r0.filament_area;
        try testing.expectApproxEqRel(0.1 * e_line, iron_e / iron_len, 0.03);
    }
    // The plastic of the beads: the triangle of each step, h * L / 2 with
    // L = 0.8 mm, along a bead almost 20 mm long on each layer.
    const r = try s.resolve();
    const vol = e_sum * r.filament_area;
    const want = @as(f64, @floatFromInt(paths)) * 0.5 * h * 0.8 * 20;
    try testing.expect(vol > 0.85 * want and vol < 1.02 * want);
}

test "shrinkage and XY offsets change the outline" {
    const gpa = testing.allocator;
    // A tube: outer radius 10 mm, hole radius 4 mm.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addTube(&b, 0, 0, 10, 4, 0, 5, 256);
    var m = try b.finish();
    defer m.deinit(gpa);
    const k = 128.0 * @sin(2.0 * std.math.pi / 256.0); // the 256-gon area factor

    var s: Settings = .{};
    s.engine.threads = 1;
    var job = try Job.init(gpa, &m, s);
    const base = job.outlines[10].areaMm2();
    const base_layers = job.layerCount();
    job.deinit();
    // The slicer simplifies to 5 um, so the base area is a little less than
    // the ideal polygon area.
    try testing.expectApproxEqAbs(k * (100 - 16), base, 0.15);

    s.filament.shrinkage_xy = 1.01;
    s.filament.shrinkage_z = 1.1;
    job = try Job.init(gpa, &m, s);
    try testing.expectApproxEqRel(base * 1.0201, job.outlines[10].areaMm2(), 0.001);
    // 5 mm x 1.1 = 5.5 mm: more layers.
    try testing.expect(job.layerCount() > base_layers);
    job.deinit();

    s.filament.shrinkage_xy = 1;
    s.filament.shrinkage_z = 1;
    s.filament.xy_offset = 0.1;
    s.filament.hole_xy_offset = 0.3;
    job = try Job.init(gpa, &m, s);
    defer job.deinit();
    // The outer radius grows by 0.1 mm, and the hole radius by 0.3 - 0.1.
    const want = base + k * (10.1 * 10.1 - 100) - k * (4.2 * 4.2 - 16);
    try testing.expectApproxEqAbs(want, job.outlines[10].areaMm2(), 0.05);
}

/// The XY move of the part for a placement mode. The file position wins if
/// the part, with `margin` mm around it (the skirt and the brim), is fully
/// on the bed there (with `.auto`). A tolerance of 1 um accepts a part that
/// touches the bed edge.
pub fn placementOffset(mode: settings_mod.Placement, min: [3]f64, max: [3]f64, bed_x: f64, bed_y: f64, margin: f64) [2]f64 {
    const center = [2]f64{ bed_x / 2 - (min[0] + max[0]) / 2, bed_y / 2 - (min[1] + max[1]) / 2 };
    const tol = 0.001;
    const on_bed = min[0] - margin >= -tol and min[1] - margin >= -tol and
        max[0] + margin <= bed_x + tol and max[1] + margin <= bed_y + tol;
    return switch (mode) {
        .file => .{ 0, 0 },
        .center => center,
        .auto => if (on_bed) .{ 0, 0 } else center,
    };
}

test "placement: the file position if it is on the bed, else the center" {
    // A part at 50..70 on a 220 bed stays where the file has it.
    try std.testing.expectEqual([2]f64{ 0, 0 }, placementOffset(.auto, .{ 50, 60, 0 }, .{ 70, 80, 5 }, 220, 220, 0));
    // A part around the origin goes to the center.
    try std.testing.expectEqual([2]f64{ 110, 110 }, placementOffset(.auto, .{ -10, -10, 0 }, .{ 10, 10, 5 }, 220, 220, 0));
    // A part over the far edge goes to the center.
    try std.testing.expectEqual([2]f64{ -105, 0 }, placementOffset(.auto, .{ 200, 100, 0 }, .{ 230, 120, 5 }, 220, 220, 0));
    // The margin: a part at the corner with a skirt around it goes to the
    // center.
    try std.testing.expectEqual([2]f64{ 90, 95 }, placementOffset(.auto, .{ 0, 0, 0 }, .{ 40, 30, 5 }, 220, 220, 4));
    // "file" and "center" do not look at the bed.
    try std.testing.expectEqual([2]f64{ 0, 0 }, placementOffset(.file, .{ -10, -10, 0 }, .{ 10, 10, 5 }, 220, 220, 0));
    try std.testing.expectEqual([2]f64{ -5, -5 }, placementOffset(.center, .{ 100, 100, 0 }, .{ 130, 130, 5 }, 220, 220, 0));
}


test "the machine origin moves the G-code, and not the part on the bed" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    var a: std.Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    _ = try slice(gpa, &mesh, s, &a.writer);
    try s.set("machine.origin_x", "-110");
    try s.set("machine.origin_y", "-110");
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    _ = try slice(gpa, &mesh, s, &b.writer);
    // The first move to the part: X and Y are 110 less.
    const xa = firstX(a.written());
    const xb = firstX(b.written());
    try std.testing.expectApproxEqAbs(xa - 110, xb, 1e-3);
}

fn firstX(g: []const u8) f64 {
    const i = std.mem.indexOf(u8, g, "G1 X").?;
    const rest = g[i + 4 ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ').?;
    return std.fmt.parseFloat(f64, rest[0..end]) catch unreachable;
}

test "an override changes only its layers, and keeps the region cache" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    const s: Settings = .{};
    var base = try Job.init(gpa, &mesh, s);
    defer base.deinit();
    const o = [_]settings_mod.Override{.{ .z_min = 3, .z_max = 4, .name = "project.infill_density", .value = "0.6" }};
    var job = try Job.initFull(gpa, &mesh, s, &o, .{});
    defer job.deinit();
    // An override does not change the outlines.
    try std.testing.expectEqual(base.outline_key, job.outline_key);
    var in_range: usize = 0;
    for (job.layers, 0..) |layer, i| {
        const d = job.resolvedAt(i).settings.project.infill_density;
        if (layer.z >= 3 and layer.z <= 4) {
            try std.testing.expectEqual(@as(f64, 0.6), d);
            in_range += 1;
        } else try std.testing.expectEqual(@as(f64, 0.2), d);
    }
    try std.testing.expect(in_range > 3);
    // A layer in the range has more infill lines than without the override
    // (more points: the joined infill lines make fewer, longer paths).
    const i_mid = blk: {
        for (job.layers, 0..) |layer, i| if (layer.z >= 3.4) break :blk i;
        unreachable;
    };
    var a = try base.planLayer(i_mid);
    defer a.deinit();
    var b = try job.planLayer(i_mid);
    defer b.deinit();
    try std.testing.expect(b.points.points.items.len > a.points.points.items.len);
    // A setting for the whole print is an error.
    const bad = [_]settings_mod.Override{.{ .z_min = 3, .z_max = 4, .name = "project.support_angle", .value = "60" }};
    try std.testing.expectError(error.InvalidSettings, Job.initFull(gpa, &mesh, s, &bad, .{}));
}

test "a job that reuses the work of an older job gives the same G-code" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    // Each step changes one setting, and keeps the changes before it. The
    // last steps go back to values from before, so the memos have results
    // of two generations. `same` is true if the outlines stay the same.
    const steps = [_]struct { name: []const u8, value: []const u8, same: bool }{
        .{ .name = "project.infill_density", .value = "0.35", .same = true },
        .{ .name = "project.wall_count", .value = "3", .same = true },
        .{ .name = "project.top_thickness", .value = "1.2", .same = true },
        .{ .name = "project.bottom_thickness", .value = "0.2", .same = true },
        .{ .name = "project.line_width", .value = "0.5", .same = true },
        .{ .name = "project.wall_count", .value = "2", .same = true },
        .{ .name = "project.line_width", .value = "0", .same = true },
        .{ .name = "project.top_thickness", .value = "0", .same = true },
        .{ .name = "project.layer_height", .value = "0.25", .same = false },
        .{ .name = "filament.xy_offset", .value = "0.05", .same = false },
        .{ .name = "project.top_thickness", .value = "0.8", .same = true },
    };
    var s: Settings = .{};
    s.engine.threads = 2;
    var prev = try Job.init(gpa, &mesh, s);
    defer prev.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try prev.writeGcode(&discard.writer);
    for (steps) |step| {
        try s.set(step.name, step.value);
        var fresh = try Job.init(gpa, &mesh, s);
        defer fresh.deinit();
        var out_fresh: std.Io.Writer.Allocating = .init(gpa);
        defer out_fresh.deinit();
        _ = try fresh.writeGcode(&out_fresh.writer);

        var reuse = try Job.initReuse(gpa, &mesh, s, &.{}, &.{}, .{}, &prev);
        try std.testing.expectEqual(step.same, reuse.gen > prev.gen);
        var out_reuse: std.Io.Writer.Allocating = .init(gpa);
        defer out_reuse.deinit();
        _ = reuse.writeGcode(&out_reuse.writer) catch |e| {
            reuse.deinit();
            return e;
        };
        prev.deinit();
        prev = reuse;
        try std.testing.expectEqualStrings(out_fresh.written(), out_reuse.written());
    }
}

test "a job with overrides reuses the work of an older job" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    const s: Settings = .{};
    var old = try Job.init(gpa, &mesh, s);
    defer old.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try old.writeGcode(&discard.writer);
    const o = [_]settings_mod.Override{.{ .z_min = 3, .z_max = 8, .name = "project.wall_count", .value = "4" }};
    var fresh = try Job.initFull(gpa, &mesh, s, &o, .{});
    defer fresh.deinit();
    var out_fresh: std.Io.Writer.Allocating = .init(gpa);
    defer out_fresh.deinit();
    _ = try fresh.writeGcode(&out_fresh.writer);
    var reuse = try Job.initReuse(gpa, &mesh, s, &o, &.{}, .{}, &old);
    defer reuse.deinit();
    try std.testing.expectEqual(@as(u32, 1), reuse.gen);
    var out_reuse: std.Io.Writer.Allocating = .init(gpa);
    defer out_reuse.deinit();
    _ = try reuse.writeGcode(&out_reuse.writer);
    try std.testing.expectEqualStrings(out_fresh.written(), out_reuse.written());
}

test "the cooling lap fills the min layer time with moves over the layer" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    try s.set("filament.min_layer_time", "20");
    var slow: std.Io.Writer.Allocating = .init(gpa);
    defer slow.deinit();
    const st_slow = try slice(gpa, &mesh, s, &slow.writer);
    try s.set("filament.cooling_mode", "lap");
    var lap: std.Io.Writer.Allocating = .init(gpa);
    defer lap.deinit();
    const st_lap = try slice(gpa, &mesh, s, &lap.writer);
    try std.testing.expect(std.mem.indexOf(u8, lap.written(), ";TYPE:COOLING-LAP") != null);
    try std.testing.expect(std.mem.indexOf(u8, slow.written(), ";TYPE:COOLING-LAP") == null);
    // Both meet the min layer time: the print times are close.
    try std.testing.expectApproxEqRel(st_slow.print_time_s, st_lap.print_time_s, 0.15);
}

test "the retraction at a layer change has no z hop" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    try s.set("project.z_hop", "1");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try slice(gpa, &mesh, s, &out.writer);
    const text = out.written();
    // From each layer mark to the first travel of the layer: one Z move
    // (the layer change), and no lift.
    var layers: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, ";LAYER:")) |mark| {
        at = mark + 1;
        const travel = std.mem.indexOfPos(u8, text, mark, "G0 X") orelse continue;
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text[mark..travel], "G0 Z"));
        layers += 1;
    }
    try std.testing.expect(layers > 10);
    // The z hop is still on the travels that retract.
    try std.testing.expect(std.mem.indexOf(u8, text, "G1 E-") != null);
}

/// The text of each layer of a G-code file: from one ";LAYER:" mark to the
/// next, or to the statistics at the end.
fn layerTexts(gpa: Allocator, all: []const u8) Allocator.Error![][]const u8 {
    const text = all[0 .. std.mem.indexOf(u8, all, ";Filament used") orelse all.len];
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var at = std.mem.indexOf(u8, text, ";LAYER:") orelse return list.toOwnedSlice(gpa);
    while (std.mem.indexOfPos(u8, text, at + 1, ";LAYER:")) |next| {
        try list.append(gpa, text[at..next]);
        at = next;
    }
    try list.append(gpa, text[at..]);
    return list.toOwnedSlice(gpa);
}

/// The G-code of the demo part with the overrides.
fn demoGcode(gpa: Allocator, overrides: []const settings_mod.Override) ![]u8 {
    return demoGcodeWith(gpa, .{}, overrides);
}

fn demoGcodeWith(gpa: Allocator, settings: Settings, overrides: []const settings_mod.Override) ![]u8 {
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s = settings;
    s.engine.threads = 2;
    var job = try Job.initFull(gpa, &mesh, s, overrides, .{});
    defer job.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    return out.toOwnedSlice();
}

/// The sum of the E values of the extrusion moves of a text.
fn extrusion(text: []const u8) f64 {
    var sum: f64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "G1 X")) continue;
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        while (tok.next()) |w| if (w[0] == 'E') {
            sum += std.fmt.parseFloat(f64, w[1..]) catch 0;
        };
    }
    return sum;
}

test "an override of the G-code settings changes only the layers in its range" {
    const gpa = testing.allocator;
    const base = try demoGcode(gpa, &.{});
    defer gpa.free(base);
    // The layers with a top z from 3 to 4: 3.1 to 3.9.
    const o = [_]settings_mod.Override{
        .{ .z_min = 3, .z_max = 4, .name = "filament.nozzle_temp", .value = "230" },
        .{ .z_min = 3, .z_max = 4, .name = "filament.bed_temp", .value = "50" },
        .{ .z_min = 3, .z_max = 4, .name = "filament.fan_speed", .value = "0.5" },
        .{ .z_min = 3, .z_max = 4, .name = "filament.fan_max_speed", .value = "0.5" },
        .{ .z_min = 3, .z_max = 4, .name = "filament.flow_ratio", .value = "1.1" },
    };
    const changed = try demoGcode(gpa, &o);
    defer gpa.free(changed);
    const a = try layerTexts(gpa, base);
    defer gpa.free(a);
    const b = try layerTexts(gpa, changed);
    defer gpa.free(b);
    try testing.expectEqual(a.len, b.len);
    // Layer i has its top at 0.3 + 0.2 i: layers 14 to 18 are in the range.
    for (a, b, 0..) |la, lb, i| {
        if (i < 14 or i > 19) {
            try testing.expectEqualStrings(la, lb);
        } else if (i <= 18) {
            try testing.expectApproxEqRel(1.1 * extrusion(la), extrusion(lb), 1e-3);
            try testing.expect(std.mem.indexOf(u8, lb, "M106 S128\n") != null or i > 14);
        }
    }
    try testing.expect(std.mem.indexOf(u8, b[14], "M104 S230\n") != null);
    try testing.expect(std.mem.indexOf(u8, b[14], "M140 S50\n") != null);
    // After the range: the values of the print again.
    try testing.expect(std.mem.indexOf(u8, b[19], "M104 S210\n") != null);
    try testing.expect(std.mem.indexOf(u8, b[19], "M140 S60\n") != null);
    try testing.expect(std.mem.indexOf(u8, b[19], "M106 S255\n") != null);
    try testing.expect(std.mem.indexOf(u8, a[14], "M104") == null);
}

/// The G-code of a wedge (its top rises 5 mm over 20 mm) with the
/// overrides.
fn wedgeGcode(gpa: Allocator, overrides: []const settings_mod.Override) ![]u8 {
    var mesh = try mesh_mod.shapes.wedge(gpa, 20, 20, 1, 6);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.machine.nozzle_tip_radius = 0.35;
    var job = try Job.initFull(gpa, &mesh, s, overrides, .{});
    defer job.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    return out.toOwnedSlice();
}

/// The text of the paths of one type in a layer, up to the next type.
fn typeText(layer: []const u8, name: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, layer, name) orelse return "";
    const end = std.mem.indexOfPos(u8, layer, at + name.len, ";TYPE:") orelse layer.len;
    return layer[at..end];
}

test "the z hop of a layer lifts only on travels that cross an edge" {
    const gpa = testing.allocator;
    // The print has no z hop; the layers of the range have one.
    var counts: [2]usize = undefined;
    for ([_]bool{ true, false }, 0..) |only_crossing, k| {
        var s: Settings = .{};
        s.project.z_hop = 0;
        s.project.z_hop_only_crossing = only_crossing;
        s.project.combing_max_distance = 5;
        // All layers above the first.
        const o = [_]settings_mod.Override{.{ .z_min = 0.4, .z_max = 100, .name = "project.z_hop", .value = "0.4" }};
        const text = try demoGcodeWith(gpa, s, &o);
        defer gpa.free(text);
        const layers = try layerTexts(gpa, text);
        defer gpa.free(layers);
        var hops: usize = 0;
        for (layers, 0..) |l, i| {
            const n = std.mem.count(u8, l, "G0 Z");
            // The layer change is one Z move; a lift and its return are two.
            if (i == 0) try testing.expectEqual(@as(usize, 1), n) else hops += n - 1;
        }
        counts[k] = hops;
    }
    try testing.expect(counts[0] > 0);
    try testing.expect(counts[0] < counts[1]);
}

test "an override of slope smoothing and ironing changes only the layers in its range" {
    const gpa = testing.allocator;
    const on = [_]settings_mod.Override{
        .{ .z_min = 3, .z_max = 4, .name = "project.slope_smoothing", .value = "true" },
        .{ .z_min = 3, .z_max = 4, .name = "project.slope_ironing", .value = "true" },
    };
    const a_text = try wedgeGcode(gpa, &on);
    defer gpa.free(a_text);
    // The same, with more flow on the layers of the range.
    const more = on ++ [_]settings_mod.Override{.{ .z_min = 3, .z_max = 4, .name = "filament.flow_ratio", .value = "1.1" }};
    const b_text = try wedgeGcode(gpa, &more);
    defer gpa.free(b_text);
    const a = try layerTexts(gpa, a_text);
    defer gpa.free(a);
    const b = try layerTexts(gpa, b_text);
    defer gpa.free(b);
    // Layer i has its top at 0.3 + 0.2 i: layers 14 to 18 are in the range.
    for (a, b, 0..) |la, lb, i| {
        const in_range = i >= 14 and i <= 18;
        try testing.expectEqual(in_range, std.mem.indexOf(u8, la, ";TYPE:SLOPE-SMOOTHING") != null);
        try testing.expectEqual(in_range, std.mem.indexOf(u8, la, ";TYPE:SLOPE-IRONING") != null);
        if (in_range) {
            const ea = extrusion(typeText(la, ";TYPE:SLOPE-SMOOTHING"));
            const eb = extrusion(typeText(lb, ";TYPE:SLOPE-SMOOTHING"));
            try testing.expect(ea > 0);
            try testing.expectApproxEqRel(1.1 * ea, eb, 2e-3);
        }
    }
}

test "a retraction and its push back have the same length at a change of the retraction" {
    const gpa = testing.allocator;
    const o = [_]settings_mod.Override{
        .{ .z_min = 3, .z_max = 4, .name = "filament.retract_ratio", .value = "2" },
        .{ .z_min = 3, .z_max = 4, .name = "project.z_hop", .value = "0.4" },
        .{ .z_min = 3, .z_max = 4, .name = "project.combing", .value = "false" },
    };
    // Each retracted travel lifts the nozzle, also inside the part.
    var s: Settings = .{};
    s.project.z_hop_only_crossing = false;
    const text = try demoGcodeWith(gpa, s, &o);
    defer gpa.free(text);
    const layers = try layerTexts(gpa, text);
    defer gpa.free(layers);
    // The sum of the retractions and the push backs is 0 to the end of each
    // layer, but for one retraction that is open at the layer change.
    var open: f64 = 0;
    for (layers, 0..) |l, i| {
        var lines = std.mem.splitScalar(u8, l, '\n');
        var hops: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "G1 E")) open += try std.fmt.parseFloat(f64, line[4 .. std.mem.indexOfScalarPos(u8, line, 4, ' ') orelse line.len]);
            if (std.mem.startsWith(u8, line, "G0 Z")) hops += 1;
        }
        try testing.expect(open > -1.7 and open < 1e-9);
        const in_range = i >= 14 and i <= 18;
        // Without combing, the layers of the range retract more, with a z hop.
        if (in_range) {
            try testing.expect(std.mem.indexOf(u8, l, "G1 E-1.6 ") != null);
            try testing.expect(hops > 1);
        } else try testing.expect(std.mem.indexOf(u8, l, "G1 E-1.6 ") == null);
    }
}

test "an override of the planner settings changes only the layers in its range" {
    const gpa = testing.allocator;
    var s: Settings = .{};
    s.machine.accel_control = true;
    const base = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(base);
    const o = [_]settings_mod.Override{
        .{ .z_min = 3, .z_max = 4, .name = "project.line_width", .value = "0.5" },
        .{ .z_min = 3, .z_max = 4, .name = "machine.outer_wall_accel", .value = "500" },
        .{ .z_min = 3, .z_max = 4, .name = "project.infill_connect", .value = "false" },
        .{ .z_min = 3, .z_max = 4, .name = "project.skin_angle_step", .value = "45" },
    };
    const changed = try demoGcodeWith(gpa, s, &o);
    defer gpa.free(changed);
    const a = try layerTexts(gpa, base);
    defer gpa.free(a);
    const b = try layerTexts(gpa, changed);
    defer gpa.free(b);
    try testing.expectEqual(a.len, b.len);
    for (a, b, 0..) |la, lb, i| {
        if (i < 14 or i > 19) {
            try testing.expectEqualStrings(la, lb);
        } else if (i <= 18) {
            try testing.expect(!std.mem.eql(u8, la, lb));
            try testing.expect(std.mem.indexOf(u8, lb, "M204 S500\n") != null);
            try testing.expect(std.mem.indexOf(u8, la, "M204 S500\n") == null);
        }
    }
}

/// The E per mm of the first outer wall line of a layer text, from the
/// nozzle position before it.
fn outerWallEPerMm(text: []const u8) !f64 {
    var x: f64 = 0;
    var y: f64 = 0;
    var in_wall = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";TYPE:")) in_wall = std.mem.eql(u8, line, ";TYPE:WALL-OUTER");
        if (!std.mem.startsWith(u8, line, "G0 X") and !std.mem.startsWith(u8, line, "G1 X")) continue;
        var nx = x;
        var ny = y;
        var e: f64 = 0;
        var tok = std.mem.tokenizeScalar(u8, line[3..], ' ');
        while (tok.next()) |w| {
            const v = try std.fmt.parseFloat(f64, w[1..]);
            switch (w[0]) {
                'X' => nx = v,
                'Y' => ny = v,
                'E' => e = v,
                else => {},
            }
        }
        if (in_wall and e > 0) return e / @import("geom.zig").hypot(nx - x, ny - y);
        x = nx;
        y = ny;
    }
    return error.TestUnexpectedResult;
}

test "a layer height override: the selected layer and the layers above get the new height" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    // "This layer and up" from the layer with its top at 3.1.
    const o = [_]settings_mod.Override{.{ .z_min = 3.1 - 1e-3, .z_max = settings_mod.part_z, .name = "project.layer_height", .value = "0.1" }};
    var job = try Job.initFull(gpa, &mesh, s, &o, .{});
    defer job.deinit();
    var base = try Job.init(gpa, &mesh, s);
    defer base.deinit();
    try testing.expect(job.outline_key != base.outline_key);
    // The layers below the selected layer (14, from 2.9 to 3.1) are the
    // layers of the plain job. From layer 14 up, the layers are 0.1 mm,
    // with z values from one multiply: 2.9 + k 0.1.
    for (job.layers, 0..) |l, i| {
        if (i < 14) {
            try testing.expectEqual(base.layers[i].z, l.z);
            try testing.expectEqual(base.layers[i].height, l.height);
        } else {
            try testing.expectEqual(@as(f64, 0.1), l.height);
            try testing.expectEqual(base.layers[13].z + @as(f64, @floatFromInt(i - 13)) * 0.1, l.z);
        }
    }
    try testing.expectApproxEqAbs(@as(f64, 2.9), base.layers[13].z, 1e-9);
    // 14 mm: 14 layers to 2.9, then 0.1 mm layers from 3.0 to 14.0.
    try testing.expectEqual(@as(usize, 14 + 111), job.layers.len);
    // The per layer settings of a layer in the range have the new height.
    try testing.expectEqual(@as(f64, 0.1), job.resolvedAt(job.layers.len - 1).settings.project.layer_height);

    // The G-code has each layer, at its z, with the flow of its height.
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const stats = try job.writeGcode(&out.writer);
    try testing.expectEqual(@as(u32, @intCast(job.layers.len)), stats.layer_count);
    const texts = try layerTexts(gpa, out.written());
    defer gpa.free(texts);
    try testing.expectEqual(job.layers.len, texts.len);
    for (texts, job.layers) |t, l| {
        var buf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "G0 Z{d} ", .{@round(l.z * 1000) / 1000});
        try testing.expect(std.mem.indexOf(u8, t, want) != null);
    }
    const flow_mod = @import("flow.zig");
    const w = job.resolved.line_width;
    const e_thick = try outerWallEPerMm(texts[10]);
    const e_thin = try outerWallEPerMm(texts[40]);
    const want_ratio = flow_mod.beadArea(w, 0.1) / flow_mod.beadArea(w, 0.2);
    try testing.expectApproxEqRel(want_ratio, e_thin / e_thick, 2e-3);
}

test "a layer height span: the top skin has its thickness in thin layers" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    const s: Settings = .{};
    const o = [_]settings_mod.Override{.{ .z_min = 10, .z_max = settings_mod.part_z, .name = "project.layer_height", .value = "0.1" }};
    var job = try Job.initFull(gpa, &mesh, s, &o, .{});
    defer job.deinit();
    // The top 0.8 mm of skin is 8 layers of 0.1 mm: the layer 8 layers
    // under the top has no skin over the full area, and the layer under the
    // top 0.8 mm has sparse infill.
    const n = job.layers.len;
    var top = try job.planLayer(n - 8);
    defer top.deinit();
    var below = try job.planLayer(n - 9);
    defer below.deinit();
    var infill_top: usize = 0;
    for (top.paths.items) |p| if (p.feature == .infill) {
        infill_top += 1;
    };
    var infill_below: usize = 0;
    for (below.paths.items) |p| if (p.feature == .infill) {
        infill_below += 1;
    };
    try testing.expectEqual(@as(usize, 0), infill_top);
    try testing.expect(infill_below > 0);
}

/// A cup around (0, 0): radius 15, height 5, with a floor up to z = 1.5.
/// The hole has a small draft: radius 11 at the floor and 11.01 at the
/// top. So each layer above the floor has a thin top surface along the
/// hole, nearly parallel to the edge of the floor top.
fn cupMesh(gpa: Allocator) !Mesh {
    const r_out = 15.0;
    const r_floor = 11.0;
    const r_top = 11.01;
    const floor = 1.5;
    const height = 5.0;
    const segments = 180;
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    const P = struct {
        fn at(r: f64, i: usize, z: f64) mesh_mod.Vec3 {
            const a = 2 * std.math.pi * @as(f64, @floatFromInt(i % segments)) / segments;
            return .{ .x = @floatCast(r * @cos(a)), .y = @floatCast(r * @sin(a)), .z = @floatCast(z) };
        }
    };
    const bottom_center: mesh_mod.Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    const floor_center: mesh_mod.Vec3 = .{ .x = 0, .y = 0, .z = floor };
    for (0..segments) |i| {
        try b.addQuad(P.at(r_out, i, 0), P.at(r_out, i + 1, 0), P.at(r_out, i + 1, height), P.at(r_out, i, height));
        try b.addTriangle(bottom_center, P.at(r_out, i + 1, 0), P.at(r_out, i, 0));
        try b.addQuad(P.at(r_out, i, height), P.at(r_out, i + 1, height), P.at(r_top, i + 1, height), P.at(r_top, i, height));
        try b.addQuad(P.at(r_floor, i + 1, floor), P.at(r_floor, i, floor), P.at(r_top, i, height), P.at(r_top, i + 1, height));
        try b.addTriangle(floor_center, P.at(r_floor, i, floor), P.at(r_floor, i + 1, floor));
    }
    return b.finish();
}

test "top skin: the floor of a cup with a draft has its full top skin" {
    const gpa = testing.allocator;
    var mesh = try cupMesh(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.project.layer_height = 0.1;
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    // The center of the cup on the bed, from the outer wall of layer 0.
    var first = try job.planLayer(0);
    defer first.deinit();
    var lo: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
    var hi: [2]f64 = .{ -std.math.inf(f64), -std.math.inf(f64) };
    for (first.paths.items, 0..) |p, k| if (p.feature == .outer_wall) {
        for (first.points.get(k)) |q| {
            lo = .{ @min(lo[0], geom.toMm(q.x)), @min(lo[1], geom.toMm(q.y)) };
            hi = .{ @max(hi[0], geom.toMm(q.x)), @max(hi[1], geom.toMm(q.y)) };
        }
    };
    const cx = (lo[0] + hi[0]) / 2;
    const cy = (lo[1] + hi[1]) / 2;
    // The 8 layers under the top of the floor (0.8 mm of top skin) have
    // no sparse infill under the hole: no infill line has its middle
    // there. The skin of these layers comes from a union of the floor top
    // and the thin surfaces above it.
    var floor_top: usize = 0;
    for (job.layers, 0..) |l, i| if (l.z < 1.5 + 1e-6) {
        floor_top = i;
    };
    try testing.expect(floor_top >= 7);
    for (floor_top - 7..floor_top + 1) |i| {
        var lp = try job.planLayer(i);
        defer lp.deinit();
        for (lp.paths.items, 0..) |p, k| if (p.feature == .infill) {
            const pts = lp.points.get(k);
            for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
                const dx = geom.toMm(@divTrunc(a.x + b.x, 2)) - cx;
                const dy = geom.toMm(@divTrunc(a.y + b.y, 2)) - cy;
                try testing.expect(dx * dx + dy * dy > 10 * 10);
            }
        };
    }
}

test "an XY offset override changes the outlines of its layers" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    const s: Settings = .{};
    var base = try Job.init(gpa, &mesh, s);
    defer base.deinit();
    const o = [_]settings_mod.Override{.{ .z_min = 3, .z_max = 4, .name = "filament.xy_offset", .value = "0.2" }};
    var job = try Job.initFull(gpa, &mesh, s, &o, .{});
    defer job.deinit();
    try testing.expect(job.outline_key != base.outline_key);
    for (job.layers, 0..) |l, i| {
        const a = base.outlines[i].areaMm2();
        const b = job.outlines[i].areaMm2();
        if (l.z >= 3 and l.z <= 4) try testing.expect(b > a + 1) else try testing.expectEqual(a, b);
    }
}

test "z hop only on travels that cross an edge, and no retraction at a layer change" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    try s.set("project.z_hop", "1");
    // Long travels inside the part retract.
    try s.set("project.combing_max_distance", "2");
    const Count = struct {
        fn of(text: []const u8, needle: []const u8) usize {
            return std.mem.count(u8, text, needle);
        }
    };
    var all: std.Io.Writer.Allocating = .init(gpa);
    defer all.deinit();
    try s.set("project.z_hop_only_crossing", "false");
    _ = try slice(gpa, &mesh, s, &all.writer);
    var crossing: std.Io.Writer.Allocating = .init(gpa);
    defer crossing.deinit();
    try s.set("project.z_hop_only_crossing", "true");
    _ = try slice(gpa, &mesh, s, &crossing.writer);
    // The same retractions, and fewer lifts.
    try std.testing.expectEqual(Count.of(all.written(), "G1 E-"), Count.of(crossing.written(), "G1 E-"));
    try std.testing.expect(Count.of(crossing.written(), "G0 Z") < Count.of(all.written(), "G0 Z"));
    var no_lc: std.Io.Writer.Allocating = .init(gpa);
    defer no_lc.deinit();
    // With no limit on combing, most first travels of a layer stay inside.
    try s.set("project.combing_max_distance", "0");
    var lc: std.Io.Writer.Allocating = .init(gpa);
    defer lc.deinit();
    try s.set("project.retract_layer_change", "true");
    _ = try slice(gpa, &mesh, s, &lc.writer);
    try s.set("project.retract_layer_change", "false");
    _ = try slice(gpa, &mesh, s, &no_lc.writer);
    try std.testing.expect(Count.of(no_lc.written(), "G1 E-") < Count.of(lc.written(), "G1 E-"));
}

/// The extrusion (E) of the moves of one feature type (";TYPE:" mark) in
/// a G-code text.
fn featureExtrusion(text: []const u8, type_name: []const u8) f64 {
    var sum: f64 = 0;
    var on = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";TYPE:")) on = std.mem.eql(u8, line[6..], type_name);
        if (!on or !std.mem.startsWith(u8, line, "G1 X")) continue;
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        while (tok.next()) |w| if (w[0] == 'E') {
            sum += std.fmt.parseFloat(f64, w[1..]) catch 0;
        };
    }
    return sum;
}

/// The infill of a job: the sum of length x bead height of the infill
/// paths of all layers (mm^2), and the number of layers with infill.
fn infillStats(job: *const Job) !struct { area: f64, layers: usize } {
    var area: f64 = 0;
    var layers: usize = 0;
    for (0..job.layerCount()) |i| {
        var lp = try job.planLayer(i);
        defer lp.deinit();
        var any = false;
        for (lp.paths.items, 0..) |path, k| {
            if (path.feature != .infill) continue;
            any = true;
            const h: f64 = if (path.height > 0) path.height else lp.height;
            area += pathLength(lp.points.get(k), path.closed) * h;
        }
        if (any) layers += 1;
    }
    return .{ .area = area, .layers = layers };
}

fn pathLength(pts: []const geom.Point, closed: bool) f64 {
    var len: f64 = 0;
    for (pts[1..], 0..) |q, k| len += geom.toMm(@intFromFloat(pts[k].dist(q)));
    if (closed and pts.len > 2) len += geom.toMm(@intFromFloat(pts[pts.len - 1].dist(pts[0])));
    return len;
}

test "combined infill: one tall bead every second layer, in the area sparse in both layers" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.project.infill_layers = 2;
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    try testing.expect(job.groups.len == job.layerCount());
    var combined_layers: usize = 0;
    for (0..job.layerCount()) |i| {
        const g = job.groups[i];
        try testing.expect(g.count() <= 2);
        var lp = try job.planLayer(i);
        defer lp.deinit();
        var comb: usize = 0;
        var plain: usize = 0;
        for (lp.paths.items, 0..) |path, k| {
            if (path.feature != .infill) continue;
            if (path.height == 0) {
                plain += 1;
                continue;
            }
            comb += 1;
            // Only the last layer of a group, with the height of the group.
            try testing.expect(g.count() == 2 and i == g.last);
            try testing.expectApproxEqAbs(job.layers[i].height + job.layers[i - 1].height, path.height, 1e-6);
            // Each point is in the sparse area of both layers.
            for (g.first..g.last + 1) |j| {
                var memo: layer_mod.Memo = .init(gpa);
                defer memo.deinit();
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const reg = try layer_mod.regions(gpa, job.planContext(), j, &memo, arena.allocator());
                for (lp.points.get(k)) |q| try testing.expect(geom.insideAny(reg.sparse, q));
            }
        }
        if (comb > 0) combined_layers += 1;
        // In the middle of the wide box, all of the sparse area of the
        // lower layer of a group is in the tall bead above.
        if (lp.z > 2 and lp.z < 4 and g.count() == 2) {
            if (i == g.first) try testing.expectEqual(@as(usize, 0), plain + comb);
            if (i == g.last) try testing.expect(comb > 0 and plain == 0);
        }
    }
    try testing.expect(combined_layers > 10);
}

test "combined infill: about the same infill per height, and the bead model for the flow" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var stats: [2]struct { area: f64, layers: usize } = undefined;
    var fill_e: [2]f64 = undefined;
    for ([_]u32{ 1, 2 }, 0..) |n, k| {
        var s: Settings = .{};
        s.engine.threads = 2;
        s.project.infill_layers = n;
        var job = try Job.init(gpa, &mesh, s);
        defer job.deinit();
        const st = try infillStats(&job);
        stats[k] = .{ .area = st.area, .layers = st.layers };
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try job.writeGcode(&out.writer);
        fill_e[k] = featureExtrusion(out.written(), "FILL");
    }
    // The lines times their bead heights: the infill covers the same
    // height of the part.
    try testing.expectApproxEqRel(stats[0].area, stats[1].area, 0.04);
    // Fewer layers with infill.
    try testing.expect(stats[1].layers * 10 < stats[0].layers * 7);
    // The plastic: one bead of 0.4 mm holds less than two beads of
    // 0.2 mm (the round sides are taller, see flow.zig). The combined
    // part has the ratio of the bead model, the rest prints as before.
    const w = 1.1 * 0.4;
    const model = flow.beadArea(w, 0.4) / (2 * flow.beadArea(w, 0.2));
    const ratio = fill_e[1] / fill_e[0];
    try testing.expect(ratio < 1 and ratio > model - 0.03);
}

test "combined infill: a group is never thicker than the nozzle" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    // 0.12 mm layers: 3 of them (0.36 mm) fit a 0.4 mm nozzle, 4 do not.
    var s: Settings = .{};
    s.engine.threads = 2;
    s.project.layer_height = 0.12;
    s.project.infill_layers = 4;
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    var most: usize = 0;
    for (job.groups) |g| {
        most = @max(most, g.count());
        var sum: f64 = 0;
        for (g.first..g.last + 1) |j| sum += job.layers[j].height;
        try testing.expect(sum <= 0.4 + 1e-9);
    }
    try testing.expectEqual(@as(usize, 3), most);
    // 0.25 mm layers: two are thicker than the nozzle, so no layer
    // combines, and the G-code is the same as with infill_layers = 1.
    var a: Settings = .{};
    a.project.layer_height = 0.25;
    var b = a;
    b.project.infill_layers = 2;
    const ga = try demoGcodeWith(gpa, a, &.{});
    defer gpa.free(ga);
    const gb = try demoGcodeWith(gpa, b, &.{});
    defer gpa.free(gb);
    // The same moves: the settings at the end differ.
    try testing.expectEqualStrings(withoutSettings(ga), withoutSettings(gb));
}

/// The G-code before the list of settings at its end.
fn withoutSettings(g: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, g, ";zslice settings") orelse return g;
    return g[0..i];
}

test "the G-code ends with the settings that differ from the defaults" {
    const gpa = testing.allocator;
    var s: Settings = .{};
    s.project.layer_height = 0.25;
    const g = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(g);
    try testing.expect(std.mem.indexOf(u8, g, ";  project.layer_height = 0.25\n") != null);
    try testing.expect(std.mem.indexOf(u8, g, ";  project.infill_layers") == null);
}

test "combined infill: each pattern makes tall beads" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    inline for (@typeInfo(settings_mod.InfillPattern).@"enum".fields) |f| {
        // Lightning layers print on their own (see layer.groups).
        if (comptime std.mem.eql(u8, f.name, "lightning")) continue;
        var s: Settings = .{};
        s.engine.threads = 2;
        s.project.infill_layers = 2;
        s.project.infill_pattern = @enumFromInt(f.value);
        var job = try Job.init(gpa, &mesh, s);
        defer job.deinit();
        // A layer in the middle of the wide box, at the top of its group.
        var i: usize = 0;
        while (!(job.layers[i].z > 3 and job.groups[i].count() == 2 and job.groups[i].last == i)) i += 1;
        var lp = try job.planLayer(i);
        defer lp.deinit();
        var comb: usize = 0;
        for (lp.paths.items) |path| {
            if (path.feature == .infill and path.height > 0) comb += 1;
        }
        testing.expect(comb > 0) catch |e| {
            std.debug.print("pattern {s}: no tall beads\n", .{f.name});
            return e;
        };
        // The G-code has the larger E for them.
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try job.writeGcode(&out.writer);
    }
}

test "combined infill: an override combines only the layers in its range" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    const overrides = [_]settings_mod.Override{.{ .z_min = 2, .z_max = 4, .name = "project.infill_layers", .value = "2" }};
    var job = try Job.initFull(gpa, &mesh, s, &overrides, .{});
    defer job.deinit();
    var any = false;
    for (job.groups, 0..) |g, i| if (g.count() > 1) {
        any = true;
        for (g.first..g.last + 1) |j| try testing.expect(overrides[0].covers(job.layers[j].z));
        _ = i;
    };
    try testing.expect(any);
}

test "a job with the same outlines and support takes the islands of the old job" {
    const gpa = testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    var old = try Job.init(gpa, &mesh, s);
    defer old.deinit();
    const fresh_n = old.islands.len;
    // A change of the infill only: the same outlines and support.
    s.project.infill_density = 0.4;
    var job = try Job.initReuse(gpa, &mesh, s, &.{}, &.{}, .{}, &old);
    defer job.deinit();
    try testing.expectEqual(old.islands_key, job.islands_key);
    try testing.expectEqual(fresh_n, job.islands.len);
    var fresh = try Job.init(gpa, &mesh, s);
    defer fresh.deinit();
    try testing.expectEqual(fresh.islands.len, job.islands.len);
    try testing.expectEqual(fresh.islands_key, job.islands_key);
    // Support on: other support areas, so another key.
    s.project.support = .everywhere;
    var with_support = try Job.initReuse(gpa, &mesh, s, &.{}, &.{}, .{}, &job);
    defer with_support.deinit();
    try testing.expect(with_support.islands_key != job.islands_key or with_support.support.len == 0);
}

/// The points of the infill paths of a plan, sorted, for a check that two
/// layers have the same infill.
fn infillPoints(gpa: Allocator, lp: *const LayerPlan) ![]geom.Point {
    var out: std.ArrayList(geom.Point) = .empty;
    for (lp.paths.items, 0..) |p, k| if (p.feature == .infill) try out.appendSlice(gpa, lp.points.get(k));
    std.mem.sort(geom.Point, out.items, {}, struct {
        fn lt(_: void, a: geom.Point, b: geom.Point) bool {
            return if (a.x != b.x) a.x < b.x else a.y < b.y;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// The direction (degrees, 0 to 180) of the longest infill segment.
fn infillDirection(lp: *const LayerPlan) f64 {
    var best: f64 = 0;
    var dir: f64 = 0;
    for (lp.paths.items, 0..) |p, k| if (p.feature == .infill) {
        const pts = lp.points.get(k);
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            const dx: f64 = @floatFromInt(b.x - a.x);
            const dy: f64 = @floatFromInt(b.y - a.y);
            const l = @import("geom.zig").hypot(dx, dy);
            if (l > best) {
                best = l;
                dir = @mod(std.math.radiansToDegrees(std.math.atan2(dy, dx)), 180);
            }
        }
    };
    return dir;
}

test "infill: the patterns that stack have the same lines on each layer" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 30, 30, 8);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    const Case = struct { pattern: settings_mod.InfillPattern, stack: bool, angles: []const u8, same: bool };
    const cases = [_]Case{
        .{ .pattern = .lines, .stack = false, .angles = "", .same = false },
        .{ .pattern = .lines, .stack = true, .angles = "", .same = true },
        .{ .pattern = .zigzag, .stack = true, .angles = "", .same = true },
        .{ .pattern = .grid, .stack = false, .angles = "", .same = true },
        .{ .pattern = .triangles, .stack = false, .angles = "", .same = true },
        .{ .pattern = .trihexagon, .stack = false, .angles = "", .same = true },
        .{ .pattern = .honeycomb, .stack = false, .angles = "", .same = true },
        .{ .pattern = .honeycomb, .stack = true, .angles = "", .same = true },
        .{ .pattern = .trihexagon, .stack = true, .angles = "", .same = true },
        .{ .pattern = .concentric, .stack = false, .angles = "", .same = true },
        // An angle list of one angle: the same on all layers.
        .{ .pattern = .lines, .stack = false, .angles = "30", .same = true },
        .{ .pattern = .cubic, .stack = false, .angles = "", .same = false },
    };
    for (cases) |c| {
        var s: Settings = .{};
        s.engine.threads = 1;
        s.project.infill_pattern = c.pattern;
        s.project.infill_stack = c.stack;
        s.project.infill_angles = c.angles;
        s.project.top_support_layers = 0;
        var job = try Job.init(gpa, &mesh, s);
        defer job.deinit();
        const i = job.layers.len / 2;
        var a = try job.planLayer(i);
        defer a.deinit();
        var a2 = try job.planLayer(i + 1);
        defer a2.deinit();
        const pa = try infillPoints(gpa, &a);
        defer gpa.free(pa);
        const pb = try infillPoints(gpa, &a2);
        defer gpa.free(pb);
        try testing.expect(pa.len > 0);
        const same = std.mem.eql(u8, std.mem.sliceAsBytes(pa), std.mem.sliceAsBytes(pb));
        testing.expectEqual(c.same, same) catch |e| {
            std.debug.print("pattern {s}, stack {}, angles \"{s}\"\n", .{ @tagName(c.pattern), c.stack, c.angles });
            return e;
        };
    }
}

test "infill: the angle list sets the angle of each layer in turn" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 30, 30, 8);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.infill_pattern = .lines;
    s.project.infill_connect = false;
    s.project.top_support_layers = 0;
    s.project.infill_angles = "[0, 0, 90]";
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    for (10..16) |i| {
        var lp = try job.planLayer(i);
        defer lp.deinit();
        const want: f64 = if (i % 3 == 2) 90 else 0;
        try testing.expectApproxEqAbs(want, infillDirection(&lp), 0.5);
    }
}

/// The lines of the infill segments longer than 1 mm: the direction
/// (degrees) and the distance of the line from the origin (in 20 µm
/// steps).
fn infillLineKeys(gpa: Allocator, lp: *const LayerPlan) ![][2]i64 {
    var out: std.ArrayList([2]i64) = .empty;
    for (lp.paths.items, 0..) |p, k| if (p.feature == .infill) {
        const pts = lp.points.get(k);
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            const dx: f64 = @floatFromInt(b.x - a.x);
            const dy: f64 = @floatFromInt(b.y - a.y);
            const l = @import("geom.zig").hypot(dx, dy);
            if (l < 1000) continue;
            var ang = std.math.atan2(dy, dx);
            if (ang < 0) ang += std.math.pi;
            if (ang >= std.math.pi - 1e-3) ang -= std.math.pi;
            const d = (@as(f64, @floatFromInt(a.x)) * -@sin(ang) + @as(f64, @floatFromInt(a.y)) * @cos(ang)) / 20;
            try out.append(gpa, .{ @intFromFloat(@round(std.math.radiansToDegrees(ang))), @intFromFloat(@round(d)) });
        }
    };
    return out.toOwnedSlice(gpa);
}

test "infill: with the part anchor, a part gets the same infill at each place" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 30, 20, 3);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    for ([_]settings_mod.InfillAnchor{ .part, .bed }) |anchor| {
        var keys: [2][]const [2]i64 = undefined;
        for ([_][2]f64{ .{ 40, 40 }, .{ 47.3, 52.9 } }, 0..) |at, k| {
            var s: Settings = .{};
            s.engine.threads = 1;
            s.project.infill_pattern = .grid;
            s.project.infill_connect = false;
            s.project.bottom_thickness = 0;
            s.project.top_support_layers = 0;
            s.project.infill_anchor = anchor;
            var job = try Job.initOpts(gpa, &mesh, s, .{ .offset = at });
            defer job.deinit();
            var l1 = try job.planLayer(1);
            defer l1.deinit();
            // The keys of the lines, from the center of the part.
            const raw = try infillLineKeys(gpa, &l1);
            defer gpa.free(raw);
            const out = try gpa.alloc([2]i64, raw.len);
            const c = [2]f64{ job.center[0] * 1000, job.center[1] * 1000 };
            for (raw, out) |q, *o| {
                const ang = std.math.degreesToRadians(@as(f64, @floatFromInt(q[0])));
                const dc = (c[0] * -@sin(ang) + c[1] * @cos(ang)) / 20;
                o.* = .{ q[0], q[1] - @as(i64, @intFromFloat(@round(dc))) };
            }
            keys[k] = out;
        }
        defer for (keys) |kk| gpa.free(kk);
        var same: usize = 0;
        for (keys[1]) |q| {
            for (keys[0]) |r| if (q[0] == r[0] and @abs(q[1] - r[1]) <= 1) {
                same += 1;
                break;
            };
        }
        const all = keys[1].len > 0 and same == keys[1].len;
        // With the part anchor the lines are the same; with the bed anchor
        // they move with the bed grid.
        try testing.expectEqual(anchor == .part, all);
    }
}

test "infill: the first layer has the same pattern grid as the layers above" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 30, 30, 3);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    for ([_]settings_mod.InfillPattern{ .honeycomb, .grid, .triangles, .trihexagon }) |pattern| {
        var s: Settings = .{};
        s.engine.threads = 1;
        s.project.infill_pattern = pattern;
        s.project.infill_connect = false;
        s.project.bottom_thickness = 0;
        s.project.top_support_layers = 0;
        // The grid of the bed: the keys below measure from its origin.
        s.project.infill_anchor = .bed;
        var job = try Job.init(gpa, &mesh, s);
        defer job.deinit();
        var l0 = try job.planLayer(0);
        defer l0.deinit();
        var l1 = try job.planLayer(1);
        defer l1.deinit();
        const k0 = try infillLineKeys(gpa, &l0);
        defer gpa.free(k0);
        const k1 = try infillLineKeys(gpa, &l1);
        defer gpa.free(k1);
        // The lines of layer 1 are lines of layer 0 (within 20 µm). A few
        // short pieces at the walls of layer 0 (its walls are wider) are
        // shorter than 1 mm there.
        var hits: usize = 0;
        for (k1) |q| {
            for (k0) |r| if (q[0] == r[0] and @abs(q[1] - r[1]) <= 1) {
                hits += 1;
                break;
            };
        }
        testing.expect(k1.len > 0 and hits * 20 >= k1.len * 19) catch |e| {
            std.debug.print("pattern {s}: {d} of {d} lines on the first layer\n", .{ @tagName(pattern), hits, k1.len });
            return e;
        };
    }
}

/// True if any point of a path of `feature` (and region, if not null) is
/// inside the box x0, y0, x1, y1 (mm).
fn featureIn(lp: *const LayerPlan, feature: settings_mod.Feature, region: ?u16, box: [4]f64) bool {
    for (lp.paths.items, 0..) |p, k| {
        if (p.feature != feature) continue;
        if (region) |r| if (p.region != r) continue;
        for (lp.points.get(k)) |q| {
            const x = geom.toMm(q.x);
            const y = geom.toMm(q.y);
            if (x > box[0] and x < box[2] and y > box[1] and y < box[3]) return true;
        }
    }
    return false;
}

test "modifier volume: its infill in place of the skin and the infill of the part" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 40, 40, 2);
    var plate = try b.finish();
    defer plate.deinit(gpa);
    var bw: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&bw, 10, 10, 0, 30, 30, 2);
    var window = try bw.finish();
    defer window.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 2;
    s.project.placement = .file;
    // All layers of the plate are skin.
    s.project.top_thickness = 2;
    s.project.bottom_thickness = 2;
    var job = try Job.init(gpa, &plate, s);
    defer job.deinit();
    const changes = [_]settings_mod.Change{
        .{ .name = "project.wall_count", .value = "0" },
        .{ .name = "project.top_thickness", .value = "0" },
        .{ .name = "project.bottom_thickness", .value = "0" },
        .{ .name = "project.infill_density", .value = "0.3" },
        .{ .name = "project.infill_pattern", .value = "lines" },
        .{ .name = "project.infill_speed", .value = "0.1" },
        .{ .name = "project.infill_flow", .value = "1.1" },
        .{ .name = "project.infill_angles", .value = "0" },
        .{ .name = "project.infill_connect", .value = "false" },
    };
    try job.setModifiers(&.{.{ .mesh = &window, .changes = &changes, .order = 1, .name = "window" }});
    // All layers are skin, but for the window.
    const inside = [4]f64{ 11, 11, 29, 29 };
    for ([_]usize{ 0, job.layers.len / 2, job.layers.len - 1 }) |i| {
        var lp = try job.planLayer(i);
        defer lp.deinit();
        try testing.expect(!featureIn(&lp, .skin, null, inside));
        try testing.expect(!featureIn(&lp, .outer_wall, null, inside));
        try testing.expect(!featureIn(&lp, .inner_wall, null, inside));
        // The lines along X end at the edge of the window.
        try testing.expect(featureIn(&lp, .infill, 1, .{ 9, 11, 31, 29 }));
        // The plate keeps its walls and its skin around the window.
        try testing.expect(featureIn(&lp, .outer_wall, 0, .{ -1, -1, 41, 41 }));
        try testing.expect(featureIn(&lp, .skin, 0, .{ 0.5, 1, 9.95, 39 }));
        try testing.expectEqual(@as(usize, 1), lp.region_resolved.len);
        // The infill of the window lies along X on all layers.
        for (lp.paths.items, 0..) |p, k| if (p.region == 1) {
            const pts = lp.points.get(k);
            try testing.expectEqual(pts[0].y, pts[pts.len - 1].y);
        };
        // The window infill is sparse on purpose: no gap there.
        var g = try @import("gaps.zig").find(gpa, &lp, .{});
        defer g.deinit(gpa);
        for (g.gaps) |gap| try testing.expect(!(gap.x > 12 and gap.x < 28 and gap.y > 12 and gap.y < 28));
    }
    // The G-code: the window infill at its speed (10 % of 150 mm/s) and
    // its flow.
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "F900") != null);
}

test "modifier volume: two volumes overlap, and the higher order wins" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 40, 40, 10);
    var plate = try b.finish();
    defer plate.deinit(gpa);
    var b1: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b1, 5, 5, 0, 25, 35, 10);
    var m1 = try b1.finish();
    defer m1.deinit(gpa);
    var b2: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b2, 15, 5, 0, 35, 35, 10);
    var m2 = try b2.finish();
    defer m2.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.placement = .file;
    var job = try Job.init(gpa, &plate, s);
    defer job.deinit();
    const low = [_]settings_mod.Change{.{ .name = "project.infill_density", .value = "0.1" }};
    const high = [_]settings_mod.Change{.{ .name = "project.infill_density", .value = "0.4" }};
    try job.setModifiers(&.{ .{ .mesh = &m1, .changes = &low, .order = 1, .name = "low" }, .{ .mesh = &m2, .changes = &high, .order = 2, .name = "high" } });
    // The higher order goes first.
    try testing.expectEqualStrings("high", job.modifiers[0].name);
    var lp = try job.planLayer(job.layers.len / 2);
    defer lp.deinit();
    // The overlap (15 to 25) belongs to "high": region 1 is "high" on
    // this layer.
    try testing.expectEqual(@as(u16, 0), lp.region_modifier[0]);
    try testing.expect(featureIn(&lp, .infill, 1, .{ 16, 6, 24, 34 }));
    try testing.expect(!featureIn(&lp, .infill, 2, .{ 16, 6, 24, 34 }));
    try testing.expect(featureIn(&lp, .infill, 2, .{ 6, 6, 14, 34 }));
    // The part has no infill in the volumes.
    try testing.expect(!featureIn(&lp, .infill, 0, .{ 7, 7, 33, 33 }));
}

/// The G-code of `mesh` with `settings`, for tests.
fn meshGcode(gpa: Allocator, mesh: *const Mesh, settings: Settings) ![]u8 {
    var s = settings;
    s.engine.threads = 2;
    var job = try Job.initFull(gpa, mesh, s, &.{}, .{});
    defer job.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    return out.toOwnedSlice();
}

test "bridges: the walls of a cap over air print as bridges" {
    const gpa = testing.allocator;
    // A cap from z 5 on a thin post: the walls of the first cap layer are
    // over air.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    const on = try meshGcode(gpa, &mesh, .{});
    defer gpa.free(on);
    try testing.expect(std.mem.indexOf(u8, on, ";TYPE:BRIDGE") != null);
    var s: Settings = .{};
    s.project.bridges = false;
    const off = try meshGcode(gpa, &mesh, s);
    defer gpa.free(off);
    try testing.expect(std.mem.indexOf(u8, off, ";TYPE:BRIDGE") == null);
    // The post alone (no air) has no bridge.
    var b2: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b2, 8, 8, 0, 12, 12, 5);
    var post = try b2.finish();
    defer post.deinit(gpa);
    const plain = try meshGcode(gpa, &post, .{});
    defer gpa.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, ";TYPE:BRIDGE") == null);
}

test "path rules: the outer walls at their own speed" {
    const gpa = testing.allocator;
    var s: Settings = .{};
    s.project.path_rules = "speed = {feature} == \"outer_wall\" ? 7 : {speed}\n# a comment\nnot a rule";
    const g = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(g);
    var in_outer = false;
    var outer_moves: usize = 0;
    var other_slow: usize = 0;
    var lines = std.mem.splitScalar(u8, g, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";TYPE:")) in_outer = std.mem.eql(u8, line, ";TYPE:WALL-OUTER");
        if (!std.mem.startsWith(u8, line, "G1 ") or std.mem.indexOf(u8, line, " E") == null) continue;
        const f = std.mem.indexOf(u8, line, " F") orelse continue;
        var end = f + 2;
        while (end < line.len and line[end] != ' ') end += 1;
        const feed = try std.fmt.parseFloat(f64, line[f + 2 .. end]);
        if (in_outer) {
            try testing.expectEqual(@as(f64, 420), feed);
            outer_moves += 1;
        } else if (feed == 420) other_slow += 1;
    }
    try testing.expect(outer_moves > 0);
    try testing.expectEqual(@as(usize, 0), other_slow);
}

test "start G-code: zslice heats if it does not, and the first layer sets the filament temperature" {
    const gpa = testing.allocator;
    var s: Settings = .{};
    s.filament.first_layer_nozzle_temp = 207;
    s.filament.bed_temp = 58;
    s.machine.start_gcode = "G28\nG1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]}";
    const a = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(a);
    // Heating before the start G-code, and the box of the first layer.
    const heat = std.mem.indexOf(u8, a, "M190 S58 ; zslice").?;
    try testing.expect(heat < std.mem.indexOf(u8, a, "M109 S207 ; zslice").?);
    try testing.expect(std.mem.indexOf(u8, a, "M109 S207 ; zslice").? < std.mem.indexOf(u8, a, "G28\n").?);
    try testing.expect(std.mem.indexOf(u8, a, "G1 X0 Y0") == null);
    // A probe temperature: the first layer waits for the filament value.
    s.machine.start_gcode = "M140 S{bed_temp}\nM109 S170\nG28";
    const b = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(b);
    const layer0 = std.mem.indexOf(u8, b, ";LAYER:0\n").?;
    try testing.expect(std.mem.startsWith(u8, b[layer0..], ";LAYER:0\nM109 S207\n"));
    try testing.expect(std.mem.indexOf(u8, b, "; zslice: the start G-code does not heat") == null);
}

test "first layer bed temperature and travel speed, as Cura writes them" {
    const gpa = testing.allocator;
    var s: Settings = .{};
    s.filament.bed_temp = 60;
    s.filament.first_layer_bed_temp = 70;
    s.machine.travel_speed = 150;
    s.machine.first_layer_travel_speed = 100;
    s.machine.start_gcode = "G28";
    const a = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(a);
    // CuraEngine heats the bed to material_bed_temperature_layer_0 before
    // the print, and sets material_bed_temperature (M140, no wait) when
    // layer 1 starts.
    try testing.expect(std.mem.indexOf(u8, a, "M190 S70 ; zslice") != null);
    const l0 = std.mem.indexOf(u8, a, ";LAYER:0\n").?;
    const l1 = std.mem.indexOf(u8, a, ";LAYER:1\n").?;
    const l2 = std.mem.indexOf(u8, a, ";LAYER:2\n").?;
    try testing.expect(std.mem.indexOf(u8, a[l1..l2], "\nM140 S60\n") != null);
    try testing.expect(std.mem.indexOf(u8, a[0..l1], "M140") == null);
    const l3 = std.mem.indexOf(u8, a, ";LAYER:3\n").?;
    try testing.expect(std.mem.indexOf(u8, a[l2..l3], "M140") == null);
    // The travel moves of layer 0 go at speed_travel_layer_0, the others
    // at speed_travel.
    try testing.expect(std.mem.indexOf(u8, a[l0..l1], "F6000") != null);
    try testing.expect(std.mem.indexOf(u8, a[l0..l1], "F9000") == null);
    try testing.expect(std.mem.indexOf(u8, a[l1..], "F9000") != null);
    // A start G-code with the variable of the first layer bed.
    s.machine.start_gcode = "M190 S{material_bed_temperature_layer_0}\nG28";
    const b = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "M190 S70\nG28") != null);
    try testing.expect(std.mem.indexOf(u8, b, "; zslice: the start G-code does not heat the bed") == null);
    // 0: the bed temperature on all layers, and one travel speed.
    s.filament.first_layer_bed_temp = 0;
    s.machine.first_layer_travel_speed = 0;
    s.machine.start_gcode = "G28";
    const c = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "M190 S60 ; zslice") != null);
    try testing.expect(std.mem.indexOf(u8, c, "M140 S60") == null);
    try testing.expect(std.mem.indexOf(u8, c, "F6000") == null);
}

test "pressure advance and the filament G-code, as OrcaSlicer writes them" {
    const gpa = testing.allocator;
    var s: Settings = .{};
    s.machine.start_gcode = "G28 ; start";
    s.machine.end_gcode = "M84 ; end";
    s.filament.start_gcode = "M117 {filament_name}";
    s.filament.end_gcode = "M117 done";
    s.filament.name = "Acme PLA";
    s.filament.pressure_advance = 0.045;
    // Marlin: M900 K (OrcaSlicer GCodeWriter::set_pressure_advance).
    s.machine.gcode_flavor = .marlin;
    const a = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(a);
    const start = std.mem.indexOf(u8, a, "G28 ; start").?;
    const fstart = std.mem.indexOf(u8, a, "M117 Acme PLA").?;
    const pa = std.mem.indexOf(u8, a, "M900 K0.045").?;
    const layer0 = std.mem.indexOf(u8, a, ";LAYER:0\n").?;
    try testing.expect(start < fstart and fstart < pa and pa < layer0);
    const fend = std.mem.indexOf(u8, a, "M117 done\n").?;
    try testing.expect(fend < std.mem.indexOf(u8, a, "M84 ; end").?);
    try testing.expect(fend > std.mem.lastIndexOf(u8, a, ";LAYER:").?);
    // Klipper and RepRapFirmware.
    s.machine.gcode_flavor = .klipper;
    const b = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "SET_PRESSURE_ADVANCE ADVANCE=0.045\n") != null);
    s.machine.gcode_flavor = .reprap;
    const c = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "M572 D0 S0.045") != null);
    // 0 and empty: no command and no text.
    s.machine.gcode_flavor = .marlin;
    s.filament.pressure_advance = 0;
    s.filament.start_gcode = "";
    s.filament.end_gcode = "";
    const d = try demoGcodeWith(gpa, s, &.{});
    defer gpa.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "M900") == null);
    try testing.expect(std.mem.indexOf(u8, d, "M117") == null);
}

test "gcode: a wipe retraction stays inside the part" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 2);
    try mesh_mod.shapes.addBox(&b, 40, 0, 0, 60, 20, 2);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.retract_wipe = true;
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    const text = out.written();
    var it = std.mem.splitScalar(u8, text, '\n');
    var left: usize = 0;
    var moves: usize = 0;
    const ox = s.machine.origin_x + job.dx;
    const oy = s.machine.origin_y + job.dy;
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, ";WIPE")) {
            left = 9;
            continue;
        }
        if (left == 0) continue;
        left -= 1;
        try testing.expect(std.mem.startsWith(u8, line, "G1 X"));
        try testing.expect(std.mem.indexOf(u8, line, " E-") != null);
        // X and Y of the move, in the frame of the mesh.
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        var x: f64 = 0;
        var y: f64 = 0;
        while (words.next()) |w| {
            if (w[0] == 'X') x = try std.fmt.parseFloat(f64, w[1..]) - ox;
            if (w[0] == 'Y') y = try std.fmt.parseFloat(f64, w[1..]) - oy;
        }
        const in_a = x > 0 and x < 20 and y > 0 and y < 20;
        const in_b = x > 40 and x < 60 and y > 0 and y < 20;
        try testing.expect(in_a or in_b);
        moves += 1;
    }
    try testing.expect(moves >= 9);
    // With no wipe: no arc.
    s.project.retract_wipe = false;
    var plain = try Job.init(gpa, &mesh, s);
    defer plain.deinit();
    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    _ = try plain.writeGcode(&out2.writer);
    try testing.expect(std.mem.indexOf(u8, out2.written(), ";WIPE") == null);
}


test "gcode: an outer wall wipe moves on along the wall with no plastic" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 1);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.project.outer_wall_wipe = 0.4;
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    // After each outer wall: G1 moves with X and Y and no E, 0.4 mm in all,
    // on the edge of the box.
    const ox = s.machine.origin_x + job.dx;
    const oy = s.machine.origin_y + job.dy;
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    var wipes: usize = 0;
    var x0: f64 = 0;
    var y0: f64 = 0;
    var run: f64 = 0;
    var in_run = false;
    while (it.next()) |line| {
        var x: ?f64 = null;
        var y: ?f64 = null;
        var has_e = false;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |w| {
            if (w[0] == 'X') x = try std.fmt.parseFloat(f64, w[1..]) - ox;
            if (w[0] == 'Y') y = try std.fmt.parseFloat(f64, w[1..]) - oy;
            if (w[0] == 'E') has_e = true;
        }
        const wipe = std.mem.startsWith(u8, line, "G1 X") and !has_e;
        if (wipe) {
            const px = x.?;
            const py = y.?;
            // On the outer wall: half a line in from an edge of the box.
            const edge = @min(@min(@abs(px), @abs(px - 20)), @min(@abs(py), @abs(py - 20)));
            try testing.expect(edge < 0.5);
            run += @import("geom.zig").hypot(px - x0, py - y0);
            in_run = true;
        } else if (in_run) {
            try testing.expectApproxEqAbs(@as(f64, 0.4), run, 1e-3);
            wipes += 1;
            run = 0;
            in_run = false;
        }
        if (x) |v| x0 = v;
        if (y) |v| y0 = v;
    }
    try testing.expect(wipes >= 3);

    // With no wipe: no move with no plastic on the wall.
    s.project.outer_wall_wipe = 0;
    var plain = try Job.init(gpa, &mesh, s);
    defer plain.deinit();
    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    _ = try plain.writeGcode(&out2.writer);
    var it2 = std.mem.splitScalar(u8, out2.written(), '\n');
    while (it2.next()) |line| {
        if (std.mem.startsWith(u8, line, "G1 X")) try testing.expect(std.mem.indexOf(u8, line, " E") != null);
    }
}

test "gcode: the fan goes up in steps over the ramp layers" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 2);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    s.engine.threads = 1;
    s.filament.fan_speed = 1;
    s.filament.fan_max_speed = 1;
    s.filament.fan_off_layers = 2;
    s.filament.fan_ramp_layers = 2;
    var job = try Job.init(gpa, &mesh, s);
    defer job.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try job.writeGcode(&out.writer);
    const text = out.written();
    // The first fan command of each layer.
    const want = [_][]const u8{ "M106 S85", "M106 S170", "M106 S255" };
    for (want, 2..) |w, li| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, ";LAYER:{d}\n", .{li});
        const at = std.mem.indexOf(u8, text, key).?;
        const fan = std.mem.indexOf(u8, text[at..], "M106 S").?;
        const end = std.mem.indexOfScalar(u8, text[at + fan ..], '\n').?;
        try testing.expectEqualStrings(w, text[at + fan ..][0..end]);
    }
}
