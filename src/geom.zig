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

/// Removes points that are on a line between their neighbors, within
/// `tolerance` units, and points equal to the point before them. The polygon
/// is closed, so the first and last points are neighbors. The result is
/// written in place. Returns the new length.
///
/// The mesh slicer makes one point for each triangle that a plane cuts. A
/// fine mesh gives many points that change the shape by less than a
/// micrometer. This removes them before the polygon operations, which are
/// faster with fewer points.
pub fn simplifyClosed(poly: []Point, tolerance: i64) usize {
    var n = poly.len;
    if (n < 3) return n;
    const tol: i128 = tolerance;
    var changed = true;
    while (changed and n >= 3) {
        changed = false;
        var out: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const prev = if (out == 0) poly[n - 1] else poly[out - 1];
            const cur = poly[i];
            const next = poly[(i + 1) % n];
            if (cur.eql(prev)) {
                changed = true;
                continue;
            }
            // Distance from cur to the line prev-next is |cross| / |next - prev|.
            // Compare the squares to stay in integers.
            const c = cross3(prev, next, cur);
            const len2 = prev.distSq(next);
            if (len2 == 0 or c * c <= tol * tol * len2) {
                // A point that goes out and comes back (a spike) also has a
                // small cross product. Remove it only if it is between its
                // neighbors.
                if (len2 == 0 or (dot3(prev, next, cur) >= 0 and dot3(next, prev, cur) >= 0)) {
                    changed = true;
                    continue;
                }
            }
            poly[out] = cur;
            out += 1;
        }
        // The first point can be equal to the last point.
        if (out >= 2 and poly[0].eql(poly[out - 1])) {
            out -= 1;
            changed = true;
        }
        n = out;
    }
    return if (n < 3) 0 else n;
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
