//! The inspection of one path: its real values (the bead, the speed, the
//! flow, the print time), the reasons for them in plain words, and the
//! settings that change it. A shell shows this after a click on a line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const Toolpaths = @import("toolpaths.zig").Toolpaths;
const fs = @import("feature_settings.zig");

/// The result of `App.inspect`.
pub const Inspection = struct {
    feature: zs.settings.Feature,
    layer: usize,
    path: usize,
    z: f64,
    height: f64,
    line_width: f64,
    bead_width: f64,
    length: f64,
    planned_speed: f64,
    speed: f64,
    flow: f64,
    start_time: f64,
    end_time: f64,
    title: [:0]const u8,
    /// The values and why, in plain words.
    explain: [:0]const u8,
    /// The setting names, one on each line.
    settings: [:0]const u8,
    /// Why the planned speed, the real speed, and the flow are what they
    /// are, and how to change them. A setting is a mark {{name}} (for
    /// example {{project.outer_wall_speed}}), for a link in the shell.
    why_planned: [:0]const u8 = "",
    why_real: [:0]const u8 = "",
    why_flow: [:0]const u8 = "",
    /// Why the real speed is lower than planned: 0 it is not, 1 the
    /// cooling slow-down (minimum layer time), 2 the acceleration on short
    /// segments.
    slow_reason: u8 = 0,
};

pub const Error = error{ OutOfRange, OutOfMemory, WriteFailed };

/// Inspects path `path` of the toolpaths `t` of the slice `job`. The
/// strings go in `arena`.
pub fn inspect(arena: Allocator, t: *const Toolpaths, job: *const zs.Job, path: usize) Error!Inspection {
    const layer = t.layerOfPath(path) orelse return error.OutOfRange;
    const r = job.resolvedAt(layer);
    const s = r.settings;

    const feature: zs.settings.Feature = @enumFromInt(t.path_features.items[path]);
    const first = layer == 0;
    // The bead height of a planar path: the layer height, or for combined
    // infill the height of all the layers of its group.
    const planar_h: f64 = t.pathHeight(path, layer);
    const layer_h: f64 = t.layer_height.items[layer];
    const combined = planar_h > layer_h + 1e-4;
    const group_n: usize = if (combined and layer < job.groups.len) job.groups[layer].count() else 1;
    const w: f64 = t.layer_width.items[layer];
    const area: f64 = t.path_area.items[path];
    // A path with a z for each point (slope smoothing): the bead is under
    // the nozzle, down to the top of the layer below. Its height is the
    // mean over the points.
    const z_range = t.pathZRange(path, layer);
    const z_low: f64 = @as(f64, t.layer_z.items[layer]) - layer_h;
    const nonplanar = t.path_z_start.items.len > path and t.path_z_start.items[path] != Toolpaths.no_z;
    const h: f64 = if (nonplanar) blk: {
        const k = t.path_z_start.items[path];
        const n = t.path_ends.items[path] - t.pathStart(path);
        var sum: f64 = 0;
        for (t.point_z.items[k..][0..n]) |z| sum += z;
        break :blk @max(sum / @as(f64, @floatFromInt(n)) - z_low, 0.01);
    } else planar_h;
    const bead = zs.flow.beadWidth(area, h);
    const length = t.pathLength(path);
    const t0: f64 = t.path_start_time.items[path];
    const t1: f64 = t.path_end_time.items[path];
    // The speed of this layer, with the ramp of the slow first layers.
    const planned = r.speedAt(feature, w, h, layer);
    const real = if (t1 > t0) length / (t1 - t0) else planned;

    var text: std.Io.Writer.Allocating = .init(arena);
    const out = &text.writer;
    const name = fs.feature_names[@intFromEnum(feature)];
    try out.print("{s}, layer {d} of {d}, at z {d:.2} mm.\n\n", .{ name, layer + 1, t.layerCount(), t.layer_z.items[layer] });
    if (combined) {
        try out.print("Combined: {d} layers, {d:.2} mm. The sparse infill of layers {d} to {d} prints here as one bead (project.infill_layers). The nozzle is at the z of this layer, and the bead goes down to the bottom of layer {d}.\n\n", .{ group_n, h, layer + 2 - group_n, layer + 1, layer + 2 - group_n });
    }
    try out.print("The bead is {d:.3} mm wide and {d:.2} mm tall. The line width is {d:.3} mm. The cross section is {d:.4} mm\u{b2}.\n", .{ bead, h, w, area });
    try out.print("The path is {d:.1} mm long, and it uses {d:.2} mm\u{b3} of plastic.\n\n", .{ length, length * area });
    if (feature == .infill and s.project.infill_pattern == .lightning) {
        try out.print("Lightning infill: this branch holds up a top surface above it. The branches start {d:.1} mm apart under each top (the density), and on each layer down the end of a branch gets {d:.2} mm shorter (the lightning angle, {d:.0}\u{b0}), until the branch ends at a wall.\n\n", .{ w / s.project.infill_density, h * @tan(s.project.lightning_angle * std.math.pi / 180.0), s.project.lightning_angle });
    }
    if (feature == .slope_smoothing) {
        try out.print("Slope smoothing: after the layer, this bead fills the steps of a sloped top surface, on the ledge of the layer below (top at z {d:.2} mm). Its plastic is the volume of the triangle of each step: the layer height \u{d7} the ledge width / 2, \u{d7} the smoothing flow ({d:.0} %). The nozzle tip goes from z {d:.3} to {d:.3} mm: half the step height, or higher where the nozzle cone needs room from this layer (tip radius {d} mm, cone angle {d}\u{b0}).\n\n", .{ z_low, s.project.slope_smoothing_flow * 100, z_range[0], z_range[1], s.machine.nozzle_tip_radius, s.machine.nozzle_cone_angle });
    }
    if (feature == .slope_ironing) {
        try out.print("Slope ironing: after the layer and its smoothing beads, the hot nozzle goes over the filled steps of a sloped top surface with a small flow ({d:.0} % of a normal line), to make the bead tops flat. It is one of {d} passes across each ledge. At each point the nozzle tip is at the height of the filled step there, between the top of the layer below (z {d:.2} mm) and this layer, and high enough for the nozzle cone: here from z {d:.3} to {d:.3} mm.\n\n", .{ s.project.slope_ironing_flow * 100, s.project.slope_ironing_passes, z_low, z_range[0], z_range[1] });
    }
    if (feature == .ironing or feature == .slope_ironing) {
        try out.print("Planned speed: {d:.0} mm/s, the ironing speed ({d:.0} %) of the machine limit ({d:.0} mm/s). Ironing uses little plastic, so the flow limit does not apply.\n", .{ planned, planned / s.machine.max_speed * 100, s.machine.max_speed });
    } else {
        const bead_area = zs.flow.beadArea(w, h);
        const flow_limit = s.filament.max_flow / bead_area;
        const limit = @min(s.machine.max_speed, flow_limit);
        try out.print("Planned speed: {d:.0} mm/s. That is {d:.0} % (the speed setting) of {d:.0} mm/s: the lower of the machine limit ({d:.0} mm/s) and the flow limit ({d} mm\u{b3}/s / {d:.4} mm\u{b2} = {d:.0} mm/s).\n", .{ planned, planned / limit * 100, limit, s.machine.max_speed, s.filament.max_flow, bead_area, flow_limit });
    }
    const layer_slowed = t.layer_slowed.items.len > layer and t.layer_slowed.items[layer] != 0;
    if (layer_slowed) {
        try out.print("Real speed: {d:.0} mm/s. The layer prints in less than the minimum layer time of the filament ({d} s), so it prints slower, to cool.\n", .{ real, s.filament.min_layer_time });
    } else if (real < planned * 0.95) {
        try out.print("Real speed: {d:.0} mm/s on average: the segments are short, so the head does not reach the planned speed between the corners (acceleration).\n", .{real});
    } else {
        try out.print("Real speed: {d:.0} mm/s.\n", .{real});
    }
    try out.print("Plastic flow: {d:.1} mm\u{b3}/s.\n\n", .{real * area});
    try out.print("Printed from {d}:{d:0>2}:{d:0>2} to {d}:{d:0>2}:{d:0>2} after the start of the print.", .{
        hours(t0), minutes(t0), seconds(t0), hours(t1), minutes(t1), seconds(t1),
    });

    // The settings, in sections. A line "# Name" starts a section.
    var names: std.Io.Writer.Allocating = .init(arena);
    const nw = &names.writer;
    try nw.writeAll("# Speed\n");
    try nw.print("{s}\n", .{fs.speedRatioSetting(feature, first)});
    try nw.writeAll("machine.max_speed\n");
    if (feature != .ironing and feature != .slope_ironing) try nw.writeAll("filament.max_flow\n");
    for (fs.cooling_speed_settings) |n| try nw.print("{s}\n", .{n});
    try nw.writeAll("# Shape\n");
    for (fs.feature_settings[@intFromEnum(feature)]) |n| try nw.print("{s}\n", .{n});
    if (first) for (fs.first_layer_settings) |n| try nw.print("{s}\n", .{n});
    try nw.writeAll("# Material\n");
    for (fs.material_settings) |n| try nw.print("{s}\n", .{n});

    // Why each number, and how to change it.
    const segs = blk: {
        const start: usize = if (path == 0) 0 else t.path_ends.items[path - 1];
        break :blk @max(1, t.path_ends.items[path] - start -| 1);
    };
    var wp: std.Io.Writer.Allocating = .init(arena);
    const pw = &wp.writer;
    const ratio_name = fs.speedRatioSetting(feature, first);
    if (feature == .ironing or feature == .slope_ironing) {
        try pw.print("{d:.0} mm/s = {d:.0} % ({{{{{s}}}}}) of the machine limit, {d:.0} mm/s ({{{{machine.max_speed}}}}). Ironing uses little plastic, so the flow limit does not apply.\n\nTo iron faster, raise {{{{{s}}}}}.", .{ planned, planned / s.machine.max_speed * 100, ratio_name, s.machine.max_speed, ratio_name });
    } else {
        const bead_area = zs.flow.beadArea(w, h);
        const flow_limit = s.filament.max_flow / bead_area;
        const limit = @min(s.machine.max_speed, flow_limit);
        const full = r.speed(feature, w, h, first);
        const ratio = if (limit > 0) full / limit else 0;
        try pw.print("{d:.0} mm/s = {d:.0} % ({{{{{s}}}}}) of {d:.0} mm/s.\n\n{d:.0} mm/s is the lower of two limits:\n\u{2022} the machine: {d:.0} mm/s ({{{{machine.max_speed}}}})\n\u{2022} the flow: {d:.1} mm\u{b3}/s ({{{{filament.max_flow}}}}) \u{f7} the bead area {d:.4} mm\u{b2} = {d:.0} mm/s\n", .{ full, ratio * 100, ratio_name, limit, limit, s.machine.max_speed, s.filament.max_flow, bead_area, flow_limit });
        if (flow_limit < s.machine.max_speed) {
            try pw.print("\nThe flow limits this line: the hot end cannot melt more plastic. A thinner or lower line ({{{{project.line_width}}}}, {{{{project.layer_height}}}}) can go faster.", .{});
        } else {
            try pw.print("\nThe machine limits this line.", .{});
        }
        if (planned < full * 0.999) {
            try pw.print("\n\nLayer {d} is one of the slow first layers ({{{{project.slow_layers}}}}): its speed goes up in steps from the first layer speed ({{{{project.first_layer_speed}}}}), so it prints at {d:.0} mm/s.", .{ layer + 1, planned });
        }
        try pw.print("\n\nTo print it faster: raise {{{{{s}}}}} (up to 100 %), or the limit that applies.", .{ratio_name});
    }

    var wr: std.Io.Writer.Allocating = .init(arena);
    const rw = &wr.writer;
    const slowed = t.layer_slowed.items.len > layer and t.layer_slowed.items[layer] != 0;
    if (slowed) {
        try rw.print("{d:.0} mm/s, slower than planned ({d:.0} mm/s): the layer is short. At the planned speeds it prints in less than the minimum layer time, {d} s ({{{{filament.min_layer_time}}}}), so all its lines slow down to give the plastic time to cool, but not below {d:.0} mm/s ({{{{filament.min_speed}}}}).\n\nTo change it: a shorter minimum layer time, more parts on the plate (each layer takes longer), or a cooling lap in place of the slow-down ({{{{filament.cooling_mode}}}}).", .{ real, planned, s.filament.min_layer_time, s.filament.min_speed });
    } else if (real < planned * 0.95) {
        const avg = length / @as(f64, @floatFromInt(segs));
        const accel_name = fs.accelSetting(feature, first);
        try rw.print("{d:.0} mm/s on average, less than the planned {d:.0} mm/s: the segments are short (about {d:.1} mm each), and at each corner the head slows to the corner speed, {d:.0} mm/s ({{{{machine.corner_speed}}}}), then speeds up again at {d:.0} mm/s\u{b2} ({{{{{s}}}}}). It does not reach the full speed on a short segment.\n\nA higher acceleration or corner speed makes it faster, if the printer can do it.", .{ real, planned, avg, @min(planned, s.machine.corner_speed), r.accel(feature, first), accel_name });
    } else {
        try rw.print("{d:.0} mm/s: the planned speed. The layer is long enough to cool ({{{{filament.min_layer_time}}}}), and the segments are long enough for the head to reach the speed.", .{real});
    }

    var wf: std.Io.Writer.Allocating = .init(arena);
    const fw = &wf.writer;
    try fw.print("{d:.1} mm\u{b3}/s = the bead area, {d:.4} mm\u{b2} ({d:.2} mm wide, {d:.2} mm high), \u{d7} {d:.0} mm/s.\n\nThe hot end melts at most {d:.1} mm\u{b3}/s of this filament ({{{{filament.max_flow}}}}). This line uses {d:.0} % of it.", .{ real * area, area, bead, h, real, s.filament.max_flow, if (s.filament.max_flow > 0) real * area / s.filament.max_flow * 100 else 0 });
    if (combined) {
        try fw.print("\n\nCombined: {d} layers, {d:.2} mm ({{{{project.infill_layers}}}}). The bead is as tall as the {d} layers, so it has more plastic for each mm, and the flow limit gives a lower speed.", .{ group_n, h, group_n });
    }

    return .{
        .feature = feature,
        .layer = layer,
        .path = path,
        .z = t.layer_z.items[layer],
        .height = h,
        .line_width = w,
        .bead_width = bead,
        .length = length,
        .planned_speed = planned,
        .speed = real,
        .flow = real * area,
        .start_time = t0,
        .end_time = t1,
        .title = try arena.dupeZ(u8, name),
        .explain = try arena.dupeZ(u8, text.written()),
        .settings = try arena.dupeZ(u8, std.mem.trimEnd(u8, names.written(), "\n")),
        .slow_reason = if (slowed) 1 else if (real < planned * 0.95) 2 else 0,
        .why_planned = try arena.dupeZ(u8, wp.written()),
        .why_real = try arena.dupeZ(u8, wr.written()),
        .why_flow = try arena.dupeZ(u8, wf.written()),
    };
}

fn hours(t: f64) u64 {
    return @intFromFloat(@floor(t / 3600));
}
fn minutes(t: f64) u64 {
    return @as(u64, @intFromFloat(@floor(t / 60))) % 60;
}
fn seconds(t: f64) u64 {
    return @as(u64, @intFromFloat(@floor(t))) % 60;
}
