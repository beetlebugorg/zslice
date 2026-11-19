//! The filaments of a plate, and the filament changes between them.
//!
//! A plate has a list of filaments: slot 1, 2, and on. Slot 1 is the
//! filament of the settings (`Settings.filament`). A part, or a range of
//! layers, prints with the slot of `project.filament`. The G-code changes
//! the filament where the slot changes (see gcode.zig):
//!
//! - `pause` (one filament path): the print pauses, and the user changes
//!   the filament. Marlin, RepRapFirmware, and Repetier-Firmware pause
//!   with M600 (the filament change of each firmware). Klipper has no
//!   M600; it pauses with PAUSE (the pause_resume module).
//! - `tool` (a unit that feeds many filaments: a Bambu Lab AMS, a Prusa
//!   MMU): a tool change, Tn for slot n + 1. The nozzle then flushes the
//!   old color out. A Bambu Lab printer flushes into its waste chute, in
//!   the change G-code of its profile (`machine.change_gcode`).
//!
//! The flush volume of a change. Bambu Studio finds a volume for each
//! pair of colors: a change from a dark color to a light color needs more
//! plastic than a change from a light color to a dark color. zslice uses
//! its own simple rule: the base volume (`machine.flush_volume`) times
//!
//!     1 + 3 * max(0, L(to) - L(from)) + |to - from|
//!
//! L is the luma of a color (0 to 1), and |to - from| is the distance of
//! the two colors in RGB (0 to 1). A change to the same color flushes the
//! base volume; black to white flushes about 5 times more. The project
//! multiplier (`project.flush_multiplier`) scales the result, as the
//! multiplier of Bambu Studio does.
//!
//! References (see REFERENCES.md): the M600 command of Marlin, the PAUSE
//! command of Klipper, and the flushing volumes of Bambu Studio (Bambu Lab
//! wiki, "Reduce wasting during filament change").
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const settings_mod = @import("settings.zig");
const Filament = settings_mod.Filament;

/// The most filaments of a plate (the limit of `project.filament`).
pub const max_slots = 16;

/// A "#rrggbb" color, or null.
pub fn parseColor(text: []const u8) ?[3]u8 {
    if (text.len != 7 or text[0] != '#') return null;
    var out: [3]u8 = undefined;
    for (0..3) |k| out[k] = std.fmt.parseInt(u8, text[1 + 2 * k .. 3 + 2 * k], 16) catch return null;
    return out;
}

/// The luma of a color, from 0 (black) to 1 (white). The weights of
/// ITU-R BT.709.
pub fn luma(c: [3]u8) f64 {
    return (0.2126 * @as(f64, @floatFromInt(c[0])) + 0.7152 * @as(f64, @floatFromInt(c[1])) + 0.0722 * @as(f64, @floatFromInt(c[2]))) / 255;
}

/// The plastic (mm³) that the nozzle flushes in a change from the color
/// `from` to the color `to` (see the header).
pub fn flushVolume(from: []const u8, to: []const u8, base: f64, multiplier: f64) f64 {
    const grey = [3]u8{ 0x80, 0x80, 0x80 };
    const a = parseColor(from) orelse grey;
    const b = parseColor(to) orelse grey;
    var d2: f64 = 0;
    for (0..3) |k| {
        const d = (@as(f64, @floatFromInt(b[k])) - @as(f64, @floatFromInt(a[k]))) / 255;
        d2 += d * d;
    }
    const dist = @sqrt(d2 / 3);
    const up = @max(0, luma(b) - luma(a));
    return base * multiplier * (1 + 3 * up + dist);
}

/// The slot (from 0) of a slot number of `project.filament` (from 1), in
/// a plate of `count` filaments. A number past the list is slot 0: the
/// filament of the settings.
pub fn slotOf(number: u32, count: usize) u32 {
    if (number == 0 or number > count) return 0;
    return number - 1;
}

const testing = std.testing;

test "flush volume: dark to light needs more than light to dark" {
    const black_white = flushVolume("#000000", "#ffffff", 100, 1);
    const white_black = flushVolume("#ffffff", "#000000", 100, 1);
    try testing.expect(black_white > 2 * white_black);
    try testing.expectApproxEqAbs(@as(f64, 500), black_white, 1);
    try testing.expectApproxEqAbs(@as(f64, 100), flushVolume("#ff0000", "#ff0000", 100, 1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50), flushVolume("#ff0000", "#ff0000", 100, 0.5), 1e-9);
}

test "slot of a filament number" {
    try testing.expectEqual(@as(u32, 0), slotOf(1, 3));
    try testing.expectEqual(@as(u32, 2), slotOf(3, 3));
    try testing.expectEqual(@as(u32, 0), slotOf(4, 3));
}
