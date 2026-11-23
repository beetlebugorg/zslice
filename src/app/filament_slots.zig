//! The filaments of the plate in the app (see filaments.zig): slot 1 is
//! the filament group of the settings, and `App.filaments` has the slots
//! after it (2, 3, and on). Each slot is a full filament: its material,
//! its color, its temperatures, and the other values of a filament
//! profile.
//!
//! A part or a range of layers prints with a slot through the setting
//! `project.filament` (a change of the part, or an override of the
//! layers). A removal of a slot moves the parts and the layers of the
//! slots after it down by one, and the parts and the layers of the removed
//! slot go to slot 1.
//!
//! The slots go into the plate 3MF as "filament" lines of the overrides
//! text: the slot number and the changed values of the filament as a
//! profile, with "\n" for each line end. So a project file keeps them,
//! and an undo brings them back. The history facts have a line for each
//! value of each slot.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const history = @import("history.zig");
const Filament = zs.settings.Filament;
const max_slots = zs.filaments.max_slots;

/// The colors of the new slots, in order: clear colors that differ from
/// each other and from the grey of the default filament.
const palette = [_][]const u8{ "#d93a3a", "#2f6fd6", "#f2c230", "#2e9e4f", "#f5f5f0", "#1c1c1c", "#e07a1f", "#8a3fc1", "#3fb8c1", "#c13f8a", "#8b5a2b", "#7fbf3f", "#ff9ec7", "#4d4d4d", "#a0c4ff" };

/// The number of filaments of the plate, at least 1.
pub fn count(app: *const App) usize {
    return 1 + app.filaments.items.len;
}

/// The filament of slot i (from 0).
pub fn get(app: *const App, i: usize) ?Filament {
    if (i == 0) return app.settings.filament;
    if (i - 1 >= app.filaments.items.len) return null;
    return app.filaments.items[i - 1];
}

pub const Error = Allocator.Error || error{ TooMany, NoSlot };

/// Adds a slot: a copy of the filament of slot 1 with the next color of
/// the palette. Returns its index (from 0).
pub fn add(app: *App) Error!usize {
    if (count(app) >= max_slots) return error.TooMany;
    var f = app.settings.filament;
    f.color = palette[app.filaments.items.len % palette.len];
    try app.filaments.append(app.gpa, f);
    return count(app) - 1;
}

/// Removes slot i (from 1). The parts and the layers of the slots after it
/// move down by one; the ones of slot i go to slot 1.
pub fn remove(app: *App, i: usize) Error!void {
    if (i == 0 or i - 1 >= app.filaments.items.len) return error.NoSlot;
    _ = app.filaments.orderedRemove(i - 1);
    @import("printer_filaments.zig").removed(app, i);
    const a = app.strings.allocator();
    const number: u32 = @intCast(i + 1);
    // The parts.
    for (app.plate.parts.items, 0..) |p, k| {
        const v = app.partSetting(k, "project.filament") orelse continue;
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch continue;
        if (n == number) {
            app.setPartSetting(k, "project.filament", null) catch {};
        } else if (n > number) {
            const t = try std.fmt.allocPrint(a, "{d}", .{n - 1});
            app.setPartSetting(k, "project.filament", t) catch {};
        }
        _ = p;
    }
    // The filament picks of some layers.
    for (app.plate.parts.items, 0..) |*p, k| {
        var v = p.volumes.items.len;
        while (v > 0) {
            v -= 1;
            const vol = &p.volumes.items[v];
            const n = zs.body_region.pickFilament(vol.meta) orelse continue;
            if (n == number) {
                app.plate.removeVolume(app.gpa, k, v);
            } else if (n > number) {
                for (vol.meta) |*m| if (std.mem.eql(u8, m.key, zs.body_region.pick_key)) {
                    const t = try std.fmt.allocPrint(app.gpa, "{d}", .{n - 1});
                    app.gpa.free(m.value);
                    m.value = t;
                };
            }
        }
    }
    // The layers.
    var j: usize = 0;
    while (j < app.overrides.items.len) {
        const o = &app.overrides.items[j];
        if (!std.mem.eql(u8, o.name, "project.filament")) {
            j += 1;
            continue;
        }
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, o.value, " "), 10) catch {
            j += 1;
            continue;
        };
        if (n == number) {
            _ = app.overrides.orderedRemove(j);
            continue;
        }
        if (n > number) o.value = try std.fmt.allocPrint(a, "{d}", .{n - 1});
        j += 1;
    }
}

/// Sets a value of the filament of slot i: `name` is a filament setting
/// ("filament.color"). Slot 0 is the filament of the settings.
pub fn set(app: *App, i: usize, name: []const u8, value: []const u8) (Error || zs.settings.Settings.SetError)!void {
    if (!std.mem.startsWith(u8, name, "filament.")) return error.UnknownSetting;
    if (i == 0) return app.setSetting(name, value);
    if (i - 1 >= app.filaments.items.len) return error.NoSlot;
    const a = app.strings.allocator();
    var s: zs.settings.Settings = .{};
    s.filament = app.filaments.items[i - 1];
    try s.set(name, try a.dupe(u8, value));
    app.filaments.items[i - 1] = s.filament;
}

/// Applies a filament profile to slot i (from 1): the values of the
/// profile over the defaults. The color of the slot stays, unless the
/// profile has one.
pub fn applyProfile(app: *App, i: usize, name: []const u8, text: []const u8, diag: *zs.profile.Diagnostic) (Error || zs.profile.Error)!void {
    if (i == 0 or i - 1 >= app.filaments.items.len) return error.NoSlot;
    const a = app.strings.allocator();
    var s: zs.settings.Settings = .{};
    const color = app.filaments.items[i - 1].color;
    try zs.profile.apply(a, &s, .filament, name, try a.dupe(u8, text), null, diag);
    if (std.mem.indexOf(u8, text, "color") == null) s.filament.color = color;
    app.filaments.items[i - 1] = s.filament;
}

/// The filament of slot i as a profile text: its values that differ from
/// the defaults.
pub fn writeProfile(f: Filament, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: zs.settings.Settings = .{};
    s.filament = f;
    try zs.profile.writeChanged(s, .filament, w);
}

/// The "filament" lines of the plate 3MF (see the header).
pub fn write3mfLines(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [16 * 1024]u8 = undefined;
    for (app.filaments.items, 2..) |f, n| {
        var fw: std.Io.Writer = .fixed(&buf);
        writeProfile(f, &fw) catch {};
        try w.print("filament\t{d}\t", .{n});
        for (fw.buffered()) |c| switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\\' => try w.writeAll("\\\\"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        };
        try w.writeByte('\n');
    }
}

/// Reads a "filament" line of the plate 3MF. Returns false if the line
/// is another line. The slots of a file come in order: slot 2 first.
pub fn read3mfLine(app: *App, line: []const u8) Allocator.Error!bool {
    if (!std.mem.startsWith(u8, line, "filament\t")) return false;
    var f = std.mem.splitScalar(u8, line["filament\t".len..], '\t');
    const n = std.fmt.parseInt(usize, f.next() orelse return true, 10) catch return true;
    if (n < 2 or n > max_slots) return true;
    const a = app.strings.allocator();
    var text: std.ArrayList(u8) = .empty;
    const raw = f.rest();
    var k: usize = 0;
    while (k < raw.len) : (k += 1) {
        if (raw[k] == '\\' and k + 1 < raw.len) {
            k += 1;
            try text.append(a, switch (raw[k]) {
                'n' => '\n',
                't' => '\t',
                else => raw[k],
            });
        } else try text.append(a, raw[k]);
    }
    var s: zs.settings.Settings = .{};
    var diag: zs.profile.Diagnostic = .{};
    zs.profile.apply(a, &s, .filament, "file", text.items, null, &diag) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // A value that this version does not know: the defaults.
    };
    while (count(app) < n) try app.filaments.append(app.gpa, app.settings.filament);
    app.filaments.items[n - 2] = s.filament;
    return true;
}

/// The filaments of a project of another slicer: the color and the
/// material of each (see threemf.Loaded.colors). Filament 1 is the
/// filament of the settings. The list gets more slots if it has fewer.
pub fn fromProject(app: *App, colors: []const []const u8, materials: []const []const u8) Allocator.Error!void {
    for (colors, 0..) |c, i| {
        if (i >= max_slots) break;
        while (count(app) <= i) _ = add(app) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (zs.filaments.parseColor(c) != null) set(app, i, "filament.color", c) catch |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        if (i < materials.len and materials[i].len > 0) set(app, i, "filament.material", materials[i]) catch |e| if (e == error.OutOfMemory) return error.OutOfMemory;
    }
}

/// The history facts of the slots: one line for each value that differs
/// from the defaults.
pub fn writeFacts(app: *const App, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [16 * 1024]u8 = undefined;
    for (app.filaments.items, 2..) |f, n| {
        try w.print("filament {d}\t(slot)\tyes\n", .{n});
        var fw: std.Io.Writer = .fixed(&buf);
        writeProfile(f, &fw) catch {};
        var lines = std.mem.splitScalar(u8, fw.buffered(), '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
            if (line.len == 0 or line[0] == '#') continue;
            try w.print("filament {d}\tfilament.{s}\t", .{ n, line[0..eq] });
            // A text value of the profile is in quotes; the facts of the
            // print settings are not. A plain text loses them, so the
            // history shows "Color #d0d0cc → #d93a3a".
            var v = line[eq + 3 ..];
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"' and std.mem.indexOfScalar(u8, v[1 .. v.len - 1], '\\') == null) v = v[1 .. v.len - 1];
            try history.writeEscaped(w, v);
            try w.writeByte('\n');
        }
    }
}

const testing = std.testing;

test "filament slots: add, set, remove, and the 3MF lines" {
    var app = try App.create(testing.allocator, null, null);
    defer app.destroy();
    try testing.expectEqual(@as(usize, 1), count(app));
    const i = try add(app);
    try testing.expectEqual(@as(usize, 1), i);
    try set(app, i, "filament.color", "#123456");
    try set(app, i, "filament.nozzle_temp", "230");
    try testing.expectEqualStrings("#123456", get(app, 1).?.color);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write3mfLines(app, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "filament\t2\t") != null);

    // A new app reads the lines back.
    var other = try App.create(testing.allocator, null, null);
    defer other.destroy();
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |line| _ = try read3mfLine(other, line);
    try testing.expectEqual(@as(usize, 2), count(other));
    try testing.expectEqualStrings("#123456", get(other, 1).?.color);
    try testing.expectEqual(@as(f64, 230), get(other, 1).?.nozzle_temp);

    // A removal moves the layers of the slots after it down.
    _ = try add(app);
    try app.setOverride(1, 2, "project.filament", "3");
    try app.setOverride(3, 4, "project.filament", "2");
    try remove(app, 1);
    try testing.expectEqual(@as(usize, 2), count(app));
    try testing.expectEqual(@as(usize, 1), app.overrides.items.len);
    try testing.expectEqualStrings("2", app.overrides.items[0].value);
}
