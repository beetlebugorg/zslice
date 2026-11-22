//! The variables of the start and the end G-code.
//!
//! A printer profile has a start and an end G-code text with variables. The
//! printer library (see printers.zig) gets these texts from Cura,
//! PrusaSlicer, and OrcaSlicer. OrcaSlicer also has the profiles of Bambu
//! Studio. Each slicer has its own names and its own syntax:
//!
//! - Cura: `{material_print_temperature}`, and `{name, 0}` for extruder 0.
//!   Cura 5 also has `{if ...}`, `{elif ...}`, `{else}`, and `{endif}`.
//! - PrusaSlicer, OrcaSlicer, and Bambu Studio: `[name]`, `[name[0]]`, and
//!   `{expression}`. An expression has numbers, texts ("PLA"), lists
//!   (`print_bed_max[0]`), arithmetic, comparisons, `and`, `or`, `not`,
//!   `? :`, regular expressions (`filament_type[0] =~ /PET.*/`), and
//!   functions (`min`, `max`, `is_nil`, ...). A block can also set a
//!   variable (`{local x = 2}`) and have statements with `if ... then`.
//! - zslice: `{bed_temp}`, `{first_layer_nozzle_temp}`, and the others
//!   that `Machine.start_gcode` lists.
//!
//! `render` writes a text with the values of the variables. It reads the
//! text once, from the start to the end. A `{...}` block is a control
//! block (if, elsif, else, endif) or a list of statements. The value of
//! each statement goes into the G-code, as in PrusaSlicer, and a line
//! break in a text of the template is a new line. A `[name]` is a
//! variable.
//!
//! The map (`names`) gives each variable name of the four slicers a key,
//! and `Renderer.value` gives each key a zslice value. A list variable of
//! the other slicers has one value for each extruder. zslice prints with
//! one nozzle, and each filament of the plate is a tool of it (see
//! filaments.zig): a filament variable with an index (`filament_type[1]`)
//! has the value of that filament. The change G-code of a machine has the
//! facts of the change (`Context.change`): the new tool, the flush
//! length, and the old and new temperatures.
//!
//! Some variables have no zslice value (a time of day, a pressure advance
//! value, a temperature of a heated chamber). zslice never writes a
//! command with a wrong value. A line with such a variable becomes a
//! comment: "; zslice: no value for NAME: <the line>". A condition with
//! such a variable is false, and a comment line tells it. On
//! RepRapFirmware, a `{...}` with a name of the object model of the
//! firmware (`{move.axes[0].min}`) stays for the firmware.
//!
//! `render` also tells the temperatures that the text sets (`Result`).
//! The emitter (gcode.zig) adds the heating commands that a start G-code
//! leaves out.
//!
//! References (see docs/references/): the Cura start G-code settings, the
//! PrusaSlicer macro language and placeholder list, and the OrcaSlicer
//! and Bambu Studio placeholder lists. This file uses their names and
//! their syntax. It has no code from them.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const settings_mod = @import("settings.zig");
const flow = @import("flow.zig");
const printers = @import("printers.zig");
const Resolved = settings_mod.Resolved;

pub const Value = union(enum) {
    /// No value: zslice has none for the variable.
    nil,
    boolean: bool,
    num: f64,
    text: []const u8,
    list: []const Value,

    fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            .num => |n| n != 0,
            .text => |t| t.len > 0,
            .list => |l| l.len > 0,
        };
    }
};

pub const Phase = enum { start, end };

/// The global variables of the texts of one print (`{global x = 1}` in
/// PrusaSlicer and OrcaSlicer): the start G-code sets them, and the change
/// G-code and the end G-code read and change them. The CORE One INDX
/// keeps the state of each tool in one (tool_init).
pub const Globals = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn init(gpa: Allocator) Globals {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(g: *Globals) void {
        g.arena.deinit();
    }

    fn put(g: *Globals, name: []const u8, v: Value) Allocator.Error!void {
        const a = g.arena.allocator();
        const key = if (g.map.getKey(name)) |k| k else try a.dupe(u8, name);
        try g.map.put(a, key, try copyValue(a, v));
    }
};

/// A copy of `v` in `a`, with its texts and lists.
fn copyValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .text => |t| .{ .text = try a.dupe(u8, t) },
        .list => |items| blk: {
            const out = try a.alloc(Value, items.len);
            for (items, out) |x, *y| y.* = try copyValue(a, x);
            break :blk .{ .list = out };
        },
        else => v,
    };
}

/// The facts of the print that the settings do not have.
pub const Context = struct {
    r: *const Resolved,
    phase: Phase = .start,
    layer_count: usize = 0,
    /// The z of the top layer.
    max_layer_z: f64 = 0,
    /// The z of the nozzle now: 0 in the start G-code.
    layer_z: f64 = 0,
    /// The box of the first layer in G-code coordinates (min x, min y, max
    /// x, max y), or null: the box of the bed.
    first_layer_box: ?[4]f64 = null,
    /// RepRapFirmware: a block with a name of the object model of the
    /// firmware stays in the G-code.
    object_model: bool = false,
    /// The filament of the print, for the end G-code.
    filament_mm: f64 = 0,
    filament_g: f64 = 0,
    print_time_s: f64 = 0,
    /// The filaments of the plate: slot k + 1 is `slots[k]`. Empty: the
    /// filament of the settings is the only one. A list variable of the
    /// filaments (`filament_type[1]`) reads the slot of its index.
    slots: []const settings_mod.Filament = &.{},
    /// The first filament slot that the print uses on each nozzle, or null
    /// for a nozzle with none; null as a whole: not known, and the first
    /// slot of the plate on that nozzle stands in (a test, or a G-code
    /// with no plate).
    first_of_nozzles: ?[settings_mod.max_nozzles]?u32 = null,
    /// The tool now (a slot, from 0). In a filament change, the old tool.
    tool: u32 = 0,
    /// The layer now, or null (the start and the end G-code).
    layer_index: ?usize = null,
    /// The facts of a filament change, in the change G-code
    /// (`Machine.change_gcode`), or null.
    change: ?Change = null,
    /// The global variables of the print, or null: a global variable
    /// lives in one text only.
    globals: ?*Globals = null,

    pub const Change = struct {
        /// The new tool (a slot, from 0).
        next: u32,
        /// The filament length (mm) that the nozzle flushes.
        flush_mm: f64 = 0,
        /// The number of this change in the print, from 1.
        count: u32 = 1,
        old_temp: f64 = 0,
        new_temp: f64 = 0,
        /// Where the nozzle goes after the change: the start of the next
        /// path, in G-code coordinates, and the z of the layer.
        after: [3]f64 = .{ 0, 0, 0 },
    };

    /// The nozzle of filament slot k: 0 on a printer with one nozzle.
    fn nozzleOf(c: *const Context, k: u32) u32 {
        const m = c.r.settings.machine;
        if (m.nozzles < 2) return 0;
        const f = if (k < c.slots.len) c.slots[k] else c.r.settings.filament;
        return m.nozzleIndex(f.nozzle);
    }

    /// A tool changer (`machine.tool_numbers = nozzle`): the extruder of
    /// the variables of PrusaSlicer is a nozzle, and a filament list
    /// (`filament_type[2]`) has the filament of each nozzle.
    fn tools(c: *const Context) bool {
        const m = c.r.settings.machine;
        return m.nozzles >= 2 and m.tool_numbers == .nozzle;
    }

    /// The extruder of slot `k` in the variables: its nozzle on a tool
    /// changer, else the slot.
    fn extruderOf(c: *const Context, k: u32) u32 {
        return if (c.tools()) c.nozzleOf(k) else k;
    }

    /// The first filament slot with nozzle `n` (a list index), or null.
    /// In the start G-code, the filament that it loads comes first: the
    /// print may not use slot 0.
    fn firstOfNozzle(c: *const Context, n: f64) ?u32 {
        if (c.phase == .start and c.change == null and c.layer_index == null and @as(f64, @floatFromInt(c.nozzleOf(c.tool))) == n) return c.tool;
        // The print's own first filament of the nozzle. A filament of the
        // plate that the print does not use has no AMS tray: the X2D
        // stopped 37 s into a print that named one for its idle nozzle.
        if (c.first_of_nozzles) |f| return if (n >= 0 and n < settings_mod.max_nozzles) f[@intFromFloat(n)] else null;
        const count: u32 = @intCast(@max(c.slots.len, 1));
        for (0..count) |k| if (@as(f64, @floatFromInt(c.nozzleOf(@intCast(k)))) == n) return @intCast(k);
        return null;
    }

    /// A Bambu Lab printer (machine.model "bambu-lab-...").
    fn bambu(c: *const Context) bool {
        return std.mem.startsWith(u8, c.r.settings.machine.model, "bambu-lab");
    }

    /// The facts of the presets of a Bambu Lab model, or null.
    fn facts(c: *const Context) ?printers.Bambu {
        return printers.bambu(c.r.settings.machine.model);
    }

    /// The nozzle of a list index: an extruder index (`each_nozzle`) or a
    /// filament index.
    fn nozzleIndex(c: *const Context, i: ?f64, of_filament: bool) usize {
        const v = i orelse return c.nozzleOf(c.tool);
        const k: u32 = if (v >= 0 and v < 64) @intFromFloat(v) else 0;
        return if (of_filament) c.nozzleOf(k) else @min(k, 1);
    }

    /// The filament of list index `i`, or of the tool now. On a tool
    /// changer, the index is a nozzle: the filament of that nozzle (the
    /// one in use, else the first of the plate on it).
    fn slot(c: *const Context, i: ?f64) settings_mod.Filament {
        var k: usize = if (i) |v| (if (v >= 0 and v < 64) @intFromFloat(v) else 0) else c.tool;
        if (i != null and c.tools()) {
            const n = i.?;
            k = if (@as(f64, @floatFromInt(c.nozzleOf(c.tool))) == n) c.tool else if (c.firstOfNozzle(n)) |f| f else c.slots.len;
        }
        if (k < c.slots.len) return c.slots[k];
        return c.r.settings.filament;
    }
};

/// What `render` found in the text.
pub const Result = struct {
    /// The last nozzle target of tool 0 (M104, M109) and the last bed
    /// target (M140, M190), or null if the text sets none.
    nozzle: ?f64 = null,
    bed: ?f64 = null,
    /// Another command (a macro, as PRINT_START EXTRUDER=215) has the
    /// value of a nozzle or bed temperature variable. The macro heats.
    macro_nozzle: bool = false,
    macro_bed: bool = false,
    /// The lines that became comments: a variable had no value.
    no_value: usize = 0,
};

// ---- The map ----

/// The zslice values. Each name of `names` has one.
pub const Key = enum {
    // Temperatures (°C).
    nozzle_temp,
    first_layer_nozzle_temp,
    bed_temp,
    first_layer_bed_temp,
    standby_temp,
    idle_temp,
    standby_delta,
    nozzle_range_low,
    nozzle_range_high,
    chamber_temp,
    // Sizes (mm).
    layer_height,
    first_layer_height,
    nozzle_diameter,
    filament_diameter,
    line_width,
    z_offset,
    max_height,
    bed_size_x,
    bed_size_y,
    bed_min,
    bed_max,
    bed_size,
    first_layer_min,
    first_layer_max,
    first_layer_size,
    first_layer_center,
    // Layers.
    max_layer_z,
    layer_z,
    // A filament change.
    next_tool,
    /// The extruder of the tool now, and of the next tool in a change: the
    /// nozzle on a tool changer (`machine.tool_numbers = nozzle`), else
    /// the filament slot.
    extruder,
    next_extruder,
    /// The position of the head: z only (the z of the layer).
    position,
    flush_length,
    old_filament_temp,
    new_filament_temp,
    toolchange_count,
    after_x,
    after_y,
    after_z,
    layer_num,
    layer_count,
    // Speeds (mm/s) and accelerations (mm/s²).
    travel_speed,
    first_layer_speed,
    print_speed,
    outer_wall_speed,
    inner_wall_speed,
    skin_speed,
    outer_wall_flow,
    max_speed_xy,
    max_speed_z,
    max_accel,
    travel_accel,
    outer_wall_accel,
    corner_speed,
    // Retraction.
    retract_length,
    retract_speed,
    z_hop,
    zero,
    // Fan (%).
    fan_speed,
    fan_max_speed,
    // The material.
    material,
    filament_name,
    max_flow,
    flow_percent,
    filament_mm,
    filament_m,
    filament_g,
    filament_cost,
    filament_volume,
    // The print.
    machine_name,
    job_name,
    print_time,
    infill_percent,
    support,
    adhesion,
    wall_thickness,
    top_thickness,
    bottom_thickness,
    // Extruders: zslice prints with tool 0.
    tool,
    one,
    /// The nozzle (from 0: 0 main, 1 second) of the filament now, of the next
    /// filament in a change, and of the filament of the list index.
    nozzle_now,
    nozzle_next,
    /// The extruder of each filament, from 1 (filament_map of Bambu
    /// Studio).
    filament_extruder,
    /// The hotend of the filament now or next: -1 on a Bambu Lab printer
    /// (each filament has one nozzle: Bambu Studio writes -1, and the
    /// firmware takes the nozzle of each filament from the file), else the
    /// nozzle.
    hotend_now,
    hotend_next,
    /// machine.nozzles.
    nozzle_count,
    /// The build plate, as Bambu Studio names it ("Textured PEI Plate").
    bed_type,
    extruder_used,
    /// The first filament of each nozzle (the list index), or -1: none.
    first_filament,
    material_tpu,
    // Fixed values: a feature that zslice does not have.
    off,
    empty_text,
    print_sequence,
    three,
    ten,
    forty,
    seventy,
    fifteen,
    /// The glass point of the material (°C): Bambu Studio's
    /// temperature_vitrification of its generic filaments.
    vitrification,
    /// The same on a Bambu Lab printer (its templates use it), else no
    /// value.
    bambu_vitrification,
    /// The facts of the presets of a Bambu Lab model (printers.Bambu), by
    /// nozzle: the retraction of a filament change (else the retraction
    /// of zslice), the heating and the cooling rate of the hotend, the
    /// retraction before the cutter, and a long retraction at the cut.
    /// A list index of the first three is a nozzle; of the last two, a
    /// filament.
    toolchange_retract,
    heating_rate,
    cooling_rate,
    cut_retract,
    long_cut,
    /// The id of the generic filament of Bambu Studio of the material.
    bambu_filament_id,
    /// The volume type of each nozzle, as Bambu Studio names it
    /// ("Standard", "High Flow").
    volume_name,
    /// The acceleration of the first layer (mm/s²).
    first_layer_accel,
    /// The retraction of a filament change with no cutter (mm): 14 in the
    /// filament presets of Bambu Studio (fdm_filament_common).
    nc_retract,
    lagrange,
    /// zslice has no value: see the header comment.
    no_value,
};

const Entry = struct { key: Key, list: bool = false };

fn just(k: Key) Entry {
    return .{ .key = k };
}

/// A list variable: one value for each extruder.
fn each(k: Key) Entry {
    return .{ .key = k, .list = true };
}

/// Each variable name of zslice, Cura (c), PrusaSlicer (p), OrcaSlicer
/// (o), and Bambu Studio (b), with its zslice value.
pub const names = std.StaticStringMap(Entry).initComptime(.{
    // zslice.
    .{ "nozzle_temp", just(.nozzle_temp) },
    .{ "first_layer_nozzle_temp", just(.first_layer_nozzle_temp) },
    .{ "bed_temp", just(.bed_temp) },
    .{ "first_layer_bed_temp", just(.first_layer_bed_temp) },
    .{ "standby_temp", just(.standby_temp) },
    .{ "layer_height", just(.layer_height) },
    .{ "first_layer_height", just(.first_layer_height) },
    .{ "first_layer_speed", just(.first_layer_speed) },
    .{ "nozzle_diameter", each(.nozzle_diameter) },
    .{ "filament_diameter", each(.filament_diameter) },
    .{ "filament_name", just(.filament_name) },
    .{ "machine_name", just(.machine_name) },
    .{ "job_name", just(.job_name) },

    // Nozzle temperature. c: material_print_temperature and the older
    // names. p: temperature. o, b: nozzle_temperature.
    .{ "material_print_temperature", each(.nozzle_temp) },
    .{ "default_material_print_temperature", each(.nozzle_temp) },
    .{ "print_temperature", each(.nozzle_temp) },
    .{ "temperature", each(.nozzle_temp) },
    .{ "nozzle_temperature", each(.nozzle_temp) },
    // The first layer. c: material_print_temperature_layer_0 and
    // material_initial_print_temperature. p: first_layer_temperature.
    // o, b: nozzle_temperature_initial_layer.
    .{ "material_print_temperature_layer_0", each(.first_layer_nozzle_temp) },
    .{ "material_initial_print_temperature", each(.first_layer_nozzle_temp) },
    .{ "first_layer_temperature", each(.first_layer_nozzle_temp) },
    .{ "nozzle_temperature_initial_layer", each(.first_layer_nozzle_temp) },
    // The bed, and the bed of the first layer (first_layer_bed_temp, or
    // bed_temp if it is 0). b: each plate type has its own name.
    .{ "material_bed_temperature", each(.bed_temp) },
    .{ "material_bed_temperature_layer_0", each(.first_layer_bed_temp) },
    .{ "print_bed_temperature", each(.bed_temp) },
    .{ "bed_temperature", each(.bed_temp) },
    .{ "first_layer_bed_temperature", each(.first_layer_bed_temp) },
    .{ "bed_temperature_initial_layer", each(.first_layer_bed_temp) },
    .{ "bed_temperature_initial_layer_single", just(.first_layer_bed_temp) },
    .{ "hot_plate_temp", each(.bed_temp) },
    .{ "hot_plate_temp_initial_layer", each(.first_layer_bed_temp) },
    .{ "cool_plate_temp", each(.bed_temp) },
    .{ "cool_plate_temp_initial_layer", each(.first_layer_bed_temp) },
    .{ "eng_plate_temp", each(.bed_temp) },
    .{ "eng_plate_temp_initial_layer", each(.first_layer_bed_temp) },
    .{ "textured_plate_temp", each(.bed_temp) },
    .{ "textured_plate_temp_initial_layer", each(.first_layer_bed_temp) },
    .{ "supertack_plate_temp", each(.bed_temp) },
    .{ "supertack_plate_temp_initial_layer", each(.first_layer_bed_temp) },
    // A tool that waits. p: idle_temperature has no value when the
    // filament does not set it (is_nil). p: standby_temperature_delta.
    .{ "material_standby_temperature", each(.standby_temp) },
    .{ "idle_temperature", each(.idle_temp) },
    .{ "standby_temperature_delta", just(.standby_delta) },
    .{ "nozzle_temperature_range_low", each(.nozzle_range_low) },
    .{ "nozzle_temperature_range_high", each(.nozzle_range_high) },
    // A heated chamber: zslice does not heat a chamber (0: off).
    .{ "chamber_temperature", each(.chamber_temp) },
    .{ "chamber_minimal_temperature", each(.chamber_temp) },
    .{ "overall_chamber_temperature", just(.chamber_temp) },
    .{ "build_volume_temperature", just(.chamber_temp) },
    // The temperature at which the material gets soft: the table of the
    // generic filaments of Bambu Studio, for a Bambu Lab printer.
    .{ "temperature_vitrification", each(.bambu_vitrification) },
    .{ "min_vitrification_temperature", just(.vitrification) },

    // Layers and sizes. c: layer_height_0. o: initial_layer_print_height.
    .{ "layer_height_0", just(.first_layer_height) },
    .{ "initial_layer_print_height", just(.first_layer_height) },
    .{ "machine_nozzle_size", just(.nozzle_diameter) },
    .{ "material_diameter", just(.filament_diameter) },
    .{ "z_offset", just(.z_offset) },
    .{ "max_print_height", just(.max_height) },
    .{ "printable_height", just(.max_height) },
    .{ "machine_height", just(.max_height) },
    .{ "machine_width", just(.bed_size_x) },
    .{ "machine_depth", just(.bed_size_y) },
    // p, o: points (x, y) in G-code coordinates.
    .{ "print_bed_min", just(.bed_min) },
    .{ "print_bed_max", just(.bed_max) },
    .{ "print_bed_size", just(.bed_size) },
    .{ "first_layer_print_min", just(.first_layer_min) },
    .{ "first_layer_print_max", just(.first_layer_max) },
    .{ "first_layer_print_size", just(.first_layer_size) },
    // o: the box of an adaptive bed mesh: zslice gives the box of the
    // first layer, with no margin.
    .{ "adaptive_bed_mesh_min", just(.first_layer_min) },
    .{ "adaptive_bed_mesh_max", just(.first_layer_max) },
    .{ "adaptive_bed_mesh_margin", just(.zero) },
    // o: Klipper accepts 3 to 6 points on each axis with "lagrange": 3 is
    // valid on each bed.
    .{ "bed_mesh_probe_count", just(.three) },
    .{ "bed_mesh_algo", just(.lagrange) },
    .{ "max_layer_z", just(.max_layer_z) },
    .{ "layer_z", just(.layer_z) },
    // p: the position of the head (x, y, z). The change G-code of the
    // Prusa XL lifts it (position[2] = position[2] + 2.0); zslice moves
    // back to the layer after each change, so only z has a value.
    .{ "position", each(.position) },
    .{ "layer_num", just(.layer_num) },
    .{ "total_layer_count", just(.layer_count) },
    .{ "total_layers", just(.layer_count) },
    .{ "line_width", just(.line_width) },
    .{ "outer_wall_line_width", just(.line_width) },
    .{ "infill_line_width", just(.line_width) },
    .{ "wall_line_width", just(.line_width) },
    .{ "wall_thickness", just(.wall_thickness) },
    .{ "top_thickness", just(.top_thickness) },
    .{ "bottom_thickness", just(.bottom_thickness) },
    .{ "top_bottom_thickness", just(.top_thickness) },

    // Speeds (mm/s). c: speed_travel, speed_layer_0. o: initial_layer_speed.
    .{ "travel_speed", just(.travel_speed) },
    .{ "speed_travel", just(.travel_speed) },
    .{ "speed_layer_0", just(.first_layer_speed) },
    .{ "speed_print_layer_0", just(.first_layer_speed) },
    .{ "initial_layer_speed", just(.first_layer_speed) },
    .{ "speed_print", just(.print_speed) },
    .{ "speed_infill", just(.print_speed) },
    .{ "outer_wall_speed", just(.outer_wall_speed) },
    .{ "speed_wall_0", just(.outer_wall_speed) },
    .{ "inner_wall_speed", just(.inner_wall_speed) },
    .{ "speed_wall_x", just(.inner_wall_speed) },
    .{ "speed_topbottom", just(.skin_speed) },
    // The limits of the machine. p, o: machine_max_*; a list of two (the
    // normal mode and the quiet mode). zslice has no limit of its own for
    // Z, E, and retractions: these lines become comments.
    .{ "machine_max_acceleration_extruding", each(.max_accel) },
    .{ "machine_max_acceleration_x", each(.max_accel) },
    .{ "machine_max_acceleration_y", each(.max_accel) },
    .{ "machine_max_acceleration_travel", each(.travel_accel) },
    .{ "machine_max_acceleration_retracting", each(.no_value) },
    .{ "machine_max_acceleration_z", each(.no_value) },
    .{ "machine_max_acceleration_e", each(.no_value) },
    .{ "machine_max_speed_x", each(.max_speed_xy) },
    .{ "machine_max_speed_y", each(.max_speed_xy) },
    .{ "machine_max_feedrate_x", each(.max_speed_xy) },
    .{ "machine_max_feedrate_y", each(.max_speed_xy) },
    .{ "machine_max_speed_z", each(.max_speed_z) },
    .{ "machine_max_feedrate_z", each(.max_speed_z) },
    .{ "machine_max_speed_e", each(.no_value) },
    .{ "machine_max_feedrate_e", each(.no_value) },
    .{ "machine_max_jerk_x", each(.corner_speed) },
    .{ "machine_max_jerk_y", each(.corner_speed) },
    .{ "machine_max_jerk_z", each(.no_value) },
    .{ "machine_max_jerk_e", each(.no_value) },
    .{ "outer_wall_acceleration", just(.outer_wall_accel) },
    .{ "default_acceleration", just(.max_accel) },
    .{ "travel_acceleration", just(.travel_accel) },
    .{ "acceleration_print", just(.max_accel) },
    .{ "acceleration_travel", just(.travel_accel) },
    .{ "jerk_print", just(.corner_speed) },

    // Retraction. c: retraction_amount, retraction_retract_speed. p:
    // retract_length, retract_speed. o: retraction_length,
    // retraction_speed.
    .{ "retraction_amount", just(.retract_length) },
    .{ "retract_length", each(.retract_length) },
    .{ "retraction_length", each(.retract_length) },
    .{ "retraction_retract_speed", just(.retract_speed) },
    .{ "retraction_prime_speed", just(.retract_speed) },
    .{ "retraction_speed", each(.retract_speed) },
    .{ "retract_speed", each(.retract_speed) },
    .{ "deretraction_speed", each(.retract_speed) },
    .{ "deretract_speed", each(.retract_speed) },
    .{ "retract_restart_extra", each(.zero) },
    .{ "retract_restart_extra_toolchange", each(.zero) },
    .{ "retract_length_toolchange", each(.toolchange_retract) },
    // b: the retraction of the old and of the new filament of a change,
    // and the length that the new extruder has retracted (the
    // retraction of a change).
    .{ "old_retract_length_toolchange", just(.toolchange_retract) },
    .{ "new_retract_length_toolchange", just(.toolchange_retract) },
    .{ "new_extruder_retracted_length", just(.toolchange_retract) },
    .{ "switch_extruder_retraction_amount", just(.no_value) },
    .{ "retraction_hop", just(.z_hop) },
    .{ "retract_lift", each(.z_hop) },
    .{ "z_hop", each(.z_hop) },
    .{ "zhop", just(.z_hop) },
    // p: the length that is retracted now (0 at the start).
    .{ "e_retracted", each(.zero) },
    // p, o: the purge of a tool on the wipe tower (the default of
    // PrusaSlicer, 15 mm³), the flush speed of OrcaSlicer (0: none of its
    // own), and the retraction of a tool change of the filament (no
    // value: the one of the printer). The tool change G-code of the CORE
    // One INDX reads them.
    .{ "filament_minimal_purge_on_wipe_tower", each(.fifteen) },
    .{ "filament_flush_volumetric_speed", each(.zero) },
    .{ "filament_retract_length_toolchange", each(.no_value) },
    // p: the loading moves of a multi material unit.
    .{ "parking_pos_retraction", just(.no_value) },
    .{ "extra_loading_move", just(.no_value) },

    // Fan (%). c: cool_fan_speed. p, o: fan_max_speed.
    .{ "cool_fan_speed", just(.fan_speed) },
    .{ "cool_fan_speed_min", just(.fan_speed) },
    .{ "cool_fan_speed_max", just(.fan_max_speed) },
    .{ "cool_fan_enabled", just(.one) },
    .{ "fan_max_speed", each(.fan_max_speed) },
    .{ "fan_min_speed", each(.fan_speed) },
    // b: the fans of the chamber of a Bambu Lab printer, with the values
    // of Bambu Studio for its generic filaments (zslice drives the part
    // fan only).
    .{ "additional_cooling_fan_speed", each(.seventy) },
    .{ "max_additional_fan", just(.seventy) },
    .{ "first_x_layer_fan_speed", each(.forty) },
    .{ "close_additional_fan_first_x_layers", each(.one) },
    .{ "additional_fan_full_speed_layer", each(.zero) },
    .{ "during_print_exhaust_fan_speed", each(.zero) },
    .{ "fan_speed_pwm", just(.no_value) },

    // The material. c: material_type, material_name. p, o: filament_type,
    // filament_settings_id.
    .{ "material_type", just(.material) },
    .{ "filament_type", each(.material) },
    .{ "material_name", just(.filament_name) },
    .{ "filament_settings_id", each(.filament_name) },
    .{ "filament_preset", each(.filament_name) },
    .{ "material_brand", just(.no_value) },
    .{ "material_id", just(.no_value) },
    .{ "material_guid", just(.no_value) },
    .{ "material_profile", just(.no_value) },
    .{ "filament_notes", each(.empty_text) },
    .{ "filament_vendor", each(.no_value) },
    // b: the id of the filament preset ("GFL99" for a generic PLA): the
    // id of the generic filament of its material (bambu.genericFilament).
    .{ "filament_ids", each(.bambu_filament_id) },
    .{ "filament_max_volumetric_speed", each(.max_flow) },
    .{ "filament_flush_volumetric_speed", each(.max_flow) },
    // o: the flow of the outer wall (mm³/s): its speed times its bead.
    .{ "outer_wall_volumetric_speed", just(.outer_wall_flow) },
    // b: the purge of the AMS: the flow and the hottest material value.
    .{ "flush_volumetric_speeds", each(.max_flow) },
    .{ "flush_temperatures", each(.nozzle_range_high) },
    .{ "material_flow", just(.flow_percent) },
    .{ "extrusion_multiplier", each(.flow_percent) },
    // The material features of p and o that zslice does not have.
    .{ "filament_abrasive", each(.off) },
    .{ "nozzle_high_flow", each(.off) },
    .{ "required_nozzle_HRC", each(.zero) },
    .{ "filament_multitool_ramming", each(.off) },
    .{ "enable_pressure_advance", each(.off) },
    .{ "pressure_advance", each(.no_value) },
    .{ "nozzle_volume_type", each(.no_value) },
    .{ "nozzle_type", each(.no_value) },
    // The filament of the print: 0 in the start G-code.
    .{ "filament_cost", each(.filament_cost) },
    .{ "total_cost", just(.filament_cost) },
    .{ "filament_weight", each(.filament_g) },
    .{ "total_weight", just(.filament_g) },
    .{ "used_filament", just(.filament_m) },
    .{ "filament_amount", each(.filament_m) },
    .{ "extruded_volume", each(.filament_volume) },
    .{ "extruded_volume_total", just(.filament_volume) },

    // The print. c: jobname, print_time. p: input_filename_base,
    // printer_preset, print_time. b: plate_name.
    .{ "jobname", just(.job_name) },
    .{ "input_filename_base", just(.job_name) },
    .{ "input_filename", just(.job_name) },
    .{ "plate_name", just(.job_name) },
    .{ "printer_preset", just(.machine_name) },
    .{ "printer_settings_id", just(.machine_name) },
    .{ "print_time", just(.print_time) },
    .{ "infill_sparse_density", just(.infill_percent) },
    .{ "fill_density", just(.infill_percent) },
    .{ "sparse_infill_density", just(.infill_percent) },
    .{ "support_enable", just(.support) },
    .{ "support_material", just(.support) },
    .{ "enable_support", just(.support) },
    .{ "adhesion_type", just(.adhesion) },
    .{ "magic_spiralize", just(.off) },
    .{ "spiral_vase", just(.off) },
    .{ "has_wipe_tower", just(.off) },
    .{ "enable_prime_tower", just(.off) },
    .{ "prime_tower_enable", just(.off) },
    .{ "has_single_extruder_multi_material_priming", just(.off) },
    .{ "single_extruder_multi_material", just(.off) },
    .{ "print_sequence", just(.print_sequence) },
    .{ "complete_objects", just(.off) },
    .{ "wall_0_wipe_dist", just(.zero) },
    .{ "start_filament_gcode", each(.empty_text) },
    .{ "printer_notes", just(.empty_text) },
    .{ "print_settings_id", just(.empty_text) },
    .{ "print_preset", just(.empty_text) },
    // The model of the printer: a printer checks it (M862.3 P "MK4").
    // zslice does not know the name of the vendor.
    .{ "printer_model", just(.no_value) },
    .{ "printer_variant", just(.no_value) },
    .{ "curr_bed_type", just(.bed_type) },
    // b: the lidar scan of the first layer.
    .{ "scan_first_layer", just(.off) },
    // b: the printers with two nozzles and an AMS (H2D): zslice prints
    // with filament 0 on nozzle 0.
    .{ "initial_filament_id", just(.tool) },
    .{ "initial_no_support_filament_id", just(.tool) },
    .{ "current_filament_id", just(.tool) },
    // b: a filament change (change_filament_gcode).
    .{ "next_filament_id", just(.next_tool) },
    .{ "flush_length", just(.flush_length) },
    .{ "old_filament_temp", just(.old_filament_temp) },
    .{ "new_filament_temp", just(.new_filament_temp) },
    .{ "toolchange_count", just(.toolchange_count) },
    .{ "x_after_toolchange", just(.after_x) },
    .{ "y_after_toolchange", just(.after_y) },
    .{ "z_after_toolchange", just(.after_z) },
    .{ "next_hotend", just(.hotend_next) },
    .{ "current_hotend", just(.hotend_now) },
    .{ "next_nozzle_id", just(.nozzle_next) },
    .{ "current_nozzle_id", just(.nozzle_now) },
    .{ "initial_nozzle_id", just(.nozzle_now) },
    .{ "initial_no_support_hotend", just(.hotend_now) },
    .{ "first_non_support_hotend", each(.hotend_now) },
    .{ "first_non_support_filaments", each(.first_filament) },
    .{ "first_filaments", each(.first_filament) },
    .{ "nozzle_diameter_at_nozzle_id", each(.nozzle_diameter) },
    .{ "is_all_bbl_filament", just(.off) },
    .{ "cooling_filter_enabled", just(.off) },
    .{ "hold_chamber_temp_for_flat_print", just(.off) },
    .{ "long_retraction_when_cut", just(.long_cut) },
    .{ "long_retraction_when_ec", just(.off) },
    .{ "long_retractions_when_cut", each(.long_cut) },
    .{ "retraction_distances_when_cut", each(.cut_retract) },
    .{ "retraction_distance_when_cut", just(.cut_retract) },
    .{ "hotend_heating_rate", each(.heating_rate) },
    .{ "hotend_cooling_rate", each(.cooling_rate) },
    .{ "nozzle_volume_types", each(.volume_name) },
    // b: a change with no cutter (the H2C): no cooling before it, and the
    // retraction of the generic filaments.
    .{ "filament_pre_cooling_temperature_nc", each(.zero) },
    .{ "filament_retract_length_nc", each(.nc_retract) },
    // b: Bambu Studio sets it false for a change (GCode::set_extruder).
    .{ "wipe_avoid_perimeter", just(.off) },
    // b: the lift of each filament: 0 is "Auto Lift", the value of the
    // Bambu Lab presets.
    .{ "z_hop_types", each(.zero) },
    .{ "initial_layer_acceleration", just(.first_layer_accel) },
    .{ "retraction_distances_when_ec", each(.no_value) },
    .{ "wipe_tower_center_pos_valid", just(.off) },
    // b: the interface of the prime tower (zslice has none), and the
    // cooling of the nozzle before the tower (Bambu Studio: 10 °C).
    .{ "is_prime_tower_interface", just(.off) },
    .{ "filament_cooling_before_tower", each(.ten) },
    .{ "spiral_mode", just(.off) },
    .{ "has_tpu_in_first_layer", just(.material_tpu) },
    .{ "max_print_z", just(.max_layer_z) },
    .{ "first_layer_center_no_wipe_tower", just(.first_layer_center) },
    .{ "infill_pattern", just(.no_value) },
    .{ "profile_string", just(.no_value) },
    .{ "belt_slice_rotation_angle", just(.no_value) },
    // A time of day: the core has no clock.
    .{ "time", just(.no_value) },
    .{ "date", just(.no_value) },
    .{ "day", just(.no_value) },
    .{ "month", just(.no_value) },
    .{ "year", just(.no_value) },
    .{ "hour", just(.no_value) },
    .{ "minute", just(.no_value) },
    .{ "second", just(.no_value) },
    .{ "timestamp", just(.no_value) },
    .{ "random", just(.no_value) },

    // Extruders: zslice prints with one nozzle. Each filament of the
    // plate is a tool (T0, T1, ...) of a unit that feeds the filaments.
    .{ "initial_tool", just(.extruder) },
    .{ "initial_extruder", just(.extruder) },
    .{ "initial_extruder_nr", just(.extruder) },
    .{ "current_extruder", just(.extruder) },
    .{ "initial_no_support_extruder", just(.extruder) },
    .{ "initial_no_support_tool", just(.extruder) },
    .{ "extruder_nr", just(.extruder) },
    .{ "next_extruder", just(.next_extruder) },
    .{ "previous_extruder", just(.extruder) },
    .{ "num_extruders", just(.nozzle_count) },
    .{ "extruders_count", just(.nozzle_count) },
    .{ "machine_extruder_count", just(.nozzle_count) },
    .{ "parallel_printheads_count", just(.one) },
    .{ "total_toolchanges", just(.zero) },
    .{ "is_extruder_used", each(.extruder_used) },
    .{ "filament_map", each(.filament_extruder) },
});

// ---- Rendering ----

pub const Error = error{ Syntax, Unknown, NoValue, ObjectModel, OutOfMemory, WriteFailed };

const Frame = struct {
    /// The text of this branch goes into the G-code.
    active: bool,
    /// A branch of this if was taken.
    taken: bool,
    /// The frame around this one was active.
    outer: bool,
};

const Renderer = struct {
    arena: Allocator,
    ctx: *const Context,
    w: *Writer,
    result: Result = .{},
    /// The variables of the text (local and global).
    vars: std.StringHashMapUnmanaged(Value) = .empty,
    frames: [32]Frame = undefined,
    depth: usize = 0,
    /// The line that the text writes now.
    line: std.ArrayList(u8) = .empty,
    /// Comment lines that go before the line.
    notes: std.ArrayList(u8) = .empty,
    /// Why the line becomes a comment ("no value for NAME"), or null.
    missing: ?[]const u8 = null,
    /// The line has a control block ({if}, {endif}, ...) or a block with
    /// no value (an assignment).
    control: bool = false,
    /// The line used a temperature variable for its value.
    used_nozzle: bool = false,
    used_bed: bool = false,
    /// The value that comes out of a block now goes into the G-code.
    in_output: bool = false,
    /// The name of the last variable that had no value.
    last_missing: []const u8 = "",

    fn active(self: *const Renderer) bool {
        return self.depth == 0 or self.frames[self.depth - 1].active;
    }

    /// True if the line has a ';' already: the text after it is a comment.
    fn inComment(self: *const Renderer) bool {
        return std.mem.indexOfScalar(u8, self.line.items, ';') != null;
    }

    /// A comment line before the line. Its text is on one line.
    fn note(self: *Renderer, comptime fmt: []const u8, args: anytype) Error!void {
        const t = try std.fmt.allocPrint(self.arena, "; zslice: " ++ fmt, args);
        for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
            ch.* = ' ';
        };
        try self.notes.appendSlice(self.arena, t);
        try self.notes.append(self.arena, '\n');
    }

    fn flush(self: *Renderer, newline: bool) Writer.Error!void {
        try self.w.writeAll(self.notes.items);
        self.notes.clearRetainingCapacity();
        const text = self.line.items;
        const blank = std.mem.trim(u8, text, " \t\r").len == 0;
        if (self.missing) |why| {
            try self.w.print("; zslice: {s}: ", .{why});
            self.result.no_value += 1;
        } else if (!blank) {
            // A block can write more than one line.
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |l| self.scanLine(l);
        }
        // A line of control blocks only: no empty line in the G-code.
        const skip = blank and self.control;
        if (!skip) {
            if (self.missing != null) {
                // Each line of a block with no value is a comment.
                var lines = std.mem.splitScalar(u8, text, '\n');
                var first = true;
                while (lines.next()) |l| {
                    if (!first) try self.w.writeAll("\n; ");
                    first = false;
                    try self.w.writeAll(l);
                }
            } else {
                try self.w.writeAll(text);
            }
            if (newline) try self.w.writeByte('\n');
        }
        self.line.clearRetainingCapacity();
        self.missing = null;
        self.control = false;
        self.used_nozzle = false;
        self.used_bed = false;
    }

    /// The temperatures that a written line sets.
    fn scanLine(self: *Renderer, text: []const u8) void {
        const cmd = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, text, ';')) |c| text[0..c] else text, " \t\r");
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        const head = it.next() orelse return;
        const nozzle_cmd = eqlUpper(head, "M104") or eqlUpper(head, "M109");
        const bed_cmd = eqlUpper(head, "M140") or eqlUpper(head, "M190");
        if (nozzle_cmd or bed_cmd) {
            var s: ?f64 = null;
            var tool: f64 = 0;
            while (it.next()) |word| {
                if (word.len < 2) continue;
                const v = std.fmt.parseFloat(f64, word[1..]) catch continue;
                switch (std.ascii.toUpper(word[0])) {
                    'S', 'R' => if (s == null) {
                        s = v;
                    },
                    'T' => tool = v,
                    else => {},
                }
            }
            if (s) |v| {
                if (nozzle_cmd and tool == 0) self.result.nozzle = v;
                if (bed_cmd) self.result.bed = v;
            }
            return;
        }
        if (eqlUpper(head, "SET_HEATER_TEMPERATURE")) {
            var heater: []const u8 = "";
            var target: ?f64 = null;
            while (it.next()) |word| {
                if (std.ascii.startsWithIgnoreCase(word, "HEATER=")) heater = word[7..];
                if (std.ascii.startsWithIgnoreCase(word, "TARGET=")) target = std.fmt.parseFloat(f64, word[7..]) catch null;
            }
            if (target) |v| {
                if (std.ascii.eqlIgnoreCase(heater, "extruder")) self.result.nozzle = v;
                if (std.ascii.eqlIgnoreCase(heater, "heater_bed")) self.result.bed = v;
            }
            return;
        }
        // A macro: a name that is not a G, M, or T code.
        const code = head.len > 1 and std.mem.indexOfScalar(u8, "GMTgmt", head[0]) != null and std.ascii.isDigit(head[1]);
        if (code) return;
        if (self.used_nozzle) self.result.macro_nozzle = true;
        if (self.used_bed) self.result.macro_bed = true;
    }

    fn textOf(self: *Renderer, v: Value) Error![]const u8 {
        return textOfImpl(self.arena, v);
    }

    fn put(self: *Renderer, text: []const u8) Error!void {
        try self.line.appendSlice(self.arena, text);
    }

    /// A text of the settings on one line, with a space for each line
    /// end. A text comes from outside (a part, a file, or a filament name
    /// of an imported profile): "PLA\nM104 S350" must not become a
    /// command of its own. A firmware also ends a line at '\r'.
    fn oneLine(self: *Renderer, text: []const u8) Value {
        if (std.mem.indexOfAny(u8, text, "\n\r") == null) return .{ .text = text };
        const out = self.arena.dupe(u8, text) catch return .nil;
        for (out) |*c| if (c.* == '\n' or c.* == '\r') {
            c.* = ' ';
        };
        return .{ .text = out };
    }

    fn putValue(self: *Renderer, v: Value) Error!void {
        switch (v) {
            .nil => return error.NoValue,
            .boolean => |b| try self.put(if (b) "1" else "0"),
            .num => |n| try self.put(try numText(self.arena, n)),
            // A text of the template can have lines ("G1 F" + v + "\n" in
            // a change G-code); the texts of the settings have one line
            // (see `oneLine`).
            .text => |t| try self.put(t),
            .list => |items| for (items, 0..) |x, i| {
                if (i > 0) try self.put(",");
                try self.putValue(x);
            },
        }
    }

    /// Renders the text.
    fn run(self: *Renderer, text: []const u8) Error!void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '{') {
                if (blockEnd(text, i)) |close| {
                    try self.block(text[i + 1 .. close], text[i .. close + 1]);
                    i = close + 1;
                    continue;
                }
                // A '{' with no '}': the source is broken. A command with
                // it is no command.
                if (self.active() and !self.inComment() and self.missing == null) self.missing = "a { with no }";
            } else if (c == '[') {
                if (bracketEnd(text, i)) |close| {
                    try self.bracket(text[i + 1 .. close], text[i .. close + 1]);
                    i = close + 1;
                    continue;
                }
            } else if (c == '\n') {
                if (self.active() or self.line.items.len > 0 or self.notes.items.len > 0) {
                    try self.flushLine(true);
                }
                i += 1;
                continue;
            }
            if (self.active()) try self.line.append(self.arena, c);
            i += 1;
        }
        try self.flushLine(false);
    }

    fn flushLine(self: *Renderer, newline: bool) Error!void {
        // An inactive line with no text: no output.
        if (!self.active() and self.line.items.len == 0 and self.notes.items.len == 0) {
            self.control = false;
            return;
        }
        try self.flush(newline);
    }

    /// A [name] or [name[index]] of PrusaSlicer and OrcaSlicer.
    fn bracket(self: *Renderer, inner: []const u8, raw: []const u8) Error!void {
        if (!self.active()) return;
        var p: Parser = .{ .r = self, .src = inner };
        self.in_output = true;
        defer self.in_output = false;
        const v = p.expression(true) catch |err| return self.unresolved(err, raw);
        p.skipSpace();
        if (p.pos != p.src.len) return self.unresolved(error.Syntax, raw);
        self.putValue(v) catch |err| return self.unresolved(err, raw);
    }

    /// A {...} block: control, or statements.
    fn block(self: *Renderer, inner: []const u8, raw: []const u8) Error!void {
        var p: Parser = .{ .r = self, .src = inner };
        p.skipSpace();
        const save = p.pos;
        const word = p.word();
        if (eqlAny(word, &.{ "if", "elsif", "elif", "else", "endif" })) {
            // A block with "then" is a statement (see Parser.statement).
            if (!(std.mem.eql(u8, word, "if") and hasThen(inner))) {
                return self.control_block(word, &p, raw);
            }
        }
        p.pos = save;
        if (!self.active()) return;
        if (self.inComment() and self.missing == null) {
            // A block in a comment: its value, or the block as it is.
            self.in_output = true;
            defer self.in_output = false;
            const v = p.statements(true) catch {
                try self.put(raw);
                return;
            };
            if (v) |x| self.putValue(x) catch try self.put(raw) else self.control = true;
            return;
        }
        self.in_output = true;
        defer self.in_output = false;
        const v = p.statements(true) catch |err| return self.unresolved(err, raw);
        if (v) |x| self.putValue(x) catch |err| return self.unresolved(err, raw) else self.control = true;
    }

    /// A value that zslice cannot give: on RepRapFirmware, the object
    /// model stays; in a comment, the block stays; else the line becomes
    /// a comment.
    fn unresolved(self: *Renderer, err: Error, raw: []const u8) Error!void {
        if (err == error.OutOfMemory) return err;
        if (err == error.ObjectModel and self.ctx.object_model) return self.put(raw);
        if (!self.inComment() and self.missing == null) {
            const name = switch (err) {
                error.Unknown, error.NoValue => if (self.last_missing.len > 0) self.last_missing else raw,
                else => raw,
            };
            self.missing = try std.fmt.allocPrint(self.arena, "no value for {s}", .{name});
        }
        try self.put(raw);
    }

    fn control_block(self: *Renderer, word: []const u8, p: *Parser, raw: []const u8) Error!void {
        self.control = true;
        if (std.mem.eql(u8, word, "if")) {
            if (self.depth == self.frames.len) return;
            const outer = self.active();
            const c = if (outer) try self.condition(p, raw) else false;
            self.frames[self.depth] = .{ .active = outer and c, .taken = c, .outer = outer };
            self.depth += 1;
            return;
        }
        if (self.depth == 0) return; // an elsif or else with no if
        const f = &self.frames[self.depth - 1];
        if (std.mem.eql(u8, word, "endif")) {
            self.depth -= 1;
            return;
        }
        if (std.mem.eql(u8, word, "else")) {
            f.active = f.outer and !f.taken;
            f.taken = true;
            return;
        }
        // elsif, elif
        if (!f.outer or f.taken) {
            f.active = false;
            return;
        }
        const c = try self.condition(p, raw);
        f.active = c;
        f.taken = c;
    }

    /// The value of a condition. A condition with no value is false, and
    /// a comment tells it.
    fn condition(self: *Renderer, p: *Parser, raw: []const u8) Error!bool {
        self.last_missing = "";
        const v = p.expression(true) catch |err| {
            if (err == error.OutOfMemory) return err;
            const name = if (self.last_missing.len > 0) self.last_missing else raw;
            try self.note("no value for {s}, so this condition is false: {s}", .{ name, raw });
            return false;
        };
        return v.truthy();
    }

    /// The value of a variable, or `error.Unknown`.
    fn variable(self: *Renderer, name: []const u8, index: ?f64) Error!Value {
        if (self.vars.get(name)) |v| return pick(v, index);
        if (self.ctx.globals) |g| if (g.map.get(name)) |v| return pick(v, index);
        if (names.get(name)) |en| {
            const v = self.value(en.key, index);
            switch (en.key) {
                .nozzle_temp, .first_layer_nozzle_temp => if (self.in_output) {
                    self.used_nozzle = true;
                },
                .bed_temp, .first_layer_bed_temp => if (self.in_output) {
                    self.used_bed = true;
                },
                else => {},
            }
            if (v == .nil) self.last_missing = name;
            return v;
        }
        // The old index forms: first_layer_print_min_0, and
        // first_layer_temperature_[1].
        if (std.mem.lastIndexOfScalar(u8, name, '_')) |u| {
            const base = name[0..u];
            const tail = name[u + 1 ..];
            if (base.len > 0 and names.get(base) != null) {
                if (tail.len == 0) return self.variable(base, index);
                if (std.fmt.parseInt(u8, tail, 10)) |k| return self.variable(base, @floatFromInt(k)) else |_| {}
            }
        }
        self.last_missing = name;
        return error.Unknown;
    }

    /// The zslice value of a key. `index`: the index in a list (an
    /// extruder, or x and y of a point).
    fn value(self: *Renderer, key: Key, index: ?f64) Value {
        const c = self.ctx;
        const r = c.r;
        const s = r.settings;
        const m = s.machine;
        // The filament keys read the slot of the index (a list variable)
        // or of the tool now.
        const f = c.slot(index);
        const p = s.project;
        const end = c.phase == .end;
        return switch (key) {
            .nozzle_temp => num(@round(f.nozzle_temp)),
            .first_layer_nozzle_temp => num(@round(f.first_layer_nozzle_temp)),
            .bed_temp => num(@round(f.bed_temp)),
            .first_layer_bed_temp => num(@round(f.firstBedTemp())),
            .standby_temp => num(@round(f.standby_temp)),
            .idle_temp => if (f.standby_temp > 0) num(@round(f.standby_temp)) else .nil,
            // machine.standby_delta, else the PrusaSlicer default: a tool
            // that waits is 5 °C cooler.
            .standby_delta => num(if (m.standby_delta != 0) m.standby_delta else -5),
            .nozzle_range_low => num(@round(@min(f.nozzle_temp, f.first_layer_nozzle_temp))),
            .nozzle_range_high => num(@round(@max(f.nozzle_temp, f.first_layer_nozzle_temp))),
            .chamber_temp => num(0),
            .layer_height => num(round3(p.layer_height)),
            .first_layer_height => num(round3(p.first_layer_height)),
            .nozzle_diameter => num(round3(nozzleDiameter(m, index))),
            .filament_diameter => num(round3(f.diameter)),
            .line_width => num(round3(r.line_width)),
            .z_offset, .zero => num(0),
            .max_height => num(m.max_height),
            .bed_size_x => num(m.bed_size_x),
            .bed_size_y => num(m.bed_size_y),
            .bed_min => point(m.origin_x, m.origin_y, index),
            .bed_max => point(m.origin_x + m.bed_size_x, m.origin_y + m.bed_size_y, index),
            .bed_size => point(m.bed_size_x, m.bed_size_y, index),
            .first_layer_min => blk: {
                const b = self.firstBox();
                break :blk point(b[0], b[1], index);
            },
            .first_layer_max => blk: {
                const b = self.firstBox();
                break :blk point(b[2], b[3], index);
            },
            .first_layer_size => blk: {
                const b = self.firstBox();
                break :blk point(b[2] - b[0], b[3] - b[1], index);
            },
            .first_layer_center => blk: {
                const b = self.firstBox();
                break :blk point((b[0] + b[2]) / 2, (b[1] + b[3]) / 2, index);
            },
            .max_layer_z => num(round3(c.max_layer_z)),
            .layer_z => num(round3(c.layer_z)),
            .layer_num => num(if (c.layer_index) |i| @floatFromInt(i) else if (end and c.layer_count > 0) @floatFromInt(c.layer_count - 1) else 0),
            .next_tool => num(@floatFromInt(if (c.change) |ch| ch.next else c.tool)),
            .extruder => num(@floatFromInt(c.extruderOf(c.tool))),
            .position => if (index) |i| (if (i == 2) num(round3(c.layer_z)) else .nil) else .nil,
            .next_extruder => num(@floatFromInt(c.extruderOf(if (c.change) |ch| ch.next else c.tool))),
            .flush_length => if (c.change) |ch| num(round3(ch.flush_mm)) else num(0),
            .old_filament_temp => num(@round(if (c.change) |ch| ch.old_temp else f.nozzle_temp)),
            .new_filament_temp => num(@round(if (c.change) |ch| ch.new_temp else f.nozzle_temp)),
            .toolchange_count => num(@floatFromInt(if (c.change) |ch| ch.count else 0)),
            .after_x => if (c.change) |ch| num(round3(ch.after[0])) else .nil,
            .after_y => if (c.change) |ch| num(round3(ch.after[1])) else .nil,
            .after_z => if (c.change) |ch| num(round3(ch.after[2])) else .nil,
            .layer_count => num(@floatFromInt(c.layer_count)),
            .travel_speed => num(m.travel_speed),
            .first_layer_speed => num(@round(r.speed(.inner_wall, r.first_layer_line_width, p.first_layer_height, true))),
            .print_speed => num(@round(r.speed(.infill, r.line_width, p.layer_height, false))),
            .outer_wall_speed => num(@round(r.speed(.outer_wall, r.line_width, p.layer_height, false))),
            .inner_wall_speed => num(@round(r.speed(.inner_wall, r.line_width, p.layer_height, false))),
            .skin_speed => num(@round(r.speed(.skin, r.line_width, p.layer_height, false))),
            .outer_wall_flow => num(round3(r.speed(.outer_wall, r.line_width, p.layer_height, false) * flow.beadArea(r.line_width, p.layer_height))),
            .max_speed_xy => num(m.max_speed),
            .max_speed_z => num(m.max_z_speed),
            .max_accel => num(m.max_accel),
            .travel_accel => num(r.accel(null, false)),
            .outer_wall_accel => num(r.accel(.outer_wall, false)),
            .corner_speed => num(m.corner_speed),
            .retract_length => num(round3(r.retract_length)),
            .retract_speed => num(m.retract_speed),
            .z_hop => num(m.z_hop),
            .fan_speed => num(@round(f.fan_speed * 100)),
            .fan_max_speed => num(@round(f.fan_max_speed * 100)),
            .material => self.oneLine(f.material),
            .filament_name => self.oneLine(f.name),
            .max_flow => num(f.max_flow),
            .flow_percent => num(@round(f.flow_ratio * 100)),
            .filament_mm => num(round3(c.filament_mm)),
            .filament_m => num(round3(c.filament_mm / 1000)),
            .filament_g => num(round3(c.filament_g)),
            .filament_cost => num(round3(c.filament_g * f.price_per_kg / 1000)),
            .filament_volume => num(round3(c.filament_mm * r.filament_area)),
            .machine_name => self.oneLine(m.name),
            .job_name => self.oneLine(s.engine.job_name),
            .print_time => if (end) num(@round(c.print_time_s)) else .nil,
            .infill_percent => num(@round(p.infill_density * 100)),
            .support => .{ .boolean = p.support != .off },
            .adhesion => .{ .text = if (p.brim_width > 0) "brim" else "skirt" },
            .wall_thickness => num(round3(@as(f64, @floatFromInt(p.wall_count)) * r.line_width)),
            .top_thickness => num(p.top_thickness),
            .bottom_thickness => num(p.bottom_thickness),
            .tool => num(@floatFromInt(c.tool)),
            .one => num(1),
            .nozzle_now => num(@floatFromInt(c.nozzleOf(c.tool))),
            .nozzle_next => num(@floatFromInt(c.nozzleOf(if (c.change) |ch| ch.next else c.tool))),
            .filament_extruder => num(@floatFromInt(c.nozzleOf(if (index) |v| (if (v >= 0 and v < 64) @intFromFloat(v) else 0) else c.tool) + 1)),
            .hotend_now => num(if (c.bambu()) -1 else @floatFromInt(c.nozzleOf(c.tool))),
            .hotend_next => num(if (c.bambu()) -1 else @floatFromInt(c.nozzleOf(if (c.change) |ch| ch.next else c.tool))),
            .nozzle_count => num(@floatFromInt(@max(m.nozzles, 1))),
            .bed_type => .{ .text = m.bed_type.studioName() },
            // An extruder (a nozzle) is in use if a filament of the plate
            // has it.
            .extruder_used => .{ .boolean = c.firstOfNozzle(index orelse 0) != null },
            .first_filament => num(if (c.firstOfNozzle(index orelse 0)) |k| @floatFromInt(k) else -1),
            .material_tpu => .{ .boolean = std.ascii.eqlIgnoreCase(f.material, "TPU") },
            .off => .{ .boolean = false },
            .empty_text => .{ .text = "" },
            .print_sequence => .{ .text = "by layer" },
            .three => num(3),
            .ten => num(10),
            .forty => num(40),
            .seventy => num(70),
            .fifteen => num(15),
            .vitrification => num(vitrificationOf(f.material)),
            .bambu_vitrification => if (c.bambu()) num(vitrificationOf(f.material)) else .nil,
            .toolchange_retract => if (c.facts()) |b| num(b.toolchange_retract[c.nozzleIndex(index, false)]) else num(round3(r.retract_length)),
            .heating_rate => if (c.facts()) |b| nonzero(b.heating_rate[c.nozzleIndex(index, false)]) else .nil,
            .cooling_rate => if (c.facts()) |b| nonzero(b.cooling_rate[c.nozzleIndex(index, false)]) else .nil,
            .cut_retract => if (c.facts()) |b| nonzero(b.cut_retract[c.nozzleIndex(index, true)]) else .nil,
            .long_cut => .{ .boolean = if (c.facts()) |b| b.long_cut[c.nozzleIndex(index, true)] else false },
            .bambu_filament_id => if (c.bambu()) .{ .text = @import("bambu.zig").genericFilament(f.material) } else .nil,
            .volume_name => .{ .text = if (m.nozzle_flow == .high_flow) "High Flow" else "Standard" },
            .first_layer_accel => num(r.accel(.inner_wall, true)),
            .nc_retract => num(14),
            .lagrange => .{ .text = "lagrange" },
            .no_value => .nil,
        };
    }

    fn firstBox(self: *const Renderer) [4]f64 {
        const m = self.ctx.r.settings.machine;
        return self.ctx.first_layer_box orelse .{ m.origin_x, m.origin_y, m.origin_x + m.bed_size_x, m.origin_y + m.bed_size_y };
    }
};

/// The glass point of a material (°C), as the generic filaments of Bambu
/// Studio give it: the chamber fans of a Bambu Lab printer use it.
fn vitrificationOf(material: []const u8) f64 {
    const table = [_]struct { []const u8, f64 }{
        .{ "PLA", 45 }, .{ "PETG", 64 }, .{ "ABS", 94 }, .{ "ASA", 94 }, .{ "TPU", 30 }, .{ "PC", 110 }, .{ "PA", 60 }, .{ "PVA", 50 },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], material)) return e[1];
    return 60;
}

fn num(v: f64) Value {
    return .{ .num = v };
}

/// A value of the presets: 0 is no value.
fn nonzero(v: f64) Value {
    return if (v != 0) num(v) else .nil;
}

/// The diameter of nozzle `index` (a list index), or of the nozzle now: a
/// nozzle after the first with a diameter of its own has it.
fn nozzleDiameter(m: settings_mod.Machine, index: ?f64) f64 {
    const v = index orelse return m.nozzle_diameter;
    if (!(v >= 1 and v < settings_mod.max_nozzles)) return m.nozzle_diameter;
    return m.nozzleValue(@intFromFloat(v), "diameter") orelse m.nozzle_diameter;
}

fn round3(v: f64) f64 {
    return @round(v * 1000) / 1000;
}

/// A point: x for index 0, y for index 1, both with no index.
fn point(x: f64, y: f64, index: ?f64) Value {
    const i = index orelse return .nil;
    return if (i == 0) num(x) else if (i == 1) num(y) else .nil;
}

/// An item of a list value, or the value itself.
fn pick(v: Value, index: ?f64) Value {
    const i = index orelse return v;
    return switch (v) {
        .list => |items| if (i >= 0 and i < @as(f64, @floatFromInt(items.len))) items[@intFromFloat(i)] else .nil,
        else => v,
    };
}

/// A number as text: whole numbers with no point, others with at most 4
/// decimals and no trailing zeros.
fn numText(a: Allocator, v: f64) Allocator.Error![]const u8 {
    if (!std.math.isFinite(v)) return a.dupe(u8, "0");
    const r = @round(v);
    if (@abs(v - r) < 1e-9 and @abs(r) < 1e15) {
        if (r == 0) return a.dupe(u8, "0");
        return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(r))});
    }
    var t = try std.fmt.allocPrint(a, "{d:.4}", .{v});
    while (t.len > 0 and t[t.len - 1] == '0') t = t[0 .. t.len - 1];
    if (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    if (std.mem.eql(u8, t, "-0")) return "0";
    return t;
}

fn eqlUpper(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn eqlAny(a: []const u8, list: []const []const u8) bool {
    for (list) |b| if (std.mem.eql(u8, a, b)) return true;
    return false;
}

/// True if a block has the word "then" (a statement `if ... then`).
fn hasThen(text: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "then")) |k| {
        const before = k == 0 or !isIdent(text[k - 1]);
        const after = k + 4 >= text.len or !isIdent(text[k + 4]);
        if (before and after) return true;
        i = k + 4;
    }
    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The index of the '}' that ends the block at `open`, or null. A text in
/// quotes can have braces.
fn blockEnd(text: []const u8, open: usize) ?usize {
    var i = open + 1;
    var quote = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote) {
            if (c == '\\') i += 1 else if (c == '"') quote = false;
            continue;
        }
        switch (c) {
            '"' => quote = true,
            '{' => return null,
            '}' => return i,
            else => {},
        }
    }
    return null;
}

/// The index of the ']' that ends a [name] at `open`, or null if the
/// text there is no variable. A variable starts with a lower case letter
/// or '_', has no space, and can have one index: [name[index]].
fn bracketEnd(text: []const u8, open: usize) ?usize {
    var i = open + 1;
    if (i >= text.len or !(std.ascii.isLower(text[i]) or text[i] == '_')) return null;
    while (i < text.len and isIdent(text[i])) i += 1;
    if (i >= text.len) return null;
    if (text[i] == ']') return i;
    if (text[i] != '[') return null;
    var depth: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) {
                    // An expression after the index: [filament_map[0]-1].
                    var k = i + 1;
                    while (k < text.len and text[k] != ']' and text[k] != '\n' and text[k] != '[') k += 1;
                    if (k < text.len and text[k] == ']') return k;
                    return null;
                }
            },
            '\n' => return null,
            else => {},
        }
    }
    return null;
}

// ---- The expression language ----

/// The most parentheses, signs, and `?` parts inside each other in one
/// expression. An imported start G-code can nest without end: it stops
/// with a syntax error before the stack runs out.
const max_depth = 64;

const Parser = struct {
    r: *Renderer,
    src: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > max_depth) return error.Syntax;
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    fn peek(p: *Parser) u8 {
        p.skipSpace();
        return if (p.pos < p.src.len) p.src[p.pos] else 0;
    }

    /// The identifier at the position (no move if none).
    fn word(p: *Parser) []const u8 {
        p.skipSpace();
        const start = p.pos;
        if (p.pos < p.src.len and (std.ascii.isAlphabetic(p.src[p.pos]) or p.src[p.pos] == '_')) {
            while (p.pos < p.src.len and isIdent(p.src[p.pos])) p.pos += 1;
        }
        return p.src[start..p.pos];
    }

    fn peekWord(p: *Parser) []const u8 {
        const save = p.pos;
        defer p.pos = save;
        return p.word();
    }

    fn eat(p: *Parser, s: []const u8) bool {
        p.skipSpace();
        if (std.mem.startsWith(u8, p.src[p.pos..], s)) {
            p.pos += s.len;
            return true;
        }
        return false;
    }

    fn eatWord(p: *Parser, w: []const u8) bool {
        const save = p.pos;
        if (std.mem.eql(u8, p.word(), w)) return true;
        p.pos = save;
        return false;
    }

    fn expect(p: *Parser, s: []const u8) Error!void {
        if (!p.eat(s)) return error.Syntax;
    }

    /// Statements: `local x = e`, `global x = e`, `x = e`, `x[i] = e`,
    /// `if e then ... elsif e then ... else ... endif`, and expressions.
    /// ';' and line ends split them. The value is the value of the last
    /// expression, or null if there is none.
    /// The statements of a block, up to its end or an elsif, else, or
    /// endif. Each statement with a value writes it, as in PrusaSlicer: a
    /// change G-code writes its lines from a list of texts. One value
    /// keeps its kind; more become one text.
    fn statements(p: *Parser, run: bool) Error!?Value {
        var out: ?Value = null;
        var joined = false;
        while (true) {
            while (p.peek() == ';') p.pos += 1;
            if (p.pos >= p.src.len) break;
            const w = p.peekWord();
            if (eqlAny(w, &.{ "elsif", "else", "endif" })) break;
            const v = (try p.statement(run)) orelse continue;
            if (!run) continue;
            if (out) |o| {
                const a = if (joined) o.text else try p.r.textOf(o);
                out = .{ .text = try std.mem.concat(p.r.arena, u8, &.{ a, try p.r.textOf(v) }) };
                joined = true;
            } else out = v;
        }
        return out;
    }

    fn statement(p: *Parser, run: bool) Error!?Value {
        const save = p.pos;
        const w = p.word();
        if (std.mem.eql(u8, w, "if")) {
            var taken = false;
            var cond = try p.expression(run);
            if (!p.eatWord("then")) return error.Syntax;
            var last: ?Value = null;
            while (true) {
                const go = run and !taken and cond.truthy();
                const v = try p.statements(go);
                if (go) {
                    taken = true;
                    last = v;
                }
                const k = p.word();
                if (std.mem.eql(u8, k, "endif")) break;
                if (std.mem.eql(u8, k, "else")) {
                    cond = .{ .boolean = true };
                    continue;
                }
                if (std.mem.eql(u8, k, "elsif")) {
                    cond = try p.expression(run and !taken);
                    if (!p.eatWord("then")) return error.Syntax;
                    continue;
                }
                return error.Syntax;
            }
            return last;
        }
        if (std.mem.eql(u8, w, "local") or std.mem.eql(u8, w, "global")) {
            const name = p.word();
            if (name.len == 0) return error.Syntax;
            try p.expect("=");
            const v = try p.expression(run);
            if (run) {
                const global = std.mem.eql(u8, w, "global");
                if (global and p.r.ctx.globals != null) try p.r.ctx.globals.?.put(name, v) else try p.r.vars.put(p.r.arena, name, v);
            }
            return null;
        }
        // An assignment: name = e, or name[i] = e.
        if (w.len > 0) {
            var index: ?f64 = null;
            const after_name = p.pos;
            if (p.peek() == '[') {
                p.pos += 1;
                const iv = try p.expression(run);
                try p.expect("]");
                index = asNum(iv) catch null;
            }
            if (p.peek() == '=' and !std.mem.startsWith(u8, p.src[p.pos..], "==")) {
                p.pos += 1;
                const v = try p.expression(run);
                if (run) try p.assign(w, index, v);
                return null;
            }
            p.pos = after_name;
        }
        p.pos = save;
        const v = try p.expression(run);
        // Cura: {name, extruder}. The extruder is tool 0 in zslice.
        if (p.peek() == ',') {
            p.pos += 1;
            _ = try p.expression(false);
        }
        return v;
    }

    fn assign(p: *Parser, name: []const u8, index: ?f64, v: Value) Error!void {
        const vars = &p.r.vars;
        // A global variable of the print, if no local one has the name.
        const global: ?*Globals = if (vars.get(name) == null) (if (p.r.ctx.globals) |g| (if (g.map.get(name) != null) g else null) else null) else null;
        const i = index orelse {
            if (global) |g| return g.put(name, v);
            return vars.put(p.r.arena, name, v);
        };
        if (i < 0 or i > 64) return error.Syntax;
        const k: usize = @intFromFloat(i);
        const current: ?Value = if (global) |g| g.map.get(name) else vars.get(name);
        const old: []const Value = if (current) |o| (if (o == .list) o.list else &.{}) else &.{};
        const items = try p.r.arena.alloc(Value, @max(old.len, k + 1));
        @memcpy(items[0..old.len], old);
        // A list of the slicer has a value for each extruder: the others
        // keep the value of the variable.
        const base: Value = if (old.len == 0) (p.r.variable(name, 0) catch Value{ .num = 0 }) else Value{ .num = 0 };
        for (items[old.len..]) |*x| x.* = base;
        items[k] = v;
        if (global) |g| return g.put(name, .{ .list = items });
        try vars.put(p.r.arena, name, .{ .list = items });
    }

    /// An expression. With `run` false, the parser only reads it (a
    /// branch that is not taken), and its value is nil.
    fn expression(p: *Parser, run: bool) Error!Value {
        try p.enter();
        defer p.depth -= 1;
        const c = try p.orExpr(run);
        if (p.peek() == '?') {
            p.pos += 1;
            const go = run and c.truthy();
            const a = try p.expression(go);
            try p.expect(":");
            const b = try p.expression(run and !go);
            return if (!run) .nil else if (go) a else b;
        }
        return c;
    }

    fn orExpr(p: *Parser, run: bool) Error!Value {
        var a = try p.andExpr(run);
        while (p.eat("||") or p.eatWord("or")) {
            const go = run and !a.truthy();
            const b = try p.andExpr(go);
            if (run) a = .{ .boolean = a.truthy() or b.truthy() };
        }
        return a;
    }

    fn andExpr(p: *Parser, run: bool) Error!Value {
        var a = try p.notExpr(run);
        while (p.eat("&&") or p.eatWord("and")) {
            const go = run and a.truthy();
            const b = try p.notExpr(go);
            if (run) a = .{ .boolean = a.truthy() and b.truthy() };
        }
        return a;
    }

    fn notExpr(p: *Parser, run: bool) Error!Value {
        try p.enter();
        defer p.depth -= 1;
        if (p.eatWord("not") or (p.peek() == '!' and !std.mem.startsWith(u8, p.src[p.pos..], "!=") and !std.mem.startsWith(u8, p.src[p.pos..], "!~"))) {
            if (p.src[p.pos] == '!') p.pos += 1;
            const v = try p.notExpr(run);
            return if (run) .{ .boolean = !v.truthy() } else .nil;
        }
        return p.compare(run);
    }

    fn compare(p: *Parser, run: bool) Error!Value {
        const a = try p.sum(run);
        const ops = [_][]const u8{ "==", "!=", "<>", "<=", ">=", "=~", "!~", "<", ">" };
        p.skipSpace();
        for (ops) |op| {
            if (!std.mem.startsWith(u8, p.src[p.pos..], op)) continue;
            p.pos += op.len;
            if (std.mem.eql(u8, op, "=~") or std.mem.eql(u8, op, "!~")) {
                const re = try p.regexLiteral();
                if (!run) return .nil;
                const t = try p.r.textOf(a);
                const hit = regexMatch(re, t);
                return .{ .boolean = if (op[0] == '=') hit else !hit };
            }
            const b = try p.sum(run);
            if (!run) return .nil;
            return .{ .boolean = try cmp(p.r, op, a, b) };
        }
        return a;
    }

    fn regexLiteral(p: *Parser) Error![]const u8 {
        if (p.peek() != '/') return error.Syntax;
        p.pos += 1;
        const start = p.pos;
        while (p.pos < p.src.len and p.src[p.pos] != '/') : (p.pos += 1) {
            if (p.src[p.pos] == '\\') p.pos += 1;
        }
        if (p.pos >= p.src.len) return error.Syntax;
        const re = p.src[start..p.pos];
        p.pos += 1;
        return re;
    }

    fn sum(p: *Parser, run: bool) Error!Value {
        var a = try p.product(run);
        while (true) {
            const c = p.peek();
            if (c != '+' and c != '-') break;
            p.pos += 1;
            const b = try p.product(run);
            if (!run) continue;
            if (c == '+' and (a == .text or b == .text)) {
                a = .{ .text = try std.mem.concat(p.r.arena, u8, &.{ try p.r.textOf(a), try p.r.textOf(b) }) };
            } else {
                const x = try asNum(a);
                const y = try asNum(b);
                a = num(if (c == '+') x + y else x - y);
            }
        }
        return a;
    }

    fn product(p: *Parser, run: bool) Error!Value {
        var a = try p.unary(run);
        while (true) {
            const c = p.peek();
            if (c != '*' and c != '/' and c != '%') break;
            p.pos += 1;
            const b = try p.unary(run);
            if (!run) continue;
            const x = try asNum(a);
            const y = try asNum(b);
            a = num(switch (c) {
                '*' => x * y,
                '/' => if (y == 0) 0 else x / y,
                else => if (y == 0) 0 else @rem(x, y),
            });
        }
        return a;
    }

    fn unary(p: *Parser, run: bool) Error!Value {
        try p.enter();
        defer p.depth -= 1;
        const c = p.peek();
        if (c == '-' or c == '+') {
            p.pos += 1;
            const v = try p.unary(run);
            if (!run) return .nil;
            const x = try asNum(v);
            return num(if (c == '-') -x else x);
        }
        if (c == '!' and !std.mem.startsWith(u8, p.src[p.pos..], "!=")) {
            p.pos += 1;
            const v = try p.unary(run);
            return if (run) .{ .boolean = !v.truthy() } else .nil;
        }
        return p.postfix(run);
    }

    fn postfix(p: *Parser, run: bool) Error!Value {
        var v = try p.primary(run);
        while (p.peek() == '[') {
            p.pos += 1;
            const i = try p.expression(run);
            try p.expect("]");
            if (run) v = pick(v, asNum(i) catch return error.Syntax);
        }
        return v;
    }

    fn primary(p: *Parser, run: bool) Error!Value {
        const c = p.peek();
        if (c == 0) return error.Syntax;
        if (std.ascii.isDigit(c) or c == '.') return p.number();
        if (c == '"') return p.string();
        if (c == '(') {
            p.pos += 1;
            const first = try p.expression(run);
            if (p.peek() == ',') {
                // A list: (0, 0, 0).
                var items: std.ArrayList(Value) = .empty;
                try items.append(p.r.arena, first);
                while (p.eat(",")) try items.append(p.r.arena, try p.expression(run));
                try p.expect(")");
                return .{ .list = items.items };
            }
            try p.expect(")");
            return first;
        }
        const name = p.word();
        if (name.len == 0) return error.Syntax;
        if (eqlAny(name, &.{ "true", "True" })) return .{ .boolean = true };
        if (eqlAny(name, &.{ "false", "False" })) return .{ .boolean = false };
        if (p.pos < p.src.len and p.src[p.pos] == '.' and p.pos + 1 < p.src.len and std.ascii.isAlphabetic(p.src[p.pos + 1])) {
            return error.ObjectModel;
        }
        if (p.peek() == '(') {
            p.pos += 1;
            var args: std.ArrayList(Value) = .empty;
            if (p.peek() != ')') {
                // is_nil and one_of read their first argument with no
                // error for a missing value.
                try args.append(p.r.arena, try p.expression(run));
                while (p.eat(",")) try args.append(p.r.arena, try p.expression(run));
            }
            try p.expect(")");
            if (!run) return .nil;
            return call(p.r, name, args.items);
        }
        if (!run) {
            // A name in a branch that is not taken: read its index too.
            return .nil;
        }
        // A variable with an index: the index goes to the lookup, so the
        // old forms (name_0) and the points work the same way.
        if (p.peek() == '[') {
            p.pos += 1;
            const i = try p.expression(run);
            try p.expect("]");
            const v = try p.r.variable(name, asNum(i) catch return error.Syntax);
            return if (v == .list) pick(v, asNum(i) catch 0) else v;
        }
        return p.r.variable(name, null);
    }

    fn number(p: *Parser) Error!Value {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) {
            const ch = p.src[p.pos];
            if (std.ascii.isDigit(ch) or ch == '.') continue;
            if ((ch == 'e' or ch == 'E') and p.pos + 1 < p.src.len and (std.ascii.isDigit(p.src[p.pos + 1]) or p.src[p.pos + 1] == '-')) {
                p.pos += 1;
                continue;
            }
            break;
        }
        return num(std.fmt.parseFloat(f64, p.src[start..p.pos]) catch return error.Syntax);
    }

    fn string(p: *Parser) Error!Value {
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (p.pos < p.src.len and p.src[p.pos] != '"') : (p.pos += 1) {
            var ch = p.src[p.pos];
            if (ch == '\\' and p.pos + 1 < p.src.len) {
                p.pos += 1;
                ch = switch (p.src[p.pos]) {
                    'n' => '\n',
                    't' => '\t',
                    else => p.src[p.pos],
                };
            }
            try out.append(p.r.arena, ch);
        }
        if (p.pos >= p.src.len) return error.Syntax;
        p.pos += 1;
        return .{ .text = out.items };
    }
};

fn asNum(v: Value) Error!f64 {
    return switch (v) {
        .num => |n| n,
        .boolean => |b| if (b) 1 else 0,
        .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " %")) catch error.Syntax,
        .nil => error.NoValue,
        .list => |items| if (items.len > 0) asNum(items[0]) else error.NoValue,
    };
}

fn cmp(r: *Renderer, op: []const u8, a: Value, b: Value) Error!bool {
    if (a == .nil or b == .nil) return error.NoValue;
    const order: std.math.Order = if (a == .text or b == .text) blk: {
        const x = try r.textOf(a);
        const y = try r.textOf(b);
        break :blk std.mem.order(u8, x, y);
    } else std.math.order(try asNum(a), try asNum(b));
    if (std.mem.eql(u8, op, "==")) return order == .eq;
    if (std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<>")) return order != .eq;
    if (std.mem.eql(u8, op, "<")) return order == .lt;
    if (std.mem.eql(u8, op, "<=")) return order != .gt;
    if (std.mem.eql(u8, op, ">")) return order == .gt;
    return order != .lt; // >=
}

const functions = [_][]const u8{ "is_nil", "min", "max", "one_of", "empty", "size", "digits", "zdigits", "int", "round", "floor", "ceil", "abs", "sqrt", "float" };

fn call(r: *Renderer, name: []const u8, args: []const Value) Error!Value {
    if (!eqlAny(name, &functions)) {
        r.last_missing = name;
        return error.Unknown;
    }
    if (std.mem.eql(u8, name, "is_nil")) {
        if (args.len != 1) return error.Syntax;
        return .{ .boolean = args[0] == .nil };
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len == 0) return error.Syntax;
        var v = try asNum(args[0]);
        for (args[1..]) |a| {
            const x = try asNum(a);
            v = if (name[1] == 'i') @min(v, x) else @max(v, x);
        }
        return num(v);
    }
    if (std.mem.eql(u8, name, "one_of")) {
        if (args.len < 1) return error.Syntax;
        const t = try r.textOf(args[0]);
        for (args[1..]) |a| if (std.mem.eql(u8, t, try r.textOf(a))) return .{ .boolean = true };
        return .{ .boolean = false };
    }
    if (std.mem.eql(u8, name, "empty")) {
        if (args.len != 1) return error.Syntax;
        return .{ .boolean = !args[0].truthy() };
    }
    if (std.mem.eql(u8, name, "size")) {
        if (args.len != 1) return error.Syntax;
        return num(@floatFromInt(switch (args[0]) {
            .list => |items| items.len,
            .text => |t| t.len,
            else => 1,
        }));
    }
    if (std.mem.eql(u8, name, "digits") or std.mem.eql(u8, name, "zdigits")) {
        // digits(x, n, d): x with n digits before the point (spaces, or
        // zeros for zdigits) and d decimals.
        if (args.len < 2) return error.Syntax;
        const x = try asNum(args[0]);
        const n: usize = @intFromFloat(std.math.clamp(try asNum(args[1]), 0, 20));
        const d: usize = if (args.len > 2) @intFromFloat(std.math.clamp(try asNum(args[2]), 0, 10)) else 0;
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ x, d }) catch return error.Syntax;
        const int_len = if (std.mem.indexOfScalar(u8, t, '.')) |k| k else t.len;
        const pad = n -| int_len;
        const out = try r.arena.alloc(u8, pad + t.len);
        @memset(out[0..pad], if (name[0] == 'z') '0' else ' ');
        @memcpy(out[pad..], t);
        return .{ .text = out };
    }
    if (args.len != 1 and !(std.mem.eql(u8, name, "round") and args.len == 2)) return error.Syntax;
    const x = try asNum(args[0]);
    if (std.mem.eql(u8, name, "int")) return num(@trunc(x));
    if (std.mem.eql(u8, name, "round")) {
        if (args.len == 2) {
            const k = std.math.pow(f64, 10, std.math.clamp(try asNum(args[1]), 0, 10));
            return num(@round(x * k) / k);
        }
        return num(@round(x));
    }
    if (std.mem.eql(u8, name, "floor")) return num(@floor(x));
    if (std.mem.eql(u8, name, "ceil")) return num(@ceil(x));
    if (std.mem.eql(u8, name, "abs")) return num(@abs(x));
    if (std.mem.eql(u8, name, "sqrt")) return num(@sqrt(@max(0, x)));
    return num(x); // float
}

fn textOfImpl(a: Allocator, v: Value) Error![]const u8 {
    return switch (v) {
        .nil => error.NoValue,
        .boolean => |b| if (b) "true" else "false",
        .num => |n| try numText(a, n),
        .text => |t| t,
        .list => |items| if (items.len > 0) textOfImpl(a, items[0]) else "",
    };
}

// ---- Regular expressions ----

/// True if the whole of `text` matches the regular expression `re`. The
/// expressions of the profiles use: letters, '.', '*', '+', '?', groups
/// with '|', classes ([A-Z], [^0-9]), '^', '$', and a backslash before a mark.
/// The match is a backtracking walk over the expression. A step budget
/// stops a walk that does not end.
pub fn regexMatch(re: []const u8, text: []const u8) bool {
    var budget: usize = 100_000;
    var m: Matcher = .{ .re = re, .text = text, .budget = &budget };
    return m.alt(0, re.len, 0, null);
}

const Matcher = struct {
    re: []const u8,
    text: []const u8,
    budget: *usize,

    /// What must match after a group: re[from..to], then `next`. With
    /// `star`, a '+' on the first atom acts as '*' (the group matched
    /// once already).
    const Cont = struct { from: usize, to: usize, star: bool = false, next: ?*const Cont };

    fn classEnd(m: *const Matcher, open: usize) usize {
        var k = open + 1;
        if (k < m.re.len and m.re[k] == '^') k += 1;
        if (k < m.re.len and m.re[k] == ']') k += 1;
        while (k < m.re.len and m.re[k] != ']') : (k += 1) {
            if (m.re[k] == '\\') k += 1;
        }
        return @min(k, m.re.len -| 1);
    }

    /// The ')' of the group that opens at `open`.
    fn groupEnd(m: *const Matcher, open: usize) usize {
        var depth: usize = 0;
        var k = open;
        while (k < m.re.len) : (k += 1) {
            switch (m.re[k]) {
                '\\' => k += 1,
                '[' => k = m.classEnd(k),
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return k;
                },
                else => {},
            }
        }
        return m.re.len;
    }

    /// One past the atom at `i`.
    fn atomEnd(m: *const Matcher, i: usize) usize {
        return switch (m.re[i]) {
            '\\' => @min(i + 2, m.re.len),
            '[' => m.classEnd(i) + 1,
            '(' => @min(m.groupEnd(i) + 1, m.re.len),
            else => i + 1,
        };
    }

    /// The alternatives ('|') of re[from..to] at `pos`, then `cont`.
    fn alt(m: *Matcher, from: usize, to: usize, pos: usize, cont: ?*const Cont) bool {
        var start = from;
        var k = from;
        while (k <= to) {
            if (k == to or m.re[k] == '|') {
                if (m.seq(start, k, pos, cont, false)) return true;
                start = k + 1;
                k += 1;
                continue;
            }
            k = m.atomEnd(k);
        }
        return false;
    }

    /// The sequence re[from..to] (no '|' at its level) at `pos`.
    fn seq(m: *Matcher, from: usize, to: usize, pos: usize, cont: ?*const Cont, star: bool) bool {
        if (m.budget.* == 0) return false;
        m.budget.* -= 1;
        if (from >= to) {
            const c = cont orelse return pos == m.text.len;
            return m.seq(c.from, c.to, pos, c.next, c.star);
        }
        const c = m.re[from];
        if (c == '^') return pos == 0 and m.seq(from + 1, to, pos, cont, false);
        if (c == '$') return pos == m.text.len and m.seq(from + 1, to, pos, cont, false);
        const end = @min(m.atomEnd(from), to);
        var q: u8 = if (end < to and std.mem.indexOfScalar(u8, "*+?", m.re[end]) != null) m.re[end] else 0;
        const rest = if (q != 0) end + 1 else end;
        if (star and q == '+') q = '*';
        if (c == '(') {
            const after: Cont = .{ .from = rest, .to = to, .next = cont };
            const inner_to = end - 1;
            switch (q) {
                0 => return m.alt(from + 1, inner_to, pos, &after),
                '?' => return m.alt(from + 1, inner_to, pos, &after) or m.seq(rest, to, pos, cont, false),
                else => {
                    const again: Cont = .{ .from = from, .to = to, .star = true, .next = cont };
                    if (m.alt(from + 1, inner_to, pos, &again)) return true;
                    return q == '*' and m.seq(rest, to, pos, cont, false);
                },
            }
        }
        const min: usize = if (q == '*' or q == '?') 0 else 1;
        const max: usize = if (q == '*' or q == '+') m.text.len - pos else 1;
        var n: usize = 0;
        while (n < max and pos + n < m.text.len and m.hit(from, m.text[pos + n])) n += 1;
        if (n < min) return false;
        var k = n;
        while (true) {
            if (m.seq(rest, to, pos + k, cont, false)) return true;
            if (k == min) return false;
            k -= 1;
        }
    }

    fn hit(m: *const Matcher, a: usize, ch: u8) bool {
        const c = m.re[a];
        return switch (c) {
            '.' => true,
            '\\' => a + 1 < m.re.len and m.re[a + 1] == ch,
            '[' => m.classHit(a, ch),
            else => c == ch,
        };
    }

    fn classHit(m: *const Matcher, open: usize, ch: u8) bool {
        const close = m.classEnd(open);
        var k = open + 1;
        const neg = k < close and m.re[k] == '^';
        if (neg) k += 1;
        var found = false;
        while (k < close) {
            var lo = m.re[k];
            if (lo == '\\' and k + 1 < close) {
                k += 1;
                lo = m.re[k];
            }
            if (k + 2 < close and m.re[k + 1] == '-') {
                if (ch >= lo and ch <= m.re[k + 2]) found = true;
                k += 3;
            } else {
                if (ch == lo) found = true;
                k += 1;
            }
        }
        return found != neg;
    }
};

// ---- The interface ----

/// Writes `text` with the values of its variables (see the header
/// comment). The memory of `gpa` is free again at the return.
pub fn render(gpa: Allocator, w: *Writer, text: []const u8, ctx: *const Context) (Writer.Error || Allocator.Error)!Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r: Renderer = .{ .arena = arena.allocator(), .ctx = ctx, .w = w };
    r.run(text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
        // The errors of the language stay in the line (see `unresolved`).
        else => {},
    };
    return r.result;
}

// ---- Tests ----

const testing = std.testing;

/// Renders `text` with the default settings and a first layer nozzle of
/// 207, a nozzle of 203, and a bed of 58.
fn testRender(text: []const u8, ctx_in: Context) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var ctx = ctx_in;
    _ = try render(testing.allocator, &out.writer, text, &ctx);
    return out.toOwnedSlice();
}

test "gcode vars: two nozzles of the X2D: the extruder of each filament, and hotend -1" {
    var r = try testResolved();
    r.settings.machine.model = "bambu-lab-x2d";
    r.settings.machine.nozzles = 2;
    var ext = r.settings.filament;
    ext.nozzle = 1;
    const slots = [_]settings_mod.Filament{ r.settings.filament, ext, r.settings.filament };
    const text = "M[filament_map[0]] M{filament_map[1]} M{filament_map[2]} N[next_nozzle_id] C[current_nozzle_id] T[next_filament_id] H[next_hotend] B[current_hotend] E{num_extruders} U{is_extruder_used[1]} F{first_filaments[1]}";
    const out = try testRender(text, .{ .r = &r, .slots = &slots, .tool = 0, .change = .{ .next = 1 } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("M1 M2 M1 N1 C0 T1 H-1 B-1 E2 U1 F1", out);
    // One nozzle: every filament on extruder 1, and nozzle 0.
    r.settings.machine.nozzles = 1;
    const one = try testRender(text, .{ .r = &r, .slots = &slots, .tool = 0, .change = .{ .next = 1 } });
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("M1 M1 M1 N0 C0 T1 H-1 B-1 E1 U0 F-1", one);
}

/// The first filament of each nozzle, from a list of the first nozzles.
fn firstOf(list: anytype) [settings_mod.max_nozzles]?u32 {
    var out: [settings_mod.max_nozzles]?u32 = .{null} ** settings_mod.max_nozzles;
    inline for (list, 0..) |v, k| out[k] = v;
    return out;
}

test "gcode vars: a tool changer: the extruder of each variable is a nozzle" {
    var r = try (settings_mod.Settings{}).resolve();
    r.settings.machine.nozzles = 5;
    r.settings.machine.tool_numbers = .nozzle;
    var a = r.settings.filament;
    a.nozzle_temp = 215;
    var b = a;
    b.nozzle = 3;
    b.nozzle_temp = 240;
    b.material = "PETG";
    var c = a;
    c.nozzle = 1;
    c.nozzle_temp = 230;
    const slots = [_]settings_mod.Filament{ a, b, c };
    const text = "P{previous_extruder} N{next_extruder} I{initial_tool} T{temperature[next_extruder]} F{filament_type[3]} U{is_extruder_used[3]}{is_extruder_used[2]} E{num_extruders} M{filament_map[1]} S{standby_temperature_delta}";
    const out = try testRender(text, .{ .r = &r, .slots = &slots, .tool = 0, .layer_index = 2, .first_of_nozzles = firstOf(.{ 0, 2, null, 1 }), .change = .{ .next = 1 } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("P0 N3 I0 T240 FPETG U10 E5 M4 S-5", out);
}

test "gcode vars: the tool change G-code of the Prusa XL renders" {
    var r = try (settings_mod.Settings{}).resolve();
    r.settings.machine.nozzles = 5;
    r.settings.machine.tool_numbers = .nozzle;
    var b = r.settings.filament;
    b.nozzle = 3;
    b.nozzle_temp = 240;
    const slots = [_]settings_mod.Filament{ r.settings.filament, b };
    const text = "; Change Tool[previous_extruder] -> Tool[next_extruder] (layer [layer_num])\n{\nlocal max_speed_toolchange = 350.0;\nlocal wait_for_extruder_temp = true;\nposition[2] = position[2] + 2.0;\n\nlocal speed_toolchange = max_speed_toolchange;\nif travel_speed < max_speed_toolchange then\n      speed_toolchange = travel_speed;\nendif\n\"G1 F\" + (speed_toolchange * 60) + \"\n\";\nif wait_for_extruder_temp and not((layer_num < 0) and (next_extruder == initial_tool)) then\n      \"P0 S1 L2 D0\n\";\n      \"; \" + layer_num + \"\n\";\n      if layer_num == 0 then\n            \"M109 S\" + first_layer_temperature[next_extruder] + \" T\" + next_extruder + \"\n\";\n      else\n            \"M109 S\" + temperature[next_extruder] + \" T\" + next_extruder + \"\n\";\n      endif\nendif\n\"T\" + next_extruder + \" S1 L0 D0\n\";\n}";
    const out = try testRender(text, .{ .r = &r, .slots = &slots, .tool = 0, .layer_index = 3, .layer_z = 0.8, .first_of_nozzles = firstOf(.{ 0, null, null, 1 }), .change = .{ .next = 1 } });
    defer testing.allocator.free(out);
    errdefer std.debug.print("{s}\n", .{out});
    try testing.expect(std.mem.indexOf(u8, out, "zslice: no value") == null);
    try testing.expect(std.mem.indexOf(u8, out, "; Change Tool0 -> Tool3 (layer 3)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "P0 S1 L2 D0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "M109 S240 T3\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "T3 S1 L0 D0\n") != null);
}

test "gcode vars: a global variable of the start G-code lives on in the change G-code" {
    var g: Globals = .init(testing.allocator);
    defer g.deinit();
    const r = try (settings_mod.Settings{}).resolve();
    const start = try testRender("{global tool_init = (0,0,0)}{global n = 8}", .{ .r = &r, .globals = &g });
    defer testing.allocator.free(start);
    const change = try testRender("{tool_init[1] = 1}T{n} {tool_init[1]} {tool_init[2]}", .{ .r = &r, .globals = &g });
    defer testing.allocator.free(change);
    try testing.expectEqualStrings("T8 1 0", change);
    // With no globals, a global lives in one text only.
    const alone = try testRender("{global n = 8}{n}", .{ .r = &r });
    defer testing.allocator.free(alone);
    try testing.expectEqualStrings("8", alone);
}

test "gcode vars: the first filament of a nozzle is one that the print uses" {
    var r = try testResolved();
    r.settings.machine.model = "bambu-lab-x2d";
    r.settings.machine.nozzles = 2;
    // Four filaments of the plate, all on the main nozzle, and a print
    // of filaments 3 and 4: the idle nozzle has no filament (-1, which
    // the X2D start G-code turns into 0), not filament 5 or an unused one.
    const f = r.settings.filament;
    const slots = [_]settings_mod.Filament{ f, f, f, f, f };
    const text = "L{first_filaments[0]} L{first_filaments[1]} N{first_non_support_filaments[1]}";
    const out = try testRender(text, .{ .r = &r, .slots = &slots, .tool = 3, .layer_index = 4, .first_of_nozzles = firstOf(.{ 3, null }) });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("L3 L-1 N-1", out);
    // The start G-code: the filament that it loads comes first on its
    // nozzle.
    const start = try testRender(text, .{ .r = &r, .slots = &slots, .tool = 3, .first_of_nozzles = firstOf(.{ 3, null }) });
    defer testing.allocator.free(start);
    try testing.expectEqualStrings("L3 L-1 N-1", start);
}

test "gcode vars: the change G-code of the Bambu Lab X2D" {
    const r = try testResolved();
    var red = r.settings.filament;
    red.color = "#ff0000";
    red.nozzle_temp = 220;
    const slots = [_]settings_mod.Filament{ r.settings.filament, red };
    const text = @import("printers.zig").changeGcode("bambu-lab-x2d").?;
    const out = try testRender(text, .{ .r = &r, .layer_count = 100, .max_layer_z = 4.2, .layer_z = 4.2, .slots = &slots, .tool = 0, .layer_index = 20, .change = .{ .next = 1, .flush_mm = 50, .count = 3, .old_temp = 203, .new_temp = 220, .after = .{ 100, 120, 4.2 } } });
    defer testing.allocator.free(out);
    // The AMS takes the new filament (M620 S1), the tool changes, and the
    // AMS ends the change (M621 S1).
    try testing.expect(std.mem.indexOf(u8, out, "M620 S1A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\nT1 H0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "M621 S1A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "L50 ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "G1 Z7.2 F1200") != null);
}

fn testResolved() !Resolved {
    var s: settings_mod.Settings = .{};
    s.filament.first_layer_nozzle_temp = 207;
    s.filament.nozzle_temp = 203;
    s.filament.bed_temp = 58;
    s.machine.bed_size_x = 250;
    s.machine.bed_size_y = 210;
    s.machine.max_height = 220;
    s.engine.job_name = "cube.stl";
    return s.resolve();
}

fn expectRender(want: []const u8, text: []const u8) !void {
    const r = try testResolved();
    const got = try testRender(text, .{ .r = &r, .layer_count = 10, .max_layer_z = 2.1 });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "zslice names" {
    try expectRender("M140 S58\nM104 S207\nM109 S207 ; wait", "M140 S{bed_temp}\nM104 S{first_layer_nozzle_temp}\nM109 S{first_layer_nozzle_temp} ; wait");
    try expectRender("; cube.stl at 0.2 mm", "; {job_name} at {layer_height} mm");
}

test "Cura names" {
    try expectRender("M190 S58\nM109 S207\nM104 T0 S203", "M190 S{material_bed_temperature_layer_0}\nM109 S{material_print_temperature_layer_0, 0}\nM104 T0 S{material_print_temperature, initial_extruder_nr}");
    try expectRender("G1 X125 Y105", "G1 X{machine_width / 2} Y{machine_depth / 2}");
    try expectRender("M117 big\n", "{if material_bed_temperature > 50}\nM117 big\n{elif material_bed_temperature > 20}\nM117 small\n{else}\nM117 cold\n{endif}\n");
}

test "PrusaSlicer and OrcaSlicer names" {
    try expectRender("M190 S58 M109 S207", "M190 S[first_layer_bed_temperature] M109 S[first_layer_temperature[0]]");
    try expectRender("M109 S207 M190 S58", "M109 S[nozzle_temperature_initial_layer] M190 S[bed_temperature_initial_layer_single]");
    try expectRender("M104 S207 M140 S58", "M104 S{first_layer_temperature[initial_tool]} M140 S{hot_plate_temp_initial_layer[initial_extruder]}");
    try expectRender("G1 X250 Y168", "G1 X{print_bed_max[0]} Y{print_bed_max[1]*0.8}");
    try expectRender("G1 Z4.1", "G1 Z{z_offset+min(max_layer_z+2, max_print_height)}");
    try expectRender("G1 X0 Y0", "G1 X[first_layer_print_min_0] Y[first_layer_print_min_1]");
    try expectRender("M104 S150", "M104 S{is_nil(idle_temperature[0]) ? 150 : idle_temperature[0]}");
    try expectRender("M109 S222", "M109 S{max(222, min(290, nozzle_temperature_initial_layer[0] + 5))}");
}

test "conditions and statements" {
    try expectRender("G1 Z22.1\n", "{if max_layer_z < max_print_height-10}G1 Z{max_layer_z+20}\n{endif}");
    try expectRender("PLA\n", "{if filament_type[0] == \"PETG\"}PETG\n{elsif filament_type[0] == \"PLA\"}PLA\n{else}other\n{endif}");
    try expectRender("170", "{((filament_notes[0]=~/.*MBL160.*/) ? 160 : (filament_type[0]=~/.*PET.*/) ? 175 : 170)}");
    try expectRender("x=12 y=24", "{local a = 12}x={a} y={a * 2}");
    try expectRender("G1 Z4.1", "{\nlocal move_z = max_print_height;\nif max_layer_z < (max_print_height - 2) then\n  move_z = min(max_layer_z + 2, max_print_height);\nendif\n}G1 Z{move_z}");
    try expectRender("T0\n", "{if is_extruder_used[0]}T0\n{endif}{if is_extruder_used[1]}T1\n{endif}");
    try expectRender("0", "{e_retracted[1] = 2}{e_retracted[0]}");
    try expectRender("1", "{\"\" + ((filament_type[0]==\"FLEX\") ? 2 : 1)}");
}

test "a variable with no value" {
    // A command line becomes a comment; the text of a comment stays.
    try expectRender("; zslice: no value for printer_model: M862.3 P \"[printer_model]\"\nG28", "M862.3 P \"[printer_model]\"\nG28");
    try expectRender("G28 ; {date} [weird_name]", "G28 ; {date} [weird_name]");
    try expectRender("; zslice: no value for unknown_thing: M104 S{unknown_thing}", "M104 S{unknown_thing}");
    // A condition with no value is false.
    try expectRender("G29.1 Z-0.04\nG28", "{if curr_bed_type==\"Textured PEI Plate\"}\nG29.1 Z-0.04\n{endif}\nG28");
    // Text that is no variable stays.
    try expectRender("M117 [Printing] ; {not a var", "M117 [Printing] ; {not a var");
    // A broken source: a '{' with no '}'.
    try expectRender("; zslice: a { with no }: M190 S{material_bed_temper109 S207 ;", "M190 S{material_bed_temper109 S{first_layer_nozzle_temp} ;");
}

test "the object model of RepRapFirmware stays" {
    const r = try testResolved();
    const got = try testRender("G1 X{move.axes[0].min+2} Z{layer_height}", .{ .r = &r, .object_model = true });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("G1 X{move.axes[0].min+2} Z0.2", got);
}

test "the temperatures that a text sets" {
    const r = try testResolved();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var res = try render(testing.allocator, &out.writer, "M104 T1 S100\nM109 S{first_layer_temperature[0]}\nM190 S{bed_temperature[0]}", &.{ .r = &r });
    try testing.expectEqual(@as(?f64, 207), res.nozzle);
    try testing.expectEqual(@as(?f64, 58), res.bed);
    res = try render(testing.allocator, &out.writer, "PRINT_START EXTRUDER=[first_layer_temperature] BED=[bed_temperature]\nM117 [nozzle_temperature]", &.{ .r = &r });
    try testing.expect(res.macro_nozzle and res.macro_bed);
    try testing.expectEqual(@as(?f64, null), res.nozzle);
    res = try render(testing.allocator, &out.writer, "G28\nM117 [first_layer_temperature]", &.{ .r = &r });
    try testing.expect(!res.macro_nozzle and res.nozzle == null);
}

test "regular expressions" {
    try testing.expect(regexMatch(".*MBL160.*", "PLA MBL160 x"));
    try testing.expect(!regexMatch(".*MBL160.*", "PLA"));
    try testing.expect(regexMatch(".*(SPEED @MK3|DRAFT @MK3).*", "0.2mm SPEED @MK3"));
    try testing.expect(regexMatch("(ABS)?(ABST)?(PC)?(PCABS)?", "PCABS"));
    try testing.expect(regexMatch("(ABS)?(ABST)?(PC)?(PCABS)?", ""));
    try testing.expect(!regexMatch("(ABS)?(ABST)?(PC)?(PCABS)?", "PLA"));
    try testing.expect(regexMatch("PLA|PVA|BVOH", "PVA"));
    try testing.expect(regexMatch("[A-Z]+[0-9]*", "PA12"));
    try testing.expect(!regexMatch("[^0-9]+", "A1"));
    try testing.expect(regexMatch("(ab)+c", "ababc"));
    try testing.expect(!regexMatch("(ab)+c", "c"));
    try testing.expect(regexMatch("a\\.b", "a.b"));
    try testing.expect(!regexMatch("a\\.b", "axb"));
}

test "each name of the map has a value" {
    const r = try testResolved();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var discard: Writer.Discarding = .init(&.{});
    var rd: Renderer = .{ .arena = arena.allocator(), .ctx = &.{ .r = &r }, .w = &discard.writer };
    for (names.keys(), names.values()) |name, en| {
        const v = try rd.variable(name, if (en.list) 0 else null);
        // A temperature is a material value or 0: never a fixed number.
        switch (en.key) {
            .nozzle_temp => try testing.expectEqual(@as(f64, 203), v.num),
            .first_layer_nozzle_temp => try testing.expectEqual(@as(f64, 207), v.num),
            .bed_temp => try testing.expectEqual(@as(f64, 58), v.num),
            .chamber_temp => try testing.expectEqual(@as(f64, 0), v.num),
            .no_value => try testing.expect(v == .nil),
            else => {},
        }
    }
}

test "a text value cannot add a line to the G-code" {
    var s: settings_mod.Settings = .{};
    s.filament.name = "PLA\nM104 S350";
    s.machine.name = "TAZ\rG28 X";
    s.engine.job_name = "part\r\nM140 S150.stl";
    const r = try s.resolve();
    const got = try testRender("M117 {filament_name}\nM117 [printer_model] {machine_name}\nM117 {job_name}", .{ .r = &r });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOfScalar(u8, got, '\r') == null);
    var lines = std.mem.splitScalar(u8, got, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        // Each line is an M117 (or a comment of a line with no value).
        try testing.expect(std.mem.startsWith(u8, line, "M117 ") or std.mem.startsWith(u8, line, "; zslice: "));
    }
    try testing.expect(n >= 3);
}

test "an expression that nests too deep becomes a comment" {
    const n = 100_000;
    const text = try testing.allocator.alloc(u8, 2 * n + 9);
    defer testing.allocator.free(text);
    @memcpy(text[0..6], "G1 Z{(");
    @memset(text[6 .. n + 6], '(');
    text[n + 6] = '1';
    @memset(text[n + 7 .. 2 * n + 7], ')');
    @memcpy(text[2 * n + 7 ..], ")}");
    const r = try testResolved();
    const got = try testRender(text, .{ .r = &r });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "; zslice: "));
    try expectRender("G1 Z5", "G1 Z{-(-(1 + 2) - 2)}");
}

test "numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { f64, []const u8 }{ .{ 215, "215" }, .{ 0.2, "0.2" }, .{ -0.00001, "0" }, .{ 1.23456, "1.2346" }, .{ -12.5, "-12.5" } };
    for (cases) |c| try testing.expectEqualStrings(c[1], try numText(arena.allocator(), c[0]));
}

test "each G-code of the printer library renders with no variable left" {
    if (printers.builtin_data.len == 0) return error.SkipZigTest;
    const profile = @import("profile.zig");
    const lib = try printers.Library.parse(testing.allocator, printers.builtin_data);
    defer lib.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (lib.models, 0..) |m, i| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var text: Writer.Allocating = .init(a);
        try lib.profileText(i, 0, &text.writer);
        var s: settings_mod.Settings = .{};
        s.filament.first_layer_nozzle_temp = 207;
        s.filament.nozzle_temp = 203;
        s.filament.bed_temp = 58;
        var diag: profile.Diagnostic = .{};
        try profile.apply(a, &s, .machine, m.id, text.written(), null, &diag);
        const r = try s.resolve();
        for ([_][]const u8{ s.machine.start_gcode, s.machine.end_gcode }, [_]Phase{ .start, .end }) |t, phase| {
            var out: Writer.Allocating = .init(a);
            const res = try render(a, &out.writer, t, &.{ .r = &r, .phase = phase, .layer_count = 10, .max_layer_z = 2, .object_model = m.flavor == .reprap });
            // The start G-code heats to a material value, or leaves it to
            // the emitter (null), or to a macro.
            if (phase == .start) if (res.nozzle) |n| try testing.expect(n >= 0);
            var lines = std.mem.splitScalar(u8, out.written(), '\n');
            while (lines.next()) |line| {
                const cmd = if (std.mem.indexOfScalar(u8, line, ';')) |c| line[0..c] else line;
                const left = std.mem.indexOfAny(u8, cmd, "{}") != null and !(m.flavor == .reprap and std.mem.indexOf(u8, cmd, ".") != null);
                if (left) {
                    std.debug.print("{s}: {s}\n", .{ m.id, line });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
