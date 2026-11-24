//! The skip lists of the keys of the slice form (see form.zig).
//!
//! A key of a tier reads every setting, minus the settings that this table
//! names for that tier. A setting with no line here is read by each tier.
//! So a new setting changes each key until someone proves that a tier does
//! not read it. A key that misses an input gives a wrong slice with no
//! error. This rule keeps the keys safe by default.
//!
//! A name enters the skip list of a tier only with two proofs:
//!
//! 1. A search of the code of the tier finds no read of the setting. The
//!    commit message names the files that were searched.
//! 2. `zslice verify --sweep` passes from its three base states.
//!
//! The tiers: mesh (the placed mesh of a part), geometry (the outlines of a
//! part), regions (the work of each layer), paths (the move stream of each
//! level), and text (the G-code of each level).
//!
//! The geometry tier reads 11 settings: the ten of the outline key of
//! before, and project.fast_offsets. Each other setting has a line with
//! the geometry tier. The regions and the paths tiers skip the patch
//! settings (`settings.patch_settings`, the one list of them): `skips`
//! reads that list. The app preferences change no G-code, so no tier
//! reads them.
//!
//! A name can end with ".*": it names a setting with parts, as
//! "machine.nozzle.*" (machine.nozzle.k.diameter and the others). A
//! comptime check stops a name that is no setting.
//!
//! Reference: the steps of an object and the settings that make a step
//! invalid (PrusaSlicer, an idea only), see docs/references/prusaslicer.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const settings_mod = @import("settings.zig");
const Settings = settings_mod.Settings;
const Tier = settings_mod.Tier;

pub const Skip = struct { name: []const u8, tiers: []const Tier };

/// Skipped by the geometry tier.
const g: []const Tier = &.{.geometry};
/// Skipped by each tier: an app preference.
const all: []const Tier = &.{ .mesh, .geometry, .regions, .paths, .text };

pub const skips_table = [_]Skip{
    .{ .name = "machine.name", .tiers = g },
    .{ .name = "machine.model", .tiers = g },
    .{ .name = "machine.bed_size_x", .tiers = g },
    .{ .name = "machine.bed_size_y", .tiers = g },
    .{ .name = "machine.origin_x", .tiers = g },
    .{ .name = "machine.origin_y", .tiers = g },
    .{ .name = "machine.max_height", .tiers = g },
    .{ .name = "machine.bed_type", .tiers = g },
    .{ .name = "machine.nozzle_diameter", .tiers = g },
    .{ .name = "machine.nozzle_type", .tiers = g },
    .{ .name = "machine.nozzle_flow", .tiers = g },
    .{ .name = "machine.nozzle_tip_radius", .tiers = g },
    .{ .name = "machine.nozzle_cone_angle", .tiers = g },
    .{ .name = "machine.chamber_temp", .tiers = g },
    .{ .name = "machine.part_fan_air", .tiers = g },
    .{ .name = "machine.max_speed", .tiers = g },
    .{ .name = "machine.travel_speed", .tiers = g },
    .{ .name = "machine.first_layer_travel_speed", .tiers = g },
    .{ .name = "machine.max_z_speed", .tiers = g },
    .{ .name = "machine.max_z_accel", .tiers = g },
    .{ .name = "machine.hour_rate", .tiers = g },
    .{ .name = "machine.max_accel", .tiers = g },
    .{ .name = "machine.corner_speed", .tiers = g },
    .{ .name = "machine.kinematics", .tiers = g },
    .{ .name = "machine.max_accel_x", .tiers = g },
    .{ .name = "machine.max_accel_y", .tiers = g },
    .{ .name = "machine.max_speed_x", .tiers = g },
    .{ .name = "machine.max_speed_y", .tiers = g },
    .{ .name = "machine.accel_control", .tiers = g },
    .{ .name = "machine.gcode_flavor", .tiers = g },
    .{ .name = "machine.outer_wall_accel", .tiers = g },
    .{ .name = "machine.inner_wall_accel", .tiers = g },
    .{ .name = "machine.skin_accel", .tiers = g },
    .{ .name = "machine.infill_accel", .tiers = g },
    .{ .name = "machine.travel_accel", .tiers = g },
    .{ .name = "machine.first_layer_accel", .tiers = g },
    .{ .name = "machine.extruder", .tiers = g },
    .{ .name = "machine.retract_length", .tiers = g },
    .{ .name = "machine.retract_speed", .tiers = g },
    .{ .name = "machine.retract_min_travel", .tiers = g },
    .{ .name = "machine.z_hop", .tiers = g },
    .{ .name = "machine.z_hop_only_crossing", .tiers = g },
    .{ .name = "machine.retract_wipe", .tiers = g },
    .{ .name = "machine.retract_wipe_distance", .tiers = g },
    .{ .name = "machine.retract_layer_change", .tiers = g },
    .{ .name = "machine.filament_change", .tiers = g },
    .{ .name = "machine.nozzles", .tiers = g },
    .{ .name = "machine.tool_numbers", .tiers = g },
    .{ .name = "machine.nozzle1_max_x", .tiers = g },
    .{ .name = "machine.nozzle1_max_height", .tiers = g },
    .{ .name = "machine.standby_delta", .tiers = g },
    .{ .name = "machine.preheat_time", .tiers = g },
    .{ .name = "machine.change_gcode", .tiers = g },
    .{ .name = "machine.change_time", .tiers = g },
    .{ .name = "machine.flush_volume", .tiers = g },
    .{ .name = "machine.nozzle.*", .tiers = g },
    .{ .name = "machine.thumbnails", .tiers = g },
    .{ .name = "machine.label_objects", .tiers = g },
    .{ .name = "machine.clearance_radius", .tiers = g },
    .{ .name = "machine.clearance_height", .tiers = g },
    .{ .name = "machine.start_gcode", .tiers = g },
    .{ .name = "machine.end_gcode", .tiers = g },
    .{ .name = "filament.name", .tiers = g },
    .{ .name = "filament.material", .tiers = g },
    .{ .name = "filament.color", .tiers = g },
    .{ .name = "filament.nozzle", .tiers = g },
    .{ .name = "filament.diameter", .tiers = g },
    .{ .name = "filament.density", .tiers = g },
    .{ .name = "filament.price_per_kg", .tiers = g },
    .{ .name = "filament.nozzle_temp", .tiers = g },
    .{ .name = "filament.first_layer_nozzle_temp", .tiers = g },
    .{ .name = "filament.bed_temp", .tiers = g },
    .{ .name = "filament.first_layer_bed_temp", .tiers = g },
    .{ .name = "filament.max_flow", .tiers = g },
    .{ .name = "filament.flow_ratio", .tiers = g },
    .{ .name = "filament.pressure_advance", .tiers = g },
    .{ .name = "filament.fan_speed", .tiers = g },
    .{ .name = "filament.fan_off_layers", .tiers = g },
    .{ .name = "filament.fan_ramp_layers", .tiers = g },
    .{ .name = "filament.fan_max_speed", .tiers = g },
    .{ .name = "filament.fan_boost_time", .tiers = g },
    .{ .name = "filament.min_layer_time", .tiers = g },
    .{ .name = "filament.min_speed", .tiers = g },
    .{ .name = "filament.cooling_mode", .tiers = g },
    .{ .name = "filament.standby_temp", .tiers = g },
    .{ .name = "filament.retract_ratio", .tiers = g },
    .{ .name = "filament.start_gcode", .tiers = g },
    .{ .name = "filament.end_gcode", .tiers = g },
    .{ .name = "project.line_width", .tiers = g },
    .{ .name = "project.first_layer_line_width", .tiers = g },
    .{ .name = "project.wall_count", .tiers = g },
    .{ .name = "project.wall_thickness", .tiers = g },
    .{ .name = "project.wall_order", .tiers = g },
    .{ .name = "project.alternate_extra_wall", .tiers = g },
    .{ .name = "project.overhang_wall_speed", .tiers = g },
    .{ .name = "project.overhang_wall_fan", .tiers = g },
    .{ .name = "project.overhang_wall_threshold", .tiers = g },
    .{ .name = "project.fuzzy_skin", .tiers = g },
    .{ .name = "project.fuzzy_skin_thickness", .tiers = g },
    .{ .name = "project.fuzzy_skin_point_distance", .tiers = g },
    .{ .name = "project.spiral_vase", .tiers = g },
    .{ .name = "project.thin_walls", .tiers = g },
    .{ .name = "project.seam", .tiers = g },
    .{ .name = "project.seam_corner", .tiers = g },
    .{ .name = "project.wall_generator", .tiers = g },
    .{ .name = "project.min_wall_line_width", .tiers = g },
    .{ .name = "project.min_feature_size", .tiers = g },
    .{ .name = "project.min_bead_width", .tiers = g },
    .{ .name = "project.wall_transition_length", .tiers = g },
    .{ .name = "project.wall_transition_angle", .tiers = g },
    .{ .name = "project.wall_transition_filter_distance", .tiers = g },
    .{ .name = "project.wall_distribution_count", .tiers = g },
    .{ .name = "project.top_thickness", .tiers = g },
    .{ .name = "project.bottom_thickness", .tiers = g },
    .{ .name = "project.skin_removal_width", .tiers = g },
    .{ .name = "project.skin_expand_distance", .tiers = g },
    .{ .name = "project.solid_infill_width", .tiers = g },
    .{ .name = "project.skin_pattern", .tiers = g },
    .{ .name = "project.angles_follow_part", .tiers = g },
    .{ .name = "project.skin_angle", .tiers = g },
    .{ .name = "project.skin_angle_step", .tiers = g },
    .{ .name = "project.skin_overlap", .tiers = g },
    .{ .name = "project.skin_link_length", .tiers = g },
    .{ .name = "project.bridges", .tiers = g },
    .{ .name = "project.bridge_speed", .tiers = g },
    .{ .name = "project.bridge_flow", .tiers = g },
    .{ .name = "project.bridge_fan", .tiers = g },
    .{ .name = "project.path_rules", .tiers = g },
    .{ .name = "project.gap_fill", .tiers = g },
    .{ .name = "project.infill_density", .tiers = g },
    .{ .name = "project.infill_pattern", .tiers = g },
    .{ .name = "project.infill_angle", .tiers = g },
    .{ .name = "project.infill_angles", .tiers = g },
    .{ .name = "project.infill_stack", .tiers = g },
    .{ .name = "project.infill_anchor", .tiers = g },
    .{ .name = "project.infill_flow", .tiers = g },
    .{ .name = "project.infill_connect", .tiers = g },
    .{ .name = "project.infill_ribs", .tiers = g },
    .{ .name = "project.lightning_angle", .tiers = g },
    .{ .name = "project.top_support_layers", .tiers = g },
    .{ .name = "project.top_support_density", .tiers = g },
    .{ .name = "project.infill_overlap", .tiers = g },
    .{ .name = "project.infill_layers", .tiers = g },
    .{ .name = "project.ironing", .tiers = g },
    .{ .name = "project.ironing_flow", .tiers = g },
    .{ .name = "project.ironing_spacing", .tiers = g },
    .{ .name = "project.ironing_inset", .tiers = g },
    .{ .name = "project.ironing_speed", .tiers = g },
    .{ .name = "project.slope_smoothing", .tiers = g },
    .{ .name = "project.slope_smoothing_min_width", .tiers = g },
    .{ .name = "project.slope_smoothing_max_width", .tiers = g },
    .{ .name = "project.slope_smoothing_flow", .tiers = g },
    .{ .name = "project.slope_smoothing_speed", .tiers = g },
    .{ .name = "project.slope_ironing", .tiers = g },
    .{ .name = "project.slope_ironing_passes", .tiers = g },
    .{ .name = "project.slope_ironing_flow", .tiers = g },
    .{ .name = "project.slope_ironing_speed", .tiers = g },
    .{ .name = "project.outer_wall_speed", .tiers = g },
    .{ .name = "project.inner_wall_speed", .tiers = g },
    .{ .name = "project.skin_speed", .tiers = g },
    .{ .name = "project.infill_speed", .tiers = g },
    .{ .name = "project.support_speed", .tiers = g },
    .{ .name = "project.support_interface_speed", .tiers = g },
    .{ .name = "project.first_layer_speed", .tiers = g },
    .{ .name = "project.slow_layers", .tiers = g },
    .{ .name = "project.combing_mode", .tiers = g },
    .{ .name = "project.combing_max_distance", .tiers = g },
    .{ .name = "project.outer_wall_wipe", .tiers = g },
    .{ .name = "project.coasting_volume", .tiers = g },
    .{ .name = "project.coasting_speed", .tiers = g },
    .{ .name = "project.support", .tiers = g },
    .{ .name = "project.support_style", .tiers = g },
    .{ .name = "project.support_tree_angle", .tiers = g },
    .{ .name = "project.support_tree_spacing", .tiers = g },
    .{ .name = "project.support_tree_tip", .tiers = g },
    .{ .name = "project.support_angle", .tiers = g },
    .{ .name = "project.support_min_ledge", .tiers = g },
    .{ .name = "project.support_density", .tiers = g },
    .{ .name = "project.support_xy_gap", .tiers = g },
    .{ .name = "project.support_z_gap_layers", .tiers = g },
    .{ .name = "project.support_interface_layers", .tiers = g },
    .{ .name = "project.support_interface_density", .tiers = g },
    .{ .name = "project.support_interface_pattern", .tiers = g },
    .{ .name = "project.skirt_loops", .tiers = g },
    .{ .name = "project.skirt_distance", .tiers = g },
    .{ .name = "project.skirt_layers", .tiers = g },
    .{ .name = "project.brim_width", .tiers = g },
    .{ .name = "project.brim_location", .tiers = g },
    .{ .name = "project.placement", .tiers = g },
    .{ .name = "project.print_sequence", .tiers = g },
    .{ .name = "project.filament", .tiers = g },
    .{ .name = "project.support_filament", .tiers = g },
    .{ .name = "project.support_interface_filament", .tiers = g },
    .{ .name = "project.infill_filament", .tiers = g },
    .{ .name = "project.prime_tower", .tiers = g },
    .{ .name = "project.prime_tower_split", .tiers = g },
    .{ .name = "project.prime_tower_width", .tiers = g },
    .{ .name = "project.prime_tower_brim", .tiers = g },
    .{ .name = "project.prime_tower_wall_loops", .tiers = g },
    .{ .name = "project.prime_tower_rib_wall", .tiers = g },
    .{ .name = "project.prime_tower_rib_width", .tiers = g },
    .{ .name = "project.prime_tower_extra_rib_length", .tiers = g },
    .{ .name = "project.prime_tower_fillet_wall", .tiers = g },
    .{ .name = "project.prime_tower_x", .tiers = g },
    .{ .name = "project.prime_tower_y", .tiers = g },
    .{ .name = "project.flush_multiplier", .tiers = g },
    .{ .name = "project.flush_into_hidden", .tiers = g },
    .{ .name = "project.paint_anchor_depth", .tiers = g },
    .{ .name = "project.paint_anchor_shape", .tiers = g },
    .{ .name = "engine.threads", .tiers = all },
    .{ .name = "engine.draft_slices", .tiers = all },
    .{ .name = "engine.auto_simulate", .tiers = all },
    .{ .name = "engine.slice_form", .tiers = all },
    .{ .name = "engine.verify_slices", .tiers = all },
    .{ .name = "engine.form_budget_mb", .tiers = all },
    .{ .name = "engine.job_name", .tiers = g },
};

/// The setting of a field name, or of a name with ".*".
fn stem(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".*")) name[0 .. name.len - 2] else name;
}

/// True if the setting `name` ("group.field") is a field of `Settings`.
fn isField(comptime name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(Settings).@"struct".fields) |gr| {
        inline for (@typeInfo(gr.type).@"struct".fields) |f| {
            if (std.mem.eql(u8, gr.name ++ "." ++ f.name, name)) return true;
        }
    }
    return false;
}

comptime {
    @setEvalBranchQuota(10_000_000);
    for (skips_table, 0..) |s, i| {
        if (!isField(stem(s.name))) @compileError("settings_tiers: no setting " ++ s.name);
        for (skips_table[0..i]) |o| {
            if (std.mem.eql(u8, stem(o.name), stem(s.name))) @compileError("settings_tiers: two lines for " ++ s.name);
        }
    }
}

/// The gates: a gate says that a group of settings has no effect while a
/// condition on the settings is false. Then the key of the regions and
/// the paths tiers reads the default of each setting of the group. The
/// plate job closes the gates only with engine.slice_form on. The text
/// tier reads all settings.
///
/// The gate of the nozzles: `machine.nozzle.K.*` for each K at or over
/// `machine.nozzles`. Proof: the plan and the paths read a nozzle only
/// through `Machine.nozzleValue` and `Machine.nozzleOffset` (the index
/// is a slot nozzle through `Machine.nozzleIndex` and
/// `SlotNozzles.nozzleOf`), and each of them gives the default for
/// K >= nozzles. A search of src/ found no other read of
/// `machine.nozzle[k]` but the setter and the writers of profiles.
pub fn nozzleGate(comptime name: []const u8, comptime tier: Tier) bool {
    return std.mem.eql(u8, name, "machine.nozzle") and (tier == .regions or tier == .paths);
}

/// The nozzles that a gate of the nozzles keeps: those that the machine
/// has (at least 1).
pub fn openNozzles(s: *const Settings) usize {
    return @min(@max(s.machine.nozzles, 1), s.machine.nozzle.len);
}

/// The tiers that skip a setting, as a mask (bit k: tier k).
fn maskOf(comptime name: []const u8) u8 {
    @setEvalBranchQuota(1_000_000);
    var m: u8 = 0;
    for (skips_table) |s| if (std.mem.eql(u8, stem(s.name), name)) {
        for (s.tiers) |t| m |= @as(u8, 1) << @intFromEnum(t);
    };
    if (settings_mod.isPatchSetting(name)) m |= (@as(u8, 1) << @intFromEnum(Tier.regions)) | (@as(u8, 1) << @intFromEnum(Tier.paths));
    return m;
}

/// True if the key of `tier` does not read the setting `name`, a field
/// of `Settings` ("project.wall_count").
pub fn skips(comptime name: []const u8, comptime tier: Tier) bool {
    return comptime (maskOf(name) >> @intFromEnum(tier)) & 1 == 1;
}

/// `skips` for a name at run time: a setting of a part or of an override
/// ("project.infill_density"), or a part of a field
/// ("machine.nozzle.2.diameter"). A name that is no field is read by each
/// tier.
pub fn skipsName(name_in: []const u8, tier: Tier) bool {
    const name = settings_mod.currentName(name_in);
    inline for (@typeInfo(Settings).@"struct".fields) |gr| {
        inline for (@typeInfo(gr.type).@"struct".fields) |f| {
            const full = gr.name ++ "." ++ f.name;
            if (std.mem.eql(u8, full, name) or (std.mem.startsWith(u8, name, full ++ ".") and comptime maskOf(full) != 0)) {
                return switch (tier) {
                    inline else => |t| skips(full, t),
                };
            }
        }
    }
    return false;
}

test "settings_tiers: a patch setting is skipped by the paths tier" {
    try std.testing.expect(skipsName("project.outer_wall_speed", .paths));
    try std.testing.expect(!skipsName("project.outer_wall_speed", .text));
    try std.testing.expect(!skipsName("project.wall_count", .paths));
    try std.testing.expect(skipsName("project.wall_count", .geometry));
    try std.testing.expect(!skipsName("project.layer_height", .geometry));
    try std.testing.expect(skipsName("machine.nozzle.2.diameter", .geometry));
    try std.testing.expect(!skipsName("machine.nozzle.2.diameter", .paths));
    try std.testing.expect(!skipsName("no.such_setting", .geometry));
}
