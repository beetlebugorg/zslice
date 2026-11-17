//! Gaps in a layer: the parts of the area that should be solid that no
//! bead covers.
//!
//! The area that should be solid is the outline of the layer less the area
//! of the sparse infill (LayerPlan.sparse_area), which is sparse on
//! purpose. The covered area is the footprint of each bead: the path, grown
//! by half of its line width, with round ends. A raster of square cells
//! (`Options.cell`, 0.04 mm) holds both: it is simple, and it has no
//! trouble with the many small, round shapes of the footprints. The cells
//! that should be solid and are not covered form the gaps, one for each
//! group of cells that touch. A group that is thinner than 3 cells (a
//! sliver at the round end of a bead, or at a sharp corner of a wall) and
//! a group smaller than `Options.min_area` are left out.
//!
//! For each gap the result has its area, its center, its width (twice the
//! largest distance from a cell to the edge of the gap), the features of
//! the beads around it (a bit for each settings.Feature), and its cells, as
//! runs along x, for a picture. The features say which settings can close
//! the gap (see app/gap_advice.zig).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const layer = @import("layer.zig");
const Feature = @import("settings.zig").Feature;
const Paths = geom.Paths;

pub const Options = struct {
    /// The size of a cell of the raster, in mm.
    cell: f64 = 0.04,
    /// The smallest gap, in mm².
    min_area: f64 = 0.02,
};

/// A run of gap cells along x, in mm: from x0 to x1 at the row y (the
/// center of the row; a row is one cell tall).
pub const Run = struct { y: f32, x0: f32, x1: f32 };

pub const Gap = struct {
    /// mm²
    area: f64,
    /// The center, in mm, in the frame of the layer (as its points).
    x: f64,
    y: f64,
    /// Twice the largest distance from a cell of the gap to its edge, in
    /// mm: the width of a bead that would fill it.
    width: f64,
    /// A bit for each feature (1 << @intFromEnum(Feature)) of the beads next
    /// to the gap.
    features: u32,
    /// The gap touches the edge of the area that should be solid: the
    /// outline of the layer, or the sparse infill.
    at_edge: bool,
    /// Its cells: runs[run_start..][0..run_len] of `Result.runs`.
    run_start: u32,
    run_len: u32,
};

pub const Result = struct {
    gaps: []Gap,
    runs: []Run,
    cell: f64,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.gaps);
        gpa.free(r.runs);
    }

    /// The gap with a cell at x, y (mm), or the nearest gap within `reach`
    /// mm, or null.
    pub fn at(r: Result, x: f64, y: f64, reach: f64) ?usize {
        var best: ?usize = null;
        var best_d: f64 = reach;
        for (r.gaps, 0..) |g, gi| {
            for (r.runs[g.run_start..][0..g.run_len]) |run| {
                const dy = @max(0, @abs(y - run.y) - r.cell / 2);
                const dx = if (x < run.x0) run.x0 - x else if (x > run.x1) x - run.x1 else 0;
                const d = @sqrt(dx * dx + dy * dy);
                if (d <= best_d) {
                    best = gi;
                    best_d = d;
                }
            }
        }
        return best;
    }
};

/// The features whose beads cover area: the planar beads of the layer.
fn covers(f: Feature) bool {
    return switch (f) {
        .outer_wall, .inner_wall, .skin, .infill => true,
        // Ironing goes over a covered top; the skirt and the support are
        // outside the outline; the slope passes are above the layer.
        .ironing, .skirt, .support, .support_interface, .slope_smoothing, .slope_ironing => false,
    };
}

const Grid = struct {
    w: usize,
    h: usize,
    x0: f64,
    y0: f64,
    cell: f64,
    /// 0 no, 1 should be solid.
    want: []u8,
    /// 0 not covered, else the feature + 1 of a bead that covers it.
    have: []u8,

    fn cx(g: Grid, i: usize) f64 {
        return g.x0 + (@as(f64, @floatFromInt(i)) + 0.5) * g.cell;
    }

    fn cy(g: Grid, j: usize) f64 {
        return g.y0 + (@as(f64, @floatFromInt(j)) + 0.5) * g.cell;
    }

    /// Sets `value` in the cells whose centers are inside `paths` (the
    /// even-odd rule, as the outlines are made).
    fn fill(g: Grid, paths: Paths, buf: []u8, value: u8, xs: *std.ArrayList(f64), gpa: Allocator) Allocator.Error!void {
        for (0..g.h) |j| {
            const y = g.cy(j);
            xs.clearRetainingCapacity();
            for (0..paths.count()) |k| {
                const poly = paths.get(k);
                if (poly.len < 3) continue;
                var prev = poly[poly.len - 1];
                for (poly) |p| {
                    defer prev = p;
                    const ay = geom.toMm(prev.y);
                    const by = geom.toMm(p.y);
                    if ((ay <= y) == (by <= y)) continue;
                    const ax = geom.toMm(prev.x);
                    const bx = geom.toMm(p.x);
                    try xs.append(gpa, ax + (y - ay) / (by - ay) * (bx - ax));
                }
            }
            std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
            var k: usize = 0;
            while (k + 1 < xs.items.len) : (k += 2) {
                const a = @max(0, @ceil((xs.items[k] - g.x0) / g.cell - 0.5));
                const b = @min(@as(f64, @floatFromInt(g.w)) - 1, @floor((xs.items[k + 1] - g.x0) / g.cell - 0.5));
                if (b < a) continue;
                const ia: usize = @intFromFloat(a);
                const ib: usize = @intFromFloat(b);
                @memset(buf[j * g.w + ia .. j * g.w + ib + 1], value);
            }
        }
    }

    /// Marks the cells within r of the segment from (ax, ay) to (bx, by), in
    /// mm, as covered by feature f.
    fn capsule(g: Grid, ax: f64, ay: f64, bx: f64, by: f64, r: f64, f: Feature) void {
        const lo_x = @max(0, @floor((@min(ax, bx) - r - g.x0) / g.cell));
        const hi_x = @min(@as(f64, @floatFromInt(g.w)) - 1, @ceil((@max(ax, bx) + r - g.x0) / g.cell));
        const lo_y = @max(0, @floor((@min(ay, by) - r - g.y0) / g.cell));
        const hi_y = @min(@as(f64, @floatFromInt(g.h)) - 1, @ceil((@max(ay, by) + r - g.y0) / g.cell));
        if (hi_x < lo_x or hi_y < lo_y) return;
        const dx = bx - ax;
        const dy = by - ay;
        const len2 = dx * dx + dy * dy;
        const r2 = r * r;
        var j: usize = @intFromFloat(lo_y);
        while (j <= @as(usize, @intFromFloat(hi_y))) : (j += 1) {
            const y = g.cy(j);
            var i: usize = @intFromFloat(lo_x);
            while (i <= @as(usize, @intFromFloat(hi_x))) : (i += 1) {
                const x = g.cx(i);
                const t = if (len2 > 0) std.math.clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1) else 0;
                const ex = ax + t * dx - x;
                const ey = ay + t * dy - y;
                if (ex * ex + ey * ey <= r2) g.have[j * g.w + i] = @as(u8, @intFromEnum(f)) + 1;
            }
        }
    }
};

/// Finds the gaps of the layer plan `lp`. The caller owns the result.
pub fn find(gpa: Allocator, lp: *const layer.LayerPlan, opts: Options) Allocator.Error!Result {
    var empty: Result = .{ .gaps = &.{}, .runs = &.{}, .cell = opts.cell };
    const box = lp.outline.bounds();
    if (lp.outline.isEmpty() or box.max.x <= box.min.x) {
        empty.gaps = try gpa.alloc(Gap, 0);
        empty.runs = try gpa.alloc(Run, 0);
        return empty;
    }
    const margin = 2 * opts.cell;
    const x0 = geom.toMm(box.min.x) - margin;
    const y0 = geom.toMm(box.min.y) - margin;
    const w: usize = @intFromFloat(@ceil((geom.toMm(box.max.x) + margin - x0) / opts.cell));
    const h: usize = @intFromFloat(@ceil((geom.toMm(box.max.y) + margin - y0) / opts.cell));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g: Grid = .{ .w = w, .h = h, .x0 = x0, .y0 = y0, .cell = opts.cell, .want = try arena.alloc(u8, w * h), .have = try arena.alloc(u8, w * h) };
    @memset(g.want, 0);
    @memset(g.have, 0);
    var xs: std.ArrayList(f64) = .empty;
    try g.fill(lp.outline, g.want, 1, &xs, arena);
    try g.fill(lp.sparse_area, g.want, 0, &xs, arena);

    // The footprints of the beads.
    var start: usize = 0;
    for (lp.paths.items, 0..) |path, pi| {
        const end: usize = lp.points.ends.items[pi];
        defer start = end;
        if (!covers(path.feature) or end <= start) continue;
        const pts = lp.points.points.items[start..end];
        const r = (if (path.width > 0) @as(f64, path.width) else lp.width) / 2;
        for (0..pts.len) |k| {
            const a = pts[k];
            const b = if (k + 1 < pts.len) pts[k + 1] else if (path.closed) pts[0] else a;
            g.capsule(geom.toMm(a.x), geom.toMm(a.y), geom.toMm(b.x), geom.toMm(b.y), r, path.feature);
        }
    }

    // The gap cells: should be solid, and not covered. A cell is in a gap
    // only if the cells around it are gap cells too, or the gap is thicker
    // than a sliver (see `core`).
    const gap = try arena.alloc(u8, w * h);
    for (gap, g.want, g.have) |*c, want, have| c.* = @intFromBool(want == 1 and have == 0);
    // Groups of gap cells that touch (4 neighbors).
    const label = try arena.alloc(u32, w * h);
    @memset(label, 0);
    var stack: std.ArrayList(usize) = .empty;
    var cells: std.ArrayList(usize) = .empty;
    var gaps: std.ArrayList(Gap) = .empty;
    errdefer gaps.deinit(gpa);
    var runs: std.ArrayList(Run) = .empty;
    errdefer runs.deinit(gpa);
    var next: u32 = 1;
    const cell_area = opts.cell * opts.cell;
    for (0..w * h) |seed| {
        if (gap[seed] == 0 or label[seed] != 0) continue;
        cells.clearRetainingCapacity();
        stack.clearRetainingCapacity();
        try stack.append(arena, seed);
        label[seed] = next;
        while (stack.pop()) |c| {
            try cells.append(arena, c);
            const ci = c % w;
            const cj = c / w;
            const nbs = [_]?usize{
                if (ci > 0) c - 1 else null,
                if (ci + 1 < w) c + 1 else null,
                if (cj > 0) c - w else null,
                if (cj + 1 < h) c + w else null,
            };
            for (nbs) |nb| if (nb) |n| if (gap[n] == 1 and label[n] == 0) {
                label[n] = next;
                try stack.append(arena, n);
            };
        }
        const id = next;
        next += 1;
        const area = @as(f64, @floatFromInt(cells.items.len)) * cell_area;
        if (area < opts.min_area) continue;
        // The width: the number of erosions of the group until it is gone.
        const depth = try erosions(arena, label, id, cells.items, w, h);
        if (depth < 2) continue; // a sliver, 3 cells thick or less
        var sx: f64 = 0;
        var sy: f64 = 0;
        var features: u32 = 0;
        var at_edge = false;
        for (cells.items) |c| {
            const ci = c % w;
            const cj = c / w;
            sx += g.cx(ci);
            sy += g.cy(cj);
            // The beads and the edges within 2 cells.
            var dj: i64 = -2;
            while (dj <= 2) : (dj += 1) {
                var di: i64 = -2;
                while (di <= 2) : (di += 1) {
                    const ni = @as(i64, @intCast(ci)) + di;
                    const nj = @as(i64, @intCast(cj)) + dj;
                    if (ni < 0 or nj < 0 or ni >= w or nj >= h) continue;
                    const n: usize = @intCast(nj * @as(i64, @intCast(w)) + ni);
                    if (g.have[n] != 0) features |= @as(u32, 1) << @intCast(g.have[n] - 1) else if (g.want[n] == 0) at_edge = true;
                }
            }
        }
        const n_cells: f64 = @floatFromInt(cells.items.len);
        // The runs of the group, row by row.
        std.mem.sort(usize, cells.items, {}, std.sort.asc(usize));
        const run_start: u32 = @intCast(runs.items.len);
        var k: usize = 0;
        while (k < cells.items.len) {
            var e = k;
            while (e + 1 < cells.items.len and cells.items[e + 1] == cells.items[e] + 1 and cells.items[e + 1] % w != 0) e += 1;
            const cj = cells.items[k] / w;
            try runs.append(gpa, .{
                .y = @floatCast(g.cy(cj)),
                .x0 = @floatCast(g.cx(cells.items[k] % w) - opts.cell / 2),
                .x1 = @floatCast(g.cx(cells.items[e] % w) + opts.cell / 2),
            });
            k = e + 1;
        }
        try gaps.append(gpa, .{
            .area = area,
            .x = sx / n_cells,
            .y = sy / n_cells,
            .width = 2 * (@as(f64, @floatFromInt(depth)) + 0.5) * opts.cell,
            .features = features,
            .at_edge = at_edge,
            .run_start = run_start,
            .run_len = @intCast(runs.items.len - run_start),
        });
    }
    // The largest gaps first.
    std.mem.sort(Gap, gaps.items, {}, struct {
        fn lt(_: void, a: Gap, b: Gap) bool {
            return a.area > b.area;
        }
    }.lt);
    return .{ .gaps = try gaps.toOwnedSlice(gpa), .runs = try runs.toOwnedSlice(gpa), .cell = opts.cell };
}

/// The number of erosions (4 neighbors) of the group `id` of `label` until
/// it has no cell left: about half of its width, in cells.
fn erosions(arena: Allocator, label: []const u32, id: u32, cells: []const usize, w: usize, h: usize) Allocator.Error!u32 {
    const alive = try arena.alloc(bool, cells.len);
    @memset(alive, true);
    // The index of each cell of the group in `cells`, for the test of the
    // neighbors.
    var index: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    for (cells, 0..) |c, k| try index.put(arena, c, @intCast(k));
    const next = try arena.alloc(bool, cells.len);
    var depth: u32 = 0;
    while (true) {
        var any = false;
        for (cells, 0..) |c, k| {
            next[k] = false;
            if (!alive[k]) continue;
            const ci = c % w;
            const cj = c / w;
            const nbs = [_]?usize{
                if (ci > 0) c - 1 else null,
                if (ci + 1 < w) c + 1 else null,
                if (cj > 0) c - w else null,
                if (cj + 1 < h) c + w else null,
            };
            var inner = true;
            for (nbs) |nb| {
                const n = nb orelse {
                    inner = false;
                    break;
                };
                if (label[n] != id) {
                    inner = false;
                    break;
                }
                const nk = index.get(n).?;
                if (!alive[nk]) {
                    inner = false;
                    break;
                }
            }
            next[k] = inner;
            any = any or inner;
        }
        if (!any) return depth;
        depth += 1;
        @memcpy(alive, next);
    }
}

const testing = std.testing;

fn testPlan(gpa: Allocator, width: f64) !layer.LayerPlan {
    var lp: layer.LayerPlan = .{ .arena = .init(gpa), .index = 1, .z = 0.4, .height = 0.2, .width = width };
    const a = lp.arena.allocator();
    // A 10 x 10 mm square.
    try lp.outline.append(a, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    return lp;
}

fn addPath(lp: *layer.LayerPlan, f: Feature, closed: bool, pts: []const geom.Point) !void {
    const a = lp.arena.allocator();
    try lp.paths.append(a, .{ .feature = f, .closed = closed });
    try lp.points.append(a, pts);
}

test "gaps: a covered square has none, and a missing line leaves one" {
    const gpa = testing.allocator;
    var lp = try testPlan(gpa, 0.5);
    defer lp.deinit();
    // The outer wall, and skin lines 0.5 mm apart in the inside.
    try addPath(&lp, .outer_wall, true, &.{ .init(250, 250), .init(9750, 250), .init(9750, 9750), .init(250, 9750) });
    var y: i64 = 750;
    var skipped = false;
    while (y < 9500) : (y += 500) {
        // Leave out the line at y = 5250: a gap of one line in the middle.
        if (y == 5250) {
            skipped = true;
            continue;
        }
        try addPath(&lp, .skin, false, &.{ .init(500, y), .init(9500, y) });
    }
    try testing.expect(skipped);
    var r = try find(gpa, &lp, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.gaps.len);
    const g = r.gaps[0];
    // About 9 mm x 0.5 mm, in the middle, between skin lines.
    try testing.expect(g.area > 3 and g.area < 6);
    try testing.expectApproxEqAbs(@as(f64, 5.25), g.y, 0.1);
    try testing.expect(g.width > 0.3 and g.width < 0.8);
    try testing.expect(g.features & (1 << @intFromEnum(Feature.skin)) != 0);
    try testing.expect(r.at(5, 5.25, 0.1) != null);
    try testing.expect(r.at(2, 2, 0.1) == null);
}

test "gaps: the sparse infill area is not a gap, and slivers are left out" {
    const gpa = testing.allocator;
    var lp = try testPlan(gpa, 0.5);
    defer lp.deinit();
    const a = lp.arena.allocator();
    try addPath(&lp, .outer_wall, true, &.{ .init(250, 250), .init(9750, 250), .init(9750, 9750), .init(250, 9750) });
    try addPath(&lp, .inner_wall, true, &.{ .init(750, 750), .init(9250, 750), .init(9250, 9250), .init(750, 9250) });
    // All inside the inner wall is sparse infill area.
    try lp.sparse_area.append(a, &.{ .init(1000, 1000), .init(9000, 1000), .init(9000, 9000), .init(1000, 9000) });
    var r = try find(gpa, &lp, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.gaps.len);
}
