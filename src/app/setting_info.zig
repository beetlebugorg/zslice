//! The description of each setting, for the settings panel of a shell:
//! the group, the section, the label, the help text, the kind, the
//! choices, the unit, the default, the slider range, and the limits. The
//! list is made at compile time from the fields of `Settings` and from
//! settings_meta.zig, so a new setting needs no code in a shell.

const std = @import("std");
const zs = @import("../root.zig");
const meta = @import("../settings_meta.zig");
const Settings = zs.Settings;
const testing = std.testing;

pub const SettingKind = enum(c_int) { number = 0, integer = 1, boolean = 2, choice = 3, text = 4 };

pub const SettingInfo = struct {
    /// "group.name"
    name: [:0]const u8,
    group: [:0]const u8,
    /// The section in the group, for example "Walls". Can be empty.
    section: [:0]const u8,
    /// A label for the UI, from the name: "nozzle_temp" -> "Nozzle temp".
    label: [:0]const u8,
    /// The help text, from the doc comment of the field.
    doc: [:0]const u8,
    kind: SettingKind,
    /// For a choice: the choices, one on each line.
    choices: [:0]const u8,
    /// The unit of a number, for the UI: "mm", "mm/s", "°C", and so on.
    /// "%" marks a ratio: the value 0.5 is 50 %, and a UI shows the value
    /// times 100. Empty for the other kinds.
    unit: [:0]const u8 = "",
    /// The built-in default value, as text (as `getSetting` writes it).
    default_value: [:0]const u8 = "",
    /// The setting can change for some layers (an override).
    per_layer: bool = false,
    /// A useful range for a slider, in the units of the value (a ratio
    /// from 0 to 1, not a percentage). min == max: no slider. A value out
    /// of the range is still valid; the slider only covers the usual
    /// values.
    slider_min: f64 = 0,
    slider_max: f64 = 0,
    /// The step of the slider, in the units of the value.
    slider_step: f64 = 0,
    /// The hard limits (see settings.limits); min == max: none.
    limit_min: f64 = 0,
    limit_max: f64 = 0,
    /// For text: true if the value can have more than one line.
    multiline: bool,
};

pub const settings_info: []const SettingInfo = blk: {
    // The text of the float defaults takes many comptime steps.
    @setEvalBranchQuota(2_000_000);
    var list: []const SettingInfo = &.{};
    for (@typeInfo(Settings).@"struct".fields) |g| {
        for (@typeInfo(g.type).@"struct".fields) |f| {
            const name = std.fmt.comptimePrint("{s}.{s}", .{ g.name, f.name });
            const m = findMeta(name);
            const kind: SettingKind = switch (@typeInfo(f.type)) {
                .float => .number,
                .int => .integer,
                .bool => .boolean,
                .@"enum" => .choice,
                .pointer => .text,
                else => @compileError("unsupported setting type"),
            };
            var choices: []const u8 = "";
            if (kind == .choice) {
                for (@typeInfo(f.type).@"enum".fields, 0..) |e, i| {
                    choices = choices ++ (if (i == 0) "" else "\n") ++ e.name;
                }
            }
            list = list ++ [_]SettingInfo{.{
                .name = name,
                .group = std.fmt.comptimePrint("{s}", .{g.name}),
                .section = std.fmt.comptimePrint("{s}", .{m.section}),
                .label = labelOf(f.name),
                .doc = std.fmt.comptimePrint("{s}", .{m.doc}),
                .kind = kind,
                .choices = std.fmt.comptimePrint("{s}", .{choices}),
                .multiline = std.mem.endsWith(u8, f.name, "gcode") or std.mem.endsWith(u8, f.name, "rules"),
                .unit = unitOf(name),
                .per_layer = zs.settings.isLayerSetting(name),
                .default_value = defaultText(g.type, f.name),
                .slider_min = sliderOf(name)[0],
                .slider_max = sliderOf(name)[1],
                .slider_step = sliderOf(name)[2],
                .limit_min = (zs.settings.limitOf(name) orelse [2]f64{ 0, 0 })[0],
                .limit_max = (zs.settings.limitOf(name) orelse [2]f64{ 0, 0 })[1],
            }};
        }
    }
    break :blk list;
};

/// The unit of each number setting. A test checks that each number has
/// one, so a new setting needs a line here.
const units = [_][2][]const u8{
    // machine
    .{ "machine.bed_size_x", "mm" },
    .{ "machine.bed_size_y", "mm" },
    .{ "machine.origin_x", "mm" },
    .{ "machine.origin_y", "mm" },
    .{ "machine.max_height", "mm" },
    .{ "machine.nozzle_diameter", "mm" },
    .{ "machine.nozzle_tip_radius", "mm" },
    .{ "machine.nozzle_cone_angle", "\u{b0}" },
    .{ "machine.max_speed", "mm/s" },
    .{ "machine.travel_speed", "mm/s" },
    .{ "machine.max_z_speed", "mm/s" },
    .{ "machine.max_z_accel", "mm/s²" },
    .{ "machine.hour_rate", "/h" },
    .{ "machine.max_accel", "mm/s²" },
    .{ "machine.corner_speed", "mm/s" },
    .{ "machine.max_accel_x", "mm/s²" },
    .{ "machine.max_accel_y", "mm/s²" },
    .{ "machine.max_speed_x", "mm/s" },
    .{ "machine.max_speed_y", "mm/s" },
    .{ "machine.retract_length", "mm" },
    .{ "machine.retract_speed", "mm/s" },
    // filament
    .{ "filament.diameter", "mm" },
    .{ "filament.density", "g/cm\u{b3}" },
    .{ "filament.price_per_kg", "per kg" },
    .{ "filament.nozzle_temp", "\u{b0}C" },
    .{ "filament.first_layer_nozzle_temp", "\u{b0}C" },
    .{ "filament.bed_temp", "\u{b0}C" },
    .{ "filament.max_flow", "mm\u{b3}/s" },
    .{ "filament.flow_ratio", "%" },
    .{ "filament.fan_speed", "%" },
    .{ "filament.fan_off_layers", "layers" },
    .{ "filament.fan_max_speed", "%" },
    .{ "filament.fan_boost_time", "s" },
    .{ "filament.min_layer_time", "s" },
    .{ "filament.min_speed", "mm/s" },
    .{ "filament.standby_temp", "\u{b0}C" },
    .{ "filament.shrinkage_xy", "%" },
    .{ "filament.shrinkage_z", "%" },
    .{ "filament.xy_offset", "mm" },
    .{ "filament.hole_xy_offset", "mm" },
    .{ "filament.retract_ratio", "%" },
    // project
    .{ "project.layer_height", "mm" },
    .{ "project.first_layer_height", "mm" },
    .{ "project.line_width", "mm" },
    .{ "project.first_layer_line_width", "mm" },
    .{ "project.wall_count", "walls" },
    .{ "project.wall_thickness", "mm" },
    .{ "project.min_wall_line_width", "mm" },
    .{ "project.min_feature_size", "mm" },
    .{ "project.min_bead_width", "mm" },
    .{ "project.wall_transition_length", "mm" },
    .{ "project.wall_transition_angle", "\u{b0}" },
    .{ "project.wall_transition_filter_distance", "mm" },
    .{ "project.wall_distribution_count", "walls" },
    .{ "project.top_thickness", "mm" },
    .{ "project.bottom_thickness", "mm" },
    .{ "project.skin_removal_width", "mm" },
    .{ "project.skin_expand_distance", "mm" },
    .{ "project.solid_infill_width", "mm" },
    .{ "project.skin_angle", "\u{b0}" },
    .{ "project.skin_angle_step", "\u{b0}" },
    .{ "project.skin_overlap", "%" },
    .{ "project.skin_link_length", "mm" },
    .{ "project.infill_density", "%" },
    .{ "project.infill_angle", "\u{b0}" },
    .{ "project.lightning_angle", "\u{b0}" },
    .{ "project.top_support_layers", "layers" },
    .{ "project.top_support_density", "%" },
    .{ "project.infill_overlap", "%" },
    .{ "project.infill_flow", "%" },
    .{ "project.bridge_speed", "%" },
    .{ "project.bridge_flow", "%" },
    .{ "project.bridge_fan", "%" },
    .{ "project.infill_layers", "layers" },
    .{ "project.ironing_flow", "%" },
    .{ "project.ironing_spacing", "mm" },
    .{ "project.ironing_inset", "mm" },
    .{ "project.ironing_speed", "%" },
    .{ "project.slope_smoothing_min_width", "%" },
    .{ "project.slope_smoothing_max_width", "%" },
    .{ "project.slope_smoothing_flow", "%" },
    .{ "project.slope_smoothing_speed", "%" },
    .{ "project.slope_ironing_passes", "passes" },
    .{ "project.slope_ironing_flow", "%" },
    .{ "project.slope_ironing_speed", "%" },
    .{ "project.outer_wall_speed", "%" },
    .{ "project.inner_wall_speed", "%" },
    .{ "project.skin_speed", "%" },
    .{ "project.infill_speed", "%" },
    .{ "project.first_layer_speed", "%" },
    .{ "project.slow_layers", "layers" },
    .{ "project.outer_wall_accel", "mm/s²" },
    .{ "project.inner_wall_accel", "mm/s²" },
    .{ "project.skin_accel", "mm/s²" },
    .{ "project.infill_accel", "mm/s²" },
    .{ "project.travel_accel", "mm/s²" },
    .{ "project.first_layer_accel", "mm/s²" },
    .{ "project.retract_min_travel", "mm" },
    .{ "project.combing_max_distance", "mm" },
    .{ "project.z_hop", "mm" },
    .{ "project.support_tree_angle", "\u{b0}" },
    .{ "project.support_tree_spacing", "mm" },
    .{ "project.support_tree_tip", "mm" },
    .{ "project.support_angle", "\u{b0}" },
    .{ "project.support_density", "%" },
    .{ "project.support_xy_gap", "mm" },
    .{ "project.support_z_gap_layers", "layers" },
    .{ "project.support_interface_layers", "layers" },
    .{ "project.support_interface_density", "%" },
    .{ "project.skirt_loops", "loops" },
    .{ "project.skirt_distance", "mm" },
    .{ "project.skirt_layers", "layers" },
    .{ "project.brim_width", "mm" },
    .{ "project.first_layer_xy_offset", "mm" },
    // engine
    .{ "engine.resolution", "mm" },
    .{ "engine.gap_closing", "mm" },
    .{ "engine.threads", "threads" },
};

/// The slider ranges: the usual values of the settings that a user tunes
/// by eye, and the step that people use (a layer height of 0.28 mm, not
/// 0.281 mm). A test checks that each name exists.
const sliders = [_]struct { []const u8, f64, f64, f64 }{
    // machine
    .{ "machine.nozzle_diameter", 0.2, 1.2, 0.05 },
    .{ "machine.nozzle_tip_radius", 0, 1.5, 0.05 },
    .{ "machine.nozzle_cone_angle", 20, 80, 1 },
    .{ "machine.max_speed", 20, 500, 5 },
    .{ "machine.travel_speed", 20, 500, 5 },
    .{ "machine.max_z_speed", 1, 30, 1 },
    .{ "machine.max_z_accel", 10, 2000, 10 },
    .{ "machine.hour_rate", 0, 10, 0.05 },
    .{ "machine.max_accel", 100, 10000, 100 },
    .{ "machine.corner_speed", 0, 30, 1 },
    .{ "machine.max_accel_x", 0, 20000, 100 },
    .{ "machine.max_accel_y", 0, 20000, 100 },
    .{ "machine.max_speed_x", 0, 1000, 10 },
    .{ "machine.max_speed_y", 0, 1000, 10 },
    .{ "machine.retract_length", 0, 8, 0.1 },
    .{ "machine.retract_speed", 10, 80, 5 },
    // filament
    .{ "filament.nozzle_temp", 160, 300, 5 },
    .{ "filament.first_layer_nozzle_temp", 160, 300, 5 },
    .{ "filament.bed_temp", 0, 120, 5 },
    .{ "filament.max_flow", 2, 40, 0.5 },
    .{ "filament.flow_ratio", 0.8, 1.2, 0.01 },
    .{ "filament.fan_speed", 0, 1, 0.05 },
    .{ "filament.fan_off_layers", 0, 5, 1 },
    .{ "filament.fan_max_speed", 0, 1, 0.05 },
    .{ "filament.fan_boost_time", 0, 30, 1 },
    .{ "filament.min_layer_time", 0, 30, 1 },
    .{ "filament.min_speed", 5, 50, 1 },
    .{ "filament.standby_temp", 0, 250, 5 },
    .{ "filament.shrinkage_xy", 0.99, 1.02, 0.001 },
    .{ "filament.shrinkage_z", 0.99, 1.02, 0.001 },
    .{ "filament.xy_offset", -0.3, 0.3, 0.01 },
    .{ "filament.hole_xy_offset", -0.3, 0.3, 0.01 },
    .{ "filament.retract_ratio", 0, 2, 0.05 },
    // project
    .{ "project.layer_height", 0.05, 0.4, 0.01 },
    .{ "project.first_layer_height", 0.1, 0.5, 0.01 },
    .{ "project.line_width", 0, 1, 0.01 },
    .{ "project.first_layer_line_width", 0, 1.2, 0.01 },
    .{ "project.wall_count", 0, 8, 1 },
    .{ "project.wall_thickness", 0, 5, 0.1 },
    .{ "project.min_wall_line_width", 0, 1, 0.01 },
    .{ "project.min_feature_size", 0, 0.5, 0.01 },
    .{ "project.min_bead_width", 0, 1, 0.01 },
    .{ "project.wall_transition_length", 0, 2, 0.05 },
    .{ "project.wall_transition_angle", 1, 59, 1 },
    .{ "project.wall_transition_filter_distance", 0.1, 200, 1 },
    .{ "project.wall_distribution_count", 1, 8, 1 },
    .{ "project.top_thickness", 0, 3, 0.1 },
    .{ "project.bottom_thickness", 0, 3, 0.1 },
    .{ "project.skin_removal_width", 0, 2, 0.05 },
    .{ "project.skin_expand_distance", 0, 5, 0.1 },
    .{ "project.solid_infill_width", 0, 5, 0.1 },
    .{ "project.skin_angle", 0, 180, 5 },
    .{ "project.skin_angle_step", 0, 90, 5 },
    .{ "project.skin_overlap", 0, 0.5, 0.01 },
    .{ "project.skin_link_length", 0, 50, 1 },
    .{ "project.infill_density", 0, 1, 0.01 },
    .{ "project.infill_angle", 0, 180, 5 },
    .{ "project.lightning_angle", 0, 75, 1 },
    .{ "project.top_support_layers", 0, 6, 1 },
    .{ "project.top_support_density", 0.05, 1, 0.05 },
    .{ "project.infill_overlap", 0, 0.5, 0.01 },
    .{ "project.infill_flow", 0.5, 1.5, 0.01 },
    .{ "project.bridge_speed", 0.05, 1, 0.01 },
    .{ "project.bridge_flow", 0.5, 1.5, 0.01 },
    .{ "project.bridge_fan", 0, 1, 0.05 },
    .{ "project.infill_layers", 1, 4, 1 },
    .{ "project.ironing_flow", 0, 0.3, 0.01 },
    .{ "project.ironing_spacing", 0.05, 0.5, 0.01 },
    .{ "project.ironing_inset", 0, 2, 0.1 },
    .{ "project.ironing_speed", 0.05, 1, 0.01 },
    .{ "project.slope_smoothing_min_width", 0.1, 1, 0.05 },
    .{ "project.slope_smoothing_max_width", 0.5, 4, 0.1 },
    .{ "project.slope_smoothing_flow", 0.5, 1.5, 0.05 },
    .{ "project.slope_smoothing_speed", 0.1, 1, 0.05 },
    .{ "project.slope_ironing_passes", 1, 5, 1 },
    .{ "project.slope_ironing_flow", 0, 0.3, 0.01 },
    .{ "project.slope_ironing_speed", 0.05, 1, 0.01 },
    .{ "project.outer_wall_speed", 0.05, 1, 0.01 },
    .{ "project.inner_wall_speed", 0.05, 1, 0.01 },
    .{ "project.skin_speed", 0.05, 1, 0.01 },
    .{ "project.infill_speed", 0.05, 1, 0.01 },
    .{ "project.first_layer_speed", 0.05, 1, 0.01 },
    .{ "project.slow_layers", 0, 10, 1 },
    .{ "project.outer_wall_accel", 0, 10000, 100 },
    .{ "project.inner_wall_accel", 0, 10000, 100 },
    .{ "project.skin_accel", 0, 10000, 100 },
    .{ "project.infill_accel", 0, 10000, 100 },
    .{ "project.travel_accel", 0, 10000, 100 },
    .{ "project.first_layer_accel", 0, 10000, 100 },
    .{ "project.retract_min_travel", 0, 10, 0.5 },
    .{ "project.combing_max_distance", 0, 200, 5 },
    .{ "project.z_hop", 0, 1, 0.05 },
    .{ "project.support_tree_angle", 10, 60, 1 },
    .{ "project.support_tree_spacing", 1, 10, 0.5 },
    .{ "project.support_tree_tip", 0, 3, 0.1 },
    .{ "project.support_angle", 0, 89, 1 },
    .{ "project.support_density", 0.05, 0.5, 0.01 },
    .{ "project.support_xy_gap", 0, 2, 0.05 },
    .{ "project.support_z_gap_layers", 0, 3, 1 },
    .{ "project.support_interface_layers", 0, 5, 1 },
    .{ "project.support_interface_density", 0.1, 1, 0.05 },
    .{ "project.skirt_loops", 0, 10, 1 },
    .{ "project.skirt_distance", 0, 20, 0.5 },
    .{ "project.skirt_layers", 0, 5, 1 },
    .{ "project.brim_width", 0, 20, 0.5 },
    .{ "project.first_layer_xy_offset", -0.5, 0.5, 0.01 },
    // engine
    .{ "engine.gap_closing", 0, 3, 0.1 },
};

fn sliderOf(comptime name: []const u8) [3]f64 {
    @setEvalBranchQuota(100_000);
    for (sliders) |sl| if (std.mem.eql(u8, sl[0], name)) return .{ sl[1], sl[2], sl[3] };
    return .{ 0, 0, 0 };
}

test "each slider is for a number setting" {
    for (sliders) |sl| {
        const info = for (settings_info) |s| {
            if (std.mem.eql(u8, s.name, sl[0])) break s;
        } else return error.TestUnexpectedResult;
        try testing.expect(info.kind == .number or info.kind == .integer);
        try testing.expect(sl[1] < sl[2]);
        // A few steps at least.
        try testing.expect(sl[3] > 0 and sl[3] <= (sl[2] - sl[1]) / 3);
        // The usual values are in the hard limits.
        try testing.expect(sl[1] >= info.limit_min and sl[2] <= info.limit_max);
    }
}

/// The default of field `name` of the settings group T, as text.
fn defaultText(comptime T: type, comptime name: []const u8) [:0]const u8 {
    const d = @field(@as(T, .{}), name);
    return switch (@typeInfo(@TypeOf(d))) {
        .float, .int => std.fmt.comptimePrint("{d}", .{d}),
        .bool => if (d) "true" else "false",
        .@"enum" => std.fmt.comptimePrint("{s}", .{@tagName(d)}),
        .pointer => std.fmt.comptimePrint("{s}", .{d}),
        else => "",
    };
}

fn unitOf(comptime name: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    for (units) |u| if (std.mem.eql(u8, u[0], name)) return std.fmt.comptimePrint("{s}", .{u[1]});
    return "";
}

test "each number setting has a unit" {
    for (settings_info) |s| {
        if ((s.kind == .number or s.kind == .integer) and s.unit.len == 0) {
            std.debug.print("no unit for {s}: add it to `units` in src/app/setting_info.zig\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
    for (units) |u| try testing.expect(for (settings_info) |s| {
        if (std.mem.eql(u8, s.name, u[0])) break true;
    } else false);
}

fn findMeta(comptime name: []const u8) meta.Meta {
    @setEvalBranchQuota(100_000);
    for (meta.all) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return .{ .name = name, .section = "", .doc = "" };
}

fn labelOf(comptime field: []const u8) [:0]const u8 {
    var out: [field.len:0]u8 = undefined;
    for (field, 0..) |c, i| {
        out[i] = if (c == '_') ' ' else if (i == 0) std.ascii.toUpper(c) else c;
    }
    const final = out;
    return &final;
}

test "each setting has help text" {
    for (settings_info) |s| {
        if (s.doc.len == 0) {
            std.debug.print("no help text for {s}: add a /// comment, then run tools/settings_doc.py --zig\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqualStrings("Nozzle temp", findInfo("filament.nozzle_temp").label);
    try testing.expectEqualStrings("lines\ngrid\ntriangles\ntrihexagon\ncubic\ngyroid\nconcentric\nhoneycomb\nzigzag\nflow\nlightning", findInfo("project.infill_pattern").choices);
}

fn findInfo(name: []const u8) SettingInfo {
    for (settings_info) |s| if (std.mem.eql(u8, s.name, name)) return s;
    unreachable;
}
