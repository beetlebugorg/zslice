//! The text of a setting value, as the editors of each app show it, and
//! back. One place for the rules, so the GTK app, the web app, and the
//! macOS app show the same text:
//!
//! - A number with the unit "%" is a ratio: the core value 0.5 shows as 50.
//! - A line width of 0 is "auto" (the width comes from the nozzle).
//! - A multiline text (G-code) shows its first line and " …".
//! - A number shows with no more digits than it needs (as %.6g).
//! - With the unit: "0.8 mm", and "1 layer" for an integer 1 (the "s" of
//!   the unit goes).
//! - Back to the core: "auto" is 0, and a percentage is divided by 100
//!   (10 significant digits).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const info_mod = @import("setting_info.zig");
const zs_settings = @import("../settings.zig");
const SettingInfo = info_mod.SettingInfo;
const Writer = std.Io.Writer;

pub const Error = error{ UnknownSetting, InvalidValue } || Writer.Error;

/// The info of a setting by its name, or null.
pub fn find(name: []const u8) ?*const SettingInfo {
    for (info_mod.settings_info) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn isAuto(s: *const SettingInfo) bool {
    return std.mem.endsWith(u8, s.name, "line_width");
}

fn isNumber(s: *const SettingInfo) bool {
    return s.kind == .number or s.kind == .integer;
}

fn isRatio(s: *const SettingInfo) bool {
    return isNumber(s) and std.mem.eql(u8, s.unit, "%");
}

/// The number of a text, or null (also for an empty text).
pub fn number(text: []const u8) ?f64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    const v = std.fmt.parseFloat(f64, t) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// Writes v with `digits` significant digits and no trailing zeros, as
/// %g does: "0.15", "210", "1e-05".
pub fn writeG(w: *Writer, v: f64, digits: u8) Writer.Error!void {
    if (v == 0) return w.writeAll("0");
    const a = @abs(v);
    const exp: i32 = @intFromFloat(@floor(std.math.log10(a)));
    if (exp < -4 or exp >= digits) {
        // The exponent form: the digits after the point, then e±XX.
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{e:.[1]}", .{ v, digits - 1 }) catch return w.writeAll("0");
        const e = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
        var mant: []const u8 = s[0..e];
        if (std.mem.indexOfScalar(u8, mant, '.') != null) {
            mant = std.mem.trimEnd(u8, mant, "0");
            mant = std.mem.trimEnd(u8, mant, ".");
        }
        const ev = std.fmt.parseInt(i32, s[e + 1 ..], 10) catch 0;
        return w.print("{s}e{s}{d:0>2}", .{ mant, if (ev < 0) "-" else "+", @abs(ev) });
    }
    const decimals: usize = @intCast(@max(0, @as(i32, digits) - 1 - exp));
    var buf: [64]u8 = undefined;
    var s: []const u8 = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, decimals }) catch return w.writeAll("0");
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    if (std.mem.eql(u8, s, "-0")) s = "0";
    return w.writeAll(s);
}

/// The value as an editor shows it; with `with_unit`, the unit after it.
pub fn display(s: *const SettingInfo, value: []const u8, with_unit: bool, w: *Writer) Writer.Error!void {
    // 0 of a support filament: no slot, but the filament of the part (or
    // the support filament, for the interface).
    if ((number(value) orelse 1) == 0) {
        if (std.mem.eql(u8, s.name, "project.support_filament")) return w.writeAll("the part");
        if (std.mem.eql(u8, s.name, "project.support_interface_filament")) return w.writeAll("the support filament");
        if (std.mem.eql(u8, s.name, "project.infill_filament")) return w.writeAll("the part");
        // A nozzle after the first: 0 is the value of the first nozzle,
        // no limit, or the edge of the bed.
        if (zs_settings.nozzleSetting(s.name)) |ns| {
            for ([_][]const u8{ "max_speed", "max_accel" }) |n| {
                if (std.mem.eql(u8, ns.field, n)) return w.writeAll("no limit");
            }
            for ([_][]const u8{ "min_x", "max_x", "max_height" }) |n| {
                if (std.mem.eql(u8, ns.field, n)) return w.writeAll("the whole bed");
            }
            const offset = std.mem.startsWith(u8, ns.field, "offset_");
            if (!offset) return w.writeAll("as the first nozzle");
        }
    }
    var buf: [256]u8 = undefined;
    var shown_w: Writer = .fixed(&buf);
    var long: ?[]const u8 = null;
    if (isAuto(s) and (number(value) orelse 1) == 0) {
        shown_w.writeAll("auto") catch {};
    } else if (isRatio(s) and number(value) != null) {
        writeG(&shown_w, number(value).? * 100, 6) catch {};
    } else if (s.kind == .text and s.multiline) {
        const nl = std.mem.indexOfScalar(u8, value, '\n');
        long = if (nl) |k| value[0..k] else value;
        if (nl == null) long = value;
    } else {
        long = value;
    }
    if (long) |text| {
        try w.writeAll(text);
        if (s.kind == .text and s.multiline and std.mem.indexOfScalar(u8, value, '\n') != null) try w.writeAll(" …");
        // A text keeps no unit.
        if (!with_unit or s.unit.len == 0 or s.kind == .text) return;
        return writeUnit(s, text, w);
    }
    const shown = shown_w.buffered();
    try w.writeAll(shown);
    if (!with_unit or s.unit.len == 0 or std.mem.eql(u8, shown, "auto")) return;
    return writeUnit(s, shown, w);
}

fn writeUnit(s: *const SettingInfo, shown: []const u8, w: *Writer) Writer.Error!void {
    // A count of one: "1 layer", not "1 layers".
    const n = s.unit.len;
    const one = std.mem.eql(u8, shown, "1") and n > 1 and s.unit[n - 1] == 's' and s.kind == .integer;
    try w.print(" {s}", .{if (one) s.unit[0 .. n - 1] else s.unit});
}

/// The core value of the text of an editor. A number setting refuses a
/// text that is not a number (error.InvalidValue).
pub fn parse(s: *const SettingInfo, text: []const u8, w: *Writer) Error!void {
    const t = std.mem.trim(u8, text, " \t");
    if (isAuto(s) and std.ascii.eqlIgnoreCase(t, "auto")) return w.writeAll("0");
    if (!isNumber(s)) return w.writeAll(t);
    const v = number(t) orelse return error.InvalidValue;
    if (isRatio(s)) return writeG(w, v / 100, 10);
    return w.writeAll(t);
}

/// The source of a value as a short tag (enum zs_level): "Global", the
/// profile name, "This print", "This part", or "= formula".
pub fn source(level: i32, profile: []const u8, formula: ?[]const u8, w: *Writer) Writer.Error!void {
    if (formula) |f| return w.print("= {s}", .{f});
    const text: []const u8 = switch (level) {
        1 => "Global",
        2 => if (profile.len > 0) profile else "Printer",
        3 => if (profile.len > 0) profile else "Filament",
        4 => if (profile.len > 0) profile else "Quality",
        5 => "This print",
        6 => "This part",
        else => "",
    };
    return w.writeAll(text);
}

const testing = std.testing;

fn show(name: []const u8, value: []const u8, unit: bool) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buf);
    try display(find(name).?, value, unit, &w);
    return w.buffered();
}

fn back(name: []const u8, text: []const u8) ![]const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buf);
    try parse(find(name).?, text, &w);
    return w.buffered();
}

test "setting text: the rules of the editors" {
    try testing.expectEqualStrings("20", try show("project.infill_density", "0.2", false));
    try testing.expectEqualStrings("20 %", try show("project.infill_density", "0.2", true));
    try testing.expectEqualStrings("auto", try show("project.line_width", "0", true));
    try testing.expectEqualStrings("0.45 mm", try show("project.line_width", "0.45", true));
    try testing.expectEqualStrings("G28 …", try show("machine.start_gcode", "G28\nG1 Z5", false));
    try testing.expectEqualStrings("0.2", back("project.infill_density", "20") catch unreachable);
    try testing.expectEqualStrings("0.333333", (try show("project.infill_density", "0.00333333333", false)));
    try testing.expectEqualStrings("0", try back("project.line_width", "auto"));
    try testing.expectError(error.InvalidValue, back("project.wall_count", "two"));
    var buf: [32]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeG(&w, 1e-5, 6);
    try testing.expectEqualStrings("1e-05", w.buffered());
}

test "setting text: one of a count" {
    // An integer setting with a plural unit, if the library has one.
    for (info_mod.settings_info) |*s| {
        if (s.kind != .integer or s.unit.len < 2 or s.unit[s.unit.len - 1] != 's') continue;
        var buf: [64]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try display(s, "1", true, &w);
        try testing.expectEqualStrings(s.unit[0 .. s.unit.len - 1], w.buffered()[2..]);
        return;
    }
}

test "display: 0 of a support filament is a filament, not a slot" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try display(find("project.support_filament").?, "0", true, &aw.writer);
    try std.testing.expectEqualStrings("the part", aw.written());
    aw.clearRetainingCapacity();
    try display(find("project.support_filament").?, "2", true, &aw.writer);
    try std.testing.expectEqualStrings("2 slot", aw.written());
}
