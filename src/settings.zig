//! Settings, in three parts that have different owners.
//!
//! - `Machine`: facts about the printer. They change only when the printer
//!   changes. Examples: the bed size, the nozzle, the speed limits, the
//!   acceleration of each feature, and the retraction of the travels.
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
//!
//! A printer with more than one nozzle has the settings of each nozzle
//! after the first in `Machine.nozzle` (`Nozzle`), by names with the
//! number of the nozzle: "machine.nozzle.3.diameter". A value of 0 is the
//! value of the first nozzle. The tool change settings have the meaning
//! of the ooze prevention and the extruder offset of PrusaSlicer and the
//! preheat time of OrcaSlicer (see docs/references/prusaslicer.md and
//! docs/references/orcaslicer.md).

const std = @import("std");
const flow = @import("flow.zig");

pub const InfillPattern = enum { lines, grid, triangles, trihexagon, cubic, gyroid, concentric, honeycomb, zigzag, flow, lightning };
pub const SeamMode = enum { hidden, sharpest, rear, nearest, random };
/// The corners that the sharpest seam looks for. See `Project.seam_corner`.
pub const SeamCorner = enum { auto, none, inner, outer, any, weighted };
/// Where the grid of the sparse infill starts: the center of each part (a
/// symmetric part gets symmetric infill, and copies of a part get the same
/// infill), or the origin of the bed (the infill of all parts lines up).
pub const InfillAnchor = enum { part, bed };
pub const WallGenerator = enum { classic, arachne };
/// The order of the walls of an island (see `Project.wall_order`).
pub const WallOrder = enum { inner_first, outer_first };
/// The walls with fuzzy skin (see `Project.fuzzy_skin`).
pub const FuzzySkin = enum { off, outer_wall, outside };
/// The shape of the root of a painted feature. See
/// `Project.paint_anchor_shape`.
pub const AnchorShape = enum { footprint, core };
/// How the top and bottom skin is filled. See `Project.skin_pattern`.
pub const SkinPattern = enum { lines, monotonic, concentric };
/// Where the part goes on the bed. See `Project.placement`.
pub const Placement = enum { auto, file, center };
/// The order of the parts of a plate. See `Project.print_sequence`.
pub const PrintSequence = enum { by_layer, by_object };

/// Where the brim goes. See `Project.brim_location`.
pub const BrimLocation = enum { outside, inside, everywhere };
pub const SupportMode = enum { off, everywhere, buildplate };
/// How a short layer gets its cooling time. See `Filament.cooling_mode`.
pub const CoolingMode = enum { slow_down, lap };
/// Where a travel can comb. See `Project.combing_mode`.
pub const CombingMode = enum { all, not_in_skin, not_on_top, within_infill, off };
/// The shape of the support. See `Project.support_style`.
pub const SupportStyle = enum { grid, tree, bridge };
/// The lines of the support interface. See `Project.support_interface_pattern`.
pub const InterfacePattern = enum { lines, grid, dots };
/// The G-code dialect for the acceleration commands. See `Machine.gcode_flavor`.
pub const GcodeFlavor = enum { marlin, klipper, reprap, repetier };
pub const ExtruderKind = enum { direct, bowden };
/// How the printer changes to another filament. See `Machine.filament_change`.
pub const FilamentChange = enum { pause, tool };
/// How the motors move the head. See `Machine.kinematics`.
pub const Kinematics = enum { cartesian, corexy };
/// The build plate on the bed. See `Machine.bed_type`.
pub const BedType = enum {
    cool_plate,
    engineering_plate,
    high_temp_plate,
    textured_pei_plate,
    supertack_plate,

    /// The name of Bambu Studio and OrcaSlicer (curr_bed_type).
    pub fn studioName(b: BedType) []const u8 {
        return switch (b) {
            .cool_plate => "Cool Plate",
            .engineering_plate => "Engineering Plate",
            .high_temp_plate => "High Temp Plate",
            .textured_pei_plate => "Textured PEI Plate",
            .supertack_plate => "Supertack Plate",
        };
    }
};
/// The material of the nozzle. See `Machine.nozzle_type`.
pub const NozzleType = enum { hardened_steel, stainless_steel, tungsten_carbide, brass };
/// The flow of the hot end. See `Machine.nozzle_flow`.
pub const NozzleFlow = enum { standard, high_flow };
/// The number of a tool change command. See `Machine.tool_numbers`.
pub const ToolNumbers = enum { filament, nozzle };

/// The most nozzles of a printer (`Machine.nozzles`).
pub const max_nozzles = 16;

/// The settings of one nozzle after the first, on a printer with more
/// than one nozzle (`Machine.nozzle`). Each nozzle has its own hot end. A
/// value of 0 is the value of the first nozzle: the nozzle is the same as
/// the first, and only its differences need a value. The setting names
/// are `machine.nozzle.k.diameter` and the others, for nozzle k (tool Tk)
/// from 1.
pub const Nozzle = struct {
    /// The diameter of this nozzle, in mm. 0: `nozzle_diameter`. With the
    /// automatic line width (`project.line_width = 0`), its lines are 1.1
    /// times this wide.
    diameter: f64 = 0,
    /// The line width of the walls, the skin, and the infill of this
    /// nozzle, in mm. 0: the line width of the first nozzle, times
    /// `diameter` / `nozzle_diameter`. The first layer gets the same ratio
    /// to its own width.
    line_width: f64 = 0,
    /// The speed of the lines of this nozzle, as a ratio of the speed that
    /// the same line gets on the first nozzle. The ratios of the features
    /// to each other stay. 0: the same speeds. Travel moves keep
    /// `travel_speed`.
    speed: f64 = 0,
    /// The highest speed of the lines of this nozzle, in mm/s, after
    /// `speed`. 0: no limit of its own. A Bambu Lab X2D prints with its
    /// second nozzle (a bowden extruder) at most at 200 mm/s.
    max_speed: f64 = 0,
    /// The highest acceleration of the lines of this nozzle, in mm/s². 0:
    /// no limit of its own. The G-code has it only with `accel_control`;
    /// the time estimate always uses it.
    max_accel: f64 = 0,
    /// The retraction length of this nozzle, in mm. 0: `retract_length`.
    /// The X2D feeds its second nozzle through a bowden tube: Bambu Studio
    /// retracts 2 mm there and 0.8 mm on the first.
    retract_length: f64 = 0,
    /// The speed of the filament in a retraction of this nozzle, in mm/s.
    /// 0: `retract_speed`.
    retract_speed: f64 = 0,
    /// The position of this nozzle from the first nozzle in X, in mm, when
    /// the firmware does not correct it (the tool offset). The G-code
    /// moves the head by minus this offset for the lines and the travels
    /// of this nozzle. As extruder_offset in PrusaSlicer. 0: the firmware
    /// corrects the offset (Prusa XL, Bambu Lab X2D, Klipper tool
    /// changers with offsets in printer.cfg).
    offset_x: f64 = 0,
    /// The position of this nozzle from the first nozzle in Y, in mm. See
    /// `offset_x`.
    offset_y: f64 = 0,
    /// The left edge of the area that this nozzle reaches, in bed X (mm).
    /// The second nozzle of the X2D stops 20.5 mm from the left side of
    /// the bed. 0: the left side of the bed.
    min_x: f64 = 0,
    /// The right edge of the area that this nozzle reaches, in bed X (mm).
    /// 0: the right side of the bed.
    max_x: f64 = 0,
    /// The highest z that this nozzle reaches (mm). 0: `max_height`.
    max_height: f64 = 0,
    /// The temperature change of this nozzle while it waits, in °C. 0:
    /// `standby_delta`.
    standby_delta: f64 = 0,
    /// The time before a change to this nozzle at which it heats, in
    /// seconds. 0: `preheat_time`.
    preheat_time: f64 = 0,
};

pub const Machine = struct {

    // Printer
    /// The name of the printer, for the G-code header.
    name: []const u8 = "generic",
    /// The id of the printer model in the printer library, for example
    /// "creality-ender-3-v2". The 3D view shows the bed model of this
    /// printer. Empty: the view shows the bed as a grid.
    model: []const u8 = "",

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
    /// The build plate on the bed, for a printer with plates that change
    /// (Bambu Lab): the start G-code of the printer uses it
    /// ({curr_bed_type}), and the printer checks it against the plate that
    /// it sees.
    bed_type: BedType = .textured_pei_plate,

    // Nozzle
    /// The diameter of the nozzle hole. The default line width comes from it.
    nozzle_diameter: f64 = 0.4,
    /// The material of the nozzle. A Bambu Lab printer checks it against
    /// the nozzle that it has (the file names it), and a hard filament
    /// (with carbon or glass fiber) needs hardened steel or tungsten
    /// carbide.
    nozzle_type: NozzleType = .hardened_steel,
    /// The flow of the hot end: `standard`, or `high_flow` (a longer melt
    /// zone). A Bambu Lab printer checks it against its nozzle.
    nozzle_flow: NozzleFlow = .standard,
    /// The radius of the flat face at the tip of the nozzle, around the
    /// hole. A common brass nozzle has a face about 1 mm across. Slope
    /// smoothing uses it to keep the nozzle off the layer that it just
    /// printed.
    nozzle_tip_radius: f64 = 0.5,
    /// The angle between the axis of the nozzle and the side of its cone,
    /// in degrees. Slope smoothing uses it with `nozzle_tip_radius`.
    nozzle_cone_angle: f64 = 45,

    // Chamber and fans
    /// The temperature of the air around the print, in °C: the room for an
    /// open printer, about 35 to 45 in a closed box with no heater, or the
    /// set point of a heated chamber. The simulated print cools the plastic
    /// toward it.
    chamber_temp: f64 = 25,
    /// The speed of the air of the part cooling fans at full speed where the
    /// plastic leaves the nozzle, in m/s, of all the fans together. The
    /// simulated print cools the plastic with it. About 5 to 10 for a
    /// radial blower and a duct.
    part_fan_air: f64 = 6,

    // Motion
    /// The maximum speed of the print head in X and Y.
    max_speed: f64 = 150,
    /// The speed of travel moves (moves with no extrusion).
    travel_speed: f64 = 150,
    /// The speed of the travel moves of the first layer, in mm/s. A slower
    /// travel does not pull the new lines off the bed. 0: `travel_speed`.
    /// As "Initial Layer Travel Speed" in Cura and "Initial layer travel
    /// speed" in OrcaSlicer.
    first_layer_travel_speed: f64 = 0,
    /// The speed of Z moves at each layer change.
    max_z_speed: f64 = 10,
    /// The acceleration of Z moves (the layer change and the z hop), in
    /// mm/s². Only the time estimate uses it.
    max_z_accel: f64 = 100,
    /// The cost of one hour of this printer, in your currency: the power,
    /// the wear, and the time of the machine. A print costs its hours times
    /// this, and its filament. 0: only the filament counts.
    hour_rate: f64 = 0,
    /// The acceleration of the print head in X and Y, in mm/s². The time
    /// estimate uses it, and it is the acceleration of each feature that
    /// has no acceleration of its own (0 in `outer_wall_accel` and the
    /// others).
    max_accel: f64 = 1500,
    /// The speed at which the head turns a corner with no stop (jerk in
    /// Marlin, square corner velocity in Klipper), in mm/s. The time
    /// estimate uses it.
    corner_speed: f64 = 8,
    /// How the motors move the head, for the time estimate. `cartesian`: a
    /// motor for X and one for Y (also a bed slinger, which moves the bed
    /// on Y). `corexy`: two motors, A = X + Y and B = X - Y, both on the
    /// frame. With per-axis limits (`max_accel_x` and the others) and
    /// Marlin, the limits of a CoreXY apply to its motors: a diagonal move
    /// turns one motor at 1.41 times the speed of the head.
    kinematics: Kinematics = .cartesian,
    /// The acceleration limit of the X axis (of motor A on a CoreXY with
    /// Marlin), in mm/s², as the firmware has it (M201 X). 0: `max_accel`.
    /// Klipper has one limit for all directions: leave it at 0.
    max_accel_x: f64 = 0,
    /// The acceleration limit of the Y axis (of motor B on a CoreXY with
    /// Marlin), in mm/s² (M201 Y). A bed slinger moves the bed on Y and
    /// has a lower limit. 0: `max_accel`.
    max_accel_y: f64 = 0,
    /// The speed limit of the X axis (M203 X), in mm/s. 0: `max_speed`.
    max_speed_x: f64 = 0,
    /// The speed limit of the Y axis (M203 Y), in mm/s. 0: `max_speed`.
    max_speed_y: f64 = 0,
    /// Write acceleration commands in the G-code: the acceleration of each
    /// feature (`outer_wall_accel` and the others), and the corner speed
    /// at the start.
    /// Off: the printer uses its own values; the time estimate still uses
    /// `max_accel` and `corner_speed`.
    accel_control: bool = false,
    /// The G-code dialect of the acceleration commands. `marlin`: M204 S and
    /// M205 X Y. `klipper`: SET_VELOCITY_LIMIT ACCEL and
    /// SQUARE_CORNER_VELOCITY. `reprap` (RepRapFirmware): M204 P T and M566
    /// X Y. `repetier`: M201 X Y and M207 X.
    gcode_flavor: GcodeFlavor = .marlin,

    // Acceleration
    /// The acceleration of the outer wall, in mm/s². A lower value gives a
    /// cleaner surface. 0: `max_accel`. The G-code has it only with
    /// `accel_control`. Each printer has its own value.
    outer_wall_accel: f64 = 0,
    /// The acceleration of the inner walls and the skirt, in mm/s². 0:
    /// `max_accel`.
    inner_wall_accel: f64 = 0,
    /// The acceleration of the skin, in mm/s². The bridges, the ironing,
    /// and the support interface use it too. 0: `max_accel`.
    skin_accel: f64 = 0,
    /// The acceleration of the sparse infill and the support, in mm/s². 0:
    /// `max_accel`.
    infill_accel: f64 = 0,
    /// The acceleration of travel moves, in mm/s². 0: `max_accel`.
    travel_accel: f64 = 0,
    /// The acceleration of all lines on the first layer, in mm/s². 0: the
    /// acceleration of each feature.
    first_layer_accel: f64 = 0,

    // Extruder
    /// The extruder type. `direct`: the motor is on the print head. `bowden`: the motor pushes the filament through a long tube.
    extruder: ExtruderKind = .direct,
    /// The retraction length of this extruder. A bowden extruder needs more.
    retract_length: f64 = 0.8,
    /// The speed of the filament during a retraction.
    retract_speed: f64 = 40,

    // Travel retraction
    /// Travel moves shorter than this do not retract. Each printer has its
    /// own value (Bambu Studio: 1 mm).
    retract_min_travel: f64 = 1.5,
    /// Lift the nozzle by this distance during a travel move with a
    /// retraction, in mm. 0 turns it off. The nozzle then does not drag
    /// over the printed lines (the tops of the support too).
    z_hop: f64 = 0,
    /// Lift the nozzle (`z_hop`) only for a travel that leaves the part or
    /// crosses an edge of the layer (a hole), and for a travel to or from
    /// the support. A travel in a straight line inside the part (it
    /// retracts because it is longer than `combing_max_distance`) does not
    /// lift. Off: each travel with a retraction lifts.
    z_hop_only_crossing: bool = true,
    /// A retraction before a travel that leaves the part moves the nozzle
    /// on a small circle inside the part while the filament pulls back:
    /// the plastic that oozes goes inside, and not onto the surface or
    /// into a string. The circle stays clear of the outer wall by half a
    /// line width. With no room for it (a thin part, the support), the
    /// nozzle moves back along the line that it printed last. A travel
    /// that stays inside the part has no wipe.
    retract_wipe: bool = false,
    /// The length of the wipe (`retract_wipe`), in mm: the length of the
    /// circle, or of the move back along the last line. 0: 1.9 mm (a
    /// circle of 0.4 mm radius).
    retract_wipe_distance: f64 = 0,
    /// Retract at each layer change. Off: the travel to the first path of
    /// the layer retracts by the rules of the other travels (combing).
    /// Off by default, as in Cura.
    retract_layer_change: bool = false,

    // Filament change
    /// How the printer changes to another filament of the plate.
    /// `pause`: one filament path; the print pauses (M600) and you change
    /// the filament by hand. `tool`: a unit that feeds many filaments (a
    /// Bambu Lab AMS, a Prusa MMU) changes it with a tool change (T0, T1,
    /// and on).
    filament_change: FilamentChange = .pause,
    /// The number of nozzles of the printer, 1 to 16. Each nozzle has its
    /// own hot end, and each filament prints with its own nozzle
    /// (`filament.nozzle`). Examples: 2 on the Bambu Lab X2D and H2D and
    /// on an IDEX printer, 5 on a Prusa XL 5T, 8 on a CORE One INDX 8T.
    /// The first nozzle has the settings of the Nozzle section. Each other
    /// nozzle has a section of its own (`nozzle.k.diameter` and the
    /// others), with the values of the first nozzle as defaults.
    nozzles: u32 = 1,
    /// The number n of a tool change command Tn. `filament`: the filament
    /// (from 0). A unit that feeds many filaments (a Bambu Lab AMS, a
    /// Prusa MMU) and the Bambu Lab X2D and H2D use it. `nozzle`: the
    /// nozzle of the filament (from 0), for a printer with a hot end for
    /// each filament (a tool changer, an IDEX printer). Two filaments on
    /// one nozzle then change with a pause (M600).
    tool_numbers: ToolNumbers = .filament,
    /// The right edge of the area that the first nozzle reaches, in bed X
    /// (mm). The left nozzle of the H2D stops 25 mm from the right side.
    /// 0: the whole bed.
    nozzle1_max_x: f64 = 0,
    /// The highest z that the first nozzle reaches (mm). 0: `max_height`.
    nozzle1_max_height: f64 = 0,
    /// The temperature of a nozzle that waits for its next filament on a
    /// printer with more than one nozzle, in °C, as a change from the
    /// print temperature of its filament: -110 waits 110 °C below it. 0:
    /// the nozzle keeps its temperature. A filament with a
    /// `standby_temp` waits at that temperature. The next nozzle heats
    /// again before its first line. As "Temperature variation" of the
    /// ooze prevention in PrusaSlicer (standby_temperature_delta). A
    /// Bambu Lab X2D or H2D waits 10 °C below, as in Bambu Studio.
    standby_delta: f64 = 0,
    /// The time before a change to another nozzle at which that nozzle
    /// heats to its print temperature, in seconds. It is then hot, or
    /// almost hot, at the change. 0: it heats at the change. As "Preheat
    /// time" in OrcaSlicer. Only a change in the middle of a layer gets a
    /// preheat.
    preheat_time: f64 = 0,
    /// The text of a filament change. Empty: zslice writes the command of
    /// the G-code flavor (M600 for a pause, Tn for a tool change). The
    /// variables of Bambu Studio and PrusaSlicer work here:
    /// {next_extruder}, {previous_extruder}, [next_filament_id],
    /// [flush_length], [new_filament_temp], [old_filament_temp],
    /// {layer_z}, {max_layer_z}, and {toolchange_count}.
    change_gcode: []const u8 = "",
    /// The time of one filament change, in seconds, for the time estimate:
    /// the cut, the unload, the load, and the flush. A pause counts this
    /// time too, but the real time depends on you.
    change_time: f64 = 40,
    /// The plastic (mm³) that the nozzle flushes after a change to a
    /// filament of the same color. A change from a dark color to a light
    /// color flushes up to 5 times more (see `project.flush_multiplier`).
    /// A pause flushes nothing: you push the new filament through by hand.
    flush_volume: f64 = 140,

    // Other nozzles
    /// The settings of each nozzle after the first (`nozzles` > 1):
    /// `machine.nozzle.k.diameter` and the others, for nozzle k from 1
    /// (the second nozzle, tool T1) to 15. A value of 0 is the value of
    /// the first nozzle. Entry 0 has no use: the first nozzle has the
    /// settings of the Nozzle section.
    nozzle: [max_nozzles]Nozzle = [_]Nozzle{.{}} ** max_nozzles,

    // G-code
    /// The pictures of the print at the top of the G-code, for the screen
    /// of the printer: sizes in pixels, as "300x300,32x32" (PNG, the form
    /// of PrusaSlicer and Klipper). Empty: none.
    thumbnails: []const u8 = "",
    /// Label each part in the G-code, so the printer can skip a part that
    /// fails and print the others: EXCLUDE_OBJECT_DEFINE, _START, and _END
    /// on Klipper (it needs [exclude_object] in printer.cfg), and M486 on
    /// Marlin and RepRapFirmware. Off by default.
    label_objects: bool = false,

    // Head clearance
    /// The radius of a cylinder around the nozzle that holds the print
    /// head (the hot end, the fan ducts, the probe), in mm. With
    /// `project.print_sequence = by_object`, the parts keep this distance
    /// from each other, so the head does not hit a part that it printed
    /// before. As "extruder_clearance_radius" in PrusaSlicer and
    /// OrcaSlicer.
    clearance_radius: f64 = 40,
    /// The height from the tip of the nozzle to the lowest part of the
    /// gantry (the X axis rods or the frame of the head), in mm. With
    /// `project.print_sequence = by_object`, only the last part can be
    /// higher: the gantry passes over the parts before it. As
    /// "extruder_clearance_height" in PrusaSlicer and
    /// "extruder_clearance_height_to_rod" in OrcaSlicer.
    clearance_height: f64 = 40,
    /// The text before the print. These variables are replaced:
    /// {nozzle_temp}, {first_layer_nozzle_temp}, {bed_temp}, {standby_temp},
    /// {layer_height}, {first_layer_height}, {first_layer_speed} (mm/s),
    /// {nozzle_diameter}, {filament_diameter}, {filament_name},
    /// {machine_name}, and {job_name}. The variables and the expressions
    /// of Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio also work. A line
    /// with a variable that has no value becomes a comment. If the text
    /// does not heat the nozzle or the bed, zslice heats them before it.
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

    /// Nozzle `n` of the machine, from 0, or 0 for a nozzle that it does
    /// not have.
    pub fn nozzleIndex(m: Machine, n: u32) u32 {
        return if (n < m.nozzles and n < max_nozzles) n else 0;
    }

    /// The value of `field` of nozzle `k` (see `Nozzle`) if it has one (not
    /// 0), else null: the first nozzle, a nozzle that the machine does not
    /// have, and a nozzle with no value of its own.
    pub fn nozzleValue(m: Machine, k: u32, comptime field: []const u8) ?f64 {
        if (k == 0 or k >= m.nozzles or k >= max_nozzles) return null;
        const v = @field(m.nozzle[k], field);
        return if (v != 0) v else null;
    }

    /// The tool offset of nozzle `k` (mm): the head moves by minus it.
    pub fn nozzleOffset(m: Machine, k: u32) [2]f64 {
        if (k == 0 or k >= m.nozzles or k >= max_nozzles) return .{ 0, 0 };
        return .{ m.nozzle[k].offset_x, m.nozzle[k].offset_y };
    }

    /// The temperature change of nozzle `k` while it waits (°C; 0: it
    /// keeps its temperature).
    pub fn standbyDelta(m: Machine, k: u32) f64 {
        return m.nozzleValue(k, "standby_delta") orelse m.standby_delta;
    }

    /// The preheat time of nozzle `k` (s; 0: no preheat).
    pub fn preheatTime(m: Machine, k: u32) f64 {
        return m.nozzleValue(k, "preheat_time") orelse m.preheat_time;
    }
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
    /// The nozzle of this filament on a printer with more than one nozzle
    /// (`machine.nozzles`), from 0: 0 is the first (main) nozzle, 1 the
    /// second, and on. On the X2D, the AMS feeds the main nozzle, and the
    /// external spool feeds the second one. On a tool changer, the nozzle
    /// is the tool (T0, T1, and on). A printer with one nozzle: 0. A
    /// nozzle that the printer does not have prints on the first nozzle,
    /// and the Check tells it.
    nozzle: u32 = 0,
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
    /// The bed temperature on the first layer. From the second layer, the
    /// bed goes to `bed_temp` (M140, no wait). 0: `bed_temp` on all layers.
    /// As "Build Plate Temperature Initial Layer" in Cura and "Initial
    /// layer" bed temperature in OrcaSlicer.
    first_layer_bed_temp: f64 = 0,

    // Flow
    /// The maximum plastic flow that the hot end melts with this filament.
    /// This limits the speed of wide and tall lines.
    max_flow: f64 = 12,
    /// A multiplier for all extrusion, to calibrate the flow.
    flow_ratio: f64 = 1.0,
    /// The pressure advance of this filament, in seconds: the firmware
    /// pushes the filament ahead of a speed change by this time. zslice
    /// writes it after the start G-code (M900 K on Marlin,
    /// SET_PRESSURE_ADVANCE on Klipper, M572 on RepRapFirmware). 0: no
    /// command, so the value of the firmware stays. As "Pressure advance"
    /// in OrcaSlicer (`enable_pressure_advance` and `pressure_advance`).
    pressure_advance: f64 = 0,

    // Cooling
    /// The part cooling fan speed, as a ratio.
    fan_speed: f64 = 1.0,
    /// The fan is off for this number of layers at the start.
    fan_off_layers: u32 = 1,
    /// After the layers with the fan off, the fan speed goes up in steps
    /// over this number of layers: layer k of the ramp (from 1) gets
    /// k / (ramp + 1) of the fan speed. 0: full speed at once.
    fan_ramp_layers: u32 = 0,
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

    // G-code
    /// G-code after the start G-code of the machine, for this filament.
    /// The variables of the start G-code work here. Empty: none. As
    /// "Filament start G-code" in OrcaSlicer and PrusaSlicer.
    start_gcode: []const u8 = "",
    /// G-code before the end G-code of the machine, for this filament.
    /// Empty: none. As "Filament end G-code" in OrcaSlicer and PrusaSlicer.
    end_gcode: []const u8 = "",

    /// The bed temperature of the first layer: `first_layer_bed_temp`, or
    /// `bed_temp` if it is 0.
    pub fn firstBedTemp(f: Filament) f64 {
        return if (f.first_layer_bed_temp > 0) f.first_layer_bed_temp else f.bed_temp;
    }
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
    /// The order of the walls of each island. `inner_first`: the inner
    /// walls from the inside out, then the outer wall. The outer wall then
    /// lies against plastic, and an overhang prints better. `outer_first`:
    /// the outer wall first, then the inner walls from the outside in. The
    /// outer surface is then more exact (a better fit of holes and of
    /// parts that join), but an overhang can curl.
    wall_order: WallOrder = .inner_first,
    /// One more wall on each odd layer (layers 1, 3, 5, and so on). The
    /// walls of two layers then interlock with the infill, and the part
    /// is stronger across its layers. Off by default.
    alternate_extra_wall: bool = false,
    /// The speed of the parts of a wall that hang over air, as a ratio of
    /// the speed of the wall. A slower overhang has more time to cool, so
    /// it curls less. 1: the speed of the wall. A wall that hangs a whole
    /// line over air prints as a bridge (see `bridges`).
    overhang_wall_speed: f64 = 1,
    /// The fan while a wall overhang prints, from 0 to 1. The fan does not
    /// go below the fan of the layer. 0: the fan of the layer.
    overhang_wall_fan: f64 = 0,
    /// How far a wall must hang over air to print as an overhang (see
    /// `overhang_wall_speed`): the part of its line width that is outside
    /// the layer below, from 0 to 1. With a 0.2 mm layer and a 0.44 mm
    /// line, 0.5 is a slope of about 48 degrees.
    overhang_wall_threshold: f64 = 0.5,
    /// A rough surface: the nozzle moves to a random side along the outer
    /// wall, so the surface looks fuzzy and hides the layer lines and the
    /// seam. `off`: a smooth wall. `outer_wall`: each outer wall, the
    /// holes too. `outside`: only the outside of each part, and not its
    /// holes (a hole keeps its size). The first layer stays smooth.
    fuzzy_skin: FuzzySkin = .off,
    /// Fuzzy skin: the width of the band of the random points, in mm. A
    /// point goes up to half of it to the outside or to the inside of the
    /// wall. Keep it below the line width.
    fuzzy_skin_thickness: f64 = 0.3,
    /// Fuzzy skin: the mean distance between the random points, in mm.
    fuzzy_skin_point_distance: f64 = 0.8,
    /// Spiral vase mode: after the bottom layers, each layer prints only
    /// the outer wall of the part, and the nozzle rises along it, so the
    /// wall is one spiral with no seam. The part prints as a vase: no top,
    /// no infill, no inner walls, no holes. For a part with one outline on
    /// each layer. The bottom layers (`bottom_thickness`) print as usual.
    spiral_vase: bool = false,
    /// Polyholes: each round hole of a layer becomes a polygon with few
    /// sides (two for each mm of its diameter, at least 3), whose inner
    /// circle is the hole. A printed round hole shrinks, because each
    /// short segment of its wall cuts the corner; the flat sides of a
    /// polyhole print to size, so a pin or a screw fits. The method of
    /// nophead. Off by default.
    polyholes: bool = false,
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
    /// The corners that the `sharpest` seam looks for, as "Seam Corner
    /// Preference" in Cura. `auto`: the zslice score (an inside corner, or
    /// else the sharpest outside corner). `inner`: inside corners, the
    /// sharper the better. `outer`: outside corners. `any`: the sharpest
    /// corner of either kind. `weighted`: any corner, but an inside corner
    /// counts twice. `none`: no corner, so the seam goes to the back right.
    /// With the other kinds of seam it has no effect.
    seam_corner: SeamCorner = .auto,
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
    /// The skin and infill lines turn with the part: the turn of a part on
    /// the bed adds to `skin_angle` and `infill_angle`, so the lines keep
    /// their place on the part. Off: the angles are from the X axis of the
    /// bed for each part.
    angles_follow_part: bool = true,
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
    /// over the line ends of skin that is printed already. It prints at
    /// half the line width, as each link of a zigzag does, so it adds no
    /// ridge along the wall. The zigzags just below a zigzag print before it, so at a
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
    /// Where the grid of the sparse infill starts. "part": at the center of
    /// each part, so a part with two equal sides gets equal infill on both,
    /// and the copies of a part get the same infill. "bed": at the origin
    /// of the bed, as before.
    infill_anchor: InfillAnchor = .part,
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
    /// diameter or the line width of the nozzle of the infill (see
    /// `infill_filament`): the count goes down where the layers are too
    /// thick, and the Check tells it. Only the area that is sparse infill in all layers of a group
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
    /// The speed of the support lines, as a ratio of the allowed speed. 0:
    /// `infill_speed`. As "Support Infill Speed" in Cura and "Support"
    /// speed in OrcaSlicer.
    support_speed: f64 = 0,
    /// The speed of the support interface, as a ratio of the allowed speed.
    /// 0: `skin_speed`. As "Support Interface Speed" in Cura and "Support
    /// interface" speed in OrcaSlicer.
    support_interface_speed: f64 = 0,
    /// The speed of all lines on the first layer, as a ratio of the allowed speed.
    first_layer_speed: f64 = 0.3,
    /// The layers after the first that print slower: their speed goes up in
    /// even steps from the first layer speed to the full speed, so that
    /// the part bonds to the bed. 0: the second layer prints at full speed.
    slow_layers: u32 = 0,

    // Travel
    /// Combing: a travel move that stays inside the part (it crosses no
    /// outline of the layer) does not retract, because an ooze there is
    /// inside the part. The mode sets where the way can go, as the combing
    /// modes of Cura. `all`: anywhere in the part. `not_in_skin`: not
    /// over the top and bottom skin of the layer. `not_on_top`: not over
    /// the top surfaces (the area that no layer covers above). `within_infill`:
    /// only in the sparse infill. `off`: each travel longer than
    /// `retract_min_travel` retracts. A travel with no way in its area
    /// retracts, and lifts with `z_hop`.
    combing_mode: CombingMode = .all,
    /// A travel inside the part that is longer than this retracts all the
    /// same (a long move can ooze a string over a top surface). 0: no limit.
    combing_max_distance: f64 = 0,
    /// After a closed outer wall, the nozzle moves on along the start of
    /// the wall for this distance (mm), with no plastic, before the
    /// retraction. The end of the wall then joins its start with no gap,
    /// and the seam shows less. 0 turns it off.
    outer_wall_wipe: f64 = 0,
    /// Coasting: the last part of each path moves with no plastic, for
    /// this volume of plastic (mm³). The pressure in the nozzle prints it,
    /// so the end of the path has less of a blob, and the travel after it
    /// strings less. A path shorter than twice this volume prints as
    /// usual. 0 turns it off. Cura uses 0.064.
    coasting_volume: f64 = 0,
    /// The speed of the coasting moves, as a ratio of the speed of the
    /// path.
    coasting_speed: f64 = 0.9,

    // Support
    /// Support under overhangs. `off`: no support. `everywhere`: support
    /// can stand on the bed or on the part. `buildplate`: only support that
    /// stands on the bed.
    support: SupportMode = .off,
    /// The shape of the support. `grid`: all the space under each overhang,
    /// filled with lines. `tree`: branches from points under each overhang
    /// down to the bed or the part; they join on the way, get thicker as
    /// they go down, and thinner in narrow spaces (so a branch can go down
    /// a deep, narrow hole). Each branch prints as one wall loop, with
    /// lines only at its foot and under its tip. A tree uses less plastic
    /// and comes off more easily. `bridge`: only a sacrificial pad under each overhang (the
    /// interface layers, with the Z gap over it), with nothing under the
    /// pad. The pad bridges from the part around it, as a bridge does, and
    /// breaks off easily. For overhangs over a hole or a short gap, where
    /// a column down to the bed would be a waste.
    support_style: SupportStyle = .grid,
    /// Tree support: the largest angle of a branch from vertical, in
    /// degrees. A larger angle lets branches reach farther, with less
    /// strength.
    support_tree_angle: f64 = 50,
    /// Tree support: the distance of the tips under an overhang. Tips also
    /// go along the edges of each overhang, at the same distance.
    support_tree_spacing: f64 = 3,
    /// Tree support: the diameter of a tip. 0 uses the line width times 2.
    support_tree_tip: f64 = 0,
    /// An overhang that leans more than this angle (degrees) from vertical
    /// gets support. A larger angle gives less support.
    support_angle: f64 = 50,
    /// No support under a small ledge: a strip of overhang that is within
    /// this distance (mm) of the layer below at each point, with no new
    /// overhang on the layer above next to it (for example the underside of
    /// an embossed letter on a wall). The nozzle prints it as a short
    /// cantilever. A slope keeps its support: each layer of it adds a new
    /// strip. 0: 1.5 line widths. A tiny value (0.01) turns the rule off.
    support_min_ledge: f64 = 0,
    /// The fraction of the support area that the support lines fill, as a
    /// ratio.
    support_density: f64 = 0.15,
    /// The gap between the support and the sides of the part. Under an
    /// overhang, the gap is at most half a line width: the Z gap keeps the
    /// support off the overhang there.
    support_xy_gap: f64 = 0.6,
    /// The number of empty layers between the support and the part above
    /// it or under it, so that the support comes off.
    support_z_gap_layers: u32 = 1,
    /// The number of dense layers at the top of the support, under the
    /// part. They make the bottom surface of the part smooth.
    support_interface_layers: u32 = 2,
    /// The fraction of the interface area that its lines fill, as a ratio.
    support_interface_density: f64 = 0.7,
    /// The pattern of the support interface. `lines`: parallel lines.
    /// `grid`: lines in two directions, a flatter bed for the part.
    /// `dots`: the lines cut into short dabs, in rows that shift on each
    /// layer: little contact with the part, so the support breaks off
    /// easily and leaves a cleaner surface.
    support_interface_pattern: InterfacePattern = .lines,

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
    /// Where the brim goes. `outside`: around the outside of the part.
    /// `inside`: in the holes of the part, along their edges.
    /// `everywhere`: both.
    brim_location: BrimLocation = .outside,

    // First layer
    /// Moves the outline of the first layer by this distance. A negative
    /// value compensates the "elephant foot": the first layer spreads out
    /// because the nozzle presses it on the bed.
    first_layer_xy_offset: f64 = 0,

    // Placement
    /// Where the part goes on the bed. auto: at the X and Y of the file if
    /// the part is fully on the bed there, else at the center of the bed;
    /// a model added to a plate with parts gets smart placement (its best
    /// orientation, then a free spot), and the parts on the plate stay.
    /// file: always at the X and Y of the file. center: always at the
    /// center of the bed. The bottom of the part always goes to z = 0.
    placement: Placement = .auto,
    /// The order of the parts of the plate. `by_layer`: each layer of all
    /// parts, then the next layer. `by_object`: one part from the bottom
    /// to the top, then the next part, in the order of the plate list.
    /// Between the parts, the head goes up over the printed parts. The
    /// parts must keep `machine.clearance_radius` from each other, and
    /// only the last part can be higher than `machine.clearance_height`
    /// (the Check lists each problem). A part that fails then stops only
    /// itself, and a part has no strings to the others. No prime tower.
    print_sequence: PrintSequence = .by_layer,

    // Outlines
    /// The largest change to the shape (mm) that the slicer makes when it
    /// removes points from the mesh outlines. A larger value gives fewer
    /// points and a faster slice, and changes the G-code: 0.01 slices a
    /// 3DBenchy about 19 % faster, and moves its outer walls up to 10 µm.
    /// The name before: `engine.resolution`.
    resolution: f64 = 0.005,

    // Experimental
    /// An experiment: a faster offset of the outlines. A closing corner
    /// of an offset gets the crossing point of its two edges in place of a
    /// small loop that a union then removes. A slice uses about 11 % less
    /// CPU. The outer walls stay within about 1.4 micrometers; some skin
    /// and fill lines move more than that where a thin piece is at a
    /// threshold, so a thin piece of skin can come or go. Off: the offsets
    /// of before, and the same G-code. The switch is for the whole app:
    /// the last slice that starts sets it.
    fast_offsets: bool = false,

    // Filaments
    /// The filament that prints this part, or these layers: 1 is the first
    /// filament of the plate, 2 the second, and so on. A change at a layer
    /// is a filament change in the G-code.
    filament: u32 = 1,
    /// The filament of the support: 1 is the first filament of the plate,
    /// 2 the second, and so on. 0: the filament of the part. A filament
    /// for support only (one that breaks away, or one that dissolves in
    /// water) makes support easy to take off. On a printer with more than
    /// one nozzle, the support prints with the nozzle of that filament.
    support_filament: u32 = 0,
    /// The filament of the support interface (the layers that touch the
    /// part). 0: the support filament.
    support_interface_filament: u32 = 0,
    /// The filament of the sparse infill: 1 is the first filament of the
    /// plate, 2 the second, and so on. 0: the filament of the part. On a
    /// printer with more than one nozzle, a filament of another nozzle
    /// prints the infill with that nozzle, at its line width. With combined
    /// infill (`infill_layers` above 1), this filament prints only the
    /// tall beads, and the filament of the part prints the narrow areas of
    /// infill that print on each layer: the nozzle then changes once in
    /// each group of layers.
    infill_filament: u32 = 0,
    /// A prime tower for a printer that changes the filament with a tool
    /// change (`machine.filament_change = tool`): after each change, the
    /// nozzle flushes the old color out into a small tower next to the
    /// parts, and wipes there, before the new filament touches the part.
    /// The tower grows on each layer up to the last change (its wall, a
    /// solid base under the next prime, and sparse lines), so it is at the
    /// height of the nozzle at each change.
    /// A Bambu Lab printer flushes into its chute (its change G-code); its
    /// tower then gets a prime of 45 mm³ of the new filament.
    prime_tower: bool = true,
    /// A prime tower for each family of materials that bond (PLA, PETG,
    /// ABS and ASA, and the others): a change purges into the tower of
    /// the new filament, so PETG never purges on PLA. Each tower grows on
    /// each layer up to its last change; on a layer with no filament of
    /// its family, its wall and its inside print with the filament in the
    /// nozzle. With one family, one tower.
    prime_tower_split: bool = true,
    /// The width of the square prime tower.
    prime_tower_width: f64 = 20,
    /// The brim of the prime tower (mm): loops around the first layer of
    /// the tower, so it holds to the bed. 0: no brim.
    prime_tower_brim: f64 = 3,
    /// The loops of the wall of the prime tower. The rows of each prime
    /// end on the inner loop. More loops make a stiffer tower that holds
    /// to the bed better, and use more plastic.
    prime_tower_wall_loops: u32 = 4,
    /// Ribs at the four corners of the prime tower: two strips along its
    /// diagonals stick out at the corners, so the wall has a wavy outline
    /// and the tower is stiff. As the rib wall of Bambu Studio. Off: a
    /// square wall.
    prime_tower_rib_wall: bool = true,
    /// The width of a rib of the prime tower (mm), at most half the side
    /// of the tower.
    prime_tower_rib_width: f64 = 8,
    /// The length of the ribs of the prime tower past its diagonal on the
    /// bed (mm). The extra length gets less on each layer, to 0 at the
    /// top. The ribs are never shorter than the diagonal.
    prime_tower_extra_rib_length: f64 = 0,
    /// Round corners on the wall of a prime tower with ribs.
    prime_tower_fillet_wall: bool = true,
    /// The x of the center of the prime tower on the bed. -1: near the
    /// right side.
    prime_tower_x: f64 = -1,
    /// The y of the center of the prime tower. -1: near the back.
    prime_tower_y: f64 = -1,
    /// A multiplier for the flush volume of each filament change (see
    /// `machine.flush_volume`). Lower wastes less plastic. Too low mixes
    /// the old color into the new one.
    flush_multiplier: f64 = 1,
    /// After a change to a filament, the nozzle first prints the hidden
    /// lines of that filament on the layer: its sparse infill and its
    /// support body. The old color goes into them, so the flush of the
    /// change is less by their volume. A change between two families of
    /// materials (see `prime_tower_split`) flushes into the support body
    /// only. The walls and the skin print after.
    flush_into_hidden: bool = true,
    /// A painted feature that stands on the part, for example a raised
    /// letter or frame in another filament, grows down into the part by
    /// this depth (mm). This hidden root of its filament replaces the
    /// infill of the part under the feature, so the feature holds to the
    /// part. The root stays inside the walls of the part: the outside of
    /// the part keeps its color. Each layer of the root adds a filament
    /// change. 0: no root.
    paint_anchor_depth: f64 = 1.0,
    /// The shape of the root of a painted feature (see
    /// `paint_anchor_depth`). `footprint`: all the area where the feature
    /// stands on the part, inside the walls of the part. `core`: only the
    /// middle of that area, inside the walls of the feature. A thin
    /// feature gets no core.
    paint_anchor_shape: AnchorShape = .footprint,

    /// The number of walls on layer `layer`: `wall_count`, and one more on
    /// an odd layer with `alternate_extra_wall`.
    pub fn wallCountAt(p: Project, layer: usize) u32 {
        if (p.alternate_extra_wall and p.wall_count > 0 and layer % 2 == 1) return p.wall_count + 1;
        return p.wall_count;
    }
};

/// Options for the engine. They do not change the print.
pub const EngineOptions = struct {

    // Slicer
    /// The largest gap (mm) that the slicer closes in a mesh with holes.
    gap_closing: f64 = 1.0,
    /// The number of threads. 0 uses one thread for each CPU but one, so
    /// that the app and the desktop can answer while a slice runs.
    threads: u32 = 0,
    /// A draft slice for the view during an edit: the outlines lose the
    /// points within 0.05 mm of a straight line, the gaps get no fill, and
    /// the walls are classic walls. A draft needs about a third of the time
    /// of the exact slice, and the exact slice follows it. A draft never
    /// goes to the G-code. Off: each edit gives the exact slice only.
    draft_slices: bool = true,
    /// The print as it forms: a simulation of the plastic after each exact
    /// slice. Off saves the CPU of the run (about 0.4 s for a 3DBenchy),
    /// and the Check shows no simulated failures until you run the
    /// simulation by hand ("Show the print as it forms"). The G-code is
    /// the same.
    auto_simulate: bool = true,
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
    pub fn set(self: *Settings, old_name: []const u8, old_value: []const u8) SetError!void {
        const name = currentName(old_name);
        const value = currentValue(old_name, old_value);
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.UnknownSetting;
        const group = name[0..dot];
        const field = name[dot + 1 ..];
        if (limitOf(name)) |l| {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " ")) catch return error.InvalidValue;
            if (!(v >= l[0] and v <= l[1])) return error.OutOfRange;
        }
        if (nozzleSetting(name)) |ns| return setField(&self.machine.nozzle[ns.k], ns.field, value);
        inline for (@typeInfo(Settings).@"struct".fields) |g| {
            if (std.mem.eql(u8, g.name, group)) return setField(&@field(self, g.name), field, value);
        }
        return error.UnknownSetting;
    }

    /// Checks the values and computes the derived values, for a print of
    /// one filament.
    pub fn resolve(self: Settings) error{InvalidValue}!Resolved {
        return self.resolveFor(.{});
    }

    /// `resolve`, for a plate of the filaments `slots`: on a printer with
    /// more than one nozzle, a part (or its infill) whose filament is on
    /// another nozzle gets the line width of that nozzle.
    pub fn resolveFor(self: Settings, slots: SlotNozzles) error{InvalidValue}!Resolved {
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
        if (!allFinite(self)) return error.InvalidValue;
        for (positive) |v| if (!(v > 0)) return error.InvalidValue;
        const ratios = [_]f64{
            f.fan_speed,     p.infill_density, p.outer_wall_speed,  p.inner_wall_speed,
            p.skin_speed,    p.infill_speed,   p.first_layer_speed, p.ironing_flow,
            p.ironing_speed, f.fan_max_speed,  p.support_density,   p.support_interface_density,
            p.slope_smoothing_speed, p.slope_ironing_flow, p.slope_ironing_speed,
            p.support_speed, p.support_interface_speed,
        };
        for (ratios) |v| if (!(v >= 0 and v <= 1)) return error.InvalidValue;
        if (p.outer_wall_speed == 0 or p.inner_wall_speed == 0 or p.skin_speed == 0 or p.infill_speed == 0 or p.first_layer_speed == 0) return error.InvalidValue;
        var angle_buf: [max_infill_angles]f64 = undefined;
        _ = infillAngles(p.infill_angles, &angle_buf) catch return error.InvalidValue;
        if (p.ironing and (p.ironing_speed == 0 or !(p.ironing_spacing > 0))) return error.InvalidValue;
        if (p.slope_ironing and (p.slope_ironing_speed == 0 or p.slope_ironing_passes == 0 or !(p.slope_smoothing_min_width < p.slope_smoothing_max_width))) return error.InvalidValue;
        if (p.slope_smoothing and (p.slope_smoothing_speed == 0 or !(p.slope_smoothing_min_width < p.slope_smoothing_max_width))) return error.InvalidValue;
        if (p.support != .off and (p.support_density == 0 or p.support_interface_density == 0 or !(p.support_angle > 0 and p.support_angle < 90))) return error.InvalidValue;

        if (m.nozzles < 1 or m.nozzles > max_nozzles) return error.InvalidValue;
        const lines = nozzleLines(m, p);
        // The part prints with the nozzle of its filament, and the sparse
        // infill with the nozzle of the infill filament.
        const nozzle = slots.nozzleOf(m, filaments_slot(p.filament, slots.count));
        const infill_nozzle = if (p.infill_filament > 0) slots.nozzleOf(m, filaments_slot(p.infill_filament, slots.count)) else nozzle;
        const w = lines.width[nozzle];
        const w0 = lines.first[nozzle];
        if (p.layer_height > w or p.first_layer_height > w0) return error.InvalidValue;
        if (!(f.shrinkage_xy > 0.5 and f.shrinkage_xy < 1.5 and f.shrinkage_z > 0.5 and f.shrinkage_z < 1.5)) return error.InvalidValue;
        const r = f.diameter / 2;
        // A wall thickness sets the wall count, as in Cura.
        var out_settings = self;
        if (p.wall_thickness > 0) out_settings.project.wall_count = @max(1, @as(u32, @intFromFloat(@round(p.wall_thickness / w))));
        // The lines of a part on another nozzle come from its diameter.
        out_settings.machine.nozzle_diameter = lines.diameter[nozzle];
        if (!(m.max_accel > 0 and m.corner_speed >= 0)) return error.InvalidValue;
        return .{
            .settings = out_settings,
            .line_width = w,
            .first_layer_line_width = w0,
            .top_layers = @intFromFloat(@ceil(p.top_thickness / p.layer_height - 1e-6)),
            .bottom_layers = @intFromFloat(@ceil(p.bottom_thickness / p.layer_height - 1e-6)),
            .filament_area = std.math.pi * r * r,
            .retract_length = m.retract_length * f.retract_ratio,
            .slots = slots,
            .nozzle = nozzle,
            .infill_line_width = lines.width[infill_nozzle],
            .infill_nozzle_diameter = lines.diameter[infill_nozzle],
        };
    }
};

/// The slot (from 0) of a filament number (from 1) in a plate of `count`
/// filaments; as filaments.slotOf.
fn filaments_slot(number: u32, count: u32) u32 {
    if (number == 0 or number > count) return 0;
    return number - 1;
}

/// The most filament slots whose nozzle `SlotNozzles` keeps: as
/// filaments.max_slots.
pub const max_slot_nozzles = 32;

/// The nozzle of each filament of a plate, for a printer with more than
/// one nozzle (see `Settings.resolveFor`).
pub const SlotNozzles = struct {
    /// The number of filaments of the plate.
    count: u32 = 1,
    /// The nozzle of the filament of each slot (`Filament.nozzle`).
    nozzle: [max_slot_nozzles]u8 = [_]u8{0} ** max_slot_nozzles,

    /// The nozzles of the filaments `slots` (each `Filament.nozzle`).
    pub fn of(slots: []const Filament) SlotNozzles {
        var out: SlotNozzles = .{ .count = @intCast(@max(1, slots.len)) };
        for (slots, 0..) |f, k| if (k < max_slot_nozzles) {
            out.nozzle[k] = @intCast(@min(f.nozzle, max_nozzles - 1));
        };
        return out;
    }

    /// The nozzle of slot `slot` on the machine `m`, from 0. A printer
    /// with one nozzle: 0. A nozzle that the machine does not have: 0.
    pub fn nozzleOf(self: SlotNozzles, m: Machine, slot: u32) u32 {
        if (m.nozzles < 2 or slot >= max_slot_nozzles or slot >= self.count) return 0;
        return m.nozzleIndex(self.nozzle[slot]);
    }

    /// A hash of the nozzles, for the stamp of a plan.
    pub fn key(self: SlotNozzles) u64 {
        var h = std.hash.Wyhash.init(self.count);
        h.update(self.nozzle[0..@min(self.count, max_slot_nozzles)]);
        return h.final();
    }
};

/// The nozzle diameter and the line widths of each nozzle. With no values
/// of its own, a nozzle has the values of the first.
pub const NozzleLines = struct {
    diameter: [max_nozzles]f64,
    width: [max_nozzles]f64,
    first: [max_nozzles]f64,
};

pub fn nozzleLines(m: Machine, p: Project) NozzleLines {
    const d = m.nozzle_diameter;
    const w = if (p.line_width > 0) p.line_width else 1.1 * d;
    const w0 = if (p.first_layer_line_width > 0) p.first_layer_line_width else 1.25 * d;
    var out: NozzleLines = .{
        .diameter = [_]f64{d} ** max_nozzles,
        .width = [_]f64{w} ** max_nozzles,
        .first = [_]f64{w0} ** max_nozzles,
    };
    for (1..max_nozzles) |k| {
        const n = m.nozzle[k];
        const dk = if (n.diameter > 0) n.diameter else d;
        // The same diameter gives the same widths, bit for bit.
        const wk = if (n.line_width > 0) n.line_width else if (dk == d) w else w * dk / d;
        out.diameter[k] = dk;
        out.width[k] = wk;
        out.first[k] = if (wk == w) w0 else w0 * wk / w;
    }
    return out;
}

/// The name of a setting of a nozzle after the first,
/// "machine.nozzle.3.diameter": the nozzle (3) and the field
/// ("diameter"). Null for another name, or a nozzle out of 1 to
/// `max_nozzles` - 1.
pub fn nozzleSetting(name: []const u8) ?struct { k: u32, field: []const u8 } {
    const prefix = "machine.nozzle.";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const k = std.fmt.parseInt(u32, rest[0..dot], 10) catch return null;
    if (k < 1 or k >= max_nozzles) return null;
    return .{ .k = k, .field = rest[dot + 1 ..] };
}

/// The names of the settings of a nozzle in the form of the docs, with
/// "k" for the nozzle: "machine.nozzle.k.diameter".
pub const nozzle_patterns = blk: {
    const fields = @typeInfo(Nozzle).@"struct".fields;
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = "machine.nozzle.k." ++ f.name;
    const final = out;
    break :blk final;
};

/// The name of a setting with "k" for the nozzle of a nozzle setting
/// ("machine.nozzle.3.diameter" -> "machine.nozzle.k.diameter"), else
/// `name`. The tables of the settings (the limits, the units) have one
/// entry for each nozzle setting, by this name.
pub fn patternName(name: []const u8) []const u8 {
    const ns = nozzleSetting(name) orelse return name;
    for (nozzle_patterns) |pat| if (std.mem.eql(u8, pat["machine.nozzle.k.".len..], ns.field)) return pat;
    return name;
}

/// True if each number in `v` (a settings struct, or a part of one) is
/// finite and of a size that the integer coordinates can hold.
fn allFinite(v: anytype) bool {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .float => return @abs(v) <= 1e6,
        .array => {
            for (v) |x| if (!allFinite(x)) return false;
            return true;
        },
        .@"struct" => |st| {
            inline for (st.fields) |f| {
                if (!allFinite(@field(v, f.name))) return false;
            }
            return true;
        },
        else => return true,
    }
}

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
    /// The nozzle of each filament of the plate.
    slots: SlotNozzles = .{},
    /// The nozzle of the filament of the part, from 0. `line_width` and
    /// `settings.machine.nozzle_diameter` are of this nozzle.
    nozzle: u32 = 0,
    /// The line width of the sparse infill: of the nozzle of
    /// `project.infill_filament`.
    infill_line_width: f64 = 0,
    /// The diameter of the nozzle of the sparse infill.
    infill_nozzle_diameter: f64 = 0,

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
        const p = self.settings.machine;
        const max = p.max_accel;
        if (first_layer and p.first_layer_accel > 0 and feature != null) return @min(max, p.first_layer_accel);
        const a = if (feature) |f| switch (f) {
            .outer_wall, .slope_smoothing => p.outer_wall_accel,
            .inner_wall, .skirt => p.inner_wall_accel,
            .skin, .support_interface, .ironing, .slope_ironing, .bridge => p.skin_accel,
            .infill, .support => p.infill_accel,
        } else p.travel_accel;
        return if (a > 0) @min(max, a) else max;
    }

    /// `speedAt` for a line of nozzle `nozzle`: a nozzle after the first
    /// scales it by its `speed` and limits it to its `max_speed`.
    pub fn speedOn(self: Resolved, feature: Feature, width: f64, height: f64, layer: usize, nozzle: u32) f64 {
        return self.nozzleSpeed(self.speedAt(feature, width, height, layer), nozzle);
    }

    /// The speed `v` (mm/s) of a line of the first nozzle, for nozzle
    /// `nozzle`.
    pub fn nozzleSpeed(self: Resolved, v: f64, nozzle: u32) f64 {
        const m = self.settings.machine;
        var out = v;
        if (m.nozzleValue(nozzle, "speed")) |k| if (k > 0) {
            out *= k;
        };
        if (m.nozzleValue(nozzle, "max_speed")) |max| if (max > 0) {
            out = @min(out, max);
        };
        return out;
    }

    /// `accel` for a line of nozzle `nozzle`: a nozzle after the first
    /// limits it to its `max_accel`. Travel (`feature` null) keeps its
    /// acceleration: the head moves the same way for each nozzle.
    pub fn accelOn(self: Resolved, feature: ?Feature, first_layer: bool, nozzle: u32) f64 {
        const a = self.accel(feature, first_layer);
        if (feature == null) return a;
        const max = self.settings.machine.nozzleValue(nozzle, "max_accel") orelse return a;
        return if (max > 0) @min(a, max) else a;
    }

    /// The retraction length of nozzle `nozzle` (mm): a nozzle after the
    /// first has its `retract_length`, if it is set. The ratio of the
    /// filament applies to each.
    pub fn retractLengthOn(self: Resolved, nozzle: u32) f64 {
        const len = self.settings.machine.nozzleValue(nozzle, "retract_length") orelse return self.retract_length;
        if (!(len > 0)) return self.retract_length;
        return len * self.settings.filament.retract_ratio;
    }

    /// The retraction speed of nozzle `nozzle` (mm/s).
    pub fn retractSpeedOn(self: Resolved, nozzle: u32) f64 {
        const m = self.settings.machine;
        const v = m.nozzleValue(nozzle, "retract_speed") orelse return m.retract_speed;
        return if (v > 0) v else m.retract_speed;
    }

    /// The nozzle of the filament slot `slot`, from 0.
    pub fn nozzleOfSlot(self: Resolved, slot: u32) u32 {
        return self.slots.nozzleOf(self.settings.machine, slot);
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
            .support => if (p.support_speed > 0) p.support_speed else p.infill_speed,
            .support_interface => if (p.support_interface_speed > 0) p.support_interface_speed else p.skin_speed,
            .slope_smoothing => p.slope_smoothing_speed,
            .bridge => p.bridge_speed,
            .ironing, .slope_ironing => unreachable,
        };
        return limit * ratio;
    }
};

/// The most angles in `Project.infill_angles`.
pub const max_infill_angles = 64;

test "support speeds: their own ratio, or the infill and skin speeds" {
    var s: Settings = .{};
    s.filament.max_flow = 1000;
    var r = try s.resolve();
    // 0: the support prints at the infill speed, the interface at the skin
    // speed (the zslice speeds before these settings).
    try std.testing.expectEqual(r.speed(.infill, 0.4, 0.2, false), r.speed(.support, 0.4, 0.2, false));
    try std.testing.expectEqual(r.speed(.skin, 0.4, 0.2, false), r.speed(.support_interface, 0.4, 0.2, false));
    // Cura speed_support 60 and speed_support_interface 40 with a 150 mm/s
    // limit: the ratios 0.4 and 0.2667.
    s.project.support_speed = 0.4;
    s.project.support_interface_speed = 40.0 / 150.0;
    r = try s.resolve();
    try std.testing.expectApproxEqAbs(@as(f64, 60), r.speed(.support, 0.4, 0.2, false), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 40), r.speed(.support_interface, 0.4, 0.2, false), 1e-9);
    // The first layer keeps the first layer speed.
    try std.testing.expectEqual(r.speed(.infill, 0.4, 0.2, true), r.speed(.support, 0.4, 0.2, true));
}

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

/// True for a setting that holds a G-code template. Only these settings
/// take `unixLines`: an LF in a name goes into the settings comments of the
/// G-code, and a firmware reads it as a new command.
pub fn isGcodeTemplate(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_gcode");
}

/// Turns CRLF and CR into LF in place, and returns the shorter text. A
/// text box of WinUI gives CR, and the G-code templates split at LF.
pub fn unixLines(text: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            text[out] = '\n';
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        } else text[out] = text[i];
        out += 1;
    }
    return text[0..out];
}

test "unixLines: CR and CRLF become LF" {
    var a = "G28\rG1 Z5\r\nM84\n\r".*;
    try std.testing.expectEqualStrings("G28\nG1 Z5\nM84\n\n", unixLines(&a));
    var b = "G28\nM84".*;
    try std.testing.expectEqualStrings("G28\nM84", unixLines(&b));
    try std.testing.expect(isGcodeTemplate("machine.start_gcode"));
    try std.testing.expect(isGcodeTemplate("filament.end_gcode"));
    try std.testing.expect(!isGcodeTemplate("machine.name"));
}

fn setField(target: anytype, name: []const u8, value: []const u8) Settings.SetError!void {
    const T = @typeInfo(@TypeOf(target)).pointer.child;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        // The nozzles after the first have names of their own (see
        // `nozzleSetting`).
        if (comptime f.type == [max_nozzles]Nozzle) continue;
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
    .{ "machine.nozzles", 1, 16 },
    .{ "machine.nozzle1_max_x", 0, 1000 },
    .{ "machine.nozzle1_max_height", 0, 1000 },
    .{ "machine.standby_delta", -300, 100 },
    .{ "machine.preheat_time", 0, 600 },
    .{ "filament.nozzle", 0, 15 },
    // nozzle.k: each nozzle after the first
    .{ "machine.nozzle.k.diameter", 0, 2 },
    .{ "machine.nozzle.k.line_width", 0, 2 },
    .{ "machine.nozzle.k.speed", 0, 1 },
    .{ "machine.nozzle.k.max_speed", 0, 2000 },
    .{ "machine.nozzle.k.max_accel", 0, 100000 },
    .{ "machine.nozzle.k.retract_length", 0, 20 },
    .{ "machine.nozzle.k.retract_speed", 0, 200 },
    .{ "machine.nozzle.k.offset_x", -1000, 1000 },
    .{ "machine.nozzle.k.offset_y", -1000, 1000 },
    .{ "machine.nozzle.k.min_x", 0, 1000 },
    .{ "machine.nozzle.k.max_x", 0, 1000 },
    .{ "machine.nozzle.k.max_height", 0, 1000 },
    .{ "machine.nozzle.k.standby_delta", -300, 100 },
    .{ "machine.nozzle.k.preheat_time", 0, 600 },
    // machine
    .{ "machine.bed_size_x", 10, 2000 },
    .{ "machine.bed_size_y", 10, 2000 },
    .{ "machine.origin_x", -2000, 2000 },
    .{ "machine.origin_y", -2000, 2000 },
    .{ "machine.max_height", 10, 2000 },
    .{ "machine.nozzle_diameter", 0.1, 2 },
    .{ "machine.nozzle_tip_radius", 0, 5 },
    .{ "machine.nozzle_cone_angle", 0, 85 },
    .{ "machine.chamber_temp", 0, 120 },
    .{ "machine.part_fan_air", 0, 40 },
    .{ "machine.max_speed", 1, 2000 },
    .{ "machine.travel_speed", 1, 2000 },
    .{ "machine.first_layer_travel_speed", 0, 2000 },
    .{ "machine.max_z_speed", 0.1, 200 },
    .{ "machine.max_z_accel", 1, 100000 },
    .{ "machine.hour_rate", 0, 100000 },
    .{ "machine.max_accel", 10, 100000 },
    .{ "machine.corner_speed", 0, 100 },
    .{ "machine.max_accel_x", 0, 100000 },
    .{ "machine.max_accel_y", 0, 100000 },
    .{ "machine.outer_wall_accel", 0, 100000 },
    .{ "machine.inner_wall_accel", 0, 100000 },
    .{ "machine.skin_accel", 0, 100000 },
    .{ "machine.infill_accel", 0, 100000 },
    .{ "machine.travel_accel", 0, 100000 },
    .{ "machine.first_layer_accel", 0, 100000 },
    .{ "machine.max_speed_x", 0, 2000 },
    .{ "machine.max_speed_y", 0, 2000 },
    .{ "machine.retract_length", 0, 20 },
    .{ "machine.clearance_radius", 0, 500 },
    .{ "machine.clearance_height", 0, 2000 },
    .{ "machine.retract_speed", 1, 200 },
    .{ "machine.retract_min_travel", 0, 100 },
    .{ "machine.z_hop", 0, 10 },
    .{ "machine.retract_wipe_distance", 0, 10 },
    // filament
    .{ "filament.diameter", 1, 3.5 },
    .{ "filament.density", 0.5, 3 },
    .{ "filament.price_per_kg", 0, 10000 },
    .{ "filament.nozzle_temp", 0, 450 },
    .{ "filament.first_layer_nozzle_temp", 0, 450 },
    .{ "filament.bed_temp", 0, 150 },
    .{ "filament.first_layer_bed_temp", 0, 150 },
    .{ "filament.max_flow", 0.5, 100 },
    .{ "filament.flow_ratio", 0.5, 2 },
    .{ "filament.pressure_advance", 0, 2 },
    .{ "filament.fan_speed", 0, 1 },
    .{ "filament.fan_off_layers", 0, 100 },
    .{ "filament.fan_ramp_layers", 0, 100 },
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
    .{ "project.overhang_wall_speed", 0.05, 1 },
    .{ "project.overhang_wall_fan", 0, 1 },
    .{ "project.overhang_wall_threshold", 0.05, 1 },
    .{ "project.fuzzy_skin_thickness", 0.01, 2 },
    .{ "project.fuzzy_skin_point_distance", 0.1, 10 },
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
    .{ "project.support_speed", 0, 1 },
    .{ "project.support_interface_speed", 0, 1 },
    .{ "project.first_layer_speed", 0.01, 1 },
    .{ "project.slow_layers", 0, 50 },
    .{ "project.combing_max_distance", 0, 1000 },
    .{ "project.support_tree_angle", 0, 75 },
    .{ "project.support_tree_spacing", 0.5, 50 },
    .{ "project.support_tree_tip", 0, 10 },
    .{ "project.support_angle", 0, 90 },
    .{ "project.support_min_ledge", 0, 20 },
    .{ "project.support_density", 0.01, 1 },
    .{ "project.support_xy_gap", 0, 10 },
    .{ "project.support_z_gap_layers", 0, 10 },
    .{ "project.support_interface_layers", 0, 20 },
    .{ "project.support_interface_density", 0.01, 1 },
    .{ "project.skirt_loops", 0, 50 },
    .{ "project.filament", 1, 16 },
    .{ "project.support_filament", 0, 16 },
    .{ "project.infill_filament", 0, 16 },
    .{ "project.support_interface_filament", 0, 16 },
    .{ "project.flush_multiplier", 0, 3 },
    .{ "project.prime_tower_width", 5, 100 },
    .{ "project.prime_tower_brim", 0, 20 },
    .{ "project.prime_tower_wall_loops", 1, 10 },
    .{ "project.prime_tower_rib_width", 0, 300 },
    .{ "project.prime_tower_extra_rib_length", -300, 300 },
    .{ "project.paint_anchor_depth", 0, 10 },
    .{ "project.prime_tower_x", -1, 2000 },
    .{ "project.prime_tower_y", -1, 2000 },
    .{ "machine.change_time", 0, 3600 },
    .{ "machine.flush_volume", 0, 5000 },
    .{ "project.skirt_distance", 0, 50 },
    .{ "project.skirt_layers", 0, 50 },
    .{ "project.brim_width", 0, 50 },
    .{ "project.outer_wall_wipe", 0, 10 },
    .{ "project.coasting_volume", 0, 5 },
    .{ "project.coasting_speed", 0.1, 1 },
    .{ "project.first_layer_xy_offset", -2, 2 },
    // engine
    .{ "project.resolution", 0.0005, 0.5 },
    .{ "engine.gap_closing", 0, 10 },
    .{ "engine.threads", 0, 256 },
};

/// The limits of a setting, or null for a setting with none.
pub fn limitOf(full_name: []const u8) ?[2]f64 {
    const name = patternName(full_name);
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
    for (nozzle_patterns) |pat| try std.testing.expect(limitOf(pat) != null);
    var s: Settings = .{};
    try std.testing.expectError(error.OutOfRange, s.set("project.brim_width", "300"));
    try s.set("project.brim_width", "8");
    try std.testing.expectEqual(@as(f64, 8), s.project.brim_width);
}

/// A change of one setting, by its dotted name ("project.infill_density").
/// The settings that change no path of a layer plan, and no travel of
/// the G-code: the speeds, the accelerations of the lines, the flow, the
/// fan, the cooling times, and the temperatures. The emitter reads them
/// when it runs a layer from its move stream (see stream.zig), so a
/// change of one of them needs no new plan.
///
/// Not in the list: each setting that the plans or the travels read. The
/// travel speed, the travel acceleration, and the retraction change the
/// combing ways. `cooling_mode` moves the nozzle.
pub const patch_settings = [_][]const u8{
    "filament.nozzle_temp",      "filament.first_layer_nozzle_temp", "filament.bed_temp",
    "filament.first_layer_bed_temp",
    "filament.fan_speed",        "filament.fan_off_layers",          "filament.fan_max_speed",
    "filament.fan_boost_time",   "filament.min_layer_time",          "filament.min_speed",
    "filament.fan_ramp_layers",  "machine.chamber_temp",             "machine.part_fan_air",
    "filament.flow_ratio",       "filament.max_flow",                "filament.density",
    "filament.price_per_kg",     "project.bridge_speed",             "project.bridge_flow",
    "project.bridge_fan",        "project.infill_flow",              "project.ironing_flow",
    "project.ironing_speed",     "project.outer_wall_speed",         "project.inner_wall_speed",
    "project.skin_speed",        "project.infill_speed",             "project.first_layer_speed",
    "project.support_speed",     "project.support_interface_speed",
    "project.slow_layers",       "machine.outer_wall_accel",         "machine.inner_wall_accel",
    "machine.skin_accel",        "machine.infill_accel",             "machine.first_layer_accel",
    "project.path_rules",
};

pub fn isPatchSetting(old_name: []const u8) bool {
    const name = currentName(old_name);
    for (patch_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Adds each setting to `h`, but no patch setting (see `patch_settings`).
pub fn hashPlanInputs(s: *const Settings, h: *std.hash.Wyhash) void {
    @setEvalBranchQuota(200000);
    inline for (@typeInfo(Settings).@"struct".fields) |g| {
        inline for (@typeInfo(g.type).@"struct".fields) |f| {
            if (comptime !isPatchSetting(g.name ++ "." ++ f.name)) hashValue(h, @field(@field(s, g.name), f.name));
        }
    }
}

/// Adds a value to `h`: a number, an enum, a text, or a list or a struct
/// of them. A text adds its bytes and its length.
pub fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .bool => h.update(&.{@intFromBool(v)}),
        .int, .float => h.update(std.mem.asBytes(&v)),
        .@"enum" => hashValue(h, @intFromEnum(v)),
        .optional => if (v) |x| {
            h.update(&.{1});
            hashValue(h, x);
        } else h.update(&.{0}),
        .array => for (v) |x| hashValue(h, x),
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("hashValue: " ++ @typeName(T));
            hashValue(h, v.len);
            if (ptr.child == u8) h.update(v) else for (v) |x| hashValue(h, x);
        },
        .@"struct" => |st| inline for (st.fields) |f| hashValue(h, @field(v, f.name)),
        else => @compileError("hashValue: " ++ @typeName(T)),
    }
}

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
/// The machine and engine settings are for the whole slice too. The
/// accelerations of the features (`part_machine_settings`) are the
/// exception: a part can have its own.
pub const plate_settings = [_][]const u8{
    "filament.name",                  "filament.material",          "filament.color",
    "filament.nozzle",
    "filament.diameter",              "filament.density",           "filament.price_per_kg",
    "filament.nozzle_temp",           "filament.first_layer_nozzle_temp", "filament.bed_temp",
    "filament.first_layer_bed_temp",
    "filament.standby_temp",          "filament.fan_speed",         "filament.fan_off_layers",
    "filament.fan_ramp_layers",
    "filament.fan_max_speed",         "filament.fan_boost_time",    "filament.min_layer_time",
    "filament.min_speed",             "filament.cooling_mode",      "filament.retract_ratio",
    "project.first_layer_height",     "machine.retract_min_travel", "project.combing_mode",
    "project.combing_max_distance",   "machine.z_hop",              "machine.z_hop_only_crossing",
    "machine.retract_wipe",           "machine.retract_wipe_distance",
    "machine.retract_layer_change",   "machine.travel_accel",       "project.skirt_loops",
    "project.skirt_distance",         "project.skirt_layers",       "project.brim_width",
    "project.brim_location",          "project.placement",          "project.flush_multiplier",
    "project.print_sequence",
    "project.prime_tower",            "project.prime_tower_width",  "project.prime_tower_x",
    "project.prime_tower_y",          "project.flush_into_hidden",      "project.prime_tower_brim",
    "project.prime_tower_wall_loops", "project.prime_tower_rib_wall", "project.prime_tower_rib_width",
    "project.prime_tower_extra_rib_length", "project.prime_tower_fillet_wall",
};

/// True for a setting that is the same for all the parts of a plate (see
/// `plate_settings`).
pub fn isPlateSetting(old_name: []const u8) bool {
    const name = currentName(old_name);
    if (!isPartSetting(name)) return true;
    for (plate_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The settings that one part of the plate can have of its own in a
/// slice (see part_settings.zig and plate_job.zig): each part slices as
/// its own job, so all the project and filament settings and the
/// accelerations, except the ones of the plate (`isPlateSetting`). Walls, layer height, seam,
/// speeds, infill, skin, support, and flow can differ from part to part.
pub fn isPerPartSetting(name: []const u8) bool {
    return isPartSetting(name) and !isPlateSetting(name);
}

/// A setting that the part can change: the project and filament settings,
/// and the accelerations and travel retraction of the printer
/// (`part_machine_settings`). The
/// other machine settings describe the printer, and the engine settings
/// the slicer.
pub fn isPartSetting(old_name: []const u8) bool {
    const name = currentName(old_name);
    for (part_machine_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return std.mem.startsWith(u8, name, "project.") or std.mem.startsWith(u8, name, "filament.");
}

/// The machine settings that a part or some layers can change: the
/// accelerations of the features, and the retraction of the travels (the
/// z hop, the wipe). Each printer has its own values, and an override of a
/// part or of some layers replaces the value of the printer there. They
/// were project settings before, with the same overrides.
pub const part_machine_settings = [_][]const u8{
    "machine.outer_wall_accel", "machine.inner_wall_accel", "machine.skin_accel",
    "machine.infill_accel",     "machine.travel_accel",     "machine.first_layer_accel",
    "machine.retract_min_travel", "machine.z_hop",            "machine.z_hop_only_crossing",
    "machine.retract_wipe",     "machine.retract_wipe_distance", "machine.retract_layer_change",
};

/// The settings that moved to another group: the old name and the new
/// name. A text with an old name (a profile, a project file, a session,
/// or an override of a part or of some layers) still loads. `Settings.set`
/// and the checks of the names use the new name.
pub const moved_settings = [_][2][]const u8{
    .{ "project.outer_wall_accel", "machine.outer_wall_accel" },
    .{ "project.inner_wall_accel", "machine.inner_wall_accel" },
    .{ "project.skin_accel", "machine.skin_accel" },
    .{ "project.infill_accel", "machine.infill_accel" },
    .{ "project.travel_accel", "machine.travel_accel" },
    .{ "project.first_layer_accel", "machine.first_layer_accel" },
    .{ "project.retract_min_travel", "machine.retract_min_travel" },
    .{ "project.z_hop", "machine.z_hop" },
    .{ "project.z_hop_only_crossing", "machine.z_hop_only_crossing" },
    .{ "project.retract_wipe", "machine.retract_wipe" },
    .{ "project.retract_layer_change", "machine.retract_layer_change" },
    .{ "project.combing", "project.combing_mode" },
    // The second nozzle of a printer with two is nozzle 1 now, one of
    // up to 15 nozzles after the first.
    .{ "machine.nozzle2_diameter", "machine.nozzle.1.diameter" },
    .{ "machine.nozzle2_line_width", "machine.nozzle.1.line_width" },
    .{ "machine.nozzle2_speed", "machine.nozzle.1.speed" },
    .{ "machine.nozzle2_max_speed", "machine.nozzle.1.max_speed" },
    .{ "machine.nozzle2_max_accel", "machine.nozzle.1.max_accel" },
    .{ "machine.nozzle2_retract_length", "machine.nozzle.1.retract_length" },
    .{ "machine.nozzle2_retract_speed", "machine.nozzle.1.retract_speed" },
    .{ "machine.nozzle2_min_x", "machine.nozzle.1.min_x" },
    .{ "machine.nozzle2_max_height", "machine.nozzle.1.max_height" },
    .{ "engine.resolution", "project.resolution" },
};

/// The value of a setting now: an old value of a setting that changed its
/// form (see `moved_settings`), else `value`. `project.combing` was true
/// or false: `all` or `off` now.
pub fn currentValue(name: []const u8, value: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "project.combing")) {
        const v = std.mem.trim(u8, value, " \"");
        if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return "all";
        if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return "off";
    }
    return value;
}

/// The name of a setting now: the new name of a setting that moved to
/// another group (see `moved_settings`), else `name`.
pub fn currentName(name: []const u8) []const u8 {
    for (moved_settings) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return name;
}

/// True if `name` is the old name of a setting that moved to another
/// group.
pub fn isMovedName(name: []const u8) bool {
    for (moved_settings) |m| if (std.mem.eql(u8, m[0], name)) return true;
    return false;
}

/// The settings that can change from one layer to the next. The others
/// are for the whole print: the first layer settings, the skirt and the
/// brim, the support areas (a column goes through many layers), the
/// shrinkage, the facts of the filament, and the machine.
/// docs/internals/layer-settings.md has the list, with the reason for each
/// setting that is not here.
pub const layer_settings = [_][]const u8{
    "project.filament",
    "project.wall_count",
    "project.wall_order",
    "project.alternate_extra_wall",
    "project.seam",
    "project.seam_corner",
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
    "project.infill_anchor",
    "project.infill_flow",
    "project.infill_ribs",
    "project.bridges",
    "project.bridge_speed",
    "project.bridge_flow",
    "project.bridge_fan",
    "project.overhang_wall_speed",
    "project.overhang_wall_fan",
    "project.overhang_wall_threshold",
    "project.fuzzy_skin",
    "project.fuzzy_skin_thickness",
    "project.fuzzy_skin_point_distance",
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
    "project.support_speed",
    "project.support_interface_speed",
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
    "filament.pressure_advance",
    "filament.retract_ratio",
    "filament.fan_speed",
    "filament.fan_max_speed",
    "filament.fan_boost_time",
    "filament.min_layer_time",
    "filament.min_speed",
    "filament.cooling_mode",
    "machine.retract_min_travel",
    "project.combing_mode",
    "project.combing_max_distance",
    "machine.z_hop",
    "machine.retract_wipe",
    "machine.retract_wipe_distance",
    "project.outer_wall_wipe",
    "project.coasting_volume",
    "project.coasting_speed",
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
    "machine.outer_wall_accel",
    "machine.inner_wall_accel",
    "machine.skin_accel",
    "machine.infill_accel",
    "machine.travel_accel",
    "filament.max_flow",
    // Pass 1 of the engine reads these for each layer. A layer gets the
    // layer height of the span that holds its top (see slicer.HeightSpan).
    "project.layer_height",
    "filament.xy_offset",
    "filament.hole_xy_offset",
};

pub fn isLayerSetting(old_name: []const u8) bool {
    const name = currentName(old_name);
    for (layer_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The layer settings that one region of some layers can have of its own:
/// a body that the user lights on the layers (a modifier volume, see
/// part_settings.zig and layer.Modifier). A region keeps the walls and
/// the skin of the part, and gets its own sparse infill inside the walls,
/// with its own speed and flow. `project.filament` of a region is paint
/// on the part (see paint_body.zig). It is no modifier.
/// docs/user/lines.md lists them.
pub const region_settings = [_][]const u8{
    "project.filament",
    "project.infill_density",
    "project.infill_pattern",
    "project.infill_angle",
    "project.infill_angles",
    "project.infill_stack",
    "project.infill_flow",
    "project.infill_speed",
    "machine.infill_accel",
};

/// Null if a region of some layers can have setting `name` of its own
/// (`region_settings`). Else why the setting is for the whole layer only,
/// in one short sentence for a row of a card.
pub fn regionNote(old_name: []const u8) ?[:0]const u8 {
    const name = currentName(old_name);
    for (region_settings) |n| if (std.mem.eql(u8, n, name)) return null;
    const has = struct {
        fn f(n: []const u8, words: []const []const u8) bool {
            for (words) |w| if (std.mem.indexOf(u8, n, w) != null) return true;
            return false;
        }
    }.f;
    if (!isLayerSetting(name)) return "This setting is for the whole print only.";
    if (has(name, &.{ "layer_height", "xy_offset" })) return "The plate has one layer height and one outline at each layer.";
    if (has(name, &.{ "fan", "cooling", "min_layer_time", "min_speed" })) return "The fan runs at one speed for the whole layer.";
    if (has(name, &.{"bed_temp"})) return "The bed has one temperature for the whole layer.";
    if (has(name, &.{"chamber_temp"})) return "The chamber has one temperature for the whole layer.";
    if (has(name, &.{ "temp", "pressure_advance", "flow_ratio", "max_flow" })) return "The nozzle has one value of this for the whole layer.";
    if (has(name, &.{ "retract", "z_hop", "combing", "travel", "coasting", "wipe" })) return "The travel moves and the retractions are for the whole layer.";
    if (has(name, &.{ "support" })) return "The support is for the whole layer.";
    if (has(name, &.{ "wall", "seam", "gap_fill", "line_width", "fuzzy", "min_feature", "min_bead", "solid_infill_width" })) return "The walls of the part go around the whole layer. A region changes the infill inside them.";
    return "The skin and the walls of the part stay in a region. A region changes the infill inside the walls.";
}

test "a region of some layers: its infill only, with no walls, fan, or layer height" {
    try std.testing.expect(regionNote("project.infill_density") == null);
    try std.testing.expect(regionNote("project.filament") == null);
    try std.testing.expect(regionNote("project.infill_accel") == null);
    for ([_][]const u8{ "project.layer_height", "filament.fan_speed", "project.wall_count", "filament.nozzle_temp", "project.top_thickness", "machine.z_hop", "project.first_layer_height" }) |n| try std.testing.expect(regionNote(n) != null);
    try std.testing.expectEqualStrings("The bed has one temperature for the whole layer.", regionNote("filament.bed_temp").?);
    try std.testing.expectEqualStrings("The nozzle has one value of this for the whole layer.", regionNote("filament.nozzle_temp").?);
    // Each region setting can change for some layers.
    for (region_settings) |n| try std.testing.expect(isLayerSetting(n));
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

test "the settings of each nozzle after the first" {
    var s: Settings = .{};
    try s.set("machine.nozzles", "5");
    try s.set("machine.nozzle.4.diameter", "0.6");
    try s.set("machine.nozzle.3.offset_x", "-12.5");
    try std.testing.expectEqual(@as(f64, 0.6), s.machine.nozzle[4].diameter);
    try std.testing.expectEqual(@as(f64, -12.5), s.machine.nozzle[3].offset_x);
    // Nozzle 0 has the settings of the Nozzle section; 16 and on do not
    // exist.
    try std.testing.expectError(error.UnknownSetting, s.set("machine.nozzle.0.diameter", "0.6"));
    try std.testing.expectError(error.UnknownSetting, s.set("machine.nozzle.16.diameter", "0.6"));
    try std.testing.expectError(error.UnknownSetting, s.set("machine.nozzle.2.size", "0.6"));
    try std.testing.expectError(error.OutOfRange, s.set("machine.nozzle.2.diameter", "5"));
    try std.testing.expectError(error.OutOfRange, s.set("machine.nozzles", "17"));
    try std.testing.expectEqualStrings("machine.nozzle.k.diameter", patternName("machine.nozzle.4.diameter"));
    // The lines of each nozzle: 1.1 times its diameter.
    var slots: SlotNozzles = .{ .count = 3 };
    slots.nozzle = .{ 0, 4, 2 } ++ [_]u8{0} ** (max_slot_nozzles - 3);
    s.project.filament = 2;
    const r = try s.resolveFor(slots);
    try std.testing.expectEqual(@as(u32, 4), r.nozzle);
    try std.testing.expectApproxEqAbs(@as(f64, 0.66), r.line_width, 1e-9);
    try std.testing.expectEqual(@as(u32, 2), r.nozzleOfSlot(2));
    // The tool offset, the standby, and the preheat of a nozzle.
    try std.testing.expectEqual([2]f64{ -12.5, 0 }, s.machine.nozzleOffset(3));
    s.machine.standby_delta = -100;
    s.machine.nozzle[2].standby_delta = -50;
    try std.testing.expectEqual(@as(f64, -100), s.machine.standbyDelta(1));
    try std.testing.expectEqual(@as(f64, -50), s.machine.standbyDelta(2));
    // A nozzle that the printer does not have: the first.
    s.machine.nozzles = 3;
    try std.testing.expectEqual(@as(u32, 0), slots.nozzleOf(s.machine, 1));
    try std.testing.expectEqual([2]f64{ 0, 0 }, s.machine.nozzleOffset(3));
}

test "a setting that moved loads by its old name" {
    var s: Settings = .{};
    try s.set("project.outer_wall_accel", "500");
    try s.set("project.travel_accel", "2500");
    try std.testing.expectEqual(@as(f64, 500), s.machine.outer_wall_accel);
    try std.testing.expectEqual(@as(f64, 2500), s.machine.travel_accel);
    try std.testing.expectError(error.OutOfRange, s.set("project.skin_accel", "-1"));
    // The old name has the same overrides as the new name.
    try std.testing.expect(isLayerSetting("project.outer_wall_accel"));
    try std.testing.expect(isLayerSetting("machine.outer_wall_accel"));
    try std.testing.expect(!isLayerSetting("machine.first_layer_accel"));
    try std.testing.expect(isPerPartSetting("machine.infill_accel"));
    try std.testing.expect(isPerPartSetting("project.infill_accel"));
    try std.testing.expect(isPlateSetting("machine.travel_accel"));
    try std.testing.expect(!isPartSetting("machine.max_accel"));
    try std.testing.expect(isPatchSetting("project.skin_accel"));
    try std.testing.expectEqualStrings("machine.skin_accel", currentName("project.skin_accel"));
    try std.testing.expectEqualStrings("project.skin_speed", currentName("project.skin_speed"));
    // Each new name is a machine setting, the combing mode, or the
    // outline tolerance (engine.resolution before).
    for (moved_settings) |m| {
        var t: Settings = .{};
        const bool_value = std.mem.indexOf(u8, m[1], "wipe") != null or std.mem.indexOf(u8, m[1], "only") != null or std.mem.indexOf(u8, m[1], "layer_change") != null;
        const enum_value = std.mem.eql(u8, m[1], "project.combing_mode");
        const ratio = std.mem.endsWith(u8, m[1], ".speed") or std.mem.endsWith(u8, m[1], ".diameter") or std.mem.endsWith(u8, m[1], ".line_width");
        const resolution = std.mem.eql(u8, m[1], "project.resolution");
        try t.set(m[1], if (bool_value) "true" else if (enum_value) "off" else if (ratio) "0.7" else if (resolution) "0.01" else "7");
        try std.testing.expect(std.mem.startsWith(u8, m[1], "machine.") or enum_value or resolution);
        if (nozzleSetting(m[1])) |ns| {
            var buf: [32]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            inline for (@typeInfo(Nozzle).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, ns.field)) try w.print("{d}", .{@field(t.machine.nozzle[ns.k], f.name)});
            }
            try std.testing.expectEqualStrings(if (ratio) "0.7" else "7", w.buffered());
        }
    }
    // The settings of the second nozzle are of nozzle 1 now.
    var two: Settings = .{};
    try two.set("machine.nozzle2_diameter", "0.6");
    try two.set("machine.nozzle2_retract_length", "2");
    try two.set("machine.nozzle2_min_x", "20.5");
    try std.testing.expectEqual(@as(f64, 0.6), two.machine.nozzle[1].diameter);
    try std.testing.expectEqual(@as(f64, 2), two.machine.nozzle[1].retract_length);
    try std.testing.expectEqual(@as(f64, 20.5), two.machine.nozzle[1].min_x);
    try std.testing.expectEqualStrings("machine.nozzle.1.max_speed", currentName("machine.nozzle2_max_speed"));
    try std.testing.expectError(error.OutOfRange, two.set("machine.nozzle2_speed", "2"));
    // The travel retraction moved too, with its overrides.
    var r: Settings = .{};
    try r.set("project.z_hop", "0.4");
    try r.set("project.retract_wipe", "true");
    try std.testing.expectEqual(@as(f64, 0.4), r.machine.z_hop);
    try std.testing.expect(r.machine.retract_wipe);
    try std.testing.expect(isLayerSetting("project.z_hop"));
    try std.testing.expect(isPartSetting("machine.retract_wipe_distance"));
    // The bool combing of before is a combing mode now.
    try r.set("project.combing", "false");
    try std.testing.expectEqual(CombingMode.off, r.project.combing_mode);
    try r.set("project.combing", "true");
    try std.testing.expectEqual(CombingMode.all, r.project.combing_mode);
    try std.testing.expect(isLayerSetting("project.combing"));
}
