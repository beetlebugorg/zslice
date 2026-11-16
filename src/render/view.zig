//! The 3D view of a slice: the scene, the camera, and the renderer.
//!
//! The goal is a preview that looks like the finished print. Each toolpath
//! segment is drawn as the bead of plastic that the printer lays down:
//!
//! - The cross section has a flat top and bottom and round sides (see
//!   flow.zig). The width comes from the plastic that is really deposited:
//!   the bead area of the path (with the flow ratio and the ironing flow)
//!   and the layer height give the width. A thread with less plastic than a
//!   round thread of the layer height is drawn round.
//! - The ends are round: the profile turns around the end point, as the
//!   plastic flows around the nozzle. Where two segments of a path meet,
//!   their round ends overlap, so the corners look like printed corners.
//! - The shape is the cooled shape: the slice is larger by the shrinkage of
//!   the filament (shrinkage compensation), and the view scales it back.
//! - The color is the filament color (the "print" mode), or one color for
//!   each feature (the "features" mode, to see what the slicer made).
//!
//! The beads are in print order, so the layers 0 to n are the first
//! `layer_end[n]` beads, and the slider of a shell only changes a count.
//!
//! The camera orbits a target point (the center of the part): yaw turns
//! around the vertical axis, pitch tilts up and down, and the distance
//! zooms. The projection is for Vulkan clip space: y goes down, and depth
//! goes from 0 to 1.
//!
//! This file is the same for all platforms. Only the backend (vk.zig, and
//! later Metal) talks to the GPU.

const std = @import("std");
const vk = @import("vk.zig");
const app_mod = @import("../app.zig");

/// The feature colors, in the order of the Feature enum. The same colors
/// as the SVG preview and docs/app/README.md.
pub const feature_rgb = [_][3]u8{
    .{ 0xd9, 0x48, 0x0f }, // outer wall
    .{ 0xf5, 0x9f, 0x00 }, // inner wall
    .{ 0x1c, 0x7e, 0xd6 }, // skin
    .{ 0x2b, 0x8a, 0x3e }, // infill
    .{ 0xae, 0x3e, 0xc9 }, // ironing
    .{ 0x8d, 0x6e, 0x63 }, // skirt and brim
    .{ 0xad, 0xb5, 0xbd }, // support
    .{ 0x49, 0x50, 0x57 }, // support interface
};

pub const Surface = vk.Surface;
pub const Error = vk.Error;

pub const Mode = enum(c_int) { print = 0, features = 1 };

pub const View = struct {
    renderer: *vk.Renderer,
    mode: Mode = .print,
    layer_end: std.ArrayList(u32) = .empty,
    /// The first bead of each path, and one more item at the end: the
    /// beads of path i are path_start[i] to path_start[i + 1].
    path_start: std.ArrayList(u32) = .empty,
    highlight: [2]f32 = .{ 0, 0 },
    layer: usize = 0,
    grid_vertices: u32 = 0,
    width: u32,
    height: u32,
    target: [3]f32 = .{ 110, 110, 0 },
    extent: f32 = 100,
    yaw: f32 = 0,
    pitch: f32 = 0,
    dist: f32 = 100,

    const gpa = std.heap.c_allocator;

    pub fn create(surface: Surface, width: u32, height: u32) Error!*View {
        const r = try vk.Renderer.init(surface, width, height);
        errdefer r.deinit();
        const v = gpa.create(View) catch return error.OutOfMemory;
        v.* = .{ .renderer = r, .width = width, .height = height };
        errdefer gpa.destroy(v);
        try v.makeMesh();
        v.reset();
        return v;
    }

    pub fn destroy(v: *View) void {
        v.layer_end.deinit(gpa);
        v.path_start.deinit(gpa);
        v.renderer.deinit();
        gpa.destroy(v);
    }

    /// The size of the view in pixels.
    pub fn resize(v: *View, width: u32, height: u32) void {
        v.width = @max(width, 1);
        v.height = @max(height, 1);
        v.renderer.resize(v.width, v.height);
    }

    /// The template mesh of a bead (see shaders/box.vert): a loop in the
    /// plan view around the segment (a half circle at each end), times the
    /// profile angles from the bottom to the top, and a flat top face and a
    /// flat bottom face.
    fn makeMesh(v: *View) Error!void {
        const cap = 4; // segments in each half circle
        const prof = 4; // segments in the profile
        const pi = std.math.pi;
        var verts: std.ArrayList([4]f32) = .empty;
        defer verts.deinit(gpa);
        var idx: std.ArrayList(u16) = .empty;
        defer idx.deinit(gpa);
        // The plan loop: around the end b (u = 1) from -90 to 90 degrees,
        // then around the end a (u = 0) from 90 to 270 degrees.
        var loop: [2 * (cap + 1)][2]f32 = undefined;
        for (0..cap + 1) |k| {
            const t: f32 = @as(f32, @floatFromInt(k)) / cap;
            loop[k] = .{ 1, -pi / 2.0 + pi * t };
            loop[cap + 1 + k] = .{ 0, pi / 2.0 + pi * t };
        }
        const n_loop = loop.len;
        for (loop) |l| {
            for (0..prof + 1) |j| {
                const phi: f32 = -pi / 2.0 + pi * @as(f32, @floatFromInt(j)) / prof;
                verts.append(gpa, .{ l[0], l[1], phi, 0 }) catch return error.OutOfMemory;
            }
        }
        for (0..n_loop) |i| {
            const next = (i + 1) % n_loop;
            for (0..prof) |j| {
                const q0: u16 = @intCast(i * (prof + 1) + j);
                const q1: u16 = @intCast(next * (prof + 1) + j);
                idx.appendSlice(gpa, &.{ q0, q1, q1 + 1, q0, q1 + 1, q0 + 1 }) catch return error.OutOfMemory;
            }
        }
        // The flat top and bottom: a fan from the middle of the segment to
        // the top (and bottom) row of the loop.
        for ([_]f32{ 1, -1 }) |face| {
            const center: u16 = @intCast(verts.items.len);
            verts.append(gpa, .{ 0.5, 0, 0, face }) catch return error.OutOfMemory;
            const row: usize = if (face > 0) prof else 0;
            for (0..n_loop) |i| {
                const a: u16 = @intCast(i * (prof + 1) + row);
                const b: u16 = @intCast(((i + 1) % n_loop) * (prof + 1) + row);
                idx.appendSlice(gpa, &.{ center, a, b }) catch return error.OutOfMemory;
            }
        }
        try v.renderer.setMesh(verts.items, idx.items);
    }

    /// Reads the toolpaths of the last slice of `app`, and the bed size.
    pub fn load(v: *View, app: *const app_mod.App) Error!void {
        const s = app.settings;
        try v.loadGrid(@floatCast(s.machine.bed_size_x), @floatCast(s.machine.bed_size_y));
        const tp = app.allToolpaths() orelse {
            v.layer_end.clearRetainingCapacity();
            v.path_start.clearRetainingCapacity();
            return;
        };
        const first_load = v.layer_end.items.len == 0;
        const filament = parseColor(s.filament.color) orelse .{ 0xd0, 0xd0, 0xcc };

        // The cooled shape: the slice is larger by the shrinkage, about the
        // center of the part.
        var center = [2]f32{ 0, 0 };
        if (app.partBounds()) |b| center = .{ @floatCast((b[0] + b[2]) / 2), @floatCast((b[1] + b[3]) / 2) };
        const sxy: f32 = @floatCast(1 / s.filament.shrinkage_xy);
        const sz: f32 = @floatCast(1 / s.filament.shrinkage_z);

        var boxes: std.ArrayList(vk.Instance) = .empty;
        defer boxes.deinit(gpa);
        v.layer_end.clearRetainingCapacity();
        v.path_start.clearRetainingCapacity();
        var zmax: f32 = 0;
        const pts = tp.points.items;
        for (tp.layer_ends.items, 0..) |layer_end, l| {
            const p0: u32 = if (l == 0) 0 else tp.layer_ends.items[l - 1];
            const z = tp.layer_z.items[l] * sz;
            const h = tp.layer_height.items[l] * sz;
            zmax = @max(zmax, z);
            for (p0..layer_end) |pi| {
                v.path_start.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
                const start: u32 = if (pi == 0) 0 else tp.path_ends.items[pi - 1];
                const end = tp.path_ends.items[pi];
                if (end - start < 2) continue;
                const f = tp.path_features.items[pi];
                const rgb = if (v.mode == .print) filament else feature_rgb[if (f < feature_rgb.len) f else 0];
                const w: f32 = @floatCast(@import("../flow.zig").beadWidth(tp.path_area.items[pi], tp.layer_height.items[l]) * sxy);
                if (!(w > 0)) continue;
                const closed = tp.path_closed.items[pi] != 0 and end - start > 2;
                const segs = end - start - 1 + @as(u32, @intFromBool(closed));
                for (0..segs) |k| {
                    const a = start + @as(u32, @intCast(k));
                    const b = if (a + 1 < end) a + 1 else start;
                    boxes.append(gpa, .{
                        .ax = center[0] + (pts[2 * a] - center[0]) * sxy,
                        .ay = center[1] + (pts[2 * a + 1] - center[1]) * sxy,
                        .bx = center[0] + (pts[2 * b] - center[0]) * sxy,
                        .by = center[1] + (pts[2 * b + 1] - center[1]) * sxy,
                        .z = z,
                        .h = h,
                        .w = w,
                        .rgba = .{ rgb[0], rgb[1], rgb[2], 255 },
                    }) catch return error.OutOfMemory;
                }
            }
            v.layer_end.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        }
        v.path_start.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        try v.renderer.setInstances(boxes.items);

        if (app.partBounds()) |b| {
            v.target = .{ @floatCast((b[0] + b[2]) / 2), @floatCast((b[1] + b[3]) / 2), zmax / 2 };
            v.extent = @max(@max(@as(f32, @floatCast(b[2] - b[0])), @as(f32, @floatCast(b[3] - b[1]))), zmax);
        }
        if (first_load) {
            v.reset();
            v.layer = if (v.layer_end.items.len > 0) v.layer_end.items.len - 1 else 0;
        }
    }

    /// The colors: the filament color, or one color for each feature. Call
    /// `load` again after a change.
    pub fn setMode(v: *View, mode: Mode) void {
        v.mode = mode;
    }

    /// Highlights the beads of path `path` (an index into the toolpaths of
    /// the app), or nothing if `path` is null.
    pub fn setHighlight(v: *View, path: ?usize) void {
        const p = path orelse {
            v.highlight = .{ 0, 0 };
            return;
        };
        if (p + 1 >= v.path_start.items.len) {
            v.highlight = .{ 0, 0 };
            return;
        }
        v.highlight = .{ @floatFromInt(v.path_start.items[p]), @floatFromInt(v.path_start.items[p + 1]) };
    }

    fn loadGrid(v: *View, bed_x: f32, bed_y: f32) Error!void {
        var pts: std.ArrayList(f32) = .empty;
        defer pts.deinit(gpa);
        // The bed outline and a 10 mm grid, at z = 0.
        var x: f32 = 0;
        while (x <= bed_x + 0.01) : (x += 10) pts.appendSlice(gpa, &.{ @min(x, bed_x), 0, 0, @min(x, bed_x), bed_y, 0 }) catch return error.OutOfMemory;
        var y: f32 = 0;
        while (y <= bed_y + 0.01) : (y += 10) pts.appendSlice(gpa, &.{ 0, @min(y, bed_y), 0, bed_x, @min(y, bed_y), 0 }) catch return error.OutOfMemory;
        try v.renderer.setGrid(pts.items);
        v.grid_vertices = @intCast(pts.items.len / 3);
    }

    /// Shows the layers 0 to `layer`.
    pub fn setLayer(v: *View, layer: usize) void {
        v.layer = layer;
    }

    /// Turns the camera by a drag of dx, dy pixels.
    pub fn orbit(v: *View, dx: f32, dy: f32) void {
        v.yaw -= dx * 0.008;
        v.pitch = std.math.clamp(v.pitch + dy * 0.008, -0.2, 1.55);
    }

    /// Moves the camera nearer (factor < 1) or further (factor > 1).
    pub fn zoom(v: *View, factor: f32) void {
        v.dist = @max(v.extent * 0.05 + 1, v.dist * factor);
    }

    pub fn reset(v: *View) void {
        v.yaw = -1.9;
        v.pitch = 0.6;
        v.dist = v.extent * 2.8;
    }

    pub fn draw(v: *View) Error!void {
        const eye = [3]f32{
            v.target[0] + v.dist * @cos(v.pitch) * @cos(v.yaw),
            v.target[1] + v.dist * @cos(v.pitch) * @sin(v.yaw),
            v.target[2] + v.dist * @sin(v.pitch),
        };
        const aspect = @as(f32, @floatFromInt(v.width)) / @as(f32, @floatFromInt(v.height));
        const proj = perspective(0.8, aspect, @max(v.dist * 0.01, 0.1), v.dist * 10 + v.extent * 4);
        const view = lookAt(eye, v.target, .{ 0, 0, 1 });
        const mvp = mul(proj, view);
        var count: u32 = 0;
        if (v.layer_end.items.len > 0) count = v.layer_end.items[@min(v.layer, v.layer_end.items.len - 1)];
        try v.renderer.draw(.{
            .clear = .{ 0.965, 0.969, 0.973 },
            // A light from above, in front, and to the right.
            .box = .{ .mvp = mvp, .vec = .{ 0.35, -0.45, 0.82, 0 }, .eye = .{ eye[0], eye[1], eye[2], 0 }, .params = .{ v.highlight[0], v.highlight[1], 0, 0 } },
            .box_count = count,
            .grid = .{ .mvp = mvp, .vec = .{ 0.80, 0.82, 0.85, 1 } },
            .grid_vertices = v.grid_vertices,
        });
    }
};

/// Parses "#rrggbb".
fn parseColor(text: []const u8) ?[3]u8 {
    if (text.len != 7 or text[0] != '#') return null;
    var out: [3]u8 = undefined;
    for (0..3) |k| out[k] = std.fmt.parseInt(u8, text[1 + 2 * k .. 3 + 2 * k], 16) catch return null;
    return out;
}

// ---- matrices, column-major ----

fn mul(a: [16]f32, b: [16]f32) [16]f32 {
    var r: [16]f32 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var s: f32 = 0;
        for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
        r[col * 4 + row] = s;
    };
    return r;
}

/// A perspective projection for Vulkan: y down, depth 0 to 1.
fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) [16]f32 {
    const f = 1 / @tan(fovy / 2);
    var m: [16]f32 = @splat(0);
    m[0] = f / aspect;
    m[5] = -f;
    m[10] = far / (near - far);
    m[11] = -1;
    m[14] = near * far / (near - far);
    return m;
}

fn lookAt(eye: [3]f32, at: [3]f32, up: [3]f32) [16]f32 {
    const f = normalize(.{ at[0] - eye[0], at[1] - eye[1], at[2] - eye[2] });
    const s = normalize(cross(f, up));
    const u = cross(s, f);
    return .{
        s[0],          u[0],          -f[0],        0,
        s[1],          u[1],          -f[1],        0,
        s[2],          u[2],          -f[2],        0,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1,
    };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize(a: [3]f32) [3]f32 {
    const l = @sqrt(dot(a, a));
    return .{ a[0] / l, a[1] / l, a[2] / l };
}

test "the camera looks at the target" {
    const view = lookAt(.{ 0, -10, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 1 });
    const proj = perspective(0.8, 1, 0.1, 100);
    const m = mul(proj, view);
    // The target is in the middle of the screen.
    const x = m[12];
    const y = m[13];
    const w = m[15];
    try std.testing.expectApproxEqAbs(@as(f32, 0), x / w, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), y / w, 1e-5);
    // A point above the target is up on the screen (negative y in Vulkan).
    const ay = m[9] * 1 + m[13];
    const aw = m[11] * 1 + m[15];
    try std.testing.expect(ay / aw < 0);
}
