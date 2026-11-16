//! The 3D view of a slice: the scene, the camera, and the renderer.
//!
//! The goal is a preview that looks like the finished print. Each toolpath
//! segment is drawn as the bead of plastic that the printer lays down:
//!
//! - The cross section has a flat top and bottom and round sides (see
//!   flow.zig). The width comes from the plastic that is really deposited:
//!   the bead area of the path (with the flow ratio and the ironing flow)
//!   and the bead height give the width. A thread with less plastic than a
//!   round thread of the bead height is drawn round. The bead height is the
//!   layer height, or for combined infill the height of all the layers of
//!   its group (project.infill_layers): the bead goes down from the nozzle
//!   through the layers below.
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
//! The camera looks at a target point (the center of the part) from a
//! distance. Its direction is a unit quaternion, so it can turn in any
//! direction: an orbit turns around the vertical axis and tilts, and a
//! free rotation turns around the axes of the screen (with roll). The
//! distance zooms. The projection is for Vulkan clip space: y goes down, and depth
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
    .{ 0x0c, 0xa6, 0xae }, // slope smoothing
    .{ 0x82, 0xc9, 0x1e }, // slope ironing
    .{ 0xe0, 0x1a, 0x26 }, // mark: seam
    .{ 0x33, 0x73, 0xf2 }, // mark: travel
    .{ 0xf2, 0x40, 0xbf }, // mark: retraction
};

pub const Surface = vk.Surface;
pub const Error = vk.Error;

pub const Mode = enum(c_int) { print = 0, features = 1, speed = 2, flow = 3, layer_time = 4, width = 5 };

pub const View = struct {
    renderer: *vk.Renderer,
    mode: Mode = .print,
    /// The range of the ramp of a value mode, after `load`.
    legend: [2]f64 = .{ 0, 0 },
    layer_end: std.ArrayList(u32) = .empty,
    /// The first bead of each path, and one more item at the end: the
    /// beads of path i are path_start[i] to path_start[i + 1].
    path_start: std.ArrayList(u32) = .empty,
    highlight: [2]f32 = .{ 0, 0 },
    /// The rings of the support marks of the app (see support.Mark): 12
    /// beads each, drawn as extras.
    mark_rings: std.ArrayList(vk.Instance) = .empty,
    /// The other selected paths (a multiple selection): their beads are
    /// yellow in the instance buffer. A load clears them.
    more: std.ArrayList(usize) = .empty,
    /// The bead of a selected segment (see setSegment), or null.
    seg_bead: ?usize = null,
    /// With a selection: the other beads are ghosts.
    isolate: bool = false,
    /// The features in focus (a bit for each), or 0 for no focus. The
    /// other beads fade. See `setFocus`.
    focus_mask: u32 = 0,
    /// With a focus: only the beads with a top at or under this z are in
    /// focus (the first layer, for a first layer setting).
    focus_zmax: f32 = std.math.inf(f32),
    /// A copy of the beads, for `pick` and the replay.
    beads: std.ArrayList(vk.Instance) = .empty,
    /// The marks: a seam blob at the start of each outer wall loop, and
    /// the travel moves and the retractions (drawn only in a focus on
    /// them). The alpha byte has the mark (8 + ...; see app.mark_seam).
    marks: std.ArrayList(vk.Instance) = .empty,
    /// The end of the marks of each layer in `marks`.
    mark_layer_end: std.ArrayList(u32) = .empty,
    /// The print time (s) at the end of each bead, for the replay.
    bead_end: std.ArrayList(f32) = .empty,
    /// The replay time (s), or null to show whole layers.
    time: ?f32 = null,
    /// The footprint of the selected part (x0, y0, x1, y1), or null: a
    /// frame on the bed around it.
    part_box: ?[4]f32 = null,
    layer: usize = 0,
    /// The lowest layer that shows (the bottom of the layer range).
    layer_lo: usize = 0,
    grid_vertices: u32 = 0,
    width: u32,
    height: u32,
    target: [3]f32 = .{ 110, 110, 0 },
    /// The target of `reset`: the center of the part.
    home: [3]f32 = .{ 110, 110, 0 },
    extent: f32 = 100,
    /// The camera direction: it turns the camera axes (right = x, up = y,
    /// back = z) into world directions. The eye is at target + dist * back.
    rot: Quat = .{ 0, 0, 0, 1 },
    dist: f32 = 100,
    /// The camera pose that `animate` moves to, or null if the camera does
    /// not move. The scroll zoom and the reset set it. A drag moves the
    /// camera at once, and moves the goal by the same amount.
    goal: ?Pose = null,

    /// The camera: the target, the angles, and the distance.
    pub const Pose = struct { target: [3]f32, rot: Quat, dist: f32 };

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
        v.mark_rings.deinit(gpa);
        v.more.deinit(gpa);
        v.path_start.deinit(gpa);
        v.beads.deinit(gpa);
        v.bead_end.deinit(gpa);
        v.marks.deinit(gpa);
        v.mark_layer_end.deinit(gpa);
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
        // The support marks: a ring at the place and the layer of each.
        v.mark_rings.clearRetainingCapacity();
        for (app.marks.items) |m| {
            const color: [4]u8 = if (m.kind == .block) .{ 0xe0, 0x31, 0x31, 13 } else .{ 0x1c, 0x7e, 0xd6, 13 };
            for (0..12) |k| {
                const t0 = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 12.0;
                const t1 = 2 * std.math.pi * @as(f64, @floatFromInt(k + 1)) / 12.0;
                v.mark_rings.append(gpa, .{
                    .ax = @floatCast(m.x + m.r * @cos(t0)),
                    .ay = @floatCast(m.y + m.r * @sin(t0)),
                    .bx = @floatCast(m.x + m.r * @cos(t1)),
                    .by = @floatCast(m.y + m.r * @sin(t1)),
                    .z = @floatCast(m.z + 0.3),
                    .h = 0.4,
                    .w = 0.5,
                    .rgba = color,
                }) catch return error.OutOfMemory;
            }
        }
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

        var boxes = v.beads;
        boxes.clearRetainingCapacity();
        defer v.beads = boxes;
        v.bead_end.clearRetainingCapacity();
        v.layer_end.clearRetainingCapacity();
        v.path_start.clearRetainingCapacity();
        var zmax: f32 = 0;
        const pts = tp.points.items;
        // A value mode: the value of each path, and the range of the ramp.
        const values = try v.pathValues(tp);
        defer if (values.len > 0) gpa.free(values);
        for (tp.layer_ends.items, 0..) |layer_end, l| {
            const p0: u32 = if (l == 0) 0 else tp.layer_ends.items[l - 1];
            const z = tp.layer_z.items[l] * sz;
            zmax = @max(zmax, z);
            for (p0..layer_end) |pi| {
                v.path_start.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
                const start: u32 = if (pi == 0) 0 else tp.path_ends.items[pi - 1];
                const end = tp.path_ends.items[pi];
                if (end - start < 2) continue;
                const f = tp.path_features.items[pi];
                const rgb = switch (v.mode) {
                    .print => filament,
                    .features => feature_rgb[if (f < feature_rgb.len) f else 0],
                    else => ramp(v.legend, values[pi], v.mode == .layer_time),
                };
                // The bead height of the path: the layer height, or the
                // height of all the layers of combined infill.
                const ph = tp.pathHeight(pi, l);
                const h = ph * sz;
                const w: f32 = @floatCast(@import("../flow.zig").beadWidth(tp.path_area.items[pi], ph) * sxy);
                if (!(w > 0)) continue;
                const closed = tp.path_closed.items[pi] != 0 and end - start > 2;
                const segs = end - start - 1 + @as(u32, @intFromBool(closed));
                // The times of the beads: the path time, spread over its
                // segments by length (the speed is the same along a path).
                var path_len: f32 = 0;
                for (0..segs) |k| {
                    const a = start + @as(u32, @intCast(k));
                    const b = if (a + 1 < end) a + 1 else start;
                    path_len += std.math.hypot(pts[2 * b] - pts[2 * a], pts[2 * b + 1] - pts[2 * a + 1]);
                }
                const t0 = tp.path_start_time.items[pi];
                const t1 = tp.path_end_time.items[pi];
                // A path with a z for each point (slope smoothing): each
                // bead has the mean z and area of its two ends, and goes
                // down to the top of the layer below.
                const z_start = if (pi < tp.path_z_start.items.len) tp.path_z_start.items[pi] else app_mod.Toolpaths.no_z;
                const z_low = (tp.layer_z.items[l] - tp.layer_height.items[l]) * sz;
                var run: f32 = 0;
                for (0..segs) |k| {
                    const a = start + @as(u32, @intCast(k));
                    const b = if (a + 1 < end) a + 1 else start;
                    run += std.math.hypot(pts[2 * b] - pts[2 * a], pts[2 * b + 1] - pts[2 * a + 1]);
                    v.bead_end.append(gpa, if (path_len > 0) t0 + (t1 - t0) * run / path_len else t1) catch return error.OutOfMemory;
                    var bz = z;
                    var bh = h;
                    var bw = w;
                    if (z_start != app_mod.Toolpaths.no_z) {
                        const ia = z_start + (a - start);
                        const ib = z_start + (b - start);
                        bz = (tp.point_z.items[ia] + tp.point_z.items[ib]) / 2 * sz;
                        bh = @max(bz - z_low, 0.01);
                        const area = (tp.point_area.items[ia] + tp.point_area.items[ib]) / 2;
                        bw = @floatCast(@import("../flow.zig").beadWidth(area, bh / sz) * sxy);
                    }
                    boxes.append(gpa, .{
                        .ax = center[0] + (pts[2 * a] - center[0]) * sxy,
                        .ay = center[1] + (pts[2 * a + 1] - center[1]) * sxy,
                        .bx = center[0] + (pts[2 * b] - center[0]) * sxy,
                        .by = center[1] + (pts[2 * b + 1] - center[1]) * sxy,
                        .z = bz,
                        .h = bh,
                        .w = bw,
                        // The alpha byte has the feature, for `setFocus`.
                        .rgba = .{ rgb[0], rgb[1], rgb[2], f },
                    }) catch return error.OutOfMemory;
                }
            }
            v.layer_end.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        }
        v.path_start.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        try v.loadMarks(tp, filament, center, sxy, sz);
        try v.renderer.setInstances(boxes.items, v.marks.items);
        v.more.clearRetainingCapacity();

        if (app.partBounds()) |b| {
            // The camera turns around the center of the bed (as in other
            // slicers), at half the height of the part. The distance shows
            // all of the part, also when it is not at the center.
            const bx: f32 = @floatCast(s.machine.bed_size_x / 2);
            const by: f32 = @floatCast(s.machine.bed_size_y / 2);
            v.home = .{ bx, by, zmax / 2 };
            if (first_load) v.target = v.home;
            var reach: f32 = 0;
            for ([_]f64{ b[0], b[2] }) |x| for ([_]f64{ b[1], b[3] }) |y| {
                reach = @max(reach, std.math.hypot(@as(f32, @floatCast(x)) - bx, @as(f32, @floatCast(y)) - by));
            };
            v.extent = @max(2 * reach, zmax);
        }
        if (first_load) {
            v.reset();
            v.layer = if (v.layer_end.items.len > 0) v.layer_end.items.len - 1 else 0;
        }
    }

    /// The value of each path for a value mode (empty for the others), and
    /// `legend`: the range of the ramp (the 2nd to the 98th percentile, so
    /// one odd path does not take the whole ramp).
    fn pathValues(v: *View, tp: *const app_mod.Toolpaths) Error![]f32 {
        v.legend = .{ 0, 0 };
        if (v.mode == .print or v.mode == .features) return &.{};
        const n = tp.path_ends.items.len;
        const values = gpa.alloc(f32, n) catch return error.OutOfMemory;
        errdefer gpa.free(values);
        const pts = tp.points.items;
        var l: usize = 0;
        for (0..n) |pi| {
            while (l + 1 < tp.layer_ends.items.len and tp.layer_ends.items[l] <= pi) l += 1;
            const start: u32 = if (pi == 0) 0 else tp.path_ends.items[pi - 1];
            const end = tp.path_ends.items[pi];
            var len: f32 = 0;
            var k = start;
            while (k + 1 < end) : (k += 1) len += std.math.hypot(pts[2 * k + 2] - pts[2 * k], pts[2 * k + 3] - pts[2 * k + 1]);
            if (tp.path_closed.items[pi] != 0 and end - start > 2) len += std.math.hypot(pts[2 * start] - pts[2 * (end - 1)], pts[2 * start + 1] - pts[2 * (end - 1) + 1]);
            const dt = tp.path_end_time.items[pi] - tp.path_start_time.items[pi];
            const speed: f32 = if (dt > 0) len / dt else 0;
            values[pi] = switch (v.mode) {
                .speed => speed,
                .flow => speed * tp.path_area.items[pi],
                .width => @floatCast(@import("../flow.zig").beadWidth(tp.path_area.items[pi], tp.pathHeight(pi, l))),
                .layer_time => blk: {
                    const last = tp.layer_ends.items[l];
                    const t_end = if (last > 0) tp.path_end_time.items[last - 1] else 0;
                    const t_start = if (l == 0 or tp.layer_ends.items[l - 1] == 0) 0 else tp.path_end_time.items[tp.layer_ends.items[l - 1] - 1];
                    break :blk t_end - t_start;
                },
                else => 0,
            };
        }
        // The range: the 2nd and the 98th percentile of the values.
        const sorted = gpa.dupe(f32, values) catch return error.OutOfMemory;
        defer gpa.free(sorted);
        std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
        if (sorted.len > 0) {
            const lo = sorted[sorted.len * 2 / 100];
            const hi = sorted[@min(sorted.len - 1, sorted.len * 98 / 100)];
            v.legend = .{ lo, if (hi > lo) hi else lo + 1 };
        }
        return values;
    }

    /// The seam blobs, the travel moves, and the retractions of each
    /// layer, from the same toolpaths and in the same cooled shape as the
    /// beads.
    fn loadMarks(v: *View, tp: *const app_mod.Toolpaths, filament: [3]u8, center: [2]f32, sxy: f32, sz: f32) Error!void {
        v.marks.clearRetainingCapacity();
        v.mark_layer_end.clearRetainingCapacity();
        const pts = tp.points.items;
        const flow = @import("../flow.zig");
        const seam_rgb = if (v.mode == .print) filament else feature_rgb[10];
        for (tp.layer_ends.items, 0..) |layer_end, l| {
            const p0: u32 = if (l == 0) 0 else tp.layer_ends.items[l - 1];
            const z = tp.layer_z.items[l] * sz;
            const h = tp.layer_height.items[l] * sz;
            // The end of the path before: the travel starts there.
            var prev: ?[2]f32 = null;
            for (p0..layer_end) |pi| {
                const start: u32 = if (pi == 0) 0 else tp.path_ends.items[pi - 1];
                const end = tp.path_ends.items[pi];
                if (end == start) continue;
                const first = [2]f32{
                    center[0] + (pts[2 * start] - center[0]) * sxy,
                    center[1] + (pts[2 * start + 1] - center[1]) * sxy,
                };
                const closed = tp.path_closed.items[pi] != 0 and end - start > 2;
                const last_i = if (closed) start else end - 1;
                const last = [2]f32{
                    center[0] + (pts[2 * last_i] - center[0]) * sxy,
                    center[1] + (pts[2 * last_i + 1] - center[1]) * sxy,
                };
                const f = tp.path_features.items[pi];
                // The seam: the start and the end of an outer wall loop
                // meet there, and leave a small blob.
                if (closed and f == 0) {
                    const w: f32 = @floatCast(flow.beadWidth(tp.path_area.items[pi], tp.layer_height.items[l]) * sxy);
                    try v.addMark(.{ .ax = first[0], .ay = first[1], .bx = first[0], .by = first[1], .z = z + 0.15 * h, .h = h * 1.25, .w = w * 1.15, .rgba = .{ seam_rgb[0], seam_rgb[1], seam_rgb[2], 10 } });
                }
                if (prev) |p| {
                    const retracted = tp.path_retract.items.len > pi and tp.path_retract.items[pi] != 0;
                    const lift: f32 = if (retracted) tp.z_hop else 0;
                    if (std.math.hypot(first[0] - p[0], first[1] - p[1]) > 0.05) {
                        const t = feature_rgb[11];
                        try v.addMark(.{ .ax = p[0], .ay = p[1], .bx = first[0], .by = first[1], .z = z + lift + 0.08, .h = 0.06, .w = 0.06, .rgba = .{ t[0], t[1], t[2], 11 } });
                    }
                    if (retracted) {
                        const r = feature_rgb[12];
                        try v.addMark(.{ .ax = p[0], .ay = p[1], .bx = p[0], .by = p[1], .z = z + 0.35, .h = 0.3, .w = 0.3, .rgba = .{ r[0], r[1], r[2], 12 } });
                    }
                }
                prev = last;
            }
            v.mark_layer_end.append(gpa, @intCast(v.marks.items.len)) catch return error.OutOfMemory;
        }
    }

    fn addMark(v: *View, m: vk.Instance) Error!void {
        v.marks.append(gpa, m) catch return error.OutOfMemory;
    }

    /// The colors: the filament color, or one color for each feature. Call
    /// `load` again after a change.
    pub fn setMode(v: *View, mode: Mode) void {
        v.mode = mode;
    }

    /// Highlights the beads of path `path` (an index into the toolpaths of
    /// the app), or nothing if `path` is null.
    pub fn setHighlight(v: *View, path: ?usize) void {
        v.seg_bead = null;
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

    /// Shows a frame on the bed around the footprint of a selected part, or
    /// none (null).
    pub fn setPartBox(v: *View, box: ?[4]f32) void {
        v.part_box = box;
    }

    /// Shows the beads of some features clearly and fades the others: a
    /// bit (1 << feature) for each feature in `mask`, or 0 to end the
    /// focus. Only beads with a top at or under `zmax` are in focus (pass
    /// infinity for all layers).
    pub fn setFocus(v: *View, mask: u32, zmax: f32) void {
        v.focus_mask = mask & 0xffff;
        v.focus_zmax = zmax;
    }

    /// Shows the layers 0 to `layer`, and stops the replay.
    pub fn setLayer(v: *View, layer: usize) void {
        v.layer = layer;
        v.time = null;
    }

    /// Shows the layers `lo` to `hi`, and stops the replay.
    pub fn setLayerRange(v: *View, lo: usize, hi: usize) void {
        v.layer_lo = @min(lo, hi);
        v.layer = hi;
        v.time = null;
    }

    /// Shows the print as it is at `t` seconds after the start: each bead
    /// that is done, and the part of the bead that the nozzle is printing.
    pub fn setTime(v: *View, t: f32) void {
        v.time = t;
    }

    /// The time (s) at the end of the last bead.
    pub fn duration(v: *const View) f32 {
        if (v.bead_end.items.len == 0) return 0;
        return v.bead_end.items[v.bead_end.items.len - 1];
    }

    /// The layer that the nozzle prints at time `t`.
    pub fn layerAtTime(v: *const View, t: f32) usize {
        const n = v.beadsDoneAt(t);
        var layer: usize = 0;
        while (layer + 1 < v.layer_end.items.len and v.layer_end.items[layer] <= n) layer += 1;
        return layer;
    }

    /// The number of beads that are done at time t.
    fn beadsDoneAt(v: *const View, t: f32) usize {
        var lo: usize = 0;
        var hi: usize = v.bead_end.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (v.bead_end.items[mid] <= t) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn pose(v: *const View) Pose {
        return .{ .target = v.target, .rot = v.rot, .dist = v.dist };
    }

    fn setPose(v: *View, p: Pose) void {
        v.target = p.target;
        v.rot = p.rot;
        v.dist = p.dist;
    }

    /// Points the camera from a turn angle around the vertical axis (yaw)
    /// and a tilt above the bed (pitch), with no roll.
    pub fn setAngles(v: *View, yaw: f32, pitch: f32) void {
        v.rot = quatFromAngles(yaw, pitch);
    }

    /// Moves the goal by the change from `before` to the current pose, so
    /// a drag during an animation does not fight the animation.
    fn carryGoal(v: *View, before: Pose) void {
        const g = &(v.goal orelse return);
        for (0..3) |k| g.target[k] += v.target[k] - before.target[k];
        const delta = qmul(v.rot, qconj(before.rot));
        g.rot = qnormalize(qmul(delta, g.rot));
    }

    /// Moves the camera toward the goal for a time step of dt seconds.
    /// Returns true while the camera still moves. The motion slows down
    /// near the goal (an exponential ease with a time constant of 70 ms).
    pub fn animate(v: *View, dt: f32) bool {
        const g = v.goal orelse return false;
        const k = 1 - @exp(-@max(dt, 0) / 0.07);
        for (0..3) |i| v.target[i] += (g.target[i] - v.target[i]) * k;
        v.rot = qslerp(v.rot, g.rot, k);
        v.dist *= std.math.pow(f32, g.dist / v.dist, k);
        // Stop when the rest of the motion is less than a pixel.
        var off: f32 = 0;
        for (0..3) |i| off = @max(off, @abs(g.target[i] - v.target[i]));
        const close = off < v.dist * 1e-4 and qangle(v.rot, g.rot) < 1e-4 and @abs(g.dist / v.dist - 1) < 1e-4;
        if (close) {
            v.setPose(g);
            v.goal = null;
            return false;
        }
        return true;
    }

    /// The same as `zoomAt`, but `animate` moves the camera there. Steps
    /// add up: each step starts from the goal of the step before.
    pub fn zoomAtSmooth(v: *View, factor: f32, px: f32, py: f32) void {
        const now = v.pose();
        if (v.goal) |g| v.setPose(g);
        v.zoomAt(factor, px, py);
        v.goal = v.pose();
        v.setPose(now);
    }

    /// The same as `reset`, but `animate` moves the camera there, on the
    /// shorter way around.
    pub fn resetSmooth(v: *View) void {
        const now = v.pose();
        v.reset();
        v.goal = v.pose();
        v.setPose(now);
    }

    /// The angle of a drag: radians for each pixel.
    const drag_angle = 0.008;

    /// Turns the camera by a drag of dx, dy pixels: around the vertical
    /// axis of the world, and a tilt around the right axis of the screen.
    /// The tilt has no limit: the camera can go under the part and over
    /// the top. Upside down, a sideways drag turns the other way, so the
    /// part follows the hand. An orbit adds no roll.
    pub fn orbit(v: *View, dx: f32, dy: f32) void {
        const before = v.pose();
        defer v.carryGoal(before);
        const cam = v.camera();
        const sign: f32 = if (cam.u[2] < 0) 1 else -1;
        const yaw = qaxis(.{ 0, 0, 1 }, sign * dx * drag_angle);
        // The tilt axis is the right axis after the turn, so the tilt adds
        // no roll.
        const tilt = qaxis(qrotate(yaw, cam.s), -dy * drag_angle);
        v.rot = qnormalize(qmul(tilt, qmul(yaw, v.rot)));
    }

    /// Turns the camera freely by a drag of dx, dy pixels: around the up
    /// and the right axes of the screen. Drags in turn can roll the view,
    /// so the part can turn to any direction.
    pub fn rotate(v: *View, dx: f32, dy: f32) void {
        const before = v.pose();
        defer v.carryGoal(before);
        const cam = v.camera();
        const a = qaxis(cam.u, -dx * drag_angle);
        const b = qaxis(cam.s, -dy * drag_angle);
        v.rot = qnormalize(qmul(b, qmul(a, v.rot)));
    }

    /// Moves the camera nearer (factor < 1) or further (factor > 1).
    pub fn zoom(v: *View, factor: f32) void {
        v.dist = @max(v.extent * 0.05 + 1, v.dist * factor);
    }

    /// Zooms toward the pixel (px, py): the point under the pixel, on the
    /// plane through the target that faces the camera, stays under it.
    pub fn zoomAt(v: *View, factor: f32, px: f32, py: f32) void {
        // The point under the pixel: on the first bead that the ray hits
        // (the surface that the user looks at), else on the plane through
        // the target.
        const old = v.dist;
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        const hit = v.rayHit(px, py, 1.6);
        const along = if (hit) |h| h.t else old / dot(dir, cam.f);
        const p = [3]f32{ cam.eye[0] + dir[0] * along, cam.eye[1] + dir[1] * along, cam.eye[2] + dir[2] * along };
        // The eye moves toward p by `f`, so p stays on the same ray. It
        // stops 2 mm in front of a surface: it never goes into the part.
        var f = factor;
        if (hit != null) f = @max(f, @min(1, 2 / @max(along, 1e-3)));
        if (hit == null) {
            v.zoom(factor);
            f = v.dist / old;
        } else v.dist = old * f;
        for (0..3) |k| v.target[k] = p[k] + (v.target[k] - p[k]) * f;
        // The orbit center stays as the zoom moves it (it does not jump to
        // the surface): the user turns the view around the same center.
    }

    /// Moves the view sideways and up or down by a drag of dx, dy pixels.
    /// The scene moves with the pointer.
    pub fn pan(v: *View, dx: f32, dy: f32) void {
        const before = v.pose();
        defer v.carryGoal(before);
        const cam = v.camera();
        // The size of one pixel on the plane through the target.
        const unit = 2 * v.dist * @tan(@as(f32, fov) / 2) / @as(f32, @floatFromInt(v.height));
        for (0..3) |k| v.target[k] += (-cam.s[k] * dx + cam.u[k] * dy) * unit;
    }

    /// Turns the camera around the vertical axis only, by a drag of dx
    /// pixels (a turntable).
    pub fn turn(v: *View, dx: f32) void {
        const before = v.pose();
        defer v.carryGoal(before);
        v.rot = qnormalize(qmul(qaxis(.{ 0, 0, 1 }, -dx * drag_angle), v.rot));
    }

    pub fn reset(v: *View) void {
        v.goal = null;
        v.target = v.home;
        v.setAngles(-1.9, 0.6);
        v.dist = v.extent * 2.8;
    }

    /// The camera position and its unit vectors: forward, right, and up.
    fn camera(v: *const View) struct { eye: [3]f32, f: [3]f32, s: [3]f32, u: [3]f32 } {
        const s_ = qrotate(v.rot, .{ 1, 0, 0 });
        const u = qrotate(v.rot, .{ 0, 1, 0 });
        const b = qrotate(v.rot, .{ 0, 0, 1 });
        const eye = [3]f32{ v.target[0] + v.dist * b[0], v.target[1] + v.dist * b[1], v.target[2] + v.dist * b[2] };
        return .{ .eye = eye, .f = .{ -b[0], -b[1], -b[2] }, .s = s_, .u = u };
    }

    /// The point of the bed (z = 0) under the pixel, or null if the ray
    /// does not meet the bed in front of the camera.
    pub fn bedPoint(v: *const View, px: f32, py: f32) ?[2]f64 {
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        if (@abs(dir[2]) < 1e-6) return null;
        const t = -cam.eye[2] / dir[2];
        if (t <= 0) return null;
        return .{ cam.eye[0] + dir[0] * t, cam.eye[1] + dir[1] * t };
    }

    /// The unit direction of the ray from the camera through pixel (px, py).
    fn pixelRay(v: *const View, cam: anytype, px: f32, py: f32) [3]f32 {
        const aspect = @as(f32, @floatFromInt(v.width)) / @as(f32, @floatFromInt(v.height));
        const tan_half = @tan(@as(f32, fov) / 2);
        const x = (2 * px / @as(f32, @floatFromInt(v.width)) - 1) * tan_half * aspect;
        const y = (1 - 2 * py / @as(f32, @floatFromInt(v.height))) * tan_half;
        return normalize(.{
            cam.f[0] + cam.s[0] * x + cam.u[0] * y,
            cam.f[1] + cam.s[1] * x + cam.u[1] * y,
            cam.f[2] + cam.s[2] * x + cam.u[2] * y,
        });
    }

    /// The path under the pixel (px, py), or null. The ray from the camera
    /// through the pixel is tested against each bead that the view shows.
    /// A bead is a flattened capsule: the test scales z by width / height
    /// around the middle of the bead, so the bead becomes a round capsule
    /// of radius width / 2, and then uses the distance from the ray to the
    /// segment. The nearest hit along the ray wins.
    pub fn pick(v: *const View, px: f32, py: f32) ?usize {
        const hit = v.pickSegment(px, py) orelse return null;
        return hit[0];
    }

    /// The first bead under a pixel, and the distance to it along the ray.
    /// `grow` scales the radius of each bead: more than 1 closes the gaps
    /// between the rounded beads (for the zoom).
    fn rayHit(v: *const View, px: f32, py: f32, grow: f32) ?struct { bead: usize, t: f32 } {
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        var count: usize = 0;
        if (v.layer_end.items.len > 0) count = v.layer_end.items[@min(v.layer, v.layer_end.items.len - 1)];
        var best: ?usize = null;
        var best_t: f32 = std.math.inf(f32);
        var start: usize = 0;
        if (v.layer_lo > 0 and v.layer_lo - 1 < v.layer_end.items.len) start = @min(count, v.layer_end.items[@min(v.layer_lo, v.layer) - 1]);
        for (v.beads.items[start..count], start..) |b, i| {
            const zc = b.z - b.h / 2;
            const k = if (b.h > 0) b.w / b.h else 1;
            const o = [3]f32{ cam.eye[0], cam.eye[1], zc + (cam.eye[2] - zc) * k };
            const d = [3]f32{ dir[0], dir[1], dir[2] * k };
            const a = [3]f32{ b.ax, b.ay, zc };
            const e = [3]f32{ b.bx - b.ax, b.by - b.ay, 0 };
            const hit = rayToSegment(o, d, a, e) orelse continue;
            const r = b.w / 2 * grow;
            if (hit.dist2 <= r * r and hit.t < best_t) {
                best_t = hit.t;
                best = i;
            }
        }
        const i = best orelse return null;
        return .{ .bead = i, .t = best_t };
    }

    /// The path and the segment of the path under a pixel.
    pub fn pickSegment(v: *const View, px: f32, py: f32) ?[2]usize {
        const i = (v.rayHit(px, py, 1) orelse return null).bead;
        // The path of bead i: the last path whose first bead is at or
        // before i.
        var lo: usize = 0;
        var hi: usize = v.path_start.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (v.path_start.items[mid] <= i) lo = mid + 1 else hi = mid;
        }
        // Paths with no beads have the same start as the next path.
        var p = lo - 1;
        while (p + 1 < v.path_start.items.len and v.path_start.items[p + 1] <= i) p += 1;
        return .{ p, i - v.path_start.items[p] };
    }

    /// The other paths of a multiple selection: yellow, as the highlighted
    /// path. The beads go to the GPU again (only on a change of the
    /// selection).
    pub fn setMore(v: *View, paths: []const usize) Error!void {
        v.more.clearRetainingCapacity();
        v.more.appendSlice(gpa, paths) catch return error.OutOfMemory;
        if (paths.len == 0) return v.renderer.setInstances(v.beads.items, v.marks.items);
        const copy = gpa.dupe(vk.Instance, v.beads.items) catch return error.OutOfMemory;
        defer gpa.free(copy);
        for (paths) |p| {
            if (p + 1 >= v.path_start.items.len) continue;
            for (copy[v.path_start.items[p]..v.path_start.items[p + 1]]) |*b| b.rgba = .{ 0xff, 0xc7, 0x0d, b.rgba[3] };
        }
        try v.renderer.setInstances(copy, v.marks.items);
    }

    /// Marks one segment of the highlighted path (the bead `seg` of path
    /// `path`) in a strong color, or none (null).
    pub fn setSegment(v: *View, path: usize, seg: ?usize) void {
        v.seg_bead = null;
        const s = seg orelse return;
        if (path + 1 >= v.path_start.items.len) return;
        const b = v.path_start.items[path] + s;
        if (b < v.path_start.items[path + 1]) v.seg_bead = b;
    }

    /// A nozzle over the point p (x, y, and the top z of the bead): a cone
    /// of round discs (beads of almost no length) to the tip, and a block
    /// over it. Returns the number of beads.
    fn nozzle(out: []vk.Instance, p: [3]f32) usize {
        const brass = [4]u8{ 0xc9, 0xa2, 0x4e, 13 };
        // A cone 4 mm high, from 0.4 mm at the tip to 4.4 mm, as 8 discs
        // that overlap, and a block of 7 mm over it.
        var parts: [9]struct { dz: f32, h: f32, w: f32 } = undefined;
        for (0..8) |k| {
            const f: f32 = @as(f32, @floatFromInt(k)) / 7;
            parts[k] = .{ .dz = 0.5 + f * 3.5, .h = 1.0, .w = 0.4 + f * 4.0 };
        }
        parts[8] = .{ .dz = 7.4, .h = 3.6, .w = 7.0 };
        var n: usize = 0;
        for (parts) |q| {
            if (n == out.len) break;
            out[n] = .{ .ax = p[0], .ay = p[1], .bx = p[0] + 0.001, .by = p[1], .z = p[2] + q.dz, .h = q.h, .w = q.w, .rgba = brass };
            n += 1;
        }
        return n;
    }

    pub fn draw(v: *View) Error!void {
        const cam = v.camera();
        const eye = cam.eye;
        const aspect = @as(f32, @floatFromInt(v.width)) / @as(f32, @floatFromInt(v.height));
        const proj = perspective(fov, aspect, @max(v.dist * 0.01, 0.1), v.dist * 10 + v.extent * 4);
        const view = lookAt(eye, v.target, cam.u);
        const mvp = mul(proj, view);
        var count: u32 = 0;
        var extras: [vk.max_extras]vk.Instance = undefined;
        var n_extras: usize = 0;
        if (v.time) |t| {
            const done = v.beadsDoneAt(t);
            count = @intCast(done);
            // The nozzle: at the end of the bead that prints now, or at the
            // end of the last bead done (on a travel).
            var tip: ?[3]f32 = null;
            if (done < v.beads.items.len) {
                const t_start = if (done == 0) 0 else v.bead_end.items[done - 1];
                const t_end = v.bead_end.items[done];
                if (t > t_start and t_end > t_start) {
                    var b = v.beads.items[done];
                    const f = @min(1, (t - t_start) / (t_end - t_start));
                    b.bx = b.ax + (b.bx - b.ax) * f;
                    b.by = b.ay + (b.by - b.ay) * f;
                    extras[n_extras] = b;
                    n_extras += 1;
                    tip = .{ b.bx, b.by, b.z };
                }
            }
            if (tip == null and done > 0 and done <= v.beads.items.len) {
                const b = v.beads.items[done - 1];
                tip = .{ b.bx, b.by, b.z };
            }
            if (tip) |p| n_extras += nozzle(extras[n_extras..], p);
        } else if (v.layer_end.items.len > 0) {
            count = v.layer_end.items[@min(v.layer, v.layer_end.items.len - 1)];
        }
        // The bottom of the layer range: the beads and marks of the layers
        // under it do not show (not in a replay).
        var first: u32 = 0;
        var mark_skip: u32 = 0;
        if (v.time == null and v.layer_lo > 0) {
            const lo = @min(v.layer_lo, v.layer);
            if (lo > 0 and lo - 1 < v.layer_end.items.len) first = v.layer_end.items[lo - 1];
            if (lo > 0 and lo - 1 < v.mark_layer_end.items.len) mark_skip = v.mark_layer_end.items[lo - 1];
        }
        // The marks of the layers that show.
        var mark_count: u32 = 0;
        if (v.mark_layer_end.items.len > 0) {
            const top = if (v.time) |t| v.layerAtTime(t) else v.layer;
            mark_count = v.mark_layer_end.items[@min(top, v.mark_layer_end.items.len - 1)];
        }
        mark_count -|= mark_skip;
        try v.renderer.draw(.{
            .extras = blk: {
                // The frame of the selected part: four thin beads on the bed.
                if (v.part_box) |pb| {
                    const corners = [_][2]f32{ .{ pb[0], pb[1] }, .{ pb[2], pb[1] }, .{ pb[2], pb[3] }, .{ pb[0], pb[3] } };
                    for (0..4) |k| {
                        const a = corners[k];
                        const b = corners[(k + 1) % 4];
                        extras[n_extras] = .{ .ax = a[0], .ay = a[1], .bx = b[0], .by = b[1], .z = 0.25, .h = 0.25, .w = 0.7, .rgba = .{ 0x33, 0x88, 0xff, 13 } };
                        n_extras += 1;
                    }
                }
                // A selected segment: the bead again, a little larger, in
                // orange, over the yellow path.
                if (v.seg_bead) |sb| if (sb < v.beads.items.len and n_extras < extras.len) {
                    var b = v.beads.items[sb];
                    b.w *= 1.35;
                    b.h *= 1.35;
                    b.z += b.h * 0.1;
                    b.rgba = .{ 0xff, 0x5a, 0x00, 13 };
                    extras[n_extras] = b;
                    n_extras += 1;
                };
                // The rings of the support marks.
                for (v.mark_rings.items) |b| {
                    if (n_extras == extras.len) break;
                    extras[n_extras] = b;
                    n_extras += 1;
                }
                break :blk extras[0..n_extras];
            },
            .clear = .{ 0.965, 0.969, 0.973 },
            // A light from above, in front, and to the right.
            .box = .{
                .mvp = mvp,
                .vec = .{ 0.35, -0.45, 0.82, 0 },
                .eye = .{ eye[0], eye[1], eye[2], if (std.math.isInf(v.focus_zmax)) 1e9 else v.focus_zmax },
                .params = .{ v.highlight[0], v.highlight[1], if (v.isolate and v.highlight[1] > v.highlight[0]) -1 else @as(f32, @floatFromInt(v.focus_mask)), if (v.mode == .print) 0 else 1 },
            },
            .box_count = count,
            .box_first = first,
            .mark_first = @intCast(v.beads.items.len + mark_skip),
            .mark_count = mark_count,
            .grid = .{ .mvp = mvp, .vec = .{ 0.80, 0.82, 0.85, 1 } },
            .grid_vertices = v.grid_vertices,
        });
    }
};

/// The color of a value on the ramp: blue, cyan, green, yellow, red (a
/// "turbo"-like ramp that people read as low to high). `reverse`: red for
/// the low values (the layer time: a short layer is the problem).
fn ramp(range: [2]f64, value: f32, reverse: bool) [3]u8 {
    var t: f64 = (value - range[0]) / (range[1] - range[0]);
    t = std.math.clamp(t, 0, 1);
    if (reverse) t = 1 - t;
    const stops = [_][3]f64{ .{ 0.19, 0.29, 0.86 }, .{ 0.10, 0.70, 0.85 }, .{ 0.25, 0.75, 0.30 }, .{ 0.95, 0.80, 0.15 }, .{ 0.85, 0.20, 0.15 } };
    const x = t * 4;
    const i: usize = @min(3, @as(usize, @intFromFloat(@floor(x))));
    const f = x - @as(f64, @floatFromInt(i));
    var out: [3]u8 = undefined;
    for (0..3) |k| out[k] = @intFromFloat(@round(255 * (stops[i][k] + (stops[i + 1][k] - stops[i][k]) * f)));
    return out;
}

/// The vertical field of view, in radians.
const fov = 0.8;

/// The closest approach of the ray o + t d (t >= 0) and the segment
/// a + s e (0 <= s <= 1): the ray parameter and the squared distance.
fn rayToSegment(o: [3]f32, d: [3]f32, a: [3]f32, e: [3]f32) ?struct { t: f32, dist2: f32 } {
    const w0 = [3]f32{ o[0] - a[0], o[1] - a[1], o[2] - a[2] };
    const dd = dot(d, d);
    const de = dot(d, e);
    const ee = dot(e, e);
    const dw = dot(d, w0);
    const ew = dot(e, w0);
    const den = dd * ee - de * de;
    var s: f32 = if (ee == 0) 0 else if (@abs(den) < 1e-12) 0 else std.math.clamp((dd * ew - de * dw) / den, 0, 1);
    var t: f32 = (de * s - dw) / dd;
    if (t < 0) {
        t = 0;
        s = if (ee == 0) 0 else std.math.clamp(ew / ee, 0, 1);
    }
    const p = [3]f32{ o[0] + d[0] * t - a[0] - e[0] * s, o[1] + d[1] * t - a[1] - e[1] * s, o[2] + d[2] * t - a[2] - e[2] * s };
    return .{ .t = t, .dist2 = dot(p, p) };
}

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

// ---- quaternions (x, y, z, w) for the camera direction ----

pub const Quat = [4]f32;

fn qmul(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

fn qconj(q: Quat) Quat {
    return .{ -q[0], -q[1], -q[2], q[3] };
}

fn qnormalize(q: Quat) Quat {
    const n = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return .{ q[0] / n, q[1] / n, q[2] / n, q[3] / n };
}

/// A turn of `angle` radians around the axis (right hand rule).
fn qaxis(axis: [3]f32, angle: f32) Quat {
    const a = normalize(axis);
    const sn = @sin(angle / 2);
    return .{ a[0] * sn, a[1] * sn, a[2] * sn, @cos(angle / 2) };
}

fn qrotate(q: Quat, p: [3]f32) [3]f32 {
    const r = qmul(qmul(q, .{ p[0], p[1], p[2], 0 }), qconj(q));
    return .{ r[0], r[1], r[2] };
}

fn qdot(a: Quat, b: Quat) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

/// The angle (radians) of the turn from a to b.
fn qangle(a: Quat, b: Quat) f32 {
    return 2 * std.math.acos(@min(1, @abs(qdot(a, b))));
}

/// The direction a fraction t of the way from a to b, on the shorter way.
fn qslerp(a: Quat, b_in: Quat, t: f32) Quat {
    var b = b_in;
    var d = qdot(a, b);
    if (d < 0) {
        b = .{ -b[0], -b[1], -b[2], -b[3] };
        d = -d;
    }
    if (d > 0.9995) {
        // Nearly the same: a straight line is exact enough.
        return qnormalize(.{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t });
    }
    const theta = std.math.acos(d);
    const sa = @sin((1 - t) * theta) / @sin(theta);
    const sb = @sin(t * theta) / @sin(theta);
    return .{ a[0] * sa + b[0] * sb, a[1] * sa + b[1] * sb, a[2] * sa + b[2] * sb, a[3] * sa + b[3] * sb };
}

/// The camera direction for a turn around the vertical axis (yaw) and a
/// tilt (pitch), with no roll: the eye is at (cos pitch cos yaw,
/// cos pitch sin yaw, sin pitch) from the target, and up is toward +z.
fn quatFromAngles(yaw: f32, pitch_in: f32) Quat {
    // Straight above or below, "toward +z" has no direction: move a very
    // small angle off the pole.
    var pitch = pitch_in;
    if (@abs(@cos(pitch)) < 1e-4) pitch -= 2e-4;
    const b = [3]f32{ @cos(pitch) * @cos(yaw), @cos(pitch) * @sin(yaw), @sin(pitch) };
    const up = [3]f32{ 0, 0, if (@cos(pitch) < 0) -1 else 1 };
    const s = normalize(cross(up, b));
    const u = cross(b, s);
    return quatFromBasis(s, u, b);
}

/// The quaternion of the rotation matrix with the columns x, y, z.
fn quatFromBasis(x: [3]f32, y: [3]f32, z: [3]f32) Quat {
    const m00 = x[0];
    const m11 = y[1];
    const m22 = z[2];
    const tr = m00 + m11 + m22;
    if (tr > 0) {
        const r = @sqrt(tr + 1) * 2;
        return qnormalize(.{ (y[2] - z[1]) / r, (z[0] - x[2]) / r, (x[1] - y[0]) / r, 0.25 * r });
    } else if (m00 > m11 and m00 > m22) {
        const r = @sqrt(1 + m00 - m11 - m22) * 2;
        return qnormalize(.{ 0.25 * r, (y[0] + x[1]) / r, (z[0] + x[2]) / r, (y[2] - z[1]) / r });
    } else if (m11 > m22) {
        const r = @sqrt(1 + m11 - m00 - m22) * 2;
        return qnormalize(.{ (y[0] + x[1]) / r, 0.25 * r, (z[1] + y[2]) / r, (z[0] - x[2]) / r });
    } else {
        const r = @sqrt(1 + m22 - m00 - m11) * 2;
        return qnormalize(.{ (z[0] + x[2]) / r, (z[1] + y[2]) / r, 0.25 * r, (x[1] - y[0]) / r });
    }
}

fn lookAt(eye: [3]f32, at: [3]f32, up: [3]f32) [16]f32 {
    const f = normalize(.{ at[0] - eye[0], at[1] - eye[1], at[2] - eye[2] });
    const s = normalize(cross(f, up));
    const u = cross(s, f);
    return .{
        s[0],         u[0],         -f[0],       0,
        s[1],         u[1],         -f[1],       0,
        s[2],         u[2],         -f[2],       0,
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
    // The ray from (0, -10, 0) along +y passes 0.5 from a segment at z 0.5.
    const hit = rayToSegment(.{ 0, -10, 0 }, .{ 0, 1, 0 }, .{ -1, 0, 0.5 }, .{ 2, 0, 0 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), hit.t, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), hit.dist2, 1e-5);
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

test "pick finds the nearest bead under the pixel" {
    const gpa = View.gpa;
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100 };
    defer {
        v.beads.deinit(gpa);
        v.layer_end.deinit(gpa);
        v.path_start.deinit(gpa);
    }
    v.target = .{ 0, 0, 0 };
    v.extent = 10;
    v.setAngles(-std.math.pi / 2.0, 0.3); // the camera is at -y, and looks along +y
    v.dist = 50;
    // Path 0: a bead at the bottom (layer 0). Path 1: a bead at the target
    // (layer 1), between the camera and path 0.
    const red = [4]u8{ 255, 0, 0, 255 };
    try v.beads.append(gpa, .{ .ax = -5, .ay = 3, .bx = 5, .by = 3, .z = -5, .h = 0.2, .w = 0.5, .rgba = red });
    try v.beads.append(gpa, .{ .ax = -5, .ay = 0, .bx = 5, .by = 0, .z = 0.1, .h = 0.2, .w = 0.5, .rgba = red });
    try v.layer_end.appendSlice(gpa, &.{ 1, 2 });
    try v.path_start.appendSlice(gpa, &.{ 0, 1, 2 });
    v.layer = 1;
    // The middle of the view looks at the target: path 1.
    try std.testing.expectEqual(@as(?usize, 1), v.pick(50, 50));
    // Far to the side: nothing.
    try std.testing.expectEqual(@as(?usize, null), v.pick(2, 2));
    // With only layer 0 shown, the middle ray misses path 0 (it is lower).
    v.layer = 0;
    try std.testing.expectEqual(@as(?usize, null), v.pick(50, 50));
}

test "the replay shows the beads that are done" {
    const gpa = View.gpa;
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100 };
    defer v.bead_end.deinit(gpa);
    try v.bead_end.appendSlice(gpa, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 0), v.beadsDoneAt(0.5));
    try std.testing.expectEqual(@as(usize, 2), v.beadsDoneAt(2));
    try std.testing.expectEqual(@as(usize, 2), v.beadsDoneAt(2.5));
    try std.testing.expectEqual(@as(usize, 4), v.beadsDoneAt(9));
    try std.testing.expectEqual(@as(f32, 4), v.duration());
}

test "zoom at a pixel keeps the point under it" {
    var v: View = .{ .renderer = undefined, .width = 200, .height = 100 };
    v.target = .{ 0, 0, 0 };
    v.extent = 10;
    v.setAngles(-1.9, 0.6);
    v.dist = 50;
    // The point on the target plane under pixel (150, 30), before and after.
    const before = v.camera();
    const d0 = v.pixelRay(before, 150, 30);
    const a0 = 50 / dot(d0, before.f);
    const p0 = [3]f32{ before.eye[0] + d0[0] * a0, before.eye[1] + d0[1] * a0, before.eye[2] + d0[2] * a0 };
    v.zoomAt(0.5, 150, 30);
    const after = v.camera();
    const d1 = v.pixelRay(after, 150, 30);
    const a1 = v.dist / dot(d1, after.f);
    const p1 = [3]f32{ after.eye[0] + d1[0] * a1, after.eye[1] + d1[1] * a1, after.eye[2] + d1[2] * a1 };
    for (0..3) |k| try std.testing.expectApproxEqAbs(p0[k], p1[k], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 25), v.dist, 1e-4);
    // A pan of one view height moves the target by the view height at the
    // target distance.
    const t0 = v.target;
    v.pan(0, 100);
    const moved = @sqrt((v.target[0] - t0[0]) * (v.target[0] - t0[0]) + (v.target[1] - t0[1]) * (v.target[1] - t0[1]) + (v.target[2] - t0[2]) * (v.target[2] - t0[2]));
    try std.testing.expectApproxEqAbs(2 * v.dist * @tan(@as(f32, fov) / 2), moved, 1e-3);
}

test "the camera can go under the part and over the top" {
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100 };
    v.target = .{ 0, 0, 0 };
    v.dist = 10;
    // The angles give the eye where the comment of quatFromAngles says.
    v.setAngles(0.7, 0.4);
    const e = v.camera().eye;
    try std.testing.expectApproxEqAbs(10 * @cos(@as(f32, 0.4)) * @cos(@as(f32, 0.7)), e[0], 1e-4);
    try std.testing.expectApproxEqAbs(10 * @sin(@as(f32, 0.4)), e[2], 1e-4);
    try std.testing.expect(v.camera().u[2] > 0);
    // A drag up moves the eye up.
    v.setAngles(0, 0);
    v.orbit(0, 50);
    try std.testing.expect(v.camera().eye[2] > 0);
    // Down past the bed: the eye is below the target.
    v.setAngles(0, 0);
    v.orbit(0, -150);
    try std.testing.expect(v.camera().eye[2] < 0);
    // Over the top: the camera is upside down, and its axes are still
    // unit vectors at right angles.
    v.setAngles(0, 0);
    v.orbit(0, 250);
    const cam = v.camera();
    try std.testing.expect(cam.u[2] < 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dot(cam.s, cam.s), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dot(cam.s, cam.u), 1e-5);
    // An orbit adds no roll: the right axis stays level.
    v.orbit(80, 30);
    v.orbit(-40, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.camera().s[2], 1e-4);
    // At the pole itself, the axes are defined.
    v.setAngles(0, std.math.pi / 2.0);
    const pole = v.camera();
    try std.testing.expect(!std.math.isNan(pole.s[0]));
}

test "the free rotation can roll the view" {
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100 };
    v.target = .{ 0, 0, 0 };
    v.dist = 10;
    v.setAngles(0, 0.5);
    // Up, then sideways: the screen right axis is no longer level.
    v.rotate(0, 120);
    v.rotate(120, 0);
    try std.testing.expect(@abs(v.camera().s[2]) > 0.1);
    // The distance to the target stays the same.
    const e = v.camera().eye;
    try std.testing.expectApproxEqAbs(@as(f32, 10), @sqrt(dot(e, e)), 1e-4);
    // The reset removes the roll.
    v.extent = 10;
    v.home = .{ 0, 0, 0 };
    v.resetSmooth();
    while (v.animate(1.0 / 60.0)) {}
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.camera().s[2], 1e-4);
}

test "the camera animation reaches the goal, and a drag carries the goal" {
    var v: View = .{ .renderer = undefined, .width = 200, .height = 100 };
    v.home = .{ 10, 20, 5 };
    v.extent = 30;
    v.target = .{ 0, 0, 0 };
    v.setAngles(2.9, 0.1);
    v.dist = 200;
    v.resetSmooth();
    try std.testing.expect(v.goal != null);
    var frames: usize = 0;
    var last = qangle(v.rot, v.goal.?.rot);
    while (v.animate(1.0 / 60.0)) : (frames += 1) {
        // The camera only gets nearer to the goal.
        if (v.goal) |g| {
            const now = qangle(v.rot, g.rot);
            try std.testing.expect(now <= last + 1e-6);
            last = now;
        }
        try std.testing.expect(frames < 200);
    }
    try std.testing.expect(frames > 5);
    try std.testing.expectApproxEqAbs(@as(f32, 84), v.dist, 1e-3);
    try std.testing.expect(qangle(v.rot, quatFromAngles(-1.9, 0.6)) < 1e-3);
    try std.testing.expectEqual(@as(?View.Pose, null), v.goal);
    // Two scroll steps add up, and a turn during the animation moves the
    // goal by the same angle.
    v.zoomAtSmooth(0.5, 100, 50);
    v.zoomAtSmooth(0.5, 100, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 21), v.goal.?.dist, 1e-3);
    const goal_before = v.goal.?.rot;
    v.turn(10);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), qangle(goal_before, v.goal.?.rot), 1e-4);
    while (v.animate(1.0 / 60.0)) {}
    try std.testing.expectApproxEqAbs(@as(f32, 21), v.dist, 1e-3);
}
