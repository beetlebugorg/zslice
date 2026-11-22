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
pub const step = @import("step.zig");
pub const cut = @import("cut.zig");
pub const bambu = @import("bambu.zig");
pub const mqtt = @import("mqtt.zig");
pub const rtsp = @import("rtsp.zig");
pub const cpu_render = @import("render/cpu.zig");
pub const plate = @import("plate.zig");
pub const zipfile = @import("zipfile.zig");
pub const threemf = @import("threemf.zig");
pub const orient = @import("orient.zig");
pub const physics = @import("physics.zig");
pub const bond = @import("bond.zig");
pub const support_pick = @import("support_pick.zig");
pub const rigid = @import("rigid.zig");
pub const print_sim = @import("print_sim.zig");
pub const gcode_sign = @import("gcode_sign.zig");
pub const open_link = @import("open_link.zig");
pub const model_import = @import("model_import.zig");
/// The reader of G-code files, for a view of a print that runs.
pub const gcode_read = @import("gcode_read.zig");
pub const gcode_meta = @import("gcode_meta.zig");
pub const slicer = @import("slicer.zig");
pub const settings = @import("settings.zig");
pub const infill = @import("infill.zig");
pub const lightning = @import("lightning.zig");
pub const layer = @import("layer.zig");
pub const slope = @import("slope.zig");
pub const gcode = @import("gcode.zig");
/// The prime tower: its shape and its lines (see tower.zig).
pub const tower = @import("tower.zig");
pub const stream = @import("stream.zig");
pub const gcode_vars = @import("gcode_vars.zig");
pub const filaments = @import("filaments.zig");
pub const paint = @import("paint.zig");
pub const paint_split = @import("paint_split.zig");
pub const field = @import("field.zig");
pub const dexel = @import("dexel.zig");
/// The paint of a selected body of a range of layers (see paint_body.zig).
pub const paint_body = @import("paint_body.zig");
/// The region of a selected body of a range of layers, as a modifier
/// volume (see body_region.zig).
pub const body_region = @import("body_region.zig");
/// The labels on the surface of a part (see label.zig), and the font of
/// their text.
pub const label = @import("label.zig");
/// The smart guides of the labels: the features of a face, and the snap
/// (see label_snap.zig).
pub const label_snap = @import("label_snap.zig");
/// The smart guides of a part that moves on the bed (see part_snap.zig).
pub const part_snap = @import("part_snap.zig");
pub const font = @import("font.zig");
pub const motion = @import("motion.zig");
pub const parallel = @import("parallel.zig");
pub const scratch = @import("scratch.zig");
/// The allocator of the wasm module with threads.
pub const wasm_heap = @import("wasm_heap.zig");
pub const engine = @import("engine.zig");
pub const plate_job = @import("plate_job.zig");
pub const svg = @import("svg.zig");
/// The filled shapes of an SVG picture, for a label (see svg_path.zig).
pub const svg_path = @import("svg_path.zig");
pub const support = @import("support.zig");
/// Tree support, and its skeleton of nodes (see tree_support.zig).
pub const tree_support = @import("tree_support.zig");
pub const support_skeleton = @import("support_skeleton.zig");
/// The edits of tree support by hand (see support_edit.zig).
pub const support_edit = @import("support_edit.zig");
/// Expressions: the formulas of the settings (see expr.zig).
pub const expr = @import("expr.zig");
pub const gaps = @import("gaps.zig");
pub const gapfill = @import("gapfill.zig");
pub const islands = @import("islands.zig");
pub const toml = @import("toml.zig");
pub const yaml = @import("yaml.zig");
pub const project = @import("project.zig");
pub const profile = @import("profile.zig");
pub const import_cura = @import("import_cura.zig");
pub const import_profile = @import("import_profile.zig");
pub const calib = @import("calib.zig");
pub const cura_compare = @import("cura_compare.zig");
pub const part_settings = @import("part_settings.zig");
pub const printers = @import("printers.zig");
/// The bed models of the printers, for the 3D view (see bed.zig).
pub const bed = @import("bed.zig");
pub const discovery = @import("discovery.zig");
pub const app = @import("app.zig");

pub const Mesh = mesh.Mesh;
pub const Settings = settings.Settings;
pub const Stats = engine.Stats;
pub const Job = engine.Job;
pub const PlateJob = plate_job.PlateJob;
pub const slice = engine.slice;

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
    // The fuzz tests run once, in the tests of the module (the C API tests
    // link libc and also reach this block).
    if (comptime !@import("builtin").link_libc) _ = @import("fuzz.zig");
}
