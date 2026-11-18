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
//! direction: an orbit turns around the vertical axis and tilts (with no
//! roll, and the tilt stops at 89 degrees), and a free rotation turns around the axes of the screen (with roll). The
//! distance zooms. The projection is for Vulkan clip space: y goes down, and depth
//! goes from 0 to 1.
//!
//! This file is the same for all platforms. Only the backend talks to the
//! GPU. On Linux, vk.zig draws with Vulkan. In a browser (the wasm build)
//! and on macOS, web.zig keeps the frame data, and the shell draws it:
//! with WebGL2 in JavaScript, or with Metal in Swift.
//!
//! The web shell slices in a Web Worker and draws on the main thread, in
//! two wasm instances. The view of the worker loads the slice, and
//! `writeScene` gives its beads as bytes; the view of the main thread reads
//! them with `readScene`. The camera, the layer range, and the replay then
//! run on the main thread, with no wait for a slice.
//!
//! A pick (the bead under a pixel) tests the beads that the ray can hit.
//! The pick index has a box for each run of 32 beads in print order, and a
//! box for each layer. The ray skips a layer or a run whose box it misses,
//! or whose box is farther than the nearest hit so far. The layers go from
//! the top down, so the nearest hit comes early. A plate of many parts has
//! a million beads; a pick then tests a few thousand.
//!
//! The bed model of the printer (bed.zig), when the shell gives one, is a
//! static mesh under the plate: the backend gets it once (`setBed`), and
//! each frame only moves it to the middle of the bed. It draws after the
//! beads, in a soft gray: the parts over the plate (a frame, a back
//! plate) are see-through, so they do not hide the print.
//!
//! A 2D view (one layer from the top) also uses the view: the beads of a
//! layer, the outline of each layer, a pick in mm, and the steps along the
//! print for the keys h, j, k, l (see `stepPath`).
//!
//! A print view (a printer screen) shows a G-code file of any slicer
//! (`loadGcode`, with gcode_read.zig): the beads go straight into the GPU
//! buffer, with no copy in host memory. The printer reports the byte
//! offset that it has read (`setPosition`), and the view draws the beads up
//! to it, lights the layer that prints, and shows the nozzle. A scrubber
//! picks a layer (`setLayer`). One or two fingers turn, zoom, and move the
//! camera (`touch`). The reduced view leaves out the tools and the marks,
//! and uses the coarse bead mesh.

const std = @import("std");
const builtin = @import("builtin");
const is_web = builtin.cpu.arch.isWasm();
/// The backend keeps the frame data and the shell draws it (web.zig).
const frame_backend = is_web or builtin.os.tag == .macos;
const vk = if (frame_backend) @import("web.zig") else @import("vk.zig");
const app_mod = @import("../app.zig");
const Draw = @import("frame.zig").Draw;
const PlateFrame = @import("frame.zig").PlateFrame;
const Push = @import("frame.zig").Push;
const plates_mod = @import("plates.zig");
const bed_mod = @import("../bed.zig");
const gcode_read = @import("../gcode_read.zig");

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
    .{ 0x66, 0xcc, 0xf2 }, // bridge
    .{ 0xe0, 0x1a, 0x26 }, // mark: seam
    .{ 0x33, 0x73, 0xf2 }, // mark: travel
    .{ 0xf2, 0x40, 0xbf }, // mark: retraction
};

/// The number of features: the marks follow them in `feature_rgb`.
const n_features = @typeInfo(@import("../settings.zig").Feature).@"enum".fields.len;
/// The codes in the alpha byte of a bead (see shaders/box.vert): a feature
/// (0 to n_features - 1), a mark (the seam, a travel, a retraction), or an
/// overlay (always solid, in its own color).
const code_seam: u8 = n_features;
const code_travel: u8 = n_features + 1;
const code_retract: u8 = n_features + 2;
const code_overlay: u8 = n_features + 3;
comptime {
    // The thumbnails of G-code (cpu.zig) have the same feature colors.
    for (@import("cpu.zig").feature_rgb, 0..) |rgb, i| std.debug.assert(std.mem.eql(u8, &rgb, &feature_rgb[i]));
    // shaders/box.vert has the same codes and colors: change it with them.
    std.debug.assert(n_features == 11 and feature_rgb.len == n_features + 3);
}

pub const Surface = vk.Surface;
pub const Error = vk.Error;

pub const Mode = enum(c_int) { print = 0, features = 1, speed = 2, flow = 3, layer_time = 4, width = 5 };

/// A support area that the view draws (see View.sup_areas).
pub const SupportArea = struct {
    first: u32,
    n: u32,
    /// The kind of support.Mark: 3 (block) is red, the others blue.
    kind: u8,
    flags: u8,

    /// The path is closed (an area). Else the path that the user draws
    /// now: no fill, and its first point is large, to close it.
    pub const closed: u8 = 1;
    /// The selected area: a thicker line, and its points.
    pub const selected: u8 = 2;
    /// Draw the points.
    pub const points: u8 = 4;
};

pub const View = struct {
    renderer: *vk.Renderer,
    mode: Mode = .print,
    /// The range of the ramp of a value mode, after `load`.
    legend: [2]f64 = .{ 0, 0 },
    layer_end: std.ArrayList(u32) = .empty,
    /// The first bead of each path, and one more item at the end: the
    /// beads of path i are path_start[i] to path_start[i + 1].
    path_start: std.ArrayList(u32) = .empty,
    /// The end of each layer in the paths: the paths of layer j are
    /// layer_path_end[j - 1] to layer_path_end[j].
    layer_path_end: std.ArrayList(u32) = .empty,
    /// The outline of each layer (the material of the layer), for a 2D
    /// view: x, y pairs in mm, in the cooled shape of the beads. Ring i has
    /// the points outline_ends[i - 1] to outline_ends[i]; layer j has the
    /// rings outline_layer_end[j - 1] to outline_layer_end[j]. Outer rings
    /// go counterclockwise and holes clockwise (fill by the nonzero rule).
    outline_points: std.ArrayList(f32) = .empty,
    outline_ends: std.ArrayList(u32) = .empty,
    outline_layer_end: std.ArrayList(u32) = .empty,
    /// The pick index (see `buildPickIndex`): boxes of runs of beads, and
    /// the box and the end of the runs of each layer. It comes from the
    /// beads, so a scene in bytes does not have it.
    pick_runs: std.ArrayList(PickBox) = .empty,
    layer_boxes: std.ArrayList(PickBox) = .empty,
    /// Boxes of about `draw_chunk` beads (whole runs), and the widest bead
    /// of each, for the draw list (see `drawList`).
    draw_chunks: std.ArrayList(PickBox) = .empty,
    chunk_width: std.ArrayList(f32) = .empty,
    /// The draw list of the last frame.
    draws: std.ArrayList(Draw) = .empty,
    highlight: [2]f32 = .{ 0, 0 },
    /// The dark look (the dark mode of the system): a dark background, and
    /// a grid and a bed for it.
    dark: bool = false,
    /// The rings of the support marks of the app (see support.Mark): 12
    /// beads each, drawn as extras.
    mark_rings: std.ArrayList(vk.Instance) = .empty,
    /// The support areas of the support editor (see app/support_areas.zig):
    /// the points of all areas, and for each area its points in them, its
    /// kind, and its flags. A load fills them from the app; a shell that
    /// edits an area sets them (`setSupportAreas`).
    sup_pts: std.ArrayList([3]f32) = .empty,
    sup_areas: std.ArrayList(SupportArea) = .empty,
    /// A pick (`surfacePoint`) skips the support lines: the Support tool
    /// is on, and the user clicks the part under the support.
    pick_skip_support: bool = false,
    /// The gaps of one layer (see gaps.zig): a thin red bead for each run
    /// of gap cells, and the layer, or null.
    gap_beads: std.ArrayList(vk.Instance) = .empty,
    gap_layer: ?usize = null,
    /// The extra beads of a frame (max_extras), made once.
    extras_buf: ?[]vk.Instance = null,
    /// The cooled shape (see `load`): points move about `xf_center` by
    /// `xf_sxy`, and z by `xf_sz`.
    xf_center: [2]f32 = .{ 0, 0 },
    xf_sxy: f32 = 1,
    xf_sz: f32 = 1,
    /// The other selected paths (a multiple selection): their beads are
    /// yellow in the instance buffer. A load clears them.
    more: std.ArrayList(usize) = .empty,
    /// The bead of a selected segment (see setSegment), or null.
    seg_bead: ?usize = null,
    /// The points of the measure tape (see `setMeasure`): 0, 1, or 2.
    measure: [2][3]f32 = undefined,
    measure_n: u8 = 0,
    /// With a selection: the other beads are ghosts.
    isolate: bool = false,
    /// The features in focus (a bit for each), or 0 for no focus. The
    /// other beads fade. See `setFocus`.
    focus_mask: u32 = 0,
    /// With a focus: only the beads with a top at or under this z are in
    /// focus (the first layer, for a first layer setting).
    focus_zmax: f32 = std.math.inf(f32),
    /// The features that have beads (a bit for each), and the beads that
    /// the mask is for (their pointer and count).
    present: u32 = 0,
    present_key: [2]usize = .{ 0, 0 },
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
    /// The time (s) at the start of each bead: the end of the bead before,
    /// or for the first bead of a path the start of the path (the travel
    /// to it is between).
    bead_start: std.ArrayList(f32) = .empty,
    /// The fan of each bead, from 0 to 255 (for the toolhead).
    bead_fan: std.ArrayList(u8) = .empty,
    /// The beads of the toolhead of a replay (see `toolhead`).
    head_buf: [128]vk.Instance = undefined,
    /// The replay time (s), or null to show whole layers.
    time: ?f32 = null,
    /// The footprint of the selected part (x0, y0, x1, y1), or null: a
    /// frame on the bed around it.
    part_box: ?[4]f32 = null,
    /// The rings of the Turn tool around the selected part (see
    /// `setRings`): the center and the radius, mm.
    rings: ?struct { c: [3]f32, r: f32 } = null,
    /// The plane of a cut (see `setCut`): x0, y0, x1, y1, and z (mm).
    cut_plane: ?[5]f32 = null,
    /// The ring of a turn in progress (0 X, 1 Y, 2 Z), or -1.
    ring_axis: i8 = -1,
    /// The press of a turn: the center of the ring on the screen, the
    /// angle of the press about it, and the sense of the ring.
    ring_press: struct { cx: f32 = 0, cy: f32 = 0, a0: f32 = 0, sense: f32 = 1 } = .{},
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
    /// The distance of `reset`, in extents: a print view (a small screen
    /// with only the part) starts nearer.
    home_dist: f32 = 2.8,
    /// The camera direction: it turns the camera axes (right = x, up = y,
    /// back = z) into world directions. The eye is at target + dist * back.
    rot: Quat = .{ 0, 0, 0, 1 },
    dist: f32 = 100,
    /// The camera pose that `animate` moves to, or null if the camera does
    /// not move. The scroll zoom and the reset set it. A drag moves the
    /// camera at once, and moves the goal by the same amount.
    goal: ?Pose = null,
    /// The bed size in mm, for the grid.
    bed: [2]f32 = .{ 0, 0 },
    /// The vertices of the bed model with the backend (0: no bed model),
    /// and if it has a texture.
    bed_vertices: u32 = 0,
    bed_textured: bool = false,
    /// A view with no renderer (`loadPlate` uses one to read an app).
    headless: bool = false,
    /// The G-code file of a print view (see `loadGcode`), or null. The
    /// view reads it on each frame: the host keeps it.
    gcode: ?*const gcode_read.Reader = null,
    /// The byte offset of the print in the file (see `setPosition`), or
    /// null to show whole layers.
    position: ?u64 = null,
    /// The colors of a print view: one color for each feature, or the
    /// filament color.
    gcode_features: bool = false,
    filament_rgb: [3]u8 = .{ 0xd0, 0xd0, 0xcc },
    /// The beads of the top layer that shows are lit, and the layers
    /// under it are darker (a print view).
    lit: bool = true,
    /// The nozzle shows at the position of the print.
    show_head: bool = true,
    /// The reduced view of a printer screen: no tools, gizmos, selection,
    /// marks, or labels. Only the beads, the bed, and the nozzle draw.
    reduced: bool = false,
    /// The backend draws mesh level 2 as a ribbon that faces the camera
    /// (box.vert, tv.w = 2), for the beads a few pixels wide. Off by
    /// default: the ribbons changed the look of the beads (a far part
    /// looked flat and hatched). zs_view_set_ribbons turns it on.
    ribbons: bool = false,
    /// The detail governor of the shell (zs_view_set_detail): 1 is full
    /// detail; a larger value moves the mesh levels to wider beads, so a
    /// slow GPU draws fewer triangles. At 2 or more, a shell that can draw
    /// ribbons (`ribbon_ok`) uses them for the narrow beads.
    detail: f32 = 1,
    ribbon_ok: bool = false,
    /// The fingers on a touch screen (see `touch`): an id (-1: none) and
    /// the last point of each.
    touches: [2]Touch = .{ .{}, .{} },
    /// The light levels of the beads (see plates.zig), for a camera far
    /// from the plate. Only the web backend draws them.
    lite: plates_mod.Lite = .{},
    lite_gen: u32 = 0,
    /// The plates of the set (see plates.zig), in the row from left to
    /// right. Item `active` is the plate of this view: it has no beads of
    /// its own. Empty: one plate, and no row.
    plates: std.ArrayList(plates_mod.Plate) = .empty,
    active: usize = 0,
    /// The generation counter of the bead buffers of the plates.
    plate_gen: u32 = 0,
    /// The grid lines of the other plates (x, y, z, in the world of the
    /// view): the plates that slice first, then from `plate_grid_dim` on
    /// the plates that cannot slice.
    plate_grid: std.ArrayList(f32) = .empty,
    plate_grid_dim: u32 = 0,
    plate_grid_gen: u32 = 0,
    /// The plates and their draws of the last frame.
    plate_frames: std.ArrayList(PlateFrame) = .empty,
    plate_draws: std.ArrayList(Draw) = .empty,
    /// The part of the plate of each path (Toolpaths.path_part), for a
    /// part preview.
    path_part: std.ArrayList(u32) = .empty,
    /// A part that turns or moves in the view only (see `setPartPreview`):
    /// its beads draw with their own matrix, until the next slice shows
    /// the part in its new place.
    preview: ?PartPreview = null,
    /// The bead ranges of the part of the preview, in print order.
    preview_ranges: std.ArrayList([2]u32) = .empty,
    /// The draws of the frame: the part of the preview, and the beads of
    /// the draw list without it.
    preview_draws: std.ArrayList(Draw) = .empty,
    rest_draws: std.ArrayList(Draw) = .empty,

    /// The camera: the target, the angles, and the distance.
    pub const Pose = struct { target: [3]f32, rot: Quat, dist: f32 };

    pub const Touch = struct { id: i64 = -1, x: f32 = 0, y: f32 = 0 };
    pub const TouchAction = enum(c_int) { down = 0, move = 1, up = 2, cancel = 3 };

    const gpa = if (is_web) (if (@import("../parallel.zig").wasm_pool) @import("../wasm_heap.zig").allocator else std.heap.wasm_allocator) else std.heap.c_allocator;

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
        v.deinitData();
        if (!v.headless) v.renderer.deinit();
        gpa.destroy(v);
    }

    /// Frees the data of the view, not the view and its renderer.
    pub fn deinitData(v: *View) void {
        v.lite.deinit(gpa);
        for (v.plates.items) |*p| p.deinit(gpa);
        v.plates.deinit(gpa);
        v.plate_grid.deinit(gpa);
        v.plate_frames.deinit(gpa);
        v.plate_draws.deinit(gpa);
        v.path_part.deinit(gpa);
        v.preview_ranges.deinit(gpa);
        v.preview_draws.deinit(gpa);
        v.rest_draws.deinit(gpa);
        v.layer_end.deinit(gpa);
        v.mark_rings.deinit(gpa);
        v.sup_pts.deinit(gpa);
        v.sup_areas.deinit(gpa);
        v.gap_beads.deinit(gpa);
        if (v.extras_buf) |b| gpa.free(b);
        v.more.deinit(gpa);
        v.path_start.deinit(gpa);
        v.layer_path_end.deinit(gpa);
        v.outline_points.deinit(gpa);
        v.outline_ends.deinit(gpa);
        v.outline_layer_end.deinit(gpa);
        v.pick_runs.deinit(gpa);
        v.layer_boxes.deinit(gpa);
        v.draw_chunks.deinit(gpa);
        v.chunk_width.deinit(gpa);
        v.draws.deinit(gpa);
        v.beads.deinit(gpa);
        v.bead_end.deinit(gpa);
        v.bead_start.deinit(gpa);
        v.bead_fan.deinit(gpa);
        v.marks.deinit(gpa);
        v.mark_layer_end.deinit(gpa);
    }

    /// Shows the bed model of a printer: the bytes of its mesh and texture
    /// files (either can be empty) and its place (see bed.zig). The
    /// vertices go to the GPU once.
    pub fn setBed(v: *View, place: bed_mod.Place, mesh: []const u8, texture: []const u8) (Error || bed_mod.Error)!void {
        var g = try bed_mod.build(gpa, mesh, texture, place);
        defer g.deinit(gpa);
        try v.renderer.setBed(g.vertices, g.image);
        v.bed_vertices = @intCast(g.vertices.len);
        v.bed_textured = g.image != null;
    }

    /// Shows the bed as the grid alone.
    pub fn clearBed(v: *View) void {
        v.renderer.setBed(&.{}, null) catch {};
        v.bed_vertices = 0;
        v.bed_textured = false;
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
        var verts: std.ArrayList([4]f32) = .empty;
        defer verts.deinit(gpa);
        var idx: std.ArrayList(u16) = .empty;
        defer idx.deinit(gpa);
        // The reduced view (a small screen, a small GPU) uses the coarse
        // mesh of the levels of detail for all beads.
        if (v.reduced) try beadMesh(&verts, &idx, 2, 2) else try beadMesh(&verts, &idx, 4, 4);
        try v.renderer.setMesh(verts.items, idx.items);
        // A coarser mesh for beads far from the camera: 36 triangles for
        // 100. Then the ribbon: 4 triangles. The GPU time goes with the
        // count of the triangles (a Benchy at a few pixels a bead on an
        // RTX 4070: 13.6 ms with the full mesh, 5.5 ms with 36 triangles,
        // 0.8 ms with 2).
        verts.clearRetainingCapacity();
        idx.clearRetainingCapacity();
        try beadMesh(&verts, &idx, 2, 2);
        try v.renderer.setLodMesh(1, verts.items, idx.items);
        verts.clearRetainingCapacity();
        idx.clearRetainingCapacity();
        try ribbonMesh(&verts, &idx);
        try v.renderer.setLodMesh(2, verts.items, idx.items);
    }

    /// The ribbon template (mesh level 2): a strip across the bead, from
    /// end a (x = 0) to end b (x = 1), with y from -1 to 1 across it, and
    /// w = 2. box.vert turns it to face the camera and gives it the normals
    /// of a round bead.
    fn ribbonMesh(verts: *std.ArrayList([4]f32), idx: *std.ArrayList(u16)) Error!void {
        for ([_]f32{ 0, 1 }) |u| for ([_]f32{ -1, 0, 1 }) |k| {
            verts.append(gpa, .{ u, k, 0, 2 }) catch return error.OutOfMemory;
        };
        idx.appendSlice(gpa, &.{ 0, 3, 4, 0, 4, 1, 1, 4, 5, 1, 5, 2 }) catch return error.OutOfMemory;
    }

    /// The bead mesh template: `cap` segments in each half circle of the
    /// ends, and `prof` segments in the profile.
    fn beadMesh(verts: *std.ArrayList([4]f32), idx: *std.ArrayList(u16), comptime cap: usize, comptime prof: usize) Error!void {
        const pi = std.math.pi;
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
    }

    /// Reads the toolpaths of the last slice of `app`, and the bed size.
    pub fn load(v: *View, app: *const app_mod.App) Error!void {
        const s = app.settings;
        v.gcode = null;
        v.position = null;
        v.home_dist = 2.8;
        // The support marks: a ring at the place and the layer of each.
        v.mark_rings.clearRetainingCapacity();
        for (app.marks.items) |m| {
            const color: [4]u8 = if (m.kind == .block) .{ 0xe0, 0x31, 0x31, code_overlay } else .{ 0x1c, 0x7e, 0xd6, code_overlay };
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
        // The support areas of the user.
        v.sup_pts.clearRetainingCapacity();
        v.sup_areas.clearRetainingCapacity();
        for (app.areas.list.items) |a| {
            var pts: [256][3]f32 = undefined;
            const n = @min(a.points.len, pts.len);
            for (a.points[0..n], pts[0..n]) |p, *q| q.* = .{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(p[2]) };
            try v.addSupportArea(pts[0..n], @intFromEnum(a.kind), SupportArea.closed);
        }
        // The modifier volumes: thin purple rings of their outline at a
        // few heights (they do not print, so the view has no beads for
        // them).
        if (app.job) |*pj| for (pj.instances) |inst| {
            if (inst.group >= pj.groups.len) continue;
            try v.addVolumeRings(&pj.groups[inst.group].job, inst.dx, inst.dy);
        };
        try v.loadGrid(@floatCast(s.machine.bed_size_x), @floatCast(s.machine.bed_size_y));
        const tp = app.allToolpaths() orelse {
            v.layer_end.clearRetainingCapacity();
            v.path_start.clearRetainingCapacity();
            v.layer_path_end.clearRetainingCapacity();
            v.outline_points.clearRetainingCapacity();
            v.outline_ends.clearRetainingCapacity();
            v.outline_layer_end.clearRetainingCapacity();
            v.path_part.clearRetainingCapacity();
            v.clearPreview();
            v.lite.clear();
            v.lite_gen = v.nextGen();
            try v.buildPickIndex();
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
        v.xf_center = center;
        v.xf_sxy = sxy;
        v.xf_sz = sz;

        var boxes = v.beads;
        boxes.clearRetainingCapacity();
        defer v.beads = boxes;
        v.bead_end.clearRetainingCapacity();
        v.bead_start.clearRetainingCapacity();
        v.bead_fan.clearRetainingCapacity();
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
                    path_len += @import("../geom.zig").hypot(pts[2 * b] - pts[2 * a], pts[2 * b + 1] - pts[2 * a + 1]);
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
                    run += @import("../geom.zig").hypot(pts[2 * b] - pts[2 * a], pts[2 * b + 1] - pts[2 * a + 1]);
                    v.bead_start.append(gpa, if (k == 0) t0 else v.bead_end.items[v.bead_end.items.len - 1]) catch return error.OutOfMemory;
                    v.bead_fan.append(gpa, if (pi < tp.path_fan.items.len) tp.path_fan.items[pi] else 255) catch return error.OutOfMemory;
                    v.bead_end.append(gpa, if (path_len > 0) t0 + (t1 - t0) * run / path_len else t1) catch return error.OutOfMemory;
                    var bz = z;
                    var bh = h;
                    var bw = w;
                    var seg_rgb = rgb;
                    if (z_start != app_mod.Toolpaths.no_z) {
                        const ia = z_start + (a - start);
                        const ib = z_start + (b - start);
                        bz = (tp.point_z.items[ia] + tp.point_z.items[ib]) / 2 * sz;
                        bh = @max(bz - z_low, 0.01);
                        const area = (tp.point_area.items[ia] + tp.point_area.items[ib]) / 2;
                        const bead: f32 = @floatCast(@import("../flow.zig").beadWidth(area, bh / sz));
                        bw = bead * sxy;
                        // The width mode: the width of this bead (an
                        // Arachne wall changes width along its path).
                        if (v.mode == .width) seg_rgb = ramp(v.legend, bead, false);
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
                        .rgba = .{ seg_rgb[0], seg_rgb[1], seg_rgb[2], f },
                    }) catch return error.OutOfMemory;
                }
            }
            v.layer_end.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        }
        v.path_start.append(gpa, @intCast(boxes.items.len)) catch return error.OutOfMemory;
        v.layer_path_end.clearRetainingCapacity();
        v.layer_path_end.appendSlice(gpa, tp.layer_ends.items) catch return error.OutOfMemory;
        v.path_part.clearRetainingCapacity();
        v.path_part.appendSlice(gpa, tp.path_part.items) catch return error.OutOfMemory;
        v.clearPreview();
        try v.loadOutlines(app, tp.layer_ends.items.len);
        try v.loadMarks(tp, filament, center, sxy, sz);
        if (!v.headless) try v.renderer.setInstances(boxes.items, v.marks.items);
        v.more.clearRetainingCapacity();
        // The light levels: only the frame backend draws them.
        if (frame_backend and !v.headless) {
            try v.lite.build(gpa, boxes.items, v.layer_end.items);
            v.lite_gen = v.nextGen();
        }
        // `boxes` goes back to v.beads at the end of this function.
        v.beads = boxes;
        try v.buildPickIndex();

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
                reach = @max(reach, @import("../geom.zig").hypot(@as(f32, @floatCast(x)) - bx, @as(f32, @floatCast(y)) - by));
            };
            v.extent = @max(2 * reach, zmax);
        }
        if (first_load) {
            v.reset();
            v.layer = if (v.layer_end.items.len > 0) v.layer_end.items.len - 1 else 0;
        }
    }

    /// Shows a G-code file (a finished reader): a bead for each move with
    /// plastic, with the same bead shape as a slice. The beads go to the
    /// GPU once, in print order, so a later position or layer only
    /// changes how many draw. `bed` is the bed size in mm (0: a bed
    /// around the part). The view keeps a pointer to the reader.
    pub fn loadGcode(v: *View, r: *const gcode_read.Reader, bed: [2]f32) Error!void {
        v.clearScene();
        v.gcode = r;
        v.position = null;
        v.time = null;
        v.layer_lo = 0;
        v.xf_center = .{ 0, 0 };
        v.xf_sxy = 1;
        v.xf_sz = 1;
        try v.layer_end.ensureTotalCapacity(gpa, r.layers.items.len);
        var none: [0]vk.Instance = .{};
        const inst: []vk.Instance = if (v.headless) &none else try v.renderer.instanceBuffer(r.bead_count);
        fillGcode(r, inst, v.gcode_features, v.filament_rgb);
        for (0..r.layers.items.len) |l| v.layer_end.appendAssumeCapacity(r.beadsIn(r.layerSegments(l)[1]));

        // The bed, and the camera: around the center of the bed, at half
        // the height of the part.
        const b = r.box;
        const has_box = b[3] >= b[0];
        var bx = bed[0];
        var by = bed[1];
        if (!(bx > 0 and by > 0)) {
            bx = if (has_box) @ceil((b[3] + 10) / 10) * 10 else 220;
            by = if (has_box) @ceil((b[4] + 10) / 10) * 10 else 220;
        }
        try v.loadGrid(bx, by);
        const zmax: f32 = if (has_box) b[5] else 0;
        v.home = .{ bx / 2, by / 2, zmax / 2 };
        v.target = v.home;
        var reach: f32 = 10;
        if (has_box) for ([_]f32{ b[0], b[3] }) |x| for ([_]f32{ b[1], b[4] }) |y| {
            reach = @max(reach, std.math.hypot(x - bx / 2, y - by / 2));
        };
        v.extent = @max(2 * reach, zmax);
        v.home_dist = 1.6;
        v.reset();
        v.layer = if (v.layer_end.items.len > 0) v.layer_end.items.len - 1 else 0;
    }

    /// Clears the beads and the lists of a slice (for a G-code file).
    fn clearScene(v: *View) void {
        inline for (.{ &v.layer_end, &v.path_start, &v.layer_path_end, &v.outline_points, &v.outline_ends, &v.outline_layer_end, &v.pick_runs, &v.layer_boxes, &v.draw_chunks, &v.chunk_width, &v.draws, &v.mark_rings, &v.sup_pts, &v.sup_areas, &v.gap_beads, &v.more, &v.beads, &v.marks, &v.mark_layer_end, &v.bead_end, &v.bead_start, &v.bead_fan, &v.path_part }) |l| l.clearRetainingCapacity();
        v.clearPreview();
        v.highlight = .{ 0, 0 };
        v.seg_bead = null;
        v.focus_mask = 0;
        v.gap_layer = null;
        v.lite.clear();
        v.lite_gen = v.nextGen();
    }

    /// Writes the beads of a G-code file, in print order. It only writes
    /// to `inst` (a GPU buffer can be slow to read).
    fn fillGcode(r: *const gcode_read.Reader, inst: []vk.Instance, features: bool, filament: [3]u8) void {
        var k: usize = 0;
        // The first move starts where it ends (the reader does not know
        // the place of the nozzle before it).
        var prev: [2]f32 = if (r.len > 0) .{ r.at(0).x, r.at(0).y } else .{ 0, 0 };
        for (r.blocks.items, 0..) |blk, bi| {
            const n = @min(gcode_read.block_len, r.len - bi * gcode_read.block_len);
            for (blk[0..n]) |sg| {
                defer prev = .{ sg.x, sg.y };
                if (sg.feature == gcode_read.travel) continue;
                if (k == inst.len) return;
                const f = sg.feature;
                const rgb = if (features) feature_rgb[if (f < n_features) f else 0] else filament;
                inst[k] = .{ .ax = prev[0], .ay = prev[1], .bx = sg.x, .by = sg.y, .z = sg.z, .h = sg.h, .w = sg.w, .rgba = .{ rgb[0], rgb[1], rgb[2], f } };
                k += 1;
            }
        }
    }

    /// The reduced view of a printer screen (see `reduced`).
    pub fn setReduced(v: *View, on: bool) Error!void {
        if (v.reduced == on) return;
        v.reduced = on;
        if (!v.headless) try v.makeMesh();
    }

    /// The colors of a print view: by feature, or one filament color. The
    /// beads are written again in place (no allocation).
    pub fn setGcodeColors(v: *View, features: bool, rgb: [3]u8) Error!void {
        v.gcode_features = features;
        v.filament_rgb = rgb;
        const r = v.gcode orelse return;
        if (v.headless) return;
        fillGcode(r, try v.renderer.instanceBuffer(r.bead_count), features, rgb);
    }

    /// Shows the print as it is at a byte offset of the file: the moves
    /// that the printer has read, and the nozzle at the last one. The
    /// layer of the offset is lit. A G-code file only.
    pub fn setPosition(v: *View, offset: u64) void {
        const r = v.gcode orelse return;
        v.position = offset;
        v.time = null;
        v.layer_lo = 0;
        v.layer = r.layerAt(offset);
    }

    /// The beads that show, and the first bead of the lit layer, for a
    /// G-code file.
    fn gcodeCount(v: *const View) [2]u32 {
        const n = v.layer_end.items.len;
        if (n == 0) return .{ 0, 0 };
        const top = @min(v.layer, n - 1);
        const lo: u32 = if (top == 0) 0 else v.layer_end.items[top - 1];
        if (v.position) |off| {
            const r = v.gcode.?;
            const count = r.beadsIn(r.doneAt(off));
            return .{ @min(lo, count), count };
        }
        return .{ lo, v.layer_end.items[top] };
    }

    /// A touch screen: a finger goes down, moves, or goes up (`id` tells
    /// the fingers apart). One finger orbits; two fingers pinch to zoom
    /// and move together to pan. A cancel ends all touches.
    pub fn touch(v: *View, id: i64, action: TouchAction, x: f32, y: f32) void {
        const slot: ?usize = for (v.touches, 0..) |t, i| {
            if (t.id == id) break i;
        } else null;
        switch (action) {
            .down => {
                if (slot != null) return;
                for (&v.touches) |*t| if (t.id < 0) {
                    t.* = .{ .id = id, .x = x, .y = y };
                    return;
                };
            },
            .move => {
                const i = slot orelse return;
                const other = &v.touches[1 - i];
                const me = &v.touches[i];
                if (other.id < 0) {
                    v.orbit(x - me.x, y - me.y);
                } else {
                    // Two fingers: the middle pans, the spread zooms about
                    // the middle.
                    const m0 = [2]f32{ (me.x + other.x) / 2, (me.y + other.y) / 2 };
                    const d0 = std.math.hypot(me.x - other.x, me.y - other.y);
                    const m1 = [2]f32{ (x + other.x) / 2, (y + other.y) / 2 };
                    const d1 = std.math.hypot(x - other.x, y - other.y);
                    v.pan(m1[0] - m0[0], m1[1] - m0[1]);
                    if (d0 > 1 and d1 > 1) v.zoomAt(d0 / d1, m1[0], m1[1]);
                }
                me.x = x;
                me.y = y;
            },
            .up => if (slot) |i| {
                v.touches[i] = .{};
            },
            .cancel => v.touches = .{ .{}, .{} },
        }
    }

    /// The head of a scene in bytes (see `writeScene`). The arrays follow
    /// it, in the order of `counts`, each at a multiple of 8 bytes.
    const SceneHead = extern struct {
        magic: u32 = scene_magic,
        mode: u32,
        legend: [2]f64,
        xf_center: [2]f32,
        xf_sxy: f32,
        xf_sz: f32,
        home: [3]f32,
        extent: f32,
        bed: [2]f32,
        /// The start of each light level (Lite.level_start).
        lite_start: [plates_mod.n_levels + 1]u32,
        /// layer_end, path_start, beads, marks, mark_layer_end, bead_end,
        /// bead_start, bead_fan, mark_rings, layer_path_end,
        /// outline_points, outline_ends, outline_layer_end, then the
        /// light beads and the layer ends of each light level, then
        /// path_part.
        counts: [18]u32,
    };
    const scene_magic: u32 = 0x34637a73; // "szc4"
    /// The index of the beads and of the light beads in `sceneLists`.
    const scene_beads = 2;
    const scene_layer_end = 0;
    const scene_lite = 13;

    /// The lists of a scene, in the order of SceneHead.counts.
    fn sceneLists(v: *View) struct {
        *std.ArrayList(u32),
        *std.ArrayList(u32),
        *std.ArrayList(vk.Instance),
        *std.ArrayList(vk.Instance),
        *std.ArrayList(u32),
        *std.ArrayList(f32),
        *std.ArrayList(f32),
        *std.ArrayList(u8),
        *std.ArrayList(vk.Instance),
        *std.ArrayList(u32),
        *std.ArrayList(f32),
        *std.ArrayList(u32),
        *std.ArrayList(u32),
        *std.ArrayList(vk.Instance),
        *std.ArrayList(u32),
        *std.ArrayList(u32),
        *std.ArrayList(u32),
        *std.ArrayList(u32),
    } {
        return .{ &v.layer_end, &v.path_start, &v.beads, &v.marks, &v.mark_layer_end, &v.bead_end, &v.bead_start, &v.bead_fan, &v.mark_rings, &v.layer_path_end, &v.outline_points, &v.outline_ends, &v.outline_layer_end, &v.lite.beads, &v.lite.layer_end[0], &v.lite.layer_end[1], &v.lite.layer_end[2], &v.path_part };
    }

    /// The place of each list of a scene in its bytes (see `writeScene`),
    /// and its head. error.InvalidScene if the bytes are too short.
    fn sceneOffsets(bytes: []const u8) error{InvalidScene}!struct { head: SceneHead, at: [18]usize } {
        if (bytes.len < @sizeOf(SceneHead)) return error.InvalidScene;
        var head: SceneHead = undefined;
        @memcpy(std.mem.asBytes(&head), bytes[0..@sizeOf(SceneHead)]);
        if (head.magic != scene_magic) return error.InvalidScene;
        const sizes = comptime blk: {
            const T = @typeInfo(@TypeOf(sceneLists)).@"fn".return_type.?;
            var out: [18]usize = undefined;
            for (@typeInfo(T).@"struct".fields, 0..) |f, k| {
                const List = @typeInfo(f.type).pointer.child;
                out[k] = @sizeOf(@typeInfo(@FieldType(List, "items")).pointer.child);
            }
            break :blk out;
        };
        var out: [18]usize = undefined;
        var at: usize = std.mem.alignForward(usize, @sizeOf(SceneHead), 8);
        for (sizes, 0..) |size, k| {
            out[k] = at;
            const len = head.counts[k] * size;
            if (at + len > bytes.len) return error.InvalidScene;
            at += std.mem.alignForward(usize, len, 8);
        }
        return .{ .head = head, .at = out };
    }

    /// The loaded scene as bytes, for a view in another wasm instance (see
    /// the header comment). The same build writes and reads them, so the
    /// layout is plain memory. The caller frees the bytes with `alloc`.
    pub fn writeScene(v: *View, alloc: std.mem.Allocator) Error![]u8 {
        var head: SceneHead = .{
            .mode = @intCast(@intFromEnum(v.mode)),
            .legend = v.legend,
            .xf_center = v.xf_center,
            .xf_sxy = v.xf_sxy,
            .xf_sz = v.xf_sz,
            .home = v.home,
            .extent = v.extent,
            .bed = v.bed,
            .lite_start = v.lite.level_start,
            .counts = undefined,
        };
        var size: usize = std.mem.alignForward(usize, @sizeOf(SceneHead), 8);
        inline for (v.sceneLists(), 0..) |list, k| {
            head.counts[k] = @intCast(list.items.len);
            size += std.mem.alignForward(usize, std.mem.sliceAsBytes(list.items).len, 8);
        }
        const out = alloc.alloc(u8, size) catch return error.OutOfMemory;
        @memset(out, 0);
        @memcpy(out[0..@sizeOf(SceneHead)], std.mem.asBytes(&head));
        var at: usize = std.mem.alignForward(usize, @sizeOf(SceneHead), 8);
        inline for (v.sceneLists()) |list| {
            const bytes = std.mem.sliceAsBytes(list.items);
            @memcpy(out[at .. at + bytes.len], bytes);
            at += std.mem.alignForward(usize, bytes.len, 8);
        }
        return out;
    }

    /// Reads a scene of `writeScene`: the same as `load` of that slice.
    pub fn readScene(v: *View, bytes: []const u8) (Error || error{InvalidScene})!void {
        if (bytes.len < @sizeOf(SceneHead)) return error.InvalidScene;
        var head: SceneHead = undefined;
        @memcpy(std.mem.asBytes(&head), bytes[0..@sizeOf(SceneHead)]);
        if (head.magic != scene_magic) return error.InvalidScene;
        const first_load = v.layer_end.items.len == 0;
        var at: usize = std.mem.alignForward(usize, @sizeOf(SceneHead), 8);
        inline for (v.sceneLists(), 0..) |list, k| {
            const T = @typeInfo(@TypeOf(list.items)).pointer.child;
            const n = head.counts[k];
            const len = n * @sizeOf(T);
            if (at + len > bytes.len) return error.InvalidScene;
            list.resize(gpa, n) catch return error.OutOfMemory;
            @memcpy(std.mem.sliceAsBytes(list.items), bytes[at .. at + len]);
            at += std.mem.alignForward(usize, len, 8);
        }
        v.mode = std.enums.fromInt(Mode, head.mode) orelse .print;
        v.legend = head.legend;
        v.xf_center = head.xf_center;
        v.xf_sxy = head.xf_sxy;
        v.xf_sz = head.xf_sz;
        v.home = head.home;
        v.extent = head.extent;
        v.lite.level_start = head.lite_start;
        v.lite_gen = v.nextGen();
        try v.loadGrid(head.bed[0], head.bed[1]);
        try v.renderer.setInstances(v.beads.items, v.marks.items);
        v.more.clearRetainingCapacity();
        v.clearPreview();
        try v.buildPickIndex();
        if (v.layer_end.items.len == 0) return;
        if (first_load) {
            v.reset();
            v.layer = v.layer_end.items.len - 1;
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
            while (k + 1 < end) : (k += 1) len += @import("../geom.zig").hypot(pts[2 * k + 2] - pts[2 * k], pts[2 * k + 3] - pts[2 * k + 1]);
            if (tp.path_closed.items[pi] != 0 and end - start > 2) len += @import("../geom.zig").hypot(pts[2 * start] - pts[2 * (end - 1)], pts[2 * start + 1] - pts[2 * (end - 1) + 1]);
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

    /// The outline of each of the `layers` levels of the slice of `app`
    /// (see `outline_points`), in the cooled shape of the beads.
    fn loadOutlines(v: *View, app: *const app_mod.App, layers: usize) Error!void {
        const geom = @import("../geom.zig");
        v.outline_points.clearRetainingCapacity();
        v.outline_ends.clearRetainingCapacity();
        v.outline_layer_end.clearRetainingCapacity();
        const job = if (app.job) |*j| j else null;
        const c = v.xf_center;
        const k = v.xf_sxy;
        for (0..layers) |l| {
            var part: usize = 0;
            while (job != null) : (part += 1) {
                const o = job.?.levelOutline(l, part) orelse break;
                for (0..o.paths.count()) |ri| {
                    const ring = o.paths.get(ri);
                    if (ring.len < 3) continue;
                    v.outline_points.ensureUnusedCapacity(gpa, 2 * ring.len) catch return error.OutOfMemory;
                    for (ring) |q| {
                        const x: f32 = @floatCast(geom.toMm(q.x + o.dx));
                        const y: f32 = @floatCast(geom.toMm(q.y + o.dy));
                        v.outline_points.appendAssumeCapacity(c[0] + (x - c[0]) * k);
                        v.outline_points.appendAssumeCapacity(c[1] + (y - c[1]) * k);
                    }
                    v.outline_ends.append(gpa, @intCast(v.outline_points.items.len / 2)) catch return error.OutOfMemory;
                }
            }
            v.outline_layer_end.append(gpa, @intCast(v.outline_ends.items.len)) catch return error.OutOfMemory;
        }
    }

    /// The seam blobs, the travel moves, and the retractions of each
    /// layer, from the same toolpaths and in the same cooled shape as the
    /// beads.
    fn loadMarks(v: *View, tp: *const app_mod.Toolpaths, filament: [3]u8, center: [2]f32, sxy: f32, sz: f32) Error!void {
        v.marks.clearRetainingCapacity();
        v.mark_layer_end.clearRetainingCapacity();
        const pts = tp.points.items;
        const flow = @import("../flow.zig");
        const seam_rgb = if (v.mode == .print) filament else feature_rgb[code_seam];
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
                    try v.addMark(.{ .ax = first[0], .ay = first[1], .bx = first[0], .by = first[1], .z = z + 0.15 * h, .h = h * 1.25, .w = w * 1.15, .rgba = .{ seam_rgb[0], seam_rgb[1], seam_rgb[2], code_seam } });
                }
                if (prev) |p| {
                    const retracted = tp.path_retract.items.len > pi and tp.path_retract.items[pi] != 0;
                    const lift: f32 = if (retracted) tp.z_hop else 0;
                    if (@import("../geom.zig").hypot(first[0] - p[0], first[1] - p[1]) > 0.05) {
                        const t = feature_rgb[code_travel];
                        try v.addMark(.{ .ax = p[0], .ay = p[1], .bx = first[0], .by = first[1], .z = z + lift + 0.08, .h = 0.06, .w = 0.06, .rgba = .{ t[0], t[1], t[2], code_travel } });
                    }
                    if (retracted) {
                        const r = feature_rgb[code_retract];
                        try v.addMark(.{ .ax = p[0], .ay = p[1], .bx = p[0], .by = p[1], .z = z + 0.35, .h = 0.3, .w = 0.3, .rgba = .{ r[0], r[1], r[2], code_retract } });
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
    /// Adds rings of the outline of each modifier volume of `job` to
    /// `mark_rings`: on its first and last layer, and on about 6 layers
    /// between. The rings stay within a budget of overlay beads.
    /// (dx, dy): the move of the part from the part of the job (see
    /// plate_job.Instance), in the units of geom.
    fn addVolumeRings(v: *View, job: *const @import("../engine.zig").Job, dx: i64, dy: i64) Error!void {
        const geom = @import("../geom.zig");
        const budget: usize = vk.max_extras / 2;
        const color: [4]u8 = .{ 0x9c, 0x36, 0xb5, 13 };
        for (job.modifiers) |m| {
            var lo: ?usize = null;
            var hi: usize = 0;
            for (m.outlines, 0..) |o, i| if (!o.isEmpty()) {
                if (lo == null) lo = i;
                hi = i;
            };
            const first = lo orelse continue;
            const step = @max(1, (hi - first) / 6);
            var i = first;
            while (true) : (i = @min(hi, i + step)) {
                const o = m.outlines[i];
                const z: f32 = @floatCast(job.layers[i].z);
                for (0..o.count()) |k| {
                    const poly = o.get(k);
                    // Joins short edges, so a curve costs fewer beads.
                    var a = poly[poly.len - 1];
                    for (poly) |b| {
                        if (a.distSq(b) < 1000 * 1000 and !std.meta.eql(b, poly[poly.len - 1])) continue;
                        if (v.mark_rings.items.len >= budget) return;
                        v.mark_rings.append(gpa, .{
                            .ax = @floatCast(geom.toMm(a.x + dx)),
                            .ay = @floatCast(geom.toMm(a.y + dy)),
                            .bx = @floatCast(geom.toMm(b.x + dx)),
                            .by = @floatCast(geom.toMm(b.y + dy)),
                            .z = z,
                            .h = 0.12,
                            .w = 0.3,
                            .rgba = color,
                        }) catch return error.OutOfMemory;
                        a = b;
                    }
                }
                if (i == hi) break;
            }
        }
    }

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
        v.bed = .{ bed_x, bed_y };
        var pts: std.ArrayList(f32) = .empty;
        defer pts.deinit(gpa);
        try appendGrid(&pts, .{ 0, 0 }, v.bed);
        if (!v.headless) try v.renderer.setGrid(pts.items);
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
    /// A focus on features with no beads on the plate (for example the
    /// ironing, when it is off) would show no line at all: the view then
    /// shows the whole print, and returns false.
    pub fn setFocus(v: *View, mask: u32, zmax: f32) bool {
        var m = mask & 0xffff;
        const shows = m == 0 or (m & v.presentFeatures()) != 0;
        if (!shows) m = 0;
        v.focus_mask = m;
        v.focus_zmax = zmax;
        return shows;
    }

    /// The features that have beads, a bit for each. Kept until the beads
    /// change.
    fn presentFeatures(v: *View) u32 {
        const key = [2]usize{ @intFromPtr(v.beads.items.ptr), v.beads.items.len };
        if (key[0] == v.present_key[0] and key[1] == v.present_key[1]) return v.present;
        var m: u32 = 0;
        for (v.beads.items) |b| {
            if (b.rgba[3] < 32) m |= @as(u32, 1) << @intCast(b.rgba[3]);
            // All 16 feature bits found: no need to look on.
            if (m & 0xffff == 0xffff) break;
        }
        v.present = m;
        v.present_key = key;
        return m;
    }

    /// Shows the layers 0 to `layer`, and stops the replay. In a print
    /// view it ends the position (the scrubber).
    pub fn setLayer(v: *View, layer: usize) void {
        v.layer = layer;
        v.time = null;
        v.position = null;
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

    /// Looks at the point `p` from the side that `n` (a unit normal) faces,
    /// from `dist` mm: the camera moves there in steps (`animate`). For a
    /// double click on a side of a part. The bed stays level: the tilt
    /// stops at `max_pitch`.
    pub fn lookAtSmooth(v: *View, p: [3]f32, n: [3]f32, dist: f32) void {
        const now = v.pose();
        v.target = p;
        const yaw = if (@abs(n[0]) + @abs(n[1]) < 1e-4) std.math.atan2(qrotate(now.rot, .{ 0, 0, 1 })[1], qrotate(now.rot, .{ 0, 0, 1 })[0]) else std.math.atan2(n[1], n[0]);
        const pitch = std.math.asin(std.math.clamp(n[2], -1, 1));
        v.setAngles(yaw, std.math.clamp(pitch, -max_pitch, max_pitch));
        v.dist = @max(v.extent * 0.05 + 1, dist);
        v.goal = v.pose();
        v.setPose(now);
    }

    /// A double click on a side of the print: the camera looks at that side
    /// from the front of it (lookAtSmooth), from 1.4 times `size` mm (at
    /// least 20 mm; 0: the size of the print). The normal of the side comes
    /// from two more points of the surface, 4 pixels to the right and 4
    /// pixels down, and faces the camera. False if the pixel shows no side
    /// of the print (the bed, or the space around).
    pub fn lookAtSide(v: *View, px: f32, py: f32, size: f32) bool {
        const p = v.surfacePoint(px, py, false) orelse return false;
        if (p[2] <= 0.05) return false;
        const a = v.surfacePoint(px + 4, py, false) orelse return false;
        const b = v.surfacePoint(px, py + 4, false) orelse return false;
        const u = [3]f32{ a[0] - p[0], a[1] - p[1], a[2] - p[2] };
        const w = [3]f32{ b[0] - p[0], b[1] - p[1], b[2] - p[2] };
        var n = [3]f32{ u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0] };
        const l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (!(l > 1e-9)) return false;
        n = .{ n[0] / l, n[1] / l, n[2] / l };
        // Toward the camera.
        const cam = v.camera();
        if (dot(n, cam.f) > 0) n = .{ -n[0], -n[1], -n[2] };
        const s = if (size > 0) size else v.extent;
        v.lookAtSmooth(.{ p[0], p[1], p[2] }, n, @max(20, 1.4 * s));
        return true;
    }

    /// The plane of a cut: the box x0, y0, x1, y1 at height z (mm), drawn
    /// as a frame with lines across it. A box with no area: no plane.
    pub fn setCut(v: *View, box: [4]f32, z: f32) void {
        v.cut_plane = if (box[2] > box[0] and box[3] > box[1]) .{ box[0], box[1], box[2], box[3], z } else null;
    }

    /// No support areas to draw.
    pub fn clearSupportAreas(v: *View) void {
        v.sup_pts.clearRetainingCapacity();
        v.sup_areas.clearRetainingCapacity();
    }

    /// One more support area to draw: its points (x, y, z in mm), its kind
    /// (as support.Mark.Kind), and its flags (see SupportArea).
    pub fn addSupportArea(v: *View, pts: []const [3]f32, kind: u8, flags: u8) Error!void {
        if (pts.len == 0) return;
        const first: u32 = @intCast(v.sup_pts.items.len);
        v.sup_pts.appendSlice(gpa, pts) catch return error.OutOfMemory;
        v.sup_areas.append(gpa, .{ .first = first, .n = @intCast(pts.len), .kind = kind, .flags = flags }) catch return error.OutOfMemory;
    }

    /// The beads of the support areas, into `out` from `n.*`: the outline
    /// of each area, a dot at its points, and lines across a closed area
    /// (the fill hint). A slope of a line is a stair of level beads.
    fn supportAreaBeads(v: *const View, out: []vk.Instance, n: *usize) void {
        const span = std.math.clamp(v.dist * 0.003, 0.12, 2);
        const eye = v.camera().eye;
        for (v.sup_areas.items) |a| {
            // The area moves a little toward the camera, out of the part:
            // down for an area on a surface that faces down, seen from
            // below.
            var buf: [256][3]f32 = undefined;
            const src = v.sup_pts.items[a.first..][0..@min(a.n, buf.len)];
            var zm: f32 = 0;
            for (src) |p| zm += p[2] / @as(f32, @floatFromInt(src.len));
            const lift: f32 = if (eye[2] < zm) -span else span;
            for (src, buf[0..src.len]) |p, *q| q.* = .{ p[0], p[1], p[2] + lift };
            const pts = buf[0..src.len];
            const block = a.kind == 3;
            const sel = a.flags & SupportArea.selected != 0;
            const closed = a.flags & SupportArea.closed != 0;
            const line: [4]u8 = if (block) .{ 0xe0, 0x31, 0x31, code_overlay } else .{ 0x1c, 0x7e, 0xd6, code_overlay };
            const fill: [4]u8 = if (block) .{ 0xf0, 0x9a, 0x9a, code_overlay } else .{ 0x8c, 0xbf, 0xf0, code_overlay };
            const w = if (sel) span * 2.2 else span * 1.4;
            // The fill hint first, so the outline stays on top where they
            // meet.
            // The lines across are thin, and as tall as the outline, so
            // that they reach out of the part on both sides of the surface.
            if (closed and pts.len >= 3) hatch(out, n, pts, span * 0.7, w, fill, if (sel) 12 else 8);
            const edges = if (closed) pts.len else pts.len - 1;
            for (0..edges) |k| stair(out, n, pts[k], pts[(k + 1) % pts.len], w, w, line);
            if (a.flags & SupportArea.points != 0 or sel or !closed) {
                for (pts, 0..) |p, k| {
                    if (n.* >= out.len) return;
                    // The first point of an open path is larger: a click on
                    // it closes the path.
                    const big: f32 = if (!closed and k == 0 and pts.len >= 3) 6 else 4;
                    const s = span * big;
                    out[n.*] = .{ .ax = p[0], .ay = p[1], .bx = p[0] + 0.001, .by = p[1], .z = p[2] + s / 2, .h = s, .w = s, .rgba = .{ 0xff, 0xff, 0xff, code_overlay } };
                    n.* += 1;
                    if (n.* >= out.len) return;
                    const c = s * 0.6;
                    out[n.*] = .{ .ax = p[0], .ay = p[1], .bx = p[0] + 0.001, .by = p[1], .z = p[2] + s / 2 + 0.01, .h = s + 0.02, .w = c, .rgba = line };
                    n.* += 1;
                }
            }
        }
    }

    /// A line from a to b as level beads of width w and height at least
    /// h: one bead if it is level, else a stair of up to 16 steps.
    fn stair(out: []vk.Instance, n: *usize, a: [3]f32, b: [3]f32, w: f32, h_min: f32, rgba: [4]u8) void {
        const dz = @abs(b[2] - a[2]);
        const steps: usize = if (dz < w * 0.5) 1 else @min(16, @as(usize, @intFromFloat(@ceil(dz / w))));
        for (0..steps) |k| {
            if (n.* >= out.len) return;
            const f0 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
            const f1 = @as(f32, @floatFromInt(k + 1)) / @as(f32, @floatFromInt(steps));
            const x0 = a[0] + (b[0] - a[0]) * f0;
            const y0 = a[1] + (b[1] - a[1]) * f0;
            const x1 = a[0] + (b[0] - a[0]) * f1;
            const y1 = a[1] + (b[1] - a[1]) * f1;
            const z = a[2] + (b[2] - a[2]) * (f0 + f1) / 2;
            const h = @max(h_min, dz / @as(f32, @floatFromInt(steps)));
            out[n.*] = .{ .ax = x0, .ay = y0, .bx = if (x0 == x1 and y0 == y1) x1 + 0.001 else x1, .by = y1, .z = z + h / 2, .h = h, .w = w, .rgba = rgba };
            n.* += 1;
        }
    }

    /// Lines across a polygon along X (the fill hint): `count` lines over
    /// its box in Y. The z of a line end comes from the edge that it meets.
    fn hatch(out: []vk.Instance, n: *usize, pts: []const [3]f32, w: f32, h: f32, rgba: [4]u8, count: usize) void {
        var y0: f32 = std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        for (pts) |p| {
            y0 = @min(y0, p[1]);
            y1 = @max(y1, p[1]);
        }
        if (!(y1 > y0)) return;
        for (1..count + 1) |k| {
            const y = y0 + (y1 - y0) * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(count + 1));
            // The points where the line meets the edges, by x.
            var hits: [64][2]f32 = undefined;
            var m: usize = 0;
            for (pts, 0..) |a, i| {
                const b = pts[(i + 1) % pts.len];
                if ((a[1] <= y) == (b[1] <= y)) continue;
                const t = (y - a[1]) / (b[1] - a[1]);
                if (m == hits.len) break;
                hits[m] = .{ a[0] + (b[0] - a[0]) * t, a[2] + (b[2] - a[2]) * t };
                m += 1;
            }
            std.mem.sort([2]f32, hits[0..m], {}, struct {
                fn lt(_: void, p: [2]f32, q: [2]f32) bool {
                    return p[0] < q[0];
                }
            }.lt);
            var j: usize = 0;
            while (j + 1 < m) : (j += 2) stair(out, n, .{ hits[j][0], y, hits[j][1] }, .{ hits[j + 1][0], y, hits[j + 1][1] }, w, h, rgba);
        }
    }

    /// The rings of the Turn tool: a ring for each axis around the point
    /// c, with radius r mm (0: none). The view draws them (red X, green Y,
    /// blue Z), and finds them under a pixel (`ringAt`).
    pub fn setRings(v: *View, c: [3]f32, r: f32) void {
        v.rings = if (r > 0) .{ .c = c, .r = r } else null;
        if (v.rings == null) v.ring_axis = -1;
    }

    pub const ring_samples = 48;

    /// The points of the ring of `axis`, mm.
    pub fn ringPoints(v: *const View, axis: usize) [ring_samples + 1][3]f32 {
        var out: [ring_samples + 1][3]f32 = undefined;
        const rg = v.rings orelse return out;
        for (&out, 0..) |*q, i| {
            const t = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / ring_samples;
            const a = rg.r * @cos(t);
            const b = rg.r * @sin(t);
            q.* = switch (axis) {
                0 => .{ rg.c[0], rg.c[1] + a, rg.c[2] + b },
                1 => .{ rg.c[0] + a, rg.c[1], rg.c[2] + b },
                else => .{ rg.c[0] + a, rg.c[1] + b, rg.c[2] },
            };
        }
        return out;
    }

    /// The ring under the pixel (px, py), within tol pixels: 0, 1, or 2;
    /// -1 for none. The nearest ring wins.
    pub fn ringAt(v: *const View, px: f32, py: f32, tol: f32) i32 {
        if (v.rings == null) return -1;
        var best: i32 = -1;
        var best_d = tol;
        for (0..3) |axis| {
            const pts = v.ringPoints(axis);
            var prev: ?[2]f32 = null;
            for (pts) |q| {
                const cur = v.pixelOf(q);
                if (prev != null and cur != null) {
                    const d = segDist(px, py, prev.?, cur.?);
                    if (d < best_d) {
                        best_d = d;
                        best = @intCast(axis);
                    }
                }
                prev = cur;
            }
        }
        return best;
    }

    /// Starts a turn on the ring of `axis` at the pixel (px, py). False if
    /// there are no rings, or the center is behind the camera.
    pub fn ringPress(v: *View, axis: u2, px: f32, py: f32) bool {
        const rg = v.rings orelse return false;
        const c = v.pixelOf(rg.c) orelse return false;
        // The sense of the ring on the screen: +1 if the angle about the
        // center grows with the angle of the ring (y down).
        const pts = v.ringPoints(axis);
        var sum: f32 = 0;
        var prev: ?f32 = null;
        for (pts) |q| {
            const p = v.pixelOf(q) orelse continue;
            const a = std.math.atan2(p[1] - c[1], p[0] - c[0]);
            if (prev) |a0| {
                var d = a - a0;
                if (d > std.math.pi) d -= 2 * std.math.pi;
                if (d < -std.math.pi) d += 2 * std.math.pi;
                sum += d;
            }
            prev = a;
        }
        v.ring_axis = axis;
        v.ring_press = .{ .cx = c[0], .cy = c[1], .a0 = std.math.atan2(py - c[1], px - c[0]), .sense = if (sum >= 0) 1 else -1 };
        return true;
    }

    /// The turn since the press, in degrees, in steps of `step` degrees
    /// (0: no steps), with the sense of the ring: the part turns with the
    /// pointer. Between -180 and 180.
    pub fn ringDrag(v: *const View, px: f32, py: f32, step: f32) f32 {
        if (v.ring_axis < 0) return 0;
        const rp = v.ring_press;
        var d = (std.math.atan2(py - rp.cy, px - rp.cx) - rp.a0) * 180 / std.math.pi;
        while (d > 180) d -= 360;
        while (d < -180) d += 360;
        d *= rp.sense;
        return if (step > 0) @round(d / step) * step else d;
    }

    /// The end of a turn.
    pub fn ringRelease(v: *View) void {
        v.ring_axis = -1;
    }

    /// The angle of a drag: radians for each pixel.
    const drag_angle = 0.008;

    /// The highest tilt of an orbit, above or below the bed (89 degrees).
    const max_pitch = 1.553;

    /// Turns the camera by a drag of dx, dy pixels, as in Cura, Tinkercad,
    /// and Fusion: a sideways drag turns around the vertical axis of the
    /// world, and an up or down drag tilts. The bed stays level (no roll),
    /// and the tilt stops at 89 degrees over the top and under the bed, so
    /// the view never goes upside down.
    pub fn orbit(v: *View, dx: f32, dy: f32) void {
        const before = v.pose();
        defer v.carryGoal(before);
        const b = qrotate(v.rot, .{ 0, 0, 1 });
        const yaw = std.math.atan2(b[1], b[0]) - dx * drag_angle;
        const pitch = std.math.asin(std.math.clamp(b[2], -1, 1)) + dy * drag_angle;
        v.setAngles(yaw, std.math.clamp(pitch, -max_pitch, max_pitch));
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
        // The reduced view (a printer screen) frames the part.
        if (v.reduced and v.framePart(0.8)) return;
        v.goal = null;
        v.target = v.home;
        v.setAngles(-1.9, 0.6);
        v.dist = v.extent * v.home_dist;
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
    /// The pixel of a point of the world, or null behind the camera. The
    /// inverse of `pixelRay`.
    pub fn pixelOf(v: *const View, p: [3]f32) ?[2]f32 {
        const cam = v.camera();
        const d = [3]f32{ p[0] - cam.eye[0], p[1] - cam.eye[1], p[2] - cam.eye[2] };
        const depth = dot(d, cam.f);
        if (depth <= 1e-6) return null;
        const aspect = @as(f32, @floatFromInt(v.width)) / @as(f32, @floatFromInt(v.height));
        const tan_half = @tan(@as(f32, fov) / 2);
        const x = dot(d, cam.s) / depth / (tan_half * aspect);
        const y = dot(d, cam.u) / depth / tan_half;
        return .{ (x + 1) / 2 * @as(f32, @floatFromInt(v.width)), (1 - y) / 2 * @as(f32, @floatFromInt(v.height)) };
    }

    /// The point of the print under a pixel, for the measure tape: on the
    /// first bead that the ray hits (its surface), else on the bed. With
    /// `snap`, an end of the bead within 12 pixels takes its place (the
    /// corner of a line, at the top of the bead). Null: the ray meets
    /// neither.
    pub fn surfacePoint(v: *const View, px: f32, py: f32, snap: bool) ?[3]f32 {
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        if (v.rayHit(px, py, 1)) |h| {
            var p = [3]f32{ cam.eye[0] + dir[0] * h.t, cam.eye[1] + dir[1] * h.t, cam.eye[2] + dir[2] * h.t };
            if (snap and h.bead < v.beads.items.len) {
                const b = v.beads.items[h.bead];
                var best: f32 = 12;
                for ([_][3]f32{ .{ b.ax, b.ay, b.z }, .{ b.bx, b.by, b.z } }) |e| {
                    const q = v.pixelOf(e) orelse continue;
                    const dpx = @import("../geom.zig").hypot(q[0] - px, q[1] - py);
                    if (dpx < best) {
                        best = dpx;
                        p = e;
                    }
                }
            }
            return p;
        }
        const b = v.bedPoint(px, py) orelse return null;
        return .{ @floatCast(b[0]), @floatCast(b[1]), 0 };
    }

    /// The points of the measure tape: none, the first point, or both. The
    /// view draws a mark at each point and a line between the two.
    pub fn setMeasure(v: *View, pts: []const [3]f32) void {
        v.measure_n = @intCast(@min(pts.len, 2));
        for (pts[0..v.measure_n], 0..) |p, i| v.measure[i] = p;
    }

    pub fn bedPoint(v: *const View, px: f32, py: f32) ?[2]f64 {
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        if (@abs(dir[2]) < 1e-6) return null;
        const t = -cam.eye[2] / dir[2];
        if (t <= 0) return null;
        return .{ cam.eye[0] + dir[0] * t, cam.eye[1] + dir[1] * t };
    }

    /// Shows the gaps of layer `layer` of the last slice of `app` (see
    /// App.layerGaps), or none for null: a thin red bead over each run of
    /// gap cells, on top of the layer.
    pub fn setGaps(v: *View, app: *app_mod.App, layer: ?usize) void {
        v.gap_beads.clearRetainingCapacity();
        v.gap_layer = null;
        const l = layer orelse return;
        const r = app.layerGaps(l) catch return;
        const tp = app.allToolpaths() orelse return;
        if (l >= tp.layer_z.items.len) return;
        v.setGapRuns(l, tp.layer_z.items[l], r.runs, r.cell);
    }

    /// The gaps of layer `layer` (its top at z mm) from their runs (see
    /// gaps.zig), with no app: a view that reads its scene from bytes (the
    /// web page) gets the runs from the app in the worker.
    pub fn setGapRuns(v: *View, layer: usize, layer_z: f32, runs: []const @import("../gaps.zig").Run, cell: f64) void {
        v.gap_beads.clearRetainingCapacity();
        v.gap_layer = layer;
        const z = layer_z * v.xf_sz;
        const c = v.xf_center;
        const w: f32 = @floatCast(cell * 1.4);
        for (runs) |run| {
            // A bead has round ends: the run is shorter by half a width at
            // each end, where it is long enough.
            var x0 = run.x0;
            var x1 = run.x1;
            if (x1 - x0 > w) {
                x0 += w / 2;
                x1 -= w / 2;
            } else {
                x0 = (x0 + x1) / 2;
                x1 = x0;
            }
            v.gap_beads.append(gpa, .{
                .ax = c[0] + (x0 - c[0]) * v.xf_sxy,
                .ay = c[1] + (run.y - c[1]) * v.xf_sxy,
                .bx = c[0] + (x1 - c[0]) * v.xf_sxy,
                .by = c[1] + (run.y - c[1]) * v.xf_sxy,
                .z = z + 0.04,
                .h = 0.06,
                .w = w * v.xf_sxy,
                .rgba = .{ 0xe8, 0x1c, 0x24, code_overlay },
            }) catch return;
        }
    }

    /// The point (mm, in the frame of the slice) under the pixel on the top
    /// of layer `layer_z` mm, or null: for a pick of a gap in the app.
    pub fn layerPoint(v: *const View, px: f32, py: f32, layer_z: f32) ?[2]f64 {
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        if (@abs(dir[2]) < 1e-6) return null;
        const zt = layer_z * v.xf_sz;
        const t = (zt - cam.eye[2]) / dir[2];
        if (t <= 0) return null;
        const c = v.xf_center;
        return .{ c[0] + (cam.eye[0] + dir[0] * t - c[0]) / v.xf_sxy, c[1] + (cam.eye[1] + dir[1] * t - c[1]) / v.xf_sxy };
    }

    /// The gap of the shown layer (see `setGaps`) under the pixel (px, py),
    /// or null: the ray meets the top of the layer within 0.3 mm of a gap.
    pub fn gapAt(v: *const View, app: *app_mod.App, px: f32, py: f32) ?usize {
        const l = v.gap_layer orelse return null;
        const r = app.layerGaps(l) catch return null;
        const tp = app.allToolpaths() orelse return null;
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        if (@abs(dir[2]) < 1e-6) return null;
        const zt = tp.layer_z.items[l] * v.xf_sz;
        const t = (zt - cam.eye[2]) / dir[2];
        if (t <= 0) return null;
        const c = v.xf_center;
        const x = c[0] + (cam.eye[0] + dir[0] * t - c[0]) / v.xf_sxy;
        const y = c[1] + (cam.eye[1] + dir[1] * t - c[1]) / v.xf_sxy;
        return r.at(x, y, 0.3);
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
        const n = v.layer_end.items.len;
        // A print view keeps no copy of its beads (they are only on the
        // GPU): no hit.
        if (n == 0 or v.beads.items.len < v.layer_end.items[n - 1]) return null;
        const top = @min(v.layer, n - 1);
        const bottom = @min(v.layer_lo, top);
        var best: ?usize = null;
        var best_t: f32 = std.math.inf(f32);
        // With no pick index (a test that fills the beads by hand), each
        // bead of the layers.
        if (v.layer_boxes.items.len != n or grow > pick_grow) {
            const start: usize = if (bottom == 0) 0 else v.layer_end.items[bottom - 1];
            v.rayBeads(cam.eye, dir, grow, start, v.layer_end.items[top], &best, &best_t);
        } else {
            // The layers from the top down, so a near hit comes early and
            // the boxes behind it drop out.
            var l = top + 1;
            while (l > bottom) {
                l -= 1;
                if (!rayBox(cam.eye, dir, v.layer_boxes.items[l], best_t)) continue;
                const r0: usize = if (l == 0) 0 else v.layer_boxes.items[l - 1].end;
                for (v.pick_runs.items[r0..v.layer_boxes.items[l].end]) |run| {
                    if (!rayBox(cam.eye, dir, run, best_t)) continue;
                    v.rayBeads(cam.eye, dir, grow, run.first, run.end, &best, &best_t);
                }
            }
        }
        const i = best orelse return null;
        return .{ .bead = i, .t = best_t };
    }

    /// The ray test of the beads first to end (see `pick`): the nearest
    /// hit nearer than `best_t` goes to `best`.
    fn rayBeads(v: *const View, eye: [3]f32, dir: [3]f32, grow: f32, first: usize, end: usize, best: *?usize, best_t: *f32) void {
        const sup: u8 = @intFromEnum(@import("../settings.zig").Feature.support);
        const sup_if: u8 = @intFromEnum(@import("../settings.zig").Feature.support_interface);
        for (v.beads.items[first..end], first..) |b, i| {
            if (v.pick_skip_support and (b.rgba[3] == sup or b.rgba[3] == sup_if)) continue;
            const zc = b.z - b.h / 2;
            const k = if (b.h > 0) b.w / b.h else 1;
            const o = [3]f32{ eye[0], eye[1], zc + (eye[2] - zc) * k };
            const d = [3]f32{ dir[0], dir[1], dir[2] * k };
            const a = [3]f32{ b.ax, b.ay, zc };
            const e = [3]f32{ b.bx - b.ax, b.by - b.ay, 0 };
            const hit = rayToSegment(o, d, a, e) orelse continue;
            const r = b.w / 2 * grow;
            if (hit.dist2 <= r * r and hit.t < best_t.*) {
                best_t.* = hit.t;
                best.* = i;
            }
        }
    }

    /// The beads in one box of the pick index: first to end, and a box
    /// around them (mm) with room for a bead radius grown by `pick_grow`.
    /// For a layer box, `end` is the end of its runs in `pick_runs`.
    pub const PickBox = struct { lo: [3]f32, hi: [3]f32, first: u32, end: u32 };

    /// The largest `grow` of `rayHit` that the pick index covers.
    const pick_grow: f32 = 1.6;
    /// The beads in one run of the pick index. Beads in print order are
    /// near each other, so the box of a run is small.
    const pick_run = 32;

    /// Makes the pick index: a box for each run of `pick_run` beads (a
    /// run stays in one layer), and a box for each layer. A pick tests a
    /// bead only if the ray goes through the box of its layer and of its
    /// run, so a pick on a plate of many parts stays fast.
    fn buildPickIndex(v: *View) Error!void {
        v.pick_runs.clearRetainingCapacity();
        v.layer_boxes.clearRetainingCapacity();
        v.pick_runs.ensureTotalCapacity(gpa, v.beads.items.len / pick_run + v.layer_end.items.len) catch return error.OutOfMemory;
        v.layer_boxes.ensureTotalCapacity(gpa, v.layer_end.items.len) catch return error.OutOfMemory;
        var first: u32 = 0;
        for (v.layer_end.items) |end| {
            var layer = emptyBox(first, 0);
            var i = first;
            while (i < end) {
                const j = @min(i + pick_run, end);
                var run = emptyBox(i, j);
                for (v.beads.items[i..j]) |b| {
                    const r = b.w / 2 * pick_grow;
                    const zr = b.h / 2 * pick_grow;
                    const zc = b.z - b.h / 2;
                    growBox(&run, .{ @min(b.ax, b.bx) - r, @min(b.ay, b.by) - r, zc - zr }, .{ @max(b.ax, b.bx) + r, @max(b.ay, b.by) + r, zc + zr });
                }
                growBox(&layer, run.lo, run.hi);
                v.pick_runs.appendAssumeCapacity(run);
                i = j;
            }
            layer.end = @intCast(v.pick_runs.items.len);
            v.layer_boxes.appendAssumeCapacity(layer);
            first = end;
        }
        // The chunks of the draw list: whole runs, about draw_chunk beads.
        v.draw_chunks.clearRetainingCapacity();
        v.chunk_width.clearRetainingCapacity();
        var chunk = emptyBox(0, 0);
        var width: f32 = 0;
        for (v.pick_runs.items, 0..) |run, k| {
            if (chunk.end == 0) chunk = emptyBox(run.first, run.end);
            growBox(&chunk, run.lo, run.hi);
            chunk.end = run.end;
            for (v.beads.items[run.first..run.end]) |b| width = @max(width, b.w);
            if (chunk.end - chunk.first >= draw_chunk or k + 1 == v.pick_runs.items.len) {
                v.draw_chunks.append(gpa, chunk) catch return error.OutOfMemory;
                v.chunk_width.append(gpa, width) catch return error.OutOfMemory;
                chunk = emptyBox(0, 0);
                width = 0;
            }
        }
    }

    /// The beads in a chunk of the draw list. A draw call for each chunk
    /// is cheap, and a chunk out of the view costs nothing.
    const draw_chunk = 96;
    /// A bead narrower than this on the screen (pixels) draws with the
    /// coarser mesh (level 1).
    const lod_pixels: f32 = 20;
    /// A bead narrower than this draws as a ribbon (level 2), if the
    /// backend has it.
    const ribbon_pixels: f32 = 7;

    /// The mesh level of a bead `px` pixels wide.
    fn lodFor(v: *const View, px: f32) u32 {
        if (px >= lod_pixels * v.detail) return 0;
        if (px >= ribbon_pixels * v.detail or !v.useRibbons()) return 1;
        return 2;
    }

    fn useRibbons(v: *const View) bool {
        return v.ribbons or (v.ribbon_ok and v.detail >= 2);
    }

    /// The mesh level of the light beads: they are less than a few
    /// pixels wide.
    fn liteLod(v: *const View) u32 {
        return if (v.useRibbons()) 2 else 1;
    }

    /// The draw list of the beads first .. end (see Frame.draws): the
    /// chunks in the view, each with the full mesh near the camera and a
    /// coarser mesh where a bead is a few pixels wide. A plate of many
    /// parts has a million beads of 100 triangles; most of them are far or
    /// out of the view.
    fn drawList(v: *View, mvp: [16]f32, eye: [3]f32, first: u32, end: u32) Error![]const Draw {
        v.draws.clearRetainingCapacity();
        if (end <= first) return v.draws.items;
        // A G-code file has no chunks: one draw of its beads.
        if (v.draw_chunks.items.len == 0) {
            v.draws.append(gpa, .{ .first = first, .count = end - first, .lod = 0 }) catch return error.OutOfMemory;
            return v.draws.items;
        }
        // The pixels per mm at distance 1 from the eye.
        const px_per_mm = @as(f32, @floatFromInt(v.height)) / (2 * @tan(@as(f32, fov) / 2));
        for (v.draw_chunks.items, v.chunk_width.items) |c, w| {
            const a = @max(c.first, first);
            const b = @min(c.end, end);
            if (b <= a) continue;
            if (!boxInView(mvp, c)) continue;
            // The distance from the eye to the box (0 inside it).
            var d2: f32 = 0;
            for (0..3) |k| {
                const e = @max(@max(c.lo[k] - eye[k], eye[k] - c.hi[k]), 0);
                d2 += e * e;
            }
            const lod = v.lodFor(w * px_per_mm / @max(@sqrt(d2), 1e-3));
            if (v.draws.items.len > 0) {
                const last = &v.draws.items[v.draws.items.len - 1];
                if (last.lod == lod and last.first + last.count == a) {
                    last.count += b - a;
                    continue;
                }
            }
            v.draws.append(gpa, .{ .first = a, .count = b - a, .lod = lod }) catch return error.OutOfMemory;
        }
        return v.draws.items;
    }

    fn emptyBox(first: u32, end: u32) PickBox {
        const inf = std.math.inf(f32);
        return .{ .lo = .{ inf, inf, inf }, .hi = .{ -inf, -inf, -inf }, .first = first, .end = end };
    }

    fn growBox(box: *PickBox, lo: [3]f32, hi: [3]f32) void {
        for (0..3) |k| {
            box.lo[k] = @min(box.lo[k], lo[k]);
            box.hi[k] = @max(box.hi[k], hi[k]);
        }
    }

    /// The box of all beads on the bed (x0, y0, x1, y1, in mm), or null
    /// with no beads. A 2D view fits it in the window.
    pub fn bounds(v: *const View) ?[4]f32 {
        var box = emptyBox(0, 0);
        for (v.layer_boxes.items) |l| if (l.lo[0] <= l.hi[0]) growBox(&box, l.lo, l.hi);
        if (!(box.lo[0] <= box.hi[0])) return null;
        // The boxes have room for a grown bead; the bounds need half of it.
        return .{ box.lo[0], box.lo[1], box.hi[0], box.hi[1] };
    }

    /// The path of bead i, and the index of the bead in the path (its
    /// segment).
    fn pathOfBead(v: *const View, i: usize) [2]usize {
        // The last path whose first bead is at or before i.
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

    /// The path and the segment of the path under a pixel.
    pub fn pickSegment(v: *const View, px: f32, py: f32) ?[2]usize {
        const i = (v.rayHit(px, py, 1) orelse return null).bead;
        return v.pathOfBead(i);
    }

    // ---- the 2D view of one layer, and the steps through the paths ----
    //
    // A 2D view shows one layer from the top (see linux/src/ui/preview.c
    // and web/app). These functions give it the beads of a layer, a pick
    // in mm, and the steps of the keys h, j, k, l along the print. They
    // work on the beads of the view, so a view from `readScene` has them
    // with no app.

    /// The beads of layer `layer`: first to end in the instances.
    pub fn layerBeads(v: *const View, layer: usize) [2]u32 {
        if (layer >= v.layer_end.items.len) return .{ 0, 0 };
        return .{ if (layer == 0) 0 else v.layer_end.items[layer - 1], v.layer_end.items[layer] };
    }

    /// The marks of layer `layer` (the seams, the travel moves, and the
    /// retractions): first to end in the instances, after the beads.
    pub fn layerMarks(v: *const View, layer: usize) [2]u32 {
        if (layer >= v.mark_layer_end.items.len) return .{ 0, 0 };
        const base: u32 = @intCast(v.beads.items.len);
        return .{ base + if (layer == 0) 0 else v.mark_layer_end.items[layer - 1], base + v.mark_layer_end.items[layer] };
    }

    /// The beads of path `path`: first to end. Bead k is segment k.
    pub fn pathBeads(v: *const View, path: usize) [2]u32 {
        if (path + 1 >= v.path_start.items.len) return .{ 0, 0 };
        return .{ v.path_start.items[path], v.path_start.items[path + 1] };
    }

    /// The number of paths.
    pub fn pathCount(v: *const View) usize {
        return if (v.path_start.items.len > 0) v.path_start.items.len - 1 else 0;
    }

    /// The segments of a path: its beads (a path with no bead has none).
    pub fn segments(v: *const View, path: usize) usize {
        const r = v.pathBeads(path);
        return r[1] - r[0];
    }

    /// The layer of a path.
    pub fn layerOfPath(v: *const View, path: usize) usize {
        var lo: usize = 0;
        var hi: usize = v.layer_path_end.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (v.layer_path_end.items[mid] <= path) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The path and the segment of layer `layer` nearest to (x, y) mm, in
    /// the 2D view: closer than twice the bead width, or null. The marks
    /// are not paths.
    pub fn pickLayer(v: *const View, layer: usize, x: f32, y: f32) ?[2]usize {
        const r = v.layerBeads(layer);
        // A print view keeps no copy of its beads.
        if (r[1] > v.beads.items.len) return null;
        var best: ?usize = null;
        var best_d: f32 = std.math.inf(f32);
        for (v.beads.items[r[0]..r[1]], r[0]..) |b, i| {
            const d = segmentDistance2(x, y, b.ax, b.ay, b.bx, b.by);
            if (d < best_d and d < 4 * b.w * b.w) {
                best_d = d;
                best = i;
            }
        }
        return v.pathOfBead(best orelse return null);
    }

    /// One step along the print from segment `seg` of path `path` (null:
    /// the whole path): to the next segment (dir 1) or the segment before
    /// (dir -1), and on to the next or the path before at an end. With
    /// `whole_path`, a whole path at a time. Paths with no segment are
    /// passed. Null at the start or the end of the print.
    pub fn stepPath(v: *const View, path: usize, seg: ?usize, dir: i32, whole_path: bool) ?struct { path: usize, seg: ?usize } {
        const n: i64 = @intCast(v.pathCount());
        const sel: i64 = @intCast(path);
        if (sel >= n) return null;
        var p = sel;
        var s: ?usize = seg;
        if (whole_path) {
            p = sel + dir;
            s = null;
        } else if (dir > 0) {
            const next: usize = if (seg) |k| k + 1 else 0;
            if (next >= v.segments(path)) p = sel + 1 else s = next;
        } else if (seg == null or seg.? == 0) {
            p = sel - 1;
        } else {
            s = seg.? - 1;
        }
        while (p >= 0 and p < n and v.segments(@intCast(p)) == 0) p += dir;
        if (p < 0 or p >= n) return null;
        const up: usize = @intCast(p);
        // On another path: its first segment going forward, its last going
        // back.
        if (!whole_path and p != sel) s = if (dir > 0) 0 else v.segments(up) - 1;
        return .{ .path = up, .seg = s };
    }

    /// The path of layer `layer` nearest to the middle of path `path`, for
    /// the keys j and k: a path of the same feature wins a near tie (a
    /// path of another feature counts as 1 mm farther). Null if the layer
    /// has no path with a segment.
    pub fn nearestOnLayer(v: *const View, path: usize, layer: usize) ?usize {
        const pr = v.pathBeads(path);
        if (pr[1] <= pr[0] or layer >= v.layer_path_end.items.len) return null;
        const mid = v.beads.items[pr[0] + (pr[1] - pr[0]) / 2];
        const feature = mid.rgba[3];
        const p0: usize = if (layer == 0) 0 else v.layer_path_end.items[layer - 1];
        var best: ?usize = null;
        var best_d: f32 = std.math.inf(f32);
        for (p0..v.layer_path_end.items[layer]) |p| {
            const r = v.pathBeads(p);
            if (r[1] <= r[0]) continue;
            var d2: f32 = std.math.inf(f32);
            for (v.beads.items[r[0]..r[1]]) |b| d2 = @min(d2, segmentDistance2(mid.ax, mid.ay, b.ax, b.ay, b.bx, b.by));
            var d = @sqrt(d2);
            if (v.beads.items[r[0]].rgba[3] != feature) d += 1;
            if (d < best_d) {
                best_d = d;
                best = p;
            }
        }
        return best;
    }

    /// The print time (s) at the end of segment `seg` of path `path`.
    pub fn segmentEndTime(v: *const View, path: usize, seg: usize) f32 {
        const r = v.pathBeads(path);
        if (r[1] <= r[0] or r[1] > v.bead_end.items.len) return 0;
        return v.bead_end.items[@min(r[0] + seg, r[1] - 1)];
    }

    /// The path and the segment that print at time t (s), or null with no
    /// beads.
    pub fn segmentAtTime(v: *const View, t: f32) ?[2]usize {
        const n = v.bead_end.items.len;
        if (n == 0 or v.path_start.items.len < 2) return null;
        // The first bead that ends at or after t.
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (v.bead_end.items[mid] < t) lo = mid + 1 else hi = mid;
        }
        return v.pathOfBead(@min(lo, n - 1));
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

    /// A small, simple toolhead: the nozzle, its hex, and a thin heater
    /// block, 12 mm high in all, so it hides little of the print. While the
    /// part fan runs, a small rotor of 4 blades turns on top of the block.
    /// The rotor is absent with the fan off. p is x, y, and the top z of
    /// the bead; `spin` is the rotor angle (radians). Returns the number
    /// of beads.
    /// `bright`: a white nozzle and a cyan hex and block, which read well
    /// on a dark background and a small screen (the reduced view).
    fn toolhead(out: []vk.Instance, p: [3]f32, spin: f32, fan_on: bool, bright: bool) usize {
        const brass: [4]u8 = if (bright) .{ 0xff, 0xff, 0xff, code_overlay } else .{ 0xc9, 0xa2, 0x4e, code_overlay };
        const alu: [4]u8 = if (bright) .{ 0x22, 0xd3, 0xee, code_overlay } else .{ 0xb8, 0xbe, 0xc6, code_overlay };
        const blade = [4]u8{ 0x4a, 0xa3, 0xff, code_overlay };
        var n: usize = 0;
        const put = struct {
            fn f(o: []vk.Instance, k: *usize, ax: f32, ay: f32, bx: f32, by: f32, z: f32, h: f32, w: f32, c: [4]u8) void {
                if (k.* == o.len) return;
                o[k.*] = .{ .ax = ax, .ay = ay, .bx = if (ax == bx and ay == by) bx + 0.001 else bx, .by = by, .z = z, .h = h, .w = w, .rgba = c };
                k.* += 1;
            }
        }.f;
        const x = p[0];
        const y = p[1];
        const z0 = p[2];
        // The nozzle: a cone 3 mm high, from 0.4 mm at the tip to 3 mm, as
        // 5 discs that overlap, and its hex (a wider disc).
        for (0..5) |k| {
            const f: f32 = @as(f32, @floatFromInt(k)) / 4;
            put(out, &n, x, y, x, y, z0 + 0.5 + f * 2.5, 0.9, 0.4 + f * 2.6, brass);
        }
        put(out, &n, x, y, x, y, z0 + 4.2, 1.2, 4.5, brass);
        // The heater block: 10 x 8 mm, 5 mm high.
        put(out, &n, x - 1, y, x + 1, y, z0 + 9.8, 5.0, 8.0, alu);
        // The fan: 4 blades over the block, 4.5 mm long.
        if (fan_on) {
            for (0..4) |k| {
                const t = spin + std.math.pi / 2.0 * @as(f32, @floatFromInt(k));
                put(out, &n, x, y, x + 4.5 * @cos(t), y + 4.5 * @sin(t), z0 + 11.4, 0.7, 1.2, blade);
            }
        }
        return n;
    }

    /// The next generation number of a bead buffer.
    fn nextGen(v: *View) u32 {
        v.plate_gen +%= 1;
        return v.plate_gen;
    }

    // ---- the plate set (see plates.zig) ----

    /// Sets the plates of the row: the bed size (mm) of each, from left to
    /// right, and the active plate (the plate of this view). The plates
    /// keep their beads. When the active plate changes, the camera moves
    /// with the world, so the picture stays still. An empty list: one
    /// plate, and no row.
    pub fn setPlates(v: *View, beds: []const [2]f32, active: usize) Error!void {
        const had = v.active < v.plates.items.len;
        const old = if (had) v.plates.items[v.active].origin else [2]f32{ 0, 0 };
        while (v.plates.items.len > beds.len) {
            var p = v.plates.pop().?;
            p.deinit(gpa);
        }
        while (v.plates.items.len < beds.len) v.plates.append(gpa, .{}) catch return error.OutOfMemory;
        // The gap: 15 % of the widest bed, and at least 30 mm.
        var gap: f32 = 30;
        for (beds) |b| gap = @max(gap, 0.15 * b[0]);
        var x: f32 = 0;
        for (v.plates.items, beds) |*p, b| {
            p.bed = b;
            p.origin = .{ x, 0 };
            x += b[0] + gap;
        }
        v.active = if (beds.len == 0) 0 else @min(active, beds.len - 1);
        if (beds.len > 0) {
            const new = v.plates.items[v.active].origin;
            if (had) v.shiftWorld(.{ old[0] - new[0], old[1] - new[1] });
            // The active plate draws from the view: its own beads go.
            const p = &v.plates.items[v.active];
            if (p.beads.items.len > 0) {
                p.clear();
                p.gen = v.nextGen();
            }
            // The bed of the active plate before its first slice (an empty
            // plate has one too).
            if (!std.meta.eql(v.bed, p.bed) and !v.headless) try v.loadGrid(p.bed[0], p.bed[1]);
        }
        try v.buildPlateGrid();
    }

    /// Moves the camera and the start view by d (mm): the world of the
    /// view moved by d.
    fn shiftWorld(v: *View, d: [2]f32) void {
        for (0..2) |k| {
            v.target[k] += d[k];
            v.home[k] += d[k];
            if (v.goal) |*g| g.target[k] += d[k];
        }
    }

    /// The place of plate i in the world of the view: the origin of its
    /// bed, from the origin of the bed of the active plate.
    pub fn plateOffset(v: *const View, i: usize) [2]f32 {
        if (i >= v.plates.items.len or v.active >= v.plates.items.len) return .{ 0, 0 };
        const a = v.plates.items[v.active].origin;
        const p = v.plates.items[i].origin;
        return .{ p[0] - a[0], p[1] - a[1] };
    }

    /// The grid lines of the other plates, in the world of the view.
    fn buildPlateGrid(v: *View) Error!void {
        v.plate_grid.clearRetainingCapacity();
        for (0..2) |pass| {
            if (pass == 1) v.plate_grid_dim = @intCast(v.plate_grid.items.len / 3);
            for (v.plates.items, 0..) |p, i| {
                if (i == v.active) continue;
                if ((p.flags & plates_mod.flag_disabled != 0) != (pass == 1)) continue;
                try appendGrid(&v.plate_grid, v.plateOffset(i), p.bed);
            }
        }
        v.plate_grid_gen = v.nextGen();
    }

    /// Reads the beads of a scene of `writeScene` into plate i (not the
    /// active plate). The other data of the scene stay out.
    pub fn readPlateScene(v: *View, i: usize, bytes: []const u8) (Error || error{InvalidScene})!void {
        if (i >= v.plates.items.len or i == v.active) return;
        const s = try sceneOffsets(bytes);
        const copy = struct {
            fn f(comptime T: type, list: *std.ArrayList(T), b: []const u8, at: usize, n: u32) Error!void {
                list.resize(gpa, n) catch return error.OutOfMemory;
                @memcpy(std.mem.sliceAsBytes(list.items), b[at..][0 .. n * @sizeOf(T)]);
            }
        }.f;
        var beads: std.ArrayList(vk.Instance) = .empty;
        defer beads.deinit(gpa);
        var ends: std.ArrayList(u32) = .empty;
        defer ends.deinit(gpa);
        var lite: plates_mod.Lite = .{};
        defer lite.deinit(gpa);
        try copy(vk.Instance, &beads, bytes, s.at[scene_beads], s.head.counts[scene_beads]);
        try copy(u32, &ends, bytes, s.at[scene_layer_end], s.head.counts[scene_layer_end]);
        try copy(vk.Instance, &lite.beads, bytes, s.at[scene_lite], s.head.counts[scene_lite]);
        for (0..plates_mod.n_levels) |k| try copy(u32, &lite.layer_end[k], bytes, s.at[scene_lite + 1 + k], s.head.counts[scene_lite + 1 + k]);
        lite.level_start = s.head.lite_start;
        const p = &v.plates.items[i];
        try p.set(gpa, beads.items, ends.items, if (lite.layers() == ends.items.len) &lite else null);
        p.gen = v.nextGen();
    }

    /// Reads the last slice of `app` into plate i (not the active plate),
    /// in the color mode of the view.
    /// The scene bytes (`writeScene`) of the last slice of an app in a
    /// color mode, with no GPU: the beads of a plate of a set
    /// (app/plate_set.zig).
    pub fn appScene(alloc: std.mem.Allocator, app: *const app_mod.App, mode: Mode) (Error || error{InvalidScene})![]u8 {
        var t: View = .{ .renderer = undefined, .headless = true, .width = 1, .height = 1, .mode = mode };
        defer t.deinitData();
        try t.load(app);
        // A headless load makes no light levels. The scene needs them: the
        // view of the page draws the active plate far from the camera with
        // them, and a plate scene without them builds them on the UI thread.
        if (frame_backend) try t.lite.build(gpa, t.beads.items, t.layer_end.items);
        return t.writeScene(alloc);
    }

    pub fn loadPlate(v: *View, i: usize, app: *const app_mod.App) Error!void {
        if (i >= v.plates.items.len or i == v.active) return;
        var t: View = .{ .renderer = undefined, .headless = true, .width = 1, .height = 1, .mode = v.mode };
        defer t.deinitData();
        try t.load(app);
        const p = &v.plates.items[i];
        try p.set(gpa, t.beads.items, t.layer_end.items, null);
        p.gen = v.nextGen();
    }

    /// Shows plate i (not the active plate) as the footprints of its
    /// parts: a frame of thin beads on the bed around each box (x0, y0,
    /// x1, y1 in mm), for a plate with parts and no slice (a resin plate).
    pub fn setPlateOutline(v: *View, i: usize, boxes: []const [4]f32) Error!void {
        if (i >= v.plates.items.len or i == v.active) return;
        var beads: std.ArrayList(vk.Instance) = .empty;
        defer beads.deinit(gpa);
        const color = [4]u8{ 0x7a, 0x86, 0x96, code_overlay };
        for (boxes) |b| {
            const c = [_][2]f32{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[2], b[3] }, .{ b[0], b[3] } };
            for (0..4) |k| {
                const a = c[k];
                const e = c[(k + 1) % 4];
                beads.append(gpa, .{ .ax = a[0], .ay = a[1], .bx = e[0], .by = e[1], .z = 0.6, .h = 0.6, .w = 1.0, .rgba = color }) catch return error.OutOfMemory;
            }
        }
        const p = &v.plates.items[i];
        const ends = [1]u32{@intCast(beads.items.len)};
        try p.set(gpa, beads.items, if (beads.items.len > 0) &ends else &.{}, null);
        p.gen = v.nextGen();
    }

    /// Drops the beads of plate i (an empty plate).
    pub fn clearPlate(v: *View, i: usize) void {
        if (i >= v.plates.items.len) return;
        const p = &v.plates.items[i];
        p.clear();
        p.gen = v.nextGen();
    }

    /// The flags of plate i (plates.flag_*).
    pub fn setPlateFlags(v: *View, i: usize, flags: u32) Error!void {
        if (i >= v.plates.items.len) return;
        const p = &v.plates.items[i];
        const before = p.flags;
        p.flags = flags;
        if ((before ^ flags) & plates_mod.flag_disabled != 0) try v.buildPlateGrid();
    }

    /// The box of plate i in the world of the view: its bed, and its beads.
    fn plateBox(v: *const View, i: usize) [2][3]f32 {
        var lo = [3]f32{ 0, 0, 0 };
        var hi = [3]f32{ v.bed[0], v.bed[1], 1 };
        if (i < v.plates.items.len) {
            const p = v.plates.items[i];
            hi = .{ p.bed[0], p.bed[1], 1 };
            if (i != v.active and p.full_end > 0) for (0..3) |k| {
                lo[k] = @min(lo[k], p.lo[k]);
                hi[k] = @max(hi[k], p.hi[k]);
            };
        }
        if (i == v.active or i >= v.plates.items.len) {
            for (v.layer_boxes.items) |b| if (b.lo[0] <= b.hi[0]) for (0..3) |k| {
                lo[k] = @min(lo[k], b.lo[k]);
                hi[k] = @max(hi[k], b.hi[k]);
            };
        }
        lo[2] = @max(lo[2], 0);
        const o = v.plateOffset(i);
        return .{ .{ lo[0] + o[0], lo[1] + o[1], lo[2] }, .{ hi[0] + o[0], hi[1] + o[1], hi[2] } };
    }

    /// The plate under the pixel: the first plate box (bed and beads) that
    /// the ray meets, or null. With no row, plate 0 if the ray meets the
    /// bed of the view.
    pub fn plateAt(v: *const View, px: f32, py: f32) ?usize {
        const cam = v.camera();
        const dir = v.pixelRay(cam, px, py);
        var best: ?usize = null;
        var best_t: f32 = std.math.inf(f32);
        const n = @max(v.plates.items.len, 1);
        for (0..n) |i| {
            const b = v.plateBox(i);
            const t = rayBoxEntry(cam.eye, dir, b[0], b[1]) orelse continue;
            if (t < best_t) {
                best_t = t;
                best = i;
            }
        }
        return best;
    }

    /// Moves the camera (animated) to show plate i whole, from the front.
    pub fn framePlate(v: *View, i: usize) void {
        const b = v.plateBox(i);
        v.frameBox(b[0], b[1]);
    }

    /// Moves the camera (animated) to show all plates.
    pub fn frameAll(v: *View) void {
        const n = @max(v.plates.items.len, 1);
        var b = v.plateBox(0);
        for (1..n) |i| {
            const c = v.plateBox(i);
            for (0..3) |k| {
                b[0][k] = @min(b[0][k], c[0][k]);
                b[1][k] = @max(b[1][k], c[1][k]);
            }
        }
        v.frameBox(b[0], b[1]);
    }

    /// Moves the camera (animated) to look at the box lo to hi from the
    /// front and above (the angles of `reset`), at the distance that shows
    /// all of it.
    fn frameBox(v: *View, lo: [3]f32, hi: [3]f32) void {
        v.frameBoxScaled(lo, hi, 1.08);
    }

    /// Frames the beads of a G-code file at once (no animation): the box
    /// of the part in the middle, at the angle of `reset`, so that it fills
    /// `fill` (0.8: 80 %) of the smaller side of the view. A printer screen
    /// shows the part as the subject. False with no G-code beads.
    pub fn framePart(v: *View, fill: f32) bool {
        const r = v.gcode orelse return false;
        const b = r.box;
        if (!(b[3] >= b[0])) return false;
        v.frameBoxScaled(.{ b[0], b[1], b[2] }, .{ b[3], b[4], b[5] }, 1 / std.math.clamp(fill, 0.1, 1));
        if (v.goal) |g| v.setPose(g);
        v.goal = null;
        return true;
    }

    fn frameBoxScaled(v: *View, lo: [3]f32, hi: [3]f32, margin: f32) void {
        const now = v.pose();
        v.setAngles(-1.75, 0.6);
        v.target = .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2 };
        const cam_b = qrotate(v.rot, .{ 0, 0, 1 });
        const s = qrotate(v.rot, .{ 1, 0, 0 });
        const u = qrotate(v.rot, .{ 0, 1, 0 });
        const aspect = @as(f32, @floatFromInt(v.width)) / @as(f32, @floatFromInt(v.height));
        const tan_half = @tan(@as(f32, fov) / 2);
        // Each corner: its depth is dist - (corner . back), and it must be
        // in the frustum on x and on y.
        var dist: f32 = 1;
        for (0..8) |c| {
            const p = [3]f32{
                (if (c & 1 != 0) hi[0] else lo[0]) - v.target[0],
                (if (c & 2 != 0) hi[1] else lo[1]) - v.target[1],
                (if (c & 4 != 0) hi[2] else lo[2]) - v.target[2],
            };
            const along = dot(p, cam_b);
            dist = @max(dist, @abs(dot(p, s)) / (tan_half * aspect) + along);
            dist = @max(dist, @abs(dot(p, u)) / tan_half + along);
        }
        v.dist = dist * margin;
        v.goal = v.pose();
        v.setPose(now);
    }

    /// The length of the row on x (mm), for the far plane.
    fn rowLength(v: *const View) f32 {
        const n = v.plates.items.len;
        if (n == 0) return 0;
        const last = v.plates.items[n - 1];
        return last.origin[0] + last.bed[0];
    }

    /// The beads of a part that turn or move in the view only.
    pub const PartPreview = struct {
        part: u32,
        /// The model matrix of the beads (column-major): a turn about the
        /// pivot, then a move.
        m: [16]f32,
        /// The turn (rows of a 3x3 matrix), and the pivot and the move
        /// after the turn: for the eye and the light in the frame of the
        /// beads.
        rot: [9]f32,
        pivot: [3]f32,
        move: [3]f32,
        /// The box of the beads of the part, before the turn.
        lo: [3]f32,
        hi: [3]f32,
    };

    pub fn clearPreview(v: *View) void {
        v.preview = null;
        v.preview_ranges.clearRetainingCapacity();
    }

    /// Shows part `part` of the plate (Toolpaths.path_part) turned by the
    /// unit quaternion q (x, y, z, w) about `pivot`, then moved by `move`
    /// (mm). With `on_bed`, the move also puts the lowest bead on the bed.
    /// Only the view changes: a turn of a ring or the fall of a part
    /// moves the beads at once, before the slice of the new place. A load
    /// ends it. null: no preview.
    pub fn setPartPreview(v: *View, part: ?u32, q: [4]f32, pivot: [3]f32, move: [3]f32, on_bed: bool) Error!void {
        const pi = part orelse {
            v.clearPreview();
            return;
        };
        if (v.preview == null or v.preview.?.part != pi) {
            v.preview_ranges.clearRetainingCapacity();
            const n = @min(v.path_part.items.len, v.path_start.items.len -| 1);
            for (0..n) |path| {
                if (v.path_part.items[path] != pi) continue;
                const a = v.path_start.items[path];
                const b = v.path_start.items[path + 1];
                if (b <= a) continue;
                const items = v.preview_ranges.items;
                if (items.len > 0 and items[items.len - 1][1] == a) {
                    items[items.len - 1][1] = b;
                } else v.preview_ranges.append(gpa, .{ a, b }) catch return error.OutOfMemory;
            }
        }
        var lo = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
        var hi = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (v.preview_ranges.items) |r| for (v.beads.items[r[0]..r[1]]) |b| {
            const r2 = b.w / 2;
            lo = .{ @min(lo[0], @min(b.ax, b.bx) - r2), @min(lo[1], @min(b.ay, b.by) - r2), @min(lo[2], b.z - b.h) };
            hi = .{ @max(hi[0], @max(b.ax, b.bx) + r2), @max(hi[1], @max(b.ay, b.by) + r2), @max(hi[2], b.z) };
        };
        if (!(lo[0] <= hi[0])) {
            v.preview = null;
            return;
        }
        // The rotation matrix of q, in rows.
        const len = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
        const x = q[0] / len;
        const y = q[1] / len;
        const z = q[2] / len;
        const w = q[3] / len;
        const rot = [9]f32{
            1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
            2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y),
        };
        var mv = move;
        if (on_bed) {
            // The lowest point of the turned part: the corners of the
            // beads (a bead is no wider than its box).
            var zmin = std.math.inf(f32);
            for (v.preview_ranges.items) |r| for (v.beads.items[r[0]..r[1]]) |b| {
                const r2 = b.w / 2;
                for ([_][2]f32{ .{ b.ax, b.ay }, .{ b.bx, b.by } }) |e| for ([_]f32{ b.z, b.z - b.h }) |bz| {
                    // The x and y of the corner do not matter much: use
                    // the end point, and the width as a margin.
                    const d = [3]f32{ e[0] - pivot[0], e[1] - pivot[1], bz - pivot[2] };
                    const zz = rot[6] * d[0] + rot[7] * d[1] + rot[8] * d[2];
                    zmin = @min(zmin, zz - r2 * @sqrt(rot[6] * rot[6] + rot[7] * rot[7]));
                };
            };
            mv[2] = -(zmin + pivot[2]);
        }
        // m = T(pivot + move) * R * T(-pivot), column-major.
        var m: [16]f32 = .{ rot[0], rot[3], rot[6], 0, rot[1], rot[4], rot[7], 0, rot[2], rot[5], rot[8], 0, 0, 0, 0, 1 };
        for (0..3) |row| {
            m[12 + row] = pivot[row] + mv[row] - (rot[row * 3] * pivot[0] + rot[row * 3 + 1] * pivot[1] + rot[row * 3 + 2] * pivot[2]);
        }
        v.preview = .{ .part = pi, .m = m, .rot = rot, .pivot = pivot, .move = mv, .lo = lo, .hi = hi };
    }

    /// A point of the world in the frame of the beads of the preview: the
    /// inverse turn (the transpose) about the pivot.
    fn previewLocal(p: PartPreview, w: [3]f32) [3]f32 {
        const d = [3]f32{ w[0] - p.pivot[0] - p.move[0], w[1] - p.pivot[1] - p.move[1], w[2] - p.pivot[2] - p.move[2] };
        return .{
            p.rot[0] * d[0] + p.rot[3] * d[1] + p.rot[6] * d[2] + p.pivot[0],
            p.rot[1] * d[0] + p.rot[4] * d[1] + p.rot[7] * d[2] + p.pivot[1],
            p.rot[2] * d[0] + p.rot[5] * d[1] + p.rot[8] * d[2] + p.pivot[2],
        };
    }

    /// The draws of the part of the preview in beads first .. end, and
    /// the draw list `list` without them (in v.rest_draws). The part gets
    /// the mesh level of its distance from the eye.
    fn splitPreview(v: *View, list: []const Draw, eye_local: [3]f32, first: u32, end: u32) Error![]const Draw {
        const p = v.preview.?;
        v.preview_draws.clearRetainingCapacity();
        v.rest_draws.clearRetainingCapacity();
        const px_per_mm = @as(f32, @floatFromInt(v.height)) / (2 * @tan(@as(f32, fov) / 2));
        const w = if (v.beads.items.len > 0) v.beads.items[v.beads.items.len / 2].w else 0.4;
        const lod = v.lodFor(w * px_per_mm / @max(boxDistance(eye_local, p.lo, p.hi), 1e-3));
        for (v.preview_ranges.items) |r| {
            const a = @max(r[0], first);
            const b = @min(r[1], end);
            if (b > a) v.preview_draws.append(gpa, .{ .first = a, .count = b - a, .lod = lod }) catch return error.OutOfMemory;
        }
        // The ranges of the list minus the ranges of the part (both in
        // print order).
        const parts = v.preview_ranges.items;
        var k: usize = 0;
        for (list) |d| {
            var a = d.first;
            const b = d.first + d.count;
            while (k < parts.len and parts[k][1] <= a) k += 1;
            var j = k;
            while (a < b) {
                if (j >= parts.len or parts[j][0] >= b) {
                    v.rest_draws.append(gpa, .{ .first = a, .count = b - a, .lod = d.lod }) catch return error.OutOfMemory;
                    break;
                }
                if (parts[j][0] > a) v.rest_draws.append(gpa, .{ .first = a, .count = parts[j][0] - a, .lod = d.lod }) catch return error.OutOfMemory;
                a = @max(a, parts[j][1]);
                j += 1;
            }
        }
        return v.rest_draws.items;
    }

    /// The light level for the active plate, or null for the full beads:
    /// only with no selection and no replay (the light beads are not in
    /// the index space of the highlight and the replay).
    fn activeLevel(v: *const View, eye: [3]f32) ?usize {
        if (!frame_backend) return null;
        const n = v.layer_end.items.len;
        if (n == 0 or v.lite.layers() != n or v.beads.items.len == 0) return null;
        if (v.time != null or v.highlight[1] > v.highlight[0] or v.seg_bead != null or v.more.items.len > 0) return null;
        if (v.preview != null) return null;
        var lo = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
        var hi = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (v.layer_boxes.items) |b| if (b.lo[0] <= b.hi[0]) for (0..3) |k| {
            lo[k] = @min(lo[k], b.lo[k]);
            hi[k] = @max(hi[k], b.hi[k]);
        };
        if (!(lo[0] <= hi[0])) return null;
        const px_per_mm = @as(f32, @floatFromInt(v.height)) / (2 * @tan(@as(f32, fov) / 2));
        const h = v.beads.items[v.beads.items.len / 2].h;
        // A large plate uses level 1 also near the camera: under the top
        // layers, the beads that it leaves out do not show from outside,
        // and the full beads of a large plate can keep the GPU busy for
        // longer than a driver allows (a reset of the context).
        // A slow GPU while the view moves (the detail governor at 2 or
        // more) also uses level 0.
        const near: ?usize = if (v.beads.items.len > large_plate or v.detail >= 2) 0 else null;
        return plates_mod.levelFor(h * px_per_mm / @max(boxDistance(eye, lo, hi), 1e-3)) orelse near;
    }

    /// The bead count of a large plate (see `activeLevel`).
    const large_plate = 500_000;

    /// The plates of a frame (frame backend only): for each other plate in the view,
    /// its matrices, its buffer, and its draws (the chunks in the view, or
    /// a light level far from the camera).
    fn drawPlates(v: *View, mvp: [16]f32, eye: [3]f32) Error!void {
        const px_per_mm = @as(f32, @floatFromInt(v.height)) / (2 * @tan(@as(f32, fov) / 2));
        for (v.plates.items, 0..) |*p, i| {
            if (i == v.active) continue;
            const o = v.plateOffset(i);
            const pm = mul(mvp, translation(o[0], o[1], 0));
            const pe = [3]f32{ eye[0] - o[0], eye[1] - o[1], eye[2] };
            const box: PickBox = .{
                .lo = .{ @min(0, p.lo[0]), @min(0, p.lo[1]), 0 },
                .hi = .{ @max(p.bed[0], p.hi[0]), @max(p.bed[1], p.hi[1]), @max(1, p.hi[2]) },
                .first = 0,
                .end = 0,
            };
            if (!boxInView(pm, box)) continue;
            const first: u32 = @intCast(v.plate_draws.items.len);
            if (p.full_end > 0) {
                const d = boxDistance(pe, p.lo, p.hi);
                if (plates_mod.levelFor(p.layer_h * px_per_mm / @max(d, 1e-3))) |k| {
                    const r = p.liteRange(k);
                    if (r[1] > r[0]) v.plate_draws.append(gpa, .{ .first = r[0], .count = r[1] - r[0], .lod = v.liteLod() }) catch return error.OutOfMemory;
                } else for (p.chunks.items) |c| {
                    if (!boxInView(pm, .{ .lo = c.lo, .hi = c.hi, .first = 0, .end = 0 })) continue;
                    const cd = boxDistance(pe, c.lo, c.hi);
                    const lod = v.lodFor(c.width * px_per_mm / @max(cd, 1e-3));
                    if (v.plate_draws.items.len > first) {
                        const last = &v.plate_draws.items[v.plate_draws.items.len - 1];
                        if (last.lod == lod and last.first + last.count == c.first) {
                            last.count += c.end - c.first;
                            continue;
                        }
                    }
                    v.plate_draws.append(gpa, .{ .first = c.first, .count = c.end - c.first, .lod = lod }) catch return error.OutOfMemory;
                }
            }
            v.plate_frames.append(gpa, .{
                .mvp = pm,
                .bed_mvp = mul(pm, translation(p.bed[0] / 2, p.bed[1] / 2, 0)),
                .instances = @intFromPtr(p.beads.items.ptr),
                .instance_count = @intCast(p.beads.items.len),
                .gen = p.gen,
                .draws_first = first,
                .draws_count = @as(u32, @intCast(v.plate_draws.items.len)) - first,
                .fade = if (p.flags & plates_mod.flag_disabled != 0) 0.3 else if (p.flags & plates_mod.flag_stale != 0) 0.45 else 0,
                .flags = if (p.flags & plates_mod.flag_bed_model != 0 and p.flags & plates_mod.flag_disabled == 0) PlateFrame.flag_bed else 0,
                .slot = @intCast(i),
            }) catch return error.OutOfMemory;
        }
    }

    pub fn draw(v: *View) Error!void {
        const cam = v.camera();
        const eye = cam.eye;
        const aspect = @as(f32, @floatFromInt(v.width)) / @as(f32, @floatFromInt(v.height));
        const proj = perspective(fov, aspect, @max(v.dist * 0.01, 0.1), v.dist * 10 + (v.extent + v.rowLength()) * 4);
        const view = lookAt(eye, v.target, cam.u);
        const mvp = mul(proj, view);
        var count: u32 = 0;
        const extras = v.extras_buf orelse blk: {
            const b = gpa.alloc(vk.Instance, vk.max_extras) catch return error.OutOfMemory;
            v.extras_buf = b;
            break :blk b;
        };
        var n_extras: usize = 0;
        // The toolhead of a replay: drawn last, see-through.
        var n_head: usize = 0;
        if (v.time) |t| {
            const done = v.beadsDoneAt(t);
            count = @intCast(done);
            // The nozzle: at the end of the bead that prints now, or at the
            // end of the last bead done (on a travel).
            var tip: ?[3]f32 = null;
            if (done < v.beads.items.len) {
                const t_start = if (done < v.bead_start.items.len) v.bead_start.items[done] else if (done == 0) 0 else v.bead_end.items[done - 1];
                const t_end = v.bead_end.items[done];
                // On a travel to this bead: the nozzle moves in a line from
                // the end of the bead before to the start of this one.
                const t_prev = if (done == 0) 0 else v.bead_end.items[done - 1];
                if (done > 0 and t < t_start and t_start > t_prev) {
                    const a = v.beads.items[done - 1];
                    const b = v.beads.items[done];
                    const f = @max(0, (t - t_prev) / (t_start - t_prev));
                    tip = .{ a.bx + (b.ax - a.bx) * f, a.by + (b.ay - a.by) * f, a.z + (b.z - a.z) * f };
                }
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
            // The impeller turns with the print time, at the fan of the
            // bead that prints: at full fan, half a turn each second of
            // the print (a replay at 10x turns it 5 times a second); with
            // the fan off it stands still.
            const fb = if (v.bead_fan.items.len == 0) 255 else v.bead_fan.items[@min(done, v.bead_fan.items.len - 1)];
            const spin: f32 = @floatCast(@mod(t * std.math.pi * @as(f32, @floatFromInt(fb)) / 255, 2 * std.math.pi));
            if (tip) |p| n_head = toolhead(&v.head_buf, p, spin, fb > 0, v.reduced);
        } else if (v.layer_end.items.len > 0) {
            count = v.layer_end.items[@min(v.layer, v.layer_end.items.len - 1)];
        }
        // A print view: the beads up to the position or the layer, the
        // top layer lit, and the nozzle at the position.
        var lit_range = [2]f32{ 0, 0 };
        var base_end: u32 = 0;
        var cached = false;
        if (v.gcode) |r| if (v.time == null) {
            const g = v.gcodeCount();
            count = g[1];
            // An offscreen view keeps the layers under the top layer in a
            // cached image (see Frame.base_end).
            if (@hasField(vk.Renderer, "offscreen") and v.renderer.offscreen) {
                cached = true;
                base_end = g[0];
            }
            if (v.lit) lit_range = .{ @floatFromInt(g[0]), @floatFromInt(g[1]) };
            if (v.position) |off| if (v.show_head) if (r.segmentAt(off)) |i| {
                const sg = r.at(i);
                n_head = toolhead(&v.head_buf, .{ sg.x, sg.y, sg.z }, 0, false, v.reduced);
            };
        };
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
        // The other plates, and far from the camera the light beads of
        // this plate under its top layers (see plates.zig).
        v.plate_frames.clearRetainingCapacity();
        v.plate_draws.clearRetainingCapacity();
        if (frame_backend) {
            if (v.activeLevel(eye)) |level| {
                const n = v.layer_end.items.len;
                const hi = @min(v.layer, n - 1);
                const lo = @min(v.layer_lo, hi);
                const step: usize = @as(usize, 1) << @intCast(level);
                // The light beads up to a layer that the level keeps, and
                // the full beads of the layers over it (the top layer
                // shows its inside).
                const split = (hi / step) * step;
                if (split > lo) {
                    const r = v.lite.range(level, lo, split - 1);
                    first = @max(first, v.layer_end.items[split - 1]);
                    v.plate_draws.append(gpa, .{ .first = r[0], .count = r[1] - r[0], .lod = v.liteLod() }) catch return error.OutOfMemory;
                    v.plate_frames.append(gpa, .{
                        .mvp = mvp,
                        .bed_mvp = mvp,
                        .instances = @intFromPtr(v.lite.beads.items.ptr),
                        .instance_count = @intCast(v.lite.beads.items.len),
                        .gen = v.lite_gen,
                        .draws_first = 0,
                        .draws_count = 1,
                        .fade = 0,
                        .flags = PlateFrame.flag_active,
                        .slot = @intCast(v.active),
                    }) catch return error.OutOfMemory;
                }
            }
            try v.drawPlates(mvp, eye);
        }
        // The draw list, and the part of a preview with its own matrix.
        var draws: []const Draw = if (frame_backend or v.gcode == null) try v.drawList(mvp, eye, first, count) else &.{};
        var part_draws: []const Draw = &.{};
        var part_push: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } };
        if (v.preview) |pv| if (v.gcode == null) {
            const le = previewLocal(pv, eye);
            draws = try v.splitPreview(draws, le, first, count);
            part_draws = v.preview_draws.items;
            const l = [3]f32{ 0.35, -0.45, 0.82 };
            const r = pv.rot;
            part_push = .{
                .mvp = mul(mvp, pv.m),
                .vec = .{ r[0] * l[0] + r[3] * l[1] + r[6] * l[2], r[1] * l[0] + r[4] * l[1] + r[7] * l[2], r[2] * l[0] + r[5] * l[1] + r[8] * l[2], 0 },
                .eye = .{ le[0], le[1], le[2], 1e9 },
                .params = .{ 0, 0, 0, if (v.mode == .print) 0 else 1 },
            };
        };
        try v.renderer.draw(.{
            .head = v.head_buf[0..n_head],
            .part = part_push,
            .part_draws = part_draws,
            .extras = blk: {
                // The reduced view has no tools and no marks.
                if (v.reduced) break :blk extras[0..n_extras];
                // The measure tape: a mark at each point, and a line of
                // short beads between them (a bead is level, so a slope
                // is a stair of 24 of them).
                if (v.measure_n > 0) {
                    const gold = [4]u8{ 0xff, 0xb3, 0x00, code_overlay };
                    const span = std.math.clamp(v.dist * 0.004, 0.15, 3);
                    for (v.measure[0..v.measure_n]) |p| {
                        if (n_extras == extras.len) break;
                        extras[n_extras] = .{ .ax = p[0], .ay = p[1], .bx = p[0] + 0.001, .by = p[1], .z = p[2] + span, .h = span * 2, .w = span * 4, .rgba = gold };
                        n_extras += 1;
                    }
                    if (v.measure_n == 2) {
                        const a = v.measure[0];
                        const b = v.measure[1];
                        const steps = 24;
                        for (0..steps) |k| {
                            if (n_extras == extras.len) break;
                            const f0 = @as(f32, @floatFromInt(k)) / steps;
                            const f1 = @as(f32, @floatFromInt(k + 1)) / steps;
                            const x0 = a[0] + (b[0] - a[0]) * f0;
                            const y0 = a[1] + (b[1] - a[1]) * f0;
                            const x1 = a[0] + (b[0] - a[0]) * f1;
                            const y1 = a[1] + (b[1] - a[1]) * f1;
                            const z = a[2] + (b[2] - a[2]) * (f0 + f1) / 2;
                            const dz = @abs(b[2] - a[2]) / steps;
                            extras[n_extras] = .{ .ax = x0, .ay = y0, .bx = if (x0 == x1 and y0 == y1) x1 + 0.001 else x1, .by = y1, .z = z + @max(span, dz) / 2, .h = @max(span, dz), .w = span * 1.5, .rgba = gold };
                            n_extras += 1;
                        }
                    }
                }
                // The rings of the Turn tool: short beads along each ring
                // (a bead is level, so a slope of the ring is a stair).
                if (v.rings) |_| {
                    const span = std.math.clamp(v.dist * 0.003, 0.12, 2);
                    const colors = [3][4]u8{ .{ 0xe5, 0x48, 0x4d, code_overlay }, .{ 0x30, 0xa4, 0x6c, code_overlay }, .{ 0x3e, 0x8e, 0xf7, code_overlay } };
                    for (0..3) |axis| {
                        const active = v.ring_axis == @as(i8, @intCast(axis));
                        const w = if (active) span * 2.5 else span * 1.4;
                        const pts = v.ringPoints(axis);
                        // 4 short beads for each sample, which overlap,
                        // so a steep part of a ring has no gaps.
                        const sub = 4;
                        for (0..ring_samples) |k| for (0..sub) |q| {
                            if (n_extras == extras.len) break;
                            const t0 = @as(f32, @floatFromInt(q)) / sub;
                            const t1 = @as(f32, @floatFromInt(q + 1)) / sub;
                            const p0 = pts[k];
                            const p1 = pts[k + 1];
                            const a = [3]f32{ p0[0] + (p1[0] - p0[0]) * t0, p0[1] + (p1[1] - p0[1]) * t0, p0[2] + (p1[2] - p0[2]) * t0 };
                            const b = [3]f32{ p0[0] + (p1[0] - p0[0]) * t1, p0[1] + (p1[1] - p0[1]) * t1, p0[2] + (p1[2] - p0[2]) * t1 };
                            const h = @max(w, @abs(b[2] - a[2]) * 1.6);
                            const dx = b[0] - a[0];
                            const dy = b[1] - a[1];
                            const len = @sqrt(dx * dx + dy * dy);
                            // A vertical piece: a bead as long as it is wide.
                            const ex = if (len < w) (if (len > 1e-6) dx / len else 1) * w / 2 else 0;
                            const ey = if (len < w) (if (len > 1e-6) dy / len else 0) * w / 2 else 0;
                            const mx = (a[0] + b[0]) / 2;
                            const my = (a[1] + b[1]) / 2;
                            extras[n_extras] = if (len < w)
                                .{ .ax = mx - ex, .ay = my - ey, .bx = mx + ex, .by = my + ey, .z = (a[2] + b[2]) / 2 + h / 2, .h = h, .w = w, .rgba = colors[axis] }
                            else
                                .{ .ax = a[0], .ay = a[1], .bx = b[0], .by = b[1], .z = (a[2] + b[2]) / 2 + h / 2, .h = h, .w = w, .rgba = colors[axis] };
                            n_extras += 1;
                        };
                    }
                }
                // The plane of a cut: a frame and lines across it, orange.
                if (v.cut_plane) |cp| {
                    const orange = [4]u8{ 0xff, 0x7a, 0x1a, code_overlay };
                    const span = std.math.clamp(v.dist * 0.003, 0.12, 2);
                    const z = cp[4];
                    const across = 6;
                    var k: usize = 0;
                    while (k <= across + 4) : (k += 1) {
                        if (n_extras == extras.len) break;
                        // 4 sides, then lines across in X.
                        const seg: [4]f32 = switch (k) {
                            0 => .{ cp[0], cp[1], cp[2], cp[1] },
                            1 => .{ cp[2], cp[1], cp[2], cp[3] },
                            2 => .{ cp[2], cp[3], cp[0], cp[3] },
                            3 => .{ cp[0], cp[3], cp[0], cp[1] },
                            else => across_line: {
                                const t = @as(f32, @floatFromInt(k - 3)) / (across + 2);
                                const x = cp[0] + (cp[2] - cp[0]) * t;
                                break :across_line .{ x, cp[1], x, cp[3] };
                            },
                        };
                        const w = if (k < 4) span * 2 else span;
                        extras[n_extras] = .{ .ax = seg[0], .ay = seg[1], .bx = seg[2], .by = seg[3], .z = z + w / 2, .h = w, .w = w, .rgba = orange };
                        n_extras += 1;
                    }
                }
                // The support areas of the support editor.
                // Some room stays for the beads after them.
                v.supportAreaBeads(extras[0 .. extras.len - 16], &n_extras);
                // The frame of the selected part: four thin beads on the bed.
                if (v.part_box) |pb| {
                    const corners = [_][2]f32{ .{ pb[0], pb[1] }, .{ pb[2], pb[1] }, .{ pb[2], pb[3] }, .{ pb[0], pb[3] } };
                    for (0..4) |k| {
                        const a = corners[k];
                        const b = corners[(k + 1) % 4];
                        extras[n_extras] = .{ .ax = a[0], .ay = a[1], .bx = b[0], .by = b[1], .z = 0.25, .h = 0.25, .w = 0.7, .rgba = .{ 0x33, 0x88, 0xff, code_overlay } };
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
                    b.rgba = .{ 0xff, 0x5a, 0x00, code_overlay };
                    extras[n_extras] = b;
                    n_extras += 1;
                };
                // The rings of the support marks.
                for (v.mark_rings.items) |b| {
                    if (n_extras == extras.len) break;
                    extras[n_extras] = b;
                    n_extras += 1;
                }
                // The gaps of a layer.
                for (v.gap_beads.items) |b| {
                    if (n_extras == extras.len) break;
                    extras[n_extras] = b;
                    n_extras += 1;
                }
                break :blk extras[0..n_extras];
            },
            .clear = if (v.dark) .{ 0.114, 0.114, 0.125 } else .{ 0.965, 0.969, 0.973 },
            // A light from above, in front, and to the right.
            .box = .{
                .mvp = mvp,
                .vec = .{ 0.35, -0.45, 0.82, 0 },
                .eye = .{ eye[0], eye[1], eye[2], if (std.math.isInf(v.focus_zmax)) 1e9 else v.focus_zmax },
                // A print view: params.w = 4 lights the beads params.x to
                // params.y, and darkens the others (see shaders/box.frag).
                .params = if (v.gcode != null or v.reduced)
                    .{ lit_range[0], lit_range[1], 0, if (lit_range[1] > lit_range[0]) 4 else 0 }
                else
                    .{ v.highlight[0], v.highlight[1], if (v.isolate and v.highlight[1] > v.highlight[0]) -1 else @as(f32, @floatFromInt(v.focus_mask)), if (v.mode == .print) 0 else 1 },
            },
            .box_count = count,
            .box_first = first,
            .draws = draws,
            .culled = !frame_backend and v.gcode == null,
            .mark_first = @intCast(v.beads.items.len + mark_skip),
            .mark_count = mark_count,
            // On a bed model the grid is darker, so it shows on the gray bed.
            .grid = .{ .mvp = mvp, .vec = if (v.dark)
                (if (v.bed_vertices > 0) [4]f32{ 0.40, 0.41, 0.44, 1 } else [4]f32{ 0.24, 0.25, 0.27, 1 })
            else if (v.bed_vertices > 0) [4]f32{ 0.62, 0.64, 0.67, 1 } else [4]f32{ 0.80, 0.82, 0.85, 1 } },
            .grid_vertices = v.grid_vertices,
            // The bed model: its center goes to the middle of the bed.
            .bed = .{
                .mvp = mul(mvp, translation(v.bed[0] / 2, v.bed[1] / 2, 0)),
                .vec = if (v.dark) .{ 0.30, 0.31, 0.33, 1 } else .{ 0.84, 0.85, 0.87, 1 },
                .eye = .{ 0.35, -0.45, 0.82, 0 },
                .params = .{ if (v.bed_textured) 1 else 0, bed_clear_z, if (eye[2] < 0) 1 else 0, 0 },
            },
            .bed_vertices = v.bed_vertices,
            .plates = v.plate_frames.items,
            .plate_draws = v.plate_draws.items,
            .plate_grid = v.plate_grid.items,
            .plate_grid_dim = v.plate_grid_dim,
            .plate_grid_gen = v.plate_grid_gen,
            .cached = cached,
            .base_end = base_end,
            // The cached layers: all darker when the top layer is lit.
            .base = .{
                .mvp = mvp,
                .vec = .{ 0.35, -0.45, 0.82, 0 },
                .eye = .{ eye[0], eye[1], eye[2], 1e9 },
                .params = .{ 0, 0, 0, if (lit_range[1] > lit_range[0]) 4 else 0 },
            },
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

/// The test of a ray o + t d (t >= 0) against a box: true if the ray goes
/// through it nearer than `max_t`.
fn rayBox(o: [3]f32, d: [3]f32, box: View.PickBox, max_t: f32) bool {
    var t0: f32 = 0;
    var t1: f32 = max_t;
    for (0..3) |k| {
        if (d[k] == 0) {
            if (o[k] < box.lo[k] or o[k] > box.hi[k]) return false;
            continue;
        }
        const inv = 1 / d[k];
        var ta = (box.lo[k] - o[k]) * inv;
        var tb = (box.hi[k] - o[k]) * inv;
        if (ta > tb) std.mem.swap(f32, &ta, &tb);
        t0 = @max(t0, ta);
        t1 = @min(t1, tb);
        if (t0 > t1) return false;
    }
    return true;
}

/// The bed outline and a 10 mm grid of a bed of size `bed` at `o`, at
/// z = 0: x, y, z points, two for each line.
fn appendGrid(pts: *std.ArrayList(f32), o: [2]f32, bed: [2]f32) Error!void {
    const gpa = View.gpa;
    var x: f32 = 0;
    while (x <= bed[0] + 0.01) : (x += 10) pts.appendSlice(gpa, &.{ o[0] + @min(x, bed[0]), o[1], 0, o[0] + @min(x, bed[0]), o[1] + bed[1], 0 }) catch return error.OutOfMemory;
    var y: f32 = 0;
    while (y <= bed[1] + 0.01) : (y += 10) pts.appendSlice(gpa, &.{ o[0], o[1] + @min(y, bed[1]), 0, o[0] + bed[0], o[1] + @min(y, bed[1]), 0 }) catch return error.OutOfMemory;
}

/// The distance from p to the box lo to hi (0 inside it).
fn boxDistance(p: [3]f32, lo: [3]f32, hi: [3]f32) f32 {
    var d2: f32 = 0;
    for (0..3) |k| {
        const e = @max(@max(lo[k] - p[k], p[k] - hi[k]), 0);
        d2 += e * e;
    }
    return @sqrt(d2);
}

/// The distance along the ray o + t d (t >= 0) to where it goes into the
/// box lo to hi (0 if o is inside), or null if it misses the box.
fn rayBoxEntry(o: [3]f32, d: [3]f32, lo: [3]f32, hi: [3]f32) ?f32 {
    var t0: f32 = 0;
    var t1: f32 = std.math.inf(f32);
    for (0..3) |k| {
        if (d[k] == 0) {
            if (o[k] < lo[k] or o[k] > hi[k]) return null;
            continue;
        }
        const inv = 1 / d[k];
        var ta = (lo[k] - o[k]) * inv;
        var tb = (hi[k] - o[k]) * inv;
        if (ta > tb) std.mem.swap(f32, &ta, &tb);
        t0 = @max(t0, ta);
        t1 = @min(t1, tb);
        if (t0 > t1) return null;
    }
    return t0;
}

/// False if the box is out of the view: all its corners are outside the
/// same plane of the clip space of `mvp` (Vulkan: -w <= x, y <= w, and
/// 0 <= z <= w). The test works in homogeneous coordinates, so a corner
/// behind the eye gives no wrong answer.
fn boxInView(mvp: [16]f32, box: View.PickBox) bool {
    var out = [_]u8{0} ** 6;
    for (0..8) |i| {
        const p = [3]f32{
            if (i & 1 != 0) box.hi[0] else box.lo[0],
            if (i & 2 != 0) box.hi[1] else box.lo[1],
            if (i & 4 != 0) box.hi[2] else box.lo[2],
        };
        var c: [4]f32 = undefined;
        for (0..4) |r| c[r] = mvp[r] * p[0] + mvp[4 + r] * p[1] + mvp[8 + r] * p[2] + mvp[12 + r];
        if (c[0] < -c[3]) out[0] += 1;
        if (c[0] > c[3]) out[1] += 1;
        if (c[1] < -c[3]) out[2] += 1;
        if (c[1] > c[3]) out[3] += 1;
        if (c[2] < 0) out[4] += 1;
        if (c[2] > c[3]) out[5] += 1;
    }
    for (out) |n| if (n == 8) return false;
    return true;
}

/// The squared distance from (px, py) to the segment from a to b.
fn segmentDistance2(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const l2 = dx * dx + dy * dy;
    const t = if (l2 > 0) std.math.clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1) else 0;
    const ex = ax + t * dx - px;
    const ey = ay + t * dy - py;
    return ex * ex + ey * ey;
}

/// Parses "#rrggbb".
fn parseColor(text: []const u8) ?[3]u8 {
    if (text.len != 7 or text[0] != '#') return null;
    var out: [3]u8 = undefined;
    for (0..3) |k| out[k] = std.fmt.parseInt(u8, text[1 + 2 * k .. 3 + 2 * k], 16) catch return null;
    return out;
}

// ---- matrices, column-major ----

/// The parts of a bed model higher than this (mm) are see-through: a
/// frame or a back plate must not hide the print.
const bed_clear_z: f32 = 3;

fn translation(x: f32, y: f32, z: f32) [16]f32 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 };
}

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

/// The distance from (px, py) to the segment a-b, pixels.
fn segDist(px: f32, py: f32, a: [2]f32, b: [2]f32) f32 {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const l2 = ex * ex + ey * ey;
    const t = if (l2 > 0) std.math.clamp(((px - a[0]) * ex + (py - a[1]) * ey) / l2, 0, 1) else 0;
    const dx = a[0] + ex * t - px;
    const dy = a[1] + ey * t - py;
    return @sqrt(dx * dx + dy * dy);
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
    defer v.bead_start.deinit(gpa);
    defer v.bead_fan.deinit(gpa);
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
    // Over the top: the tilt stops at the limit, and the camera stays
    // upright.
    v.setAngles(0, 0);
    v.orbit(0, 250);
    const cam = v.camera();
    try std.testing.expect(cam.u[2] > 0);
    try std.testing.expectApproxEqAbs(@sin(@as(f32, View.max_pitch)), cam.eye[2] / 10, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dot(cam.s, cam.s), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dot(cam.s, cam.u), 1e-5);
    // Under the bed: the same limit.
    v.orbit(0, -1000);
    try std.testing.expectApproxEqAbs(-@sin(@as(f32, View.max_pitch)), v.camera().eye[2] / 10, 1e-3);
    // An orbit removes a roll that a free rotation made.
    v.setAngles(0, 0.5);
    v.rotate(0, 120);
    v.rotate(120, 0);
    v.orbit(1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.camera().s[2], 1e-4);
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

/// A view with no renderer, for the tests of the 2D calls and the pick
/// index: rows of beads along x, `per_layer` paths on each of `layers`
/// layers, each path `segs` beads long. Path p of a layer is at y = p, and
/// its feature is p % 3.
fn testScene(layers: usize, per_layer: usize, segs: usize) Error!View {
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100 };
    errdefer destroyTest(&v);
    var t: f32 = 0;
    for (0..layers) |l| {
        for (0..per_layer) |p| {
            v.path_start.append(View.gpa, @intCast(v.beads.items.len)) catch return error.OutOfMemory;
            for (0..segs) |k| {
                const x: f32 = @floatFromInt(k);
                const y: f32 = @floatFromInt(p);
                const z: f32 = 0.2 * @as(f32, @floatFromInt(l + 1));
                v.beads.append(View.gpa, .{ .ax = x, .ay = y, .bx = x + 1, .by = y, .z = z, .h = 0.2, .w = 0.4, .rgba = .{ 0, 0, 0, @intCast(p % 3) } }) catch return error.OutOfMemory;
                t += 1;
                v.bead_end.append(View.gpa, t) catch return error.OutOfMemory;
            }
        }
        v.layer_end.append(View.gpa, @intCast(v.beads.items.len)) catch return error.OutOfMemory;
        v.layer_path_end.append(View.gpa, @intCast(v.path_start.items.len)) catch return error.OutOfMemory;
    }
    v.path_start.append(View.gpa, @intCast(v.beads.items.len)) catch return error.OutOfMemory;
    try v.buildPickIndex();
    v.layer = layers - 1;
    return v;
}

fn destroyTest(v: *View) void {
    const g = View.gpa;
    v.beads.deinit(g);
    v.layer_end.deinit(g);
    v.layer_path_end.deinit(g);
    v.path_start.deinit(g);
    v.bead_end.deinit(g);
    v.pick_runs.deinit(g);
    v.layer_boxes.deinit(g);
    v.draw_chunks.deinit(g);
    v.chunk_width.deinit(g);
    v.draws.deinit(g);
    v.path_part.deinit(g);
    v.preview_ranges.deinit(g);
    v.preview_draws.deinit(g);
    v.rest_draws.deinit(g);
}

test "a part preview draws the beads of the part apart, turned" {
    // 6 layers of 4 paths of 5 beads; the paths 1 and 2 of each layer are
    // part 1, the others part 0.
    var v = try testScene(6, 4, 5);
    defer destroyTest(&v);
    const paths = v.path_start.items.len - 1;
    for (0..paths) |p| try v.path_part.append(View.gpa, if (p % 4 == 1 or p % 4 == 2) 1 else 0);
    // A quarter turn about z through (1, 2, 0).
    const s = @sqrt(0.5);
    try v.setPartPreview(1, .{ 0, 0, s, s }, .{ 1, 2, 0 }, .{ 0, 0, 0 }, false);
    const pv = v.preview.?;
    try std.testing.expectEqual(@as(usize, 6), v.preview_ranges.items.len);
    // The matrix turns (2, 2, 0) to (1, 3, 0).
    const q = [3]f32{ pv.m[0] * 2 + pv.m[4] * 2 + pv.m[12], pv.m[1] * 2 + pv.m[5] * 2 + pv.m[13], pv.m[2] * 2 + pv.m[6] * 2 + pv.m[14] };
    try std.testing.expectApproxEqAbs(@as(f32, 1), q[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), q[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[2], 1e-5);
    // The eye in the frame of the beads turns back.
    const le = View.previewLocal(pv, .{ 1, 3, 5 });
    try std.testing.expectApproxEqAbs(@as(f32, 2), le[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), le[1], 1e-5);
    // The draws of the part and the rest cover each bead once.
    const n: u32 = @intCast(v.beads.items.len);
    const rest = try v.splitPreview(&.{.{ .first = 0, .count = n, .lod = 0 }}, le, 0, n);
    var seen = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(seen);
    @memset(seen, 0);
    for (rest) |d| for (d.first..d.first + d.count) |i| {
        seen[i] += 1;
    };
    for (v.preview_draws.items) |d| for (d.first..d.first + d.count) |i| {
        seen[i] += 1;
    };
    for (seen) |k| try std.testing.expectEqual(@as(u8, 1), k);
    // On the bed: the lowest bead goes to z 0 after a half turn about x.
    try v.setPartPreview(1, .{ 1, 0, 0, 0 }, .{ 0, 0, 3 }, .{ 0, 0, 0 }, true);
    try std.testing.expect(v.preview.?.move[2] != 0);
    v.clearPreview();
    try std.testing.expect(v.preview == null);
}

test "the pick index finds the same bead as a test of each bead" {
    var v = try testScene(12, 9, 70);
    defer destroyTest(&v);
    v.target = .{ 35, 4, 1 };
    v.extent = 80;
    v.dist = 60;
    var hits: usize = 0;
    for ([_][2]f32{ .{ 0.3, 0.9 }, .{ -1.2, 0.4 }, .{ 2.5, 1.3 }, .{ 0.0, -0.2 } }) |ang| {
        v.setAngles(ang[0], ang[1]);
        var y: f32 = 0;
        while (y < 100) : (y += 7) {
            var x: f32 = 0;
            while (x < 100) : (x += 7) {
                for ([_]usize{ 0, 5 }) |lo| {
                    v.layer_lo = lo;
                    const fast = v.rayHit(x, y, 1);
                    // The same test with no index.
                    const runs = v.layer_boxes;
                    v.layer_boxes = .empty;
                    const slow = v.rayHit(x, y, 1);
                    v.layer_boxes = runs;
                    try std.testing.expectEqual(slow == null, fast == null);
                    if (fast) |f| {
                        try std.testing.expectEqual(slow.?.bead, f.bead);
                        hits += 1;
                    }
                }
            }
        }
    }
    try std.testing.expect(hits > 50);
}

test "the 2D calls: the beads of a layer, a pick in mm, and the layer of a path" {
    var v = try testScene(3, 4, 5);
    defer destroyTest(&v);
    try std.testing.expectEqual([2]u32{ 20, 40 }, v.layerBeads(1));
    try std.testing.expectEqual([2]u32{ 25, 30 }, v.pathBeads(5));
    try std.testing.expectEqual(@as(usize, 12), v.pathCount());
    try std.testing.expectEqual(@as(usize, 1), v.layerOfPath(5));
    try std.testing.expectEqual(@as(usize, 2), v.layerOfPath(8));
    // Layer 1, near the bead from x 2 to 3 of the path at y 2 (path 6).
    try std.testing.expectEqual(@as(?[2]usize, .{ 6, 2 }), v.pickLayer(1, 2.5, 2.1));
    // Far from all beads: nothing.
    try std.testing.expectEqual(@as(?[2]usize, null), v.pickLayer(1, 2.5, 9));
    const b = v.bounds().?;
    try std.testing.expect(b[0] < 0 and b[2] > 5 and b[1] < 0 and b[3] > 3);
}

test "the steps along the print go on to the next path, and pass paths with no segment" {
    var v = try testScene(2, 3, 4);
    defer destroyTest(&v);
    // Path 2 has no beads: the paths 1 and 3 have their ends next to it.
    const g = View.gpa;
    var beads: std.ArrayList(vk.Instance) = .empty;
    defer beads.deinit(g);
    try beads.appendSlice(g, v.beads.items[0..8]);
    try beads.appendSlice(g, v.beads.items[12..]);
    v.beads.clearRetainingCapacity();
    try v.beads.appendSlice(g, beads.items);
    for (v.path_start.items[3..]) |*s| s.* -= 4;
    for (v.layer_end.items) |*e| e.* -= 4;
    v.bead_end.shrinkRetainingCapacity(v.beads.items.len);
    try std.testing.expectEqual(@as(usize, 0), v.segments(2));
    // On along path 0, then to path 1.
    var s = v.stepPath(0, 2, 1, false).?;
    try std.testing.expectEqual(@as(usize, 0), s.path);
    try std.testing.expectEqual(@as(?usize, 3), s.seg);
    s = v.stepPath(0, 3, 1, false).?;
    try std.testing.expectEqual(@as(usize, 1), s.path);
    try std.testing.expectEqual(@as(?usize, 0), s.seg);
    // From the end of path 1, over path 2, to path 3.
    s = v.stepPath(1, 3, 1, false).?;
    try std.testing.expectEqual(@as(usize, 3), s.path);
    try std.testing.expectEqual(@as(?usize, 0), s.seg);
    // Back from the start of path 3: the last segment of path 1.
    s = v.stepPath(3, 0, -1, false).?;
    try std.testing.expectEqual(@as(usize, 1), s.path);
    try std.testing.expectEqual(@as(?usize, 3), s.seg);
    // A whole path at a time.
    s = v.stepPath(1, null, 1, true).?;
    try std.testing.expectEqual(@as(usize, 3), s.path);
    try std.testing.expectEqual(@as(?usize, null), s.seg);
    // The ends of the print.
    try std.testing.expect(v.stepPath(0, 0, -1, false) == null);
    try std.testing.expect(v.stepPath(5, 3, 1, false) == null);
}

test "the nearest path on another layer, and the segment at a time" {
    var v = try testScene(3, 4, 5);
    defer destroyTest(&v);
    // Path 5 (layer 1, y 1): on layer 2, path 9 (y 1, the same feature).
    try std.testing.expectEqual(@as(?usize, 9), v.nearestOnLayer(5, 2));
    try std.testing.expectEqual(@as(?usize, 1), v.nearestOnLayer(5, 0));
    // Bead i ends at time i + 1: time 12.5 is in bead 12, path 2,
    // segment 2.
    try std.testing.expectEqual(@as(?[2]usize, .{ 2, 2 }), v.segmentAtTime(12.5));
    try std.testing.expectEqual(@as(f32, 13), v.segmentEndTime(2, 2));
    try std.testing.expectEqual(@as(?[2]usize, .{ 11, 4 }), v.segmentAtTime(1e9));
}

test "the draw list leaves out the chunks out of the view, and draws far beads coarse" {
    if (frame_backend) return error.SkipZigTest;
    // 40 layers of 30 paths of 20 beads: 24000 beads, several chunks.
    var v = try testScene(40, 30, 20);
    // A backend that draws ribbons (they are off by default).
    v.ribbons = true;
    defer destroyTest(&v);
    v.height = 800;
    v.width = 800;
    const n: u32 = @intCast(v.beads.items.len);
    const Case = struct { target: [3]f32, dist: f32, yaw: f32 };
    const frame = struct {
        fn list(view: *View, c: Case) ![]const Draw {
            view.target = c.target;
            view.dist = c.dist;
            view.setAngles(c.yaw, 0.5);
            const cam = view.camera();
            const proj = perspective(fov, 1, 0.1, 1000);
            const mvp = mul(proj, lookAt(cam.eye, view.target, cam.u));
            return view.drawList(mvp, cam.eye, 0, @intCast(view.beads.items.len));
        }
    };
    // From far away: all beads, as ribbons, in one range.
    var d = try frame.list(&v, .{ .target = .{ 10, 15, 4 }, .dist = 400, .yaw = 0.3 });
    try std.testing.expectEqual(@as(usize, 1), d.len);
    try std.testing.expectEqual(Draw{ .first = 0, .count = n, .lod = 2 }, d[0]);
    // A backend with no ribbons: the coarse mesh.
    v.ribbons = false;
    d = try frame.list(&v, .{ .target = .{ 10, 15, 4 }, .dist = 400, .yaw = 0.3 });
    try std.testing.expectEqual(Draw{ .first = 0, .count = n, .lod = 1 }, d[0]);
    v.ribbons = true;
    // Close: full beads, and the chunks behind the eye are left out.
    d = try frame.list(&v, .{ .target = .{ 10, 15, 4 }, .dist = 3, .yaw = 0.3 });
    var drawn: u32 = 0;
    for (d) |x| {
        drawn += x.count;
        try std.testing.expectEqual(@as(u32, 0), x.lod);
    }
    try std.testing.expect(drawn > 0 and drawn <= n);
    // Looking away from the part: nothing.
    d = try frame.list(&v, .{ .target = .{ 500, 500, 4 }, .dist = 3, .yaw = 0.3 });
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "a point on the ray of a pixel shows at that pixel" {
    var v: View = .{ .renderer = undefined, .width = 800, .height = 600 };
    v.target = .{ 10, 20, 5 };
    v.dist = 120;
    v.setAngles(0.7, 0.5);
    const cam = v.camera();
    for ([_][2]f32{ .{ 400, 300 }, .{ 13, 590 }, .{ 777, 41 } }) |px| {
        const dir = v.pixelRay(cam, px[0], px[1]);
        const p = [3]f32{ cam.eye[0] + dir[0] * 50, cam.eye[1] + dir[1] * 50, cam.eye[2] + dir[2] * 50 };
        const q = v.pixelOf(p).?;
        try std.testing.expectApproxEqAbs(px[0], q[0], 0.01);
        try std.testing.expectApproxEqAbs(px[1], q[1], 0.01);
    }
}

test {
    _ = plates_mod;
}

test "the plates of a row: offsets, the active plate, the pick, and the frame" {
    var v: View = .{ .renderer = undefined, .width = 800, .height = 600, .headless = true };
    defer v.deinitData();
    try v.setPlates(&.{ .{ 200, 200 }, .{ 300, 250 }, .{ 200, 200 } }, 0);
    // The gap is 15 % of the widest bed: 45 mm.
    try std.testing.expectEqual([2]f32{ 245, 0 }, v.plateOffset(1));
    try std.testing.expectEqual([2]f32{ 590, 0 }, v.plateOffset(2));
    // The camera looks at the middle of plate 1 from above.
    v.target = .{ 245 + 150, 125, 0 };
    v.setAngles(-std.math.pi / 2.0, 1.4);
    v.dist = 400;
    try std.testing.expectEqual(@as(?usize, 1), v.plateAt(400, 300));
    // Plate 1 active: the world moves, and the camera with it.
    try v.setPlates(&.{ .{ 200, 200 }, .{ 300, 250 }, .{ 200, 200 } }, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 150), v.target[0], 1e-4);
    try std.testing.expectEqual([2]f32{ -245, 0 }, v.plateOffset(0));
    try std.testing.expectEqual(@as(?usize, 1), v.plateAt(400, 300));
    // The frame of plate 2: the goal looks at its middle, and all its
    // corners are in the view.
    v.framePlate(2);
    const g = v.goal.?;
    try std.testing.expectApproxEqAbs(@as(f32, 345 + 100), g.target[0], 1e-3);
    v.setPose(g);
    for ([_][2]f32{ .{ 345, 0 }, .{ 545, 0 }, .{ 345, 200 }, .{ 545, 200 } }) |c| {
        const q = v.pixelOf(.{ c[0], c[1], 0 }).?;
        try std.testing.expect(q[0] >= 0 and q[0] <= 800 and q[1] >= 0 and q[1] <= 600);
    }
    try std.testing.expectEqual(@as(?usize, 2), v.plateAt(400, 300));
}

test "a support area draws its outline, its points, and lines across it" {
    const gpa = View.gpa;
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100 };
    defer {
        v.sup_pts.deinit(gpa);
        v.sup_areas.deinit(gpa);
    }
    v.dist = 100;
    const sq = [_][3]f32{ .{ 0, 0, 10 }, .{ 20, 0, 10 }, .{ 20, 20, 10 }, .{ 0, 20, 10 } };
    var out: [512]vk.Instance = undefined;
    // An open path: 3 edges and 4 points (2 beads each), no fill.
    try v.addSupportArea(&sq, 0, 0);
    var n: usize = 0;
    v.supportAreaBeads(&out, &n);
    try std.testing.expectEqual(@as(usize, 3 + 8), n);
    // Closed: 4 edges and 8 lines across (one bead each, the area is level).
    v.clearSupportAreas();
    try v.addSupportArea(&sq, 3, SupportArea.closed);
    n = 0;
    v.supportAreaBeads(&out, &n);
    try std.testing.expectEqual(@as(usize, 8 + 4), n);
    // Each bead has its middle a little over the surface, toward the
    // camera.
    const lift = std.math.clamp(v.dist * 0.003, 0.12, 2);
    const up: f32 = if (v.camera().eye[2] < 10) -lift else lift;
    for (out[0..n]) |b| try std.testing.expectApproxEqAbs(10 + up, b.z - b.h / 2, 1e-4);
}

test "a print view: the beads of a G-code file, the position, and the scrubber" {
    const text =
        \\M83
        \\;LAYER:0
        \\G1 Z0.2 F600
        \\G0 X10 Y10 F6000
        \\;TYPE:WALL-OUTER
        \\G1 X20 Y10 E0.5 F1200
        \\G1 X20 Y20 E0.5
        \\;LAYER:1
        \\G1 Z0.4
        \\;TYPE:FILL
        \\G1 X10 Y20 E0.5 F3000
        \\G0 X30 Y30
        \\G1 X40 Y30 E0.5
        \\
    ;
    var r = try gcode_read.Reader.parse(std.testing.allocator, text);
    defer r.deinit();
    var v: View = .{ .renderer = undefined, .width = 100, .height = 100, .headless = true };
    defer v.deinitData();
    try v.loadGcode(&r, .{ 200, 200 });
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, v.layer_end.items);
    try std.testing.expectEqual([2]f32{ 200, 200 }, v.bed);
    try std.testing.expectEqual(@as(usize, 1), v.layer);
    // Whole layers: the top layer is lit.
    try std.testing.expectEqual([2]u32{ 2, 4 }, v.gcodeCount());
    // At the end of the second line of layer 1: 3 beads, layer 1 lit.
    const at = std.mem.indexOf(u8, text, "G1 X10 Y20").? + "G1 X10 Y20 E0.5 F3000\n".len;
    v.setPosition(at);
    try std.testing.expectEqual(@as(usize, 1), v.layer);
    try std.testing.expectEqual([2]u32{ 2, 3 }, v.gcodeCount());
    // In layer 0: its first bead.
    v.setPosition(std.mem.indexOf(u8, text, "G1 X20 Y20").?);
    try std.testing.expectEqual(@as(usize, 0), v.layer);
    try std.testing.expectEqual([2]u32{ 0, 1 }, v.gcodeCount());
    // The scrubber ends the position.
    v.setLayer(0);
    try std.testing.expectEqual(@as(?u64, null), v.position);
    try std.testing.expectEqual([2]u32{ 0, 2 }, v.gcodeCount());
    // No pick in a print view (no copy of the beads).
    try std.testing.expectEqual(@as(?usize, null), v.pick(50, 50));
}

test "touch: one finger orbits, two fingers pinch and pan" {
    var v: View = .{ .renderer = undefined, .width = 400, .height = 300, .headless = true };
    defer v.deinitData();
    v.reset();
    const rot0 = v.rot;
    v.touch(1, .down, 100, 100);
    v.touch(1, .move, 140, 100);
    try std.testing.expect(qangle(rot0, v.rot) > 0.1);
    v.touch(1, .up, 140, 100);
    // Two fingers spread apart: the camera comes nearer.
    const d0 = v.dist;
    v.touch(1, .down, 150, 150);
    v.touch(2, .down, 250, 150);
    v.touch(2, .move, 350, 150);
    try std.testing.expect(v.dist < d0 * 0.8);
    // Both move up together: a pan moves the target.
    const t0 = v.target;
    v.touch(1, .move, 150, 100);
    v.touch(2, .move, 350, 100);
    try std.testing.expect(@abs(v.target[2] - t0[2]) > 1e-3);
    // A third finger has no effect; a cancel ends all.
    const rot1 = v.rot;
    v.touch(3, .down, 10, 10);
    v.touch(3, .move, 90, 10);
    try std.testing.expectEqual(rot1, v.rot);
    v.touch(0, .cancel, 0, 0);
    try std.testing.expectEqual(@as(i64, -1), v.touches[0].id);
}
