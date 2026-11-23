//! The selection model: one record of what the user points at.
//!
//! The model holds the active plate, the selected parts, the selected
//! line and segment, the hover, the tool, and the camera target. Each
//! shell reads and changes this state only through the `zs_sel_*` calls.
//! docs/internals/selection.md explains the design.
//!
//! Identity:
//!
//! - A part is its stable id (plate.Part.id), never its index.
//! - A line is its key (edits.pathKey), never its path index alone.
//!
//! The generation. Each change adds 1 to `gen`. A shell sends the
//! generation with each request to a worker. The reply of that request
//! calls `answered`. A local change that is newer than the reply stays.
//! So a late reply never undoes a newer click.
//!
//! The places. `parts` holds the facts of the owner of the plate. `over`
//! holds local places of a drag, which are newer than those facts.
//! `scene` holds the places of the beads that the view shows now. A part
//! whose place differs from its scene place has beads at an old place.
//! The pick then tests its box at its current place.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A part in the table of the model: its id and its box on the bed (mm).
/// The C API has the same layout (zs_sel_part).
pub const PartBox = extern struct {
    id: u64,
    x0: f64,
    y0: f64,
    z0: f64,
    x1: f64,
    y1: f64,
    z1: f64,

    fn samePlace(a: PartBox, b: PartBox) bool {
        const e = 1e-6;
        return @abs(a.x0 - b.x0) < e and @abs(a.y0 - b.y0) < e and @abs(a.z0 - b.z0) < e and
            @abs(a.x1 - b.x1) < e and @abs(a.y1 - b.y1) < e and @abs(a.z1 - b.z1) < e;
    }

    /// The distance along a ray to the box, or null for a miss.
    fn rayEnter(b: PartBox, ray: [6]f32) ?f64 {
        const lo = [3]f64{ b.x0, b.y0, b.z0 };
        const hi = [3]f64{ b.x1, b.y1, b.z1 };
        var t0: f64 = 0;
        var t1: f64 = std.math.inf(f64);
        for (0..3) |k| {
            const o: f64 = ray[k];
            const d: f64 = ray[k + 3];
            if (d == 0) {
                if (o < lo[k] or o > hi[k]) return null;
                continue;
            }
            const a = (lo[k] - o) / d;
            const c = (hi[k] - o) / d;
            t0 = @max(t0, @min(a, c));
            t1 = @min(t1, @max(a, c));
            if (t0 > t1) return null;
        }
        return t0;
    }

    fn holds(b: PartBox, x: f64, y: f64) bool {
        return x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1;
    }

    fn area(b: PartBox) f64 {
        return (b.x1 - b.x0) * (b.y1 - b.y0);
    }
};

/// How a selection call changes the list.
pub const Mode = enum(c_int) { replace = 0, add = 1, toggle = 2, remove = 3 };

/// The camera target: no request.
pub const frame_none: i64 = -2;
/// The camera target: all plates.
pub const frame_all: i64 = -1;

const Over = struct { box: PartBox, gen: u64 };

pub const Selection = struct {
    gpa: Allocator,
    gen: u64 = 1,

    /// The active plate that the owner reports.
    plate_now: usize = 0,
    plate_count: usize = 1,
    /// A plate that the user asked for, until the reply comes.
    plate_want: ?usize = null,
    plate_want_gen: u64 = 0,

    parts: std.ArrayList(PartBox) = .empty,
    over: std.ArrayList(Over) = .empty,
    scene: std.ArrayList(PartBox) = .empty,
    /// The selected ids. The last id is the primary part.
    selected: std.ArrayList(u64) = .empty,

    line_key: u64 = 0,
    line_path: i64 = -1,
    line_seg: i64 = -1,

    hover: u64 = 0,
    tool: c_int = 0,
    camera: i64 = frame_none,

    pub fn deinit(s: *Selection) void {
        s.parts.deinit(s.gpa);
        s.over.deinit(s.gpa);
        s.scene.deinit(s.gpa);
        s.selected.deinit(s.gpa);
    }

    fn bump(s: *Selection) void {
        s.gen += 1;
    }

    // ---- the plate ----

    /// The plate that the user sees: the request, else the reported plate.
    pub fn plate(s: *const Selection) usize {
        return s.plate_want orelse s.plate_now;
    }

    /// The user goes to plate i. The selection ends at once: it names
    /// parts of the plate before.
    pub fn requestPlate(s: *Selection, i: usize) void {
        if (i == s.plate()) return;
        // The request stays open until its reply (`answered`), also for
        // the plate that the owner reports now: an older request can still
        // be on its way.
        s.plate_want = i;
        s.bump();
        s.plate_want_gen = s.gen;
        s.dropFocus();
    }

    /// The owner reports its active plate and the count of plates.
    pub fn reportPlate(s: *Selection, active: usize, count: usize) void {
        const before = s.plate();
        const changed = active != s.plate_now or count != s.plate_count;
        s.plate_now = active;
        s.plate_count = count;
        if (s.plate_want) |w| {
            if (w >= count) s.plate_want = null;
        }
        if (s.plate() != before) s.dropFocus();
        if (changed) s.bump();
    }

    fn dropFocus(s: *Selection) void {
        s.selected.clearRetainingCapacity();
        s.over.clearRetainingCapacity();
        s.hover = 0;
        s.line_key = 0;
        s.line_path = -1;
        s.line_seg = -1;
    }

    // ---- the replies ----

    /// The owner finished each request up to generation `g`. A local
    /// place or a plate request of that age now has its answer.
    pub fn answered(s: *Selection, g: u64) void {
        var i: usize = 0;
        var changed = false;
        while (i < s.over.items.len) {
            if (s.over.items[i].gen <= g) {
                _ = s.over.swapRemove(i);
                changed = true;
            } else i += 1;
        }
        if (s.plate_want != null and s.plate_want_gen <= g) {
            const before = s.plate();
            s.plate_want = null;
            if (s.plate() != before) s.dropFocus();
            changed = true;
        }
        if (changed) s.bump();
    }

    // ---- the parts ----

    /// The parts of the active plate from the owner. An id that left the
    /// table leaves the selection, so the selection is valid or empty.
    pub fn setParts(s: *Selection, table: []const PartBox) Allocator.Error!void {
        const same = table.len == s.parts.items.len and
            std.mem.eql(u8, std.mem.sliceAsBytes(table), std.mem.sliceAsBytes(s.parts.items));
        if (same) return;
        s.parts.clearRetainingCapacity();
        try s.parts.appendSlice(s.gpa, table);
        var k: usize = 0;
        for (s.selected.items) |id| {
            if (s.tableIndex(id) != null) {
                s.selected.items[k] = id;
                k += 1;
            }
        }
        s.selected.shrinkRetainingCapacity(k);
        var i: usize = 0;
        while (i < s.over.items.len) {
            if (s.tableIndex(s.over.items[i].box.id) == null) _ = s.over.swapRemove(i) else i += 1;
        }
        if (s.hover != 0 and s.tableIndex(s.hover) == null) s.hover = 0;
        s.bump();
    }

    /// The places of the beads of the view, by the part index of the
    /// slice of that view.
    pub fn setScene(s: *Selection, table: []const PartBox) Allocator.Error!void {
        s.scene.clearRetainingCapacity();
        try s.scene.appendSlice(s.gpa, table);
    }

    fn tableIndex(s: *const Selection, id: u64) ?usize {
        if (id == 0) return null;
        for (s.parts.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    /// The index of a part on the plate now, or null.
    pub fn indexOf(s: *const Selection, id: u64) ?usize {
        return s.tableIndex(id);
    }

    /// The box of a part at its current place.
    pub fn boxOf(s: *const Selection, id: u64) ?PartBox {
        for (s.over.items) |o| if (o.box.id == id) return o.box;
        const i = s.tableIndex(id) orelse return null;
        return s.parts.items[i];
    }

    /// A drag puts a part at a new place at once: x and y are the center
    /// of its footprint, and z its lowest point. No reply is needed.
    pub fn place(s: *Selection, id: u64, x: f64, y: f64, z: f64) Allocator.Error!bool {
        const b = s.boxOf(id) orelse return false;
        const hx = (b.x1 - b.x0) / 2;
        const hy = (b.y1 - b.y0) / 2;
        const h = b.z1 - b.z0;
        const next: PartBox = .{ .id = id, .x0 = x - hx, .y0 = y - hy, .z0 = z, .x1 = x + hx, .y1 = y + hy, .z1 = z + h };
        s.bump();
        for (s.over.items) |*o| if (o.box.id == id) {
            o.* = .{ .box = next, .gen = s.gen };
            return true;
        };
        try s.over.append(s.gpa, .{ .box = next, .gen = s.gen });
        return true;
    }

    // ---- the selected parts ----

    /// Changes the selection. An id that is not on the plate changes
    /// nothing, except that `replace` with id 0 clears the selection.
    pub fn select(s: *Selection, id: u64, mode: Mode) Allocator.Error!void {
        if (s.tableIndex(id) == null) {
            if (mode == .replace and id == 0) s.clearParts();
            return;
        }
        const at = std.mem.indexOfScalar(u64, s.selected.items, id);
        switch (mode) {
            .replace => {
                if (s.selected.items.len == 1 and at != null) return;
                s.selected.clearRetainingCapacity();
                try s.selected.append(s.gpa, id);
            },
            .add => {
                if (at != null) return;
                try s.selected.append(s.gpa, id);
            },
            .toggle => {
                if (at) |k| _ = s.selected.orderedRemove(k) else try s.selected.append(s.gpa, id);
            },
            .remove => {
                _ = s.selected.orderedRemove(at orelse return);
            },
        }
        s.bump();
    }

    pub fn clearParts(s: *Selection) void {
        if (s.selected.items.len == 0) return;
        s.selected.clearRetainingCapacity();
        s.bump();
    }

    /// The primary part (the last selected), or 0.
    pub fn primary(s: *const Selection) u64 {
        const n = s.selected.items.len;
        return if (n > 0) s.selected.items[n - 1] else 0;
    }

    pub fn has(s: *const Selection, id: u64) bool {
        return std.mem.indexOfScalar(u64, s.selected.items, id) != null;
    }

    // ---- the line ----

    /// Selects a line by its key, with its path and segment now. Key 0
    /// and path -1: no line.
    pub fn setLine(s: *Selection, key: u64, path: i64, seg: i64) void {
        if (s.line_key == key and s.line_path == path and s.line_seg == seg) return;
        s.line_key = if (path < 0) 0 else key;
        s.line_path = path;
        s.line_seg = if (path < 0) -1 else seg;
        s.bump();
    }

    /// A new slice: `path` is the path of the same key, or -1. The key
    /// stays with the path. With no path, the line selection ends.
    pub fn lineFound(s: *Selection, path: i64, segments: i64) void {
        if (s.line_key == 0) return;
        if (path < 0) {
            s.setLine(0, -1, -1);
            return;
        }
        const seg = if (segments > 0) std.math.clamp(s.line_seg, 0, segments - 1) else s.line_seg;
        if (path == s.line_path and seg == s.line_seg) return;
        s.line_path = path;
        s.line_seg = seg;
        s.bump();
    }

    // ---- hover, tool, and camera ----

    pub fn setHover(s: *Selection, id: u64) void {
        const v = if (s.tableIndex(id) != null) id else 0;
        if (v == s.hover) return;
        s.hover = v;
        s.bump();
    }

    pub fn setTool(s: *Selection, tool: c_int) void {
        if (tool == s.tool) return;
        s.tool = tool;
        s.bump();
    }

    /// Asks the camera to go to plate `target`, or to all plates.
    pub fn requestFrame(s: *Selection, target: i64) void {
        if (s.camera == target) return;
        s.camera = target;
        s.bump();
    }

    /// The camera target that is due now, or null. A plate target waits
    /// until that plate is the reported plate.
    pub fn takeFrame(s: *Selection) ?i64 {
        const t = s.camera;
        if (t == frame_none) return null;
        if (t >= 0 and @as(usize, @intCast(t)) != s.plate_now) {
            // A plate that no longer exists drops the request.
            if (@as(usize, @intCast(t)) >= s.plate_count and s.plate_want == null) s.camera = frame_none;
            return null;
        }
        s.camera = frame_none;
        s.bump();
        return t;
    }

    // ---- the pick ----

    /// True if the beads of table part `b` are at another place.
    fn beadsMoved(s: *const Selection, b: PartBox) bool {
        for (s.scene.items) |q| if (q.id == b.id) return !q.samePlace(b);
        return true;
    }

    /// The part under a pointer, or 0. `ray`: the eye and the direction.
    /// `hit_part`: the part index in the scene of the bead under the
    /// pointer, or a negative number. `bed`: the bed point under the
    /// pointer, or null.
    ///
    /// The beads of a part at its scene place are exact. A part that has
    /// moved since its scene has beads at an old place, so its box at the
    /// current place counts. The nearest candidate wins. With no
    /// candidate, the smallest footprint under the bed point wins.
    pub fn pick(s: *const Selection, ray: [6]f32, hit_part: i64, bed: ?[2]f64) u64 {
        // A request for another plate is open: the table is of the plate
        // before.
        if (s.plate_want != null) return 0;
        var best: u64 = 0;
        var best_t: f64 = std.math.inf(f64);
        if (hit_part >= 0 and hit_part < s.scene.items.len) {
            const id = s.scene.items[@intCast(hit_part)].id;
            if (s.boxOf(id)) |b| if (!s.beadsMoved(b)) {
                best = id;
                // A bead can stick out of the box of its part (a brim):
                // it then counts behind any box on the ray.
                best_t = b.rayEnter(ray) orelse std.math.floatMax(f64);
            };
        }
        for (s.parts.items) |p| {
            const b = s.boxOf(p.id).?;
            if (!s.beadsMoved(b)) continue;
            const t = b.rayEnter(ray) orelse continue;
            if (t < best_t) {
                best_t = t;
                best = p.id;
            }
        }
        if (best != 0) return best;
        const q = bed orelse return 0;
        var best_area: f64 = std.math.inf(f64);
        for (s.parts.items) |p| {
            const b = s.boxOf(p.id).?;
            if (b.holds(q[0], q[1]) and b.area() < best_area) {
                best_area = b.area();
                best = p.id;
            }
        }
        return best;
    }
};

// ---- tests ----

const testing = std.testing;

fn box(id: u64, x: f64, y: f64) PartBox {
    return .{ .id = id, .x0 = x - 10, .y0 = y - 10, .z0 = 0, .x1 = x + 10, .y1 = y + 10, .z1 = 20 };
}

/// A ray straight down onto the bed at (x, y).
fn down(x: f32, y: f32) [6]f32 {
    return .{ x, y, 100, 0, 0, -1 };
}

test "selection: select a part after a move of another part, 100 times" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    const start = [_]PartBox{ box(7, 50, 50), box(9, 150, 50) };
    try s.setParts(&start);
    try s.setScene(&start);
    var r = std.Random.DefaultPrng.init(36);
    const rand = r.random();
    var x: f64 = 50;
    var y: f64 = 50;
    for (0..100) |_| {
        // Part 7 moves. Its beads stay at the scene place: no slice ran.
        x = 20 + rand.float(f64) * 80;
        y = 100 + rand.float(f64) * 80;
        try s.select(7, .replace);
        try testing.expect(try s.place(7, x, y, 0));
        // A click on part 9 selects part 9.
        const got = s.pick(down(150, 50), 1, .{ 150, 50 });
        try testing.expectEqual(@as(u64, 9), got);
        try s.select(got, .replace);
        try testing.expectEqual(@as(u64, 9), s.primary());
        // A click at the new place selects part 7, and the old place is
        // free.
        try testing.expectEqual(@as(u64, 7), s.pick(down(@floatCast(x), @floatCast(y)), -1, .{ x, y }));
        try testing.expectEqual(@as(u64, 0), s.pick(down(50, 50), 0, .{ 50, 50 }));
    }
}

test "selection: a late reply keeps the newer place and the newer plate" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    try s.setParts(&.{box(1, 50, 50)});
    const old = s.gen;
    _ = try s.place(1, 120, 80, 0);
    // A reply of a request before the drag: the place stays.
    s.answered(old);
    try testing.expectEqual(@as(f64, 110), s.boxOf(1).?.x0);
    // The table of that older request does not move the part either.
    try s.setParts(&.{box(1, 60, 60)});
    try testing.expectEqual(@as(f64, 110), s.boxOf(1).?.x0);
    // The reply of the drag: the facts of the owner count again.
    s.answered(s.gen);
    try testing.expectEqual(@as(f64, 50), s.boxOf(1).?.x0);

    s.reportPlate(0, 3);
    s.requestPlate(2);
    const asked = s.plate_want_gen;
    try testing.expectEqual(@as(usize, 2), s.plate());
    // A report of the plate before does not undo the click.
    s.reportPlate(0, 3);
    s.answered(asked - 1);
    try testing.expectEqual(@as(usize, 2), s.plate());
    s.reportPlate(2, 3);
    s.answered(asked);
    try testing.expectEqual(@as(usize, 2), s.plate());
    try testing.expect(s.plate_want == null);
}

test "selection: a failed plate request does not stay stuck" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    s.reportPlate(0, 2);
    s.requestPlate(1);
    // The reply comes, and the owner stayed on plate 0.
    s.answered(s.plate_want_gen);
    try testing.expectEqual(@as(usize, 0), s.plate());
    s.requestPlate(1);
    try testing.expectEqual(@as(usize, 1), s.plate());
    // A click back wins over the open request, and its reply ends it.
    s.requestPlate(0);
    try testing.expectEqual(@as(usize, 0), s.plate());
    s.reportPlate(1, 2);
    try testing.expectEqual(@as(usize, 0), s.plate());
    s.reportPlate(0, 2);
    s.answered(s.plate_want_gen);
    try testing.expect(s.plate_want == null);
    try testing.expectEqual(@as(usize, 0), s.plate());
}

test "selection: 50 random selects keep a valid list, and a plate change clears it" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    s.reportPlate(0, 2);
    const t = [_]PartBox{ box(3, 30, 30), box(4, 80, 30), box(5, 130, 30) };
    try s.setParts(&t);
    var r = std.Random.DefaultPrng.init(50);
    const rand = r.random();
    for (0..50) |_| {
        const id = t[rand.uintLessThan(usize, 3)].id;
        const mode: Mode = @enumFromInt(@as(c_int, rand.uintLessThan(u3, 4)));
        try s.select(id, mode);
        for (s.selected.items, 0..) |a, i| {
            try testing.expect(s.indexOf(a) != null);
            for (s.selected.items[i + 1..]) |b| try testing.expect(a != b);
        }
    }
    try s.select(4, .replace);
    s.requestPlate(1);
    try testing.expectEqual(@as(usize, 0), s.selected.items.len);
    // During the plate change, a pick names no part of the plate before.
    try testing.expectEqual(@as(u64, 0), s.pick(down(80, 30), -1, .{ 80, 30 }));
}

test "selection: a table without the part drops it, and never names another part" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    try s.setParts(&.{ box(1, 30, 30), box(2, 80, 30), box(3, 130, 30) });
    try s.select(2, .replace);
    try s.select(3, .add);
    // Part 2 goes: part 3 moves to its index.
    try s.setParts(&.{ box(1, 30, 30), box(3, 130, 30) });
    try testing.expectEqualSlices(u64, &.{3}, s.selected.items);
    try testing.expectEqual(@as(?usize, 1), s.indexOf(3));
    try s.setParts(&.{box(1, 30, 30)});
    try testing.expectEqual(@as(u64, 0), s.primary());
}

test "selection: a line stays by its key, and ends when the key is gone" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    s.setLine(0xabc, 10, 4);
    s.lineFound(25, 3);
    try testing.expectEqual(@as(i64, 25), s.line_path);
    try testing.expectEqual(@as(i64, 2), s.line_seg);
    try testing.expectEqual(@as(u64, 0xabc), s.line_key);
    s.lineFound(-1, 0);
    try testing.expectEqual(@as(u64, 0), s.line_key);
    try testing.expectEqual(@as(i64, -1), s.line_path);
}

test "selection: the camera target waits for its plate" {
    var s: Selection = .{ .gpa = testing.allocator };
    defer s.deinit();
    s.reportPlate(0, 2);
    s.requestPlate(1);
    s.requestFrame(1);
    try testing.expectEqual(@as(?i64, null), s.takeFrame());
    s.reportPlate(1, 2);
    s.answered(s.plate_want_gen);
    try testing.expectEqual(@as(?i64, 1), s.takeFrame());
    try testing.expectEqual(@as(?i64, null), s.takeFrame());
    s.requestFrame(frame_all);
    try testing.expectEqual(@as(?i64, frame_all), s.takeFrame());
}
