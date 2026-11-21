//! The clipboard of parts: Copy, Cut, and Paste of parts and of whole
//! plates. The core keeps one clipboard for the process, so a paste
//! works on each plate of a set, also after the parts of the copy go.
//!
//! A copy holds deep copies of the parts (Plate.clonePart: the mesh, the
//! pose, the scale, the settings, the modifier volumes, the support trees,
//! the paint, and the labels), and the support areas and the support marks
//! over each part (Plate.partAt of the center of the area or of the mark).
//! A copy of a plate holds all of its parts, all of its areas and marks,
//! and its layer profiles, filament slots, edits, and overrides.
//!
//! A paste puts new copies on the plate of an app:
//!
//! - On an empty plate, each part goes to its place of the copy. A copy of
//!   a plate also brings its profiles, filaments, edits, and overrides, so
//!   the new plate is the same as the plate of the copy.
//! - At a point of the bed (the pointer), the parts keep their places
//!   relative to each other, with the center of the group at the point.
//! - Else each part goes to a free place on the bed, as Duplicate does.
//!
//! The areas and the marks of a part move with it. The clipboard stays for
//! more pastes. Call these functions from one thread.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const zs = @import("../root.zig");
const App = @import("../app.zig").App;
const Plate = zs.plate.Plate;
const Part = zs.plate.Part;
const Mark = zs.support.Mark;
const Kind = Mark.Kind;

const Area = struct {
    /// The index of the part in the clipboard, or null: no part.
    part: ?usize,
    kind: Kind,
    points: [][3]f64,
    z_lo: f64,
    z_hi: f64,
};

const MarkCopy = struct { part: ?usize, mark: Mark };

pub const Clip = struct {
    gpa: Allocator,
    parts: []Part = &.{},
    areas: []Area = &.{},
    marks: []MarkCopy = &.{},
    /// A copy of a whole plate: `lines` has its profiles, filament slots,
    /// edits, and overrides (the lines of App.writeFileLines).
    plate: bool = false,
    lines: []u8 = &.{},

    fn deinit(c: *Clip) void {
        for (c.parts) |*p| Plate.freePart(c.gpa, p);
        c.gpa.free(c.parts);
        for (c.areas) |a| c.gpa.free(a.points);
        c.gpa.free(c.areas);
        c.gpa.free(c.marks);
        c.gpa.free(c.lines);
    }
};

var clip: ?Clip = null;

/// Empties the clipboard.
pub fn clear() void {
    if (clip) |*c| c.deinit();
    clip = null;
}

/// The count of parts on the clipboard.
pub fn count() usize {
    return if (clip) |c| c.parts.len else 0;
}

/// True if the clipboard has a whole plate.
pub fn isPlate() bool {
    return if (clip) |c| c.plate else false;
}

fn center(pts: []const [3]f64) [2]f64 {
    var x: f64 = 0;
    var y: f64 = 0;
    for (pts) |p| {
        x += p[0];
        y += p[1];
    }
    const n: f64 = @floatFromInt(@max(1, pts.len));
    return .{ x / n, y / n };
}

/// The index in `picked` of the part of the plate under (x, y), or null.
fn owner(plate: *const Plate, picked: []const usize, x: f64, y: f64) ?usize {
    const i = plate.partAt(x, y) orelse return null;
    return std.mem.indexOfScalar(usize, picked, i);
}

/// Copies parts `picked` of the plate of `app` to the clipboard, with the
/// areas and the marks over them. whole: a copy of the plate (all parts,
/// all areas and marks, and the lines of the plate). An index out of
/// range gives error.OutOfRange; the clipboard then stays as it was.
pub fn copy(app: *const App, picked_in: []const usize, whole: bool) (Allocator.Error || error{ OutOfRange, WriteFailed })!void {
    const c = try make(app, picked_in, whole);
    clear();
    clip = c;
}

/// A copy of parts `picked` (or of the whole plate) that the caller owns
/// (free it with `free`), with no change of the clipboard.
pub fn make(app: *const App, picked_in: []const usize, whole: bool) (Allocator.Error || error{ OutOfRange, WriteFailed })!Clip {
    const gpa = app.gpa;
    const n_all = app.plate.count();
    const picked = if (whole) blk: {
        const all = try gpa.alloc(usize, n_all);
        for (all, 0..) |*v, i| v.* = i;
        break :blk all;
    } else try gpa.dupe(usize, picked_in);
    defer gpa.free(picked);
    for (picked) |i| if (i >= n_all) return error.OutOfRange;
    if (picked.len == 0) return error.OutOfRange;

    var c: Clip = .{ .gpa = gpa, .plate = whole };
    errdefer c.deinit();
    var parts: std.ArrayList(Part) = .empty;
    errdefer {
        for (parts.items) |*p| Plate.freePart(gpa, p);
        parts.deinit(gpa);
    }
    for (picked) |i| {
        try parts.ensureUnusedCapacity(gpa, 1);
        parts.appendAssumeCapacity(try Plate.clonePart(gpa, &app.plate.parts.items[i]));
    }
    c.parts = try parts.toOwnedSlice(gpa);

    var areas: std.ArrayList(Area) = .empty;
    errdefer {
        for (areas.items) |a| gpa.free(a.points);
        areas.deinit(gpa);
    }
    for (app.areas.list.items) |a| {
        const at = center(a.points);
        const k = owner(&app.plate, picked, at[0], at[1]);
        if (k == null and !whole) continue;
        try areas.ensureUnusedCapacity(gpa, 1);
        areas.appendAssumeCapacity(.{ .part = k, .kind = a.kind, .points = try gpa.dupe([3]f64, a.points), .z_lo = a.z_lo, .z_hi = a.z_hi });
    }
    c.areas = try areas.toOwnedSlice(gpa);

    var marks: std.ArrayList(MarkCopy) = .empty;
    errdefer marks.deinit(gpa);
    for (app.marks.items) |m| {
        const k = owner(&app.plate, picked, m.x, m.y);
        if (k == null and !whole) continue;
        try marks.append(gpa, .{ .part = k, .mark = m });
    }
    c.marks = try marks.toOwnedSlice(gpa);

    if (whole) {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try app.writePlateLines(&w.writer);
        c.lines = try gpa.dupe(u8, w.written());
    }
    return c;
}

pub fn free(c: *Clip) void {
    c.deinit();
}

pub const Paste = struct {
    /// The index of the first new part; the new parts follow it.
    first: usize,
    count: usize,
};

/// Where a paste puts the parts.
pub const At = union(enum) {
    /// Each part at a free place (on an empty plate: at its place).
    free,
    /// The center of the group at this point of the bed.
    point: [2]f64,
};

/// Puts copies of the parts of the clipboard on the plate of `app` (see
/// the header). The caller stops the slice before and notes the change
/// of the plate after. error.NoResult: the clipboard is empty.
pub fn paste(app: *App, at: At) (Allocator.Error || error{NoResult})!Paste {
    return pasteFrom(&(clip orelse return error.NoResult), app, at);
}

/// As paste, from a copy of `make`.
pub fn pasteFrom(c: *const Clip, app: *App, at: At) (Allocator.Error || error{NoResult})!Paste {
    if (c.parts.len == 0) return error.NoResult;
    const gpa = app.gpa;
    const empty = app.plate.count() == 0;
    const first = app.plate.count();
    // The center of the group: the center of the box of the footprints.
    var box = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (c.parts) |*p| {
        const f = p.footprint();
        box[0] = @min(box[0], f[0]);
        box[1] = @min(box[1], f[1]);
        box[2] = @max(box[2], f[2]);
        box[3] = @max(box[3], f[3]);
    }
    const mid = [2]f64{ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2 };
    const shift = try gpa.alloc([2]f64, c.parts.len);
    defer gpa.free(shift);
    for (c.parts, shift) |*src, *d| {
        var p = try Plate.clonePart(gpa, src);
        const i = switch (at) {
            .free => if (empty) try app.plate.putAt(gpa, p) else try app.plate.put(gpa, p, app.bedSize(), app.partGap()),
            .point => |q| blk: {
                p.x = q[0] + (src.x - mid[0]);
                p.y = q[1] + (src.y - mid[1]);
                break :blk try app.plate.putAt(gpa, p);
            },
        };
        const placed = &app.plate.parts.items[i];
        d.* = .{ placed.x - src.x, placed.y - src.y };
    }
    const whole = c.plate and empty and at == .free;
    for (c.areas) |a| {
        const d = if (a.part) |k| shift[k] else if (whole) [2]f64{ 0, 0 } else continue;
        const pts = try gpa.dupe([3]f64, a.points);
        defer gpa.free(pts);
        for (pts) |*p| {
            p[0] += d[0];
            p[1] += d[1];
        }
        _ = app.areas.add(gpa, a.kind, pts, a.z_lo, a.z_hi) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
    for (c.marks) |m| {
        const d = if (m.part) |k| shift[k] else if (whole) [2]f64{ 0, 0 } else continue;
        var mk = m.mark;
        mk.x += d[0];
        mk.y += d[1];
        try app.addMark(mk);
    }
    if (whole) try app.readFileLines(first, c.lines);
    return .{ .first = first, .count = c.parts.len };
}

// ---- tests ----

const testing = std.testing;

fn testApp() !*App {
    const app = try App.create(testing.allocator, null, null);
    errdefer app.destroy();
    const gpa = testing.allocator;
    var b: zs.mesh.Builder = .init(gpa);
    try zs.mesh.shapes.addBox(&b, 0, 0, 0, 10, 10, 10);
    var m = try b.finish();
    defer m.deinit(gpa);
    var stl: std.Io.Writer.Allocating = .init(gpa);
    defer stl.deinit();
    try m.writeStl(&stl.writer);
    _ = try app.addStl("cube.stl", stl.written());
    return app;
}

test "copy and paste a part with its area, mark, and label" {
    defer clear();
    const app = try testApp();
    defer app.destroy();
    const p0 = app.plate.parts.items[0];
    // An area and a mark under the part, and one far from it.
    const pts = [_][3]f64{ .{ p0.x - 2, p0.y - 2, 0 }, .{ p0.x + 2, p0.y - 2, 0 }, .{ p0.x, p0.y + 2, 0 } };
    _ = try app.areas.add(testing.allocator, .grid, &pts, 1, 0);
    const far = [_][3]f64{ .{ 1, 1, 0 }, .{ 3, 1, 0 }, .{ 2, 3, 0 } };
    _ = try app.areas.add(testing.allocator, .block, &far, 1, 0);
    try app.addMark(.{ .x = p0.x + 1, .y = p0.y, .z = 2, .r = 1, .kind = .tree });
    _ = try zs.app.labels.add(app, 0, "{\"origin\":[0,-5,5],\"normal\":[0,-1,0],\"right\":[1,0,0],\"filament\":2,\"items\":[{\"kind\":\"text\",\"text\":\"A\",\"size\":3}]}");

    try copy(app, &.{0}, false);
    try testing.expectEqual(@as(usize, 1), count());
    try testing.expect(!isPlate());

    const r = try paste(app, .free);
    try testing.expectEqual(@as(usize, 1), r.first);
    try testing.expectEqual(@as(usize, 2), app.plate.count());
    const p1 = app.plate.parts.items[1];
    try testing.expect(@abs(p1.x - p0.x) + @abs(p1.y - p0.y) > 5);
    try testing.expectEqual(@as(usize, 1), p1.labels.items.len);
    // The area and the mark of the part come with it; the far area not.
    try testing.expectEqual(@as(usize, 3), app.areas.count());
    try testing.expectEqual(@as(usize, 2), app.marks.items.len);
    const a = app.areas.list.items[2];
    const c = center(a.points);
    try testing.expectApproxEqAbs(p1.x, c[0], 1e-9);
    try testing.expectApproxEqAbs(p1.y - 2.0 / 3.0, c[1], 1e-9);
    const m = app.marks.items[1];
    try testing.expectApproxEqAbs(p1.x + 1, m.x, 1e-9);

    // At a point: the center of the part goes there.
    const q = try paste(app, .{ .point = .{ 40, 50 } });
    try testing.expectEqual(@as(usize, 2), q.first);
    try testing.expectApproxEqAbs(@as(f64, 40), app.plate.parts.items[2].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50), app.plate.parts.items[2].y, 1e-9);
}

test "the clipboard stays after the part goes, and works on another app" {
    defer clear();
    const app = try testApp();
    defer app.destroy();
    try copy(app, &.{0}, false);
    try app.removePart(0);
    try testing.expectEqual(@as(usize, 0), app.plate.count());
    const other = try App.create(testing.allocator, null, null);
    defer other.destroy();
    const r = try paste(other, .free);
    try testing.expectEqual(@as(usize, 0), r.first);
    try testing.expectEqual(@as(usize, 1), other.plate.count());
    try testing.expectError(error.OutOfRange, copy(app, &.{3}, false));
    // The failed copy keeps the clipboard.
    try testing.expectEqual(@as(usize, 1), count());
}

test "a copy of a plate pastes the same plate on an empty plate" {
    defer clear();
    const app = try testApp();
    defer app.destroy();
    try app.setOverride(1, 3, "project.wall_count", "4");
    const far = [_][3]f64{ .{ 1, 1, 0 }, .{ 3, 1, 0 }, .{ 2, 3, 0 } };
    _ = try app.areas.add(testing.allocator, .block, &far, 1, 0);
    try copy(app, &.{}, true);
    try testing.expect(isPlate());
    const other = try App.create(testing.allocator, null, null);
    defer other.destroy();
    _ = try paste(other, .free);
    try testing.expectEqual(app.plate.parts.items[0].x, other.plate.parts.items[0].x);
    try testing.expectEqual(app.plate.parts.items[0].y, other.plate.parts.items[0].y);
    try testing.expectEqual(@as(usize, 1), other.overrides.items.len);
    try testing.expectEqual(@as(usize, 1), other.areas.count());
    // On a plate with parts, only the parts (and their areas) come.
    _ = try paste(other, .free);
    try testing.expectEqual(@as(usize, 2), other.plate.count());
    try testing.expectEqual(@as(usize, 1), other.overrides.items.len);
    try testing.expectEqual(@as(usize, 1), other.areas.count());
}

test "a copy of make leaves the clipboard as it was" {
    defer clear();
    const app = try testApp();
    defer app.destroy();
    try testing.expectEqual(@as(usize, 0), count());
    var c = try make(app, &.{}, true);
    defer free(&c);
    const other = try App.create(testing.allocator, null, null);
    defer other.destroy();
    _ = try pasteFrom(&c, other, .free);
    try testing.expectEqual(@as(usize, 1), other.plate.count());
    try testing.expectEqual(@as(usize, 0), count());
}
