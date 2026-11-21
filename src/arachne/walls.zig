//! Arachne walls: the variable-width wall lines of one layer outline.
//!
//! The steps, as CuraEngine `WallToolPaths::generateArachne`:
//!
//! 1. Clean the outline (CuraEngine `MendedShape`): an opening and a
//!    closing by half the minimum feature size remove slivers that cannot
//!    print, small areas go, and the points within the maximum deviation
//!    of a straight line go. A union then removes any crossing. The
//!    Voronoi diagram needs segments that do not cross.
//! 2. Make the beading strategy (see `beading.zig`) and the skeletal
//!    trapezoidation (see `skeletal.zig`). Its toolpaths are pieces of
//!    lines, one list for each wall.
//! 3. Stitch the pieces of each wall into lines and loops, remove short odd
//!    lines (shorter than half their width), and simplify the lines.
//! 4. The lines of width 0 are not printed. They mark the inner edge of
//!    the walls: their closed loops make the inner contour, the area for
//!    the skin and the infill.
//!
//! Not ported from CuraEngine: the "fluid motion" smoothing of the
//! outline, and the walls of support.
//!
//! This file is a port to Zig of CuraEngine
//! (https://github.com/Ultimaker/CuraEngine, commit
//! 5eff812d2124b2eb93f832e92d33ccdba721135b): `src/WallToolPaths.cpp` and
//! `src/types/geometry/MendedShape.cpp`.
//!
//! Copyright (c) 2026 UltiMaker. CuraEngine is released under the terms of
//! the AGPLv3 or higher. This port is part of zslice (AGPL-3.0-or-later).
//! See docs/references/cura.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("../geom.zig");
const clip = @import("../clip.zig");
const offset_mod = @import("../offset.zig");
const beading = @import("beading.zig");
const extrusion = @import("extrusion.zig");
const skeletal = @import("skeletal.zig");
const Paths = geom.Paths;
const Lines = extrusion.Lines;
const Line = extrusion.Line;

/// The settings of the walls of one layer. Lengths in micrometers.
pub const Params = struct {
    walls: beading.WallSettings,
    /// Transitions closer together than this cancel out.
    wall_transition_filter_distance: i64 = 100_000,
    /// The line width change that a canceled transition can cause.
    wall_transition_filter_deviation: i64 = 100,
    /// The step along a curved part of the center line.
    discretization_step_size: i64 = 800,
    simplify: extrusion.SimplifyParams = .{},
};

/// The wall lines of a layer, and the area inside them.
pub const Result = struct {
    /// The lines of each wall, from the outer wall (0) inward. The lines of
    /// a wall can be loops (`is_closed`) or open lines.
    insets: []Lines,
    /// The area inside the walls, for the skin and the infill.
    inner: Paths,
};

/// The walls of `outline`. All memory is in `a` (an arena).
pub fn generate(a: Allocator, outline: Paths, p: Params) !Result {
    const ws = p.walls;
    if (ws.inset_count == 0) return .{ .insets = &.{}, .inner = outline };
    const prepared = try mend(a, outline, p);
    if (prepared.isEmpty() or prepared.areaMm2() <= 0) return .{ .insets = &.{}, .inner = .empty };

    const strategy = beading.forWalls(ws);
    var st = try skeletal.SkeletalTrapezoidation.init(a, prepared, &strategy, .{
        .transitioning_angle = strategy.getTransitioningAngle(),
        .discretization_step_size = p.discretization_step_size,
        .transition_filter_dist = p.wall_transition_filter_distance,
        .allowed_filter_deviation = p.wall_transition_filter_deviation,
        .beading_propagation_transition_dist = ws.wall_transition_length,
    });
    var toolpaths: std.ArrayList(Lines) = .empty;
    try st.generateToolpaths(&toolpaths, false);

    // In 0-width contours, the junctions can leave gaps of up to one line
    // width. Do not stitch more than one line width.
    const stitch_distance = ws.bead_width_x - 1;
    try stitchToolPaths(a, toolpaths.items, stitch_distance);
    removeSmallFillLines(toolpaths.items);
    try simplifyToolPaths(a, toolpaths.items, p.simplify);
    return separateOutInnerContour(a, toolpaths.items, ws.inset_count);
}

/// The outline, ready for the Voronoi diagram (CuraEngine `MendedShape`).
fn mend(a: Allocator, outline: Paths, p: Params) !Paths {
    const ws = p.walls;
    // Slivers can spoil the prepared outline. An opening and a closing by
    // half the minimum printable feature size removes them, and keeps the
    // shape (CuraEngine PR 1811).
    const open_close = if (ws.print_thin_walls) @divTrunc(ws.min_feature_size, 2) - 5 else @divTrunc(ws.min_even_wall_line_width, 2) - 5;
    var shape = outline;
    if (open_close > 0) {
        shape = try offset_mod.offset(a, shape, -open_close, .{});
        shape = try offset_mod.offset(a, shape, 2 * open_close, .{});
        shape = try offset_mod.offset(a, shape, -open_close, .{});
    }
    // Remove small areas (not holes).
    const small_len: f64 = @as(f64, @floatFromInt(ws.bead_width_0)) / 2.0;
    const small_area_mm2 = small_len * small_len / 1e6;
    var kept: Paths = .empty;
    for (0..shape.count()) |k| {
        const poly = shape.get(k);
        const ar = geom.areaMm2(poly);
        if (ar > 0 and ar < small_area_mm2) continue;
        // Simplify: the points within the maximum deviation of a line go.
        const copy = try a.dupe(geom.Point, poly);
        const n = geom.simplifyClosed(copy, p.simplify.max_deviation);
        if (n < 3) continue;
        try kept.append(a, copy[0..n]);
    }
    // A union removes crossings and degenerate parts.
    return clip.unionAll(a, kept, .positive);
}

fn stitchToolPaths(a: Allocator, toolpaths: []Lines, stitch_distance: i64) !void {
    for (toolpaths) |*wall_lines| {
        var stitched: Lines = .empty;
        var closed: Lines = .empty;
        var input: Lines = .empty;
        for (wall_lines.items) |l| {
            if (l.junctions.items.len > 0) try input.append(a, l);
        }
        try extrusion.stitch(a, input.items, &stitched, &closed, stitch_distance, 10);
        for (closed.items) |*poly| {
            if (poly.junctions.items.len == 0) continue;
            poly.is_closed = true;
            try stitched.append(a, poly.*);
        }
        wall_lines.* = stitched;
    }
}

/// Removes the odd open lines shorter than half their width.
fn removeSmallFillLines(toolpaths: []Lines) void {
    for (toolpaths) |*inset| {
        var i: usize = 0;
        while (i < inset.items.len) {
            const line = inset.items[i];
            if (line.inset_idx != 0 and line.is_odd and !line.is_closed and line.shorterThan(@divTrunc(line.minWidth(), 2))) {
                // Remove the line: the last one takes its place, and is
                // checked next.
                _ = inset.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
}

fn simplifyToolPaths(a: Allocator, toolpaths: []Lines, sp: extrusion.SimplifyParams) !void {
    for (toolpaths) |*toolpath| {
        var out: Lines = .empty;
        for (toolpath.items) |line| {
            var s = try extrusion.simplify(a, line, sp);
            const js = s.junctions.items;
            if (s.is_closed and js.len >= 2 and !js[0].eql(js[js.len - 1])) try s.junctions.append(a, js[0]);
            if (s.junctions.items.len > 0) try out.append(a, s);
        }
        toolpath.* = out;
    }
}

/// Moves the lines of width 0 out of the toolpaths, into the inner
/// contour.
fn separateOutInnerContour(a: Allocator, toolpaths: []Lines, inset_count: usize) !Result {
    _ = inset_count;
    var actual: std.ArrayList(Lines) = .empty;
    var contour: Paths = .empty;
    for (toolpaths) |inset| {
        if (inset.items.len == 0) continue;
        // As in CuraEngine, the first junction of the last line decides.
        var is_contour = false;
        for (inset.items) |line| {
            if (line.junctions.items.len > 0) is_contour = line.junctions.items[0].w == 0;
        }
        if (is_contour) {
            for (inset.items) |line| {
                // Odd lines are not part of the contour. A very small even
                // loop can stay open.
                if (line.is_odd or !line.is_closed) continue;
                var pts: std.ArrayList(geom.Point) = .empty;
                for (line.junctions.items) |j| try pts.append(a, j.p);
                // The loop ends with its first point again.
                if (pts.items.len > 1 and pts.items[0].eql(pts.items[pts.items.len - 1])) _ = pts.pop();
                if (pts.items.len >= 3) try contour.append(a, pts.items);
            }
        } else {
            var kept: Lines = .empty;
            for (inset.items) |line| {
                if (line.junctions.items.len > 0) try kept.append(a, line);
            }
            if (kept.items.len > 0) try actual.append(a, kept);
        }
    }
    // The loops have no known direction, so the even-odd rule makes the
    // area: the outer loops positive, the holes negative.
    const inner = if (contour.isEmpty()) contour else try clip.unionAll(a, contour, .even_odd);
    return .{ .insets = actual.items, .inner = inner };
}

const testing = std.testing;

/// The wall settings of the tests: 0.4 mm lines, as Cura for a 0.4 mm
/// nozzle.
fn testParams(walls: usize) Params {
    return .{ .walls = .{
        .bead_width_0 = 400,
        .bead_width_x = 400,
        .inset_count = walls,
        .min_feature_size = 100,
        .min_bead_width = 340,
        .wall_transition_length = 400,
        .min_even_wall_line_width = 340,
        .min_odd_wall_line_width = 340,
    } };
}

fn rect(a: Allocator, x0: i64, y0: i64, x1: i64, y1: i64) !Paths {
    var p: Paths = .empty;
    try p.append(a, &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } });
    return p;
}

test "a 1.2 mm wall with 0.4 mm lines gets 3 beads of 0.4 mm" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outline = try rect(a, 0, 0, 20000, 1200);
    const r = try generate(a, outline, testParams(3));
    try testing.expect(r.inner.isEmpty());
    // The outer loop and one odd line in the middle.
    var lines: usize = 0;
    var odd: usize = 0;
    for (r.insets) |inset| for (inset.items) |line| {
        lines += 1;
        if (line.is_odd) odd += 1;
    };
    try testing.expectEqual(@as(usize, 2), lines);
    try testing.expectEqual(@as(usize, 1), odd);
    for (r.insets) |inset| for (inset.items) |line| for (line.junctions.items) |j| {
        try testing.expect(@abs(j.w - 400) <= 2);
        // The outer wall is half a line inside the outline, the odd line
        // in the middle.
        if (line.is_odd) try testing.expectEqual(@as(i64, 600), j.p.y) else try testing.expect(j.p.y == 200 or j.p.y == 1000);
    };
}

test "a 0.3 mm fin prints one narrow bead" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outline = try rect(a, 0, 0, 20000, 300);
    const r = try generate(a, outline, testParams(2));
    var lines: usize = 0;
    for (r.insets) |inset| for (inset.items) |line| {
        lines += 1;
        try testing.expect(line.is_odd);
        // The bead is narrower than a line: the minimum bead width.
        for (line.junctions.items) |j| try testing.expect(j.w >= 300 and j.w <= 340);
        // It goes along the middle of the fin.
        for (line.junctions.items) |j| try testing.expect(@abs(j.p.y - 150) <= 2);
    };
    try testing.expectEqual(@as(usize, 1), lines);
}

test "a wedge gets a smooth bead count transition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A wedge from 0.2 mm to 3 mm thick over 40 mm.
    var outline: Paths = .empty;
    try outline.append(a, &.{ .{ .x = 0, .y = -100 }, .{ .x = 40000, .y = -1500 }, .{ .x = 40000, .y = 1500 }, .{ .x = 0, .y = 100 } });
    const r = try generate(a, outline, testParams(3));
    // Each bead is between the minimum bead width and the widest bead of
    // the strategy (two minimum widths), plus some rounding.
    for (r.insets) |inset| for (inset.items) |line| for (line.junctions.items) |j| {
        try testing.expect(j.w >= 300 and j.w <= 2 * 340 + 20);
    };
    // The number of beads across the wedge goes up, never down, from the
    // thin end to the thick end.
    var last: usize = 0;
    var x: i64 = 2000;
    while (x <= 36000) : (x += 2000) {
        var count: usize = 0;
        for (r.insets) |inset| for (inset.items) |line| {
            const js = line.junctions.items;
            for (js[0 .. js.len - 1], js[1..]) |p, q| {
                if ((p.p.x < x) != (q.p.x < x) and p.w > 0) count += 1;
            }
            if (line.is_closed and js.len > 1) {
                const p = js[js.len - 1];
                const q = js[0];
                if ((p.p.x < x) != (q.p.x < x)) count += 1;
            }
        };
        try testing.expect(count + 1 >= last);
        last = count;
    }
    // The thick end has the walls (6 bead crossings) and an inner area.
    try testing.expect(last >= 6);
    try testing.expect(!r.inner.isEmpty());
}

