//! The settings that matter most for a selected line, for the line card of
//! each app (zs_app_inspect_picks). The order:
//!
//! 1. Why the line is slow: a short layer (the minimum layer time, then the
//!    fan), or short segments (the acceleration of its feature).
//! 2. On the first layer: the first layer speed and height.
//! 3. A setting that changes the line and that the user changed: for some
//!    layers (an override), or for this print or this part.
//! 4. The main settings of its feature.
//! 5. The other settings that change the line (inspect `settings`).
//!
//! Each pick has a reason ("" for 4 and 5). No setting comes twice, and
//! only known settings come. The names and the reasons are static strings.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const settings_mod = @import("../settings.zig");
const setting_text = @import("setting_text.zig");

pub const Pick = struct { name: [:0]const u8, why: [:0]const u8 };

/// The sentence of a slow reason of an inspection, or "".
pub fn slowText(reason: u8) [:0]const u8 {
    return switch (reason) {
        1 => "Slow: the layer is short, so it prints slower to cool.",
        2 => "Slow: the segments are short, so the head does not reach full speed.",
        else => "",
    };
}

/// The main settings of each feature (settings.Feature), best first.
const by_feature = [_][]const [:0]const u8{
    &.{ "project.outer_wall_speed", "project.wall_count", "machine.outer_wall_accel", "project.seam" },
    &.{ "project.wall_count", "project.inner_wall_speed", "project.wall_thickness", "project.infill_overlap" },
    &.{ "project.top_thickness", "project.bottom_thickness", "project.solid_infill_width", "project.skin_pattern", "project.skin_speed" },
    &.{ "project.infill_density", "project.infill_pattern", "project.infill_speed", "project.infill_angle" },
    &.{ "project.ironing", "project.ironing_flow", "project.ironing_speed", "project.ironing_spacing" },
    &.{ "project.brim_width", "project.skirt_loops", "project.skirt_distance", "project.skirt_layers" },
    &.{ "project.support", "project.support_style", "project.support_density", "project.support_xy_gap" },
    &.{ "project.support_interface_layers", "project.support_z_gap_layers", "project.support_interface_density", "project.support_xy_gap" },
    &.{ "project.slope_smoothing", "project.slope_smoothing_flow", "project.slope_smoothing_speed", "project.slope_smoothing_max_width" },
    &.{ "project.slope_ironing", "project.slope_ironing_passes", "project.slope_ironing_flow", "project.slope_ironing_speed" },
    &.{ "project.bridge_speed", "project.bridge_flow", "project.bridge_fan", "project.bridges" },
};

/// The acceleration of the features that have one.
const accel = [_][:0]const u8{ "machine.outer_wall_accel", "machine.inner_wall_accel", "machine.skin_accel", "machine.infill_accel" };

/// What the picks need to know of the line and of the user's changes.
pub const Line = struct {
    feature: usize,
    layer: usize,
    slow_reason: u8,
    /// The settings that change the line: names, one a line; lines that
    /// start with "# " are section titles.
    settings: []const u8,
    /// ctx for the two lookups.
    ctx: *const anyopaque,
    /// 1: changed for some layers at the line; 2: changed for this print
    /// or this part; 0: not changed.
    changed: *const fn (ctx: *const anyopaque, name: []const u8) u8,
};

/// The picks of a line, at most out.len. Returns the count.
pub fn picks(line: Line, out: []Pick) usize {
    var n: usize = 0;
    const add = struct {
        fn f(o: []Pick, count: *usize, name: []const u8, why: [:0]const u8) void {
            if (count.* >= o.len) return;
            const info = setting_text.find(name) orelse return;
            for (o[0..count.*]) |p| if (std.mem.eql(u8, p.name, name)) return;
            o[count.*] = .{ .name = info.name, .why = why };
            count.* += 1;
        }
    }.f;
    if (line.slow_reason == 1) {
        add(out, &n, "filament.min_layer_time", "Why it is slow: the layer is short");
        add(out, &n, "filament.fan_speed", "More fan cools a short layer");
    } else if (line.slow_reason == 2) {
        add(out, &n, if (line.feature < accel.len) accel[line.feature] else "machine.max_accel", "Why it is slow: short segments");
    }
    if (line.layer == 0) {
        add(out, &n, "project.first_layer_speed", "The first layer");
        add(out, &n, "project.first_layer_height", "The first layer");
    }
    var it = std.mem.tokenizeScalar(u8, line.settings, '\n');
    while (it.next()) |name| {
        if (std.mem.startsWith(u8, name, "# ")) continue;
        switch (line.changed(line.ctx, name)) {
            1 => add(out, &n, name, "You changed it for some layers"),
            2 => add(out, &n, name, "You changed it"),
            else => {},
        }
    }
    if (line.feature < by_feature.len) for (by_feature[line.feature]) |name| add(out, &n, name, "");
    it = std.mem.tokenizeScalar(u8, line.settings, '\n');
    while (it.next()) |name| {
        if (std.mem.startsWith(u8, name, "# ")) continue;
        add(out, &n, name, "");
    }
    return n;
}

const testing = std.testing;

fn noChange(_: *const anyopaque, _: []const u8) u8 {
    return 0;
}

fn infillChanged(_: *const anyopaque, name: []const u8) u8 {
    return if (std.mem.eql(u8, name, "project.infill_speed")) 2 else 0;
}

test "picks: a slow first layer line of infill" {
    var out: [4]Pick = undefined;
    const ctx: u8 = 0;
    const n = picks(.{
        .feature = @intFromEnum(settings_mod.Feature.infill),
        .layer = 0,
        .slow_reason = 1,
        .settings = "# Speed\nproject.infill_speed\nproject.infill_density",
        .ctx = &ctx,
        .changed = noChange,
    }, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("filament.min_layer_time", out[0].name);
    try testing.expectEqualStrings("filament.fan_speed", out[1].name);
    try testing.expectEqualStrings("project.first_layer_speed", out[2].name);
    try testing.expectEqualStrings("The first layer", out[3].why);
}

test "picks: a changed setting comes before the main settings" {
    var out: [3]Pick = undefined;
    const ctx: u8 = 0;
    const n = picks(.{
        .feature = @intFromEnum(settings_mod.Feature.infill),
        .layer = 5,
        .slow_reason = 0,
        .settings = "project.infill_speed\nproject.infill_density",
        .ctx = &ctx,
        .changed = infillChanged,
    }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("project.infill_speed", out[0].name);
    try testing.expectEqualStrings("You changed it", out[0].why);
    try testing.expectEqualStrings("project.infill_density", out[1].name);
    try testing.expectEqualStrings("", out[1].why);
}
