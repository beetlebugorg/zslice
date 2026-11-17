//! The history of changes: what changed from one step of the undo list to
//! the next, in words, for a history panel and a timeline.
//!
//! A step is a "facts" text (see `App.writeFacts`): one line for each value
//! of the state that differs from the start, as "scope\tkey\tvalue". The
//! scopes:
//!
//! - "machine", "filament", "print": a setting of the printer, of the
//!   filament, or of the print (the effective value, over the built-in
//!   default).
//! - "part:<name>": a setting of one part ("project.wall_count"), and its
//!   place: "(part)" (the part is on the plate), "position", "rotation"
//!   (the turn around the vertical axis), "orientation" (the side on the
//!   bed), and "scale".
//! - "layers:<z_min>:<z_max>": a change for some layers (an override), and
//!   "(name)", the name of a layer profile.
//!
//! `diff` gives the changes from one facts text to another, as lines of
//! "scope\tkey\told\tnew" (an empty old or new value: no value). `describe`
//! writes each change in words: the scope ("Part Benchy", "Layers 2–5 mm")
//! and the change ("Infill density 20 % → 55 %").
//!
//! The facts escape a tab as "\t" and a new line as "\n", so each value is
//! on one line. Only the shell keeps the facts of each step: the core keeps
//! no list (the undo list of the shell has the steps).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const setting_info = @import("setting_info.zig");

/// One line of a facts text, or of a diff.
pub const Fact = struct { scope: []const u8, key: []const u8, value: []const u8 };
pub const Change = struct { scope: []const u8, key: []const u8, old: []const u8, new: []const u8 };

/// Writes a value with a tab or a new line escaped.
pub fn writeEscaped(w: *std.Io.Writer, v: []const u8) std.Io.Writer.Error!void {
    for (v) |c| switch (c) {
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

/// The lines of a facts text. The slices point into `text`.
pub fn parseFacts(a: Allocator, text: []const u8) Allocator.Error![]Fact {
    var out: std.ArrayList(Fact) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const scope = f.next() orelse continue;
        const key = f.next() orelse continue;
        const value = f.rest();
        try out.append(a, .{ .scope = scope, .key = key, .value = value });
    }
    return out.items;
}

/// The lines of a diff. The slices point into `text`.
pub fn parseChanges(a: Allocator, text: []const u8) Allocator.Error![]Change {
    var out: std.ArrayList(Change) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const scope = f.next() orelse continue;
        const key = f.next() orelse continue;
        const old = f.next() orelse continue;
        const new = f.rest();
        try out.append(a, .{ .scope = scope, .key = key, .old = old, .new = new });
    }
    return out.items;
}

/// Writes the changes from the facts `a` to the facts `b`: first the values
/// of `b` that are new or differ, in the order of `b`, then the values of
/// `a` that `b` does not have.
pub fn diff(gpa: Allocator, a_text: []const u8, b_text: []const u8, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const a = try parseFacts(ar, a_text);
    const b = try parseFacts(ar, b_text);
    var in_a: std.StringHashMapUnmanaged([]const u8) = .empty;
    var in_b: std.StringHashMapUnmanaged(void) = .empty;
    for (a) |f| try in_a.put(ar, try std.fmt.allocPrint(ar, "{s}\t{s}", .{ f.scope, f.key }), f.value);
    for (b) |f| {
        const k = try std.fmt.allocPrint(ar, "{s}\t{s}", .{ f.scope, f.key });
        try in_b.put(ar, k, {});
        const old = in_a.get(k) orelse "";
        if (!std.mem.eql(u8, old, f.value)) try w.print("{s}\t{s}\t{s}\t{s}\n", .{ f.scope, f.key, old, f.value });
    }
    for (a) |f| {
        const k = try std.fmt.allocPrint(ar, "{s}\t{s}", .{ f.scope, f.key });
        if (!in_b.contains(k)) try w.print("{s}\t{s}\t{s}\t\n", .{ f.scope, f.key, f.value });
    }
}

/// A layer range from its scope "layers:<z_min>:<z_max>".
pub fn layerRange(scope: []const u8) ?[2]f64 {
    if (!std.mem.startsWith(u8, scope, "layers:")) return null;
    var it = std.mem.splitScalar(u8, scope["layers:".len..], ':');
    const lo = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const hi = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    return .{ lo, hi };
}

/// The name of the part of a scope "part:<name>", or null.
pub fn partName(scope: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, scope, "part:")) return null;
    return scope["part:".len..];
}

/// The scope in words: "Printer", "Filament", "This print", "Part
/// Benchy", and for a layer range "Layers 86–120", "Layers 86 and up", or
/// "Layers 1–40" when `layer_z` (the top z of each layer of the last slice)
/// has the layers, else "Layers 2.00–5.00 mm", "From 2.00 mm up", "Up to
/// 5.00 mm".
pub fn writeScope(w: *std.Io.Writer, scope: []const u8, part_z: f64, layer_z: []const f32) std.Io.Writer.Error!void {
    if (std.mem.eql(u8, scope, "machine")) return w.writeAll("Printer");
    if (std.mem.eql(u8, scope, "filament")) return w.writeAll("Filament");
    if (std.mem.eql(u8, scope, "print")) return w.writeAll("This print");
    if (partName(scope)) |n| return w.print("Part {s}", .{n});
    if (layerRange(scope)) |r| {
        const down = r[0] <= -part_z;
        const up = r[1] >= part_z;
        if (down and up) return w.writeAll("All layers");
        // The layers (from 1) with a top z in the range.
        var lo: ?usize = null;
        var hi: usize = 0;
        for (layer_z, 0..) |z, j| {
            if (z >= r[0] - 1e-4 and z <= r[1] + 1e-4) {
                if (lo == null) lo = j;
                hi = j;
            }
        }
        if (lo) |l| {
            if (up) return w.print("Layers {d} and up", .{l + 1});
            if (l == hi) return w.print("Layer {d}", .{l + 1});
            return w.print("Layers {d}–{d}", .{ l + 1, hi + 1 });
        }
        if (up) return w.print("From {d:.2} mm up", .{r[0]});
        if (down) return w.print("Up to {d:.2} mm", .{r[1]});
        return w.print("Layers {d:.2}–{d:.2} mm", .{ r[0], r[1] });
    }
    return w.writeAll(scope);
}

fn infoOf(name: []const u8) ?setting_info.SettingInfo {
    for (setting_info.settings_info) |i| if (std.mem.eql(u8, i.name, name)) return i;
    return null;
}

/// Writes a value of a setting for a person: a ratio as a percentage, a
/// number with its unit, a switch as on or off, a long text as "(text)".
fn writeValue(w: *std.Io.Writer, info: ?setting_info.SettingInfo, v: []const u8) std.Io.Writer.Error!void {
    const i = info orelse return w.writeAll(v);
    switch (i.kind) {
        .boolean => return w.writeAll(if (std.mem.eql(u8, v, "true")) "on" else "off"),
        .number, .integer => {
            const x = std.fmt.parseFloat(f64, v) catch return w.writeAll(v);
            if (std.mem.eql(u8, i.unit, "%")) return w.print("{d} %", .{@round(x * 10000) / 100});
            if (i.unit.len == 0) return w.print("{d}", .{x});
            const space = !(std.mem.eql(u8, i.unit, "°") or std.mem.eql(u8, i.unit, "\u{b0}"));
            return w.print("{d}{s}{s}", .{ x, if (space) " " else "", i.unit });
        },
        .text => {
            if (v.len > 32 or std.mem.indexOf(u8, v, "\\n") != null) return w.writeAll("(text)");
            return w.writeAll(v);
        },
        .choice => return w.writeAll(v),
    }
}

/// Writes one change in words, for a list: "Infill density 20 % → 55 %",
/// "Added", "Moved to 120, 95 mm". An empty old value of a setting is its
/// default (the facts have only the values that differ from it).
pub fn writeChange(w: *std.Io.Writer, c: Change) std.Io.Writer.Error!void {
    const is_part = partName(c.scope) != null;
    const is_layers = layerRange(c.scope) != null;
    if (is_part and std.mem.eql(u8, c.key, "(part)")) return w.writeAll(if (c.new.len > 0) "Added to the plate" else "Removed from the plate");
    if (is_part and std.mem.eql(u8, c.key, "position")) return w.print("Moved to {s} mm", .{c.new});
    if (is_part and std.mem.eql(u8, c.key, "rotation")) return w.print("Turned to {s}°", .{if (c.new.len > 0) c.new else "0"});
    if (is_part and std.mem.eql(u8, c.key, "orientation")) return w.writeAll(if (c.new.len > 0) "Put on another side" else "Back on its first side");
    if (is_part and std.mem.eql(u8, c.key, "scale")) return w.print("Scaled to {s}", .{if (c.new.len > 0) c.new else "1, 1, 1"});
    if (is_layers and std.mem.eql(u8, c.key, "(name)")) {
        if (c.new.len == 0) return w.print("Layer profile \"{s}\" removed", .{c.old});
        if (c.old.len == 0) return w.print("Layer profile \"{s}\"", .{c.new});
        return w.print("Layer profile \"{s}\" → \"{s}\"", .{ c.old, c.new });
    }
    if (std.mem.eql(u8, c.key, "quality")) {
        if (c.new.len == 0) return w.print("Quality {s} → custom", .{c.old});
        if (c.old.len == 0) return w.print("Quality → {s}", .{c.new});
        return w.print("Quality {s} → {s}", .{ c.old, c.new });
    }
    const info = infoOf(c.key);
    if (info) |i| try w.writeAll(i.label) else try w.writeAll(c.key);
    try w.writeByte(' ');
    // A part or a layer range with no value of its own has the value of
    // the print: "Wall count → 4 walls", "Wall count back to the print
    // value".
    if (is_part or is_layers) {
        if (c.new.len == 0) return w.writeAll("back to the print value");
        if (c.old.len > 0) {
            try writeValue(w, info, c.old);
            try w.writeByte(' ');
        }
        try w.writeAll("→ ");
        return writeValue(w, info, c.new);
    }
    const none = if (info) |i| i.default_value else "";
    try writeValue(w, info, if (c.old.len > 0) c.old else none);
    try w.writeAll(" → ");
    try writeValue(w, info, if (c.new.len > 0) c.new else none);
}

/// The kind of a change, in broad strokes, for the look of a step in a
/// timeline: what part of the print it changes.
pub const Kind = enum {
    walls,
    infill,
    /// The top and bottom skin, ironing, and slope smoothing.
    surface,
    /// Speeds, acceleration, travel, and retraction.
    speed,
    /// Temperatures, cooling, the filament, and the flow.
    heat,
    /// Support, skirt, and brim.
    support,
    /// The layer height, the first layer, the lines, and the changes for
    /// some layers.
    layers,
    move,
    rotate,
    scale,
    add,
    remove,
    quality,
    printer,
    other,
};

fn kindOfSection(group: []const u8, section: []const u8) Kind {
    const eq = std.mem.eql;
    if (eq(u8, group, "machine")) return .printer;
    const map = [_]struct { []const u8, Kind }{
        .{ "Walls", .walls },              .{ "Size compensation", .walls },
        .{ "Infill", .infill },            .{ "Top and bottom skin", .surface },
        .{ "Ironing", .surface },          .{ "Slope smoothing", .surface },
        .{ "Speed ratios", .speed },       .{ "Acceleration", .speed },
        .{ "Motion", .speed },             .{ "Travel", .speed },
        .{ "Retraction", .speed },         .{ "Temperatures", .heat },
        .{ "Cooling", .heat },             .{ "Filament", .heat },
        .{ "Flow", .heat },                .{ "Extruder", .heat },
        .{ "Support", .support },          .{ "Skirt and brim", .support },
        .{ "Layers", .layers },            .{ "First layer", .layers },
        .{ "Lines", .layers },             .{ "Placement", .move },
    };
    for (map) |m| if (eq(u8, m[0], section)) return m[1];
    return .other;
}

/// The kind of one change.
pub fn kindOf(c: Change) Kind {
    const eq = std.mem.eql;
    if (partName(c.scope) != null) {
        if (eq(u8, c.key, "(part)")) return if (c.new.len > 0) .add else .remove;
        if (eq(u8, c.key, "position")) return .move;
        if (eq(u8, c.key, "rotation") or eq(u8, c.key, "orientation")) return .rotate;
        if (eq(u8, c.key, "scale")) return .scale;
    }
    if (eq(u8, c.key, "quality")) return .quality;
    if (layerRange(c.scope) != null and eq(u8, c.key, "(name)")) return .layers;
    const info = infoOf(c.key) orelse return .other;
    return kindOfSection(info.group, info.section);
}

/// The kind of a step: the kind of most of its changes (the first one of
/// a tie). An added part with its place is an add, a part that is gone is
/// a remove, and a new quality profile (with its settings) is a quality
/// step. No change: other.
pub fn stepKind(gpa: Allocator, changes: []const u8) Allocator.Error!Kind {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const cs = try parseChanges(arena_state.allocator(), changes);
    var counts = std.EnumArray(Kind, usize).initFill(0);
    var first: ?Kind = null;
    for (cs) |c| {
        const k = kindOf(c);
        if (k == .add or k == .remove or k == .quality) return k;
        counts.getPtr(k).* += 1;
        if (first == null) first = k;
    }
    var best = first orelse return .other;
    for (std.enums.values(Kind)) |k| {
        if (counts.get(k) > counts.get(best)) best = k;
    }
    return best;
}

/// Writes the changes of a diff in words, one on each line: "scope in
/// words\tchange in words".
pub fn describe(gpa: Allocator, changes: []const u8, part_z: f64, layer_z: []const f32, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for (try parseChanges(arena_state.allocator(), changes)) |c| {
        try writeScope(w, c.scope, part_z, layer_z);
        try w.writeByte('\t');
        try writeChange(w, c);
        try w.writeByte('\n');
    }
}

const testing = std.testing;

test "history: the diff of two facts texts, and the changes in words" {
    const a = "print\tproject.infill_density\t0.2\npart:Benchy\tposition\t10, 20\nmachine\tmachine.bed_size_x\t300\n";
    const b = "print\tproject.infill_density\t0.55\npart:Benchy\tposition\t10, 20\npart:Benchy\tproject.wall_count\t4\n";
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try diff(testing.allocator, a, b, &buf.writer);
    try testing.expectEqualStrings(
        "print\tproject.infill_density\t0.2\t0.55\n" ++
            "part:Benchy\tproject.wall_count\t\t4\n" ++
            "machine\tmachine.bed_size_x\t300\t\n",
        buf.written(),
    );
    var words: std.Io.Writer.Allocating = .init(testing.allocator);
    defer words.deinit();
    try describe(testing.allocator, buf.written(), 1e5, &.{}, &words.writer);
    var lines = std.mem.splitScalar(u8, words.written(), '\n');
    try testing.expectEqualStrings("This print\tInfill density 20 % → 55 %", lines.next().?);
    try testing.expectEqualStrings("Part Benchy\tWall count → 4 walls", lines.next().?);
    const third = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, third, "Printer\tBed size x 300 mm → "));
}

test "history: the scope of a layer range in words" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeScope(&buf.writer, "layers:2:5", 1e5, &.{});
    try testing.expectEqualStrings("Layers 2.00–5.00 mm", buf.written());
    buf.clearRetainingCapacity();
    try writeScope(&buf.writer, "layers:2:100000", 1e5, &.{});
    try testing.expectEqualStrings("From 2.00 mm up", buf.written());
    // With the layers of a slice: layer numbers from 1.
    const zs_ = [_]f32{ 1, 2, 3, 4, 5, 6 };
    buf.clearRetainingCapacity();
    try writeScope(&buf.writer, "layers:2:100000", 1e5, &zs_);
    try testing.expectEqualStrings("Layers 2 and up", buf.written());
    buf.clearRetainingCapacity();
    try writeScope(&buf.writer, "layers:2.9:4.1", 1e5, &zs_);
    try testing.expectEqualStrings("Layers 3–4", buf.written());
}

test "history: the kind of a step" {
    const a = testing.allocator;
    try testing.expectEqual(Kind.infill, try stepKind(a, "print\tproject.infill_density\t0.2\t0.55\n"));
    try testing.expectEqual(Kind.walls, try stepKind(a, "part:Benchy\tproject.wall_count\t\t4\n"));
    try testing.expectEqual(Kind.rotate, try stepKind(a, "part:Benchy\trotation\t\t90.0\n"));
    try testing.expectEqual(Kind.add, try stepKind(a, "part:Benchy\t(part)\t\tyes\npart:Benchy\tposition\t\t10, 20\n"));
    try testing.expectEqual(Kind.printer, try stepKind(a, "machine\tmachine.bed_size_x\t220\t300\n"));
    try testing.expectEqual(Kind.other, try stepKind(a, ""));
    try testing.expectEqual(Kind.quality, try stepKind(a, "print\tproject.layer_height\t0.2\t0.1\nprint\tproject.ironing\t\ttrue\nprint\tquality\tstandard\tfine\n"));
}
