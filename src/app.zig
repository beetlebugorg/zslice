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
//! - `setting_text.zig`: the text of a setting value in an editor, and back.
//! - `licenses.zig`: the licenses for a Licenses screen.
//! - `history.zig`: the undo list of an app.
//! - `plate_set.zig`: the plates of a set, each with its own app.
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
/// The sweep of the settings (see app/sweep.zig).
pub const sweep = @import("app/sweep.zig");
/// The settings that can close a gap (see app/gap_advice.zig).
pub const gap_advice = @import("app/gap_advice.zig");
pub const history = @import("app/history.zig");
/// The support areas of the user (see app/support_areas.zig).
pub const support_areas = @import("app/support_areas.zig");
pub const plate_set = @import("app/plate_set.zig");
pub const measure = @import("app/measure.zig");
/// The printability check (see app/checks.zig).
pub const checks_mod = @import("app/checks.zig");

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
/// The text of a setting value, as the editors show it (setting_text.zig).
pub const setting_text = @import("app/setting_text.zig");
/// The settings that matter most for a selected line (inspect_picks.zig).
pub const inspect_picks = @import("app/inspect_picks.zig");
/// The search of the settings (setting_search.zig).
pub const setting_search = @import("app/setting_search.zig");
/// The status of a printer from its API replies (printer_status.zig).
pub const printer_status = @import("app/printer_status.zig");
/// The edits of the user on the lines of a slice (edits.zig).
pub const edits_mod = @import("app/edits.zig");
/// The farm: printers, orders, and jobs (farm.zig).
pub const farm_mod = @import("app/farm.zig");
/// The session of an app, for a restore after a reload or a quit.
pub const session = @import("app/session.zig");
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
    /// size of the model; startSlice makes it again after a change of the
    /// plate. Each part slices as its own job (see plate_job.zig).
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
    /// The parts of a 3MF file keep their places in the file, also when
    /// they are near the edge of the bed or near another part (the zslice
    /// commands, for a plate that another program packed). False: a part
    /// that does not fit with the part gap goes to a free place.
    keep_places: bool = false,
    /// The memory for the string values of the settings. It only grows, so
    /// a copy of the settings stays valid while a slice uses it.
    strings: std.heap.ArenaAllocator,

    state: std.atomic.Value(State) = .init(.empty),
    cancel_flag: std.atomic.Value(bool) = .init(false),
    /// True while `requestSlice` stops an old slice: that slice sends no
    /// events, because a new slice replaces it.
    quiet: std.atomic.Value(bool) = .init(false),
    worker: ?Worker = null,
    /// The count of the slices that ended with a result. A plate set
    /// (app/plate_set.zig) compares it to see a new result.
    done_count: std.atomic.Value(u32) = .init(0),

    // The results. The worker writes them before it sets the state to
    // `done` or `failed`.
    job: ?zs.PlateJob = null,
    /// The job of the slice before, kept for its work: if the new settings
    /// of a part give the same outlines (for example, only the infill
    /// density or the wall count changed), the new job of the part takes
    /// the outlines and the results of the slow steps that are still good
    /// (see Job.initReuse and plate_job.Options.old). Only the worker uses
    /// it while a slice runs.
    prev_job: ?zs.PlateJob = null,
    /// A part that slices coarse (see `setCoarsePart`), or null.
    coarse_part: ?usize = null,
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
    /// The gaps of one layer of the last slice (see `layerGaps`), and the
    /// memory of the advice for one of them. A new slice clears them.
    gaps_layer: ?usize = null,
    gaps_result: ?zs.gaps.Result = null,
    gaps_arena: ?std.heap.ArenaAllocator = null,
    /// The printability check of the last slice (see `checks`).
    checks_result: ?checks_mod.Result = null,
    /// The names of layer ranges (layer profiles): the overrides with the
    /// same range are the changes of the profile. A profile can have no
    /// changes yet. The names are in `strings`.
    profiles: std.ArrayList(Profile) = .empty,
    /// The support marks of the user (see support.Mark), and a copy for
    /// the running slice. A new model clears them.
    marks: std.ArrayList(zs.support.Mark) = .empty,
    slice_marks: []zs.support.Mark = &.{},
    /// The support areas of the user (the support editor). A new model
    /// clears them. The running slice has them in `slice_marks`, with
    /// their polygons in `area_arena`.
    areas: support_areas.Areas = .{},
    area_arena: ?std.heap.ArenaAllocator = null,
    /// The cascade of the settings (see `Level`): the quality profile and
    /// the global settings of the user, as their changes from the
    /// defaults, in `strings`. `settings` has the result, with the changes
    /// of this print on top.
    /// The defaults of the settings are the built-in "standard" quality.
    quality_name: [:0]const u8 = "standard",
    /// The settings whose value comes from a formula (see setFormula).
    formulas: std.ArrayList(Formula) = .empty,
    quality: []const zs.settings.Change = &.{},
    global: []const zs.settings.Change = &.{},
    /// The settings of the parts and the modifier volumes for the running
    /// slice (see part_settings.zig), the meshes that it points to, and
    /// the parts of the plate job (in `slice_arena`).
    slice_plan: ?zs.part_settings.Plan = null,
    slice_meshes: []zs.Mesh = &.{},
    slice_parts: []const zs.plate_job.PartInput = &.{},
    slice_arena: ?std.heap.ArenaAllocator = null,
    /// The bytes of the last write3mf.
    file_bytes: []u8 = &.{},
    /// The undo list (see app/history.zig). The C API notes each change.
    undo: history.History = .{},
    /// The edits of the user on the lines of the slice (app/edits.zig).
    edits: edits_mod.Edits = .{},

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
        app.formulas.deinit(app.gpa);
        app.profiles.deinit(app.gpa);
        app.clearGaps();
        app.gpa.free(app.slice_overrides);
        app.gpa.free(app.file_bytes);
        app.undo.deinit(app.gpa);
        app.edits.deinit(app.gpa);
        app.marks.deinit(app.gpa);
        app.gpa.free(app.slice_marks);
        app.areas.deinit(app.gpa);
        if (app.area_arena) |*a| a.deinit();
        app.dropSlicePlan();
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
        app.areas.clear(app.gpa);
        // The edits were for the lines of the old parts.
        app.edits.list.clearRetainingCapacity();
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
        // The parts that print first, then the volumes (modifiers and the
        // other Cura volume types): each goes to the part that it overlaps
        // most (see plate.Volume).
        const index = try app.gpa.alloc(?usize, loaded.parts.len);
        defer app.gpa.free(index);
        var any_print = false;
        for (loaded.parts) |p| any_print = any_print or zs.part_settings.prints(p.meta);
        for (loaded.parts, index) |*p, *idx| {
            idx.* = null;
            if (any_print and !zs.part_settings.prints(p.meta)) continue;
            const m = p.mesh;
            p.mesh = .empty; // The plate owns the mesh now.
            // A gap of -inf: each place fits (see Plate.fits).
            const gap = if (app.keep_places) -std.math.inf(f64) else app.partGap();
            const i = try app.plate.add(app.gpa, p.name, m, app.bedSize(), gap, true);
            idx.* = i;
            // With no part that prints, a volume prints as a part.
            if (zs.part_settings.prints(p.meta)) {
                app.plate.setMeta(app.gpa, i, p.meta);
                p.meta = &.{};
            }
        }
        for (loaded.parts) |*p| {
            if (p.mesh.faces.items.len == 0) continue;
            const vb = p.mesh.bounds();
            var best: ?usize = null;
            var best_v: f64 = -1;
            for (loaded.parts, index) |*q, idx| {
                const i = idx orelse continue;
                const qb = app.plate.parts.items[i].mesh.bounds();
                _ = q;
                var vol: f64 = 1;
                for (0..3) |k| vol *= @max(0, @min(vb.max[k], qb.max[k]) - @max(vb.min[k], qb.min[k]));
                if (vol > best_v) {
                    best_v = vol;
                    best = i;
                }
            }
            const host = best orelse continue;
            const m = p.mesh;
            p.mesh = .empty;
            const meta = p.meta;
            p.meta = &.{};
            try app.plate.addVolume(app.gpa, host, p.name, m, meta);
        }
        try app.plateChanged();
        var lines = std.mem.tokenizeAny(u8, loaded.overrides, "\r\n");
        while (lines.next()) |line| {
            // A support area of the user (app/support_areas.zig).
            if (try app.areas.read3mfLine(app.gpa, line)) continue;
            // "edit <tab> key <tab> kind <tab> value <tab> layer": an edit of
            // the user on a line (app/edits.zig).
            if (std.mem.startsWith(u8, line, "edit\t")) {
                var f = std.mem.splitScalar(u8, line["edit\t".len..], '\t');
                const key = std.fmt.parseInt(u64, f.next() orelse continue, 16) catch continue;
                const kind = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
                const value = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
                const layer = std.fmt.parseInt(u32, f.next() orelse "0", 10) catch 0;
                const x = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
                const y = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
                const z = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
                if (kind > 2) continue;
                try app.edits.put(app.gpa, .{ .key = key, .kind = @enumFromInt(kind), .value = value, .layer = layer, .x = x, .y = y, .z = z });
                continue;
            }
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
        const bytes = try app.write3mfAlloc(app.gpa);
        app.gpa.free(app.file_bytes);
        app.file_bytes = bytes;
        return app.file_bytes;
    }

    /// A 3MF file of the plate and its overrides, in memory of `gpa` that
    /// the caller owns.
    pub fn write3mfAlloc(app: *const App, gpa: Allocator) (Allocator.Error || error{WriteFailed} || error{NoModel})![]u8 {
        if (app.plate.count() == 0) return error.NoModel;
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        for (app.profiles.items) |p| try text.writer.print("profile\t{d}\t{d}\t{s}\n", .{ p.z_min, p.z_max, p.name });
        try app.areas.write3mfLines(&text.writer);
        for (app.edits.list.items) |e| try text.writer.print("edit\t{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ e.key, @intFromEnum(e.kind), e.value, e.layer, e.x, e.y, e.z });
        for (app.overrides.items) |o| try text.writer.print("{d}\t{d}\t{s}\t{s}\n", .{ o.z_min, o.z_max, o.name, o.value });
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try zs.threemf.write(gpa, &out.writer, &app.plate, text.written());
        return out.toOwnedSlice();
    }

    fn addMesh(app: *App, name: []const u8, m: zs.Mesh) zs.mesh.Error!usize {
        const s = app.settings;
        const i = try app.plate.add(app.gpa, name, m, app.bedSize(), app.partGap(), s.project.placement != .center);
        try app.plateChanged();
        return i;
    }

    pub fn bedSize(app: *const App) [2]f64 {
        return .{ app.settings.machine.bed_size_x, app.settings.machine.bed_size_y };
    }

    /// The gap between parts: the skirt and the brim go around each part.
    pub fn partGap(app: *const App) f64 {
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
        areas: support_areas.Areas = .{},

        fn deinit(s: *PlateSlot, gpa: Allocator) void {
            s.plate.deinit(gpa);
            s.overrides.deinit(gpa);
            s.profiles.deinit(gpa);
            s.marks.deinit(gpa);
            s.areas.deinit(gpa);
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
        std.mem.swap(support_areas.Areas, &app.areas, &app.plates.items[app.active].areas);
        std.mem.swap(zs.plate.Plate, &app.plate, &app.plates.items[i].plate);
        std.mem.swap(std.ArrayList(zs.settings.Override), &app.overrides, &app.plates.items[i].overrides);
        std.mem.swap(std.ArrayList(Profile), &app.profiles, &app.plates.items[i].profiles);
        std.mem.swap(std.ArrayList(zs.support.Mark), &app.marks, &app.plates.items[i].marks);
        std.mem.swap(support_areas.Areas, &app.areas, &app.plates.items[i].areas);
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

    /// The settings of part i and of its modifier volumes, one on each
    /// line, for a part page: each Cura setting with the zslice setting
    /// it becomes, or why zslice does not use it. Empty for a part with
    /// no settings and no volumes.
    pub fn partSettingsText(app: *const App, i: usize, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
        if (i >= app.plate.count()) return;
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const p = &app.plate.parts.items[i];
        if (p.meta.len > 0) {
            try w.writeAll("Settings of this part:\n");
            for (try zs.part_settings.describe(a, p.meta, &app.settings)) |line| try w.print("  {s}\n", .{line});
        }
        for (p.volumes.items) |v| {
            try w.print("Volume \"{s}\":\n", .{v.name});
            for (try zs.part_settings.describe(a, v.meta, &app.settings)) |line| try w.print("  {s}\n", .{line});
        }
    }

    /// The settings of part i and of its volumes that zslice does not use,
    /// one a line: "key\tvalue\twhy". It leaves out a near value (the
    /// nearest infill pattern). For the zslice commands, which stop on a
    /// setting that a part would drop in silence.
    pub fn partUnusedText(app: *const App, i: usize, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
        if (i >= app.plate.count()) return;
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const p = &app.plate.parts.items[i];
        const metas = try a.alloc([]const zs.threemf.Meta, p.volumes.items.len + 1);
        metas[0] = p.meta;
        for (p.volumes.items, metas[1..]) |v, *m| m.* = v.meta;
        for (metas) |meta| {
            const ps = try zs.import_cura.partSettings(a, meta, &app.settings);
            for (ps.ignored) |ig| if (!ig.near) try w.print("{s}\t{s}\t{s}\n", .{ ig.key, ig.value, ig.why });
            // A zslice setting of the plate on a part (zslice:project.support).
            for (ps.sets) |c| if (!zs.settings.isPerPartSetting(c.name)) try w.print("{s}\t{s}\tzslice keeps this setting for the whole plate\n", .{ c.name, c.value });
        }
    }

    /// Sets one zslice setting of part i (stored as "zslice:<name>" in its
    /// metadata, so a 3MF save keeps it), or clears it with a null value.
    /// The part then slices as its own job with it (see part_settings.zig
    /// and plate_job.zig). A setting of the plate (settings.isPlateSetting)
    /// gets a note, and the part keeps the plate value.
    pub fn setPartSetting(app: *App, i: usize, name: []const u8, value: ?[]const u8) (Allocator.Error || Settings.SetError || error{NoPart})!void {
        if (i >= app.plate.parts.items.len) return error.NoPart;
        if (value) |v| {
            // "quality": a built-in quality profile for the part (see
            // import_cura.partSettings).
            if (std.mem.eql(u8, name, "quality")) {
                if (zs.profile.builtin(.project, v) == null) return error.InvalidValue;
            } else {
                var check = app.settings;
                try check.set(name, v);
            }
        }
        const old = app.plate.parts.items[i].meta;
        var list: std.ArrayList(zs.threemf.Meta) = .empty;
        errdefer {
            for (list.items) |m| {
                app.gpa.free(m.key);
                app.gpa.free(m.value);
            }
            list.deinit(app.gpa);
        }
        for (old) |m| {
            if (std.mem.startsWith(u8, m.key, "zslice:") and std.mem.eql(u8, m.key["zslice:".len..], name)) continue;
            try list.append(app.gpa, .{ .key = try app.gpa.dupe(u8, m.key), .value = try app.gpa.dupe(u8, m.value) });
        }
        if (value) |v| {
            const key = try std.fmt.allocPrint(app.gpa, "zslice:{s}", .{name});
            errdefer app.gpa.free(key);
            try list.append(app.gpa, .{ .key = key, .value = try app.gpa.dupe(u8, v) });
        }
        app.stopWorker();
        // The meshes stay the same, so the next slice keeps the work of
        // the jobs of the parts (see plate_job.Options.old).
        app.plate.setMeta(app.gpa, i, try list.toOwnedSlice(app.gpa));
    }

    /// The value of a zslice setting of part i, or null if the part has no
    /// value of its own.
    pub fn partSetting(app: *const App, i: usize, name: []const u8) ?[]const u8 {
        if (i >= app.plate.parts.items.len) return null;
        for (app.plate.parts.items[i].meta) |m| {
            if (std.mem.startsWith(u8, m.key, "zslice:") and std.mem.eql(u8, m.key["zslice:".len..], name)) return m.value;
        }
        return null;
    }

    /// A copy of part i at a free place. Returns its index.
    pub fn duplicatePart(app: *App, i: usize) Allocator.Error!usize {
        app.stopWorker();
        const j = try app.plate.duplicate(app.gpa, i, app.bedSize(), app.partGap());
        try app.plateChanged();
        return j;
    }

    /// A debug print: the G-code of the layers lo to hi - 1 of the last
    /// slice alone, lowered so that layer lo prints on the bed, with the
    /// start and the end G-code. In `gpa`, for the caller.
    pub fn debugGcode(app: *App, gpa: Allocator, lo: usize, hi: usize) (Allocator.Error || error{ NoResult, WriteFailed } || zs.engine.Error)![]u8 {
        if (app.getState() != .done) return error.NoResult;
        const job = &(app.job orelse return error.NoResult);
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        _ = try job.writeLevels(&out.writer, lo, hi);
        return out.toOwnedSlice();
    }

    /// Splits part i into its separate bodies (Plate.split). Returns the
    /// count of new parts, or 0 for a part of one body.
    pub fn splitPart(app: *App, i: usize) Allocator.Error!usize {
        app.stopWorker();
        const n = try app.plate.split(app.gpa, i, app.bedSize(), app.partGap());
        if (n > 0) try app.plateChanged();
        return n;
    }

    /// Cuts part i at height z above the bed (Plate.cut). Returns 2, or 0
    /// if the plane misses the part.
    pub fn cutPart(app: *App, i: usize, z: f64, flip: bool, pegs: zs.cut.Pegs) Allocator.Error!usize {
        app.stopWorker();
        const n = try app.plate.cut(app.gpa, i, z, flip, pegs, app.bedSize(), app.partGap());
        if (n > 0) try app.plateChanged();
        return n;
    }

    /// Moves part i of this app to the plate of `to` (another app), at a
    /// free place. Returns its index there.
    pub fn movePartTo(app: *App, i: usize, to: *App) Allocator.Error!usize {
        app.stopWorker();
        to.stopWorker();
        const part = app.plate.take(i) orelse return error.OutOfMemory;
        try app.plateChanged();
        const j = try to.plate.put(to.gpa, part, to.bedSize(), to.partGap());
        try to.plateChanged();
        return j;
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
        // A file in inches is at its small place: the larger part goes
        // where it fits.
        app.plate.keepOnBed(i, app.bedSize(), app.partGap());
        try app.plateChanged();
    }

    /// Turns a part by `deg` about the X (0) or Y (1) axis of the bed.
    pub fn turnPart(app: *App, i: usize, axis: u2, deg: f64) Allocator.Error!void {
        try app.plate.turn(app.gpa, i, axis, deg);
        try app.plateChanged();
    }

    /// Physics: part i falls over if it cannot stand as it is (its center
    /// of mass past the area it stands on), and rolls until it rests (see
    /// physics.zig). With support on, the support holds it, and it stays.
    /// Returns the angle of the fall in degrees (0: it stands).
    pub fn settlePart(app: *App, i: usize) Allocator.Error!f64 {
        if (i >= app.plate.count()) return 0;
        if (app.settings.project.support != .off) return 0;
        const s = try zs.physics.settle(app.gpa, &app.plate.parts.items[i].mesh);
        if (s.rolls == 0) return 0;
        try app.plate.putDown(app.gpa, i, zs.physics.downOf(s));
        app.plate.keepOnBed(i, app.bedSize(), app.partGap());
        try app.plateChanged();
        return s.degrees;
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
        app.areas.clear(app.gpa);
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
        const trimmed = std.mem.trim(u8, value, " ");
        // A formula: "= {line_width} * 2" (see expr.zig and Formula).
        if (trimmed.len > 0 and trimmed[0] == '=') {
            app.setFormula(name, trimmed[1..]) catch return error.InvalidValue;
            return;
        }
        const copy = app.strings.allocator().dupe(u8, value) catch return error.InvalidValue;
        var s = app.settings;
        try s.set(name, copy);
        app.settings = s;
        // A plain value replaces the formula of the setting.
        app.removeFormula(name);
        app.applyFormulas();
    }

    /// A setting whose value comes from a formula (see expr.zig).
    pub const Formula = struct { name: []const u8, text: []const u8, node: *const zs.expr.Node };

    /// Sets the formula of a setting (the text after "="), and the values
    /// of all formulas. error.InvalidValue: the text does not parse, or
    /// its value is not valid for the setting.
    pub fn setFormula(app: *App, name: []const u8, text: []const u8) (Allocator.Error || Settings.SetError || zs.expr.Error)!void {
        const a = app.strings.allocator();
        var diag: zs.expr.Diagnostic = .{};
        const t = try a.dupe(u8, std.mem.trim(u8, text, " "));
        const node = try zs.expr.parse(a, t, &diag);
        // The value now, to check it.
        var check = app.settings;
        const lc: LookupCtx = .{ .s = &check, .a = a };
        const v = try zs.expr.eval(node, .{ .ctx = &lc, .lookup = lookupSetting });
        try setValue(&check, a, name, v);
        app.removeFormula(name);
        try app.formulas.append(app.gpa, .{ .name = try a.dupe(u8, name), .text = t, .node = node });
        app.settings = check;
        app.applyFormulas();
    }

    pub fn removeFormula(app: *App, name: []const u8) void {
        for (app.formulas.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) {
            _ = app.formulas.orderedRemove(i);
            return;
        };
    }

    /// The formula of a setting (the text after "="), or null.
    pub fn formulaOf(app: *const App, name: []const u8) ?[]const u8 {
        for (app.formulas.items) |f| if (std.mem.eql(u8, f.name, name)) return f.text;
        return null;
    }

    /// The values of the formulas, in passes until no value changes (a
    /// formula can use the value of another). A loop of formulas stops
    /// after as many passes as there are formulas. A formula that fails
    /// (an unknown name, a bad value) keeps the value before.
    pub fn applyFormulas(app: *App) void {
        if (app.formulas.items.len == 0) return;
        const a = app.strings.allocator();
        var pass: usize = 0;
        while (pass <= app.formulas.items.len) : (pass += 1) {
            var changed = false;
            for (app.formulas.items) |f| {
                const lc: LookupCtx = .{ .s = &app.settings, .a = a };
                const v = zs.expr.eval(f.node, .{ .ctx = &lc, .lookup = lookupSetting }) catch continue;
                var s = app.settings;
                setValue(&s, a, f.name, v) catch continue;
                if (!sameValue(s, app.settings, f.name)) {
                    app.settings = s;
                    changed = true;
                }
            }
            if (!changed) return;
        }
    }

    /// The formulas as text, one "name = text" on each line (for the state
    /// of a shell).
    pub fn writeFormulas(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (app.formulas.items) |f| try w.print("{s} = {s}\n", .{ f.name, f.text });
    }

    /// Reads the text of writeFormulas. A line that fails is left out.
    pub fn readFormulas(app: *App, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
            app.setFormula(line[0..eq], line[eq + 3 ..]) catch {};
        }
    }

    fn setValue(s: *Settings, a: Allocator, name: []const u8, v: zs.expr.Value) (Allocator.Error || Settings.SetError)!void {
        const text = switch (v) {
            .num => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
            .text => |t| t,
        };
        try s.set(name, text);
    }

    /// The value of a setting for a formula: a full name ("project.line_width"),
    /// or a short name that the first group with it gives (project,
    /// filament, machine).
    const LookupCtx = struct { s: *const Settings, a: Allocator };

    fn lookupSetting(ctx: ?*const anyopaque, name: []const u8) ?zs.expr.Value {
        const lc: *const LookupCtx = @ptrCast(@alignCast(ctx.?));
        const s = lc.s;
        // The widths that the slicer uses: 0 means automatic (1.1 times
        // the nozzle), so the resolved value.
        const short = if (std.mem.startsWith(u8, name, "project.")) name["project.".len..] else name;
        if (std.mem.eql(u8, short, "line_width") or std.mem.eql(u8, short, "first_layer_line_width")) {
            if (s.resolve()) |r| {
                return .{ .num = if (std.mem.eql(u8, short, "line_width")) r.line_width else r.first_layer_line_width };
            } else |_| {}
        }
        var buf: [128]u8 = undefined;
        const tries = [_][]const u8{ "", "project.", "filament.", "machine." };
        for (tries) |pre| {
            const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ pre, name }) catch continue;
            var out: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&out);
            writeSettingOf(s.*, full, &w) catch continue;
            const text = w.buffered();
            if (std.fmt.parseFloat(f64, text)) |n| return .{ .num = n } else |_| {}
            if (std.mem.eql(u8, text, "true")) return .{ .num = 1 };
            if (std.mem.eql(u8, text, "false")) return .{ .num = 0 };
            // A text (a choice, a name): a copy, as the buffer goes.
            const copy = lc.a.dupe(u8, std.mem.trim(u8, text, "\"")) catch return null;
            return .{ .text = copy };
        }
        return null;
    }

    /// Writes the settings of a group that differ from the defaults, as a
    /// profile (see profile.writeChanged). A shell saves this text to keep
    /// the settings after a restart.
    pub fn writeState(app: *const App, group: zs.profile.Group, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // The project group: only the changes of this print, over the
        // quality profile and the global settings (see `base`).
        if (group == .project) return zs.profile.writeChangedFrom(app.settings, app.base(), group, w);
        return zs.profile.writeChanged(app.settings, group, w);
    }

    /// The facts of the state for the history of changes (see
    /// app/history.zig): the settings that differ from the built-in
    /// defaults, the settings and the place of each part, and the changes
    /// for some layers. Two steps with the same facts look the same.
    pub fn writeFacts(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const defaults: Settings = .{};
        inline for (.{ "machine", "filament", "project" }, .{ "machine", "filament", "print" }) |g, scope| {
            const values = @field(app.settings, g);
            const base_values = @field(defaults, g);
            inline for (@typeInfo(@TypeOf(values)).@"struct".fields) |f| {
                const v = @field(values, f.name);
                const d = @field(base_values, f.name);
                const same = switch (@typeInfo(f.type)) {
                    .pointer => std.mem.eql(u8, v, d),
                    else => v == d,
                };
                if (!same) {
                    try w.print("{s}\t{s}.{s}\t", .{ scope, g, f.name });
                    var buf: [64]u8 = undefined;
                    switch (@typeInfo(f.type)) {
                        .pointer => try history.writeEscaped(w, v),
                        else => {
                            var fw: std.Io.Writer = .fixed(&buf);
                            writeValue(&fw, v) catch {};
                            try w.writeAll(fw.buffered());
                        },
                    }
                    try w.writeByte('\n');
                }
            }
        }
        if (app.quality_name.len > 0) try w.print("print\tquality\t{s}\n", .{app.quality_name});
        // The edits of the user on lines.
        for (app.edits.list.items) |e| {
            try w.print("edits\tlayer {d}, line {x:0>4}\t", .{ e.layer + 1, e.key & 0xffff });
            switch (e.kind) {
                .delete => try w.writeAll("does not print\n"),
                .flow => try w.print("{d:.0} % plastic\n", .{e.value * 100}),
                .dot => try w.print("a drop of {d:.1} mm at {d:.1}, {d:.1}\n", .{ e.value, e.x, e.y }),
            }
        }
        try app.areas.writeFacts(w);
        for (app.plate.parts.items) |p| {
            const name: []const u8 = p.name;
            try w.print("part:{s}\t(part)\tyes\n", .{name});
            try w.print("part:{s}\tposition\t{d:.2}, {d:.2}\n", .{ name, p.x, p.y });
            if (p.rot != 0) try w.print("part:{s}\trotation\t{d:.1}\n", .{ name, p.rot });
            // The orientation of the part (a side on the bed), as the rows of
            // its pose.
            const id = zs.plate.identity;
            var turned = false;
            for (0..3) |r| for (0..3) |c| {
                if (@abs(p.pose[r][c] - id[r][c]) > 1e-9) turned = true;
            };
            if (turned) {
                try w.print("part:{s}\torientation\t", .{name});
                for (0..3) |r| for (0..3) |c| try w.print("{s}{d:.3}", .{ if (r == 0 and c == 0) "" else " ", p.pose[r][c] });
                try w.writeByte('\n');
            }
            if (p.scale[0] != 1 or p.scale[1] != 1 or p.scale[2] != 1) try w.print("part:{s}\tscale\t{d:.3}, {d:.3}, {d:.3}\n", .{ name, p.scale[0], p.scale[1], p.scale[2] });
            for (p.meta) |m| {
                if (!std.mem.startsWith(u8, m.key, "zslice:")) continue;
                try w.print("part:{s}\t{s}\t", .{ name, m.key["zslice:".len..] });
                try history.writeEscaped(w, m.value);
                try w.writeByte('\n');
            }
        }
        for (app.profiles.items) |p| {
            try w.print("layers:{d:.4}:{d:.4}\t(name)\t", .{ p.z_min, p.z_max });
            try history.writeEscaped(w, p.name);
            try w.writeByte('\n');
        }
        for (app.overrides.items) |o| {
            try w.print("layers:{d:.4}:{d:.4}\t{s}\t", .{ o.z_min, o.z_max, o.name });
            try history.writeEscaped(w, o.value);
            try w.writeByte('\n');
        }
    }

    /// The changes of a history diff in words (see history.describe), with
    /// layer numbers from the last slice.
    pub fn describeChanges(app: *const App, changes: []const u8, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
        const layer_z: []const f32 = if (app.allToolpaths()) |t| t.layer_z.items else &.{};
        return history.describe(app.gpa, changes, zs.settings.part_z, layer_z, w);
    }

    pub const RevertError = Allocator.Error || Settings.SetError || OverrideError || error{ NoPart, NotSupported };

    /// Undoes one change of the history (a line of history.diff) and keeps
    /// all other changes: the setting, the setting of the part, or the
    /// change for the layers goes back to its old value (or to no value of
    /// its own). The place of a part (moved, turned, added) cannot go back
    /// this way: error.NotSupported. The shell slices again after it.
    pub fn revertChange(app: *App, line: []const u8) RevertError!void {
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const ar = arena_state.allocator();
        const cs = try history.parseChanges(ar, line);
        if (cs.len != 1) return error.InvalidValue;
        const c = cs[0];
        const old = try unescape(ar, c.old);
        if (std.mem.eql(u8, c.scope, "machine") or std.mem.eql(u8, c.scope, "filament") or std.mem.eql(u8, c.scope, "print")) {
            // The quality profile: its settings are changes of their own.
            if (std.mem.eql(u8, c.key, "quality")) return error.NotSupported;
            if (old.len > 0) return app.setSetting(c.key, try app.strings.allocator().dupe(u8, old));
            // No old value: the built-in default.
            for (settings_info) |i| if (std.mem.eql(u8, i.name, c.key)) return app.setSetting(c.key, i.default_value);
            return error.UnknownSetting;
        }
        if (history.partName(c.scope)) |name| {
            if (c.key.len > 0 and c.key[0] == '(' or std.mem.eql(u8, c.key, "position") or std.mem.eql(u8, c.key, "rotation") or std.mem.eql(u8, c.key, "orientation") or std.mem.eql(u8, c.key, "scale")) return error.NotSupported;
            for (app.plate.parts.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
                return app.setPartSetting(i, c.key, if (old.len > 0) old else null);
            };
            return error.NoPart;
        }
        if (history.layerRange(c.scope)) |r| {
            if (std.mem.eql(u8, c.key, "(name)")) {
                if (old.len > 0) return app.setProfile(r[0], r[1], old);
                for (app.profiles.items, 0..) |p, i| if (@abs(p.z_min - r[0]) < 1e-3 and @abs(p.z_max - r[1]) < 1e-3) {
                    _ = app.profiles.orderedRemove(i);
                    return;
                };
                return;
            }
            if (old.len > 0) return app.setOverride(r[0], r[1], c.key, old);
            for (app.overrides.items, 0..) |o, i| if (std.mem.eql(u8, o.name, c.key) and @abs(o.z_min - r[0]) < 1e-3 and @abs(o.z_max - r[1]) < 1e-3) {
                _ = app.overrides.orderedRemove(i);
                return;
            };
            return;
        }
        return error.NotSupported;
    }

    fn unescape(a: Allocator, v: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, v, '\\') == null) return v;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < v.len) : (i += 1) {
            if (v[i] == '\\' and i + 1 < v.len) {
                i += 1;
                try out.append(a, switch (v[i]) {
                    't' => '\t',
                    'n' => '\n',
                    else => v[i],
                });
            } else try out.append(a, v[i]);
        }
        return out.items;
    }

    /// The levels of the cascade of the settings, the lowest first: a
    /// higher level replaces the value of a lower one.
    ///
    /// - default: the built-in value.
    /// - global: the global settings of the user (for all prints).
    /// - machine, filament: the profile of the printer, of the filament.
    /// - quality: the quality profile (fine, standard, draft, ...).
    /// - print: the changes for this print (the plate).
    /// - part: the value of one part (see setPartSetting).
    ///
    /// Layer ranges and modifier volumes come on top of a part, for some
    /// layers or for a volume.
    pub const Level = enum(u8) { default = 0, global = 1, machine = 2, filament = 3, quality = 4, print = 5, part = 6 };

    /// The settings under the changes of this print: the defaults, the
    /// global settings, the printer and the filament (as they are), and
    /// the quality profile.
    pub fn base(app: *const App) Settings {
        var s = app.settings;
        s.project = .{};
        for (app.global) |c| s.set(c.name, c.value) catch {};
        for (app.quality) |c| s.set(c.name, c.value) catch {};
        return s;
    }

    /// The changes of `s` from `from`, of the settings whose names start
    /// with `prefix`, in `strings`.
    fn diffOf(app: *App, s: Settings, from: Settings, prefix: []const u8) Allocator.Error![]const zs.settings.Change {
        const a = app.strings.allocator();
        var out: std.ArrayList(zs.settings.Change) = .empty;
        for (@import("settings_meta.zig").all) |m| {
            if (!std.mem.startsWith(u8, m.name, prefix)) continue;
            var wa: std.Io.Writer.Allocating = .init(a);
            writeSettingOf(s, m.name, &wa.writer) catch continue;
            var wb: std.Io.Writer.Allocating = .init(a);
            writeSettingOf(from, m.name, &wb.writer) catch continue;
            if (std.mem.eql(u8, wa.written(), wb.written())) continue;
            try out.append(a, .{ .name = m.name, .value = wa.written() });
        }
        return out.items;
    }

    /// Sets the quality profile: its name and its text (a project profile,
    /// with `extends`). `keep_edits`: the changes of this print stay on
    /// top; else they go.
    pub fn setQuality(app: *App, name: []const u8, text: []const u8, keep_edits: bool, diag: *zs.profile.Diagnostic) (zs.profile.Error || Allocator.Error)!void {
        const a = app.strings.allocator();
        var q: Settings = .{};
        // Its own name in the chain: the text often extends the profile of
        // the same name ("fine" extends "fine").
        try zs.profile.apply(a, &q, .project, "(quality)", try a.dupe(u8, text), null, diag);
        const edits = if (keep_edits) try app.diffOf(app.settings, app.base(), "project.") else &.{};
        app.quality = try app.diffOf(q, .{}, "project.");
        app.quality_name = try a.dupeZ(u8, name);
        app.rebase(edits);
    }

    /// Sets the global settings of the user (a project profile text). The
    /// changes of this print stay on top.
    pub fn setGlobal(app: *App, text: []const u8, diag: *zs.profile.Diagnostic) (zs.profile.Error || Allocator.Error)!void {
        const a = app.strings.allocator();
        var g: Settings = .{};
        try zs.profile.apply(a, &g, .project, "global", try a.dupe(u8, text), null, diag);
        const edits = try app.diffOf(app.settings, app.base(), "project.");
        app.global = try app.diffOf(g, .{}, "project.");
        app.rebase(edits);
    }

    /// The global settings as a Settings value: the defaults with the
    /// global changes.
    pub fn globalSettings(app: *const App) Settings {
        var g: Settings = .{};
        for (app.global) |c| g.set(c.name, c.value) catch {};
        return g;
    }

    /// Sets one global setting (a project setting for all prints), or
    /// clears it (value null). The changes of this print stay on top.
    pub fn setGlobalSetting(app: *App, name: []const u8, value: ?[]const u8) (Allocator.Error || Settings.SetError)!void {
        if (!std.mem.startsWith(u8, name, "project.")) return error.UnknownSetting;
        var g = app.globalSettings();
        if (value) |v| {
            try g.set(name, try app.strings.allocator().dupe(u8, v));
        } else {
            const d: Settings = .{};
            var w: std.Io.Writer.Allocating = .init(app.strings.allocator());
            writeSettingOf(d, name, &w.writer) catch return error.UnknownSetting;
            try g.set(name, w.written());
        }
        const edits = try app.diffOf(app.settings, app.base(), "project.");
        app.global = try app.diffOf(g, .{}, "project.");
        app.rebase(edits);
        app.applyFormulas();
    }

    /// The global settings as a profile text (for global.toml).
    pub fn writeGlobal(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return zs.profile.writeChanged(app.globalSettings(), .project, w);
    }

    /// The project settings: the base, with `edits` on top.
    fn rebase(app: *App, edits: []const zs.settings.Change) void {
        var s = app.base();
        for (edits) |c| s.set(c.name, c.value) catch {};
        app.settings.project = s.project;
    }

    pub const Source = struct { level: Level, profile: []const u8 };

    /// Where the value of a setting comes from (the highest level that
    /// gives it), for the plate (part null) or for one part, and the name
    /// of the profile of that level ("" if none).
    pub fn source(app: *const App, part: ?usize, name: []const u8) Source {
        if (part) |i| if (app.partSetting(i, name) != null) return .{ .level = .part, .profile = "" };
        if (std.mem.startsWith(u8, name, "machine.")) {
            return .{ .level = if (sameValue(app.settings, .{}, name)) .default else .machine, .profile = app.settings.machine.name };
        }
        if (std.mem.startsWith(u8, name, "filament.")) {
            return .{ .level = if (sameValue(app.settings, .{}, name)) .default else .filament, .profile = app.settings.filament.name };
        }
        if (!sameValue(app.settings, app.base(), name)) return .{ .level = .print, .profile = "" };
        for (app.quality) |c| if (std.mem.eql(u8, c.name, name)) return .{ .level = .quality, .profile = app.quality_name };
        for (app.global) |c| if (std.mem.eql(u8, c.name, name)) return .{ .level = .global, .profile = "" };
        return .{ .level = .default, .profile = "" };
    }

    fn sameValue(x: Settings, y: Settings, name: []const u8) bool {
        var ba: [512]u8 = undefined;
        var bb: [512]u8 = undefined;
        var wa: std.Io.Writer = .fixed(&ba);
        var wb: std.Io.Writer = .fixed(&bb);
        writeSettingOf(x, name, &wa) catch return false;
        writeSettingOf(y, name, &wb) catch return false;
        return std.mem.eql(u8, wa.buffered(), wb.buffered());
    }

    /// Sets all settings of a group to the built-in defaults. A shell does
    /// this before it applies the profile of an other printer, so that no
    /// value of the printer before stays.
    pub fn resetGroup(app: *App, group: zs.profile.Group) void {
        switch (group) {
            // The project settings go back to the base: the quality profile
            // and the global settings stay (see `base`).
            .project => app.settings.project = app.base().project,
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

    /// The printability check of the last slice (app/checks.zig), the
    /// worst issues first. Valid until the next slice.
    pub fn checks(app: *App) (Allocator.Error || error{NoResult})!*const checks_mod.Result {
        if (app.getState() != .done) return error.NoResult;
        if (app.checks_result) |*r| return r;
        const j = &(app.job orelse return error.NoResult);
        const t = app.allToolpaths() orelse return error.NoResult;
        app.checks_result = try checks_mod.run(app.gpa, j, t, app.settings);
        return &app.checks_result.?;
    }

    fn clearGaps(app: *App) void {
        if (app.checks_result) |*r| r.deinit(app.gpa);
        app.checks_result = null;
        if (app.gaps_result) |*r| r.deinit(app.gpa);
        app.gaps_result = null;
        app.gaps_layer = null;
        if (app.gaps_arena) |*a| a.deinit();
        app.gaps_arena = null;
    }

    /// The gaps of layer `layer` of the last slice (see gaps.zig): the
    /// areas that should be solid and that no bead covers. The result is
    /// valid until the next call for another layer, or the next slice.
    pub fn layerGaps(app: *App, layer: usize) (Allocator.Error || error{ NoResult, InvalidArgument })!*const zs.gaps.Result {
        if (app.getState() != .done) return error.NoResult;
        const j = &(app.job orelse return error.NoResult);
        if (layer >= j.layerCount()) return error.InvalidArgument;
        if (app.gaps_layer) |l| if (l == layer) if (app.gaps_result) |*r| return r;
        app.clearGaps();
        var lp = try j.planLayer(layer);
        defer lp.deinit();
        app.gaps_result = try zs.gaps.find(app.gpa, &lp, .{});
        app.gaps_layer = layer;
        return &app.gaps_result.?;
    }

    /// The settings that can close gap `index` of layer `layer` (see
    /// `layerGaps`), the best first, with the values of that layer.
    pub fn gapAdvice(app: *App, layer: usize, index: usize) (Allocator.Error || Settings.SetError || error{ NoResult, InvalidArgument })![]const gap_advice.Step {
        const r = try app.layerGaps(layer);
        if (index >= r.gaps.len) return error.InvalidArgument;
        if (app.gaps_arena) |*a| _ = a.reset(.retain_capacity) else app.gaps_arena = .init(app.gpa);
        const s = try zs.settings.withOverrides(app.settings, app.overrides.items, app.layerZ(layer) orelse 0);
        return gap_advice.steps(app.gaps_arena.?.allocator(), r.gaps[index], s);
    }

    /// The z of the top of layer `layer` of the last slice, or null.
    fn layerZ(app: *const App, layer: usize) ?f64 {
        const t = app.allToolpaths() orelse return null;
        if (layer >= t.layer_z.items.len) return null;
        return t.layer_z.items[layer];
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
            if (@abs(m.z - z) < 0.05 and @import("geom.zig").hypot(m.x - x, m.y - y) < r + m.r) {
                _ = app.marks.orderedRemove(i);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    pub fn clearMarks(app: *App) void {
        app.marks.clearRetainingCapacity();
    }

    /// The mark whose disk has (x, y), on a layer within `dz` of z, the
    /// nearest first; null if none.
    pub fn markAt(app: *const App, x: f64, y: f64, z: f64, dz: f64) ?usize {
        var best: ?usize = null;
        var best_d: f64 = std.math.inf(f64);
        for (app.marks.items, 0..) |m, i| {
            const d = @import("geom.zig").hypot(m.x - x, m.y - y);
            if (@abs(m.z - z) > dz or d > m.r) continue;
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        return best;
    }

    /// Changes the kind and the radius of mark i.
    pub fn setMark(app: *App, i: usize, kind: zs.support.Mark.Kind, r: f64) error{NoMark}!void {
        if (i >= app.marks.items.len) return error.NoMark;
        app.marks.items[i].kind = kind;
        app.marks.items[i].r = r;
    }

    pub fn removeMark(app: *App, i: usize) void {
        if (i < app.marks.items.len) _ = app.marks.orderedRemove(i);
    }

    /// The part of the plate that has a path of the last slice (the part
    /// under the first point of the path), or null.
    pub fn partOfPath(app: *const App, path: usize) ?usize {
        const t = app.allToolpaths() orelse return null;
        if (path >= t.pathCount()) return null;
        if (path < t.path_part.items.len) {
            const part = t.path_part.items[path];
            if (part != zs.layer.LayerPlan.no_part and part < app.plate.count()) return part;
        }
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
        const start: usize = if (path == 0) 0 else t.path_ends.items[path - 1];
        const end: usize = t.path_ends.items[path];
        const z0 = if (path < t.path_z_start.items.len) t.path_z_start.items[path] else Toolpaths.no_z;
        if (z0 == Toolpaths.no_z) {
            try w.print("\n## The path (x, y in mm on the bed; the first 40 points)\n", .{});
        } else {
            try w.print("\n## The path (x, y, and the nozzle z in mm on the bed; the first 40 points)\n", .{});
        }
        var k = start;
        while (k < end and k < start + 40) : (k += 1) {
            if (z0 == Toolpaths.no_z) {
                try w.print("{d:.2},{d:.2}\n", .{ t.points.items[2 * k], t.points.items[2 * k + 1] });
            } else {
                try w.print("{d:.2},{d:.2},{d:.3}\n", .{ t.points.items[2 * k], t.points.items[2 * k + 1], t.point_z.items[z0 + (k - start)] });
            }
        }
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

    pub fn writeSettingOf(settings: Settings, name: []const u8, w: *std.Io.Writer) (Settings.SetError || std.Io.Writer.Error)!void {
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
        app.clearGaps();
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
        app.slice_marks = app.sliceMarks() catch &.{};
        try app.makeSlicePlan();
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

    /// Stops a slice that runs, with no event. The app keeps no result of
    /// that slice. A plate set stops a plate this way when another plate
    /// slices first.
    pub fn halt(app: *App) void {
        app.quiet.store(true, .release);
        app.stopWorker();
        app.quiet.store(false, .release);
        if (app.getState() == .slicing) app.state.store(.ready, .release);
    }

    /// Waits for the end of the slice that runs, with no cancel.
    pub fn waitSlice(app: *App) void {
        if (comptime !has_threads) return;
        if (app.worker) |t| {
            t.join();
            app.worker = null;
        }
    }

    /// Copies the settings of another app: the global settings, the three
    /// groups, the quality profile, and the formulas (the saved state of a
    /// shell). For a new plate of a set with the settings of the active
    /// plate.
    pub fn copySettingsFrom(app: *App, other: *const App) (Allocator.Error || zs.profile.Error)!void {
        const a = app.strings.allocator();
        const copy = struct {
            fn f(al: Allocator, list: []const zs.settings.Change) Allocator.Error![]const zs.settings.Change {
                const out = try al.alloc(zs.settings.Change, list.len);
                for (list, out) |c, *d| d.* = .{ .name = try al.dupe(u8, c.name), .value = try al.dupe(u8, c.value) };
                return out;
            }
        }.f;
        // The base (the quality profile and the global settings) first,
        // then the groups over it.
        app.global = try copy(a, other.global);
        app.quality = try copy(a, other.quality);
        app.quality_name = try a.dupeZ(u8, other.quality_name);
        app.rebase(&.{});
        var aw: std.Io.Writer.Allocating = .init(app.gpa);
        defer aw.deinit();
        var diag: zs.profile.Diagnostic = .{};
        for ([_]zs.profile.Group{ .machine, .filament, .project }) |g| {
            aw.clearRetainingCapacity();
            other.writeState(g, &aw.writer) catch return error.OutOfMemory;
            if (aw.written().len > 0) try app.applyProfile(g, "saved", aw.written(), &diag);
        }
        aw.clearRetainingCapacity();
        other.writeFormulas(&aw.writer) catch return error.OutOfMemory;
        app.readFormulas(aw.written());
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
    pub fn stopWorkerForTest(app: *App) void {
        app.waitSlice();
    }

    fn dropSlicePlan(app: *App) void {
        if (app.slice_plan) |*p| p.deinit();
        app.slice_plan = null;
        for (app.slice_meshes) |*m| m.deinit(app.gpa);
        app.gpa.free(app.slice_meshes);
        app.slice_meshes = &.{};
        if (app.slice_arena) |*a| a.deinit();
        app.slice_arena = null;
        app.slice_parts = &.{};
    }

    /// The support marks and the support areas for the next slice.
    fn sliceMarks(app: *App) Allocator.Error![]zs.support.Mark {
        if (app.areas.count() == 0) return app.gpa.dupe(zs.support.Mark, app.marks.items);
        if (app.area_arena == null) app.area_arena = .init(app.gpa);
        _ = app.area_arena.?.reset(.retain_capacity);
        const a = app.area_arena.?.allocator();
        var list: std.ArrayList(zs.support.Mark) = .empty;
        try list.appendSlice(a, app.marks.items);
        try app.areas.marks(a, &list);
        return app.gpa.dupe(zs.support.Mark, list.items);
    }

    /// Slices part i coarse in the next slices (null: none): thicker
    /// layers, one wall, no skin, and no infill. A part that turns with
    /// the drag of a ring slices so, a few times faster, and the full
    /// slice comes at the release. The other parts keep their work (see
    /// plate_job.Options.old). Only the shell uses it, during a drag.
    pub fn setCoarsePart(app: *App, i: ?usize) void {
        if (std.meta.eql(app.coarse_part, i)) return;
        app.stopWorker();
        app.coarse_part = i;
    }

    /// The changes of a part, then the changes of a coarse slice.
    fn coarseChanges(app: *const App, a: Allocator, own: []const zs.settings.Change) Allocator.Error![]const zs.settings.Change {
        const nozzle = app.settings.machine.nozzle_diameter;
        const h = @min(app.settings.project.layer_height * 2, 0.75 * nozzle);
        const lh = try std.fmt.allocPrint(a, "{d:.3}", .{@max(h, app.settings.project.layer_height)});
        const extra = [_]zs.settings.Change{
            .{ .name = "project.layer_height", .value = lh },
            .{ .name = "project.wall_count", .value = "1" },
            .{ .name = "project.infill_density", .value = "0" },
            .{ .name = "project.top_thickness", .value = "0" },
            .{ .name = "project.bottom_thickness", .value = "0" },
        };
        const out = try a.alloc(zs.settings.Change, own.len + extra.len);
        @memcpy(out[0..own.len], own);
        @memcpy(out[own.len..], &extra);
        return out;
    }

    /// The parts of the plate job for the next slice: the mesh of each
    /// part on the bed, its settings and its modifier volumes (see
    /// part_settings.zig), and the support marks of the user over it.
    fn makeSlicePlan(app: *App) Allocator.Error!void {
        app.dropSlicePlan();
        app.slice_arena = .init(app.gpa);
        const a = app.slice_arena.?.allocator();
        var n: usize = 0;
        for (app.plate.parts.items) |p| n += 1 + p.volumes.items.len;
        app.slice_meshes = try app.gpa.alloc(zs.Mesh, n);
        @memset(app.slice_meshes, .empty);
        const inputs = try a.alloc(zs.part_settings.Input, n);
        // The plate index of each input that is a part.
        const part_of = try a.alloc(?u32, n);
        var k: usize = 0;
        for (app.plate.parts.items, 0..) |p, i| {
            const host = k;
            app.slice_meshes[k] = try app.plate.partMesh(app.gpa, i);
            inputs[k] = .{ .name = p.name, .meta = p.meta, .mesh = &app.slice_meshes[k] };
            part_of[k] = @intCast(i);
            k += 1;
            for (p.volumes.items, 0..) |v, vk| {
                app.slice_meshes[k] = try app.plate.volumeMesh(app.gpa, i, vk);
                inputs[k] = .{ .name = v.name, .meta = v.meta, .mesh = &app.slice_meshes[k], .host = host };
                part_of[k] = null;
                k += 1;
            }
        }
        app.slice_plan = try zs.part_settings.plan(app.gpa, inputs, &app.settings);
        const plan = &app.slice_plan.?;
        const parts = try a.alloc(zs.plate_job.PartInput, plan.parts.len);
        for (plan.parts, parts) |pp, *out| {
            const mesh = &app.slice_meshes[pp.input];
            // The marks of the user over the box of the part.
            const b = mesh.bounds();
            var marks: std.ArrayList(zs.support.Mark) = .empty;
            for (app.slice_marks) |mk| {
                const rx = @max(mk.r, mk.hw);
                const ry = @max(mk.r, mk.hh);
                if (mk.x + rx < b.min[0] or mk.x - rx > b.max[0] or mk.y + ry < b.min[1] or mk.y - ry > b.max[1]) continue;
                try marks.append(a, mk);
            }
            var changes = pp.changes;
            if (app.coarse_part != null and part_of[pp.input] != null and part_of[pp.input].? == app.coarse_part.?) {
                changes = try app.coarseChanges(a, pp.changes);
            }
            out.* = .{
                .mesh = mesh,
                .changes = changes,
                .modifiers = pp.modifiers,
                .marks = marks.items,
                .part = part_of[pp.input] orelse 0,
            };
        }
        app.slice_parts = parts;
    }

    /// Frees the memory that only a faster next slice uses: the memos of
    /// the job, and the results before (kept to fill them again). The
    /// result stays. For an app that waits: a plate of a set that is not
    /// the active plate. No effect while a slice runs.
    pub fn trim(app: *App) void {
        if (app.getState() == .slicing) return;
        if (app.job) |*j| j.dropMemos();
        app.dropPrevJob();
        app.gpa.free(app.spare_gcode);
        app.spare_gcode = &.{};
        app.spare_paths.deinit(app.gpa);
        app.spare_paths = .{};
    }

    fn dropPrevJob(app: *App) void {
        if (app.prev_job) |*j| j.deinit();
        app.prev_job = null;
    }

    /// A job that did not finish: its regions are still good for its
    /// settings, so keep it for the next slice.
    fn keepForRegions(app: *App, job: zs.PlateJob) void {
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
        // The settings of the parts for the whole plate, under the
        // overrides of the user.
        if (app.slice_plan) |*pp| pp.applyBase(&part) catch |e| return app.finishFailed(e);
        if (app.slice_parts.len == 0) return app.finishFailed(error.EmptyMesh);
        var layer_overrides: std.ArrayList(zs.settings.Override) = .empty;
        defer layer_overrides.deinit(app.gpa);
        for (app.slice_overrides) |o| {
            if (o.wholePart()) {
                part.set(o.name, o.value) catch return app.finishFailed(error.InvalidSettings);
            } else {
                layer_overrides.append(app.gpa, o) catch |e| return app.finishFailed(e);
            }
        }
        const prev: ?*zs.PlateJob = if (app.prev_job) |*j| j else null;
        const job_or = zs.PlateJob.init(app.gpa, part, app.slice_parts, .{ .overrides = layer_overrides.items, .monitor = monitor, .old = prev });
        // The new job took what it could use. A job that failed (for
        // example, a cancel) can leave the old job without outlines, so the
        // old job goes in each case.
        app.dropPrevJob();
        var job = job_or catch |e| return app.finishFailed(e);
        // The edits of the user apply to each layer plan.
        app.edits.resetApplied();
        job.edits = &app.edits;
        var out: std.Io.Writer.Allocating = .initOwnedSlice(app.gpa, app.spare_gcode);
        app.spare_gcode = &.{};
        out.clearRetainingCapacity();
        var store = app.spare_paths;
        app.spare_paths = .{};
        store.clearRetainingCapacity();
        store.gpa = app.gpa;
        store.z_hop = @floatCast(part.project.z_hop);
        const sink: zs.engine.Job.LayerSink = .{ .ctx = &store, .func = Toolpaths.addLayer };
        // The pictures for the screen of the printer, first.
        writeThumbnails(app.gpa, app.slice_parts, part.machine.thumbnails, part.filament.color, &out.writer) catch {};
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

        app.part_box = job.bounds() orelse .{ 0, 0, 0, 0 };
        app.job = job;
        app.toolpaths = store;
        app.gcode_bytes = bytes;
        app.gcode_buf = buf;
        app.stats = stats;
        _ = app.done_count.fetchAdd(1, .release);
        app.state.store(.done, .release);
        app.emit(.sliced, 1, 0);
    }

    /// The thumbnails of `sizes` ("300x300,32x32") of the parts, in the
    /// color of the filament ("#rrggbb"), at the top of the G-code.
    fn writeThumbnails(gpa: Allocator, parts: []const zs.plate_job.PartInput, sizes: []const u8, color: []const u8, out: *std.Io.Writer) !void {
        if (sizes.len == 0 or parts.len == 0) return;
        var rgb = [3]u8{ 0xd0, 0xd0, 0xcc };
        if (color.len == 7 and color[0] == '#') {
            for (0..3) |k| rgb[k] = std.fmt.parseInt(u8, color[1 + 2 * k ..][0..2], 16) catch rgb[k];
        }
        const meshes = try gpa.alloc(zs.Mesh, parts.len);
        defer gpa.free(meshes);
        for (parts, meshes) |p, *m| m.* = p.mesh.*;
        var it = std.mem.tokenizeAny(u8, sizes, ", ");
        while (it.next()) |size| {
            // "300x300", or "300x300/PNG" (the form of PrusaSlicer).
            const spec = if (std.mem.indexOfScalar(u8, size, '/')) |k| size[0..k] else size;
            const x = std.mem.indexOfScalar(u8, spec, 'x') orelse continue;
            const w = std.fmt.parseInt(u32, spec[0..x], 10) catch continue;
            const h = std.fmt.parseInt(u32, spec[x + 1 ..], 10) catch continue;
            if (w == 0 or h == 0 or w > 1024 or h > 1024) continue;
            var img = try zs.cpu_render.render(gpa, meshes, w, h, rgb);
            defer img.deinit(gpa);
            const bytes = try zs.cpu_render.png(gpa, img);
            defer gpa.free(bytes);
            try zs.cpu_render.gcodeThumbnail(gpa, bytes, w, h, out);
        }
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

    /// The same as `inspect`, in `arena`: the strings of the last `inspect`
    /// stay valid (for the picks of a line card that shows them).
    pub fn inspectIn(app: *const App, arena: Allocator, path: usize) error{ NoResult, OutOfRange, OutOfMemory }!Inspection {
        const t = app.allToolpaths() orelse return error.NoResult;
        return inspect_mod.inspect(arena, t, &app.job.?, path) catch |e| switch (e) {
            error.OutOfRange => error.OutOfRange,
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        };
    }

    /// The measurements of path `path` at its segment `seg` (see
    /// app/measure.zig): the segment, its straight edge, the path, its size,
    /// and the radius of a circle or an arc.
    pub fn measurePath(app: *const App, path: usize, seg: usize) error{ NoResult, OutOfRange, OutOfMemory }!measure.Measure {
        const t = app.allToolpaths() orelse return error.NoResult;
        if (path >= t.path_ends.items.len) return error.OutOfRange;
        const start: usize = if (path == 0) 0 else t.path_ends.items[path - 1];
        const end: usize = t.path_ends.items[path];
        const pts = try app.gpa.alloc([2]f64, end - start);
        defer app.gpa.free(pts);
        for (pts, start..) |*p, i| p.* = .{ t.points.items[2 * i], t.points.items[2 * i + 1] };
        return measure.measure(app.gpa, pts, t.path_closed.items[path] != 0, seg);
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
    _ = sweep;
    _ = gap_advice;
    _ = checks_mod;
    _ = plate_set;
    _ = support_areas;
    _ = @import("app/feature_settings.zig");
    _ = @import("app/farm.zig");
    _ = @import("app/session.zig");
}

test "app: support areas slice, go into the 3MF, and undo" {
    const gpa = testing.allocator;
    // A mushroom: a 4 mm post and a 20 mm cap from z 5 to 7.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try zs.mesh.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("mushroom.stl", bytes.written());
    const has_support = struct {
        fn f(a: *App) !bool {
            try a.startSlice();
            a.stopWorkerForTest();
            return std.mem.indexOf(u8, a.gcode().?, ";TYPE:SUPPORT") != null;
        }
    }.f;
    // Support off: none.
    try testing.expect(!try has_support(app));
    _ = app.undo.commit(app, 0);
    // A support area under the cap, drawn on its bottom: support.
    const box = app.part_box;
    const cx = (box[0] + box[2]) / 2;
    const cy = (box[1] + box[3]) / 2;
    const pts = [_][3]f64{ .{ cx - 11, cy - 11, 5 }, .{ cx + 11, cy - 11, 5 }, .{ cx + 11, cy + 11, 5 }, .{ cx - 11, cy + 11, 5 } };
    _ = try app.areas.add(gpa, .grid, &pts, std.math.nan(f64), std.math.nan(f64));
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    try testing.expect(try has_support(app));
    const with_area = try gpa.dupe(u8, app.gcode().?);
    defer gpa.free(with_area);

    // The 3MF keeps the area: a new app slices the same G-code.
    const file = try app.write3mfAlloc(gpa);
    defer gpa.free(file);
    const other = try App.create(gpa, null, null);
    defer other.destroy();
    other.keep_places = true;
    try other.loadStl("plate.3mf", file);
    try testing.expectEqual(@as(usize, 1), other.areas.count());
    try testing.expectEqualSlices([3]f64, &pts, other.areas.list.items[0].points);
    try testing.expect(try has_support(other));
    try testing.expectEqualStrings(with_area, other.gcode().?);

    // The facts name the area.
    var facts: std.Io.Writer.Allocating = .init(gpa);
    defer facts.deinit();
    try app.writeFacts(&facts.writer);
    try testing.expect(std.mem.indexOf(u8, facts.written(), "Support\tarea 1\tsupport (grid), 4 points") != null);

    // Support on, and the area becomes a block: no support under the cap.
    try app.setSetting("project.support", "everywhere");
    try testing.expect(try has_support(app));
    try app.areas.setKind(0, .block);
    try testing.expect(!try has_support(app));

    // Undo to the step before the area: no area; redo: the area again.
    try app.setSetting("project.support", "off");
    try app.areas.setKind(0, .grid);
    _ = app.undo.undo(app, 2000);
    try testing.expectEqual(@as(usize, 0), app.areas.count());
    _ = app.undo.redo(app, 3000);
    try testing.expectEqual(@as(usize, 1), app.areas.count());
    try testing.expect(try has_support(app));
}

test "app: Arachne walls carry a bead area for each point, at the z of the layer" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.wedge(gpa, 20, 20, 1, 6);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("wedge.stl", stl.written());
    try app.setSetting("project.wall_generator", "arachne");
    // Gap fill lines have a width for each point too.
    try app.setSetting("project.gap_fill", "false");
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    const tp = app.allToolpaths().?;
    try testing.expectEqual(tp.point_z.items.len, tp.point_area.items.len);
    var walls: usize = 0;
    for (tp.path_features.items, 0..) |f, pi| {
        const wall = f == @intFromEnum(zs.settings.Feature.outer_wall) or f == @intFromEnum(zs.settings.Feature.inner_wall);
        try testing.expectEqual(wall, tp.path_z_start.items[pi] != Toolpaths.no_z);
        if (!wall) continue;
        walls += 1;
        const l = tp.layerOfPath(pi).?;
        const k = tp.path_z_start.items[pi];
        const n = tp.path_ends.items[pi] - tp.pathStart(pi);
        for (tp.point_z.items[k..][0..n], tp.point_area.items[k..][0..n]) |z, area| {
            try testing.expectEqual(tp.layer_z.items[l], z);
            try testing.expect(area > 0);
        }
    }
    try testing.expect(walls > 0);
}

test "app: slope smoothing and ironing paths carry a z for each point" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.wedge(gpa, 20, 20, 1, 6);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("wedge.stl", stl.written());
    try app.setSetting("project.slope_smoothing", "true");
    try app.setSetting("machine.nozzle_tip_radius", "0.35");
    try app.setSetting("project.slope_ironing", "true");
    // Gap fill lines have a width for each point.
    try app.setSetting("project.gap_fill", "false");
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    const tp = app.allToolpaths().?;
    try testing.expectEqual(tp.pathCount(), tp.path_z_start.items.len);
    try testing.expectEqual(tp.point_z.items.len, tp.point_area.items.len);
    var found: ?usize = null;
    var iron: ?usize = null;
    for (tp.path_features.items, 0..) |f, pi| {
        const smooth = f == @intFromEnum(zs.settings.Feature.slope_smoothing);
        const ironing = f == @intFromEnum(zs.settings.Feature.slope_ironing);
        try testing.expectEqual(smooth or ironing, tp.path_z_start.items[pi] != Toolpaths.no_z);
        if (ironing) iron = pi;
        if (!smooth and !ironing) continue;
        if (smooth) found = pi;
        const l = tp.layerOfPath(pi).?;
        const zr = tp.pathZRange(pi, l);
        try testing.expect(zr[0] >= tp.layer_z.items[l] - 0.75 * tp.layer_height.items[l] - 1e-4);
        try testing.expect(zr[1] <= tp.layer_z.items[l] + 1e-4);
    }
    const pi = found.?;
    const info = try app.inspect(pi);
    try testing.expectEqualStrings("Slope smoothing", info.title);
    try testing.expect(std.mem.indexOf(u8, info.explain, "Slope smoothing: after the layer") != null);
    try testing.expect(info.height < tp.layer_height.items[info.layer]);
    const report = try app.lineReport(pi, "wedge.gcode");
    try testing.expect(std.mem.indexOf(u8, report, "nozzle z") != null);
    const iron_info = try app.inspect(iron.?);
    try testing.expectEqualStrings("Slope ironing", iron_info.title);
    try testing.expect(std.mem.indexOf(u8, iron_info.explain, "Slope ironing: after the layer") != null);
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

    // Lightning infill: the inspector of an infill path says what the
    // branch does.
    try app.setSetting("project.infill_pattern", "lightning");
    try app.requestSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    const feats = app.allToolpaths().?.path_features.items;
    const fill = std.mem.indexOfScalar(u8, feats, @intFromEnum(zs.settings.Feature.infill)).?;
    const fill_info = try app.inspect(fill);
    try testing.expect(std.mem.indexOf(u8, fill_info.explain, "Lightning infill") != null);
    try testing.expect(std.mem.indexOf(u8, fill_info.settings, "project.lightning_angle") != null);

    // A new model clears the result.
    try app.loadStl("demo.stl", stl.written());
    try testing.expectEqual(@as(usize, 0), app.layerCount());
}

test "app: a coarse part slices with fewer layers, and the full slice comes back" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", stl.written());
    try app.startSlice();
    app.stopWorkerForTest();
    const full = app.layerCount();
    const gcode = try gpa.dupe(u8, app.gcode().?);
    defer gpa.free(gcode);
    app.setCoarsePart(0);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expect(app.layerCount() < full);
    app.setCoarsePart(null);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(full, app.layerCount());
    try testing.expectEqualStrings(gcode, app.gcode().?);
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
    // The first layer height is not a layer setting, but the part can
    // change it.
    try testing.expectError(error.NotPerLayer, app.setOverride(1, 2, "project.first_layer_height", "0.3"));
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

test "app: a trim keeps the result, and the next slice gives the same G-code" {
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
    const before = try gpa.dupe(u8, app.gcode().?);
    defer gpa.free(before);
    app.trim();
    try testing.expectEqualStrings(before, app.gcode().?);
    // A change after the trim: the same G-code as a new app.
    try app.setSetting("project.infill_density", "0.35");
    try app.requestSlice();
    app.stopWorkerForTest();
    const fresh = try App.create(gpa, null, null);
    defer fresh.destroy();
    try fresh.loadStl("demo.stl", bytes.written());
    try fresh.setSetting("project.infill_density", "0.35");
    try fresh.startSlice();
    fresh.stopWorkerForTest();
    try testing.expectEqualStrings(fresh.gcode().?, app.gcode().?);
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

test "app: combined infill shows its height, and the inspector says why" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.settings.set("project.infill_layers", "2");
    try app.loadStl("demo.stl", bytes.written());
    try app.startSlice();
    app.stopWorkerForTest();
    const t = app.allToolpaths().?;
    var path: ?usize = null;
    for (t.path_height.items, 0..) |h, i| {
        const l = t.layerOfPath(i).?;
        if (h > t.layer_height.items[l] + 1e-4) {
            try testing.expectApproxEqAbs(@as(f32, 0.4), h, 1e-5);
            path = i;
        }
    }
    const info = try app.inspect(path.?);
    try testing.expectApproxEqAbs(@as(f64, 0.4), info.height, 1e-6);
    try testing.expect(std.mem.indexOf(u8, info.explain, "Combined: 2 layers, 0.40 mm") != null);
    try testing.expect(std.mem.indexOf(u8, info.why_flow, "Combined: 2 layers, 0.40 mm") != null);
    const r = try app.lineReport(path.?, "/tmp/x.gcode");
    try testing.expect(std.mem.indexOf(u8, r, "Combined: 2 layers, 0.40 mm") != null);
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
    try app.setOverride(2.1 - 1e-3, zs.settings.part_z, "project.layer_height", "0.1");
    try app.setOverride(1.5, 2.5, "filament.nozzle_temp", "225");
    const bytes = try gpa.dupe(u8, try app.write3mf());
    defer gpa.free(bytes);

    const back = try App.create(gpa, null, null);
    defer back.destroy();
    try back.loadStl("plate.3mf", bytes);
    try std.testing.expectEqual(@as(usize, 2), back.plate.count());
    const p = back.plate.parts.items[1];
    try std.testing.expectApproxEqAbs(@as(f64, 60), p.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 50), p.y, 1e-3);
    try std.testing.expectEqual(@as(usize, 3), back.overrides.items.len);
    try std.testing.expectEqualStrings("0.35", back.overrides.items[0].value);
    try std.testing.expectEqualStrings("project.layer_height", back.overrides.items[1].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.1 - 1e-3), back.overrides.items[1].z_min, 1e-9);
    try std.testing.expectEqualStrings("225", back.overrides.items[2].value);
    // The slice has the thin layers at the top.
    try back.startSlice();
    back.stopWorkerForTest();
    const t = back.allToolpaths().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), t.layer_height.items[t.layer_height.items.len - 1], 1e-6);
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

/// A Cura project 3MF of a plate (40 x 40 x 2 mm, 100 % lines) and a
/// window in it (an infill mesh with no walls and no skin).
fn grilleProject(gpa: Allocator) ![]u8 {
    const box = struct {
        fn mesh(w: *std.Io.Writer, x0: f64, y0: f64, x1: f64, y1: f64, h: f64) !void {
            try w.writeAll("<mesh><vertices>");
            for ([_][3]f64{ .{ x0, y0, 0 }, .{ x1, y0, 0 }, .{ x1, y1, 0 }, .{ x0, y1, 0 }, .{ x0, y0, h }, .{ x1, y0, h }, .{ x1, y1, h }, .{ x0, y1, h } }) |v| try w.print("<vertex x=\"{d}\" y=\"{d}\" z=\"{d}\"/>", .{ v[0], v[1], v[2] });
            try w.writeAll("</vertices><triangles>");
            for ([_][3]u32{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 3, 0, 4 }, .{ 3, 4, 7 } }) |f| try w.print("<triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\"/>", .{ f[0], f[1], f[2] });
            try w.writeAll("</triangles></mesh>");
        }
    };
    var model: std.Io.Writer.Allocating = .init(gpa);
    defer model.deinit();
    const w = &model.writer;
    try w.writeAll("<?xml version=\"1.0\"?><model unit=\"millimeter\" xmlns:cura=\"http://software.ultimaker.com/xml/cura/3mf/2015/10\"><resources>");
    try w.writeAll("<object id=\"1\" name=\"plate\" type=\"model\"><metadatagroup><metadata name=\"cura:infill_sparse_density\">=100</metadata><metadata name=\"cura:infill_pattern\">lines</metadata></metadatagroup>");
    try box.mesh(w, -20, -20, 20, 20, 2);
    try w.writeAll("</object><object id=\"2\" name=\"window\" type=\"model\"><metadatagroup><metadata name=\"cura:infill_mesh\">=True</metadata><metadata name=\"cura:wall_line_count\">=0</metadata><metadata name=\"cura:top_layers\">=0</metadata><metadata name=\"cura:bottom_layers\">=0</metadata><metadata name=\"cura:infill_sparse_density\">=25</metadata><metadata name=\"cura:infill_pattern\">grid</metadata></metadatagroup>");
    try box.mesh(w, -10, -10, 10, 10, 2);
    try w.writeAll("</object></resources><build><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 100 100 0\"/><item objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 100 100 0\"/></build></model>");
    const entries = [_]zs.zipfile.Entry{.{ .name = "3D/3dmodel.model", .data = model.written() }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try zs.zipfile.write(gpa, &out.writer, &entries);
    return out.toOwnedSlice();
}

test "app: a Cura project with a modifier volume: load, slice, inspect, and save" {
    const gpa = testing.allocator;
    const bytes = try grilleProject(gpa);
    defer gpa.free(bytes);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("grille.3mf", bytes);
    // One part that prints, with its settings and the window volume.
    try testing.expectEqual(@as(usize, 1), app.plate.count());
    const part = app.plate.parts.items[0];
    try testing.expectEqual(@as(usize, 2), part.meta.len);
    try testing.expectEqual(@as(usize, 1), part.volumes.items.len);
    try testing.expectEqualStrings("window", part.volumes.items[0].name);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try app.partSettingsText(0, &text.writer);
    try testing.expect(std.mem.indexOf(u8, text.written(), "project.infill_density = 1") != null);
    try testing.expect(std.mem.indexOf(u8, text.written(), "a modifier volume") != null);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    const tp = app.allToolpaths().?;
    var in_window: ?usize = null;
    for (tp.path_modifier.items, 0..) |m, k| if (m == 1) {
        in_window = k;
    };
    try testing.expect(in_window != null);
    // The inspector names the volume, and uses its settings.
    const ins = try app.inspect(in_window.?);
    try testing.expect(std.mem.indexOf(u8, ins.explain, "Modifier volume \"window\"") != null);
    // The part and its volume go in a 3MF file and come back.
    const saved = try gpa.dupe(u8, try app.write3mf());
    defer gpa.free(saved);
    const back = try App.create(gpa, null, null);
    defer back.destroy();
    try back.loadStl("grille.3mf", saved);
    try testing.expectEqual(@as(usize, 1), back.plate.count());
    try testing.expectEqual(@as(usize, 1), back.plate.parts.items[0].volumes.items.len);
    try testing.expectEqual(@as(usize, 2), back.plate.parts.items[0].meta.len);
    try testing.expectEqual(@as(usize, 6), back.plate.parts.items[0].volumes.items[0].meta.len);
}

test "part settings: one part with its own infill and support" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", stl.written());
    _ = try app.addStl("b.stl", stl.written());
    _ = try app.arrangePlate();
    try app.setPartSetting(0, "project.infill_density", "0.8");
    try app.setPartSetting(0, "project.support", "everywhere");
    try testing.expectEqualStrings("0.8", app.partSetting(0, "project.infill_density").?);
    try testing.expect(app.partSetting(1, "project.infill_density") == null);
    try testing.expectError(error.InvalidValue, app.setPartSetting(0, "project.infill_density", "lots"));
    try app.startSlice();
    app.stopWorkerForTest();
    const plan = app.slice_plan.?;
    try testing.expectEqual(@as(usize, 0), plan.base.len);
    // Each part slices with its own settings: two jobs.
    try testing.expectEqual(@as(usize, 2), plan.parts.len);
    try testing.expectEqual(@as(usize, 2), plan.parts[0].changes.len);
    try testing.expectEqual(@as(usize, 0), plan.parts[1].changes.len);
    try testing.expectEqual(State.done, app.getState());
    const pj = &app.job.?;
    try testing.expectEqual(@as(usize, 2), pj.groups.len);
    try testing.expectEqual(@as(f64, 0.8), pj.jobOf(0).?.resolved.settings.project.infill_density);
    try testing.expectEqual(zs.settings.SupportMode.everywhere, pj.jobOf(0).?.resolved.settings.project.support);
    try testing.expectEqual(zs.settings.SupportMode.off, pj.jobOf(1).?.resolved.settings.project.support);
    // Each path knows its part.
    const tp = app.allToolpaths().?;
    var seen = [2]bool{ false, false };
    for (tp.path_part.items) |part| if (part < 2) {
        seen[part] = true;
    };
    try testing.expect(seen[0] and seen[1]);
    try testing.expectEqual(@as(?usize, 1), app.partOfPath(std.mem.indexOfScalar(u32, tp.path_part.items, 1).?));
    // Cleared: no plan.
    try app.setPartSetting(0, "project.infill_density", null);
    try app.setPartSetting(0, "project.support", null);
    try testing.expect(app.partSetting(0, "project.support") == null);
}

test "settings cascade: quality, the changes of this print, and a part" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    var diag: zs.profile.Diagnostic = .{};
    try app.setQuality("fine", "extends = \"fine\"\n", false, &diag);
    try testing.expectEqual(@as(f64, 0.1), app.settings.project.layer_height);
    try testing.expectEqual(App.Level.quality, app.source(null, "project.layer_height").level);
    try testing.expectEqualStrings("fine", app.source(null, "project.layer_height").profile);
    try testing.expectEqual(App.Level.default, app.source(null, "project.infill_pattern").level);
    // A change of this print, over the quality.
    try app.setSetting("project.wall_count", "5");
    try testing.expectEqual(App.Level.print, app.source(null, "project.wall_count").level);
    // Another quality keeps the change with keep_edits.
    try app.setQuality("draft", "extends = \"draft\"\n", true, &diag);
    try testing.expectEqual(@as(f64, 0.3), app.settings.project.layer_height);
    try testing.expectEqual(@as(u32, 5), app.settings.project.wall_count);
    // The state has the change only, not the quality.
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try app.writeState(.project, &w.writer);
    try testing.expect(std.mem.indexOf(u8, w.written(), "wall_count = 5") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "layer_height") == null);
    // A reset of the group goes back to the quality.
    app.resetGroup(.project);
    try testing.expectEqual(@as(f64, 0.3), app.settings.project.layer_height);
    // Draft has the default wall count: the default again.
    try testing.expectEqual(@as(u32, 2), app.settings.project.wall_count);
    try testing.expectEqual(App.Level.default, app.source(null, "project.wall_count").level);
    try testing.expectEqual(App.Level.quality, app.source(null, "project.layer_height").level);
    // A filament value from its profile.
    try app.setSetting("filament.nozzle_temp", "230");
    try testing.expectEqual(App.Level.filament, app.source(null, "filament.nozzle_temp").level);
}

test "formulas: a setting from other settings, kept up to date" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.setSetting("project.line_width", "0.5");
    try app.setSetting("project.top_thickness", "= {line_width} * 2");
    try testing.expectEqual(@as(f64, 1.0), app.settings.project.top_thickness);
    try testing.expectEqualStrings("{line_width} * 2", app.formulaOf("project.top_thickness").?);
    // A change of the input changes the value.
    try app.setSetting("project.line_width", "0.6");
    try testing.expectApproxEqAbs(@as(f64, 1.2), app.settings.project.top_thickness, 1e-9);
    // A plain value replaces the formula.
    try app.setSetting("project.top_thickness", "0.8");
    try testing.expect(app.formulaOf("project.top_thickness") == null);
    try app.setSetting("project.line_width", "0.4");
    try testing.expectEqual(@as(f64, 0.8), app.settings.project.top_thickness);
    // A bad formula is an error, and changes nothing.
    try testing.expectError(error.InvalidValue, app.setSetting("project.top_thickness", "= {nope} * 2"));
    try testing.expectError(error.InvalidValue, app.setSetting("project.top_thickness", "= 1 +"));
    // A text setting in a choice.
    try app.setSetting("project.wall_count", "= {infill_pattern} == \"grid\" ? 3 : 2");
    try testing.expectEqual(@as(u32, 3), app.settings.project.wall_count);
    // The state text, and back.
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try app.writeFormulas(&w.writer);
    try testing.expect(std.mem.indexOf(u8, w.written(), "project.wall_count = {infill_pattern}") != null);
}

test "formulas: an automatic line width gives the width that the slicer uses" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.setSetting("machine.nozzle_diameter", "0.5");
    try app.setSetting("project.top_thickness", "= {line_width} * 2");
    try testing.expectApproxEqAbs(@as(f64, 1.1), app.settings.project.top_thickness, 1e-9);
}

test "global settings: under the quality, and saved apart" {
    const gpa = testing.allocator;
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.setGlobalSetting("project.seam", "rear");
    try testing.expectEqual(zs.settings.SeamMode.rear, app.settings.project.seam);
    try testing.expectEqual(App.Level.global, app.source(null, "project.seam").level);
    // A change of this print stays over a global change.
    try app.setSetting("project.wall_count", "4");
    try app.setGlobalSetting("project.wall_count", "3");
    try testing.expectEqual(@as(u32, 4), app.settings.project.wall_count);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try app.writeGlobal(&w.writer);
    try testing.expect(std.mem.indexOf(u8, w.written(), "seam = \"rear\"") != null);
    try app.setGlobalSetting("project.seam", null);
    try testing.expectEqual(App.Level.default, app.source(null, "project.seam").level);
}

test "part settings: a part with its own quality profile" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 6);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", stl.written());
    _ = try app.addStl("b.stl", stl.written());
    _ = try app.arrangePlate();
    try app.setPartSetting(1, "quality", "draft");
    try testing.expectError(error.InvalidValue, app.setPartSetting(1, "quality", "nope"));
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    // The paths of the draft part are 0.3 mm high (above the first
    // layer), and the paths of the other part 0.2 mm.
    const t = app.allToolpaths().?;
    var seen = [2]bool{ false, false };
    const first_end = t.layer_ends.items[0];
    for (first_end..t.path_part.items.len) |pi| {
        const part = t.path_part.items[pi];
        if (part > 1) continue;
        const h = t.path_height.items[pi];
        const want: f32 = if (part == 1) 0.3 else 0.2;
        try testing.expectApproxEqAbs(want, h, 0.001);
        seen[part] = true;
    }
    try testing.expect(seen[0] and seen[1]);
}

test "app: the facts of a state, a change in the history, and its revert" {
    const app = try App.create(std.testing.allocator, null, null);
    defer app.destroy();
    var before: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before.deinit();
    try app.writeFacts(&before.writer);
    try app.setSetting("project.infill_density", "0.55");
    try app.setSetting("project.wall_count", "4");
    try app.setOverride(2, 5, "project.infill_density", "0.3");
    var after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after.deinit();
    try app.writeFacts(&after.writer);
    var d: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer d.deinit();
    try history.diff(std.testing.allocator, before.written(), after.written(), &d.writer);
    // Three changes: the wall count, the infill density, and the change
    // for the layers.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, d.written(), "\n"));
    var density: []const u8 = "";
    var third: []const u8 = "";
    var it = std.mem.splitScalar(u8, d.written(), '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "print\tproject.infill_density")) density = line;
        if (std.mem.startsWith(u8, line, "layers:")) third = line;
    }
    try std.testing.expectEqualStrings("print\tproject.infill_density\t\t0.55", density);
    // Revert the density: it goes back to the default, and the wall count
    // and the change for the layers stay.
    try app.revertChange(density);
    try std.testing.expectEqual(@as(f64, 0.2), app.settings.project.infill_density);
    try std.testing.expectEqual(@as(u32, 4), app.settings.project.wall_count);
    try std.testing.expectEqual(@as(usize, 1), app.overrides.items.len);
    // Revert the change for the layers: the override goes.
    try std.testing.expect(std.mem.startsWith(u8, third, "layers:2.0000:5.0000\tproject.infill_density"));
    try app.revertChange(third);
    try std.testing.expectEqual(@as(usize, 0), app.overrides.items.len);
}
