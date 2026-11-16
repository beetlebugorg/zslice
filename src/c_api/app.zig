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

export fn zs_app_new(event_fn: ?app_mod.EventFn, user: ?*anyopaque, out: ?*?*App) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = App.create(gpa, event_fn, user) catch |e| return status(e);
    return ok;
}

export fn zs_app_free(a: ?*App) void {
    const app = a orelse return;
    app.destroy();
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
};

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
    return ok;
}

/// Removes the marks near a place. Returns how many.
export fn zs_app_mark_remove_near(a: ?*App, x: f64, y: f64, z: f64, r: f64) usize {
    const app = a orelse return 0;
    return app.removeMarksNear(x, y, z, r);
}

export fn zs_app_mark_count(a: ?*const App) usize {
    const app = a orelse return 0;
    return app.marks.items.len;
}

export fn zs_app_marks_clear(a: ?*App) void {
    const app = a orelse return;
    app.clearMarks();
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
};

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
    };
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
    return ok;
}

/// Removes the overrides of a setting that cover z. Returns how many.
export fn zs_app_override_clear_at(a: ?*App, z: f64, name: ?[*:0]const u8) usize {
    const app = a orelse return 0;
    return app.clearOverridesAt(z, std.mem.span(name orelse return 0));
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

export fn zs_app_part_move(a: ?*App, i: usize, x: f64, y: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.movePart(i, x, y) catch |e| return status(e);
    return ok;
}

export fn zs_app_part_rotate(a: ?*App, i: usize, degrees: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.rotatePart(i, degrees) catch |e| return status(e);
    return ok;
}

export fn zs_app_part_scale(a: ?*App, i: usize, sx: f64, sy: f64, sz: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.scalePart(i, .{ sx, sy, sz }) catch |e| return status(e);
    return ok;
}

export fn zs_app_part_turn(a: ?*App, i: usize, axis: c_int, degrees: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or axis < 0 or axis > 1) return @intFromEnum(Status.out_of_range);
    app.turnPart(i, @intCast(axis), degrees) catch |e| return status(e);
    return ok;
}

export fn zs_app_part_put_down_at(a: ?*App, i: usize, x: f64, y: f64, z: f64) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.putPartDownAt(i, x, y, z) catch |e| return status(e);
    return ok;
}

export fn zs_app_part_place(a: ?*App, i: usize, mode: c_int, axis: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count() or mode < 0 or mode > 2 or axis < 0 or axis > 2) return @intFromEnum(Status.out_of_range);
    app.placePart(i, @enumFromInt(@as(u8, @intCast(mode))), @intCast(axis)) catch |e| return status(e);
    return ok;
}

export fn zs_app_part_reset(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.resetPart(i) catch |e| return status(e);
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
    return @intCast(i);
}

export fn zs_app_plate_select(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plateCount()) return @intFromEnum(Status.out_of_range);
    app.selectPlate(i) catch |e| return status(e);
    return ok;
}

export fn zs_app_plate_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plateCount()) return @intFromEnum(Status.out_of_range);
    app.removePlate(i) catch |e| return status(e);
    return ok;
}

/// Smart placement of all parts, then an arrange. 1 if they all fit.
export fn zs_app_plate_smart_place(a: ?*App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.smartPlacePlate() catch return 0);
}

export fn zs_app_part_remove(a: ?*App, i: usize) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (i >= app.plate.count()) return @intFromEnum(Status.out_of_range);
    app.removePart(i) catch |e| return status(e);
    return ok;
}

/// 1 if all parts fit on the bed, 0 if not.
export fn zs_app_plate_arrange(a: ?*App) c_int {
    const app = a orelse return 0;
    return @intFromBool(app.arrangePlate() catch false);
}

export fn zs_app_plate_clear(a: ?*App) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.clearPlate() catch |e| return status(e);
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

/// Sets all settings of a group to the built-in defaults.
export fn zs_app_group_reset(a: ?*App, group: c_int) c_int {
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    app.resetGroup(groupOf(group) orelse return @intFromEnum(Status.invalid_argument));
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
