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
const parallel = @import("parallel.zig");
const support_mod = @import("support.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
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
const pass1_share = 0.3;

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

fn slicePart(gpa: Allocator, mesh: *const Mesh, settings: Settings, height: f64, z_base: f64, b: mesh_mod.Bounds3, dx: f64, dy: f64, threads: usize, monitor: Monitor) Error!Sliced {
        // Step 3.
        const f = settings.filament;
        const layers = try slicer.layerTable(gpa, height, settings.project.first_layer_height, settings.project.layer_height);
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

        // Step 4.
        var index = try slicer.FaceIndex.buildScaled(gpa, mesh, layers, z_base, f.shrinkage_z);
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
            xy_offset: i64,
            hole_offset: i64,
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
                const xy = c.xy_offset + (if (i == 0) c.first_offset else 0);
                if (xy != 0 or c.hole_offset != 0) {
                    const moved = try compensate(c.gpa, o, xy, c.hole_offset);
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
            .xy_offset = geom.fromMm(f.xy_offset),
            .hole_offset = geom.fromMm(f.hole_xy_offset),
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
    /// The top and bottom surfaces of each layer (see layer.surfaces), or
    /// empty slices if no layer has skin.
    tops: []Paths = &.{},
    bottoms: []Paths = &.{},
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
        return initReuse(gpa, mesh, settings, overrides, monitor, null);
    }

    /// `initFull`, and the job uses the work of `old`, a job of the same
    /// mesh (the caller knows). If the outlines are the same (the same
    /// `outline_key`), the job takes the outlines, the surfaces, and the
    /// memos of `old`, and skips pass 1. A change of a setting that does
    /// not change the outlines (walls, skin, infill, speeds) then slices
    /// again in much less time. `old` stays valid, but it has no outlines
    /// after this call. Free it after this call.
    pub fn initReuse(gpa: Allocator, mesh: *const Mesh, settings: Settings, overrides: []const settings_mod.Override, monitor: Monitor, old: ?*Job) Error!Job {
        for (overrides) |o| if (!settings_mod.isLayerSetting(o.name)) return error.InvalidSettings;
        var job = try initBase(gpa, mesh, settings, monitor, old);
        errdefer job.deinit();
        if (overrides.len > 0) try job.resolveLayers(settings, overrides);
        if (job.tops.len == 0) try job.makeSurfaces();
        // The work memory goes back to the operating system (see
        // scratch.zig).
        scratch.trim();
        return job;
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

    fn initBase(gpa: Allocator, mesh: *const Mesh, settings: Settings, monitor: Monitor, old: ?*Job) Error!Job {
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
        const fw = r.first_layer_line_width;
        const skirt = if (pr.skirt_loops > 0 and pr.skirt_layers > 0) pr.skirt_distance + @as(f64, @floatFromInt(pr.skirt_loops)) * fw else 0;
        const margin = pr.brim_width + skirt + fw / 2;
        const dx, const dy = placementOffset(pr.placement, b.min, b.max, m.bed_size_x, m.bed_size_y, margin);

        // The outlines depend only on the mesh and these values. If an
        // older job has the same key, its outlines are good.
        const key = outlineKey(settings, height, b, dx, dy);
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

        if (old) |o| if (o.outline_key == key and o.outlines.len > 0) {
            // The same outlines: take them, with the surfaces and the memos.
            job.layers = o.layers;
            o.layers = &.{};
            job.outlines = o.outlines;
            o.outlines = &.{};
            job.tops = o.tops;
            o.tops = &.{};
            job.bottoms = o.bottoms;
            o.bottoms = &.{};
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
            var sliced = try slicePart(gpa, mesh, settings, height, z_base, b, dx, dy, threads, monitor);
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
                sliced = try slicePart(gpa, mesh, settings, height - lift, z_base, b, dx, dy, threads, monitor);
            }
            job.layers = sliced.layers;
            job.outlines = sliced.outlines;
            job.memos = try gpa.alloc(layer_mod.Memo, job.layers.len);
            for (job.memos) |*mm| mm.* = .init(gpa);
        }

        // The support areas need the outlines of all layers.
        job.support = support_mod.compute(gpa, job.outlines, job.layers, &r, threads) catch |e| return @as(Error, @errorCast(e));
        return job;
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

    pub fn deinit(self: *Job) void {
        self.gpa.free(self.layer_set);
        self.gpa.free(self.layer_resolved);
        for (self.memos) |*mm| mm.deinit();
        self.gpa.free(self.memos);
        for (self.tops) |*t| t.deinit(self.gpa);
        self.gpa.free(self.tops);
        for (self.bottoms) |*b| b.deinit(self.gpa);
        self.gpa.free(self.bottoms);
        if (self.support.len > 0) support_mod.deinitAll(self.gpa, self.support);
        for (self.outlines) |*o| o.deinit(self.gpa);
        self.gpa.free(self.outlines);
        self.gpa.free(self.layers);
    }

    pub fn layerCount(self: *const Job) usize {
        return self.layers.len;
    }

    fn planContext(self: *const Job) layer_mod.Context {
        return .{
            .resolved = &self.resolved,
            .layers = self.layers,
            .outlines = self.outlines,
            .support = self.support,
            .cache = self.memos,
            .gen = self.gen,
            .tops = self.tops,
            .bottoms = self.bottoms,
            .layer_set = self.layer_set,
            .layer_resolved = self.layer_resolved,
        };
    }

    /// The settings of layer i, with its overrides.
    pub fn resolvedAt(self: *const Job, i: usize) *const settings_mod.Resolved {
        if (i < self.layer_set.len and self.layer_set[i] > 0) return &self.layer_resolved[self.layer_set[i] - 1];
        return &self.resolved;
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
        var em: gcode.Emitter = .init(out, &self.resolved);
        var record: std.ArrayList(gcode.PathInfo) = .empty;
        defer record.deinit(gpa);
        if (sink != null) em.record = &record;
        try em.begin(self.layers.len);

        var reporter: Reporter = .{ .monitor = self.monitor, .base = pass1_share, .span = 1 - pass1_share, .total = self.layers.len };
        // The planned layers wait in a ring of slots for the emitter. The
        // ring holds a few layers for each thread: enough to keep the
        // threads busy, and a small part of the memory of all plans.
        const window = @max(8, self.threads * 4);
        const slots = try gpa.alloc(Slot, window);
        defer gpa.free(slots);
        for (slots) |*sl| sl.* = .{ .text = .init(gpa) };
        defer for (slots) |*sl| sl.deinit(gpa);
        var pipe: Pipeline = .{ .gpa = gpa, .ctx = self.planContext(), .slots = slots, .n = self.layers.len, .monitor = self.monitor, .record = sink != null, .keep_memos = self.keep_memos };

        // The other threads plan layers and write their text. This thread
        // runs the emitter: a dry run of each layer in order (see
        // gcode.Emitter.dry), and then the text of each layer in order. It
        // also plans or writes a layer while it waits.
        var pool: [64]if (parallel.has_threads) std.Thread else void = undefined;
        var spawned: usize = 0;
        defer if (comptime parallel.has_threads) {
            pipe.stop.store(true, .release);
            pipe.signal.notify();
            for (pool[0..spawned]) |t| t.join();
        };
        if (comptime parallel.has_threads) {
            const want = @min(self.threads, pool.len + 1, self.layers.len) -| 1;
            while (spawned < want) : (spawned += 1) {
                pool[spawned] = std.Thread.spawn(.{}, Pipeline.work, .{&pipe}) catch break;
            }
        }
        var discard: Writer.Discarding = .init(&.{});
        var dried: usize = 0;
        var written: usize = 0;
        const n = self.layers.len;
        while (written < n) {
            if (pipe.failed()) |e| return e;
            if (self.monitor.canceled()) return error.Canceled;
            const seen = pipe.signal.current();
            var progress = false;
            // Dry runs: the state at the start of each planned layer.
            while (dried < n and slots[dried % window].ready.load(.acquire) == dried + 1) {
                const slot = &slots[dried % window];
                slot.start = em;
                slot.start.?.w = undefined;
                const out_w = em.w;
                em.w = &discard.writer;
                em.dry = true;
                em.record = null;
                defer {
                    em.w = out_w;
                    em.dry = false;
                    if (sink != null) em.record = &record;
                }
                try em.layer(&slot.plan.?);
                dried += 1;
                pipe.dried.store(dried, .release);
                pipe.signal.notify();
                progress = true;
            }
            // The text of each layer, in order.
            while (written < dried and slots[written % window].written.load(.acquire) == written + 1) {
                const slot = &slots[written % window];
                const lp = &slot.plan.?;
                try out.writeAll(slot.text.written());
                if (sink) |sk| sk.func(sk.ctx, lp, slot.records.items) catch |e| return @as(Error, @errorCast(e));
                slot.clear();
                written += 1;
                // The slot is free for layer written - 1 + window.
                pipe.emitted.store(written, .release);
                pipe.signal.notify();
                reporter.step(1);
                progress = true;
            }
            if (progress or written == n) continue;
            if (!pipe.writeOne() and !pipe.planOne()) pipe.signal.wait(seen);
        }
        try em.end();
        // The work memory of the booleans and offsets goes back to the
        // operating system (see scratch.zig).
        scratch.trim();
        return em.stats;
    }
};

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
    written: std.atomic.Value(usize) = .init(0),

    /// Frees the plan, and keeps the memory of the text for the next layer.
    fn clear(slot: *Slot) void {
        if (slot.plan) |*lp| lp.deinit();
        slot.plan = null;
        slot.start = null;
        slot.text.clearRetainingCapacity();
        slot.records.clearRetainingCapacity();
    }

    fn deinit(slot: *Slot, gpa: Allocator) void {
        slot.clear();
        slot.text.deinit();
        slot.records.deinit(gpa);
    }
};

/// Pass 2, with the G-code in parallel. Three steps for each layer:
///
/// 1. Plan. Each thread takes the next layer from one counter and plans it
///    into its slot of the ring. Layer i uses slot i mod (ring size), so a
///    thread waits until layer i - (ring size) is out.
/// 2. Dry run, in layer order on the emitter thread: the emitter state at
///    the start of the layer (the nozzle position, the fan, the time). This
///    step is fast, because it formats no numbers.
/// 3. Text. Any thread writes the G-code text of a layer into its slot,
///    with a copy of the emitter from step 2. The emitter thread writes the
///    texts out in layer order.
///
/// Each step depends only on the layer index and on the steps before it,
/// so the output is the same for each thread count.
const Pipeline = struct {
    gpa: Allocator,
    ctx: layer_mod.Context,
    slots: []Slot,
    n: usize,
    monitor: Monitor,
    /// True if the sink needs the path records.
    record: bool,
    /// See `Job.keep_memos`.
    keep_memos: bool,
    next: std.atomic.Value(usize) = .init(0),
    /// The number of layers with a dry run.
    dried: std.atomic.Value(usize) = .init(0),
    /// The next layer whose text a thread writes.
    next_text: std.atomic.Value(usize) = .init(0),
    /// The number of layers that the emitter has written out.
    emitted: std.atomic.Value(usize) = .init(0),
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
            // The text first: the emitter waits for it.
            if (!p.writeOne() and !p.planOne()) p.signal.wait(seen);
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
        slot.plan = layer_mod.plan(p.gpa, p.ctx, i) catch |e| {
            p.fail(e);
            return true;
        };
        if (!p.keep_memos and p.ctx.cache.len > i) {
            p.ctx.cache[i].deinit();
            p.ctx.cache[i] = .init(p.gpa);
        }
        slot.ready.store(i + 1, .release);
        p.signal.notify();
        return true;
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
        slot.written.store(i + 1, .release);
        p.signal.notify();
        return true;
    }

    fn text(p: *Pipeline, slot: *Slot) Error!void {
        var em = slot.start.?;
        em.w = &slot.text.writer;
        em.record = null;
        if (p.record) {
            try slot.records.ensureTotalCapacity(p.gpa, slot.plan.?.paths.items.len);
            em.record = &slot.records;
        }
        try em.layer(&slot.plan.?);
    }

    fn fail(p: *Pipeline, e: Error) void {
        _ = p.err_code.cmpxchgStrong(0, @intFromError(e), .acq_rel, .monotonic);
        p.signal.notify();
    }
};

/// A hash of all inputs of the outlines, except the mesh: the part height
/// and bottom, the placement, and the settings that pass 1 uses.
fn outlineKey(settings: Settings, height: f64, b: mesh_mod.Bounds3, dx: f64, dy: f64) u64 {
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
    return h.final();
}

/// Moves the outer boundaries of an outline by `xy`, and its holes by
/// `hole - xy` more (a positive `hole` makes the holes larger). A hole is a
/// clockwise loop.
fn compensate(gpa: Allocator, outline: Paths, xy: i64, hole: i64) Allocator.Error!Paths {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var outer: Paths = .empty;
    var holes: Paths = .empty;
    for (0..outline.count()) |i| {
        const poly = outline.get(i);
        if (geom.area2(poly) > 0) {
            try outer.append(a, poly);
        } else {
            // The hole as a counterclockwise area, so that a positive
            // offset makes it larger.
            const rev = try a.dupe(geom.Point, poly);
            std.mem.reverse(geom.Point, rev);
            try holes.append(a, rev);
        }
    }
    const grown = try offset_mod.offset(a, outer, xy, .{});
    if (holes.isEmpty()) return grown.clone(gpa);
    const hole_area = try offset_mod.offset(a, holes, hole - xy, .{});
    return clip.difference(gpa, grown, hole_area);
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

    // The time of layer 10, from its G1 moves: each move takes
    // distance / F.
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    var layer: i32 = -1;
    var x: f64 = 0;
    var y: f64 = 0;
    var f: f64 = 1;
    var t: f64 = 0;
    var max_f: f64 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ";LAYER:")) layer = try std.fmt.parseInt(i32, line[7..], 10);
        if (!std.mem.startsWith(u8, line, "G0 ") and !std.mem.startsWith(u8, line, "G1 ")) continue;
        var nx = x;
        var ny = y;
        var has_e = false;
        var tok = std.mem.tokenizeScalar(u8, line[3..], ' ');
        while (tok.next()) |w| {
            const v = std.fmt.parseFloat(f64, w[1..]) catch continue;
            switch (w[0]) {
                'X' => nx = v,
                'Y' => ny = v,
                'F' => f = v,
                'E' => has_e = true,
                else => {},
            }
        }
        if (layer == 10) {
            t += std.math.hypot(nx - x, ny - y) / (f / 60);
            if (has_e) max_f = @max(max_f, f);
        }
        x = nx;
        y = ny;
    }
    // The layer takes at least min_layer_time (6 s), minus rounding.
    try testing.expect(t > 5.5);
    // And the walls are slower than the full outer wall speed (68 mm/s).
    try testing.expect(max_f < 68 * 60);
    // The fan is at the maximum on these short layers.
    try testing.expect(std.mem.indexOf(u8, out.written(), "M106 S255") != null);
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
    const bad = [_]settings_mod.Override{.{ .z_min = 3, .z_max = 4, .name = "project.layer_height", .value = "0.1" }};
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

        var reuse = try Job.initReuse(gpa, &mesh, s, &.{}, .{}, &prev);
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
    var reuse = try Job.initReuse(gpa, &mesh, s, &o, .{}, &old);
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
