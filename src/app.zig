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
    gcode_bytes: []u8 = &.{},
    stats: zs.Stats = .{},
    part_box: [4]f64 = .{ 0, 0, 0, 0 },
    failure: anyerror = error.Unexpected,
    slice_settings: Settings = .{},

    pub fn create(gpa: Allocator, event_fn: ?EventFn, user: ?*anyopaque) Allocator.Error!*App {
        const app = try gpa.create(App);
        app.* = .{ .gpa = gpa, .event_fn = event_fn, .user = user, .strings = .init(gpa) };
        return app;
    }

    pub fn destroy(app: *App) void {
        app.stopWorker();
        app.clearResults();
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

    fn clearResults(app: *App) void {
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
        var out: std.Io.Writer.Allocating = .init(app.gpa);
        const stats = job.writeGcode(&out.writer) catch |e| {
            out.deinit();
            job.deinit();
            return app.finishFailed(e);
        };
        const bytes = out.toOwnedSlice() catch |e| {
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
    /// For text: true if the value can have more than one line.
    multiline: bool,
};

pub const settings_info: []const SettingInfo = blk: {
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
            }};
        }
    }
    break :blk list;
};

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
    try testing.expectEqualStrings("lines\ngrid", findInfo("project.infill_pattern").choices);
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

    var lp = try app.layerPaths(gpa, 30);
    defer lp.deinit();
    try testing.expect(lp.ends.len > 0);
    try testing.expectEqual(lp.ends.len, lp.features.len);
    try testing.expectEqual(lp.points.len, 2 * @as(usize, lp.ends[lp.ends.len - 1]));
    const pb = app.partBounds().?;
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
