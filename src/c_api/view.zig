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
const GCode = @import("gcode.zig").GCode;

/// The Vulkan renderer needs libc (it loads the Vulkan loader with
/// dlopen). It is on Linux. Windows has the Direct3D 12 renderer
/// (src/render/d3d12.zig). The wasm build and macOS have the frame
/// backend (see src/render/web.zig): the view keeps the frame data, and
/// the shell draws it (WebGL2 in JavaScript, Metal in Swift). Other
/// targets get "not supported" from each call.
const is_mac = builtin.os.tag == .macos and builtin.link_libc;
pub const frame_backend = is_wasm or is_mac;
const is_windows = builtin.os.tag == .windows and builtin.link_libc;
pub const render_on = (builtin.os.tag == .linux and builtin.link_libc and !is_wasm) or is_windows or frame_backend;
pub const view_mod = if (render_on) @import("../render/view.zig") else struct {
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
    const native: view_mod.Surface = if (frame_backend) switch (s.kind) {
        3 => .web,
        else => return @intFromEnum(Status.not_supported),
    } else if (is_windows) switch (s.kind) {
        4 => .panel,
        else => return @intFromEnum(Status.not_supported),
    } else switch (s.kind) {
        1 => .{ .wayland = .{ .display = s.display orelse return @intFromEnum(Status.invalid_argument), .surface = s.surface orelse return @intFromEnum(Status.invalid_argument) } },
        2 => .{ .xlib = .{ .display = s.display orelse return @intFromEnum(Status.invalid_argument), .window = s.window } },
        else => return @intFromEnum(Status.not_supported),
    };
    o.* = View.create(native, width, height) catch |e| return status(e);
    return ok;
}

/// The DXGI swapchain of a view on a ZS_SURFACE_PANEL (an IDXGISwapChain).
/// The view keeps its reference. The shell attaches it to its panel.
export fn zs_view_swapchain(view: ?*View, out: ?*?*anyopaque) c_int {
    if (!is_windows) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    o.* = v.renderer.swapchainPtr() orelse return @intFromEnum(Status.not_supported);
    return ok;
}

/// The flags of zs_view_offscreen.
const offscreen_reduced = 1;
const offscreen_bgra = 2;

/// A view that draws into an image that it owns, with no window: the host
/// reads each frame with zs_view_read. `mode`: offscreen_reduced for the
/// reduced view of a printer screen, offscreen_bgra for B, G, R, A bytes.
export fn zs_view_offscreen(width: u32, height: u32, mode: c_int, out: ?*?*View) c_int {
    if (!render_on or frame_backend) return @intFromEnum(Status.not_supported);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return @intFromEnum(Status.invalid_argument);
    const v = View.create(.{ .offscreen = .{ .bgra = mode & offscreen_bgra != 0 } }, width, height) catch |e| return status(e);
    v.setReduced(mode & offscreen_reduced != 0) catch |e| {
        v.destroy();
        return status(e);
    };
    o.* = v;
    return ok;
}

/// Copies the last frame of an offscreen view to `out`: `stride` bytes
/// from one row to the next, rows from the top, 4 bytes for each pixel.
/// Waits for the frame. ZS_BUSY before the first zs_view_draw.
export fn zs_view_read(view: ?*View, out: ?[*]u8, len: usize, stride: usize) c_int {
    if (!render_on or frame_backend) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const size = v.renderer.targetSize();
    if (size[1] > 0 and (stride < @as(usize, size[0]) * 4 or len < stride * (size[1] - 1) + @as(usize, size[0]) * 4)) return @intFromEnum(Status.invalid_argument);
    v.renderer.read(o[0..len], stride) catch |e| return status(e);
    return ok;
}

/// Shows a G-code file (see zs_gcode_open). Keep the zs_gcode while the
/// view shows it. bed_x, bed_y: the bed size in mm (0: around the part).
export fn zs_view_load_gcode(view: ?*View, g: ?*const GCode, bed_x: f64, bed_y: f64) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const h = g orelse return @intFromEnum(Status.invalid_argument);
    if (!h.r.finished) return @intFromEnum(Status.invalid_argument);
    v.loadGcode(&h.r, .{ @floatCast(bed_x), @floatCast(bed_y) }) catch |e| return status(e);
    return ok;
}

/// The print at a byte offset of the file (the file position that
/// Klipper reports): the moves read so far, the layer lit, the nozzle.
export fn zs_view_set_position(view: ?*View, offset: u64) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setPosition(offset);
}

/// The colors of a G-code file: by_feature != 0 for one color for each
/// feature, else the filament color rgb (0xRRGGBB).
export fn zs_view_gcode_colors(view: ?*View, by_feature: c_int, rgb: u32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    v.setGcodeColors(by_feature != 0, .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) }) catch |e| return status(e);
    return ok;
}

/// The reduced view of a printer screen (on != 0): no tools, gizmos,
/// selection, marks, or labels.
export fn zs_view_set_reduced(view: ?*View, on: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setReduced(on != 0) catch {};
}

/// A print view: show the nozzle at the position (on != 0, the default),
/// and light the top layer (lit != 0, the default).
export fn zs_view_print_look(view: ?*View, nozzle: c_int, lit: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.show_head = nozzle != 0;
    v.lit = lit != 0;
}

/// A finger on a touch screen: action 0 down, 1 move, 2 up, 3 cancel; x,
/// y in pixels. One finger orbits; two pinch to zoom and pan.
export fn zs_view_touch(view: ?*View, id: i64, action: c_int, x: f32, y: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    if (action < 0 or action > 3) return;
    v.touch(id, @enumFromInt(action), x, y);
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
    // With zs_app_set_auto_scene, the view takes the scenes of the worker:
    // they change only atomic fields of the app.
    if (app.scene_hook.load(.acquire) != null) {
        v.loadScenes(@constCast(app)) catch |e| return status(e);
    } else v.load(app) catch |e| return status(e);
    return ok;
}

/// A load can leave the new scene waiting while a thread copies its beads
/// into the GPU; the view draws the old scene until then. Returns 1 if
/// the new scene went in now: then apply the selection and the other
/// state of a load again (zs_view_load keeps the beads). Call it before
/// each frame while zs_view_scene_pending is 1.
export fn zs_view_scene_poll(view: ?*View) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return @intFromBool(v.pollScene() catch false);
}

/// 1 while a new scene waits for the copy of its beads into the GPU.
export fn zs_view_scene_pending(view: ?*const View) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return @intFromBool(v.scenePending());
}

/// Builds the scene of the 3D view on the thread of the slice (on = 1):
/// after each slice and each simulation on that thread, before
/// ZS_EVENT_SLICED and ZS_EVENT_SIMULATED. zs_view_load then takes it, and
/// only sends the beads to the GPU. The scene has the color mode of the
/// last zs_view_load.
export fn zs_app_set_auto_scene(a: ?*App, on: c_int) c_int {
    if (comptime !render_on) return @intFromEnum(Status.not_supported);
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    if (on == 0) {
        app.setSceneHook(null);
        return ok;
    }
    app.setSceneHook(&scene_hook);
    return ok;
}

const scene_hook: zs.app.SceneHook = .{ .build = View.buildScene, .free = View.freeScene, .write = View.sceneBytes };

/// The bed model of model i of a library: the bytes of its mesh and
/// texture files (see zs_printers_bed; either can be empty).
export fn zs_view_set_bed(view: ?*View, lib: ?*const zs.printers.Library, i: usize, mesh: ?[*]const u8, mesh_len: usize, texture: ?[*]const u8, texture_len: usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const l = lib orelse return @intFromEnum(Status.invalid_argument);
    if (i >= l.models.len) return @intFromEnum(Status.out_of_range);
    const b = l.bed(i) orelse return @intFromEnum(Status.no_result);
    const m: []const u8 = if (mesh) |p| p[0..mesh_len] else "";
    const t: []const u8 = if (texture) |p| p[0..texture_len] else "";
    v.setBed(.{ .offset = b.offset, .rect = b.rect, .round = l.models[i].round }, m, t) catch |e| return status(e);
    return ok;
}

export fn zs_view_clear_bed(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.clearBed();
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

/// Looks at the point (x, y, z) from the side that faces (nx, ny, nz), from
/// `dist` mm; the camera moves there in steps (zs_view_animate).
export fn zs_view_look_at(view: ?*View, x: f32, y: f32, z: f32, nx: f32, ny: f32, nz: f32, dist: f32) void {
    if (!render_on) return;
    const v = view orelse return;
    const l = @sqrt(nx * nx + ny * ny + nz * nz);
    if (!(l > 0)) return;
    v.lookAtSmooth(.{ x, y, z }, .{ nx / l, ny / l, nz / l }, dist);
}

/// A double click at the pixel (px, py): the camera turns to face the side
/// of the print there, and zooms to it (from 1.4 times `size` mm, at least
/// 20; 0: the size of the print). 1 if the camera moves; 0 if the pixel
/// shows no side of the print (the shell then resets the view).
export fn zs_view_look_at_side(view: ?*View, px: f32, py: f32, size: f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return @intFromBool(v.lookAtSide(px, py, size));
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
/// Returns 1 if the focus shows lines, 0 if the plate has no line of these
/// features (the view then shows the whole print, so a shell can say "no
/// lines of this setting on this plate").
export fn zs_view_focus(view: ?*View, features: u32, zmax: f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return @intFromBool(v.setFocus(features, if (zmax < 0) std.math.inf(f32) else @floatCast(zmax)));
}

/// A frame on the bed around (x0, y0)-(x1, y1), for a selected part; no
/// frame if x1 < x0.
export fn zs_view_part_box(view: ?*View, x0: f64, y0: f64, x1: f64, y1: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setPartBox(if (x1 < x0) null else .{ @floatCast(x0), @floatCast(y0), @floatCast(x1), @floatCast(y1) });
}

/// A frame on the bed around each of n boxes (x0, y0, x1, y1 each), for
/// the selected parts. n = 0: no frame.
export fn zs_view_part_boxes(view: ?*View, boxes: ?[*]const f64, n: usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    if (n > 0 and boxes == null) return @intFromEnum(Status.invalid_argument);
    const list = c.gpa.alloc([4]f32, n) catch return @intFromEnum(Status.out_of_memory);
    defer c.gpa.free(list);
    var k: usize = 0;
    for (0..n) |i| {
        const b = boxes.?[i * 4 ..][0..4];
        if (b[2] < b[0]) continue;
        list[k] = .{ @floatCast(b[0]), @floatCast(b[1]), @floatCast(b[2]), @floatCast(b[3]) };
        k += 1;
    }
    v.setPartBoxes(list[0..k]) catch |e| return status(e);
    return ok;
}

/// Lights the layers lo to hi as a selection, and shows the other beads as
/// ghosts. hi < lo: no light.
export fn zs_view_light_layers(view: ?*View, lo: usize, hi: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setLightLayers(if (hi < lo) null else .{ lo, hi });
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

/// The point under the pixel on the level plane at height z (mm): the place
/// of the hand that carries a part. 0 if the plane is not under the pixel.
export fn zs_view_plane_point(view: ?*const View, px: f32, py: f32, z: f64, x: ?*f64, y: ?*f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const p = v.planePoint(px, py, z) orelse return 0;
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

/// The ray of the camera through a pixel: out gets the eye (x, y, z) and
/// the direction (a unit vector), for zs_paint_hit. 0 with no view.
export fn zs_view_ray(view: ?*const View, px: f32, py: f32, out: ?*[6]f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const o = out orelse return 0;
    o.* = v.ray(px, py);
    return 1;
}

/// The pixel of a point of the world (mm), or 0 if it is behind the
/// camera: for a grab of an end of the measure tape.
export fn zs_view_pixel_of(view: ?*const View, x: f64, y: f64, z: f64, px: ?*f32, py: ?*f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const q = v.pixelOf(.{ @floatCast(x), @floatCast(y), @floatCast(z) }) orelse return 0;
    if (px) |o| o.* = q[0];
    if (py) |o| o.* = q[1];
    return 1;
}

/// The points of the measure tape: n (0, 1, or 2) points of 3 values.
/// The plane of a cut: the box x0, y0, x1, y1 (mm) at height z, drawn in
/// orange. A box with no area hides it.
export fn zs_view_set_cut(view: ?*View, x0: f64, y0: f64, x1: f64, y1: f64, z: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setCut(.{ @floatCast(x0), @floatCast(y0), @floatCast(x1), @floatCast(y1) }, @floatCast(z));
}

/// The support areas that the view draws (the support editor): no areas.
/// A load of the app fills them from its areas; a shell that edits an area
/// sets them again with zs_view_support_add.
export fn zs_view_support_clear(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.clearSupportAreas();
}

/// One more support area to draw: n points of x, y, z (mm) in pts, its
/// kind (enum zs_mark_kind: block is red, the others blue), and flags: 1
/// closed (an area with a fill hint; else a path that the user draws now),
/// 2 selected (a thicker line and its points), 4 its points, 8 bare (a
/// path in the air, as the nodes of the support trees: no fill hint; with
/// 4, only a small bead at each point, and no lines).
export fn zs_view_support_add(view: ?*View, pts: ?[*]const f64, n: usize, kind: c_int, flags: c_int) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const p = pts orelse return 0;
    var buf: [256][3]f32 = undefined;
    const k = @min(n, buf.len);
    for (buf[0..k], 0..) |*q, i| q.* = .{ @floatCast(p[3 * i]), @floatCast(p[3 * i + 1]), @floatCast(p[3 * i + 2]) };
    v.addSupportArea(buf[0..k], @intCast(std.math.clamp(kind, 0, 255)), @intCast(std.math.clamp(flags, 0, 255))) catch return 0;
    return 1;
}

/// The labels of the Label tool that the view draws as decals: none.
export fn zs_view_labels_clear(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.clearLabels();
}

/// One more label to draw as a decal: its frame (origin, normal, right:
/// 9 values, as in the JSON of a label), its outline (pts, ends, n as
/// zs_label_outline gives them), its color 0xRRGGBB, and selected != 0
/// for an outline around it. 1 if the view has it.
export fn zs_view_label_add(view: ?*View, frame: ?*const [9]f64, pts: ?[*]const f32, ends: ?[*]const u32, n: usize, rgb: u32, selected: c_int) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const f = frame orelse return 0;
    if (n == 0) return 0;
    const e = (ends orelse return 0)[0..n];
    var count: usize = 0;
    for (e) |x| count = @max(count, x);
    const p: []const [2]f32 = if (count > 0) @as([*]const [2]f32, @ptrCast(pts orelse return 0))[0..count] else &.{};
    v.addLabel(f.*, p, e, rgb, selected != 0) catch return 0;
    return 1;
}

/// The mesh of the Paint tool: the view draws it in place of the beads,
/// each triangle in the color of its state (zs_view_paint_colors). verts:
/// nv points x, y, z (mm, the frame of zs_app_part_mesh); faces: nf
/// triangles of three indexes. All states are 0 at first. nf = 0: no
/// mesh, and the beads draw again. 1 if the view has it.
export fn zs_view_paint_mesh(view: ?*View, verts: ?[*]const f32, nv: usize, faces: ?[*]const u32, nf: usize) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    if (nf == 0) {
        v.clearPaint();
        return 1;
    }
    const p = verts orelse return 0;
    const f = faces orelse return 0;
    v.setPaintMesh(p[0 .. 3 * nv], f[0 .. 3 * nf]) catch return 0;
    return 1;
}

/// The color 0xRRGGBB of each state of the paint mesh, from state 0 (at
/// most 32).
export fn zs_view_paint_colors(view: ?*View, rgb: ?[*]const u32, n: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    const colors = rgb orelse return;
    v.setPaintColors(colors[0..n]);
}

/// The state of each triangle of the paint mesh (zs_paint_states), plus
/// 128 for a lit triangle, and the nl pieces of the split triangles
/// (zs_paint_leaves: 10 floats each). 1 if the view has them.
export fn zs_view_paint_states(view: ?*View, states: ?[*]const u8, n: usize, leaves: ?[*]const f32, nl: usize) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const s: []const u8 = if (states) |p| p[0..n] else &.{};
    const l: []const f32 = if (leaves) |p| p[0 .. 10 * nl] else &.{};
    v.setPaintStates(s, l) catch return 0;
    return 1;
}

/// on != 0: a pick of a point of the print (zs_view_surface_point,
/// zs_view_pick) skips the support lines, so a click finds the part under
/// them (the Support tool).
export fn zs_view_pick_skip_support(view: ?*View, on: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.pick_skip_support = on != 0;
}

/// The rings of the Turn tool around (x, y, z) with radius `radius` mm
/// (0: no rings). The view draws them: red about X, green about Y, blue
/// about Z.
export fn zs_view_set_rings(view: ?*View, x: f64, y: f64, z: f64, radius: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    v.setRings(.{ @floatCast(x), @floatCast(y), @floatCast(z) }, @floatCast(radius));
}

/// The ring under the pixel (px, py) within tol pixels: 0 X, 1 Y, 2 Z,
/// or -1.
export fn zs_view_ring_at(view: ?*const View, px: f32, py: f32, tol: f32) c_int {
    if (!render_on) return -1;
    const v = view orelse return -1;
    return v.ringAt(px, py, tol);
}

/// Starts a turn on the ring of `axis` at the pixel. 1 if it started.
export fn zs_view_ring_press(view: ?*View, axis: c_int, px: f32, py: f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    if (axis < 0 or axis > 2) return 0;
    return @intFromBool(v.ringPress(@intCast(axis), px, py));
}

/// The turn since the press, degrees, in steps of step_deg (0: none),
/// with the sense of the ring on the screen. Send the difference to the
/// last value to the part (zs_app_part_turn).
export fn zs_view_ring_drag(view: ?*const View, px: f32, py: f32, step_deg: f32) f64 {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.ringDrag(px, py, step_deg);
}

/// The end of a turn.
export fn zs_view_ring_release(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.ringRelease();
}

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

/// The gaps of a layer from their runs (zs_gap_run: y, x0, x1 in mm), for
/// a view with no app (the web page): see View.setGapRuns. A negative
/// layer: none.
export fn zs_view_set_gap_runs(view: ?*View, layer: i64, layer_z: f32, runs: ?[*]const zs.gaps.Run, n: usize, cell: f64) void {
    if (!render_on) return;
    const v = view orelse return;
    if (layer < 0) {
        v.gap_beads.clearRetainingCapacity();
        v.gap_layer = null;
        return;
    }
    v.setGapRuns(@intCast(layer), layer_z, if (runs) |r| r[0..n] else &.{}, cell);
}

/// The point (x, y in mm) under the pixel on the top of a layer at z mm,
/// for a pick of a gap in an app of another instance (zs_app_gap_at). 0 if
/// the ray misses it.
export fn zs_view_layer_point(view: ?*const View, px: f32, py: f32, layer_z: f32, x: ?*f64, y: ?*f64) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const p = v.layerPoint(px, py, layer_z) orelse return 0;
    if (x) |o| o.* = p[0];
    if (y) |o| o.* = p[1];
    return 1;
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

/// Frames the beads of a loaded G-code file at once: the part in the
/// middle, filling `fill` of the smaller side (0.8 is a good value). Call it
/// again after a resize. Returns 1, or 0 with no G-code.
export fn zs_view_frame_part(view: ?*View, fill: f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return @intFromBool(v.framePart(fill));
}

/// The camera, for a restore after a reload: 8 floats, the target (x, y,
/// z), the rotation (a quaternion x, y, z, w), and the distance.
export fn zs_view_get_camera(view: ?*const View, out: ?[*]f32) void {
    if (!render_on) return;
    const v = view orelse return;
    const o = out orelse return;
    o[0..3].* = v.target;
    o[3..7].* = v.rot;
    o[7] = v.dist;
}

/// Sets the camera from 8 floats of zs_view_get_camera, at once (no
/// animation). A bad value (not finite, or a distance of 0 or less) leaves
/// the camera as it is.
export fn zs_view_set_camera(view: ?*View, in: ?[*]const f32) void {
    if (!render_on) return;
    const v = view orelse return;
    const cam = in orelse return;
    for (cam[0..8]) |x| if (!std.math.isFinite(x)) return;
    if (!(cam[7] > 0)) return;
    const q = cam[3..7].*;
    const l = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (!(l > 0.5 and l < 2)) return;
    v.goal = null;
    v.target = cam[0..3].*;
    v.rot = .{ q[0] / l, q[1] / l, q[2] / l, q[3] / l };
    v.dist = cam[7];
}

export fn zs_view_reset(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.reset();
}

/// The dark look (on != 0): a dark background, grid, and bed, for the
/// dark mode of the system.
export fn zs_view_set_dark(view: ?*View, on: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.dark = on != 0;
}

/// Shows a part turned and moved in the view only (View.setPartPreview).
/// part < 0 ends it.
export fn zs_view_part_preview(view: ?*View, part: c_int, qx: f32, qy: f32, qz: f32, qw: f32, px: f32, py: f32, pz: f32, mx: f32, my: f32, mz: f32, flags: c_int) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const q = [4]f32{ qx, qy, qz, qw };
    for (q) |k| if (!std.math.isFinite(k)) return @intFromEnum(Status.invalid_argument);
    if (part >= 0 and q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3] < 1e-12) return @intFromEnum(Status.invalid_argument);
    v.setPartPreview(if (part < 0) null else @intCast(part), q, .{ px, py, pz }, .{ mx, my, mz }, .{ .on_bed = flags & 1 != 0, .centered = flags & 2 != 0 }) catch |e| return status(e);
    return ok;
}

/// The move of the part preview after its turn, as the view placed it
/// (ZS_PREVIEW_ON_BED, ZS_PREVIEW_CENTERED), to out (3 values). 0 with no
/// preview.
export fn zs_view_part_preview_move(view: ?*const View, out: ?[*]f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const o = out orelse return 0;
    const p = v.preview orelse return 0;
    for (0..3) |k| o[k] = p.move[k];
    return 1;
}

/// The shell draws mesh level 2 as a ribbon (on != 0). See View.ribbons.
export fn zs_view_set_ribbons(view: ?*View, on: c_int) void {
    if (!render_on) return;
    const v = view orelse return;
    v.ribbons = on != 0;
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

/// Lights the paths of layers lo to hi joined to path `start` (its body of
/// its part, see View.connectedPaths) as a multiple selection, and gives
/// their count in `count` (may be NULL).
export fn zs_view_light_connected(view: ?*View, start: usize, lo: usize, hi: usize, count: ?*usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    var list: std.ArrayList(usize) = .empty;
    defer list.deinit(View.gpa);
    v.connectedPaths(start, lo, hi, &list) catch |e| return status(e);
    v.setMore(list.items) catch |e| return status(e);
    if (count) |cn| cn.* = list.items.len;
    return ok;
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

/// The box of path `path` on the screen, in pixels (x0, y0, x1, y1), for a
/// card that must keep out of it. 0 if no part of it is in front of the
/// camera.
export fn zs_view_path_rect(view: ?*const View, path: usize, out: ?*[4]f32) c_int {
    if (!render_on) return 0;
    const v = view orelse return 0;
    const r = v.pathRect(path) orelse return 0;
    if (out) |o| o.* = r;
    return 1;
}

export fn zs_view_path_layer(view: ?*const View, path: usize) usize {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.layerOfPath(path);
}

/// The feature of a path (0 outer wall ... 6 support, 7 support
/// interface), or -1.
export fn zs_view_path_feature(view: ?*const View, path: usize) c_int {
    if (!render_on) return -1;
    const v = view orelse return -1;
    const f = v.featureOfPath(path) orelse return -1;
    return f;
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

/// A span of instances in the bytes of zs_view_scene_write (enum
/// zs_scene_span): its byte offset and its count. `head` is the first
/// head_len bytes of a scene of len bytes (1024 bytes are enough).
export fn zs_view_scene_span(head: ?[*]const u8, head_len: usize, len: usize, which: u32, offset: ?*usize, count: ?*u32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const h = head orelse return @intFromEnum(Status.invalid_argument);
    const o = offset orelse return @intFromEnum(Status.invalid_argument);
    const n = count orelse return @intFromEnum(Status.invalid_argument);
    const w = std.enums.fromInt(View.SceneSpan, which) orelse return @intFromEnum(Status.invalid_argument);
    const r = View.sceneSpan(h[0..@min(head_len, len)], len, w) catch |e| return status(e);
    o.* = r.offset;
    n.* = r.count;
    return ok;
}

/// Reads a scene in steps: copies up to `budget` bytes of it, and sets
/// *done to 1 when all is copied. Each call gets the same bytes. Then
/// zs_view_scene_commit loads the scene; until then the view draws its old
/// scene. zs_view_scene_read drops a scene in steps.
export fn zs_view_scene_stage(view: ?*View, data: ?[*]const u8, len: usize, budget: usize, done: ?*c_int) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    const r = v.stageScene(d[0..len], budget) catch |e| {
        v.dropStage();
        return status(e);
    };
    if (done) |p| p.* = @intFromBool(r);
    return ok;
}

/// Loads the scene of zs_view_scene_stage, after it set *done.
export fn zs_view_scene_commit(view: ?*View) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    v.commitScene() catch |e| return status(e);
    return ok;
}

/// The generation of the light beads of the active plate (zs_web_plate.gen
/// of its light levels).
export fn zs_view_light_gen(view: ?*const View) u32 {
    if (!render_on) return 0;
    const v = view orelse return 0;
    return v.lite_gen;
}

/// wasm and macOS: the frame data of the frame backend (zs_web_frame in
/// zslice-app.h). NULL on the other targets.
export fn zs_view_web_frame(view: ?*View) ?*const anyopaque {
    if (comptime !frame_backend) return null;
    const v = view orelse return null;
    return &v.renderer.out;
}

// ---- the plate set (src/render/plates.zig) ----

/// The plates of the row: n bed sizes (x, y pairs, mm) and the active plate.
export fn zs_view_set_plates(view: ?*View, n: usize, active: usize, beds: ?[*]const f32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    if (n > 0 and beds == null) return @intFromEnum(Status.invalid_argument);
    const list = c.gpa.alloc([2]f32, n) catch return @intFromEnum(Status.out_of_memory);
    defer c.gpa.free(list);
    for (list, 0..) |*b, i| b.* = .{ beds.?[2 * i], beds.?[2 * i + 1] };
    v.setPlates(list, active) catch |e| return status(e);
    return ok;
}

/// The beads of plate i from the bytes of zs_view_scene_write.
export fn zs_view_plate_scene_read(view: ?*View, i: usize, data: ?[*]const u8, len: usize) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    v.readPlateScene(i, d[0..len]) catch |e| return status(e);
    return ok;
}

/// The beads of plate i from the last slice of an app.
export fn zs_view_plate_load(view: ?*View, i: usize, a: ?*const App) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const app = a orelse return @intFromEnum(Status.invalid_argument);
    v.loadPlate(i, app) catch |e| return status(e);
    return ok;
}

/// Shows plate i as the footprints of its parts: n boxes (x0, y0, x1, y1).
export fn zs_view_plate_outline(view: ?*View, i: usize, n: usize, boxes: ?[*]const f32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    if (n > 0 and boxes == null) return @intFromEnum(Status.invalid_argument);
    const list = c.gpa.alloc([4]f32, n) catch return @intFromEnum(Status.out_of_memory);
    defer c.gpa.free(list);
    for (list, 0..) |*b, k| b.* = .{ boxes.?[4 * k], boxes.?[4 * k + 1], boxes.?[4 * k + 2], boxes.?[4 * k + 3] };
    v.setPlateOutline(i, list) catch |e| return status(e);
    return ok;
}

export fn zs_view_plate_clear(view: ?*View, i: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    v.clearPlate(i);
}

export fn zs_view_plate_flags(view: ?*View, i: usize, flags: u32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    v.setPlateFlags(i, flags) catch |e| return status(e);
    return ok;
}

/// The plate under a pixel, or -1.
export fn zs_view_plate_at(view: ?*const View, px: f32, py: f32) i64 {
    if (!render_on) return -1;
    const v = view orelse return -1;
    const i = v.plateAt(px, py) orelse return -1;
    return @intCast(i);
}

/// The origin of the bed of plate i in the world of the view (mm).
export fn zs_view_plate_origin(view: ?*const View, i: usize, x: ?*f64, y: ?*f64) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    const o = v.plateOffset(i);
    if (x) |p| p.* = o[0];
    if (y) |p| p.* = o[1];
    return ok;
}

/// The signs of the plates: n rects (x, y, w, h) in an RGBA image.
export fn zs_view_set_signs(view: ?*View, n: usize, rects: ?[*]const f32, width: u32, height: u32, rgba: ?[*]const u8, scale: f32) c_int {
    if (!render_on) return @intFromEnum(Status.not_supported);
    const v = view orelse return @intFromEnum(Status.invalid_argument);
    if (n > 0 and (rects == null or rgba == null or width == 0 or height == 0)) return @intFromEnum(Status.invalid_argument);
    const list = c.gpa.alloc([4]f32, n) catch return @intFromEnum(Status.out_of_memory);
    defer c.gpa.free(list);
    for (list, 0..) |*r, k| r.* = .{ rects.?[4 * k], rects.?[4 * k + 1], rects.?[4 * k + 2], rects.?[4 * k + 3] };
    const bytes: []const u8 = if (n > 0) rgba.?[0 .. @as(usize, width) * height * 4] else &.{};
    v.setSigns(list, .{ width, height }, bytes, scale) catch |e| return status(e);
    return ok;
}

/// The plate of the sign under a pixel, or -1.
export fn zs_view_sign_at(view: ?*const View, px: f32, py: f32) i64 {
    if (!render_on) return -1;
    const v = view orelse return -1;
    const i = v.signAt(px, py) orelse return -1;
    return @intCast(i);
}

/// Moves the camera to show plate i, or all plates for (size_t)-1.
export fn zs_view_frame_plate(view: ?*View, i: usize) void {
    if (!render_on) return;
    const v = view orelse return;
    if (i == std.math.maxInt(usize)) v.frameAll() else v.framePlate(i);
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
