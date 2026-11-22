//! The Speed group of the settings panel: the options that change the
//! time of a slice, in one list, with the measured gain and cost of each
//! (docs/internals/performance.md, a 3DBenchy with the default settings).
//!
//! The "Faster slicing" switch sets the options of the list that have a
//! faster value (`Option.faster`): together about 28 % less CPU for a
//! 3DBenchy (1580 ms to 1140 ms). Off puts back their built-in defaults,
//! which give the exact slice. The switch has no value of its own: its
//! state comes from the values of its options. So a change of one option
//! shows the switch as `custom`, and a project that has the faster values
//! shows it as on.
//!
//! The draft slice of an edit (`engine.draft_slices`) is in the list, but
//! the switch does not change it: a draft never goes to the G-code.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const Settings = zs.Settings;
const writeSettingOf = @import("../app.zig").App.writeSettingOf;
const testing = std.testing;

pub const Option = struct {
    /// The setting ("group.name").
    name: [:0]const u8,
    /// The value with Faster slicing on, or "" if the switch does not set
    /// this option.
    faster: [:0]const u8 = "",
    /// The option changes the G-code. A shell says so in the row.
    gcode: bool,
    /// One line: the gain and the cost, from the measured numbers.
    note: [:0]const u8,
};

/// The options in the order of the panel: the options of the switch first.
pub const options = [_]Option{
    .{
        .name = "project.fast_offsets",
        .faster = "true",
        .gcode = true,
        .note = "About 11 % faster slices. The outer walls stay within 1.4 µm. Some skin and fill lines move where a thin piece is at a threshold.",
    },
    .{
        .name = "project.resolution",
        .faster = "0.01",
        .gcode = true,
        .note = "0.01 mm: about 19 % faster slices of a fine mesh, and 19 % less G-code. The outer walls move up to 10 µm (99 % of the points).",
    },
    .{
        .name = "engine.draft_slices",
        .gcode = false,
        .note = "A draft shows an edit in a third of the time. The exact slice follows. A draft never goes to the G-code.",
    },
    .{
        .name = "engine.threads",
        .gcode = false,
        .note = "0: one thread for each CPU but one, the fastest. The G-code is the same with each count.",
    },
    .{
        .name = "project.gap_fill",
        .gcode = true,
        .note = "Off: about 30 % faster slices. The narrow gaps between the walls and the skin stay empty.",
    },
    .{
        .name = "project.wall_generator",
        .gcode = true,
        .note = "classic is the faster method. arachne: about 16 % more CPU for each slice, for walls with a width that follows the part.",
    },
};

/// The help of the Faster slicing switch, for the row at the top of the
/// Speed section.
pub const switch_note: [:0]const u8 = "On: fast offsets and an outline tolerance of 0.01 mm, together about 28 % faster slices. The outer walls move up to 10 µm, and some thin skin and fill lines change. Off: the exact slice. Custom: one of these options has another value.";

pub const State = enum(c_int) { off = 0, on = 1, custom = 2 };

/// The option of `name`, or null.
pub fn find(name: []const u8) ?Option {
    for (options) |o| if (std.mem.eql(u8, o.name, name)) return o;
    return null;
}

/// True if the value of `name` in `a` is the value of `name` in `b`.
fn same(a: Settings, b: Settings, name: []const u8) bool {
    var x: [64]u8 = undefined;
    var y: [64]u8 = undefined;
    var wx: std.Io.Writer = .fixed(&x);
    var wy: std.Io.Writer = .fixed(&y);
    writeSettingOf(a, name, &wx) catch return false;
    writeSettingOf(b, name, &wy) catch return false;
    return std.mem.eql(u8, wx.buffered(), wy.buffered());
}

/// The settings with the options of the switch at their faster values
/// (on) or at their built-in defaults (off). The other settings stay.
pub fn applied(s: Settings, on: bool) Settings {
    var out = s;
    const defaults: Settings = .{};
    for (options) |o| {
        if (o.faster.len == 0) continue;
        if (on) {
            out.set(o.name, o.faster) catch unreachable;
        } else {
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeSettingOf(defaults, o.name, &w) catch unreachable;
            out.set(o.name, w.buffered()) catch unreachable;
        }
    }
    return out;
}

/// The state of the switch: off if each of its options has its default,
/// on if each has its faster value, and custom otherwise.
pub fn state(s: Settings) State {
    const off = applied(s, false);
    const on = applied(s, true);
    var all_off = true;
    var all_on = true;
    for (options) |o| {
        if (o.faster.len == 0) continue;
        if (!same(s, off, o.name)) all_off = false;
        if (!same(s, on, o.name)) all_on = false;
    }
    if (all_off) return .off;
    if (all_on) return .on;
    return .custom;
}

test "speed: each option is a setting, and its faster value is valid" {
    for (options) |o| {
        var s: Settings = .{};
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeSettingOf(s, o.name, &w);
        if (o.faster.len > 0) try s.set(o.name, o.faster);
        try testing.expect(o.note.len > 0);
    }
}

test "speed: the switch sets and clears its options, and one change is custom" {
    var s: Settings = .{};
    try testing.expectEqual(State.off, state(s));
    s = applied(s, true);
    try testing.expectEqual(State.on, state(s));
    try testing.expect(s.project.fast_offsets);
    try testing.expectEqual(@as(f64, 0.01), s.project.resolution);
    // The options outside the switch keep their values.
    try testing.expect(s.engine.draft_slices);
    try testing.expect(s.project.gap_fill);
    try s.set("project.resolution", "0.02");
    try testing.expectEqual(State.custom, state(s));
    s = applied(s, false);
    try testing.expectEqual(State.off, state(s));
    try testing.expect(!s.project.fast_offsets);
    try testing.expectEqual(@as(f64, 0.005), s.project.resolution);
    // A change of an option outside the switch keeps its state.
    try s.set("project.gap_fill", "false");
    try testing.expectEqual(State.off, state(s));
}

test "speed: the old name engine.resolution sets project.resolution" {
    var s: Settings = .{};
    try s.set("engine.resolution", "0.01");
    try testing.expectEqual(@as(f64, 0.01), s.project.resolution);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 1), try zs.profile.movedKeys(arena.allocator(), .project, "[engine]\nresolution = 0.01\n"));
}
