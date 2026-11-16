//! Line infill: fill a region with parallel lines.
//!
//! The method is a scanline fill:
//!
//! 1. Turn the region by -angle, so that the lines become horizontal.
//! 2. Put the lines at y = k * spacing for each integer k. All layers use the
//!    same grid, so the lines of one layer are on top of the lines of the
//!    layer below. This makes infill columns that are strong.
//! 3. For each polygon edge, find the lines that it crosses. Record each
//!    crossing: the line k, the x, and the edge direction (up or down).
//! 4. Sort the crossings by line, then by x. Go along each line from left to
//!    right and add the directions (a winding number). Where the winding
//!    number is not zero, the line is inside the region. Each inside span is
//!    one infill line.
//! 5. Turn the lines back by +angle.
//!
//! An edge counts for a line at y if min_y <= y < max_y (half open). A
//! line that goes through a vertex then crosses exactly one of the two
//! edges at the vertex.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const Point = geom.Point;
const Paths = geom.Paths;

const Crossing = struct { k: i64, x: i64, dir: i8 };

/// Returns the infill lines, each as a path of two points. `spacing` is the
/// distance between lines, in units. Lines shorter than `min_length` are
/// removed. The caller owns the result.
pub fn lines(gpa: Allocator, region: Paths, spacing: i64, angle_deg: f64, min_length: i64) Allocator.Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    if (region.isEmpty() or spacing <= 0) return out;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = angle_deg * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);

    // Steps 1 and 3.
    var xs: std.ArrayList(Crossing) = .empty;
    for (0..region.count()) |pi| {
        const poly = region.get(pi);
        if (poly.len < 3) continue;
        var prev = rotate(poly[poly.len - 1], c, -s);
        for (poly) |p_raw| {
            const p = rotate(p_raw, c, -s);
            defer prev = p;
            if (p.y == prev.y) continue;
            const lo = if (prev.y < p.y) prev else p;
            const hi = if (prev.y < p.y) p else prev;
            const dir: i8 = if (prev.y < p.y) 1 else -1;
            // Lines with lo.y <= k * spacing < hi.y.
            var k = std.math.divCeil(i64, lo.y, spacing) catch unreachable;
            while (k * spacing < hi.y) : (k += 1) {
                const y = k * spacing;
                const t = @as(f64, @floatFromInt(y - lo.y)) / @as(f64, @floatFromInt(hi.y - lo.y));
                const x = @as(f64, @floatFromInt(lo.x)) + t * @as(f64, @floatFromInt(hi.x - lo.x));
                try xs.append(arena, .{ .k = k, .x = @intFromFloat(@round(x)), .dir = dir });
            }
        }
    }

    // Step 4.
    std.mem.sortUnstable(Crossing, xs.items, {}, struct {
        fn lt(_: void, l: Crossing, r: Crossing) bool {
            if (l.k != r.k) return l.k < r.k;
            return l.x < r.x;
        }
    }.lt);
    var i: usize = 0;
    while (i < xs.items.len) {
        const k = xs.items[i].k;
        var wind: i32 = 0;
        var start_x: i64 = 0;
        while (i < xs.items.len and xs.items[i].k == k) : (i += 1) {
            const was_inside = wind != 0;
            wind += xs.items[i].dir;
            const is_inside = wind != 0;
            if (!was_inside and is_inside) start_x = xs.items[i].x;
            if (was_inside and !is_inside) {
                const end_x = xs.items[i].x;
                if (end_x - start_x >= min_length) {
                    // Step 5.
                    const y = k * spacing;
                    try out.append(gpa, &.{
                        rotate(.{ .x = start_x, .y = y }, c, s),
                        rotate(.{ .x = end_x, .y = y }, c, s),
                    });
                }
            }
        }
    }
    return out;
}

/// Turns p around the origin by the angle with cosine c and sine s.
fn rotate(p: Point, c: f64, s: f64) Point {
    const x: f64 = @floatFromInt(p.x);
    const y: f64 = @floatFromInt(p.y);
    return .{
        .x = @intFromFloat(@round(x * c - y * s)),
        .y = @intFromFloat(@round(x * s + y * c)),
    };
}

const testing = std.testing;

test "horizontal lines in a square" {
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var l = try lines(gpa, sq, 1000, 0, 0);
    defer l.deinit(gpa);
    // y = 0, 1000, ..., 9000. y = 10000 is outside the half-open range.
    try testing.expectEqual(@as(usize, 10), l.count());
    for (0..l.count()) |i| {
        const seg = l.get(i);
        try testing.expectEqual(@as(u64, 10_000), @abs(seg[1].x - seg[0].x));
    }
}

test "lines skip a hole" {
    const gpa = testing.allocator;
    var p: Paths = .empty;
    defer p.deinit(gpa);
    try p.append(gpa, &.{ .init(0, 0), .init(30_000, 0), .init(30_000, 30_000), .init(0, 30_000) });
    try p.append(gpa, &.{ .init(10_000, 10_000), .init(10_000, 20_000), .init(20_000, 20_000), .init(20_000, 10_000) });
    var l = try lines(gpa, p, 5000, 0, 0);
    defer l.deinit(gpa);
    // y = 0, 5000, 25000: one line each. y = 10000, 15000: two lines each.
    // y = 20000 is at the top edge of the hole, which is half open, so the
    // line goes through: one line.
    try testing.expectEqual(@as(usize, 8), l.count());
}

test "diagonal lines cover the square" {
    const gpa = testing.allocator;
    var sq: Paths = .empty;
    defer sq.deinit(gpa);
    try sq.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    var l = try lines(gpa, sq, 500, 45, 0);
    defer l.deinit(gpa);
    // The total line length times the spacing is close to the area.
    var total: f64 = 0;
    for (0..l.count()) |i| total += l.get(i)[0].dist(l.get(i)[1]);
    try testing.expectApproxEqRel(@as(f64, 100.0), total * 500 / 1e6, 0.05);
}
