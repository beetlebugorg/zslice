//! The search of the settings, for the search box of each app (/ in the
//! web app, the GTK app, and the macOS app). One place for the rules:
//!
//! - The query splits into words. Each word must match the setting, by
//!   itself or by a word of its groups (`same`, at 3/4 of the score).
//! - A word scores by where it matches: the start of the label 40, the
//!   start of a word of the label 30, inside the label 20, the name 14, the
//!   section 12, the help text 3.
//! - The settings of the print (project) get +2, the engine settings -2.
//! - The settings that most people change (`common`) get +4, so a short
//!   query ("speed", "temp") shows them before the special ones.
//!
//! `aliases` sends a word straight to one setting: "color", "colour",
//! "extruder", "material", and "tool" find the filament of the part or of
//! some layers (`project.filament`) first, as a person who wants another
//! color looks for that word. "nozzle" finds it too, after the nozzle
//! settings.
//!
//! `same` has the words of other slicers for the settings of zslice
//! ("perimeters" for walls, "feedrate" for speed), so a person who knows
//! another slicer finds the setting. The actions of an app (export, print)
//! stay in the app.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const info_mod = @import("setting_info.zig");
const settings_mod = @import("../settings.zig");
const SettingInfo = info_mod.SettingInfo;

/// Groups of words that mean the same thing in a search.
/// The settings that most people change.
pub const common = [_][]const u8{
    "project.layer_height",   "project.infill_density",  "project.wall_count",
    "project.support",        "project.support_style",   "project.brim_width",
    "project.outer_wall_speed", "project.inner_wall_speed", "project.infill_speed",
    "project.top_thickness",  "project.bottom_thickness", "project.seam",
    "filament.nozzle_temp",   "filament.bed_temp",       "filament.fan_speed",
    "filament.max_flow",      "machine.max_speed",       "machine.max_accel",
};

fn isCommon(name: []const u8) bool {
    for (common) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

pub const same = [_][]const []const u8{
    &.{ "speed", "speeds", "motion", "velocity", "fast", "slow", "mm/s", "feedrate", "accel", "acceleration", "jerk", "max speed" },
    &.{ "acceleration", "accel", "jerk", "motion" },
    &.{ "temperature", "temp", "heat", "hot", "nozzle temp", "bed temp", "temperatures" },
    &.{ "fan", "cooling", "cool", "fans" },
    &.{ "wall", "walls", "perimeter", "perimeters", "shell", "shells", "outline" },
    &.{ "infill", "fill", "density", "sparse" },
    &.{ "skin", "top", "bottom", "solid", "top and bottom" },
    &.{ "support", "supports", "overhang", "overhangs", "tree" },
    &.{ "brim", "skirt", "adhesion", "raft" },
    &.{ "retraction", "retract", "stringing", "z hop", "wipe" },
    &.{ "travel", "moves", "combing", "avoid" },
    &.{ "layer", "layers", "height", "layer height", "resolution" },
    &.{ "first layer", "initial", "first", "bed adhesion" },
    &.{ "flow", "extrusion", "multiplier", "extrusion multiplier", "volumetric" },
    &.{ "seam", "z seam", "scarf" },
    &.{ "bridge", "bridges", "bridging" },
    &.{ "ironing", "iron", "smooth" },
    &.{ "shrink", "shrinkage", "compensation", "xy offset", "horizontal expansion", "elephant foot" },
    &.{ "gcode", "g-code", "start", "end", "macro" },
    &.{ "bed", "plate", "build plate", "bed size" },
    &.{ "line width", "extrusion width", "width" },
};

/// A word that finds one setting at a fixed score (see the file comment).
pub const Alias = struct { words: []const []const u8, name: []const u8, score: u32 };

pub const aliases = [_]Alias{
    .{ .words = &.{ "color", "colour", "colors", "colours", "extruder", "material", "tool", "spool" }, .name = "project.filament", .score = 60 },
    .{ .words = &.{"nozzle"}, .name = "project.filament", .score = 30 },
};

/// The score of an alias of word `w` for setting `name`: 0 for none.
fn aliasScore(name: []const u8, w: []const u8) u32 {
    if (w.len < 3) return 0;
    var best: u32 = 0;
    for (aliases) |al| {
        if (!std.mem.eql(u8, al.name, name)) continue;
        for (al.words) |x| if (std.mem.startsWith(u8, x, w)) {
            best = @max(best, al.score);
        };
    }
    return best;
}

fn lower(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

fn containsLower(hay: []const u8, w: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, w) != null;
}

/// The score of one word (or phrase, lower case) in a setting: 0 for no
/// match.
pub fn wordScore(s: *const SettingInfo, w: []const u8) u32 {
    if (w.len == 0) return 0;
    if (std.ascii.startsWithIgnoreCase(s.label, w)) return 40;
    var it = std.mem.tokenizeAny(u8, s.label, " \t");
    while (it.next()) |x| if (std.ascii.startsWithIgnoreCase(x, w)) return 30;
    if (containsLower(s.label, w)) return 20;
    // The name: spaces of the word as "_".
    var nb: [64]u8 = undefined;
    if (w.len <= nb.len) {
        for (w, 0..) |c, i| nb[i] = if (c == ' ') '_' else c;
        if (containsLower(s.name, nb[0..w.len])) return 14;
    }
    if (containsLower(s.section, w)) return 12;
    if (containsLower(s.doc, w)) return 3;
    return 0;
}

/// The best score of the word `w` or of a word of its groups (3/4).
fn bestScore(s: *const SettingInfo, w: []const u8) f64 {
    var best: f64 = @floatFromInt(@max(wordScore(s, w), aliasScore(s.name, w)));
    if (w.len < 3) return best;
    for (same) |g| {
        var hit = false;
        for (g) |x| if (std.mem.startsWith(u8, x, w)) {
            hit = true;
            break;
        };
        if (!hit) continue;
        for (g) |x| best = @max(best, 0.75 * @as(f64, @floatFromInt(wordScore(s, x))));
    }
    return best;
}

/// The score of a setting for a query: 0 for no match.
pub fn score(s: *const SettingInfo, query: []const u8) f64 {
    var buf: [256]u8 = undefined;
    const q = lower(&buf, query);
    var total: f64 = 0;
    var any = false;
    var it = std.mem.tokenizeAny(u8, q, " \t\n");
    while (it.next()) |w| {
        any = true;
        const b = bestScore(s, w);
        if (b == 0) return 0;
        total += b;
    }
    if (!any) return 0;
    // The whole query at the start of the label: the setting the user
    // types ("start gcode" is Start gcode, not Gcode flavor).
    const tq = std.mem.trim(u8, q, " \t");
    if (tq.len > 0 and std.ascii.startsWithIgnoreCase(s.label, tq)) total += 15;
    if (std.mem.eql(u8, s.group, "project")) total += 2;
    if (std.mem.eql(u8, s.group, "engine")) total -= 2;
    if (isCommon(s.name)) total += 4;
    return @max(total, 0.001);
}

pub const Hit = struct { index: u32, score: f64 };

/// The settings that match a query, best first, at most out.len. With
/// `part_only`, only the settings that a part can have of its own. The
/// index is the index of zs_setting_get_info. Returns the count.
pub fn search(query: []const u8, part_only: bool, out: []Hit) usize {
    var n: usize = 0;
    for (info_mod.settings_info, 0..) |*s, i| {
        if (part_only and !settings_mod.isPerPartSetting(s.name)) continue;
        const sc = score(s, query);
        if (sc <= 0) continue;
        // Keep the best out.len, sorted: insert in place.
        var k = n;
        if (k == out.len) {
            if (out.len == 0 or out[k - 1].score >= sc) continue;
            k -= 1;
        } else n += 1;
        while (k > 0 and out[k - 1].score < sc) : (k -= 1) out[k] = out[k - 1];
        out[k] = .{ .index = @intCast(i), .score = sc };
    }
    return n;
}

const testing = std.testing;

fn top(query: []const u8) []const u8 {
    var out: [1]Hit = undefined;
    if (search(query, false, &out) == 0) return "";
    return info_mod.settings_info[out[0].index].name;
}

test "setting search: words, synonyms, and order" {
    try testing.expect(std.mem.indexOf(u8, top("infill"), "infill") != null);
    // A word of another slicer finds the setting of zslice.
    try testing.expect(std.mem.indexOf(u8, top("perimeters"), "wall") != null);
    // "speed" and "motion" find the same kind of settings.
    var a: [8]Hit = undefined;
    var b: [8]Hit = undefined;
    const na = search("speed", false, &a);
    const nb = search("motion", false, &b);
    try testing.expect(na > 0 and nb > 0);
    // Each word must match.
    try testing.expectEqual(@as(usize, 0), search("infill zzqqx", false, &a));
    // The results are sorted.
    for (1..na) |i| try testing.expect(a[i - 1].score >= a[i].score);
}

test "setting search: the common settings first" {
    try testing.expectEqualStrings("project.infill_density", top("infill"));
    var out: [3]Hit = undefined;
    const n = search("speed", false, &out);
    var common_first = false;
    for (out[0..n]) |h| {
        if (isCommon(info_mod.settings_info[h.index].name)) common_first = true;
    }
    try testing.expect(common_first);
    // Each name of the list is a setting.
    for (common) |c| {
        var found = false;
        for (info_mod.settings_info) |*s| if (std.mem.eql(u8, s.name, c)) {
            found = true;
        };
        try testing.expect(found);
    }
}

test "setting search: a color, a material, or a tool finds the filament first" {
    for ([_][]const u8{ "color", "colour", "extruder", "material", "tool", "Color" }) |q| try testing.expectEqualStrings("project.filament", top(q));
    // "nozzle" finds it after the nozzle settings.
    var out: [64]Hit = undefined;
    const n = search("nozzle", false, &out);
    var found = false;
    for (out[0..n]) |h| {
        if (std.mem.eql(u8, info_mod.settings_info[h.index].name, "project.filament")) found = true;
    }
    try testing.expect(found);
    try testing.expect(!std.mem.eql(u8, top("nozzle"), "project.filament"));
    // Other settings with the word still come after it.
    try testing.expect(search("color", false, &out) > 1);
}

test "setting search: the whole query first" {
    try testing.expectEqualStrings("machine.start_gcode", top("start gcode"));
}

test "setting search: the settings of a part" {
    var out: [64]Hit = undefined;
    const n = search("speed", true, &out);
    for (out[0..n]) |h| try testing.expect(settings_mod.isPerPartSetting(info_mod.settings_info[h.index].name));
}
