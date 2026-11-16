//! The settings that change each feature (the walls, the skin, the
//! infill, and so on). The inspector lists them for a selected line, and
//! the settings panel uses the same tables to show the lines that a
//! setting changes (see setting_effect.zig). One set of tables keeps the
//! two views in agreement.

const std = @import("std");
const meta = @import("../settings_meta.zig");
const Feature = @import("../settings.zig").Feature;

/// The name of each feature for the UI, in the order of the Feature enum.
pub const feature_names = [_][]const u8{ "Outer wall", "Inner wall", "Skin", "Sparse infill", "Ironing", "Skirt or brim", "Support", "Support interface" };

/// The settings that change the shape and the place of each feature, in
/// the order of the Feature enum. The speed settings are in
/// `speedRatioSetting` and `cooling_speed_settings`.
pub const feature_settings = [_][]const []const u8{
    &.{ "project.wall_count", "project.seam", "project.thin_walls", "project.line_width", "project.layer_height", "filament.xy_offset", "filament.hole_xy_offset" },
    &.{ "project.wall_count", "project.line_width", "project.layer_height" },
    &.{ "project.top_thickness", "project.bottom_thickness", "project.skin_expand_distance", "project.skin_removal_width", "project.solid_infill_width", "project.skin_pattern", "project.skin_angle", "project.skin_angle_step", "project.skin_overlap", "project.line_width", "project.layer_height" },
    &.{ "project.infill_density", "project.solid_infill_width", "project.skin_expand_distance", "project.infill_pattern", "project.infill_connect", "project.top_support_layers", "project.top_support_density", "project.infill_angle", "project.infill_overlap", "project.line_width", "project.layer_height" },
    &.{ "project.ironing", "project.ironing_flow", "project.ironing_spacing", "project.ironing_inset", "project.skin_angle" },
    &.{ "project.skirt_loops", "project.skirt_distance", "project.skirt_layers", "project.brim_width", "project.line_width" },
    &.{ "project.support", "project.support_style", "project.support_angle", "project.support_density", "project.support_xy_gap", "project.support_z_gap_layers", "project.support_tree_angle", "project.support_tree_spacing", "project.support_tree_tip" },
    &.{ "project.support_interface_layers", "project.support_interface_density", "project.support_z_gap_layers" },
};
pub const first_layer_settings = [_][]const u8{ "project.first_layer_height", "project.first_layer_line_width", "filament.first_layer_nozzle_temp", "project.first_layer_xy_offset" };
/// The settings that slow a layer down to cool it.
pub const cooling_speed_settings = [_][]const u8{ "filament.min_layer_time", "filament.min_speed" };
pub const material_settings = [_][]const u8{ "filament.flow_ratio", "filament.nozzle_temp", "filament.fan_speed" };

/// The acceleration setting of a feature (or of the first layer).
pub fn accelSetting(feature: Feature, first_layer: bool) []const u8 {
    if (first_layer) return "project.first_layer_accel";
    return switch (feature) {
        .outer_wall => "project.outer_wall_accel",
        .inner_wall, .skirt => "project.inner_wall_accel",
        .skin, .support_interface, .ironing => "project.skin_accel",
        .infill, .support => "project.infill_accel",
    };
}

/// The speed ratio setting of a line of `feature` (see Resolved.speed).
pub fn speedRatioSetting(feature: Feature, first_layer: bool) []const u8 {
    if (feature == .ironing) return "project.ironing_speed";
    if (first_layer) return "project.first_layer_speed";
    return switch (feature) {
        .outer_wall => "project.outer_wall_speed",
        .inner_wall, .skirt => "project.inner_wall_speed",
        .skin, .support_interface => "project.skin_speed",
        .infill, .support => "project.infill_speed",
        .ironing => unreachable,
    };
}

test "each inspector setting exists" {
    const has = struct {
        fn f(name: []const u8) bool {
            for (meta.all) |m| if (std.mem.eql(u8, m.name, name)) return true;
            return false;
        }
    }.f;
    for (feature_settings) |list| for (list) |n| try std.testing.expect(has(n));
    for (first_layer_settings ++ cooling_speed_settings ++ material_settings) |n| try std.testing.expect(has(n));
    for (0..feature_names.len) |i| for ([_]bool{ false, true }) |first| try std.testing.expect(has(speedRatioSetting(@enumFromInt(i), first)));
}
