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
//! - `speed.zig`: the Speed group of the panel, and the Faster slicing switch.
//! - `licenses.zig`: the licenses for a Licenses screen.
//! - `history.zig`: the undo list of an app.
//! - `plate_set.zig`: the plates of a set, each with its own app.
//! - `sim_print.zig`: the print as it forms (the physical simulation of
//!   the plastic), as toolpaths.
//!
//! The split of a core and native shells comes from Lookout Marine (see
//! docs/references/libraries.md).

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
pub const refine = @import("app/refine.zig");
/// The support areas of the user (see app/support_areas.zig).
pub const support_areas = @import("app/support_areas.zig");
/// The support trees that the user edits (see app/support_trees.zig).
pub const support_trees = @import("app/support_trees.zig");
pub const plate_set = @import("app/plate_set.zig");
/// The selection and the focus of the app (see app/selection.zig).
pub const selection = @import("app/selection.zig");
/// The Speed group of the settings panel, and the Faster slicing switch.
pub const speed = @import("app/speed.zig");
/// The filaments of the plate (see app/filament_slots.zig).
pub const filament_slots = @import("app/filament_slots.zig");
/// The filaments that the printer has loaded (see app/printer_filaments.zig).
pub const printer_filaments = @import("app/printer_filaments.zig");
/// The labels of the parts (see app/labels.zig).
pub const labels = @import("app/labels.zig");
pub const clipboard = @import("app/clipboard.zig");
pub const measure = @import("app/measure.zig");
/// The printability check (see app/checks.zig).
pub const checks_mod = @import("app/checks.zig");
/// The print as it forms (see app/sim_print.zig).
pub const sim_print = @import("app/sim_print.zig");

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
    /// The simulated print of the slice is ready (see `auto_simulate`):
    /// `adoptSimulation` shows it.
    simulated = 6,
    /// The check of the slice is ready (see `auto_checks`): `checks`
    /// returns it at once.
    checked = 7,
    /// The worker wrote the scene bytes of a slice (see
    /// `scene_bytes_on`). Only a plate set gets it: it is not in the C API.
    scene_bytes = 8,
};

/// The input of a scene of the 3D view (render/view.zig `buildBeads`):
/// the toolpaths of a result, and the settings that the view reads.
pub const SceneSource = struct {
    settings: *const Settings,
    /// The filaments of slots 1 and up (slot 0 is settings.filament).
    filaments: []const zs.settings.Filament,
    tp: *const Toolpaths,
    job: ?*const zs.PlateJob,
    part_box: [4]f64,
    /// The support marks (their rings are in the bytes of a scene).
    marks: []const zs.support.Mark,
    /// The result that `tp` is, its slice, and its app (see
    /// `App.resultId`).
    result: u64,
    slice: u64,
    app: u32,
    /// A build on the worker stops when a change cancels the slice.
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// Builds a scene of the 3D view on the thread of the slice (see
/// `App.scene_hook`). The C API of the view sets it: the app does not
/// know the view.
pub const SceneHook = struct {
    /// Returns the scene, or null on a cancel or an error. `mode` is the
    /// color mode (enum zs_view_mode).
    build: *const fn (src: SceneSource, mode: u32) ?*anyopaque,
    /// Frees a scene that no view took.
    free: *const fn (scene: *anyopaque) void,
    /// The scene as bytes (render/view.zig appScene), in `alloc`, for a
    /// plate set.
    write: *const fn (alloc: Allocator, src: SceneSource, mode: u32) ?SceneBytes,
};

/// The bytes of a scene for a plate set (see `App.scene_bytes`).
pub const SceneBytes = struct {
    bytes: []u8,
    /// The key of the input (render/view.zig bytesKey).
    key: u64,
    /// The slice (App.done_count).
    gen: u32 = 0,
};

/// The kinds of the scenes that the worker builds: the slice, and the
/// simulated print.
pub const SceneKind = enum(u1) { plan = 0, sim = 1 };

/// The ids of the apps (see `App.uid`).
var next_uid: std.atomic.Value(u32) = .init(1);

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
    /// An id that no other app of the process has, for `resultId`.
    uid: u32 = 0,
    /// Builds the scenes of the 3D view on the worker: after each slice
    /// (the slice), and after each simulation on the worker (the
    /// simulated print), before their events. Null: no scenes. The
    /// worker reads it, so it changes only with `setSceneHook`.
    scene_hook: std.atomic.Value(?*const SceneHook) = .init(null),
    /// The color mode of the scenes (enum zs_view_mode): the mode of the
    /// last load of a view.
    scene_mode: std.atomic.Value(u32) = .init(0),
    /// The scenes of the worker that wait for a view (`takeScene`), for
    /// each SceneKind.
    scenes: [2]std.atomic.Value(?*anyopaque) = .{ .init(null), .init(null) },
    /// A plate set wants the scene bytes of each slice: the worker writes
    /// them after the `sliced` event, in `gpa`, and they wait in
    /// `scene_bytes` for the set (`takeSceneBytes`).
    scene_bytes_on: std.atomic.Value(bool) = .init(false),
    /// The worker writes scene bytes now: the `scene_bytes` event follows.
    scene_bytes_coming: std.atomic.Value(bool) = .init(false),
    scene_bytes: [2]std.atomic.Value(?*SceneBytes) = .{ .init(null), .init(null) },
    /// A copy of `marks` for the running slice, for the scene bytes.
    slice_view_marks: []zs.support.Mark = &.{},

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
    /// The next slices are drafts (see `setDraft`).
    draft: bool = false,
    /// The slice that runs, or the last slice, is a draft.
    slice_draft: bool = false,
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
    /// The toolpaths of the last slice as the plastic set (see
    /// `simulatePrint`), and if `allToolpaths` gives them.
    sim: ?sim_print.Result = null,
    show_sim: bool = false,
    /// Simulate the print after each slice, on the thread of the slice
    /// (see `auto_simulate`). A change stops it.
    auto_simulate: bool = false,
    /// The simulation of the thread of the slice, when it is done, and if
    /// it waits for `adoptSimulation`.
    sim_pending: ?sim_print.Result = null,
    sim_ready: std.atomic.Value(bool) = .init(false),
    /// The worker simulates the slice after it (`auto_simulate` at the
    /// start of the slice, or `requestSimulation`). The worker clears it
    /// when it ends.
    sim_coming: std.atomic.Value(bool) = .init(false),
    /// True while the simulation of the slice runs on the worker, and its
    /// progress in 1/1000 (see `simulationWork`).
    sim_working: std.atomic.Value(bool) = .init(false),
    sim_permille: std.atomic.Value(u32) = .init(0),
    /// A simulation that runs in pieces (`beginSimulation`).
    sim_job: ?*sim_print.Job = null,
    /// The checkpoints of the last simulation that ended (see
    /// print_sim.Checkpoints): the next simulation runs from the last
    /// checkpoint before the first path that changed. Only the thread
    /// that runs a simulation uses them: the thread of the slice, or the
    /// thread of the shell after `stopWorker`.
    sim_checkpoints: ?*zs.print_sim.Checkpoints = null,
    /// The first path of the last simulation: 0, or the path of the
    /// checkpoint that it started from.
    sim_first_path: usize = 0,
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
    /// The shell wants the check after each slice: the worker runs it
    /// after the `sliced` event (the slice shows at once), then sends
    /// `checked`, so `checks` returns at once on the thread of the shell.
    /// While it runs, `checks` gives error.Pending.
    auto_checks: bool = false,
    checks_pending: std.atomic.Value(bool) = .init(false),
    /// The bond of each part for the check of the running slice (see
    /// `auto_checks`), in `slice_arena`, or null: no check on the worker.
    slice_stands: ?[]checks_mod.Stand = null,
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
    /// The note of the last drop of the support trees of the user (see
    /// app/support_trees.zig), and the copy that the shell reads.
    trees_note: std.ArrayList(u8) = .empty,
    trees_note_out: std.ArrayList(u8) = .empty,
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
    /// The parts that the last slice left out (too low to slice).
    slice_left_out: [8]zs.plate_job.LeftOut = undefined,
    slice_left_out_n: usize = 0,
    slice_arena: ?std.heap.ArenaAllocator = null,
    /// The bytes of the last write3mf.
    file_bytes: []u8 = &.{},
    /// The undo list (see app/history.zig). The C API notes each change.
    undo: history.History = .{},
    /// The fall of a part that runs now, step by step (see fallStart).
    fall: ?Fall = null,
    /// The last bond test of each part (see bondOf).
    bond_memo: std.ArrayList(BondMemo) = .empty,
    /// The places of the parts for the slice that runs, and for the slice
    /// that the view shows (see edits.Place).
    slice_places: []edits_mod.Place = &.{},
    scene_places: []edits_mod.Place = &.{},
    /// The edits of the user on the lines of the slice (app/edits.zig).
    edits: edits_mod.Edits = .{},
    /// The filaments of the plate after the first: slot 2, 3, and on
    /// (see app/filament_slots.zig). Their strings are in `strings`.
    filaments: std.ArrayList(zs.settings.Filament) = .empty,
    /// Where the values of each slot come from: the printer, or the hand
    /// of the user (see app/printer_filaments.zig).
    slot_marks: [zs.filaments.max_slots]printer_filaments.Mark = @splat(.{}),
    /// The copy of `filaments` that the slice uses.
    slice_filaments: []zs.settings.Filament = &.{},
    /// The last mesh of zs_app_part_mesh.
    mesh_out: ?zs.Mesh = null,
    /// The report of the last profile import (zs_app_profile_import).
    import_report: std.ArrayList(u8) = .empty,
    /// The calibration print of this plate (app/calibrate.zig), or null.
    /// Its strings are in `strings`.
    calibration: ?@import("app/calibrate.zig").Calibration = null,

    pub fn create(gpa: Allocator, event_fn: ?EventFn, user: ?*anyopaque) Allocator.Error!*App {
        const app = try gpa.create(App);
        app.* = .{ .gpa = gpa, .event_fn = event_fn, .user = user, .strings = .init(gpa), .uid = next_uid.fetchAdd(1, .monotonic) };
        return app;
    }

    pub fn destroy(app: *App) void {
        app.fallCancel();
        app.bond_memo.deinit(app.gpa);
        if (app.inspect_arena) |*a| a.deinit();
        app.stopWorker();
        app.clearResults();
        app.dropSimCheckpoints();
        app.dropPrevJob();
        app.gpa.free(app.spare_gcode);
        app.spare_paths.deinit(app.gpa);
        app.overrides.deinit(app.gpa);
        app.formulas.deinit(app.gpa);
        app.profiles.deinit(app.gpa);
        app.clearGaps();
        app.gpa.free(app.slice_overrides);
        app.filaments.deinit(app.gpa);
        app.gpa.free(app.slice_filaments);
        app.gpa.free(app.slice_view_marks);
        if (app.mesh_out) |*m| m.deinit(app.gpa);
        app.import_report.deinit(app.gpa);
        app.gpa.free(app.file_bytes);
        app.undo.deinit(app.gpa);
        app.edits.deinit(app.gpa);
        app.gpa.free(app.slice_places);
        app.gpa.free(app.scene_places);
        app.marks.deinit(app.gpa);
        app.gpa.free(app.slice_marks);
        app.areas.deinit(app.gpa);
        if (app.area_arena) |*a| a.deinit();
        app.trees_note.deinit(app.gpa);
        app.trees_note_out.deinit(app.gpa);
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
    /// and stops a slice that runs. A part of an STL file that cannot
    /// stand falls over (settleFrom). The parts of a 3MF file keep the
    /// orientation of the file: a project, a session, or a plate of
    /// another slicer comes back as it was saved.
    pub fn loadStl(app: *App, name: []const u8, bytes: []const u8) LoadError!void {
        // Read the file first: a bad file keeps the old plate.
        if (isZip(bytes)) {
            var loaded = try zs.threemf.readWith(app.gpa, bytes, .{ .keep_places = true });
            defer loaded.deinit(app.gpa);
            app.dropPlate();
            try app.addLoaded(&loaded);
        } else {
            const m = try zs.Mesh.fromStl(app.gpa, bytes);
            app.dropPlate();
            _ = try app.addMesh(name, m);
            try app.settleFrom(0);
        }
        // The old result is gone: there is a model, and no slice of it.
        app.state.store(.ready, .release);
    }

    fn dropPlate(app: *App) void {
        // A fall or a hand on a part that goes: it ends.
        app.fallCancel();
        app.stopWorker();
        app.clearResults();
        // The overrides were for the old parts.
        app.overrides.clearRetainingCapacity();
        app.profiles.clearRetainingCapacity();
        app.marks.clearRetainingCapacity();
        app.areas.clear(app.gpa);
        // The edits were for the lines of the old parts.
        app.edits.list.clearRetainingCapacity();
        app.edits.places = &.{};
        app.plate.clear(app.gpa);
        app.calibration = null;
    }

    /// Adds a model file (STL or 3MF) to the plate. Returns the index of
    /// its first part. A 3MF file can have more than one part.
    pub fn addStl(app: *App, name: []const u8, bytes: []const u8) LoadError!usize {
        app.stopWorker();
        if (isZip(bytes)) {
            var loaded = try zs.threemf.readWith(app.gpa, bytes, .{ .keep_places = true });
            defer loaded.deinit(app.gpa);
            const first = app.plate.count();
            // The parts keep the orientation of the file (see loadStl).
            try app.addLoaded(&loaded);
            return first;
        }
        const m = try zs.Mesh.fromStl(app.gpa, bytes);
        const i = try app.addMesh(name, m);
        // A model added to a plate with parts: smart placement of the new
        // part only (its best orientation, then a free spot); the parts
        // on the plate stay where they are. Only with placement "auto": a
        // placement of "file" or "center" is the user's.
        if (i > 0 and app.settings.project.placement == .auto) {
            try app.plate.place(app.gpa, i, .smart, 0, app.settings.project.support_angle);
            app.plate.respot(i, app.bedSize(), app.partGap());
            try app.plateChanged();
        }
        try app.settleFrom(i);
        return i;
    }

    fn isZip(bytes: []const u8) bool {
        return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
    }

    /// The parts of a 3MF file stay at their places in the file (if they
    /// fit), and its overrides apply.
    fn addLoaded(app: *App, loaded: *zs.threemf.Loaded) LoadError!void {
        // The index of the first part of the file on the plate.
        const first = app.plate.count();
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
            // A part of zslice comes back with the mesh of the file and its
            // turn: the same vertices, to the bit, as before the save.
            const i = if (p.place) |pl|
                try app.plate.addPlaced(app.gpa, p.name, m, pl, app.bedSize(), gap)
            else
                try app.plate.add(app.gpa, p.name, m, app.bedSize(), gap, true);
            idx.* = i;
            // The paint of the file, and the filament of the part.
            app.plate.parts.items[i].paint = p.paint;
            p.paint = .{};
            // The labels of the file, in the frame of the mesh.
            const pl = &app.plate.parts.items[i];
            try pl.labels.ensureTotalCapacity(app.gpa, p.labels.len);
            for (p.labels) |l| pl.labels.appendAssumeCapacity(l);
            app.gpa.free(p.labels);
            p.labels = &.{};
            // With no part that prints, a volume prints as a part.
            if (zs.part_settings.prints(p.meta)) {
                app.plate.setMeta(app.gpa, i, p.meta);
                p.meta = &.{};
            }
            // The filament goes into the settings of the part after the
            // settings of the file, as they replace all of them.
            if (p.filament > 1) {
                var buf: [8]u8 = undefined;
                const v = std.fmt.bufPrint(&buf, "{d}", .{p.filament}) catch unreachable;
                app.setPartSetting(i, "project.filament", v) catch |e| if (e == error.OutOfMemory) return error.OutOfMemory;
            }
        }
        for (loaded.parts) |*p| {
            if (p.mesh.faces.items.len == 0) continue;
            const vb = p.buildBounds();
            var best: ?usize = null;
            var best_v: f64 = -1;
            var best_place: ?zs.threemf.Place = null;
            for (loaded.parts, index) |*q, idx| {
                const i = idx orelse continue;
                // The box of the part on the bed.
                const part = &app.plate.parts.items[i];
                const fp = part.footprint();
                const qb: zs.mesh.Bounds3 = .{ .min = .{ fp[0], fp[1], 0 }, .max = .{ fp[2], fp[3], part.height } };
                var vol: f64 = 1;
                for (0..3) |k| vol *= @max(0, @min(vb.max[k], qb.max[k]) - @max(vb.min[k], qb.min[k]));
                if (vol > best_v) {
                    best_v = vol;
                    best = i;
                    best_place = q.place;
                }
            }
            const host = best orelse continue;
            // The volume goes into the frame of the mesh of its part: as it
            // is when it has the place of its part, else from the bed.
            const same = if (p.place) |a| if (best_place) |b| a.rot == b.rot and std.mem.eql(f64, &a.move, &b.move) else false else best_place == null;
            if (!same) {
                p.toBuild();
                if (best_place != null) app.plate.parts.items[host].fromBed(&p.mesh);
            }
            const m = p.mesh;
            p.mesh = .empty;
            const meta = p.meta;
            p.meta = &.{};
            try app.plate.addVolume(app.gpa, host, p.name, m, meta);
        }
        try app.plateChanged();
        // The filaments of a project of Bambu Studio or PrusaSlicer: their
        // colors and materials.
        if (loaded.colors.len > 1) try filament_slots.fromProject(app, loaded.colors, loaded.materials);
        try app.readFileLines(first, loaded.overrides);
    }

    /// Reads the lines of Metadata/zslice_overrides.txt (writeFileLines):
    /// the support areas, the filament slots, the support trees (of the
    /// parts from index `first` on), the edits, the layer profiles, and
    /// the overrides. A line that this version does not know is left out.
    pub fn readFileLines(app: *App, first: usize, text: []const u8) Allocator.Error!void {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            // A support area of the user (app/support_areas.zig).
            if (try app.areas.read3mfLine(app.gpa, line)) continue;
            // A filament of the plate (app/filament_slots.zig).
            if (try filament_slots.read3mfLine(app, line)) continue;
            // The support trees of a part (app/support_trees.zig).
            if (try support_trees.read3mfLine(app, first, line)) continue;
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
            if (std.mem.startsWith(u8, line, "linefil\t")) {
                try app.readLineFilament(line);
                continue;
            }
            // "mark <tab> x <tab> y <tab> z <tab> r <tab> kind": a support
            // mark of the user (support.Mark).
            if (std.mem.startsWith(u8, line, "mark\t")) {
                var f = std.mem.splitScalar(u8, line["mark\t".len..], '\t');
                const x = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                const y = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                const z = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                const r = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                const kind = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
                if (kind > @intFromEnum(zs.support.Mark.Kind.block) or !(r > 0)) continue;
                try app.marks.append(app.gpa, .{ .x = x, .y = y, .z = z, .r = r, .kind = @enumFromInt(kind) });
                continue;
            }
            // "lift <tab> part <tab> z": the lift of a part (plate.Part.z).
            if (std.mem.startsWith(u8, line, "lift\t")) {
                var f = std.mem.splitScalar(u8, line["lift\t".len..], '\t');
                const k = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
                const z = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue;
                app.plate.lift(first + k, z);
                continue;
            }
            // "partid <tab> part <tab> id": the stable id of a part
            // (plate.Part.id). An older version leaves this line out.
            if (std.mem.startsWith(u8, line, "partid\t")) {
                var f = std.mem.splitScalar(u8, line["partid\t".len..], '\t');
                const k = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
                const id = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
                app.plate.restoreId(first, first + k, id);
                continue;
            }
            // "pose <tab> part <tab> 9 values <tab> 3 values": the pose and
            // the scale of a part (plate.Plate.restorePose).
            if (std.mem.startsWith(u8, line, "pose\t")) {
                var f = std.mem.splitScalar(u8, line["pose\t".len..], '\t');
                const k = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
                var v: [12]f64 = undefined;
                var ok = true;
                for (&v) |*x| x.* = std.fmt.parseFloat(f64, f.next() orelse {
                    ok = false;
                    break;
                }) catch {
                    ok = false;
                    break;
                };
                if (!ok) continue;
                const pose: zs.plate.M3 = .{ v[0..3].*, v[3..6].*, v[6..9].* };
                try app.plate.restorePose(app.gpa, first + k, pose, v[9..12].*);
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
        return app.writePlateAlloc(gpa, false);
    }

    /// The plate as a snapshot of the history (threemf.writeSnapshot): no
    /// text of the vertices, and each mesh in its own entry, so a move
    /// writes no mesh again.
    pub fn writeSnapshotAlloc(app: *const App, gpa: Allocator) (Allocator.Error || error{WriteFailed} || error{NoModel})![]u8 {
        return app.writePlateAlloc(gpa, true);
    }

    /// Puts the plate of a snapshot of the history back, as it was: the
    /// parts stay as they are (no settle), with their overrides.
    pub fn loadSnapshot(app: *App, bytes: []const u8) LoadError!void {
        var loaded = try zs.threemf.readSnapshot(app.gpa, bytes, .{ .keep_places = true });
        defer loaded.deinit(app.gpa);
        app.dropPlate();
        // The filaments of the step come back with its lines.
        app.filaments.clearRetainingCapacity();
        try app.addLoaded(&loaded);
        app.state.store(.ready, .release);
    }

    /// The lines of Metadata/zslice_overrides.txt in the 3MF file of the
    /// plate: the layer profiles, the support areas, the filament slots,
    /// the support trees, the edits of lines, and the overrides.
    pub fn writeFileLines(app: *const App, w: *std.Io.Writer) (Allocator.Error || error{WriteFailed})!void {
        for (app.profiles.items) |p| try w.print("profile\t{d}\t{d}\t{s}\n", .{ p.z_min, p.z_max, p.name });
        try app.areas.write3mfLines(w);
        try filament_slots.write3mfLines(app, w);
        try support_trees.write3mfLines(app, w);
        try app.writeEditLines(w);
        // The support marks of the user at a point (support.Mark): "mark",
        // x, y, z, the radius, and the kind. They are in the history and
        // the session with the plate.
        for (app.marks.items) |m| {
            if (m.poly.len > 0 or @intFromEnum(m.kind) > @intFromEnum(zs.support.Mark.Kind.block)) continue;
            try w.print("mark\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ m.x, m.y, m.z, m.r, @intFromEnum(m.kind) });
        }
        // The lift of each part that floats or sinks (plate.Part.z), by its
        // index on the plate.
        for (app.plate.parts.items, 0..) |p, k| if (p.z != 0) try w.print("lift\t{d}\t{d}\n", .{ k, p.z });
        // The stable id of each part, so that undo, redo, and a reload
        // find the same part.
        for (app.plate.parts.items, 0..) |p, k| try w.print("partid\t{d}\t{d}\n", .{ k, p.id });
        // The pose and the scale of each part that has them (the mesh of
        // the file has them in its vertices): "pose", the index, the 9
        // values of the pose (rows), and the 3 of the scale.
        for (app.plate.parts.items, 0..) |p, k| {
            if (p.source == null) continue;
            try w.print("pose\t{d}", .{k});
            for (p.pose) |row| for (row) |x| try w.print("\t{d}", .{x});
            for (p.scale) |x| try w.print("\t{d}", .{x});
            try w.writeByte('\n');
        }
        for (app.overrides.items) |o| try w.print("{d}\t{d}\t{s}\t{s}\n", .{ o.z_min, o.z_max, o.name, o.value });
    }

    /// The edits of lines: "edit" for a key, and "linefil" for a filament
    /// edit with its anchor (see app/edits.zig). An older version skips
    /// the "linefil" lines.
    fn writeEditLines(app: *const App, w: *std.Io.Writer) error{WriteFailed}!void {
        for (app.edits.list.items) |e| {
            const a = e.anchor orelse {
                try w.print("edit\t{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ e.key, @intFromEnum(e.kind), e.value, e.layer, e.x, e.y, e.z });
                continue;
            };
            try w.print("linefil\t{d}\t{d}\t{x}\t{d}\t{d}\t{d}\t{d}", .{ e.value, e.layer, a.stamp, a.part, a.feature, @intFromBool(a.whole), a.length });
            for (a.pts[0..a.n]) |q| try w.print("\t{d}\t{d}\t{d}", .{ q[0], q[1], q[2] });
            try w.writeByte('\n');
        }
    }

    /// Reads a "linefil" line (see `writeEditLines`).
    fn readLineFilament(app: *App, line: []const u8) Allocator.Error!void {
        var f = std.mem.splitScalar(u8, line["linefil\t".len..], '\t');
        const value = std.fmt.parseFloat(f64, f.next() orelse return) catch return;
        const layer = std.fmt.parseInt(u32, f.next() orelse return, 10) catch return;
        var a: edits_mod.Anchor = .{ .stamp = std.fmt.parseInt(u64, f.next() orelse return, 16) catch return, .part = std.fmt.parseInt(u64, f.next() orelse return, 10) catch return, .feature = std.fmt.parseInt(u8, f.next() orelse return, 10) catch return, .whole = (f.next() orelse return)[0] == '1', .n = 0, .length = std.fmt.parseFloat(f64, f.next() orelse return) catch return };
        while (f.next()) |x| {
            if (a.n == edits_mod.max_anchor) return;
            a.pts[a.n] = .{ std.fmt.parseInt(i32, x, 10) catch return, std.fmt.parseInt(i32, f.next() orelse return, 10) catch return, std.fmt.parseInt(i32, f.next() orelse return, 10) catch return };
            a.n += 1;
        }
        if (a.n < 2 or !(value >= 1 and value <= 255)) return;
        _ = try app.edits.putFilament(app.gpa, a, @intFromFloat(value), layer);
    }

    pub const LineFilamentError = Allocator.Error || error{ NoResult, InvalidSettings };

    /// Adds the filament edit of one line, or of segment `seg` of it, from
    /// the beads of the view (body_region.stride floats each). The beads
    /// are in the frame of the slice in the view, so the anchor comes from
    /// the place of the part in that slice.
    pub fn lineFilament(app: *App, beads: []const f32, seg: isize, feature: c_int, filament: u32) LineFilamentError!usize {
        const stride = zs.body_region.stride;
        const count = beads.len / stride;
        if (count == 0 or filament == 0 or filament > 255) return error.InvalidSettings;
        if (feature < 0 or feature == @intFromEnum(zs.settings.Feature.skirt)) return error.InvalidSettings;
        if (app.settings.project.spiral_vase or beads[0] < 0) return error.InvalidSettings;
        const part: u32 = @intFromFloat(beads[0]);
        var place: ?*const edits_mod.Place = null;
        for (app.scene_places) |*p| if (p.index == part) {
            place = p;
        };
        const pl = place orelse return error.NoResult;
        const bead = struct {
            fn at(b: []const f32, k: usize) struct { a: [3]f64, b: [3]f64 } {
                const q = b[k * stride ..][0..stride];
                return .{ .a = .{ q[4], q[5], q[2] }, .b = .{ q[6], q[7], q[2] } };
            }
        }.at;
        var a: edits_mod.Anchor = .{ .part = pl.id, .stamp = pl.stamp, .feature = @intCast(feature), .whole = true, .n = 0, .length = 0 };
        if (seg >= 0 and count > 1) {
            if (seg >= count) return error.InvalidSettings;
            // A line with a height at each point keeps one filament.
            for (0..count) |k| if (@abs(beads[k * stride + 2] - beads[2]) > 0.001) return error.InvalidSettings;
            const e = bead(beads, @intCast(seg));
            a.whole = false;
            a.n = 2;
            a.pts[0] = pl.toMesh(e.a);
            a.pts[1] = pl.toMesh(e.b);
            a.length = 1000 * std.math.hypot(e.b[0] - e.a[0], e.b[1] - e.a[1]);
        } else {
            for (0..count) |k| {
                const e = bead(beads, k);
                a.length += 1000 * std.math.hypot(e.b[0] - e.a[0], e.b[1] - e.a[1]);
            }
            // The start of each bead, evenly, and the end of the last.
            const m = @min(count, edits_mod.max_anchor - 1);
            for (0..m) |j| {
                a.pts[j] = pl.toMesh(bead(beads, j * count / m).a);
            }
            a.pts[m] = pl.toMesh(bead(beads, count - 1).b);
            a.n = @intCast(m + 1);
        }
        const layer: u32 = @intFromFloat(beads[1]);
        app.stopWorker();
        return app.edits.putFilament(app.gpa, a, filament, layer);
    }

    /// The filament edit on the line of these beads, or null: all points
    /// of its anchor lie on the line.
    pub fn lineFilamentAt(app: *const App, beads: []const f32) ?isize {
        const stride = zs.body_region.stride;
        if (beads.len < stride or beads[0] < 0) return null;
        const part: u32 = @intFromFloat(beads[0]);
        var place: ?*const edits_mod.Place = null;
        for (app.scene_places) |*p| if (p.index == part) {
            place = p;
        };
        const pl = place orelse return null;
        const tol: f64 = edits_mod.match_um / 1000;
        for (app.edits.list.items, 0..) |*e, i| {
            const anchor = if (e.anchor) |*q| q else continue;
            if (anchor.part != pl.id or anchor.stamp != pl.stamp) continue;
            const all = for (anchor.pts[0..anchor.n]) |q| {
                const b = pl.toBed(q);
                const x = b[0] / 1000;
                const y = b[1] / 1000;
                if (@abs(b[2] / 1000 - beads[2]) > 0.005) break false;
                var near = false;
                var k: usize = 0;
                while (k + stride <= beads.len) : (k += stride) {
                    const ax: f64 = beads[k + 4];
                    const ay: f64 = beads[k + 5];
                    const dx = beads[k + 6] - ax;
                    const dy = beads[k + 7] - ay;
                    const l2 = dx * dx + dy * dy;
                    const t = if (l2 > 0) std.math.clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0, 1) else 0;
                    if (std.math.hypot(ax + t * dx - x, ay + t * dy - y) <= tol) {
                        near = true;
                        break;
                    }
                }
                if (!near) break false;
            } else true;
            if (all) return @intCast(i);
        }
        return null;
    }

    pub const LineCost = struct { changes: u32, seconds: f64, grams: f64 };

    /// What a filament for one path costs on its layer. A filament that
    /// the layer has already adds no change, because the planner groups
    /// the lines of each filament. A new one adds a change to it and a
    /// change back.
    pub fn lineFilamentCost(app: *const App, path: usize, filament: u32) ?LineCost {
        const t = app.allToolpaths() orelse return null;
        if (path >= t.path_tool.items.len or filament == 0) return null;
        const layer = t.layerOfPath(path) orelse return null;
        const lo: usize = if (layer == 0) 0 else t.layer_ends.items[layer - 1];
        const hi: usize = t.layer_ends.items[layer];
        const want = filament - 1;
        // The other lines of the layer: the filament of most of them is
        // the base. This line can have the edit already, so it does not
        // count.
        var counts = [_]u32{0} ** 256;
        for (lo..hi) |k| {
            if (k != path) counts[t.path_tool.items[k]] += 1;
        }
        if (counts[want] > 0) return .{ .changes = 0, .seconds = 0, .grams = 0 };
        var own: usize = t.path_tool.items[path];
        var most: u32 = 0;
        for (counts, 0..) |c, k| if (c > most) {
            most = c;
            own = k;
        };
        if (own == want) return .{ .changes = 0, .seconds = 0, .grams = 0 };
        const m = app.settings.machine;
        var grams: f64 = 0;
        if (m.filament_change == .tool and own < app.filaments.items.len and want < app.filaments.items.len) {
            const from = app.filaments.items[own];
            const to = app.filaments.items[want];
            const mult = app.settings.project.flush_multiplier;
            grams = (zs.filaments.flushVolume(from.color, to.color, m.flush_volume, mult) * to.density + zs.filaments.flushVolume(to.color, from.color, m.flush_volume, mult) * from.density) / 1000;
        }
        return .{ .changes = 2, .seconds = 2 * m.change_time, .grams = grams };
    }

    /// The place of each part now, for the filament edits.
    fn makeLinePlaces(app: *const App) Allocator.Error![]edits_mod.Place {
        const out = try app.gpa.alloc(edits_mod.Place, app.plate.parts.items.len);
        for (app.plate.parts.items, out, 0..) |*p, *o, k| o.* = linePlace(p, k);
        return out;
    }

    fn linePlace(p: *const zs.plate.Part, k: usize) edits_mod.Place {
        const b = p.mesh.bounds();
        return .{ .index = @intCast(k), .id = p.id, .stamp = edits_mod.shapeStamp(p.pose, p.scale, p.mesh.vertices.items.len, p.mesh.faces.items.len, b.min, b.max), .m = p.transform() };
    }

    /// The lines of the plate that a copy of the whole plate keeps
    /// (app/clipboard.zig): the layer profiles, the filament slots, the
    /// edits, and the overrides. The parts keep their areas and trees.
    pub fn writePlateLines(app: *const App, w: *std.Io.Writer) (Allocator.Error || error{WriteFailed})!void {
        for (app.profiles.items) |p| try w.print("profile\t{d}\t{d}\t{s}\n", .{ p.z_min, p.z_max, p.name });
        try filament_slots.write3mfLines(app, w);
        try app.writeEditLines(w);
        for (app.overrides.items) |o| try w.print("{d}\t{d}\t{s}\t{s}\n", .{ o.z_min, o.z_max, o.name, o.value });
    }

    /// Pastes the clipboard on the plate (app/clipboard.zig).
    /// With `from`, a copy of clipboard.make in place of the clipboard.
    pub fn pasteParts(app: *App, from: ?*const clipboard.Clip, at: clipboard.At) (Allocator.Error || error{NoResult})!clipboard.Paste {
        app.fallCancel();
        app.stopWorker();
        const r = if (from) |c| try clipboard.pasteFrom(c, app, at) else try clipboard.paste(app, at);
        try app.plateChanged();
        return r;
    }

    fn writePlateAlloc(app: *const App, gpa: Allocator, snapshot: bool) (Allocator.Error || error{WriteFailed} || error{NoModel})![]u8 {
        if (app.plate.count() == 0) return error.NoModel;
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try app.writeFileLines(&text.writer);
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        if (snapshot) try zs.threemf.writeSnapshot(gpa, &out.writer, &app.plate, text.written()) else try zs.threemf.write(gpa, &out.writer, &app.plate, text.written());
        return out.toOwnedSlice();
    }

    /// Adds a mesh as a part (the app owns it after the call). Returns its
    /// index.
    pub fn addMeshPart(app: *App, name: []const u8, m: zs.Mesh) zs.mesh.Error!usize {
        app.stopWorker();
        return app.addMesh(name, m);
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
        const gap = @max(3, p.brim_width * 2 + skirt);
        // One part at a time: the head must not touch the parts that it
        // printed before.
        if (p.print_sequence == .by_object) return @max(gap, app.settings.machine.clearance_radius);
        return gap;
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
    pub fn plateChanged(app: *App) Allocator.Error!void {
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
    /// Sets the paint of part i from its text (see paint.Paint.readLines).
    /// The next slice splits the part by the filaments of its paint.
    pub fn setPartPaint(app: *App, i: usize, text: []const u8) Allocator.Error!void {
        if (i >= app.plate.parts.items.len) return;
        app.stopWorker();
        const p = &app.plate.parts.items[i];
        try p.paint.readLines(app.gpa, text, p.mesh.faces.items.len);
    }

    /// Gives a body of a range of layers the filament `filament` (from 1):
    /// a pick of the lines of the beads of `beads` (see body_region.zig,
    /// the beads of zs_view_connected_beads) on each part under them. The
    /// pick is a volume of the part, so it moves and turns with the part.
    /// A newer pick wins over an older pick and over paint. A pick in the
    /// filament of the part goes if no other pick or paint is under it.
    /// Returns the count of triangles of the picks that changed.
    pub fn paintBody(app: *App, beads: []const f32, filament: u32) Allocator.Error!usize {
        const stride = zs.body_region.stride;
        var changed: usize = 0;
        var list: std.ArrayList(f32) = .empty;
        defer list.deinit(app.gpa);
        for (0..app.plate.parts.items.len) |i| {
            list.clearRetainingCapacity();
            var k: usize = 0;
            while (k + stride <= beads.len) : (k += stride) {
                if (beads[k] == @as(f32, @floatFromInt(i))) try list.appendSlice(app.gpa, beads[k..][0..stride]);
            }
            if (list.items.len == 0) continue;
            // The filament of the part.
            var own: u32 = app.settings.project.filament;
            if (app.partSetting(i, "project.filament")) |v| own = std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch own;
            var mesh = try app.plate.partMesh(app.gpa, i);
            defer mesh.deinit(app.gpa);
            var vol = zs.body_region.pickVolume(app.gpa, list.items, &mesh) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            var owned = true;
            defer if (owned) vol.deinit(app.gpa);
            const faces = vol.faces.items.len;
            if (faces == 0) continue;
            // The pick of the same shape, and what else is on the part.
            const want = vol.bounds();
            const p = &app.plate.parts.items[i];
            var same: ?usize = null;
            var others = !p.paint.isEmpty();
            for (p.volumes.items, 0..) |v, vk| {
                if (zs.body_region.pickFilament(v.meta) == null) continue;
                var vm = try app.plate.volumeMesh(app.gpa, i, vk);
                defer vm.deinit(app.gpa);
                const got = vm.bounds();
                var eq = vm.faces.items.len == faces;
                for (0..3) |d| eq = eq and @abs(got.min[d] - want.min[d]) < 0.02 and @abs(got.max[d] - want.max[d]) < 0.02;
                if (eq) same = vk else others = true;
            }
            if (same) |vk| {
                // The same filament on the newest pick: no change.
                if (vk + 1 == p.volumes.items.len and zs.body_region.pickFilament(p.volumes.items[vk].meta) == filament) continue;
                app.stopWorker();
                app.plate.removeVolume(app.gpa, i, vk);
                changed += faces;
            }
            if (filament == own and !others) {
                if (same != null) try app.plateChanged();
                continue;
            }
            var next: u32 = 1;
            for (app.plate.parts.items) |q| for (q.volumes.items) |v| {
                next = @max(next, regionId(v.meta) + 1);
            };
            var name_buf: [32]u8 = undefined;
            const vname = std.fmt.bufPrint(&name_buf, "Pick {d}", .{next}) catch unreachable;
            const meta = try app.gpa.alloc(zs.threemf.Meta, 4);
            @memset(meta, .{ .key = &.{}, .value = &.{} });
            errdefer zs.threemf.freeMeta(app.gpa, meta);
            meta[0] = .{ .key = try app.gpa.dupe(u8, "cura:infill_mesh"), .value = try app.gpa.dupe(u8, "True") };
            meta[1] = .{ .key = try app.gpa.dupe(u8, region_key), .value = try std.fmt.allocPrint(app.gpa, "{d}", .{next}) };
            meta[2] = .{ .key = try app.gpa.dupe(u8, "zslice:project.wall_count"), .value = try app.gpa.dupe(u8, "0") };
            meta[3] = .{ .key = try app.gpa.dupe(u8, zs.body_region.pick_key), .value = try std.fmt.allocPrint(app.gpa, "{d}", .{filament}) };
            app.stopWorker();
            owned = false;
            try app.plate.addVolumeOnBed(app.gpa, i, vname, vol, meta);
            if (same == null) changed += faces;
            try app.plateChanged();
        }
        return changed;
    }

    /// The metadata key of the id of a region (see body_region.zig).
    pub const region_key = "zslice:region";

    /// The region of id `id`: its part and its volume, or null.
    pub fn regionAt(app: *const App, id: u32) ?[2]usize {
        if (id == 0) return null;
        for (app.plate.parts.items, 0..) |p, i| for (p.volumes.items, 0..) |v, k| {
            if (regionId(v.meta) == id) return .{ i, k };
        };
        return null;
    }

    /// The id of a region from the metadata of a volume, or 0.
    pub fn regionId(meta: []const zs.threemf.Meta) u32 {
        for (meta) |m| if (std.mem.eql(u8, m.key, region_key)) return std.fmt.parseInt(u32, m.value, 10) catch 0;
        return 0;
    }

    /// True if a key of the metadata of a region is one of its settings
    /// (not its role, its id, or the walls it has none of).
    pub fn isRegionSettingKey(key: []const u8) bool {
        if (!std.mem.startsWith(u8, key, "zslice:")) return false;
        if (std.mem.eql(u8, key, region_key)) return false;
        if (std.mem.eql(u8, key, zs.body_region.pick_key)) return false;
        return !std.mem.eql(u8, key, "zslice:project.wall_count");
    }

    pub const RegionError = Allocator.Error || Settings.SetError || error{ NoPart, NotRegional, NoRegion };

    /// Sets setting `name` of the region of a body of some layers to
    /// `value` (null: the region gets no value of its own). `id` 0: the
    /// region of the beads (body_region.zig, the beads of
    /// zs_view_connected_beads): the region with the same box, or a new
    /// modifier volume of their part. A region with no setting left goes.
    /// Returns the id of the region (0 if it went). Only the settings of
    /// settings.region_settings (not the filament: that is paint, see
    /// `paintBody`).
    pub fn regionSet(app: *App, beads: []const f32, id: u32, name: []const u8, value: ?[]const u8) RegionError!u32 {
        const current = zs.settings.currentName(name);
        if (zs.settings.regionNote(current) != null or std.mem.eql(u8, current, "project.filament")) return error.NotRegional;
        if (value) |v| {
            var check = app.settings;
            try check.set(current, v);
        }
        var at = app.regionAt(id);
        if (at == null and id == 0) at = try app.regionOfBeads(beads);
        if (at == null) {
            if (value == null) return 0;
            if (id != 0) return error.NoRegion;
            const part = zs.body_region.partOf(beads) orelse return error.NoPart;
            if (part >= app.plate.parts.items.len) return error.NoPart;
            const mesh = zs.body_region.volume(app.gpa, beads) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NoPart,
            };
            if (mesh.faces.items.len == 0) return error.NoPart;
            var next: u32 = 1;
            for (app.plate.parts.items) |p| for (p.volumes.items) |v| {
                next = @max(next, regionId(v.meta) + 1);
            };
            var vname_buf: [32]u8 = undefined;
            const vname = std.fmt.bufPrint(&vname_buf, "Region {d}", .{next}) catch unreachable;
            const meta = try app.gpa.alloc(zs.threemf.Meta, 3);
            @memset(meta, .{ .key = &.{}, .value = &.{} });
            errdefer zs.threemf.freeMeta(app.gpa, meta);
            meta[0] = .{ .key = try app.gpa.dupe(u8, "cura:infill_mesh"), .value = try app.gpa.dupe(u8, "True") };
            meta[1] = .{ .key = try app.gpa.dupe(u8, region_key), .value = try std.fmt.allocPrint(app.gpa, "{d}", .{next}) };
            // The walls of the part stay: the region has none of its own.
            meta[2] = .{ .key = try app.gpa.dupe(u8, "zslice:project.wall_count"), .value = try app.gpa.dupe(u8, "0") };
            app.stopWorker();
            try app.plate.addVolumeOnBed(app.gpa, part, vname, mesh, meta);
            at = .{ part, app.plate.parts.items[part].volumes.items.len - 1 };
        }
        const i = at.?[0];
        const k = at.?[1];
        const vol = &app.plate.parts.items[i].volumes.items[k];
        const rid = regionId(vol.meta);
        app.stopWorker();
        // The key of the setting in the metadata.
        const key = try std.fmt.allocPrint(app.gpa, "zslice:{s}", .{current});
        defer app.gpa.free(key);
        var found: ?usize = null;
        for (vol.meta, 0..) |m, j| if (std.mem.startsWith(u8, m.key, "zslice:") and sameSetting(m.key["zslice:".len..], current)) {
            found = j;
        };
        if (value) |v| {
            const nv = try app.gpa.dupe(u8, v);
            if (found) |j| {
                app.gpa.free(vol.meta[j].value);
                vol.meta[j].value = nv;
            } else {
                errdefer app.gpa.free(nv);
                const nk = try app.gpa.dupe(u8, key);
                errdefer app.gpa.free(nk);
                const grown = try app.gpa.realloc(vol.meta, vol.meta.len + 1);
                grown[grown.len - 1] = .{ .key = nk, .value = nv };
                vol.meta = grown;
            }
        } else if (found) |j| {
            const smaller = try app.gpa.alloc(zs.threemf.Meta, vol.meta.len - 1);
            const m = vol.meta[j];
            app.gpa.free(m.key);
            app.gpa.free(m.value);
            @memcpy(smaller[0..j], vol.meta[0..j]);
            @memcpy(smaller[j..], vol.meta[j + 1 ..]);
            app.gpa.free(vol.meta);
            vol.meta = smaller;
        }
        // The next slice plans the parts again, with the region.
        try app.plateChanged();
        // No setting left: the region goes.
        for (vol.meta) |m| {
            if (isRegionSettingKey(m.key)) return rid;
        }
        app.plate.removeVolume(app.gpa, i, k);
        return 0;
    }

    /// The region whose box is the box of the beads (within 0.3 mm: the
    /// outline of the volume is simplified), or null.
    fn regionOfBeads(app: *App, beads: []const f32) Allocator.Error!?[2]usize {
        const part = zs.body_region.partOf(beads) orelse return null;
        if (part >= app.plate.parts.items.len) return null;
        const want = zs.body_region.bounds(beads) orelse return null;
        const p = &app.plate.parts.items[part];
        for (p.volumes.items, 0..) |v, k| {
            if (regionId(v.meta) == 0 or zs.body_region.pickFilament(v.meta) != null) continue;
            var vm = try app.plate.volumeMesh(app.gpa, part, k);
            defer vm.deinit(app.gpa);
            const got = vm.bounds();
            var same = true;
            for (0..3) |d| same = same and @abs(got.min[d] - want[0][d]) < 0.3 and @abs(got.max[d] - want[1][d]) < 0.3;
            if (same) return .{ part, k };
        }
        return null;
    }

    /// The id of the region of the beads (see `regionSet`), or 0.
    pub fn regionFind(app: *App, beads: []const f32) Allocator.Error!u32 {
        const at = (try app.regionOfBeads(beads)) orelse return 0;
        return regionId(app.plate.parts.items[at[0]].volumes.items[at[1]].meta);
    }

    /// The settings of region `id`, one on each line: "name\tvalue".
    pub fn regionSettings(app: *const App, id: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const at = app.regionAt(id) orelse return;
        for (app.plate.parts.items[at[0]].volumes.items[at[1]].meta) |m| {
            if (!isRegionSettingKey(m.key)) continue;
            try w.print("{s}\t{s}\n", .{ m.key["zslice:".len..], m.value });
        }
    }

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
            if (std.mem.startsWith(u8, m.key, "zslice:") and sameSetting(m.key["zslice:".len..], name)) continue;
            try list.append(app.gpa, .{ .key = try app.gpa.dupe(u8, m.key), .value = try app.gpa.dupe(u8, m.value) });
        }
        if (value) |v| {
            const key = try std.fmt.allocPrint(app.gpa, "zslice:{s}", .{zs.settings.currentName(name)});
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
            if (std.mem.startsWith(u8, m.key, "zslice:") and sameSetting(m.key["zslice:".len..], name)) return m.value;
        }
        return null;
    }

    /// True if two names are of the same setting: a setting that moved
    /// to another group has an old name too (a part of an old file).
    fn sameSetting(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, zs.settings.currentName(a), zs.settings.currentName(b));
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
        app.fallCancel();
        app.stopWorker();
        app.plate.remove(app.gpa, i);
        try app.plateChanged();
    }

    /// Moves part i to place `to` of the plate list: the print order of
    /// one part at a time (project.print_sequence = by_object).
    pub fn reorderPart(app: *App, i: usize, to: usize) Allocator.Error!void {
        app.fallCancel();
        app.stopWorker();
        app.plate.reorder(i, to);
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

    /// Mirrors a part along the X (0) or Y (1) axis of the bed.
    pub fn mirrorPart(app: *App, i: usize, axis: u1) Allocator.Error!void {
        // The filament edits of the part mirror with it.
        const before: ?edits_mod.Place = if (i < app.plate.parts.items.len) linePlace(&app.plate.parts.items[i], i) else null;
        const fp0 = if (before != null) app.plate.parts.items[i].footprint() else [4]f64{ 0, 0, 0, 0 };
        const c: [2]f64 = .{ (fp0[0] + fp0[2]) / 2, (fp0[1] + fp0[3]) / 2 };
        try app.plate.mirror(app.gpa, i, axis);
        app.plate.keepOnBed(i, app.bedSize(), app.partGap());
        if (before) |old| {
            const p = &app.plate.parts.items[i];
            app.stopWorker();
            const fp1 = p.footprint();
            app.edits.mirrorAnchors(old, linePlace(p, i), axis, c, .{ (fp1[0] + fp1[2]) / 2, (fp1[1] + fp1[3]) / 2 });
        }
        try app.plateChanged();
    }

    /// Turns a part by `deg` about the X (0) or Y (1) axis of the bed.
    pub fn turnPart(app: *App, i: usize, axis: u2, deg: f64) Allocator.Error!void {
        try app.plate.turn(app.gpa, i, axis, deg);
        try app.plateChanged();
    }

    /// The lift of part i (see plate.Part.z): over 0 it floats over the
    /// bed, under 0 it sinks into it. A part that floats with support off
    /// falls at the next `fallStart` or `settlePart`.
    pub fn liftPart(app: *App, i: usize, z: f64) Allocator.Error!void {
        if (i >= app.plate.count()) return;
        const before = app.plate.parts.items[i].z;
        app.plate.lift(i, z);
        if (app.plate.parts.items[i].z != before) try app.plateChanged();
    }

    /// Sets the orientation of part i from the angles about X, Y, and Z
    /// of the bed, in degrees (see plate.Plate.angles).
    pub fn setPartAngles(app: *App, i: usize, a: [3]f64) Allocator.Error!void {
        if (i >= app.plate.count()) return;
        try app.plate.setAngles(app.gpa, i, a);
        app.plate.keepOnBed(i, app.bedSize(), app.partGap());
        try app.plateChanged();
    }

    /// Why part i floats with no support under it, or null: the words for
    /// the card of a part (it falls when the drag ends).
    pub fn floatNote(app: *const App, i: usize) ?[]const u8 {
        if (i >= app.plate.count()) return null;
        const p = &app.plate.parts.items[i];
        if (!(p.z > lift_eps)) return null;
        if (app.settings.project.support != .off or p.trees != null) return "It floats: it prints on support.";
        return "Support is off: nothing holds the part in the air, so it falls to the bed.";
    }

    /// Physics: part i falls over if it cannot stand as it is (see
    /// `standOf`), and rolls until it rests (see physics.zig). With support
    /// on, the support holds it, and it stays. Returns the angle of the
    /// fall in degrees (0: it stands).
    pub fn settlePart(app: *App, i: usize) Allocator.Error!f64 {
        const deg = try app.fallNow(i);
        if (deg > 0) try app.plateChanged();
        return deg;
    }

    /// Turns part i at once onto the side that it falls onto, with no
    /// plateChanged. Returns the angle of the fall in degrees (0: it
    /// stands).
    fn fallNow(app: *App, i: usize) Allocator.Error!f64 {
        if (i >= app.plate.count()) return 0;
        // A part in the air with nothing under it drops to the bed first.
        const pz = &app.plate.parts.items[i].z;
        var dropped = false;
        if (pz.* > lift_eps and (try app.standOf(i)) != .stands) {
            pz.* = 0;
            dropped = true;
        }
        const deg = try app.fallOnBed(i);
        // A drop with no turn still changes the plate.
        return if (deg == 0 and dropped) 1e-6 else deg;
    }

    /// fallNow for a part on the bed.
    fn fallOnBed(app: *App, i: usize) Allocator.Error!f64 {
        const mesh = &app.plate.parts.items[i].mesh;
        const s = switch (try app.standOf(i)) {
            .stands, .weak => return 0,
            .rolls => try zs.physics.settle(app.gpa, mesh),
            .knocked => |dir| try zs.physics.knock(app.gpa, mesh, dir),
        };
        if (s.rolls == 0) return 0;
        try app.plate.putDown(app.gpa, i, zs.physics.downOf(s));
        app.plate.keepOnBed(i, app.bedSize(), app.partGap());
        return s.degrees;
    }

    /// The fall of a part on the bed, step by step, for a shell that shows
    /// it (see rigid.zig). The body is the part as it is on the bed now;
    /// the view turns its beads by `rot` about `start` and moves them by
    /// pos - start.
    pub const Fall = struct { part: usize, body: zs.rigid.Body, start: [3]f64, time: f64 = 0 };

    /// One frame of a fall: the turn (x, y, z, w) about the pivot, and the
    /// move, for zs_view_part_preview. done: the part rests, and its new
    /// place is on the plate (slice again).
    pub const FallFrame = struct { q: [4]f64, pivot: [3]f64, move: [3]f64, done: bool };

    /// The first part that cannot stand as it is (see `standsUp`), or
    /// null: after a change that takes away what held it (support turned
    /// off, or a branch of its support trees deleted), a shell starts its
    /// fall.
    pub fn unstablePart(app: *App) Allocator.Error!?usize {
        if (app.fall != null) return null;
        for (0..app.plate.count()) |i| if (!try app.standsUp(i)) return i;
        return null;
    }

    /// True if part i stands as it is (see `standOf`).
    fn standsUp(app: *App, i: usize) Allocator.Error!bool {
        return switch (try app.standOf(i)) {
            .stands, .weak => true,
            .rolls, .knocked => false,
        };
    }

    /// How part i stands while it prints.
    pub const Stand = union(enum) {
        /// It stands: the bond of its first layer (and its brim) holds it,
        /// or support holds it.
        stands,
        /// It tips over, but no side that it can fall onto stands either
        /// (a ball, say). It stays, and the check warns.
        weak,
        /// Its weight tips it over: it rolls (physics.settle).
        rolls,
        /// The push of the nozzle tips it over toward this direction (in
        /// the frame of its mesh), and then it stands on its side
        /// (physics.knock).
        knocked: [2]f64,
    };

    /// How part i stands: on the support trees of the user if it has
    /// them (see support_trees.holds), always with planned support, and
    /// else on the bond of its first layer to the bed (bond.zig).
    pub fn standOf(app: *App, i: usize) Allocator.Error!Stand {
        const p = &app.plate.parts.items[i];
        // Trees that no longer fit the part go first.
        if (p.trees != null) support_trees.check(app);
        if (p.trees != null) return if (try support_trees.holds(app, i)) .stands else .rolls;
        if (app.settings.project.support != .off) return .stands;
        // A part in the air with no support falls; a part that sinks into
        // the bed stands on its cut face.
        if (p.z > lift_eps) return .rolls;
        if (p.z < -lift_eps) return .stands;
        return (try app.bondOf(i)).stand;
    }

    /// A lift (mm) under this is on the bed.
    pub const lift_eps = 1e-3;

    /// True if the bond of the first layer of part i (and its brim) holds
    /// it as it is, whatever the support setting.
    pub fn standsOnBed(app: *App, i: usize) Allocator.Error!bool {
        return switch ((try app.bondOf(i)).stand) {
            .stands, .weak => true,
            .rolls, .knocked => false,
        };
    }

    /// The options of the bond test (bond.zig) from the settings.
    fn bondOptions(app: *const App) zs.bond.Options {
        const p = app.settings.project;
        const f = app.settings.filament;
        return .{
            // No setting names the bed surface: smooth PEI, the usual one.
            .strength = zs.bond.strength(zs.bond.materialOf(f.material), .smooth_pei),
            .density = f.density,
            .first_layer_height = p.first_layer_height,
            .brim_width = p.brim_width,
            .brim_outside = p.brim_location != .inside,
            .brim_inside = p.brim_location != .outside,
        };
    }

    /// The bond test of part i and how it stands. The memo keeps the last
    /// result of each part for the same pose and options.
    pub const BondMemo = struct { key: u64, result: zs.bond.Result, stand: Stand };

    fn bondOf(app: *App, i: usize) Allocator.Error!BondMemo {
        const p = &app.plate.parts.items[i];
        const o = app.bondOptions();
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&p.pose));
        h.update(std.mem.asBytes(&p.scale));
        h.update(std.mem.asBytes(&p.mesh.vertices.items.len));
        h.update(std.mem.asBytes(&p.mesh.faces.items.len));
        const ptr = @intFromPtr(p.mesh.vertices.items.ptr);
        h.update(std.mem.asBytes(&ptr));
        inline for (.{ o.strength, o.density, o.first_layer_height, o.push, o.brim_width, o.brim_outside, o.brim_inside }) |f| h.update(std.mem.asBytes(&f));
        const key = h.final();
        if (i < app.bond_memo.items.len and app.bond_memo.items[i].key == key) return app.bond_memo.items[i];
        const r = try zs.bond.check(app.gpa, &p.mesh, o);
        var m: BondMemo = .{ .key = key, .result = r, .stand = .stands };
        if (!r.stands) m.stand = try app.fallOf(&p.mesh, r.dir, o);
        while (app.bond_memo.items.len <= i) try app.bond_memo.append(app.gpa, .{ .key = 0, .result = .{}, .stand = .stands });
        app.bond_memo.items[i] = m;
        return m;
    }

    /// How a part that the bond does not hold falls. Its weight rolls it,
    /// or the push of the nozzle knocks it over toward `dir`. A knock
    /// counts only if the part stands on the side that it falls onto.
    fn fallOf(app: *App, mesh: *const zs.Mesh, dir: [2]f64, o: zs.bond.Options) Allocator.Error!Stand {
        if ((try zs.physics.settle(app.gpa, mesh)).rolls > 0) return .rolls;
        const k = try zs.physics.knock(app.gpa, mesh, dir);
        if (k.rolls == 0) return .weak;
        var after = try mesh.clone(app.gpa);
        defer after.deinit(app.gpa);
        for (after.vertices.items) |*v| {
            const x: f64 = v.x;
            const y: f64 = v.y;
            const z: f64 = v.z;
            const r = k.rot;
            v.* = .{
                .x = @floatCast(r[0][0] * x + r[0][1] * y + r[0][2] * z),
                .y = @floatCast(r[1][0] * x + r[1][1] * y + r[1][2] * z),
                .z = @floatCast(r[2][0] * x + r[2][1] * y + r[2][2] * z),
            };
        }
        return if ((try zs.bond.check(app.gpa, &after, o)).stands) .{ .knocked = dir } else .weak;
    }

    /// Starts the fall of part i if it cannot stand as it is (see
    /// `standOf`). False: it stands, or support holds it, or a fall runs.
    pub fn fallStart(app: *App, i: usize) Allocator.Error!bool {
        if (app.fall != null or i >= app.plate.count()) return false;
        const st = try app.standOf(i);
        switch (st) {
            .stands, .weak => return false,
            .rolls, .knocked => {},
        }
        try app.bodyOf(i);
        switch (st) {
            .knocked => |d| {
                // The push of the nozzle: a spin toward the side that it
                // falls to, with the direction turned from the mesh to the
                // bed.
                const t = app.plate.parts.items[i].transform();
                app.fall.?.body.tip(.{ d[0] * t[0] + d[1] * t[3], d[0] * t[1] + d[1] * t[4] });
            },
            else => {},
        }
        return true;
    }

    /// The hand takes part i at the bed point `at` (on its surface): the
    /// part follows the hand as a real object does (rigid.Grab), and the
    /// steps of fallStep move it. False: a fall runs.
    pub fn grabStart(app: *App, i: usize, at: [3]f64) Allocator.Error!bool {
        if (app.fall != null or i >= app.plate.count()) return false;
        try app.bodyOf(i);
        app.fall.?.body.grabAt(at, at);
        return true;
    }

    /// The hand moves to `target` (bed point, mm).
    pub fn grabMove(app: *App, target: [3]f64) void {
        const f = &(app.fall orelse return);
        if (f.body.grab) |*g| g.target = .{ target[0], target[1], @max(target[2], 0) };
        f.body.wake();
    }

    /// The hand lets go: the part keeps its speed, falls, and rests (the
    /// steps of fallStep end the fall on the plate).
    pub fn grabEnd(app: *App) void {
        const f = &(app.fall orelse return);
        f.body.grab = null;
        f.body.wake();
        // With support on, the part keeps the orientation of the hand: it
        // goes down on the bed at once, and support holds it.
        if (app.settings.project.support != .off) f.body.asleep = true;
    }

    /// Turns the part in the hand by `deg` degrees about the axis (x, y,
    /// z) of the bed: the hand holds its orientation, and turns it.
    pub fn grabTurn(app: *App, axis: [3]f64, deg: f64) void {
        const f = &(app.fall orelse return);
        f.body.turnHand(axis, deg);
    }

    /// The body of part i as it is on the bed, as the fall.
    fn bodyOf(app: *App, i: usize) Allocator.Error!void {
        const part = &app.plate.parts.items[i];
        // The mesh in the frame of the bed.
        var m = try part.mesh.clone(app.gpa);
        defer m.deinit(app.gpa);
        const t = part.transform();
        for (m.vertices.items) |*v| {
            const x: f64 = v.x;
            const y: f64 = v.y;
            const z: f64 = v.z;
            v.* = .{
                .x = @floatCast(x * t[0] + y * t[3] + z * t[6] + t[9]),
                .y = @floatCast(x * t[1] + y * t[4] + z * t[7] + t[10]),
                .z = @floatCast(x * t[2] + y * t[5] + z * t[8] + t[11]),
            };
        }
        const body = try zs.rigid.Body.init(app.gpa, &m);
        app.fall = .{ .part = i, .body = body, .start = body.pos };
    }

    /// Runs the fall for dt seconds (fixed steps, at most 1/8 s). Null: no
    /// fall runs.
    pub fn fallStep(app: *App, dt: f64) Allocator.Error!?FallFrame {
        const f = &(app.fall orelse return null);
        const steps: usize = @intFromFloat(@ceil(std.math.clamp(dt, 0, 0.125) / zs.rigid.step_dt));
        for (0..@max(steps, 1)) |_| {
            f.body.step(zs.rigid.step_dt);
            // The time limit counts from the release of the hand.
            f.time = if (f.body.grab != null) 0 else f.time + zs.rigid.step_dt;
        }
        const b = f.body;
        const frame: FallFrame = .{
            .q = .{ b.rot[1], b.rot[2], b.rot[3], b.rot[0] },
            .pivot = f.start,
            .move = .{ b.pos[0] - f.start[0], b.pos[1] - f.start[1], b.pos[2] - f.start[2] },
            .done = b.asleep or f.time > 8,
        };
        if (frame.done) try app.fallFinish();
        return frame;
    }

    /// Ends a fall with no change of the plate.
    pub fn fallCancel(app: *App) void {
        if (app.fall) |*f| f.body.deinit(app.gpa);
        app.fall = null;
    }

    /// The part rests: its new orientation is the turn of the body, with
    /// support off flush on the face that holds it (the geometric settle
    /// of the last bit), at the place where it came to rest, on the bed.
    /// With support on, it keeps the orientation that the hand gave it,
    /// and support holds it.
    fn fallFinish(app: *App) Allocator.Error!void {
        const f = app.fall.?;
        defer app.fallCancel();
        const i = f.part;
        if (i >= app.plate.count()) return;
        try app.plate.applyTurn(app.gpa, i, zs.rigid.quatMat(f.body.rot));
        const part = &app.plate.parts.items[i];
        // The body rests on the bed: a part that floated is on it now.
        if (part.z > 0) part.z = 0;
        if (app.settings.project.support == .off) {
            const st = try zs.physics.settle(app.gpa, &part.mesh);
            if (st.rolls > 0) try app.plate.putDown(app.gpa, i, zs.physics.downOf(st));
        }
        // The center of mass where the body came to rest.
        const c = zs.rigid.massOf(&part.mesh).center;
        const t = part.transform();
        const cx = c[0] * t[0] + c[1] * t[3] + c[2] * t[6] + t[9];
        const cy = c[0] * t[1] + c[1] * t[4] + c[2] * t[7] + t[10];
        part.x += f.body.pos[0] - cx;
        part.y += f.body.pos[1] - cy;
        app.plate.clampOnBed(i, app.bedSize(), app.partGap());
        app.plate.keepOnBed(i, app.bedSize(), app.partGap());
        try app.plateChanged();
    }

    /// Physics for each change of the app that gives a part a new
    /// orientation (a load, a placement, a reset): a part that cannot stand
    /// falls over and rests, as settlePart, with no plateChanged (the
    /// caller does it). True if it fell. The Turn tool of a shell turns in
    /// steps and calls settlePart after the last step.
    fn settleNew(app: *App, i: usize) Allocator.Error!bool {
        return (try app.fallNow(i)) > 0;
    }

    fn settleFrom(app: *App, first: usize) Allocator.Error!void {
        var fell = false;
        for (first..app.plate.count()) |i| fell = (try app.settleNew(i)) or fell;
        if (fell) try app.plateChanged();
    }

    /// Puts the side of part i nearest to the bed point (x, y, z) on the
    /// bed ("this side on the bed", from a picked line).
    pub fn putPartDownAt(app: *App, i: usize, x: f64, y: f64, z: f64) Allocator.Error!void {
        const n = app.plate.sideAt(i, x, y, z) orelse return;
        try app.plate.putDown(app.gpa, i, n);
        try app.plateChanged();
    }

    /// Puts the side of part i under a ray of the view on the bed. Returns
    /// false, with no change, if the ray misses the part.
    pub fn putPartDownRay(app: *App, i: usize, o: [3]f64, d: [3]f64) Allocator.Error!bool {
        const n = app.plate.sideOnRay(i, o, d) orelse return false;
        try app.plate.putDown(app.gpa, i, n);
        try app.plateChanged();
        return true;
    }

    pub fn placePart(app: *App, i: usize, mode: zs.plate.PlaceMode, axis: u2) Allocator.Error!void {
        try app.plate.place(app.gpa, i, mode, axis, app.settings.project.support_angle);
        _ = try app.settleNew(i);
        try app.plateChanged();
    }

    pub fn resetPart(app: *App, i: usize) Allocator.Error!void {
        try app.plate.resetPose(app.gpa, i);
        _ = try app.settleNew(i);
        try app.plateChanged();
    }

    /// Smart placement of the whole plate: each part turns to its best
    /// orientation (less support, more on the bed, low), then the plate is
    /// arranged. Returns false if the parts do not all fit.
    pub fn smartPlacePlate(app: *App) Allocator.Error!bool {
        for (0..app.plate.count()) |i| {
            try app.plate.place(app.gpa, i, .smart, 0, app.settings.project.support_angle);
            _ = try app.settleNew(i);
        }
        return app.arrangePlate();
    }

    /// Packs all parts on the bed. Returns false if they do not all fit.
    pub fn arrangePlate(app: *App) Allocator.Error!bool {
        const ok = try app.plate.arrange(app.gpa, app.bedSize(), app.partGap());
        try app.plateChanged();
        return ok;
    }

    pub fn clearPlate(app: *App) Allocator.Error!void {
        app.fallCancel();
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
        var copy = app.strings.allocator().dupe(u8, value) catch return error.InvalidValue;
        if (zs.settings.isGcodeTemplate(name)) copy = zs.settings.unixLines(copy);
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
    pub fn setFormula(app: *App, old_name: []const u8, text: []const u8) (Allocator.Error || Settings.SetError || zs.expr.Error)!void {
        const name = zs.settings.currentName(old_name);
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
    /// The context of the refinements of the app (see app/refine.zig).
    pub fn refineContext(app: *App) refine.Context {
        const t = app.allToolpaths();
        const height: f64 = if (t) |tp| (if (tp.layer_z.items.len > 0) tp.layer_z.items[tp.layer_z.items.len - 1] else 0) else 0;
        return .{
            .material = app.settings.filament.material,
            .printer = app.settings.machine.name,
            .nozzle = app.settings.machine.nozzle_diameter,
            .height = height,
        };
    }

    /// The records of the refinements of the plate: its changes from the
    /// guide, the first slice (see app/refine.zig).
    pub fn writeRefinements(app: *App, gpa: Allocator, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
        const guide = refine.guideFacts(&app.undo) orelse return;
        var now: std.Io.Writer.Allocating = .init(gpa);
        defer now.deinit();
        try app.writeFacts(&now.writer);
        try refine.records(gpa, guide, now.written(), app.refineContext(), w);
    }

    /// Applies a suggestion line of refine.suggest: a setting of the print,
    /// of each part, or of the bottom or top layers.
    pub fn applySuggestion(app: *App, line: []const u8) (OverrideError || error{ BadSuggestion, NoPart })!void {
        const sg = refine.Suggestion.parse(line) orelse return error.BadSuggestion;
        var value_buf: [256]u8 = undefined;
        // The value of a suggestion is escaped (history.writeEscaped).
        var vw: std.Io.Writer = .fixed(&value_buf);
        var i: usize = 0;
        while (i < sg.value.len) : (i += 1) {
            const c = sg.value[i];
            if (c == '\\' and i + 1 < sg.value.len) {
                i += 1;
                vw.writeByte(switch (sg.value[i]) {
                    't' => '\t',
                    'n' => '\n',
                    else => sg.value[i],
                }) catch return error.BadSuggestion;
            } else vw.writeByte(c) catch return error.BadSuggestion;
        }
        const value = vw.buffered();
        if (std.mem.eql(u8, sg.kind, "print")) return app.setSetting(sg.key, value);
        if (std.mem.eql(u8, sg.kind, "layers")) return app.setOverride(sg.lo, sg.hi, sg.key, value);
        if (std.mem.eql(u8, sg.kind, "part")) {
            if (app.plate.count() == 0) return error.NoPart;
            for (0..app.plate.count()) |p| app.setPartSetting(p, sg.key, value) catch |e| switch (e) {
                error.NoPart => return error.NoPart,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadSuggestion,
            };
            return;
        }
        return error.BadSuggestion;
    }

    pub fn writeFacts(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const defaults: Settings = .{};
        inline for (.{ "machine", "filament", "project" }, .{ "machine", "filament", "print" }) |g, scope| {
            const values = @field(app.settings, g);
            const base_values = @field(defaults, g);
            inline for (@typeInfo(@TypeOf(values)).@"struct".fields) |f| {
                if (comptime f.type == [zs.settings.max_nozzles]zs.settings.Nozzle) {
                    // The nozzles after the first: machine.nozzle.k.field.
                    for (1..zs.settings.max_nozzles) |k| {
                        inline for (@typeInfo(zs.settings.Nozzle).@"struct".fields) |nf| {
                            const v = @field(@field(values, f.name)[k], nf.name);
                            if (v != @field(@field(base_values, f.name)[k], nf.name)) try w.print("{s}\t{s}.{s}.{d}.{s}\t{d}\n", .{ scope, g, f.name, k, nf.name, v });
                        }
                    }
                    continue;
                }
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
                .filament => try w.print("filament {d}\n", .{@as(u32, @intFromFloat(e.value))}),
            }
        }
        // The support marks of the user at a point.
        for (app.marks.items) |m| {
            if (m.poly.len > 0 or @intFromEnum(m.kind) > @intFromEnum(zs.support.Mark.Kind.block)) continue;
            try w.print("marks\tsupport mark at {d:.1}, {d:.1}, z {d:.2}\t{s}, {d:.1} mm\n", .{ m.x, m.y, m.z, @tagName(m.kind), m.r });
        }
        try app.areas.writeFacts(w);
        try filament_slots.writeFacts(app, w);
        try support_trees.writeFacts(app, w);
        for (app.plate.parts.items) |p| {
            const name: []const u8 = p.name;
            try w.print("part:{s}\t(part)\tyes\n", .{name});
            try w.print("part:{s}\tposition\t{d:.2}, {d:.2}\n", .{ name, p.x, p.y });
            if (p.rot != 0) try w.print("part:{s}\trotation\t{d:.1}\n", .{ name, p.rot });
            if (p.z != 0) try w.print("part:{s}\theight\t{d:.2}\n", .{ name, p.z });
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
            // The paint: a hash, so a change of the paint is a step.
            if (!p.paint.isEmpty()) try w.print("part:{s}\t(paint)\t{x}\n", .{ name, p.paint.hash() });
            // Each label: a summary, so each edit of a label is a step.
            for (p.labels.items) |*l| {
                try w.print("part:{s}\tlabel {d}\t", .{ name, l.id });
                try zs.label.summary(l, w);
                try w.writeByte('\n');
            }
            for (p.meta) |m| {
                if (!std.mem.startsWith(u8, m.key, "zslice:")) continue;
                try w.print("part:{s}\t{s}\t", .{ name, m.key["zslice:".len..] });
                try history.writeEscaped(w, m.value);
                try w.writeByte('\n');
            }
            // The settings of each region of some layers (body_region.zig).
            for (p.volumes.items) |v| {
                const rid = regionId(v.meta);
                if (rid == 0) continue;
                // A filament pick: its filament and its shape.
                if (zs.body_region.pickFilament(v.meta)) |f| {
                    try w.print("part:{s}\t(pick {d})\t{d} {x}\n", .{ name, rid, f, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(v.mesh.vertices.items)) });
                    continue;
                }
                for (v.meta) |m| {
                    if (!isRegionSettingKey(m.key)) continue;
                    try w.print("part:{s}\tregion {d} {s}\t", .{ name, rid, m.key["zslice:".len..] });
                    try history.writeEscaped(w, m.value);
                    try w.writeByte('\n');
                }
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
        const owned = try a.dupe(u8, text);
        try zs.profile.apply(a, &g, .project, "global", owned, null, diag);
        // A global text from before the accelerations moved to the
        // printer: its values go to the printer now.
        if (try zs.profile.movedKeys(a, .project, owned) > 0) for (zs.settings.moved_settings) |m| {
            if (sameValue(g, .{}, m[1])) continue;
            var w: std.Io.Writer.Allocating = .init(a);
            writeSettingOf(g, m[1], &w.writer) catch continue;
            app.settings.set(m[1], w.written()) catch {};
        };
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

    /// Imports the profile of another slicer (import_profile.zig): its
    /// values become changes of the settings now, and `w` gets the
    /// report. The settings change only if the file is a profile.
    pub fn importProfile(app: *App, name: []const u8, bytes: []const u8, w: *std.Io.Writer) (zs.import_profile.Error || std.Io.Writer.Error)!void {
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const r = try zs.import_profile.read(arena_state.allocator(), bytes, name, &app.settings);
        for (r.changes) |ch| app.setSetting(ch.name, ch.value) catch {};
        try r.writeReport(w);
    }

    pub const OverrideError = Settings.SetError || error{ NotPerLayer, OutOfMemory };

    /// Changes a setting for the layers with a top z from z_min to z_max.
    /// An override for the same range and setting is replaced. Only
    /// settings.layer_settings can change for some layers.
    pub fn setOverride(app: *App, z_min: f64, z_max: f64, old_name: []const u8, value: []const u8) OverrideError!void {
        // An override of a setting that moved (an old file) gets its new
        // name.
        const name = zs.settings.currentName(old_name);
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
    /// True if the check of the last slice has run, so `checks` returns
    /// at once. A card that shows the issues of a line asks this first.
    pub fn checksReady(app: *const App) bool {
        // The worker writes the check before the state goes to `done`.
        return app.getState() == .done and app.checks_result != null;
    }

    pub fn checks(app: *App) (Allocator.Error || error{ NoResult, Pending })!*const checks_mod.Result {
        if (app.getState() != .done) return error.NoResult;
        if (app.checks_pending.load(.acquire)) return error.Pending;
        if (app.checks_result) |*r| return r;
        const j = &(app.job orelse return error.NoResult);
        const t = app.allToolpaths() orelse return error.NoResult;
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const stands = try app.checkStands(arena.allocator());
        app.checks_result = try checks_mod.runLabels(app.gpa, j, t, app.settings, stands, app.stats, try app.checkLabels(arena.allocator()));
        return &app.checks_result.?;
    }

    /// The labels of the last slice, for the check (see checks.labelIssues):
    /// the copies of the slice plan, with the names of their parts.
    fn checkLabels(app: *const App, a: Allocator) Allocator.Error![]checks_mod.LabelInput {
        var n: usize = 0;
        for (app.slice_parts) |sp| n += sp.labels.len;
        const out = try a.alloc(checks_mod.LabelInput, n);
        var k: usize = 0;
        for (app.slice_parts) |sp| {
            const name: []const u8 = if (sp.part < app.plate.parts.items.len) app.plate.parts.items[sp.part].name else "";
            for (sp.labels) |*l| {
                out[k] = .{ .part = name, .label = l };
                k += 1;
            }
        }
        return out;
    }

    /// The bond of each part on the bed with support off, for the check.
    /// The names are in `a`.
    fn checkStands(app: *App, a: Allocator) Allocator.Error![]checks_mod.Stand {
        var stands: std.ArrayList(checks_mod.Stand) = .empty;
        for (app.plate.parts.items, 0..) |p, i| {
            if (p.trees != null or app.settings.project.support != .off) continue;
            const m = try app.bondOf(i);
            try stands.append(a, .{ .name = try a.dupe(u8, p.name), .x = p.x, .y = p.y, .result = m.result, .weak = m.stand == .weak });
        }
        return stands.items;
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

    pub fn writeSettingOf(settings: Settings, old_name: []const u8, w: *std.Io.Writer) (Settings.SetError || std.Io.Writer.Error)!void {
        const name = zs.settings.currentName(old_name);
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.UnknownSetting;
        if (zs.settings.nozzleSetting(name)) |ns| {
            inline for (@typeInfo(zs.settings.Nozzle).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, ns.field)) return writeValue(w, @field(settings.machine.nozzle[ns.k], f.name));
            }
            return error.UnknownSetting;
        }
        inline for (@typeInfo(Settings).@"struct".fields) |g| {
            if (std.mem.eql(u8, g.name, name[0..dot])) {
                const group = @field(settings, g.name);
                inline for (@typeInfo(g.type).@"struct".fields) |f| {
                    if (comptime f.type == [zs.settings.max_nozzles]zs.settings.Nozzle) continue;
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
        const start_t0 = zs.stage_clock.now();
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
        app.slice_draft = app.draft;
        if (app.draft) {
            const s = &app.slice_settings;
            s.project.resolution = @max(s.project.resolution, draft_resolution);
            s.project.gap_fill = false;
            s.project.wall_generator = .classic;
        }
        app.gpa.free(app.slice_overrides);
        app.slice_overrides = app.gpa.dupe(zs.settings.Override, app.overrides.items) catch &.{};
        app.gpa.free(app.slice_filaments);
        app.slice_filaments = app.gpa.dupe(zs.settings.Filament, app.filaments.items) catch &.{};
        // The places of the parts for the filament edits of lines. The
        // worker reads them while the shell changes the plate.
        app.gpa.free(app.slice_places);
        app.slice_places = app.makeLinePlaces() catch &.{};
        app.edits.places = app.slice_places;
        app.gpa.free(app.slice_view_marks);
        app.slice_view_marks = app.gpa.dupe(zs.support.Mark, app.marks.items) catch &.{};
        app.gpa.free(app.slice_marks);
        app.slice_marks = app.sliceMarks() catch &.{};
        try app.makeSlicePlan();
        // The bond of the parts for the check on the worker: it reads the
        // plate, which the shell changes while the slice runs.
        if (app.auto_checks) app.slice_stands = try app.checkStands(app.slice_arena.?.allocator());
        app.cancel_flag.store(false, .release);
        // The simulation is for the exact slice: a draft has none.
        // engine.auto_simulate off: only a run by hand (requestSimulation).
        app.sim_coming.store(app.auto_simulate and app.settings.engine.auto_simulate and !app.draft, .release);
        app.state.store(.slicing, .release);
        // The experiment of a faster offset (project.fast_offsets): a
        // switch of the process, read by each offset of this slice.
        zs.offset.fast_offsets.store(app.settings.project.fast_offsets, .monotonic);
        zs.stage_clock.add(.start, start_t0);
        if (comptime !has_threads) {
            // No threads: slice now, on the calling thread.
            work(app);
            return;
        }
        app.worker = std.Thread.spawn(.{}, work, .{app}) catch {
            app.sim_coming.store(false, .release);
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

    /// Stops a slice that runs, before a change of the parts that the
    /// slice reads (see app/labels.zig).
    pub fn stopSlice(app: *App) void {
        app.stopWorker();
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
        app.slice_stands = null;
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

    /// The outline tolerance of a draft slice (mm).
    pub const draft_resolution = 0.05;

    /// The next slices are drafts (true) or exact (false). A draft is a
    /// slice for the view while the user drags or edits: the outlines
    /// lose the points within 0.05 mm of a straight line, the gaps get
    /// no fill, and the walls are classic walls. All other paths are as
    /// in the exact slice, within the outline tolerance. A draft of a
    /// 3DBenchy needs a third of the CPU time of the exact slice.
    ///
    /// The G-code of a draft is not for a printer: `exactGcode` gives
    /// none (see `isDraft`). The shell turns the draft off at the end of
    /// the drag and slices again. Only the shell uses it.
    /// With `engine.draft_slices` off, the slices stay exact.
    pub fn setDraft(app: *App, on_: bool) void {
        const on = on_ and app.settings.engine.draft_slices;
        if (app.draft == on) return;
        app.stopWorker();
        app.draft = on;
    }

    /// The state of the Faster slicing switch (see speed.zig).
    pub fn speedState(app: *const App) speed.State {
        return speed.state(app.settings);
    }

    /// Faster slicing on: the options of the switch get their faster
    /// values. Off: their built-in defaults, for the exact slice. A value
    /// replaces the formula of its option. The other settings stay.
    pub fn setFasterSlicing(app: *App, on: bool) Settings.SetError!void {
        const target = speed.applied(app.settings, on);
        for (speed.options) |o| {
            if (o.faster.len == 0) continue;
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeSettingOf(target, o.name, &w) catch return error.InvalidValue;
            try app.setSetting(o.name, w.buffered());
        }
    }

    /// True if the slice that runs, or the last slice, is a draft.
    pub fn isDraft(app: *const App) bool {
        return app.slice_draft;
    }

    /// The G-code of the last slice for a file or a printer: null for a
    /// draft, and null with no result.
    pub fn exactGcode(app: *const App) ?[]const u8 {
        if (app.slice_draft) return null;
        return app.gcode();
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
        support_trees.check(app);
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
        const all_parts = try a.alloc(zs.plate_job.PartInput, plan.parts.len);
        var n_parts: usize = 0;
        app.slice_left_out_n = 0;
        for (plan.parts) |pp| {
            const mesh = &app.slice_meshes[pp.input];
            // A part lower than half of the first layer: no layer cuts it.
            // It stays out of the slice, so that the other parts slice,
            // and the check names it (checks.fitIssues). With no other
            // part, the slice fails with PartTooThin.
            if (plan.parts.len > 1) {
                const bb = mesh.bounds();
                if (bb.max[2] * app.settings.filament.shrinkage_z < app.settings.project.first_layer_height / 2) {
                    if (app.slice_left_out_n < app.slice_left_out.len) {
                        const nm = if (part_of[pp.input]) |pi| app.plate.parts.items[pi].name else "";
                        app.slice_left_out[app.slice_left_out_n] = .of(nm, @max(0, bb.max[2] - bb.min[2]), (bb.min[0] + bb.max[0]) / 2, (bb.min[1] + bb.max[1]) / 2);
                        app.slice_left_out_n += 1;
                    }
                    continue;
                }
            }
            const out = &all_parts[n_parts];
            n_parts += 1;
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
            // The skin and infill lines turn with the part
            // (Project.angles_follow_part): their angles get the turn of
            // the part on the bed.
            if (part_of[pp.input]) |pi| changes = try angleChanges(a, app.settings, changes, app.plate.parts.items[pi].rot);
            // The support trees of the user, on the plate.
            var trees: ?*const zs.support_skeleton.Skeleton = null;
            var trees_layers: u64 = 0;
            if (part_of[pp.input]) |pi| if (app.plate.parts.items[pi].trees) |*t| {
                const pt = &app.plate.parts.items[pi];
                const sk = try a.create(zs.support_skeleton.Skeleton);
                sk.* = .{};
                try sk.appendMoved(a, &t.sk, pt.x * 1000, pt.y * 1000);
                trees = sk;
                trees_layers = t.layers;
            };
            // The paint of the part: a copy, as the user can paint while the
            // slice runs.
            var paint: ?*const zs.paint.Paint = null;
            if (part_of[pp.input]) |pi| if (!app.plate.parts.items[pi].paint.isEmpty()) {
                const pc = try a.create(zs.paint.Paint);
                pc.* = try app.plate.parts.items[pi].paint.clone(a);
                paint = pc;
            };
            // The labels of the part, on the plate: copies, as the user
            // can change them while the slice runs.
            var part_labels: []const zs.label.Label = &.{};
            if (part_of[pp.input]) |pi| {
                const pt = &app.plate.parts.items[pi];
                if (pt.labels.items.len > 0) {
                    const ls = try a.alloc(zs.label.Label, pt.labels.items.len);
                    for (pt.labels.items, ls) |l, *d| d.* = try pt.placeLabel(l).clone(a);
                    part_labels = ls;
                }
            }
            out.* = .{
                .mesh = mesh,
                .changes = changes,
                .modifiers = pp.modifiers,
                .picks = pp.picks,
                .marks = marks.items,
                .part = part_of[pp.input] orelse 0,
                .trees = trees,
                .trees_layers = trees_layers,
                .paint = paint,
                .labels = part_labels,
                .name = if (part_of[pp.input]) |pi| try a.dupe(u8, app.plate.parts.items[pi].name) else "",
            };
        }
        const parts = all_parts[0..n_parts];
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

    /// `trim`, with the free on a new thread: the app gives up the memory
    /// at once, and the thread frees it (the unmap of the memos of a
    /// 3DBenchy held the UI thread for 50 to 70 ms). For the thread of a
    /// shell.
    pub fn trimLater(app: *App) void {
        if (comptime !has_threads) return app.trim();
        if (app.getState() == .slicing) return;
        const t = app.gpa.create(Trash) catch return app.trim();
        t.* = .{ .gpa = app.gpa };
        if (app.job) |*j| j.takeMemos(&t.memos) catch j.dropMemos();
        t.prev_job = app.prev_job;
        app.prev_job = null;
        t.gcode = app.spare_gcode;
        app.spare_gcode = &.{};
        t.paths = app.spare_paths;
        app.spare_paths = .{};
        const thread = std.Thread.spawn(.{}, Trash.free, .{t}) catch return t.free();
        thread.detach();
    }

    /// The memory of `trimLater`.
    const Trash = struct {
        gpa: Allocator,
        memos: std.ArrayList(zs.layer.Memo) = .empty,
        prev_job: ?zs.PlateJob = null,
        gcode: []u8 = &.{},
        paths: Toolpaths = .{},

        fn free(t: *Trash) void {
            for (t.memos.items) |*m| m.deinit();
            t.memos.deinit(t.gpa);
            if (t.prev_job) |*j| j.deinit();
            t.gpa.free(t.gcode);
            t.paths.deinit(t.gpa);
            t.gpa.destroy(t);
        }
    };

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
        app.dropScenes();
        app.dropSimulation();
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
        defer app.sim_coming.store(false, .release);
        const monitor: zs.engine.Monitor = .{ .ctx = app, .progress = onProgress, .cancel = &app.cancel_flag };
        // The overrides of the whole part change the settings of the slice;
        // the others change some layers.
        var part = app.slice_settings;
        // The plate has placed the parts: the engine keeps their places.
        part.project.placement = .file;
        // The settings of the parts for the whole plate, under the
        // overrides of the user.
        if (app.slice_plan) |*pp| pp.applyBase(&part) catch |e| return app.finishFailed(e);
        if (app.slice_parts.len == 0) return app.finishFailed(if (app.slice_left_out_n > 0) error.PartTooThin else error.EmptyMesh);
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
        // The job keeps the move streams of the print. The edits of the
        // lines change the plans, and the job does not see them in `init`.
        var edits_hash = std.hash.Wyhash.init(0);
        for (app.edits.list.items) |e| {
            zs.settings.hashValue(&edits_hash, .{ e.key, e.kind, e.value, e.layer, e.x, e.y, e.z });
            // A filament edit depends on the place of its part too.
            const a = e.anchor orelse continue;
            if (app.edits.placeOf(a.part)) |pl| edits_hash.update(std.mem.asBytes(pl));
        }
        // The order of the parts on a level depends on the number of
        // filaments (see plate_job.zig).
        zs.settings.hashValue(&edits_hash, app.slice_filaments.len);
        const init_t0 = zs.stage_clock.now();
        const job_or = zs.PlateJob.init(app.gpa, part, app.slice_parts, .{ .overrides = layer_overrides.items, .monitor = monitor, .old = prev, .streams = edits_hash.final(), .filaments = app.slice_filaments, .left_out = app.slice_left_out[0..app.slice_left_out_n] });
        zs.stage_clock.add(.init, init_t0);
        // The new job took what it could use. A job that failed (for
        // example, a cancel) can leave the old job without outlines, so the
        // old job goes in each case.
        app.dropPrevJob();
        var job = job_or catch |e| return app.finishFailed(e);
        // The edits of the user apply to each layer plan. A level with a
        // move stream gets no plan: its edits stay as the slice before
        // found them. An edit that came back (undo, a file) gets that
        // state again.
        if (!job.hasStreams()) app.edits.resetApplied() else app.edits.recall();
        job.edits = &app.edits;
        job.markLineEdits(&app.edits) catch |e| {
            job.deinit();
            return app.finishFailed(e);
        };
        var out: std.Io.Writer.Allocating = .initOwnedSlice(app.gpa, app.spare_gcode);
        app.spare_gcode = &.{};
        out.clearRetainingCapacity();
        var store = app.spare_paths;
        app.spare_paths = .{};
        store.clearRetainingCapacity();
        store.gpa = app.gpa;
        store.z_hop = @floatCast(part.machine.z_hop);
        const sink: zs.engine.Job.LayerSink = .{ .ctx = &store, .func = Toolpaths.addLayer };
        // The pictures for the screen of the printer, first. A Bambu Lab
        // printer has them in its .gcode.3mf, and its G-code starts with
        // the header block of Bambu Studio.
        if (zs.printers.bambu(part.machine.model) == null)
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
        // The times and the filament in the header of a Bambu Lab G-code.
        {
            const lvl = job.levels;
            const top = if (lvl.len > 0) lvl[lvl.len - 1].z else 0;
            zs.gcode.Emitter.finishBambuHeader(bytes, stats, job.slots.len, job.resolved.filament_area, top);
            // The progress of each layer: the start of its first path.
            if (std.mem.startsWith(u8, bytes, "; HEADER_BLOCK_START\n")) {
                const n = store.layer_ends.items.len;
                if (app.gpa.alloc(f64, n)) |starts| {
                    defer app.gpa.free(starts);
                    for (0..n) |l| {
                        const p0: usize = if (l == 0) 0 else store.layer_ends.items[l - 1];
                        starts[l] = if (p0 < store.path_start_time.items.len) store.path_start_time.items[p0] else stats.print_time_s;
                    }
                    zs.gcode.Emitter.finishBambuProgress(bytes, starts, stats.print_time_s);
                } else |_| {}
            }
        }
        const buf = out.writer.buffer;
        app.checks_result = null;
        const stands_now = app.slice_stands;
        if (stands_now != null) app.checks_pending.store(true, .release);
        app.part_box = job.bounds() orelse .{ 0, 0, 0, 0 };
        app.job = job;
        app.edits.remember(app.gpa);
        // The places of the slice that the view shows now.
        app.gpa.free(app.scene_places);
        app.scene_places = app.gpa.dupe(edits_mod.Place, app.slice_places) catch &.{};
        app.toolpaths = store;
        app.gcode_bytes = bytes;
        app.gcode_buf = buf;
        app.stats = stats;
        _ = app.done_count.fetchAdd(1, .release);
        // The scene of the view, before the event: the view of the shell
        // only takes it (see `scene_hook`).
        app.buildScene(.plan, &app.toolpaths);
        // A plate set waits for the scene bytes of this slice (see
        // `writeSceneBytes`): it skips a plate whose bytes come.
        if (app.scene_bytes_on.load(.acquire) and app.scene_hook.load(.acquire) != null) app.scene_bytes_coming.store(true, .release);
        app.state.store(.done, .release);
        app.emit(.sliced, 1, 0);
        app.writeSceneBytes(.plan, &app.toolpaths);
        // The check of the print (see `auto_checks`), after the slice
        // shows, with the settings at the start of the slice. A change
        // stops it within a layer; the next slice checks again.
        if (stands_now) |stands| {
            const label_inputs = app.checkLabels(app.gpa) catch &.{};
            defer app.gpa.free(label_inputs);
            const r = checks_mod.runWith(app.gpa, &app.job.?, &app.toolpaths, app.slice_settings, stands, app.stats, label_inputs, &app.cancel_flag) catch null;
            app.checks_result = r;
            app.checks_pending.store(false, .release);
            if (r != null) app.emit(.checked, 1, 0);
        }
        if (app.sim_coming.load(.acquire)) app.simulateOnWorker();
    }

    /// Simulates the print of the last slice on a worker thread, as
    /// `auto_simulate` does after a slice. The `simulated` event tells
    /// when it is ready, and `adoptSimulation` shows it. No new run if a
    /// simulation of the slice is there, waits, or runs. On the thread of
    /// the shell: the worker has no slice left, so the call waits little
    /// for it.
    pub fn requestSimulation(app: *App) error{ NoResult, ThreadSpawnFailed }!void {
        if (app.getState() != .done) return error.NoResult;
        if (app.sim != null or app.sim_ready.load(.acquire) or app.sim_coming.load(.acquire)) return;
        if (comptime !has_threads) return error.ThreadSpawnFailed;
        app.stopWorker();
        // The simulation of the old worker can be ready now.
        if (app.sim_ready.load(.acquire)) return;
        app.cancel_flag.store(false, .release);
        app.sim_coming.store(true, .release);
        app.worker = std.Thread.spawn(.{}, simulateWork, .{app}) catch {
            app.sim_coming.store(false, .release);
            return error.ThreadSpawnFailed;
        };
    }

    fn simulateWork(app: *App) void {
        defer app.sim_coming.store(false, .release);
        app.simulateOnWorker();
    }

    /// The simulated print of the slice, on the thread of the slice, in
    /// pieces with a check of the cancel flag between them: a change stops
    /// it at once. The result waits in `sim_pending` for the thread of the
    /// shell (`adoptSimulation`), and the `simulated` event tells it.
    fn simulateOnWorker(app: *App) void {
        const job = sim_print.Job.createFrom(app.gpa, &app.toolpaths, sim_print.paramsOf(app.slice_settings), app.sim_checkpoints) catch return;
        defer job.destroy();
        // A change stops the run within a step of the simulation, so the
        // shell thread waits little for this thread (see stopWorker).
        job.setCancel(&app.cancel_flag);
        app.sim_permille.store(0, .release);
        app.sim_working.store(true, .release);
        defer app.sim_working.store(false, .release);
        while (true) {
            if (app.cancel_flag.load(.acquire)) return;
            const done = job.advance(sim_piece) catch return;
            app.sim_permille.store(@intFromFloat(std.math.clamp(job.progress(), 0, 1) * 1000), .release);
            if (done) break;
        }
        if (app.cancel_flag.load(.acquire)) return;
        const r = job.finish() catch return;
        if (app.cancel_flag.load(.acquire)) {
            var x = r;
            x.deinit(app.gpa);
            return;
        }
        app.keepCheckpoints(job);
        app.sim_pending = r;
        app.buildScene(.sim, &app.sim_pending.?.paths);
        // The shell can take the result after the event: the lists of the
        // paths stay until the next slice stops this thread.
        const paths = app.sim_pending.?.paths;
        if (app.scene_bytes_on.load(.acquire) and app.scene_hook.load(.acquire) != null) app.scene_bytes_coming.store(true, .release);
        app.sim_ready.store(true, .release);
        app.emit(.simulated, 1, 0);
        app.writeSceneBytes(.sim, &paths);
    }

    /// The paths of a piece of a simulation that runs in pieces: about a
    /// few ms of work, so a cancel or a message waits little.
    pub const sim_piece = 64;

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

    /// The id of the last slice: the app, and its count of slices.
    pub fn sliceId(app: *const App) u64 {
        var h = std.hash.Wyhash.init(0x5ce4e);
        h.update(std.mem.asBytes(&app.uid));
        h.update(std.mem.asBytes(&app.done_count.load(.acquire)));
        return h.final();
    }

    /// The id of the result that `allToolpaths` gives (with `sim`: the
    /// simulated print of the slice): the slice and the kind. A view
    /// compares it to see a new result.
    pub fn resultId(app: *const App, sim: bool) u64 {
        return std.hash.Wyhash.hash(app.sliceId(), &.{@intFromBool(sim)});
    }

    /// The input of a scene of the view from the last slice (see
    /// `allToolpaths`) and the settings now, or null with no result.
    pub fn sceneSource(app: *const App) ?SceneSource {
        const tp = app.allToolpaths() orelse return null;
        return .{
            .settings = &app.settings,
            .filaments = app.filaments.items,
            .marks = app.marks.items,
            .tp = tp,
            .job = if (app.job) |*j| j else null,
            .part_box = app.partBounds() orelse return null,
            .result = app.resultId(tp != &app.toolpaths),
            .slice = app.sliceId(),
            .app = app.uid,
        };
    }

    /// Builds the scene of `kind` on the worker (see `scene_hook`), from
    /// the settings at the start of the slice.
    fn buildScene(app: *App, kind: SceneKind, tp: *const Toolpaths) void {
        const hook = app.scene_hook.load(.acquire) orelse return;
        if (app.cancel_flag.load(.acquire)) return;
        const scene_t0 = zs.stage_clock.now();
        defer zs.stage_clock.add(.scene, scene_t0);
        const scene = hook.build(.{
            .settings = &app.slice_settings,
            .filaments = app.slice_filaments,
            .marks = app.slice_view_marks,
            .tp = tp,
            .job = if (app.job) |*j| j else null,
            .part_box = app.part_box,
            .result = app.resultId(kind == .sim),
            .slice = app.sliceId(),
            .app = app.uid,
            .cancel = &app.cancel_flag,
        }, app.scene_mode.load(.acquire)) orelse return;
        if (app.scenes[@intFromEnum(kind)].swap(scene, .acq_rel)) |old| hook.free(old);
    }

    /// The scene bytes of the slice or of its simulated print for a plate
    /// set (see `scene_bytes_on`), on the worker after the event.
    fn writeSceneBytes(app: *App, kind: SceneKind, tp: *const Toolpaths) void {
        defer app.scene_bytes_coming.store(false, .release);
        if (!app.scene_bytes_on.load(.acquire)) return;
        const hook = app.scene_hook.load(.acquire) orelse return;
        if (app.cancel_flag.load(.acquire)) return;
        var sb = hook.write(app.gpa, .{
            .settings = &app.slice_settings,
            .filaments = app.slice_filaments,
            .marks = app.slice_view_marks,
            .tp = tp,
            .job = if (app.job) |*j| j else null,
            .part_box = app.part_box,
            .result = app.resultId(kind == .sim),
            .slice = app.sliceId(),
            .app = app.uid,
            .cancel = &app.cancel_flag,
        }, app.scene_mode.load(.acquire)) orelse return;
        sb.gen = app.done_count.load(.acquire);
        const p = app.gpa.create(SceneBytes) catch {
            app.gpa.free(sb.bytes);
            return;
        };
        p.* = sb;
        if (app.scene_bytes[@intFromEnum(kind)].swap(p, .acq_rel)) |old| app.freeSceneBytes(old);
        app.scene_bytes_coming.store(false, .release);
        app.emit(.scene_bytes, 1, 0);
    }

    /// The scene bytes of the worker with key `key` and slice `gen`, or
    /// null. The caller owns them (in `gpa`): take `bytes`, then free the
    /// struct with gpa.destroy. Bytes of an older slice go.
    pub fn takeSceneBytes(app: *App, key: u64, gen: u32) ?*SceneBytes {
        for (&app.scene_bytes) |*slot| {
            const sb = slot.load(.acquire) orelse continue;
            if (sb.gen != gen) {
                if (slot.cmpxchgStrong(sb, null, .acq_rel, .acquire) == null) app.freeSceneBytes(sb);
                continue;
            }
            if (sb.key != key) continue;
            if (slot.cmpxchgStrong(sb, null, .acq_rel, .acquire) == null) return sb;
        }
        return null;
    }

    pub fn freeSceneBytes(app: *App, sb: *SceneBytes) void {
        app.gpa.free(sb.bytes);
        app.gpa.destroy(sb);
    }

    /// The scene of `kind` that the worker built, or null. The caller
    /// owns it.
    pub fn takeScene(app: *App, kind: SceneKind) ?*anyopaque {
        return app.scenes[@intFromEnum(kind)].swap(null, .acq_rel);
    }

    /// Sets `scene_hook` (null: no scenes). A scene that waits with the
    /// old hook goes.
    pub fn setSceneHook(app: *App, hook: ?*const SceneHook) void {
        const old = app.scene_hook.swap(hook, .acq_rel);
        if (old != null and old != hook) app.dropScenesWith(old.?);
    }

    fn dropScenes(app: *App) void {
        app.scene_bytes_coming.store(false, .release);
        for (&app.scene_bytes) |*slot| if (slot.swap(null, .acq_rel)) |sb| app.freeSceneBytes(sb);
        app.dropScenesWith(app.scene_hook.load(.acquire) orelse return);
    }

    fn dropScenesWith(app: *App, hook: *const SceneHook) void {
        for (&app.scenes) |*sc| if (sc.swap(null, .acq_rel)) |old| hook.free(old);
    }

    /// The paths of all layers, for a 3D view: the paths of the slice, or
    /// the paths as the plastic set while the simulation shows (see
    /// `showSimulated`).
    pub fn allToolpaths(app: *const App) ?*const Toolpaths {
        if (app.getState() != .done) return null;
        if (app.show_sim) if (app.sim) |*s| return &s.paths;
        return &app.toolpaths;
    }

    /// Simulates the plastic of the last slice: it comes out of the
    /// nozzle, hangs, falls, cools, and sets (see print_sim.zig). Then
    /// shows the result: `allToolpaths` gives the paths as the plastic
    /// set, until `showSimulated(false)` or the next slice. A view shows
    /// them after its next load. It runs on the calling thread: a
    /// 3DBenchy (585 000 masses, one for each half bead width) runs for
    /// about 1.5 s.
    pub fn simulatePrint(app: *App) !zs.print_sim.Stats {
        if (app.getState() != .done) return error.NoResult;
        // A simulation that runs on the thread of the slice stops.
        app.stopWorker();
        app.dropSimulation();
        const job = try sim_print.Job.createFrom(app.gpa, &app.toolpaths, sim_print.paramsOf(app.slice_settings), app.sim_checkpoints);
        defer job.destroy();
        while (!try job.advance(std.math.maxInt(usize))) {}
        const r = try job.finish();
        app.keepCheckpoints(job);
        app.sim = r;
        app.show_sim = true;
        return r.stats;
    }

    /// Shows the simulated print (on), or the slice (off). error.NoResult
    /// if there is no simulation of the last slice.
    pub fn showSimulated(app: *App, on: bool) error{NoResult}!void {
        _ = app.adoptSimulation();
        if (on and app.sim == null) return error.NoResult;
        app.show_sim = on;
    }

    /// Takes the simulation of the thread of the slice (after the
    /// `simulated` event), and shows it. False if none waits. On the
    /// thread of the shell.
    pub fn adoptSimulation(app: *App) bool {
        if (!app.sim_ready.load(.acquire)) return false;
        app.sim_ready.store(false, .release);
        if (app.sim) |*s| s.deinit(app.gpa);
        app.sim = app.sim_pending;
        app.sim_pending = null;
        app.show_sim = true;
        return true;
    }

    /// Starts a simulation of the last slice that runs in pieces
    /// (`advanceSimulation`), for a shell with no threads: it runs it
    /// between its other work. A new slice drops it.
    pub fn beginSimulation(app: *App) !void {
        if (app.getState() != .done) return error.NoResult;
        app.stopWorker();
        app.dropSimulation();
        app.sim_job = try sim_print.Job.createFrom(app.gpa, &app.toolpaths, sim_print.paramsOf(app.slice_settings), app.sim_checkpoints);
    }

    /// Runs a piece of the simulation of `beginSimulation`: up to `count`
    /// paths. True when it is done: then `allToolpaths` gives the plastic
    /// as it set. error.NoResult if no simulation runs.
    pub fn advanceSimulation(app: *App, count: usize) !bool {
        const job = app.sim_job orelse return error.NoResult;
        errdefer app.dropSimulation();
        if (!try job.advance(count)) return false;
        const r = try job.finish();
        app.keepCheckpoints(job);
        job.destroy();
        app.sim_job = null;
        app.sim = r;
        app.show_sim = true;
        return true;
    }

    /// The share of the simulation on the worker that ran (the simulation
    /// after each slice, and `requestSimulation`), 0 to 1, or null if
    /// none runs. For a progress bar of the shell; any thread can call it.
    pub fn simulationWork(app: *const App) ?f64 {
        if (!app.sim_working.load(.acquire)) return null;
        return @as(f64, @floatFromInt(app.sim_permille.load(.acquire))) / 1000;
    }

    /// The share of the simulation of `beginSimulation` that ran, 0 to 1.
    pub fn simulationProgress(app: *const App) f64 {
        const job = app.sim_job orelse return 1;
        return job.progress();
    }

    /// The outcome of each layer in the last simulated print, or null if
    /// there is none.
    pub fn simulatedLayers(app: *const App) ?[]const sim_print.Layer {
        const s = app.sim orelse return null;
        return s.layers;
    }

    /// The plastic that the simulation uses for the filament of the last
    /// slice: its name, and false if the filament type has no data and
    /// the simulation uses the nearest plastic (see print_sim.materialFor).
    pub fn simulatedMaterial(app: *const App) struct { name: []const u8, exact: bool } {
        const m = zs.print_sim.materialFor(app.slice_settings.filament.material);
        return .{ .name = m.material.name, .exact = m.exact };
    }

    /// Keeps the checkpoints of a simulation that ended, for the next
    /// one. With no memory for them, the next simulation runs from the
    /// start.
    fn keepCheckpoints(app: *App, job: *sim_print.Job) void {
        app.sim_first_path = job.firstPath();
        const c = job.takeCheckpoints() catch null;
        app.dropSimCheckpoints();
        app.sim_checkpoints = c;
    }

    /// Drops the checkpoints of the last simulation: the next simulation
    /// runs from the start.
    pub fn dropSimCheckpoints(app: *App) void {
        if (app.sim_checkpoints) |c| c.destroy();
        app.sim_checkpoints = null;
    }

    fn dropSimulation(app: *App) void {
        if (app.sim) |*s| s.deinit(app.gpa);
        app.sim = null;
        app.show_sim = false;
        if (app.sim_job) |j| j.destroy();
        app.sim_job = null;
        // The thread of the slice is not running here: a simulation of it
        // that waits goes too.
        if (app.sim_ready.swap(false, .acq_rel)) {
            if (app.sim_pending) |*p| p.deinit(app.gpa);
        }
        app.sim_pending = null;
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
        error.PartTooThin => 17,
        error.WriteFailed => 9,
        error.Canceled => 10,
        else => 2,
    };
}

const testing = std.testing;

test {
    _ = selection;
    _ = refine;
    _ = inspect_mod;
    _ = toolpaths_mod;
    _ = sim_print;
    _ = @import("app/sim_calib.zig");
    _ = setting_effect;
    _ = setting_info;
    _ = sweep;
    _ = gap_advice;
    _ = checks_mod;
    _ = plate_set;
    _ = speed;
    _ = support_areas;
    _ = filament_slots;
    _ = printer_filaments;
    _ = support_trees;
    _ = clipboard;
    _ = @import("app/feature_settings.zig");
    _ = @import("app/farm.zig");
    _ = @import("app/session.zig");
    _ = @import("app/calibrate.zig");
}

/// The changes of a part with the skin and infill angles turned by `rot`
/// degrees, the turn of the part on the bed (Project.angles_follow_part).
/// The same changes when the setting is off or the part has no turn.
fn angleChanges(a: Allocator, base: Settings, changes: []const zs.settings.Change, rot: f64) Allocator.Error![]const zs.settings.Change {
    if (@abs(@mod(rot, 360)) < 1e-9) return changes;
    var s = base;
    for (changes) |c| s.set(c.name, c.value) catch {};
    if (!s.project.angles_follow_part) return changes;
    const out = try a.alloc(zs.settings.Change, changes.len + 2);
    @memcpy(out[0..changes.len], changes);
    out[changes.len] = .{ .name = "project.skin_angle", .value = try std.fmt.allocPrint(a, "{d}", .{@mod(s.project.skin_angle + rot, 360)}) };
    out[changes.len + 1] = .{ .name = "project.infill_angle", .value = try std.fmt.allocPrint(a, "{d}", .{@mod(s.project.infill_angle + rot, 360)}) };
    return out;
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

test "app: paint goes into the 3MF and comes back with undo, and the slice has two filaments" {
    const gpa = testing.allocator;
    // A base and a letter on it.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 20, 3);
    try zs.mesh.shapes.addBox(&b, 12, 7, 3, 18, 13, 5);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    const nf = mesh.faces.items.len;
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("plaque.stl", bytes.written());
    _ = app.undo.commit(app, 0);
    _ = try filament_slots.add(app);
    // The letter (the last 12 triangles) with filament 2, one of them in
    // pieces.
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (nf - 12..nf - 1) |t| try text.writer.print("{d} 8\n", .{t});
    try text.writer.print("{d} 40843\n", .{nf - 1});
    try app.setPartPaint(0, text.written());
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    try testing.expect(!app.plate.parts.items[0].paint.isEmpty());
    try app.startSlice();
    app.stopWorkerForTest();
    const st = app.result().?;
    try testing.expect(st.slot_g[1] > 0);
    try testing.expect(st.changes >= 1);
    // The view shows the root of the letter (paint_split.zig): lines of
    // filament 2 on the layers under the top of the base (z 3).
    const tp = app.allToolpaths().?;
    var root_layers: usize = 0;
    var first: usize = 0;
    for (tp.layer_ends.items, tp.layer_z.items) |end, z| {
        defer first = end;
        if (z > 3 - 1e-3) continue;
        var white = false;
        for (tp.path_tool.items[first..end]) |t| white = white or t == 1;
        root_layers += @intFromBool(white);
    }
    try testing.expect(root_layers >= 4);

    // The 3MF keeps the paint in the attributes of PrusaSlicer and Bambu
    // Studio, and the filaments.
    const file = try app.write3mfAlloc(gpa);
    defer gpa.free(file);
    const other = try App.create(gpa, null, null);
    defer other.destroy();
    other.keep_places = true;
    try other.loadStl("plate.3mf", file);
    try testing.expectEqual(@as(usize, 2), filament_slots.count(other));
    const p = &other.plate.parts.items[0].paint;
    try testing.expectEqual(@as(u8, 2), p.stateOf(nf - 12));
    try testing.expectEqual(zs.paint.split, p.stateOf(nf - 1));
    try testing.expectEqual(app.plate.parts.items[0].paint.hash(), p.hash());

    // Undo: no paint; redo: the paint again.
    _ = app.undo.undo(app, 2000);
    try testing.expect(app.plate.parts.items[0].paint.isEmpty());
    _ = app.undo.redo(app, 3000);
    try testing.expectEqual(zs.paint.split, app.plate.parts.items[0].paint.stateOf(nf - 1));
}

test "app: the filament of a body of some layers paints the body, a step of kind filament, with undo" {
    const gpa = testing.allocator;
    // A base and a column on it.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 20, 3);
    try zs.mesh.shapes.addBox(&b, 12, 7, 3, 18, 13, 13);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("column.stl", bytes.written());
    _ = try filament_slots.add(app);
    _ = app.undo.commit(app, 0);
    const base_count = app.undo.count();
    // The outer wall of the column on the layers from z 5 to 9 (as the
    // view gives its beads), in the frame of the part on the bed.
    var placed = try app.plate.partMesh(gpa, 0);
    const box = placed.bounds();
    placed.deinit(gpa);
    const x0: f32 = @floatCast(box.min[0] + 12 + 0.2);
    const y0: f32 = @floatCast(box.min[1] + 7 + 0.2);
    const x1: f32 = @floatCast(box.min[0] + 18 - 0.2);
    const y1: f32 = @floatCast(box.min[1] + 13 - 0.2);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    var l: usize = 25;
    while (l <= 45) : (l += 1) {
        const z: f32 = 0.2 * @as(f32, @floatFromInt(l));
        const c = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        for (0..4) |k| try beads.appendSlice(gpa, &.{ 0, @floatFromInt(l), z, 0.2, c[k][0], c[k][1], c[(k + 1) % 4][0], c[(k + 1) % 4][1], 0.4 });
    }
    try testing.expect(try app.paintBody(beads.items, 2) > 0);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    try testing.expectEqual(base_count + 1, app.undo.count());
    const info = try app.undo.step(app, app.undo.count() - 1);
    try testing.expectEqualStrings("filament", info.kind);

    // The slice: filament 2 (tool 1) on the column, near its layers (and its root,
    // 1 mm under it: paint_anchor_depth), and not on the base.
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(app.result().?.slot_g[1] > 0);
    const tp = app.allToolpaths().?;
    var first: usize = 0;
    var two: usize = 0;
    for (tp.layer_ends.items, tp.layer_z.items) |end, z| {
        defer first = end;
        for (tp.path_tool.items[first..end]) |t| if (t == 1) {
            two += 1;
            try testing.expect(z > 3.7 and z < 9.4);
        };
    }
    try testing.expect(two > 0);

    // The filament of the part removes the pick. Undo restores it.
    _ = try app.paintBody(beads.items, 1);
    try testing.expectEqual(@as(usize, 0), app.plate.parts.items[0].volumes.items.len);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 2000);
    _ = app.undo.undo(app, 3000);
    try testing.expectEqual(@as(usize, 1), app.plate.parts.items[0].volumes.items.len);
}

/// The beads of all paths of layer `layer` of the last slice, as the view
/// gives them (see body_region.stride).
fn layerBeads(gpa: Allocator, app: *App, layer: usize, out: *std.ArrayList(f32)) !void {
    const tp = app.allToolpaths().?;
    const first: usize = if (layer == 0) 0 else tp.layer_ends.items[layer - 1];
    const z = tp.layer_z.items[layer];
    const h = tp.layer_height.items[layer];
    for (first..tp.layer_ends.items[layer]) |p| {
        const a: usize = if (p == 0) 0 else tp.path_ends.items[p - 1];
        const e: usize = tp.path_ends.items[p];
        var k = a;
        while (k + 1 < e) : (k += 1) {
            try out.appendSlice(gpa, &.{ 0, @floatFromInt(layer), z, h, tp.points.items[2 * k], tp.points.items[2 * k + 1], tp.points.items[2 * k + 2], tp.points.items[2 * k + 3], 0.4 });
        }
    }
}

/// The beads of one path of the last slice, as the view gives them.
fn oneBeads(gpa: Allocator, app: *App, p: usize, out: *std.ArrayList(f32)) !void {
    const tp = app.allToolpaths().?;
    out.clearRetainingCapacity();
    const layer = tp.layerOfPath(p).?;
    const part: f32 = @floatFromInt(tp.path_part.items[p]);
    const a: usize = if (p == 0) 0 else tp.path_ends.items[p - 1];
    var k = a;
    while (k + 1 < tp.path_ends.items[p]) : (k += 1) {
        try out.appendSlice(gpa, &.{ part, @floatFromInt(layer), tp.layer_z.items[layer], tp.layer_height.items[layer], tp.points.items[2 * k], tp.points.items[2 * k + 1], tp.points.items[2 * k + 2], tp.points.items[2 * k + 3], 0.4 });
    }
    // The view has a bead for the closing segment of a loop.
    const e = tp.path_ends.items[p];
    if (tp.path_closed.items[p] != 0 and e - a > 2) {
        try out.appendSlice(gpa, &.{ part, @floatFromInt(layer), tp.layer_z.items[layer], tp.layer_height.items[layer], tp.points.items[2 * (e - 1)], tp.points.items[2 * (e - 1) + 1], tp.points.items[2 * a], tp.points.items[2 * a + 1], 0.4 });
    }
}

/// A plate with an L-shaped part (no symmetry) and two filaments, sliced.
fn lineTestApp(gpa: Allocator) !*App {
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 10, 4);
    try zs.mesh.shapes.addBox(&b, 0, 10, 0, 10, 25, 4);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    errdefer app.destroy();
    try app.loadStl("ell.stl", bytes.written());
    app.settings.machine.filament_change = .tool;
    _ = try filament_slots.add(app);
    try app.startSlice();
    app.stopWorkerForTest();
    return app;
}

/// The first outer wall of the layer nearest to the middle of the part.
fn midWall(app: *App) struct { path: usize, layer: usize } {
    const tp = app.allToolpaths().?;
    const layer = tp.layer_ends.items.len / 2;
    for (tp.layer_ends.items[layer - 1]..tp.layer_ends.items[layer]) |p| {
        if (tp.path_features.items[p] == @intFromEnum(zs.settings.Feature.outer_wall)) return .{ .path = p, .layer = layer };
    }
    unreachable;
}

/// The plastic (mm³) of the lines of the parts: no skirt and no tower.
fn partPlastic(app: *App) f64 {
    const tp = app.allToolpaths().?;
    var sum: f64 = 0;
    for (0..tp.pathCount()) |p| {
        if (tp.path_part.items[p] == zs.layer.LayerPlan.no_part) continue;
        sum += tp.path_area.items[p] * tp.pathLength(p);
    }
    return sum;
}

/// The paths of filament 2: on `layer`, and on the other layers.
fn toolTwo(app: *App, layer: usize) [2]usize {
    const tp = app.allToolpaths().?;
    var out = [2]usize{ 0, 0 };
    var first: usize = 0;
    for (tp.layer_ends.items, 0..) |end, l| {
        defer first = end;
        for (tp.path_tool.items[first..end]) |t| {
            if (t == 1) out[@intFromBool(l != layer)] += 1;
        }
    }
    return out;
}

test "app: a filament for one line colors that line alone" {
    const gpa = testing.allocator;
    const app = try lineTestApp(gpa);
    defer app.destroy();
    const plain = partPlastic(app);
    const w = midWall(app);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    try oneBeads(gpa, app, w.path, &beads);
    const cost = app.lineFilamentCost(w.path, 2).?;
    try testing.expectEqual(@as(u32, 2), cost.changes);
    _ = try app.lineFilament(beads.items, -1, @intFromEnum(zs.settings.Feature.outer_wall), 2);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(app.edits.list.items[0].applied.load(.acquire));
    try testing.expectEqual([2]usize{ 1, 0 }, toolTwo(app, w.layer));
    // A change to the filament and a change back, with a prime tower up
    // to the layer of the line (PlateJob.markLineEdits).
    try testing.expectEqual(@as(u32, 2), app.stats.changes);
    try testing.expect(app.stats.tower_layers[0] > w.layer);
    // The lines of the part keep their plastic.
    try testing.expectApproxEqRel(plain, partPlastic(app), 1e-4);
    try testing.expect(std.mem.indexOf(u8, app.gcode_bytes, "\nT1") != null);
    try testing.expect(std.mem.indexOf(u8, app.gcode_bytes, "\nT0") != null);
}

test "app: a filament for one segment cuts the line and keeps the plastic" {
    const gpa = testing.allocator;
    const app = try lineTestApp(gpa);
    defer app.destroy();
    const plain = partPlastic(app);
    const w = midWall(app);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    try oneBeads(gpa, app, w.path, &beads);
    const segs = beads.items.len / zs.body_region.stride;
    try testing.expect(segs >= 4);
    // The longest segment of the wall.
    var seg: usize = 0;
    var longest: f32 = 0;
    for (0..segs) |k| {
        const q = beads.items[k * 9 ..][0..9];
        const l = std.math.hypot(q[6] - q[4], q[7] - q[5]);
        if (l > longest) {
            longest = l;
            seg = k;
        }
    }
    _ = try app.lineFilament(beads.items, @intCast(seg), @intFromEnum(zs.settings.Feature.outer_wall), 2);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(app.edits.list.items[0].applied.load(.acquire));
    try testing.expectEqual([2]usize{ 1, 0 }, toolTwo(app, w.layer));
    try testing.expectEqual(@as(u32, 2), app.stats.changes);
    try testing.expectApproxEqRel(plain, partPlastic(app), 1e-4);
    // The path of filament 2 has the length of the segment.
    const tp = app.allToolpaths().?;
    for (tp.path_tool.items, 0..) |t, p| {
        if (t != 1) continue;
        const a: usize = if (p == 0) 0 else tp.path_ends.items[p - 1];
        var len: f32 = 0;
        var k = a;
        while (k + 1 < tp.path_ends.items[p]) : (k += 1) len += std.math.hypot(tp.points.items[2 * k + 2] - tp.points.items[2 * k], tp.points.items[2 * k + 3] - tp.points.items[2 * k + 1]);
        try testing.expectApproxEqAbs(longest, len, 0.01);
    }
}

test "app: a line filament follows a move, a turn, a mirror, undo, and the file" {
    const gpa = testing.allocator;
    const app = try lineTestApp(gpa);
    defer app.destroy();
    _ = app.undo.commit(app, 0);
    const w = midWall(app);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    try oneBeads(gpa, app, w.path, &beads);
    _ = try app.lineFilament(beads.items, 0, @intFromEnum(zs.settings.Feature.outer_wall), 2);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    const check = struct {
        fn f(q: *App, layer: usize) !void {
            try q.startSlice();
            q.stopWorkerForTest();
            try testing.expect(q.edits.list.items[0].applied.load(.acquire));
            try testing.expectEqual([2]usize{ 1, 0 }, toolTwo(q, layer));
        }
    }.f;
    try check(app, w.layer);
    app.plate.parts.items[0].x += 13.37;
    app.plate.parts.items[0].y -= 7.5;
    try app.plateChanged();
    try check(app, w.layer);
    app.plate.parts.items[0].rot = 90;
    try app.plateChanged();
    try check(app, w.layer);
    try app.mirrorPart(0, 0);
    try check(app, w.layer);
    // The lines of the file bring it back.
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try app.writeFileLines(&text.writer);
    app.edits.list.clearRetainingCapacity();
    try app.readFileLines(0, text.written());
    try testing.expectEqual(@as(usize, 1), app.edits.list.items.len);
    try check(app, w.layer);
    // Undo to the state with no edit, and redo.
    _ = app.undo.undo(app, 3000);
    try testing.expectEqual(@as(usize, 0), app.edits.list.items.len);
    _ = app.undo.redo(app, 4000);
    try testing.expectEqual(@as(usize, 1), app.edits.list.items.len);
}

test "app: a line filament whose shape changed waits and colors nothing" {
    const gpa = testing.allocator;
    const app = try lineTestApp(gpa);
    defer app.destroy();
    const w = midWall(app);
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    try oneBeads(gpa, app, w.path, &beads);
    _ = try app.lineFilament(beads.items, -1, @intFromEnum(zs.settings.Feature.outer_wall), 2);
    try app.plate.setScale(gpa, 0, .{ 1.1, 1, 1 });
    try app.plateChanged();
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(!app.edits.list.items[0].applied.load(.acquire));
    try testing.expectEqual([2]usize{ 0, 0 }, toolTwo(app, w.layer));
    try testing.expectEqual(@as(u32, 0), app.stats.changes);
}

test "app: a filament pick of one layer changes all its lines and no other layer" {
    const gpa = testing.allocator;
    // A base and a column on it: the top of the base is a flat face at
    // the top of the picked layer.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 20, 3);
    try zs.mesh.shapes.addBox(&b, 12, 7, 3, 18, 13, 13);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("column.stl", bytes.written());
    _ = try filament_slots.add(app);
    try app.startSlice();
    app.stopWorkerForTest();
    // The last layer of the base.
    const before = app.allToolpaths().?;
    var layer: usize = 0;
    while (before.layer_z.items[layer] < 3 - 1e-3) layer += 1;
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    try layerBeads(gpa, app, layer, &beads);
    const count = before.layer_ends.items[layer] - before.layer_ends.items[layer - 1];
    try testing.expect(try app.paintBody(beads.items, 2) > 0);
    try app.startSlice();
    app.stopWorkerForTest();
    const tp = app.allToolpaths().?;
    var first: usize = 0;
    var on_layer: usize = 0;
    var off_layer: usize = 0;
    for (tp.layer_ends.items, 0..) |end, l| {
        defer first = end;
        for (tp.path_tool.items[first..end]) |t| {
            if (t != 1) continue;
            if (l == layer) on_layer += 1 else off_layer += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), off_layer);
    try testing.expectEqual(count, on_layer);
}

/// The count of the paths of filament 2 on layer `layer`, and on all other
/// layers.
fn pickCounts(app: *App, layer: usize) [2]usize {
    const tp = app.allToolpaths().?;
    var out: [2]usize = .{ 0, 0 };
    var first: usize = 0;
    for (tp.layer_ends.items, 0..) |end, l| {
        defer first = end;
        for (tp.path_tool.items[first..end]) |t| {
            if (t == 1) out[@intFromBool(l != layer)] += 1;
        }
    }
    return out;
}

test "app: a filament pick keeps to its body and follows the part" {
    const gpa = testing.allocator;
    // A plate with a ring, a post inside the ring, and a column.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 50, 20, 2);
    try zs.mesh.shapes.addBox(&b, 4, 2, 2, 24, 5, 10);
    try zs.mesh.shapes.addBox(&b, 4, 15, 2, 24, 18, 10);
    try zs.mesh.shapes.addBox(&b, 4, 5, 2, 7, 15, 10);
    try zs.mesh.shapes.addBox(&b, 21, 5, 2, 24, 15, 10);
    try zs.mesh.shapes.addBox(&b, 12, 8, 2, 16, 12, 10);
    try zs.mesh.shapes.addBox(&b, 30, 5, 2, 40, 15, 10);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("ring.stl", bytes.written());
    _ = try filament_slots.add(app);
    try app.startSlice();
    app.stopWorkerForTest();
    var placed = try app.plate.partMesh(gpa, 0);
    const box = placed.bounds();
    placed.deinit(gpa);
    const ox: f32 = @floatCast(box.min[0]);
    const oy: f32 = @floatCast(box.min[1]);
    const tp = app.allToolpaths().?;
    var layer: usize = 0;
    while (tp.layer_z.items[layer] < 6 - 1e-3) layer += 1;
    // The beads of the ring alone: no line of the post or the column.
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    var ring: usize = 0;
    for (tp.layer_ends.items[layer - 1]..tp.layer_ends.items[layer]) |p| {
        const a: usize = if (p == 0) 0 else tp.path_ends.items[p - 1];
        const e: usize = tp.path_ends.items[p];
        const x = tp.points.items[2 * a] - ox;
        const y = tp.points.items[2 * a + 1] - oy;
        if (x > 26 or (x > 10 and x < 18 and y > 6 and y < 14)) continue;
        ring += 1;
        var k = a;
        while (k + 1 < e) : (k += 1) {
            try beads.appendSlice(gpa, &.{ 0, @floatFromInt(layer), tp.layer_z.items[layer], tp.layer_height.items[layer], tp.points.items[2 * k], tp.points.items[2 * k + 1], tp.points.items[2 * k + 2], tp.points.items[2 * k + 3], 0.4 });
        }
    }
    try testing.expect(ring > 0);
    try testing.expect(try app.paintBody(beads.items, 2) > 0);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual([2]usize{ ring, 0 }, pickCounts(app, layer));
    // The pick moves and turns with the part.
    try app.movePart(0, app.plate.parts.items[0].x + 5, app.plate.parts.items[0].y + 3);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual([2]usize{ ring, 0 }, pickCounts(app, layer));
    try app.rotatePart(0, 90);
    try app.startSlice();
    app.stopWorkerForTest();
    const turned = pickCounts(app, layer);
    try testing.expect(turned[0] > 0);
    try testing.expectEqual(@as(usize, 0), turned[1]);
    // The pick goes in a 3MF file and comes back.
    const saved = try gpa.dupe(u8, try app.write3mf());
    defer gpa.free(saved);
    const back = try App.create(gpa, null, null);
    defer back.destroy();
    try back.loadStl("ring.3mf", saved);
    try testing.expectEqual(@as(usize, 1), back.plate.parts.items[0].volumes.items.len);
    try back.startSlice();
    back.stopWorkerForTest();
    try testing.expectEqual(turned, pickCounts(back, layer));
    // The pick goes with its filament.
    try filament_slots.remove(app, 1);
    try testing.expectEqual(@as(usize, 0), app.plate.parts.items[0].volumes.items.len);
}

/// The infill length (mm) of the paths of `tp` with x in [x0, x1], on the
/// layers with z in (z0, z1): one sum for each such layer, in `out`.
fn infillLengths(gpa: Allocator, tp: *const toolpaths_mod.Toolpaths, x0: f32, x1: f32, z0: f32, z1: f32, out: *std.ArrayList(f32)) !void {
    out.clearRetainingCapacity();
    var first: usize = 0;
    for (tp.layer_ends.items, tp.layer_z.items) |end, z| {
        defer first = end;
        if (!(z > z0 and z < z1)) continue;
        var sum: f32 = 0;
        for (first..end) |p| {
            if (tp.path_features.items[p] != 3) continue;
            const a = if (p == 0) 0 else tp.path_ends.items[p - 1];
            const b = tp.path_ends.items[p];
            const px = tp.points.items[2 * a];
            if (px < x0 or px > x1) continue;
            for (a + 1..b) |k| {
                const dx = tp.points.items[2 * k] - tp.points.items[2 * k - 2];
                const dy = tp.points.items[2 * k + 1] - tp.points.items[2 * k - 1];
                sum += @sqrt(dx * dx + dy * dy);
            }
        }
        try out.append(gpa, sum);
    }
}

test "app: a setting of a body of some layers changes only its lines there, with undo" {
    const gpa = testing.allocator;
    // A base and two columns on it: A on the left, B on the right.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 34, 14, 3);
    try zs.mesh.shapes.addBox(&b, 2, 2, 3, 14, 12, 13);
    try zs.mesh.shapes.addBox(&b, 20, 2, 3, 32, 12, 13);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("columns.stl", bytes.written());
    try app.startSlice();
    app.stopWorkerForTest();
    var placed = try app.plate.partMesh(gpa, 0);
    const box = placed.bounds();
    placed.deinit(gpa);
    const ox: f32 = @floatCast(box.min[0]);
    const oy: f32 = @floatCast(box.min[1]);
    var before_a: std.ArrayList(f32) = .empty;
    defer before_a.deinit(gpa);
    var before_b: std.ArrayList(f32) = .empty;
    defer before_b.deinit(gpa);
    var before_base: std.ArrayList(f32) = .empty;
    defer before_base.deinit(gpa);
    try infillLengths(gpa, app.allToolpaths().?, ox + 2, ox + 14, 5.3, 8.7, &before_a);
    try infillLengths(gpa, app.allToolpaths().?, ox + 20, ox + 32, 5.3, 8.7, &before_b);
    try infillLengths(gpa, app.allToolpaths().?, ox, ox + 34, 0.5, 2.5, &before_base);
    _ = app.undo.commit(app, 0);
    const base_count = app.undo.count();

    // The outer wall of column A on the layers from z 5 to 9 (as the view
    // gives its beads).
    var beads: std.ArrayList(f32) = .empty;
    defer beads.deinit(gpa);
    var l: usize = 25;
    while (l <= 45) : (l += 1) {
        const z: f32 = 0.2 * @as(f32, @floatFromInt(l));
        const c = [_][2]f32{ .{ ox + 2.2, oy + 2.2 }, .{ ox + 13.8, oy + 2.2 }, .{ ox + 13.8, oy + 11.8 }, .{ ox + 2.2, oy + 11.8 } };
        for (0..4) |k| try beads.appendSlice(gpa, &.{ 0, @floatFromInt(l), z, 0.2, c[k][0], c[k][1], c[(k + 1) % 4][0], c[(k + 1) % 4][1], 0.4 });
    }
    // Not a setting of a region: the walls, the filament (paint).
    try testing.expectError(error.NotRegional, app.regionSet(beads.items, 0, "project.wall_count", "4"));
    try testing.expectError(error.NotRegional, app.regionSet(beads.items, 0, "project.filament", "2"));
    const id = try app.regionSet(beads.items, 0, "project.infill_density", "0.6");
    try testing.expect(id > 0);
    try testing.expectEqual(id, try app.regionFind(beads.items));
    try testing.expectEqual(@as(usize, 1), app.plate.parts.items[0].volumes.items.len);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    try testing.expectEqual(base_count + 1, app.undo.count());
    const info = try app.undo.step(app, app.undo.count() - 1);
    try testing.expectEqualStrings("infill", info.kind);

    try app.startSlice();
    app.stopWorkerForTest();
    const tp = app.allToolpaths().?;
    var after: std.ArrayList(f32) = .empty;
    defer after.deinit(gpa);
    // Column B and the base: the same lines.
    try infillLengths(gpa, tp, ox + 20, ox + 32, 5.3, 8.7, &after);
    try testing.expectEqualSlices(f32, before_b.items, after.items);
    try infillLengths(gpa, tp, ox, ox + 34, 0.5, 2.5, &after);
    try testing.expectEqualSlices(f32, before_base.items, after.items);
    // Column A: more infill on these layers.
    try infillLengths(gpa, tp, ox + 2, ox + 14, 5.3, 8.7, &after);
    try testing.expectEqual(before_a.items.len, after.items.len);
    for (before_a.items, after.items) |x, y| try testing.expect(y > 1.5 * x);
    // Each path of the region is in column A, on its layers.
    var first: usize = 0;
    var any = false;
    for (tp.layer_ends.items, tp.layer_z.items) |end, z| {
        defer first = end;
        for (first..end) |p| if (tp.path_modifier.items[p] != 0) {
            any = true;
            try testing.expect(z > 4.7 and z < 9.3);
            const a = if (p == 0) 0 else tp.path_ends.items[p - 1];
            try testing.expect(tp.points.items[2 * a] > ox + 1.5 and tp.points.items[2 * a] < ox + 14.5);
        };
    }
    try testing.expect(any);

    // The region goes with its last setting; undo brings it back.
    try testing.expectEqual(@as(u32, 0), try app.regionSet(beads.items, 0, "project.infill_density", null));
    try testing.expectEqual(@as(usize, 0), app.plate.parts.items[0].volumes.items.len);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 2000);
    _ = app.undo.undo(app, 3000);
    try testing.expectEqual(@as(usize, 1), app.plate.parts.items[0].volumes.items.len);
    try testing.expectEqual(id, App.regionId(app.plate.parts.items[0].volumes.items[0].meta));
}

/// The JSON of a label "VOLUME" 5 mm tall in filament 2 on the +x side of
/// part 0 (on the bed), at height z.
fn volumeLabel(app: *App, gpa: Allocator, z: f64) ![]u8 {
    var m = try app.plate.partMesh(gpa, 0);
    defer m.deinit(gpa);
    const b = m.bounds();
    return std.fmt.allocPrint(gpa, "{{\"origin\":[{d},{d},{d}],\"normal\":[1,0,0],\"right\":[0,1,0],\"filament\":2,\"items\":[{{\"kind\":\"text\",\"text\":\"VOLUME\",\"size\":5}}]}}", .{ b.max[0], (b.min[1] + b.max[1]) / 2, z });
}

test "app: a label goes into the history, the 3MF, and the slice" {
    const gpa = testing.allocator;
    // A box with a +x side 40 mm wide.
    var mesh = try zs.mesh.shapes.box(gpa, 20, 40, 10);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    app.settings.machine.filament_change = .tool;
    try app.loadStl("box.stl", bytes.written());
    _ = try filament_slots.add(app);
    _ = app.undo.commit(app, 0);
    // Add.
    const json = try volumeLabel(app, gpa, 5);
    defer gpa.free(json);
    const id = try labels.add(app, 0, json);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    try testing.expectEqual(@as(usize, 1), app.plate.parts.items[0].labels.items.len);
    // Move up 1 mm.
    const moved = try volumeLabel(app, gpa, 6);
    defer gpa.free(moved);
    try labels.update(app, 0, id, moved);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 2000);
    const placed = struct {
        fn z(ap: *App) f64 {
            const p = &ap.plate.parts.items[0];
            return p.placeLabel(p.labels.items[0]).origin[2];
        }
    };
    try testing.expectApproxEqAbs(@as(f64, 6), placed.z(app), 1e-6);
    // The facts of the step say so.
    var facts: std.Io.Writer.Allocating = .init(gpa);
    defer facts.deinit();
    try app.writeFacts(&facts.writer);
    try testing.expect(std.mem.indexOf(u8, facts.written(), "part:box.stl\tlabel 1\ttext \"VOLUME\", filament 2") != null);
    // Undo the move, and redo it.
    _ = app.undo.undo(app, 3000);
    try testing.expectApproxEqAbs(@as(f64, 5), placed.z(app), 1e-4);
    _ = app.undo.redo(app, 4000);
    try testing.expectApproxEqAbs(@as(f64, 6), placed.z(app), 1e-4);
    // Remove, and undo the removal.
    try labels.remove(app, 0, id);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 5000);
    try testing.expectEqual(@as(usize, 0), app.plate.parts.items[0].labels.items.len);
    _ = app.undo.undo(app, 6000);
    try testing.expectEqual(@as(usize, 1), app.plate.parts.items[0].labels.items.len);
    try testing.expectEqual(id, app.plate.parts.items[0].labels.items[0].id);

    // The 3MF keeps the label at its place.
    const file = try app.write3mfAlloc(gpa);
    defer gpa.free(file);
    const other = try App.create(gpa, null, null);
    defer other.destroy();
    other.keep_places = true;
    try other.loadStl("plate.3mf", file);
    const op = &other.plate.parts.items[0];
    try testing.expectEqual(@as(usize, 1), op.labels.items.len);
    const a0 = app.plate.parts.items[0].placeLabel(app.plate.parts.items[0].labels.items[0]);
    const b0 = op.placeLabel(op.labels.items[0]);
    for (0..3) |k| {
        try testing.expectApproxEqAbs(a0.origin[k], b0.origin[k], 1e-4);
        try testing.expectApproxEqAbs(a0.normal[k], b0.normal[k], 1e-9);
        try testing.expectApproxEqAbs(a0.right[k], b0.right[k], 1e-9);
    }
    try testing.expectEqualStrings("VOLUME", op.labels.items[0].firstText());

    // The slice: the label prints in filament 2, with changes on its
    // layers only, and the card gets them.
    try app.startSlice();
    app.stopWorkerForTest();
    const st = app.result().?;
    try testing.expect(st.slot_g[1] > 0);
    const in = try labels.info(app, 0, id);
    try testing.expect(in.sliced);
    try testing.expectEqual(st.changes, in.changes);
    try testing.expect(in.changes >= in.layers);
    try testing.expect(in.minutes > 0);
    // The check: text 5 mm tall prints clean, so no label issue.
    const r = try app.checks();
    for (r.issues) |is| try testing.expect(is.kind != .label);
}

test "app: a pick of the overhang under a point, as an area, gives support" {
    const gpa = testing.allocator;
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
    const p = &app.plate.parts.items[0];
    // A point on the top of the cap, near its edge.
    var pr = try zs.support_pick.Prep.init(gpa, &p.mesh);
    defer pr.deinit(gpa);
    var r = (try zs.support_pick.pick(gpa, &p.mesh, &pr, p.transform(), .{ p.x + 9, p.y + 9, 7 }, 4, zs.support_pick.downFor(50))).?;
    defer r.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 5), r.z_lo, 1e-3);
    _ = try app.areas.add(gpa, .grid, r.points, r.z_lo, r.z_hi);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(std.mem.indexOf(u8, app.gcode().?, ";TYPE:SUPPORT") != null);
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
        // A zigzag of skin lines has a width for each point too: its
        // links have half the plastic of a line (see layer.thinLinks).
        const skin = f == @intFromEnum(zs.settings.Feature.skin);
        if (!skin) try testing.expectEqual(wall, tp.path_z_start.items[pi] != Toolpaths.no_z);
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
        // A zigzag of skin lines has a width for each point too (see
        // layer.thinLinks).
        const skin = f == @intFromEnum(zs.settings.Feature.skin);
        if (!skin) try testing.expectEqual(smooth or ironing, tp.path_z_start.items[pi] != Toolpaths.no_z);
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

test "app: a draft slice has no gap fill and no G-code for a printer, and the exact slice comes back" {
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
    const layers = app.layerCount();
    const gcode = try gpa.dupe(u8, app.exactGcode().?);
    defer gpa.free(gcode);
    app.setDraft(true);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expect(app.isDraft());
    // The view has the paths of the draft. A file and a printer get no
    // G-code.
    try testing.expectEqual(layers, app.layerCount());
    try testing.expect(app.gcode() != null);
    try testing.expect(app.exactGcode() == null);
    try testing.expectEqual(@as(f64, 0.005), app.settings.project.resolution);
    try testing.expectEqual(@as(f64, 0.05), app.slice_settings.project.resolution);
    try testing.expect(!app.slice_settings.project.gap_fill);
    app.setDraft(false);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(!app.isDraft());
    try testing.expectEqualStrings(gcode, app.exactGcode().?);
}

test "app: Faster slicing on and back off gives the exact G-code; no draft with draft slices off" {
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
    const exact = try gpa.dupe(u8, app.exactGcode().?);
    defer gpa.free(exact);
    try testing.expectEqual(speed.State.off, app.speedState());
    try app.setFasterSlicing(true);
    try testing.expectEqual(speed.State.on, app.speedState());
    try testing.expect(app.settings.project.fast_offsets);
    try testing.expectEqual(@as(f64, 0.01), app.settings.project.resolution);
    try app.startSlice();
    app.stopWorkerForTest();
    try app.setSetting("project.fast_offsets", "false");
    try testing.expectEqual(speed.State.custom, app.speedState());
    try app.setFasterSlicing(false);
    try testing.expectEqual(speed.State.off, app.speedState());
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqualStrings(exact, app.exactGcode().?);
    // Draft slices off: a draft request gives the exact slice.
    try app.setSetting("engine.draft_slices", "false");
    app.setDraft(true);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(!app.isDraft());
    try testing.expectEqualStrings(exact, app.exactGcode().?);
}

test "app: a simulation on the worker gives the result of a simulation on the calling thread" {
    if (comptime !has_threads) return error.SkipZigTest;
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try testing.expectError(error.NoResult, app.requestSimulation());
    try app.loadStl("demo.stl", stl.written());
    try app.startSlice();
    app.stopWorkerForTest();
    try app.requestSimulation();
    // A second request while the first runs or waits starts no run.
    try app.requestSimulation();
    app.stopWorkerForTest();
    try testing.expect(app.adoptSimulation());
    const got = app.sim.?.stats;
    app.dropSimulation();
    const want = try app.simulatePrint();
    try testing.expectEqual(want.masses, got.masses);
    try testing.expectEqual(want.moved, got.moved);
    try testing.expectEqual(want.steps, got.steps);
    // A simulation shows: no new run.
    try app.requestSimulation();
    try testing.expect(app.worker == null);
}

test "app: the check on the worker gives the check on the calling thread" {
    if (comptime !has_threads) return error.SkipZigTest;
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("demo.stl", stl.written());
    app.auto_checks = true;
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(app.checksReady());
    const got = try app.checks();
    const issues = try gpa.dupe(checks_mod.Issue, got.issues);
    defer gpa.free(issues);
    const text = try gpa.dupe(u8, got.text);
    defer gpa.free(text);
    app.clearGaps();
    try testing.expect(!app.checksReady());
    const want = try app.checks();
    try testing.expectEqualSlices(checks_mod.Issue, want.issues, issues);
    try testing.expectEqualStrings(want.text, text);
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

/// The edits of `checkEdits`, in order. A setting changes, then goes back
/// to a value of before, so a slice can use the results of the slices
/// before it (see layer.Memo).
const edit_steps = [_][2][]const u8{
    .{ "project.infill_density", "0.3" },
    .{ "project.wall_count", "3" },
    .{ "project.top_thickness", "1.2" },
    .{ "project.bottom_thickness", "1.0" },
    .{ "project.top_thickness", "0.8" },
    .{ "project.bottom_thickness", "0.6" },
    .{ "project.wall_count", "2" },
    .{ "project.infill_density", "0.2" },
    .{ "project.skin_angle", "30" },
    .{ "project.line_width", "0.45" },
    .{ "project.layer_height", "0.25" },
    .{ "filament.xy_offset", "0.02" },
    .{ "project.support", "everywhere" },
    .{ "project.support_tree_angle", "44" },
    .{ "project.outer_wall_speed", "0.42" },
    .{ "filament.nozzle_temp", "212" },
    .{ "project.line_width", "0" },
    .{ "project.layer_height", "0.2" },
};

/// Slices a plate with one part for each file of `stls`, then makes each
/// edit of `edit_steps` and slices again. After each edit, the G-code is
/// the G-code of a new app with the same settings.
fn checkEdits(gpa: Allocator, stls: []const []const u8) !void {
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try loadParts(app, stls);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    for (edit_steps, 0..) |e, k| {
        try app.setSetting(e[0], e[1]);
        try app.requestSlice();
        app.stopWorkerForTest();
        try testing.expectEqual(State.done, app.getState());
        const fresh = try App.create(gpa, null, null);
        defer fresh.destroy();
        try loadParts(fresh, stls);
        for (edit_steps[0 .. k + 1]) |v| try fresh.setSetting(v[0], v[1]);
        try fresh.startSlice();
        fresh.stopWorkerForTest();
        if (!std.mem.eql(u8, fresh.gcode().?, app.gcode().?)) {
            std.debug.print("the G-code differs after {s} = {s} ({d} parts)\n", .{ e[0], e[1], stls.len });
            return error.TestExpectedEqual;
        }
    }
}

fn loadParts(app: *App, stls: []const []const u8) !void {
    try app.loadStl("part.stl", stls[0]);
    for (stls[1..]) |stl| _ = try app.addStl("part.stl", stl);
    if (stls.len > 1) _ = try app.arrangePlate();
}

fn stlOf(gpa: Allocator, mesh: *zs.mesh.Mesh) ![]u8 {
    defer mesh.deinit(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    errdefer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    return bytes.toOwnedSlice();
}

test "app: each kind of edit gives the G-code of a new slice" {
    const gpa = testing.allocator;
    const shapes = zs.mesh.shapes;
    var demo = try shapes.demo(gpa);
    const a = try stlOf(gpa, &demo);
    defer gpa.free(a);
    // Two cones: one gets smaller to the top (a top surface on each
    // layer), one gets larger (a bottom surface on each layer).
    var up = try shapes.frustum(gpa, 0, 0, 9, 3, 8, 40);
    const b = try stlOf(gpa, &up);
    defer gpa.free(b);
    var down = try shapes.frustum(gpa, 0, 0, 4, 9, 8, 40);
    const c = try stlOf(gpa, &down);
    defer gpa.free(c);
    try checkEdits(gpa, &.{a});
    // Copies of one part, and parts of their own.
    try checkEdits(gpa, &.{ a, a });
    try checkEdits(gpa, &.{ b, c });
}

/// A new value for each patch setting (see settings.patch_settings), for
/// the tests and the bench.
pub const patch_values = [_][2][]const u8{
    .{ "filament.nozzle_temp", "215" },       .{ "filament.first_layer_nozzle_temp", "222" },
    .{ "filament.bed_temp", "63" },           .{ "filament.fan_speed", "0.7" },
    .{ "filament.fan_off_layers", "3" },      .{ "filament.fan_max_speed", "0.9" },
    .{ "filament.fan_ramp_layers", "2" },     .{ "machine.chamber_temp", "40" },
    .{ "machine.part_fan_air", "8" },         .{ "filament.fan_boost_time", "12" },
    .{ "filament.min_layer_time", "9" },      .{ "filament.min_speed", "12" },
    .{ "filament.flow_ratio", "0.97" },       .{ "filament.max_flow", "9" },
    .{ "filament.density", "1.3" },           .{ "filament.price_per_kg", "31" },
    .{ "project.bridge_speed", "0.3" },       .{ "project.bridge_flow", "0.9" },
    .{ "project.bridge_fan", "0.8" },         .{ "project.infill_flow", "1.05" },
    .{ "project.ironing_flow", "0.2" },       .{ "project.ironing_speed", "0.2" },
    .{ "project.outer_wall_speed", "0.4" },   .{ "project.inner_wall_speed", "0.6" },
    .{ "project.skin_speed", "0.45" },        .{ "project.infill_speed", "0.8" },
    .{ "project.first_layer_speed", "0.25" }, .{ "project.slow_layers", "3" },
    .{ "machine.outer_wall_accel", "700" },   .{ "machine.inner_wall_accel", "900" },
    .{ "machine.skin_accel", "800" },         .{ "machine.infill_accel", "1100" },
    .{ "machine.first_layer_accel", "400" },  .{ "project.path_rules", "speed = {speed} * 0.9" },
    .{ "filament.first_layer_bed_temp", "68" },
    .{ "project.support_speed", "0.5" },      .{ "project.support_interface_speed", "0.35" },
};

/// Slices `stl` with `base`, then changes the patch settings in groups of
/// `step`. After each group: the slice makes no plan, and its G-code is
/// the G-code of a new app with the same settings.
fn checkPatches(gpa: Allocator, stl: []const u8, base: []const [2][]const u8, step: usize) !void {
    try testing.expectEqual(zs.settings.patch_settings.len, patch_values.len);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("part.stl", stl);
    for (base) |b| try app.setSetting(b[0], b[1]);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    var done: usize = 0;
    while (done < patch_values.len) {
        const end = @min(done + step, patch_values.len);
        for (patch_values[done..end]) |v| {
            try testing.expect(zs.settings.isPatchSetting(v[0]));
            try app.setSetting(v[0], v[1]);
        }
        done = end;
        const plans = zs.plate_job.plans_made.load(.monotonic);
        try app.requestSlice();
        app.stopWorkerForTest();
        try testing.expectEqual(State.done, app.getState());
        try testing.expectEqual(plans, zs.plate_job.plans_made.load(.monotonic));
        const fresh = try App.create(gpa, null, null);
        defer fresh.destroy();
        try fresh.loadStl("part.stl", stl);
        for (base) |b| try fresh.setSetting(b[0], b[1]);
        for (patch_values[0..done]) |v| try fresh.setSetting(v[0], v[1]);
        try fresh.startSlice();
        fresh.stopWorkerForTest();
        if (!std.mem.eql(u8, fresh.gcode().?, app.gcode().?)) {
            std.debug.print("the G-code differs after {s}\n", .{patch_values[done - 1][0]});
            return error.TestExpectedEqual;
        }
        // The view gets the same paths with the same times.
        const a = app.allToolpaths().?;
        const b = fresh.allToolpaths().?;
        try testing.expectEqualSlices(f32, b.path_end_time.items, a.path_end_time.items);
        try testing.expectEqualSlices(f32, b.points.items, a.points.items);
        try testing.expectEqualSlices(u8, b.path_fan.items, a.path_fan.items);
    }
}

const patch_bases = [_][]const [2][]const u8{
    &.{},
    &.{
        .{ "project.support", "everywhere" },       .{ "project.support_style", "tree" },
        .{ "machine.retract_wipe", "true" },        .{ "machine.z_hop", "0.4" },
        .{ "machine.z_hop_only_crossing", "true" },
    },
};

test "app: a change of a patch setting makes no plan, and gives the G-code of a new slice" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    for (patch_bases) |base| try checkPatches(gpa, bytes.written(), base, 11);
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

test "app: the inspector gives the fan, the layer time, and what support holds up" {
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
    try app.settings.set("project.support", "everywhere");
    try app.loadStl("mushroom.stl", bytes.written());
    try app.startSlice();
    app.stopWorkerForTest();
    const t = app.allToolpaths().?;
    var support: ?usize = null;
    var wall: ?usize = null;
    for (t.path_features.items, 0..) |f, i| {
        const feature: zs.settings.Feature = @enumFromInt(f);
        if (support == null and feature == .support) support = i;
        if (wall == null and feature == .outer_wall and t.layerOfPath(i).? > 3) wall = i;
    }
    // A wall: the fan is on above the first layers, and the layer takes
    // some time.
    const w = try app.inspect(wall.?);
    try testing.expect(w.fan > 0 and w.fan <= 1);
    try testing.expect(w.layer_time > 0);
    try testing.expect(w.max_flow > 0);
    try testing.expect(w.holds == null);
    // A support line under the cap holds up a line of the cap, above z 5.
    const s = try app.inspect(support.?);
    const held = s.holds.?;
    try testing.expect(held.layer > s.layer);
    try testing.expect(t.layer_z.items[held.layer] > 5);
    try testing.expect(held.feature != .support and held.feature != .support_interface);
    // The check runs only on demand, and then it is ready.
    try testing.expect(!app.checksReady());
    _ = try app.checks();
    try testing.expect(app.checksReady());
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

test "an added model gets a smart place; the parts on the plate stay" {
    const gpa = testing.allocator;
    var mesh = try zs.mesh.shapes.demo(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("a.stl", bytes.written());
    // The user moved the first part off the middle.
    app.plate.parts.items[0].x = 60;
    app.plate.parts.items[0].y = 70;
    const before = app.plate.parts.items[0];
    _ = try app.addStl("b.stl", bytes.written());
    _ = try app.addStl("c.stl", bytes.written());
    const a0 = app.plate.parts.items[0];
    try testing.expectEqual(before.x, a0.x);
    try testing.expectEqual(before.y, a0.y);
    try testing.expectEqual(before.pose, a0.pose);
    // No two parts touch, and each is on the bed.
    const bed = app.bedSize();
    for (0..3) |i| {
        const f = app.plate.parts.items[i].footprint();
        try testing.expect(f[0] >= 0 and f[1] >= 0 and f[2] <= bed[0] and f[3] <= bed[1]);
        for (i + 1..3) |j| {
            const g = app.plate.parts.items[j].footprint();
            try testing.expect(f[2] <= g[0] or g[2] <= f[0] or f[3] <= g[1] or g[3] <= f[1]);
        }
    }
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

test "app: the parts of a Bambu Studio project keep their filaments, and the slice has two" {
    const gpa = testing.allocator;
    // Two cubes of 10 mm side by side: object 2 has filament 2 in
    // Metadata/model_settings.config.
    var model: std.Io.Writer.Allocating = .init(gpa);
    defer model.deinit();
    const w = &model.writer;
    try w.writeAll("<?xml version=\"1.0\"?><model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources>");
    for (1..3) |id| {
        try w.print("<object id=\"{d}\" type=\"model\"><mesh><vertices>", .{id});
        for ([_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 0, 0, 10 }, .{ 10, 0, 10 }, .{ 10, 10, 10 }, .{ 0, 10, 10 } }) |v| try w.print("<vertex x=\"{d}\" y=\"{d}\" z=\"{d}\"/>", .{ v[0], v[1], v[2] });
        try w.writeAll("</vertices><triangles>");
        for ([_][3]u32{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 3, 0, 4 }, .{ 3, 4, 7 } }) |f| try w.print("<triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\"/>", .{ f[0], f[1], f[2] });
        try w.writeAll("</triangles></mesh></object>");
    }
    try w.writeAll("</resources><build><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 80 100 0\"/><item objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 110 100 0\"/></build></model>");
    const settings =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<config>
        \\  <object id="1"><metadata key="extruder" value="1"/></object>
        \\  <object id="2"><metadata key="extruder" value="2"/></object>
        \\</config>
    ;
    const project =
        \\{ "filament_colour": ["#FFFFFF", "#D93A3A"], "filament_type": ["PLA", "PLA"] }
    ;
    const entries = [_]zs.zipfile.Entry{
        .{ .name = "3D/3dmodel.model", .data = model.written() },
        .{ .name = "Metadata/model_settings.config", .data = @constCast(settings) },
        .{ .name = "Metadata/project_settings.config", .data = @constCast(project) },
    };
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    try zs.zipfile.write(gpa, &file.writer, &entries);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    app.keep_places = true;
    try app.loadStl("two.3mf", file.written());
    try testing.expectEqual(@as(usize, 2), app.plate.count());
    try testing.expectEqual(@as(usize, 2), filament_slots.count(app));
    try testing.expect(app.partSetting(0, "project.filament") == null);
    try testing.expectEqualStrings("2", app.partSetting(1, "project.filament").?);
    try app.startSlice();
    app.stopWorkerForTest();
    const st = app.result().?;
    try testing.expect(st.slot_g[0] > 0);
    try testing.expect(st.slot_g[1] > 0);
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

/// An app with support off, a brim of `brim` mm, and the boxes as one
/// part, loaded from an STL.
fn appWithBoxes(gpa: Allocator, brim: []const u8, boxes: []const [6]f64) !*App {
    var b: zs.mesh.Builder = .init(gpa);
    for (boxes) |x| try zs.mesh.shapes.addBox(&b, x[0], x[1], x[2], x[3], x[4], x[5]);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    const app = try App.create(gpa, null, null);
    errdefer app.destroy();
    try app.setSetting("project.brim_width", brim);
    try app.loadStl("part.stl", bytes.written());
    return app;
}

fn partHeight(app: *App) f64 {
    const bb = app.plate.parts.items[0].mesh.bounds();
    return bb.max[2] - bb.min[2];
}

test "app: a thin pin falls over on the load with no brim, and stands with a brim" {
    const gpa = testing.allocator;
    // A pin of 4 x 4 x 40 mm: the push of the nozzle at its top is more
    // than its bare foot holds, and less than an 8 mm brim holds.
    const pin = [_][6]f64{.{ 0, 0, 0, 4, 4, 40 }};
    {
        const app = try appWithBoxes(gpa, "0", &pin);
        defer app.destroy();
        try testing.expectApproxEqAbs(@as(f64, 4), partHeight(app), 0.01);
    }
    const app = try appWithBoxes(gpa, "8", &pin);
    defer app.destroy();
    try testing.expectApproxEqAbs(@as(f64, 40), partHeight(app), 0.01);
    try testing.expect(try app.unstablePart() == null);
    try testing.expect(!try app.fallStart(0));
    // The brim goes: the pin falls over, step by step, onto its side.
    try app.setSetting("project.brim_width", "0");
    try testing.expectEqual(@as(?usize, 0), try app.unstablePart());
    try testing.expect(try app.fallStart(0));
    var frames: usize = 0;
    while (try app.fallStep(1.0 / 60.0)) |fr| {
        frames += 1;
        if (fr.done) break;
        try testing.expect(frames < 60 * 9);
    }
    try testing.expectApproxEqAbs(@as(f64, 4), partHeight(app), 0.01);
    try testing.expect(try app.unstablePart() == null);
}

test "app: a tall thin pin falls over even with a brim" {
    const gpa = testing.allocator;
    // A pin of 2 x 2 x 120 mm: the push makes 36 N mm, and a 2 mm brim
    // holds about 7 N mm.
    const app = try appWithBoxes(gpa, "2", &.{.{ 0, 0, 0, 2, 2, 120 }});
    defer app.destroy();
    try testing.expectApproxEqAbs(@as(f64, 2), partHeight(app), 0.01);
}

test "app: a box stands with and without a brim" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "0", "8" }) |brim| {
        const app = try appWithBoxes(gpa, brim, &.{.{ 0, 0, 0, 20, 20, 20 }});
        defer app.destroy();
        try testing.expectApproxEqAbs(@as(f64, 20), partHeight(app), 0.01);
        try testing.expect(try app.unstablePart() == null);
        try testing.expect(!try app.fallStart(0));
    }
}

test "app: the bond of the first layer holds the cantilever up with no brim" {
    const gpa = testing.allocator;
    // The cantilever of tools/stress/gen.py: its center of mass is 3.6 mm
    // past the post, but the post holds 14 times the load.
    const app = try appWithBoxes(gpa, "0", &.{ .{ 0, 0, 0, 10, 10, 20 }, .{ 0, 0, 20, 50, 10, 23 } });
    defer app.destroy();
    try testing.expectApproxEqAbs(@as(f64, 23), partHeight(app), 0.01);
    // It is as in the file: the post on the bed, so its weight alone
    // tips it (upside down, the slab holds it).
    try testing.expect((try zs.physics.settle(gpa, &app.plate.parts.items[0].mesh)).rolls > 0);
    try testing.expect(try app.unstablePart() == null);
}

test "app: a part that loads on an edge falls over and rests" {
    const gpa = testing.allocator;
    // A board 40 x 10 x 4 mm, turned 45 degrees about X: it stands on an
    // edge.
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 40, 10, 4);
    var mesh = try b.finish();
    const c = @cos(std.math.pi / 4.0);
    const sn = @sin(std.math.pi / 4.0);
    for (mesh.vertices.items) |*v| {
        const y = v.y;
        const z = v.z;
        v.y = @floatCast(c * y - sn * z);
        v.z = @floatCast(sn * y + c * z);
    }
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("board.stl", bytes.written());
    const st = try zs.physics.settle(gpa, &app.plate.parts.items[0].mesh);
    try testing.expectEqual(@as(usize, 0), st.rolls);
    // It lies on a large face: 4 mm tall or 10 mm tall, no more.
    const bb = app.plate.parts.items[0].mesh.bounds();
    try testing.expect(bb.max[2] - bb.min[2] < 10.5);
}

test "app: a fall step by step ends with the part flat, where it rests" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 40, 10, 4);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("board.stl", bytes.written());
    try app.turnPart(0, 0, 40);
    try testing.expect(try app.fallStart(0));
    var frames: usize = 0;
    while (try app.fallStep(1.0 / 60.0)) |fr| {
        frames += 1;
        if (fr.done) break;
        try testing.expect(frames < 60 * 8);
    }
    try testing.expect(app.fall == null);
    // Flat: 4 mm or 10 mm tall, on a face.
    const bb = app.plate.parts.items[0].mesh.bounds();
    try testing.expect(bb.max[2] - bb.min[2] < 10.01);
    const st = try zs.physics.settle(gpa, &app.plate.parts.items[0].mesh);
    try testing.expectEqual(@as(usize, 0), st.rolls);
    // A part that stands does not start a fall.
    try testing.expect(!try app.fallStart(0));
}

test "app: support turned off under a part that cannot stand: it is the unstable part" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 40, 10, 4);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("board.stl", bytes.written());
    try app.setSetting("project.support", "everywhere");
    try app.turnPart(0, 0, 40);
    try testing.expect(try app.unstablePart() == null);
    try app.setSetting("project.support", "off");
    try testing.expectEqual(@as(?usize, 0), try app.unstablePart());
}

test "app: the hand carries a part, lets go, and it rests on the plate" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 20, 10);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("box.stl", bytes.written());
    const p = app.plate.parts.items[0];
    // Take a top corner, lift it, and carry it 40 mm in x.
    const fp = p.footprint();
    try testing.expect(try app.grabStart(0, .{ fp[2], fp[3], 10 }));
    var k: usize = 0;
    while (k < 120) : (k += 1) {
        const t: f64 = @as(f64, @floatFromInt(k)) / 120.0;
        app.grabMove(.{ fp[2] - 40 * t, fp[3], 25 });
        _ = try app.fallStep(1.0 / 60.0);
    }
    app.grabEnd();
    var frames: usize = 0;
    while (try app.fallStep(1.0 / 60.0)) |fr| {
        frames += 1;
        if (fr.done) break;
    }
    try testing.expect(app.fall == null);
    try testing.expect(frames < 60 * 9);
    // It rests near the hand: the hand moved the corner 40 mm to -x.
    const q = app.plate.parts.items[0];
    try testing.expect(q.x < p.x - 10);
    const st = try zs.physics.settle(gpa, &app.plate.parts.items[0].mesh);
    try testing.expectEqual(@as(usize, 0), st.rolls);
}

test "app: the simulated print of a shelf with no support shows the plastic that fell" {
    const gpa = testing.allocator;
    // A post with a wide slab on it: 10 mm of each end of the slab is over
    // air.
    var b: zs.mesh.Builder = .init(gpa);
    errdefer b.deinit();
    try zs.mesh.shapes.addBox(&b, 10, 0, 0, 16, 6, 4);
    try zs.mesh.shapes.addBox(&b, 0, 0, 4, 26, 6, 5.2);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("shelf.stl", stl.written());
    try testing.expectError(error.NoResult, app.simulatePrint());
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    const planned = app.allToolpaths().?;
    const st = try app.simulatePrint();
    try testing.expect(st.moved_paths > 0);
    try testing.expect(st.max_move > 1);
    const shown = app.allToolpaths().?;
    try testing.expect(shown != planned);
    try testing.expectEqual(planned.pathCount(), shown.pathCount());
    try testing.expectEqual(planned.layerCount(), shown.layerCount());
    try app.showSimulated(false);
    try testing.expectEqual(planned, app.allToolpaths().?);
    try app.showSimulated(true);
    try testing.expectEqual(shown, app.allToolpaths().?);
    // A new slice drops the simulation.
    try app.setSetting("project.wall_count", "3");
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectError(error.NoResult, app.showSimulated(true));
}

fn slabStl(gpa: Allocator) !std.Io.Writer.Allocating {
    // A post with a slab 10 mm out over air on each side.
    var b: zs.mesh.Builder = .init(gpa);
    errdefer b.deinit();
    try zs.mesh.shapes.addBox(&b, 10, 0, 0, 16, 6, 4);
    try zs.mesh.shapes.addBox(&b, 0, 0, 4, 26, 6, 5.2);
    var mesh = try b.finish();
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    try mesh.writeStl(&stl.writer);
    return stl;
}

test "app: the simulation runs after the slice on its thread, and in pieces, with the same result" {
    const gpa = testing.allocator;
    var stl = try slabStl(gpa);
    defer stl.deinit();
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("slab.stl", stl.written());
    // On the thread of the slice, after it.
    app.auto_simulate = true;
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expect(app.adoptSimulation());
    try testing.expect(!app.adoptSimulation());
    const auto = app.sim.?.stats;
    try testing.expect(auto.failed > 0);
    try testing.expect(app.allToolpaths().? == &app.sim.?.paths);
    // In pieces, from the start: the same numbers.
    app.dropSimCheckpoints();
    try app.beginSimulation();
    try testing.expect(app.sim == null);
    var pieces: usize = 0;
    while (!try app.advanceSimulation(8)) pieces += 1;
    try testing.expect(pieces > 2);
    try testing.expectEqual(@as(usize, 0), app.sim_first_path);
    try testing.expectEqual(auto, app.sim.?.stats);
    // From a checkpoint of the simulation before: the same numbers.
    try app.beginSimulation();
    while (!try app.advanceSimulation(8)) {}
    try testing.expect(app.sim_first_path > 0);
    try testing.expectEqual(auto, app.sim.?.stats);
    // A change drops a simulation that runs in pieces.
    try app.beginSimulation();
    try testing.expect(!try app.advanceSimulation(1));
    try app.setSetting("project.wall_count", "3");
    try app.requestSlice();
    app.stopWorkerForTest();
    try testing.expectError(error.NoResult, app.advanceSimulation(1));
    // The new slice simulates again on its thread.
    try testing.expect(app.adoptSimulation());
}

test "app: engine.auto_simulate off gives no simulation after the slice; a run by hand still works" {
    if (comptime !has_threads) return error.SkipZigTest;
    const gpa = testing.allocator;
    var stl = try slabStl(gpa);
    defer stl.deinit();
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("slab.stl", stl.written());
    app.auto_simulate = true;
    try app.setSetting("engine.auto_simulate", "false");
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expect(!app.adoptSimulation());
    try testing.expect(app.sim == null);
    // By hand: the simulation runs.
    try app.requestSimulation();
    app.stopWorkerForTest();
    try testing.expect(app.adoptSimulation());
    // On again: the simulation runs after the slice, as before.
    try app.setSetting("engine.auto_simulate", "true");
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expect(app.adoptSimulation());
}

test "app: a change stops the simulation on the thread of the slice" {
    const gpa = testing.allocator;
    var stl = try slabStl(gpa);
    defer stl.deinit();
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("slab.stl", stl.written());
    app.auto_simulate = true;
    try app.startSlice();
    // A change at once: the slice or its simulation stops, and the new
    // slice simulates.
    try app.setSetting("project.wall_count", "3");
    try app.requestSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expect(app.adoptSimulation());
}

test "app: a part thrown past the edge of the bed stops at the edge" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 100, 60, 10);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("plate.stl", bytes.written());
    const p0 = app.plate.parts.items[0];
    const fp = p0.footprint();
    try testing.expect(try app.grabStart(0, .{ (fp[0] + fp[2]) / 2, (fp[1] + fp[3]) / 2, 10 }));
    // Carry it 100 mm to +x: past the edge of a 220 mm bed.
    var k: usize = 0;
    while (k < 120) : (k += 1) {
        const t: f64 = @as(f64, @floatFromInt(k)) / 120.0;
        app.grabMove(.{ (fp[0] + fp[2]) / 2 + 100 * t, (fp[1] + fp[3]) / 2, 15 });
        _ = try app.fallStep(1.0 / 60.0);
    }
    app.grabEnd();
    while (try app.fallStep(1.0 / 60.0)) |fr| if (fr.done) break;
    const q = app.plate.parts.items[0];
    // At the edge: well right of the start, and on the bed.
    try testing.expect(q.x > p0.x + 40);
    try testing.expect(q.footprint()[2] <= app.bedSize()[0]);
}

test "app: an undo or a removal while the hand holds a part ends the hold" {
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    defer app.destroy();
    try app.loadStl("box.stl", bytes.written());
    _ = app.undo.commit(app, 0);
    try app.movePart(0, 60, 60);
    app.undo.note(gpa, null, true);
    _ = app.undo.commit(app, 1000);
    const fp = app.plate.parts.items[0].footprint();
    try testing.expect(try app.grabStart(0, .{ fp[2], fp[3], 10 }));
    _ = try app.fallStep(1.0 / 60.0);
    _ = app.undo.undo(app, 2000);
    try testing.expect(app.fall == null);
    try testing.expect((try app.fallStep(1.0 / 60.0)) == null);
    // A removal of the part in the hand.
    try testing.expect(try app.grabStart(0, .{ fp[2], fp[3], 10 }));
    try app.removePart(0);
    try testing.expect(app.fall == null);
}

test "app: the skin and infill angles turn with a part, unless the setting is off" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var base: Settings = .{};
    base.project.skin_angle = 45;
    base.project.infill_angle = 10;
    // No turn: the same changes.
    const none = try angleChanges(ar, base, &.{}, 0);
    try testing.expectEqual(@as(usize, 0), none.len);
    // A turn of 30 degrees adds to both angles.
    const turned = try angleChanges(ar, base, &.{}, 30);
    var s = base;
    for (turned) |c| try s.set(c.name, c.value);
    try testing.expectApproxEqAbs(@as(f64, 75), s.project.skin_angle, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 40), s.project.infill_angle, 1e-9);
    // A part angle of its own: the turn adds to it.
    const own = [_]zs.settings.Change{.{ .name = "project.skin_angle", .value = "90" }};
    const t2 = try angleChanges(ar, base, &own, -30);
    s = base;
    for (t2) |c| try s.set(c.name, c.value);
    try testing.expectApproxEqAbs(@as(f64, 60), s.project.skin_angle, 1e-9);
    // Off: the angles stay from the bed.
    base.project.angles_follow_part = false;
    const off = try angleChanges(ar, base, &.{}, 30);
    try testing.expectEqual(@as(usize, 0), off.len);
}

/// A box of 20 x 20 x 10 mm on a new app, for the tests of the lift.
fn liftTestApp(gpa: Allocator) !*App {
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var mesh = try b.finish();
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try mesh.writeStl(&bytes.writer);
    mesh.deinit(gpa);
    const app = try App.create(gpa, null, null);
    errdefer app.destroy();
    try app.loadStl("box.stl", bytes.written());
    return app;
}

/// The lowest and the highest Z of the moves that print in G-code.
fn printZ(g: []const u8) [2]f64 {
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    var z: f64 = 0;
    var lines = std.mem.tokenizeScalar(u8, g, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "G1 ") and !std.mem.startsWith(u8, line, "G0 ")) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        var prints = false;
        while (f.next()) |w| {
            if (w[0] == ';') break;
            if (w[0] == 'Z') z = std.fmt.parseFloat(f64, w[1..]) catch z;
            if (w[0] == 'E') prints = (std.fmt.parseFloat(f64, w[1..]) catch 0) > 0;
        }
        if (prints) {
            lo = @min(lo, z);
            hi = @max(hi, z);
        }
    }
    return .{ lo, hi };
}

test "app: a part that sinks into the bed slices from z 0, with no layer under the bed" {
    const gpa = testing.allocator;
    const app = try liftTestApp(gpa);
    defer app.destroy();
    try app.startSlice();
    app.stopWorkerForTest();
    const full = app.layerCount();
    const top = printZ(app.gcode().?)[1];
    try testing.expectApproxEqAbs(@as(f64, 10), top, 0.21);
    // 4 mm into the bed: 6 mm of the part print, from the first layer up.
    try app.liftPart(0, -4);
    try testing.expectEqual(@as(f64, -4), app.plate.parts.items[0].z);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    try testing.expect(app.layerCount() < full);
    const z = printZ(app.gcode().?);
    try testing.expectApproxEqAbs(@as(f64, 6), z[1], 0.21);
    try testing.expectApproxEqAbs(app.settings.project.first_layer_height, z[0], 1e-6);
    // The cut at z 0 stands on the bed (no fall), and the card has no
    // note.
    try testing.expect(try app.unstablePart() == null);
    try testing.expectEqual(@as(?[]const u8, null), app.floatNote(0));
    // A part sinks at most to 0.5 mm over the bed.
    try app.liftPart(0, -50);
    try testing.expectApproxEqAbs(@as(f64, -9.5), app.plate.parts.items[0].z, 1e-9);
}

test "app: a part that floats prints on support; with support off it falls to the bed" {
    const gpa = testing.allocator;
    const app = try liftTestApp(gpa);
    defer app.destroy();
    try app.setSetting("project.support", "everywhere");
    try app.liftPart(0, 5);
    try testing.expect(try app.unstablePart() == null);
    try testing.expect(std.mem.startsWith(u8, app.floatNote(0).?, "It floats"));
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqual(State.done, app.getState());
    const g = app.gcode().?;
    // Support from the bed up to the part, and the top of the part at 15.
    try testing.expect(std.mem.indexOf(u8, g, ";TYPE:SUPPORT") != null);
    const z = printZ(g);
    try testing.expectApproxEqAbs(app.settings.project.first_layer_height, z[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 15), z[1], 0.21);
    // Support off: nothing holds it. The card says why, and the fall drops
    // it to the bed.
    try app.setSetting("project.support", "off");
    try testing.expect(std.mem.startsWith(u8, app.floatNote(0).?, "Support is off"));
    try testing.expectEqual(@as(?usize, 0), try app.unstablePart());
    try testing.expect(try app.fallStart(0));
    var frames: usize = 0;
    while (try app.fallStep(1.0 / 60.0)) |fr| {
        frames += 1;
        if (fr.done) break;
        try testing.expect(frames < 60 * 8);
    }
    try testing.expectEqual(@as(f64, 0), app.plate.parts.items[0].z);
    try testing.expect(try app.unstablePart() == null);
    // settlePart drops a part in the air at once.
    try app.liftPart(0, 3);
    try testing.expect(try app.settlePart(0) > 0);
    try testing.expectEqual(@as(f64, 0), app.plate.parts.items[0].z);
}

test "app: a lift back to 0 gives the same G-code, and a 3MF keeps the lift" {
    const gpa = testing.allocator;
    const app = try liftTestApp(gpa);
    defer app.destroy();
    try app.startSlice();
    app.stopWorkerForTest();
    const before = try gpa.dupe(u8, app.gcode().?);
    defer gpa.free(before);
    try app.liftPart(0, 3);
    try app.liftPart(0, 0);
    try app.startSlice();
    app.stopWorkerForTest();
    try testing.expectEqualStrings(before, app.gcode().?);
    // The lift goes into the 3MF of the plate and comes back.
    try app.liftPart(0, -2.5);
    const snap = try app.writeSnapshotAlloc(gpa);
    defer gpa.free(snap);
    const other = try App.create(gpa, null, null);
    defer other.destroy();
    try other.loadSnapshot(snap);
    try testing.expectApproxEqAbs(@as(f64, -2.5), other.plate.parts.items[0].z, 1e-9);
}

test "app: the angles of a part come back, and a turn about X is about the X of the bed" {
    const gpa = testing.allocator;
    const app = try liftTestApp(gpa);
    defer app.destroy();
    try app.setPartAngles(0, .{ 30, -20, 75 });
    const a = app.plate.angles(0);
    try testing.expectApproxEqAbs(@as(f64, 30), a[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -20), a[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 75), a[2], 1e-6);
    // A part turned 90 degrees about Z, then 90 about the X of the bed:
    // the file Y (turned to -X by the turn about Z) stays on the X axis
    // of the bed.
    try app.setPartAngles(0, .{ 0, 0, 90 });
    try app.turnPart(0, 0, 90);
    const r = zs.plate.orientation(&app.plate.parts.items[0]);
    try testing.expectApproxEqAbs(@as(f64, -1), r[0][1], 1e-9);
    // The lift stays after a turn.
    try app.liftPart(0, 4);
    try app.turnPart(0, 1, 30);
    try testing.expectEqual(@as(f64, 4), app.plate.parts.items[0].z);
}
