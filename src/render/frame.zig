//! The data that the view (view.zig) gives to a backend for each frame:
//! the bead instances, the push constants, and the frame description. The
//! backends (vk.zig for Vulkan, web.zig for WebGL in a browser) share these
//! types, so the view code is the same for all of them.

const std = @import("std");

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

/// A range of beads to draw with one mesh: the full bead mesh (lod 0), or
/// a coarser mesh for a bead far from the camera (lod 1). See
/// View.drawList.
pub const Draw = extern struct { first: u32, count: u32, lod: u32 };

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
    /// The beads box_first .. box_count in ranges, with the boxes out of
    /// the view left out and a coarse mesh far from the camera. Empty: draw
    /// all of them with the full mesh. The web backend uses it.
    draws: []const Draw = &.{},
};
