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
//! References (see docs/references/): the M600 command of Marlin, the PAUSE
//! command of Klipper, and the flushing volumes of Bambu Studio (Bambu Lab
//! wiki, "Reduce wasting during filament change").
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const settings_mod = @import("settings.zig");
const Filament = settings_mod.Filament;

/// The most filaments of a plate (the limit of `project.filament`).
pub const max_slots = 16;

/// The family of a material for the prime towers: materials of one family
/// bond to each other, so they can share a tower. The letters at the start
/// of the material in capitals ("PLA" for "PLA-CF" and "pla+"), with ABS
/// and ASA in one family, and PCTG with PETG. `buf` holds the name.
pub fn family(material: []const u8, buf: *[8]u8) []const u8 {
    var n: usize = 0;
    for (material) |c| {
        if (!std.ascii.isAlphabetic(c) or n == buf.len) break;
        buf[n] = std.ascii.toUpper(c);
        n += 1;
    }
    const name = buf[0..n];
    if (std.mem.eql(u8, name, "ASA")) return "ABS";
    if (std.mem.eql(u8, name, "PCTG") or std.mem.eql(u8, name, "PET")) return "PETG";
    if (n == 0) return "PLA";
    return name;
}

test "family: the materials that bond share a family" {
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("PLA", family("PLA-CF", &a));
    try std.testing.expectEqualStrings("PLA", family("pla+", &a));
    try std.testing.expectEqualStrings(family("ASA", &a), family("ABS", &b));
    try std.testing.expectEqualStrings(family("PCTG", &a), family("PETG-HF", &b));
    try std.testing.expect(!std.mem.eql(u8, family("PLA", &a), family("PETG", &b)));
}

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
/// The slot of the filament of a path of `feature` with the settings `p`
/// (a Project): the support filament for support, the interface filament
/// for the support interface, else the filament of the part. Count: the
/// filaments of the plate.
/// The sparse infill of a layer is of the infill filament, but with
/// combined infill (`infill_layers` above 1) only the tall beads are: see
/// `slotOfPath`.
pub fn pathSlot(feature: @import("settings.zig").Feature, p: anytype, count: usize) u32 {
    return lineSlot(feature, false, p, count);
}

/// The slot of the filament of a path (a layer.Path): as `pathSlot`, with
/// the tall beads of combined infill (a path with its own height), and
/// the root of a painted feature (a hidden path), which keeps the
/// filament of the part.
pub fn slotOfPath(path: anytype, p: anytype, count: usize) u32 {
    if (path.hidden) return if (count < 2) 0 else slotOf(p.filament, count);
    return lineSlot(path.feature, path.height > 0, p, count);
}

/// The slot of a line of `feature`; `tall`: a tall bead of combined
/// infill. The infill filament (`infill_filament`) prints the sparse
/// infill; with combined infill only the tall beads, so the nozzle
/// changes once for each group of layers.
pub fn lineSlot(feature: @import("settings.zig").Feature, tall: bool, p: anytype, count: usize) u32 {
    if (count < 2) return 0;
    const part = slotOf(p.filament, count);
    const support = if (p.support_filament > 0) slotOf(p.support_filament, count) else part;
    return switch (feature) {
        .support => support,
        .support_interface => if (p.support_interface_filament > 0) slotOf(p.support_interface_filament, count) else support,
        .infill => if (p.infill_filament > 0 and (tall or p.infill_layers <= 1)) slotOf(p.infill_filament, count) else part,
        else => part,
    };
}

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

/// The cost of a filament change in the flush planner (see `bestOrder`):
/// the seconds of the change and of its flush, then the count of
/// changes for a tie.
pub const Cost = struct {
    seconds: f64 = 0,
    changes: u32 = 0,

    pub fn add(a: Cost, b: Cost) Cost {
        return .{ .seconds = a.seconds + b.seconds, .changes = a.changes + b.changes };
    }

    pub fn less(a: Cost, b: Cost) bool {
        if (a.seconds != b.seconds) return a.seconds < b.seconds;
        return a.changes < b.changes;
    }
};

/// The most filaments of a layer that `bestOrder` searches. A layer with
/// more keeps the order of the rule.
pub const max_search = 8;

/// The flush planner: the order of the filaments of one layer with the
/// least cost, into `out`. The nozzle starts with filament `entry`.
/// `rule`: the filaments of the layer in the order of the rule (up or
/// down by slot), and `cost(ctx, a, b)` the cost of a change from a to b.
/// The search tries each order (at most 8! = 40320), in the order of the
/// rule first, and keeps an order only if it costs less than the best
/// one before it: of two orders of one cost, the one nearer to the rule
/// wins. A layer of more than `max_search` filaments takes the order of
/// the rule, with `entry` first if it is on the layer.
pub fn bestOrder(entry: u32, rule: []const u32, ctx: anytype, out: []u32) void {
    const n = rule.len;
    @memcpy(out[0..n], rule);
    if (n < 2) return;
    if (n > max_search) {
        if (std.mem.indexOfScalar(u32, out[0..n], entry)) |k| {
            std.mem.copyBackwards(u32, out[1 .. k + 1], out[0..k]);
            out[0] = entry;
        }
        return;
    }
    const Search = struct {
        rule: []const u32,
        ctx: @TypeOf(ctx),
        best: Cost = .{ .seconds = std.math.inf(f64), .changes = std.math.maxInt(u32) },
        best_order: [max_search]u32 = undefined,
        now: [max_search]u32 = undefined,
        used: [max_search]bool = @splat(false),

        fn step(s: *@This(), depth: usize, last: u32, cost: Cost) void {
            // A part of an order that costs as much as the best one cannot
            // win: no change has a negative cost.
            if (!cost.less(s.best)) return;
            if (depth == s.rule.len) {
                s.best = cost;
                @memcpy(s.best_order[0..depth], s.now[0..depth]);
                return;
            }
            for (s.rule, 0..) |t, k| {
                if (s.used[k]) continue;
                s.used[k] = true;
                s.now[depth] = t;
                const c = if (t == last) Cost{} else s.ctx.cost(last, t);
                s.step(depth + 1, t, cost.add(c));
                s.used[k] = false;
            }
        }
    };
    var s: Search = .{ .rule = rule, .ctx = ctx };
    s.step(0, entry, .{});
    @memcpy(out[0..n], s.best_order[0..n]);
}

test "flush planner: the dark filament goes before the light one" {
    // Filaments 0 (black), 1 (white), 2 (red). From black, the order up
    // by slot flushes black to white, then white to red. Black, red,
    // white flushes less.
    const colors = [_][]const u8{ "#000000", "#ffffff", "#ff0000" };
    const Ctx = struct {
        fn cost(_: @This(), a: u32, b: u32) Cost {
            return .{ .seconds = flushVolume(colors[a], colors[b], 100, 1), .changes = 1 };
        }
    };
    var out: [3]u32 = undefined;
    bestOrder(0, &.{ 0, 1, 2 }, Ctx{}, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, &out);
    // The filament in the nozzle prints first: a change back costs more.
    bestOrder(1, &.{ 0, 1, 2 }, Ctx{}, &out);
    try testing.expectEqual(@as(u32, 1), out[0]);
}

test "flush planner: equal costs keep the order of the rule" {
    const Ctx = struct {
        fn cost(_: @This(), _: u32, _: u32) Cost {
            return .{ .changes = 1 };
        }
    };
    var out: [4]u32 = undefined;
    bestOrder(9, &.{ 3, 2, 1, 0 }, Ctx{}, &out);
    try testing.expectEqualSlices(u32, &.{ 3, 2, 1, 0 }, &out);
    // The filament in the nozzle first, then the rule: no extra change.
    bestOrder(1, &.{ 3, 2, 1, 0 }, Ctx{}, &out);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 2, 0 }, &out);
}

test "flush planner: a layer of more filaments than the search keeps the rule" {
    const Ctx = struct {
        fn cost(_: @This(), a: u32, b: u32) Cost {
            return .{ .seconds = @floatFromInt(a * 7 + b), .changes = 1 };
        }
    };
    var rule: [max_search + 1]u32 = undefined;
    for (&rule, 0..) |*r, k| r.* = @intCast(k);
    var out: [max_search + 1]u32 = undefined;
    bestOrder(4, &rule, Ctx{}, &out);
    try testing.expectEqualSlices(u32, &.{ 4, 0, 1, 2, 3, 5, 6, 7, 8 }, &out);
}
