//! The C API of the plate set, the `zs_set_*` functions of
//! `include/zslice-app.h`. See src/app/plate_set.zig. The rules of the API
//! are in c_api.zig.
//!
//! This file also has the part of the set that needs the renderer: the
//! scene bytes of a plate (render/view.zig appScene), and a sync of the
//! plates to a view. A sync goes to a view directly (zs_set_view_sync),
//! or as bytes (zs_set_sync_write) to a view in another wasm instance
//! (zs_view_sync_read): the web app slices in a worker and draws on the
//! page.
//!
//! The bytes of a sync, all little-endian:
//!
//!   u32 magic "ZSPS", u32 n, u32 active, u32 0
//!   n times: f32 bed_x, f32 bed_y, u32 flags, u32 clear, u32 n_boxes,
//!            u32 scene_len, then n_boxes x 4 f32 (x0, y0, x1, y1), then
//!            the scene bytes; each part starts at a multiple of 8.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const view_api = @import("view.zig");
const Status = c.Status;
const status = c.status;
const ok = c.ok;
const gpa = c.gpa;
const App = zs.app.App;
const plate_set = zs.app.plate_set;
const Set = plate_set.Set;
const project = zs.project;
const render_on = view_api.render_on;
const View = view_api.view_mod.View;

pub const PlateInfo = extern struct {
    id: u64,
    status: c_int,
    bed_x: f64,
    bed_y: f64,
    name: [*:0]const u8,
    printer_key: [*:0]const u8,
    part_count: usize,
    message: [*:0]const u8,
};

/// The scene of an app for the set: a view with no GPU.
fn sceneOf(alloc: std.mem.Allocator, app: *const App, mode: u32) ?[]u8 {
    if (comptime !render_on) return null;
    const m: view_api.view_mod.Mode = if (mode <= 5) @enumFromInt(mode) else .print;
    return View.appScene(alloc, app, m) catch null;
}

fn newSet(event_fn: ?plate_set.EventFn, user: ?*anyopaque, auto: bool, out: ?*?*Set) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const set = Set.create(gpa, event_fn, user, auto) catch |e| return status(e);
    set.scene_fn = sceneOf;
    o.* = set;
    return ok;
}

/// A set in auto mode (with threads): the core starts each slice.
export fn zs_set_new(event_fn: ?plate_set.EventFn, user: ?*anyopaque, out: ?*?*Set) c_int {
    return newSet(event_fn, user, true, out);
}

/// wasm: the events go to the import env.zs_web_set_event of the module.
/// The set is in manual mode: the shell calls zs_set_step.
const web_events = struct {
    extern "env" fn zs_web_set_event(plate: usize, event: c_int, progress: f64, st: c_int) void;
    fn forward(_: ?*anyopaque, plate: usize, event: c_int, progress: f64, st: c_int) callconv(.c) void {
        zs_web_set_event(plate, event, progress, st);
    }
    fn new(out: ?*?*Set) callconv(.c) c_int {
        return newSet(forward, null, false, out);
    }
};

comptime {
    if (c.is_wasm) @export(&web_events.new, .{ .name = "zs_set_new_web" });
}

export fn zs_set_free(set: ?*Set) void {
    const s = set orelse return;
    s.destroy();
}

export fn zs_set_count(set: ?*Set) usize {
    const s = set orelse return 0;
    return s.count();
}

export fn zs_set_active(set: ?*Set) usize {
    const s = set orelse return 0;
    return s.activeIndex();
}

export fn zs_set_app(set: ?*Set, i: usize) ?*App {
    const s = set orelse return null;
    return s.appOf(i);
}

/// A new empty plate; it becomes the active plate. Returns its index, or
/// a negative status.
export fn zs_set_add(set: ?*Set) isize {
    const s = set orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const i = s.add() catch |e| return -@as(isize, status(e));
    return @intCast(i);
}

export fn zs_set_select(set: ?*Set, i: usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.select(i) catch |e| return status(e);
    return ok;
}

export fn zs_set_remove(set: ?*Set, i: usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.remove(i) catch |e| return status(e);
    return ok;
}

export fn zs_set_keep_active(set: ?*Set) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.keepActive();
    return ok;
}

/// The facts of plate i. The strings stay valid until the next
/// zs_set_plate_info of the same plate, or a change of the list.
export fn zs_set_plate_info(set: ?*Set, i: usize, out: ?*PlateInfo) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const info = s.info(i) orelse return @intFromEnum(Status.out_of_range);
    o.* = .{
        .id = info.id,
        .status = @intFromEnum(info.status),
        .bed_x = info.bed_x,
        .bed_y = info.bed_y,
        .name = info.name.ptr,
        .printer_key = info.printer_key.ptr,
        .part_count = info.part_count,
        .message = info.message.ptr,
    };
    return ok;
}

/// The name of plate i for a list; NULL or "": the name of its model.
export fn zs_set_name(set: ?*Set, i: usize, name: ?[*:0]const u8) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.setName(i, if (name) |n| std.mem.span(n) else null) catch |e| return status(e);
    return ok;
}

export fn zs_set_changed(set: ?*Set, i: usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.changed(i, false) catch |e| return status(e);
    return ok;
}

export fn zs_set_changed_held(set: ?*Set, i: usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.changed(i, true) catch |e| return status(e);
    return ok;
}

export fn zs_set_release(set: ?*Set) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    s.releaseHeld();
    return ok;
}

/// The plate that zs_set_step slices next, or -1.
export fn zs_set_next(set: ?*Set) isize {
    const s = set orelse return -1;
    const i = s.next() orelse return -1;
    return @intCast(i);
}

/// Slices the next wanted plate on the calling thread. 1 if a plate
/// waited, 0 if none.
export fn zs_set_step(set: ?*Set) c_int {
    const s = set orelse return 0;
    return @intFromBool(s.step());
}

/// Loads all plates of a printdeck.yml (see Set.projectLoad). On an error
/// of the yml, the set does not change, and message (can be NULL) gets the
/// reason.
export fn zs_set_project_load(set: ?*Set, files: ?*const project.Files, yml: ?[*:0]const u8, counts: ?[*:0]const u8, active: usize, message: ?[*]u8, cap: usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const f = files orelse return @intFromEnum(Status.invalid_argument);
    const t = std.mem.span(yml orelse return @intFromEnum(Status.invalid_argument));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diag: project.Diagnostic = .{};
    if (message) |m| if (cap > 0) {
        m[0] = 0;
    };
    s.projectLoad(f, t, if (counts) |cs| std.mem.span(cs) else "", active, &diag, arena_state.allocator()) catch |e| {
        if (message) |m| if (cap > 0) {
            const text = if (diag.message.len > 0) diag.message else @errorName(e);
            const k = @min(text.len, cap - 1);
            @memcpy(m[0..k], text[0..k]);
            m[k] = 0;
        };
        return switch (e) {
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.invalid_value),
        };
    };
    return ok;
}

const project_file = @import("../app/project_file.zig");

fn sayMsg(message: ?[*]u8, cap: usize, text: []const u8) void {
    const m = message orelse return;
    if (cap == 0) return;
    const k = @min(text.len, cap - 1);
    @memcpy(m[0..k], text[0..k]);
    m[k] = 0;
}

/// All plates of the set as one project file (a 3MF file that other
/// slicers open as its first plate; see src/app/project_file.zig): the
/// parts, their places and settings, and the printer, the filament, and
/// the print settings of each plate. Free the bytes with zs_buffer_free.
export fn zs_set_project_save(set: ?*Set, name: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const bytes = s.saveProject(gpa, if (name) |n| std.mem.span(n) else "") catch |e| switch (e) {
        error.OutOfMemory => return @intFromEnum(Status.out_of_memory),
        error.WriteFailed => return @intFromEnum(Status.out_of_memory),
    };
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

/// 1 if the bytes are a project file of zslice (open it with
/// zs_set_project_open); 0 for another file (a plain 3MF: open it as a
/// model).
export fn zs_project_file_is(bytes: ?[*]const u8, len: usize) c_int {
    const b = bytes orelse return 0;
    return @intFromBool(project_file.isProject(gpa, b[0..len]));
}

/// Opens a project file: its plates replace the plates of the set, and the
/// active plate of the file becomes active. ZS_INVALID_VALUE with a
/// message for a bad file; the set stays as it was. A message can also
/// come with ZS_OK (a plate that did not load fully).
export fn zs_set_project_open(set: ?*Set, bytes: ?[*]const u8, len: usize, message: ?[*]u8, cap: usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const b = bytes orelse return @intFromEnum(Status.invalid_argument);
    sayMsg(message, cap, "");
    var diag: project_file.Diagnostic = .{};
    s.openProject(b[0..len], &diag) catch |e| {
        sayMsg(message, cap, if (diag.message.len > 0) diag.message else switch (e) {
            error.NotProject => "The file is not a zslice project.",
            else => @errorName(e),
        });
        return switch (e) {
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.invalid_value),
        };
    };
    sayMsg(message, cap, diag.message);
    return ok;
}

pub const Totals = extern struct {
    plates: usize,
    sliced: usize,
    missing: usize,
    parts: usize,
    time_s: f64,
    filament_g: f64,
    filament_mm: f64,
    cost_filament: f64,
    cost_machine: f64,
    cost: f64,
};

fn totalsOut(t: plate_set.Set.Totals) Totals {
    return .{ .plates = t.plates, .sliced = t.sliced, .missing = t.missing, .parts = t.parts, .time_s = t.time_s, .filament_g = t.filament_g, .filament_mm = t.filament_mm, .cost_filament = t.cost_filament, .cost_machine = t.cost_machine, .cost = t.cost_filament + t.cost_machine };
}

/// The sums of the project: the plates with parts, how many have a slice,
/// the parts, the print time, the filament, and the cost (the filament at
/// filament.price_per_kg, and the time at machine.hour_rate, of each
/// plate). A plate with no slice yet counts in `missing`, not in the sums.
export fn zs_set_totals(set: ?*Set, out: ?*Totals) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = totalsOut(s.totals());
    return ok;
}

/// The same sums for plate i alone.
export fn zs_set_plate_totals(set: ?*Set, i: usize, out: ?*Totals) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = totalsOut(s.plateTotals(i) orelse return @intFromEnum(Status.out_of_range));
    return ok;
}

/// Moves part `part` of plate `from` to plate `to`, or to a new plate after
/// the others (to < 0, with the settings of plate `from`). The part keeps
/// its mesh, pose, scale, settings, and volumes, and goes to a free place.
/// One history step on each plate; both slice again. Returns the index of
/// the target plate, or -status.
export fn zs_set_part_move(set: ?*Set, from: usize, part: usize, to: isize) isize {
    const s = set orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const t: ?usize = if (to < 0) null else @intCast(to);
    const j = s.movePart(from, part, t) catch |e| return -@as(isize, switch (e) {
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    });
    return @intCast(j);
}

/// The color mode of the scenes of the set (enum zs_view_mode).
export fn zs_set_view_mode(set: ?*Set, mode: c_int) void {
    const s = set orelse return;
    s.setMode(@intCast(@max(mode, 0)));
}

/// The scene bytes of plate i (for zs_view_scene_read): its last slice, or
/// its old beads while it slices again. ZS_NO_RESULT if none. The bytes
/// stay valid until the next call of the set.
export fn zs_set_plate_scene(set: ?*Set, i: usize, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    if (comptime !render_on) return @intFromEnum(Status.not_supported);
    const bytes = s.scene(i) orelse return @intFromEnum(Status.no_result);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

/// The next sync gives all plates again: for a new view.
export fn zs_set_view_reset(set: ?*Set) void {
    const s = set orelse return;
    s.resetSync();
}

// ---- the bytes of a sync ----

const magic: u32 = 0x5350535a; // "ZSPS"

fn pad8(n: usize) usize {
    return std.mem.alignForward(usize, n, 8);
}

fn put32(buf: []u8, at: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[at.*..][0..4], v, .little);
    at.* += 4;
}

fn writePlan(alloc: std.mem.Allocator, plan: plate_set.Plan) std.mem.Allocator.Error![]u8 {
    var size: usize = 16;
    for (plan.items) |it| {
        size += 24;
        size = pad8(size + (if (it.outline) |b| b.len * 16 else 0));
        size = pad8(size + (if (it.scene) |b| b.len else 0));
    }
    const buf = try alloc.alloc(u8, size);
    @memset(buf, 0);
    var at: usize = 0;
    put32(buf, &at, magic);
    put32(buf, &at, @intCast(plan.items.len));
    put32(buf, &at, @intCast(plan.active));
    put32(buf, &at, 0);
    for (plan.items, plan.beds) |it, bed| {
        put32(buf, &at, @bitCast(bed[0]));
        put32(buf, &at, @bitCast(bed[1]));
        put32(buf, &at, it.flags);
        put32(buf, &at, @intFromBool(it.clear));
        const boxes = it.outline orelse &.{};
        const scene = it.scene orelse "";
        put32(buf, &at, @intCast(boxes.len));
        put32(buf, &at, @intCast(scene.len));
        for (boxes) |b| for (b) |x| put32(buf, &at, @bitCast(x));
        at = pad8(at);
        @memcpy(buf[at..][0..scene.len], scene);
        at = pad8(at + scene.len);
    }
    return buf;
}

/// The changes for the view of the page since the last sync, as bytes
/// for zs_view_sync_read. Free them with zs_buffer_free.
export fn zs_set_sync_write(set: ?*Set, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = s.sync(arena_state.allocator()) catch |e| return status(e);
    const bytes = writePlan(gpa, plan) catch |e| return status(e);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

/// A plan from the bytes of zs_set_sync_write. The slices point into
/// `data`, except the beds and the boxes (in `arena`).
fn readPlan(arena: std.mem.Allocator, data: []const u8) (std.mem.Allocator.Error || error{InvalidScene})!plate_set.Plan {
    const R = struct {
        d: []const u8,
        at: usize = 0,
        fn u32_(r: *@This()) error{InvalidScene}!u32 {
            if (r.at + 4 > r.d.len) return error.InvalidScene;
            const v = std.mem.readInt(u32, r.d[r.at..][0..4], .little);
            r.at += 4;
            return v;
        }
        fn f32_(r: *@This()) error{InvalidScene}!f32 {
            return @bitCast(try r.u32_());
        }
    };
    var r: R = .{ .d = data };
    if (try r.u32_() != magic) return error.InvalidScene;
    const n = try r.u32_();
    const active = try r.u32_();
    _ = try r.u32_();
    if (n > 4096) return error.InvalidScene;
    const beds = try arena.alloc([2]f32, n);
    const items = try arena.alloc(plate_set.Plan.Item, n);
    for (beds, items) |*bed, *it| {
        bed.* = .{ try r.f32_(), try r.f32_() };
        const flags = try r.u32_();
        const clear = try r.u32_() != 0;
        const nb = try r.u32_();
        const sl = try r.u32_();
        if (nb > data.len / 16) return error.InvalidScene;
        const boxes = try arena.alloc([4]f32, nb);
        for (boxes) |*b| b.* = .{ try r.f32_(), try r.f32_(), try r.f32_(), try r.f32_() };
        r.at = pad8(r.at);
        if (r.at + sl > data.len) return error.InvalidScene;
        it.* = .{
            .clear = clear,
            .flags = flags,
            .outline = if (nb > 0) boxes else null,
            .scene = if (sl > 0) data[r.at..][0..sl] else null,
        };
        r.at = pad8(r.at + sl);
    }
    return .{ .active = active, .beds = beds, .items = items };
}

/// Applies a sync to a view: the row of the beds, then the clears, the
/// flags, the footprints, and the scenes of the other plates.
fn applyPlan(v: *View, plan: plate_set.Plan) !void {
    try v.setPlates(plan.beds, plan.active);
    for (plan.items, 0..) |it, i| {
        if (it.clear) v.clearPlate(i);
        try v.setPlateFlags(i, it.flags);
        if (it.outline) |b| try v.setPlateOutline(i, b);
        if (it.scene) |bytes| try v.readPlateScene(i, bytes);
    }
}

/// Applies the bytes of zs_set_sync_write to a view.
export fn zs_view_sync_read(view: ?*View, data: ?[*]const u8, len: usize) c_int {
    if (comptime !render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = readPlan(arena_state.allocator(), d[0..len]) catch |e| return status(e);
    applyPlan(v, plan) catch |e| return status(e);
    return ok;
}

/// Brings a view in this instance up to date with the set (see
/// Set.sync), in the color mode of the view.
export fn zs_set_view_sync(set: ?*Set, view: ?*View) c_int {
    if (comptime !render_on) return @intFromEnum(Status.not_supported);
    const s = set orelse return @intFromEnum(Status.invalid_argument);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    s.setMode(@intCast(@intFromEnum(v.mode)));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = s.sync(arena_state.allocator()) catch |e| return status(e);
    applyPlan(v, plan) catch |e| return status(e);
    return ok;
}

// ---- tests ----

const testing = std.testing;

test "C API: a set of plates, and a sync as bytes" {
    var set: ?*Set = null;
    try testing.expectEqual(ok, newSet(null, null, false, &set));
    defer zs_set_free(set);
    try testing.expectEqual(@as(usize, 1), zs_set_count(set));
    var mesh = try zs.mesh.shapes.box(gpa, 20, 20, 5);
    defer mesh.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    const a0 = zs_set_app(set, 0).?;
    try a0.loadStl("box.stl", stl.written());
    try testing.expectEqual(ok, zs_set_changed(set, 0));
    try testing.expectEqual(@as(isize, 1), zs_set_add(set));
    try zs_set_app(set, 1).?.loadStl("box.stl", stl.written());
    try testing.expectEqual(ok, zs_set_changed(set, 1));
    try testing.expectEqual(@as(isize, 1), zs_set_next(set));
    while (zs_set_step(set) == 1) {}
    try testing.expectEqual(@as(isize, -1), zs_set_next(set));

    var info: PlateInfo = undefined;
    try testing.expectEqual(ok, zs_set_plate_info(set, 0, &info));
    try testing.expectEqual(@as(c_int, @intFromEnum(plate_set.Status.done)), info.status);
    try testing.expectEqualStrings("box.stl", std.mem.span(info.name));
    try testing.expectEqual(ok, zs_set_name(set, 0, "Feet"));
    try testing.expectEqual(ok, zs_set_plate_info(set, 0, &info));
    try testing.expectEqualStrings("Feet", std.mem.span(info.name));

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(ok, zs_set_sync_write(set, &ptr, &len));
    defer gpa.free(ptr.?[0..len]);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try readPlan(arena_state.allocator(), ptr.?[0..len]);
    try testing.expectEqual(@as(usize, 2), plan.items.len);
    try testing.expectEqual(@as(usize, 1), plan.active);
    try testing.expectEqual(@as(u32, plate_set.flag_bed_model), plan.items[0].flags);
    if (render_on) {
        // The scene of plate 0 reads as a scene.
        try testing.expect(plan.items[0].scene != null);
        var t: View = .{ .renderer = undefined, .headless = true, .width = 1, .height = 1 };
        try t.setPlates(plan.beds, plan.active);
        try t.readPlateScene(0, plan.items[0].scene.?);
        t.deinitData();
    }
}
