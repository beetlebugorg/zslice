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
//!
//! Files. This file has the state: the plate, the settings and their
//! overrides, the support marks, and the slice worker. `app/` has the rest:
//!
//! - `toolpaths.zig`: the paths of a slice for the previews, and the pick.
//! - `inspect.zig`: the values of one path and the reasons for them.
//! - `feature_settings.zig`: the settings that change each feature.
//! - `setting_effect.zig`: what a setting changes in the preview.
//! - `setting_info.zig`: the description of each setting for a panel.
//! - `licenses.zig`: the licenses for a Licenses screen.
//!
//! The split of a core and native shells comes from Lookout Marine (see
//! REFERENCES.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("root.zig");
const Settings = zs.Settings;
const inspect_mod = @import("app/inspect.zig");
const toolpaths_mod = @import("app/toolpaths.zig");
const setting_effect = @import("app/setting_effect.zig");
const setting_info = @import("app/setting_info.zig");

pub const Toolpaths = toolpaths_mod.Toolpaths;
pub const LayerPaths = toolpaths_mod.LayerPaths;
pub const FeatureStats = toolpaths_mod.FeatureStats;
pub const Inspection = inspect_mod.Inspection;
pub const feature_names = @import("app/feature_settings.zig").feature_names;
pub const SettingEffect = setting_effect.SettingEffect;
pub const settingEffect = setting_effect.settingEffect;
pub const ratioSpeed = setting_effect.ratioSpeed;
pub const mark_seam = setting_effect.mark_seam;
pub const mark_travel = setting_effect.mark_travel;
pub const mark_retract = setting_effect.mark_retract;
pub const SettingKind = setting_info.SettingKind;
pub const SettingInfo = setting_info.SettingInfo;
pub const settings_info = setting_info.settings_info;
pub const License = @import("app/licenses.zig").License;
pub const licenses = @import("app/licenses.zig").licenses;

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

    /// The parts on the bed. `mesh` is all of them in one mesh, for the
    /// engine; startSlice makes it again after a change of the plate.
    plate: zs.plate.Plate = .{},
    plate_changed: bool = false,
    /// More than one plate: a slot for each plate. The active plate
    /// (`active`) has its parts, overrides, and marks in `plate`,
    /// `overrides`, and `marks`; its slot is empty until a switch.
    plates: std.ArrayList(PlateSlot) = .empty,
    active: usize = 0,
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
    /// The job of the slice before, kept for its work: if the new settings
    /// give the same outlines (for example, only the infill density or the
    /// wall count changed), the new slice takes the outlines and the
    /// results of the slow steps that are still good (see Job.initReuse).
    /// Only the worker uses it while a slice runs.
    prev_job: ?zs.Job = null,
    gcode_bytes: []u8 = &.{},
    /// The memory of `gcode_bytes`: it can be larger.
    gcode_buf: []u8 = &.{},
    /// The memory of the results before, for the next slice. A new slice
    /// fills the same arrays, so it does not grow them again from zero.
    spare_gcode: []u8 = &.{},
    spare_paths: Toolpaths = .{},
    stats: zs.Stats = .{},
    part_box: [4]f64 = .{ 0, 0, 0, 0 },
    toolpaths: Toolpaths = .{},
    /// The strings of the last inspection (for the C API).
    inspect_arena: ?std.heap.ArenaAllocator = null,
    failure: anyerror = error.Unexpected,
    slice_settings: Settings = .{},
    /// Changes of settings for z ranges (see settings.Override). The
    /// strings are in `strings`. A new model clears them.
    overrides: std.ArrayList(zs.settings.Override) = .empty,
    /// A copy of `overrides` for the running slice.
    slice_overrides: []zs.settings.Override = &.{},
    /// The names of layer ranges (layer profiles): the overrides with the
    /// same range are the changes of the profile. A profile can have no
    /// changes yet. The names are in `strings`.
    profiles: std.ArrayList(Profile) = .empty,
    /// The support marks of the user (see support.Mark), and a copy for
    /// the running slice. A new model clears them.
    marks: std.ArrayList(zs.support.Mark) = .empty,
    slice_marks: []zs.support.Mark = &.{},
    /// The bytes of the last write3mf.
    file_bytes: []u8 = &.{},

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
        app.gpa.free(app.spare_gcode);
        app.spare_paths.deinit(app.gpa);
        app.overrides.deinit(app.gpa);
        app.profiles.deinit(app.gpa);
        app.gpa.free(app.slice_overrides);
        app.gpa.free(app.file_bytes);
        app.marks.deinit(app.gpa);
        app.gpa.free(app.slice_marks);
        for (app.plates.items) |*slot| slot.deinit(app.gpa);
        app.plates.deinit(app.gpa);
        if (app.mesh) |*m| m.deinit(app.gpa);
        app.plate.deinit(app.gpa);
        app.gpa.free(app.model_name);
        app.strings.deinit();
        app.gpa.destroy(app);
    }

    pub fn getState(app: *const App) State {
        return app.state.load(.acquire);
    }

    pub const LoadError = zs.mesh.Error || zs.threemf.Error;

    /// Loads a model file (STL or 3MF). It replaces all parts of the plate
    /// and stops a slice that runs.
    pub fn loadStl(app: *App, name: []const u8, bytes: []const u8) LoadError!void {
        // Read the file first: a bad file keeps the old plate.
        if (isZip(bytes)) {
            var loaded = try zs.threemf.read(app.gpa, bytes);
            defer loaded.deinit(app.gpa);
            app.dropPlate();
            try app.addLoaded(&loaded);
        } else {
            const m = try zs.Mesh.fromStl(app.gpa, bytes);
            app.dropPlate();
            _ = try app.addMesh(name, m);
        }
        // The old result is gone: there is a model, and no slice of it.
        app.state.store(.ready, .release);
    }

    fn dropPlate(app: *App) void {
        app.stopWorker();
        app.clearResults();
        // The overrides were for the old parts.
        app.overrides.clearRetainingCapacity();
        app.profiles.clearRetainingCapacity();
        app.marks.clearRetainingCapacity();
        app.plate.clear(app.gpa);
    }

    /// Adds a model file (STL or 3MF) to the plate. Returns the index of
    /// its first part. A 3MF file can have more than one part.
    pub fn addStl(app: *App, name: []const u8, bytes: []const u8) LoadError!usize {
        app.stopWorker();
        if (isZip(bytes)) {
            var loaded = try zs.threemf.read(app.gpa, bytes);
            defer loaded.deinit(app.gpa);
            const first = app.plate.count();
            try app.addLoaded(&loaded);
            return first;
        }
        const m = try zs.Mesh.fromStl(app.gpa, bytes);
        return app.addMesh(name, m);
    }

    fn isZip(bytes: []const u8) bool {
        return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
    }

    /// The parts of a 3MF file stay at their places in the file (if they
    /// fit), and its overrides apply.
    fn addLoaded(app: *App, loaded: *zs.threemf.Loaded) LoadError!void {
        try zs.threemf.joinOverlapping(app.gpa, loaded);
        for (loaded.parts) |*p| {
            const m = p.mesh;
            p.mesh = .empty; // The plate owns the mesh now.
            const i = try app.plate.add(app.gpa, p.name, m, app.bedSize(), app.partGap(), true);
            _ = i;
        }
        try app.plateChanged();
        var lines = std.mem.tokenizeAny(u8, loaded.overrides, "\r\n");
        while (lines.next()) |line| {
            // "profile <tab> z_min <tab> z_max <tab> name": a layer profile.
            if (std.mem.startsWith(u8, line, "profile\t")) {
                var f = std.mem.splitScalar(u8, line["profile\t".len..], '\t');
                const lo = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                const hi = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                try app.setProfile(lo, hi, f.rest());
                continue;
            }
            var f = std.mem.splitScalar(u8, line, '\t');
            const lo = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
            const hi = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
            const n = f.next() orelse continue;
            const v = f.rest();
            // A change that this version does not know is left out.
            app.setOverride(lo, hi, n, v) catch |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        }
    }

    /// A 3MF file of the plate and its overrides. The bytes are valid
    /// until the next call or until the app goes.
    pub fn write3mf(app: *App) (Allocator.Error || error{WriteFailed} || error{NoModel})![]const u8 {
        if (app.plate.count() == 0) return error.NoModel;
        var text: std.Io.Writer.Allocating = .init(app.gpa);
        defer text.deinit();
        for (app.profiles.items) |p| try text.writer.print("profile\t{d}\t{d}\t{s}\n", .{ p.z_min, p.z_max, p.name });
        for (app.overrides.items) |o| try text.writer.print("{d}\t{d}\t{s}\t{s}\n", .{ o.z_min, o.z_max, o.name, o.value });
        var out: std.Io.Writer.Allocating = .init(app.gpa);
        errdefer out.deinit();
        try zs.threemf.write(app.gpa, &out.writer, &app.plate, text.written());
        app.gpa.free(app.file_bytes);
        app.file_bytes = &.{};
        app.file_bytes = try out.toOwnedSlice();
        return app.file_bytes;
    }

    fn addMesh(app: *App, name: []const u8, m: zs.Mesh) zs.mesh.Error!usize {
        const s = app.settings;
        const i = try app.plate.add(app.gpa, name, m, app.bedSize(), app.partGap(), s.project.placement != .center);
        try app.plateChanged();
        return i;
    }

    fn bedSize(app: *const App) [2]f64 {
        return .{ app.settings.machine.bed_size_x, app.settings.machine.bed_size_y };
    }

    /// The gap between parts: the skirt and the brim go around each part.
    fn partGap(app: *const App) f64 {
        const p = app.settings.project;
        const w = if (p.first_layer_line_width > 0) p.first_layer_line_width else 1.25 * app.settings.machine.nozzle_diameter;
        const skirt = if (p.skirt_loops > 0 and p.skirt_layers > 0) p.skirt_distance + @as(f64, @floatFromInt(p.skirt_loops)) * w else 0;
        return @max(3, p.brim_width * 2 + skirt);
    }

    pub const PlateSlot = struct {
        plate: zs.plate.Plate = .{},
        overrides: std.ArrayList(zs.settings.Override) = .empty,
        profiles: std.ArrayList(Profile) = .empty,
        marks: std.ArrayList(zs.support.Mark) = .empty,

        fn deinit(s: *PlateSlot, gpa: Allocator) void {
            s.plate.deinit(gpa);
            s.overrides.deinit(gpa);
            s.profiles.deinit(gpa);
            s.marks.deinit(gpa);
        }
    };

    pub fn plateCount(app: *const App) usize {
        return @max(1, app.plates.items.len);
    }

    fn ensureSlots(app: *App) Allocator.Error!void {
        if (app.plates.items.len == 0) try app.plates.append(app.gpa, .{});
    }

    /// The parts of plate i (the active plate, or a slot).
    pub fn plateParts(app: *const App, i: usize) usize {
        if (i == app.active or i >= app.plates.items.len) return if (i == app.active) app.plate.count() else 0;
        return app.plates.items[i].plate.count();
    }

    /// Makes plate i the active plate: its parts, changes, and marks are
    /// the ones that the app slices and shows.
    pub fn selectPlate(app: *App, i: usize) Allocator.Error!void {
        try app.ensureSlots();
        if (i >= app.plates.items.len or i == app.active) return;
        app.stopWorker();
        app.clearResults();
        // The active plate to its slot, and plate i out of its slot.
        std.mem.swap(zs.plate.Plate, &app.plate, &app.plates.items[app.active].plate);
        std.mem.swap(std.ArrayList(zs.settings.Override), &app.overrides, &app.plates.items[app.active].overrides);
        std.mem.swap(std.ArrayList(Profile), &app.profiles, &app.plates.items[app.active].profiles);
        std.mem.swap(std.ArrayList(zs.support.Mark), &app.marks, &app.plates.items[app.active].marks);
        std.mem.swap(zs.plate.Plate, &app.plate, &app.plates.items[i].plate);
        std.mem.swap(std.ArrayList(zs.settings.Override), &app.overrides, &app.plates.items[i].overrides);
        std.mem.swap(std.ArrayList(Profile), &app.profiles, &app.plates.items[i].profiles);
        std.mem.swap(std.ArrayList(zs.support.Mark), &app.marks, &app.plates.items[i].marks);
        app.active = i;
        if (app.mesh) |*old| old.deinit(app.gpa);
        app.mesh = null;
        if (app.getState() != .empty) app.state.store(.ready, .release);
        try app.plateChanged();
    }

    /// A new empty plate, after the others; it becomes the active plate.
    pub fn addPlate(app: *App) Allocator.Error!usize {
        try app.ensureSlots();
        try app.plates.append(app.gpa, .{});
        const i = app.plates.items.len - 1;
        try app.selectPlate(i);
        return i;
    }

    /// Removes plate i with its parts. The last plate stays (empty).
    pub fn removePlate(app: *App, i: usize) Allocator.Error!void {
        try app.ensureSlots();
        if (i >= app.plates.items.len) return;
        if (app.plates.items.len == 1) return app.clearPlate();
        if (i == app.active) try app.selectPlate(if (i > 0) i - 1 else 1);
        var slot = app.plates.orderedRemove(i);
        slot.deinit(app.gpa);
        if (app.active > i) app.active -= 1;
    }

    /// After each change of the plate: a new name, and the next slice
    /// makes the mesh again (with no regions of the old one).
    fn plateChanged(app: *App) Allocator.Error!void {
        app.plate_changed = true;
        app.dropPrevJob();
        const n = app.plate.count();
        const name = if (n == 0)
            try app.gpa.dupe(u8, "")
        else if (n == 1)
            try app.gpa.dupe(u8, app.plate.parts.items[0].name)
        else
            try std.fmt.allocPrint(app.gpa, "{s} and {d} more", .{ app.plate.parts.items[0].name, n - 1 });
        app.gpa.free(app.model_name);
        app.model_name = name;
        if (n == 0) {
            app.stopWorker();
            app.clearResults();
            if (app.mesh) |*old| old.deinit(app.gpa);
            app.mesh = null;
            app.state.store(.empty, .release);
        } else if (app.getState() == .empty) {
            app.state.store(.ready, .release);
        }
        // A non-empty plate has a mesh at once (for the model size), and
        // startSlice makes it again after later changes.
        if (n > 0 and app.mesh == null) {
            app.mesh = try app.plate.combined(app.gpa);
            app.plate_changed = false;
        }
    }

    pub fn removePart(app: *App, i: usize) Allocator.Error!void {
        app.stopWorker();
        app.plate.remove(app.gpa, i);
        try app.plateChanged();
    }

    pub fn movePart(app: *App, i: usize, x: f64, y: f64) Allocator.Error!void {
        app.plate.move(i, x, y);
        try app.plateChanged();
    }

    pub fn rotatePart(app: *App, i: usize, deg: f64) Allocator.Error!void {
        app.plate.rotate(i, deg);
        try app.plateChanged();
    }

    pub fn scalePart(app: *App, i: usize, s: [3]f64) Allocator.Error!void {
        try app.plate.setScale(app.gpa, i, s);
        try app.plateChanged();
    }

    /// Turns a part by `deg` about the X (0) or Y (1) axis of the bed.
    pub fn turnPart(app: *App, i: usize, axis: u2, deg: f64) Allocator.Error!void {
        try app.plate.turn(app.gpa, i, axis, deg);
        try app.plateChanged();
    }

    /// Puts the side of part i nearest to the bed point (x, y, z) on the
    /// bed ("this side on the bed", from a picked line).
    pub fn putPartDownAt(app: *App, i: usize, x: f64, y: f64, z: f64) Allocator.Error!void {
        const n = app.plate.sideAt(i, x, y, z) orelse return;
        try app.plate.putDown(app.gpa, i, n);
        try app.plateChanged();
    }

    pub fn placePart(app: *App, i: usize, mode: zs.plate.PlaceMode, axis: u2) Allocator.Error!void {
        try app.plate.place(app.gpa, i, mode, axis, app.settings.project.support_angle);
        try app.plateChanged();
    }

    pub fn resetPart(app: *App, i: usize) Allocator.Error!void {
        try app.plate.resetPose(app.gpa, i);
        try app.plateChanged();
    }

    /// Smart placement of the whole plate: each part turns to its best
    /// orientation (less support, more on the bed, low), then the plate is
    /// arranged. Returns false if the parts do not all fit.
    pub fn smartPlacePlate(app: *App) Allocator.Error!bool {
        for (0..app.plate.count()) |i| try app.plate.place(app.gpa, i, .smart, 0, app.settings.project.support_angle);
        return app.arrangePlate();
    }

    /// Packs all parts on the bed. Returns false if they do not all fit.
    pub fn arrangePlate(app: *App) Allocator.Error!bool {
        const ok = try app.plate.arrange(app.gpa, app.bedSize(), app.partGap());
        try app.plateChanged();
        return ok;
    }

    pub fn clearPlate(app: *App) Allocator.Error!void {
        app.stopWorker();
        app.overrides.clearRetainingCapacity();
        app.profiles.clearRetainingCapacity();
        app.plate.clear(app.gpa);
        try app.plateChanged();
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

    /// Writes the settings of a group that differ from the defaults, as a
    /// profile (see profile.writeChanged). A shell saves this text to keep
    /// the settings after a restart.
    pub fn writeState(app: *const App, group: zs.profile.Group, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return zs.profile.writeChanged(app.settings, group, w);
    }

    /// Sets all settings of a group to the built-in defaults. A shell does
    /// this before it applies the profile of an other printer, so that no
    /// value of the printer before stays.
    pub fn resetGroup(app: *App, group: zs.profile.Group) void {
        switch (group) {
            inline else => |g| @field(app.settings, @tagName(g)) = .{},
        }
    }

    /// Applies a profile text to the settings of a group (for example, the
    /// text of `writeState` after a restart). The settings change only if
    /// all of the text is valid.
    pub fn applyProfile(app: *App, group: zs.profile.Group, name: []const u8, text: []const u8, diag: *zs.profile.Diagnostic) zs.profile.Error!void {
        const a = app.strings.allocator();
        const owned = try a.dupe(u8, text);
        var s = app.settings;
        try zs.profile.apply(a, &s, group, name, owned, null, diag);
        app.settings = s;
    }

    pub const OverrideError = Settings.SetError || error{ NotPerLayer, OutOfMemory };

    /// Changes a setting for the layers with a top z from z_min to z_max.
    /// An override for the same range and setting is replaced. Only
    /// settings.layer_settings can change for some layers.
    pub fn setOverride(app: *App, z_min: f64, z_max: f64, name: []const u8, value: []const u8) OverrideError!void {
        const whole = z_min <= -zs.settings.part_z and z_max >= zs.settings.part_z;
        if (whole) {
            if (!zs.settings.isPartSetting(name)) return error.NotPerLayer;
        } else if (!zs.settings.isLayerSetting(name)) return error.NotPerLayer;
        const a = app.strings.allocator();
        const n = try a.dupe(u8, name);
        const v = try a.dupe(u8, value);
        // Check the value.
        var check = app.settings;
        try check.set(n, v);
        for (app.overrides.items) |*o| {
            if (std.mem.eql(u8, o.name, name) and @abs(o.z_min - z_min) < 1e-6 and @abs(o.z_max - z_max) < 1e-6) {
                o.value = v;
                return;
            }
        }
        try app.overrides.append(app.gpa, .{ .z_min = z_min, .z_max = z_max, .name = n, .value = v });
    }

    pub const Profile = struct { z_min: f64, z_max: f64, name: []const u8 };

    fn sameRange(a_min: f64, a_max: f64, b_min: f64, b_max: f64) bool {
        return @abs(a_min - b_min) < 1e-6 and @abs(a_max - b_max) < 1e-6;
    }

    /// Names the layer range from z_min to z_max (a layer profile), or
    /// gives it a new name.
    pub fn setProfile(app: *App, z_min: f64, z_max: f64, name: []const u8) Allocator.Error!void {
        const n = try app.strings.allocator().dupe(u8, name);
        for (app.profiles.items) |*p| if (sameRange(p.z_min, p.z_max, z_min, z_max)) {
            p.name = n;
            return;
        };
        try app.profiles.append(app.gpa, .{ .z_min = z_min, .z_max = z_max, .name = n });
    }

    /// Removes a layer range: its name and all its changes. Returns the
    /// number of changes removed.
    pub fn removeProfile(app: *App, z_min: f64, z_max: f64) usize {
        var i: usize = 0;
        while (i < app.profiles.items.len) {
            const p = app.profiles.items[i];
            if (sameRange(p.z_min, p.z_max, z_min, z_max)) _ = app.profiles.orderedRemove(i) else i += 1;
        }
        var removed: usize = 0;
        i = 0;
        while (i < app.overrides.items.len) {
            const o = app.overrides.items[i];
            if (sameRange(o.z_min, o.z_max, z_min, z_max)) {
                _ = app.overrides.orderedRemove(i);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    /// Removes the change of one setting in one range. Returns true if
    /// there was one.
    pub fn removeOverride(app: *App, z_min: f64, z_max: f64, name: []const u8) bool {
        for (app.overrides.items, 0..) |o, i| if (std.mem.eql(u8, o.name, name) and sameRange(o.z_min, o.z_max, z_min, z_max)) {
            _ = app.overrides.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// The islands of the last slice (shapes that start in the air), or
    /// none.
    pub fn islands(app: *const App) []const zs.islands.Island {
        if (app.getState() != .done) return &.{};
        const j = app.job orelse return &.{};
        return j.islands;
    }

    /// Adds a support mark (support of a kind under a disk at x, y on the
    /// layer at z, or a block of support there). A mark at the same place
    /// (closer than its radius, on the same layer) is replaced.
    pub fn addMark(app: *App, mark: zs.support.Mark) Allocator.Error!void {
        _ = app.removeMarksNear(mark.x, mark.y, mark.z, mark.r);
        try app.marks.append(app.gpa, mark);
    }

    /// Removes the marks within r of x, y on the layer at z (0.05 mm).
    /// Returns how many.
    pub fn removeMarksNear(app: *App, x: f64, y: f64, z: f64, r: f64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < app.marks.items.len) {
            const m = app.marks.items[i];
            if (@abs(m.z - z) < 0.05 and std.math.hypot(m.x - x, m.y - y) < r + m.r) {
                _ = app.marks.orderedRemove(i);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    pub fn clearMarks(app: *App) void {
        app.marks.clearRetainingCapacity();
    }

    /// The part of the plate that has a path of the last slice (the part
    /// under the first point of the path), or null.
    pub fn partOfPath(app: *const App, path: usize) ?usize {
        const t = app.allToolpaths() orelse return null;
        if (path >= t.pathCount()) return null;
        const start = t.pathStart(path);
        return app.plate.partAt(t.points.items[2 * start], t.points.items[2 * start + 1]);
    }

    /// Removes the overrides of a setting that cover z. Returns how many.
    pub fn clearOverridesAt(app: *App, z: f64, name: []const u8) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < app.overrides.items.len) {
            const o = app.overrides.items[i];
            if (std.mem.eql(u8, o.name, name) and o.covers(z)) {
                _ = app.overrides.orderedRemove(i);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    /// True if an override of the setting covers z.
    pub fn hasOverrideAt(app: *const App, z: f64, name: []const u8) bool {
        for (app.overrides.items) |o| if (std.mem.eql(u8, o.name, name) and o.covers(z)) return true;
        return false;
    }

    /// Writes the value of a setting for the layers at z: with the
    /// overrides that cover z.
    pub fn getSettingAt(app: *const App, z: f64, name: []const u8, w: *std.Io.Writer) (Settings.SetError || std.Io.Writer.Error)!void {
        const s = try zs.settings.withOverrides(app.settings, app.overrides.items, z);
        return writeSettingOf(s, name, w);
    }

    /// A report of path `path` for a person or a language model that is
    /// asked why it prints as it does: what it is, its numbers, the "why"
    /// texts, the values of the settings that change it (at its layer), the
    /// printer and the filament, and the first points of the path. Plain
    /// text; valid until the next call or inspection.
    pub fn lineReport(app: *App, path: usize, gcode_file: []const u8) ![]const u8 {
        const info = try app.inspect(path);
        const arena = app.inspect_arena.?.allocator();
        const t = app.allToolpaths() orelse return error.NoResult;
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("zslice report of one line of a 3D print slice ({s}).\n\n", .{app.model_name});
        try w.print("## The line\n{s}\n\n", .{info.explain});
        const whys = [_][2][]const u8{ .{ "Planned speed", info.why_planned }, .{ "Real speed", info.why_real }, .{ "Flow", info.why_flow } };
        for (whys) |wy| {
            // The {{name}} marks as plain names.
            const plain = try std.mem.replaceOwned(u8, arena, try std.mem.replaceOwned(u8, arena, wy[1], "{{", "`"), "}}", "`");
            try w.print("## Why the {s}\n{s}\n\n", .{ wy[0], plain });
        }
        try w.print("## The settings that change this line (values at z {d:.2} mm)\n", .{info.z});
        var it = std.mem.tokenizeScalar(u8, info.settings, '\n');
        while (it.next()) |name| {
            if (name.len > 0 and name[0] == '#') continue;
            var v: std.Io.Writer.Allocating = .init(arena);
            app.getSettingAt(info.z, name, &v.writer) catch continue;
            try w.print("- {s} = {s}\n", .{ name, v.written() });
        }
        const s = app.settings;
        try w.print("\n## The printer and the filament\n- printer: {s}, bed {d} x {d} mm, nozzle {d} mm, max speed {d} mm/s, max acceleration {d} mm/s2, corner speed {d} mm/s\n- filament: {s}, {d} mm, nozzle {d} C, bed {d} C, max flow {d} mm3/s\n", .{ s.machine.name, s.machine.bed_size_x, s.machine.bed_size_y, s.machine.nozzle_diameter, s.machine.max_speed, s.machine.max_accel, s.machine.corner_speed, s.filament.name, s.filament.diameter, s.filament.nozzle_temp, s.filament.bed_temp, s.filament.max_flow });
        try w.print("\n## The path (x, y in mm on the bed; the first 40 points)\n", .{});
        const start: usize = if (path == 0) 0 else t.path_ends.items[path - 1];
        const end: usize = t.path_ends.items[path];
        var k = start;
        while (k < end and k < start + 40) : (k += 1) try w.print("{d:.2},{d:.2}\n", .{ t.points.items[2 * k], t.points.items[2 * k + 1] });
        if (end - start > 40) try w.print("... ({d} points in all)\n", .{end - start});
        // Where the line is in the G-code: the file, the line numbers, and
        // the lines.
        if (app.gcodeLines(path)) |lines| {
            try w.print("\n## The G-code\nFile: {s}\nThis line is lines {d} to {d} of the file (layer {d}: the block after \";LAYER:{d}\"). X and Y in the file include the bed origin ({d}, {d}).\n```gcode\n", .{ gcode_file, lines[0] + 1, lines[1] + 1, info.layer + 1, info.layer, s.machine.origin_x, s.machine.origin_y });
            const g = app.gcode().?;
            var n: usize = 0;
            var from: usize = 0;
            var shown: usize = 0;
            while (from < g.len) : (n += 1) {
                const nl = std.mem.indexOfScalarPos(u8, g, from, '\n') orelse g.len;
                if (n >= lines[0] and n <= lines[1]) {
                    if (shown < 60) try w.print("{s}\n", .{g[from..nl]});
                    shown += 1;
                }
                if (n > lines[1]) break;
                from = nl + 1;
            }
            if (shown > 60) try w.print("... ({d} lines in all)\n", .{shown});
            try w.writeAll("```\n");
        } else {
            try w.print("\n## The G-code\nFile: {s} (the line was not found in it).\n", .{gcode_file});
        }
        return out.written();
    }

    /// The first and the last line (from 0) of the G-code of path `path`:
    /// in the block of its layer, the extrusion to its second point, and
    /// the line before it (the travel or the type comment), to the
    /// extrusion to its last point. Null if not found.
    pub fn gcodeLines(app: *const App, path: usize) ?[2]usize {
        const t = app.allToolpaths() orelse return null;
        const g = app.gcode() orelse return null;
        const layer = app.layerOfPath(path) orelse return null;
        const start: usize = if (path == 0) 0 else t.path_ends.items[path - 1];
        const end: usize = t.path_ends.items[path];
        if (end < start + 2) return null;
        const ox = app.settings.machine.origin_x;
        const oy = app.settings.machine.origin_y;
        const p1 = [2]f64{ t.points.items[2 * (start + 1)] + ox, t.points.items[2 * (start + 1) + 1] + oy };
        // A closed path ends with the move back to its first point.
        const closed = t.path_closed.items[path] != 0;
        const li = if (closed) start else end - 1;
        const pn = [2]f64{ t.points.items[2 * li] + ox, t.points.items[2 * li + 1] + oy };
        var marker_buf: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buf, ";LAYER:{d}\n", .{layer}) catch return null;
        var n: usize = 0;
        var from: usize = 0;
        var in_layer = false;
        var first: ?usize = null;
        while (from < g.len) : (n += 1) {
            const nl = std.mem.indexOfScalarPos(u8, g, from, '\n') orelse g.len;
            const line = g[from..nl];
            if (std.mem.startsWith(u8, line, ";LAYER:")) {
                if (in_layer) break;
                in_layer = std.mem.eql(u8, line, marker[0 .. marker.len - 1]);
            } else if (in_layer and std.mem.startsWith(u8, line, "G1 X")) {
                if (parseXY(line)) |xy| {
                    if (first == null) {
                        if (@abs(xy[0] - p1[0]) < 0.002 and @abs(xy[1] - p1[1]) < 0.002) {
                            first = n;
                            // A path of one segment ends at its second point.
                            if (li == start + 1) return .{ n -| 1, n };
                        }
                    } else if (@abs(xy[0] - pn[0]) < 0.002 and @abs(xy[1] - pn[1]) < 0.002) {
                        return .{ first.? -| 1, n };
                    }
                }
            }
            from = nl + 1;
        }
        return null;
    }

    fn parseXY(line: []const u8) ?[2]f64 {
        const xi = std.mem.indexOf(u8, line, " X") orelse return null;
        const yi = std.mem.indexOf(u8, line, " Y") orelse return null;
        const xe = std.mem.indexOfScalarPos(u8, line, xi + 2, ' ') orelse line.len;
        const ye = std.mem.indexOfScalarPos(u8, line, yi + 2, ' ') orelse line.len;
        const x = std.fmt.parseFloat(f64, line[xi + 2 .. xe]) catch return null;
        const y = std.fmt.parseFloat(f64, line[yi + 2 .. ye]) catch return null;
        return .{ x, y };
    }

    /// Writes the value of a setting as text.
    pub fn getSetting(app: *const App, name: []const u8, w: *std.Io.Writer) (Settings.SetError || std.Io.Writer.Error)!void {
        return writeSettingOf(app.settings, name, w);
    }

    fn writeSettingOf(settings: Settings, name: []const u8, w: *std.Io.Writer) (Settings.SetError || std.Io.Writer.Error)!void {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.UnknownSetting;
        inline for (@typeInfo(Settings).@"struct".fields) |g| {
            if (std.mem.eql(u8, g.name, name[0..dot])) {
                const group = @field(settings, g.name);
                inline for (@typeInfo(g.type).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, name[dot + 1 ..])) {
                        return writeValue(w, @field(group, f.name));
                    }
                }
            }
        }
        return error.UnknownSetting;
    }

    pub const StartError = error{ NoModel, Busy, ThreadSpawnFailed, OutOfMemory };

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
        app.recycleResults();
        // The mesh of the plate, made again after a change.
        if (app.plate_changed) {
            const m = try app.plate.combined(app.gpa);
            if (app.mesh) |*old| old.deinit(app.gpa);
            app.mesh = m;
            app.plate_changed = false;
            app.dropPrevJob();
        }
        app.slice_settings = app.settings;
        app.gpa.free(app.slice_overrides);
        app.slice_overrides = app.gpa.dupe(zs.settings.Override, app.overrides.items) catch &.{};
        app.gpa.free(app.slice_marks);
        app.slice_marks = app.gpa.dupe(zs.support.Mark, app.marks.items) catch &.{};
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
        app.gpa.free(app.gcode_buf);
        app.gcode_buf = &.{};
        app.gcode_bytes = &.{};
        app.stats = .{};
    }

    /// `clearResults`, but the memory of the G-code and the toolpaths
    /// stays for the next slice.
    fn recycleResults(app: *App) void {
        app.gpa.free(app.spare_gcode);
        app.spare_gcode = app.gcode_buf;
        app.gcode_buf = &.{};
        app.gcode_bytes = &.{};
        app.spare_paths.deinit(app.gpa);
        app.spare_paths = app.toolpaths;
        app.toolpaths = .{};
        app.clearResults();
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
        // The overrides of the whole part change the settings of the slice;
        // the others change some layers.
        var part = app.slice_settings;
        // The plate has placed the parts: the engine keeps their places.
        part.project.placement = .file;
        var layer_overrides: std.ArrayList(zs.settings.Override) = .empty;
        defer layer_overrides.deinit(app.gpa);
        for (app.slice_overrides) |o| {
            if (o.wholePart()) {
                part.set(o.name, o.value) catch return app.finishFailed(error.InvalidSettings);
            } else {
                layer_overrides.append(app.gpa, o) catch |e| return app.finishFailed(e);
            }
        }
        const prev: ?*zs.Job = if (app.prev_job) |*j| j else null;
        const job_or = zs.Job.initReuse(app.gpa, &app.mesh.?, part, layer_overrides.items, app.slice_marks, monitor, prev);
        // The new job took what it could use. A job that failed (for
        // example, a cancel) can leave the old job without outlines, so the
        // old job goes in each case.
        app.dropPrevJob();
        var job = job_or catch |e| return app.finishFailed(e);
        var out: std.Io.Writer.Allocating = .initOwnedSlice(app.gpa, app.spare_gcode);
        app.spare_gcode = &.{};
        out.clearRetainingCapacity();
        var store = app.spare_paths;
        app.spare_paths = .{};
        store.clearRetainingCapacity();
        store.gpa = app.gpa;
        store.z_hop = @floatCast(part.project.z_hop);
        const sink: zs.engine.Job.LayerSink = .{ .ctx = &store, .func = Toolpaths.addLayer };
        const stats = job.writeGcodeWith(&out.writer, sink) catch |e| {
            store.deinit(app.gpa);
            out.deinit();
            app.keepForRegions(job);
            return app.finishFailed(e);
        };
        // The buffer can be larger than the text. It stays, for the next
        // slice.
        const bytes = out.written();
        const buf = out.writer.buffer;

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
        app.gcode_buf = buf;
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
        return t.featureStats();
    }

    /// The layer of a path of the toolpaths.
    pub fn layerOfPath(app: *const App, path: usize) ?usize {
        const t = app.allToolpaths() orelse return null;
        return t.layerOfPath(path);
    }

    /// See Toolpaths.pickInLayer.
    pub fn pickInLayer(app: *const App, layer: usize, x: f64, y: f64) ?usize {
        const t = app.allToolpaths() orelse return null;
        return t.pickInLayer(layer, x, y);
    }

    /// See Toolpaths.pickFeature.
    pub fn pickFeature(app: *const App, layer: usize, feature: u8, x: f64, y: f64) ?usize {
        const t = app.allToolpaths() orelse return null;
        return t.pickFeature(layer, feature, x, y);
    }

    /// The real values of one path, why they are what they are, and the
    /// settings that change them. The strings stay valid until the next
    /// call, the next slice, or `destroy`.
    pub fn inspect(app: *App, path: usize) error{ NoResult, OutOfRange, OutOfMemory }!Inspection {
        const t = app.allToolpaths() orelse return error.NoResult;
        if (app.inspect_arena) |*a| a.deinit();
        app.inspect_arena = .init(app.gpa);
        return inspect_mod.inspect(app.inspect_arena.?.allocator(), t, &app.job.?, path) catch |e| switch (e) {
            error.OutOfRange => error.OutOfRange,
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
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

const testing = std.testing;

test {
    _ = inspect_mod;
    _ = toolpaths_mod;
    _ = setting_effect;
    _ = setting_info;
    _ = @import("app/feature_settings.zig");
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

test "an override of the whole part changes the slice, and not the global settings" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", bytes.written());
    // The layer height is not a layer setting, but the part can change it.
    try testing.expectError(error.NotPerLayer, app.setOverride(1, 2, "project.layer_height", "0.3"));
    try testing.expectError(error.NotPerLayer, app.setOverride(-1e6, 1e6, "machine.bed_size_x", "300"));
    try app.setOverride(-1e6, 1e6, "project.layer_height", "0.3");
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    // 14 mm: a 0.3 mm first layer, then 46 layers of 0.3 mm (not 69 of
    // 0.2 mm).
    try testing.expectEqual(@as(usize, 47), app.allToolpaths().?.layer_ends.items.len);
    try testing.expectEqual(@as(f64, 0.2), app.settings.project.layer_height);
}

test "app: a change for the top layer gives the same G-code with the cache and without it" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const values = [_][]const u8{ "90", "45", "0", "90" };
    for ([_][]const u8{ "lines", "monotonic" }) |pattern| {
        // With the cache: slice, then change the override of the top layer
        // again and again, as a slider does.
        const app = try App.create(gpa, null, null);
        defer app.destroy();
        try app.loadStl("demo.stl", bytes.written());
        try app.setSetting("project.skin_pattern", pattern);
        try app.startSlice();
        app.stopWorkerForTest();
        const t = app.allToolpaths().?;
        const top_z = t.layer_z.items[t.layer_z.items.len - 1];
        for (values) |v| {
            try app.setOverride(top_z - 1e-3, top_z + 1e-3, "project.skin_angle", v);
            try app.requestSlice();
            app.stopWorkerForTest();
        }
        // Without the cache: a new app with the last value.
        const fresh = try App.create(gpa, null, null);
        defer fresh.destroy();
        try fresh.loadStl("demo.stl", bytes.written());
        try fresh.setSetting("project.skin_pattern", pattern);
        try fresh.setOverride(top_z - 1e-3, top_z + 1e-3, "project.skin_angle", values[values.len - 1]);
        try fresh.startSlice();
        fresh.stopWorkerForTest();
        try testing.expectEqualStrings(fresh.gcode().?, app.gcode().?);
    }
}

test "app: a support mark adds support where the settings have none" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", bytes.written());
    // A shelf: the demo part has none, so make an overhang with a bridge
    // mark over the hole of the tube is not possible; use the top of the
    // box: a mark there finds no overhang (the box is on the base), so the
    // G-code has no support.
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(std.mem.indexOf(u8, app.gcode().?, ";TYPE:SUPPORT") == null);
    const t = app.allToolpaths().?;
    const top = t.layer_z.items[t.layer_z.items.len - 1];
    // The box of the demo part (20 x 20 mm) sits on the base: no overhang.
    try app.addMark(.{ .x = 100, .y = 100, .z = top, .kind = .grid });
    try testing.expectEqual(@as(usize, 1), app.marks.items.len);
    // The same place again replaces the mark.
    try app.addMark(.{ .x = 100.5, .y = 100, .z = top, .kind = .tree });
    try testing.expectEqual(@as(usize, 1), app.marks.items.len);
    try app.requestSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expectEqual(@as(usize, 1), app.removeMarksNear(100, 100, top, 1));
}

test "app: plates keep their parts, and a switch slices the active plate" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 10, 5);
    var m = try b.finish();
    defer m.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    try app.loadStl("a.stl", stl.written());
    try testing.expectEqual(@as(usize, 1), app.plateCount());
    // A second plate with two parts.
    try testing.expectEqual(@as(usize, 1), try app.addPlate());
    try testing.expectEqual(State.empty, app.getState());
    _ = try app.addStl("b.stl", stl.written());
    _ = try app.addStl("c.stl", stl.written());
    try testing.expectEqual(@as(usize, 2), app.plate.count());
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    // Back to plate 0: one part, and it slices.
    try app.selectPlate(0);
    try testing.expectEqual(@as(usize, 1), app.plate.count());
    try testing.expectEqual(@as(usize, 2), app.plateParts(1));
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    // Remove plate 0: plate 1 is the only one, and active.
    try app.removePlate(0);
    try testing.expectEqual(@as(usize, 1), app.plateCount());
    try testing.expectEqual(@as(usize, 2), app.plate.count());
}

test "app: layer profiles name a range, keep their changes, and go in a 3MF file" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", bytes.written());
    try app.setProfile(2, 1e6, "Top part");
    try app.setOverride(2, 1e6, "project.infill_density", "0.5");
    try app.setOverride(2, 1e6, "project.wall_count", "4");
    try app.setOverride(0, 1, "project.infill_density", "0.1");
    // A new name for the same range replaces the name.
    try app.setProfile(2, 1e6, "Upper");
    try testing.expectEqual(@as(usize, 1), app.profiles.items.len);
    try testing.expectEqualStrings("Upper", app.profiles.items[0].name);
    // A 3MF file keeps the profile and its changes.
    const file = try gpa.dupe(u8, try app.write3mf());
    defer gpa.free(file);
    const other = try App.create(gpa, null, null);
    defer other.destroy();
    try other.loadStl("demo.3mf", file);
    try testing.expectEqual(@as(usize, 1), other.profiles.items.len);
    try testing.expectEqualStrings("Upper", other.profiles.items[0].name);
    try testing.expectEqual(@as(usize, 3), other.overrides.items.len);
    // One change of the profile goes; then the profile with the rest.
    try testing.expect(app.removeOverride(2, 1e6, "project.wall_count"));
    try testing.expect(!app.removeOverride(2, 1e6, "project.wall_count"));
    try testing.expectEqual(@as(usize, 1), app.removeProfile(2, 1e6));
    try testing.expectEqual(@as(usize, 0), app.profiles.items.len);
    try testing.expectEqual(@as(usize, 1), app.overrides.items.len);
}

test "app: the G-code lines of a path, and the report for AI" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", bytes.written());
    try app.startSlice();
    app.stopWorkerForTest();
    const t = app.allToolpaths().?;
    const g = app.gcode().?;
    var found: usize = 0;
    var path: usize = 0;
    while (path < t.path_ends.items.len) : (path += 37) {
        const lines = app.gcodeLines(path) orelse continue;
        found += 1;
        // The last line is an extrusion to the last point of the path.
        var n: usize = 0;
        var from: usize = 0;
        while (n < lines[1]) : (n += 1) from = std.mem.indexOfScalarPos(u8, g, from, '\n').? + 1;
        const nl = std.mem.indexOfScalarPos(u8, g, from, '\n') orelse g.len;
        try testing.expect(std.mem.startsWith(u8, g[from..nl], "G1 X"));
        try testing.expect(lines[0] < lines[1]);
    }
    try testing.expect(found > 5);
    const r = try app.lineReport(37, "/tmp/x.gcode");
    try testing.expect(std.mem.indexOf(u8, r, "File: /tmp/x.gcode") != null);
    try testing.expect(std.mem.indexOf(u8, r, "```gcode") != null);
}

test "app: a 3MF file keeps the parts, the places, and the changes" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 10, 5);
    var m = try b.finish();
    defer m.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    try app.loadStl("a.stl", stl.written());
    _ = try app.addStl("b.stl", stl.written());
    try app.movePart(1, 60, 50);
    try app.setOverride(-zs.settings.part_z, zs.settings.part_z, "project.infill_density", "0.35");
    const bytes = try gpa.dupe(u8, try app.write3mf());
    defer gpa.free(bytes);

    const back = try App.create(gpa, null, null);
    defer back.destroy();
    try back.loadStl("plate.3mf", bytes);
    try std.testing.expectEqual(@as(usize, 2), back.plate.count());
    const p = back.plate.parts.items[1];
    try std.testing.expectApproxEqAbs(@as(f64, 60), p.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 50), p.y, 1e-3);
    try std.testing.expectEqual(@as(usize, 1), back.overrides.items.len);
    try std.testing.expectEqualStrings("0.35", back.overrides.items[0].value);
}

test "a plate of two parts slices as one print" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", bytes.written());
    const second = try app.addStl("b.stl", bytes.written());
    try testing.expectEqual(@as(usize, 1), second);
    try testing.expectEqualStrings("a.stl and 1 more", app.model_name);
    // The two parts do not touch.
    const fa = app.plate.parts.items[0].footprint();
    const fb = app.plate.parts.items[1].footprint();
    try testing.expect(fa[2] <= fb[0] or fb[2] <= fa[0] or fa[3] <= fb[1] or fb[3] <= fa[1]);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    // Twice the paths of one part on the first layer (and two skirts).
    const pb = app.partBounds().?;
    try testing.expect(pb[2] - pb[0] > 2 * 39 or pb[3] - pb[1] > 2 * 29);
    // The part of a path: the outer wall nearest to the center of part b
    // is in part b.
    const b = app.plate.parts.items[1];
    try testing.expectEqual(@as(?usize, 1), app.plate.partAt(b.x, b.y));
    const wall = app.pickFeature(0, @intFromEnum(zs.settings.Feature.outer_wall), b.x, b.y).?;
    try testing.expectEqual(@as(?usize, 1), app.partOfPath(wall));
    try testing.expectEqual(@as(?usize, null), app.partOfPath(1 << 30));
    // Remove a part: one left.
    try app.removePart(0);
    try testing.expectEqualStrings("b.stl", app.model_name);
}

/// The STL bytes of a box, for the tests.
fn boxStl(gpa: Allocator, sx: f32, sy: f32, sz: f32) ![]u8 {
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, sx, sy, sz);
    var m = try b.finish();
    defer m.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    errdefer stl.deinit();
    try m.writeStl(&stl.writer);
    return stl.toOwnedSlice();
}

test "app: a bad file keeps the plate" {
    const gpa = testing.allocator;
    const stl = try boxStl(gpa, 20, 10, 5);
    defer gpa.free(stl);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", stl);
    try app.setOverride(-zs.settings.part_z, zs.settings.part_z, "project.infill_density", "0.35");
    // A file that is no STL and no 3MF, and a zip that is no 3MF.
    try testing.expect(std.meta.isError(app.loadStl("b.stl", "solid nothing")));
    try testing.expect(std.meta.isError(app.loadStl("c.3mf", "PK\x03\x04 broken")));
    try testing.expect(std.meta.isError(app.addStl("d.stl", "")));
    try testing.expectEqual(@as(usize, 1), app.plate.count());
    try testing.expectEqualStrings("a.stl", app.model_name);
    try testing.expectEqual(@as(usize, 1), app.overrides.items.len);
    try testing.expectEqual(State.ready, app.getState());
}

test "app: a 3MF override that this version does not know is left out" {
    const gpa = testing.allocator;
    const stl = try boxStl(gpa, 20, 10, 5);
    defer gpa.free(stl);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", stl);
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    // One good override, one of an unknown setting, one with a bad value,
    // and a line that is not an override.
    const overrides =
        "-1000000\t1000000\tproject.infill_density\t0.4\n" ++
        "-1000000\t1000000\tproject.no_such_setting\t1\n" ++
        "1\t2\tproject.wall_count\ttwo\n" ++
        "nonsense\n";
    try zs.threemf.write(gpa, &file.writer, &app.plate, overrides);

    const back = try App.create(gpa, null, null);
    defer back.destroy();
    try back.loadStl("plate.3mf", file.written());
    try testing.expectEqual(@as(usize, 1), back.plate.count());
    try testing.expectEqual(@as(usize, 1), back.overrides.items.len);
    try testing.expectEqualStrings("project.infill_density", back.overrides.items[0].name);
}

test "app: the plate changes its name, its parts, and its state" {
    const gpa = testing.allocator;
    const stl = try boxStl(gpa, 20, 10, 5);
    defer gpa.free(stl);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try testing.expectEqual(State.empty, app.getState());
    try testing.expectEqual(@as(?App.ModelInfo, null), app.modelInfo());
    for ([_][]const u8{ "a.stl", "b.stl", "c.stl" }) |n| _ = try app.addStl(n, stl);
    try testing.expectEqualStrings("a.stl and 2 more", app.model_name);
    try testing.expectEqual(State.ready, app.getState());
    // A turn of 90 degrees swaps the sides of the footprint.
    try app.rotatePart(0, 90);
    const f = app.plate.parts.items[0].footprint();
    try testing.expectApproxEqAbs(@as(f64, 10), f[2] - f[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 20), f[3] - f[1], 1e-3);
    // Three small parts fit on the bed.
    try testing.expect(try app.arrangePlate());
    try app.removePart(1);
    try testing.expectEqualStrings("a.stl and 1 more", app.model_name);
    try app.clearPlate();
    try testing.expectEqual(State.empty, app.getState());
    try testing.expectEqualStrings("", app.model_name);
    try testing.expectError(error.NoModel, app.requestSlice());
}

test "app: support marks: the place, the layer, and the radius" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.addMark(.{ .x = 10, .y = 10, .z = 1, .r = 2, .kind = .grid });
    // Another layer (0.1 mm higher): a new mark.
    try app.addMark(.{ .x = 10, .y = 10, .z = 1.1, .r = 2, .kind = .grid });
    // Far away on the same layer: a new mark.
    try app.addMark(.{ .x = 30, .y = 10, .z = 1, .r = 2, .kind = .tree });
    try testing.expectEqual(@as(usize, 3), app.marks.items.len);
    // Near the first mark, closer than the sum of the radii: it replaces
    // the mark.
    try app.addMark(.{ .x = 12, .y = 10, .z = 1, .r = 1, .kind = .block });
    try testing.expectEqual(@as(usize, 3), app.marks.items.len);
    try testing.expectEqual(zs.support.Mark.Kind.block, app.marks.items[2].kind);
    // A remove far from all marks removes none.
    try testing.expectEqual(@as(usize, 0), app.removeMarksNear(50, 50, 1, 1));
    try testing.expectEqual(@as(usize, 1), app.removeMarksNear(30, 10, 1, 0.5));
    app.clearMarks();
    try testing.expectEqual(@as(usize, 0), app.marks.items.len);
}

test "app: the state of a group goes out as a profile and comes back" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.setSetting("project.wall_count", "4");
    try app.setSetting("project.infill_pattern", "gyroid");
    try app.setSetting("filament.nozzle_temp", "230");
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try app.writeState(.project, &text.writer);

    const back = try App.create(gpa, null, null);
    defer back.destroy();
    var diag: zs.profile.Diagnostic = .{};
    try back.applyProfile(.project, "state", text.written(), &diag);
    try testing.expectEqual(@as(u32, 4), back.settings.project.wall_count);
    try testing.expectEqual(zs.settings.InfillPattern.gyroid, back.settings.project.infill_pattern);
    // Only the project group was in the text.
    try testing.expectEqual((Settings{}).filament.nozzle_temp, back.settings.filament.nozzle_temp);

    // A text with an error changes nothing, and the diagnostic has the line.
    try testing.expectError(error.InvalidValue, back.applyProfile(.project, "bad", "wall_count = 2\ninfill_pattern = \"spiral\"\n", &diag));
    try testing.expectEqual(@as(u32, 4), back.settings.project.wall_count);
    try testing.expectEqual(@as(usize, 2), diag.line);

    // A reset of the group gives the defaults.
    back.resetGroup(.project);
    try testing.expectEqual((Settings{}).project.wall_count, back.settings.project.wall_count);
}
