//! The frame backend of the renderer, for the wasm build and for macOS.
//!
//! A browser draws with WebGL in JavaScript, and wasm code cannot call the
//! GPU directly. So this backend does not draw: it keeps the data of the
//! scene and of the last frame in memory, and the shell reads them and
//! draws them. The web app draws with WebGL2 (web/app/gl.js). The macOS
//! app draws with Metal (macos/Sources/ZSlice/Render). The scene logic
//! (the beads, the camera, the replay) stays in view.zig, the same as for
//! the Vulkan backend.
//!
//! The shell reads `WebFrame` (see zs_view_web_frame in
//! include/zslice-app.h) after each zs_view_draw. A buffer goes to the GPU
//! again only when its generation number changes.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch.isWasm();
const frame_mod = @import("frame.zig");

pub const Instance = frame_mod.Instance;
pub const max_extras = frame_mod.max_extras;
pub const Push = frame_mod.Push;
pub const Draw = frame_mod.Draw;
pub const PlateFrame = frame_mod.PlateFrame;
const BedVertex = @import("../bed.zig").Vertex;
const BedImage = @import("../bed.zig").Image;

pub const Error = error{OutOfMemory};

/// A frame view has no native surface: the shell draws the frame data.
pub const Surface = union(enum) { web };

/// The data of the scene and of the last frame, for the JavaScript side.
/// The layout is zs_web_frame in include/zslice-app.h: a usize field is a
/// pointer there. In wasm32 all fields are 4 bytes wide.
pub const WebFrame = extern struct {
    /// The push constants of the beads and of the grid.
    box: Push,
    grid: Push,
    clear: [4]f32,
    /// The beads to draw (box_first .. box_count), and the marks.
    box_first: u32 = 0,
    box_count: u32 = 0,
    mark_first: u32 = 0,
    mark_count: u32 = 0,
    /// The beads to draw after all others, and the toolhead of a replay.
    extras: usize = 0,
    extras_count: u32 = 0,
    head: usize = 0,
    head_count: u32 = 0,
    /// The instances: the beads, then the marks.
    instances: usize = 0,
    instance_count: u32 = 0,
    instances_gen: u32 = 0,
    /// The bead mesh template: vec4 vertices and u16 indices.
    mesh_verts: usize = 0,
    mesh_vert_count: u32 = 0,
    mesh_index: usize = 0,
    mesh_index_count: u32 = 0,
    mesh_gen: u32 = 0,
    /// The grid lines: vec3 points, two for each line.
    grid_points: usize = 0,
    grid_vertices: u32 = 0,
    grid_gen: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// The ranges of beads to draw (frame_mod.Draw), and the meshes of
    /// their levels of detail: the full mesh is indices 0 ..
    /// mesh_full_count; level k (1 or 2) is mesh_lod_first[k - 1] .. +
    /// mesh_lod_count[k - 1] (count 0 if there is none).
    draws: usize = 0,
    draws_count: u32 = 0,
    mesh_full_count: u32 = 0,
    mesh_lod_first: [2]u32 = .{ 0, 0 },
    mesh_lod_count: [2]u32 = .{ 0, 0 },
    /// The bed model (see bed.zig): its push constants, its vertices (8
    /// floats each: position, normal, uv), and its RGBA texture (width 0:
    /// none). bed_vertices is 0 when the frame has no bed.
    bed: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } },
    bed_verts: usize = 0,
    bed_vertex_count: u32 = 0,
    bed_vertices: u32 = 0,
    bed_gen: u32 = 0,
    bed_tex: usize = 0,
    bed_tex_width: u32 = 0,
    bed_tex_height: u32 = 0,
    /// The other plates of the set (PlateFrame, zs_web_plate), and their
    /// draws (frame_mod.Draw).
    plates: usize = 0,
    plates_count: u32 = 0,
    plate_draws: usize = 0,
    plate_draws_count: u32 = 0,
    /// The grid lines of the other plates (vec3 points, two for each
    /// line): the vertices before plate_grid_dim are the plates that
    /// slice, the others the plates that cannot slice (a lighter color).
    plate_grid: usize = 0,
    plate_grid_vertices: u32 = 0,
    plate_grid_dim: u32 = 0,
    plate_grid_gen: u32 = 0,
    /// A part that turns in the view only (frame_mod.Frame.part): its push
    /// data, and its draws in the bead buffer. draws leaves them out.
    part: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } },
    part_draws: usize = 0,
    part_draws_count: u32 = 0,
};

comptime {
    // web/app/view.js reads the plates at this stride.
    if (is_wasm) std.debug.assert(@sizeOf(PlateFrame) == 160);
}

pub const Renderer = struct {
    out: WebFrame,
    verts: std.ArrayList([4]f32) = .empty,
    index: std.ArrayList(u16) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    grid: std.ArrayList(f32) = .empty,
    bed_verts: std.ArrayList(BedVertex) = .empty,
    bed_tex: std.ArrayList(u8) = .empty,

    const gpa = if (!is_wasm) std.heap.c_allocator else if (@import("../parallel.zig").wasm_pool) @import("../wasm_heap.zig").allocator else std.heap.wasm_allocator;

    pub fn init(surface: Surface, width: u32, height: u32) Error!*Renderer {
        _ = surface;
        const r = gpa.create(Renderer) catch return error.OutOfMemory;
        r.* = .{ .out = std.mem.zeroInit(WebFrame, .{ .width = width, .height = height }) };
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        r.verts.deinit(gpa);
        r.index.deinit(gpa);
        r.instances.deinit(gpa);
        r.grid.deinit(gpa);
        r.bed_verts.deinit(gpa);
        r.bed_tex.deinit(gpa);
        gpa.destroy(r);
    }

    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        r.out.width = width;
        r.out.height = height;
    }

    pub fn setMesh(r: *Renderer, verts: []const [4]f32, indices: []const u16) Error!void {
        r.verts.clearRetainingCapacity();
        r.verts.appendSlice(gpa, verts) catch return error.OutOfMemory;
        r.index.clearRetainingCapacity();
        r.index.appendSlice(gpa, indices) catch return error.OutOfMemory;
        r.out.mesh_verts = @intFromPtr(r.verts.items.ptr);
        r.out.mesh_vert_count = @intCast(verts.len);
        r.out.mesh_index = @intFromPtr(r.index.items.ptr);
        r.out.mesh_index_count = @intCast(indices.len);
        r.out.mesh_full_count = @intCast(indices.len);
        r.out.mesh_lod_count = .{ 0, 0 };
        r.out.mesh_gen +%= 1;
    }

    /// A coarser mesh of a bead (level 1 or 2) for a bead far from the
    /// camera, after the full mesh in the same buffers (call it after
    /// setMesh).
    pub fn setLodMesh(r: *Renderer, level: usize, verts: []const [4]f32, indices: []const u16) Error!void {
        const base: u16 = @intCast(r.verts.items.len);
        r.verts.appendSlice(gpa, verts) catch return error.OutOfMemory;
        const first: u32 = @intCast(r.index.items.len);
        r.index.ensureUnusedCapacity(gpa, indices.len) catch return error.OutOfMemory;
        for (indices) |i| r.index.appendAssumeCapacity(base + i);
        r.out.mesh_verts = @intFromPtr(r.verts.items.ptr);
        r.out.mesh_vert_count = @intCast(r.verts.items.len);
        r.out.mesh_index = @intFromPtr(r.index.items.ptr);
        r.out.mesh_index_count = @intCast(r.index.items.len);
        r.out.mesh_lod_first[level - 1] = first;
        r.out.mesh_lod_count[level - 1] = @intCast(indices.len);
        r.out.mesh_gen +%= 1;
    }

    /// The beads, then the marks, in one buffer: Frame.mark_first is
    /// beads.len.
    pub fn setInstances(r: *Renderer, items: []const Instance, marks: []const Instance) Error!void {
        r.instances.clearRetainingCapacity();
        r.instances.ensureTotalCapacity(gpa, items.len + marks.len) catch return error.OutOfMemory;
        r.instances.appendSliceAssumeCapacity(items);
        r.instances.appendSliceAssumeCapacity(marks);
        r.out.instances = @intFromPtr(r.instances.items.ptr);
        r.out.instance_count = @intCast(r.instances.items.len);
        r.out.instances_gen +%= 1;
    }

    /// The instance buffer for `n` beads, for the caller to fill in place.
    /// The marks are none.
    pub fn instanceBuffer(r: *Renderer, n: usize) Error![]Instance {
        r.instances.resize(gpa, n) catch return error.OutOfMemory;
        r.out.instances = @intFromPtr(r.instances.items.ptr);
        r.out.instance_count = @intCast(n);
        r.out.instances_gen +%= 1;
        return r.instances.items;
    }

    pub fn setGrid(r: *Renderer, points: []const f32) Error!void {
        r.grid.clearRetainingCapacity();
        r.grid.appendSlice(gpa, points) catch return error.OutOfMemory;
        r.out.grid_points = @intFromPtr(r.grid.items.ptr);
        r.out.grid_vertices = @intCast(points.len / 3);
        r.out.grid_gen +%= 1;
    }

    /// The bed model: the shell uploads it once for each generation.
    pub fn setBed(r: *Renderer, verts: []const BedVertex, image: ?BedImage) Error!void {
        r.bed_verts.clearRetainingCapacity();
        r.bed_verts.appendSlice(gpa, verts) catch return error.OutOfMemory;
        r.bed_tex.clearRetainingCapacity();
        r.out.bed_tex_width = 0;
        r.out.bed_tex_height = 0;
        if (image) |img| {
            r.bed_tex.appendSlice(gpa, img.rgba[0 .. @as(usize, img.width) * img.height * 4]) catch return error.OutOfMemory;
            r.out.bed_tex_width = img.width;
            r.out.bed_tex_height = img.height;
        }
        r.out.bed_verts = @intFromPtr(r.bed_verts.items.ptr);
        r.out.bed_vertex_count = @intCast(verts.len);
        r.out.bed_tex = @intFromPtr(r.bed_tex.items.ptr);
        r.out.bed_gen +%= 1;
    }

    /// Keeps the frame for the shell. The extras and the head
    /// point into buffers of the view that live as long as the view.
    pub fn draw(r: *Renderer, frame: frame_mod.Frame) Error!void {
        const o = &r.out;
        o.box = frame.box;
        o.grid = frame.grid;
        o.clear = .{ frame.clear[0], frame.clear[1], frame.clear[2], 1 };
        o.box_first = frame.box_first;
        o.box_count = frame.box_count;
        o.mark_first = frame.mark_first;
        o.mark_count = frame.mark_count;
        const extras = frame.extras[0..@min(frame.extras.len, max_extras)];
        o.extras = @intFromPtr(extras.ptr);
        o.extras_count = @intCast(extras.len);
        const head = frame.head[0..@min(frame.head.len, max_extras - extras.len)];
        o.head = @intFromPtr(head.ptr);
        o.head_count = @intCast(head.len);
        o.grid_vertices = frame.grid_vertices;
        o.bed = frame.bed;
        o.bed_vertices = @min(frame.bed_vertices, o.bed_vertex_count);
        o.draws = @intFromPtr(frame.draws.ptr);
        o.draws_count = @intCast(frame.draws.len);
        o.plates = @intFromPtr(frame.plates.ptr);
        o.plates_count = @intCast(frame.plates.len);
        o.plate_draws = @intFromPtr(frame.plate_draws.ptr);
        o.plate_draws_count = @intCast(frame.plate_draws.len);
        o.plate_grid = @intFromPtr(frame.plate_grid.ptr);
        o.plate_grid_vertices = @intCast(frame.plate_grid.len / 3);
        o.plate_grid_dim = frame.plate_grid_dim;
        o.plate_grid_gen = frame.plate_grid_gen;
        o.part = frame.part;
        o.part_draws = @intFromPtr(frame.part_draws.ptr);
        o.part_draws_count = @intCast(frame.part_draws.len);
    }
};
