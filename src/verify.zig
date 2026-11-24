//! The slice verifier: proof that kept work does not change the output.
//!
//! The app keeps work between slices. A key that misses an input gives a
//! wrong slice with no error. This tool finds such a fault by differential
//! testing. Two apps get the same edits:
//!
//! - `inc` keeps its work between slices, as a user's app does.
//! - `full` calls `App.dropWork` before each slice, so each of its slices
//!   starts from the mesh.
//!
//! After each edit both apps slice. The G-code bytes, each array of the
//! toolpaths, and the statistics must be equal. A difference is a fault.
//! The report has the seed, the step, the edit, the first byte that
//! differs, and its level. Then `inc` drops its work, so that the next
//! steps test the next faults.
//!
//! Each edit is one value of the union `Edit`. The generator makes the
//! value once, and both apps get it. So the two apps see the same random
//! choices, and one seed gives one list of edits. The result has a hash of
//! that list.
//!
//! The modes:
//!
//! - Random: each step picks one edit of the user.
//! - Sweep: each value of each setting, from three base states, and back.
//! - Ranges: an override of one layer setting on three z ranges, alone and
//!   in pairs.
//! - Restore: a third app loads the 3MF of `full` after each eighth step.
//!   A difference counts in its own total.
//!
//! Reference: differential testing (W. McKeeman, 1998), see
//! docs/references/papers-and-algorithms.md.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("root.zig");
const App = zs.app.App;
const Toolpaths = zs.app.Toolpaths;
const clock = zs.stage_clock;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const SettingInfo = @import("app/setting_info.zig").SettingInfo;

/// One model of the plate: a file name and its bytes.
pub const Model = struct { name: []const u8, bytes: []const u8 };

pub const Options = struct {
    seeds: []const u64 = &.{ 11, 22, 33 },
    steps: usize = 40,
    /// Run the random edits.
    random: bool = true,
    /// Run the sweep of the settings.
    sweep: bool = false,
    /// The base states of the sweep: 1 to 4. The fourth has 4 nozzles,
    /// and sweeps only the settings of the nozzles: their gate is open
    /// for nozzles 1 to 3 and closed for the others.
    sweep_bases: usize = 4,
    /// A layer setting, or "all".
    ranges: ?[]const u8 = null,
    /// Check a load of the 3MF after each eighth step.
    restore: bool = false,
    /// Base settings for both apps, as "group.name=value".
    sets: []const []const u8 = &.{},
    /// Settings that the random edits and the sweep leave out.
    skip: []const []const u8 = &.{},
};

pub const Result = struct {
    steps: usize = 0,
    faults: usize = 0,
    restore_steps: usize = 0,
    restore_faults: usize = 0,
    /// Steps where both apps failed in the same way.
    failed_slices: usize = 0,
    /// A hash of the list of edits of the random mode.
    edits_hash: u64 = 0,
    /// The random edits that both apps applied, for each kind of edit.
    kinds: [@typeInfo(@typeInfo(Edit).@"union".tag_type.?).@"enum".fields.len]usize = @splat(0),
};

const Set = struct { name: []const u8, value: []const u8 };

/// The change of the part after a filament edit of a line, in the same
/// step.
const LineThen = union(enum) {
    none,
    move: [2]f64,
    turn_z: f64,
    mirror: u1,
};

const Edit = union(enum) {
    set: Set,
    part_set: struct { part: usize, set: Set },
    range: struct { z0: f64, z1: f64, set: Set },
    move: struct { part: usize, dx: f64, dy: f64 },
    turn_z: struct { part: usize, deg: f64 },
    turn_xy: struct { part: usize, axis: u2, deg: f64 },
    scale: struct { part: usize, f: f64 },
    mirror: struct { part: usize, axis: u1 },
    copy: usize,
    delete: usize,
    arrange,
    line: struct { key: u64, kind: zs.app.edits_mod.Kind, value: f32, layer: u32, zc: i32 },
    /// A filament for one line or one segment (edits.Anchor). The anchor
    /// comes from `inc`. Each app puts the id of its own part in it. Then
    /// the part can move, turn, or mirror in the same step.
    line_fil: struct { part: usize, anchor: zs.app.edits_mod.Anchor, filament: u32, layer: u32, then: LineThen },
    /// A new filament for filament edit `index` of the edit list.
    fil_value: struct { index: usize, filament: u32 },
    add_slot,
    part_slot: struct { part: usize, slot: u32 },
    range_slot: struct { z0: f64, z1: f64, slot: u32 },
    mark: struct { x: f64, y: f64, z: f64 },
    area: struct { x: f64, y: f64, z0: f64, z1: f64 },
    paint: struct { part: usize, at: f64 },
    undo,
    redo,
    draft: struct { n: u8, sets: [3]Set },
    cancel: u32,
    /// `engine.form_budget_mb` of 1 in `inc` for one slice.
    budget,

    fn write(e: Edit, w: *Io.Writer) Io.Writer.Error!void {
        switch (e) {
            .set => |s| try w.print("set {s}={s}", .{ s.name, s.value }),
            .part_set => |x| try w.print("part {d} set {s}={s}", .{ x.part, x.set.name, x.set.value }),
            .range => |x| try w.print("range {d:.3}..{d:.3} {s}={s}", .{ x.z0, x.z1, x.set.name, x.set.value }),
            .move => |x| try w.print("move {d} by {d:.4},{d:.4}", .{ x.part, x.dx, x.dy }),
            .turn_z => |x| try w.print("turn {d} about z to {d:.3}", .{ x.part, x.deg }),
            .turn_xy => |x| try w.print("turn {d} about axis {d} by {d:.3}", .{ x.part, x.axis, x.deg }),
            .scale => |x| try w.print("scale {d} to {d:.4}", .{ x.part, x.f }),
            .mirror => |x| try w.print("mirror {d} axis {d}", .{ x.part, x.axis }),
            .copy => |p| try w.print("copy {d}", .{p}),
            .delete => |p| try w.print("delete {d}", .{p}),
            .arrange => try w.writeAll("arrange"),
            .line => |x| try w.print("line {x} {s} {d:.2} level {d} zc {d}", .{ x.key, @tagName(x.kind), x.value, x.layer, x.zc }),
            .line_fil => |x| {
                try w.print("line filament {d} part {d} feature {d} {s} level {d}", .{ x.filament, x.part, x.anchor.feature, if (x.anchor.whole) "line" else "segment", x.layer });
                switch (x.then) {
                    .none => {},
                    .move => |d| try w.print(", then move by {d:.4},{d:.4}", .{ d[0], d[1] }),
                    .turn_z => |d| try w.print(", then turn about z to {d:.3}", .{d}),
                    .mirror => |ax| try w.print(", then mirror axis {d}", .{ax}),
                }
            },
            .fil_value => |x| try w.print("filament edit {d} to filament {d}", .{ x.index, x.filament }),
            .add_slot => try w.writeAll("add a filament slot"),
            .part_slot => |x| try w.print("part {d} filament {d}", .{ x.part, x.slot }),
            .range_slot => |x| try w.print("range {d:.3}..{d:.3} filament {d}", .{ x.z0, x.z1, x.slot }),
            .mark => |x| try w.print("mark {d:.2},{d:.2},{d:.2}", .{ x.x, x.y, x.z }),
            .area => |x| try w.print("area {d:.2},{d:.2} z {d:.2}..{d:.2}", .{ x.x, x.y, x.z0, x.z1 }),
            .paint => |x| try w.print("paint part {d} at {d:.3}", .{ x.part, x.at }),
            .undo => try w.writeAll("undo"),
            .redo => try w.writeAll("redo"),
            .draft => |x| {
                try w.print("draft of {d}:", .{x.n});
                for (x.sets[0..x.n]) |s| try w.print(" {s}={s}", .{ s.name, s.value });
            },
            .cancel => |ms| try w.print("cancel after {d} ms", .{ms}),
            .budget => try w.writeAll("a budget of 1 MB for one slice"),
        }
    }

    /// True for an edit of the plate. The other edits change one setting.
    fn isPlate(e: Edit) bool {
        return switch (e) {
            .set, .undo, .redo, .cancel, .draft, .budget => false,
            else => true,
        };
    }
};

/// Slices and waits. True if the slice ended with a result.
fn sliceApp(app: *App) bool {
    app.requestSlice() catch return false;
    app.waitSlice();
    return app.getState() == .done;
}

/// The first difference of two slices.
const Diff = struct { what: []const u8, offset: usize, level: usize };

/// The level of a byte of the G-code: the `;LAYER:` lines before it.
fn levelOf(g: []const u8, offset: usize) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, g, at, ";LAYER:")) |k| {
        if (k >= offset) break;
        n += 1;
        at = k + 1;
    }
    return n;
}

/// Compares the G-code, each array of the toolpaths, and the statistics.
fn compare(a: *const App, b: *const App) ?Diff {
    const ga = a.gcode() orelse "";
    const gb = b.gcode() orelse "";
    if (std.mem.indexOfDiff(u8, ga, gb)) |k| return .{ .what = "G-code", .offset = k, .level = levelOf(ga, k) };
    inline for (@typeInfo(Toolpaths).@"struct".fields) |f| {
        if (comptime !isList(f.type)) continue;
        const x = std.mem.sliceAsBytes(@field(a.toolpaths, f.name).items);
        const y = std.mem.sliceAsBytes(@field(b.toolpaths, f.name).items);
        if (std.mem.indexOfDiff(u8, x, y)) |k| return .{ .what = "toolpaths." ++ f.name, .offset = k, .level = 0 };
    }
    if (!std.meta.eql(a.stats, b.stats)) return .{ .what = "statistics", .offset = 0, .level = 0 };
    return null;
}

fn isList(T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity");
}

/// The count of the levels whose text differs.
fn levelsChanged(a: []const u8, b: []const u8) usize {
    var ia = std.mem.splitSequence(u8, a, "\n;LAYER:");
    var ib = std.mem.splitSequence(u8, b, "\n;LAYER:");
    var n: usize = 0;
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return n;
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) n += 1;
    }
}

const Twin = struct {
    gpa: Allocator,
    io: Io,
    inc: *App,
    full: *App,
    opts: *const Options,
    report: *Io.Writer,
    result: *Result,
    /// The time of the undo list: one second more for each step.
    now_ms: i64 = 0,

    fn init(gpa: Allocator, io: Io, models: []const Model, opts: *const Options, report: *Io.Writer, result: *Result) !Twin {
        const inc = try makeApp(gpa, models, opts);
        errdefer inc.destroy();
        const full = try makeApp(gpa, models, opts);
        return .{ .gpa = gpa, .io = io, .inc = inc, .full = full, .opts = opts, .report = report, .result = result };
    }

    fn deinit(t: *Twin) void {
        t.inc.destroy();
        t.full.destroy();
    }

    fn apps(t: *Twin) [2]*App {
        return .{ t.inc, t.full };
    }

    /// Slices both apps and compares them. `what` names the step.
    fn check(t: *Twin, seed: u64, step: usize, e: ?Edit, what: []const u8) !bool {
        const ok_inc = sliceApp(t.inc);
        t.full.dropWork();
        const ok_full = sliceApp(t.full);
        t.result.steps += 1;
        var diff: ?Diff = null;
        if (ok_inc != ok_full) {
            diff = .{ .what = if (ok_inc) "only full failed" else "only inc failed", .offset = 0, .level = 0 };
        } else if (ok_inc) {
            diff = compare(t.inc, t.full);
        } else {
            t.result.failed_slices += 1;
        }
        // A key of a mesh that is not the key of the mesh now: the next
        // slice can keep a placed mesh of before (plate.Part.mesh_key).
        if (diff == null and !t.inc.meshKeysFresh()) diff = .{ .what = "a mesh key", .offset = 0, .level = 0 };
        const d = diff orelse return ok_inc;
        t.result.faults += 1;
        try t.report.print("FAULT seed {d} step {d}: ", .{ seed, step });
        if (e) |x| try x.write(t.report) else try t.report.writeAll(what);
        try t.report.print(": {s} differs at byte {d}, level {d}\n", .{ d.what, d.offset, d.level });
        try t.report.flush();
        t.inc.dropWork();
        return ok_inc;
    }
};

fn makeApp(gpa: Allocator, models: []const Model, opts: *const Options) !*App {
    const app = try App.create(gpa, null, null);
    errdefer app.destroy();
    for (opts.sets) |v| {
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse return error.InvalidValue;
        try app.setSetting(v[0..eq], v[eq + 1 ..]);
    }
    try app.loadStl(models[0].name, models[0].bytes);
    for (models[1..]) |m| _ = try app.addStl(m.name, m.bytes);
    if (models.len > 1) _ = try app.arrangePlate();
    return app;
}

fn skipped(opts: *const Options, name: []const u8) bool {
    for (opts.skip) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

fn infoOf(name: []const u8) ?SettingInfo {
    for (zs.app.settings_info) |i| if (std.mem.eql(u8, i.name, name)) return i;
    return null;
}

/// A value of a setting that differs from its value now, or null.
fn pickValue(a: Allocator, rnd: std.Random, info: SettingInfo, s: zs.Settings) !?[]const u8 {
    const values = try zs.app.sweep.valuesOf(a, info, s, 3);
    if (values.len < 2) return null;
    return values[1 + rnd.uintLessThan(usize, values.len - 1)];
}

fn pickSet(a: Allocator, rnd: std.Random, opts: *const Options, s: zs.Settings) !?Set {
    const all = zs.app.settings_info;
    for (0..16) |_| {
        const info = all[rnd.uintLessThan(usize, all.len)];
        if (info.kind == .text or skipped(opts, info.name)) continue;
        const v = (try pickValue(a, rnd, info, s)) orelse continue;
        return .{ .name = info.name, .value = v };
    }
    return null;
}

fn pickLayerSet(a: Allocator, rnd: std.Random, opts: *const Options, s: zs.Settings) !?Set {
    const names = zs.settings.layer_settings;
    for (0..16) |_| {
        const name = names[rnd.uintLessThan(usize, names.len)];
        if (skipped(opts, name)) continue;
        const info = infoOf(name) orelse continue;
        if (info.kind == .text) continue;
        const v = (try pickValue(a, rnd, info, s)) orelse continue;
        return .{ .name = name, .value = v };
    }
    return null;
}

/// The height of the print of the last slice (mm).
fn topZ(app: *const App) f64 {
    const z = app.toolpaths.layer_z.items;
    return if (z.len > 0) z[z.len - 1] else 20;
}

/// Makes one edit from the state of `inc`. Both apps get this value.
fn nextEdit(a: Allocator, rnd: std.Random, t: *Twin) !Edit {
    const inc = t.inc;
    const parts = inc.plate.count();
    const part = rnd.uintLessThan(usize, parts);
    const top = topZ(inc);
    const roll = rnd.uintLessThan(u32, 100);
    const r1 = rnd.float(f64);
    const r2 = rnd.float(f64);
    const z0 = r1 * top * 0.7;
    const z1 = z0 + 0.5 + r2 * top * 0.3;
    const slots: u32 = @intCast(zs.app.filament_slots.count(inc));
    const fallback: Edit = .{ .move = .{ .part = part, .dx = r1 * 4 - 2, .dy = r2 * 4 - 2 } };
    switch (roll) {
        0...31 => return .{ .set = (try pickSet(a, rnd, t.opts, inc.settings)) orelse return fallback },
        32...39 => return lineFilEdit(a, rnd, t, slots) catch fallback,
        40...44 => return .{ .part_set = .{ .part = part, .set = (try pickLayerSet(a, rnd, t.opts, inc.settings)) orelse return fallback } },
        45...52 => return .{ .range = .{ .z0 = z0, .z1 = z1, .set = (try pickLayerSet(a, rnd, t.opts, inc.settings)) orelse return fallback } },
        53...56 => return fallback,
        57...59 => return .{ .turn_z = .{ .part = part, .deg = r1 * 360 } },
        60...61 => return .{ .turn_xy = .{ .part = part, .axis = if (r2 < 0.5) 0 else 1, .deg = 15 + r1 * 75 } },
        62...63 => return .{ .scale = .{ .part = part, .f = 0.8 + r1 * 0.4 } },
        64 => return .{ .mirror = .{ .part = part, .axis = if (r2 < 0.5) 0 else 1 } },
        65...66 => return if (parts < 4) .{ .copy = part } else fallback,
        67 => return if (parts > 1) .{ .delete = part } else fallback,
        68 => return .arrange,
        69...74 => {
            // One line edit in three changes the value of an edit that
            // exists, so a key that has an edit but not its value fails.
            const have = inc.edits.list.items;
            if (have.len > 0 and rnd.uintLessThan(u8, 3) == 0) {
                const e = have[rnd.uintLessThan(usize, have.len)];
                if (e.kind != .dot and e.kind != .filament) return .{ .line = .{ .key = e.key, .kind = e.kind, .value = 0.5 + @as(f32, @floatCast(r1)), .layer = e.layer, .zc = e.zc } };
            }
            const keys = inc.toolpaths.path_key.items;
            if (keys.len < 10) return fallback;
            const k = rnd.uintLessThan(usize, keys.len);
            const kind: zs.app.edits_mod.Kind = if (r2 < 0.5) .flow else .delete;
            const level = levelOfPath(inc, k);
            // One edit in four has no z, as an edit of an older file.
            const lz = inc.toolpaths.layer_z.items;
            const zc = if (rnd.uintLessThan(u8, 4) == 0 or level >= lz.len) zs.app.edits_mod.no_zc else zs.app.edits_mod.zcOf(lz[level]);
            return .{ .line = .{ .key = keys[k], .kind = kind, .value = 0.5 + @as(f32, @floatCast(r1)), .layer = level, .zc = zc } };
        },
        75 => return if (slots < 4) .add_slot else fallback,
        76...77 => return if (slots >= 2) .{ .part_slot = .{ .part = part, .slot = 1 + rnd.uintLessThan(u32, slots) } } else .add_slot,
        78...79 => return if (slots >= 2) .{ .range_slot = .{ .z0 = z0, .z1 = z1, .slot = 1 + rnd.uintLessThan(u32, slots) } } else .add_slot,
        80...81 => {
            const p = inc.plate.parts.items[part];
            return .{ .mark = .{ .x = p.x + r2 * 4 - 2, .y = p.y + r1 * 4 - 2, .z = z0 } };
        },
        82...83 => {
            const p = inc.plate.parts.items[part];
            return .{ .area = .{ .x = p.x, .y = p.y, .z0 = z0, .z1 = z1 } };
        },
        84...85 => return .{ .paint = .{ .part = part, .at = r1 } },
        86...89 => return .undo,
        90...91 => return .redo,
        92...95 => {
            var d: Edit = .{ .draft = .{ .n = 1 + rnd.uintLessThan(u8, 3), .sets = undefined } };
            for (&d.draft.sets) |*s| s.* = (try pickSet(a, rnd, t.opts, inc.settings)) orelse return fallback;
            return d;
        },
        96...97 => return .budget,
        else => return .{ .cancel = rnd.uintLessThan(u32, 51) },
    }
}

/// A filament edit of a line of `inc`: a new one, or one in three a new
/// filament of an edit that exists. Half of the new ones are of one
/// segment, so the plan cuts the line. Half of them move, turn, or mirror
/// the part in the same step.
fn lineFilEdit(a: Allocator, rnd: std.Random, t: *Twin, slots: u32) !Edit {
    if (slots < 2) return .add_slot;
    const inc = t.inc;
    const filament = 1 + rnd.uintLessThan(u32, slots);
    const have = inc.edits.list.items;
    if (have.len > 0 and rnd.uintLessThan(u8, 3) == 0) {
        const i = rnd.uintLessThan(usize, have.len);
        if (have[i].anchor != null) return .{ .fil_value = .{ .index = i, .filament = filament } };
    }
    const tp = inc.allToolpaths() orelse return error.NoResult;
    const n = tp.pathCount();
    if (n < 10) return error.NoResult;
    const no_part = zs.layer.LayerPlan.no_part;
    const skirt = @intFromEnum(zs.settings.Feature.skirt);
    for (0..16) |_| {
        const p = rnd.uintLessThan(usize, n);
        if (tp.path_part.items[p] == no_part or tp.path_features.items[p] == skirt) continue;
        var beads: std.ArrayList(f32) = .empty;
        try zs.app.oneBeads(a, inc, p, &beads);
        const count = beads.items.len / zs.body_region.stride;
        if (count == 0) continue;
        const seg: isize = if (rnd.boolean()) -1 else @intCast(rnd.uintLessThan(usize, count));
        const anchor = inc.lineAnchor(beads.items, seg, tp.path_features.items[p]) catch continue;
        const part: usize = @intFromFloat(beads.items[0]);
        if (part >= inc.plate.count()) continue;
        const r = rnd.float(f64);
        const then: LineThen = switch (rnd.uintLessThan(u8, 6)) {
            0 => .{ .move = .{ r * 6 - 3, rnd.float(f64) * 6 - 3 } },
            1 => .{ .turn_z = r * 360 },
            2 => .{ .mirror = if (r < 0.5) 0 else 1 },
            else => .none,
        };
        return .{ .line_fil = .{ .part = part, .anchor = anchor, .filament = filament, .layer = @intFromFloat(beads.items[1]), .then = then } };
    }
    return error.NoResult;
}

fn levelOfPath(app: *const App, path: usize) u32 {
    for (app.toolpaths.layer_ends.items, 0..) |end, l| if (path < end) return @intCast(l);
    return 0;
}

/// The change of an edit on one app, and its note in the undo list.
fn apply(app: *App, e: Edit, now_ms: i64) !void {
    const gpa = app.gpa;
    var buf: [16]u8 = undefined;
    switch (e) {
        .set => |s| try app.setSetting(s.name, s.value),
        .part_set => |x| try app.setPartSetting(x.part, x.set.name, x.set.value),
        .range => |x| try app.setOverride(x.z0, x.z1, x.set.name, x.set.value),
        .move => |x| {
            const p = &app.plate.parts.items[x.part];
            try app.movePart(x.part, p.x + x.dx, p.y + x.dy);
        },
        .turn_z => |x| try app.rotatePart(x.part, x.deg),
        .turn_xy => |x| try app.turnPart(x.part, x.axis, x.deg),
        .scale => |x| try app.scalePart(x.part, .{ x.f, x.f, x.f }),
        .mirror => |x| try app.mirrorPart(x.part, x.axis),
        .copy => |p| _ = try app.duplicatePart(p),
        .delete => |p| try app.removePart(p),
        .arrange => _ = try app.arrangePlate(),
        .line => |x| try app.edits.put(gpa, .{ .key = x.key, .kind = x.kind, .value = x.value, .layer = x.layer, .zc = x.zc }),
        .line_fil => |x| {
            var an = x.anchor;
            an.part = app.plate.parts.items[x.part].id;
            _ = try app.edits.putFilament(gpa, an, x.filament, x.layer);
            switch (x.then) {
                .none => {},
                .move => |d| {
                    const p = &app.plate.parts.items[x.part];
                    try app.movePart(x.part, p.x + d[0], p.y + d[1]);
                },
                .turn_z => |d| try app.rotatePart(x.part, d),
                .mirror => |ax| try app.mirrorPart(x.part, ax),
            }
        },
        .fil_value => |x| {
            const list = app.edits.list.items;
            if (x.index < list.len and list[x.index].anchor != null) list[x.index].value = @floatFromInt(x.filament);
        },
        .add_slot => _ = try zs.app.filament_slots.add(app),
        .part_slot => |x| try app.setPartSetting(x.part, "project.filament", try std.fmt.bufPrint(&buf, "{d}", .{x.slot})),
        .range_slot => |x| try app.setOverride(x.z0, x.z1, "project.filament", try std.fmt.bufPrint(&buf, "{d}", .{x.slot})),
        .mark => |x| try app.addMark(.{ .x = x.x, .y = x.y, .z = x.z, .r = 3, .kind = .grid }),
        .area => |x| {
            const pts = [_][3]f64{ .{ x.x - 5, x.y - 5, x.z0 }, .{ x.x + 5, x.y - 5, x.z0 }, .{ x.x + 5, x.y + 5, x.z0 }, .{ x.x - 5, x.y + 5, x.z0 } };
            _ = try app.areas.add(gpa, .tree, &pts, x.z0, x.z1);
        },
        .paint => |x| try paintPart(app, x.part, x.at),
        .undo => {
            _ = app.undo.undo(app, now_ms);
            return;
        },
        .redo => {
            _ = app.undo.redo(app, now_ms);
            return;
        },
        .draft => |x| for (x.sets[0..x.n]) |s| try app.setSetting(s.name, s.value),
        .cancel, .budget => return,
    }
    app.undo.note(gpa, if (e == .set) e.set.name else null, e.isPlate());
    _ = app.undo.commit(app, now_ms);
}

/// A stroke of a brush of 3 mm on a part, with filament 2.
fn paintPart(app: *App, i: usize, at: f64) !void {
    const gpa = app.gpa;
    if (zs.app.filament_slots.count(app) < 2) _ = try zs.app.filament_slots.add(app);
    const part = &app.plate.parts.items[i];
    const m = &part.mesh;
    if (m.vertices.items.len == 0) return;
    var grid = try zs.paint.Grid.init(gpa, m);
    defer grid.deinit(gpa);
    const Ctx = struct {
        gpa: Allocator,
        list: std.ArrayList(u32) = .empty,
        fn add(cx: *@This(), t: u32) void {
            cx.list.append(cx.gpa, t) catch {};
        }
    };
    var ctx: Ctx = .{ .gpa = gpa };
    defer ctx.list.deinit(gpa);
    const n: f64 = @floatFromInt(m.vertices.items.len - 1);
    const v = m.vertices.items[@intFromFloat(at * n)];
    const c: zs.paint.V3 = .{ v.x, v.y, v.z };
    grid.near(c, 3, &ctx, Ctx.add);
    const sphere: zs.paint.Sphere = .{ .c = c, .r = 3 };
    for (ctx.list.items) |t| _ = try zs.paint.brushTriangle(&part.paint, gpa, m, t, sphere, 2, 0.3);
    try app.plateChanged();
}

/// A third app loads the 3MF of `full`. Its G-code must equal the G-code
/// of `full`.
fn checkRestore(t: *Twin, seed: u64, step: usize) !void {
    const full = t.full;
    if (full.getState() != .done) return;
    const file = try full.write3mfAlloc(t.gpa);
    defer t.gpa.free(file);
    const fresh = try App.create(t.gpa, null, null);
    defer fresh.destroy();
    fresh.settings = full.settings;
    try fresh.loadStl("verify.3mf", file);
    fresh.settings = full.settings;
    for (full.edits.list.items) |e| try fresh.edits.put(t.gpa, .{ .key = e.key, .kind = e.kind, .value = e.value, .layer = e.layer, .x = e.x, .y = e.y, .z = e.z, .zc = e.zc, .anchor = e.anchor });
    t.result.restore_steps += 1;
    const same = sliceApp(fresh) and std.mem.eql(u8, fresh.gcode() orelse "", full.gcode() orelse "");
    if (same) return;
    t.result.restore_faults += 1;
    const ga = fresh.gcode() orelse "";
    const k = std.mem.indexOfDiff(u8, ga, full.gcode() orelse "") orelse 0;
    try t.report.print("RESTORE seed {d} step {d}: G-code differs at byte {d}, level {d}\n", .{ seed, step, k, levelOf(ga, k) });
    try t.report.flush();
}

fn runRandom(gpa: Allocator, io: Io, models: []const Model, opts: *const Options, report: *Io.Writer, result: *Result) !void {
    var list_hash = std.hash.Wyhash.init(0x7e51);
    for (opts.seeds) |seed| {
        var t = try Twin.init(gpa, io, models, opts, report, result);
        defer t.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng: std.Random.DefaultPrng = .init(seed);
        const rnd = prng.random();
        // The result must not depend on the thread count: in the last
        // seed of more than one, `inc` slices with one thread.
        if (opts.seeds.len > 1 and seed == opts.seeds[opts.seeds.len - 1]) try t.inc.setSetting("engine.threads", "1");
        for (t.apps()) |app| _ = app.undo.commit(app, 0);
        _ = try t.check(seed, 0, null, "first slice");
        var text: [512]u8 = undefined;
        for (1..opts.steps + 1) |step| {
            t.now_ms += 1000;
            const e = try nextEdit(arena, rnd, &t);
            var tw: Io.Writer = .fixed(&text);
            e.write(&tw) catch {};
            list_hash.update(tw.buffered());
            list_hash.update("\n");
            // The two apps of a draft or a cancel differ only in the work
            // that `inc` does before the compare.
            const saved = [2]zs.Settings{ t.inc.settings, t.full.settings };
            // A draft changes its settings one at a time on `inc`, with a
            // draft slice after each one.
            if (e == .draft) {
                t.inc.setDraft(true);
                for (e.draft.sets[0..e.draft.n]) |s| {
                    t.inc.setSetting(s.name, s.value) catch {};
                    _ = sliceApp(t.inc);
                }
                t.inc.setDraft(false);
            }
            const ok_inc = if (apply(t.inc, e, t.now_ms)) true else |_| false;
            const ok_full = if (apply(t.full, e, t.now_ms)) true else |_| false;
            if (ok_inc != ok_full) {
                result.faults += 1;
                try report.print("FAULT seed {d} step {d}: the edit failed in one app: {s}\n", .{ seed, step, tw.buffered() });
                try report.flush();
                break;
            }
            if (!ok_inc) continue;
            result.kinds[@intFromEnum(e)] += 1;
            switch (e) {
                .cancel => |ms| {
                    t.inc.requestSlice() catch {};
                    try io.sleep(.fromMilliseconds(ms), .awake);
                    t.inc.cancel();
                    t.inc.waitSlice();
                },
                else => {},
            }
            // A budget: `inc` frees its kept work after this slice, as the
            // app does over its budget. The next slices must not change.
            const budget = t.inc.settings.engine.form_budget_mb;
            if (e == .budget) t.inc.settings.engine.form_budget_mb = 1;
            const sliced = try t.check(seed, step, e, "");
            if (e == .budget) t.inc.settings.engine.form_budget_mb = budget;
            if (!sliced) {
                // A value that no slice accepts: go back, so that the next
                // steps test a slice.
                t.inc.settings = saved[0];
                t.full.settings = saved[1];
            } else if (opts.restore and step % 8 == 0) try checkRestore(&t, seed, step);
        }
    }
    result.edits_hash = list_hash.final();
}

/// Sets one of the three base states of the sweep on both apps.
fn setBase(t: *Twin, k: usize) !void {
    const sets: []const [2][]const u8 = switch (k) {
        0 => &.{},
        1 => &.{ .{ "project.support", "everywhere" }, .{ "project.support_style", "tree" }, .{ "project.brim_width", "3" } },
        3 => &.{.{ "machine.nozzles", "4" }},
        else => &.{ .{ "project.wall_generator", "arachne" }, .{ "project.ironing", "true" }, .{ "project.infill_layers", "2" }, .{ "machine.z_hop", "0.4" } },
    };
    for (t.apps()) |app| {
        for (sets) |s| try app.setSetting(s[0], s[1]);
        if (k == 1) {
            _ = try zs.app.filament_slots.add(app);
            try app.setOverride(5, 10, "project.filament", "2");
        }
    }
}

fn runSweep(gpa: Allocator, io: Io, models: []const Model, opts: *const Options, report: *Io.Writer, result: *Result) !void {
    const was_on = clock.on.swap(true, .monotonic);
    defer clock.on.store(was_on, .monotonic);
    try report.writeAll("setting\tvalue\tms\tplans\tmesh_cuts\tbooleans\ttexts_changed\tvs_full\tback\n");
    for (0..opts.sweep_bases) |k| {
        var t = try Twin.init(gpa, io, models, opts, report, result);
        defer t.deinit();
        try setBase(&t, k);
        _ = try t.check(k, 0, null, "the base state");
        const base_settings = t.inc.settings;
        const base_g = try gpa.dupe(u8, t.inc.gcode() orelse "");
        defer gpa.free(base_g);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var case: usize = 0;
        for (zs.app.settings_info) |info| {
            if (info.kind == .text or skipped(opts, info.name)) continue;
            if (k == 3 and !std.mem.startsWith(u8, info.name, "machine.nozzle.")) continue;
            _ = arena_state.reset(.retain_capacity);
            const values = try zs.app.sweep.valuesOf(arena, info, base_settings, 3);
            if (values.len < 2) continue;
            for (values[1..]) |v| {
                case += 1;
                t.inc.setSetting(info.name, v) catch continue;
                t.full.setSetting(info.name, v) catch {
                    t.inc.settings = base_settings;
                    continue;
                };
                clock.reset();
                const t0 = Io.Clock.awake.now(io);
                const ok_inc = sliceApp(t.inc);
                const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
                const plans = clock.plansMade();
                const cuts = clock.callsOf(.mesh_cut);
                const bools = clock.countOf(.booleans);
                const texts = if (ok_inc) levelsChanged(t.inc.gcode() orelse "", base_g) else 0;
                t.full.dropWork();
                const ok_full = sliceApp(t.full);
                result.steps += 1;
                var bad = ok_inc != ok_full;
                if (ok_inc and ok_full) bad = compare(t.inc, t.full) != null;
                if (!ok_inc and !ok_full) result.failed_slices += 1;
                if (bad) result.faults += 1;
                // Back to the base value.
                t.inc.settings = base_settings;
                t.full.settings = base_settings;
                if (bad) t.inc.dropWork();
                const ok_back = sliceApp(t.inc);
                const back_same = ok_back and std.mem.eql(u8, t.inc.gcode() orelse "", base_g);
                if (!back_same) {
                    result.faults += 1;
                    t.inc.dropWork();
                    _ = sliceApp(t.inc);
                }
                const state: []const u8 = if (bad) "OTHER" else if (ok_inc) "same" else "failed";
                try report.print("{s}\t{s}\t{d:.1}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{ info.name, v, ms, plans, cuts, bools, texts, state, if (back_same) "same" else "OTHER" });
                try report.flush();
            }
        }
    }
}

fn runRanges(gpa: Allocator, io: Io, models: []const Model, opts: *const Options, report: *Io.Writer, result: *Result) !void {
    const which = opts.ranges.?;
    var t = try Twin.init(gpa, io, models, opts, report, result);
    defer t.deinit();
    _ = try t.check(0, 0, null, "the base state");
    const top = topZ(t.inc);
    const ranges = [3][2]f64{ .{ 1, 2 }, .{ 5, 10 }, .{ @max(top - 3, 0), top + 1 } };
    const combos = [_][]const usize{ &.{0}, &.{1}, &.{2}, &.{ 0, 1 }, &.{ 0, 2 }, &.{ 1, 2 } };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var step: usize = 0;
    // "all": each setting of settings.layer_local. Another name: that
    // layer setting.
    const all = std.mem.eql(u8, which, "all");
    for (zs.settings.layer_settings) |name| {
        if (all and !zs.settings.isLayerLocal(name)) continue;
        if (!all and !std.mem.eql(u8, which, name)) continue;
        if (skipped(opts, name)) continue;
        const info = infoOf(name) orelse continue;
        if (info.kind == .text) continue;
        _ = arena_state.reset(.retain_capacity);
        const values = try zs.app.sweep.valuesOf(arena, info, t.inc.settings, 3);
        if (values.len < 2) continue;
        for (values[1..]) |v| for (combos) |c| {
            step += 1;
            var label: [160]u8 = undefined;
            const what = std.fmt.bufPrint(&label, "{s}={s} on {d} ranges from z {d:.2}", .{ name, v, c.len, ranges[c[0]][0] }) catch name;
            var set_ok = true;
            for (t.apps()) |app| for (c) |r| {
                app.setOverride(ranges[r][0], ranges[r][1], name, v) catch {
                    set_ok = false;
                };
            };
            if (set_ok) _ = try t.check(0, step, null, what);
            for (t.apps()) |app| for (c) |r| {
                _ = app.removeOverride(ranges[r][0], ranges[r][1], name);
            };
            if (set_ok) _ = try t.check(0, step, null, "back at the base");
        };
    }
}

/// Runs the modes of `opts`, and writes faults and a summary to `report`.
pub fn run(gpa: Allocator, io: Io, models: []const Model, opts: Options, report: *Io.Writer) !Result {
    var result: Result = .{};
    if (opts.sweep) try runSweep(gpa, io, models, &opts, report, &result);
    if (opts.ranges != null) try runRanges(gpa, io, models, &opts, report, &result);
    if (opts.random) try runRandom(gpa, io, models, &opts, report, &result);
    try report.print("verify: {d} steps, {d} faults, {d} steps failed in both apps", .{ result.steps, result.faults, result.failed_slices });
    if (opts.restore) try report.print(", restore: {d} checks, {d} faults", .{ result.restore_steps, result.restore_faults });
    if (opts.random) {
        try report.print(", edits hash {x}\nedits:", .{result.edits_hash});
        for (result.kinds, 0..) |n, k| try report.print(" {s} {d}", .{ @tagName(@as(@typeInfo(Edit).@"union".tag_type.?, @enumFromInt(k))), n });
    }
    try report.writeAll("\n");
    try report.flush();
    return result;
}

test "verify: random edits of the demo part give the bytes of a full slice" {
    // The test of the C API links libc and runs the tests of this module
    // again. One run is enough.
    if (comptime @import("builtin").link_libc) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var m = try zs.mesh.shapes.demo(gpa);
    defer m.deinit(gpa);
    var stl: Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    var sink: Io.Writer.Discarding = .init(&.{});
    const models = [_]Model{.{ .name = "demo.stl", .bytes = stl.written() }};
    const r = try run(gpa, std.testing.io, &models, .{ .seeds = &.{ 11, 22 }, .steps = 6 }, &sink.writer);
    try std.testing.expectEqual(@as(usize, 0), r.faults);
    try std.testing.expect(r.steps >= 2);
}
