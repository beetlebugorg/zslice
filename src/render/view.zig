//! The 3D view of a slice: the scene, the camera, and the renderer.
//!
//! Each toolpath segment is one box: one line width wide and one layer
//! height tall, with its top at the nozzle height of its layer. The boxes
//! are in print order, so the layers 0 to n are the first `layer_end[n]`
//! boxes, and the slider of a shell only changes a count.
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

pub const View = struct {
    renderer: *vk.Renderer,
    layer_end: std.ArrayList(u32) = .empty,
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
        v.reset();
        return v;
    }

    pub fn destroy(v: *View) void {
        v.layer_end.deinit(gpa);
        v.renderer.deinit();
        gpa.destroy(v);
    }

    /// The size of the view in pixels.
    pub fn resize(v: *View, width: u32, height: u32) void {
        v.width = @max(width, 1);
        v.height = @max(height, 1);
        v.renderer.resize(v.width, v.height);
    }

    /// Reads the toolpaths of the last slice of `app`, and the bed size.
    pub fn load(v: *View, app: *const app_mod.App) Error!void {
        const s = app.settings;
        try v.loadGrid(@floatCast(s.machine.bed_size_x), @floatCast(s.machine.bed_size_y));
        const tp = app.allToolpaths() orelse {
            v.layer_end.clearRetainingCapacity();
            return;
        };
        const first_load = v.layer_end.items.len == 0;

        var boxes: std.ArrayList(vk.Instance) = .empty;
        defer boxes.deinit(gpa);
        v.layer_end.clearRetainingCapacity();
        var zmax: f32 = 0;
        const pts = tp.points.items;
        for (tp.layer_ends.items, 0..) |layer_end, l| {
            const p0: u32 = if (l == 0) 0 else tp.layer_ends.items[l - 1];
            const z = tp.layer_z.items[l];
            const h = tp.layer_height.items[l];
            const w = tp.layer_width.items[l];
            zmax = @max(zmax, z);
            for (p0..layer_end) |pi| {
                const start: u32 = if (pi == 0) 0 else tp.path_ends.items[pi - 1];
                const end = tp.path_ends.items[pi];
                if (end - start < 2) continue;
                const f = tp.path_features.items[pi];
                const rgb = feature_rgb[if (f < feature_rgb.len) f else 0];
                const closed = tp.path_closed.items[pi] != 0 and end - start > 2;
                const segs = end - start - 1 + @as(u32, @intFromBool(closed));
                for (0..segs) |k| {
                    const a = start + @as(u32, @intCast(k));
                    const b = if (a + 1 < end) a + 1 else start;
                    boxes.append(gpa, .{
                        .ax = pts[2 * a],
                        .ay = pts[2 * a + 1],
                        .bx = pts[2 * b],
                        .by = pts[2 * b + 1],
                        .z = z,
                        .h = h,
                        .w = w,
                        .rgba = .{ rgb[0], rgb[1], rgb[2], 255 },
                    }) catch return error.OutOfMemory;
                }
            }
            v.layer_end.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        }
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
            .box = .{ .mvp = mvp, .vec = .{ 0.35, -0.45, 0.82, 0 } },
            .box_count = count,
            .grid = .{ .mvp = mvp, .vec = .{ 0.80, 0.82, 0.85, 1 } },
            .grid_vertices = v.grid_vertices,
        });
    }
};

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
