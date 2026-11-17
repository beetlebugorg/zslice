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

/// The Vulkan renderer needs libc (it loads the Vulkan loader with
/// dlopen). It is on Linux now. The wasm build has the web backend (see
/// src/render/web.zig): the view keeps the frame data, and the JavaScript
/// side draws it. Other targets get "not supported" from each call.
const render_on = (builtin.os.tag == .linux and builtin.link_libc and !is_wasm) or is_wasm;
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
    const native: view_mod.Surface = if (is_wasm) switch (s.kind) {
        3 => .web,
        else => return @intFromEnum(Status.not_supported),
    } else switch (s.kind) {
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

/// The point of the print under the pixel, for the measure tape (see
/// View.surfacePoint): out gets x, y, z in mm. With snap, the end of a line
/// near the pixel. 0 if the pixel shows neither the print nor the bed.
export fn zs_view_surface_point(view: ?*const View, px: f32, py: f32, snap: c_int, out: ?*[3]f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const p = v.surfacePoint(px, py, snap != 0) orelse return 0;
    if (out) |o| o.* = .{ p[0], p[1], p[2] };
    return 1;
}

/// The points of the measure tape: n (0, 1, or 2) points of 3 values.
export fn zs_view_set_measure(view: ?*View, n: usize, pts: ?[*]const f64) void {
    if (!render_on) return;
    const v = view orelse return;
    var buf: [2][3]f32 = undefined;
    const k = @min(n, 2);
    if (k > 0) {
        const p = pts orelse return;
        for (0..k) |i| buf[i] = .{ @floatCast(p[3 * i]), @floatCast(p[3 * i + 1]), @floatCast(p[3 * i + 2]) };
    }
    v.setMeasure(buf[0..k]);
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

// ---- the 2D view of one layer, and the steps along the print ----

/// The path and the segment of `layer` nearest to (x, y) mm, closer than
/// twice the bead width, or (size_t)-1.
export fn zs_view_pick_layer(view: ?*const View, layer: usize, x: f64, y: f64, seg: ?*usize) usize {
    if (!render_on) return std.math.maxInt(usize);
    const v = view orelse return std.math.maxInt(usize);
    const hit = v.pickLayer(layer, @floatCast(x), @floatCast(y)) orelse return std.math.maxInt(usize);
    if (seg) |s| s.* = hit[1];
    return hit[0];
}

/// The beads of a layer (first, end) in the instances of the view.
export fn zs_view_layer_beads(view: ?*const View, layer: usize, first: ?*u32, end: ?*u32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const r = v.layerBeads(layer);
    if (first) |f| f.* = r[0];
    if (end) |e| e.* = r[1];
    return ok;
}

/// The marks of a layer (first, end) in the instances, after the beads.
export fn zs_view_layer_marks(view: ?*const View, layer: usize, first: ?*u32, end: ?*u32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const r = v.layerMarks(layer);
    if (first) |f| f.* = r[0];
    if (end) |e| e.* = r[1];
    return ok;
}

/// The beads of a path (first, end): bead first + k is segment k.
export fn zs_view_path_beads(view: ?*const View, path: usize, first: ?*u32, end: ?*u32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const r = v.pathBeads(path);
    if (first) |f| f.* = r[0];
    if (end) |e| e.* = r[1];
    return ok;
}

export fn zs_view_path_layer(view: ?*const View, path: usize) usize {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.layerOfPath(path);
}

export fn zs_view_path_segments(view: ?*const View, path: usize) usize {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.segments(path);
}

/// The outlines of all layers: the points (x, y pairs), the end of each
/// ring in points, and the end of each layer in rings.
export fn zs_view_outlines(view: ?*const View, points: ?*?[*]const f32, n_points: ?*usize, ring_ends: ?*?[*]const u32, n_rings: ?*usize, layer_ends: ?*?[*]const u32, n_layers: ?*usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    if (points) |p| p.* = v.outline_points.items.ptr;
    if (n_points) |n| n.* = v.outline_points.items.len / 2;
    if (ring_ends) |p| p.* = v.outline_ends.items.ptr;
    if (n_rings) |n| n.* = v.outline_ends.items.len;
    if (layer_ends) |p| p.* = v.outline_layer_end.items.ptr;
    if (n_layers) |n| n.* = v.outline_layer_end.items.len;
    return ok;
}

/// The box of the beads on the bed: x0, y0, x1, y1 in mm.
export fn zs_view_bounds(view: ?*const View, out: ?*[4]f64) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const b = v.bounds() orelse return @intFromEnum(Status.no_result);
    for (0..4) |k| o[k] = b[k];
    return ok;
}

/// One step along the print from (*path, *seg); *seg < 0 is the whole
/// path. Returns 1 and sets both, or 0 at an end of the print.
export fn zs_view_step(view: ?*const View, path: ?*usize, seg: ?*isize, dir: c_int, whole_path: c_int) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const p = path orelse return 0;
    const s = seg orelse return 0;
    const r = v.stepPath(p.*, if (s.* < 0) null else @intCast(s.*), if (dir < 0) -1 else 1, whole_path != 0) orelse return 0;
    p.* = r.path;
    s.* = if (r.seg) |k| @intCast(k) else -1;
    return 1;
}

export fn zs_view_nearest_on_layer(view: ?*const View, path: usize, layer: usize) usize {
    if (!render_on) return std.math.maxInt(usize);
    const v = view orelse return std.math.maxInt(usize);
    return v.nearestOnLayer(path, layer) orelse std.math.maxInt(usize);
}

export fn zs_view_segment_end_time(view: ?*const View, path: usize, seg: usize) f64 {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.segmentEndTime(path, seg);
}

export fn zs_view_segment_at_time(view: ?*const View, t: f64, path: ?*usize, seg: ?*usize) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const hit = v.segmentAtTime(@floatCast(t)) orelse return 0;
    if (path) |p| p.* = hit[0];
    if (seg) |s| s.* = hit[1];
    return 1;
}

/// The loaded scene as bytes, for a view in another wasm instance (see
/// src/render/view.zig). Free them with zs_buffer_free.
export fn zs_view_scene_write(view: ?*View, out: ?*?[*]u8, out_len: ?*usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const l = out_len orelse return @intFromEnum(Status.invalid_argument);
    const bytes = v.writeScene(c.gpa) catch |e| return status(e);
    o.* = bytes.ptr;
    l.* = bytes.len;
    return ok;
}

/// Reads the bytes of zs_view_scene_write: the same as zs_view_load of that
/// slice.
export fn zs_view_scene_read(view: ?*View, data: ?[*]const u8, len: usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    v.readScene(d[0..len]) catch |e| return status(e);
    return ok;
}

/// wasm: the frame data of the web backend (zs_web_frame in
/// zslice-app.h). NULL on the other targets.
export fn zs_view_web_frame(view: ?*View) ?*const anyopaque {
    if (comptime !is_wasm) return null;
    const v = view orelse return null;
    return &v.renderer.out;
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
