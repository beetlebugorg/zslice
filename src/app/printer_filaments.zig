//! The filaments that a printer has loaded, for the filaments of the plate.
//!
//! A printdeck tells the spools of its printer in "filaments" of
//! GET /api/plugin/printdeck: [{slot "A1", tray 0, nozzle "main" or "aux",
//! material "PLA", color "#rrggbb", idx "GFA00"}]. A Bambu Lab printer
//! tells its trays in its MQTT report (printer_status.zig makes the same
//! list from it). `apply` makes the slots of the plate the same as that
//! list: the count, and the material, the profile, the color, and the
//! nozzle of each slot, in the order of the printer. So a plate prints
//! with the filament that is in the printer, and the print command can
//! map each filament to the tray that holds it (`amsMapping`).
//!
//! A slot that the user set by hand (`Mark.hand`) keeps the values of the
//! user. `apply` with `take_hand` (the "Use the printer's filament" button)
//! makes all slots follow the printer again.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const slots = @import("filament_slots.zig");
const max_slots = zs.filaments.max_slots;

/// Where the values of a slot come from.
pub const Mark = struct {
    /// The user set a value of the slot by hand.
    hand: bool = false,
    /// The values come from a spool of the printer.
    printer: bool = false,
    /// The tray of the spool (the AMS unit times 4 and the tray, 254 and
    /// 255 the external spools), or -1 when not known.
    tray: i32 = -1,
    /// The name of the spool holder ("A1", "Ext"), and the Bambu Lab
    /// filament id of the spool ("GFA00"), or "".
    name_buf: [8]u8 = @splat(0),
    name_len: u8 = 0,
    idx_buf: [12]u8 = @splat(0),
    idx_len: u8 = 0,

    pub fn name(m: *const Mark) []const u8 {
        return m.name_buf[0..m.name_len];
    }

    pub fn idx(m: *const Mark) []const u8 {
        return m.idx_buf[0..m.idx_len];
    }

    fn setText(buf: []u8, len: *u8, text: []const u8) void {
        const n = @min(text.len, buf.len);
        @memcpy(buf[0..n], text[0..n]);
        len.* = @intCast(n);
    }
};

/// A spool of the printer.
pub const Spool = struct {
    /// "A1", "Ext", or "".
    slot: []const u8 = "",
    /// See Mark.tray.
    tray: i32 = -1,
    /// In upper case ("PLA").
    material: []const u8,
    /// "#rrggbb", or "".
    color: []const u8 = "",
    /// The Bambu Lab filament id ("GFA00"), or "".
    idx: []const u8 = "",
    /// The spool feeds the second nozzle ("nozzle": "aux").
    aux: bool = false,
};

fn isColor(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The spools of a JSON text: an object with "filaments" (the reply of a
/// printdeck) or the list itself. Spools with no material are not in the
/// list. The strings are in `a`.
pub fn parse(a: Allocator, json: []const u8) Allocator.Error![]Spool {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const list = switch (root) {
        .array => |l| l,
        .object => |o| if (o.get("filaments")) |v| (if (v == .array) v.array else return &.{}) else return &.{},
        else => return &.{},
    };
    var out: std.ArrayList(Spool) = .empty;
    for (list.items) |e| {
        if (e != .object) continue;
        const o = e.object;
        const text = struct {
            fn f(obj: std.json.ObjectMap, key: []const u8) []const u8 {
                const v = obj.get(key) orelse return "";
                return if (v == .string) v.string else "";
            }
        }.f;
        const material = std.mem.trim(u8, text(o, "material"), " ");
        if (material.len == 0 or material.len > 32) continue;
        const color = text(o, "color");
        var idx = text(o, "idx");
        if (idx.len == 0) idx = text(o, "tray_info_idx");
        const tray: i32 = if (o.get("tray")) |v| switch (v) {
            .integer => |n| if (n >= 0 and n < 1000) @intCast(n) else -1,
            .float => |f| if (f >= 0 and f < 1000) @intFromFloat(f) else -1,
            else => -1,
        } else -1;
        try out.append(a, .{
            .slot = text(o, "slot"),
            .tray = tray,
            .material = try std.ascii.allocUpperString(a, material),
            .color = if (isColor(color)) try std.ascii.allocLowerString(a, color) else "",
            .idx = if (idx.len <= 12) idx else "",
            .aux = std.mem.eql(u8, text(o, "nozzle"), "aux"),
        });
    }
    return out.toOwnedSlice(a);
}

pub const Result = struct {
    /// A value or the count of the slots changed: slice again.
    changed: bool = false,
    /// The spools that the plate uses, and the spools of the second nozzle
    /// that a printer with one nozzle in the settings leaves out.
    used: usize = 0,
    left_out: usize = 0,
    /// The slots that stay as the user set them.
    kept: usize = 0,
};

/// The machine has two nozzles (the settings, or the Bambu Lab model).
pub fn twoNozzles(app: *const App) bool {
    const m = app.settings.machine;
    if (m.nozzles >= 2) return true;
    return if (zs.printers.bambu(m.model)) |b| b.nozzles >= 2 else false;
}

pub const How = enum {
    /// The user asks: the slots that the user set by hand follow too.
    take_hand,
    /// The plate follows the printer: the slots of the user stay.
    keep_hand,
    /// `keep_hand` on a change of the spools of the printer, with no
    /// question to the user: only on a printer that changes the filament
    /// by itself (machine.filament_change "tool"). A printer that pauses
    /// for each change gets its other spools from the user, so the count
    /// of the slots stays the user's.
    follow,
};

/// Makes the slots of the plate the spools of the printer (see the
/// header and `How`).
pub fn apply(app: *App, spools: []const Spool, how: How) (Allocator.Error || slots.Error)!Result {
    var r: Result = .{};
    const take_hand = how == .take_hand;
    if (how == .follow and app.settings.machine.filament_change != .tool) {
        r.used = spools.len;
        return r;
    }
    const two = twoNozzles(app);
    var want: [max_slots]Spool = undefined;
    var n: usize = 0;
    for (spools) |s| {
        if (s.aux and !two) {
            r.left_out += 1;
            continue;
        }
        if (n < want.len) {
            want[n] = s;
            n += 1;
        }
    }
    r.used = n;
    if (n == 0) return r;
    if (take_hand) for (&app.slot_marks) |*m| {
        m.hand = false;
    };
    // The count: the spools, and each slot of the user after them.
    var count = n;
    for (app.slot_marks[0..slots.count(app)], 0..) |m, k| if (m.hand) {
        count = @max(count, k + 1);
    };
    while (slots.count(app) < count) {
        _ = try slots.add(app);
        r.changed = true;
    }
    while (slots.count(app) > count) {
        try slots.remove(app, slots.count(app) - 1);
        r.changed = true;
    }
    const a = app.strings.allocator();
    for (want[0..n], 0..) |s, k| {
        if (app.slot_marks[k].hand) {
            r.kept += 1;
            continue;
        }
        const cur = slots.get(app, k) orelse continue;
        if (!std.ascii.eqlIgnoreCase(cur.material, s.material)) {
            // The built-in profile of the material, if zslice has one;
            // the diameter stays (a property of the printer).
            const low = try std.ascii.allocLowerString(a, s.material);
            const text = try std.fmt.allocPrint(a, "extends = \"generic-{s}\"\ndiameter = {d}\n", .{ low, cur.diameter });
            var diag: zs.profile.Diagnostic = .{};
            if (k == 0) {
                const color = app.settings.filament.color;
                app.applyProfile(.filament, "saved", text, &diag) catch |e| if (e == error.OutOfMemory) return error.OutOfMemory;
                slots.set(app, 0, "filament.color", color) catch {};
            } else slots.applyProfile(app, k, "saved", text, &diag) catch |e| if (e == error.OutOfMemory) return error.OutOfMemory;
            slots.set(app, k, "filament.material", s.material) catch {};
            slots.set(app, k, "filament.name", s.material) catch {};
            r.changed = true;
        }
        if (s.color.len == 7 and !std.ascii.eqlIgnoreCase((slots.get(app, k) orelse cur).color, s.color)) {
            slots.set(app, k, "filament.color", s.color) catch {};
            r.changed = true;
        }
        if (two) {
            const nz: u32 = if (s.aux) 1 else 0;
            if ((slots.get(app, k) orelse cur).nozzle != nz) {
                slots.set(app, k, "filament.nozzle", if (s.aux) "1" else "0") catch {};
                r.changed = true;
            }
        }
        const m = &app.slot_marks[k];
        if (!std.mem.eql(u8, m.idx(), s.idx)) r.changed = true;
        m.printer = true;
        m.tray = s.tray;
        Mark.setText(&m.name_buf, &m.name_len, s.slot);
        Mark.setText(&m.idx_buf, &m.idx_len, s.idx);
    }
    // A slot of the user after the spools has no spool.
    for (app.slot_marks[n..]) |*m| if (!m.hand) {
        m.* = .{};
    };
    return r;
}

/// The user set a value of slot i by hand: it keeps it.
pub fn markHand(app: *App, i: usize) void {
    if (i >= max_slots) return;
    app.slot_marks[i] = .{ .hand = true };
}

/// Slot i left the plate: the marks of the slots after it move down.
pub fn removed(app: *App, i: usize) void {
    if (i >= max_slots) return;
    std.mem.copyForwards(Mark, app.slot_marks[i .. max_slots - 1], app.slot_marks[i + 1 ..]);
    app.slot_marks[max_slots - 1] = .{};
}

/// The tray of each filament of the plate, for the ams_mapping of a print
/// start of a Bambu Lab printer: -1 for a filament with no spool of the
/// printer. Returns the count (the filaments of the plate, at most
/// out.len).
pub fn amsMapping(app: *const App, out: []i32) usize {
    const n = @min(slots.count(app), out.len);
    for (out[0..n], 0..) |*t, k| t.* = if (app.slot_marks[k].printer) app.slot_marks[k].tray else -1;
    return n;
}

/// The words for the user: "3 filaments from X2D: A1 PLA, A2 PETG, Ext
/// PLA (2nd nozzle)." and the slots of the user that stay. In `a`.
pub fn message(a: Allocator, app: *const App, spools: []const Spool, r: Result, printer: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const two = twoNozzles(app);
    (blk: {
        if (r.used == 0) {
            if (r.left_out > 0) {
                w.print("The spools of {s} feed its second nozzle only. Pick the printer profile of {s} (two nozzles), or load a spool in the AMS.", .{ printer, printer }) catch |e| break :blk e;
            } else w.writeAll("The printer tells no loaded filaments. Update the deck, or load a spool.") catch |e| break :blk e;
            break :blk;
        }
        w.print("{d} {s} from {s}: ", .{ r.used, if (r.used == 1) "filament" else "filaments", printer }) catch |e| break :blk e;
        var k: usize = 0;
        for (spools) |s| {
            if (s.aux and !two) continue;
            if (k >= r.used) break;
            w.print("{s}{s} {s}{s}", .{ if (k > 0) ", " else "", if (s.slot.len > 0) s.slot else "roll", s.material, if (two and s.aux) " (2nd nozzle)" else "" }) catch |e| break :blk e;
            k += 1;
        }
        w.writeAll(".") catch |e| break :blk e;
        if (r.kept > 0) w.print(" {d} {s} as you set {s}.", .{ r.kept, if (r.kept == 1) "filament stays" else "filaments stay", if (r.kept == 1) "it" else "them" }) catch |e| break :blk e;
        if (r.left_out > 0) {
            w.writeAll(" Not used:") catch |e| break :blk e;
            var j: usize = 0;
            for (spools) |s| if (s.aux) {
                w.print("{s} {s} {s}", .{ if (j > 0) "," else "", if (s.slot.len > 0) s.slot else "spool", s.material }) catch |e| break :blk e;
                j += 1;
            };
            w.print(" (the second nozzle: pick the printer profile of {s}, with two nozzles).", .{printer}) catch |e| break :blk e;
        }
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const testing = std.testing;

test "printer filaments: the slots follow the spools, and a slot of the user stays" {
    var app = try App.create(testing.allocator, null, null);
    defer app.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"filaments":[{"slot":"A1","index":0,"tray":0,"material":"PLA","color":"#FF0000"},
        \\{"slot":"A2","index":1,"tray":1,"material":"petg","color":"#00ff00","idx":"GFG00"},
        \\{"slot":"A4","index":2,"tray":3,"material":"PLA","color":"#ffff00"},
        \\{"slot":"Ext","index":3,"tray":254,"nozzle":"aux","material":"PLA","color":"#0000ff"},
        \\{"slot":"A3","tray":2,"material":""}]}
    ;
    const spools = try parse(a, json);
    try testing.expectEqual(@as(usize, 4), spools.len);
    try testing.expectEqualStrings("PETG", spools[1].material);
    try testing.expectEqualStrings("#ff0000", spools[0].color);
    try testing.expect(spools[3].aux);

    // One nozzle: the spool of the second nozzle stays out.
    var r = try apply(app, spools, .keep_hand);
    try testing.expect(r.changed);
    try testing.expectEqual(@as(usize, 3), r.used);
    try testing.expectEqual(@as(usize, 1), r.left_out);
    try testing.expectEqual(@as(usize, 3), slots.count(app));
    try testing.expectEqualStrings("#ff0000", slots.get(app, 0).?.color);
    try testing.expectEqualStrings("PETG", slots.get(app, 1).?.material);
    // The profile of PETG: a hotter nozzle than PLA.
    try testing.expect(slots.get(app, 1).?.nozzle_temp > slots.get(app, 2).?.nozzle_temp);
    try testing.expectEqualStrings("A4", app.slot_marks[2].name());
    try testing.expectEqualStrings("GFG00", app.slot_marks[1].idx());
    var map: [16]i32 = undefined;
    try testing.expectEqual(@as(usize, 3), amsMapping(app, &map));
    try testing.expectEqualSlices(i32, &.{ 0, 1, 3 }, map[0..3]);
    const msg = try message(a, app, spools, r, "X2D");
    try testing.expect(std.mem.startsWith(u8, msg, "3 filaments from X2D: A1 PLA, A2 PETG, A4 PLA."));

    // The same spools again: no change.
    r = try apply(app, spools, .keep_hand);
    try testing.expect(!r.changed);

    // The user sets slot 2 by hand: it stays, the other slots follow.
    try slots.set(app, 1, "filament.color", "#123456");
    markHand(app, 1);
    const other = try parse(a,
        \\[{"slot":"A1","tray":0,"material":"PLA","color":"#ffffff"},{"slot":"A2","tray":1,"material":"PLA","color":"#000000"}]
    );
    r = try apply(app, other, .keep_hand);
    try testing.expect(r.changed);
    try testing.expectEqual(@as(usize, 1), r.kept);
    try testing.expectEqual(@as(usize, 2), slots.count(app));
    try testing.expectEqualStrings("#ffffff", slots.get(app, 0).?.color);
    try testing.expectEqualStrings("#123456", slots.get(app, 1).?.color);
    try testing.expectEqual(@as(usize, 2), amsMapping(app, &map));
    try testing.expectEqual(@as(i32, -1), map[1]);
    // A printer that pauses for a change: the follow keeps the slots.
    r = try apply(app, spools, .follow);
    try testing.expect(!r.changed);
    try testing.expectEqual(@as(usize, 2), slots.count(app));
    // "Use the printer's filament": the slot of the user follows again.
    r = try apply(app, other, .take_hand);
    try testing.expectEqualStrings("#000000", slots.get(app, 1).?.color);
    try testing.expectEqual(@as(i32, 1), app.slot_marks[1].tray);
}

test "printer filaments: two nozzles take the spool of the second nozzle" {
    var app = try App.create(testing.allocator, null, null);
    defer app.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try app.setSetting("machine.nozzles", "2");
    const spools = try parse(arena.allocator(),
        \\[{"slot":"A1","tray":0,"material":"PLA","color":"#ff0000"},{"slot":"Ext","tray":254,"nozzle":"aux","material":"PLA","color":"#0000ff"}]
    );
    const r = try apply(app, spools, .keep_hand);
    try testing.expectEqual(@as(usize, 2), r.used);
    try testing.expectEqual(@as(u32, 1), slots.get(app, 1).?.nozzle);
    try testing.expectEqual(@as(u32, 0), slots.get(app, 0).?.nozzle);
}
