//! The app core: the state and the logic of the zslice app, for each
//! platform shell (GTK4 on Linux, SwiftUI on Apple, Win32 on Windows,
//! Kotlin on Android).
//!
//! A shell does only three things: it draws native widgets, it reads and
//! writes files, and it moves events to its UI thread. All other logic is
//! here, so that each shell behaves the same. `include/zslice-app.h` is the
//! C API, and `c_api.zig` has its exports.
//!
//! The core does no file I/O. The shell reads a model file and gives the
//! bytes to `loadStl`. It gets the G-code bytes from `gcode` and writes them
//! where the user chooses. Thus the core also works in a sandbox (iOS, a
//! browser) where the shell owns all file access.
//!
//! Threads. `startSlice` runs the slice on a worker thread. The core sends
//! events to the shell callback from that thread. The shell must move them
//! to its UI thread (g_idle_add, DispatchQueue.main, PostMessage, ...).
//! The results (stats, G-code, layer paths) are read only while the state
//! is `done`. The worker writes them, then it sets the state with release
//! order, and the reader checks the state with acquire order. So the code
//! needs no lock.
//!
//! Memory. After a slice, the app keeps the G-code and the layer outlines.
//! The paths of a layer for the preview are made when the shell asks for
//! that layer, in a few milliseconds. The app does not keep the paths of
//! all layers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("root.zig");
const meta = @import("settings_meta.zig");
const Settings = zs.Settings;

const has_threads = zs.parallel.has_threads;
/// A target without threads (wasm32-freestanding) slices on the calling
/// thread, and has no worker.
const Worker = if (has_threads) std.Thread else void;

pub const State = enum(u8) {
    /// No model.
    empty,
    /// A model, no slice result.
    ready,
    slicing,
    /// A slice result: stats, G-code, and layers.
    done,
    failed,
};

pub const Event = enum(c_int) {
    /// The slice progress changed. `progress` is 0 to 1.
    progress = 1,
    /// The slice is done.
    sliced = 2,
    /// The slice failed. `status` has the C status code.
    failed = 3,
    /// The slice was canceled.
    canceled = 4,
};

/// The shell callback. It runs on the worker thread.
pub const EventFn = *const fn (user: ?*anyopaque, event: c_int, progress: f64, status: c_int) callconv(.c) void;

pub const App = struct {
    gpa: Allocator,
    event_fn: ?EventFn,
    user: ?*anyopaque,

    mesh: ?zs.Mesh = null,
    model_name: []u8 = &.{},
    settings: Settings = .{},
    /// The memory for the string values of the settings. It only grows, so
    /// a copy of the settings stays valid while a slice uses it.
    strings: std.heap.ArenaAllocator,

    state: std.atomic.Value(State) = .init(.empty),
    cancel_flag: std.atomic.Value(bool) = .init(false),
    /// True while `requestSlice` stops an old slice: that slice sends no
    /// events, because a new slice replaces it.
    quiet: std.atomic.Value(bool) = .init(false),
    worker: ?Worker = null,

    // The results. The worker writes them before it sets the state to
    // `done` or `failed`.
    job: ?zs.Job = null,
    /// The job of the slice before, kept for its layer regions: if the new
    /// settings give the same regions (for example, only the infill
    /// density changed), the new slice takes them and skips the slow steps
    /// (see Job.takeRegions). Only the worker uses it while a slice runs.
    prev_job: ?zs.Job = null,
    gcode_bytes: []u8 = &.{},
    stats: zs.Stats = .{},
    part_box: [4]f64 = .{ 0, 0, 0, 0 },
    toolpaths: Toolpaths = .{},
    /// The strings of the last inspection (for the C API).
    inspect_arena: ?std.heap.ArenaAllocator = null,
    failure: anyerror = error.Unexpected,
    slice_settings: Settings = .{},

    pub fn create(gpa: Allocator, event_fn: ?EventFn, user: ?*anyopaque) Allocator.Error!*App {
        const app = try gpa.create(App);
        app.* = .{ .gpa = gpa, .event_fn = event_fn, .user = user, .strings = .init(gpa) };
        return app;
    }

    pub fn destroy(app: *App) void {
        if (app.inspect_arena) |*a| a.deinit();
        app.stopWorker();
        app.clearResults();
        app.dropPrevJob();
        if (app.mesh) |*m| m.deinit(app.gpa);
        app.gpa.free(app.model_name);
        app.strings.deinit();
        app.gpa.destroy(app);
    }

    pub fn getState(app: *const App) State {
        return app.state.load(.acquire);
    }

    /// Loads an STL model. It replaces the current model and stops a slice
    /// that runs.
    pub fn loadStl(app: *App, name: []const u8, bytes: []const u8) zs.mesh.Error!void {
        const m = try zs.Mesh.fromStl(app.gpa, bytes);
        const n = app.gpa.dupe(u8, name) catch |e| {
            var mm = m;
            mm.deinit(app.gpa);
            return e;
        };
        app.stopWorker();
        app.clearResults();
        // The regions of the old mesh are of no use for the new mesh.
        app.dropPrevJob();
        if (app.mesh) |*old| old.deinit(app.gpa);
        app.gpa.free(app.model_name);
        app.mesh = m;
        app.model_name = n;
        app.state.store(.ready, .release);
    }

    pub const ModelInfo = struct {
        triangles: usize,
        size: [3]f64,
    };

    pub fn modelInfo(app: *const App) ?ModelInfo {
        const m = app.mesh orelse return null;
        const b = m.bounds();
        return .{
            .triangles = m.faces.items.len,
            .size = .{ b.max[0] - b.min[0], b.max[1] - b.min[1], b.max[2] - b.min[2] },
        };
    }

    /// Sets a setting from text. A slice that runs keeps the settings that
    /// it started with. A done result stays until the next slice.
    pub fn setSetting(app: *App, name: []const u8, value: []const u8) Settings.SetError!void {
        const copy = app.strings.allocator().dupe(u8, value) catch return error.InvalidValue;
        var s = app.settings;
        try s.set(name, copy);
        app.settings = s;
    }

    /// Writes the value of a setting as text.
    pub fn getSetting(app: *const App, name: []const u8, w: *std.Io.Writer) (Settings.SetError || std.Io.Writer.Error)!void {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.UnknownSetting;
        inline for (@typeInfo(Settings).@"struct".fields) |g| {
            if (std.mem.eql(u8, g.name, name[0..dot])) {
                const group = @field(app.settings, g.name);
                inline for (@typeInfo(g.type).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, name[dot + 1 ..])) {
                        return writeValue(w, @field(group, f.name));
                    }
                }
            }
        }
        return error.UnknownSetting;
    }

    pub const StartError = error{ NoModel, Busy, ThreadSpawnFailed };

    /// Starts a slice on a worker thread. Events go to the callback.
    pub fn startSlice(app: *App) StartError!void {
        if (app.mesh == null) return error.NoModel;
        if (app.getState() == .slicing) return error.Busy;
        app.stopWorker();
        // Keep the last job for its regions, and free the rest.
        if (app.job) |j| {
            app.dropPrevJob();
            app.prev_job = j;
            app.job = null;
        }
        app.clearResults();
        app.slice_settings = app.settings;
        app.cancel_flag.store(false, .release);
        app.state.store(.slicing, .release);
        if (comptime !has_threads) {
            // No threads: slice now, on the calling thread.
            work(app);
            return;
        }
        app.worker = std.Thread.spawn(.{}, work, .{app}) catch {
            app.state.store(.ready, .release);
            return error.ThreadSpawnFailed;
        };
    }

    /// Starts a slice with the current settings. A slice that runs stops
    /// first, with no event. A shell calls this after each change of a
    /// setting or the model, so that the preview always shows the current
    /// settings. The old slice checks for a stop at each layer, so the wait
    /// is short.
    pub fn requestSlice(app: *App) StartError!void {
        if (app.mesh == null) return error.NoModel;
        app.quiet.store(true, .release);
        app.stopWorker();
        app.quiet.store(false, .release);
        if (app.getState() == .slicing) app.state.store(.ready, .release);
        return app.startSlice();
    }

    /// Asks a slice that runs to stop. The `canceled` event follows.
    pub fn cancel(app: *App) void {
        app.cancel_flag.store(true, .release);
    }

    fn stopWorker(app: *App) void {
        if (comptime !has_threads) return;
        if (app.worker) |t| {
            app.cancel_flag.store(true, .release);
            t.join();
            app.worker = null;
        }
    }

    /// Waits for the worker, with no cancel. For tests.
    fn stopWorkerForTest(app: *App) void {
        if (comptime !has_threads) return;
        if (app.worker) |t| {
            t.join();
            app.worker = null;
        }
    }

    fn dropPrevJob(app: *App) void {
        if (app.prev_job) |*j| j.deinit();
        app.prev_job = null;
    }

    /// A job that did not finish: its regions are still good for its
    /// settings, so keep it for the next slice.
    fn keepForRegions(app: *App, job: zs.Job) void {
        app.dropPrevJob();
        app.prev_job = job;
    }

    fn clearResults(app: *App) void {
        app.toolpaths.deinit(app.gpa);
        if (app.job) |*j| j.deinit();
        app.job = null;
        app.gpa.free(app.gcode_bytes);
        app.gcode_bytes = &.{};
        app.stats = .{};
    }

    fn emit(app: *App, event: Event, progress: f64, status: c_int) void {
        if (app.quiet.load(.acquire)) return;
        const f = app.event_fn orelse return;
        f(app.user, @intFromEnum(event), progress, status);
    }

    fn onProgress(ctx: ?*anyopaque, fraction: f64) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        app.emit(.progress, fraction, 0);
    }

    fn work(app: *App) void {
        const monitor: zs.engine.Monitor = .{ .ctx = app, .progress = onProgress, .cancel = &app.cancel_flag };
        var job = zs.Job.initWith(app.gpa, &app.mesh.?, app.slice_settings, monitor) catch |e| return app.finishFailed(e);
        if (app.prev_job) |*prev| {
            _ = job.takeRegions(prev);
            app.dropPrevJob();
        }
        var out: std.Io.Writer.Allocating = .init(app.gpa);
        var store: Toolpaths = .{ .gpa = app.gpa, .z_hop = @floatCast(app.slice_settings.project.z_hop) };
        const sink: zs.engine.Job.LayerSink = .{ .ctx = &store, .func = Toolpaths.addLayer };
        const stats = job.writeGcodeWith(&out.writer, sink) catch |e| {
            store.deinit(app.gpa);
            out.deinit();
            app.keepForRegions(job);
            return app.finishFailed(e);
        };
        const bytes = out.toOwnedSlice() catch |e| {
            store.deinit(app.gpa);
            out.deinit();
            job.deinit();
            return app.finishFailed(e);
        };

        var box = zs.geom.Box.empty;
        for (job.outlines) |o| {
            const b = o.bounds();
            if (b.isEmpty()) continue;
            box.extend(b.min);
            box.extend(b.max);
        }
        app.part_box = if (box.isEmpty()) .{ 0, 0, 0, 0 } else .{
            zs.geom.toMm(box.min.x), zs.geom.toMm(box.min.y),
            zs.geom.toMm(box.max.x), zs.geom.toMm(box.max.y),
        };
        app.job = job;
        app.toolpaths = store;
        app.gcode_bytes = bytes;
        app.stats = stats;
        app.state.store(.done, .release);
        app.emit(.sliced, 1, 0);
    }

    fn finishFailed(app: *App, e: anyerror) void {
        app.failure = e;
        if (e == error.Canceled) {
            app.state.store(.ready, .release);
            app.emit(.canceled, 0, 0);
            return;
        }
        app.state.store(.failed, .release);
        app.emit(.failed, 0, statusOf(e));
    }

    /// The G-code of the last slice, or null if there is no result.
    pub fn gcode(app: *const App) ?[]const u8 {
        if (app.getState() != .done) return null;
        return app.gcode_bytes;
    }

    pub fn result(app: *const App) ?zs.Stats {
        if (app.getState() != .done) return null;
        return app.stats;
    }

    pub fn layerCount(app: *const App) usize {
        if (app.getState() != .done) return 0;
        return app.job.?.layerCount();
    }

    /// The bounds of the sliced part on the bed: min x, min y, max x, max y
    /// in mm.
    pub fn partBounds(app: *const App) ?[4]f64 {
        if (app.getState() != .done) return null;
        return app.part_box;
    }

    /// The paths of all layers, for a 3D view.
    pub fn allToolpaths(app: *const App) ?*const Toolpaths {
        if (app.getState() != .done) return null;
        return &app.toolpaths;
    }

    /// The time, length, and plastic of each feature in the last slice.
    pub fn featureStats(app: *const App) ?[feature_names.len]FeatureStats {
        const t = app.allToolpaths() orelse return null;
        var out: [feature_names.len]FeatureStats = @splat(.{});
        const pts = t.points.items;
        for (t.path_features.items, 0..) |f, p| {
            const start: usize = if (p == 0) 0 else t.path_ends.items[p - 1];
            const end: usize = t.path_ends.items[p];
            var len: f64 = 0;
            var k = start;
            while (k + 1 < end) : (k += 1) len += std.math.hypot(@as(f64, pts[2 * k + 2] - pts[2 * k]), @as(f64, pts[2 * k + 3] - pts[2 * k + 1]));
            if (t.path_closed.items[p] != 0 and end - start > 2) {
                len += std.math.hypot(@as(f64, pts[2 * start] - pts[2 * (end - 1)]), @as(f64, pts[2 * start + 1] - pts[2 * (end - 1) + 1]));
            }
            const s = &out[f];
            s.time += t.path_end_time.items[p] - t.path_start_time.items[p];
            s.length += len;
            s.volume += len * t.path_area.items[p];
            s.paths += 1;
        }
        return out;
    }

    /// The layer of a path of the toolpaths.
    pub fn layerOfPath(app: *const App, path: usize) ?usize {
        const t = app.allToolpaths() orelse return null;
        if (path >= t.path_ends.items.len) return null;
        // The first layer whose end is after the path.
        var lo: usize = 0;
        var hi: usize = t.layer_ends.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (t.layer_ends.items[mid] <= path) lo = mid + 1 else hi = mid;
        }
        return if (lo < t.layer_ends.items.len) lo else null;
    }

    /// The path of layer `layer` nearest to (x, y) mm, within twice the line
    /// width, or null. For a click in a 2D layer view.
    pub fn pickInLayer(app: *const App, layer: usize, x: f64, y: f64) ?usize {
        const t = app.allToolpaths() orelse return null;
        if (layer >= t.layer_ends.items.len) return null;
        return app.nearestPath(layer, x, y, null, 2 * @as(f64, t.layer_width.items[layer]));
    }

    /// The path of `feature` nearest to (x, y) on `layer` (or on the last
    /// layer, if the part has fewer layers now), at any distance. A shell
    /// uses it to keep a selection after a new slice moves the line (for
    /// example, a new skirt distance moves the skirt).
    pub fn pickFeature(app: *const App, layer: usize, feature: u8, x: f64, y: f64) ?usize {
        const t = app.allToolpaths() orelse return null;
        if (t.layer_ends.items.len == 0) return null;
        return app.nearestPath(@min(layer, t.layer_ends.items.len - 1), x, y, feature, std.math.inf(f64));
    }

    fn nearestPath(app: *const App, layer: usize, x: f64, y: f64, feature: ?u8, limit: f64) ?usize {
        const t = app.allToolpaths() orelse return null;
        const p0: usize = if (layer == 0) 0 else t.layer_ends.items[layer - 1];
        var best: ?usize = null;
        var best_d = limit;
        const pts = t.points.items;
        for (p0..t.layer_ends.items[layer]) |pi| {
            if (feature) |f| if (t.path_features.items[pi] != f) continue;
            const start: usize = if (pi == 0) 0 else t.path_ends.items[pi - 1];
            const end: usize = t.path_ends.items[pi];
            if (end - start < 2) continue;
            const closed = t.path_closed.items[pi] != 0;
            const segs = end - start - 1 + @as(usize, @intFromBool(closed and end - start > 2));
            for (0..segs) |k| {
                const a = start + k;
                const b = if (a + 1 < end) a + 1 else start;
                const d = segmentDistance(x, y, pts[2 * a], pts[2 * a + 1], pts[2 * b], pts[2 * b + 1]);
                if (d < best_d) {
                    best_d = d;
                    best = pi;
                }
            }
        }
        return best;
    }

    /// The real values of one path, why they are what they are, and the
    /// settings that change them. The strings stay valid until the next
    /// call, the next slice, or `destroy`.
    pub fn inspect(app: *App, path: usize) error{ NoResult, OutOfRange, OutOfMemory }!Inspection {
        return app.inspectInner(path) catch |e| switch (e) {
            error.NoResult, error.OutOfRange => |x| x,
            else => error.OutOfMemory,
        };
    }

    fn inspectInner(app: *App, path: usize) !Inspection {
        const t = app.allToolpaths() orelse return error.NoResult;
        const layer = app.layerOfPath(path) orelse return error.OutOfRange;
        if (app.inspect_arena) |*a| a.deinit();
        app.inspect_arena = .init(app.gpa);
        const arena = app.inspect_arena.?.allocator();
        const r = &app.job.?.resolved;
        const s = r.settings;

        const feature: zs.settings.Feature = @enumFromInt(t.path_features.items[path]);
        const first = layer == 0;
        const h: f64 = t.layer_height.items[layer];
        const w: f64 = t.layer_width.items[layer];
        const area: f64 = t.path_area.items[path];
        const bead = zs.flow.beadWidth(area, h);
        var length: f64 = 0;
        {
            const start: usize = if (path == 0) 0 else t.path_ends.items[path - 1];
            const end: usize = t.path_ends.items[path];
            const pts = t.points.items;
            var k = start;
            while (k + 1 < end) : (k += 1) length += std.math.hypot(@as(f64, pts[2 * k + 2] - pts[2 * k]), @as(f64, pts[2 * k + 3] - pts[2 * k + 1]));
            if (t.path_closed.items[path] != 0 and end - start > 2) {
                length += std.math.hypot(@as(f64, pts[2 * start] - pts[2 * (end - 1)]), @as(f64, pts[2 * start + 1] - pts[2 * (end - 1) + 1]));
            }
        }
        const t0: f64 = t.path_start_time.items[path];
        const t1: f64 = t.path_end_time.items[path];
        const planned = r.speed(feature, w, h, first);
        const real = if (t1 > t0) length / (t1 - t0) else planned;

        var text: std.Io.Writer.Allocating = .init(arena);
        const out = &text.writer;
        const name = feature_names[@intFromEnum(feature)];
        try out.print("{s}, layer {d} of {d}, at z {d:.2} mm.\n\n", .{ name, layer + 1, t.layer_ends.items.len, t.layer_z.items[layer] });
        try out.print("The bead is {d:.3} mm wide and {d:.2} mm tall. The line width is {d:.3} mm. The cross section is {d:.4} mm\u{b2}.\n", .{ bead, h, w, area });
        try out.print("The path is {d:.1} mm long, and it uses {d:.2} mm\u{b3} of plastic.\n\n", .{ length, length * area });
        if (feature == .ironing) {
            try out.print("Planned speed: {d:.0} mm/s, the ironing speed ({d:.0} %) of the machine limit ({d:.0} mm/s). Ironing uses little plastic, so the flow limit does not apply.\n", .{ planned, s.project.ironing_speed * 100, s.machine.max_speed });
        } else {
            const bead_area = zs.flow.beadArea(w, h);
            const flow_limit = s.filament.max_flow / bead_area;
            const limit = @min(s.machine.max_speed, flow_limit);
            try out.print("Planned speed: {d:.0} mm/s. That is {d:.0} % (the speed setting) of {d:.0} mm/s: the lower of the machine limit ({d:.0} mm/s) and the flow limit ({d} mm\u{b3}/s / {d:.4} mm\u{b2} = {d:.0} mm/s).\n", .{ planned, planned / limit * 100, limit, s.machine.max_speed, s.filament.max_flow, bead_area, flow_limit });
        }
        if (real < planned * 0.98) {
            try out.print("Real speed: {d:.0} mm/s. The layer prints in less than the minimum layer time of the filament ({d} s), so it prints slower, to cool.\n", .{ real, s.filament.min_layer_time });
        } else {
            try out.print("Real speed: {d:.0} mm/s.\n", .{real});
        }
        try out.print("Plastic flow: {d:.1} mm\u{b3}/s.\n\n", .{real * area});
        try out.print("Printed from {d}:{d:0>2}:{d:0>2} to {d}:{d:0>2}:{d:0>2} after the start of the print.", .{
            hours(t0), minutes(t0), seconds(t0), hours(t1), minutes(t1), seconds(t1),
        });

        // The settings, in sections. A line "# Name" starts a section.
        var names: std.Io.Writer.Allocating = .init(arena);
        const nw = &names.writer;
        try nw.writeAll("# Speed\n");
        try nw.print("{s}\n", .{speedRatioSetting(feature, first)});
        try nw.writeAll("machine.max_speed\n");
        if (feature != .ironing) try nw.writeAll("filament.max_flow\n");
        for (cooling_speed_settings) |n| try nw.print("{s}\n", .{n});
        try nw.writeAll("# Shape\n");
        for (feature_settings[@intFromEnum(feature)]) |n| try nw.print("{s}\n", .{n});
        if (first) for (first_layer_settings) |n| try nw.print("{s}\n", .{n});
        try nw.writeAll("# Material\n");
        for (material_settings) |n| try nw.print("{s}\n", .{n});

        return .{
            .feature = feature,
            .layer = layer,
            .path = path,
            .z = t.layer_z.items[layer],
            .height = h,
            .line_width = w,
            .bead_width = bead,
            .length = length,
            .planned_speed = planned,
            .speed = real,
            .flow = real * area,
            .start_time = t0,
            .end_time = t1,
            .title = try arena.dupeZ(u8, name),
            .explain = try arena.dupeZ(u8, text.written()),
            .settings = try arena.dupeZ(u8, std.mem.trimEnd(u8, names.written(), "\n")),
        };
    }

    /// The paths of one layer, for a preview. Call `deinit` on the result.
    pub fn layerPaths(app: *const App, gpa: Allocator, layer: usize) error{ NoResult, OutOfRange, OutOfMemory }!LayerPaths {
        if (app.getState() != .done) return error.NoResult;
        const job = &app.job.?;
        if (layer >= job.layerCount()) return error.OutOfRange;
        var plan = try job.planLayer(layer);
        defer plan.deinit();
        return LayerPaths.fromPlan(gpa, &plan);
    }
};

/// The result of `App.inspect`.
pub const Inspection = struct {
    feature: zs.settings.Feature,
    layer: usize,
    path: usize,
    z: f64,
    height: f64,
    line_width: f64,
    bead_width: f64,
    length: f64,
    planned_speed: f64,
    speed: f64,
    flow: f64,
    start_time: f64,
    end_time: f64,
    title: [:0]const u8,
    /// The values and why, in plain words.
    explain: [:0]const u8,
    /// The setting names, one on each line.
    settings: [:0]const u8,
};

pub const feature_names = [_][]const u8{ "Outer wall", "Inner wall", "Skin", "Sparse infill", "Ironing", "Skirt or brim", "Support", "Support interface" };

/// The settings that change the shape and the place of each feature, in
/// the order of the Feature enum. The speed settings are in
/// `speedRatioSetting` and `cooling_speed_settings`.
const feature_settings = [_][]const []const u8{
    &.{ "project.wall_count", "project.seam", "project.line_width", "project.layer_height", "filament.xy_offset", "filament.hole_xy_offset" },
    &.{ "project.wall_count", "project.line_width", "project.layer_height" },
    &.{ "project.top_thickness", "project.bottom_thickness", "project.skin_overlap", "project.infill_angle", "project.line_width", "project.layer_height" },
    &.{ "project.infill_density", "project.infill_pattern", "project.infill_angle", "project.infill_overlap", "project.line_width", "project.layer_height" },
    &.{ "project.ironing", "project.ironing_flow", "project.ironing_spacing", "project.ironing_inset" },
    &.{ "project.skirt_loops", "project.skirt_distance", "project.skirt_layers", "project.brim_width", "project.line_width" },
    &.{ "project.support", "project.support_angle", "project.support_density", "project.support_xy_gap", "project.support_z_gap_layers" },
    &.{ "project.support_interface_layers", "project.support_interface_density", "project.support_z_gap_layers" },
};
const first_layer_settings = [_][]const u8{ "project.first_layer_height", "project.first_layer_line_width", "filament.first_layer_nozzle_temp", "project.first_layer_xy_offset" };
/// The settings that slow a layer down to cool it.
const cooling_speed_settings = [_][]const u8{ "filament.min_layer_time", "filament.min_speed" };
const material_settings = [_][]const u8{ "filament.flow_ratio", "filament.nozzle_temp", "filament.fan_speed" };

/// Settings that change every line: the bead size, the flow, the speed
/// limits, the cooling, and the place and size of the part.
const all_lines_settings = [_][]const u8{
    "project.layer_height",     "project.line_width",      "filament.flow_ratio",
    "filament.max_flow",        "machine.max_speed",       "machine.nozzle_diameter",
    "filament.min_layer_time",  "filament.min_speed",      "filament.shrinkage_xy",
    "filament.shrinkage_z",     "filament.xy_offset",      "project.placement",
    "engine.resolution",        "engine.gap_closing",       "filament.color",
    "machine.bed_size_x",       "machine.bed_size_y",
};

/// What a setting changes in the toolpaths.
pub const SettingEffect = struct {
    /// A bit for each feature (1 << Feature) whose lines the setting
    /// changes. 0: the setting changes no line, only the G-code (for
    /// example temperatures, retraction, start code) or nothing visible.
    features: u32 = 0,
    /// The setting changes only the lines of the first layer.
    first_layer_only: bool = false,
    /// For a setting with no visible effect: what it changes, and how to
    /// see it.
    note: [:0]const u8 = "",
};

/// Marks that the previews draw for settings with no line of their own,
/// in the bits after the features (see SettingEffect.features).
pub const mark_seam: u32 = 1 << 8;
/// The travel moves between the paths.
pub const mark_travel: u32 = 1 << 9;
/// The retractions (at the start of a retracted travel).
pub const mark_retract: u32 = 1 << 10;

/// Settings whose effect is a mark: the seam points, the travel moves, and
/// the retractions.
const mark_settings = [_]struct { []const u8, u32 }{
    .{ "project.seam", mark_seam },
    .{ "project.retract_min_travel", mark_travel | mark_retract },
    .{ "project.z_hop", mark_travel | mark_retract },
    .{ "machine.travel_speed", mark_travel },
    .{ "machine.retract_length", mark_retract | mark_travel },
    .{ "machine.retract_speed", mark_retract | mark_travel },
    .{ "filament.retract_ratio", mark_retract | mark_travel },
};

/// The settings that change no line and no mark in the preview, with what
/// they change. A test checks that each setting has an effect or a note,
/// so a new setting gets one of them.
const preview_notes = [_]struct { []const u8, [:0]const u8 }{
    .{ "machine.name", "The name of the printer, for the profiles and the start G-code." },
    .{ "machine.max_height", "A check: a part higher than this does not slice." },
    .{ "machine.max_z_speed", "The speed of the Z moves between layers. It changes the print time (see the status bar)." },
    .{ "machine.start_gcode", "The G-code before the print: heating, homing, and the purge line." },
    .{ "machine.end_gcode", "The G-code after the print." },
    .{ "machine.extruder", "The extruder type, for the retraction defaults." },
    .{ "machine.origin_x", "The G-code position of the bed corner. The preview shows bed coordinates, so it does not change." },
    .{ "machine.origin_y", "The G-code position of the bed corner. The preview shows bed coordinates, so it does not change." },
    .{ "filament.name", "The name of the filament, for the profiles and the start G-code." },
    .{ "filament.diameter", "The filament diameter: it changes how far the extruder pushes, not the lines." },
    .{ "filament.density", "The weight of the plastic, for the filament weight in the status bar." },
    .{ "filament.nozzle_temp", "A G-code temperature. It changes no line." },
    .{ "filament.first_layer_nozzle_temp", "A G-code temperature for the first layer. It changes no line." },
    .{ "filament.bed_temp", "A G-code temperature. It changes no line." },
    .{ "filament.standby_temp", "A G-code temperature. It changes no line." },
    .{ "filament.fan_speed", "The part cooling fan in the G-code. It changes no line." },
    .{ "filament.fan_off_layers", "The fan in the G-code on the first layers. It changes no line." },
    .{ "filament.fan_max_speed", "The fan in the G-code on short layers. It changes no line." },
    .{ "filament.fan_boost_time", "The fan in the G-code on short layers. It changes no line." },
    .{ "engine.threads", "The number of threads of the slicer. The result is the same." },
    .{ "engine.job_name", "The name of the print, for the start G-code." },
};

fn noteOf(name: []const u8) [:0]const u8 {
    for (preview_notes) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    return "";
}

/// The lines that a setting changes. It uses the same tables as the
/// inspector, so a click on a line and a look at a setting agree.
pub fn settingEffect(name: []const u8) SettingEffect {
    const all: u32 = (1 << feature_names.len) - 1;
    const no_ironing = all & ~@as(u32, 1 << @intFromEnum(zs.settings.Feature.ironing));
    var e: SettingEffect = .{};
    // A mark setting (the seam, travel, retraction) shows its marks only:
    // the lines around them would hide them.
    for (mark_settings) |m| if (std.mem.eql(u8, m[0], name)) return .{ .features = m[1] };
    for (all_lines_settings) |n| if (std.mem.eql(u8, n, name)) {
        e.features = all;
    };
    // The flow limit does not apply to ironing.
    if (std.mem.eql(u8, name, "filament.max_flow")) e.features = no_ironing;
    for (feature_settings, 0..) |list, i| for (list) |n| {
        if (std.mem.eql(u8, n, name)) e.features |= @as(u32, 1) << @intCast(i);
    };
    for (0..feature_names.len) |i| {
        if (std.mem.eql(u8, speedRatioSetting(@enumFromInt(i), false), name)) e.features |= @as(u32, 1) << @intCast(i);
    }
    if (e.features != 0) return e;
    for (first_layer_settings) |n| if (std.mem.eql(u8, n, name)) return .{ .features = all, .first_layer_only = true };
    if (std.mem.eql(u8, name, "project.first_layer_speed")) return .{ .features = no_ironing, .first_layer_only = true };
    e.note = noteOf(name);
    return e;
}

test "each setting shows in the preview, or has a note" {
    for (settings_info) |s| {
        const e = settingEffect(s.name);
        if (e.features == 0 and e.note.len == 0) {
            std.debug.print("{s} changes nothing in the preview: give it a line, a mark, or a note in src/app.zig\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "the seam setting shows the seam marks only" {
    try testing.expectEqual(mark_seam, settingEffect("project.seam").features);
}

test "setting effects" {
    const bit = struct {
        fn f(x: zs.settings.Feature) u32 {
            return @as(u32, 1) << @intCast(@intFromEnum(x));
        }
    }.f;
    try testing.expectEqual(bit(.outer_wall), settingEffect("project.outer_wall_speed").features);
    // The skirt uses the inner wall speed.
    try testing.expectEqual(bit(.inner_wall) | bit(.skirt), settingEffect("project.inner_wall_speed").features);
    try testing.expect(settingEffect("project.first_layer_height").first_layer_only);
    try testing.expectEqual(@as(u32, 0xff), settingEffect("project.layer_height").features);
    // A temperature changes no line.
    try testing.expectEqual(@as(u32, 0), settingEffect("filament.bed_temp").features);
    try testing.expectEqual(bit(.ironing), settingEffect("project.ironing_spacing").features & bit(.ironing));
}

/// The print time, the length, and the plastic of the lines of one
/// feature.
pub const FeatureStats = struct {
    time: f64 = 0,
    length: f64 = 0,
    volume: f64 = 0,
    paths: usize = 0,
};

/// The speed ratio that a line of `feature` uses (see Resolved.speed).
fn speedRatioSetting(feature: zs.settings.Feature, first_layer: bool) []const u8 {
    if (feature == .ironing) return "project.ironing_speed";
    if (first_layer) return "project.first_layer_speed";
    return switch (feature) {
        .outer_wall => "project.outer_wall_speed",
        .inner_wall, .skirt => "project.inner_wall_speed",
        .skin, .support_interface => "project.skin_speed",
        .infill, .support => "project.infill_speed",
        .ironing => unreachable,
    };
}

test "each inspector setting exists" {
    const has = struct {
        fn f(name: []const u8) bool {
            for (meta.all) |m| if (std.mem.eql(u8, m.name, name)) return true;
            return false;
        }
    }.f;
    for (feature_settings) |list| for (list) |n| try std.testing.expect(has(n));
    for (first_layer_settings ++ cooling_speed_settings ++ material_settings) |n| try std.testing.expect(has(n));
    for (0..8) |i| for ([_]bool{ false, true }) |first| try std.testing.expect(has(speedRatioSetting(@enumFromInt(i), first)));
}

fn hours(t: f64) u64 {
    return @intFromFloat(@floor(t / 3600));
}
fn minutes(t: f64) u64 {
    return @as(u64, @intFromFloat(@floor(t / 60))) % 60;
}
fn seconds(t: f64) u64 {
    return @as(u64, @intFromFloat(@floor(t))) % 60;
}

/// The distance from (x, y) to the segment from (ax, ay) to (bx, by).
fn segmentDistance(x: f64, y: f64, ax: f32, ay: f32, bx: f32, by: f32) f64 {
    const dx: f64 = bx - ax;
    const dy: f64 = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1);
    return std.math.hypot(x - (ax + t * dx), y - (ay + t * dy));
}

/// The paths of all layers of a slice, for a 3D view. The arrays are flat,
/// in mm, and in print order:
/// - path i has the points from path_ends[i - 1] to path_ends[i] (x, y
///   pairs in `points`), the feature path_features[i], and is closed if
///   path_closed[i] is 1;
/// - layer j has the paths from layer_ends[j - 1] to layer_ends[j], at the
///   height layer_z[j], with the layer height layer_height[j] and the line
///   width layer_width[j].
pub const Toolpaths = struct {
    points: std.ArrayList(f32) = .empty,
    path_ends: std.ArrayList(u32) = .empty,
    path_features: std.ArrayList(u8) = .empty,
    path_closed: std.ArrayList(u8) = .empty,
    /// The cross-section area (mm^2) of the bead of each path.
    path_area: std.ArrayList(f32) = .empty,
    /// The print time (s) from the start to the start of the extrusion of
    /// each path, and to its end.
    path_start_time: std.ArrayList(f32) = .empty,
    path_end_time: std.ArrayList(f32) = .empty,
    /// 1 if the travel to the path retracted the filament.
    path_retract: std.ArrayList(u8) = .empty,
    /// The nozzle lift of a retracted travel (project.z_hop), in mm.
    z_hop: f32 = 0,
    layer_ends: std.ArrayList(u32) = .empty,
    layer_z: std.ArrayList(f32) = .empty,
    layer_height: std.ArrayList(f32) = .empty,
    layer_width: std.ArrayList(f32) = .empty,
    gpa: ?Allocator = null,

    pub fn deinit(t: *Toolpaths, gpa: Allocator) void {
        t.points.deinit(gpa);
        t.path_ends.deinit(gpa);
        t.path_features.deinit(gpa);
        t.path_closed.deinit(gpa);
        t.path_area.deinit(gpa);
        t.path_start_time.deinit(gpa);
        t.path_end_time.deinit(gpa);
        t.path_retract.deinit(gpa);
        t.layer_ends.deinit(gpa);
        t.layer_z.deinit(gpa);
        t.layer_height.deinit(gpa);
        t.layer_width.deinit(gpa);
        t.* = .{};
    }

    /// A Job.LayerSink function. `ctx` is a *Toolpaths whose `gpa` is set.
    fn addLayer(ctx: ?*anyopaque, plan: *const zs.layer.LayerPlan, infos: []const zs.gcode.PathInfo) anyerror!void {
        const t: *Toolpaths = @ptrCast(@alignCast(ctx.?));
        const gpa = t.gpa.?;
        for (plan.points.points.items) |p| {
            try t.points.append(gpa, @floatCast(zs.geom.toMm(p.x)));
            try t.points.append(gpa, @floatCast(zs.geom.toMm(p.y)));
        }
        const base: u32 = if (t.path_ends.items.len == 0) 0 else t.path_ends.items[t.path_ends.items.len - 1];
        for (plan.points.ends.items) |e| try t.path_ends.append(gpa, base + e);
        for (plan.paths.items, infos) |p, info| {
            try t.path_features.append(gpa, @intFromEnum(p.feature));
            try t.path_closed.append(gpa, @intFromBool(p.closed));
            try t.path_area.append(gpa, @floatCast(info.area));
            try t.path_start_time.append(gpa, @floatCast(info.start_time));
            try t.path_end_time.append(gpa, @floatCast(info.end_time));
            try t.path_retract.append(gpa, @intFromBool(info.retracted));
        }
        try t.layer_ends.append(gpa, @intCast(t.path_ends.items.len));
        try t.layer_z.append(gpa, @floatCast(plan.z));
        try t.layer_height.append(gpa, @floatCast(plan.height));
        try t.layer_width.append(gpa, @floatCast(plan.width));
    }
};

/// The paths of one layer in flat arrays of floats, in mm, ready to draw.
pub const LayerPaths = struct {
    gpa: Allocator,
    /// x, y pairs.
    points: []f32,
    /// The end of each path in `points`, in points (not floats).
    ends: []u32,
    features: []u8,
    closed: []u8,
    outline_points: []f32,
    outline_ends: []u32,
    z: f32,
    height: f32,
    width: f32,

    fn fromPlan(gpa: Allocator, plan: *const zs.layer.LayerPlan) Allocator.Error!LayerPaths {
        var lp: LayerPaths = .{
            .gpa = gpa,
            .points = &.{},
            .ends = &.{},
            .features = &.{},
            .closed = &.{},
            .outline_points = &.{},
            .outline_ends = &.{},
            .z = @floatCast(plan.z),
            .height = @floatCast(plan.height),
            .width = @floatCast(plan.width),
        };
        errdefer lp.deinit();
        lp.points = try toFloats(gpa, plan.points.points.items);
        lp.ends = try gpa.dupe(u32, plan.points.ends.items);
        lp.features = try gpa.alloc(u8, plan.paths.items.len);
        lp.closed = try gpa.alloc(u8, plan.paths.items.len);
        for (plan.paths.items, 0..) |p, i| {
            lp.features[i] = @intFromEnum(p.feature);
            lp.closed[i] = @intFromBool(p.closed);
        }
        lp.outline_points = try toFloats(gpa, plan.outline.points.items);
        lp.outline_ends = try gpa.dupe(u32, plan.outline.ends.items);
        return lp;
    }

    pub fn deinit(lp: *LayerPaths) void {
        lp.gpa.free(lp.points);
        lp.gpa.free(lp.ends);
        lp.gpa.free(lp.features);
        lp.gpa.free(lp.closed);
        lp.gpa.free(lp.outline_points);
        lp.gpa.free(lp.outline_ends);
    }
};

fn toFloats(gpa: Allocator, pts: []const zs.geom.Point) Allocator.Error![]f32 {
    const out = try gpa.alloc(f32, pts.len * 2);
    for (pts, 0..) |p, i| {
        out[2 * i] = @floatCast(zs.geom.toMm(p.x));
        out[2 * i + 1] = @floatCast(zs.geom.toMm(p.y));
    }
    return out;
}

fn writeValue(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(v))) {
        .float, .int => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .@"enum" => try w.writeAll(@tagName(v)),
        .pointer => try w.writeAll(v),
        else => @compileError("unsupported setting type"),
    }
}

/// The C status code of an error. The codes are in include/zslice.h.
pub fn statusOf(e: anyerror) c_int {
    return switch (e) {
        error.OutOfMemory => 1,
        error.InvalidStl, error.InvalidMesh => 3,
        error.EmptyMesh => 4,
        error.UnknownSetting => 5,
        error.InvalidValue => 6,
        error.InvalidSettings => 7,
        error.PartTooLarge => 8,
        error.WriteFailed => 9,
        error.Canceled => 10,
        else => 2,
    };
}

// ---------------------------------------------------------------------------
// Setting descriptions, for a settings panel.

pub const SettingKind = enum(c_int) { number = 0, integer = 1, boolean = 2, choice = 3, text = 4 };

pub const SettingInfo = struct {
    /// "group.name"
    name: [:0]const u8,
    group: [:0]const u8,
    /// The section in the group, for example "Walls". Can be empty.
    section: [:0]const u8,
    /// A label for the UI, from the name: "nozzle_temp" -> "Nozzle temp".
    label: [:0]const u8,
    /// The help text, from the doc comment of the field.
    doc: [:0]const u8,
    kind: SettingKind,
    /// For a choice: the choices, one on each line.
    choices: [:0]const u8,
    /// The unit of a number, for the UI: "mm", "mm/s", "°C", and so on.
    /// "%" marks a ratio: the value 0.5 is 50 %, and a UI shows the value
    /// times 100. Empty for the other kinds.
    unit: [:0]const u8 = "",
    /// The built-in default value, as text (as `getSetting` writes it).
    default_value: [:0]const u8 = "",
    /// A useful range for a slider, in the units of the value (a ratio
    /// from 0 to 1, not a percentage). min == max: no slider. A value out
    /// of the range is still valid; the slider only covers the usual
    /// values.
    slider_min: f64 = 0,
    slider_max: f64 = 0,
    /// The step of the slider, in the units of the value.
    slider_step: f64 = 0,
    /// The hard limits (see settings.limits); min == max: none.
    limit_min: f64 = 0,
    limit_max: f64 = 0,
    /// For text: true if the value can have more than one line.
    multiline: bool,
};

pub const settings_info: []const SettingInfo = blk: {
    // The text of the float defaults takes many comptime steps.
    @setEvalBranchQuota(2_000_000);
    var list: []const SettingInfo = &.{};
    for (@typeInfo(Settings).@"struct".fields) |g| {
        for (@typeInfo(g.type).@"struct".fields) |f| {
            const name = std.fmt.comptimePrint("{s}.{s}", .{ g.name, f.name });
            const m = findMeta(name);
            const kind: SettingKind = switch (@typeInfo(f.type)) {
                .float => .number,
                .int => .integer,
                .bool => .boolean,
                .@"enum" => .choice,
                .pointer => .text,
                else => @compileError("unsupported setting type"),
            };
            var choices: []const u8 = "";
            if (kind == .choice) {
                for (@typeInfo(f.type).@"enum".fields, 0..) |e, i| {
                    choices = choices ++ (if (i == 0) "" else "\n") ++ e.name;
                }
            }
            list = list ++ [_]SettingInfo{.{
                .name = name,
                .group = std.fmt.comptimePrint("{s}", .{g.name}),
                .section = std.fmt.comptimePrint("{s}", .{m.section}),
                .label = labelOf(f.name),
                .doc = std.fmt.comptimePrint("{s}", .{m.doc}),
                .kind = kind,
                .choices = std.fmt.comptimePrint("{s}", .{choices}),
                .multiline = std.mem.endsWith(u8, f.name, "gcode"),
                .unit = unitOf(name),
                .default_value = defaultText(g.type, f.name),
                .slider_min = sliderOf(name)[0],
                .slider_max = sliderOf(name)[1],
                .slider_step = sliderOf(name)[2],
                .limit_min = (zs.settings.limitOf(name) orelse [2]f64{ 0, 0 })[0],
                .limit_max = (zs.settings.limitOf(name) orelse [2]f64{ 0, 0 })[1],
            }};
        }
    }
    break :blk list;
};

/// The unit of each number setting. A test checks that each number has
/// one, so a new setting needs a line here.
const units = [_][2][]const u8{
    // machine
    .{ "machine.bed_size_x", "mm" },           .{ "machine.bed_size_y", "mm" },
    .{ "machine.origin_x", "mm" },             .{ "machine.origin_y", "mm" },
    .{ "machine.max_height", "mm" },           .{ "machine.nozzle_diameter", "mm" },
    .{ "machine.max_speed", "mm/s" },          .{ "machine.travel_speed", "mm/s" },
    .{ "machine.max_z_speed", "mm/s" },        .{ "machine.retract_length", "mm" },
    .{ "machine.retract_speed", "mm/s" },
    // filament
    .{ "filament.diameter", "mm" },            .{ "filament.density", "g/cm\u{b3}" },
    .{ "filament.nozzle_temp", "\u{b0}C" },    .{ "filament.first_layer_nozzle_temp", "\u{b0}C" },
    .{ "filament.bed_temp", "\u{b0}C" },       .{ "filament.standby_temp", "\u{b0}C" },
    .{ "filament.max_flow", "mm\u{b3}/s" },    .{ "filament.flow_ratio", "%" },
    .{ "filament.fan_speed", "%" },            .{ "filament.fan_off_layers", "layers" },
    .{ "filament.fan_max_speed", "%" },        .{ "filament.fan_boost_time", "s" },
    .{ "filament.min_layer_time", "s" },       .{ "filament.min_speed", "mm/s" },
    .{ "filament.shrinkage_xy", "%" },         .{ "filament.shrinkage_z", "%" },
    .{ "filament.xy_offset", "mm" },           .{ "filament.hole_xy_offset", "mm" },
    .{ "filament.retract_ratio", "%" },
    // project
    .{ "project.layer_height", "mm" },         .{ "project.first_layer_height", "mm" },
    .{ "project.line_width", "mm" },           .{ "project.first_layer_line_width", "mm" },
    .{ "project.wall_count", "walls" },        .{ "project.top_thickness", "mm" },
    .{ "project.bottom_thickness", "mm" },     .{ "project.skin_overlap", "%" },
    .{ "project.infill_density", "%" },        .{ "project.infill_angle", "\u{b0}" },
    .{ "project.infill_overlap", "%" },        .{ "project.ironing_flow", "%" },
    .{ "project.ironing_spacing", "mm" },      .{ "project.ironing_inset", "mm" },
    .{ "project.ironing_speed", "%" },         .{ "project.outer_wall_speed", "%" },
    .{ "project.inner_wall_speed", "%" },      .{ "project.skin_speed", "%" },
    .{ "project.infill_speed", "%" },          .{ "project.first_layer_speed", "%" },
    .{ "project.retract_min_travel", "mm" },   .{ "project.z_hop", "mm" },
    .{ "project.support_angle", "\u{b0}" },    .{ "project.support_density", "%" },
    .{ "project.support_xy_gap", "mm" },       .{ "project.support_z_gap_layers", "layers" },
    .{ "project.support_interface_layers", "layers" }, .{ "project.support_interface_density", "%" },
    .{ "project.skirt_loops", "loops" },       .{ "project.skirt_distance", "mm" },
    .{ "project.skirt_layers", "layers" },     .{ "project.brim_width", "mm" },
    .{ "project.first_layer_xy_offset", "mm" },
    // engine
    .{ "engine.resolution", "mm" },            .{ "engine.gap_closing", "mm" },
    .{ "engine.threads", "threads" },
};

/// The slider ranges: the usual values of the settings that a user tunes
/// by eye, and the step that people use (a layer height of 0.28 mm, not
/// 0.281 mm). A test checks that each name exists.
const sliders = [_]struct { []const u8, f64, f64, f64 }{
    .{ "project.infill_density", 0, 1, 0.01 },          .{ "project.outer_wall_speed", 0.05, 1, 0.01 },
    .{ "project.inner_wall_speed", 0.05, 1, 0.01 },     .{ "project.skin_speed", 0.05, 1, 0.01 },
    .{ "project.infill_speed", 0.05, 1, 0.01 },         .{ "project.first_layer_speed", 0.05, 1, 0.01 },
    .{ "project.ironing_speed", 0.05, 1, 0.01 },        .{ "project.ironing_flow", 0, 0.3, 0.01 },
    .{ "project.ironing_spacing", 0.05, 0.5, 0.01 },    .{ "project.ironing_inset", 0, 2, 0.1 },
    .{ "project.skin_overlap", 0, 0.5, 0.01 },          .{ "project.infill_overlap", 0, 0.5, 0.01 },
    .{ "project.support_density", 0.05, 0.5, 0.01 },    .{ "project.support_interface_density", 0.1, 1, 0.05 },
    .{ "project.support_angle", 0, 89, 1 },          .{ "project.wall_count", 0, 8, 1 },
    .{ "project.top_thickness", 0, 3, 0.1 },           .{ "project.bottom_thickness", 0, 3, 0.1 },
    .{ "project.infill_angle", 0, 180, 5 },          .{ "project.brim_width", 0, 20, 0.5 },
    .{ "project.skirt_loops", 0, 10, 1 },            .{ "project.skirt_distance", 0, 20, 0.5 },
    .{ "project.layer_height", 0.05, 0.4, 0.01 },       .{ "filament.flow_ratio", 0.8, 1.2, 0.01 },
    .{ "filament.fan_speed", 0, 1, 0.05 },              .{ "filament.fan_max_speed", 0, 1, 0.05 },
    .{ "filament.nozzle_temp", 160, 300, 5 },        .{ "filament.first_layer_nozzle_temp", 160, 300, 5 },
    .{ "filament.bed_temp", 0, 120, 5 },             .{ "filament.min_layer_time", 0, 30, 1 },
    .{ "project.first_layer_height", 0.1, 0.5, 0.01 },  .{ "project.line_width", 0, 1, 0.01 },
    .{ "project.first_layer_line_width", 0, 1.2, 0.01 }, .{ "project.support_xy_gap", 0, 2, 0.05 },
    .{ "project.support_z_gap_layers", 0, 3, 1 },    .{ "project.support_interface_layers", 0, 5, 1 },
    .{ "project.skirt_layers", 0, 5, 1 },            .{ "project.retract_min_travel", 0, 10, 0.5 },
    .{ "project.z_hop", 0, 1, 0.05 },                   .{ "project.first_layer_xy_offset", -0.5, 0.5, 0.01 },
    .{ "filament.xy_offset", -0.3, 0.3, 0.01 },         .{ "filament.hole_xy_offset", -0.3, 0.3, 0.01 },
    .{ "filament.shrinkage_xy", 0.99, 1.02, 0.001 },     .{ "filament.shrinkage_z", 0.99, 1.02, 0.001 },
    .{ "filament.retract_ratio", 0, 2, 0.05 },          .{ "filament.fan_off_layers", 0, 5, 1 },
    .{ "filament.fan_boost_time", 0, 30, 1 },        .{ "filament.min_speed", 5, 50, 1 },
    .{ "filament.max_flow", 2, 40, 0.5 },              .{ "filament.standby_temp", 0, 250, 5 },
    .{ "machine.max_speed", 20, 500, 5 },            .{ "machine.travel_speed", 20, 500, 5 },
    .{ "machine.max_z_speed", 1, 30, 1 },            .{ "machine.retract_length", 0, 8, 0.1 },
    .{ "machine.retract_speed", 10, 80, 5 },         .{ "machine.nozzle_diameter", 0.2, 1.2, 0.05 },
    .{ "engine.gap_closing", 0, 3, 0.1 },
};

fn sliderOf(comptime name: []const u8) [3]f64 {
    @setEvalBranchQuota(100_000);
    for (sliders) |sl| if (std.mem.eql(u8, sl[0], name)) return .{ sl[1], sl[2], sl[3] };
    return .{ 0, 0, 0 };
}

test "each slider is for a number setting" {
    for (sliders) |sl| {
        const info = for (settings_info) |s| {
            if (std.mem.eql(u8, s.name, sl[0])) break s;
        } else return error.TestUnexpectedResult;
        try testing.expect(info.kind == .number or info.kind == .integer);
        try testing.expect(sl[1] < sl[2]);
        // A few steps at least.
        try testing.expect(sl[3] > 0 and sl[3] <= (sl[2] - sl[1]) / 3);
        // The usual values are in the hard limits.
        try testing.expect(sl[1] >= info.limit_min and sl[2] <= info.limit_max);
    }
}

/// The default of field `name` of the settings group T, as text.
fn defaultText(comptime T: type, comptime name: []const u8) [:0]const u8 {
    const d = @field(@as(T, .{}), name);
    return switch (@typeInfo(@TypeOf(d))) {
        .float, .int => std.fmt.comptimePrint("{d}", .{d}),
        .bool => if (d) "true" else "false",
        .@"enum" => std.fmt.comptimePrint("{s}", .{@tagName(d)}),
        .pointer => std.fmt.comptimePrint("{s}", .{d}),
        else => "",
    };
}

fn unitOf(comptime name: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    for (units) |u| if (std.mem.eql(u8, u[0], name)) return std.fmt.comptimePrint("{s}", .{u[1]});
    return "";
}

test "each number setting has a unit" {
    for (settings_info) |s| {
        if ((s.kind == .number or s.kind == .integer) and s.unit.len == 0) {
            std.debug.print("no unit for {s}: add it to `units` in src/app.zig\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
    for (units) |u| try testing.expect(for (settings_info) |s| {
        if (std.mem.eql(u8, s.name, u[0])) break true;
    } else false);
}

fn findMeta(comptime name: []const u8) meta.Meta {
    @setEvalBranchQuota(100_000);
    for (meta.all) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return .{ .name = name, .section = "", .doc = "" };
}

fn labelOf(comptime field: []const u8) [:0]const u8 {
    var out: [field.len:0]u8 = undefined;
    for (field, 0..) |c, i| {
        out[i] = if (c == '_') ' ' else if (i == 0) std.ascii.toUpper(c) else c;
    }
    const final = out;
    return &final;
}

// ---------------------------------------------------------------------------
// Licenses, for an About or Licenses screen.

pub const License = struct {
    name: [:0]const u8,
    license: [:0]const u8,
    text: [:0]const u8,
};

/// zslice and the components in its binaries. The texts come from LICENSE
/// and licenses/ (see build.zig). A shell adds the components that only it
/// links, for example GTK.
pub const licenses = [_]License{
    .{ .name = "zslice", .license = "AGPL-3.0-or-later", .text = @embedFile("license_zslice") },
    .{ .name = "Zig standard library", .license = "MIT", .text = @embedFile("license_zig") },
    .{ .name = "musl libc (math functions)", .license = "MIT", .text = @embedFile("license_musl") },
    .{ .name = "Go (number parsing)", .license = "BSD-3-Clause", .text = @embedFile("license_go") },
    .{ .name = "ARM optimized-routines (acos)", .license = "MIT", .text = @embedFile("license_arm") },
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "each setting has help text" {
    for (settings_info) |s| {
        if (s.doc.len == 0) {
            std.debug.print("no help text for {s}: add a /// comment, then run tools/settings_doc.py --zig\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqualStrings("Nozzle temp", findInfo("filament.nozzle_temp").label);
    try testing.expectEqualStrings("lines\ngrid\ntriangles\ncubic\ngyroid\nconcentric", findInfo("project.infill_pattern").choices);
}

fn findInfo(name: []const u8) SettingInfo {
    for (settings_info) |s| if (std.mem.eql(u8, s.name, name)) return s;
    unreachable;
}

test "app: load, slice, preview, and export" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);

    const Events = struct {
        sliced: std.atomic.Value(u32) = .init(0),
        progress: std.atomic.Value(u32) = .init(0),
        fn f(user: ?*anyopaque, event: c_int, _: f64, _: c_int) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user.?));
            switch (@as(Event, @enumFromInt(event))) {
                .sliced => _ = self.sliced.fetchAdd(1, .release),
                .progress => _ = self.progress.fetchAdd(1, .monotonic),
                else => {},
            }
        }
    };
    var events: Events = .{};
    const app = try App.create(gpa, Events.f, &events);
    defer app.destroy();

    try testing.expectError(error.NoModel, app.startSlice());
    try app.loadStl("demo.stl", stl.written());
    try testing.expectEqual(State.ready, app.getState());
    try app.setSetting("project.wall_count", "3");
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try app.getSetting("project.wall_count", &w);
    try testing.expectEqualStrings("3", w.buffered());

    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expectEqual(@as(u32, 1), events.sliced.load(.acquire));
    try testing.expect(events.progress.load(.monotonic) > 0);
    try testing.expectEqual(@as(usize, 69), app.layerCount());
    try testing.expect(std.mem.indexOf(u8, app.gcode().?, ";LAYER:68") != null);

    const tp = app.allToolpaths().?;
    try testing.expectEqual(@as(usize, 69), tp.layer_ends.items.len);
    try testing.expectEqual(tp.path_ends.items.len, tp.path_features.items.len);
    try testing.expectEqual(tp.points.items.len, 2 * @as(usize, tp.path_ends.items[tp.path_ends.items.len - 1]));

    var lp = try app.layerPaths(gpa, 30);
    defer lp.deinit();
    try testing.expect(lp.ends.len > 0);
    try testing.expectEqual(lp.ends.len, lp.features.len);
    try testing.expectEqual(lp.points.len, 2 * @as(usize, lp.ends[lp.ends.len - 1]));
    const pb = app.partBounds().?;

    // A point far from all lines: the plain pick finds nothing, and the
    // pick of a feature finds the skirt of layer 0 at any distance.
    try testing.expectEqual(@as(?usize, null), app.pickInLayer(0, 1, 1));
    const skirt = app.pickFeature(0, @intFromEnum(zs.settings.Feature.skirt), 1, 1).?;
    try testing.expectEqual(@as(u8, @intFromEnum(zs.settings.Feature.skirt)), app.allToolpaths().?.path_features.items[skirt]);

    // Inspect a path of layer 30: the pick finds it, and the explanation
    // has the feature and the speed.
    const path = app.pickInLayer(30, lp.points[0], lp.points[1]).?;
    try testing.expectEqual(@as(usize, 30), app.layerOfPath(path).?);
    const info = try app.inspect(path);
    try testing.expect(std.mem.indexOf(u8, info.explain, "layer 31 of 69") != null);
    try testing.expect(std.mem.indexOf(u8, info.explain, "Planned speed") != null);
    try testing.expect(info.speed > 0 and info.speed <= info.planned_speed + 1e-6);
    try testing.expect(std.mem.indexOf(u8, info.settings, "project.") != null);
    try testing.expectApproxEqAbs(@as(f64, 90), pb[0], 0.01);

    // A new request replaces the result.
    try app.setSetting("project.wall_count", "2");
    try app.requestSlice();
    try app.requestSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expectEqual(@as(usize, 69), app.layerCount());

    // A new model clears the result.
    try app.loadStl("demo.stl", stl.written());
    try testing.expectEqual(@as(usize, 0), app.layerCount());
}

test "app: cancel a slice" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", stl.written());
    // Start, then cancel at once: the result is `ready` (canceled) or
    // `done` (the slice was faster than the cancel).
    try app.startSlice();
    app.cancel();
    app.stopWorkerForTest();
    const st = app.getState();
    try testing.expect(st == .ready or st == .done);
}
