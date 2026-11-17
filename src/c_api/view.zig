//! The C API of the 3D view, the `zs_view_*` functions of
//! `include/zslice-app.h`. See src/render/view.zig. The rules of the API
//! are in c_api.zig.

const std = @import("std");
const builtin = @import("builtin");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const status = c.status;
const ok = c.ok;
const is_wasm = c.is_wasm;
const App = zs.app.App;

/// The renderer needs libc (it loads the Vulkan loader with dlopen). It is
/// on Linux now. Other targets get "not supported" from each call.
const render_on = builtin.os.tag == .linux and builtin.link_libc and !is_wasm;
const view_mod = if (render_on) @import("../render/view.zig") else struct {
    pub const View = opaque {};
};
const View = view_mod.View;

pub const CSurface = extern struct {
    kind: c_int,
    display: ?*anyopaque,
    surface: ?*anyopaque,
    window: u64,
};

export fn zs_view_new(surface: ?*const CSurface, width: u32, height: u32, out: ?*?*View) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const s = surface orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const native: view_mod.Surface = switch (s.kind) {
        1 => .{ .wayland = .{ .display = s.display orelse return @intFromEnum(Status.invalid_argument), .surface = s.surface orelse return @intFromEnum(Status.invalid_argument) } },
        2 => .{ .xlib = .{ .display = s.display orelse return @intFromEnum(Status.invalid_argument), .window = s.window } },
        else => return @intFromEnum(Status.not_supported),
    };
    o.* = View.create(native, width, height) catch |e| return status(e);
    return ok;
}

export fn zs_view_free(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.destroy();
}

export fn zs_view_resize(view: ?*View, width: u32, height: u32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.resize(width, height);
}

export fn zs_view_load(view: ?*View, a: ?*const App) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    v.load(app) catch |e| return status(e);
    return ok;
}

export fn zs_view_isolate(view: ?*View, on: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.isolate = on != 0;
}

export fn zs_view_set_layer_range(view: ?*View, lo: usize, hi: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setLayerRange(lo, hi);
}

export fn zs_view_set_layer(view: ?*View, layer: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setLayer(layer);
}

export fn zs_view_orbit(view: ?*View, dx: f32, dy: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.orbit(dx, dy);
}

export fn zs_view_zoom(view: ?*View, factor: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.zoom(factor);
}

export fn zs_view_zoom_at(view: ?*View, factor: f32, px: f32, py: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.zoomAtSmooth(factor, px, py);
}

export fn zs_view_reset_smooth(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.resetSmooth();
}

/// Moves the camera toward its goal for dt seconds. 1 while it still
/// moves, 0 when it is at rest.
export fn zs_view_animate(view: ?*View, dt: f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return @intFromBool(v.animate(@floatCast(dt)));
}

export fn zs_view_pan(view: ?*View, dx: f32, dy: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.pan(dx, dy);
}

/// A negative zmax: all layers.
export fn zs_view_focus(view: ?*View, features: u32, zmax: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setFocus(features, if (zmax < 0) std.math.inf(f32) else @floatCast(zmax));
}

/// A frame on the bed around (x0, y0)-(x1, y1), for a selected part; no
/// frame if x1 < x0.
export fn zs_view_part_box(view: ?*View, x0: f64, y0: f64, x1: f64, y1: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setPartBox(if (x1 < x0) null else .{ @floatCast(x0), @floatCast(y0), @floatCast(x1), @floatCast(y1) });
}

/// The point of the bed (z = 0) under the pixel (px, py). Returns 0 if the
/// ray does not meet the bed.
export fn zs_view_bed_point(view: ?*const View, px: f32, py: f32, x: ?*f64, y: ?*f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const p = v.bedPoint(px, py) orelse return 0;
    if (x) |o| o.* = p[0];
    if (y) |o| o.* = p[1];
    return 1;
}

/// Shows the gaps of layer `layer` of the last slice of `app` in red, or
/// none for a negative layer.
export fn zs_view_show_gaps(view: ?*View, app: ?*App, layer: i64) void {
    if (!render_on) return;
    const v = view orelse return;
    const a = app orelse return;
    v.setGaps(a, if (layer < 0) null else @intCast(layer));
}

/// The index of the shown gap under the pixel (px, py), or -1.
export fn zs_view_gap_at(view: ?*const View, app: ?*App, px: f32, py: f32) i64 {
    if (!render_on) return -1;
    const v = view orelse return -1;
    const a = app orelse return -1;
    return if (v.gapAt(a, px, py)) |i| @intCast(i) else -1;
}

export fn zs_view_rotate(view: ?*View, dx: f32, dy: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.rotate(dx, dy);
}

export fn zs_view_turn(view: ?*View, dx: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    v.turn(dx);
}

export fn zs_view_reset(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.reset();
}

export fn zs_view_set_mode(view: ?*View, mode: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setMode(if (mode >= 0 and mode <= 5) @enumFromInt(mode) else .print);
}

/// The range of the color ramp of a value mode (speed, flow, layer time,
/// line width), in mm/s, mm3/s, s, or mm. 0 for the other modes.
export fn zs_view_legend(view: ?*const View, min: ?*f64, max: ?*f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    if (min) |m| m.* = v.legend[0];
    if (max) |m| m.* = v.legend[1];
    return @intFromBool(v.legend[1] > v.legend[0]);
}

/// Highlights the beads of one path (an index into zs_app_toolpaths), or
/// nothing if path is (size_t)-1.
export fn zs_view_highlight(view: ?*View, path: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setHighlight(if (path == std.math.maxInt(usize)) null else path);
}

/// Replay: show the print at t seconds after the start. A negative t
/// returns to whole layers.
export fn zs_view_set_time(view: ?*View, t: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    if (t < 0) v.time = null else v.setTime(@floatCast(t));
}

/// The replay length: the print time at the end of the last bead.
export fn zs_view_duration(view: ?*const View) f64 {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.duration();
}

/// The layer that the nozzle prints at time t.
export fn zs_view_layer_at_time(view: ?*const View, t: f64) usize {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.layerAtTime(@floatCast(t));
}

/// The path under the pixel (px, py), or (size_t)-1.
export fn zs_view_pick(view: ?*View, px: f32, py: f32) usize {
    if (!render_on) return std.math.maxInt(usize);
    const v = view orelse return std.math.maxInt(usize);
    return v.pick(px, py) orelse std.math.maxInt(usize);
}

export fn zs_view_pick_segment(view: ?*View, px: f32, py: f32, seg: ?*usize) usize {
    if (!render_on) return std.math.maxInt(usize);
    const v = view orelse return std.math.maxInt(usize);
    const hit = v.pickSegment(px, py) orelse return std.math.maxInt(usize);
    if (seg) |s| s.* = hit[1];
    return hit[0];
}

/// The other paths of a multiple selection (yellow), or none (n = 0).
export fn zs_view_highlight_more(view: ?*View, paths: ?[*]const usize, n: usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const list: []const usize = if (paths) |p| p[0..n] else &.{};
    v.setMore(list) catch |e| return status(e);
    return ok;
}

export fn zs_view_highlight_segment(view: ?*View, path: usize, seg: isize) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setSegment(path, if (seg < 0) null else @intCast(seg));
}

export fn zs_view_draw(view: ?*View) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    v.draw() catch |e| return status(e);
    return ok;
}

test "C API: the view module compiles" {
    if (render_on) _ = &view_mod.View.create;
}

test {
    // The tests of the view module (its math needs no GPU).
    if (render_on) _ = view_mod;
}
