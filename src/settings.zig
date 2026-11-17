//! Settings, in three parts that have different owners.
//!
//! - `Machine`: facts about the printer. They change only when the printer
//!   changes. Examples: the bed size, the nozzle, and the speed limits.
//! - `Filament`: facts about the material. Examples: the diameter, the
//!   temperatures, and the maximum flow that the hot end can melt.
//! - `Project`: what the user wants for this part. Examples: the layer
//!   height, the number of walls, and the infill.
//!
//! A project does not set speeds in mm/s. It sets a speed ratio (0 to 1) for
//! each feature. The engine gets the speed from the limits of the machine
//! and the filament (see `Resolved.speed`). One project then gives correct
//! speeds on a slow printer and on a fast printer, and with PLA and with
//! TPU.
//!
//! Lengths are in millimeters, speeds in mm/s, flow in mm^3/s,
//! temperatures in degrees Celsius. Ratios are 0 to 1.
//!
//! `Settings.set` changes a field from a dotted name, for example
//! "filament.nozzle_temp", and a text value. It uses comptime reflection, so
//! each new field is available in the C API, the wasm API, and the command
//! line with no more code.

const std = @import("std");
const flow = @import("flow.zig");

pub const InfillPattern = enum { lines, grid, triangles, trihexagon, cubic, gyroid, concentric, honeycomb, zigzag, flow, lightning };
pub const SeamMode = enum { hidden, sharpest, rear, nearest, random };
pub const WallGenerator = enum { classic, arachne };
/// How the top and bottom skin is filled. See `Project.skin_pattern`.
pub const SkinPattern = enum { lines, monotonic, concentric };
/// Where the part goes on the bed. See `Project.placement`.
pub const Placement = enum { auto, file, center };
pub const SupportMode = enum { off, everywhere, buildplate };
/// How a short layer gets its cooling time. See `Filament.cooling_mode`.
pub const CoolingMode = enum { slow_down, lap };
/// The shape of the support. See `Project.support_style`.
pub const SupportStyle = enum { grid, tree, bridge };
/// The G-code dialect for the acceleration commands. See `Machine.gcode_flavor`.
pub const GcodeFlavor = enum { marlin, klipper };
pub const ExtruderKind = enum { direct, bowden };

pub const Machine = struct {

    // Printer
    /// The name of the printer, for the G-code header.
    name: []const u8 = "generic",

    // Bed
    /// The size of the bed in X.
    bed_size_x: f64 = 220,
    /// The size of the bed in Y.
    bed_size_y: f64 = 220,
    /// The G-code X of the front left corner of the bed. The slicer places
    /// parts in bed coordinates (0, 0 at the front left corner) and adds
    /// this to each X in the G-code. Most printers: 0. A printer with its
    /// origin at the bed center: minus half the bed width.
    origin_x: f64 = 0,
    /// The G-code Y of the front left corner of the bed. See `origin_x`.
    origin_y: f64 = 0,
    /// The highest part that the printer can make.
    max_height: f64 = 250,

    // Nozzle
    /// The diameter of the nozzle hole. The default line width comes from it.
    nozzle_diameter: f64 = 0.4,
    /// The radius of the flat face at the tip of the nozzle, around the
    /// hole. A common brass nozzle has a face about 1 mm across. Slope
    /// smoothing uses it to keep the nozzle off the layer that it just
    /// printed.
    nozzle_tip_radius: f64 = 0.5,
    /// The angle between the axis of the nozzle and the side of its cone,
    /// in degrees. Slope smoothing uses it with `nozzle_tip_radius`.
    nozzle_cone_angle: f64 = 45,

    // Motion
    /// The maximum speed of the print head in X and Y.
    max_speed: f64 = 150,
    /// The speed of travel moves (moves with no extrusion).
    travel_speed: f64 = 150,
    /// The speed of Z moves at each layer change.
    max_z_speed: f64 = 10,
    /// The acceleration of Z moves (the layer change and the z hop), in
    /// mm/s². Only the time estimate uses it.
    max_z_accel: f64 = 100,
    /// The acceleration of the print head in X and Y, in mm/s². The time
    /// estimate uses it, and it is the acceleration of each feature that
    /// has no acceleration of its own (0 in the project).
    max_accel: f64 = 1500,
    /// The speed at which the head turns a corner with no stop (jerk in
    /// Marlin, square corner velocity in Klipper), in mm/s. The time
    /// estimate uses it.
    corner_speed: f64 = 8,
    /// Write acceleration commands in the G-code: the acceleration of each
    /// feature (project `*_accel`), and the corner speed at the start.
    /// Off: the printer uses its own values; the time estimate still uses
    /// `max_accel` and `corner_speed`.
    accel_control: bool = false,
    /// The G-code dialect of the acceleration commands. `marlin`: M204 S and
    /// M205 X Y. `klipper`: SET_VELOCITY_LIMIT ACCEL and
    /// SQUARE_CORNER_VELOCITY.
    gcode_flavor: GcodeFlavor = .marlin,

    // Extruder
    /// The extruder type. `direct`: the motor is on the print head. `bowden`: the motor pushes the filament through a long tube.
    extruder: ExtruderKind = .direct,
    /// The retraction length of this extruder. A bowden extruder needs more.
    retract_length: f64 = 0.8,
    /// The speed of the filament during a retraction.
    retract_speed: f64 = 40,

    // G-code
    /// The text before the print. These variables are replaced:
    /// {nozzle_temp}, {first_layer_nozzle_temp}, {bed_temp}, {standby_temp},
    /// {layer_height}, {first_layer_height}, {first_layer_speed} (mm/s),
    /// {nozzle_diameter}, {filament_diameter}, {filament_name},
    /// {machine_name}, and {job_name}.
    start_gcode: []const u8 =
        \\G90 ; absolute positions
        \\M83 ; relative extrusion
        \\M140 S{bed_temp}
        \\M104 S{first_layer_nozzle_temp}
        \\G28 ; home all axes
        \\M190 S{bed_temp}
        \\M109 S{first_layer_nozzle_temp}
    ,
    /// The text after the print. The same values as in `start_gcode` are replaced.
    end_gcode: []const u8 =
        \\M104 S0
        \\M140 S0
        \\M107
        \\G91
        \\G1 Z5 F600
        \\G90
        \\M84
    ,
};

pub const Filament = struct {

    // Filament
    /// The name of the filament, for the G-code header.
    name: []const u8 = "generic PLA",
    /// The type of the plastic, for example "PLA", "PETG", "ABS", or
    /// "TPU". The Filament menu lists the rolls of this type.
    material: []const u8 = "PLA",
    /// The color of the filament, as "#rrggbb". The 3D view draws the
    /// print in this color.
    color: []const u8 = "#d0d0cc",
    /// The diameter of the filament.
    diameter: f64 = 1.75,
    /// g/cm^3. For the filament weight in the statistics.
    density: f64 = 1.24,
    /// The price of one kilogram of this filament, in your currency. For
    /// the cost of a print (the filament weight times this price).
    price_per_kg: f64 = 25,

    // Temperatures
    /// The nozzle temperature from the second layer.
    nozzle_temp: f64 = 210,
    /// The nozzle temperature on the first layer.
    first_layer_nozzle_temp: f64 = 215,
    /// The bed temperature.
    bed_temp: f64 = 60,

    // Flow
    /// The maximum plastic flow that the hot end melts with this filament.
    /// This limits the speed of wide and tall lines.
    max_flow: f64 = 12,
    /// A multiplier for all extrusion, to calibrate the flow.
    flow_ratio: f64 = 1.0,

    // Cooling
    /// The part cooling fan speed, as a ratio.
    fan_speed: f64 = 1.0,
    /// The fan is off for this number of layers at the start.
    fan_off_layers: u32 = 1,
    /// The fan speed on short layers, as a ratio. See `fan_boost_time`.
    fan_max_speed: f64 = 1.0,
    /// A layer that takes less time than this (s) gets the fan at
    /// `fan_max_speed`.
    fan_boost_time: f64 = 15,
    /// The shortest time (s) for one layer. A layer that takes less time
    /// prints slower, so that the plastic below has time to cool.
    min_layer_time: f64 = 6,
    /// The lowest print speed (mm/s) for the slow-down of `min_layer_time`.
    min_speed: f64 = 10,
    /// How a layer that takes less than `min_layer_time` gets its time to
    /// cool. `slow_down`: it prints slower. `lap`: it prints at the planned
    /// speed; then the nozzle goes up 1 mm and moves around the layer with
    /// the fan at full until the time is over, so the air blows on the new
    /// plastic. The lap keeps the planned speed of the walls.
    cooling_mode: CoolingMode = .slow_down,
    /// A lower nozzle temperature for waits, for example while the printer
    /// probes the bed. The start G-code can use it as {standby_temp}. 0 is
    /// off.
    standby_temp: f64 = 0,

    // Size compensation
    /// The part is printed larger by this ratio in X and Y, because the
    /// plastic shrinks as it cools. Example: 1.003 for 0.3 % shrinkage.
    shrinkage_xy: f64 = 1,
    /// The part is printed taller by this ratio, for shrinkage in Z.
    shrinkage_z: f64 = 1,
    /// Moves all outlines out by this distance (in if negative). Use it if
    /// parts come out too large or too small by a fixed amount.
    xy_offset: f64 = 0,
    /// Moves the edges of holes by this distance. A positive value makes
    /// holes larger. It adds to `xy_offset`, which makes holes smaller when
    /// it is positive. Holes often come out too small.
    hole_xy_offset: f64 = 0,

    // Retraction
    /// A multiplier for the retraction length of the machine. Soft filament
    /// needs less.
    retract_ratio: f64 = 1.0,
};

pub const Project = struct {
    // Layers
    /// The height of each layer after the first. A smaller value gives a smoother surface and a longer print.
    layer_height: f64 = 0.2,
    /// The height of the first layer. A thicker first layer sticks to the bed better.
    first_layer_height: f64 = 0.3,

    // Lines
    /// The line width. 0 uses 1.1 x the nozzle diameter.
    line_width: f64 = 0,
    /// The line width on the first layer. 0 uses 1.25 x the nozzle diameter.
    first_layer_line_width: f64 = 0,

    // Walls
    /// The number of walls (loops) around the outline of each layer.
    wall_count: u32 = 2,
    /// The thickness of the walls, in mm, as in Cura: the wall count is
    /// this thickness divided by the line width, rounded (at least 1). 0:
    /// use `wall_count`.
    wall_thickness: f64 = 0,
    /// Print parts of the outline that are thinner than one line width
    /// (a thin fin, a sheet, a label): a loop inside each thin part, with a
    /// narrower line, so that its two sides fill the thickness. Without
    /// it, these parts print nothing. Off by default.
    thin_walls: bool = false,
    /// Where each wall loop starts and ends (the seam). `hidden`: at the
    /// point where the seam is hardest to see: an inside corner first, then
    /// an outside corner, toward the back, and not where the wall hangs
    /// over air; similar layers pick the same point, so the seam is one
    /// clean line. `sharpest`: in the deepest inside corner, or else in the
    /// sharpest outside corner, or else at the rear. `rear`: at the back of
    /// the part (the largest y), in one straight line. `nearest`: at the
    /// point nearest to the nozzle, which is the fastest. `random`: at a
    /// different point on each layer, so that no seam line shows.
    seam: SeamMode = .hidden,
    /// The method that makes the walls. `classic`: each wall is the outline
    /// moved in by a whole number of line widths, with one line width.
    /// `arachne`: the walls follow the center lines of the part, and the
    /// width of each line changes along it, so that a whole number of lines
    /// fills the part. A part thinner than two lines gets one line in its
    /// middle, so `thin_walls` has no effect. This is the method of Cura
    /// and the other open source slicers.
    wall_generator: WallGenerator = .classic,
    /// Arachne: the narrowest wall line. Where the wall count changes, the
    /// lines go from this width to two times this width. 0 uses 0.85 x the
    /// nozzle diameter.
    min_wall_line_width: f64 = 0,
    /// Arachne: parts thinner than this print nothing. A thicker part
    /// that is thinner than a line gets one line of at least
    /// `min_bead_width`. 0 uses 1/4 of the line width.
    min_feature_size: f64 = 0,
    /// Arachne: the narrowest line in a part thinner than a line. 0 uses
    /// `min_wall_line_width`.
    min_bead_width: f64 = 0,
    /// Arachne: the length over which one line splits into two, or two
    /// join into one, where the wall count changes. 0 uses the line width.
    wall_transition_length: f64 = 0,
    /// Arachne: in a wedge with a larger angle than this (in degrees), the
    /// wall count does not change along the middle: the walls follow the
    /// sides, and no line fills the middle.
    wall_transition_angle: f64 = 10,
    /// Arachne: two changes of the wall count closer together than this
    /// cancel out, so that the walls do not go back and forth.
    wall_transition_filter_distance: f64 = 100,
    /// Arachne: the number of walls, counted from the middle, that share a
    /// change of the line width. 1: only the middle line changes, and the
    /// outer walls keep their width.
    wall_distribution_count: u32 = 1,

    // Top and bottom skin, as a thickness. The engine computes the number
    // of layers, so a change of the layer height keeps the strength.
    /// The thickness of solid skin under each top surface.
    top_thickness: f64 = 0.8,
    /// The thickness of solid skin above each bottom surface.
    bottom_thickness: f64 = 0.6,
    /// Skin pieces narrower than this are removed before the expand (a
    /// sliver of skin at the edge of a slope). A thin piece next to a
    /// large skin area still gets skin from the expand.
    skin_removal_width: f64 = 0.2,
    /// The skin grows this far into the sparse infill next to it, so that
    /// its edges hold on the infill and close against the walls.
    skin_expand_distance: f64 = 0.8,
    /// A sparse infill area narrower than this prints solid, as skin. A
    /// narrow strip would get no infill lines, and a gap would show next to
    /// the walls under a top surface.
    solid_infill_width: f64 = 1.5,
    /// How the skin is filled. `lines`: parallel lines in the nearest
    /// order. `monotonic`: parallel lines from one side to the other, so
    /// each line lies against the line before it in the same way; the top
    /// has an even sheen. `concentric`: loops that follow the outline.
    skin_pattern: SkinPattern = .lines,
    /// The direction of the skin lines on the first layer, in degrees from
    /// the X axis. Ironing goes at a right angle to the top skin.
    skin_angle: f64 = 45,
    /// How much the skin direction turns from one layer to the next, in
    /// degrees. 90 crosses the lines of each layer with the layer below.
    skin_angle_step: f64 = 90,
    /// Skin lines go this far into the walls, as a fraction of the line
    /// width, so that the skin bonds to the walls.
    skin_overlap: f64 = 0.15,
    /// Retractless skin: the top and bottom skin of each island prints as
    /// few paths as it can. The skin lines split into pieces at holes and
    /// corners, and each piece prints as one zigzag. From the end of a
    /// zigzag, the nozzle goes on to the next zigzag along the walls, and
    /// prints on the way, if that way is at most this long (mm). A travel
    /// and a retraction come only where no such way is. The way can go
    /// over skin that is printed already: it adds a little plastic along
    /// the wall. The zigzags just below a zigzag print before it, so at a
    /// hole both sides fill before the skin over the hole. 0: off, each
    /// piece prints on its own. Only for the `lines` pattern.
    skin_link_length: f64 = 15,
    /// Print bridges as bridges: the part of a bottom skin over air that
    /// solid plastic holds at its sides prints in straight lines across the
    /// air (the direction with the most lines that start and end on solid
    /// plastic), each line anchored on the solid skin around it, slower
    /// (`bridge_speed`), with `bridge_flow` and `bridge_fan`. The parts of
    /// the walls over air (1 mm or longer) print as bridges too. Off: the
    /// bridge prints as normal skin and walls.
    bridges: bool = true,
    /// The speed of the bridge lines, as a ratio of the allowed speed. A slow
    /// line sags less.
    bridge_speed: f64 = 0.3,
    /// The flow of the bridge lines, as a ratio of the flow of a normal
    /// line. A little less flow makes a thinner strand that cools fast.
    bridge_flow: f64 = 0.95,
    /// The fan speed while the bridge lines print, from 0 to 1.
    bridge_fan: f64 = 1.0,
    /// Rules for each path, one on each line: "speed = ...", "flow = ...",
    /// or "fan = ...", with a formula (see the formulas of the settings).
    /// The variables of a path: {feature} ("outer_wall", "inner_wall",
    /// "skin", "infill", "bridge", ...), {layer} (from 0), {z} (mm),
    /// {part}, {speed} (the planned speed, mm/s), {width} and {height}
    /// (mm), {length} (mm), and {fan} (0 to 1). "speed" sets the speed in
    /// mm/s, "flow" multiplies the flow, and "fan" sets the fan (0 to 1)
    /// while the path prints. For example: speed = {feature} ==
    /// "outer_wall" and {z} < 5 ? 20 : {speed}. A line that does not work
    /// is left out.
    path_rules: []const u8 = "",
    /// Fill the narrow areas that no wall and no skin line covers (a strip
    /// between two walls, a wedge of skin next to a hole) with a line along
    /// the middle of each area. The width of the line follows the width of
    /// the area. These lines print at the skin speed. A part thinner than
    /// one line gets a line from `thin_walls`, not from this setting.
    gap_fill: bool = true,

    // Infill
    /// The fraction of the inside that the sparse infill fills, as a ratio. 0 makes the part hollow.
    infill_density: f64 = 0.2,
    /// The sparse infill pattern. `lines`: one direction on each layer,
    /// turned 90 degrees on the next layer. `grid`: two directions on each
    /// layer. `triangles`: three directions at 60 degrees on each layer,
    /// which cross at the same points, so they make triangles.
    /// `trihexagon`: the three directions of `triangles`, with the third
    /// set moved by half its spacing, so the lines make triangles and
    /// hexagons (as in Cura). `cubic`: three directions that move with the height, so the infill
    /// makes cubes in 3D. `gyroid`: smooth curves that change with the
    /// height, strong in all directions. `concentric`: loops that follow
    /// the outline. `honeycomb`: hexagon cells, the same on all layers.
    /// `zigzag`: the lines of `lines`, joined at the walls into one path,
    /// so the nozzle does not travel or retract between them. `flow`: the
    /// zigzag, with twice the density under each top surface (a band of 3
    /// times the top thickness, at least 2 mm), where the top skin needs
    /// it, and the density of the setting in the middle. `lightning`:
    /// thin branches only under the top surfaces; they grow down from each
    /// top, join into trees, and end at the walls, so most of the inside
    /// stays empty. For display parts: it is fast and uses little plastic,
    /// but it is weak. The density sets the distance between the branches
    /// under a top.
    infill_pattern: InfillPattern = .grid,
    /// The angle of the infill and skin lines, in degrees from the X axis.
    infill_angle: f64 = 45,
    /// A list of infill angles in degrees from the X axis, with commas
    /// between them, one for each layer in turn: "45,45,45,135,135,135"
    /// prints 3 layers at 45 degrees, then 3 layers at 135 degrees, and
    /// again. The line patterns (lines, zigzag, flow, grid, triangles,
    /// trihexagon, cubic, honeycomb) use the angle of the layer in place of
    /// `infill_angle`, and the lines and zigzag patterns do not turn by 90
    /// degrees on each layer. Empty: `infill_angle`. As "Infill Line
    /// Directions" in Cura.
    infill_angles: []const u8 = "",
    /// Keep the infill of all layers on top of each other: the lines,
    /// zigzag, and flow patterns do not turn by 90 degrees on each layer.
    /// The lines of each layer lie on the lines of the layer below, and
    /// make vertical walls, for example the openings of a grille. Grid,
    /// triangles, trihexagon, honeycomb, and concentric stack in each case.
    /// Honeycomb also prints each cell wall once, so all its walls have
    /// one width (else two of the six sides of a cell print twice).
    infill_stack: bool = false,
    /// The flow of the sparse infill lines, as a ratio of the flow of a
    /// normal line. As "Infill Flow" in Cura.
    infill_flow: f64 = 1.0,
    /// Join the infill lines (lines, grid, triangles, cubic) at their ends
    /// with a short line along the edge, as "Connect Infill Lines" in Cura:
    /// the nozzle prints a zigzag with no travel and no retraction, and the
    /// joints tie the infill to the walls. Off: each line on its own.
    infill_connect: bool = true,
    /// A rib in each narrow infill area that the infill lines miss: one
    /// line along the length of the area, through its middle, on each
    /// layer, so the lines stack into a rib. At a low density the lines
    /// are far apart (10 % grid: 11 mm), and an area narrower than that
    /// gets no infill on most layers; the top over it then sags. Off: such
    /// an area stays empty.
    infill_ribs: bool = true,
    /// The lightning infill: how far a branch leans from vertical, in
    /// degrees. On each layer down, the end of a branch gets shorter by
    /// the layer height times tan(angle), and a bent branch gets
    /// straighter by at most the same distance. A larger angle gives
    /// smaller trees and less plastic, but the lines hang out more over
    /// the layer below.
    lightning_angle: f64 = 40,
    /// Top support: the layers under each top skin that get denser
    /// infill lines (one direction on each layer, turned 90 degrees on the
    /// next), so that the skin lies on a flat grid and bridges less. 0:
    /// off. The flow pattern has its own band.
    top_support_layers: u32 = 2,
    /// The density of the top support lines, as a ratio. It works only if
    /// it is more than `infill_density`.
    top_support_density: f64 = 0.5,
    /// Sparse infill lines go this far into the walls, as a fraction of the line width.
    infill_overlap: f64 = 0.2,
    /// Print the sparse infill once every this many layers, as one taller
    /// bead at the top layer of each group, with the flow of all the
    /// layers. The walls and the skin still print on each layer. Sparse
    /// infill is hidden, so it does not need the fine layers, and the
    /// print has fewer infill moves. A group is never thicker than the
    /// nozzle diameter: the count goes down where the layers are too
    /// thick. Only the area that is sparse infill in all layers of a group
    /// gets the tall bead, and the dense band under the top skin prints
    /// on each layer. 1: each layer.
    infill_layers: u32 = 1,

    // Ironing
    /// Iron the top surfaces. After the layer is complete, the nozzle goes
    /// over each top surface again with close lines and a small flow. The
    /// hot nozzle melts the surface flat, and the small flow fills the gaps
    /// between the skin lines.
    ironing: bool = false,
    /// The flow of the ironing lines, as a ratio of the flow of a normal line.
    ironing_flow: f64 = 0.1,
    /// The distance between the ironing lines.
    ironing_spacing: f64 = 0.1,
    /// The ironing area is this far inside the edges of the top surface, so
    /// that the nozzle does not push plastic over the edges.
    ironing_inset: f64 = 0.3,
    /// The ironing speed, as a ratio of `machine.max_speed`. The flow limit
    /// of the filament does not apply, because the flow is small.
    ironing_speed: f64 = 0.15,

    // Slope smoothing
    /// Fill the steps on gently sloped top surfaces. After each layer, the
    /// nozzle goes back along the edge of the layer, over the narrow ledge
    /// of the layer below. It lays a bead in the corner of each step,
    /// with the volume of the triangle there. The nozzle height can change
    /// along the bead, between the two layers.
    slope_smoothing: bool = false,
    /// The narrowest ledge that gets a bead, as a ratio of the line width.
    /// A narrower step is small, and its bead is too small to meter.
    slope_smoothing_min_width: f64 = 0.3,
    /// The widest ledge that gets a bead, as a ratio of the line width. A
    /// wider ledge is a flat top, or needs more than one bead.
    slope_smoothing_max_width: f64 = 2,
    /// The plastic of a smoothing bead, as a ratio of the volume of the
    /// triangle in the step.
    slope_smoothing_flow: f64 = 1,
    /// The speed of the smoothing beads, as a ratio of the allowed speed.
    slope_smoothing_speed: f64 = 0.3,
    /// Iron the sloped steps. After each layer (and after its smoothing
    /// beads), the nozzle goes along the same ledges as slope smoothing,
    /// with a very small flow. At each point, the nozzle tip is at the
    /// height of the filled step there, so the hot tip makes the bead tops
    /// flat. The ledges are the ones of `slope_smoothing_min_width` and
    /// `slope_smoothing_max_width`.
    slope_ironing: bool = false,
    /// The number of ironing passes over each ledge, evenly across it.
    slope_ironing_passes: u32 = 2,
    /// The flow of the slope ironing lines, as a ratio of the flow of a
    /// normal line.
    slope_ironing_flow: f64 = 0.1,
    /// The slope ironing speed, as a ratio of `machine.max_speed`. The
    /// flow limit of the filament does not apply, because the flow is
    /// small.
    slope_ironing_speed: f64 = 0.15,

    // Speed ratios: the fraction of the speed that the machine and the
    // filament allow.
    /// The outer wall speed, as a ratio of the allowed speed. A slower outer wall gives a better surface.
    outer_wall_speed: f64 = 0.5,
    /// The inner wall speed, as a ratio of the allowed speed.
    inner_wall_speed: f64 = 0.8,
    /// The skin speed, as a ratio of the allowed speed.
    skin_speed: f64 = 0.7,
    /// The sparse infill speed, as a ratio of the allowed speed.
    infill_speed: f64 = 1.0,
    /// The speed of all lines on the first layer, as a ratio of the allowed speed.
    first_layer_speed: f64 = 0.3,
    /// The layers after the first that print slower: their speed goes up in
    /// even steps from the first layer speed to the full speed, so that
    /// the part bonds to the bed. 0: the second layer prints at full speed.
    slow_layers: u32 = 0,

    // Acceleration
    /// The acceleration of the outer wall, in mm/s². A lower value gives a
    /// cleaner surface. 0: the machine `max_accel`. The G-code has it only
    /// with machine `accel_control`.
    outer_wall_accel: f64 = 0,
    /// The acceleration of the inner walls and the skirt, in mm/s². 0: the
    /// machine `max_accel`.
    inner_wall_accel: f64 = 0,
    /// The acceleration of the skin, in mm/s². 0: the machine `max_accel`.
    skin_accel: f64 = 0,
    /// The acceleration of the sparse infill and the support, in mm/s². 0:
    /// the machine `max_accel`.
    infill_accel: f64 = 0,
    /// The acceleration of travel moves, in mm/s². 0: the machine
    /// `max_accel`.
    travel_accel: f64 = 0,
    /// The acceleration of all lines on the first layer, in mm/s². 0: the
    /// acceleration of each feature.
    first_layer_accel: f64 = 0,

    // Travel
    /// Travel moves shorter than this do not retract.
    retract_min_travel: f64 = 1.5,
    /// Combing: a travel move that stays inside the part (it crosses no
    /// outline of the layer) does not retract, because an ooze there is
    /// inside the part. Off: each travel longer than `retract_min_travel`
    /// retracts.
    combing: bool = true,
    /// A travel inside the part that is longer than this retracts all the
    /// same (a long move can ooze a string over a top surface). 0: no limit.
    combing_max_distance: f64 = 0,
    /// Lift the nozzle by this distance during a travel move with a retraction. 0 turns it off.
    z_hop: f64 = 0,
    /// Lift the nozzle (`z_hop`) only for a travel that crosses an edge of
    /// the layer: it leaves the part, or it goes over a hole. A travel in
    /// a straight line inside the part (it retracts because it is longer
    /// than `combing_max_distance`) does not lift. Off: each travel with
    /// a retraction lifts.
    z_hop_only_crossing: bool = true,
    /// Retract at each layer change. Off: the travel to the first path of
    /// the layer retracts by the rules of the other travels (combing).
    /// Off by default, as in Cura.
    retract_layer_change: bool = false,

    // Support
    /// Support under overhangs. `off`: no support. `everywhere`: support
    /// can stand on the bed or on the part. `buildplate`: only support that
    /// stands on the bed.
    support: SupportMode = .off,
    /// The shape of the support. `grid`: all the space under each overhang,
    /// filled with lines. `tree`: branches from points under each overhang
    /// down to the bed or the part; they join on the way, get thicker as
    /// they go down, and thinner in narrow spaces (so a branch can go down
    /// a deep, narrow hole). A tree uses less plastic and comes off more
    /// easily. `bridge`: only a sacrificial pad under each overhang (the
    /// interface layers, with the Z gap over it), with nothing under the
    /// pad. The pad bridges from the part around it, as a bridge does, and
    /// breaks off easily. For overhangs over a hole or a short gap, where
    /// a column down to the bed would be a waste.
    support_style: SupportStyle = .grid,
    /// Tree support: the largest angle of a branch from vertical, in
    /// degrees. A larger angle lets branches reach farther, with less
    /// strength.
    support_tree_angle: f64 = 40,
    /// Tree support: the distance of the tips under an overhang.
    support_tree_spacing: f64 = 3,
    /// Tree support: the diameter of a tip. 0 uses the line width times 2.
    support_tree_tip: f64 = 0,
    /// An overhang that leans more than this angle (degrees) from vertical
    /// gets support. A larger angle gives less support.
    support_angle: f64 = 50,
    /// The fraction of the support area that the support lines fill, as a
    /// ratio.
    support_density: f64 = 0.15,
    /// The gap between the support and the sides of the part.
    support_xy_gap: f64 = 0.6,
    /// The number of empty layers between the support and the part above
    /// it or under it, so that the support comes off.
    support_z_gap_layers: u32 = 1,
    /// The number of dense layers at the top of the support, under the
    /// part. They make the bottom surface of the part smooth.
    support_interface_layers: u32 = 2,
    /// The fraction of the interface area that its lines fill, as a ratio.
    support_interface_density: f64 = 0.7,

    // Skirt and brim
    /// The number of skirt loops. A skirt is a loop around the part on the
    /// first layers, at a distance from it. It primes the nozzle before the
    /// part starts. 0 turns it off.
    skirt_loops: u32 = 1,
    /// The distance from the part (or from the brim) to the skirt.
    skirt_distance: f64 = 3,
    /// The number of layers with a skirt.
    skirt_layers: u32 = 1,
    /// The width of the brim. A brim is loops on the first layer around the
    /// outside of the part, joined to it. It holds the part on the bed, and
    /// helps against warping. 0 turns it off.
    brim_width: f64 = 0,

    // First layer
    /// Moves the outline of the first layer by this distance. A negative
    /// value compensates the "elephant foot": the first layer spreads out
    /// because the nozzle presses it on the bed.
    first_layer_xy_offset: f64 = 0,

    // Placement
    /// Where the part goes on the bed. auto: at the X and Y of the file if
    /// the part is fully on the bed there, else at the center of the bed.
    /// file: always at the X and Y of the file. center: always at the
    /// center of the bed. The bottom of the part always goes to z = 0.
    placement: Placement = .auto,
};

/// Options for the engine. They do not change the print.
pub const EngineOptions = struct {

    // Slicer
    /// The largest change to the shape (mm) that the slicer makes when it
    /// removes points from the mesh outlines.
    resolution: f64 = 0.005,
    /// The largest gap (mm) that the slicer closes in a mesh with holes.
    gap_closing: f64 = 1.0,
    /// The number of threads. 0 uses one thread for each CPU but one, so
    /// that the app and the desktop can answer while a slice runs.
    threads: u32 = 0,
    /// The name of the print, for {job_name} in the start and end G-code.
    /// The command line tool sets it to the model file name.
    job_name: []const u8 = "",
};

pub const Settings = struct {
    machine: Machine = .{},
    filament: Filament = .{},
    project: Project = .{},
    engine: EngineOptions = .{},

    pub const SetError = error{ UnknownSetting, InvalidValue, OutOfRange };

    /// Sets a field from a dotted name ("project.wall_count") and a text
    /// value. String values are not copied: the caller keeps them alive
    /// while the settings are in use.
    pub fn set(self: *Settings, name: []const u8, value: []const u8) SetError!void {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.UnknownSetting;
        const group = name[0..dot];
        const field = name[dot + 1 ..];
        if (limitOf(name)) |l| {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " ")) catch return error.InvalidValue;
            if (!(v >= l[0] and v <= l[1])) return error.OutOfRange;
        }
        inline for (@typeInfo(Settings).@"struct".fields) |g| {
            if (std.mem.eql(u8, g.name, group)) return setField(&@field(self, g.name), field, value);
        }
        return error.UnknownSetting;
    }

    /// Checks the values and computes the derived values.
    pub fn resolve(self: Settings) error{InvalidValue}!Resolved {
        const m = self.machine;
        const f = self.filament;
        const p = self.project;
        const positive = [_]f64{
            m.nozzle_diameter,    m.max_speed, m.travel_speed, m.max_z_speed,
            f.diameter,           f.max_flow,  f.flow_ratio,   p.layer_height,
            p.first_layer_height,
        };
        // Each number must be finite and of a size that the integer
        // coordinates can hold.
        inline for (@typeInfo(Settings).@"struct".fields) |g| {
            const group = @field(self, g.name);
            inline for (@typeInfo(@TypeOf(group)).@"struct".fields) |field| {
                if (field.type == f64) {
                    const v = @field(group, field.name);
                    if (!(@abs(v) <= 1e6)) return error.InvalidValue;
                }
            }
        }
        for (positive) |v| if (!(v > 0)) return error.InvalidValue;
        const ratios = [_]f64{
            f.fan_speed,     p.infill_density, p.outer_wall_speed,  p.inner_wall_speed,
            p.skin_speed,    p.infill_speed,   p.first_layer_speed, p.ironing_flow,
            p.ironing_speed, f.fan_max_speed,  p.support_density,   p.support_interface_density,
            p.slope_smoothing_speed, p.slope_ironing_flow, p.slope_ironing_speed,
        };
        for (ratios) |v| if (!(v >= 0 and v <= 1)) return error.InvalidValue;
        if (p.outer_wall_speed == 0 or p.inner_wall_speed == 0 or p.skin_speed == 0 or p.infill_speed == 0 or p.first_layer_speed == 0) return error.InvalidValue;
        var angle_buf: [max_infill_angles]f64 = undefined;
        _ = infillAngles(p.infill_angles, &angle_buf) catch return error.InvalidValue;
        if (p.ironing and (p.ironing_speed == 0 or !(p.ironing_spacing > 0))) return error.InvalidValue;
        if (p.slope_ironing and (p.slope_ironing_speed == 0 or p.slope_ironing_passes == 0 or !(p.slope_smoothing_min_width < p.slope_smoothing_max_width))) return error.InvalidValue;
        if (p.slope_smoothing and (p.slope_smoothing_speed == 0 or !(p.slope_smoothing_min_width < p.slope_smoothing_max_width))) return error.InvalidValue;
        if (p.support != .off and (p.support_density == 0 or p.support_interface_density == 0 or !(p.support_angle > 0 and p.support_angle < 90))) return error.InvalidValue;

        const w = if (p.line_width > 0) p.line_width else 1.1 * m.nozzle_diameter;
        const w0 = if (p.first_layer_line_width > 0) p.first_layer_line_width else 1.25 * m.nozzle_diameter;
        if (p.layer_height > w or p.first_layer_height > w0) return error.InvalidValue;
        if (!(f.shrinkage_xy > 0.5 and f.shrinkage_xy < 1.5 and f.shrinkage_z > 0.5 and f.shrinkage_z < 1.5)) return error.InvalidValue;
        const r = f.diameter / 2;
        // A wall thickness sets the wall count, as in Cura.
        var out_settings = self;
        if (p.wall_thickness > 0) out_settings.project.wall_count = @max(1, @as(u32, @intFromFloat(@round(p.wall_thickness / w))));
        if (!(m.max_accel > 0 and m.corner_speed >= 0)) return error.InvalidValue;
        return .{
            .settings = out_settings,
            .line_width = w,
            .first_layer_line_width = w0,
            .top_layers = @intFromFloat(@ceil(p.top_thickness / p.layer_height - 1e-6)),
            .bottom_layers = @intFromFloat(@ceil(p.bottom_thickness / p.layer_height - 1e-6)),
            .filament_area = std.math.pi * r * r,
            .retract_length = m.retract_length * f.retract_ratio,
        };
    }
};

pub const Feature = enum(u8) {
    outer_wall,
    inner_wall,
    skin,
    infill,
    ironing,
    /// The skirt and the brim.
    skirt,
    support,
    support_interface,
    /// The beads in the steps of a sloped top surface (see
    /// `Project.slope_smoothing`).
    slope_smoothing,
    /// The ironing passes over the steps of a sloped top surface (see
    /// `Project.slope_ironing`).
    slope_ironing,
    /// The lines of a skin over air, held at its sides (see
    /// `Project.bridges`).
    bridge,
};

/// Settings after `Settings.resolve`, with the derived values.
pub const Resolved = struct {
    settings: Settings,
    line_width: f64,
    first_layer_line_width: f64,
    top_layers: u32,
    bottom_layers: u32,
    filament_area: f64,
    retract_length: f64,

    /// The print speed of a line, in mm/s. The speed is the lowest of:
    /// the speed limit of the machine, and the speed at which the line uses
    /// the maximum flow of the filament. The project ratio of the feature
    /// then scales it. Ironing uses only the machine limit.
    /// The speed of a line on layer `layer`: `speed`, with the ramp of the
    /// slow layers after the first (`slow_layers`).
    pub fn speedAt(self: Resolved, feature: Feature, width: f64, height: f64, layer: usize) f64 {
        const full = self.speed(feature, width, height, layer == 0);
        const n = self.settings.project.slow_layers;
        if (layer == 0 or layer > n or feature == .ironing or feature == .slope_smoothing or feature == .slope_ironing) return full;
        // From the first layer speed (layer 0) up to the full speed (layer
        // n + 1), in even steps.
        const first = self.speed(feature, width, height, true);
        if (first >= full) return full;
        const t = @as(f64, @floatFromInt(layer)) / @as(f64, @floatFromInt(n + 1));
        return first + (full - first) * t;
    }

    /// The acceleration of a feature on a layer, in mm/s² (`null` feature:
    /// travel).
    pub fn accel(self: Resolved, feature: ?Feature, first_layer: bool) f64 {
        const p = self.settings.project;
        const max = self.settings.machine.max_accel;
        if (first_layer and p.first_layer_accel > 0 and feature != null) return @min(max, p.first_layer_accel);
        const a = if (feature) |f| switch (f) {
            .outer_wall, .slope_smoothing => p.outer_wall_accel,
            .inner_wall, .skirt => p.inner_wall_accel,
            .skin, .support_interface, .ironing, .slope_ironing, .bridge => p.skin_accel,
            .infill, .support => p.infill_accel,
        } else p.travel_accel;
        return if (a > 0) @min(max, a) else max;
    }

    pub fn speed(self: Resolved, feature: Feature, width: f64, height: f64, first_layer: bool) f64 {
        const p = self.settings.project;
        if (feature == .ironing) return self.settings.machine.max_speed * p.ironing_speed;
        if (feature == .slope_ironing) return self.settings.machine.max_speed * p.slope_ironing_speed;
        const flow_limit = self.settings.filament.max_flow / flow.beadArea(width, height);
        const limit = @min(self.settings.machine.max_speed, flow_limit);
        const ratio = if (first_layer) p.first_layer_speed else switch (feature) {
            .outer_wall => p.outer_wall_speed,
            .inner_wall => p.inner_wall_speed,
            .skin => p.skin_speed,
            .infill => p.infill_speed,
            .skirt => p.inner_wall_speed,
            .support => p.infill_speed,
            .support_interface => p.skin_speed,
            .slope_smoothing => p.slope_smoothing_speed,
            .bridge => p.bridge_speed,
            .ironing, .slope_ironing => unreachable,
        };
        return limit * ratio;
    }
};

/// The most angles in `Project.infill_angles`.
pub const max_infill_angles = 64;

/// The angles of `Project.infill_angles` in `buf`: numbers with commas or
/// spaces between them. Brackets around the list are allowed, as in Cura
/// ("[45, 135]"). An empty list is no list.
pub fn infillAngles(text: []const u8, buf: *[max_infill_angles]f64) error{InvalidValue}![]const f64 {
    const t = std.mem.trim(u8, text, " \t[]");
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, t, ", \t");
    while (it.next()) |tok| {
        if (n == buf.len) return error.InvalidValue;
        const v = std.fmt.parseFloat(f64, tok) catch return error.InvalidValue;
        if (!(@abs(v) <= 3600)) return error.InvalidValue;
        buf[n] = v;
        n += 1;
    }
    return buf[0..n];
}

test "infill angles: a list, with or without brackets" {
    var buf: [max_infill_angles]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try infillAngles("", &buf)).len);
    try std.testing.expectEqual(@as(usize, 0), (try infillAngles(" [] ", &buf)).len);
    const a = try infillAngles("[45,45, 135]", &buf);
    try std.testing.expectEqualSlices(f64, &.{ 45, 45, 135 }, a);
    try std.testing.expectError(error.InvalidValue, infillAngles("45,x", &buf));
    var s: Settings = .{};
    try s.set("project.infill_angles", "90,0");
    _ = try s.resolve();
    s.project.infill_angles = "9e9";
    try std.testing.expectError(error.InvalidValue, s.resolve());
}

fn setField(target: anytype, name: []const u8, value: []const u8) Settings.SetError!void {
    const T = @typeInfo(@TypeOf(target)).pointer.child;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            @field(target, f.name) = try parseValue(f.type, value);
            return;
        }
    }
    return error.UnknownSetting;
}

fn parseValue(comptime T: type, value: []const u8) Settings.SetError!T {
    const v = std.mem.trim(u8, value, " \t");
    switch (@typeInfo(T)) {
        .float => return std.fmt.parseFloat(T, v) catch error.InvalidValue,
        .int => return std.fmt.parseInt(T, v, 10) catch error.InvalidValue,
        .bool => {
            if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
            if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
            return error.InvalidValue;
        },
        .@"enum" => return std.meta.stringToEnum(T, v) orelse error.InvalidValue,
        .pointer => return value,
        else => @compileError("unsupported setting type " ++ @typeName(T)),
    }
}

const testing = std.testing;

test "set fields by dotted name" {
    var s: Settings = .{};
    try s.set("project.layer_height", "0.12");
    try s.set("project.wall_count", "3");
    try s.set("project.infill_pattern", "lines");
    try s.set("filament.nozzle_temp", "245");
    try s.set("machine.extruder", "bowden");
    try s.set("engine.threads", "1");
    try testing.expectEqual(@as(f64, 0.12), s.project.layer_height);
    try testing.expectEqual(@as(u32, 3), s.project.wall_count);
    try testing.expectEqual(InfillPattern.lines, s.project.infill_pattern);
    try testing.expectEqual(@as(f64, 245), s.filament.nozzle_temp);
    try testing.expectEqual(ExtruderKind.bowden, s.machine.extruder);
    try testing.expectError(error.UnknownSetting, s.set("project.no_such_setting", "1"));
    try testing.expectError(error.UnknownSetting, s.set("layer_height", "1"));
    try testing.expectError(error.InvalidValue, s.set("project.wall_count", "two"));
}

test "set: the text forms of each kind, and a bad value keeps the old one" {
    var s: Settings = .{};
    // Spaces around a value do not count.
    try s.set("project.layer_height", " 0.16 ");
    try testing.expectEqual(@as(f64, 0.16), s.project.layer_height);
    // A boolean is true, false, 1, or 0.
    try s.set("project.ironing", "1");
    try testing.expect(s.project.ironing);
    try s.set("project.ironing", "false");
    try testing.expect(!s.project.ironing);
    try testing.expectError(error.InvalidValue, s.set("project.ironing", "yes"));
    try testing.expect(!s.project.ironing);
    // An enum takes only the name of a value.
    try testing.expectError(error.InvalidValue, s.set("project.infill_pattern", "Grid"));
    try testing.expectEqual(InfillPattern.grid, s.project.infill_pattern);
    // A number out of its limits, or not a number, keeps the old value.
    try testing.expectError(error.OutOfRange, s.set("project.layer_height", "-0.2"));
    try testing.expectError(error.OutOfRange, s.set("project.layer_height", "nan"));
    try testing.expectError(error.InvalidValue, s.set("project.layer_height", "0.2mm"));
    try testing.expectEqual(@as(f64, 0.16), s.project.layer_height);
    // An integer takes no fraction.
    try testing.expectError(error.InvalidValue, s.set("project.wall_count", "2.5"));
    try testing.expectEqual(@as(u32, 2), s.project.wall_count);
    // A string is not copied: the settings keep the slice of the caller.
    const name = "PLA from the shop";
    try s.set("filament.name", name);
    try testing.expectEqual(@as([*]const u8, name.ptr), s.filament.name.ptr);
}

test "resolve: values that do not go together are an error" {
    const bad = [_][2][]const u8{
        // A layer higher than the line is wide.
        .{ "project.layer_height", "0.5" },
        // A speed ratio of 0.
        .{ "project.skin_speed", "0" },
        // Shrinkage that makes the part half its size.
        .{ "filament.shrinkage_xy", "0.4" },
    };
    for (bad) |b| {
        var s: Settings = .{};
        s.set(b[0], b[1]) catch |e| {
            // The limits stop some values before resolve: that is also an
            // error for the user.
            try testing.expect(e == error.OutOfRange);
            continue;
        };
        try testing.expectError(error.InvalidValue, s.resolve());
    }
    // Ironing needs a speed and a spacing.
    var s: Settings = .{};
    s.project.ironing = true;
    s.project.ironing_spacing = 0;
    try testing.expectError(error.InvalidValue, s.resolve());
    // Support needs an overhang angle between 0 and 90 degrees.
    s = .{};
    s.project.support = .everywhere;
    s.project.support_angle = 90;
    try testing.expectError(error.InvalidValue, s.resolve());
    // The same angle is fine with no support.
    s.project.support = .off;
    _ = try s.resolve();
}

test "resolve: a wall thickness sets the wall count" {
    var s: Settings = .{};
    s.project.wall_thickness = 1.3;
    // 1.3 mm of walls at the 0.44 mm line width: 3 walls.
    try testing.expectEqual(@as(u32, 3), (try s.resolve()).settings.project.wall_count);
    // A thin wall still has one line.
    s.project.wall_thickness = 0.1;
    try testing.expectEqual(@as(u32, 1), (try s.resolve()).settings.project.wall_count);
}

test "resolve derives layers and speeds" {
    var s: Settings = .{};
    s.project.layer_height = 0.2;
    s.project.top_thickness = 0.8;
    const r = try s.resolve();
    try testing.expectEqual(@as(u32, 4), r.top_layers);
    try testing.expectApproxEqAbs(@as(f64, 0.44), r.line_width, 1e-9);
    // 12 mm^3/s over the bead area of 0.44 x 0.2 mm (0.0794 mm^2) is
    // 151 mm/s, so the machine limit (150 mm/s) applies.
    const a = flow.beadArea(0.44, 0.2);
    try testing.expectApproxEqAbs(@min(150, 12.0 / a), r.speed(.infill, 0.44, 0.2, false), 1e-9);
    try testing.expectApproxEqAbs(0.5 * @min(150, 12.0 / a), r.speed(.outer_wall, 0.44, 0.2, false), 1e-9);
}

/// The hard limits of the number settings: a value out of its limits is an
/// error (`Settings.set` returns error.OutOfRange). The limits are wide:
/// they stop values that no print needs (a 300 mm brim), not unusual ones.
/// The usual values are the slider ranges in src/app/setting_info.zig. A
/// test checks that each number setting has a limit, and each default is
/// in it.
pub const limits = [_]struct { []const u8, f64, f64 }{
    // machine
    .{ "machine.bed_size_x", 10, 2000 },
    .{ "machine.bed_size_y", 10, 2000 },
    .{ "machine.origin_x", -2000, 2000 },
    .{ "machine.origin_y", -2000, 2000 },
    .{ "machine.max_height", 10, 2000 },
    .{ "machine.nozzle_diameter", 0.1, 2 },
    .{ "machine.nozzle_tip_radius", 0, 5 },
    .{ "machine.nozzle_cone_angle", 0, 85 },
    .{ "machine.max_speed", 1, 2000 },
    .{ "machine.travel_speed", 1, 2000 },
    .{ "machine.max_z_speed", 0.1, 200 },
    .{ "machine.max_z_accel", 1, 100000 },
    .{ "machine.max_accel", 10, 100000 },
    .{ "machine.corner_speed", 0, 100 },
    .{ "machine.retract_length", 0, 20 },
    .{ "machine.retract_speed", 1, 200 },
    // filament
    .{ "filament.diameter", 1, 3.5 },
    .{ "filament.density", 0.5, 3 },
    .{ "filament.price_per_kg", 0, 10000 },
    .{ "filament.nozzle_temp", 0, 450 },
    .{ "filament.first_layer_nozzle_temp", 0, 450 },
    .{ "filament.bed_temp", 0, 150 },
    .{ "filament.max_flow", 0.5, 100 },
    .{ "filament.flow_ratio", 0.5, 2 },
    .{ "filament.fan_speed", 0, 1 },
    .{ "filament.fan_off_layers", 0, 100 },
    .{ "filament.fan_max_speed", 0, 1 },
    .{ "filament.fan_boost_time", 0, 120 },
    .{ "filament.min_layer_time", 0, 120 },
    .{ "filament.min_speed", 1, 100 },
    .{ "filament.standby_temp", 0, 450 },
    .{ "filament.shrinkage_xy", 0.9, 1.1 },
    .{ "filament.shrinkage_z", 0.9, 1.1 },
    .{ "filament.xy_offset", -2, 2 },
    .{ "filament.hole_xy_offset", -2, 2 },
    .{ "filament.retract_ratio", 0, 5 },
    // project
    .{ "project.layer_height", 0.02, 1 },
    .{ "project.first_layer_height", 0.02, 1 },
    .{ "project.line_width", 0, 2 },
    .{ "project.first_layer_line_width", 0, 2 },
    .{ "project.wall_count", 0, 50 },
    .{ "project.wall_thickness", 0, 50 },
    .{ "project.min_wall_line_width", 0, 2 },
    .{ "project.min_feature_size", 0, 2 },
    .{ "project.min_bead_width", 0, 2 },
    .{ "project.wall_transition_length", 0, 10 },
    .{ "project.wall_transition_angle", 1, 59 },
    .{ "project.wall_transition_filter_distance", 0.01, 1000 },
    .{ "project.wall_distribution_count", 1, 20 },
    .{ "project.top_thickness", 0, 20 },
    .{ "project.bottom_thickness", 0, 20 },
    .{ "project.skin_removal_width", 0, 10 },
    .{ "project.skin_expand_distance", 0, 20 },
    .{ "project.solid_infill_width", 0, 20 },
    .{ "project.skin_angle", -360, 360 },
    .{ "project.skin_angle_step", -180, 180 },
    .{ "project.skin_overlap", 0, 1 },
    .{ "project.skin_link_length", 0, 200 },
    .{ "project.infill_density", 0, 1 },
    .{ "project.infill_angle", -360, 360 },
    .{ "project.lightning_angle", 0, 80 },
    .{ "project.top_support_layers", 0, 20 },
    .{ "project.top_support_density", 0, 1 },
    .{ "project.infill_overlap", 0, 1 },
    .{ "project.infill_flow", 0.1, 3 },
    .{ "project.bridge_speed", 0.01, 1 },
    .{ "project.bridge_flow", 0.1, 2 },
    .{ "project.bridge_fan", 0, 1 },
    .{ "project.infill_layers", 1, 10 },
    .{ "project.ironing_flow", 0, 1 },
    .{ "project.ironing_spacing", 0.01, 2 },
    .{ "project.ironing_inset", 0, 10 },
    .{ "project.ironing_speed", 0.01, 1 },
    .{ "project.slope_smoothing_min_width", 0.05, 5 },
    .{ "project.slope_smoothing_max_width", 0.1, 10 },
    .{ "project.slope_smoothing_flow", 0, 2 },
    .{ "project.slope_smoothing_speed", 0.01, 1 },
    .{ "project.slope_ironing_passes", 1, 5 },
    .{ "project.slope_ironing_flow", 0, 1 },
    .{ "project.slope_ironing_speed", 0.01, 1 },
    .{ "project.outer_wall_speed", 0.01, 1 },
    .{ "project.inner_wall_speed", 0.01, 1 },
    .{ "project.skin_speed", 0.01, 1 },
    .{ "project.infill_speed", 0.01, 1 },
    .{ "project.first_layer_speed", 0.01, 1 },
    .{ "project.slow_layers", 0, 50 },
    .{ "project.outer_wall_accel", 0, 100000 },
    .{ "project.inner_wall_accel", 0, 100000 },
    .{ "project.skin_accel", 0, 100000 },
    .{ "project.infill_accel", 0, 100000 },
    .{ "project.travel_accel", 0, 100000 },
    .{ "project.first_layer_accel", 0, 100000 },
    .{ "project.retract_min_travel", 0, 100 },
    .{ "project.combing_max_distance", 0, 1000 },
    .{ "project.z_hop", 0, 10 },
    .{ "project.support_tree_angle", 0, 75 },
    .{ "project.support_tree_spacing", 0.5, 50 },
    .{ "project.support_tree_tip", 0, 10 },
    .{ "project.support_angle", 0, 90 },
    .{ "project.support_density", 0.01, 1 },
    .{ "project.support_xy_gap", 0, 10 },
    .{ "project.support_z_gap_layers", 0, 10 },
    .{ "project.support_interface_layers", 0, 20 },
    .{ "project.support_interface_density", 0.01, 1 },
    .{ "project.skirt_loops", 0, 50 },
    .{ "project.skirt_distance", 0, 50 },
    .{ "project.skirt_layers", 0, 50 },
    .{ "project.brim_width", 0, 50 },
    .{ "project.first_layer_xy_offset", -2, 2 },
    // engine
    .{ "engine.resolution", 0.0005, 0.5 },
    .{ "engine.gap_closing", 0, 10 },
    .{ "engine.threads", 0, 256 },
};

/// The limits of a setting, or null for a setting with none.
pub fn limitOf(name: []const u8) ?[2]f64 {
    for (limits) |l| if (std.mem.eql(u8, l[0], name)) return .{ l[1], l[2] };
    return null;
}

test "limits: each number has one, and each default is in it" {
    const d: Settings = .{};
    inline for (@typeInfo(Settings).@"struct".fields) |g| {
        const group = @field(d, g.name);
        inline for (@typeInfo(g.type).@"struct".fields) |f| {
            const is_number = switch (@typeInfo(f.type)) {
                .float, .int => true,
                else => false,
            };
            if (is_number) {
                const name = g.name ++ "." ++ f.name;
                const l = limitOf(name) orelse {
                    std.debug.print("no limit for {s}: add it to `limits` in src/settings.zig\n", .{name});
                    return error.TestUnexpectedResult;
                };
                const v: f64 = switch (@typeInfo(f.type)) {
                    .float => @field(group, f.name),
                    else => @floatFromInt(@field(group, f.name)),
                };
                try std.testing.expect(v >= l[0] and v <= l[1]);
            }
        }
    }
    var s: Settings = .{};
    try std.testing.expectError(error.OutOfRange, s.set("project.brim_width", "300"));
    try s.set("project.brim_width", "8");
    try std.testing.expectEqual(@as(f64, 8), s.project.brim_width);
}

/// A change of one setting, by its dotted name ("project.infill_density").
pub const Change = struct {
    name: []const u8,
    value: []const u8,
};

/// A change of one setting for the layers with a top z from z_min to z_max
/// (mm). The z range, and not the layer numbers, so that an override stays
/// on the same part of the print after a change of the layer height.
pub const Override = struct {
    z_min: f64,
    z_max: f64,
    name: []const u8,
    value: []const u8,

    pub fn covers(o: Override, z: f64) bool {
        return z >= o.z_min - 1e-6 and z <= o.z_max + 1e-6;
    }

    /// An override of the whole part (all layers): any project or filament
    /// setting can have one.
    pub fn wholePart(o: Override) bool {
        return o.z_min <= -part_z and o.z_max >= part_z;
    }
};

/// A z range from -part_z to part_z covers all layers of any part.
pub const part_z: f64 = 1e5;

/// The settings that are the same for all the parts of a plate (see
/// plate_job.zig). One extruder prints all parts, and the G-code merges
/// the layers of all parts, so these come from the plate:
///
/// - the filament itself and its temperatures (one hot end, one bed);
/// - the cooling: the fan and the minimum layer time act on a layer of
///   the plate, with the paths of all parts in it;
/// - the travel: retraction, z hop, and combing act on the moves between
///   the paths and between the parts;
/// - the first layer height: all parts start their layers on the bed at
///   the same z;
/// - the skirt and the brim, which go around all parts, and the placement.
///
/// The machine and engine settings are for the whole slice too.
pub const plate_settings = [_][]const u8{
    "filament.name",                  "filament.material",          "filament.color",
    "filament.diameter",              "filament.density",           "filament.price_per_kg",
    "filament.nozzle_temp",           "filament.first_layer_nozzle_temp", "filament.bed_temp",
    "filament.standby_temp",          "filament.fan_speed",         "filament.fan_off_layers",
    "filament.fan_max_speed",         "filament.fan_boost_time",    "filament.min_layer_time",
    "filament.min_speed",             "filament.cooling_mode",      "filament.retract_ratio",
    "project.first_layer_height",     "project.retract_min_travel", "project.combing",
    "project.combing_max_distance",   "project.z_hop",              "project.z_hop_only_crossing",
    "project.retract_layer_change",   "project.travel_accel",       "project.skirt_loops",
    "project.skirt_distance",         "project.skirt_layers",       "project.brim_width",
    "project.placement",
};

/// True for a setting that is the same for all the parts of a plate (see
/// `plate_settings`).
pub fn isPlateSetting(name: []const u8) bool {
    if (!isPartSetting(name)) return true;
    for (plate_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The settings that one part of the plate can have of its own in a
/// slice (see part_settings.zig and plate_job.zig): each part slices as
/// its own job, so all the project and filament settings except the
/// ones of the plate (`isPlateSetting`). Walls, layer height, seam,
/// speeds, infill, skin, support, and flow can differ from part to part.
pub fn isPerPartSetting(name: []const u8) bool {
    return isPartSetting(name) and !isPlateSetting(name);
}

/// A setting that the part can change: the project and filament settings.
/// The machine settings describe the printer, and the engine settings the
/// slicer.
pub fn isPartSetting(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "project.") or std.mem.startsWith(u8, name, "filament.");
}

/// The settings that can change from one layer to the next. The others
/// are for the whole print: the first layer settings, the skirt and the
/// brim, the support areas (a column goes through many layers), the
/// shrinkage, the facts of the filament, and the machine.
/// docs/internals/layer-settings.md has the list, with the reason for each
/// setting that is not here.
pub const layer_settings = [_][]const u8{
    "project.wall_count",
    "project.seam",
    "project.top_thickness",
    "project.bottom_thickness",
    "project.skin_pattern",
    "project.skin_angle",
    "project.skin_overlap",
    "project.skin_link_length",
    "project.gap_fill",
    "project.infill_density",
    "project.infill_pattern",
    "project.infill_angle",
    "project.infill_angles",
    "project.infill_stack",
    "project.infill_flow",
    "project.infill_ribs",
    "project.bridges",
    "project.bridge_speed",
    "project.bridge_flow",
    "project.bridge_fan",
    "project.infill_overlap",
    "project.infill_layers",
    "project.ironing",
    "project.ironing_flow",
    "project.ironing_spacing",
    "project.ironing_inset",
    "project.ironing_speed",
    "project.outer_wall_speed",
    "project.inner_wall_speed",
    "project.skin_speed",
    "project.infill_speed",
    "project.slope_smoothing",
    "project.slope_smoothing_min_width",
    "project.slope_smoothing_max_width",
    "project.slope_smoothing_flow",
    "project.slope_smoothing_speed",
    "project.slope_ironing",
    "project.slope_ironing_passes",
    "project.slope_ironing_flow",
    "project.slope_ironing_speed",
    // The G-code writer reads these from the settings of each layer.
    "filament.nozzle_temp",
    "filament.bed_temp",
    "filament.flow_ratio",
    "filament.retract_ratio",
    "filament.fan_speed",
    "filament.fan_max_speed",
    "filament.fan_boost_time",
    "filament.min_layer_time",
    "filament.min_speed",
    "filament.cooling_mode",
    "project.retract_min_travel",
    "project.combing",
    "project.combing_max_distance",
    "project.z_hop",
    // The layer planner reads these from the settings of each layer.
    "project.line_width",
    "project.wall_thickness",
    "project.thin_walls",
    "project.wall_generator",
    "project.min_wall_line_width",
    "project.min_feature_size",
    "project.min_bead_width",
    "project.wall_transition_length",
    "project.wall_transition_angle",
    "project.wall_transition_filter_distance",
    "project.wall_distribution_count",
    "project.skin_removal_width",
    "project.skin_expand_distance",
    "project.solid_infill_width",
    "project.skin_angle_step",
    "project.infill_connect",
    "project.top_support_layers",
    "project.top_support_density",
    "project.support_density",
    "project.support_interface_density",
    "project.outer_wall_accel",
    "project.inner_wall_accel",
    "project.skin_accel",
    "project.infill_accel",
    "project.travel_accel",
    "filament.max_flow",
    // Pass 1 of the engine reads these for each layer. A layer gets the
    // layer height of the span that holds its top (see slicer.HeightSpan).
    "project.layer_height",
    "filament.xy_offset",
    "filament.hole_xy_offset",
};

pub fn isLayerSetting(name: []const u8) bool {
    for (layer_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The settings with the overrides that cover z, in their order.
pub fn withOverrides(base: Settings, overrides: []const Override, z: f64) Settings.SetError!Settings {
    var s = base;
    for (overrides) |o| if (o.covers(z)) try s.set(o.name, o.value);
    return s;
}

test "overrides cover a z range" {
    const list = [_]Override{
        .{ .z_min = 1, .z_max = 2, .name = "project.infill_density", .value = "0.5" },
        .{ .z_min = 1.5, .z_max = 9, .name = "project.infill_density", .value = "0.7" },
    };
    const base: Settings = .{};
    try std.testing.expectEqual(@as(f64, 0.2), (try withOverrides(base, &list, 0.5)).project.infill_density);
    try std.testing.expectEqual(@as(f64, 0.5), (try withOverrides(base, &list, 1.2)).project.infill_density);
    // The later override wins where both cover.
    try std.testing.expectEqual(@as(f64, 0.7), (try withOverrides(base, &list, 1.8)).project.infill_density);
    try std.testing.expect(isLayerSetting("project.skin_angle"));
    try std.testing.expect(isLayerSetting("project.layer_height"));
    try std.testing.expect(!isLayerSetting("project.first_layer_height"));
    try std.testing.expect(!isLayerSetting("project.support_angle"));
}
