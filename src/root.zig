//! zslice: a slicer for FDM 3D printers.
//!
//! The pipeline, in order (each module explains its stage):
//!
//! - `mesh`: load the STL file and weld the vertices.
//! - `slicer`: cut the mesh into one outline for each layer.
//! - `layer`: make walls, skin, and infill for each layer, and order them.
//! - `gcode`: write the printer commands.
//! - `engine`: run all stages on all threads, with low memory use.
//!
//! The 2D tools that the stages use: `geom` (points and polygons), `clip`
//! (polygon booleans), `offset` (polygon offset), and `infill` (line fill).
//!
//! Basic use:
//!
//!     var mesh = try zslice.Mesh.fromStl(gpa, stl_bytes);
//!     defer mesh.deinit(gpa);
//!     var settings: zslice.Settings = .{};
//!     try settings.set("project.wall_count", "3");
//!     const stats = try zslice.slice(gpa, &mesh, settings, writer);

pub const geom = @import("geom.zig");
pub const clip = @import("clip.zig");
pub const offset = @import("offset.zig");
pub const mesh = @import("mesh.zig");
pub const slicer = @import("slicer.zig");
pub const settings = @import("settings.zig");
pub const infill = @import("infill.zig");
pub const layer = @import("layer.zig");
pub const gcode = @import("gcode.zig");
pub const parallel = @import("parallel.zig");
pub const engine = @import("engine.zig");
pub const svg = @import("svg.zig");

pub const Mesh = mesh.Mesh;
pub const Settings = settings.Settings;
pub const Stats = engine.Stats;
pub const Job = engine.Job;
pub const slice = engine.slice;

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
}
