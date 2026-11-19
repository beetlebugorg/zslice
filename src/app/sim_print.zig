//! The print as it forms: the physical simulation of the plastic
//! (print_sim.zig) on the toolpaths of a slice. The result is a copy of the
//! toolpaths with the places where the plastic set, so a view draws it
//! as it draws a slice.
//!
//! - Each path of the slice is a path of the simulation, with its bead
//!   height, its width (from its area), its times, its fan, and its layer.
//!   A closed path gets its closing point. A path with a z for each point
//!   (slope smoothing) keeps them. A path that starts at the end of the
//!   path before it in its layer, with no retraction, is the same strand
//!   (`joined`): the slicer splits a wall into pieces over air and on
//!   plastic, and the nozzle prints them as one line.
//! - A path whose plastic set where it printed keeps its points.
//! - A path with plastic that moved (a sagged bridge, a fallen strand)
//!   gets the masses of the simulation as its points, with a nozzle z for
//!   each point (`point_z`, the top of the bead) and a bead area
//!   (`point_area`). A view draws such a bead down to the top of the layer
//!   under the path, so the area gives the bead its width at the height
//!   that the view draws. Plastic that fell under that layer is a whole
//!   bead: the view draws each link with the bead height plus the z
//!   between its two ends, so a strand that hangs is one bead.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const sim = zs.print_sim;
const Toolpaths = @import("toolpaths.zig").Toolpaths;

/// The outcome of one layer: the largest drop of its plastic under its
/// place (mm), and its failed masses (see `print_sim.Params.fail_drop`).
pub const Layer = struct {
    max_drop: f32 = 0,
    failed: u32 = 0,
};

pub const Result = struct {
    paths: Toolpaths,
    stats: sim.Stats,
    /// For each layer of the slice.
    layers: []Layer,
    /// For each path: the largest drop (mm), and the failed masses.
    drop: []f32,
    failed: []u32,
    /// The masses of the paths that moved: the path, the place where the
    /// slicer meant it to be, and the place where it set (the center of
    /// the bead).
    masses: []Mass,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.paths.deinit(gpa);
        gpa.free(r.layers);
        gpa.free(r.drop);
        gpa.free(r.failed);
        gpa.free(r.masses);
    }
};

pub const Mass = struct { path: u32, want: sim.V, pos: sim.V };

/// The parameters of the simulation from the settings of a slice: the
/// plastic (`filament.material`, or the nearest plastic with data; see
/// print_sim.materialFor), the nozzle, the air around the print, the fans,
/// and the bed.
pub fn paramsOf(s: zs.Settings) sim.Params {
    return .{
        .material = sim.materialFor(s.filament.material).material,
        .nozzle_t = @floatCast(s.filament.nozzle_temp),
        .room_t = @floatCast(s.machine.chamber_temp),
        .fan_air = @floatCast(s.machine.part_fan_air),
        .bed_t = @floatCast(@max(s.filament.bed_temp, s.machine.chamber_temp)),
    };
}

/// The paths of the simulation for the toolpaths `tp`. The points and the
/// z values are in `arena`, or in `tp`.
pub fn toPaths(arena: Allocator, tp: *const Toolpaths) Allocator.Error![]sim.Path {
    const out = try arena.alloc(sim.Path, tp.pathCount());
    const all: []const [2]f32 = @as([*]const [2]f32, @ptrCast(tp.points.items.ptr))[0 .. tp.points.items.len / 2];
    for (0..tp.layerCount()) |l| {
        const p0: usize = if (l == 0) 0 else tp.layer_ends.items[l - 1];
        for (p0..tp.layer_ends.items[l]) |pi| {
            const start = tp.pathStart(pi);
            const end: usize = tp.path_ends.items[pi];
            var xy = all[start..end];
            const z0 = if (pi < tp.path_z_start.items.len) tp.path_z_start.items[pi] else Toolpaths.no_z;
            var zs_: []const f32 = if (z0 == Toolpaths.no_z) &.{} else tp.point_z.items[z0..][0..xy.len];
            if (tp.path_closed.items[pi] != 0 and xy.len > 2) {
                const c = try arena.alloc([2]f32, xy.len + 1);
                @memcpy(c[0..xy.len], xy);
                c[xy.len] = xy[0];
                xy = c;
                if (zs_.len > 0) {
                    const z = try arena.alloc(f32, zs_.len + 1);
                    @memcpy(z[0..zs_.len], zs_);
                    z[zs_.len] = zs_[0];
                    zs_ = z;
                }
            }
            const h = tp.pathHeight(pi, l);
            const area = tp.path_area.items[pi];
            const width: f32 = @floatCast(zs.flow.beadWidth(area, h));
            var joined = false;
            if (pi > p0 and tp.path_retract.items[pi] == 0) {
                const prev = out[pi - 1].xy;
                const e = prev[prev.len - 1];
                joined = std.math.hypot(e[0] - xy[0][0], e[1] - xy[0][1]) < 0.5 * width;
            }
            out[pi] = .{
                .xy = xy,
                .zs = zs_,
                .z = tp.layer_z.items[l],
                .height = h,
                .width = width,
                .area = area,
                .t0 = tp.path_start_time.items[pi],
                .t1 = tp.path_end_time.items[pi],
                .fan = if (pi < tp.path_fan.items.len) @as(f32, @floatFromInt(tp.path_fan.items[pi])) / 255 else 1,
                .layer = @intCast(l),
                .joined = joined,
            };
        }
    }
    return out;
}

/// Simulates the print of `tp`, and returns its toolpaths as the plastic
/// set.
pub fn simulate(gpa: Allocator, tp: *const Toolpaths, params: sim.Params) Allocator.Error!Result {
    const job = try Job.create(gpa, tp, params);
    defer job.destroy();
    while (!try job.advance(std.math.maxInt(usize))) {}
    return job.finish();
}

/// A simulation of the toolpaths of a slice that runs in pieces (see
/// print_sim.Runner): a shell runs it after a slice, between its other
/// work, and drops it at a change. `tp` must stay as it is while the job
/// lives.
pub const Job = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    tp: *const Toolpaths,
    paths: []sim.Path,
    runner: sim.Runner,

    pub fn create(gpa: Allocator, tp: *const Toolpaths, params: sim.Params) Allocator.Error!*Job {
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        job.* = .{ .gpa = gpa, .arena = .init(gpa), .tp = tp, .paths = &.{}, .runner = undefined };
        errdefer job.arena.deinit();
        job.paths = try toPaths(job.arena.allocator(), tp);
        job.runner = try sim.Runner.init(gpa, job.paths, params);
        return job;
    }

    pub fn destroy(job: *Job) void {
        job.runner.deinit();
        job.arena.deinit();
        job.gpa.destroy(job);
    }

    /// Prints up to `count` more paths, and true when the simulation is
    /// done.
    pub fn advance(job: *Job, count: usize) Allocator.Error!bool {
        return job.runner.advance(count);
    }

    pub fn progress(job: *const Job) f64 {
        return job.runner.progress();
    }

    /// The toolpaths as the plastic set, after `advance` gave true.
    pub fn finish(job: *Job) Allocator.Error!Result {
        var r = try job.runner.result();
        defer r.deinit(job.gpa);
        return output(job.gpa, job.tp, job.paths, &r);
    }
};

fn output(gpa: Allocator, tp: *const Toolpaths, paths: []const sim.Path, r: *sim.Result) Allocator.Error!Result {
    // The masses of the paths that moved, for an analysis.
    const masses = try gpa.alloc(Mass, r.pos.len);
    errdefer gpa.free(masses);
    var at: usize = 0;
    for (0..paths.len) |pi| {
        const g = r.ranges[pi];
        for (g[0]..g[0] + g[1]) |i| {
            masses[at] = .{ .path = @intCast(pi), .want = r.want[i], .pos = r.pos[i] };
            at += 1;
        }
    }
    var out: Toolpaths = .{};
    errdefer out.deinit(gpa);
    // The values of the paths and the layers stay.
    inline for (.{ "path_features", "path_area", "path_height", "path_start_time", "path_end_time", "path_retract", "path_fan", "path_modifier", "path_part", "path_key", "layer_slowed", "layer_ends", "layer_z", "layer_height", "layer_width" }) |name| {
        try @field(out, name).appendSlice(gpa, @field(tp, name).items);
    }
    out.z_hop = tp.z_hop;
    try out.path_closed.ensureTotalCapacity(gpa, tp.pathCount());
    try out.path_ends.ensureTotalCapacity(gpa, tp.pathCount());
    try out.path_z_start.ensureTotalCapacity(gpa, tp.pathCount());
    for (0..tp.layerCount()) |l| {
        const p0: usize = if (l == 0) 0 else tp.layer_ends.items[l - 1];
        // A view draws a bead with a z for each point down to this z.
        const z_low = tp.layer_z.items[l] - tp.layer_height.items[l];
        for (p0..tp.layer_ends.items[l]) |pi| {
            const nodes = r.nodes(pi);
            const z0 = if (pi < tp.path_z_start.items.len) tp.path_z_start.items[pi] else Toolpaths.no_z;
            if (nodes.len == 0) {
                // The plastic set where it printed.
                const start = tp.pathStart(pi);
                const end: usize = tp.path_ends.items[pi];
                try out.points.appendSlice(gpa, tp.points.items[2 * start .. 2 * end]);
                out.path_closed.appendAssumeCapacity(tp.path_closed.items[pi]);
                if (z0 == Toolpaths.no_z) {
                    out.path_z_start.appendAssumeCapacity(Toolpaths.no_z);
                } else {
                    out.path_z_start.appendAssumeCapacity(@intCast(out.point_z.items.len));
                    try out.point_z.appendSlice(gpa, tp.point_z.items[z0..][0 .. end - start]);
                    try out.point_area.appendSlice(gpa, tp.point_area.items[z0..][0 .. end - start]);
                    for (start..end, tp.point_z.items[z0..][0 .. end - start]) |k, z| {
                        try out.point_from.append(gpa, .{ tp.points.items[2 * k], tp.points.items[2 * k + 1], z });
                        try out.point_set_time.append(gpa, 0);
                    }
                }
            } else {
                const h = paths[pi].height;
                const w: f64 = paths[pi].width;
                out.path_closed.appendAssumeCapacity(0);
                out.path_z_start.appendAssumeCapacity(@intCast(out.point_z.items.len));
                // A joined path starts at the last mass of the path before.
                var first: [1]sim.V = undefined;
                var first_want: [1]sim.V = undefined;
                var first_set: [1]f32 = .{0};
                if (paths[pi].joined) {
                    const g = r.ranges[pi - 1];
                    const e = paths[pi - 1].xy[paths[pi - 1].xy.len - 1];
                    const planned: sim.V = .{ e[0], e[1], tp.layer_z.items[l] - 0.5 * paths[pi - 1].height };
                    first[0] = if (g[1] > 0) r.pos[g[0] + g[1] - 1] else planned;
                    first_want[0] = if (g[1] > 0) r.want[g[0] + g[1] - 1] else planned;
                    if (g[1] > 0) first_set[0] = r.set_time[g[0] + g[1] - 1];
                }
                const n_lead: usize = @intFromBool(paths[pi].joined);
                const g = r.ranges[pi];
                // The places where the plastic set, and where the nozzle
                // laid it.
                const parts = [2][2][]const sim.V{ .{ first[0..n_lead], first_want[0..n_lead] }, .{ nodes, r.want[g[0]..][0..g[1]] } };
                const sets = [2][]const f32{ first_set[0..n_lead], r.set_time[g[0]..][0..g[1]] };
                for (parts, sets) |part, set| for (part[0], part[1], set) |q, want, t_set| {
                    try out.points.appendSlice(gpa, &.{ q[0], q[1] });
                    const top = q[2] + 0.5 * h;
                    try out.point_from.append(gpa, .{ want[0], want[1], want[2] + 0.5 * h });
                    try out.point_set_time.append(gpa, t_set);
                    try out.point_z.append(gpa, top);
                    // The height that a view draws (see view.zig): down
                    // to the top of the layer under the path, or the bead
                    // height for plastic that fell under it.
                    const drawn = if (top - z_low < 0.25 * h) h else top - z_low;
                    try out.point_area.append(gpa, @floatCast(zs.flow.beadArea(w, drawn)));
                };
            }
            out.path_ends.appendAssumeCapacity(@intCast(out.points.items.len / 2));
        }
    }
    const layers = try gpa.alloc(Layer, tp.layerCount());
    errdefer gpa.free(layers);
    for (layers, 0..) |*ly, l| {
        ly.* = .{};
        const p0: usize = if (l == 0) 0 else tp.layer_ends.items[l - 1];
        for (p0..tp.layer_ends.items[l]) |pi| {
            ly.max_drop = @max(ly.max_drop, r.drop[pi]);
            ly.failed += r.failed[pi];
        }
    }
    const drop = r.drop;
    const failed = r.failed;
    r.drop = &.{};
    r.failed = &.{};
    return .{ .paths = out, .stats = r.stats, .layers = layers, .drop = drop, .failed = failed, .masses = masses };
}

const testing = std.testing;

/// The toolpaths of two posts and a bridge over them (as in print_sim.zig),
/// in one layer each.
fn bridgeToolpaths(gpa: Allocator) !Toolpaths {
    var t: Toolpaths = .{};
    errdefer t.deinit(gpa);
    const area: f32 = @floatCast(zs.flow.beadArea(0.45, 0.2));
    var time: f32 = 0;
    for (0..21) |k| {
        const z = 0.2 * @as(f32, @floatFromInt(k + 1));
        const lines: []const [4]f32 = if (k < 20) &.{ .{ 0, 0, 0, 3 }, .{ 20, 3, 20, 0 } } else &.{.{ -0.2, 1.5, 20.2, 1.5 }};
        for (lines) |ln| {
            try t.points.appendSlice(gpa, &ln);
            try t.path_ends.append(gpa, @intCast(t.points.items.len / 2));
            try t.path_features.append(gpa, 0);
            try t.path_closed.append(gpa, 0);
            try t.path_area.append(gpa, area);
            try t.path_height.append(gpa, 0.2);
            const l = std.math.hypot(ln[2] - ln[0], ln[3] - ln[1]);
            try t.path_start_time.append(gpa, time);
            time += l / 15;
            try t.path_end_time.append(gpa, time);
            try t.path_retract.append(gpa, 0);
            try t.path_fan.append(gpa, 255);
            try t.path_modifier.append(gpa, 0);
            try t.path_part.append(gpa, 0);
            try t.path_key.append(gpa, t.path_key.items.len);
            try t.path_z_start.append(gpa, Toolpaths.no_z);
        }
        time += 2;
        try t.layer_slowed.append(gpa, 0);
        try t.layer_ends.append(gpa, @intCast(t.path_ends.items.len));
        try t.layer_z.append(gpa, z);
        try t.layer_height.append(gpa, 0.2);
        try t.layer_width.append(gpa, 0.45);
    }
    return t;
}

test "sim print: the posts keep their points, and the bridge gets its sag" {
    const gpa = testing.allocator;
    var tp = try bridgeToolpaths(gpa);
    defer tp.deinit(gpa);
    var r = try simulate(gpa, &tp, .{});
    defer r.deinit(gpa);
    const out = &r.paths;
    try testing.expectEqual(tp.pathCount(), out.pathCount());
    try testing.expectEqual(tp.layerCount(), out.layerCount());
    try testing.expectEqual(@as(usize, 1), r.stats.moved_paths);
    // The posts are the same.
    for (0..40) |pi| {
        try testing.expectEqual(Toolpaths.no_z, out.path_z_start.items[pi]);
        try testing.expectEqualSlices(f32, tp.points.items[2 * tp.pathStart(pi) .. 2 * tp.path_ends.items[pi]], out.points.items[2 * out.pathStart(pi) .. 2 * out.path_ends.items[pi]]);
    }
    // The bridge has a point for each mass, lower in the middle.
    const b = 40;
    const n = out.path_ends.items[b] - out.pathStart(b);
    try testing.expect(n > 80);
    const zs_ = out.point_z.items[out.path_z_start.items[b]..][0..n];
    try testing.expectApproxEqAbs(@as(f32, 4.2), zs_[0], 1e-4);
    try testing.expect(zs_[n / 2] < 4.2 - 0.15);
    try testing.expect(zs_[n / 2] > 4.2 - 1);
    // The view draws the bead with the path width.
    const a = out.point_area.items[out.path_z_start.items[b] + n / 2];
    const drawn = if (zs_[n / 2] - 4.0 < 0.25 * 0.2) 0.2 else zs_[n / 2] - 4.0;
    try testing.expectApproxEqAbs(@as(f64, 0.45), zs.flow.beadWidth(a, drawn), 1e-3);
}
