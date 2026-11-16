//! Basic 2D geometry.
//!
//! All 2D work in the slicer uses integer coordinates. One unit is one
//! micrometer (0.001 mm). Integers give exact results for the tests that
//! decide topology: "is this point left of this line" and "do these two
//! segments cross". Floating point can give a different answer for the same
//! test at two places in the code, and the polygon operations then make
//! broken output. CuraEngine uses the same unit (see REFERENCES.md).
//!
//! Cross products of two vectors can be as large as (2^31)^2, so the code
//! does them in i128.
//!
//! References (see REFERENCES.md): the shoelace formula for the area, and
//! polyline simplification with an anchor point and a distance bound.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The number of coordinate units in one millimeter.
pub const units_per_mm: f64 = 1000.0;

pub fn fromMm(mm: f64) i64 {
    return @intFromFloat(@round(mm * units_per_mm));
}

pub fn toMm(units: i64) f64 {
    return @as(f64, @floatFromInt(units)) / units_per_mm;
}

pub const Point = struct {
    x: i64,
    y: i64,

    pub fn init(x: i64, y: i64) Point {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// Lexicographic order: first x, then y.
    pub fn lessThan(a: Point, b: Point) bool {
        return a.x < b.x or (a.x == b.x and a.y < b.y);
    }

    pub fn distSq(a: Point, b: Point) i128 {
        const dx: i128 = a.x - b.x;
        const dy: i128 = a.y - b.y;
        return dx * dx + dy * dy;
    }

    pub fn dist(a: Point, b: Point) f64 {
        return @sqrt(@as(f64, @floatFromInt(distSq(a, b))));
    }
};

/// The z component of (b - a) x (c - a). The value is positive when c is to
/// the left of the line from a to b, negative when c is to the right, and
/// zero when the three points are on one line.
pub fn cross3(a: Point, b: Point, c: Point) i128 {
    const abx: i128 = b.x - a.x;
    const aby: i128 = b.y - a.y;
    const acx: i128 = c.x - a.x;
    const acy: i128 = c.y - a.y;
    return abx * acy - aby * acx;
}

pub fn dot3(a: Point, b: Point, c: Point) i128 {
    const abx: i128 = b.x - a.x;
    const aby: i128 = b.y - a.y;
    const acx: i128 = c.x - a.x;
    const acy: i128 = c.y - a.y;
    return abx * acx + aby * acy;
}

/// Two times the signed area of a closed polygon (the shoelace formula).
/// The value is positive for a counterclockwise polygon.
pub fn area2(poly: []const Point) i128 {
    if (poly.len < 3) return 0;
    var sum: i128 = 0;
    var prev = poly[poly.len - 1];
    for (poly) |p| {
        sum += @as(i128, prev.x) * p.y - @as(i128, p.x) * prev.y;
        prev = p;
    }
    return sum;
}

/// The signed area in square millimeters.
pub fn areaMm2(poly: []const Point) f64 {
    const a: f64 = @floatFromInt(area2(poly));
    return a / 2.0 / (units_per_mm * units_per_mm);
}

pub const Box = struct {
    min: Point,
    max: Point,

    pub const empty: Box = .{
        .min = .{ .x = std.math.maxInt(i64), .y = std.math.maxInt(i64) },
        .max = .{ .x = std.math.minInt(i64), .y = std.math.minInt(i64) },
    };

    pub fn extend(b: *Box, p: Point) void {
        b.min.x = @min(b.min.x, p.x);
        b.min.y = @min(b.min.y, p.y);
        b.max.x = @max(b.max.x, p.x);
        b.max.y = @max(b.max.y, p.y);
    }

    pub fn isEmpty(b: Box) bool {
        return b.min.x > b.max.x;
    }
};

/// A set of paths in one flat array.
///
/// `points` has the points of all paths, one path after the other.
/// `ends[i]` is the index one past the last point of path i. One flat array
/// uses less memory than one allocation per path, and the CPU reads it in
/// order. A path is a closed polygon or an open polyline. The code that
/// makes the set decides which.
///
/// Closed polygons follow one convention: an outer boundary is
/// counterclockwise and a hole is clockwise. The area to the left of each
/// edge is then inside the shape.
pub const Paths = struct {
    points: std.ArrayList(Point) = .empty,
    ends: std.ArrayList(u32) = .empty,

    pub const empty: Paths = .{};

    pub fn deinit(self: *Paths, gpa: Allocator) void {
        self.points.deinit(gpa);
        self.ends.deinit(gpa);
        self.* = .empty;
    }

    pub fn count(self: Paths) usize {
        return self.ends.items.len;
    }

    pub fn isEmpty(self: Paths) bool {
        return self.ends.items.len == 0;
    }

    pub fn get(self: Paths, i: usize) []Point {
        const start: usize = if (i == 0) 0 else self.ends.items[i - 1];
        return self.points.items[start..self.ends.items[i]];
    }

    /// Adds one path. Paths with no points are ignored.
    pub fn append(self: *Paths, gpa: Allocator, pts: []const Point) Allocator.Error!void {
        if (pts.len == 0) return;
        try self.points.appendSlice(gpa, pts);
        try self.ends.append(gpa, @intCast(self.points.items.len));
    }

    /// Adds one point to the path that is open now. Call `endPath` to close it.
    pub fn appendPoint(self: *Paths, gpa: Allocator, p: Point) Allocator.Error!void {
        try self.points.append(gpa, p);
    }

    /// Ends the path started by the `appendPoint` calls since the last
    /// `endPath`. Removes the path if it has fewer than `min_points` points.
    pub fn endPath(self: *Paths, gpa: Allocator, min_points: usize) Allocator.Error!void {
        const start: usize = if (self.ends.items.len == 0) 0 else self.ends.items[self.ends.items.len - 1];
        if (self.points.items.len - start < min_points) {
            self.points.shrinkRetainingCapacity(start);
            return;
        }
        try self.ends.append(gpa, @intCast(self.points.items.len));
    }

    pub fn appendAll(self: *Paths, gpa: Allocator, other: Paths) Allocator.Error!void {
        for (0..other.count()) |i| try self.append(gpa, other.get(i));
    }

    pub fn clone(self: Paths, gpa: Allocator) Allocator.Error!Paths {
        var out: Paths = .empty;
        errdefer out.deinit(gpa);
        try out.points.appendSlice(gpa, self.points.items);
        try out.ends.appendSlice(gpa, self.ends.items);
        return out;
    }

    pub fn bounds(self: Paths) Box {
        var b: Box = .empty;
        for (self.points.items) |p| b.extend(p);
        return b;
    }

    /// The sum of the signed areas, in square millimeters. Holes subtract.
    pub fn areaMm2(self: Paths) f64 {
        var sum: f64 = 0;
        for (0..self.count()) |i| sum += geomAreaMm2(self.get(i));
        return sum;
    }
};

const geomAreaMm2 = areaMm2;

/// Removes points from a closed polygon while each removed point stays
/// within `tolerance` units of the new edge that replaces it. The result is
/// written in place. Returns the new length, or 0 if fewer than 3 points
/// are left. With `tolerance` 0, only exactly collinear points and equal
/// points are removed.
///
/// The mesh slicer makes one point for each triangle that a plane cuts. A
/// fine mesh gives many points that change the shape by less than a
/// micrometer. This removes them before the polygon operations, which are
/// faster with fewer points.
///
/// The method: keep an "anchor" point. Try to replace the points after it
/// with one edge from the anchor to a point further on. Extend the edge
/// while each point between is within the tolerance of it. When the next
/// point fails, keep the last point that passed, and make it the anchor.
/// Each removed point is tested against the final edge, so the error does
/// not add up. The walk starts at the lowest point in (x, y) order, which is
/// a real corner and is never removed. One edge replaces at most 256
/// points, so the cost is O(256 n) in the worst case.
pub fn simplifyClosed(poly: []Point, tolerance: i64) usize {
    var n = removeDuplicates(poly);
    if (n < 3) return 0;
    var first: usize = 0;
    for (poly[0..n], 0..) |p, i| {
        if (p.lessThan(poly[first])) first = i;
    }
    std.mem.rotate(Point, poly[0..n], first);

    const max_run = 256;
    var out: usize = 1;
    var anchor: usize = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        // Can poly[i] go? Test the edge from the anchor to the point after i.
        const end = if (i + 1 == n) poly[0] else poly[i + 1];
        var removable = i - anchor < max_run;
        if (removable) {
            for (poly[anchor + 1 .. i + 1]) |p| {
                if (!nearSegment(poly[anchor], end, p, tolerance)) {
                    removable = false;
                    break;
                }
            }
        }
        if (removable) continue;
        poly[out] = poly[i];
        out += 1;
        anchor = i;
    }
    n = out;
    return if (n < 3) 0 else n;
}

/// Removes points equal to the point before them (the first and last
/// points are neighbors). Returns the new length.
fn removeDuplicates(poly: []Point) usize {
    if (poly.len == 0) return 0;
    var out: usize = 1;
    for (poly[1..]) |p| {
        if (!p.eql(poly[out - 1])) {
            poly[out] = p;
            out += 1;
        }
    }
    while (out > 1 and poly[out - 1].eql(poly[0])) out -= 1;
    return out;
}

/// True if p is within `tolerance` units of the segment from a to b.
fn nearSegment(a: Point, b: Point, p: Point, tolerance: i64) bool {
    if (tolerance == 0) {
        return cross3(a, b, p) == 0 and dot3(a, b, p) >= 0 and dot3(b, a, p) >= 0;
    }
    // The distance is not a topology decision, so floating point is enough.
    const abx: f64 = @floatFromInt(b.x - a.x);
    const aby: f64 = @floatFromInt(b.y - a.y);
    const apx: f64 = @floatFromInt(p.x - a.x);
    const apy: f64 = @floatFromInt(p.y - a.y);
    const len2 = abx * abx + aby * aby;
    const t = if (len2 == 0) 0 else std.math.clamp((apx * abx + apy * aby) / len2, 0, 1);
    const dx = apx - t * abx;
    const dy = apy - t * aby;
    const tol: f64 = @floatFromInt(tolerance);
    return dx * dx + dy * dy <= tol * tol;
}

test "area of a counterclockwise square is positive" {
    const sq = [_]Point{ .init(0, 0), .init(1000, 0), .init(1000, 1000), .init(0, 1000) };
    try std.testing.expectEqual(@as(i128, 2_000_000), area2(&sq));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), areaMm2(&sq), 1e-9);
}

test "simplify removes collinear points" {
    var sq = [_]Point{ .init(0, 0), .init(500, 0), .init(1000, 0), .init(1000, 1000), .init(0, 1000), .init(0, 1000) };
    const n = simplifyClosed(&sq, 0);
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "simplify a fine circle: the error does not add up" {
    // A regression test from the code review: the old method tested each
    // point only against its neighbors, so a circle of 6283 points lost 13 %
    // of its area at a tolerance of 5 micrometers.
    const gpa = std.testing.allocator;
    const n = 6283;
    const r = 10_000.0;
    const pts = try gpa.alloc(Point, n);
    defer gpa.free(pts);
    for (pts, 0..) |*p, i| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / n;
        p.* = .{ .x = @intFromFloat(@round(r * @cos(a))), .y = @intFromFloat(@round(r * @sin(a))) };
    }
    const exact = areaMm2(pts);
    const orig = try gpa.dupe(Point, pts);
    defer gpa.free(orig);
    const m = simplifyClosed(pts, 5);
    try std.testing.expect(m > 20 and m < 1000);
    try std.testing.expectApproxEqRel(exact, areaMm2(pts[0..m]), 0.002);
    // Each original point is within the tolerance (plus rounding) of an edge.
    for (orig) |p| {
        var near = false;
        for (0..m) |k| {
            if (nearSegment(pts[k], pts[(k + 1) % m], p, 6)) {
                near = true;
                break;
            }
        }
        try std.testing.expect(near);
    }
}


/// True if p is inside a set of polygons: its winding number is not 0.
/// The ray goes from p to +x; each edge that crosses it adds 1 (upward)
/// or -1 (downward). Points on an edge can go either way.
pub fn insideAny(paths: Paths, p: Point) bool {
    var winding: i32 = 0;
    for (0..paths.count()) |k| {
        const poly = paths.get(k);
        for (poly, 0..) |a, i| {
            const b = poly[(i + 1) % poly.len];
            if (a.y <= p.y) {
                if (b.y > p.y and cross3(a, b, p) > 0) winding += 1;
            } else if (b.y <= p.y and cross3(a, b, p) < 0) winding -= 1;
        }
    }
    return winding != 0;
}

test "insideAny: a square with a hole" {
    var ps: Paths = .empty;
    defer ps.deinit(std.testing.allocator);
    try ps.append(std.testing.allocator, &.{ .init(0, 0), .init(10, 0), .init(10, 10), .init(0, 10) });
    try ps.append(std.testing.allocator, &.{ .init(3, 3), .init(3, 7), .init(7, 7), .init(7, 3) });
    try std.testing.expect(insideAny(ps, .init(1, 5)));
    try std.testing.expect(!insideAny(ps, .init(5, 5)));
    try std.testing.expect(!insideAny(ps, .init(20, 5)));
}
