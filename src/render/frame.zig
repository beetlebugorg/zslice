//! The data that the view (view.zig) gives to a backend for each frame:
//! the bead instances, the push constants, and the frame description. The
//! backends (vk.zig for Vulkan, web.zig for a shell that draws) share these
//! types, so the view code is the same for all of them.

const std = @import("std");
const BedVertex = @import("../bed.zig").Vertex;

/// One toolpath segment, drawn as one bead. The layout matches the
/// per-instance attributes of shaders/box.vert.
pub const Instance = extern struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    z: f32,
    h: f32,
    w: f32,
    rgba: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 32);
}

/// The spare instance slots for Frame.extras.
pub const max_extras = 4096;

/// The push constants of both pipelines: a matrix and three vectors. For
/// the beads: the light direction, the camera position, and the highlight
/// range. For the grid: the color. 112 bytes: within the 128 bytes that
/// each device supports.
pub const Push = extern struct {
    mvp: [16]f32,
    vec: [4]f32,
    eye: [4]f32 = .{ 0, 0, 0, 0 },
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

/// A range of beads to draw with one mesh: the full bead mesh (lod 0), a
/// coarser mesh for a bead far from the camera (lod 1), or a ribbon that
/// faces the camera for a bead a few pixels wide (lod 2). See
/// View.drawList.
pub const Draw = extern struct { first: u32, count: u32, lod: u32 };

/// One plate of a frame other than the active plate (see plates.zig), or
/// the light beads of the active plate: its bead buffer, its matrices, and
/// its draws in Frame.plate_draws. The layout is zs_web_plate in
/// include/zslice-app.h. The Vulkan backend draws the other plates only
/// (it draws the active plate with its full beads).
pub const PlateFrame = extern struct {
    /// The matrix of the beads and of the bed model, with the place of the
    /// plate in the row.
    mvp: [16]f32,
    bed_mvp: [16]f32,
    /// The bead buffer of the plate (a pointer), its size, and its
    /// generation: upload it again when the generation changes.
    instances: usize,
    instance_count: u32,
    gen: u32,
    draws_first: u32,
    draws_count: u32,
    /// How much the colors fade to the background (0: not at all): a plate
    /// whose slice is old.
    fade: f32,
    flags: u32,
    /// The buffer slot of the plate (its index in the set).
    slot: u32,

    /// Draw the bed model of the view at the plate.
    pub const flag_bed: u32 = 1;
    /// The light beads of the active plate: draw them with Frame.box.
    pub const flag_active: u32 = 2;
    /// The light beads of the active plate while its one part moves in
    /// the view only (a hold, a fall, a turn): draw them with Frame.part.
    pub const flag_part: u32 = 4;
};

pub const Frame = struct {
    clear: [3]f32,
    box: Push,
    box_count: u32,
    /// The beads before this one do not show (the bottom of a layer
    /// range): the draw is of beads box_first .. box_count.
    box_first: u32 = 0,
    /// The marks to draw: instances mark_first .. mark_first + mark_count.
    mark_first: u32 = 0,
    mark_count: u32 = 0,
    /// Beads drawn after all others, written each frame into spare slots
    /// (at most max_extras): the bead that the replay is printing, and the
    /// frame of a selected part.
    extras: []const Instance = &.{},
    /// The toolhead of a replay: drawn last, lit and see-through (the
    /// print shows through it). In the spare slots after `extras`.
    head: []const Instance = &.{},
    grid: Push,
    grid_vertices: u32,
    /// The bed model (see bed.zig and shaders/bed.vert): the vertices that
    /// the backend has from `setBed`, drawn after the beads. 0: none.
    bed: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } },
    bed_vertices: u32 = 0,
    /// The signs of the plates (see View.setSigns): their triangles in
    /// the world of the view, and their push data (the matrix). The
    /// normal of a vertex has the alpha of its sign in x. Drawn after
    /// the bed with the image of the signs, blended, with no depth write.
    sign: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } },
    signs: []const BedVertex = &.{},
    /// The decals of the labels (see View.addLabel): their fill, in the
    /// world of the view (the push data of `sign`). The normal of a vertex
    /// has its color, and uv.x its alpha. The fill changes with
    /// `decal_gen`; the outlines of the selected labels (`decal_edges`)
    /// change with each frame. Drawn after the beads and the bed, blended,
    /// with the depth test and no depth write.
    decals: []const BedVertex = &.{},
    decal_gen: u32 = 0,
    decal_edges: []const BedVertex = &.{},
    /// The beads box_first .. box_count in ranges, with the boxes out of
    /// the view left out and a coarse mesh far from the camera. The frame
    /// backend uses it: an empty list there is no bead in the view. The
    /// Vulkan backend draws box_first .. box_count.
    draws: []const Draw = &.{},
    /// The Vulkan backend draws `draws` (and no other beads) when this is
    /// true. A print view has no draw list.
    culled: bool = false,
    /// A part that turns in the view only (View.setPartPreview): its
    /// beads, with this push data (the matrix of the turn, and the eye and
    /// the light in the frame of the beads). `draws` leaves them out.
    part: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } },
    part_draws: []const Draw = &.{},
    /// The other plates (see PlateFrame), and their draws.
    plates: []const PlateFrame = &.{},
    plate_draws: []const Draw = &.{},
    /// The grid lines of the other plates (x, y, z points): the plates up
    /// to vertex `plate_grid_dim`, then the plates that cannot slice.
    plate_grid: []const f32 = &.{},
    plate_grid_dim: u32 = 0,
    plate_grid_gen: u32 = 0,
    /// A print view that draws offscreen keeps the finished layers in a
    /// cached image: the beads box_first .. base_end, drawn with `base`.
    /// A frame adds the beads after the cached ones, and draws the rest
    /// (base_end .. box_count, the extras, the toolhead) over a copy of
    /// the cache. See vk.zig.
    cached: bool = false,
    base_end: u32 = 0,
    base: Push = .{ .mvp = @splat(0), .vec = .{ 0, 0, 0, 0 } },
};
