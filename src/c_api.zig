//! The C API. `include/zslice.h` declares these functions. The wasm module
//! exports the same functions.
//!
//! Rules of the API:
//!
//! - Each function returns a status code. 0 is success.
//! - Objects (meshes, settings) are opaque pointers. Each `_new` or `_load`
//!   function has a `_free` function.
//! - The library allocates its own memory. Native builds use the Zig SMP
//!   allocator (thread-safe), and wasm builds use the wasm allocator.

const std = @import("std");
const builtin = @import("builtin");
const zs = @import("root.zig");
const Writer = std.Io.Writer;

const is_wasm = builtin.cpu.arch.isWasm();
const gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;

pub const Status = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_argument = 2,
    invalid_mesh = 3,
    empty_mesh = 4,
    unknown_setting = 5,
    invalid_value = 6,
    invalid_settings = 7,
    part_too_large = 8,
    write_failed = 9,
    canceled = 10,
    busy = 11,
    no_model = 12,
    no_result = 13,
    out_of_range = 14,
    not_supported = 15,
    gpu_failed = 16,
};

fn status(e: anyerror) c_int {
    const s: Status = switch (e) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidStl, error.InvalidMesh => .invalid_mesh,
        error.EmptyMesh => .empty_mesh,
        error.UnknownSetting => .unknown_setting,
        error.InvalidValue => .invalid_value,
        error.InvalidSettings => .invalid_settings,
        error.PartTooLarge => .part_too_large,
        error.WriteFailed => .write_failed,
        error.Canceled => .canceled,
        error.Busy => .busy,
        error.NoModel => .no_model,
        error.NoResult => .no_result,
        error.OutOfRange => .out_of_range,
        error.NoVulkan => .not_supported,
        error.NoDevice, error.VulkanFailed, error.SurfaceFailed => .gpu_failed,
        else => .invalid_argument,
    };
    return @intFromEnum(s);
}

const ok: c_int = @intFromEnum(Status.ok);

pub const Stats = extern struct {
    layer_count: u32,
    retractions: u32,
    filament_mm: f64,
    filament_g: f64,
    print_time_s: f64,
    travel_mm: f64,
};

fn cStats(s: zs.Stats) Stats {
    return .{
        .layer_count = s.layer_count,
        .retractions = s.retractions,
        .filament_mm = s.filament_mm,
        .filament_g = s.filament_g,
        .print_time_s = s.print_time_s,
        .travel_mm = s.travel_mm,
    };
}

/// Settings and the memory for their string values.
const CSettings = struct {
    settings: zs.Settings = .{},
    strings: std.heap.ArenaAllocator,
};

export fn zs_version() [*:0]const u8 {
    return zs.version;
}

export fn zs_status_string(code: c_int) [*:0]const u8 {
    const s = std.enums.fromInt(Status, code) orelse return "unknown status";
    return @tagName(s);
}

/// All setting names ("group.name"), one on each line.
export fn zs_setting_names() [*:0]const u8 {
    return setting_names;
}

const setting_names: [:0]const u8 = blk: {
    var text: [:0]const u8 = "";
    for (@typeInfo(zs.Settings).@"struct".fields) |g| {
        for (@typeInfo(g.type).@"struct".fields) |f| text = text ++ g.name ++ "." ++ f.name ++ "\n";
    }
    break :blk text;
};

export fn zs_mesh_load_stl(data: ?[*]const u8, len: usize, out: ?*?*zs.Mesh) c_int {
    const d = data orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const m = gpa.create(zs.Mesh) catch |e| return status(e);
    m.* = zs.Mesh.fromStl(gpa, d[0..len]) catch |e| {
        gpa.destroy(m);
        return status(e);
    };
    o.* = m;
    return ok;
}

/// `xyz` has 9 floats for each triangle: x, y, z of each of 3 vertices.
export fn zs_mesh_from_triangles(xyz: ?[*]const f32, triangle_count: usize, out: ?*?*zs.Mesh) c_int {
    const d = xyz orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const m = gpa.create(zs.Mesh) catch |e| return status(e);
    m.* = zs.Mesh.fromTriangles(gpa, d[0 .. triangle_count * 9]) catch |e| {
        gpa.destroy(m);
        return status(e);
    };
    o.* = m;
    return ok;
}

export fn zs_mesh_free(mesh: ?*zs.Mesh) void {
    const m = mesh orelse return;
    m.deinit(gpa);
    gpa.destroy(m);
}

export fn zs_settings_new(out: ?*?*CSettings) c_int {
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const s = gpa.create(CSettings) catch |e| return status(e);
    s.* = .{ .strings = .init(gpa) };
    o.* = s;
    return ok;
}

/// Sets one setting. `key` is "group.name", for example
/// "project.wall_count". The value is text. The library copies it.
export fn zs_settings_set(settings: ?*CSettings, key: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const s = settings orelse return @intFromEnum(Status.invalid_argument);
    const k = std.mem.span(key orelse return @intFromEnum(Status.invalid_argument));
    const v = std.mem.span(value orelse return @intFromEnum(Status.invalid_argument));
    // String settings keep a pointer to the value, so it must live as long
    // as the settings.
    const copy = s.strings.allocator().dupe(u8, v) catch |e| return status(e);
    s.settings.set(k, copy) catch |e| return status(e);
    return ok;
}

export fn zs_settings_free(settings: ?*CSettings) void {
    const s = settings orelse return;
    s.strings.deinit();
    gpa.destroy(s);
}

/// The callback gets the G-code in parts. It returns 0 on success. Any
/// other value stops the slice with status write_failed.
pub const WriteFn = *const fn (user: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) c_int;

/// A writer that sends its data to a C callback.
const CallbackWriter = struct {
    interface: Writer,
    write: WriteFn,
    user: ?*anyopaque,

    fn send(self: *CallbackWriter, bytes: []const u8) Writer.Error!void {
        if (bytes.len == 0) return;
        if (self.write(self.user, bytes.ptr, bytes.len) != 0) return error.WriteFailed;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *CallbackWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.send(w.buffer[0..w.end]);
        w.end = 0;
        if (data.len == 1) {
            for (0..splat) |_| try self.send(data[0]);
            return data[0].len * splat;
        }
        try self.send(data[0]);
        return data[0].len;
    }
};

/// Slices the mesh and sends the G-code to `write` as it is made.
export fn zs_slice(mesh: ?*const zs.Mesh, settings: ?*const CSettings, write: ?WriteFn, user: ?*anyopaque, stats: ?*Stats) c_int {
    const m = mesh orelse return @intFromEnum(Status.invalid_argument);
    const w = write orelse return @intFromEnum(Status.invalid_argument);
    const s: zs.Settings = if (settings) |cs| cs.settings else .{};
    var buf: [64 * 1024]u8 = undefined;
    var cw: CallbackWriter = .{
        .interface = .{ .buffer = &buf, .vtable = &.{ .drain = CallbackWriter.drain } },
        .write = w,
        .user = user,
    };
    const result = zs.slice(gpa, m, s, &cw.interface) catch |e| return status(e);
    cw.interface.flush() catch |e| return status(e);
    if (stats) |st| st.* = cStats(result);
    return ok;
}

/// Slices the mesh into one buffer. Free the buffer with zs_buffer_free.
export fn zs_slice_to_buffer(mesh: ?*const zs.Mesh, settings: ?*const CSettings, out: ?*?[*]u8, out_len: ?*usize, stats: ?*Stats) c_int {
    const m = mesh orelse return @intFromEnum(Status.invalid_argument);
    const o = out orelse return @intFromEnum(Status.invalid_argument);
    const ol = out_len orelse return @intFromEnum(Status.invalid_argument);
    const s: zs.Settings = if (settings) |cs| cs.settings else .{};
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = zs.slice(gpa, m, s, &aw.writer) catch |e| return status(e);
    const bytes = aw.toOwnedSlice() catch |e| return status(e);
    o.* = bytes.ptr;
    ol.* = bytes.len;
    if (stats) |st| st.* = cStats(result);
    return ok;
}

export fn zs_buffer_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

/// Memory for the host to pass data in (wasm). Free it with zs_free.
export fn zs_alloc(len: usize) ?[*]u8 {
    const b = gpa.alloc(u8, len) catch return null;
    return b.ptr;
}

export fn zs_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

// ---------------------------------------------------------------------------
// The app core (include/zslice-app.h). See src/app.zig.

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
    path_count: usize,
    layer_ends: [*]const u32,
    layer_z: [*]const f32,
    layer_height: [*]const f32,
    layer_width: [*]const f32,
    layer_count: usize,
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
        .path_count = t.path_ends.items.len,
        .layer_ends = t.layer_ends.items.ptr,
        .layer_z = t.layer_z.items.ptr,
        .layer_height = t.layer_height.items.ptr,
        .layer_width = t.layer_width.items.ptr,
        .layer_count = t.layer_ends.items.len,
    };
    return ok;
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

// ---------------------------------------------------------------------------
// The 3D view (include/zslice-app.h). See src/render/view.zig.

/// The renderer needs libc (it loads the Vulkan loader with dlopen). It is
/// on Linux now. Other targets get "not supported" from each call.
const render_on = builtin.os.tag == .linux and builtin.link_libc and !is_wasm;
const view_mod = if (render_on) @import("render/view.zig") else struct {
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

export fn zs_view_reset(view: ?*View) void {
    if (!render_on) return;
    const v = view orelse return;
    v.reset();
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

test "C API: slice a box to a buffer and with a callback" {
    var m: ?*zs.Mesh = null;
    const box = [_]f32{
        // Two triangles of each of 6 faces of a 10 mm cube.
        0, 0, 0, 0, 10, 0, 10, 10, 0, 0, 0, 0, 10, 10, 0, 10, 0, 0, // bottom
        0, 0, 10, 10, 0, 10, 10, 10, 10, 0, 0, 10, 10, 10, 10, 0, 10, 10, // top
        0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 0, 10, 0, 10, 0, 0, 10, // front
        0, 10, 0, 0, 10, 10, 10, 10, 10, 0, 10, 0, 10, 10, 10, 10, 10, 0, // back
        0, 0, 0, 0, 0, 10, 0, 10, 10, 0, 0, 0, 0, 10, 10, 0, 10, 0, // left
        10, 0, 0, 10, 10, 0, 10, 10, 10, 10, 0, 0, 10, 10, 10, 10, 0, 10, // right
    };
    try std.testing.expectEqual(ok, zs_mesh_from_triangles(&box, 12, &m));
    defer zs_mesh_free(m);

    var s: ?*CSettings = null;
    try std.testing.expectEqual(ok, zs_settings_new(&s));
    defer zs_settings_free(s);
    try std.testing.expectEqual(ok, zs_settings_set(s, "project.wall_count", "3"));
    try std.testing.expectEqual(@intFromEnum(Status.unknown_setting), zs_settings_set(s, "project.nope", "3"));

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    var st: Stats = undefined;
    try std.testing.expectEqual(ok, zs_slice_to_buffer(m, s, &ptr, &len, &st));
    defer zs_buffer_free(ptr, len);
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], ";LAYER:0\n") != null);

    const Counter = struct {
        fn f(user: ?*anyopaque, _: [*]const u8, n: usize) callconv(.c) c_int {
            const total: *usize = @ptrCast(@alignCast(user.?));
            total.* += n;
            return 0;
        }
    };
    var total: usize = 0;
    try std.testing.expectEqual(ok, zs_slice(m, s, Counter.f, &total, null));
    try std.testing.expectEqual(len, total);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zs_setting_names()), "filament.nozzle_temp\n") != null);
}
