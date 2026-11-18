//! The support areas of the user (the support editor). An area is a
//! polygon that the user draws on the surface of a part: its points are
//! clicks on the surface (x, y, z in mm). Support uses the polygon on the
//! bed (x, y) and a z range, from the lowest to the highest point (see
//! support.Mark.poly):
//!
//! - kind grid or tree: support under all of the surface in the polygon
//!   that faces down in the z range, also under the support angle.
//! - kind block: no support for that surface.
//!
//! The areas stay apart from the slice. They go into the plate 3MF as
//! "support_area" lines of the overrides text, so a project file keeps
//! them, and an undo (which loads the 3MF of a step) brings them back. The
//! history facts have a line for each area, so a change of an area is a
//! step with a name.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const support = @import("../support.zig");

pub const Kind = support.Mark.Kind;

pub const Area = struct {
    kind: Kind,
    /// The points of the polygon, in order (x, y, z in mm).
    points: [][3]f64,
    /// The z range of the surface (mm).
    z_lo: f64,
    z_hi: f64,

    /// The box of the points on the bed: x0, y0, x1, y1.
    pub fn box(a: Area) [4]f64 {
        var b = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        for (a.points) |p| {
            b[0] = @min(b[0], p[0]);
            b[1] = @min(b[1], p[1]);
            b[2] = @max(b[2], p[0]);
            b[3] = @max(b[3], p[1]);
        }
        return b;
    }
};

/// The most points of one area.
pub const max_points = 256;

pub const Error = Allocator.Error || error{ BadArea, NoArea };

/// True for a kind that an area can have.
pub fn validKind(k: c_int) bool {
    return k == @intFromEnum(Kind.grid) or k == @intFromEnum(Kind.tree) or k == @intFromEnum(Kind.bridge) or k == @intFromEnum(Kind.block);
}

pub const Areas = struct {
    list: std.ArrayList(Area) = .empty,

    pub fn deinit(s: *Areas, gpa: Allocator) void {
        s.clear(gpa);
        s.list.deinit(gpa);
    }

    pub fn clear(s: *Areas, gpa: Allocator) void {
        for (s.list.items) |a| gpa.free(a.points);
        s.list.clearRetainingCapacity();
    }

    pub fn count(s: *const Areas) usize {
        return s.list.items.len;
    }

    /// The points and the z range of a new or moved area. A z range with
    /// z_lo over z_hi (or NaN) comes from the points.
    fn make(gpa: Allocator, pts: []const [3]f64, z_lo: f64, z_hi: f64) Error!struct { points: [][3]f64, lo: f64, hi: f64 } {
        if (pts.len < 3 or pts.len > max_points) return error.BadArea;
        for (pts) |p| for (p) |c| if (!std.math.isFinite(c)) return error.BadArea;
        var lo = z_lo;
        var hi = z_hi;
        if (!(lo <= hi)) {
            lo = std.math.inf(f64);
            hi = -std.math.inf(f64);
            for (pts) |p| {
                lo = @min(lo, p[2]);
                hi = @max(hi, p[2]);
            }
        }
        return .{ .points = try gpa.dupe([3]f64, pts), .lo = lo, .hi = hi };
    }

    /// Adds an area. Returns its index.
    pub fn add(s: *Areas, gpa: Allocator, kind: Kind, pts: []const [3]f64, z_lo: f64, z_hi: f64) Error!usize {
        if (kind == .area_on or kind == .area_off) return error.BadArea;
        const m = try make(gpa, pts, z_lo, z_hi);
        errdefer gpa.free(m.points);
        try s.list.append(gpa, .{ .kind = kind, .points = m.points, .z_lo = m.lo, .z_hi = m.hi });
        return s.list.items.len - 1;
    }

    /// Gives area i new points (a drag of a point) and a z range.
    pub fn set(s: *Areas, gpa: Allocator, i: usize, pts: []const [3]f64, z_lo: f64, z_hi: f64) Error!void {
        if (i >= s.list.items.len) return error.NoArea;
        const m = try make(gpa, pts, z_lo, z_hi);
        const a = &s.list.items[i];
        gpa.free(a.points);
        a.points = m.points;
        a.z_lo = m.lo;
        a.z_hi = m.hi;
    }

    pub fn setKind(s: *Areas, i: usize, kind: Kind) Error!void {
        if (i >= s.list.items.len) return error.NoArea;
        if (kind == .area_on or kind == .area_off) return error.BadArea;
        s.list.items[i].kind = kind;
    }

    pub fn remove(s: *Areas, gpa: Allocator, i: usize) Error!void {
        if (i >= s.list.items.len) return error.NoArea;
        const a = s.list.orderedRemove(i);
        gpa.free(a.points);
    }

    /// The marks of the areas for a slice (see support.Mark.poly). The
    /// polygons are in `a`.
    pub fn marks(s: *const Areas, a: Allocator, out: *std.ArrayList(support.Mark)) Allocator.Error!void {
        for (s.list.items) |area| {
            const poly = try a.alloc([2]f64, area.points.len);
            for (area.points, poly) |p, *q| q.* = .{ p[0], p[1] };
            const b = area.box();
            try out.append(a, .{
                .x = (b[0] + b[2]) / 2,
                .y = (b[1] + b[3]) / 2,
                .hw = (b[2] - b[0]) / 2,
                .hh = (b[3] - b[1]) / 2,
                .r = 0,
                .z = area.z_lo,
                .z_hi = area.z_hi,
                .kind = area.kind,
                .poly = poly,
            });
        }
    }

    /// The lines of the areas in the overrides text of a 3MF file:
    /// "support_area <tab> kind <tab> z_lo <tab> z_hi <tab> x,y,z;x,y,z;...".
    pub fn write3mfLines(s: *const Areas, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (s.list.items) |a| {
            try w.print("support_area\t{d}\t{d}\t{d}\t", .{ @intFromEnum(a.kind), a.z_lo, a.z_hi });
            for (a.points, 0..) |p, i| {
                if (i > 0) try w.writeByte(';');
                try w.print("{d},{d},{d}", .{ p[0], p[1], p[2] });
            }
            try w.writeByte('\n');
        }
    }

    /// Reads one line of the overrides text. False if it is not an area
    /// line. A bad area line is left out.
    pub fn read3mfLine(s: *Areas, gpa: Allocator, line: []const u8) Allocator.Error!bool {
        const tag = "support_area\t";
        if (!std.mem.startsWith(u8, line, tag)) return false;
        var f = std.mem.splitScalar(u8, line[tag.len..], '\t');
        const kind = std.fmt.parseInt(c_int, f.next() orelse return true, 10) catch return true;
        const lo = std.fmt.parseFloat(f64, f.next() orelse return true) catch return true;
        const hi = std.fmt.parseFloat(f64, f.next() orelse return true) catch return true;
        if (!validKind(kind)) return true;
        var pts: std.ArrayList([3]f64) = .empty;
        defer pts.deinit(gpa);
        var it = std.mem.splitScalar(u8, f.next() orelse return true, ';');
        while (it.next()) |text| {
            var c = std.mem.splitScalar(u8, text, ',');
            var p: [3]f64 = undefined;
            for (&p) |*v| v.* = std.fmt.parseFloat(f64, c.next() orelse return true) catch return true;
            try pts.append(gpa, p);
        }
        _ = s.add(gpa, @enumFromInt(@as(u8, @intCast(kind))), pts.items, lo, hi) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        return true;
    }

    /// The facts of the areas for the history (see App.writeFacts): one
    /// line for each area.
    pub fn writeFacts(s: *const Areas, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (s.list.items, 0..) |a, i| {
            const b = a.box();
            try w.print("Support\tarea {d}\t{s}, {d} points, z {d:.2} to {d:.2} mm, at {d:.1}, {d:.1}\n", .{
                i + 1,
                kindName(a.kind),
                a.points.len,
                a.z_lo,
                a.z_hi,
                (b[0] + b[2]) / 2,
                (b[1] + b[3]) / 2,
            });
        }
    }
};

pub fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .grid => "support (grid)",
        .tree => "support (tree)",
        .bridge => "a pad",
        .block => "no support",
        else => "?",
    };
}

test "support areas: add, move, and the 3MF lines" {
    const gpa = std.testing.allocator;
    var s: Areas = .{};
    defer s.deinit(gpa);
    const pts = [_][3]f64{ .{ 10, 10, 5 }, .{ 20, 10, 5.5 }, .{ 20, 20, 6 }, .{ 10, 20, 5 } };
    // A range of NaN comes from the points.
    const i = try s.add(gpa, .tree, &pts, std.math.nan(f64), std.math.nan(f64));
    try std.testing.expectEqual(@as(usize, 0), i);
    try std.testing.expectEqual(@as(f64, 5), s.list.items[0].z_lo);
    try std.testing.expectEqual(@as(f64, 6), s.list.items[0].z_hi);
    try std.testing.expectError(error.BadArea, s.add(gpa, .grid, pts[0..2], 0, 1));
    _ = try s.add(gpa, .block, &pts, 4, 7);
    try s.set(gpa, 0, pts[0..3], 1, 2);
    try std.testing.expectEqual(@as(usize, 3), s.list.items[0].points.len);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try s.write3mfLines(&w.writer);
    var t: Areas = .{};
    defer t.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, w.written(), '\n');
    while (lines.next()) |l| try std.testing.expect(try t.read3mfLine(gpa, l));
    try std.testing.expect(!try t.read3mfLine(gpa, "1\t2\tproject.wall_count\t3"));
    try std.testing.expectEqual(@as(usize, 2), t.count());
    for (s.list.items, t.list.items) |a, b| {
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.z_lo, b.z_lo);
        try std.testing.expectEqual(a.z_hi, b.z_hi);
        try std.testing.expectEqualSlices([3]f64, a.points, b.points);
    }
}
