//! A calibration print on a plate (see calib.zig for the test parts).
//!
//! `add` puts the test parts of a calibration on the plate of an app, and
//! sets the values of the test with the tools that a user has: a layer
//! range (an override with a name) for each step of a tower, or the
//! settings of each part for a test of parts. The user sees each value
//! and can change it, and the history and the Check work as for any
//! plate. With a printer that changes the filament by itself
//! (`machine.filament_change = tool`), each step gets a label with its
//! value in a second filament (app/labels.zig).
//!
//! The app keeps the plan (`Calibration`): how to read the print, the
//! setting of the test, and the value of each step, for the shells to
//! show and to set the value that the user picks.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const calib = zs.calib;
const labels_mod = @import("labels.zig");
const filament_slots = @import("filament_slots.zig");

/// The calibration of a plate. The strings are in `App.strings`.
pub const Calibration = struct {
    kind: calib.Kind,
    name: []const u8,
    setting: []const u8,
    note: []const u8,
    /// Each step: its text and the value of `setting`.
    steps: []const calib.Step,
};

pub const Error = calib.Error || error{ NotEmpty, BadLabel, NoLabel, TooMany, NoPart, NoSlot } || zs.settings.Settings.SetError || App.OverrideError;

/// Puts the test of `kind` on the plate of `app`. The plate must be empty
/// (a new plate): the layer ranges of a tower are for the whole plate.
pub fn add(app: *App, kind: calib.Kind) Error!void {
    if (app.plate.count() > 0) return error.NotEmpty;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try calib.plan(app.gpa, arena, kind, app.settings);
    defer p.deinit(app.gpa);
    const first = app.plate.count();
    for (p.parts) |*part| {
        const m = part.mesh;
        part.mesh = .empty;
        const i = try app.addMeshPart(part.name, m);
        for (part.changes) |c| app.setPartSetting(i, c.name, c.value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
    }
    if (p.parts.len > 1) _ = try app.arrangePlate();
    // The steps of a tower: a named layer range for each.
    if (p.layers) for (p.steps) |st| {
        var buf: [32]u8 = undefined;
        const v = std.fmt.bufPrint(&buf, "{d}", .{st.value}) catch unreachable;
        try app.setOverride(st.z_min, st.z_max, p.setting, v);
        const name = try std.fmt.allocPrint(arena, "{s} {s}", .{ kind.title(), st.text });
        try app.setProfile(st.z_min, st.z_max, name);
    };
    // The labels, in a second filament, if the printer changes it by
    // itself: a pause for each label is no use.
    if (app.settings.machine.filament_change == .tool) {
        if (filament_slots.count(app) < 2) _ = filament_slots.add(app) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        if (filament_slots.count(app) >= 2) for (p.labels) |l| {
            const part = &app.plate.parts.items[first + l.part];
            var json: std.Io.Writer.Allocating = .init(arena);
            json.writer.print("{{\"name\":\"{s}\",\"origin\":[{d},{d},{d}],\"normal\":[{d},{d},{d}],\"right\":[{d},{d},{d}],\"filament\":2,\"items\":[{{\"kind\":\"text\",\"text\":\"{s}\",\"size\":{d}}}]}}", .{
                l.text,
                part.x + l.origin[0], part.y + l.origin[1], l.origin[2],
                l.normal[0], l.normal[1], l.normal[2],
                l.right[0], l.right[1], l.right[2],
                l.text, l.size,
            }) catch return error.OutOfMemory;
            _ = try labels_mod.add(app, first + l.part, json.written());
        };
    }
    // The plan, for the shells.
    const a = app.strings.allocator();
    const steps = try a.alloc(calib.Step, p.steps.len);
    for (p.steps, steps) |st, *d| {
        d.* = st;
        d.text = try a.dupe(u8, st.text);
    }
    app.calibration = .{
        .kind = kind,
        .name = try a.dupe(u8, p.name),
        .setting = try a.dupe(u8, p.setting),
        .note = try a.dupe(u8, p.note),
        .steps = steps,
    };
    try app.plateChanged();
    app.state.store(.ready, .release);
}

/// The calibration of the plate as text: "kind\t<name of the kind>",
/// "name\t<plate name>", "setting\t<setting>", "note\t<how to read
/// it>", then "step\t<text>\t<value of the setting>" for each step, the
/// first (the bottom, or the first part) first.
pub fn write(c: Calibration, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("kind\t{s}\nname\t{s}\nsetting\t{s}\nnote\t{s}\n", .{ @tagName(c.kind), c.name, c.setting, c.note });
    for (c.steps) |st| try w.print("step\t{s}\t{d}\n", .{ st.text, st.value });
}

const testing = std.testing;

test "a temperature tower on a plate: a layer range for each block, and labels with a tool changer" {
    const app = try App.create(testing.allocator, null, null);
    defer app.destroy();
    try app.setSetting("machine.filament_change", "tool");
    try add(app, .temperature);
    try testing.expectEqual(@as(usize, 1), app.plate.count());
    const c = app.calibration.?;
    try testing.expectEqualStrings("filament.nozzle_temp", c.setting);
    // A layer range for each block, with its temperature.
    try testing.expectEqual(c.steps.len, app.overrides.items.len);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try app.getSettingAt(c.steps[2].z_min + 1, "filament.nozzle_temp", &w);
    try testing.expectEqualStrings("220", w.buffered());
    // The labels, in filament 2.
    try testing.expectEqual(c.steps.len, app.plate.parts.items[0].labels.items.len);
    try testing.expectEqual(@as(usize, 2), filament_slots.count(app));
    // A plate with a part already: no test.
    try testing.expectError(error.NotEmpty, add(app, .flow));
}

test "a flow test: a part with its own flow for each step" {
    const app = try App.create(testing.allocator, null, null);
    defer app.destroy();
    try add(app, .flow);
    const c = app.calibration.?;
    try testing.expectEqual(c.steps.len, app.plate.count());
    try testing.expectEqualStrings("0.8", app.partSetting(0, "filament.flow_ratio").?);
    try testing.expectEqualStrings("1.2", app.partSetting(8, "filament.flow_ratio").?);
    // A pause printer: no labels.
    try testing.expectEqual(@as(usize, 0), app.plate.parts.items[0].labels.items.len);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(c, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "step\t-20 %\t0.8\n") != null);
}

test "each calibration slices, and the G-code has its values" {
    inline for (.{ calib.Kind.temperature, calib.Kind.retraction, calib.Kind.flow, calib.Kind.pressure_advance }) |k| {
        const app = try App.create(testing.allocator, null, null);
        defer app.destroy();
        try app.setSetting("machine.gcode_flavor", "klipper");
        try add(app, k);
        try app.startSlice();
        app.stopWorkerForTest();
        const g = app.gcode() orelse return error.TestUnexpectedResult;
        switch (k) {
            // The blocks: 230 °C at the bottom, then 225 °C, to 190 °C.
            .temperature => {
                try testing.expect(std.mem.indexOf(u8, g, "M104 S225\n") != null);
                try testing.expect(std.mem.indexOf(u8, g, "M104 S190\n") != null);
            },
            .pressure_advance => try testing.expect(std.mem.indexOf(u8, g, "SET_PRESSURE_ADVANCE ADVANCE=0.18\n") != null),
            // Longer retractions on the higher bands.
            .retraction => try testing.expect(std.mem.indexOf(u8, g, "G1 E-1.4 F") != null),
            .flow => try testing.expectEqual(@as(usize, 9), app.plate.count()),
        }
    }
}
