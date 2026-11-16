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

pub const InfillPattern = enum { lines, grid };
pub const ExtruderKind = enum { direct, bowden };

pub const Machine = struct {
    /// The name of the printer, for the G-code header.
    name: []const u8 = "generic",
    /// The size of the bed in X.
    bed_size_x: f64 = 220,
    /// The size of the bed in Y.
    bed_size_y: f64 = 220,
    /// The highest part that the printer can make.
    max_height: f64 = 250,
    /// The diameter of the nozzle hole. The default line width comes from it.
    nozzle_diameter: f64 = 0.4,
    /// The maximum speed of the print head in X and Y.
    max_speed: f64 = 150,
    /// The speed of travel moves (moves with no extrusion).
    travel_speed: f64 = 150,
    /// The speed of Z moves at each layer change.
    max_z_speed: f64 = 10,
    /// The extruder type. `direct`: the motor is on the print head. `bowden`: the motor pushes the filament through a long tube.
    extruder: ExtruderKind = .direct,
    /// The retraction length of this extruder. A bowden extruder needs more.
    retract_length: f64 = 0.8,
    /// The speed of the filament during a retraction.
    retract_speed: f64 = 40,
    /// The text before the print. {nozzle_temp}, {first_layer_nozzle_temp},
    /// and {bed_temp} are replaced with the filament values.
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
    /// The name of the filament, for the G-code header.
    name: []const u8 = "generic PLA",
    /// The diameter of the filament.
    diameter: f64 = 1.75,
    /// g/cm^3. For the filament weight in the statistics.
    density: f64 = 1.24,
    /// The nozzle temperature from the second layer.
    nozzle_temp: f64 = 210,
    /// The nozzle temperature on the first layer.
    first_layer_nozzle_temp: f64 = 215,
    /// The bed temperature.
    bed_temp: f64 = 60,
    /// The maximum plastic flow that the hot end melts with this filament.
    /// This limits the speed of wide and tall lines.
    max_flow: f64 = 12,
    /// A multiplier for all extrusion, to calibrate the flow.
    flow_ratio: f64 = 1.0,
    /// The part cooling fan speed, as a ratio.
    fan_speed: f64 = 1.0,
    /// The fan is off for this number of layers at the start.
    fan_off_layers: u32 = 1,
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

    /// The line width. 0 uses 1.1 x the nozzle diameter.
    line_width: f64 = 0,
    /// The line width on the first layer. 0 uses 1.25 x the nozzle diameter.
    first_layer_line_width: f64 = 0,

    // Walls
    /// The number of walls (loops) around the outline of each layer.
    wall_count: u32 = 2,

    // Top and bottom skin, as a thickness. The engine computes the number
    // of layers, so a change of the layer height keeps the strength.
    /// The thickness of solid skin under each top surface.
    top_thickness: f64 = 0.8,
    /// The thickness of solid skin above each bottom surface.
    bottom_thickness: f64 = 0.6,
    /// Skin lines go this far into the walls, as a fraction of the line
    /// width, so that the skin bonds to the walls.
    skin_overlap: f64 = 0.15,

    // Infill
    /// The fraction of the inside that the sparse infill fills, as a ratio. 0 makes the part hollow.
    infill_density: f64 = 0.2,
    /// The sparse infill pattern. `lines`: one direction on each layer, turned 90 degrees on the next layer. `grid`: two directions on each layer.
    infill_pattern: InfillPattern = .grid,
    /// The angle of the infill and skin lines, in degrees from the X axis.
    infill_angle: f64 = 45,
    /// Sparse infill lines go this far into the walls, as a fraction of the line width.
    infill_overlap: f64 = 0.2,

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

    /// Travel moves shorter than this do not retract.
    retract_min_travel: f64 = 1.5,
    /// Lift the nozzle by this distance during a travel move with a retraction. 0 turns it off.
    z_hop: f64 = 0,

    // Placement
    /// Move the part so that the center of its bounding box is at the
    /// center of the bed, and its bottom is at z = 0.
    auto_center: bool = true,
};

/// Options for the engine. They do not change the print.
pub const EngineOptions = struct {
    /// The largest change to the shape (mm) that the slicer makes when it
    /// removes points from the mesh outlines.
    resolution: f64 = 0.005,
    /// The largest gap (mm) that the slicer closes in a mesh with holes.
    gap_closing: f64 = 1.0,
    /// The number of threads. 0 uses one thread for each CPU.
    threads: u32 = 0,
};

pub const Settings = struct {
    machine: Machine = .{},
    filament: Filament = .{},
    project: Project = .{},
    engine: EngineOptions = .{},

    pub const SetError = error{ UnknownSetting, InvalidValue };

    /// Sets a field from a dotted name ("project.wall_count") and a text
    /// value. String values are not copied: the caller keeps them alive
    /// while the settings are in use.
    pub fn set(self: *Settings, name: []const u8, value: []const u8) SetError!void {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.UnknownSetting;
        const group = name[0..dot];
        const field = name[dot + 1 ..];
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
            m.nozzle_diameter, m.max_speed,          m.travel_speed, m.max_z_speed,
            f.diameter,        f.max_flow,           f.flow_ratio,   p.layer_height,
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
            f.fan_speed,         p.infill_density,   p.outer_wall_speed, p.inner_wall_speed,
            p.skin_speed,        p.infill_speed,     p.first_layer_speed,
        };
        for (ratios) |v| if (!(v >= 0 and v <= 1)) return error.InvalidValue;
        if (p.outer_wall_speed == 0 or p.inner_wall_speed == 0 or p.skin_speed == 0 or p.infill_speed == 0 or p.first_layer_speed == 0) return error.InvalidValue;

        const w = if (p.line_width > 0) p.line_width else 1.1 * m.nozzle_diameter;
        const w0 = if (p.first_layer_line_width > 0) p.first_layer_line_width else 1.25 * m.nozzle_diameter;
        if (p.layer_height > w or p.first_layer_height > w0) return error.InvalidValue;
        const r = f.diameter / 2;
        return .{
            .settings = self,
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
    /// then scales it.
    pub fn speed(self: Resolved, feature: Feature, width: f64, height: f64, first_layer: bool) f64 {
        const p = self.settings.project;
        const flow_limit = self.settings.filament.max_flow / (width * height);
        const limit = @min(self.settings.machine.max_speed, flow_limit);
        const ratio = if (first_layer) p.first_layer_speed else switch (feature) {
            .outer_wall => p.outer_wall_speed,
            .inner_wall => p.inner_wall_speed,
            .skin => p.skin_speed,
            .infill => p.infill_speed,
        };
        return limit * ratio;
    }
};

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

test "resolve derives layers and speeds" {
    var s: Settings = .{};
    s.project.layer_height = 0.2;
    s.project.top_thickness = 0.8;
    const r = try s.resolve();
    try testing.expectEqual(@as(u32, 4), r.top_layers);
    try testing.expectApproxEqAbs(@as(f64, 0.44), r.line_width, 1e-9);
    // 12 mm^3/s over 0.44 x 0.2 mm is 136 mm/s, less than the 150 mm/s limit.
    try testing.expectApproxEqAbs(12.0 / 0.088, r.speed(.infill, 0.44, 0.2, false), 1e-9);
    try testing.expectApproxEqAbs(0.5 * 12.0 / 0.088, r.speed(.outer_wall, 0.44, 0.2, false), 1e-9);
}
