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
//! under it. A pad on the bed layer prints as the body.
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

    /// `area_on` and `area_off` come from the settings of one part (see
    /// part_settings.zig): support in its box with support off for the
    /// plate, or no support in its box.
    pub const Kind = enum(u8) { grid = 0, tree = 1, bridge = 2, block = 3, area_on = 4, area_off = 5 };
};

pub const SupportLayer = struct {
    body: Paths = .empty,
    interface: Paths = .empty,

    pub fn deinit(self: *SupportLayer, gpa: Allocator) void {
        self.body.deinit(gpa);
        self.interface.deinit(gpa);
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
    var main = try computeStyle(gpa, outlines, layers, &rr, threads, marks, null);
    errdefer deinitAll(gpa, main);
    if (only_on or (p.support != .off and off_area)) try clipToAreas(gpa, main, marks, only_on);
    for ([_]Mark.Kind{ .grid, .tree, .bridge }) |kind| {
        var has = false;
        for (marks) |m| if (m.kind == kind) {
            has = true;
        };
        if (!has) continue;
        const extra = try computeStyle(gpa, outlines, layers, r, threads, marks, kind);
        defer deinitAll(gpa, extra);
        if (extra.len == 0) continue;
        if (main.len == 0) {
            main = try gpa.alloc(SupportLayer, extra.len);
            for (main) |*x| x.* = .{};
        }
        for (main, extra) |*a, b| {
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
    const blocked = try gpa.alloc(Paths, n);
    for (blocked) |*x| x.* = .empty;
    const near = try gpa.alloc(Paths, n);
    for (near) |*x| x.* = .empty;
    defer {
        for (need) |*x| x.deinit(gpa);
        gpa.free(need);
        for (blocked) |*x| x.deinit(gpa);
        gpa.free(blocked);
        for (near) |*x| x.deinit(gpa);
        gpa.free(near);
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
            c.need[i] = try strip.clone(c.gpa);
        }
    };
    const angle = std.math.degreesToRadians(p.support_angle);
    const gap = p.support_z_gap_layers;
    const xy = geom.fromMm(p.support_xy_gap);
    // Under an overhang, the support comes nearer to the part than the XY
    // gap: the Z gap keeps it off the overhang, and a slope moves out by
    // less than the XY gap in two layers.
    const xy_under = @min(xy, @divTrunc(w, 2));
    const oc: Overhangs = .{ .gpa = gpa, .outlines = outlines, .layers = layers, .need = need, .blocked = blocked, .near = near, .tan_angle = @tan(angle), .w = w, .xy = xy, .xy_under = xy_under };
    try parallel.forEach(threads, n, &oc, Overhangs.run);

    // The marks: a block mark removes the overhang near it (2 mm up and
    // down); a mark of the kind of this pass replaces the overhangs with
    // the part of its disk that is not on the layer under it.
    {
        var arena_m = std.heap.ArenaAllocator.init(gpa);
        defer arena_m.deinit();
        const am = arena_m.allocator();
        if (kind) |k| {
            for (need) |*x| x.deinit(gpa);
            for (need) |*x| x.* = .empty;
            // The first overhang at or above the layer of the mark, in its
            // disk: so a mark on the floor under an arch, or on a wall
            // under a shelf, supports the overhang over it.
            for (marks) |m| if (m.kind == k) {
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
            for (marks) |m| if (m.kind == .block) {
                const d = try disk(am, m.x, m.y, m.r);
                for (layers, 0..) |l, i| {
                    if (@abs(l.z - m.z) > 2 or need[i].isEmpty()) continue;
                    const rest = try clip.difference(gpa, need[i], d);
                    need[i].deinit(gpa);
                    need[i] = rest;
                }
            };
        }
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
        try treeSupport(gpa, threads, outlines, layers, r_style, need, wide, blocked, near, out);
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
        .growth = 0.06,
        .tan_angle = @tan(std.math.degreesToRadians(p.support_tree_angle)),
        .spacing = @floatFromInt(geom.fromMm(p.support_tree_spacing)),
        .z_gap = gap,
        .bed_only = p.support == .buildplate,
    };
    const branches = try tree.grow(gpa, threads, outlines, layers, need, blocked, near, 1 + gap + pads, params);
    defer gpa.free(branches);
    for (out, branches) |*o, b| o.body = b;
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
    // of a pad more than `reach` from the support of the layer below go:
    // for example the pads of the branches that bed-only support removes.
    // A pad over the part keeps the Z gap, and rests on the part under
    // the gap.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const s = arena_state.allocator();
    const reach = @min(geom.fromMm(p.support_tree_spacing), geom.fromMm(2.5 * r.line_width));
    for (1..out.len) |j| {
        if (out[j].interface.isEmpty()) continue;
        var pad = out[j].interface;
        var k: usize = 1;
        while (k <= gap and k <= j) : (k += 1) pad = try clip.difference(s, pad, outlines[j - k]);
        const below = try clip.unite(s, out[j - 1].body, out[j - 1].interface);
        var held = try offset_mod.offset(s, below, reach, .{});
        if (j >= gap + 1) held = try clip.unite(s, held, outlines[j - 1 - gap]);
        const kept = try clip.intersect(gpa, pad, held);
        out[j].interface.deinit(gpa);
        out[j].interface = kept;
    }
    // A pad on the bed layer prints as the body, so that the pad of the
    // layer above has lines under it.
    if (out.len > 0 and !out[0].interface.isEmpty()) {
        const u = try clip.unite(gpa, out[0].body, out[0].interface);
        out[0].body.deinit(gpa);
        out[0].body = u;
        out[0].interface.deinit(gpa);
        out[0].interface = .empty;
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
const pad_widen: i64 = 4;

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

test "tree support: a pad on the bed layer prints as the body" {
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
    try testing.expect(sup[0].interface.isEmpty());
    try testing.expect(sup[0].body.areaMm2() > 50);
}
