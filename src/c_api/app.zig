//! The C API of the app core: `include/zslice-app.h`, without the 3D
//! view. Each function checks its pointers and calls `App` (src/app.zig).
//! The rules of the API are in c_api.zig.

const std = @import("std");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const status = c.status;
const ok = c.ok;
const Stats = c.Stats;
const cStats = c.cStats;
const gpa = c.gpa;
const Writer = std.Io.Writer;

const app_mod = zs.app;
const App = app_mod.App;

/// Notes a change for the undo list (see app/history.zig): the name of one
/// setting, or null for more; `plate`: the plate changed.
fn noted(app: *App, key: ?[]const u8, plate: bool) void {
    app.undo.note(app.gpa, key, plate);
}

export fn zs_app_new(event_fn: ?app_mod.EventFn, user: ?*anyopaque, out: ?*?*App) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = App.create(gpa, event_fn, user) catch |e| return status(e);
    return ok;
}

/// wasm: the host cannot give a C function pointer, so the events go to the
/// import env.zs_web_event of the module. A slice runs on the calling
/// thread there, so the events come while zs_app_slice runs.
const web_events = struct {
    extern "env" fn zs_web_event(event: c_int, progress: f64, status: c_int) void;
    fn forward(_: ?*anyopaque, event: c_int, progress: f64, st: c_int) callconv(.c) void {
        zs_web_event(event, progress, st);
    }
    fn new(out: ?*?*App) callconv(.c) c_int {
        return zs_app_new(forward, null, out);
    }
};

comptime {
    if (c.is_wasm) @export(&web_events.new, .{ .name = "zs_app_new_web" });
}

export fn zs_app_free(a: ?*App) void {
    const app = a orelse return;
    app.destroy();
}

/// Frees the memory of the app that only a faster next slice uses.
export fn zs_app_trim(a: ?*App) void {
    const app = a orelse return;
    app.trim();
}

export fn zs_app_state(a: ?*const App) c_int {
    const app = a orelse return 0;
    return @intFromEnum(app.getState());
}

export fn zs_app_load_stl(a: ?*App, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    const n = if (name) |p| std.mem.span(p) else "";
    app.loadStl(n, d[0..len]) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

pub const ModelInfo = extern struct {
    triangles: u64,
    size_x: f64,
    size_y: f64,
    size_z: f64,
};

export fn zs_app_model_info(a: ?*const App, out: ?*ModelInfo) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const info = app.modelInfo() orelse return @intFromEnum(Status.no_model);
    o.* = .{ .triangles = info.triangles, .size_x = info.size[0], .size_y = info.size[1], .size_z = info.size[2] };
    return ok;
}

pub const SettingInfo = extern struct {
    name: [*:0]const u8,
    group: [*:0]const u8,
    section: [*:0]const u8,
    label: [*:0]const u8,
    doc: [*:0]const u8,
    kind: c_int,
    multiline: c_int,
    choices: [*:0]const u8,
    unit: [*:0]const u8,
    default_value: [*:0]const u8,
    slider_min: f64,
    slider_max: f64,
    limit_min: f64,
    limit_max: f64,
    slider_step: f64,
    per_layer: c_int,
    per_part: c_int,
};

/// The text of a value of setting `name`, as an editor shows it (a ratio as
/// a percentage, a line width of 0 as "auto", the first line of a G-code);
/// with_unit != 0 adds the unit ("0.8 mm", "1 layer"). The same buffer
/// rules as zs_app_setting_get.
export fn zs_setting_display(name: ?[*:0]const u8, value: ?[*:0]const u8, with_unit: c_int, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const s = app_mod.setting_text.find(std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) orelse return @intFromEnum(Status.unknown_setting);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.setting_text.display(s, std.mem.span(value orelse return @intFromEnum(Status.invalid_argument)), with_unit != 0, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The core value of the text of an editor of setting `name` ("auto" is
/// 0, a percentage is a ratio). ZS_INVALID_VALUE: a number setting with a
/// text that is not a number. The same buffer rules as zs_app_setting_get.
export fn zs_setting_parse(name: ?[*:0]const u8, text: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const s = app_mod.setting_text.find(std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) orelse return @intFromEnum(Status.unknown_setting);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.setting_text.parse(s, std.mem.span(text orelse return @intFromEnum(Status.invalid_argument)), &aw.writer) catch |e| return switch (e) {
        error.InvalidValue => @intFromEnum(Status.invalid_value),
        else => @intFromEnum(Status.out_of_memory),
    };
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The source of a value as a short tag: level (enum zs_level), the name
/// of its profile, and its formula or NULL. "Global", the profile name,
/// "This print", "This part", or "= formula". The same buffer rules as
/// zs_app_setting_get.
export fn zs_setting_source_text(level: c_int, profile: ?[*:0]const u8, formula: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const f: ?[]const u8 = if (formula) |x| std.mem.span(x) else null;
    app_mod.setting_text.source(level, if (profile) |p| std.mem.span(p) else "", f, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The settings that match a search query, best first, at most max: their
/// indices (zs_setting_get_info) in out_index, and their scores in
/// out_score (either can be NULL). part_only != 0: only the settings that
/// a part can have of its own. Returns the count. The rules and the words
/// of other slicers are in src/app/setting_search.zig.
export fn zs_setting_search(query: ?[*:0]const u8, part_only: c_int, out_index: ?[*]u32, out_score: ?[*]f64, max: usize) usize {
    const q = std.mem.span(query orelse return 0);
    var buf: [512]zs.app.setting_search.Hit = undefined;
    const n = zs.app.setting_search.search(q, part_only != 0, buf[0..@min(max, buf.len)]);
    for (buf[0..n], 0..) |h, i| {
        if (out_index) |o| o[i] = h.index;
        if (out_score) |o| o[i] = h.score;
    }
    return n;
}

const PStatus = zs.app.printer_status.Status;

fn kindOf(kind: c_int) ?zs.app.printer_status.Kind {
    return switch (kind) {
        1 => .octoprint,
        2 => .printdeck,
        3 => .moonraker,
        else => null,
    };
}

/// The paths of the status of a printer of `kind` (1 OctoPrint, 2
/// printdeck, 3 Moonraker), one on each line, to GET in order. Static.
export fn zs_printer_status_paths(kind: c_int) [*:0]const u8 {
    const k = kindOf(kind) orelse return "";
    return zs.app.printer_status.paths(k).ptr;
}

/// A new, empty printer status. Free it with zs_printer_status_free.
export fn zs_printer_status_new() ?*PStatus {
    const s = gpa.create(PStatus) catch return null;
    s.* = .init(gpa);
    return s;
}

export fn zs_printer_status_free(s: ?*PStatus) void {
    const st = s orelse return;
    st.deinit();
    gpa.destroy(st);
}

/// Reads the reply of a path (see zs_printer_status_paths). A reply that is
/// not JSON changes nothing.
export fn zs_printer_status_feed(s: ?*PStatus, kind: c_int, path: ?[*:0]const u8, body: ?[*]const u8, len: usize) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const k = kindOf(kind) orelse return @intFromEnum(Status.invalid_argument);
    const b = body orelse return @intFromEnum(Status.invalid_argument);
    st.feed(k, std.mem.span(path orelse return @intFromEnum(Status.invalid_argument)), b[0..len]) catch return @intFromEnum(Status.out_of_memory);
    return ok;
}

pub const PrinterRoll = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    material: [*:0]const u8,
    color: [*:0]const u8,
    left: f64,
};

pub const PrinterInfo = extern struct {
    state: [*:0]const u8,
    bed_x: f64,
    bed_y: f64,
    height: f64,
    nozzle: f64,
    material: [*:0]const u8,
    diameter: f64,
    spool: PrinterRoll,
    spool_price: f64,
    spool_full: f64,
    roll_count: usize,
    max_velocity: f64,
    max_accel: f64,
    corner_velocity: f64,
    max_z_velocity: f64,
    max_z_accel: f64,
    job: [*:0]const u8,
    progress: f64,
    time_left: f64,
    layer: c_int,
    layers: c_int,
};

fn rollOut(r: zs.app.printer_status.Roll) PrinterRoll {
    return .{ .id = r.id.ptr, .name = r.name.ptr, .material = r.material.ptr, .color = r.color.ptr, .left = r.left };
}

/// The status read so far. The strings stay valid until the next feed or
/// the free.
export fn zs_printer_status_get(s: ?*const PStatus, out: ?*PrinterInfo) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = .{
        .state = st.state.ptr,
        .bed_x = st.bed_x,
        .bed_y = st.bed_y,
        .height = st.height,
        .nozzle = st.nozzle,
        .material = st.material.ptr,
        .diameter = st.diameter,
        .spool = rollOut(st.spool),
        .spool_price = st.spool_price,
        .spool_full = st.spool_full,
        .roll_count = st.rolls.len,
        .max_velocity = st.max_velocity,
        .max_accel = st.max_accel,
        .corner_velocity = st.corner_velocity,
        .max_z_velocity = st.max_z_velocity,
        .max_z_accel = st.max_z_accel,
        .job = st.job.ptr,
        .progress = st.progress,
        .time_left = st.time_left,
        .layer = st.layer,
        .layers = st.layers,
    };
    return ok;
}

/// Roll i of the printer (i < roll_count).
export fn zs_printer_status_roll(s: ?*const PStatus, i: usize, out: ?*PrinterRoll) c_int {
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= st.rolls.len) return @intFromEnum(Status.out_of_range);
    o.* = rollOut(st.rolls[i]);
    return ok;
}

/// Applies the status of a printer to the settings of the app. what: 1
/// the machine (the bed, the height, the nozzle, and the motion limits
/// that the printer gives, each only when known), 2 the filament (the
/// built-in profile of its material, the name of the roll, the diameter,
/// and the color), 3 both. A material with no built-in profile keeps the
/// profile, and sets only the name, the material, the diameter, and the
/// color. Noted in the history as one step.
export fn zs_app_apply_printer_status(a: ?*App, s: ?*const PStatus, what: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const st = s orelse return @intFromEnum(Status.invalid_argument);
    var buf: [64]u8 = undefined;
    const Num = struct {
        fn set(ap: *App, b: []u8, name: []const u8, v: f64) void {
            if (!(v > 0)) return;
            const t = std.fmt.bufPrint(b, "{d}", .{v}) catch return;
            ap.setSetting(name, t) catch {};
        }
    };
    if (what & 1 != 0) {
        Num.set(app, &buf, "machine.bed_size_x", st.bed_x);
        Num.set(app, &buf, "machine.bed_size_y", st.bed_y);
        Num.set(app, &buf, "machine.max_height", st.height);
        Num.set(app, &buf, "machine.nozzle_diameter", st.nozzle);
        // The motion limits, for a time estimate that matches the printer
        // (the speed of the print stays a setting of zslice).
        Num.set(app, &buf, "machine.max_accel", st.max_accel);
        Num.set(app, &buf, "machine.corner_speed", st.corner_velocity);
        Num.set(app, &buf, "machine.max_z_speed", st.max_z_velocity);
        Num.set(app, &buf, "machine.max_z_accel", st.max_z_accel);
    }
    if (what & 2 != 0) {
        const material = if (st.material.len > 0) st.material else st.spool.material;
        // The diameter belongs to the printer: a new base profile keeps it,
        // unless the printer gives one.
        const keep_diameter = app.settings.filament.diameter;
        if (material.len > 0 and material.len < 40) {
            var low: [40]u8 = undefined;
            const lower = std.ascii.lowerString(&low, material);
            var pb: [80]u8 = undefined;
            const text = std.fmt.bufPrint(&pb, "extends = \"generic-{s}\"\n", .{lower}) catch "";
            var diag: zs.profile.Diagnostic = .{};
            app.applyProfile(.filament, "saved", text, &diag) catch {};
            var up: [40]u8 = undefined;
            app.setSetting("filament.material", std.ascii.upperString(&up, material)) catch {};
        }
        const name = if (st.spool.name.len > 0) st.spool.name else material;
        if (name.len > 0) app.setSetting("filament.name", name) catch {};
        Num.set(app, &buf, "filament.diameter", if (st.diameter > 0) st.diameter else keep_diameter);
        const color = if (st.spool.color.len > 0) st.spool.color else "";
        if (color.len > 0) app.setSetting("filament.color", color) catch {};
    }
    noted(app, null, false);
    return ok;
}

/// 1 if a change line of a history step (zs_history_step.changes) can be
/// undone alone (zs_app_history_revert): not the quality, and not a move,
/// turn, orientation, or scale of a part.
export fn zs_history_revertible(line: ?[*]const u8, len: usize) c_int {
    const l = line orelse return 0;
    return @intFromBool(zs.app.history.revertible(l[0..len]));
}

export fn zs_setting_count() usize {
    return app_mod.settings_info.len;
}

export fn zs_setting_get_info(index: usize, out: ?*SettingInfo) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (index >= app_mod.settings_info.len) return @intFromEnum(Status.out_of_range);
    const s = app_mod.settings_info[index];
    o.* = .{
        .name = s.name.ptr,
        .group = s.group.ptr,
        .section = s.section.ptr,
        .label = s.label.ptr,
        .doc = s.doc.ptr,
        .kind = @intFromEnum(s.kind),
        .multiline = @intFromBool(s.multiline),
        .choices = s.choices.ptr,
        .unit = s.unit.ptr,
        .default_value = s.default_value.ptr,
        .slider_min = s.slider_min,
        .slider_max = s.slider_max,
        .limit_min = s.limit_min,
        .limit_max = s.limit_max,
        .slider_step = s.slider_step,
        .per_layer = @intFromBool(s.per_layer),
        .per_part = @intFromBool(zs.settings.isPerPartSetting(s.name)),
    };
    return ok;
}

/// Writes the value as text with a NUL at the end. If `cap` is too small,
/// the text is cut. `out_len` (can be NULL) gets the full length without
/// the NUL.
export fn zs_app_setting_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.getSetting(n, &aw.writer) catch |e| return status(e);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap > 0) {
            const k = @min(text.len, cap - 1);
            @memcpy(b[0..k], text[0..k]);
            b[k] = 0;
        }
    }
    return ok;
}

export fn zs_app_setting_set(a: ?*App, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    app.setSetting(n, v) catch |e| return status(e);
    noted(app, n, false);
    return ok;
}

export fn zs_app_slice(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.startSlice() catch |e| return status(e);
    return ok;
}

export fn zs_app_request_slice(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.requestSlice() catch |e| return status(e);
    return ok;
}

export fn zs_app_cancel(a: ?*App) void {
    const app = a orelse return;
    app.cancel();
}

/// The address of the cancel flag of the app (a byte: 1 stops the slice
/// that runs), or 0. On the web, the slice runs on the thread of the core
/// worker, so the worker cannot take a call while it slices; with a shared
/// memory, the page sets the byte with Atomics.store. A new slice sets it
/// back to 0.
export fn zs_app_cancel_address(a: ?*App) usize {
    const app = a orelse return 0;
    return @intFromPtr(&app.cancel_flag.raw);
}

export fn zs_app_stats(a: ?*const App, out: ?*Stats) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = cStats(app.result() orelse return @intFromEnum(Status.no_result));
    return ok;
}

/// The number of islands of the last slice (see islands.zig).
export fn zs_app_island_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.islands().len;
}

/// Island i: its layer, its place (mm), and its area (mm²).
export fn zs_app_island_get(a: ?*const App, i: usize, layer: ?*usize, x: ?*f64, y: ?*f64, area: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const all = app.islands();
    if (i >= all.len) return @intFromEnum(Status.invalid_argument);
    const isl = all[i];
    if (layer) |p| p.* = isl.layer;
    if (x) |p| p.* = isl.x;
    if (y) |p| p.* = isl.y;
    if (area) |p| p.* = isl.area;
    return ok;
}

/// Adds a support mark: kind 0 grid, 1 tree, 2 bridge (a pad), 3 block.
export fn zs_app_mark_add(a: ?*App, x: f64, y: f64, z: f64, r: f64, kind: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (kind < 0 or kind > 3 or !(r > 0)) return @intFromEnum(Status.invalid_argument);
    app.addMark(.{ .x = x, .y = y, .z = z, .r = r, .kind = @enumFromInt(@as(u8, @intCast(kind))) }) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// Removes the marks near a place. Returns how many.
export fn zs_app_mark_remove_near(a: ?*App, x: f64, y: f64, z: f64, r: f64) usize {
    const app = a orelse return 0;
    const n = app.removeMarksNear(x, y, z, r);
    if (n > 0) noted(app, null, true);
    return n;
}

export fn zs_app_mark_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.marks.items.len;
}

/// The support mark at a place (in its disk, on a layer within dz of z),
/// or -1.
export fn zs_app_mark_at(a: ?*const App, x: f64, y: f64, z: f64, dz: f64) isize {
    const app = a orelse return -1;
    return if (app.markAt(x, y, z, dz)) |i| @intCast(i) else -1;
}

/// Mark i: its place, its radius, and its kind (enum zs_mark_kind).
export fn zs_app_mark_get(a: ?*const App, i: usize, x: ?*f64, y: ?*f64, z: ?*f64, r: ?*f64, kind: ?*c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.marks.items.len) return @intFromEnum(Status.out_of_range);
    const m = app.marks.items[i];
    if (x) |o| o.* = m.x;
    if (y) |o| o.* = m.y;
    if (z) |o| o.* = m.z;
    if (r) |o| o.* = m.r;
    if (kind) |o| o.* = @intFromEnum(m.kind);
    return ok;
}

/// Changes the kind and the radius of mark i.
export fn zs_app_mark_set(a: ?*App, i: usize, kind: c_int, r: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (kind < 0 or kind > 3 or !(r > 0)) return @intFromEnum(Status.invalid_argument);
    app.setMark(i, @enumFromInt(@as(u8, @intCast(kind))), r) catch return @intFromEnum(Status.out_of_range);
    noted(app, null, true);
    return ok;
}

export fn zs_app_mark_remove(a: ?*App, i: usize) void {
    const app = a orelse return;
    app.removeMark(i);
    noted(app, null, true);
}

export fn zs_app_marks_clear(a: ?*App) void {
    const app = a orelse return;
    app.clearMarks();
    noted(app, null, true);
}

export fn zs_app_write_3mf(a: ?*App, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const b = app.write3mf() catch |e| return status(e);
    o.* = b.ptr;
    l.* = b.len;
    return ok;
}

/// The G-code of the last slice. The bytes stay valid until the next
/// slice, the next model, or zs_app_free.
export fn zs_app_gcode(a: ?*const App, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const g = app.gcode() orelse return @intFromEnum(Status.no_result);
    o.* = g.ptr;
    l.* = g.len;
    return ok;
}

export fn zs_app_layer_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.layerCount();
}

export fn zs_app_part_bounds(a: ?*const App, out: ?*[4]f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = app.partBounds() orelse return @intFromEnum(Status.no_result);
    return ok;
}

pub const LayerPaths = extern struct {
    points: [*]const f32,
    path_ends: [*]const u32,
    path_features: [*]const u8,
    path_closed: [*]const u8,
    path_count: usize,
    outline_points: [*]const f32,
    outline_ends: [*]const u32,
    outline_count: usize,
    z: f32,
    height: f32,
    width: f32,
    owner: ?*anyopaque,
};

export fn zs_app_layer_paths(a: ?*const App, layer: usize, out: ?*LayerPaths) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const lp = gpa.create(app_mod.LayerPaths) catch |e| return status(e);
    lp.* = app.layerPaths(gpa, layer) catch |e| {
        gpa.destroy(lp);
        return status(e);
    };
    o.* = .{
        .points = lp.points.ptr,
        .path_ends = lp.ends.ptr,
        .path_features = lp.features.ptr,
        .path_closed = lp.closed.ptr,
        .path_count = lp.ends.len,
        .outline_points = lp.outline_points.ptr,
        .outline_ends = lp.outline_ends.ptr,
        .outline_count = lp.outline_ends.len,
        .z = lp.z,
        .height = lp.height,
        .width = lp.width,
        .owner = lp,
    };
    return ok;
}

export fn zs_layer_paths_free(paths: ?*LayerPaths) void {
    const p = paths orelse return;
    const owner = p.owner orelse return;
    const lp: *app_mod.LayerPaths = @ptrCast(@alignCast(owner));
    lp.deinit();
    gpa.destroy(lp);
    p.owner = null;
}

pub const Toolpaths = extern struct {
    points: [*]const f32,
    path_ends: [*]const u32,
    path_features: [*]const u8,
    path_closed: [*]const u8,
    path_area: [*]const f32,
    path_end_time: [*]const f32,
    path_count: usize,
    layer_ends: [*]const u32,
    layer_z: [*]const f32,
    layer_height: [*]const f32,
    layer_width: [*]const f32,
    layer_count: usize,
    path_start_time: [*]const f32,
    path_retract: [*]const u8,
    z_hop: f32,
    layer_slowed: [*]const u8,
    path_z_start: [*]const u32,
    point_z: [*]const f32,
    point_area: [*]const f32,
    path_height: [*]const f32,
};

/// The paths of all layers, for a 3D view. The arrays stay valid until the
/// next slice, the next model, or zs_app_free.
export fn zs_app_toolpaths(a: ?*const App, out: ?*Toolpaths) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const t = app.allToolpaths() orelse return @intFromEnum(Status.no_result);
    o.* = .{
        .points = t.points.items.ptr,
        .path_ends = t.path_ends.items.ptr,
        .path_features = t.path_features.items.ptr,
        .path_closed = t.path_closed.items.ptr,
        .path_area = t.path_area.items.ptr,
        .path_end_time = t.path_end_time.items.ptr,
        .path_count = t.path_ends.items.len,
        .layer_ends = t.layer_ends.items.ptr,
        .layer_z = t.layer_z.items.ptr,
        .layer_height = t.layer_height.items.ptr,
        .layer_width = t.layer_width.items.ptr,
        .layer_count = t.layer_ends.items.len,
        .path_start_time = t.path_start_time.items.ptr,
        .path_retract = t.path_retract.items.ptr,
        .z_hop = t.z_hop,
        .layer_slowed = t.layer_slowed.items.ptr,
        .path_z_start = t.path_z_start.items.ptr,
        .point_z = t.point_z.items.ptr,
        .point_area = t.point_area.items.ptr,
        .path_height = t.path_height.items.ptr,
    };
    return ok;
}

pub const Inspect = extern struct {
    feature: c_int,
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
    title: [*:0]const u8,
    explain: [*:0]const u8,
    settings: [*:0]const u8,
    why_planned: [*:0]const u8,
    why_real: [*:0]const u8,
    why_flow: [*:0]const u8,
    slow_reason: c_int,
    /// The sentence of slow_reason, or "".
    slow_text: [*:0]const u8,
};

/// The printability check of the last slice: the issues, the worst
/// first, and the text that they point into. Valid until the next slice.
export fn zs_app_checks(a: ?*App, issues: ?*?[*]const zs.app.checks_mod.Issue, n: ?*usize, text: ?*?[*]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = app.checks() catch |e| return switch (e) {
        error.NoResult => @intFromEnum(Status.no_result),
        else => status(e),
    };
    if (issues) |o| o.* = r.issues.ptr;
    if (n) |o| o.* = r.issues.len;
    if (text) |o| o.* = r.text.ptr;
    return ok;
}

/// The number of built-in profiles of a group (enum zs_group).
export fn zs_builtin_profile_count(group: c_int) usize {
    var n: usize = 0;
    for (zs.profile.builtins) |b| {
        if (@intFromEnum(b.group) == group) n += 1;
    }
    return n;
}

/// The name of built-in profile i of a group, or null.
export fn zs_builtin_profile_name(group: c_int, i: usize) ?[*:0]const u8 {
    var k: usize = 0;
    for (zs.profile.builtins) |b| {
        if (@intFromEnum(b.group) != group) continue;
        if (k == i) return b.name.ptr;
        k += 1;
    }
    return null;
}

/// The gaps of a layer of the last slice (see App.layerGaps). The arrays
/// stay valid until the next call for another layer, or the next slice.
export fn zs_app_layer_gaps(a: ?*App, layer: usize, gaps: ?*?[*]const zs.gaps.Gap, n_gaps: ?*usize, runs: ?*?[*]const zs.gaps.Run, n_runs: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = app.layerGaps(layer) catch |e| return switch (e) {
        error.InvalidArgument => @intFromEnum(Status.invalid_argument),
        error.NoResult => @intFromEnum(Status.no_result),
        else => status(e),
    };
    if (gaps) |o| o.* = r.gaps.ptr;
    if (n_gaps) |o| o.* = r.gaps.len;
    if (runs) |o| o.* = r.runs.ptr;
    if (n_runs) |o| o.* = r.runs.len;
    return ok;
}

/// The gap of layer `layer` at x, y (mm), or the nearest one within 0.3
/// mm, or -1. The cell size of the gaps of the layer goes to `cell`.
export fn zs_app_gap_at(a: ?*App, layer: usize, x: f64, y: f64, cell: ?*f64) i64 {
    const app = a orelse return -1;
    const r = app.layerGaps(layer) catch return -1;
    if (cell) |out| out.* = r.cell;
    return if (r.at(x, y, 0.3)) |i| @intCast(i) else -1;
}

/// The size of the cells of the gaps of a layer (mm), or 0.
export fn zs_app_gap_cell(a: ?*App, layer: usize) f64 {
    const app = a orelse return 0;
    const r = app.layerGaps(layer) catch return 0;
    return r.cell;
}

/// A setting that can close a gap: its name, the value to try, and why.
/// The strings are not NUL-terminated.
pub const GapStep = extern struct {
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
    why: [*]const u8,
    why_len: usize,
};

/// The settings that can close gap `index` of layer `layer`, the best
/// first, at most `cap` of them in `out`. `n` gets their number. Valid
/// until the next call or slice.
export fn zs_app_gap_advice(a: ?*App, layer: usize, index: usize, out: ?[*]GapStep, cap: usize, n: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const steps = app.gapAdvice(layer, index) catch |e| return switch (e) {
        error.InvalidArgument => @intFromEnum(Status.invalid_argument),
        error.NoResult => @intFromEnum(Status.no_result),
        else => status(e),
    };
    if (n) |o| o.* = steps.len;
    if (out) |o| for (steps[0..@min(cap, steps.len)], 0..) |st, i| {
        o[i] = .{ .name = st.name.ptr, .name_len = st.name.len, .value = st.value.ptr, .value_len = st.value.len, .why = st.why.ptr, .why_len = st.why.len };
    };
    return ok;
}

/// A plain-text report of a line, for "Copy for AI". Valid until the next
/// call or inspection.
export fn zs_app_line_report(a: ?*App, path: usize, gcode_file: ?[*:0]const u8, out: ?*?[*]const u8, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const file = if (gcode_file) |f| std.mem.span(f) else "(not saved)";
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const r = app.lineReport(path, file) catch |e| return status(e);
    o.* = r.ptr;
    l.* = r.len;
    return ok;
}

export fn zs_app_inspect(a: ?*App, path: usize, out: ?*Inspect) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const i = app.inspect(path) catch |e| return status(e);
    o.* = .{
        .feature = @intFromEnum(i.feature),
        .layer = i.layer,
        .path = i.path,
        .z = i.z,
        .height = i.height,
        .line_width = i.line_width,
        .bead_width = i.bead_width,
        .length = i.length,
        .planned_speed = i.planned_speed,
        .speed = i.speed,
        .flow = i.flow,
        .start_time = i.start_time,
        .end_time = i.end_time,
        .title = i.title.ptr,
        .explain = i.explain.ptr,
        .why_planned = i.why_planned.ptr,
        .why_real = i.why_real.ptr,
        .why_flow = i.why_flow.ptr,
        .slow_reason = i.slow_reason,
        .settings = i.settings.ptr,
        .slow_text = app_mod.inspect_picks.slowText(i.slow_reason).ptr,
    };
    return ok;
}

pub const Pick = extern struct {
    name: [*:0]const u8,
    why: [*:0]const u8,
};

/// The settings that matter most for path `path`, best first, at most max
/// (see src/app/inspect_picks.zig). The strings are static.
export fn zs_app_inspect_picks(a: ?*App, path: usize, out: ?[*]Pick, max: usize, n: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    // A separate arena: the strings of the last zs_app_inspect stay valid.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const i = app.inspectIn(arena.allocator(), path) catch |e| return status(e);
    const Ctx = struct {
        app: *const App,
        z: f64,
        fn changed(ctx: *const anyopaque, name: []const u8) u8 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (self.app.hasOverrideAt(self.z, name)) return 1;
            const src = self.app.source(null, name);
            return if (src.level == .print or src.level == .part) 2 else 0;
        }
    };
    const ctx: Ctx = .{ .app = app, .z = i.z };
    var buf: [32]app_mod.inspect_picks.Pick = undefined;
    const count = app_mod.inspect_picks.picks(.{
        .feature = @intFromEnum(i.feature),
        .layer = i.layer,
        .slow_reason = i.slow_reason,
        .settings = i.settings,
        .ctx = &ctx,
        .changed = Ctx.changed,
    }, buf[0..@min(max, buf.len)]);
    for (buf[0..count], 0..) |p, k| o[k] = .{ .name = p.name.ptr, .why = p.why.ptr };
    if (n) |cnt| cnt.* = count;
    return ok;
}

pub const SettingEffect = extern struct {
    features: u32,
    first_layer_only: c_int,
    note: [*:0]const u8,
};

/// The speed in mm/s of a speed ratio setting with the value `value`, and
/// the other settings of the app.
export fn zs_app_ratio_speed(a: ?*const App, name: ?[*:0]const u8, value: ?[*:0]const u8, out: ?*f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = app_mod.ratioSpeed(app.settings, n, v) orelse return @intFromEnum(Status.unknown_setting);
    return ok;
}

export fn zs_setting_get_effect(name: ?[*:0]const u8, out: ?*SettingEffect) c_int {
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const e = app_mod.settingEffect(n);
    o.* = .{ .features = e.features, .first_layer_only = @intFromBool(e.first_layer_only), .note = e.note.ptr };
    return ok;
}

pub const FeatureStats = extern struct {
    time_s: f64,
    length_mm: f64,
    volume_mm3: f64,
    paths: usize,
};

export fn zs_app_feature_stats(a: ?*const App, out: ?[*]FeatureStats) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const stats = app.featureStats() orelse return @intFromEnum(Status.no_result);
    for (stats, 0..) |s, i| o[i] = .{ .time_s = s.time, .length_mm = s.length, .volume_mm3 = s.volume, .paths = s.paths };
    return ok;
}

/// Changes a setting for the layers with a top z from z_min to z_max (mm).
export fn zs_app_override_set(a: ?*App, z_min: f64, z_max: f64, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    app.setOverride(z_min, z_max, n, v) catch |e| return switch (e) {
        error.NotPerLayer => @intFromEnum(Status.invalid_argument),
        else => status(e),
    };
    // The changes for some layers are in the 3MF file of the plate.
    noted(app, n, true);
    return ok;
}

/// The number of overrides, and override i: its range, setting, and value.
/// The strings are valid until the next change of the overrides.
export fn zs_app_override_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.overrides.items.len;
}

pub const Override = extern struct {
    z_min: f64,
    z_max: f64,
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
};

export fn zs_app_override_get(a: ?*const App, i: usize, out: ?*Override) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.overrides.items.len) return @intFromEnum(Status.invalid_argument);
    const v = app.overrides.items[i];
    o.* = .{ .z_min = v.z_min, .z_max = v.z_max, .name = v.name.ptr, .name_len = v.name.len, .value = v.value.ptr, .value_len = v.value.len };
    return ok;
}

/// Removes the override of a setting for exactly the range z_min..z_max.
/// Returns 1 if there was one.
export fn zs_app_override_remove(a: ?*App, z_min: f64, z_max: f64, name: ?[*:0]const u8) c_int {
    const app = a orelse return 0;
    const n = std.mem.span(name orelse return 0);
    const removed = app.removeOverride(z_min, z_max, n);
    if (removed) noted(app, n, true);
    return @intFromBool(removed);
}

/// Layer profiles: a name for a layer range. The overrides with the same
/// range are its changes.
export fn zs_app_profile_set(a: ?*App, z_min: f64, z_max: f64, name: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.setProfile(z_min, z_max, std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_profile_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.profiles.items.len;
}

pub const Profile = extern struct {
    z_min: f64,
    z_max: f64,
    name: [*]const u8,
    name_len: usize,
};

export fn zs_app_profile_get(a: ?*const App, i: usize, out: ?*Profile) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.profiles.items.len) return @intFromEnum(Status.invalid_argument);
    const p = app.profiles.items[i];
    o.* = .{ .z_min = p.z_min, .z_max = p.z_max, .name = p.name.ptr, .name_len = p.name.len };
    return ok;
}

/// Removes a layer range: its name and all its overrides. Returns the
/// number of overrides removed.
export fn zs_app_profile_remove(a: ?*App, z_min: f64, z_max: f64) usize {
    const app = a orelse return 0;
    defer noted(app, null, true);
    return app.removeProfile(z_min, z_max);
}

/// Removes the overrides of a setting that cover z. Returns how many.
export fn zs_app_override_clear_at(a: ?*App, z: f64, name: ?[*:0]const u8) usize {
    const app = a orelse return 0;
    const n = std.mem.span(name orelse return 0);
    const k = app.clearOverridesAt(z, n);
    if (k > 0) noted(app, n, true);
    return k;
}

export fn zs_app_override_at(a: ?*const App, z: f64, name: ?[*:0]const u8) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.hasOverrideAt(z, std.mem.span(name orelse return 0)));
}

/// The value of a setting for the layers at z, with the overrides. The
/// same buffer rules as zs_app_setting_get.
export fn zs_app_setting_get_at(a: ?*const App, z: f64, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.getSettingAt(z, n, &aw.writer) catch |e| return status(e);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

// ---- the plate ----

export fn zs_app_add_stl(a: ?*App, name: ?[*:0]const u8, data: ?[*]const u8, len: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const d = data orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    const i = app.addStl(std.mem.span(name orelse "part.stl"), d[0..len]) catch |e| return -@as(isize, status(e));
    noted(app, null, true);
    return @intCast(i);
}

pub const Part = extern struct {
    name: [*:0]const u8,
    x: f64,
    y: f64,
    rotation: f64,
    size_x: f64,
    size_y: f64,
    size_z: f64,
    scale_x: f64,
    scale_y: f64,
    scale_z: f64,
};

export fn zs_app_part_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.plate.count();
}

/// The name stays valid until the plate changes.
export fn zs_app_part_get(a: ?*App, i: usize, out: ?*Part) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    const p = &app.plate.parts.items[i];
    o.* = .{ .name = p.name.ptr, .x = p.x, .y = p.y, .rotation = p.rot, .size_x = 2 * p.half[0], .size_y = 2 * p.half[1], .size_z = p.height, .scale_x = p.scale[0], .scale_y = p.scale[1], .scale_z = p.scale[2] };
    return ok;
}

/// The settings of part i and of its modifier volumes, as text (see
/// App.partSettingsText). The same buffer rules as zs_app_setting_get.
/// Sets a zslice setting of part i (value NULL: the part has the value of
/// the plate again). See App.setPartSetting.
export fn zs_app_part_setting_set(a: ?*App, i: usize, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const v: ?[]const u8 = if (value) |p| std.mem.span(p) else null;
    app.setPartSetting(i, n, v) catch |e| return switch (e) {
        error.NoPart => @intFromEnum(Status.out_of_range),
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_value),
    };
    noted(app, null, true);
    return ok;
}

/// The value of a zslice setting of part i, or ZS_NO_RESULT if the part
/// has the value of the plate. The same buffer rules as
/// zs_app_setting_get.
export fn zs_app_part_setting_get(a: ?*const App, i: usize, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    const text = app.partSetting(i, n) orelse return @intFromEnum(Status.no_result);
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

export fn zs_app_part_settings(a: ?*const App, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.partSettingsText(i, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The settings of part i that zslice does not use (App.partUnusedText).
/// The same buffer rules as zs_app_setting_get.
export fn zs_app_part_unused(a: ?*const App, i: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.partUnusedText(i, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The zslice settings of Cura settings for the whole plate
/// (import_cura.plateSettings), from the settings of the app now. `text`
/// has one "key=value" a line. Each line of the result is one of:
///   "set\tname\tvalue": a zslice setting to set;
///   "near\tkey\tvalue\twhy": zslice uses a near value;
///   "unused\tkey\tvalue\twhy": zslice cannot use this key.
/// It changes no setting. The same buffer rules as zs_app_setting_get.
export fn zs_app_cura_settings(a: ?*const App, text: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = std.mem.span(text orelse return @intFromEnum(Status.invalid_argument));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pairs: std.ArrayList(zs.import_cura.Pair) = .empty;
    var lines = std.mem.tokenizeAny(u8, t, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return @intFromEnum(Status.invalid_argument);
        pairs.append(arena, .{
            .key = std.mem.trim(u8, line[0..eq], " \t"),
            .value = std.mem.trim(u8, line[eq + 1 ..], " \t"),
        }) catch return @intFromEnum(Status.out_of_memory);
    }
    const ps = zs.import_cura.plateSettings(arena, pairs.items, &app.settings) catch return @intFromEnum(Status.out_of_memory);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    (struct {
        fn f(out: *Writer, r: zs.import_cura.PartSettings) Writer.Error!void {
            for (r.sets) |ch| try out.print("set\t{s}\t{s}\n", .{ ch.name, ch.value });
            for (r.ignored) |ig| try out.print("{s}\t{s}\t{s}\t{s}\n", .{ if (ig.near) "near" else "unused", ig.key, ig.value, ig.why });
        }
    }).f(w, ps) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The parts of a 3MF file keep their places in the file (App.keep_places).
export fn zs_app_set_keep_places(a: ?*App, on: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.keep_places = on != 0;
    return ok;
}

export fn zs_app_part_move(a: ?*App, i: usize, x: f64, y: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.movePart(i, x, y) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_rotate(a: ?*App, i: usize, degrees: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.rotatePart(i, degrees) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_scale(a: ?*App, i: usize, sx: f64, sy: f64, sz: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.scalePart(i, .{ sx, sy, sz }) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_turn(a: ?*App, i: usize, axis: c_int, degrees: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or axis < 0 or axis > 1) return @intFromEnum(Status.out_of_range);
    app.turnPart(i, @intCast(axis), degrees) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_put_down_at(a: ?*App, i: usize, x: f64, y: f64, z: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.putPartDownAt(i, x, y, z) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_part_place(a: ?*App, i: usize, mode: c_int, axis: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or mode < 0 or mode > 2 or axis < 0 or axis > 2) return @intFromEnum(Status.out_of_range);
    app.placePart(i, @enumFromInt(@as(u8, @intCast(mode))), @intCast(axis)) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// A copy of part i at a free place on the bed. Returns its index, or a
/// negative status.
/// Splits part i into its separate bodies, each a part at its place with
/// the settings of part i (the new parts are at index i on). Returns the
/// count of new parts, 0 for a part of one body, or -status.
export fn zs_app_part_split(a: ?*App, i: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const n = app.splitPart(i) catch |e| return -@as(isize, status(e));
    if (n > 0) noted(app, null, true);
    return @intCast(n);
}

/// Cuts part i with a level plane at height z (mm above the bed): the part
/// below and the part above, each closed, with the settings of part i, at
/// index i and i + 1. flip != 0 turns the upper part over, onto its cut
/// face. pegs > 0: at most that many holes for pegs in both parts, and the
/// pegs (diameter `peg_d` mm, 0: 5 mm) as parts at the end of the plate.
/// Returns the count of new parts (2 and the pegs), 0 if the plane misses
/// the part, or -status.
export fn zs_app_part_cut(a: ?*App, i: usize, z: f64, flip: c_int, pegs: c_int, peg_d: f64) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const p: zs.cut.Pegs = .{ .count = @intCast(std.math.clamp(pegs, 0, 8)), .diameter = if (peg_d > 0) peg_d else 5 };
    const n = app.cutPart(i, z, flip != 0, p) catch |e| return -@as(isize, status(e));
    if (n > 0) noted(app, null, true);
    return @intCast(n);
}

export fn zs_app_part_duplicate(a: ?*App, i: usize) isize {
    const app = a orelse return -@as(isize, @intFromEnum(Status.invalid_argument));
    if (i >= app.plate.count()) return -@as(isize, @intFromEnum(Status.out_of_range));
    const j = app.duplicatePart(i) catch |e| return -@as(isize, status(e));
    noted(app, null, true);
    return @intCast(j);
}

export fn zs_app_part_reset(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.resetPart(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_plate_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.plateCount();
}

export fn zs_app_plate_active(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.active;
}

export fn zs_app_plate_parts(a: ?*const App, i: usize) usize {
    const app = a orelse return 0;
    return app.plateParts(i);
}

/// A new empty plate (it becomes the active plate). Returns its index.
export fn zs_app_plate_add(a: ?*App) isize {
    const app = a orelse return -1;
    const i = app.addPlate() catch return -1;
    noted(app, null, true);
    return @intCast(i);
}

export fn zs_app_plate_select(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plateCount()) return @intFromEnum(Status.out_of_range);
    app.selectPlate(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

export fn zs_app_plate_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plateCount()) return @intFromEnum(Status.out_of_range);
    app.removePlate(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// Smart placement of all parts, then an arrange. 1 if they all fit.
export fn zs_app_plate_smart_place(a: ?*App) c_int {
    const app = a orelse return 0;
    defer noted(app, null, true);
    return @intFromBool(app.smartPlacePlate() catch return 0);
}

export fn zs_app_part_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.removePart(i) catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// 1 if all parts fit on the bed, 0 if not.
export fn zs_app_plate_arrange(a: ?*App) c_int {
    const app = a orelse return 0;
    defer noted(app, null, true);
    return @intFromBool(app.arrangePlate() catch false);
}

export fn zs_app_plate_clear(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.clearPlate() catch |e| return status(e);
    noted(app, null, true);
    return ok;
}

/// The part whose footprint holds (x, y) on the bed, or -1.
export fn zs_app_part_at(a: ?*const App, x: f64, y: f64) isize {
    const app = a orelse return -1;
    const i = app.plate.partAt(x, y) orelse return -1;
    return @intCast(i);
}

/// The part of a path of the toolpaths (by its first point), or -1.
export fn zs_app_part_of_path(a: ?*const App, path: usize) isize {
    const app = a orelse return -1;
    const i = app.partOfPath(path) orelse return -1;
    return @intCast(i);
}

fn groupOf(group: c_int) ?zs.profile.Group {
    return switch (group) {
        0 => .machine,
        1 => .filament,
        2 => .project,
        else => null,
    };
}

/// Writes the settings of a group that differ from the defaults, as a
/// profile. The same buffer rules as zs_app_setting_get.
export fn zs_app_state_write(a: ?*const App, group: c_int, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = groupOf(group) orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeState(g, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const n = @min(text.len, cap - 1);
        @memcpy(b[0..n], text[0..n]);
        b[n] = 0;
    }
    return ok;
}

/// The settings of a group that differ from the built-in defaults: for
/// the project group, the quality profile with the changes of this print
/// (a full profile, for "Save as profile").
export fn zs_app_profile_write(a: ?*const App, group: c_int, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = groupOf(group) orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    zs.profile.writeChanged(app.settings, g, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const n = @min(text.len, cap - 1);
        @memcpy(b[0..n], text[0..n]);
        b[n] = 0;
    }
    return ok;
}

/// Sets all settings of a group to the built-in defaults.
export fn zs_app_group_reset(a: ?*App, group: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.resetGroup(groupOf(group) orelse return @intFromEnum(Status.invalid_argument));
    noted(app, null, false);
    return ok;
}

/// Applies a profile text to a group. On an error, `message` (can be
/// NULL) gets the line and the reason, and the settings do not change.
export fn zs_app_profile_apply(a: ?*App, group: c_int, text: ?[*]const u8, len: usize, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const g = groupOf(group) orelse return @intFromEnum(Status.invalid_argument);
    const t = (text orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var diag: zs.profile.Diagnostic = .{};
    app.applyProfile(g, "saved", t, &diag) catch |e| {
        if (message) |m| if (cap > 0) {
            const msg = std.fmt.bufPrint(m[0 .. cap - 1], "line {d}: {s}", .{ diag.line, if (diag.message.len > 0) diag.message else @errorName(e) }) catch m[0 .. cap - 1];
            m[msg.len] = 0;
        };
        return switch (e) {
            error.SyntaxError, error.InvalidValue => @intFromEnum(Status.invalid_value),
            error.UnknownSetting => @intFromEnum(Status.unknown_setting),
            error.OutOfRange => @intFromEnum(Status.out_of_range),
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.invalid_argument),
        };
    };
    noted(app, null, false);
    return ok;
}

fn profileError(e: anyerror, diag: zs.profile.Diagnostic, message: ?[*]u8, cap: usize) c_int {
    if (message) |m| if (cap > 0) {
        const msg = std.fmt.bufPrint(m[0 .. cap - 1], "line {d}: {s}", .{ diag.line, if (diag.message.len > 0) diag.message else @errorName(e) }) catch m[0 .. cap - 1];
        m[msg.len] = 0;
    };
    return switch (e) {
        error.SyntaxError, error.InvalidValue => @intFromEnum(Status.invalid_value),
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_argument),
    };
}

/// The formula of a setting (the text after "="), or ZS_NO_RESULT. A
/// setting gets a formula from zs_app_setting_set with a value that
/// starts with "=". The same buffer rules as zs_app_setting_get.
export fn zs_app_formula_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const text = app.formulaOf(std.mem.span(name orelse return @intFromEnum(Status.invalid_argument))) orelse return @intFromEnum(Status.no_result);
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// All formulas as text ("name = text" lines), for the state of a shell.
export fn zs_app_formulas_write(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeFormulas(&aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// Reads the text of zs_app_formulas_write.
export fn zs_app_formulas_read(a: ?*App, text: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.readFormulas((text orelse return @intFromEnum(Status.invalid_argument))[0..len]);
    noted(app, null, false);
    return ok;
}

/// Sets the quality profile (see App.setQuality).
export fn zs_app_quality_set(a: ?*App, name: ?[*:0]const u8, text: ?[*]const u8, len: usize, keep_edits: bool, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const t = (text orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var diag: zs.profile.Diagnostic = .{};
    app.setQuality(n, t, keep_edits, &diag) catch |e| return profileError(e, diag, message, cap);
    noted(app, null, false);
    return ok;
}

/// The name of the quality profile ("" if none). Valid until the next
/// zs_app_quality_set.
export fn zs_app_quality_name(a: ?*const App) [*:0]const u8 {
    const app = a orelse return "";
    return app.quality_name.ptr;
}

/// Sets the global settings of the user (see App.setGlobal).
export fn zs_app_global_set(a: ?*App, text: ?[*]const u8, len: usize, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = (text orelse return @intFromEnum(Status.invalid_argument))[0..len];
    var diag: zs.profile.Diagnostic = .{};
    app.setGlobal(t, &diag) catch |e| return profileError(e, diag, message, cap);
    noted(app, null, false);
    return ok;
}

/// Sets one global setting (value NULL: clears it). See
/// App.setGlobalSetting.
export fn zs_app_global_setting_set(a: ?*App, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    app.setGlobalSetting(n, if (value) |v| std.mem.span(v) else null) catch |e| return switch (e) {
        error.UnknownSetting => @intFromEnum(Status.unknown_setting),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
        else => @intFromEnum(Status.invalid_value),
    };
    noted(app, n, false);
    return ok;
}

/// The value of a setting in the global settings (the default if the
/// global settings do not set it).
export fn zs_app_global_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    App.writeSettingOf(app.globalSettings(), n, &aw.writer) catch return @intFromEnum(Status.unknown_setting);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The global settings as a profile text, for the state of a shell.
export fn zs_app_global_write(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeGlobal(&aw.writer) catch return @intFromEnum(Status.out_of_memory);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// Where the value of a setting comes from (see App.source): the level
/// (enum zs_level) and the name of its profile. `part` < 0: the plate.
export fn zs_app_setting_source(a: ?*const App, part: isize, name: ?[*:0]const u8, level: ?*c_int, profile: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    const src = app.source(if (part >= 0) @intCast(part) else null, n);
    if (level) |l| l.* = @intFromEnum(src.level);
    if (profile) |p| if (cap > 0) {
        const k = @min(src.profile.len, cap - 1);
        @memcpy(p[0..k], src.profile[0..k]);
        p[k] = 0;
    };
    return ok;
}

/// The value of a setting under the changes of this print (see App.base):
/// the value that a reset of the setting gives. The same buffer rules as
/// zs_app_setting_get.
export fn zs_app_setting_base_get(a: ?*const App, name: ?[*:0]const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const n = std.mem.span(name orelse return @intFromEnum(Status.invalid_argument));
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    App.writeSettingOf(app.base(), n, &aw.writer) catch return @intFromEnum(Status.unknown_setting);
    const text = aw.written();
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const k = @min(text.len, cap - 1);
        @memcpy(b[0..k], text[0..k]);
        b[k] = 0;
    }
    return ok;
}

/// The path of a feature nearest to (x, y) mm on a layer, at any
/// distance, or (size_t)-1.
export fn zs_app_pick_feature(a: ?*const App, layer: usize, feature: c_int, x: f64, y: f64) usize {
    const app = a orelse return std.math.maxInt(usize);
    if (feature < 0 or feature > 255) return std.math.maxInt(usize);
    return app.pickFeature(layer, @intCast(feature), x, y) orelse std.math.maxInt(usize);
}

/// The path of a layer nearest to (x, y) mm, or (size_t)-1.
export fn zs_app_pick_layer(a: ?*const App, layer: usize, x: f64, y: f64) usize {
    const app = a orelse return std.math.maxInt(usize);
    return app.pickInLayer(layer, x, y) orelse std.math.maxInt(usize);
}

pub const License = extern struct {
    name: [*:0]const u8,
    license: [*:0]const u8,
    text: [*:0]const u8,
};

export fn zs_license_count() usize {
    return app_mod.licenses.len;
}

export fn zs_license_get(index: usize, out: ?*License) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (index >= app_mod.licenses.len) return @intFromEnum(Status.out_of_range);
    const l = app_mod.licenses[index];
    o.* = .{ .name = l.name.ptr, .license = l.license.ptr, .text = l.text.ptr };
    return ok;
}

// ---- comparison with Cura ----

/// Reads the file at `path` for the core. Returns its bytes and sets
/// `len`, or returns null. The bytes stay valid until the call that gave
/// the callback returns.
pub const ReadFn = *const fn (ctx: ?*anyopaque, path: [*:0]const u8, len: *usize) callconv(.c) ?[*]const u8;

pub const CuraRow = extern struct {
    name: [*:0]const u8,
    zslice_value: [*:0]const u8,
    cura_value: [*:0]const u8,
    cura_keys: [*:0]const u8,
    from: [*:0]const u8,
    note: [*:0]const u8,
    differs: c_int,
    formula: c_int,
    in_use_all: c_int,
};

/// The rows of a comparison, with the memory of their strings.
pub const CuraCompare = struct {
    arena: std.heap.ArenaAllocator,
    rows: []CuraRow,
};

const CuraReader = struct {
    read: ReadFn,
    ctx: ?*anyopaque,
    fn readFile(ctx: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *const CuraReader = @ptrCast(@alignCast(ctx.?));
        const p = arena.dupeZ(u8, path) catch return null;
        var len: usize = 0;
        const bytes = self.read(self.ctx, p, &len) orelse return null;
        return arena.dupe(u8, bytes[0..len]) catch null;
    }
};

/// Compares the settings of the app with a Cura stack (see
/// src/cura_compare.zig). `read` gives "cura.json" and the files that it
/// names. On an error, `message` (can be NULL) gets the file and the
/// reason.
export fn zs_app_cura_compare(a: ?*const App, read: ?ReadFn, ctx: ?*anyopaque, out: ?*?*CuraCompare, message: ?[*]u8, cap: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const r = read orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const cc = gpa.create(CuraCompare) catch return @intFromEnum(Status.out_of_memory);
    cc.arena = .init(gpa);
    const arena = cc.arena.allocator();
    var reader: CuraReader = .{ .read = r, .ctx = ctx };
    var diag: zs.cura_compare.Diagnostic = .{};
    const rows = zs.cura_compare.compare(arena, app.settings, .{ .ctx = &reader, .read = CuraReader.readFile }, &diag) catch |e| {
        if (message) |m| if (cap > 0) {
            const msg = std.fmt.bufPrint(m[0 .. cap - 1], "{s}: {s}", .{ diag.file, if (diag.message.len > 0) diag.message else @errorName(e) }) catch m[0 .. cap - 1];
            m[msg.len] = 0;
        };
        cc.arena.deinit();
        gpa.destroy(cc);
        return switch (e) {
            error.OutOfMemory => @intFromEnum(Status.out_of_memory),
            else => @intFromEnum(Status.invalid_value),
        };
    };
    cc.rows = cRows(arena, rows) catch {
        cc.arena.deinit();
        gpa.destroy(cc);
        return @intFromEnum(Status.out_of_memory);
    };
    o.* = cc;
    return ok;
}

fn cRows(arena: std.mem.Allocator, rows: []const zs.cura_compare.Row) ![]CuraRow {
    const out = try arena.alloc(CuraRow, rows.len);
    for (rows, out) |src, *dst| dst.* = .{
        .name = (try arena.dupeZ(u8, src.name)).ptr,
        .zslice_value = (try arena.dupeZ(u8, src.zslice)).ptr,
        .cura_value = (try arena.dupeZ(u8, src.cura)).ptr,
        .cura_keys = (try arena.dupeZ(u8, src.cura_keys)).ptr,
        .from = (try arena.dupeZ(u8, src.from)).ptr,
        .note = (try arena.dupeZ(u8, src.note)).ptr,
        .differs = @intFromBool(src.differs),
        .formula = @intFromBool(src.formula),
        .in_use_all = @intFromBool(src.in_use_all),
    };
    return out;
}

export fn zs_cura_compare_count(cc: ?*const CuraCompare) usize {
    const c_ = cc orelse return 0;
    return c_.rows.len;
}

export fn zs_cura_compare_get(cc: ?*const CuraCompare, i: usize, out: ?*CuraRow) c_int {
    const c_ = cc orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (i >= c_.rows.len) return @intFromEnum(Status.out_of_range);
    o.* = c_.rows[i];
    return ok;
}

export fn zs_cura_compare_free(cc: ?*CuraCompare) void {
    const c_ = cc orelse return;
    c_.arena.deinit();
    gpa.destroy(c_);
}

test "C API: the app" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    try std.testing.expectEqual(@intFromEnum(Status.no_model), zs_app_slice(app));
    var info: SettingInfo = undefined;
    try std.testing.expectEqual(ok, zs_setting_get_info(0, &info));
    try std.testing.expectEqualStrings("machine.name", std.mem.span(info.name));
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(ok, zs_app_setting_get(app, "machine.name", &buf, buf.len, &len));
    try std.testing.expectEqual(@as(usize, 7), len);
    try std.testing.expectEqualStrings("generic", std.mem.span(@as([*:0]u8, @ptrCast(&buf))));
    var lic: License = undefined;
    try std.testing.expectEqual(ok, zs_license_get(0, &lic));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(lic.text), "AFFERO") != null);
}

test "C API: apply the status of a printer" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    const st = zs_printer_status_new();
    defer zs_printer_status_free(st);
    const body = "{\"material\":\"PETG\",\"diameter\":2.85,\"spool\":{\"name\":\"Navy\",\"color\":\"#1a2b4c\"},\"limits\":{\"max_accel\":1500}}";
    try std.testing.expectEqual(ok, zs_printer_status_feed(st, 2, "/api/plugin/printdeck", body, body.len));
    try std.testing.expectEqual(ok, zs_app_apply_printer_status(app, st, 3));
    const a = app.?;
    try std.testing.expectEqual(@as(f64, 1500), a.settings.machine.max_accel);
    try std.testing.expectEqualStrings("Navy", a.settings.filament.name);
    try std.testing.expectEqualStrings("PETG", a.settings.filament.material);
    try std.testing.expectEqualStrings("#1a2b4c", a.settings.filament.color);
    try std.testing.expectEqual(@as(f64, 2.85), a.settings.filament.diameter);
}

test "C API: compare with Cura" {
    var app: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &app));
    defer zs_app_free(app);
    const Files = struct {
        fn read(ctx: ?*anyopaque, path: [*:0]const u8, len: *usize) callconv(.c) ?[*]const u8 {
            _ = ctx;
            const p = std.mem.span(path);
            const text: []const u8 = if (std.mem.eql(u8, p, "cura.json"))
                \\{"machine": "box", "profiles": {"q": {"quality_changes": "q.inst.cfg"}}}
            else if (std.mem.eql(u8, p, "definitions/box.def.json"))
                \\{"name": "Box", "inherits": "fdmprinter", "overrides": {"machine_width": {"default_value": 123}}}
            else if (std.mem.eql(u8, p, "q.inst.cfg"))
                "[values]\nlayer_height = 0.25\n"
            else
                return null;
            len.* = text.len;
            return text.ptr;
        }
    };
    var cc: ?*CuraCompare = null;
    var msg: [128]u8 = undefined;
    try std.testing.expectEqual(ok, zs_app_cura_compare(app, Files.read, null, &cc, &msg, msg.len));
    defer zs_cura_compare_free(cc);
    var found: usize = 0;
    for (0..zs_cura_compare_count(cc)) |i| {
        var row: CuraRow = undefined;
        try std.testing.expectEqual(ok, zs_cura_compare_get(cc, i, &row));
        if (std.mem.eql(u8, std.mem.span(row.name), "machine.bed_size_x")) {
            try std.testing.expectEqualStrings("123", std.mem.span(row.cura_value));
            try std.testing.expectEqual(@as(c_int, 1), row.in_use_all);
            found += 1;
        }
        if (std.mem.eql(u8, std.mem.span(row.name), "project.layer_height")) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    // A missing file gives its name.
    const None = struct {
        fn read(ctx: ?*anyopaque, path: [*:0]const u8, len: *usize) callconv(.c) ?[*]const u8 {
            _ = ctx;
            _ = path;
            _ = len;
            return null;
        }
    };
    var cc2: ?*CuraCompare = null;
    try std.testing.expect(zs_app_cura_compare(app, None.read, null, &cc2, &msg, msg.len) != ok);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(@as([*:0]u8, @ptrCast(&msg))), "cura.json:"));
}

// ---- the history of changes (see app/history.zig) ----

fn copyOut(text: []const u8, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    if (out_len) |l| l.* = text.len;
    if (buf) |b| {
        if (cap == 0) return ok;
        const n = @min(text.len, cap - 1);
        @memcpy(b[0..n], text[0..n]);
        b[n] = 0;
    }
    return ok;
}

/// The facts of the state, for a step of the history: one line for each
/// value that differs from the start ("scope\tkey\tvalue").
export fn zs_app_history_facts(a: ?*const App, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.writeFacts(&aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The changes from the facts `before` to the facts `after`, one on each
/// line ("scope\tkey\told\tnew").
export fn zs_history_diff(before: ?[*]const u8, before_len: usize, after: ?[*]const u8, after_len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const b = if (before) |p| p[0..before_len] else "";
    const af = if (after) |p| p[0..after_len] else "";
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.history.diff(gpa, b, af, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// The changes of a diff in words, one on each line: "scope\tchange", for
/// example "Part Benchy\tWall count the print value → 4".
export fn zs_history_describe(changes: ?[*]const u8, len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const t = if (changes) |p| p[0..len] else "";
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app_mod.history.describe(gpa, t, zs.settings.part_z, &.{}, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// zs_history_describe, with the layer numbers of the last slice of the app
/// for the changes of some layers ("Layers 86 and up").
export fn zs_app_history_describe(a: ?*const App, changes: ?[*]const u8, len: usize, buf: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const t = if (changes) |p| p[0..len] else "";
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.describeChanges(t, &aw.writer) catch return @intFromEnum(Status.out_of_memory);
    return copyOut(aw.written(), buf, cap, out_len);
}

/// Undoes one change (one line of zs_history_diff) and keeps the others.
/// ZS_NOT_SUPPORTED for a change of the place of a part. Slice again after
/// it.
export fn zs_app_history_revert(a: ?*App, change: ?[*]const u8, len: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const line = (change orelse return @intFromEnum(Status.invalid_argument))[0..len];
    app.revertChange(line) catch |e| return switch (e) {
        error.NotSupported => @intFromEnum(Status.not_supported),
        error.NoPart, error.NotPerLayer => @intFromEnum(Status.invalid_argument),
        else => status(e),
    };
    // A new step: it never amends the step of an edit.
    const settings = std.mem.startsWith(u8, line, "machine\t") or std.mem.startsWith(u8, line, "filament\t") or std.mem.startsWith(u8, line, "print\t");
    noted(app, null, !settings);
    return ok;
}

// ---- the undo list (see app/history.zig) ----

fn keyOf(key: ?[*:0]const u8) ?[]const u8 {
    return if (key) |k| std.mem.span(k) else null;
}

/// Ends the step of the changes so far. 1 if a step was added, amended,
/// or dropped.
export fn zs_app_history_commit(a: ?*App, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.undo.commit(app, now_ms));
}

/// The setting whose editor has the focus (NULL: none). 1 if the commit
/// of the edit before changed the list.
export fn zs_app_history_set_focus(a: ?*App, key: ?[*:0]const u8, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.undo.setFocus(app, keyOf(key), now_ms));
}

export fn zs_app_history_undo(a: ?*App, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.undo(app, now_ms));
}

export fn zs_app_history_redo(a: ?*App, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.redo(app, now_ms));
}

export fn zs_app_history_goto(a: ?*App, i: usize, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.goto(app, i, now_ms));
}

export fn zs_app_history_truncate(a: ?*App, i: usize, now_ms: i64) c_int {
    const app = a orelse return 0;
    return @intCast(app.undo.truncate(app, i, now_ms));
}

/// Drops all steps. The next commit takes the start.
export fn zs_app_history_reset(a: ?*App) void {
    const app = a orelse return;
    app.undo.reset(app.gpa);
}

export fn zs_app_history_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.undo.count();
}

export fn zs_app_history_current(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.undo.current;
}

/// 1 if changes wait for a commit.
export fn zs_app_history_pending(a: ?*const App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.undo.pending_key != null);
}

pub const HistoryStep = extern struct {
    time_ms: i64,
    kind: [*:0]const u8,
    changes: [*]const u8,
    changes_len: usize,
    text: [*]const u8,
    text_len: usize,
};

/// Step i of the undo list: its time, its kind, and its changes from step
/// i - 1 (as lines and in words). The strings are valid until the next
/// zs_app_history_step or the next change of the list.
export fn zs_app_history_step(a: ?*App, i: usize, out: ?*HistoryStep) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const info = app.undo.step(app, i) catch |e| return switch (e) {
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    };
    o.* = .{
        .time_ms = info.time_ms,
        .kind = info.kind.ptr,
        .changes = info.changes.ptr,
        .changes_len = info.changes.len,
        .text = info.text.ptr,
        .text_len = info.text.len,
    };
    return ok;
}

/// The kind of a step of the history, from its changes (zs_history_diff
/// lines): "walls", "infill", "surface", "speed", "heat", "support",
/// "layers", "move", "rotate", "scale", "add", "remove", "quality",
/// "printer", or "other". A static string.
export fn zs_history_kind(changes: ?[*]const u8, len: usize) [*:0]const u8 {
    const t = if (changes) |p| p[0..len] else "";
    const k = app_mod.history.stepKind(gpa, t) catch return "other";
    return @tagName(k);
}

/// The measurements of a path at one of its segments.
pub const CMeasure = extern struct {
    segment_length: f64,
    edge_length: f64,
    path_length: f64,
    closed: c_int,
    size_x: f64,
    size_y: f64,
    shape: c_int,
    radius: f64,
    center_x: f64,
    center_y: f64,
    angle: f64,
};

export fn zs_app_measure(a: ?*const App, path: usize, seg: usize, out: ?*CMeasure) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const m = app.measurePath(path, seg) catch |e| return switch (e) {
        error.NoResult => @intFromEnum(Status.no_result),
        error.OutOfRange => @intFromEnum(Status.out_of_range),
        error.OutOfMemory => @intFromEnum(Status.out_of_memory),
    };
    o.* = .{
        .segment_length = m.segment_length,
        .edge_length = m.edge_length,
        .path_length = m.path_length,
        .closed = @intFromBool(m.closed),
        .size_x = m.size[0],
        .size_y = m.size[1],
        .shape = @intFromEnum(m.shape),
        .radius = m.radius,
        .center_x = m.center[0],
        .center_y = m.center[1],
        .angle = m.angle,
    };
    return ok;
}

/// An app with one box on the plate, and the start of its undo list.
fn historyTestApp() !*App {
    var a: ?*App = null;
    try std.testing.expectEqual(ok, zs_app_new(null, null, &a));
    errdefer zs_app_free(a);
    var mesh = try zs.mesh.shapes.box(gpa, 20, 20, 10);
    defer mesh.deinit(gpa);
    var stl: Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try mesh.writeStl(&stl.writer);
    try std.testing.expectEqual(ok, zs_app_load_stl(a, "box.stl", stl.written().ptr, stl.written().len));
    try std.testing.expectEqual(@as(c_int, 0), zs_app_history_commit(a, 0));
    try std.testing.expectEqual(@as(usize, 1), zs_app_history_count(a));
    return a.?;
}

fn settingOf(app: *App, name: [*:0]const u8) []const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    var len: usize = 0;
    _ = zs_app_setting_get(app, name, &S.buf, S.buf.len, &len);
    return S.buf[0..len];
}

test "C API: the undo list: one step for an edit with the focus, undo, redo, goto, and truncate" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    var step: HistoryStep = undefined;

    // Three changes of the infill while its editor has the focus: one step.
    _ = zs_app_history_set_focus(app, "project.infill_density", 1);
    for ([_][*:0]const u8{ "0.3", "0.4", "0.5" }, 0..) |v, k| {
        try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", v));
        try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, @intCast(10 + k)));
    }
    try t.expectEqual(@as(usize, 2), zs_app_history_count(app));
    try t.expectEqual(ok, zs_app_history_step(app, 1, &step));
    try t.expectEqualStrings("infill", std.mem.span(step.kind));
    try t.expectEqualStrings("This print\tInfill density 20 % → 50 %\n", step.text[0..step.text_len]);
    try t.expectEqual(@as(i64, 12), step.time_ms);
    // A commit with no change keeps the edit open.
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 20));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.6"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 21));
    try t.expectEqual(@as(usize, 2), zs_app_history_count(app));

    // The walls: a new step.
    _ = zs_app_history_set_focus(app, "project.wall_count", 30);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 31));
    try t.expectEqual(@as(usize, 3), zs_app_history_count(app));

    // A move of the part: a step.
    _ = zs_app_history_set_focus(app, null, 40);
    var part: Part = undefined;
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    const x0 = part.x;
    try t.expectEqual(ok, zs_app_part_move(app, 0, x0 + 30, part.y));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 41));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));
    try t.expectEqual(ok, zs_app_history_step(app, 3, &step));
    try t.expectEqualStrings("move", std.mem.span(step.kind));
    try t.expectEqual(ok, zs_app_history_step(app, 0, &step));
    try t.expectEqualStrings("start", std.mem.span(step.kind));

    // Undo three times: the move, the walls, the infill.
    const H = app_mod.history;
    const undo1 = zs_app_history_undo(app, 50);
    try t.expect(undo1 & H.restored_moved != 0 and undo1 & H.restored_plate != 0);
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    try t.expectApproxEqAbs(x0, part.x, 1e-6);
    const undo2 = zs_app_history_undo(app, 51);
    try t.expect(undo2 & H.restored_plate == 0 and undo2 & (H.restored_group << 2) != 0);
    try t.expectEqualStrings("2", settingOf(app, "project.wall_count"));
    try t.expect(zs_app_history_undo(app, 52) != 0);
    try t.expectEqualStrings("0.2", settingOf(app, "project.infill_density"));
    try t.expectEqual(@as(usize, 0), zs_app_history_current(app));
    try t.expectEqual(@as(c_int, 0), zs_app_history_undo(app, 53));
    // A restore is not a change: no step waits, and a commit adds none.
    try t.expectEqual(@as(c_int, 0), zs_app_history_pending(app));
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 54));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));

    // Redo, then go to the last step.
    try t.expect(zs_app_history_redo(app, 60) != 0);
    try t.expectEqualStrings("0.6", settingOf(app, "project.infill_density"));
    try t.expect(zs_app_history_goto(app, 3, 61) & H.restored_plate != 0);
    try t.expectEqual(@as(usize, 3), zs_app_history_current(app));
    try t.expectEqualStrings("4", settingOf(app, "project.wall_count"));
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    try t.expectApproxEqAbs(x0 + 30, part.x, 1e-6);
    try t.expectEqual(@as(c_int, 0), zs_app_history_goto(app, 3, 62));

    // Clear the history after step 1: it goes to step 1 first.
    const tr = zs_app_history_truncate(app, 1, 70);
    try t.expect(tr & H.restored_dropped != 0 and tr & H.restored_moved != 0);
    try t.expectEqual(@as(usize, 2), zs_app_history_count(app));
    try t.expectEqual(@as(usize, 1), zs_app_history_current(app));
    try t.expectEqualStrings("2", settingOf(app, "project.wall_count"));
    try t.expectEqual(@as(c_int, 0), zs_app_history_redo(app, 71));

    // A revert of one change is a new step.
    try t.expectEqual(ok, zs_app_history_step(app, 1, &step));
    const line = try gpa.dupe(u8, step.changes[0..step.changes_len]);
    defer gpa.free(line);
    try t.expectEqual(ok, zs_app_history_revert(app, line.ptr, line.len));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 80));
    try t.expectEqual(@as(usize, 3), zs_app_history_count(app));
    try t.expectEqualStrings("0.2", settingOf(app, "project.infill_density"));

    // A reset drops the steps; the next commit takes the start.
    zs_app_history_reset(app);
    try t.expectEqual(@as(usize, 0), zs_app_history_count(app));
    try t.expectEqual(@as(c_int, 0), zs_app_history_commit(app, 90));
    try t.expectEqual(@as(usize, 1), zs_app_history_count(app));
}

test "C API: the undo list: an edit back at its old value drops its step; other keys make new steps" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    _ = zs_app_history_set_focus(app, "project.infill_density", 1);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 2));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.2"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 3));
    try t.expectEqual(@as(usize, 1), zs_app_history_count(app));
    // With no focus, each commit is a step.
    _ = zs_app_history_set_focus(app, null, 4);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.4"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 5));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.5"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 6));
    try t.expectEqual(@as(usize, 3), zs_app_history_count(app));
    // A move of the focus commits the edit before it.
    _ = zs_app_history_set_focus(app, "project.infill_density", 7);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.6"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_set_focus(app, "project.wall_count", 8));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));
    // Two settings at once: a step that the next edit does not amend.
    _ = zs_app_history_set_focus(app, "project.wall_count", 9);
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "3"));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.7"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 10));
    try t.expectEqual(ok, zs_app_setting_set(app, "project.wall_count", "5"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 11));
    try t.expectEqual(@as(usize, 6), zs_app_history_count(app));
}

test "C API: the undo list keeps at most max_steps steps and max_plate_bytes of plates" {
    const t = std.testing;
    const app = try historyTestApp();
    defer zs_app_free(app);
    app.undo.max_steps = 3;
    for (0..6) |k| {
        var buf: [16]u8 = undefined;
        const v = try std.fmt.bufPrintZ(&buf, "0.{d}", .{k + 3});
        try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", v.ptr));
        try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, @intCast(k)));
    }
    try t.expectEqual(@as(usize, 3), zs_app_history_current(app));
    try t.expectEqual(@as(usize, 4), zs_app_history_count(app));
    // Steps with the same plate share its file: the cap counts it once.
    const file = try app.write3mfAlloc(gpa);
    const size = file.len;
    gpa.free(file);
    app.undo.max_steps = 100;
    app.undo.max_plate_bytes = size + size / 2;
    try t.expectEqual(ok, zs_app_setting_set(app, "project.infill_density", "0.9"));
    try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, 10));
    try t.expectEqual(@as(usize, 4), zs_app_history_current(app));
    var part: Part = undefined;
    try t.expectEqual(ok, zs_app_part_get(app, 0, &part));
    for (0..3) |k| {
        try t.expectEqual(ok, zs_app_part_move(app, 0, part.x + @as(f64, @floatFromInt(k + 1)), part.y));
        try t.expectEqual(@as(c_int, 1), zs_app_history_commit(app, @intCast(20 + k)));
    }
    // Before the step now: one plate file is left.
    try t.expectEqual(@as(usize, 1), zs_app_history_current(app));
}
