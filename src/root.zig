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
//! (polygon booleans), `offset` (polygon offset), `voronoi` (the Voronoi
//! diagram of segments), and `infill` (line fill). `arachne` makes the
//! variable-width walls.
//!
//! Basic use:
//!
//!     var mesh = try zslice.Mesh.fromStl(gpa, stl_bytes);
//!     defer mesh.deinit(gpa);
//!     var settings: zslice.Settings = .{};
//!     try settings.set("project.wall_count", "3");
//!     const stats = try zslice.slice(gpa, &mesh, settings, writer);

pub const geom = @import("geom.zig");
pub const flow = @import("flow.zig");
pub const clip = @import("clip.zig");
pub const clip_open = @import("clip_open.zig");
pub const offset = @import("offset.zig");
pub const voronoi = @import("voronoi.zig");
pub const arachne = @import("arachne.zig");
pub const mesh = @import("mesh.zig");
pub const plate = @import("plate.zig");
pub const zipfile = @import("zipfile.zig");
pub const threemf = @import("threemf.zig");
pub const orient = @import("orient.zig");
pub const slicer = @import("slicer.zig");
pub const settings = @import("settings.zig");
pub const infill = @import("infill.zig");
pub const lightning = @import("lightning.zig");
pub const layer = @import("layer.zig");
pub const slope = @import("slope.zig");
pub const gcode = @import("gcode.zig");
pub const motion = @import("motion.zig");
pub const parallel = @import("parallel.zig");
pub const scratch = @import("scratch.zig");
pub const engine = @import("engine.zig");
pub const svg = @import("svg.zig");
pub const support = @import("support.zig");
/// Expressions: the formulas of the settings (see expr.zig).
pub const expr = @import("expr.zig");
pub const gaps = @import("gaps.zig");
pub const gapfill = @import("gapfill.zig");
pub const islands = @import("islands.zig");
pub const toml = @import("toml.zig");
pub const profile = @import("profile.zig");
pub const import_cura = @import("import_cura.zig");
pub const part_settings = @import("part_settings.zig");
pub const app = @import("app.zig");

pub const Mesh = mesh.Mesh;
pub const Settings = settings.Settings;
pub const Stats = engine.Stats;
pub const Job = engine.Job;
pub const slice = engine.slice;

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
}
