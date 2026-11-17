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
//! does them in i128. Wasm has no instruction for a 64 x 64 -> 128 bit
//! product: each one is a call of a library function. So in wasm the
//! products first test if all factors are small (see `mulSub`), and then
//! use 64-bit products. Both forms give the same value.
//!
//! References (see REFERENCES.md): the shoelace formula for the area, and
//! polyline simplification with an anchor point and a distance bound.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The number of coordinate units in one millimeter.
pub const units_per_mm: f64 = 1000.0;

pub fn fromMm(mm: f64) i64 {
    return @intFromFloat(round(mm * units_per_mm));
}

/// The smaller of two floats that are not NaN. `@min`, `@max`, and `@round`
/// of floats are calls of library functions in wasm: wasm has other rules
/// for NaN and for a half than C. These three are a few wasm instructions,
/// and one instruction on x86-64. Use them in hot loops.
pub inline fn fmin(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a < b) a else b;
}

/// The larger of two floats that are not NaN (see `fmin`).
pub inline fn fmax(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a < b) b else a;
}

/// x rounded to the nearest whole number, a half away from zero: the
/// value of `@round` (see `fmin`).
pub inline fn round(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (T == comptime_float) return @round(x);
    const t = @trunc(x);
    // x - t is exact.
    return if (@abs(x - t) >= 0.5) t + std.math.copysign(@as(T, 1), x) else t;
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
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        return mulAdd(dx, dx, dy, dy);
    }

    pub fn dist(a: Point, b: Point) f64 {
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        // A 64-bit sum of squares is exact, so its float is the same as
        // the float of the 128-bit sum (which is a library call in wasm).
        if (slow_wide and small4(dx, dy, 0, 0)) return @sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
        return @sqrt(@as(f64, @floatFromInt(distSq(a, b))));
    }
};

/// The length of the vector (x, y). `std.math.hypot` gives the correctly
/// rounded result, and guards against overflow, with fused multiply-adds.
/// Wasm has no fused multiply-add, so there it is a slow function call
/// (about 9 % of the time of a slice after an infill change). The lengths
/// of a slice are far from the limits of a float, so the plain form is
/// safe.
pub inline fn hypot(x: anytype, y: anytype) @TypeOf(x, y) {
    return @sqrt(x * x + y * y);
}

/// The z component of (b - a) x (c - a). The value is positive when c is to
/// the left of the line from a to b, negative when c is to the right, and
/// zero when the three points are on one line.
pub fn cross3(a: Point, b: Point, c: Point) i128 {
    return mulSub(b.x - a.x, c.y - a.y, b.y - a.y, c.x - a.x);
}

pub fn dot3(a: Point, b: Point, c: Point) i128 {
    return mulAdd(b.x - a.x, c.x - a.x, b.y - a.y, c.y - a.y);
}

/// True if a 128-bit product is slow on the target (see the file header).
const slow_wide = @import("builtin").cpu.arch.isWasm();

/// a * b - c * d, exact.
pub inline fn mulSub(a: i64, b: i64, c: i64, d: i64) i128 {
    return mulSubFor(slow_wide, a, b, c, d);
}

/// a * b + c * d, exact.
pub inline fn mulAdd(a: i64, b: i64, c: i64, d: i64) i128 {
    return mulAddFor(slow_wide, a, b, c, d);
}

/// `mulSub`. With `narrow_first`, it uses 64-bit products if the factors
/// are small.
pub inline fn mulSubFor(comptime narrow_first: bool, a: i64, b: i64, c: i64, d: i64) i128 {
    if (narrow_first and small4(a, b, c, d)) return a * b - c * d;
    return @as(i128, a) * b - @as(i128, c) * d;
}

pub inline fn mulAddFor(comptime narrow_first: bool, a: i64, b: i64, c: i64, d: i64) i128 {
    if (narrow_first and small4(a, b, c, d)) return a * b + c * d;
    return @as(i128, a) * b + @as(i128, c) * d;
}

/// True if each value is in -2^30 .. 2^30 - 1 (about 1 km). Then a product
/// of two values is at most 2^60, and a sum of two products fits in an i64.
inline fn small4(a: i64, b: i64, c: i64, d: i64) bool {
    const bias: i64 = 1 << 30;
    const bits = @as(u64, @bitCast(a +% bias)) | @as(u64, @bitCast(b +% bias)) |
        @as(u64, @bitCast(c +% bias)) | @as(u64, @bitCast(d +% bias));
    return bits >> 31 == 0;
}

/// Two times the signed area of a closed polygon (the shoelace formula).
/// The value is positive for a counterclockwise polygon.
pub fn area2(poly: []const Point) i128 {
    if (poly.len < 3) return 0;
    var sum: i128 = 0;
    var prev = poly[poly.len - 1];
    for (poly) |p| {
        sum += mulSub(prev.x, p.y, p.x, prev.y);
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

/// True if the segment a-b crosses no edge of the polygons (a touch at an
/// end does not count) and its middle point is inside them: the segment
/// stays inside.
pub fn segmentInside(paths: Paths, a: Point, b: Point) bool {
    for (0..paths.count()) |k| {
        const poly = paths.get(k);
        for (poly, 0..) |c, i| {
            const d = poly[(i + 1) % poly.len];
            const s1 = std.math.sign(cross3(a, b, c));
            const s2 = std.math.sign(cross3(a, b, d));
            if (s1 * s2 >= 0) continue;
            const s3 = std.math.sign(cross3(c, d, a));
            const s4 = std.math.sign(cross3(c, d, b));
            if (s3 * s4 < 0) return false;
        }
    }
    return insideAny(paths, .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2) });
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

/// The edges of a set of polygons in bands of y, for fast tests of a point:
/// is it inside (`inside`, the same result as `insideAny`), and is it near
/// an edge (`near`). A horizontal ray from the point crosses only edges
/// whose y range holds the y of the point, and an edge within `pad` of the
/// point has a y range within `pad` of it. Each edge goes in each band
/// that its y range, grown by `pad`, touches. So a test looks only at the
/// edges in the band of the point.
pub const EdgeIndex = struct {
    min: i64,
    /// The width of a band is 1 << shift: the band of a y is a shift, with
    /// no division.
    shift: u6,
    /// Band k has the edges from starts[k] to starts[k + 1].
    starts: []u32,
    edges: [][2]Point,

    pub fn init(s: Allocator, paths: Paths, pad: i64) Allocator.Error!EdgeIndex {
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        for (paths.points.items) |q| {
            lo = @min(lo, q.y - pad);
            hi = @max(hi, q.y + pad);
        }
        const n = paths.points.items.len;
        const want: usize = std.math.clamp(2 * std.math.sqrt(n), 1, 4096);
        const span: u64 = @intCast(@max(hi - lo + 1, 1));
        // The smallest power of two width that gives at most `want` bands.
        var shift: u6 = 0;
        while ((span - 1) >> shift >= want) shift += 1;
        const bands: usize = @intCast(((span - 1) >> shift) + 1);
        var idx: EdgeIndex = .{ .min = lo, .shift = shift, .starts = try s.alloc(u32, bands + 1), .edges = &.{} };
        @memset(idx.starts, 0);
        // Two passes over the edges: count, then fill.
        var fill: []u32 = &.{};
        defer s.free(fill);
        for (0..2) |pass| {
            if (pass == 1) {
                for (1..idx.starts.len) |k| idx.starts[k] += idx.starts[k - 1];
                idx.edges = try s.alloc([2]Point, idx.starts[bands]);
                fill = try s.dupe(u32, idx.starts[0..bands]);
            }
            for (0..paths.count()) |k| {
                const poly = paths.get(k);
                if (poly.len == 0) continue;
                // Each edge a -> b: a is the point before b.
                var a = poly[poly.len - 1];
                for (poly) |b| {
                    defer a = b;
                    // A horizontal edge never counts for `inside`.
                    if (a.y == b.y and pad == 0) continue;
                    const b0 = idx.band(@min(a.y, b.y) - pad);
                    // `inside` needs the half-open range [min y, max y),
                    // and `near` the closed range grown by the pad.
                    const b1 = idx.band(if (pad > 0) @max(a.y, b.y) + pad else @max(a.y, b.y) - 1);
                    for (b0..b1 + 1) |bi| {
                        if (pass == 0) {
                            idx.starts[bi + 1] += 1;
                        } else {
                            idx.edges[fill[bi]] = .{ a, b };
                            fill[bi] += 1;
                        }
                    }
                }
            }
        }
        return idx;
    }

    pub fn deinit(idx: *EdgeIndex, s: Allocator) void {
        s.free(idx.starts);
        s.free(idx.edges);
    }

    inline fn band(idx: *const EdgeIndex, y: i64) usize {
        const k = (y - idx.min) >> idx.shift;
        return @intCast(std.math.clamp(k, 0, @as(i64, @intCast(idx.starts.len - 2))));
    }

    fn bandEdges(idx: EdgeIndex, y: i64) []const [2]Point {
        const k = idx.band(y);
        return idx.edges[idx.starts[k]..idx.starts[k + 1]];
    }

    /// The same as `insideAny`.
    pub fn inside(idx: EdgeIndex, p: Point) bool {
        var winding: i32 = 0;
        for (idx.bandEdges(p.y)) |e| {
            const a = e[0];
            const b = e[1];
            if (a.y <= p.y) {
                if (b.y > p.y and cross3(a, b, p) > 0) winding += 1;
            } else if (b.y <= p.y and cross3(a, b, p) < 0) winding -= 1;
        }
        return winding != 0;
    }

    /// True if p is at most `tol` from an edge. `tol` must not be more than
    /// the pad of the index, and the pad must be more than 0.
    pub fn near(idx: EdgeIndex, p: Point, tol: i64) bool {
        const t2: f64 = @floatFromInt(tol * tol);
        for (idx.bandEdges(p.y)) |e| {
            const a = e[0];
            const b = e[1];
            const abx: f64 = @floatFromInt(b.x - a.x);
            const aby: f64 = @floatFromInt(b.y - a.y);
            const apx: f64 = @floatFromInt(p.x - a.x);
            const apy: f64 = @floatFromInt(p.y - a.y);
            const len2 = abx * abx + aby * aby;
            const t = if (len2 > 0) fmax(0, fmin((apx * abx + apy * aby) / len2, 1)) else 0;
            const dx = apx - t * abx;
            const dy = apy - t * aby;
            if (dx * dx + dy * dy <= t2) return true;
        }
        return false;
    }

    /// The distance (units) from p to the nearest edge, or `limit` if no
    /// edge is nearer. `limit` must not be more than the pad of the index,
    /// and the pad must be more than 0.
    pub fn distance(idx: EdgeIndex, p: Point, limit: i64) f64 {
        var best: f64 = @floatFromInt(limit);
        var best2 = best * best;
        for (idx.bandEdges(p.y)) |e| {
            const a = e[0];
            const b = e[1];
            const abx: f64 = @floatFromInt(b.x - a.x);
            const aby: f64 = @floatFromInt(b.y - a.y);
            const apx: f64 = @floatFromInt(p.x - a.x);
            const apy: f64 = @floatFromInt(p.y - a.y);
            const len2 = abx * abx + aby * aby;
            const t = if (len2 > 0) fmax(0, fmin((apx * abx + apy * aby) / len2, 1)) else 0;
            const dx = apx - t * abx;
            const dy = apy - t * aby;
            const d2 = dx * dx + dy * dy;
            if (d2 < best2) best2 = d2;
        }
        if (best2 < best * best) best = @sqrt(best2);
        return best;
    }
};

test "EdgeIndex gives the same answers as the tests over all edges" {
    const gpa = std.testing.allocator;
    var ps: Paths = .empty;
    defer ps.deinit(gpa);
    try ps.append(gpa, &.{ .init(0, 0), .init(10_000, 0), .init(10_000, 10_000), .init(0, 10_000) });
    try ps.append(gpa, &.{ .init(3000, 3000), .init(3000, 7000), .init(7000, 7000), .init(7000, 3000) });
    try ps.append(gpa, &.{ .init(12_000, 500), .init(15_000, 9000), .init(11_000, 4000) });
    var idx: EdgeIndex = try .init(gpa, ps, 50);
    defer idx.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    for (0..2000) |_| {
        const p: Point = .init(rnd.intRangeAtMost(i64, -500, 16_000), rnd.intRangeAtMost(i64, -500, 10_500));
        try std.testing.expectEqual(insideAny(ps, p), idx.inside(p));
    }
    // Points on the edges and near them.
    for ([_]Point{ .init(0, 5000), .init(-30, 5000), .init(5000, 10_049), .init(3000, 2960), .init(10_000, 0) }) |p| {
        try std.testing.expectEqual(insideAny(ps, p), idx.inside(p));
        try std.testing.expect(idx.near(p, 50));
    }
    try std.testing.expect(!idx.near(.init(5000, 5000), 50));
    try std.testing.expectApproxEqAbs(@as(f64, 30), idx.distance(.init(-30, 5000), 50), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), idx.distance(.init(5000, 5000), 50), 1e-9);
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

test "the 64-bit products give the values of the 128-bit products" {
    var prng = std.Random.DefaultPrng.init(31);
    const rnd = prng.random();
    const lim: i64 = 1 << 30;
    for (0..100_000) |k| {
        // Values at the limits, small values, and values past the limits.
        var v: [4]i64 = undefined;
        for (&v) |*x| x.* = switch (k % 4) {
            0 => rnd.intRangeAtMost(i64, -lim, lim - 1),
            1 => if (rnd.boolean()) -lim else lim - 1,
            2 => rnd.intRangeAtMost(i64, -50, 50),
            else => rnd.intRangeAtMost(i64, -(lim << 20), lim << 20),
        };
        try std.testing.expectEqual(mulSubFor(false, v[0], v[1], v[2], v[3]), mulSubFor(true, v[0], v[1], v[2], v[3]));
        try std.testing.expectEqual(mulAddFor(false, v[0], v[1], v[2], v[3]), mulAddFor(true, v[0], v[1], v[2], v[3]));
    }
    try std.testing.expect(small4(-lim, lim - 1, 0, -1));
    try std.testing.expect(!small4(lim, 0, 0, 0));
    try std.testing.expect(!small4(0, 0, 0, -lim - 1));
    try std.testing.expect(!small4(std.math.minInt(i64), std.math.maxInt(i64), 0, 0));
}

test "round gives the value of @round" {
    var prng = std.Random.DefaultPrng.init(37);
    const rnd = prng.random();
    const cases = [_]f64{ 0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.49999999999999994, -0.49999999999999994, 4503599627370495.5, -4503599627370495.5, 4503599627370496, 9007199254740994, 1e300, -1e300, std.math.inf(f64), -std.math.inf(f64) };
    for (cases) |x| {
        try std.testing.expectEqual(@as(u64, @bitCast(@round(x))), @as(u64, @bitCast(round(x))));
    }
    for (0..200_000) |k| {
        const whole: f64 = @floatFromInt(rnd.intRangeAtMost(i64, -1 << 40, 1 << 40));
        const x = switch (k % 3) {
            0 => whole + 0.5,
            1 => whole + rnd.float(f64),
            else => (rnd.float(f64) - 0.5) * 4,
        };
        try std.testing.expectEqual(@as(u64, @bitCast(@round(x))), @as(u64, @bitCast(round(x))));
        const y: f32 = @floatCast(x / 1024);
        try std.testing.expectEqual(@as(u32, @bitCast(@round(y))), @as(u32, @bitCast(round(y))));
    }
    try std.testing.expectEqual(@as(f64, 2), fmin(2, 3.0));
    try std.testing.expectEqual(@as(f64, 3), fmax(2, 3.0));
}
