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
    WriteFailed,
} || Allocator.Error;

/// Slices `mesh` and writes the G-code to `out`. `gpa` must be thread-safe
/// unless `settings.engine.threads` is 1. The function does not change the
/// mesh. It does not flush `out`.
pub fn slice(gpa: Allocator, mesh: *const Mesh, settings: Settings, out: *Writer) Error!Stats {
    var job = try Job.init(gpa, mesh, settings);
    defer job.deinit();
    return job.writeGcode(out);
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
    /// The regions of each layer (see layer.Regions), made when a plan
    /// needs them. `takeRegions` moves them from an older job.
    regions: []?layer_mod.Regions = &.{},
    /// A hash of the settings that change the regions (`regionKey`).
    region_key: u64 = 0,

    /// Steps 1 to 4.
    pub fn init(gpa: Allocator, mesh: *const Mesh, settings: Settings) Error!Job {
        return initWith(gpa, mesh, settings, .{});
    }

    /// `init`, with progress and cancel hooks. `writeGcode` uses the same
    /// hooks.
    pub fn initWith(gpa: Allocator, mesh: *const Mesh, settings: Settings, monitor: Monitor) Error!Job {
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

        // Step 3.
        const layers = try slicer.layerTable(gpa, height, settings.project.first_layer_height, settings.project.layer_height);
        // The part center on the bed: the center of the XY shrinkage scale.
        const center_x = (b.min[0] + b.max[0]) / 2 + dx;
        const center_y = (b.min[1] + b.max[1]) / 2 + dy;
        errdefer gpa.free(layers);
        if (layers.len == 0) return error.EmptyMesh;

        const outlines = try gpa.alloc(Paths, layers.len);
        for (outlines) |*o| o.* = .empty;
        errdefer {
            for (outlines) |*o| o.deinit(gpa);
            gpa.free(outlines);
        }

        // Step 4.
        var index = try slicer.FaceIndex.buildScaled(gpa, mesh, layers, b.min[2], f.shrinkage_z);
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
            .z_offset = b.min[2],
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

        // The support areas need the outlines of all layers.
        const sup = support_mod.compute(gpa, outlines, layers, &r, threads) catch |e| return @as(Error, @errorCast(e));

        const regs = try gpa.alloc(?layer_mod.Regions, layers.len);
        @memset(regs, null);
        return .{
            .gpa = gpa,
            .resolved = r,
            .monitor = monitor,
            .threads = threads,
            .layers = layers,
            .outlines = outlines,
            .support = sup,
            .regions = regs,
            .region_key = regionKey(settings),
        };
    }

    /// Moves the regions of `old` to this job if they are the same: the
    /// same mesh (the caller knows) and the same region settings. Then
    /// the plans of this job skip steps 1 to 4. Returns true if it moved
    /// them.
    pub fn takeRegions(self: *Job, old: *Job) bool {
        if (old.region_key != self.region_key or old.regions.len != self.regions.len) return false;
        for (self.regions, old.regions) |*mine, *theirs| {
            if (mine.*) |*m| m.deinit();
            mine.* = theirs.*;
            theirs.* = null;
        }
        return true;
    }

    pub fn deinit(self: *Job) void {
        for (self.regions) |*reg| if (reg.*) |*rg| rg.deinit();
        self.gpa.free(self.regions);
        if (self.support.len > 0) support_mod.deinitAll(self.gpa, self.support);
        for (self.outlines) |*o| o.deinit(self.gpa);
        self.gpa.free(self.outlines);
        self.gpa.free(self.layers);
    }

    pub fn layerCount(self: *const Job) usize {
        return self.layers.len;
    }

    fn planContext(self: *const Job) layer_mod.Context {
        return .{ .resolved = &self.resolved, .layers = self.layers, .outlines = self.outlines, .support = self.support, .cache = self.regions };
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
        const batch = @max(8, self.threads * 4);
        const plans = try gpa.alloc(?LayerPlan, batch);
        defer gpa.free(plans);
        @memset(plans, null);
        defer for (plans) |*p| if (p.*) |*lp| lp.deinit();

        const Pass2 = struct {
            gpa: Allocator,
            ctx: layer_mod.Context,
            plans: []?LayerPlan,
            start: usize,

            fn run(c: *const @This(), i: usize) anyerror!void {
                c.plans[i] = try layer_mod.plan(c.gpa, c.ctx, c.start + i);
            }
        };
        var start: usize = 0;
        while (start < self.layers.len) : (start += batch) {
            if (self.monitor.canceled()) return error.Canceled;
            const n = @min(batch, self.layers.len - start);
            const c: Pass2 = .{ .gpa = gpa, .ctx = self.planContext(), .plans = plans[0..n], .start = start };
            parallel.forEach(self.threads, n, &c, Pass2.run) catch |e| return @as(Error, @errorCast(e));
            for (plans[0..n]) |*p| {
                if (sink != null) {
                    record.clearRetainingCapacity();
                    try record.ensureTotalCapacity(gpa, p.*.?.paths.items.len);
                }
                try em.layer(&p.*.?);
                if (sink) |sk| sk.func(sk.ctx, &p.*.?, record.items) catch |e| return @as(Error, @errorCast(e));
                p.*.?.deinit();
                p.* = null;
            }
            reporter.step(n);
        }
        try em.end();
        return em.stats;
    }
};

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

/// The settings that do not change the regions of a layer (the walls, the
/// skin area, the sparse area): they act in later steps or only in the
/// G-code. A setting that is not in this list goes into `regionKey`. So a
/// missing name costs time (a new region pass), and never a wrong result.
const late_settings = [_][]const u8{
    // project: the fill, the speeds, ironing, travel, support, skirt
    "project.infill_density",           "project.infill_pattern",     "project.infill_angle",
    "project.infill_overlap",           "project.skin_overlap",       "project.ironing",
    "project.ironing_flow",             "project.ironing_spacing",    "project.ironing_inset",
    "project.ironing_speed",            "project.outer_wall_speed",   "project.inner_wall_speed",
    "project.skin_speed",               "project.infill_speed",       "project.first_layer_speed",
    "project.retract_min_travel",       "project.z_hop",              "project.seam",
    "project.support",                  "project.support_angle",      "project.support_density",
    "project.support_xy_gap",           "project.support_z_gap_layers", "project.support_interface_layers",
    "project.support_interface_density", "project.skirt_loops",       "project.skirt_distance",
    "project.skirt_layers",             "project.brim_width",
    // filament: all but the size compensation
    "filament.name",                    "filament.color",             "filament.diameter",
    "filament.density",                 "filament.nozzle_temp",       "filament.first_layer_nozzle_temp",
    "filament.bed_temp",                "filament.standby_temp",      "filament.max_flow",
    "filament.flow_ratio",              "filament.fan_speed",         "filament.fan_off_layers",
    "filament.fan_max_speed",           "filament.fan_boost_time",    "filament.min_layer_time",
    "filament.min_speed",               "filament.retract_ratio",
    // machine: motion, retraction, and G-code
    "machine.name",                     "machine.max_speed",          "machine.travel_speed",
    "machine.max_z_speed",              "machine.retract_length",     "machine.retract_speed",
    "machine.origin_x",                 "machine.origin_y",
    "machine.start_gcode",              "machine.end_gcode",          "machine.extruder",
    // engine
    "engine.threads",                   "engine.job_name",
};

fn isLate(comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    for (late_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// A hash of all settings that can change the regions of a layer.
pub fn regionKey(settings: Settings) u64 {
    var h = std.hash.Wyhash.init(0);
    inline for (@typeInfo(Settings).@"struct".fields) |g| {
        const group = @field(settings, g.name);
        inline for (@typeInfo(g.type).@"struct".fields) |f| {
            if (comptime isLate(g.name ++ "." ++ f.name)) continue;
            const v = @field(group, f.name);
            switch (@typeInfo(f.type)) {
                .float => h.update(std.mem.asBytes(&@as(u64, @bitCast(@as(f64, v))))),
                .int => h.update(std.mem.asBytes(&@as(u64, @intCast(v)))),
                .bool => h.update(&.{@intFromBool(v)}),
                .@"enum" => h.update(@tagName(v)),
                .pointer => h.update(v),
                else => @compileError("regionKey: add a case for " ++ f.name),
            }
            h.update(f.name);
        }
    }
    return h.final();
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

test "region key: late settings do not change it" {
    var a: Settings = .{};
    const k0 = regionKey(a);
    try a.set("project.infill_density", "0.5");
    try a.set("project.outer_wall_speed", "0.3");
    try a.set("filament.nozzle_temp", "230");
    try std.testing.expectEqual(k0, regionKey(a));
    try a.set("project.wall_count", "3");
    try std.testing.expect(k0 != regionKey(a));
}

test "late setting names exist" {
    const app_meta = @import("settings_meta.zig");
    for (late_settings) |n| {
        const found = for (app_meta.all) |m| {
            if (std.mem.eql(u8, m.name, n)) break true;
        } else false;
        if (!found) std.debug.print("late_settings: no setting {s}\n", .{n});
        try std.testing.expect(found);
    }
}

test "a job takes the regions of an older job, and the result is the same" {
    const gpa = std.testing.allocator;
    var mesh = try mesh_mod.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var s: Settings = .{};
    var old = try Job.init(gpa, &mesh, s);
    defer old.deinit();
    var sink_old: std.Io.Writer.Allocating = .init(gpa);
    defer sink_old.deinit();
    _ = try old.writeGcode(&sink_old.writer);
    try std.testing.expect(old.regions[10] != null);

    try s.set("project.infill_density", "0.35");
    var fresh = try Job.init(gpa, &mesh, s);
    defer fresh.deinit();
    var out_fresh: std.Io.Writer.Allocating = .init(gpa);
    defer out_fresh.deinit();
    _ = try fresh.writeGcode(&out_fresh.writer);

    var reuse = try Job.init(gpa, &mesh, s);
    defer reuse.deinit();
    try std.testing.expect(reuse.takeRegions(&old));
    try std.testing.expect(old.regions[10] == null);
    var out_reuse: std.Io.Writer.Allocating = .init(gpa);
    defer out_reuse.deinit();
    _ = try reuse.writeGcode(&out_reuse.writer);
    try std.testing.expectEqualStrings(out_fresh.written(), out_reuse.written());
}
