//! The plate set: the plates of the app, each with its own App.
//!
//! A set has one or more plates. Each plate has its own App (app.zig), so
//! it keeps its own settings, parts, undo list, and slice. One plate is
//! the active plate: the shell shows it and changes it with the zs_app
//! calls. The set slices the other plates in the background, so that the
//! view can show all plates in a row (render/plates.zig).
//!
//! The status of a plate (`Status`) comes from the state of its App and
//! from two marks of the set: `wanted` (the plate waits for a slice) and
//! `cannot` (zslice cannot slice the plate, for example a resin plate).
//!
//! The slice order. A change of a plate marks it wanted (`changed`). The
//! set slices one plate at a time: the active plate first, then the other
//! wanted plates in order. A plate keeps its old slice until its new slice
//! is done. During a drag of a part, the shell marks the change "held"
//! (`changed` with hold): the slice waits until `releaseHeld`, so that a
//! move or a turn slices once, at the end.
//!
//! Two modes:
//!
//! - Auto (a native shell, with threads). A change of the active plate
//!   starts its slice at once, and stops a slice of another plate (that
//!   plate slices again later). The set starts the slices of the other
//!   plates itself, on the thread of the slice that ended. The events come
//!   on the slice threads.
//! - Manual (wasm, or a test). The App slices on the calling thread. The
//!   shell calls `step` when it has time: one step slices the next wanted
//!   plate. The web worker calls it from a timer, so the messages of the
//!   page come first.
//!
//! Threads in auto mode. The calls of the shell come from one thread (the
//! UI thread). A slice thread calls `onAppEvent`. Both take the lock of
//! the set to start a slice. A slice thread never waits for the lock: it
//! marks `pending`, and the holder of the lock does the work before it
//! lets the lock go. So the UI thread can wait for a slice thread (a stop
//! of a slice) while it holds the lock.
//!
//! The view. `sync` gives the changes for a view of the plates since the
//! last sync: the beds, the plates whose id changed at a place (their old
//! beads go), the flags, the footprints of the plates that cannot slice,
//! and the beads of the other plates with a new slice. The set keeps the
//! bytes of the last scene of each plate (`scene`): the view of the web
//! page is in another wasm instance, and a plate that slices again shows
//! its old beads until then. c_api/set.zig makes the scene bytes and
//! applies a sync to a view.
//!
//! The model for this code is the plate set of the web worker
//! (web/app/worker.js and web/app/app.js before the set moved here).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const parallel = zs.parallel;
const project = zs.project;
const project_file = @import("project_file.zig");

pub const Status = enum(c_int) {
    /// No parts.
    empty = 0,
    /// The slice is old, or there is no slice yet: the plate waits.
    stale = 1,
    slicing = 2,
    done = 3,
    failed = 4,
    /// zslice cannot slice the plate (a resin plate).
    cannot = 5,
};

/// The event of a change of the list or of a status. The plate of the
/// event is `no_plate`.
pub const event_plates: c_int = 5;
pub const no_plate = std.math.maxInt(usize);

/// The shell callback: the events of the App of each plate (with the
/// index of the plate), and `event_plates`.
pub const EventFn = *const fn (user: ?*anyopaque, plate: usize, event: c_int, progress: f64, status: c_int) callconv(.c) void;

/// Makes the scene bytes (render/view.zig writeScene) of the last slice of
/// an app, in a color mode, or null. c_api/set.zig gives it: the set does
/// not depend on the renderer.
pub const SceneFn = *const fn (gpa: Allocator, app: *const App, mode: u32) ?[]u8;

/// The flags of a plate in a view (enum zs_plate_flag).
pub const flag_stale: u32 = 1;
pub const flag_bed_model: u32 = 2;
pub const flag_disabled: u32 = 4;

/// The bed of a plate whose bed size is 0.
const default_bed: f32 = 220;

pub const Plate = struct {
    set: *Set,
    app: *App,
    /// New for each plate: a view clears the beads at a place when another
    /// plate comes there.
    id: u64,
    /// The place of the plate in the list, for the events of its app.
    index: std.atomic.Value(usize),
    /// The name for a list; empty: the name of the model of the app.
    name: []u8 = &.{},
    /// The key of the printer that the plate is for (a key of the app's
    /// list of printers), or empty: no printer yet. The project file keeps
    /// it.
    printer: []u8 = &.{},
    /// Why the plate failed to load, or why its parts do not fit.
    message: [:0]u8 = empty,
    cannot: bool = false,
    load_failed: bool = false,
    wanted: bool = false,
    /// The last scene of the plate, its slice (App.done_count), its color
    /// mode, and a serial number that changes with each new scene.
    scene: []u8 = &.{},
    scene_gen: u32 = 0,
    scene_mode: u32 = 0,
    scene_serial: u64 = 0,
    /// The strings of the last `info`.
    info_name: [:0]u8 = empty,
    info_key: [:0]u8 = empty,

    fn deinit(p: *Plate, gpa: Allocator) void {
        p.app.halt();
        p.app.destroy();
        gpa.free(p.name);
        gpa.free(p.printer);
        freeZ(gpa, p.message);
        gpa.free(p.scene);
        freeZ(gpa, p.info_name);
        freeZ(gpa, p.info_key);
        gpa.destroy(p);
    }
};

/// Frees a string of `dupeZ`; "" is the static empty string.
fn freeZ(gpa: Allocator, s: [:0]u8) void {
    if (s.ptr != empty.ptr) gpa.free(s);
}

var empty_buf = [_:0]u8{};
const empty: [:0]u8 = &empty_buf;

fn dupeZ(gpa: Allocator, s: []const u8) Allocator.Error![:0]u8 {
    if (s.len == 0) return empty;
    return gpa.dupeZ(u8, s);
}

/// A lock that a thread can wait on. Zig 0.16 has no thread mutex in std
/// without an Io, so it is an atomic flag and a parallel.Signal.
const Lock = struct {
    held: std.atomic.Value(u32) = .init(0),
    signal: parallel.Signal = .{},

    fn tryLock(l: *Lock) bool {
        return l.held.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    fn lock(l: *Lock) void {
        while (true) {
            const seen = l.signal.current();
            if (l.tryLock()) return;
            l.signal.wait(seen);
        }
    }

    fn unlock(l: *Lock) void {
        l.held.store(0, .release);
        l.signal.notify();
    }
};

/// What a view of the plates gets in a sync (see `sync`).
pub const Plan = struct {
    active: usize,
    beds: []const [2]f32,
    items: []const Item,

    pub const Item = struct {
        /// Another plate is at this place now: its old beads go first.
        clear: bool,
        flags: u32,
        /// The footprints of the parts (x0, y0, x1, y1), or null.
        outline: ?[]const [4]f32,
        /// The bytes of a new scene, or null. They point into the set and
        /// stay valid until the next call of the set.
        scene: ?[]const u8,
    };
};

/// What a view has of each place (see `sync`).
const Synced = struct { id: u64 = 0, scene: u64 = 0, outline: u64 = 0 };

pub const Info = struct {
    id: u64,
    status: Status,
    bed_x: f64,
    bed_y: f64,
    name: [:0]const u8,
    printer_key: [:0]const u8,
    part_count: usize,
    message: [:0]const u8,
};

pub const Set = struct {
    gpa: Allocator,
    event_fn: ?EventFn,
    user: ?*anyopaque,
    /// Auto mode (see the header comment).
    auto: bool,
    plates: std.ArrayList(*Plate) = .empty,
    active: usize = 0,
    next_id: u64 = 1,
    /// The id of the plate with a held change, or 0. Only the shell thread
    /// reads and writes it (a slice thread kicks with `worker`, which does
    /// not read it), so a held change sets it with no lock.
    held: u64 = 0,
    /// The id of the plate that `step` slices now, or 0.
    stepping: u64 = 0,
    lock: Lock = .{},
    /// A slice thread asks the holder of the lock to start the next slice.
    pending: std.atomic.Value(bool) = .init(false),
    /// The list or a status changed: an `event_plates` when the lock goes.
    dirty: std.atomic.Value(bool) = .init(false),
    scene_fn: ?SceneFn = null,
    /// The color mode of the scenes (enum zs_view_mode).
    mode: u32 = 0,
    /// The shell uses the scenes: keep the beads of a plate that stops
    /// being the active plate.
    scenes_on: bool = false,
    synced: std.ArrayList(Synced) = .empty,

    pub const Error = Allocator.Error || error{OutOfRange};

    /// A new set with one empty plate.
    pub fn create(gpa: Allocator, event_fn: ?EventFn, user: ?*anyopaque, auto: bool) Allocator.Error!*Set {
        const set = try gpa.create(Set);
        set.* = .{ .gpa = gpa, .event_fn = event_fn, .user = user, .auto = auto and parallel.has_threads };
        errdefer gpa.destroy(set);
        const p = try set.newPlate();
        set.plates.append(gpa, p) catch |e| {
            p.deinit(gpa);
            return e;
        };
        return set;
    }

    pub fn destroy(set: *Set) void {
        set.lock.lock();
        // Each slice stops first, so no slice thread uses the set later.
        for (set.plates.items) |p| p.app.halt();
        for (set.plates.items) |p| p.deinit(set.gpa);
        set.plates.deinit(set.gpa);
        set.synced.deinit(set.gpa);
        set.lock.unlock();
        set.gpa.destroy(set);
    }

    fn newPlate(set: *Set) Allocator.Error!*Plate {
        const p = try set.gpa.create(Plate);
        errdefer set.gpa.destroy(p);
        p.* = .{ .set = set, .app = undefined, .id = set.next_id, .index = .init(set.plates.items.len) };
        p.app = try App.create(set.gpa, onAppEvent, p);
        set.next_id += 1;
        return p;
    }

    // ---- the lock ----

    fn enter(set: *Set) void {
        set.lock.lock();
    }

    /// Lets the lock go: first the work that a slice thread asked for,
    /// then the event of a change, with no lock held.
    fn leave(set: *Set) void {
        if (set.pending.swap(false, .acq_rel)) set.kick(false, null);
        set.lock.unlock();
        set.drain(null);
        if (set.dirty.swap(false, .acq_rel)) set.emit(no_plate, event_plates, 0, 0);
    }

    /// Starts the next slice if the lock is free; else the holder does it.
    fn drain(set: *Set, from: ?*Plate) void {
        while (set.pending.load(.acquire)) {
            if (!set.lock.tryLock()) return;
            if (set.pending.swap(false, .acq_rel)) set.kick(from != null, from);
            set.lock.unlock();
        }
    }

    fn emit(set: *Set, plate: usize, event: c_int, progress: f64, status: c_int) void {
        const f = set.event_fn orelse return;
        f(set.user, plate, event, progress, status);
    }

    fn markDirty(set: *Set) void {
        set.dirty.store(true, .release);
    }

    /// The event function of the App of each plate. It runs on the slice
    /// thread (auto mode), or in `step` (manual mode).
    fn onAppEvent(user: ?*anyopaque, event: c_int, progress: f64, status: c_int) callconv(.c) void {
        const p: *Plate = @ptrCast(@alignCast(user.?));
        const set = p.set;
        set.emit(p.index.load(.acquire), event, progress, status);
        // The progress and the simulated print of a slice that ended
        // change no status.
        if (event == 1 or event == 6 or !set.auto) return;
        // A plate that waits keeps its result, and not the memory for a
        // faster next slice.
        if (p.index.load(.acquire) != @atomicLoad(usize, &set.active, .acquire)) p.app.trim();
        set.emit(no_plate, event_plates, 0, 0);
        set.pending.store(true, .release);
        set.drain(p);
    }

    // ---- the status ----

    fn statusOf(set: *const Set, p: *const Plate) Status {
        if (p.cannot) return .cannot;
        if (p.id == set.stepping) return .slicing;
        const st = p.app.getState();
        if (st == .slicing) return .slicing;
        if (p.load_failed) return .failed;
        if (st == .empty) return .empty;
        if (p.wanted) return .stale;
        return switch (st) {
            .done => .done,
            .failed => .failed,
            else => .stale,
        };
    }

    fn reindex(set: *Set) void {
        for (set.plates.items, 0..) |p, i| p.index.store(i, .release);
    }

    fn setActive(set: *Set, i: usize) void {
        @atomicStore(usize, &set.active, i, .release);
    }

    // ---- the slices ----

    /// Starts the next slice in auto mode. On the shell thread (worker =
    /// false), a wanted active plate starts at once, and a slice of
    /// another plate stops first. On a slice thread, only the other
    /// plates start, and only when no plate slices.
    fn kick(set: *Set, worker: bool, from: ?*Plate) void {
        if (!set.auto) return;
        const a = set.plates.items[set.active];
        if (!worker and a.wanted and !a.cannot and a.id != set.held) {
            for (set.plates.items) |p| {
                if (p == a or p.app.getState() != .slicing) continue;
                p.app.halt();
                p.wanted = true;
            }
            a.wanted = false;
            a.load_failed = false;
            if (a.app.getState() != .empty) a.app.requestSlice() catch {};
            set.markDirty();
            return;
        }
        for (set.plates.items) |p| if (p.app.getState() == .slicing) return;
        for (set.plates.items, 0..) |p, i| {
            if (i == set.active or !p.wanted or p.cannot or p == from) continue;
            p.wanted = false;
            p.load_failed = false;
            if (p.app.getState() != .empty) p.app.startSlice() catch {};
            set.markDirty();
            return;
        }
    }

    /// The next plate that `step` slices: the active plate first, then
    /// the other wanted plates in order.
    fn nextLocked(set: *const Set) ?usize {
        const a = set.plates.items[set.active];
        if (a.wanted and !a.cannot and a.id != set.held) return set.active;
        for (set.plates.items, 0..) |p, i| {
            if (i != set.active and p.wanted and !p.cannot) return i;
        }
        return null;
    }

    pub fn next(set: *Set) ?usize {
        set.enter();
        defer set.leave();
        return set.nextLocked();
    }

    /// Manual mode: slices the next wanted plate on the calling thread.
    /// Returns false if no plate waits. A canceled slice waits again.
    pub fn step(set: *Set) bool {
        set.enter();
        const i = set.nextLocked() orelse {
            set.leave();
            return false;
        };
        const p = set.plates.items[i];
        p.wanted = false;
        p.load_failed = false;
        if (p.app.getState() == .empty) {
            set.markDirty();
            set.leave();
            return true;
        }
        set.stepping = p.id;
        set.markDirty();
        set.leave();
        const started = if (p.app.startSlice()) true else |_| false;
        if (started) p.app.waitSlice();
        set.enter();
        set.stepping = 0;
        // A canceled slice: the change that canceled it waits, and its
        // slice comes next.
        if (p.app.getState() == .ready) p.wanted = true;
        if (i != set.active and p.app.getState() == .done) {
            if (set.scenes_on) set.ensureScene(p);
            p.app.trim();
        }
        set.markDirty();
        set.leave();
        return true;
    }

    // ---- the list ----

    pub fn count(set: *Set) usize {
        set.enter();
        defer set.leave();
        return set.plates.items.len;
    }

    pub fn activeIndex(set: *Set) usize {
        return @atomicLoad(usize, &set.active, .acquire);
    }

    /// The App of plate i. Only the calls of the shell (one thread) change
    /// the list of the plates, so this call reads it with no wait: while a
    /// slice thread holds the lock (a slice starts), it does not wait for
    /// it. With the lock free, it takes it, so the work that a slice thread
    /// asked for runs (see `leave`).
    pub fn appOf(set: *Set, i: usize) ?*App {
        if (set.lock.tryLock()) {
            defer set.leave();
            if (i >= set.plates.items.len) return null;
            return set.plates.items[i].app;
        }
        if (i >= set.plates.items.len) return null;
        return set.plates.items[i].app;
    }

    /// A new empty plate after the others, with the settings of the active
    /// plate, named "Plate n". It becomes the active plate.
    pub fn add(set: *Set) Allocator.Error!usize {
        set.enter();
        defer set.leave();
        const p = try set.newPlate();
        p.app.copySettingsFrom(set.plates.items[set.active].app) catch {};
        p.name = std.fmt.allocPrint(set.gpa, "Plate {d}", .{set.plates.items.len + 1}) catch &.{};
        set.plates.append(set.gpa, p) catch |e| {
            p.deinit(set.gpa);
            return e;
        };
        set.reindex();
        const i = set.plates.items.len - 1;
        set.selectLocked(i);
        set.markDirty();
        return i;
    }

    /// Makes plate i the active plate. The plate that was active frees
    /// the memory for a faster slice (App.trim). A plate with no slice of
    /// its parts now waits for one.
    pub fn select(set: *Set, i: usize) error{OutOfRange}!void {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return error.OutOfRange;
        set.selectLocked(i);
    }

    fn selectLocked(set: *Set, i: usize) void {
        if (i != set.active) {
            const old = set.plates.items[set.active];
            // The beads of the plate that was active, for the view: its
            // result goes with its next slice.
            if (set.scenes_on) set.ensureScene(old);
            old.app.trim();
            set.setActive(i);
            set.markDirty();
        }
        const p = set.plates.items[i];
        if (!p.cannot and p.app.getState() != .empty) {
            const st = set.statusOf(p);
            if (st != .done and st != .slicing) p.wanted = true;
        }
        set.kick(false, null);
    }

    /// Removes plate i. If it is the active plate, the plate on its left
    /// becomes active (the first plate, if it was the first); else the
    /// active plate stays. The last plate stays, with no parts.
    pub fn remove(set: *Set, i: usize) error{OutOfRange}!void {
        set.enter();
        defer set.leave();
        const n = set.plates.items.len;
        if (i >= n) return error.OutOfRange;
        set.markDirty();
        if (n == 1) {
            const p = set.plates.items[0];
            p.app.halt();
            p.app.clearPlate() catch {};
            p.wanted = false;
            p.cannot = false;
            p.load_failed = false;
            set.gpa.free(p.name);
            p.name = &.{};
            set.dropScene(p);
            return;
        }
        const p = set.plates.orderedRemove(i);
        p.deinit(set.gpa);
        set.reindex();
        if (i < set.active) {
            set.setActive(set.active - 1);
        } else if (i == set.active) {
            // The plate on its left becomes active (the first plate, if
            // it was the first).
            set.setActive(if (i > 0) i - 1 else 0);
            set.selectLocked(set.active);
        }
        set.kick(false, null);
    }

    /// Keeps the active plate alone: a set of one plate.
    pub fn keepActive(set: *Set) void {
        set.enter();
        defer set.leave();
        if (set.plates.items.len <= 1) return;
        const a = set.plates.items[set.active];
        for (set.plates.items) |p| if (p != a) p.deinit(set.gpa);
        set.plates.clearRetainingCapacity();
        set.plates.appendAssumeCapacity(a);
        set.setActive(0);
        set.reindex();
        set.markDirty();
    }

    /// The name of plate i for a list (null or "": the name of its model).
    pub fn setName(set: *Set, i: usize, name: ?[]const u8) Error!void {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return error.OutOfRange;
        const p = set.plates.items[i];
        const copy = try set.gpa.dupe(u8, name orelse "");
        set.gpa.free(p.name);
        p.name = copy;
        set.markDirty();
    }

    /// The printer that plate i is for (a key of the app's printers), or
    /// null or "": none.
    pub fn setPrinter(set: *Set, i: usize, key: ?[]const u8) Error!void {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return error.OutOfRange;
        const p = set.plates.items[i];
        const copy = try set.gpa.dupe(u8, key orelse "");
        set.gpa.free(p.printer);
        p.printer = copy;
        set.markDirty();
    }

    /// The printer of plate i (empty: none). It stays valid until the next
    /// change of the printer of the plate, or of the list.
    pub fn printerOf(set: *Set, i: usize) ?[]const u8 {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return null;
        return set.plates.items[i].printer;
    }

    /// The facts of plate i for a list. The strings stay valid until the
    /// next `info` of the same plate, or a change of the list.
    pub fn info(set: *Set, i: usize) ?Info {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return null;
        const p = set.plates.items[i];
        const s = &p.app.settings;
        const name = if (p.name.len > 0) p.name else p.app.model_name;
        if (dupeZ(set.gpa, name)) |z| {
            freeZ(set.gpa, p.info_name);
            p.info_name = z;
        } else |_| {}
        if (std.fmt.allocPrintSentinel(set.gpa, "{s}\n{s}", .{ s.machine.model, s.machine.name }, 0)) |z| {
            freeZ(set.gpa, p.info_key);
            p.info_key = z;
        } else |_| {}
        return .{
            .id = p.id,
            .status = set.statusOf(p),
            .bed_x = s.machine.bed_size_x,
            .bed_y = s.machine.bed_size_y,
            .name = p.info_name,
            .printer_key = p.info_key,
            .part_count = p.app.plate.count(),
            .message = if (p.message.len == 0 and set.statusOf(p) == .failed) failureText(p.app.failure) else p.message,
        };
    }

    /// Why a slice failed, in words, for a plate with no message.
    fn failureText(e: ?anyerror) [:0]const u8 {
        const err = e orelse return "The slice failed.";
        return switch (err) {
            error.OutOfMemory => "Out of memory: the plate is too big to slice here. Put fewer parts on it (Make n in all spreads them over plates), or use the desktop app.",
            error.EmptyMesh => "A part has no material to print.",
            else => "The slice failed.",
        };
    }

    // ---- changes ----

    /// Plate i changed: it waits for a slice. In auto mode, a change of the
    /// active plate starts its slice at once. With `hold` (a drag goes
    /// on), the slice waits until `releaseHeld`.
    pub fn changed(set: *Set, i: usize, hold: bool) error{OutOfRange}!void {
        // A held change (each step of a drag) only marks the plate: no
        // wait for the lock, which a slice thread can hold while a live
        // slice of the drag starts (the Mac saw 8 ms waits for each edit).
        // Only the calls of the shell (one thread) change the list of the
        // plates, so this call reads it with no lock (as `appOf`).
        if (hold) {
            if (i >= set.plates.items.len) return error.OutOfRange;
            const p = set.plates.items[i];
            if (!p.cannot) set.held = p.id;
            return;
        }
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return error.OutOfRange;
        set.changedLocked(set.plates.items[i], hold);
    }

    fn changedLocked(set: *Set, p: *Plate, hold: bool) void {
        if (p.cannot) return;
        if (hold) {
            set.held = p.id;
            return;
        }
        if (set.held == p.id) set.held = 0;
        p.load_failed = false;
        set.markDirty();
        if (p.app.getState() == .empty) {
            // No parts: no slice, and no beads.
            p.wanted = false;
            set.dropScene(p);
            return;
        }
        p.wanted = true;
        // A plate that is not active and slices: it slices again later.
        if (set.auto and p.index.load(.acquire) != set.active and p.app.getState() == .slicing) p.app.halt();
        set.kick(false, null);
    }

    /// The end of a drag: the held change slices now.
    pub fn releaseHeld(set: *Set) void {
        set.enter();
        defer set.leave();
        const id = set.held;
        if (id == 0) return;
        set.held = 0;
        for (set.plates.items) |p| {
            if (p.id == id) return set.changedLocked(p, false);
        }
    }

    // ---- projects ----

    /// Loads all plates of a printdeck.yml in place of the plates of the
    /// set: one App for each plate, with its profiles, settings, and parts
    /// (project.zig). A plate that zslice cannot slice (no Cura stack: a
    /// resin plate) gets its parts for their footprints, and the status
    /// `cannot`. A plate that does not load has the status `failed` and a
    /// message; a plate whose parts do not all fit has a message too.
    /// Plate `want` becomes the active plate. On an error of the yml, the
    /// set does not change and `diag` says why.
    pub fn projectLoad(set: *Set, files: *const project.Files, yml: []const u8, counts: []const u8, want: usize, diag: *project.Diagnostic, diag_arena: Allocator) (Allocator.Error || project.Error)!void {
        var arena_state = std.heap.ArenaAllocator.init(set.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const planned = project.planText(arena, yml, counts, diag) catch |e| {
            // The message lives in the arena of the caller.
            diag.message = diag_arena.dupe(u8, diag.message) catch "";
            return e;
        };
        var list: std.ArrayList(*Plate) = .empty;
        defer list.deinit(set.gpa);
        errdefer for (list.items) |p| p.deinit(set.gpa);
        for (planned.plates) |plate| {
            const p = try set.newPlate();
            list.append(set.gpa, p) catch |e| {
                p.deinit(set.gpa);
                return e;
            };
            p.name = try set.gpa.dupe(u8, try project.plateName(arena, &planned.project, plate));
            try set.loadProjectPlate(arena, p, files, &planned, plate);
        }
        if (list.items.len == 0) return;

        set.enter();
        defer set.leave();
        for (set.plates.items) |p| p.app.halt();
        for (set.plates.items) |p| p.deinit(set.gpa);
        set.plates.clearRetainingCapacity();
        try set.plates.appendSlice(set.gpa, list.items);
        list.clearRetainingCapacity();
        set.held = 0;
        set.setActive(@min(want, set.plates.items.len - 1));
        set.reindex();
        set.markDirty();
        set.selectLocked(set.active);
    }

    fn loadProjectPlate(set: *Set, arena: Allocator, p: *Plate, files: *const project.Files, planned: *const project.Planned, plate: project.Plate) Allocator.Error!void {
        const app = p.app;
        if (try project.plateCannot(arena, files, plate)) {
            // Its parts, with no slice: a view shows their footprints.
            p.cannot = true;
            for (plate.items) |item| {
                const part = &planned.project.parts[item.part];
                for (part.files) |f| {
                    const bytes = files.get(f) orelse continue;
                    for (0..item.count) |_| _ = app.addStl(std.fs.path.basename(f), bytes) catch break;
                }
            }
            if (app.plate.count() > 1) _ = app.arrangePlate() catch {};
            return;
        }
        var diag: project.Diagnostic = .{};
        const fail = struct {
            fn f(s: *Set, pl: *Plate, text: []const u8) Allocator.Error!void {
                pl.load_failed = true;
                freeZ(s.gpa, pl.message);
                pl.message = try dupeZ(s.gpa, text);
            }
        }.f;
        const profiles = project.plateProfiles(arena, files, plate, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(set, p, if (diag.message.len > 0) diag.message else @errorName(e)),
        };
        const groups = [_]zs.profile.Group{ .machine, .filament, .project };
        for (groups, profiles) |g, prof| {
            app.resetGroup(g);
            var pd: zs.profile.Diagnostic = .{};
            app.applyProfile(g, "saved", prof.text, &pd) catch |e| {
                app.resetGroup(g);
                return fail(set, p, try std.fmt.allocPrint(arena, "The {s} profile {s}: line {d}: {s}", .{ @tagName(g), prof.name, pd.line, if (pd.message.len > 0) pd.message else @errorName(e) }));
            };
        }
        const fits = project.loadPlate(arena, app, files, planned, plate, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(set, p, if (diag.message.len > 0) diag.message else @errorName(e)),
        };
        if (!fits) {
            freeZ(set.gpa, p.message);
            p.message = try dupeZ(set.gpa, "The parts do not all fit on the bed. Print fewer copies, or put some parts on another plate.");
        }
        p.wanted = app.getState() != .empty;
    }

    /// Moves part `part` of plate `from` to plate `to` (null: a new plate
    /// after the others, with the settings of plate `from`). Both plates
    /// slice again. Returns the index of the target plate.
    pub fn movePart(set: *Set, from: usize, part: usize, to: ?usize) Error!usize {
        if (from >= set.plates.items.len) return error.OutOfRange;
        if (to) |t| if (t >= set.plates.items.len or t == from) return error.OutOfRange;
        const src = set.plates.items[from].app;
        if (part >= src.plate.count()) return error.OutOfRange;
        const target = to orelse blk: {
            const keep = set.active;
            set.active = from;
            const n = try set.add();
            // `add` copies the settings of the active plate and selects
            // the new plate; the active plate stays the one before.
            try set.select(keep);
            break :blk n;
        };
        const dst = set.plates.items[target].app;
        _ = try src.movePartTo(part, dst);
        src.undo.note(src.gpa, null, true);
        dst.undo.note(dst.gpa, null, true);
        try set.changed(from, false);
        try set.changed(target, false);
        return target;
    }

    pub const Fill = struct { copies: usize, plates: usize };

    /// Copies of part `part` of plate `from` until there are `n` in all:
    /// on its plate while they fit the bed, then on new plates after the
    /// others, each with the settings of plate `from`, full in turn. At
    /// most 200 new plates. Returns the copies in all (with the part) and
    /// the plates that have them.
    pub fn fill(set: *Set, from: usize, part: usize, n: usize) Error!Fill {
        if (from >= set.plates.items.len) return error.OutOfRange;
        const src = set.plates.items[from].app;
        if (part >= src.plate.count()) return error.OutOfRange;
        var copies: usize = 1;
        var plates: usize = 1;
        // On the plate of the part.
        while (copies < n) {
            const j = try src.duplicatePart(part);
            if (!src.plate.allFit(src.bedSize(), src.partGap())) {
                try src.removePart(j);
                break;
            }
            copies += 1;
        }
        src.undo.note(src.gpa, null, true);
        try set.changed(from, false);
        // On new plates.
        const keep = set.active;
        var made: usize = 0;
        while (copies < n and made < 200) : (made += 1) {
            set.active = from;
            const t = try set.add();
            const dst = set.plates.items[t].app;
            // A first copy goes over; the plate then fills as the first.
            const j = try src.duplicatePart(part);
            _ = try src.movePartTo(j, dst);
            copies += 1;
            plates += 1;
            while (copies < n) {
                const k = try dst.duplicatePart(0);
                if (!dst.plate.allFit(dst.bedSize(), dst.partGap())) {
                    try dst.removePart(k);
                    break;
                }
                copies += 1;
            }
            dst.undo.note(dst.gpa, null, true);
            try set.changed(t, false);
            // A part that does not fit an empty bed: no more plates.
            if (dst.plate.count() == 1 and !dst.plate.allFit(dst.bedSize(), dst.partGap())) break;
        }
        try set.select(@min(keep, set.plates.items.len - 1));
        return .{ .copies = copies, .plates = plates };
    }

    pub const Totals = struct {
        plates: usize = 0,
        /// The plates with parts and a slice; the others are not in the
        /// sums (they slice now, or failed).
        sliced: usize = 0,
        missing: usize = 0,
        parts: usize = 0,
        time_s: f64 = 0,
        filament_g: f64 = 0,
        filament_mm: f64 = 0,
        /// The filament (its weight times filament.price_per_kg of each
        /// plate) and the machine time (machine.hour_rate).
        cost_filament: f64 = 0,
        cost_machine: f64 = 0,

        fn addApp(t: *Totals, app: *App) void {
            const parts = app.plate.count();
            if (parts == 0) return;
            t.plates += 1;
            t.parts += parts;
            const r = app.result() orelse {
                t.missing += 1;
                return;
            };
            t.sliced += 1;
            t.time_s += r.print_time_s;
            t.filament_g += r.filament_g;
            t.filament_mm += r.filament_mm;
            t.cost_filament += r.filament_g / 1000 * app.settings.filament.price_per_kg;
            t.cost_machine += r.print_time_s / 3600 * app.settings.machine.hour_rate;
        }
    };

    /// The sums over the plates with parts: time, filament, and cost. A
    /// plate with no slice yet counts in `missing`.
    pub fn totals(set: *Set) Totals {
        set.enter();
        defer set.leave();
        var t: Totals = .{};
        for (set.plates.items) |p| t.addApp(p.app);
        return t;
    }

    /// The same for plate i alone.
    pub fn plateTotals(set: *Set, i: usize) ?Totals {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return null;
        var t: Totals = .{};
        t.addApp(set.plates.items[i].app);
        return t;
    }

    // ---- the project file ----

    /// The plates as one file (see project_file.zig), in gpa.
    pub fn saveProject(set: *Set, gpa: Allocator, name: []const u8) (Allocator.Error || error{WriteFailed})![]u8 {
        set.enter();
        defer set.leave();
        var list: std.ArrayList(project_file.PlateIn) = .empty;
        defer list.deinit(gpa);
        for (set.plates.items) |p| try list.append(gpa, .{ .app = p.app, .name = p.name, .printer = p.printer });
        return project_file.save(gpa, name, list.items, set.active);
    }

    /// Opens a project file: its plates replace the plates of the set. A
    /// file that is not a project changes nothing (error.NotProject).
    pub fn openProject(set: *Set, bytes: []const u8, diag: *project_file.Diagnostic) project_file.Error!void {
        var arena_state = std.heap.ArenaAllocator.init(set.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = try project_file.parse(arena, bytes, diag);
        var list: std.ArrayList(*Plate) = .empty;
        defer list.deinit(set.gpa);
        errdefer for (list.items) |p| p.deinit(set.gpa);
        for (parsed.plates) |pl| {
            const p = try set.newPlate();
            list.append(set.gpa, p) catch |e| {
                p.deinit(set.gpa);
                return e;
            };
            p.name = try set.gpa.dupe(u8, pl.name);
            p.printer = try set.gpa.dupe(u8, pl.printer);
            try project_file.loadPlate(p.app, pl, diag);
            p.wanted = p.app.getState() != .empty;
        }
        if (list.items.len == 0) return error.NotProject;
        set.enter();
        defer set.leave();
        for (set.plates.items) |p| p.app.halt();
        for (set.plates.items) |p| p.deinit(set.gpa);
        set.plates.clearRetainingCapacity();
        try set.plates.appendSlice(set.gpa, list.items);
        list.clearRetainingCapacity();
        set.held = 0;
        set.setActive(@min(parsed.active, set.plates.items.len - 1));
        set.reindex();
        set.markDirty();
        set.selectLocked(set.active);
    }

    // ---- the view ----

    /// The color mode of the scenes (enum zs_view_mode). The scenes of the
    /// plates with a slice are made again in the new mode.
    pub fn setMode(set: *Set, mode: u32) void {
        set.enter();
        defer set.leave();
        set.mode = mode;
    }

    fn dropScene(set: *Set, p: *Plate) void {
        set.gpa.free(p.scene);
        p.scene = &.{};
        p.scene_serial +%= 1;
    }

    /// Makes the scene of plate p again if its app has a newer slice, or
    /// the color mode changed. Without a slice, the old scene stays (the
    /// beads of a plate that slices again).
    fn ensureScene(set: *Set, p: *Plate) void {
        const f = set.scene_fn orelse return;
        if (p.app.getState() != .done) return;
        const gen = p.app.done_count.load(.acquire);
        if (p.scene.len > 0 and p.scene_gen == gen and p.scene_mode == set.mode) return;
        const bytes = f(set.gpa, p.app, set.mode) orelse return;
        set.gpa.free(p.scene);
        p.scene = bytes;
        p.scene_gen = gen;
        p.scene_mode = set.mode;
        p.scene_serial +%= 1;
    }

    /// Puts back the last scene of plate i from a session (session.zig):
    /// the view shows it at once, until the plate slices again.
    pub fn restoreScene(set: *Set, i: usize, bytes: []const u8) Allocator.Error!void {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return;
        const p = set.plates.items[i];
        const copy = try set.gpa.dupe(u8, bytes);
        set.gpa.free(p.scene);
        p.scene = copy;
        // No slice made it: the first slice of the plate replaces it.
        p.scene_gen = std.math.maxInt(@TypeOf(p.scene_gen));
        p.scene_mode = set.mode;
        p.scene_serial +%= 1;
    }

    /// The scene bytes of plate i: of its last slice, or its old beads
    /// while it slices again. Null if it has none. The bytes stay valid
    /// until the next call of the set.
    pub fn scene(set: *Set, i: usize) ?[]const u8 {
        set.enter();
        defer set.leave();
        if (i >= set.plates.items.len) return null;
        set.scenes_on = true;
        const p = set.plates.items[i];
        set.ensureScene(p);
        return if (p.scene.len > 0) p.scene else null;
    }

    /// The changes for a view of the plates since the last sync (see the
    /// header comment). One view follows one set; `resetSync` starts again
    /// for a new view. The plan is in `arena`; its scenes point into the
    /// set.
    pub fn sync(set: *Set, arena: Allocator) Allocator.Error!Plan {
        set.enter();
        defer set.leave();
        set.scenes_on = true;
        const n = set.plates.items.len;
        const old_len = set.synced.items.len;
        try set.synced.resize(set.gpa, n);
        if (n > old_len) @memset(set.synced.items[old_len..], .{});
        const beds = try arena.alloc([2]f32, n);
        const items = try arena.alloc(Plan.Item, n);
        const a = set.plates.items[set.active];
        for (set.plates.items, beds, items, set.synced.items, 0..) |p, *bed, *item, *sy, i| {
            const s = &p.app.settings;
            bed.* = .{
                if (s.machine.bed_size_x > 0) @floatCast(s.machine.bed_size_x) else default_bed,
                if (s.machine.bed_size_y > 0) @floatCast(s.machine.bed_size_y) else default_bed,
            };
            const st = set.statusOf(p);
            var flags: u32 = 0;
            if (st == .stale or st == .slicing) flags |= flag_stale;
            if (std.mem.eql(u8, s.machine.model, a.app.settings.machine.model) and std.mem.eql(u8, s.machine.name, a.app.settings.machine.name)) flags |= flag_bed_model;
            if (st == .cannot or st == .failed) flags |= flag_disabled;
            item.* = .{ .clear = false, .flags = flags, .outline = null, .scene = null };
            if (sy.id != p.id) {
                item.clear = i != set.active and sy.id != 0;
                sy.* = .{ .id = p.id };
            }
            if (i == set.active) {
                // The view draws the active plate itself: its beads as
                // another plate go.
                sy.scene = 0;
                sy.outline = 0;
                continue;
            }
            if (st == .cannot or st == .failed) {
                const boxes = try footprints(arena, p.app);
                const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(boxes)) | 1;
                if (boxes.len > 0 and sy.outline != key) {
                    item.outline = boxes;
                    sy.outline = key;
                    sy.scene = 0;
                }
                continue;
            }
            set.ensureScene(p);
            if (p.scene.len > 0 and sy.scene != p.scene_serial) {
                item.scene = p.scene;
                sy.scene = p.scene_serial;
                sy.outline = 0;
            }
        }
        return .{ .active = set.active, .beds = beds, .items = items };
    }

    /// The next sync gives all plates again (for a new view).
    pub fn resetSync(set: *Set) void {
        set.enter();
        defer set.leave();
        set.synced.clearRetainingCapacity();
    }
};

/// The box (x0, y0, x1, y1) of each part of an app on its bed.
fn footprints(arena: Allocator, app: *const App) Allocator.Error![]const [4]f32 {
    const parts = app.plate.parts.items;
    const out = try arena.alloc([4]f32, parts.len);
    for (parts, out) |q, *b| b.* = .{
        @floatCast(q.x - q.half[0]),
        @floatCast(q.y - q.half[1]),
        @floatCast(q.x + q.half[0]),
        @floatCast(q.y + q.half[1]),
    };
    return out;
}

// ---- tests ----

const testing = std.testing;

fn boxStl(gpa: Allocator, sx: f32, sy: f32, sz: f32) ![]u8 {
    var mesh = try zs.mesh.shapes.box(gpa, sx, sy, sz);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    errdefer stl.deinit();
    try mesh.writeStl(&stl.writer);
    return stl.toOwnedSlice();
}

/// A record of the events of a set, for the tests.
const Events = struct {
    plates: std.atomic.Value(u32) = .init(0),
    sliced: [8]std.atomic.Value(u32) = @splat(.init(0)),
    /// The order of the slices: the plate of each ZS_EVENT_SLICED.
    order: [16]usize = undefined,
    n_order: std.atomic.Value(usize) = .init(0),

    fn f(user: ?*anyopaque, plate: usize, event: c_int, _: f64, _: c_int) callconv(.c) void {
        const e: *Events = @ptrCast(@alignCast(user.?));
        if (event == event_plates) {
            _ = e.plates.fetchAdd(1, .monotonic);
        } else if (event == 2 and plate < e.sliced.len) {
            _ = e.sliced[plate].fetchAdd(1, .monotonic);
            const k = e.n_order.fetchAdd(1, .monotonic);
            if (k < e.order.len) e.order[k] = plate;
        }
    }
};

fn loadBox(set: *Set, i: usize, size: f32) !void {
    const stl = try boxStl(testing.allocator, size, size, 4);
    defer testing.allocator.free(stl);
    try set.appOf(i).?.loadStl("box.stl", stl);
    try set.changed(i, false);
}

test "plate set: add, select, remove, keep the active plate, and the ids" {
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, false);
    defer set.destroy();
    try testing.expectEqual(@as(usize, 1), set.count());
    const id0 = set.info(0).?.id;
    try testing.expectEqual(Status.empty, set.info(0).?.status);
    try set.appOf(0).?.setSetting("machine.bed_size_x", "300");

    // A new plate: after the others, active, with the settings of the
    // active plate, and a new id.
    try testing.expectEqual(@as(usize, 1), try set.add());
    try testing.expectEqual(@as(usize, 1), set.activeIndex());
    const second = set.info(1).?;
    try testing.expect(second.id != id0);
    try testing.expectEqual(@as(f64, 300), second.bed_x);
    try testing.expectEqualStrings("Plate 2", second.name);
    try testing.expect(ev.plates.load(.monotonic) > 0);

    _ = try set.add();
    try set.select(0);
    try testing.expectEqual(@as(usize, 0), set.activeIndex());
    try testing.expectError(error.OutOfRange, set.select(3));

    // Remove a plate before the active plate, then the active plate.
    try set.select(2);
    const id2 = set.info(2).?.id;
    try set.remove(0);
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(usize, 1), set.activeIndex());
    try testing.expectEqual(id2, set.info(1).?.id);
    try set.remove(1);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(usize, 0), set.activeIndex());

    // The active plate goes: the plate on its left becomes active, or the
    // first plate if it was the first.
    _ = try set.add();
    _ = try set.add();
    const left = set.info(1).?.id;
    try set.remove(2);
    try testing.expectEqual(@as(usize, 1), set.activeIndex());
    try testing.expectEqual(left, set.info(1).?.id);
    try set.select(0);
    const right = set.info(1).?.id;
    try set.remove(0);
    try testing.expectEqual(@as(usize, 0), set.activeIndex());
    try testing.expectEqual(right, set.info(0).?.id);
    try set.remove(0);

    // Keep the active plate alone.
    _ = try set.add();
    _ = try set.add();
    try set.select(1);
    const kept = set.info(1).?.id;
    set.keepActive();
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(usize, 0), set.activeIndex());
    try testing.expectEqual(kept, set.info(0).?.id);

    // The last plate stays when it is removed, with no parts.
    try loadBox(set, 0, 10);
    try set.remove(0);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(usize, 0), set.info(0).?.part_count);
    try testing.expectEqual(Status.empty, set.info(0).?.status);
    try testing.expectEqualStrings("", set.info(0).?.name);
}

test "plate set: the active plate slices first, then the others" {
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, false);
    defer set.destroy();
    try loadBox(set, 0, 10);
    _ = try set.add();
    try loadBox(set, 1, 12);
    _ = try set.add();
    try loadBox(set, 2, 14);
    try testing.expectEqual(Status.stale, set.info(0).?.status);
    // Plate 1 is active: it slices first, then 0 and 2 in order.
    try set.select(1);
    try testing.expectEqual(@as(?usize, 1), set.next());
    while (set.step()) {}
    try testing.expectEqual(@as(usize, 3), ev.n_order.load(.monotonic));
    try testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, ev.order[0..3]);
    for (0..3) |i| try testing.expectEqual(Status.done, set.info(i).?.status);

    // A change of another plate, then of the active plate: the active
    // plate first.
    try set.changed(0, false);
    try set.changed(1, false);
    try testing.expectEqual(Status.stale, set.info(0).?.status);
    try testing.expectEqual(@as(?usize, 1), set.next());
    try testing.expect(set.step());
    try testing.expectEqual(@as(?usize, 0), set.next());
    try testing.expect(set.step());
    try testing.expect(!set.step());

    // A plate with no parts does not slice.
    try set.appOf(2).?.clearPlate();
    try set.changed(2, false);
    try testing.expectEqual(Status.empty, set.info(2).?.status);
    try testing.expectEqual(@as(?usize, null), set.next());
}

test "plate set: a held change slices once, at the release" {
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, false);
    defer set.destroy();
    try loadBox(set, 0, 10);
    while (set.step()) {}
    const before = ev.sliced[0].load(.monotonic);
    const app = set.appOf(0).?;
    for (0..5) |k| {
        try app.movePart(0, 50 + @as(f64, @floatFromInt(k)), 60);
        try set.changed(0, true);
        try testing.expectEqual(@as(?usize, null), set.next());
    }
    set.releaseHeld();
    try testing.expectEqual(@as(?usize, 0), set.next());
    while (set.step()) {}
    try testing.expectEqual(before + 1, ev.sliced[0].load(.monotonic));
    // A release with no held change does nothing.
    set.releaseHeld();
    try testing.expectEqual(@as(?usize, null), set.next());
}

/// A scene function for the tests: the bytes say the slice and the mode.
fn testScene(gpa: Allocator, app: *const App, mode: u32) ?[]u8 {
    return std.fmt.allocPrint(gpa, "scene {d} {d}", .{ app.done_count.load(.acquire), mode }) catch null;
}

test "plate set: a view sync gives flags, footprints, scenes, and clears by id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try Set.create(testing.allocator, null, null, false);
    defer set.destroy();
    set.scene_fn = testScene;
    try loadBox(set, 0, 10);
    _ = try set.add();
    try loadBox(set, 1, 12);
    try set.appOf(1).?.setSetting("machine.bed_size_x", "300");
    try set.select(0);

    // Plate 1 waits: stale, and no scene yet.
    var plan = try set.sync(arena);
    try testing.expectEqual(@as(usize, 0), plan.active);
    try testing.expectEqual(@as(f32, 300), plan.beds[1][0]);
    try testing.expect(plan.items[1].flags & flag_stale != 0);
    try testing.expect(plan.items[1].flags & flag_bed_model != 0);
    try testing.expect(plan.items[1].scene == null);
    try testing.expect(!plan.items[1].clear);

    while (set.step()) {}
    plan = try set.sync(arena);
    try testing.expectEqual(@as(u32, 0), plan.items[1].flags & flag_stale);
    try testing.expectEqualStrings("scene 1 0", plan.items[1].scene.?);
    // Once: the next sync has no new scene.
    plan = try set.sync(arena);
    try testing.expect(plan.items[1].scene == null);
    // A new color mode makes the scene again.
    set.setMode(2);
    plan = try set.sync(arena);
    try testing.expectEqualStrings("scene 1 2", plan.items[1].scene.?);

    // Another printer: no bed model on that plate.
    try set.appOf(1).?.setSetting("machine.name", "other");
    plan = try set.sync(arena);
    try testing.expectEqual(@as(u32, 0), plan.items[1].flags & flag_bed_model);

    // The plate that was active is another plate in the view now: its
    // scene, from the slice it had.
    try set.select(1);
    plan = try set.sync(arena);
    try testing.expectEqual(@as(usize, 1), plan.active);
    try testing.expectEqualStrings("scene 1 2", plan.items[0].scene.?);

    // Another plate at place 0 (a remove): it clears, and its scene comes.
    _ = try set.add();
    try loadBox(set, 2, 8);
    while (set.step()) {}
    try set.select(1);
    try set.remove(0);
    plan = try set.sync(arena);
    try testing.expectEqual(@as(usize, 0), plan.active);
    try testing.expect(plan.items[1].clear);
    try testing.expect(plan.items[1].scene != null);

    // A plate that cannot slice: disabled, with the footprints of its
    // parts, once.
    set.plates.items[1].cannot = true;
    plan = try set.sync(arena);
    try testing.expect(plan.items[1].flags & flag_disabled != 0);
    try testing.expectEqual(@as(usize, 1), plan.items[1].outline.?.len);
    const box = plan.items[1].outline.?[0];
    try testing.expectApproxEqAbs(@as(f32, 8), box[2] - box[0], 0.01);
    plan = try set.sync(arena);
    try testing.expect(plan.items[1].outline == null);
}

const test_stack = [_][2][]const u8{
    .{ "profiles/fdm/cura.json",
    \\{"cura": "5.13.0", "machine": "test_printer", "extruder": "test_extruder",
    \\ "profiles": {"pla": {"quality_changes": "q.inst.cfg"}},
    \\ "materials": {"roll-1": {"file": "materials/navy.xml.fdm_material"}}}
    },
    .{ "profiles/fdm/definitions/test_printer.def.json",
    \\{"name": "Test Printer", "inherits": "fdmprinter", "overrides": {
    \\  "machine_width": {"default_value": 280}, "machine_depth": {"default_value": 250}}}
    },
    .{ "profiles/fdm/definitions/test_extruder.def.json",
    \\{"name": "Extruder", "inherits": "fdmextruder", "overrides": {
    \\  "machine_nozzle_size": {"default_value": 0.4}}}
    },
    .{ "profiles/fdm/q.inst.cfg",
    \\[values]
    \\layer_height = 0.2
    },
    .{ "profiles/fdm/materials/navy.xml.fdm_material",
    \\<fdmmaterial><metadata><name><brand>Acme</brand><material>PLA</material><color>Navy</color></name></metadata>
    \\<properties><density>1.24</density><diameter>1.75</diameter></properties>
    \\<settings><setting key="print temperature">210</setting></settings></fdmmaterial>
    },
};

const test_yml =
    \\project: test
    \\parts:
    \\  - name: Cube
    \\    files: [models/cube.stl]
    \\    count: 2
    \\    printer: taz
    \\    profile: fdm/pla
    \\    material: roll-1
    \\  - name: Ring
    \\    files: [models/ring.stl]
    \\    printer: phenom
    \\    profile: resin/standard
    \\    count: 3
;

test "plate set: a project loads all plates, and a resin plate cannot slice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try Set.create(testing.allocator, null, null, false);
    defer set.destroy();
    set.scene_fn = testScene;
    var files: project.Files = .init(testing.allocator);
    defer files.deinit();
    for (test_stack) |f| try files.add(f[0], f[1]);
    const cube = try boxStl(testing.allocator, 20, 20, 5);
    defer testing.allocator.free(cube);
    const ring = try boxStl(testing.allocator, 15, 10, 3);
    defer testing.allocator.free(ring);
    try files.add("models/cube.stl", cube);
    try files.add("models/ring.stl", ring);

    var diag: project.Diagnostic = .{};
    try set.projectLoad(&files, test_yml, "", 0, &diag, arena);
    try testing.expectEqual(@as(usize, 2), set.count());
    const fdm = set.info(0).?;
    try testing.expectEqualStrings("Cube", fdm.name);
    try testing.expectEqual(Status.stale, fdm.status);
    try testing.expectEqual(@as(usize, 2), fdm.part_count);
    try testing.expectEqual(@as(f64, 280), fdm.bed_x);
    try testing.expectEqualStrings("", fdm.message);
    const resin = set.info(1).?;
    try testing.expectEqual(Status.cannot, resin.status);
    try testing.expectEqual(@as(usize, 3), resin.part_count);

    // The resin plate never slices; the other plate does.
    try testing.expectEqual(@as(?usize, 0), set.next());
    while (set.step()) {}
    try testing.expectEqual(Status.done, set.info(0).?.status);
    try testing.expectEqual(Status.cannot, set.info(1).?.status);
    try set.changed(1, false);
    try testing.expectEqual(@as(?usize, null), set.next());

    // The view: the footprints of the resin plate.
    const plan = try set.sync(arena);
    try testing.expectEqual(@as(usize, 3), plan.items[1].outline.?.len);

    // A second load replaces the plates, with new ids.
    const old_id = set.info(0).?.id;
    try set.projectLoad(&files, test_yml, "1,0", 0, &diag, arena);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(set.info(0).?.id != old_id);
    try testing.expectEqual(@as(usize, 1), set.info(0).?.part_count);
    // An error of the yml: the set stays.
    try testing.expectError(error.BadProject, set.projectLoad(&files, "parts: [", "", 0, &diag, arena));
    try testing.expectEqual(@as(usize, 1), set.count());
}

test "plate set: auto mode slices the active plate, then the others, on threads" {
    if (!parallel.has_threads) return error.SkipZigTest;
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, true);
    defer set.destroy();
    try loadBox(set, 0, 10);
    _ = try set.add();
    try loadBox(set, 1, 12);
    try set.select(0);
    // Wait for both slices.
    var tries: usize = 0;
    while (tries < 2000) : (tries += 1) {
        if (set.info(0).?.status == .done and set.info(1).?.status == .done) break;
        var sig: parallel.Signal = .{};
        sig.wait(0);
    }
    try testing.expectEqual(Status.done, set.info(0).?.status);
    try testing.expectEqual(Status.done, set.info(1).?.status);
    try testing.expect(ev.n_order.load(.monotonic) >= 2);
}

test "plate set: move a part to a new plate and back" {
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, false);
    defer set.destroy();
    const app0 = set.appOf(0).?;
    try app0.setSetting("machine.bed_size_x", "250");
    var b: zs.mesh.Builder = .init(testing.allocator);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 20, 20, 10);
    var m = try b.finish();
    defer m.deinit(testing.allocator);
    var stl: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    _ = try app0.addStl("a", stl.written());
    _ = try app0.addStl("b", stl.written());
    try testing.expectEqual(@as(usize, 2), app0.plate.count());
    // To a new plate: it has the settings of plate 0, and the part.
    const t = try set.movePart(0, 1, null);
    try testing.expectEqual(@as(usize, 1), t);
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(usize, 0), set.activeIndex());
    try testing.expectEqual(@as(usize, 1), app0.plate.count());
    const app1 = set.appOf(1).?;
    try testing.expectEqual(@as(usize, 1), app1.plate.count());
    try testing.expectEqual(@as(f64, 250), app1.settings.machine.bed_size_x);
    // Back to plate 0.
    try testing.expectEqual(@as(usize, 0), try set.movePart(1, 0, 0));
    try testing.expectEqual(@as(usize, 2), app0.plate.count());
    try testing.expectEqual(@as(usize, 0), app1.plate.count());
    try testing.expectError(error.OutOfRange, set.movePart(0, 0, 0));
}

test "plate set: fill copies over plates" {
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, false);
    defer set.destroy();
    const app0 = set.appOf(0).?;
    try app0.setSetting("machine.bed_size_x", "100");
    try app0.setSetting("machine.bed_size_y", "100");
    var b: zs.mesh.Builder = .init(testing.allocator);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 30, 30, 5);
    var m = try b.finish();
    defer m.deinit(testing.allocator);
    var stl: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    _ = try app0.addStl("square", stl.written());
    // About 4 to 9 squares of 30 mm fit a bed of 100 mm: 20 need more plates.
    const f = try set.fill(0, 0, 20);
    try testing.expectEqual(@as(usize, 20), f.copies);
    try testing.expect(f.plates >= 2);
    var total: usize = 0;
    for (0..set.count()) |i| {
        const a = set.appOf(i).?;
        total += a.plate.count();
        try testing.expect(a.plate.allFit(a.bedSize(), a.partGap()));
        try testing.expectEqual(@as(f64, 100), a.settings.machine.bed_size_x);
    }
    try testing.expectEqual(@as(usize, 20), total);
    try testing.expectEqual(@as(usize, 0), set.activeIndex());
}


test "plate set: a session brings back the plates, the camera, and the app text" {
    const session = @import("session.zig");
    var ev: Events = .{};
    const set = try Set.create(testing.allocator, Events.f, &ev, false);
    defer set.destroy();
    _ = try set.add();
    try set.setName(1, "Second");
    try set.appOf(1).?.setSetting("project.infill_density", "0.35");
    const cam = [8]f32{ 1, 2, 3, 0, 0, 0, 1, 250 };
    const bytes = try session.write(testing.allocator, set, cam, "panel=settings;scroll=120");
    defer testing.allocator.free(bytes);
    const back = try Set.create(testing.allocator, Events.f, &ev, false);
    defer back.destroy();
    var diag: @import("project_file.zig").Diagnostic = .{};
    const r = try session.read(testing.allocator, bytes, back, &diag);
    defer testing.allocator.free(r.app_text);
    try testing.expectEqual(@as(usize, 2), back.count());
    try testing.expectEqualStrings("Second", back.info(1).?.name);
    try testing.expectEqual(@as(f64, 0.35), back.appOf(1).?.settings.project.infill_density);
    try testing.expectEqual(cam, r.camera.?);
    try testing.expectEqualStrings("panel=settings;scroll=120", r.app_text);
}
