//! Support: the areas that hold up the overhangs of a part.
//!
//! A printer cannot put plastic on air. A part of a layer that is too far
//! outside the layer below it needs support under it. The method:
//!
//! 1. Overhangs. For each layer i, the basic overhang is the outline of
//!    layer i minus the outline of layer i - 1 moved out by d = h *
//!    tan(angle). A wall that leans less than `support_angle` from vertical
//!    moves less than d in one layer, so it holds itself. A wall that leans
//!    a little more gives a thin basic strip on each layer, and the strips
//!    of two layers do not touch. So the overhang that needs support is the
//!    full strip: the part of layer i that is not on layer i - 1, within d
//!    of the basic overhang. The strips of a slope then cover its whole
//!    area. Only slivers of the arithmetic and specks are removed. The
//!    layer below moves out by a little less than d, so that the removal
//!    of the slivers keeps the strip of a wall that leans just over the
//!    angle.
//! 2. Columns, from the top down. An overhang of layer i needs support from
//!    layer i - 1 - gap down, where gap is `support_z_gap_layers`: the
//!    empty layers between the support and the part, so that the support
//!    comes off. On each layer, the column is the column of the layer above
//!    plus the new overhangs, minus the outline of the part. Where the part
//!    is under the column, the column stops: it rests on the part. A column
//!    that rests on the part also keeps `support_z_gap_layers` empty layers
//!    above the part. The support area of a layer is the column minus the
//!    part moved out by `support_xy_gap`. The XY gap does not stop the
//!    column: under a slope, the area next to the part is free again on
//!    the layers below. A column starts from the overhang moved out by
//!    one line width: the strip of a slope is thinner than a line, and a
//!    thinner area does not print. Where the part above the Z gap covers the support,
//!    the XY gap is at most half a line width: the Z gap keeps the support
//!    off the overhang, and the full XY gap would remove the support under
//!    a slope.
//! 3. Bed only (`support = buildplate`). A pass from the bottom up keeps
//!    only the areas that have support under them, so that each column
//!    starts on the bed.
//! 4. Interface. The top `support_interface_layers` layers under each
//!    overhang are the interface. They are dense, so that the bottom
//!    surface of the part is smooth.
//!
//! Tree support (see tree_support.zig) replaces steps 2 and 3 with
//! branches. Its interface is a pad under each overhang. A pad reaches
//! one line width further out than the overhang area of grid support, so
//! that the pad under a slope is wide enough for the interface lines. A
//! pad stays only where a branch, the part (under the Z gap), or a pad is
//! under it: it reaches at most half a line past a branch, so it does not
//! hang. A pad on a pad reaches at most half a line past it, and spans
//! its gaps up to two lines wide (the lines bridge them). On the
//! bed layer, a tree prints its wall loop and dense interface lines in it.
//! A tree layer is hollow (see `SupportLayer.hollow`).
//!
//! Step 1 (with the XY offset of the model), the clean-up after step 2,
//! and step 4 run on all threads. Step 2 and step 3 go one layer at a time,
//! because each layer depends on its neighbor, so they do as little as
//! possible.
//!
//! The method (overhang by angle, columns down, gaps in XY and Z, dense
//! interface layers) is the common "grid" or "normal" support of FDM
//! slicers (see REFERENCES.md). The code is new.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const parallel = @import("parallel.zig");
const settings_mod = @import("settings.zig");
const slicer = @import("slicer.zig");
const Paths = geom.Paths;
const tree = @import("tree_support.zig");

/// A support mark of the user, from a click on a line: support of a
/// kind under a disk at a place, or no support there. Coordinates on the
/// bed, in mm; `z` is the nozzle z of the layer of the line.
pub const Mark = struct {
    x: f64,
    y: f64,
    z: f64,
    /// The radius of the disk, mm.
    r: f64 = 3,
    kind: Kind,
    /// For `area_on` and `area_off`: half the width and half the depth of
    /// the box around (x, y), mm, at all heights.
    hw: f64 = 0,
    hh: f64 = 0,
    /// A support area of the user (the support editor): a polygon on the
    /// bed (x, y in mm) over the heights `z` to `z_hi`. With kind grid,
    /// tree, or bridge, all of the surface in the polygon that faces down
    /// in that range gets support, also under the support angle. With kind
    /// block, that surface gets no support. Empty: a mark at a point.
    poly: []const [2]f64 = &.{},
    z_hi: f64 = 0,

    /// `area_on` and `area_off` come from the settings of one part (see
    /// part_settings.zig): support in its box with support off for the
    /// plate, or no support in its box.
    pub const Kind = enum(u8) { grid = 0, tree = 1, bridge = 2, block = 3, area_on = 4, area_off = 5 };
};

pub const SupportLayer = struct {
    body: Paths = .empty,
    interface: Paths = .empty,
    /// Tree support: the body prints as a wall loop only, with support
    /// lines only in `filled` (see tree_support.zig).
    hollow: bool = false,
    filled: Paths = .empty,

    pub fn deinit(self: *SupportLayer, gpa: Allocator) void {
        self.body.deinit(gpa);
        self.interface.deinit(gpa);
        self.filled.deinit(gpa);
    }
};

pub fn deinitAll(gpa: Allocator, layers: []SupportLayer) void {
    for (layers) |*l| l.deinit(gpa);
    gpa.free(layers);
}

/// Computes the support areas of each layer. Returns an empty slice if
/// support is off. `gpa` must be thread-safe if `threads` is more than 1.
pub fn compute(
    gpa: Allocator,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    r: *const settings_mod.Resolved,
    threads: usize,
    marks: []const Mark,
) anyerror![]SupportLayer {
    return computeCached(gpa, outlines, layers, r, threads, marks, null);
}

/// The work of the support of a job, for the next job with the same
/// outlines (see engine.Job): the result, and the parts of the work that
/// depend only on the outlines and a few settings. So a change of the
/// infill keeps the support, and an edit of a support area does not make
/// the overhangs and the gaps around the part again.
pub const Cache = struct {
    /// A key of the outlines and the layers, from the caller; 0: no cache.
    outline_key: u64 = 0,
    /// The key of `result` (see `resultKey`), and a copy of it.
    result_key: u64 = 0,
    result: []SupportLayer = &.{},
    /// Step 1 of `computeStyle`: its key, the overhangs (before the
    /// marks), and the part moved out by the two XY gaps.
    step1_key: u64 = 0,
    need: []Paths = &.{},
    blocked: []Paths = &.{},
    near: []Paths = &.{},
    /// The avoidance area of tree support (see tree_support.zig).
    avoid: tree.AvoidCache = .{},

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        if (c.result.len > 0) deinitAll(gpa, c.result);
        c.dropStep1(gpa);
        c.avoid.deinit(gpa);
        c.* = .{};
    }

    fn dropStep1(c: *Cache, gpa: Allocator) void {
        for ([_][]Paths{ c.need, c.blocked, c.near }) |ps| {
            for (ps) |*x| x.deinit(gpa);
            gpa.free(ps);
        }
        c.need = &.{};
        c.blocked = &.{};
        c.near = &.{};
        c.step1_key = 0;
    }
};

/// A hash of the inputs of `compute` besides the outlines: the support
/// settings, the line width, and the marks. Never 0.
fn resultKey(outline_key: u64, r: *const settings_mod.Resolved, marks: []const Mark) u64 {
    var h = std.hash.Wyhash.init(outline_key);
    const p = r.settings.project;
    inline for (@typeInfo(settings_mod.Project).@"struct".fields) |f| {
        if (comptime std.mem.startsWith(u8, f.name, "support")) h.update(std.mem.asBytes(&@field(p, f.name)));
    }
    h.update(std.mem.asBytes(&r.line_width));
    for (marks) |m| {
        h.update(std.mem.asBytes(&[_]f64{ m.x, m.y, m.z, m.r, m.hw, m.hh, m.z_hi, @floatFromInt(@intFromEnum(m.kind)), @floatFromInt(m.poly.len) }));
        h.update(std.mem.sliceAsBytes(m.poly));
    }
    return h.final() | 1;
}

fn cloneLayers(gpa: Allocator, src: []const SupportLayer) Allocator.Error![]SupportLayer {
    const out = try gpa.alloc(SupportLayer, src.len);
    for (out) |*x| x.* = .{};
    errdefer deinitAll(gpa, out);
    for (out, src) |*o, l| o.* = .{ .body = try l.body.clone(gpa), .interface = try l.interface.clone(gpa), .hollow = l.hollow, .filled = try l.filled.clone(gpa) };
    return out;
}

/// `compute`, with the work of the job before in `cache` (or null).
pub fn computeCached(
    gpa: Allocator,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    r: *const settings_mod.Resolved,
    threads: usize,
    marks: []const Mark,
    cache_in: ?*Cache,
) anyerror![]SupportLayer {
    const cache = if (cache_in) |c| (if (c.outline_key != 0) c else null) else null;
    if (cache) |c| {
        const key = resultKey(c.outline_key, r, marks);
        if (key == c.result_key) return cloneLayers(gpa, c.result);
        const out = try computeAll(gpa, outlines, layers, r, threads, marks, c);
        errdefer if (out.len > 0) deinitAll(gpa, out);
        if (c.result.len > 0) deinitAll(gpa, c.result);
        c.result = &.{};
        c.result_key = 0;
        if (out.len > 0) c.result = try cloneLayers(gpa, out);
        c.result_key = key;
        return out;
    }
    return computeAll(gpa, outlines, layers, r, threads, marks, null);
}

fn computeAll(
    gpa: Allocator,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    r: *const settings_mod.Resolved,
    threads: usize,
    marks: []const Mark,
    cache: ?*Cache,
) anyerror![]SupportLayer {
    const p = r.settings.project;
    var adds = false;
    var on_area = false;
    var off_area = false;
    for (marks) |m| switch (m.kind) {
        .grid, .tree, .bridge => adds = true,
        .area_on => on_area = true,
        .area_off => off_area = true,
        .block => {},
    };
    if ((p.support == .off and !adds and !on_area) or outlines.len < 2) return &.{};
    // Support from the settings, less the blocked marks; then the support
    // of each kind of mark, with its own style, joined in. With support
    // off and parts with support on: the support of the settings, in the
    // boxes of those parts only.
    var rr = r.*;
    const only_on = p.support == .off and on_area;
    if (only_on) rr.settings.project.support = .everywhere;
    var main = try computeStyle(gpa, outlines, layers, &rr, threads, marks, null, cache);
    errdefer deinitAll(gpa, main);
    if (only_on or (p.support != .off and off_area)) try clipToAreas(gpa, main, marks, only_on);
    for ([_]Mark.Kind{ .grid, .tree, .bridge }) |kind| {
        var has = false;
        for (marks) |m| if (m.kind == kind) {
            has = true;
        };
        if (!has) continue;
        const extra = try computeStyle(gpa, outlines, layers, r, threads, marks, kind, cache);
        defer deinitAll(gpa, extra);
        if (extra.len == 0) continue;
        if (main.len == 0) {
            main = try gpa.alloc(SupportLayer, extra.len);
            for (main) |*x| x.* = .{};
        }
        for (main, extra) |*a, b| {
            // A hollow layer joined with a filled one: the filled body
            // stays filled.
            if (a.hollow or b.hollow) {
                const fa = if (a.hollow) a.filled else a.body;
                const fb = if (b.hollow) b.filled else b.body;
                const u = try clip.unite(gpa, fa, fb);
                a.filled.deinit(gpa);
                a.filled = u;
                a.hollow = true;
            }
            if (!b.body.isEmpty()) {
                const u = try clip.unite(gpa, a.body, b.body);
                a.body.deinit(gpa);
                a.body = u;
            }
            if (!b.interface.isEmpty()) {
                const u = try clip.unite(gpa, a.interface, b.interface);
                a.interface.deinit(gpa);
                a.interface = u;
            }
        }
    }
    return main;
}

/// Keeps the support in the boxes of the `area_on` marks (`keep_on`), or
/// removes the support in the boxes of the `area_off` marks.
fn clipToAreas(gpa: Allocator, layers_out: []SupportLayer, marks: []const Mark, keep_on: bool) Allocator.Error!void {
    var boxes: Paths = .empty;
    defer boxes.deinit(gpa);
    for (marks) |m| if (m.kind == (if (keep_on) Mark.Kind.area_on else Mark.Kind.area_off)) {
        const x0 = geom.fromMm(m.x - m.hw);
        const x1 = geom.fromMm(m.x + m.hw);
        const y0 = geom.fromMm(m.y - m.hh);
        const y1 = geom.fromMm(m.y + m.hh);
        try boxes.append(gpa, &.{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) });
    };
    if (boxes.isEmpty()) return;
    const area = try clip.unite(gpa, boxes, .empty);
    defer @constCast(&area).deinit(gpa);
    for (layers_out) |*l| {
        for ([_]*Paths{ &l.body, &l.interface }) |pp| {
            if (pp.isEmpty()) continue;
            const next = if (keep_on) try clip.intersect(gpa, pp.*, area) else try clip.difference(gpa, pp.*, area);
            pp.deinit(gpa);
            pp.* = next;
        }
    }
}

/// A disk of radius r at x, y (mm), as a polygon.
fn disk(a: Allocator, x: f64, y: f64, r: f64) Allocator.Error!Paths {
    var out: Paths = .empty;
    var pts: [24]geom.Point = undefined;
    for (&pts, 0..) |*q, k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 24.0;
        q.* = .{ .x = geom.fromMm(x + r * @cos(t)), .y = geom.fromMm(y + r * @sin(t)) };
    }
    try out.append(a, &pts);
    return out;
}

/// The polygon of an area, as paths.
fn polygon(a: Allocator, pts: []const [2]f64) Allocator.Error!Paths {
    var out: Paths = .empty;
    const q = try a.alloc(geom.Point, pts.len);
    for (pts, q) |p, *o| o.* = .{ .x = geom.fromMm(p[0]), .y = geom.fromMm(p[1]) };
    try out.append(a, q);
    // The union gives the polygon a positive orientation, and splits a
    // polygon that crosses itself.
    return clip.unite(a, out, .empty);
}

/// The room in z around the points of an area, mm. The points come from
/// clicks on the surface, so they can be a little off its height.
const area_z_room = 0.3;

/// The layers of an area, first to end: the layers whose top is in the
/// z range of the area. A surface that faces down at height z is the
/// bottom of the layer over z, so the range reaches one layer higher.
fn areaLayers(layers: []const slicer.Layer, m: Mark) [2]usize {
    const lo = @min(m.z, m.z_hi) - area_z_room;
    const hi = @max(m.z, m.z_hi) + area_z_room;
    var first: usize = layers.len;
    var end: usize = 0;
    for (layers, 0..) |l, i| {
        if (l.z < lo or l.z - l.height > hi) continue;
        first = @min(first, i);
        end = i + 1;
    }
    if (first >= end) return .{ 0, 0 };
    return .{ first, end };
}

/// Adds the overhangs of an area of the user to `need`: on each layer of
/// its z range, the part of the layer in the polygon that is not on the
/// layer below. That is all of the surface that faces down, at any angle.
fn enforceArea(gpa: Allocator, a: Allocator, outlines: []const Paths, layers: []const slicer.Layer, need: []Paths, m: Mark) Allocator.Error!void {
    const area = try polygon(a, m.poly);
    const range = areaLayers(layers, m);
    for (@max(1, range[0])..range[1]) |i| {
        const on = try clip.intersect(a, outlines[i], area);
        if (on.isEmpty()) continue;
        const free = try clip.difference(a, on, outlines[i - 1]);
        if (free.isEmpty()) continue;
        // Only slivers of the arithmetic go. A steep wall gives a thin
        // strip on each layer, and the user wants support under it.
        const strip = try offset_mod.opening(a, free, sliver, .{});
        if (strip.isEmpty()) continue;
        const u = try clip.unite(gpa, need[i], strip);
        need[i].deinit(gpa);
        need[i] = u;
    }
}

/// The layer of a z (the nearest nozzle z).
fn layerAt(layers: []const slicer.Layer, z: f64) usize {
    var best: usize = 0;
    for (layers, 0..) |l, i| if (@abs(l.z - z) < @abs(layers[best].z - z)) {
        best = i;
    };
    return best;
}

/// The support of one style. `kind` null: the support of the settings
/// (the overhangs by angle), with no support under the block marks.
/// Else: only the support under the marks of that kind, in its style.
fn computeStyle(
    gpa: Allocator,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    r: *const settings_mod.Resolved,
    threads: usize,
    marks: []const Mark,
    kind: ?Mark.Kind,
    cache: ?*Cache,
) anyerror![]SupportLayer {
    var p = r.settings.project;
    if (kind) |k| {
        p.support_style = switch (k) {
            .grid => .grid,
            .tree => .tree,
            .bridge => .bridge,
            .block, .area_on, .area_off => unreachable,
        };
        if (p.support == .off) p.support = .everywhere;
    } else if (p.support == .off) return &.{};
    var rs = r.*;
    rs.settings.project = p;
    const r_style = &rs;
    const n = outlines.len;
    const w = geom.fromMm(r.line_width);

    // Step 1: the overhangs, and the model moved out by the XY gap.
    const need = try gpa.alloc(Paths, n);
    for (need) |*x| x.* = .empty;
    var blocked = try gpa.alloc(Paths, n);
    for (blocked) |*x| x.* = .empty;
    var near = try gpa.alloc(Paths, n);
    for (near) |*x| x.* = .empty;
    // With a cache, `blocked` and `near` belong to the cache.
    var own_gaps = true;
    defer {
        for (need) |*x| x.deinit(gpa);
        gpa.free(need);
        if (own_gaps) {
            for (blocked) |*x| x.deinit(gpa);
            gpa.free(blocked);
            for (near) |*x| x.deinit(gpa);
            gpa.free(near);
        }
    }
    const Overhangs = struct {
        gpa: Allocator,
        outlines: []const Paths,
        layers: []const slicer.Layer,
        need: []Paths,
        blocked: []Paths,
        near: []Paths,
        tan_angle: f64,
        w: i64,
        xy: i64,
        xy_under: i64,
        /// The small-ledge limit (project.support_min_ledge), or 0: off.
        ledge: i64,

        fn run(c: *const @This(), i: usize) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(c.gpa);
            defer arena.deinit();
            const s = arena.allocator();
            c.blocked[i] = try offset_mod.offset(c.gpa, c.outlines[i], c.xy, .{});
            c.near[i] = try offset_mod.offset(c.gpa, c.outlines[i], c.xy_under, .{});
            if (i == 0) return;
            const d = geom.fromMm(c.layers[i].height * c.tan_angle);
            // The opening below removes strips thinner than 2 slivers. The
            // layer below moves out by that much less, so that a wall that
            // leans just over the angle keeps its strip.
            const below = try offset_mod.offset(s, c.outlines[i - 1], d - 3 * sliver, .{});
            const raw = try clip.difference(s, c.outlines[i], below);
            if (raw.isEmpty()) return;
            // Only slivers of the arithmetic go. A slope that leans a little
            // more than the angle gives a thin strip on each layer, and it
            // needs support too.
            const basic = try offset_mod.opening(s, raw, sliver, .{});
            if (basic.isEmpty()) return;
            // The full strip: the part of the layer that is not on the
            // layer below, next to the basic overhang. The strips of a
            // slope then cover its area with no gaps from layer to layer.
            const full = try clip.difference(s, c.outlines[i], c.outlines[i - 1]);
            const band = try offset_mod.offset(s, basic, d + @divTrunc(c.w, 4), .{});
            var strip = try clip.intersect(s, full, band);
            dropSmall(&strip, @divTrunc(c.w, 2));
            if (c.ledge > 0 and !strip.isEmpty()) strip = try c.dropLedges(s, i, strip, d);
            c.need[i] = try strip.clone(c.gpa);
        }

        /// Takes out the small ledges of layer i: each piece of the strip
        /// that is within `ledge` of the layer below at each point, with no
        /// new overhang of the layer above near it.
        fn dropLedges(c: *const @This(), s: Allocator, i: usize, strip: Paths, d: i64) !Paths {
            const reach = try offset_mod.offset(s, c.outlines[i - 1], c.ledge, .{});
            const far = try clip.difference(s, strip, reach);
            // The new overhang of the layer above (a slope goes on).
            var above: Paths = .empty;
            if (i + 1 < c.outlines.len) {
                // The same margin as the overhang of layer i (see run).
                const under = try offset_mod.offset(s, c.outlines[i], d - 3 * sliver, .{});
                above = try offset_mod.opening(s, try clip.difference(s, c.outlines[i + 1], under), sliver, .{});
            }
            var out: Paths = .empty;
            for (0..strip.count()) |k| {
                const poly = strip.get(k);
                var one: Paths = .empty;
                try one.append(s, poly);
                const small = blk: {
                    if (geom.area2(poly) < 0) break :blk false; // a hole stays with its piece
                    if (!(try clip.intersect(s, one, far)).isEmpty()) break :blk false;
                    if (above.isEmpty()) break :blk true;
                    const near_piece = try offset_mod.offset(s, one, c.ledge + d, .{});
                    break :blk (try clip.intersect(s, near_piece, above)).isEmpty();
                };
                if (!small) try out.append(s, poly);
            }
            return out;
        }
    };
    const angle = std.math.degreesToRadians(p.support_angle);
    const gap = p.support_z_gap_layers;
    const xy = geom.fromMm(p.support_xy_gap);
    // Under an overhang, the support comes nearer to the part than the XY
    // gap: the Z gap keeps it off the overhang, and a slope moves out by
    // less than the XY gap in two layers.
    const xy_under = @min(xy, @divTrunc(w, 2));
    // The small-ledge limit: 0 is 1.5 line widths; under 0.05 mm, off.
    const ledge: i64 = if (p.support_min_ledge == 0) @divTrunc(3 * w, 2) else if (p.support_min_ledge < 0.05) 0 else geom.fromMm(p.support_min_ledge);
    const step1_key = blk: {
        const c = cache orelse break :blk 0;
        var h = std.hash.Wyhash.init(c.outline_key);
        h.update(std.mem.asBytes(&[_]f64{ angle, @floatFromInt(xy), @floatFromInt(xy_under), @floatFromInt(w), @floatFromInt(n), @floatFromInt(ledge) }));
        break :blk h.final() | 1;
    };
    if (cache != null and cache.?.step1_key == step1_key) {
        const c = cache.?;
        for (need, c.need) |*x, cn| x.* = try cn.clone(gpa);
        gpa.free(blocked);
        gpa.free(near);
        blocked = c.blocked;
        near = c.near;
        own_gaps = false;
    } else {
        const oc: Overhangs = .{ .gpa = gpa, .outlines = outlines, .layers = layers, .need = need, .blocked = blocked, .near = near, .tan_angle = @tan(angle), .w = w, .xy = xy, .xy_under = xy_under, .ledge = ledge };
        try parallel.forEach(threads, n, &oc, Overhangs.run);
        if (cache) |c| {
            // The cache takes the gaps, and a copy of the overhangs.
            c.dropStep1(gpa);
            c.need = try gpa.alloc(Paths, n);
            for (c.need) |*x| x.* = .empty;
            for (c.need, need) |*x, nd| x.* = try nd.clone(gpa);
            c.blocked = blocked;
            c.near = near;
            c.step1_key = step1_key;
            own_gaps = false;
        }
    }

    // The marks: a block mark removes the overhang near it (2 mm up and
    // down); a mark of the kind of this pass replaces the overhangs with
    // the part of its disk that is not on the layer under it. An area of
    // the kind of this pass adds the surface in it that faces down, and a
    // block area removes the overhangs in it.
    {
        var arena_m = std.heap.ArenaAllocator.init(gpa);
        defer arena_m.deinit();
        const am = arena_m.allocator();
        if (kind) |k| {
            for (need) |*x| x.deinit(gpa);
            for (need) |*x| x.* = .empty;
            for (marks) |m| if (m.kind == k and m.poly.len > 0) try enforceArea(gpa, am, outlines, layers, need, m);
            // The first overhang at or above the layer of the mark, in its
            // disk: so a mark on the floor under an arch, or on a wall
            // under a shelf, supports the overhang over it.
            for (marks) |m| if (m.kind == k and m.poly.len == 0) {
                const d = try disk(am, m.x, m.y, m.r);
                var i = @max(1, layerAt(layers, m.z));
                while (i < n) : (i += 1) {
                    const on = try clip.intersect(am, outlines[i], d);
                    const free = try clip.difference(am, on, outlines[i - 1]);
                    if (free.areaMm2() < 0.2) continue;
                    const u = try clip.unite(gpa, need[i], free);
                    need[i].deinit(gpa);
                    need[i] = u;
                    break;
                }
            };
        } else {
            for (marks) |m| if (m.kind == .block and m.poly.len == 0) {
                const d = try disk(am, m.x, m.y, m.r);
                for (layers, 0..) |l, i| {
                    if (@abs(l.z - m.z) > 2 or need[i].isEmpty()) continue;
                    const rest = try clip.difference(gpa, need[i], d);
                    need[i].deinit(gpa);
                    need[i] = rest;
                }
            };
        }
        // A block area wins over the other marks and areas.
        for (marks) |m| if (m.kind == .block and m.poly.len > 0) {
            const area = try polygon(am, m.poly);
            const range = areaLayers(layers, m);
            for (range[0]..range[1]) |i| {
                if (need[i].isEmpty()) continue;
                const rest = try clip.difference(gpa, need[i], area);
                need[i].deinit(gpa);
                need[i] = rest;
            }
        };
    }

    // The overhangs moved out by one line width (`wide`). The columns and
    // the pads start from these areas. Under a slope, the strip of a layer
    // is thinner than a line, so it would not print; the wider area does,
    // and the XY gap cuts it back on the side of the part.
    const wide = try gpa.alloc(Paths, n);
    for (wide) |*x| x.* = .empty;
    defer {
        for (wide) |*x| x.deinit(gpa);
        gpa.free(wide);
    }
    const Widen = struct {
        gpa: Allocator,
        need: []const Paths,
        wide: []Paths,
        w: i64,
        fn run(c: *const @This(), i: usize) anyerror!void {
            if (c.need[i].isEmpty()) return;
            var x = try offset_mod.offset(c.gpa, c.need[i], c.w, .{});
            simplifyAll(&x, 20);
            c.wide[i] = x;
        }
    };
    const wc: Widen = .{ .gpa = gpa, .need = need, .wide = wide, .w = w };
    try parallel.forEach(threads, n, &wc, Widen.run);

    const out = try gpa.alloc(SupportLayer, n);
    for (out) |*x| x.* = .{};
    errdefer deinitAll(gpa, out);

    if (p.support_style == .tree) {
        try treeSupport(gpa, threads, outlines, layers, r_style, need, wide, blocked, near, out, if (cache) |c| &c.avoid else null, step1_key);
        return out;
    }
    if (p.support_style == .bridge) {
        try addPads(gpa, wide, near, p.support_z_gap_layers, @max(1, p.support_interface_layers), out);
        return out;
    }

    // Step 2: the columns, from the top down. Each layer depends on the
    // layer above, so this loop is on one thread. It does only the union
    // with the new overhangs and the difference with the model. The other
    // work is in steps 1 and 2b, on all threads.
    {
        var carry: Paths = .empty;
        defer carry.deinit(gpa);
        var j: usize = n - 1;
        while (j > 0) {
            j -= 1;
            const src = j + 1 + gap;
            const has_new = src < n and !wide[src].isEmpty();
            if (carry.isEmpty() and !has_new) continue;
            var area = if (has_new) try clip.unite(gpa, carry, wide[src]) else try carry.clone(gpa);
            defer area.deinit(gpa);
            // Only the part stops a column. The XY gap comes in step 2b:
            // under a slope, the area next to the part on this layer is
            // free again on the layers below.
            var next = try clip.difference(gpa, area, outlines[j]);
            // The carried area gets more points from each layer that it
            // passes. Support needs no micrometer precision, so 20 um of
            // simplification keeps the point count, and the time, low.
            simplifyAll(&next, 20);
            carry.deinit(gpa);
            carry = next;
            out[j].body = try carry.clone(gpa);
        }
    }

    // Step 2b: the Z gap above a model surface, and the removal of areas
    // thinner than a line width.
    const Clean = struct {
        gpa: Allocator,
        outlines: []const Paths,
        blocked: []const Paths,
        near: []const Paths,
        out: []SupportLayer,
        gap: usize,
        w: i64,

        fn run(c: *const @This(), j: usize) anyerror!void {
            if (c.out[j].body.isEmpty()) return;
            var arena = std.heap.ArenaAllocator.init(c.gpa);
            defer arena.deinit();
            const s = arena.allocator();
            // The XY gap: the full gap beside the part, and the smaller gap
            // where the part above (over the Z gap) covers the support.
            var area = try clip.difference(s, c.out[j].body, c.near[j]);
            var over: Paths = .empty;
            for (j + 1 + c.gap..j + 3 + c.gap) |q| {
                if (q < c.outlines.len) over = try clip.unite(s, over, c.outlines[q]);
            }
            const side = try clip.difference(s, c.blocked[j], over);
            area = try clip.difference(s, area, side);
            var k: usize = 1;
            while (k <= c.gap and k <= j) : (k += 1) {
                area = try clip.difference(s, area, c.outlines[j - k]);
            }
            const clean = try offset_mod.opening(s, area, @divTrunc(c.w, 2), .{});
            const kept = try clean.clone(c.gpa);
            c.out[j].body.deinit(c.gpa);
            c.out[j].body = kept;
        }
    };
    const cc: Clean = .{ .gpa = gpa, .outlines = outlines, .blocked = blocked, .near = near, .out = out, .gap = gap, .w = w };
    try parallel.forEach(threads, n, &cc, Clean.run);

    // Step 3: only columns that start on the bed.
    if (p.support == .buildplate) {
        for (1..n) |j| {
            if (out[j].body.isEmpty()) continue;
            const kept = try clip.intersect(gpa, out[j].body, out[j - 1].body);
            out[j].body.deinit(gpa);
            out[j].body = kept;
        }
    }

    // Step 4: the interface layers.
    if (p.support_interface_layers > 0) {
        const Interface = struct {
            gpa: Allocator,
            need: []const Paths,
            out: []SupportLayer,
            gap: usize,
            count: usize,

            fn run(c: *const @This(), j: usize) anyerror!void {
                if (c.out[j].body.isEmpty()) return;
                var arena = std.heap.ArenaAllocator.init(c.gpa);
                defer arena.deinit();
                const s = arena.allocator();
                var above: Paths = .empty;
                for (1..c.count + 1) |k| {
                    const src = j + c.gap + k;
                    if (src >= c.need.len) break;
                    if (!c.need[src].isEmpty()) above = try clip.unite(s, above, c.need[src]);
                }
                if (above.isEmpty()) return;
                const iface = try clip.intersect(s, c.out[j].body, above);
                if (iface.isEmpty()) return;
                const body = try clip.difference(s, c.out[j].body, iface);
                c.out[j].interface = try iface.clone(c.gpa);
                c.out[j].body.deinit(c.gpa);
                c.out[j].body = try body.clone(c.gpa);
            }
        };
        const ic: Interface = .{ .gpa = gpa, .need = wide, .out = out, .gap = gap, .count = p.support_interface_layers };
        try parallel.forEach(threads, n, &ic, Interface.run);
    }
    return out;
}

/// Tree support (see tree_support.zig): the pads of interface layers under
/// each overhang, and the branches under the pads.
fn treeSupport(
    gpa: Allocator,
    threads: usize,
    outlines: []const Paths,
    layers: []const slicer.Layer,
    r: *const settings_mod.Resolved,
    need: []const Paths,
    wide: []const Paths,
    blocked: []const Paths,
    near: []const Paths,
    out: []SupportLayer,
    avoid_cache: ?*tree.AvoidCache,
    step1_key: u64,
) !void {
    const p = r.settings.project;
    const gap = p.support_z_gap_layers;
    const pads = p.support_interface_layers;
    const tip_mm = if (p.support_tree_tip > 0) p.support_tree_tip else 2 * r.line_width;
    const params: tree.Params = .{
        .tip = @floatFromInt(geom.fromMm(tip_mm / 2)),
        // A trunk is at most 10 mm thick, and a branch gets 0.6 mm thicker
        // for each 10 mm that it goes down (and more where branches join).
        .max_r = @floatFromInt(geom.fromMm(@max(tip_mm, 10) / 2)),
        .growth = 0.1,
        .tan_angle = @tan(std.math.degreesToRadians(p.support_tree_angle)),
        .spacing = @floatFromInt(geom.fromMm(p.support_tree_spacing)),
        .z_gap = gap,
        .bed_only = p.support == .buildplate,
        // A branch is at least 5 mm thick on the bed.
        .foot = @floatFromInt(geom.fromMm(2.5)),
        // The bend rule (tree.Params.bend): a push of 0.3 N from the
        // nozzle, printed PLA at 2000 N/mm², one wall of a line width, and
        // a bend of at most 0.1 mm at the tip. A tip 30 mm up needs a
        // branch of about 4.4 mm across; 60 mm up, about 9 mm.
        .bend = 0.3 / (3 * 2000 * std.math.pi * r.line_width * 0.1),
        // The buckling rule (tree.Params.buckle): a push down of 2 N from
        // the nozzle on the pad, a safety factor of 2, and one wall.
        .buckle = 4 * 2.0 * 2.0 / (std.math.pow(f64, std.math.pi, 3) * 2000 * r.line_width),
        // The foot rule (tree.Params.peel): the push of 0.3 N at the top,
        // and a hold of 0.3 N/mm2 of the first layer on the bed.
        .peel = 4 * 0.3 / (std.math.pi * 0.3),
        // A branch is at least 2 mm thick under its tip layers.
        .min_r = @floatFromInt(geom.fromMm(1.0)),
        // The head of a tip: 3 layers that grow at 80 % of the branch
        // angle, so a tip of 0.8 mm is about 2 mm wide under its pad.
        .head_layers = 3,
        .head_grow = 0.8 * @as(f64, @floatFromInt(geom.fromMm(p.layer_height))) * @tan(std.math.degreesToRadians(p.support_tree_angle)),
    };
    const areas = try tree.growCached(gpa, threads, outlines, layers, need, blocked, near, 1 + gap + pads, params, avoid_cache, step1_key);
    defer gpa.free(areas.body);
    defer gpa.free(areas.filled);
    for (out, areas.body, areas.filled) |*o, b, f| {
        o.body = b;
        o.filled = f;
        o.hollow = true;
    }
    // The pads reach further out than the pads of grid support. The
    // interface lines miss a pad thinner than about two lines, and under a
    // slope the pad is a thin strip.
    const padsrc = try gpa.alloc(Paths, wide.len);
    for (padsrc) |*x| x.* = .empty;
    defer {
        for (padsrc) |*x| x.deinit(gpa);
        gpa.free(padsrc);
    }
    const Widen = struct {
        gpa: Allocator,
        wide: []const Paths,
        out: []Paths,
        w: i64,
        fn run(c: *const @This(), i: usize) anyerror!void {
            if (c.wide[i].isEmpty()) return;
            var x = try offset_mod.offset(c.gpa, c.wide[i], c.w, .{});
            simplifyAll(&x, 20);
            c.out[i] = x;
        }
    };
    const wc: Widen = .{ .gpa = gpa, .wide = wide, .out = padsrc, .w = @divTrunc(geom.fromMm(r.line_width) * pad_widen, 4) };
    try parallel.forEach(threads, wide.len, &wc, Widen.run);
    try addPads(gpa, padsrc, near, gap, pads, out);
    // A pad holds only where a branch or the part is under it. The parts
    // of a pad more than `reach` from the branches of the layer below go:
    // for example the pads of the branches that bed-only support removes.
    // A pad over the part keeps the Z gap, and rests on the part under
    // the gap.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const s = arena_state.allocator();
    // A pad reaches at most half a line past the branch under it: more
    // hangs in the air.
    const reach = @divTrunc(geom.fromMm(r.line_width), 2);
    for (1..out.len) |j| {
        if (out[j].interface.isEmpty()) continue;
        var pad = out[j].interface;
        var k: usize = 1;
        while (k <= gap and k <= j) : (k += 1) pad = try clip.difference(s, pad, outlines[j - k]);
        // A pad on a pad reaches only half a line past it: the lines of
        // the two pads end at the same place.
        const on_body = try offset_mod.offset(s, out[j - 1].body, reach, .{});
        // A pad on a pad also spans the gaps of the pad under it up to two
        // lines wide: the lines bridge them.
        const lw = geom.fromMm(r.line_width);
        const grown = try offset_mod.offset(s, out[j - 1].interface, lw, .{});
        const on_pad = try offset_mod.offset(s, grown, -@divTrunc(lw, 2), .{});
        var held = try clip.unite(s, on_body, on_pad);
        if (j >= gap + 1) held = try clip.unite(s, held, outlines[j - 1 - gap]);
        const kept = try clip.intersect(gpa, pad, held);
        out[j].interface.deinit(gpa);
        out[j].interface = kept;
    }
    // The bed layer: the wall loop of each foot, and dense interface lines
    // in it. The dense lines hold the foot on the bed, and the loop holds
    // the edge of a small foot, where the lines miss.
    if (out.len > 0 and !out[0].body.isEmpty()) {
        const inner = try offset_mod.offset(s, out[0].body, -@divTrunc(geom.fromMm(r.line_width), 2), .{});
        const u = try clip.unite(gpa, inner, out[0].interface);
        out[0].interface.deinit(gpa);
        out[0].interface = u;
        out[0].filled.deinit(gpa);
        out[0].filled = .empty;
    }
}

/// The pads: the overhang area, on the `pads` interface layers under each
/// overhang (under the Z gap), minus the part moved out by the XY gap
/// under an overhang (`near`). Tree support and bridge support use them.
fn addPads(gpa: Allocator, need: []const Paths, blocked: []const Paths, gap: usize, pads: usize, out: []SupportLayer) !void {
    const n = need.len;
    if (pads == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const s = arena_state.allocator();
    for (0..n) |src| {
        if (need[src].isEmpty()) continue;
        for (0..pads) |k| {
            const below = 1 + gap + k;
            if (below > src) break;
            const j = src - below;
            const pad = try clip.difference(s, need[src], blocked[j]);
            if (pad.isEmpty()) continue;
            const joined = try clip.unite(gpa, out[j].interface, pad);
            out[j].interface.deinit(gpa);
            out[j].interface = joined;
        }
    }
}

/// The pads of tree support reach this many quarter line widths further
/// out than the pads of grid support.
const pad_widen: i64 = 3;

/// The width of the slivers that the overhang test removes, in units.
const sliver: i64 = 10;

/// Removes the polygons (and holes) of a set with an area under the area
/// of a square of side `side` (units), in place.
fn dropSmall(paths: *Paths, side: i64) void {
    const min: i128 = 2 * @as(i128, side) * side;
    var out: usize = 0;
    var start: usize = 0;
    var kept: usize = 0;
    for (paths.ends.items) |end| {
        const poly = paths.points.items[start..end];
        start = end;
        if (@abs(geom.area2(poly)) < min) continue;
        std.mem.copyForwards(geom.Point, paths.points.items[out .. out + poly.len], poly);
        out += poly.len;
        paths.ends.items[kept] = @intCast(out);
        kept += 1;
    }
    paths.points.shrinkRetainingCapacity(out);
    paths.ends.shrinkRetainingCapacity(kept);
}

/// Simplifies each polygon of a set in place, and removes polygons with
/// fewer than 3 points.
pub fn simplifyAll(paths: *Paths, tolerance: i64) void {
    var out: usize = 0;
    var start: usize = 0;
    var kept: usize = 0;
    for (paths.ends.items) |end| {
        const poly = paths.points.items[start..end];
        const n = geom.simplifyClosed(poly, tolerance);
        start = end;
        if (n < 3) continue;
        std.mem.copyForwards(geom.Point, paths.points.items[out .. out + n], poly[0..n]);
        out += n;
        paths.ends.items[kept] = @intCast(out);
        kept += 1;
    }
    paths.points.shrinkRetainingCapacity(out);
    paths.ends.shrinkRetainingCapacity(kept);
}

const testing = std.testing;
const mesh_mod = @import("mesh.zig");

fn sliceAll(gpa: Allocator, m: *const mesh_mod.Mesh, height: f64) !struct { layers: []slicer.Layer, outlines: []Paths } {
    const layers = try slicer.layerTable(gpa, height, 0.3, 0.2);
    var idx = try slicer.FaceIndex.build(gpa, m, layers, 0);
    defer idx.deinit(gpa);
    const outlines = try gpa.alloc(Paths, layers.len);
    for (outlines, 0..) |*o, li| o.* = try slicer.sliceAt(gpa, m, idx.get(li), layers[li].sliceZ(), 5, 1000);
    return .{ .layers = layers, .outlines = outlines };
}

test "a mushroom gets support under its cap" {
    const gpa = testing.allocator;
    // A 4 x 4 mm post to z = 5, and a 20 x 20 mm cap from z = 5 to z = 7.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 4, &.{});
    defer deinitAll(gpa, sup);

    // Layer 24 (z 5.1) is the first layer of the cap. With a z gap of one
    // layer, layer 22 (z 4.7) is the top of the support: interface.
    try testing.expect(!sup[22].interface.isEmpty());
    try testing.expect(sup[23].body.isEmpty() and sup[23].interface.isEmpty());
    // Layer 10 is support body: the cap area (moved out by a line width)
    // minus the post and the gap.
    const xy = st.project.support_xy_gap;
    const cap = 20 + 2 * r.line_width;
    const want = cap * cap - (4 + 2 * xy) * (4 + 2 * xy);
    try testing.expectApproxEqRel(want, sup[10].body.areaMm2(), 0.03);
    // No support inside the cap or on the top.
    try testing.expect(sup[30].body.isEmpty());
}

test "support marks: a pad with support off, and a block" {
    const gpa = testing.allocator;
    // The mushroom of the test above: a cap from z 5 over a post.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    // Support off; a bridge mark under the cap near its corner (z of the
    // first cap layer).
    var st: settings_mod.Settings = .{};
    const r = try st.resolve();
    const z_cap = sl.layers[24].z;
    const marks = [_]Mark{.{ .x = 3, .y = 3, .z = z_cap, .r = 2, .kind = .bridge }};
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &marks);
    defer deinitAll(gpa, sup);
    // A pad under the mark (layer 22, under the z gap), and nothing below.
    try testing.expect(!sup[22].interface.isEmpty());
    try testing.expect(sup[22].interface.areaMm2() < 22); // the disk of 2 mm, moved out by a line width
    try testing.expect(sup[10].body.isEmpty() and sup[10].interface.isEmpty());

    // A mark on a layer under the cap (where the pad prints, not where the
    // overhang is) gives the same pad: it supports the overhang above it.
    const low = [_]Mark{.{ .x = 3, .y = 3, .z = sl.layers[10].z, .r = 2, .kind = .bridge }};
    const sup_low = try compute(gpa, sl.outlines, sl.layers, &r, 1, &low);
    defer deinitAll(gpa, sup_low);
    try testing.expectApproxEqAbs(sup[22].interface.areaMm2(), sup_low[22].interface.areaMm2(), 0.01);

    // Support on, with a block mark at the same corner: less support there.
    st.project.support = .everywhere;
    const r2 = try st.resolve();
    const all = try compute(gpa, sl.outlines, sl.layers, &r2, 1, &.{});
    defer deinitAll(gpa, all);
    const block = [_]Mark{.{ .x = 3, .y = 3, .z = z_cap, .r = 2, .kind = .block }};
    const less = try compute(gpa, sl.outlines, sl.layers, &r2, 1, &block);
    defer deinitAll(gpa, less);
    try testing.expect(less[10].body.areaMm2() < all[10].body.areaMm2() - 5);
}

test "support areas: a part with support on, and a part with support off" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    // Support off for the plate; the part has support on (a box around
    // its left half): support only in that box.
    var st: settings_mod.Settings = .{};
    const r = try st.resolve();
    const on = [_]Mark{.{ .x = 5, .y = 10, .z = 0, .hw = 5, .hh = 11, .kind = .area_on }};
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &on);
    defer deinitAll(gpa, sup);
    try testing.expect(sup.len > 0 and !sup[10].body.isEmpty());
    const box = sup[10].body.bounds();
    try testing.expect(geom.toMm(box.max.x) <= 10.01);
    // Support on for the plate; the part has support off: no support.
    st.project.support = .everywhere;
    const r2 = try st.resolve();
    const off = [_]Mark{.{ .x = 10, .y = 10, .z = 0, .hw = 11, .hh = 11, .kind = .area_off }};
    const none = try compute(gpa, sl.outlines, sl.layers, &r2, 1, &off);
    defer deinitAll(gpa, none);
    for (none) |l| try testing.expect(l.body.isEmpty() and l.interface.isEmpty());
}

test "support editor: an area under a slope of 30 degrees gets support" {
    const gpa = testing.allocator;
    // A cone that opens up with a wall at 30 degrees from vertical: under
    // the support angle, so the settings give it no support.
    const r1 = 5 + @tan(std.math.degreesToRadians(30.0)) * 10;
    var m = try mesh_mod.shapes.frustum(gpa, 30, 30, 5, r1, 10, 64);
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 10);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    // The right half of the slope, from z 1 to 9.
    const poly = [_][2]f64{ .{ 30, 15 }, .{ 45, 15 }, .{ 45, 45 }, .{ 30, 45 } };
    for ([_]Mark.Kind{ .grid, .tree }) |kind| {
        var st: settings_mod.Settings = .{};
        st.project.support = .everywhere;
        const r = try st.resolve();
        const none = try compute(gpa, sl.outlines, sl.layers, &r, 2, &.{});
        defer deinitAll(gpa, none);
        for (none) |l| try testing.expect(l.body.isEmpty() and l.interface.isEmpty());
        // Support on, and support off: the area gets support both times.
        for ([_]settings_mod.SupportMode{ .everywhere, .off }) |mode| {
            st.project.support = mode;
            const r2 = try st.resolve();
            const area = [_]Mark{.{ .x = 0, .y = 0, .z = 1, .z_hi = 9, .kind = kind, .poly = &poly }};
            const sup = try compute(gpa, sl.outlines, sl.layers, &r2, 2, &area);
            defer deinitAll(gpa, sup);
            const l = sup[25];
            try testing.expect(l.body.areaMm2() + l.interface.areaMm2() > 5);
            // Only under the right half (the left edge of the cone is at
            // x 22 on this layer).
            const box = try clip.unite(gpa, l.body, l.interface);
            defer @constCast(&box).deinit(gpa);
            try testing.expect(geom.toMm(box.bounds().min.x) > 28.5);
        }
    }
}

test "support editor: a block area removes the support of an overhang" {
    const gpa = testing.allocator;
    // The mushroom: a cap from z 5 over a post.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    for ([_]settings_mod.SupportStyle{ .grid, .tree }) |style| {
        var st: settings_mod.Settings = .{};
        st.project.support = .everywhere;
        st.project.support_style = style;
        const r = try st.resolve();
        // A block area over the whole cap, drawn on its bottom (z 5).
        const poly = [_][2]f64{ .{ -1, -1 }, .{ 21, -1 }, .{ 21, 21 }, .{ -1, 21 } };
        const block = [_]Mark{.{ .x = 0, .y = 0, .z = 5, .z_hi = 5, .kind = .block, .poly = &poly }};
        const sup = try compute(gpa, sl.outlines, sl.layers, &r, 2, &block);
        defer deinitAll(gpa, sup);
        for (sup) |l| try testing.expect(l.body.isEmpty() and l.interface.isEmpty());
        // A block area on the left half only: support on the right half.
        const half = [_][2]f64{ .{ -1, -1 }, .{ 10, -1 }, .{ 10, 21 }, .{ -1, 21 } };
        const left = [_]Mark{.{ .x = 0, .y = 0, .z = 4.9, .z_hi = 5.1, .kind = .block, .poly = &half }};
        const some = try compute(gpa, sl.outlines, sl.layers, &r, 2, &left);
        defer deinitAll(gpa, some);
        const l = some[22];
        try testing.expect(l.interface.areaMm2() + l.body.areaMm2() > 20);
        const box = try clip.unite(gpa, l.body, l.interface);
        defer @constCast(&box).deinit(gpa);
        try testing.expect(geom.toMm(box.bounds().min.x) > 9);
        // A block area at another height keeps the support.
        const high = [_]Mark{.{ .x = 0, .y = 0, .z = 6.5, .z_hi = 7, .kind = .block, .poly = &poly }};
        const same = try compute(gpa, sl.outlines, sl.layers, &r, 2, &high);
        defer deinitAll(gpa, same);
        try testing.expect(same[10].body.areaMm2() > 100 or same[10].interface.areaMm2() + same[22].interface.areaMm2() > 100);
    }
}

test "bed-only support skips a column that rests on the part" {
    const gpa = testing.allocator;
    // A wide base (0 to 2 mm), a post on it, and a cap. The support under
    // the cap rests on the base, not on the bed.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 2);
    try mesh_mod.shapes.addBox(&b, 8, 8, 2, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    var r = try st.resolve();
    const every = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, every);
    try testing.expect(!every[15].body.isEmpty());
    // The column stops above the base, with a one-layer gap: layer 9 (z
    // 2.1) is the first layer above the base, so it is empty.
    try testing.expect(every[9].body.isEmpty());

    st.project.support = .buildplate;
    r = try st.resolve();
    const bed = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, bed);
    for (bed) |l| try testing.expect(l.body.isEmpty() and l.interface.isEmpty());
}

test "tree support: branches under a cap, and a branch down a narrow hole" {
    const gpa = testing.allocator;
    // A post with a cap (as in the test of grid support).
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, sup);
    // The pads under the cap, and branches down to the bed.
    try testing.expect(!sup[22].interface.isEmpty() or !sup[21].interface.isEmpty());
    try testing.expect(!sup[1].body.isEmpty());
    // Branches use much less area than the grid support (400 - 23 mm2).
    const tree_area = sup[10].body.areaMm2();
    try testing.expect(tree_area > 1 and tree_area < 200);
    // No branch inside the post.
    for (sup) |l| {
        const inside = try clip.intersect(gpa, l.body, sl.outlines[5]);
        defer @constCast(&inside).deinit(gpa);
        try testing.expect(inside.areaMm2() < 0.01);
    }
}

test "a slope of 60 degrees gets support (grid and tree)" {
    const gpa = testing.allocator;
    // A cone that opens up: radius 5 mm on the bed, and a wall that leans
    // 60 degrees from vertical. The strip of each layer is thinner than a
    // line width, and the whole slope needs support.
    const r1 = 5 + @tan(std.math.degreesToRadians(60.0)) * 10;
    var m = try mesh_mod.shapes.frustum(gpa, 30, 30, 5, r1, 10, 64);
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 10);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    for ([_]settings_mod.SupportStyle{ .grid, .tree }) |style| {
        var st: settings_mod.Settings = .{};
        st.project.support = .everywhere;
        st.project.support_style = style;
        const r = try st.resolve();
        const sup = try compute(gpa, sl.outlines, sl.layers, &r, 2, &.{});
        defer deinitAll(gpa, sup);
        // Layer 25 (z 5.1): the cone is 5 + 8.8 mm in radius at the top of
        // the gap. The ring under the slope has support.
        const area = sup[25].body.areaMm2() + sup[25].interface.areaMm2();
        try testing.expect(area > 20);
    }
}

test "a wall that leans just over the support angle gets support" {
    const gpa = testing.allocator;
    // A cone that opens up with a wall at 51 degrees from vertical: one
    // degree over the angle. Each layer moves out by only 9 um more than
    // the limit.
    const r1 = 5 + @tan(std.math.degreesToRadians(51.0)) * 10;
    var m = try mesh_mod.shapes.frustum(gpa, 30, 30, 5, r1, 10, 64);
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 10);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 2, &.{});
    defer deinitAll(gpa, sup);
    try testing.expect(sup[25].body.areaMm2() + sup[25].interface.areaMm2() > 20);
}

test "tree pads under a slope are wide enough for the interface lines" {
    const gpa = testing.allocator;
    const r1 = 5 + @tan(std.math.degreesToRadians(55.0)) * 10;
    var m = try mesh_mod.shapes.frustum(gpa, 30, 30, 5, r1, 10, 64);
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 10);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 2, &.{});
    defer deinitAll(gpa, sup);
    // The pad of a layer, moved in by more than half a line, is still a
    // ring: the layer plan can put a line in it.
    const in = try offset_mod.offset(gpa, sup[25].interface, -geom.fromMm(0.35), .{});
    defer @constCast(&in).deinit(gpa);
    try testing.expect(in.areaMm2() > 5);
}

test "tree support: the bed layer prints a loop and interface lines" {
    const gpa = testing.allocator;
    // A plate a few layers over the bed, on a post.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 9, 9, 0, 11, 11, 0.65);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0.65, 20, 20, 3);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 3);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, sup);
    // Dense lines, and no support lines.
    try testing.expect(sup[0].hollow and sup[0].filled.isEmpty());
    try testing.expect(sup[0].interface.areaMm2() > 50);
}

test "tree support is hollow, and filled at the foot and under the tips" {
    const gpa = testing.allocator;
    // A post with a cap, 15 mm over the bed.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 15);
    try mesh_mod.shapes.addBox(&b, 0, 0, 15, 20, 20, 17);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 17);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, sup);
    // Layer 74 (z 15.1) is the first layer of the cap. The tips start 4
    // layers under it (the Z gap and 2 pads), on layer 70.
    for (sup[1..74]) |l| try testing.expect(l.hollow);
    // The foot: filled over the bed layer.
    try testing.expect(sup[2].filled.areaMm2() > 0.5 * sup[2].body.areaMm2());
    // Under the tips: filled.
    try testing.expect(!sup[69].filled.isEmpty());
    // The middle: a wall loop only.
    try testing.expect(!sup[40].body.isEmpty());
    try testing.expect(sup[40].filled.areaMm2() < 0.1 * sup[40].body.areaMm2());
}

test "tree support: a branch beside a tall wall is thick, and thicker down low" {
    const gpa = testing.allocator;
    // A wall 50 mm high, with a shelf at 40 mm that sticks out 8 mm from
    // its face. The branches under the shelf go down beside the wall.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 40, 4, 50);
    try mesh_mod.shapes.addBox(&b, 5, 4, 40, 35, 12, 43);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 50);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, sup);
    // The thinnest piece of each layer, and the mean area of a piece.
    const Stat = struct { min: f64, mean: f64 };
    const stat = struct {
        fn of(p: geom.Paths) Stat {
            var lo: f64 = std.math.inf(f64);
            var sum: f64 = 0;
            var n: f64 = 0;
            for (0..p.count()) |i| {
                const a = geom.areaMm2(p.get(i));
                if (a <= 0) continue; // a hole
                lo = @min(lo, a);
                sum += a;
                n += 1;
            }
            return .{ .min = lo, .mean = if (n > 0) sum / n else 0 };
        }
    }.of;
    // Under the tip layers, no piece is thinner than a disk of 2 mm
    // (3.1 mm2). Before the bend rule, branches beside the wall were one
    // or two lines wide all the way down.
    var low: Stat = undefined;
    var high: Stat = undefined;
    for (sup, 0..) |l, i| {
        const z = sl.layers[i].z;
        if (z < 2 or z > 36 or l.body.isEmpty()) continue;
        const s = stat(l.body);
        try testing.expect(s.min > 3);
        if (i == 25) low = s;
        if (i == 170) high = s;
    }
    // The bend rule: the branches are thicker at 5 mm than at 34 mm.
    try testing.expect(low.mean > high.mean);
}

/// The area (mm2) and the centroid (mm) of the part of `paths` in the
/// band x0 <= x <= x1, for the tests of equal support.
const BandStat = struct { area: f64, cx: f64, cy: f64 };
fn bandStat(a: Allocator, paths: Paths, x0: f64, x1: f64) !BandStat {
    var box: Paths = .empty;
    try box.append(a, &.{ .init(geom.fromMm(x0), -geom.fromMm(1000)), .init(geom.fromMm(x1), -geom.fromMm(1000)), .init(geom.fromMm(x1), geom.fromMm(1000)), .init(geom.fromMm(x0), geom.fromMm(1000)) });
    const part = try clip.intersect(a, paths, box);
    var s: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (0..part.count()) |k| {
        const poly = part.get(k);
        for (poly, 0..) |p, i| {
            const q = poly[(i + 1) % poly.len];
            const px = geom.toMm(p.x);
            const py = geom.toMm(p.y);
            const qx = geom.toMm(q.x);
            const qy = geom.toMm(q.y);
            const c = px * qy - qx * py;
            s += c;
            sx += (px + qx) * c;
            sy += (py + qy) * c;
        }
    }
    if (@abs(s) < 1e-9) return .{ .area = 0, .cx = 0, .cy = 0 };
    return .{ .area = s / 2, .cx = sx / (3 * s), .cy = sy / (3 * s) };
}

/// The support of each layer as one set (body and interface).
fn supportOf(a: Allocator, l: SupportLayer) !Paths {
    return clip.unite(a, l.body, l.interface);
}

test "tree support: two equal ledges get equal trees" {
    const gpa = testing.allocator;
    // A wall 60 x 4 x 50 mm, and two equal ledges at z 40 that stick out
    // 8 mm from its face: x 8 to 22 and x 38 to 52. The right ledge is the
    // left ledge moved by 30 mm, and the mirror of it about x = 30.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 60, 4, 50);
    try mesh_mod.shapes.addBox(&b, 8, 4, 40, 22, 12, 43);
    try mesh_mod.shapes.addBox(&b, 38, 4, 40, 52, 12, 43);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 50);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    // One thread and four threads give the same support.
    for ([_]usize{ 1, 4 }) |threads| {
        const sup = try compute(gpa, sl.outlines, sl.layers, &r, threads, &.{});
        defer deinitAll(gpa, sup);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var layers_with: usize = 0;
        for (sup) |l| {
            const all = try supportOf(a, l);
            const left = try bandStat(a, all, -10, 30);
            const right = try bandStat(a, all, 30, 70);
            if (left.area + right.area < 0.01) continue;
            layers_with += 1;
            // Moved: the same area, and the centroid 30 mm to the right.
            try testing.expectApproxEqAbs(left.area, right.area, 0.02 * @max(left.area, right.area) + 0.05);
            if (left.area < 0.05) continue;
            try testing.expectApproxEqAbs(left.cx + 30, right.cx, 0.1);
            try testing.expectApproxEqAbs(left.cy, right.cy, 0.1);
            // Each tree is the mirror of itself about the middle of its
            // ledge (x 15 and x 45).
            const ll = try bandStat(a, all, -10, 15);
            const lr = try bandStat(a, all, 15, 30);
            try testing.expectApproxEqAbs(ll.area, lr.area, 0.02 * left.area + 0.05);
        }
        try testing.expect(layers_with > 150);
    }
}

test "tree support: a mirrored part gets mirrored support" {
    const gpa = testing.allocator;
    // A post, an L-shaped shelf on it at z 20, and a small cap at z 12:
    // no symmetry. The second part is the mirror of the first about x = 0.
    var parts: [2]mesh_mod.Mesh = undefined;
    for (0..2) |k| {
        const sx: f64 = if (k == 0) 1 else -1;
        var b: mesh_mod.Builder = .init(gpa);
        const boxes = [_][6]f64{
            .{ 2, 2, 0, 6, 6, 23 },
            .{ 2, 2, 20, 20, 8, 23 },
            .{ 2, 2, 20, 8, 16, 23 },
            .{ 6, 4, 12, 11, 7, 13 },
        };
        for (boxes) |bx| {
            const x0 = @min(sx * bx[0], sx * bx[3]);
            const x1 = @max(sx * bx[0], sx * bx[3]);
            try mesh_mod.shapes.addBox(&b, x0 + 30, bx[1] + 10, bx[2], x1 + 30, bx[4] + 10, bx[5]);
        }
        parts[k] = try b.finish();
    }
    defer for (&parts) |*p| p.deinit(gpa);
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    var stats: [2][]BandStat = undefined;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..2) |k| {
        const sl = try sliceAll(gpa, &parts[k], 23);
        defer {
            for (sl.outlines) |*o| o.deinit(gpa);
            gpa.free(sl.outlines);
            gpa.free(sl.layers);
        }
        const sup = try compute(gpa, sl.outlines, sl.layers, &r, 2, &.{});
        defer deinitAll(gpa, sup);
        stats[k] = try a.alloc(BandStat, sup.len);
        for (sup, stats[k]) |l, *s| s.* = try bandStat(a, try supportOf(a, l), -100, 200);
    }
    try testing.expectEqual(stats[0].len, stats[1].len);
    var with: usize = 0;
    for (stats[0], stats[1]) |p, q| {
        try testing.expectApproxEqAbs(p.area, q.area, 0.02 * @max(p.area, q.area) + 0.05);
        if (p.area < 0.05) continue;
        with += 1;
        // Mirrored about x = 30.
        try testing.expectApproxEqAbs(p.cx - 30, 30 - q.cx, 0.1);
        try testing.expectApproxEqAbs(p.cy, q.cy, 0.1);
    }
    try testing.expect(with > 50);
}

test "tree support: each layer of a branch stands on the layer under it" {
    const gpa = testing.allocator;
    // The wall with the two ledges, and a small ledge lower down under the
    // left one: the branches of the left ledge go around it.
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 60, 4, 50);
    try mesh_mod.shapes.addBox(&b, 8, 4, 40, 22, 12, 43);
    try mesh_mod.shapes.addBox(&b, 38, 4, 40, 52, 12, 43);
    try mesh_mod.shapes.addBox(&b, 12, 4, 24, 18, 9, 26);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 50);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 2, &.{});
    defer deinitAll(gpa, sup);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The body of a layer, out of the support, the part, and the pads of
    // the layer under it moved out by one step of the branch angle (and a
    // tenth of a millimeter): it hangs in the air.
    const step = 0.2 * @tan(std.math.degreesToRadians(st.project.support_tree_angle)) + 0.1;
    var worst: f64 = 0;
    for (sup[2..], 2..) |l, i| {
        if (l.body.isEmpty()) continue;
        var under = try clip.unite(a, sup[i - 1].body, sup[i - 1].interface);
        under = try clip.unite(a, under, sl.outlines[i - 1]);
        const grown = try offset_mod.offset(a, under, geom.fromMm(step), .{});
        const hang = try clip.difference(a, l.body, grown);
        worst = @max(worst, hang.areaMm2());
    }
    try testing.expect(worst < 0.5);
}

test "support cache: the same support as with no cache, after a change of the marks" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 5);
    try mesh_mod.shapes.addBox(&b, 0, 0, 5, 20, 20, 7);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 7);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var cache: Cache = .{ .outline_key = 1234 };
    defer cache.deinit(gpa);
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 10, -1 }, .{ 10, 21 }, .{ -1, 21 } };
    for ([_]settings_mod.SupportStyle{ .grid, .tree }) |style| {
        var st: settings_mod.Settings = .{};
        st.project.support = .everywhere;
        st.project.support_style = style;
        const r = try st.resolve();
        // No marks, a block area, the block area at another height, and
        // no marks again (the result of the cache).
        const sets = [_][]const Mark{
            &.{},
            &.{.{ .x = 0, .y = 0, .z = 4.9, .z_hi = 5.1, .kind = .block, .poly = &poly }},
            &.{.{ .x = 0, .y = 0, .z = 6.5, .z_hi = 7, .kind = .block, .poly = &poly }},
            &.{},
        };
        for (sets) |marks| {
            const want = try compute(gpa, sl.outlines, sl.layers, &r, 2, marks);
            defer deinitAll(gpa, want);
            const got = try computeCached(gpa, sl.outlines, sl.layers, &r, 2, marks, &cache);
            defer deinitAll(gpa, got);
            try testing.expectEqual(want.len, got.len);
            for (want, got) |x, y| {
                try testing.expectApproxEqAbs(x.body.areaMm2(), y.body.areaMm2(), 1e-9);
                try testing.expectApproxEqAbs(x.interface.areaMm2(), y.interface.areaMm2(), 1e-9);
                try testing.expectApproxEqAbs(x.filled.areaMm2(), y.filled.areaMm2(), 1e-9);
            }
        }
    }
}

test "tree pads touch the cap, cover it, and stand on the branches" {
    const gpa = testing.allocator;
    // A post with a cap 15 mm over the bed (a user saw pads that did not
    // touch the part, and pads that hung past their branches).
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 8, 8, 0, 12, 12, 15);
    try mesh_mod.shapes.addBox(&b, 0, 0, 15, 20, 20, 17);
    var m = try b.finish();
    defer m.deinit(gpa);
    const sl = try sliceAll(gpa, &m, 17);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    st.project.support_style = .tree;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, sup);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // 1. The top pad is right under the Z gap: layer 74 is the first layer
    // of the cap, layer 73 the gap.
    const cap: usize = 74;
    try testing.expect(sl.outlines[cap].areaMm2() > 300 and sl.outlines[cap - 1].areaMm2() < 20);
    const gap = st.project.support_z_gap_layers;
    try testing.expect(!sup[cap - 1 - gap].interface.isEmpty());
    for (cap - gap..cap) |i| try testing.expect(sup[i].interface.isEmpty() and sup[i].body.isEmpty());
    // 2. The top pad covers the overhang: the cap minus the post and its
    // XY gap, all but a thin rim.
    const post = try offset_mod.offset(a, sl.outlines[cap - 1], geom.fromMm(st.project.support_xy_gap), .{});
    const over = try clip.difference(a, sl.outlines[cap], post);
    const bare = try clip.difference(a, over, sup[cap - 1 - gap].interface);
    try testing.expect(bare.areaMm2() < 0.07 * over.areaMm2());
    // 3. No pad reaches more than half a line past the support or the pad
    // under it (with a little room for the circles). A pad on a pad spans
    // the gaps of the pad under it up to two lines wide.
    const lw = geom.fromMm(r.line_width);
    for (1..cap) |i| {
        if (sup[i].interface.isEmpty()) continue;
        const pad = try offset_mod.offset(a, try offset_mod.offset(a, sup[i - 1].interface, lw, .{}), -@divTrunc(lw, 2) + 50, .{});
        const body = try offset_mod.offset(a, sup[i - 1].body, @divTrunc(lw, 2) + 50, .{});
        const held = try clip.unite(a, pad, body);
        const hang = try clip.difference(a, sup[i].interface, held);
        try testing.expect(hang.areaMm2() < 0.1);
    }
}

test "small ledges: an embossed letter gets no support, a shelf and a slope keep it" {
    const gpa = testing.allocator;
    const Case = struct { boxes: []const [6]f64, height: f64, want_support: bool };
    const cases = [_]Case{
        // A wall with a letter 0.6 mm out of its face, from z 10 to 15.
        .{ .boxes = &.{ .{ 0, 0, 0, 40, 4, 30 }, .{ 10, 4, 10, 20, 4.6, 15 } }, .height = 30, .want_support = false },
        // A shelf 6 mm out of the face: it needs support.
        .{ .boxes = &.{ .{ 0, 0, 0, 40, 4, 30 }, .{ 10, 4, 10, 20, 10, 15 } }, .height = 30, .want_support = true },
    };
    for (cases) |cs| {
        var b: mesh_mod.Builder = .init(gpa);
        for (cs.boxes) |x| try mesh_mod.shapes.addBox(&b, x[0], x[1], x[2], x[3], x[4], x[5]);
        var m = try b.finish();
        defer m.deinit(gpa);
        const sl = try sliceAll(gpa, &m, cs.height);
        defer {
            for (sl.outlines) |*o| o.deinit(gpa);
            gpa.free(sl.outlines);
            gpa.free(sl.layers);
        }
        var st: settings_mod.Settings = .{};
        st.project.support = .everywhere;
        const r = try st.resolve();
        const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
        defer deinitAll(gpa, sup);
        var area: f64 = 0;
        for (sup) |l| area += l.body.areaMm2() + l.interface.areaMm2();
        try testing.expectEqual(cs.want_support, area > 1);
    }
    // A slope that leans 70 degrees from vertical (a cone that opens up):
    // each layer adds a thin strip, and it keeps its support.
    const r1 = 5 + @tan(std.math.degreesToRadians(70.0)) * 6;
    var cone = try mesh_mod.shapes.frustum(gpa, 30, 30, 5, r1, 6, 64);
    defer cone.deinit(gpa);
    const sl = try sliceAll(gpa, &cone, 6);
    defer {
        for (sl.outlines) |*o| o.deinit(gpa);
        gpa.free(sl.outlines);
        gpa.free(sl.layers);
    }
    var st: settings_mod.Settings = .{};
    st.project.support = .everywhere;
    const r = try st.resolve();
    const sup = try compute(gpa, sl.outlines, sl.layers, &r, 1, &.{});
    defer deinitAll(gpa, sup);
    var area: f64 = 0;
    for (sup) |l| area += l.body.areaMm2();
    try testing.expect(area > 10);
}
