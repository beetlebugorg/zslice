//! What can close a gap of a layer (see gaps.zig): the settings to change,
//! first the ones that act on the beads around the gap, with the value to
//! try and why. The rules come from the features next to the gap and from
//! its width.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const Feature = zs.settings.Feature;
const Settings = zs.Settings;

/// A setting to change, the value to try (as text), and why.
pub const Step = struct {
    name: []const u8,
    value: []const u8,
    why: []const u8,
};

fn has(features: u32, f: Feature) bool {
    return features & (@as(u32, 1) << @intCast(@intFromEnum(f))) != 0;
}

/// The steps for gap `g` with the settings `s` of its layer, the best
/// first. The strings are in `arena`.
pub fn steps(arena: std.mem.Allocator, g: zs.gaps.Gap, s: Settings) std.mem.Allocator.Error![]const Step {
    var out: std.ArrayList(Step) = .empty;
    const p = s.project;
    const wall = has(g.features, .outer_wall) or has(g.features, .inner_wall);
    const skin = has(g.features, .skin);
    const infill = has(g.features, .infill);
    const lw = if (p.line_width > 0) p.line_width else s.machine.nozzle_diameter * 1.1;
    if (skin and wall) {
        // The ends of the skin lines stop short of the wall.
        const more = @min(p.skin_overlap + 0.15, 0.5);
        try out.append(arena, .{
            .name = "project.skin_overlap",
            .value = try std.fmt.allocPrint(arena, "{d:.2}", .{more}),
            .why = try std.fmt.allocPrint(arena, "The skin lines end before the wall. More overlap ({d:.0} % of a line, now {d:.0} %) runs them into the wall.", .{ more * 100, p.skin_overlap * 100 }),
        });
    }
    if (wall and (g.width < lw * 1.5 or (!skin and !infill))) {
        // A space between walls that is narrower than a line, or a part
        // of the walls with no fill in it.
        if (p.wall_generator == .classic) try out.append(arena, .{
            .name = "project.wall_generator",
            .value = "arachne",
            .why = "Arachne walls change their width to fill the space between them, with no gap in the middle.",
        });
        if (!p.thin_walls and p.wall_generator == .classic) try out.append(arena, .{
            .name = "project.thin_walls",
            .value = "true",
            .why = "Thin walls print a narrow loop in a part that is thinner than one line.",
        });
        const n = p.wall_count + 1;
        try out.append(arena, .{
            .name = "project.wall_count",
            .value = try std.fmt.allocPrint(arena, "{d}", .{n}),
            .why = try std.fmt.allocPrint(arena, "One more wall ({d}) fills the space inside the walls, where it is wide enough for a line.", .{n}),
        });
    }
    if (skin and !wall) {
        // Between skin lines: the lines are too far apart or too thin.
        try out.append(arena, .{
            .name = "filament.flow_ratio",
            .value = try std.fmt.allocPrint(arena, "{d:.2}", .{s.filament.flow_ratio * 1.05}),
            .why = "The skin lines are too thin to touch. 5 % more flow makes them wider. Check the flow of the filament first.",
        });
        try out.append(arena, .{
            .name = "project.skin_pattern",
            .value = if (p.skin_pattern == .concentric) "lines" else "concentric",
            .why = "Another skin pattern puts the lines in other places.",
        });
    }
    if (infill and wall) {
        const more = @min(p.infill_overlap + 0.15, 0.6);
        try out.append(arena, .{
            .name = "project.infill_overlap",
            .value = try std.fmt.allocPrint(arena, "{d:.2}", .{more}),
            .why = "The infill lines end before the wall. More overlap runs them into it.",
        });
    }
    if (g.width >= lw * 0.8 and p.wall_generator == .classic and !has(g.features, .skin) and !infill and wall) {
        // Already listed above.
    } else if (p.line_width > 0 and g.width < lw * 0.6) {
        try out.append(arena, .{
            .name = "project.line_width",
            .value = try std.fmt.allocPrint(arena, "{d:.2}", .{lw + g.width / 2}),
            .why = "Wider lines cover more, also the narrow gaps between them.",
        });
    }
    if (out.items.len == 0) try out.append(arena, .{
        .name = "project.wall_generator",
        .value = if (p.wall_generator == .classic) "arachne" else "classic",
        .why = "Another wall generator fills the area in another way.",
    });
    return out.items;
}

test "gap advice: skin ends at a wall give more skin overlap first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const g: zs.gaps.Gap = .{ .area = 0.1, .x = 0, .y = 0, .width = 0.25, .features = (1 << @intFromEnum(Feature.skin)) | (1 << @intFromEnum(Feature.inner_wall)), .at_edge = false, .run_start = 0, .run_len = 0 };
    const st = try steps(arena_state.allocator(), g, .{});
    try std.testing.expect(st.len >= 2);
    try std.testing.expectEqualStrings("project.skin_overlap", st[0].name);
    try std.testing.expectEqualStrings("0.30", st[0].value);
    // Each value is valid for its setting.
    for (st) |step| {
        var s: Settings = .{};
        try s.set(step.name, step.value);
    }
}
