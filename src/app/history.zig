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
//! on one line.
//!
//! `History` is the undo list of one app: a list of steps, the oldest
//! first, and the step now. A step has the state of the app: the texts of
//! the three groups of settings (`App.writeState`), the quality profile,
//! the plate as a 3MF file, the facts, and the time.
//!
//! The steps come from changes. Each change of the C API notes its key
//! (`note`): the name of one setting, or "*" for a change of the plate or
//! of more than one setting. The shell calls `commit` 400 ms after the
//! last change. A commit makes a snapshot of the state. If it differs from
//! the step now, it is a new step, and the redo steps go. The shell keeps
//! the timer, so the core needs no clock: the shell gives the time.
//!
//! An edit of one setting is one step while its editor has the focus. The
//! shell tells the core which setting has the focus (`setFocus`). A commit
//! of a change of only that setting, after a step of only that setting,
//! amends that step. If the value goes back to the value before the edit,
//! the step goes.
//!
//! An undo, a redo, or a jump to a step (`goto`) restores the state of
//! that step: it loads the 3MF file if the plate differs, then it applies
//! each group of settings that differs. These changes are not noted.
//!
//! Limits: at most `max_steps` steps before the step now, and at most
//! `max_plate_bytes` of 3MF files in them. The oldest steps go first.
//! Steps with the same plate share one copy of its 3MF file.
//!
//! The undo lists of the GTK shell and the web app were the model for this
//! code (linux/src/model/app-model.c and web/app/worker.js before the
//! history moved here).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const setting_info = @import("setting_info.zig");
const zs = @import("../root.zig");
const App = @import("../app.zig").App;

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
/// True if a change line of a step (a line of the diff) can be undone
/// alone: not the quality, and not a move, turn, orientation, or scale of
/// a part (those come only with the whole step).
pub fn revertible(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "\tquality\t") != null) return false;
    // The edits of lines come back with the whole step.
    if (std.mem.startsWith(u8, line, "edits\t")) return false;
    // So do the support areas: they are in the 3MF of the plate.
    if (std.mem.startsWith(u8, line, "Support\t")) return false;
    if (!std.mem.startsWith(u8, line, "part:")) return true;
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return false;
    const key = line[tab + 1 ..];
    for ([_][]const u8{ "(part)", "position", "rotation", "orientation", "scale" }) |k| {
        if (std.mem.startsWith(u8, key, k)) return false;
    }
    return true;
}

test "history: the changes that can be undone alone" {
    try std.testing.expect(revertible("print\tproject.infill_density\t0.2\t0.4"));
    try std.testing.expect(!revertible("print\tquality\tfine\tdraft"));
    try std.testing.expect(!revertible("part:0\tposition\t1,2\t3,4"));
    try std.testing.expect(revertible("part:0\tproject.wall_count\t2\t3"));
}

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

// ---- the undo list ----

/// The bits of the result of a restore (`History.undo`, `redo`, `goto`,
/// `truncate`): what changed in the app. The shell updates its widgets
/// and its saved files for them.
pub const restored_moved: u32 = 1;
pub const restored_plate: u32 = 2;
/// The bit of a group of settings: `restored_group << group`.
pub const restored_group: u32 = 4;
pub const restored_quality: u32 = 32;
/// `truncate` dropped the later steps.
pub const restored_dropped: u32 = 64;

/// A 3MF file of the plate, shared by the steps with the same plate.
const Plate3mf = struct {
    refs: usize,
    bytes: []u8,

    fn ref(p: *Plate3mf) *Plate3mf {
        p.refs += 1;
        return p;
    }

    fn unref(p: *Plate3mf, gpa: Allocator) void {
        p.refs -= 1;
        if (p.refs > 0) return;
        gpa.free(p.bytes);
        gpa.destroy(p);
    }
};

/// One step: the state of the app at a commit.
pub const Step = struct {
    /// The texts of the machine, filament, and project groups.
    settings: [3][]u8,
    /// The quality profile. The strings are in `App.strings`, which only
    /// grows, so the step keeps them as they are.
    quality_name: [:0]const u8,
    quality: []const zs.settings.Change,
    /// The plate, or null for an empty plate.
    plate: ?*Plate3mf,
    facts: []u8,
    time_ms: i64,

    fn deinit(s: *Step, gpa: Allocator) void {
        for (s.settings) |t| gpa.free(t);
        gpa.free(s.facts);
        if (s.plate) |p| p.unref(gpa);
    }
};

fn samePlate(a: ?*Plate3mf, b: ?*Plate3mf) bool {
    if (a == b) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return std.mem.eql(u8, x.bytes, y.bytes);
}

/// The same settings, quality profile, and plate.
fn sameState(a: *const Step, b: *const Step) bool {
    for (a.settings, b.settings) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    if (!std.mem.eql(u8, a.quality_name, b.quality_name)) return false;
    return samePlate(a.plate, b.plate);
}

fn eqlKey(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// What `History.step` gives for one step. The strings are valid until
/// the next call of `step` or the next change of the history.
pub const StepInfo = struct {
    time_ms: i64,
    /// "start" for step 0, else the name of the `Kind` of its changes.
    kind: [:0]const u8,
    /// The changes from the step before (`diff` lines). "" for step 0.
    changes: []const u8,
    /// The changes in words (`describe` lines). "" for step 0.
    text: []const u8,
};

/// The undo list of one app (see the header comment).
pub const History = struct {
    /// The steps, the oldest first. The steps after `current` are the redo
    /// steps.
    steps: std.ArrayList(Step) = .empty,
    current: usize = 0,
    /// The key of the changes since the last commit: a setting, or "*".
    pending_key: ?[]u8 = null,
    /// The setting of the last step while its edit is open.
    edit_key: ?[]u8 = null,
    /// The setting whose editor has the focus.
    focus_key: ?[]u8 = null,
    /// The plate changed since the last commit: the next snapshot writes
    /// a new 3MF file.
    plate_dirty: bool = true,
    /// A restore runs: its changes are not noted.
    restoring: bool = false,
    max_steps: usize = 100,
    max_plate_bytes: usize = 200 << 20,
    /// The memory of the strings of `step`.
    info: ?std.heap.ArenaAllocator = null,

    pub fn deinit(h: *History, gpa: Allocator) void {
        for (h.steps.items) |*s| s.deinit(gpa);
        h.steps.deinit(gpa);
        for ([_]?[]u8{ h.pending_key, h.edit_key, h.focus_key }) |k| if (k) |t| gpa.free(t);
        if (h.info) |*a| a.deinit();
        h.* = .{};
    }

    fn setKey(gpa: Allocator, slot: *?[]u8, key: ?[]const u8) void {
        if (slot.*) |t| gpa.free(t);
        slot.* = null;
        if (key) |k| slot.* = gpa.dupe(u8, k) catch null;
    }

    /// Notes a change: `key` is the name of one setting, or null for more
    /// than one (a key that ends with "." is a whole group). `plate`: the
    /// plate changed (its parts, their settings, or the changes for some
    /// layers).
    pub fn note(h: *History, gpa: Allocator, key: ?[]const u8, plate: bool) void {
        if (h.restoring) return;
        if (plate) h.plate_dirty = true;
        const k = key orelse "*";
        const whole = plate or k.len == 0 or k[k.len - 1] == '.';
        if (h.pending_key) |p| {
            if (whole or !std.mem.eql(u8, p, k)) setKey(gpa, &h.pending_key, "*");
        } else setKey(gpa, &h.pending_key, if (whole) "*" else k);
    }

    pub fn count(h: *const History) usize {
        return h.steps.items.len;
    }

    fn snapshot(h: *History, app: *App, now_ms: i64) Allocator.Error!Step {
        const gpa = app.gpa;
        var s: Step = .{ .settings = .{ &.{}, &.{}, &.{} }, .quality_name = app.quality_name, .quality = app.quality, .plate = null, .facts = &.{}, .time_ms = now_ms };
        errdefer s.deinit(gpa);
        inline for (.{ zs.profile.Group.machine, .filament, .project }, 0..) |g, i| {
            var w: std.Io.Writer.Allocating = .init(gpa);
            app.writeState(g, &w.writer) catch return error.OutOfMemory;
            s.settings[i] = try w.toOwnedSlice();
        }
        if (!h.plate_dirty and h.steps.items.len > 0) {
            if (h.steps.items[h.current].plate) |p| s.plate = p.ref();
        } else if (app.plate.count() > 0) {
            const bytes = app.write3mfAlloc(gpa) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (bytes) |b| {
                const p = gpa.create(Plate3mf) catch |e| {
                    gpa.free(b);
                    return e;
                };
                p.* = .{ .refs = 1, .bytes = b };
                s.plate = p;
            }
        }
        var fw: std.Io.Writer.Allocating = .init(gpa);
        app.writeFacts(&fw.writer) catch return error.OutOfMemory;
        s.facts = try fw.toOwnedSlice();
        h.plate_dirty = false;
        return s;
    }

    /// Drops the steps after the step now (the redo steps).
    fn dropRedo(h: *History, gpa: Allocator) void {
        for (h.steps.items[h.current + 1 ..]) |*s| s.deinit(gpa);
        h.steps.shrinkRetainingCapacity(h.current + 1);
    }

    fn dropOldest(h: *History, gpa: Allocator) void {
        var s = h.steps.orderedRemove(0);
        s.deinit(gpa);
        h.current -= 1;
    }

    /// The limits: the oldest steps go while there are too many steps
    /// before the step now, or while their 3MF files are too large (a file
    /// counts once for the steps that share it).
    fn trim(h: *History, gpa: Allocator) void {
        while (h.current > h.max_steps) h.dropOldest(gpa);
        while (h.current > 0) {
            var total: usize = 0;
            var last: ?*Plate3mf = null;
            for (h.steps.items[0..h.current]) |s| {
                if (s.plate) |p| if (p != last) {
                    total += p.bytes.len;
                };
                last = s.plate;
            }
            if (total <= h.max_plate_bytes) return;
            h.dropOldest(gpa);
        }
    }

    /// Ends the step of the changes so far. The first commit takes the
    /// start. Returns true if a step was added, amended, or dropped.
    pub fn commit(h: *History, app: *App, now_ms: i64) bool {
        const gpa = app.gpa;
        var now = h.snapshot(app, now_ms) catch return false;
        const key = h.pending_key;
        h.pending_key = null;
        defer if (key) |k| gpa.free(k);
        if (h.steps.items.len == 0) {
            h.steps.append(gpa, now) catch {
                now.deinit(gpa);
                return false;
            };
            h.current = 0;
            return false;
        }
        const before = &h.steps.items[h.current];
        const differs = !sameState(&now, before);
        const single = if (key) |k| !std.mem.eql(u8, k, "*") else false;
        // More changes of the setting of the last step, in the same edit:
        // they change that step.
        if (differs and single and h.current > 0 and eqlKey(key, h.edit_key) and eqlKey(key, h.focus_key)) {
            h.dropRedo(gpa);
            before.deinit(gpa);
            before.* = now;
            // Back at the value before the edit: the step goes.
            if (sameState(&h.steps.items[h.current - 1], &now)) {
                var s = h.steps.pop().?;
                s.deinit(gpa);
                h.current -= 1;
                setKey(gpa, &h.edit_key, null);
            }
            return true;
        }
        if (!differs) {
            // No change: the step now gets the new time and facts. An open
            // edit stays open.
            before.deinit(gpa);
            before.* = now;
            return false;
        }
        setKey(gpa, &h.edit_key, if (single) key else null);
        h.dropRedo(gpa);
        h.steps.append(gpa, now) catch {
            now.deinit(gpa);
            return false;
        };
        h.current += 1;
        h.trim(gpa);
        return true;
    }

    /// The setting whose editor has the focus now, or null. A move of the
    /// focus ends the edit: the changes so far are a step (of the old
    /// focus). Returns true if that commit changed the list.
    pub fn setFocus(h: *History, app: *App, key: ?[]const u8, now_ms: i64) bool {
        if (eqlKey(key, h.focus_key)) return false;
        const changed = if (h.pending_key != null) h.commit(app, now_ms) else false;
        setKey(app.gpa, &h.edit_key, null);
        setKey(app.gpa, &h.focus_key, key);
        return changed;
    }

    /// Loads the state of step `to` over the state of step `from`: the
    /// plate if it differs, then the quality profile, then each group of
    /// settings that differs. Returns the `restored_*` bits.
    fn restore(h: *History, app: *App, to: *const Step, from: *const Step) u32 {
        h.restoring = true;
        defer {
            h.restoring = false;
            h.plate_dirty = false;
        }
        var bits: u32 = restored_moved;
        if (!samePlate(to.plate, from.plate)) {
            if (to.plate) |p| {
                // A file of the history loaded before: an error here is
                // only a lack of memory, and the plate stays as it is.
                app.loadStl("plate.3mf", p.bytes) catch {};
            } else {
                app.clearPlate() catch {};
            }
            bits |= restored_plate;
        }
        const quality = !std.mem.eql(u8, to.quality_name, app.quality_name) or to.quality.ptr != app.quality.ptr or to.quality.len != app.quality.len;
        if (quality) {
            app.quality = to.quality;
            app.quality_name = to.quality_name;
            bits |= restored_quality;
        }
        inline for (.{ zs.profile.Group.machine, .filament, .project }, 0..) |g, i| {
            var w: std.Io.Writer.Allocating = .init(app.gpa);
            defer w.deinit();
            app.writeState(g, &w.writer) catch {};
            if (!std.mem.eql(u8, w.written(), to.settings[i]) or (quality and g == .project)) {
                app.resetGroup(g);
                var diag: zs.profile.Diagnostic = .{};
                // On an error, the settings stay as they were.
                app.applyProfile(g, "saved", to.settings[i], &diag) catch {
                    app.resetGroup(g);
                    app.applyProfile(g, "saved", w.written(), &diag) catch {};
                };
                bits |= restored_group << i;
            }
        }
        return bits;
    }

    /// Goes to step i: it restores the state of that step. Returns the
    /// `restored_*` bits, or 0 if it did not move.
    pub fn goto(h: *History, app: *App, i: usize, now_ms: i64) u32 {
        _ = h.commit(app, now_ms);
        if (h.steps.items.len == 0 or i == h.current or i >= h.steps.items.len) return 0;
        const from = h.current;
        h.current = i;
        const bits = h.restore(app, &h.steps.items[i], &h.steps.items[from]);
        setKey(app.gpa, &h.edit_key, null);
        return bits;
    }

    pub fn undo(h: *History, app: *App, now_ms: i64) u32 {
        _ = h.commit(app, now_ms);
        if (h.current == 0) return 0;
        return h.goto(app, h.current - 1, now_ms);
    }

    pub fn redo(h: *History, app: *App, now_ms: i64) u32 {
        _ = h.commit(app, now_ms);
        return h.goto(app, h.current + 1, now_ms);
    }

    /// Clears the history after step i: goes to step i first if it is not
    /// the step now, then drops the later steps (redo cannot bring them
    /// back). Returns the `restored_*` bits, with `restored_dropped` if
    /// steps went, or 0 if nothing changed.
    pub fn truncate(h: *History, app: *App, i: usize, now_ms: i64) u32 {
        _ = h.commit(app, now_ms);
        if (i >= h.steps.items.len) return 0;
        var bits: u32 = 0;
        if (i != h.current) bits = h.goto(app, i, now_ms);
        if (h.current + 1 >= h.steps.items.len) return bits;
        h.dropRedo(app.gpa);
        setKey(app.gpa, &h.edit_key, null);
        return bits | restored_dropped;
    }

    /// Drops all steps (a new file). The next commit takes the start.
    pub fn reset(h: *History, gpa: Allocator) void {
        for (h.steps.items) |*s| s.deinit(gpa);
        h.steps.clearRetainingCapacity();
        h.current = 0;
        setKey(gpa, &h.pending_key, null);
        setKey(gpa, &h.edit_key, null);
        h.plate_dirty = true;
    }

    /// Step i: its time, kind, and changes, with the layer numbers of the
    /// last slice of the app.
    pub fn step(h: *History, app: *const App, i: usize) (Allocator.Error || error{OutOfRange})!StepInfo {
        if (i >= h.steps.items.len) return error.OutOfRange;
        const s = &h.steps.items[i];
        if (i == 0) return .{ .time_ms = s.time_ms, .kind = "start", .changes = "", .text = "" };
        if (h.info) |*a| _ = a.reset(.retain_capacity) else h.info = .init(app.gpa);
        const a = h.info.?.allocator();
        var cw: std.Io.Writer.Allocating = .init(a);
        diff(a, h.steps.items[i - 1].facts, s.facts, &cw.writer) catch return error.OutOfMemory;
        const changes = cw.written();
        var tw: std.Io.Writer.Allocating = .init(a);
        app.describeChanges(changes, &tw.writer) catch return error.OutOfMemory;
        return .{ .time_ms = s.time_ms, .kind = @tagName(try stepKind(a, changes)), .changes = changes, .text = tw.written() };
    }
};

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
