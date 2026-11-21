//! What a setting changes in the preview: the lines of some features, a
//! mark (the seams, the travel moves, the retractions), or nothing that
//! shows, with a note that says what it changes. The settings panel uses
//! this to show the lines of a setting. It uses the tables of the
//! inspector (feature_settings.zig), so a click on a line and a look at a
//! setting agree.

const std = @import("std");
const zs = @import("../root.zig");
const Settings = zs.Settings;
const fs = @import("feature_settings.zig");
const feature_names = fs.feature_names;
const feature_settings = fs.feature_settings;
const first_layer_settings = fs.first_layer_settings;
const speedRatioSetting = fs.speedRatioSetting;
const settings_info = @import("setting_info.zig").settings_info;
const testing = std.testing;

/// Settings that change every line: the bead size, the flow, the speed
/// limits, the cooling, and the place and size of the part.
const all_lines_settings = [_][]const u8{
    "project.layer_height",    "project.line_width", "filament.flow_ratio",
    "filament.max_flow",       "machine.max_speed",  "machine.nozzle_diameter",
    "filament.min_layer_time", "filament.min_speed", "filament.shrinkage_xy",
    "filament.shrinkage_z",    "filament.xy_offset", "project.placement",
    "engine.resolution",       "engine.gap_closing", "filament.color",
    "machine.bed_size_x",      "machine.bed_size_y",
};

/// What a setting changes in the toolpaths.
pub const SettingEffect = struct {
    /// A bit for each feature (1 << Feature) whose lines the setting
    /// changes. 0: the setting changes no line, only the G-code (for
    /// example temperatures, retraction, start code) or nothing visible.
    features: u32 = 0,
    /// The setting changes only the lines of the first layer.
    first_layer_only: bool = false,
    /// For a setting with no visible effect: what it changes, and how to
    /// see it.
    note: [:0]const u8 = "",
};

/// Marks that the previews draw for settings with no line of their own,
/// in the bits after the features (see SettingEffect.features).
pub const mark_seam: u32 = 1 << feature_names.len;
/// The travel moves between the paths.
pub const mark_travel: u32 = 1 << (feature_names.len + 1);
/// The retractions (at the start of a retracted travel).
pub const mark_retract: u32 = 1 << (feature_names.len + 2);

/// Settings whose effect is a mark: the seam points, the travel moves, and
/// the retractions.
const mark_settings = [_]struct { []const u8, u32 }{
    .{ "project.seam", mark_seam },
    .{ "project.seam_corner", mark_seam },
    .{ "project.retract_min_travel", mark_travel | mark_retract },
    .{ "project.combing", mark_travel | mark_retract },
    .{ "project.combing_max_distance", mark_travel | mark_retract },
    .{ "project.z_hop", mark_travel | mark_retract },
    .{ "project.retract_wipe", mark_retract },
    .{ "project.outer_wall_wipe", mark_retract },
    .{ "project.coasting_volume", mark_retract },
    .{ "project.coasting_speed", mark_retract },
    .{ "project.retract_layer_change", mark_travel | mark_retract },
    .{ "machine.travel_speed", mark_travel },
    .{ "machine.first_layer_travel_speed", mark_travel },
    .{ "machine.retract_length", mark_retract | mark_travel },
    .{ "machine.retract_speed", mark_retract | mark_travel },
    .{ "filament.retract_ratio", mark_retract | mark_travel },
};

/// The settings that change no line and no mark in the preview, with what
/// they change. A test checks that each setting has an effect or a note,
/// so a new setting gets one of them.
const preview_notes = [_]struct { []const u8, [:0]const u8 }{
    .{ "machine.name", "The name of the printer, for the profiles and the start G-code." },
    .{ "project.support_min_ledge", "The small ledges with no support under them, such as embossed letters: the support lines there come or go." },
    .{ "machine.model", "The printer model: the 3D view shows its bed. The lines do not move." },
    .{ "machine.max_height", "A check: a part higher than this does not slice." },
    .{ "machine.max_z_speed", "The speed of the Z moves between layers. It changes the print time (see the status bar)." },
    .{ "machine.max_z_accel", "The acceleration of the Z moves. It changes the print time (see the status bar)." },
    .{ "machine.max_accel", "The acceleration of the head. It changes the print time (see the status bar), and the acceleration commands in the G-code." },
    .{ "machine.corner_speed", "The speed of the head at a corner. It changes the print time (see the status bar)." },
    .{ "machine.kinematics", "How the motors move the head. It changes the print time with per-axis limits (see the status bar)." },
    .{ "machine.max_accel_x", "The acceleration limit of X. It changes the print time (see the status bar)." },
    .{ "machine.max_accel_y", "The acceleration limit of Y (the bed of a bed slinger). It changes the print time (see the status bar)." },
    .{ "machine.max_speed_x", "The speed limit of X. It changes the print time (see the status bar)." },
    .{ "machine.max_speed_y", "The speed limit of Y. It changes the print time (see the status bar)." },
    .{ "machine.accel_control", "Acceleration commands in the G-code (M204, or SET_VELOCITY_LIMIT in Klipper). The lines do not move." },
    .{ "machine.gcode_flavor", "The dialect of the acceleration commands in the G-code." },
    .{ "machine.outer_wall_accel", "The acceleration of the outer walls: the G-code commands and the print time. The lines do not move." },
    .{ "machine.inner_wall_accel", "The acceleration of the inner walls: the G-code commands and the print time. The lines do not move." },
    .{ "machine.skin_accel", "The acceleration of the skin: the G-code commands and the print time. The lines do not move." },
    .{ "machine.infill_accel", "The acceleration of the infill: the G-code commands and the print time. The lines do not move." },
    .{ "project.z_hop_only_crossing", "Which retracted travels lift the nozzle: the Z moves in the G-code and the print time. The travel lines do not move." },
    .{ "machine.travel_accel", "The acceleration of the travel moves: the G-code commands and the print time." },
    .{ "machine.first_layer_accel", "The acceleration of the first layer: the G-code commands and the print time." },
    .{ "machine.start_gcode", "The G-code before the print: heating, homing, and the purge line." },
    .{ "machine.label_objects", "Labels of the parts in the G-code, so the printer can skip a part. The lines do not move." },
    .{ "machine.thumbnails", "Pictures of the print in the G-code, for the screen of the printer. The lines do not move." },
    .{ "machine.end_gcode", "The G-code after the print." },
    .{ "machine.extruder", "The extruder type, for the retraction defaults." },
    .{ "machine.origin_x", "The G-code position of the bed corner. The preview shows bed coordinates, so it does not change." },
    .{ "machine.origin_y", "The G-code position of the bed corner. The preview shows bed coordinates, so it does not change." },
    .{ "filament.name", "The name of the filament, for the profiles and the start G-code." },
    .{ "filament.material", "The type of the plastic, for the Filament menu. It does not change the lines." },
    .{ "project.path_rules", "Rules that change the speed, the flow, or the fan of the paths that they match (see the speed and flow colors)." },
    .{ "filament.diameter", "The filament diameter: it changes how far the extruder pushes, not the lines." },
    .{ "filament.density", "The weight of the plastic, for the filament weight in the status bar." },
    .{ "filament.price_per_kg", "The cost of the filament, for the cost of a print. The lines do not move." },
    .{ "machine.hour_rate", "The cost of an hour of the printer, for the cost of a print. The lines do not move." },
    .{ "filament.nozzle_temp", "A G-code temperature. It changes no line." },
    .{ "filament.first_layer_nozzle_temp", "A G-code temperature for the first layer. It changes no line." },
    .{ "filament.bed_temp", "A G-code temperature. It changes no line." },
    .{ "filament.pressure_advance", "A firmware command after the start G-code. It changes no line." },
    .{ "filament.start_gcode", "G-code after the start G-code. It changes no line." },
    .{ "filament.end_gcode", "G-code before the end G-code. It changes no line." },
    .{ "filament.first_layer_bed_temp", "A G-code temperature of the first layer. It changes no line." },
    .{ "machine.chamber_temp", "The air around the print, for the simulated print. It changes no line." },
    .{ "machine.part_fan_air", "The air of the fans, for the simulated print. It changes no line." },
    .{ "filament.standby_temp", "A G-code temperature. It changes no line." },
    .{ "filament.fan_speed", "The part cooling fan in the G-code. It changes no line." },
    .{ "filament.fan_off_layers", "The fan in the G-code on the first layers. It changes no line." },
    .{ "filament.fan_ramp_layers", "The fan in the G-code on the layers after the fan comes on. It changes no line." },
    .{ "filament.fan_max_speed", "The fan in the G-code on short layers. It changes no line." },
    .{ "filament.fan_boost_time", "The fan in the G-code on short layers. It changes no line." },
    .{ "filament.cooling_mode", "How a short layer cools: slower lines, or a lap of the nozzle over the layer with the fan at full. The layer time and the speed color modes show the effect." },
    .{ "machine.filament_change", "How the printer changes the filament: a pause or a tool change in the G-code. The lines do not move." },
    .{ "machine.change_gcode", "The G-code of a filament change." },
    .{ "machine.change_time", "The time of a filament change. It changes the print time." },
    .{ "machine.bed_type", "The build plate: the start G-code of a Bambu Lab printer, and the plate in its file. The lines do not move." },
    .{ "machine.nozzle_type", "The material of the nozzle, in the file of a Bambu Lab printer. The lines do not move." },
    .{ "machine.nozzle_flow", "The flow of the hot end, in the file of a Bambu Lab printer. The lines do not move." },
    .{ "machine.nozzles", "The nozzles of the print head. The lines do not move: each filament prints with its nozzle." },
    .{ "machine.nozzle1_max_x", "The reach of the first nozzle. The Check tells a part on it that goes past this edge." },
    .{ "machine.nozzle1_max_height", "The reach of the first nozzle. The Check tells a part on it that goes higher." },
    .{ "machine.nozzle2_min_x", "The reach of the second nozzle. The Check tells a part on it that goes past this edge." },
    .{ "machine.nozzle2_max_height", "The reach of the second nozzle. The Check tells a part on it that goes higher." },
    .{ "filament.nozzle", "The nozzle of the filament on a printer with two. The lines do not move." },
    .{ "machine.flush_volume", "The plastic that a change flushes. It changes the filament weight." },
    .{ "project.flush_multiplier", "The plastic that a change flushes. It changes the filament weight." },
    .{ "project.flush_into_hidden", "The plastic that a change flushes, and the order of the lines after a change. It changes the filament weight." },
    .{ "project.prime_tower", "The prime tower of a print with tool changes, in the G-code. The view draws it next to the parts." },
    .{ "project.angles_follow_part", "The skin and infill angles of a turned part, in its lines." },
    .{ "project.prime_tower_split", "A prime tower for each family of materials, in the G-code. The view draws each tower next to the parts." },
    .{ "project.prime_tower_width", "The size of the prime tower, in the G-code." },
    .{ "project.prime_tower_x", "The place of the prime tower, in the G-code." },
    .{ "project.prime_tower_y", "The place of the prime tower, in the G-code." },
    .{ "project.filament", "The filament of the part or of the layers: the color of its lines, and the filament changes in the G-code." },
    .{ "project.support_filament", "The filament of the support: the color of the support lines, and the filament changes in the G-code." },
    .{ "project.support_interface_filament", "The filament of the support interface: the color of its lines, and the filament changes in the G-code." },
    .{ "project.paint_anchor_depth", "The root of a painted feature in the part under it: lines of the paint color under the feature, inside the walls. Only a painted part has it. Look at the layers under the feature." },
    .{ "project.paint_anchor_shape", "The shape of the root of a painted feature in the part under it. Only a painted part has it. Look at the layers under the feature." },
    .{ "engine.threads", "The number of threads of the slicer. The result is the same." },
    .{ "engine.job_name", "The name of the print, for the start G-code." },
};

fn noteOf(name: []const u8) [:0]const u8 {
    for (preview_notes) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    return "";
}

/// The lines that a setting changes. It uses the same tables as the
/// inspector, so a click on a line and a look at a setting agree.
pub fn settingEffect(name: []const u8) SettingEffect {
    const all: u32 = (1 << feature_names.len) - 1;
    const no_ironing = all & ~@as(u32, 1 << @intFromEnum(zs.settings.Feature.ironing)) & ~@as(u32, 1 << @intFromEnum(zs.settings.Feature.slope_ironing));
    var e: SettingEffect = .{};
    // A mark setting (the seam, travel, retraction) shows its marks only:
    // the lines around them would hide them.
    for (mark_settings) |m| if (std.mem.eql(u8, m[0], name)) return .{ .features = m[1] };
    // A wall thickness sets the wall count; the slow layers change the
    // speed of all lines on the layers after the first.
    if (std.mem.eql(u8, name, "project.wall_thickness")) return settingEffect("project.wall_count");
    if (std.mem.eql(u8, name, "project.slow_layers")) return .{ .features = no_ironing };
    for (all_lines_settings) |n| if (std.mem.eql(u8, n, name)) {
        e.features = all;
    };
    // The flow limit does not apply to ironing.
    if (std.mem.eql(u8, name, "filament.max_flow")) e.features = no_ironing;
    for (feature_settings, 0..) |list, i| for (list) |n| {
        if (std.mem.eql(u8, n, name)) e.features |= @as(u32, 1) << @intCast(i);
    };
    for (0..feature_names.len) |i| {
        if (std.mem.eql(u8, speedRatioSetting(@enumFromInt(i), false), name)) e.features |= @as(u32, 1) << @intCast(i);
    }
    if (e.features != 0) return e;
    for (first_layer_settings) |n| if (std.mem.eql(u8, n, name)) return .{ .features = all, .first_layer_only = true };
    if (std.mem.eql(u8, name, "project.first_layer_speed")) return .{ .features = no_ironing, .first_layer_only = true };
    e.note = noteOf(name);
    return e;
}

test "each setting shows in the preview, or has a note" {
    for (settings_info) |s| {
        const e = settingEffect(s.name);
        if (e.features == 0 and e.note.len == 0) {
            std.debug.print("{s} changes nothing in the preview: give it a line, a mark, or a note in src/app/setting_effect.zig\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "the seam setting shows the seam marks only" {
    try testing.expectEqual(mark_seam, settingEffect("project.seam").features);
}

test "setting effects" {
    const bit = struct {
        fn f(x: zs.settings.Feature) u32 {
            return @as(u32, 1) << @intCast(@intFromEnum(x));
        }
    }.f;
    try testing.expectEqual(bit(.outer_wall), settingEffect("project.outer_wall_speed").features);
    // The skirt uses the inner wall speed.
    try testing.expectEqual(bit(.inner_wall) | bit(.skirt), settingEffect("project.inner_wall_speed").features);
    try testing.expect(settingEffect("project.first_layer_height").first_layer_only);
    try testing.expectEqual(@as(u32, 0x7ff), settingEffect("project.layer_height").features);
    try testing.expectEqual(bit(.slope_ironing), settingEffect("project.slope_ironing_flow").features);
    try testing.expectEqual(bit(.slope_smoothing), settingEffect("project.slope_smoothing_flow").features);
    // A temperature changes no line.
    try testing.expectEqual(@as(u32, 0), settingEffect("filament.bed_temp").features);
    try testing.expectEqual(bit(.ironing), settingEffect("project.ironing_spacing").features & bit(.ironing));
}

/// The speed in mm/s that a speed ratio gives, with the value `value`
/// and the other settings as they are. Null if the setting is not a speed
/// ratio, or the value is not valid. The speed is for a line of the line
/// width of the feature at the layer height (the flow limit can make it
/// lower than the ratio of the machine limit).
pub fn ratioSpeed(settings: Settings, name: []const u8, value: []const u8) ?f64 {
    const Case = struct { n: []const u8, f: zs.settings.Feature, first: bool };
    const cases = [_]Case{
        .{ .n = "project.outer_wall_speed", .f = .outer_wall, .first = false },
        .{ .n = "project.inner_wall_speed", .f = .inner_wall, .first = false },
        .{ .n = "project.skin_speed", .f = .skin, .first = false },
        .{ .n = "project.infill_speed", .f = .infill, .first = false },
        .{ .n = "project.first_layer_speed", .f = .outer_wall, .first = true },
        .{ .n = "project.ironing_speed", .f = .ironing, .first = false },
        .{ .n = "project.slope_smoothing_speed", .f = .slope_smoothing, .first = false },
        .{ .n = "project.slope_ironing_speed", .f = .slope_ironing, .first = false },
        .{ .n = "project.bridge_speed", .f = .bridge, .first = false },
    };
    for (cases) |c| if (std.mem.eql(u8, c.n, name)) {
        var s = settings;
        s.set(name, value) catch return null;
        const r = s.resolve() catch return null;
        const w = if (c.first) r.first_layer_line_width else r.line_width;
        const h = if (c.first) s.project.first_layer_height else s.project.layer_height;
        return r.speed(c.f, w, h, c.first);
    };
    return null;
}

test "ratioSpeed" {
    var s: Settings = .{};
    s.machine.max_speed = 100;
    s.filament.max_flow = 1000;
    try std.testing.expectApproxEqAbs(@as(f64, 50), ratioSpeed(s, "project.outer_wall_speed", "0.5").?, 1e-9);
    try std.testing.expect(ratioSpeed(s, "project.layer_height", "0.2") == null);
}
