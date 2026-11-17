//! Beading strategies: how many beads (wall lines) fill a wall of a given
//! thickness, and how wide each bead is.
//!
//! Arachne (see `arachne.zig`) measures the thickness of the part at each
//! point of its center line. A beading strategy turns that thickness into
//! beads. The strategies are layers. Each layer changes the result of the
//! layer below it:
//!
//! 1. Distributed: n beads of the optimal width fill n optimal widths. The
//!    rest (positive or negative) goes to the beads near the middle, with
//!    weights that fall off with the distance from the middle
//!    (`wall_distribution_count`).
//! 2. Redistribute: the two outer beads keep the outer wall width. Only the
//!    inner beads change width. One or two beads share a thin wall.
//! 3. Widening: a part thinner than one bead, but thicker than the
//!    minimum feature size, gets one bead of at least the minimum bead
//!    width.
//! 4. Outer wall inset and inner wall inset: move the beads in by a fixed
//!    distance.
//! 5. Limited: at most 2 x (wall count) beads. A thicker part gets the
//!    beads of its optimal thickness at the sides, and a bead of width 0
//!    at the inner side of the walls. The 0-width bead marks the edge of
//!    the area for the skin and the infill.
//!
//! The thickness at which the bead count goes from n to n + 1 is the
//! transition thickness. Below it, n beads get wider; above it, n + 1
//! beads get narrower.
//!
//! This file is a port to Zig of the beading strategies of CuraEngine
//! (https://github.com/Ultimaker/CuraEngine, commit
//! 5eff812d2124b2eb93f832e92d33ccdba721135b): the files
//! `src/beading_strategy/BeadingStrategy.cpp`,
//! `DistributedBeadingStrategy.cpp`, `RedistributeBeadingStrategy.cpp`,
//! `WideningBeadingStrategy.cpp`, `OuterWallInsetBeadingStrategy.cpp`,
//! `InnerWallInsetBeadingStrategy.cpp`, `LimitedBeadingStrategy.cpp`, the
//! headers in `include/beading_strategy/`, and
//! `src/utils/beading_strategy_factory.cpp`. The integer arithmetic
//! (truncation toward zero) follows the C++ code.
//!
//! Copyright (c) 2026 UltiMaker. CuraEngine is released under the terms of
//! the AGPLv3 or higher. This port is part of zslice (AGPL-3.0-or-later).
//! See REFERENCES.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The beads that fill one thickness. All lengths are in micrometers.
pub const Beading = struct {
    total_thickness: i64 = 0,
    /// The width of each bead, from the outer side to the other side.
    bead_widths: []i64 = &.{},
    /// The distance of the center of each bead from the outline.
    toolpath_locations: []i64 = &.{},
    /// The thickness that no bead covers (a gap).
    left_over: i64 = 0,

    pub fn clone(b: Beading, a: Allocator) Allocator.Error!Beading {
        return .{
            .total_thickness = b.total_thickness,
            .bead_widths = try a.dupe(i64, b.bead_widths),
            .toolpath_locations = try a.dupe(i64, b.toolpath_locations),
            .left_over = b.left_over,
        };
    }
};

/// The inputs of `Strategy.init` (the arguments of CuraEngine
/// `makeStrategy`). Lengths in micrometers.
pub const Params = struct {
    preferred_bead_width_outer: i64 = 500,
    preferred_bead_width_inner: i64 = 500,
    preferred_transition_length: i64 = 400,
    transitioning_angle: f64 = std.math.pi / 4.0,
    print_thin_walls: bool = false,
    min_bead_width: i64 = 0,
    min_feature_size: i64 = 0,
    wall_split_middle_threshold: f64 = 0.5,
    wall_add_middle_threshold: f64 = 0.5,
    max_bead_count: i64 = 0,
    outer_wall_offset: i64 = 0,
    inner_wall_offset: i64 = 0,
    inward_distributed_center_wall_count: i64 = 2,
    minimum_variable_line_ratio: f64 = 0.5,
};

const Kind = enum { distributed, redistribute, widening, outer_inset, inner_inset, limited };

/// One layer of the strategy. `parent` is the index of the layer below.
const Layer = struct {
    kind: Kind,
    // Distributed.
    one_over_distribution_radius_squared: f64 = 1,
    // Redistribute.
    optimal_width_outer: i64 = 0,
    minimum_variable_line_ratio: f64 = 0,
    // Widening.
    min_input_width: i64 = 0,
    min_output_width: i64 = 0,
    // Outer and inner inset.
    wall_offset: i64 = 0,
    // Limited.
    max_bead_count: i64 = 0,
};

/// A chain of strategy layers, as `makeStrategy` builds it. The top layer
/// is the last one. The base values (the optimal width, the thresholds,
/// the transition length and angle) are the same for all layers, as in
/// CuraEngine, where each layer copies them from its parent.
pub const Strategy = struct {
    layers: [6]Layer = undefined,
    n: usize = 0,
    optimal_width: i64,
    wall_split_middle_threshold: f64,
    wall_add_middle_threshold: f64,
    default_transition_length: i64,
    transitioning_angle: f64,

    pub fn init(p: Params) Strategy {
        var s: Strategy = .{
            .optimal_width = p.preferred_bead_width_inner,
            .wall_split_middle_threshold = p.wall_split_middle_threshold,
            .wall_add_middle_threshold = p.wall_add_middle_threshold,
            .default_transition_length = p.preferred_transition_length,
            .transitioning_angle = p.transitioning_angle,
        };
        const r = p.inward_distributed_center_wall_count;
        // CuraEngine computes this in single precision.
        const inv: f32 = if (r >= 2) 1.0 / @as(f32, @floatFromInt(r - 1)) * 1.0 / @as(f32, @floatFromInt(r - 1)) else 1.0;
        s.push(.{ .kind = .distributed, .one_over_distribution_radius_squared = inv });
        s.push(.{ .kind = .redistribute, .optimal_width_outer = p.preferred_bead_width_outer, .minimum_variable_line_ratio = p.minimum_variable_line_ratio });
        if (p.print_thin_walls) s.push(.{ .kind = .widening, .min_input_width = p.min_feature_size, .min_output_width = p.min_bead_width });
        if (p.outer_wall_offset > 0) s.push(.{ .kind = .outer_inset, .wall_offset = p.outer_wall_offset });
        if (p.inner_wall_offset != 0) s.push(.{ .kind = .inner_inset, .wall_offset = p.inner_wall_offset });
        // Limited goes last: it adds a 0-width marker wall that the other
        // strategies must not touch.
        s.push(.{ .kind = .limited, .max_bead_count = p.max_bead_count });
        return s;
    }

    fn push(s: *Strategy, l: Layer) void {
        s.layers[s.n] = l;
        s.n += 1;
    }

    fn top(s: *const Strategy) usize {
        return s.n - 1;
    }

    /// The beads that cover `thickness` with `bead_count` beads.
    pub fn compute(s: *const Strategy, a: Allocator, thickness: i64, bead_count: i64) Allocator.Error!Beading {
        return s.computeAt(a, s.top(), thickness, bead_count);
    }

    /// The thickness that `bead_count` beads fill at their optimal widths.
    pub fn getOptimalThickness(s: *const Strategy, bead_count: i64) i64 {
        return s.optimalThicknessAt(s.top(), bead_count);
    }

    /// The thickness at which the bead count goes from `lower_bead_count`
    /// to `lower_bead_count` + 1.
    pub fn getTransitionThickness(s: *const Strategy, lower_bead_count: i64) i64 {
        return s.transitionThicknessAt(s.top(), lower_bead_count);
    }

    /// The best bead count for `thickness`.
    pub fn getOptimalBeadCount(s: *const Strategy, thickness: i64) i64 {
        return s.optimalBeadCountAt(s.top(), thickness);
    }

    /// The length of a transition from `lower_bead_count` beads to one more.
    pub fn getTransitioningLength(s: *const Strategy, lower_bead_count: i64) i64 {
        // All layers pass this to the base implementation.
        if (lower_bead_count == 0) return 10;
        return s.default_transition_length;
    }

    /// The part of the transition length before the point where the bead
    /// count changes.
    pub fn getTransitionAnchorPos(s: *const Strategy, lower_bead_count: i64) f64 {
        return s.anchorPosAt(s.top(), lower_bead_count);
    }

    /// The thicknesses where the bead widths bend (for extra ribs), from
    /// low to high. At most 1 value in this chain.
    pub fn getNonlinearThicknesses(s: *const Strategy, lower_bead_count: i64, out: *[4]i64) []i64 {
        return s.nonlinearAt(s.top(), lower_bead_count, out, 0);
    }

    pub fn getOptimalWidth(s: *const Strategy) i64 {
        return s.optimal_width;
    }

    pub fn getTransitioningAngle(s: *const Strategy) f64 {
        return s.transitioning_angle;
    }

    pub fn getSplitMiddleThreshold(s: *const Strategy) f64 {
        return s.wall_split_middle_threshold;
    }

    fn computeAt(s: *const Strategy, a: Allocator, level: usize, thickness: i64, bead_count_in: i64) Allocator.Error!Beading {
        const l = s.layers[level];
        switch (l.kind) {
            .distributed => return s.distributedCompute(a, l, thickness, bead_count_in),
            .redistribute => {
                var ret: Beading = .{};
                // All cases in which no lines are made.
                if (bead_count_in == 0 or lessThanScaled(thickness, l.minimum_variable_line_ratio, l.optimal_width_outer)) {
                    ret.left_over = thickness;
                    ret.total_thickness = thickness;
                    return ret;
                }
                // The inner walls, if any.
                var widths: std.ArrayList(i64) = .empty;
                var locs: std.ArrayList(i64) = .empty;
                const inner_bead_count = bead_count_in - 2;
                const inner_thickness = thickness - 2 * l.optimal_width_outer;
                if (inner_bead_count > 0 and inner_thickness > 0) {
                    const inner = try s.computeAt(a, level - 1, inner_thickness, inner_bead_count);
                    try widths.appendSlice(a, inner.bead_widths);
                    for (inner.toolpath_locations) |loc| try locs.append(a, loc + l.optimal_width_outer);
                }
                // The outer walls around the inner walls (which can be none).
                const actual_outer_thickness = if (bead_count_in > 2) @min(@divTrunc(thickness, 2), l.optimal_width_outer) else @divTrunc(thickness, bead_count_in);
                try widths.insert(a, 0, actual_outer_thickness);
                try locs.insert(a, 0, @divTrunc(actual_outer_thickness, 2));
                if (bead_count_in > 1) {
                    try widths.append(a, actual_outer_thickness);
                    try locs.append(a, thickness - @divTrunc(actual_outer_thickness, 2));
                }
                ret.bead_widths = widths.items;
                ret.toolpath_locations = locs.items;
                ret.total_thickness = thickness;
                var sum: i64 = 0;
                for (widths.items) |w| sum += w;
                ret.left_over = thickness - sum;
                return ret;
            },
            .widening => {
                if (thickness < s.optimal_width) {
                    var ret: Beading = .{ .total_thickness = thickness };
                    if (thickness >= l.min_input_width) {
                        ret.bead_widths = try a.dupe(i64, &.{@max(thickness, l.min_output_width)});
                        ret.toolpath_locations = try a.dupe(i64, &.{@divTrunc(thickness, 2)});
                    } else {
                        ret.left_over = thickness;
                    }
                    return ret;
                }
                return s.computeAt(a, level - 1, thickness, bead_count_in);
            },
            .outer_inset, .inner_inset => {
                const ret = try s.computeAt(a, level - 1, thickness, bead_count_in);
                // The count of real walls: no 0-width marker walls.
                var count: usize = 0;
                for (ret.bead_widths) |w| {
                    if (w > 0) count += 1;
                }
                // No inset for a single wall.
                if (count < 2) return ret;
                if (l.kind == .outer_inset) {
                    // The outer wall never goes past the middle line.
                    ret.toolpath_locations[0] = @min(ret.toolpath_locations[0] + l.wall_offset, @divTrunc(thickness, 2));
                } else {
                    for (ret.toolpath_locations[1..]) |*loc| loc.* += l.wall_offset;
                }
                return ret;
            },
            .limited => return s.limitedCompute(a, level, l, thickness, bead_count_in),
        }
    }

    fn distributedCompute(s: *const Strategy, a: Allocator, l: Layer, thickness: i64, bead_count: i64) Allocator.Error!Beading {
        var ret: Beading = .{ .total_thickness = thickness };
        const ow = s.optimal_width;
        if (bead_count > 2) {
            const n: usize = @intCast(bead_count);
            const to_be_divided = thickness - bead_count * ow;
            const middle = @as(f64, @floatFromInt(bead_count - 1)) / 2;
            const weights = try a.alloc(f64, n);
            var total_weight: f64 = 0;
            for (weights, 0..) |*wt, idx| {
                const dev = @as(f64, @floatFromInt(idx)) - middle;
                wt.* = @max(0.0, 1.0 - l.one_over_distribution_radius_squared * dev * dev);
                total_weight += wt.*;
            }
            const widths = try a.alloc(i64, n);
            const locs = try a.alloc(i64, n);
            for (0..n) |idx| {
                const fraction = weights[idx] / total_weight;
                const split = trunc(@as(f64, @floatFromInt(to_be_divided)) * fraction);
                const width = ow + split;
                locs[idx] = if (idx == 0) @divTrunc(width, 2) else locs[idx - 1] + @divTrunc(widths[idx - 1] + width, 2);
                widths[idx] = width;
            }
            ret.bead_widths = widths;
            ret.toolpath_locations = locs;
            ret.left_over = 0;
        } else if (bead_count == 2) {
            const outer_width = @divTrunc(thickness, 2);
            ret.bead_widths = try a.dupe(i64, &.{ outer_width, outer_width });
            ret.toolpath_locations = try a.dupe(i64, &.{ @divTrunc(outer_width, 2), thickness - @divTrunc(outer_width, 2) });
            ret.left_over = 0;
        } else if (bead_count == 1) {
            ret.bead_widths = try a.dupe(i64, &.{thickness});
            ret.toolpath_locations = try a.dupe(i64, &.{@divTrunc(thickness, 2)});
            ret.left_over = 0;
        } else {
            ret.left_over = thickness;
        }
        return ret;
    }

    fn limitedCompute(s: *const Strategy, a: Allocator, level: usize, l: Layer, thickness: i64, bead_count_in: i64) Allocator.Error!Beading {
        const max = l.max_bead_count;
        const half: usize = @intCast(@divTrunc(max, 2));
        if (bead_count_in <= max) {
            var ret = try s.computeAt(a, level - 1, thickness, bead_count_in);
            const bead_count: i64 = @intCast(ret.toolpath_locations.len);
            if (@mod(bead_count, 2) == 0 and bead_count == max) {
                const loc = ret.toolpath_locations[half - 1];
                const w = ret.bead_widths[half - 1];
                ret.toolpath_locations = try insertAt(a, ret.toolpath_locations, half, loc + @divTrunc(w, 2));
                ret.bead_widths = try insertAt(a, ret.bead_widths, half, 0);
            }
            return ret;
        }
        // Here bead_count_in is max + 1.
        const optimal_thickness = s.optimalThicknessAt(level - 1, max);
        var ret = try s.computeAt(a, level - 1, optimal_thickness, max);
        const bead_count: usize = ret.toolpath_locations.len;
        ret.left_over += thickness - ret.total_thickness;
        ret.total_thickness = thickness;

        // Make the beads symmetric.
        if (bead_count % 2 == 1) {
            ret.toolpath_locations[bead_count / 2] = @divTrunc(thickness, 2);
            ret.bead_widths[bead_count / 2] = thickness - optimal_thickness;
        }
        for (0..(bead_count + 1) / 2) |idx| {
            ret.toolpath_locations[bead_count - 1 - idx] = thickness - ret.toolpath_locations[idx];
        }

        // A "fake" inner wall of width 0 marks the edge of the walled area.
        // The skin and the infill fill the area next to it.
        var loc = ret.toolpath_locations[half - 1];
        var w = ret.bead_widths[half - 1];
        ret.toolpath_locations = try insertAt(a, ret.toolpath_locations, half, loc + @divTrunc(w, 2));
        ret.bead_widths = try insertAt(a, ret.bead_widths, half, 0);

        // The same on the other side.
        const opposite: usize = bead_count - (half - 1);
        loc = ret.toolpath_locations[opposite];
        w = ret.bead_widths[opposite];
        ret.toolpath_locations = try insertAt(a, ret.toolpath_locations, opposite, loc - @divTrunc(w, 2));
        ret.bead_widths = try insertAt(a, ret.bead_widths, opposite, 0);
        return ret;
    }

    fn optimalThicknessAt(s: *const Strategy, level: usize, bead_count: i64) i64 {
        const l = s.layers[level];
        return switch (l.kind) {
            .distributed => s.optimal_width * bead_count,
            .redistribute => blk: {
                const inner_bead_count = @max(0, bead_count - 2);
                const outer_bead_count = bead_count - inner_bead_count;
                break :blk s.optimalThicknessAt(level - 1, inner_bead_count) + l.optimal_width_outer * outer_bead_count;
            },
            .widening, .outer_inset, .inner_inset => s.optimalThicknessAt(level - 1, bead_count),
            .limited => if (bead_count <= l.max_bead_count) s.optimalThicknessAt(level - 1, bead_count) else 10000000, // 10 m
        };
    }

    fn transitionThicknessAt(s: *const Strategy, level: usize, lower_bead_count: i64) i64 {
        const l = s.layers[level];
        return switch (l.kind) {
            .distributed => blk: {
                // The base implementation.
                const lower = s.optimalThicknessAt(level, lower_bead_count);
                const higher = s.optimalThicknessAt(level, lower_bead_count + 1);
                const threshold = if (@mod(lower_bead_count, 2) == 1) s.wall_split_middle_threshold else s.wall_add_middle_threshold;
                break :blk trunc(@as(f64, @floatFromInt(lower)) + threshold * @as(f64, @floatFromInt(higher - lower)));
            },
            .redistribute => switch (lower_bead_count) {
                0 => trunc(l.minimum_variable_line_ratio * @as(f64, @floatFromInt(l.optimal_width_outer))),
                1 => trunc((1.0 + s.wall_split_middle_threshold) * @as(f64, @floatFromInt(l.optimal_width_outer))),
                else => s.transitionThicknessAt(level - 1, lower_bead_count - 2) + 2 * l.optimal_width_outer,
            },
            .widening => if (lower_bead_count == 0) l.min_input_width else s.transitionThicknessAt(level - 1, lower_bead_count),
            .outer_inset, .inner_inset => s.transitionThicknessAt(level - 1, lower_bead_count),
            .limited => if (lower_bead_count < l.max_bead_count)
                s.transitionThicknessAt(level - 1, lower_bead_count)
            else if (lower_bead_count == l.max_bead_count)
                s.optimalThicknessAt(level - 1, lower_bead_count + 1) - 10
            else
                9000000, // 9 m
        };
    }

    fn optimalBeadCountAt(s: *const Strategy, level: usize, thickness: i64) i64 {
        const l = s.layers[level];
        const ow = s.optimal_width;
        return switch (l.kind) {
            .distributed => blk: {
                // How many lines fit for sure, and the space left.
                const naive_count = @divTrunc(thickness, ow);
                const remainder = thickness - naive_count * ow;
                const threshold = if (@mod(naive_count, 2) == 1) s.wall_split_middle_threshold else s.wall_add_middle_threshold;
                const minimum_line_width = trunc(@as(f64, @floatFromInt(ow)) * threshold);
                break :blk naive_count + @intFromBool(remainder >= minimum_line_width);
            },
            .redistribute => blk: {
                const outer: f64 = @floatFromInt(l.optimal_width_outer);
                if (lessThanScaled(thickness, l.minimum_variable_line_ratio, l.optimal_width_outer)) break :blk 0;
                if (thickness <= 2 * l.optimal_width_outer) {
                    break :blk if (@as(f64, @floatFromInt(thickness)) > (1.0 + s.wall_split_middle_threshold) * outer) 2 else 1;
                }
                break :blk s.optimalBeadCountAt(level - 1, thickness - 2 * l.optimal_width_outer) + 2;
            },
            .widening => blk: {
                if (thickness < l.min_input_width) break :blk 0;
                const ret = s.optimalBeadCountAt(level - 1, thickness);
                if (ret < 1) break :blk 1;
                break :blk ret;
            },
            .outer_inset, .inner_inset => s.optimalBeadCountAt(level - 1, thickness),
            .limited => blk: {
                const parent_count = s.optimalBeadCountAt(level - 1, thickness);
                if (parent_count <= l.max_bead_count) break :blk parent_count;
                if (parent_count == l.max_bead_count + 1) {
                    break :blk if (thickness < s.optimalThicknessAt(level - 1, l.max_bead_count + 1) - 10) l.max_bead_count else l.max_bead_count + 1;
                }
                break :blk l.max_bead_count + 1;
            },
        };
    }

    fn anchorPosAt(s: *const Strategy, level: usize, lower_bead_count: i64) f64 {
        const l = s.layers[level];
        // The redistribute, widening, and limited layers pass this to
        // their parent. The inset layers and the distributed layer use the
        // base implementation, with their own thickness functions.
        switch (l.kind) {
            .redistribute, .widening, .limited => return s.anchorPosAt(level - 1, lower_bead_count),
            .distributed, .outer_inset, .inner_inset => {
                const lower_optimum = s.optimalThicknessAt(level, lower_bead_count);
                const transition_point = s.transitionThicknessAt(level, lower_bead_count);
                const upper_optimum = s.optimalThicknessAt(level, lower_bead_count + 1);
                return 1.0 - @as(f64, @floatFromInt(transition_point - lower_optimum)) / @as(f64, @floatFromInt(upper_optimum - lower_optimum));
            },
        }
    }

    fn nonlinearAt(s: *const Strategy, level: usize, lower_bead_count: i64, out: *[4]i64, n: usize) []i64 {
        const l = s.layers[level];
        switch (l.kind) {
            // The redistribute and inset layers do not pass this on in
            // CuraEngine: they use the base implementation (no values).
            .distributed, .redistribute, .outer_inset, .inner_inset => return out[0..n],
            .widening => {
                out[n] = l.min_output_width;
                return s.nonlinearAt(level - 1, lower_bead_count, out, n + 1);
            },
            // LimitedBeadingStrategy does not override it either.
            .limited => return out[0..n],
        }
    }
};

/// C++ conversion of a double to an integer: truncation toward zero.
pub fn trunc(x: f64) i64 {
    return @intFromFloat(x);
}

/// `thickness < ratio * width`, compared as C++ does it (in double).
fn lessThanScaled(thickness: i64, ratio: f64, width: i64) bool {
    return @as(f64, @floatFromInt(thickness)) < ratio * @as(f64, @floatFromInt(width));
}

fn insertAt(a: Allocator, items: []i64, at: usize, v: i64) Allocator.Error![]i64 {
    const out = try a.alloc(i64, items.len + 1);
    @memcpy(out[0..at], items[0..at]);
    out[at] = v;
    @memcpy(out[at + 1 ..], items[at..]);
    return out;
}

/// The parameters of CuraEngine `WallToolPaths::generateArachne` for the
/// settings of a layer. Lengths in micrometers, the angle in degrees.
pub const WallSettings = struct {
    bead_width_0: i64,
    bead_width_x: i64,
    inset_count: usize,
    wall_0_inset: i64 = 0,
    wall_x_inset: i64 = 0,
    print_thin_walls: bool = true,
    min_feature_size: i64,
    min_bead_width: i64,
    wall_transition_angle_deg: f64 = 10,
    wall_transition_length: i64,
    min_even_wall_line_width: i64,
    min_odd_wall_line_width: i64,
    wall_distribution_count: i64 = 1,
};

/// The strategy of `generateArachne` for the wall settings.
pub fn forWalls(ws: WallSettings) Strategy {
    const w0: f64 = @floatFromInt(ws.bead_width_0);
    const wx: f64 = @floatFromInt(ws.bead_width_x);
    const even: f64 = @floatFromInt(ws.min_even_wall_line_width);
    const odd: f64 = @floatFromInt(ws.min_odd_wall_line_width);
    // When to split the middle wall into two.
    const split = @max(1.0, @min(99.0, 100.0 * (2.0 * even - w0) / w0)) / 100.0;
    // When to add a new middle wall between the innermost two walls.
    const add = @max(1.0, @min(99.0, 100.0 * odd / wx)) / 100.0;
    return Strategy.init(.{
        .preferred_bead_width_outer = ws.bead_width_0,
        .preferred_bead_width_inner = ws.bead_width_x,
        .preferred_transition_length = ws.wall_transition_length,
        .transitioning_angle = ws.wall_transition_angle_deg * std.math.pi / 180.0,
        .print_thin_walls = ws.print_thin_walls,
        .min_bead_width = ws.min_bead_width,
        .min_feature_size = ws.min_feature_size,
        .wall_split_middle_threshold = split,
        .wall_add_middle_threshold = add,
        .max_bead_count = @intCast(2 * ws.inset_count),
        .outer_wall_offset = ws.wall_0_inset,
        .inner_wall_offset = ws.wall_x_inset,
        .inward_distributed_center_wall_count = ws.wall_distribution_count,
    });
}

const testing = std.testing;

fn testSettings(walls: usize) WallSettings {
    return .{
        .bead_width_0 = 400,
        .bead_width_x = 400,
        .inset_count = walls,
        .min_feature_size = 100,
        .min_bead_width = 340,
        .wall_transition_length = 400,
        .min_even_wall_line_width = 340,
        .min_odd_wall_line_width = 340,
    };
}

test "bead counts for known thicknesses" {
    const s = forWalls(testSettings(3));
    // Thinner than the minimum feature size: no bead.
    try testing.expectEqual(@as(i64, 0), s.getOptimalBeadCount(50));
    // A thin fin: one bead.
    try testing.expectEqual(@as(i64, 1), s.getOptimalBeadCount(300));
    try testing.expectEqual(@as(i64, 1), s.getOptimalBeadCount(600));
    // Two beads from (1 + split) x 0.4 mm: split = 2 x 0.34 / 0.4 - 1 = 0.7.
    try testing.expectEqual(@as(i64, 1), s.getOptimalBeadCount(680));
    try testing.expectEqual(@as(i64, 2), s.getOptimalBeadCount(681));
    try testing.expectEqual(@as(i64, 2), s.getOptimalBeadCount(800));
    // A third bead when the rest is at least 0.85 x 0.4 mm.
    try testing.expectEqual(@as(i64, 2), s.getOptimalBeadCount(1139));
    try testing.expectEqual(@as(i64, 3), s.getOptimalBeadCount(1140));
    try testing.expectEqual(@as(i64, 3), s.getOptimalBeadCount(1200));
    try testing.expectEqual(@as(i64, 6), s.getOptimalBeadCount(2400));
    // More than 6 beads: the limit (max + 1 marks the inner area).
    try testing.expectEqual(@as(i64, 7), s.getOptimalBeadCount(5000));
    try testing.expectEqual(@as(i64, 680), s.getTransitionThickness(1));
    try testing.expectEqual(@as(i64, 1140), s.getTransitionThickness(2));
}

test "bead widths for known thicknesses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = forWalls(testSettings(3));
    // 1.2 mm with 0.4 mm lines: 3 beads of 0.4 mm.
    const b3 = try s.compute(a, 1200, 3);
    try testing.expectEqualSlices(i64, &.{ 400, 400, 400 }, b3.bead_widths);
    try testing.expectEqualSlices(i64, &.{ 200, 600, 1000 }, b3.toolpath_locations);
    try testing.expectEqual(@as(i64, 0), b3.left_over);
    // 1.0 mm with 3 beads: the outer beads keep 0.4 mm, the middle one
    // gets the rest.
    const b3n = try s.compute(a, 1000, 3);
    try testing.expectEqualSlices(i64, &.{ 400, 200, 400 }, b3n.bead_widths);
    // 0.3 mm: one bead, widened to the minimum bead width.
    const b1 = try s.compute(a, 300, 1);
    try testing.expectEqualSlices(i64, &.{340}, b1.bead_widths);
    try testing.expectEqualSlices(i64, &.{150}, b1.toolpath_locations);
    // 0.7 mm with 2 beads: each bead is half.
    const b2 = try s.compute(a, 700, 2);
    try testing.expectEqualSlices(i64, &.{ 350, 350 }, b2.bead_widths);
    // 6 beads (the maximum for 3 walls): a 0-width marker in the middle.
    const b6 = try s.compute(a, 2400, 6);
    try testing.expectEqualSlices(i64, &.{ 400, 400, 400, 0, 400, 400, 400 }, b6.bead_widths);
    try testing.expectEqual(@as(i64, 1200), b6.toolpath_locations[3]);
    // Thicker: the walls at the sides, and markers at their inner edges.
    const b7 = try s.compute(a, 5000, 7);
    try testing.expectEqualSlices(i64, &.{ 400, 400, 400, 0, 0, 400, 400, 400 }, b7.bead_widths);
    try testing.expectEqualSlices(i64, &.{ 200, 600, 1000, 1200, 3800, 4000, 4400, 4800 }, b7.toolpath_locations);
    try testing.expectEqual(@as(i64, 5000), b7.total_thickness);
}

test "distributed strategy spreads the rest over the middle beads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ws = testSettings(5);
    ws.wall_distribution_count = 2;
    const s = forWalls(ws);
    // 5 beads in 2.1 mm: the 3 inner beads share 0.1 mm more, the middle
    // one most.
    const b = try s.compute(a, 2100, 5);
    try testing.expectEqual(@as(usize, 5), b.bead_widths.len);
    try testing.expectEqual(@as(i64, 400), b.bead_widths[0]);
    try testing.expectEqual(@as(i64, 400), b.bead_widths[4]);
    try testing.expect(b.bead_widths[2] > b.bead_widths[1]);
    var sum: i64 = 0;
    for (b.bead_widths) |w| sum += w;
    try testing.expect(@abs(sum - 2100) <= 2);
}
