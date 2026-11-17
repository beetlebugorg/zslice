//! The plates of a set in one 3D view, and the light copies of a slice
//! that the view draws when the camera is far.
//!
//! A project has several plates. The view shows them all, in a row from
//! left to right with a gap between them. The active plate is the full
//! view (view.zig): the pick index, the layer range, the selection, and
//! the replay. Each other plate is a fixed buffer of beads, made once
//! after each slice of its app. It has no pick index and no layer range.
//!
//! The world of the view is the frame of the active plate: its bed starts
//! at (0, 0). A plate i has an origin in the row (`origin`), and it draws
//! at origin[i] - origin[active] in that world. When the active plate
//! changes, the camera moves by the change of the origin, so the picture
//! stays still.
//!
//! The speed. A plate of many parts has millions of beads, and a GPU draws
//! each bead as an instance of a mesh. The count of the instances is the
//! cost. Far from the camera, a bead is less than a pixel wide, and most
//! beads are hidden in the part. So each slice also has light copies (a
//! `Lite`), at three levels:
//!
//! 1. The beads that show from outside: no sparse infill, and the inner
//!    walls only on the layers with skin (where they show at a top or a
//!    bottom surface). Runs of short beads along a path that are almost
//!    straight join into one bead (to 0.1 mm).
//! 2. The same, from every second layer, with twice the height, and
//!    joined to 0.3 mm.
//! 3. Every fourth layer, four times the height, joined to 0.8 mm.
//!
//! The view takes a level from the size of a layer on the screen. A plate
//! out of the view (its box is outside the frustum) costs nothing.

const std = @import("std");
const frame_mod = @import("frame.zig");
const Instance = frame_mod.Instance;

/// The number of light levels.
pub const n_levels = 3;
/// The layers of each level: a level keeps one layer of `step`.
const level_step = [n_levels]u32{ 1, 2, 4 };
/// The largest distance (mm) of a point of a path from a joined bead.
const level_tol = [n_levels]f32{ 0.1, 0.3, 0.8 };
/// The most beads in one joined bead.
const max_join = 24;

/// The features in the alpha byte of a bead (settings.Feature).
const f_inner_wall = 1;
const f_skin = 2;
const f_infill = 3;
const f_ironing = 4;
const f_bridge = 10;

/// The light copies of a slice (see the header comment). The indices are
/// in `beads`, from 0.
pub const Lite = struct {
    beads: std.ArrayList(Instance) = .empty,
    /// Level k is beads level_start[k] to level_start[k + 1].
    level_start: [n_levels + 1]u32 = @splat(0),
    /// The end of each layer in `beads`, for each level. A layer that a
    /// level leaves out has no beads.
    layer_end: [n_levels]std.ArrayList(u32) = .{ .empty, .empty, .empty },

    pub fn deinit(l: *Lite, gpa: std.mem.Allocator) void {
        l.beads.deinit(gpa);
        for (&l.layer_end) |*e| e.deinit(gpa);
        l.* = .{};
    }

    pub fn clear(l: *Lite) void {
        l.beads.clearRetainingCapacity();
        for (&l.layer_end) |*e| e.clearRetainingCapacity();
        l.level_start = @splat(0);
    }

    /// The layer count of the levels.
    pub fn layers(l: *const Lite) usize {
        return l.layer_end[0].items.len;
    }

    /// The beads of level `level` of the layers lo to hi (all inclusive).
    pub fn range(l: *const Lite, level: usize, lo: usize, hi: usize) [2]u32 {
        const ends = l.layer_end[level].items;
        if (ends.len == 0 or lo > hi) return .{ 0, 0 };
        const top = @min(hi, ends.len - 1);
        const first = if (lo == 0) l.level_start[level] else ends[@min(lo, ends.len) - 1];
        return .{ first, @max(first, ends[top]) };
    }

    /// Makes the levels from the beads of a slice and the end of each of
    /// its layers.
    pub fn build(l: *Lite, gpa: std.mem.Allocator, beads: []const Instance, layer_end: []const u32) error{OutOfMemory}!void {
        l.clear();
        // The layers with a top or a bottom surface: their inner walls show.
        const skin = try gpa.alloc(bool, layer_end.len);
        defer gpa.free(skin);
        var first: u32 = 0;
        for (layer_end, 0..) |end, li| {
            skin[li] = false;
            for (beads[first..end]) |b| {
                const f = b.rgba[3];
                if (f == f_skin or f == f_ironing or f == f_bridge) {
                    skin[li] = true;
                    break;
                }
            }
            first = end;
        }
        for (0..n_levels) |level| {
            l.level_start[level] = @intCast(l.beads.items.len);
            const step = level_step[level];
            try l.layer_end[level].ensureTotalCapacity(gpa, layer_end.len);
            first = 0;
            for (layer_end, 0..) |end, li| {
                const keep = (li + 1) % step == 0 or li + 1 == layer_end.len;
                if (keep) try l.addLayer(gpa, beads[first..end], skin[li], @floatFromInt(step), level_tol[level]);
                l.layer_end[level].appendAssumeCapacity(@intCast(l.beads.items.len));
                first = end;
            }
        }
        l.level_start[n_levels] = @intCast(l.beads.items.len);
    }

    /// Adds the beads of one layer that show from outside, joined along
    /// their paths. `hmul` scales the height (a level that keeps one layer
    /// of several), and `tol` is the largest distance of a point of the
    /// path from a joined bead.
    fn addLayer(l: *Lite, gpa: std.mem.Allocator, beads: []const Instance, skin: bool, hmul: f32, tol: f32) error{OutOfMemory}!void {
        const shows = struct {
            fn f(b: Instance, s: bool) bool {
                const feat = b.rgba[3];
                if (feat == f_infill) return false;
                if (feat == f_inner_wall) return s;
                return true;
            }
        }.f;
        var i: usize = 0;
        while (i < beads.len) {
            const b = beads[i];
            if (!shows(b, skin)) {
                i += 1;
                continue;
            }
            // Extend the run while the next bead goes on from the end of
            // the run, looks the same, and keeps the path near the line.
            var j = i + 1;
            while (j < beads.len and j - i < max_join) : (j += 1) {
                const n = beads[j];
                const p = beads[j - 1];
                if (n.ax != p.bx or n.ay != p.by or n.z != b.z or n.h != b.h) break;
                if (!std.mem.eql(u8, &n.rgba, &b.rgba)) break;
                if (@abs(n.w - b.w) > 0.15 * b.w) break;
                if (!nearLine(beads[i .. j + 1], tol)) break;
            }
            var out = b;
            out.bx = beads[j - 1].bx;
            out.by = beads[j - 1].by;
            // A bead of zero length draws as a dot: keep a tiny length.
            if (out.ax == out.bx and out.ay == out.by) out.bx += 0.001;
            out.h = @min(b.h * hmul, b.z);
            if (!(out.h > 0)) out.h = b.h;
            try l.beads.append(gpa, out);
            i = j;
        }
    }
};

/// True if the inner points of a run of beads (the ends of all but the
/// last) are within `tol` of the line from the start of the first bead
/// to the end of the last.
fn nearLine(run: []const Instance, tol: f32) bool {
    const ax = run[0].ax;
    const ay = run[0].ay;
    const dx = run[run.len - 1].bx - ax;
    const dy = run[run.len - 1].by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return false;
    for (run[0 .. run.len - 1]) |b| {
        const px = b.bx - ax;
        const py = b.by - ay;
        // The distance to the infinite line, and the point must be between
        // the ends (a path that turns back is not a line).
        const cr = px * dy - py * dx;
        if (cr * cr > tol * tol * len2) return false;
        const t = px * dx + py * dy;
        if (t < 0 or t > len2) return false;
    }
    return true;
}

/// A box of beads, for the frustum cull: first to end in a buffer.
pub const Chunk = struct { lo: [3]f32, hi: [3]f32, first: u32, end: u32, width: f32 };

/// The beads in a chunk of a plate: a draw call for each is cheap.
const chunk_beads = 512;

/// One plate of the set, other than the active plate.
pub const Plate = struct {
    /// The full beads, then the light levels: `beads[full_end..]` is
    /// lite.beads.
    beads: std.ArrayList(Instance) = .empty,
    full_end: u32 = 0,
    lite: Lite = .{},
    /// The chunks of the full beads.
    chunks: std.ArrayList(Chunk) = .empty,
    /// The box of all beads (plate frame), and the height of the first
    /// layer (for the choice of a level).
    lo: [3]f32 = .{ 0, 0, 0 },
    hi: [3]f32 = .{ 0, 0, 0 },
    layer_h: f32 = 0.2,
    /// The bed size (mm) and the origin of the plate in the row.
    bed: [2]f32 = .{ 220, 220 },
    origin: [2]f32 = .{ 0, 0 },
    flags: u32 = 0,
    /// The generation of `beads`: a backend uploads them again when it
    /// changes.
    gen: u32 = 0,

    pub fn deinit(p: *Plate, gpa: std.mem.Allocator) void {
        p.beads.deinit(gpa);
        p.lite.deinit(gpa);
        p.chunks.deinit(gpa);
    }

    /// Drops the beads (an empty plate, or a plate with no slice).
    pub fn clear(p: *Plate) void {
        p.beads.clearRetainingCapacity();
        p.lite.clear();
        p.chunks.clearRetainingCapacity();
        p.full_end = 0;
        p.lo = .{ 0, 0, 0 };
        p.hi = .{ 0, 0, 0 };
    }

    /// Takes the beads of a slice: the full beads and the end of each
    /// layer, and its light levels (made with `Lite.build` from the same
    /// beads, or null to make them here).
    pub fn set(p: *Plate, gpa: std.mem.Allocator, beads: []const Instance, layer_end: []const u32, lite: ?*const Lite) error{OutOfMemory}!void {
        p.clear();
        if (lite) |src| {
            try p.lite.beads.appendSlice(gpa, src.beads.items);
            p.lite.level_start = src.level_start;
            for (&p.lite.layer_end, src.layer_end) |*d, s| try d.appendSlice(gpa, s.items);
        } else try p.lite.build(gpa, beads, layer_end);
        try p.beads.ensureTotalCapacity(gpa, beads.len + p.lite.beads.items.len);
        p.beads.appendSliceAssumeCapacity(beads);
        p.beads.appendSliceAssumeCapacity(p.lite.beads.items);
        p.full_end = @intCast(beads.len);
        // The chunks, and the box of all beads.
        const inf = std.math.inf(f32);
        p.lo = .{ inf, inf, 0 };
        p.hi = .{ -inf, -inf, 0 };
        var c: Chunk = undefined;
        for (beads, 0..) |b, i| {
            if (i % chunk_beads == 0) c = .{ .lo = .{ inf, inf, inf }, .hi = .{ -inf, -inf, -inf }, .first = @intCast(i), .end = @intCast(i), .width = 0 };
            const r = b.w / 2;
            const lo = [3]f32{ @min(b.ax, b.bx) - r, @min(b.ay, b.by) - r, b.z - b.h };
            const hi = [3]f32{ @max(b.ax, b.bx) + r, @max(b.ay, b.by) + r, b.z };
            for (0..3) |k| {
                c.lo[k] = @min(c.lo[k], lo[k]);
                c.hi[k] = @max(c.hi[k], hi[k]);
                p.lo[k] = @min(p.lo[k], lo[k]);
                p.hi[k] = @max(p.hi[k], hi[k]);
            }
            c.width = @max(c.width, b.w);
            c.end = @intCast(i + 1);
            if (c.end % chunk_beads == 0 or i + 1 == beads.len) try p.chunks.append(gpa, c);
        }
        if (beads.len == 0) {
            p.lo = .{ 0, 0, 0 };
            p.hi = .{ 0, 0, 0 };
        }
        p.layer_h = if (beads.len > 0) beads[0].h else 0.2;
    }

    /// The beads of a light level, in `beads`.
    pub fn liteRange(p: *const Plate, level: usize) [2]u32 {
        return .{ p.full_end + p.lite.level_start[level], p.full_end + p.lite.level_start[level + 1] };
    }
};

/// The flags of a plate (zs_view_plate_flags).
pub const flag_stale: u32 = 1;
pub const flag_bed_model: u32 = 2;
/// The plate cannot slice: a light grid, and its beads (an outline of its
/// parts, see View.setPlateOutline) fade.
pub const flag_disabled: u32 = 4;

/// The level of detail for a layer of `layer_px` pixels on the screen:
/// null for the full beads, else a light level.
pub fn levelFor(layer_px: f32) ?usize {
    if (layer_px >= 2.5) return null;
    if (layer_px >= 1.2) return 0;
    if (layer_px >= 0.6) return 1;
    return 2;
}

test "the light levels leave out the infill and join straight runs" {
    const gpa = std.testing.allocator;
    var beads: std.ArrayList(Instance) = .empty;
    defer beads.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    // 8 layers. Each: an outer wall of 10 beads on a line, then 10 beads
    // of infill, then 4 beads of inner wall.
    for (0..8) |l| {
        const z: f32 = 0.2 * @as(f32, @floatFromInt(l + 1));
        for (0..10) |k| {
            const x: f32 = @floatFromInt(k);
            try beads.append(gpa, .{ .ax = x, .ay = 0, .bx = x + 1, .by = 0, .z = z, .h = 0.2, .w = 0.4, .rgba = .{ 1, 2, 3, 0 } });
        }
        for (0..10) |k| {
            const x: f32 = @floatFromInt(k);
            try beads.append(gpa, .{ .ax = x, .ay = 1, .bx = x + 1, .by = 1, .z = z, .h = 0.2, .w = 0.4, .rgba = .{ 1, 2, 3, f_infill } });
        }
        for (0..4) |k| {
            const x: f32 = @floatFromInt(k);
            try beads.append(gpa, .{ .ax = x, .ay = 2, .bx = x + 1, .by = 2, .z = z, .h = 0.2, .w = 0.4, .rgba = .{ 1, 2, 3, f_inner_wall } });
        }
        try ends.append(gpa, @intCast(beads.items.len));
    }
    var l: Lite = .{};
    defer l.deinit(gpa);
    try l.build(gpa, beads.items, ends.items);
    // Level 1: one bead for each layer (the wall in one run, no infill,
    // no inner wall: no layer has skin).
    try std.testing.expectEqual(@as(u32, 8), l.level_start[1] - l.level_start[0]);
    const w = l.beads.items[0];
    try std.testing.expectEqual(@as(f32, 0), w.ax);
    try std.testing.expectEqual(@as(f32, 10), w.bx);
    // Level 2: every second layer, twice the height. Level 3: 2 layers.
    try std.testing.expectEqual(@as(u32, 4), l.level_start[2] - l.level_start[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), l.beads.items[l.level_start[1]].h, 1e-6);
    try std.testing.expectEqual(@as(u32, 2), l.level_start[3] - l.level_start[2]);
    // The range of layers 2 to 5 of level 1.
    try std.testing.expectEqual([2]u32{ 2, 6 }, l.range(0, 2, 5));
    // A plate with these beads: its box and its chunks.
    var p: Plate = .{};
    defer p.deinit(gpa);
    try p.set(gpa, beads.items, ends.items, &l);
    try std.testing.expectEqual(@as(u32, 8 * 24), p.full_end);
    try std.testing.expectEqual(@as(usize, 1), p.chunks.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.6), p.hi[2], 1e-5);
    try std.testing.expectEqual([2]u32{ 192, 200 }, p.liteRange(0));
}

test "a path that turns does not join past the corner" {
    const gpa = std.testing.allocator;
    const beads = [_]Instance{
        .{ .ax = 0, .ay = 0, .bx = 1, .by = 0, .z = 0.2, .h = 0.2, .w = 0.4, .rgba = .{ 0, 0, 0, 0 } },
        .{ .ax = 1, .ay = 0, .bx = 2, .by = 0, .z = 0.2, .h = 0.2, .w = 0.4, .rgba = .{ 0, 0, 0, 0 } },
        .{ .ax = 2, .ay = 0, .bx = 2, .by = 1, .z = 0.2, .h = 0.2, .w = 0.4, .rgba = .{ 0, 0, 0, 0 } },
        .{ .ax = 2, .ay = 1, .bx = 2, .by = 2, .z = 0.2, .h = 0.2, .w = 0.4, .rgba = .{ 0, 0, 0, 0 } },
    };
    var l: Lite = .{};
    defer l.deinit(gpa);
    try l.build(gpa, &beads, &.{4});
    try std.testing.expectEqual(@as(u32, 2), l.level_start[1]);
    try std.testing.expectEqual(@as(f32, 2), l.beads.items[0].bx);
    try std.testing.expectEqual(@as(f32, 2), l.beads.items[1].by);
}
