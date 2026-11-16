//! A sweep of the settings: for each setting, slice the part with values
//! across its range (the other settings stay at their base values), and
//! measure each result. It shows which settings change the print time,
//! the plastic, and the cost of this part, and by how much. It is the
//! first step of a search for the best settings for a goal (speed,
//! quality, or cost).
//!
//! The values: for a number, `points` values across the slider range of
//! the setting, and the base value; for an integer, the same, rounded; for
//! a boolean, both; for a choice, each choice. Text settings and settings
//! with no slider are left out.
//!
//! Each slice reuses the work of the slice before (engine.Job.initReuse),
//! so a change of a late setting (for example the infill) costs only the
//! late stages.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const zs = @import("../root.zig");
const setting_info = @import("setting_info.zig");
const Allocator = std.mem.Allocator;
const Settings = zs.Settings;

pub const Options = struct {
    /// The values of a number setting, across its slider range.
    points: usize = 5,
    /// The groups to sweep.
    groups: []const []const u8 = &.{ "project", "filament" },
    /// Only the settings whose name has this text, or all.
    filter: ?[]const u8 = null,
};

/// The result of one slice.
pub const Result = struct {
    /// "group.name"
    name: []const u8,
    /// The value, as text.
    value: []const u8,
    /// The value is the base value.
    base: bool,
    /// The slice failed with this error, or null.
    failure: ?anyerror = null,
    time_s: f64 = 0,
    filament_g: f64 = 0,
    /// filament_g / 1000 times filament.price_per_kg (of the base).
    cost: f64 = 0,
    travel_mm: f64 = 0,
    retractions: u32 = 0,
    layers: u32 = 0,
};

/// Gets each result as it comes, for progress.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    result: *const fn (ctx: ?*anyopaque, r: Result, done: usize, total: usize) void,
};

/// The values to try for setting `info` (the base value first). The
/// strings are in `arena`.
pub fn valuesOf(arena: Allocator, info: setting_info.SettingInfo, base: Settings, points: usize) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var text: std.Io.Writer.Allocating = .init(arena);
    zs.app.App.writeSettingOf(base, info.name, &text.writer) catch return list.items;
    const base_text = text.written();
    try list.append(arena, base_text);
    switch (info.kind) {
        .number, .integer => {
            if (info.slider_max <= info.slider_min or points < 2) return list.items;
            for (0..points) |k| {
                const f = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(points - 1));
                var v = info.slider_min + f * (info.slider_max - info.slider_min);
                if (info.kind == .integer) v = @round(v);
                if (info.slider_step > 0) v = @round(v / info.slider_step) * info.slider_step;
                const t = try std.fmt.allocPrint(arena, "{d}", .{v});
                if (!contains(list.items, t) and !sameNumber(t, base_text)) try list.append(arena, t);
            }
        },
        .boolean => {
            const other: []const u8 = if (std.mem.eql(u8, base_text, "true")) "false" else "true";
            try list.append(arena, other);
        },
        .choice => {
            var it = std.mem.tokenizeScalar(u8, info.choices, '\n');
            while (it.next()) |c| if (!std.mem.eql(u8, c, base_text)) try list.append(arena, c);
        },
        .text => {},
    }
    return list.items;
}

fn contains(list: []const []const u8, t: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, t)) return true;
    return false;
}

fn sameNumber(a: []const u8, b: []const u8) bool {
    const x = std.fmt.parseFloat(f64, a) catch return false;
    const y = std.fmt.parseFloat(f64, b) catch return false;
    return @abs(x - y) < 1e-9;
}

/// The settings that a sweep with `opts` tries.
pub fn wanted(info: setting_info.SettingInfo, opts: Options) bool {
    if (info.kind == .text) return false;
    if ((info.kind == .number or info.kind == .integer) and info.slider_max <= info.slider_min) return false;
    var in_group = false;
    for (opts.groups) |g| in_group = in_group or std.mem.eql(u8, g, info.group);
    if (!in_group) return false;
    if (opts.filter) |f| if (std.mem.indexOf(u8, info.name, f) == null) return false;
    return true;
}

/// Slices `mesh` once for each value of each wanted setting, and sends
/// each result to `sink`. The base slice comes first (its value is the
/// base value of the first setting). The results are valid until the
/// call returns (their strings are in an arena of the call).
pub fn run(gpa: Allocator, mesh: *const zs.Mesh, base: Settings, opts: Options, sink: Sink) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The list of slices first, for the progress.
    const Case = struct { name: []const u8, value: []const u8, base: bool };
    var cases: std.ArrayList(Case) = .empty;
    try cases.append(arena, .{ .name = "", .value = "", .base = true });
    for (setting_info.settings_info) |info| {
        if (!wanted(info, opts)) continue;
        const values = try valuesOf(arena, info, base, opts.points);
        // The first value is the base: the base slice has it.
        for (values[1..]) |v| try cases.append(arena, .{ .name = info.name, .value = v, .base = false });
    }
    const price = base.filament.price_per_kg;
    var old: ?zs.engine.Job = null;
    defer if (old) |*j| j.deinit();
    for (cases.items, 0..) |c, i| {
        var s = base;
        var r: Result = .{ .name = c.name, .value = c.value, .base = c.base };
        if (!c.base) s.set(c.name, c.value) catch |e| {
            r.failure = e;
            sink.result(sink.ctx, r, i + 1, cases.items.len);
            continue;
        };
        const prev: ?*zs.engine.Job = if (old) |*j| j else null;
        var job = zs.engine.Job.initReuse(gpa, mesh, s, &.{}, &.{}, .{}, prev) catch |e| {
            r.failure = e;
            sink.result(sink.ctx, r, i + 1, cases.items.len);
            continue;
        };
        var discard: std.Io.Writer.Discarding = .init(&.{});
        const stats = job.writeGcode(&discard.writer) catch |e| blk: {
            r.failure = e;
            break :blk zs.Stats{};
        };
        if (old) |*j| j.deinit();
        old = job;
        r.time_s = stats.print_time_s;
        r.filament_g = stats.filament_g;
        r.cost = stats.filament_g / 1000 * price;
        r.travel_mm = stats.travel_mm;
        r.retractions = stats.retractions;
        r.layers = stats.layer_count;
        sink.result(sink.ctx, r, i + 1, cases.items.len);
    }
}

test "sweep: the values of a setting, and a small sweep of the demo part" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base: Settings = .{};
    for (setting_info.settings_info) |info| {
        if (std.mem.eql(u8, info.name, "project.infill_density")) {
            const v = try valuesOf(arena, info, base, 5);
            try std.testing.expect(v.len >= 5);
            try std.testing.expect(sameNumber(v[0], "0.2"));
        }
        if (std.mem.eql(u8, info.name, "project.thin_walls")) {
            const v = try valuesOf(arena, info, base, 5);
            try std.testing.expectEqual(@as(usize, 2), v.len);
        }
    }
    var mesh = try zs.mesh.shapes.demo(gpa);
    defer mesh.deinit(gpa);
    const Count = struct {
        n: usize = 0,
        base_time: f64 = 0,
        denser_more_plastic: bool = false,
        fn add(ctx: ?*anyopaque, r: Result, done: usize, total: usize) void {
            _ = total;
            _ = done;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.n += 1;
            if (r.base) self.base_time = r.time_s;
            if (std.mem.eql(u8, r.value, "0.5") and r.filament_g > 0) self.denser_more_plastic = true;
        }
    };
    var count: Count = .{};
    try run(gpa, &mesh, base, .{ .filter = "infill_density" }, .{ .ctx = &count, .result = Count.add });
    try std.testing.expect(count.n >= 5);
    try std.testing.expect(count.base_time > 0);
}
