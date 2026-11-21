//! The edits of the user on the lines of a slice (the segment editor): a
//! line that does not print, or a line with more or less plastic. They
//! stay apart from the slice, and apply to each new slice:
//!
//! - Each line of a layer plan has a key (`pathKey`): the z of its layer,
//!   its feature, and its points, rounded to 10 µm. A line that a new
//!   slice makes again in the same place has the same key.
//! - Before the writer prints a layer, `apply` looks up the key of each
//!   line. A delete takes the line out; a flow edit changes its width
//!   (and so its plastic).
//! - The match is strict: a line that moves or changes even a little has
//!   another key. Its edit then does not apply, and says so (`applied`),
//!   and it applies again when the same line comes back (for example after
//!   an undo of a setting).
//!
//! The preview, the time, and the G-code all come from the edited plans,
//! so they agree.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const layer_mod = @import("../layer.zig");
const geom = @import("../geom.zig");
const LayerPlan = layer_mod.LayerPlan;

pub const Kind = enum(u8) {
    /// The line does not print.
    delete = 0,
    /// The line prints with `value` times its plastic (its width).
    flow = 1,
    /// A drop of plastic at (x, y) on the layer at z: a short closed
    /// loop of diameter `value` mm, to fill a small gap.
    dot = 2,
};

pub const Edit = struct {
    key: u64,
    kind: Kind,
    value: f32 = 1,
    /// The layer of the line when the edit was made, for a list.
    layer: u32 = 0,
    /// A drop: its place (mm, on the bed) and the z of its layer (mm).
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    /// The last slice found the line (set by `apply`).
    applied: std.atomic.Value(bool) = .init(false),
};

/// The key of path i of a plan.
pub fn pathKey(plan: *const LayerPlan, i: usize) u64 {
    var h = std.hash.Wyhash.init(0);
    const z: i64 = @intFromFloat(@round(plan.z * 100));
    h.update(std.mem.asBytes(&z));
    const f: u8 = @intFromEnum(plan.paths.items[i].feature);
    h.update(std.mem.asBytes(&f));
    // The rounded points go to the hash in blocks. The hash reads a
    // stream of bytes, so a block gives the key of one update for each
    // point, with fewer calls. The view makes the keys of all paths in
    // layer order, on one thread, after each slice.
    var block: [64][2]i64 = undefined;
    var n: usize = 0;
    for (plan.points.get(i)) |p| {
        block[n] = .{ @divFloor(p.x + 5, 10), @divFloor(p.y + 5, 10) };
        n += 1;
        if (n == block.len) {
            h.update(std.mem.sliceAsBytes(&block));
            n = 0;
        }
    }
    h.update(std.mem.sliceAsBytes(block[0..n]));
    return h.final();
}

pub const Edits = struct {
    list: std.ArrayList(Edit) = .empty,

    pub fn deinit(e: *Edits, gpa: Allocator) void {
        e.list.deinit(gpa);
    }

    /// The key of a drop: its layer and its place, so a second drop at the
    /// same place replaces the first.
    pub fn dotKey(z: f32, x: f32, y: f32) u64 {
        var h = std.hash.Wyhash.init(1);
        const q = [3]i64{ @intFromFloat(@round(z * 100)), @intFromFloat(@round(x * 100)), @intFromFloat(@round(y * 100)) };
        h.update(std.mem.asBytes(&q));
        return h.final();
    }

    /// Adds an edit, or changes the edit of the same line.
    pub fn put(e: *Edits, gpa: Allocator, edit: Edit) Allocator.Error!void {
        for (e.list.items) |*x| if (x.key == edit.key) {
            x.kind = edit.kind;
            x.value = edit.value;
            return;
        };
        try e.list.append(gpa, edit);
    }

    pub fn remove(e: *Edits, i: usize) void {
        if (i < e.list.items.len) _ = e.list.orderedRemove(i);
    }

    /// Before a slice: no edit has applied yet.
    pub fn resetApplied(e: *Edits) void {
        for (e.list.items) |*x| x.applied.store(false, .release);
    }

    fn find(e: *const Edits, key: u64) ?*Edit {
        for (e.list.items) |*x| if (x.key == key) return @constCast(x);
        return null;
    }

    /// Applies the edits to a plan, in its arena. Any thread can call it
    /// for its own plan.
    pub fn apply(e: *const Edits, plan: *LayerPlan) Allocator.Error!void {
        if (e.list.items.len == 0) return;
        const a = plan.arena.allocator();
        // The drops of this layer: a small closed loop each, at the end of
        // the layer.
        for (e.list.items) |*d| {
            if (d.kind != .dot or @abs(@as(f64, d.z) - plan.z) > 0.005) continue;
            const r = geom.fromMm(@max(0.05, (d.value - @as(f32, @floatCast(plan.width))) / 2));
            const cx = geom.fromMm(d.x);
            const cy = geom.fromMm(d.y);
            var loop: [8]geom.Point = undefined;
            for (&loop, 0..) |*q, k| {
                const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 8;
                q.* = .{ .x = cx + @as(i64, @intFromFloat(@as(f64, @floatFromInt(r)) * @cos(t))), .y = cy + @as(i64, @intFromFloat(@as(f64, @floatFromInt(r)) * @sin(t))) };
            }
            try plan.paths.append(a, .{ .feature = .skin, .closed = true });
            try plan.points.append(a, &loop);
            d.applied.store(true, .release);
        }
        var deleted = false;
        for (plan.paths.items, 0..) |*p, i| {
            const edit = e.find(pathKey(plan, i)) orelse continue;
            if (edit.kind == .dot) continue;
            edit.applied.store(true, .release);
            switch (edit.kind) {
                .delete => deleted = true,
                .flow => {
                    const w: f32 = if (p.width > 0) p.width else @floatCast(plan.width);
                    p.width = w * std.math.clamp(edit.value, 0.1, 3);
                },
                .dot => {},
            }
        }
        if (!deleted) return;
        // The plan again, without the deleted lines.
        var paths: std.ArrayList(layer_mod.Path) = .empty;
        var points: geom.Paths = .empty;
        for (plan.paths.items, 0..) |p, i| {
            if (e.find(pathKey(plan, i))) |edit| if (edit.kind == .delete) continue;
            try paths.append(a, p);
            try points.append(a, plan.points.get(i));
        }
        plan.paths = paths;
        plan.points = points;
    }
};

const testing = std.testing;

test "edits: delete a line, and change the flow of another" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    const a = plan.arena.allocator();
    const lines = [_][2]geom.Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 10000, .y = 0 } },
        .{ .{ .x = 0, .y = 1000 }, .{ .x = 10000, .y = 1000 } },
        .{ .{ .x = 0, .y = 2000 }, .{ .x = 10000, .y = 2000 } },
    };
    for (lines) |l| {
        try plan.paths.append(a, .{ .feature = .infill, .closed = false });
        try plan.points.append(a, &l);
    }
    var e: Edits = .{};
    defer e.deinit(gpa);
    try e.put(gpa, .{ .key = pathKey(&plan, 1), .kind = .delete });
    try e.put(gpa, .{ .key = pathKey(&plan, 2), .kind = .flow, .value = 1.5 });
    // A line of another layer: it does not apply.
    try e.put(gpa, .{ .key = 12345, .kind = .delete });
    try e.apply(&plan);
    try testing.expectEqual(@as(usize, 2), plan.paths.items.len);
    try testing.expectEqual(@as(i64, 0), plan.points.get(0)[0].y);
    try testing.expectEqual(@as(i64, 2000), plan.points.get(1)[0].y);
    try testing.expectApproxEqAbs(@as(f32, 0.6), plan.paths.items[1].width, 1e-6);
    try testing.expect(e.list.items[0].applied.load(.acquire));
    try testing.expect(!e.list.items[2].applied.load(.acquire));
}

test "edits: the key of a path is the hash of its rounded points, one by one" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    const a = plan.arena.allocator();
    var rng: std.Random.DefaultPrng = .init(7);
    const r = rng.random();
    // Paths of 1 to 300 points: shorter and longer than a block.
    for ([_]usize{ 1, 2, 63, 64, 65, 128, 300 }) |len| {
        try plan.paths.append(a, .{ .feature = .outer_wall, .closed = true });
        const pts = try a.alloc(geom.Point, len);
        for (pts) |*q| q.* = .{ .x = r.intRangeAtMost(i64, -300_000, 300_000), .y = r.intRangeAtMost(i64, -300_000, 300_000) };
        try plan.points.append(a, pts);
    }
    for (0..plan.paths.items.len) |i| {
        var h = std.hash.Wyhash.init(0);
        const z: i64 = 80;
        h.update(std.mem.asBytes(&z));
        const f: u8 = @intFromEnum(plan.paths.items[i].feature);
        h.update(std.mem.asBytes(&f));
        for (plan.points.get(i)) |p| {
            const q = [2]i64{ @divFloor(p.x + 5, 10), @divFloor(p.y + 5, 10) };
            h.update(std.mem.asBytes(&q));
        }
        try testing.expectEqual(h.final(), pathKey(&plan, i));
    }
}

test "edits: a drop of plastic on its layer" {
    const gpa = testing.allocator;
    var plan: LayerPlan = .{ .arena = .init(gpa), .index = 3, .z = 0.8, .height = 0.2, .width = 0.4 };
    defer plan.deinit();
    var e: Edits = .{};
    defer e.deinit(gpa);
    try e.put(gpa, .{ .key = Edits.dotKey(0.8, 10, 12), .kind = .dot, .value = 1.2, .x = 10, .y = 12, .z = 0.8 });
    try e.put(gpa, .{ .key = Edits.dotKey(1.0, 10, 12), .kind = .dot, .value = 1.2, .x = 10, .y = 12, .z = 1.0 });
    try e.apply(&plan);
    try testing.expectEqual(@as(usize, 1), plan.paths.items.len);
    try testing.expect(plan.paths.items[0].closed);
    try testing.expect(e.list.items[0].applied.load(.acquire));
    try testing.expect(!e.list.items[1].applied.load(.acquire));
    // Around (10, 12): the loop has a radius of (1.2 - 0.4) / 2 mm.
    const p0 = plan.points.get(0)[0];
    try testing.expectApproxEqAbs(@as(f64, 10.4), geom.toMm(p0.x), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 12), geom.toMm(p0.y), 0.01);
}

