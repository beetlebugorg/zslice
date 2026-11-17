//! The web backend of the renderer, for the wasm build.
//!
//! A browser draws with WebGL in JavaScript, and wasm code cannot call the
//! GPU directly. So this backend does not draw: it keeps the data of the
//! scene and of the last frame in wasm memory, and the JavaScript side
//! reads them and draws them with WebGL2 (web/app/gl.js). The scene logic
//! (the beads, the camera, the replay) stays in view.zig, the same as for
//! the native backends.
//!
//! The JavaScript side reads `WebFrame` (see zs_view_web_frame in
//! include/zslice-app.h) after each zs_view_draw. A buffer goes to the GPU
//! again only when its generation number changes.

const std = @import("std");
const frame_mod = @import("frame.zig");

pub const Instance = frame_mod.Instance;
pub const max_extras = frame_mod.max_extras;
pub const Push = frame_mod.Push;
pub const Draw = frame_mod.Draw;

pub const Error = error{OutOfMemory};

/// A web view has no native surface: the shell draws the frame data.
pub const Surface = union(enum) { web };

/// The data of the scene and of the last frame, for the JavaScript side.
/// All fields are 4 bytes wide (wasm32), in this order; the layout is in
/// include/zslice-app.h (zs_web_frame).
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
};

pub const Renderer = struct {
    out: WebFrame,
    verts: std.ArrayList([4]f32) = .empty,
    index: std.ArrayList(u16) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    grid: std.ArrayList(f32) = .empty,

    const gpa = std.heap.wasm_allocator;

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

    pub fn setGrid(r: *Renderer, points: []const f32) Error!void {
        r.grid.clearRetainingCapacity();
        r.grid.appendSlice(gpa, points) catch return error.OutOfMemory;
        r.out.grid_points = @intFromPtr(r.grid.items.ptr);
        r.out.grid_vertices = @intCast(points.len / 3);
        r.out.grid_gen +%= 1;
    }

    /// Keeps the frame for the JavaScript side. The extras and the head
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
        o.draws = @intFromPtr(frame.draws.ptr);
        o.draws_count = @intCast(frame.draws.len);
    }
};
