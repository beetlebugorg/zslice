//! The engine: runs all stages, from a mesh to G-code.
//!
//! 1. Resolve the settings (see `settings.zig`).
//! 2. Place the part: its bottom goes to z = 0, and (with `auto_center`)
//!    its center goes to the center of the bed.
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
const Mesh = mesh_mod.Mesh;
const Paths = geom.Paths;
const Settings = settings_mod.Settings;
const LayerPlan = layer_mod.LayerPlan;

pub const Stats = gcode.Stats;

pub const Error = error{
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
    threads: usize,
    layers: []slicer.Layer,
    outlines: []Paths,

    /// Steps 1 to 4.
    pub fn init(gpa: Allocator, mesh: *const Mesh, settings: Settings) Error!Job {
        // Step 1.
        const r = settings.resolve() catch return error.InvalidSettings;
        const threads = parallel.threadCount(settings.engine.threads);

        // Step 2.
        if (mesh.faces.items.len == 0) return error.EmptyMesh;
        const b = mesh.bounds();
        const height = b.max[2] - b.min[2];
        if (!(height > 0)) return error.EmptyMesh;
        const m = settings.machine;
        if (height > m.max_height) return error.PartTooLarge;
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (settings.project.auto_center) {
            dx = m.bed_size_x / 2 - (b.min[0] + b.max[0]) / 2;
            dy = m.bed_size_y / 2 - (b.min[1] + b.max[1]) / 2;
        }

        // Step 3.
        const layers = try slicer.layerTable(gpa, height, settings.project.first_layer_height, settings.project.layer_height);
        errdefer gpa.free(layers);
        if (layers.len == 0) return error.EmptyMesh;

        const outlines = try gpa.alloc(Paths, layers.len);
        for (outlines) |*o| o.* = .empty;
        errdefer {
            for (outlines) |*o| o.deinit(gpa);
            gpa.free(outlines);
        }

        // Step 4.
        var index = try slicer.FaceIndex.build(gpa, mesh, layers, b.min[2]);
        defer index.deinit(gpa);
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

            fn run(c: *const @This(), i: usize) anyerror!void {
                const o = try slicer.sliceAt(c.gpa, c.mesh, c.index.get(i), c.layers[i].sliceZ() + c.z_offset, c.tolerance, c.gap);
                for (o.points.items) |*p| {
                    p.x += c.dx;
                    p.y += c.dy;
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
        };
        parallel.forEach(threads, layers.len, &ctx, Pass1.run) catch |e| return @as(Error, @errorCast(e));

        return .{ .gpa = gpa, .resolved = r, .threads = threads, .layers = layers, .outlines = outlines };
    }

    pub fn deinit(self: *Job) void {
        for (self.outlines) |*o| o.deinit(self.gpa);
        self.gpa.free(self.outlines);
        self.gpa.free(self.layers);
    }

    pub fn layerCount(self: *const Job) usize {
        return self.layers.len;
    }

    fn planContext(self: *const Job) layer_mod.Context {
        return .{ .resolved = &self.resolved, .layers = self.layers, .outlines = self.outlines };
    }

    /// The plan of layer i. Call `deinit` on the result.
    pub fn planLayer(self: *const Job, i: usize) Allocator.Error!LayerPlan {
        return layer_mod.plan(self.gpa, self.planContext(), i);
    }

    /// Step 5.
    pub fn writeGcode(self: *const Job, out: *Writer) Error!Stats {
        const gpa = self.gpa;
        var em: gcode.Emitter = .init(out, &self.resolved);
        try em.begin(self.layers.len);

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
            const n = @min(batch, self.layers.len - start);
            const c: Pass2 = .{ .gpa = gpa, .ctx = self.planContext(), .plans = plans[0..n], .start = start };
            parallel.forEach(self.threads, n, &c, Pass2.run) catch |e| return @as(Error, @errorCast(e));
            for (plans[0..n]) |*p| {
                try em.layer(&p.*.?);
                p.*.?.deinit();
                p.* = null;
            }
        }
        try em.end();
        return em.stats;
    }
};

const testing = std.testing;

test "slice the demo part" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: Settings = .{};
    s.engine.threads = 4;
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
