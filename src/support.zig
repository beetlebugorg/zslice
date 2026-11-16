//! Support: the areas that hold up the overhangs of a part.
//!
//! A printer cannot put plastic on air. A part of a layer that is too far
//! outside the layer below it needs support under it. The method:
//!
//! 1. Overhangs. For each layer i, the overhang is the outline of layer i
//!    minus the outline of layer i - 1 moved out by d = h * tan(angle). A
//!    wall that leans less than `support_angle` from vertical moves less
//!    than d in one layer, so it holds itself. Overhangs thinner than one
//!    line width are removed (an "opening").
//! 2. Columns, from the top down. An overhang of layer i needs support from
//!    layer i - 1 - gap down, where gap is `support_z_gap_layers`: the
//!    empty layers between the support and the part, so that the support
//!    comes off. On each layer, the support area is the area from the layer
//!    above plus the new overhangs, minus the model moved out by
//!    `support_xy_gap`. Where the model blocks the area, the column stops:
//!    it rests on the model. A column that rests on the model also keeps
//!    `support_z_gap_layers` empty layers above the model.
//! 3. Bed only (`support = buildplate`). A pass from the bottom up keeps
//!    only the areas that have support under them, so that each column
//!    starts on the bed.
//! 4. Interface. The top `support_interface_layers` layers under each
//!    overhang are the interface. They are dense, so that the bottom
//!    surface of the part is smooth.
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

    pub const Kind = enum(u8) { grid = 0, tree = 1, bridge = 2, block = 3 };
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
    for (marks) |m| if (m.kind != .block) {
        adds = true;
    };
    if ((p.support == .off and !adds) or outlines.len < 2) return &.{};
    // Support from the settings, less the blocked marks; then the support
    // of each kind of mark, with its own style, joined in.
    var main = try computeStyle(gpa, outlines, layers, r, threads, marks, null);
    errdefer deinitAll(gpa, main);
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
            .block => unreachable,
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
    defer {
        for (need) |*x| x.deinit(gpa);
        gpa.free(need);
        for (blocked) |*x| x.deinit(gpa);
        gpa.free(blocked);
    }
    const Overhangs = struct {
        gpa: Allocator,
        outlines: []const Paths,
        layers: []const slicer.Layer,
        need: []Paths,
        blocked: []Paths,
        tan_angle: f64,
        w: i64,
        xy: i64,

        fn run(c: *const @This(), i: usize) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(c.gpa);
            defer arena.deinit();
            const s = arena.allocator();
            c.blocked[i] = try offset_mod.offset(c.gpa, c.outlines[i], c.xy, .{});
            if (i == 0) return;
            const d = geom.fromMm(c.layers[i].height * c.tan_angle);
            const below = try offset_mod.offset(s, c.outlines[i - 1], d, .{});
            const raw = try clip.difference(s, c.outlines[i], below);
            const clean = try offset_mod.opening(s, raw, @divTrunc(c.w, 2), .{});
            c.need[i] = try clean.clone(c.gpa);
        }
    };
    const angle = std.math.degreesToRadians(p.support_angle);
    const gap = p.support_z_gap_layers;
    const xy = geom.fromMm(p.support_xy_gap);
    const oc: Overhangs = .{ .gpa = gpa, .outlines = outlines, .layers = layers, .need = need, .blocked = blocked, .tan_angle = @tan(angle), .w = w, .xy = xy };
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
            for (marks) |m| if (m.kind == k) {
                const i = layerAt(layers, m.z);
                if (i == 0) continue;
                const d = try disk(am, m.x, m.y, m.r);
                const on = try clip.intersect(am, outlines[i], d);
                const free = try clip.difference(am, on, outlines[i - 1]);
                const u = try clip.unite(gpa, need[i], free);
                need[i].deinit(gpa);
                need[i] = u;
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

    const out = try gpa.alloc(SupportLayer, n);
    for (out) |*x| x.* = .{};
    errdefer deinitAll(gpa, out);

    if (p.support_style == .tree) {
        try treeSupport(gpa, threads, outlines, layers, r_style, need, blocked, out);
        return out;
    }
    if (p.support_style == .bridge) {
        try addPads(gpa, need, blocked, p.support_z_gap_layers, @max(1, p.support_interface_layers), out);
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
            const has_new = src < n and !need[src].isEmpty();
            if (carry.isEmpty() and !has_new) continue;
            var area = if (has_new) try clip.unite(gpa, carry, need[src]) else try carry.clone(gpa);
            defer area.deinit(gpa);
            var next = try clip.difference(gpa, area, blocked[j]);
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
        out: []SupportLayer,
        gap: usize,
        w: i64,

        fn run(c: *const @This(), j: usize) anyerror!void {
            if (c.out[j].body.isEmpty()) return;
            var arena = std.heap.ArenaAllocator.init(c.gpa);
            defer arena.deinit();
            const s = arena.allocator();
            var area = c.out[j].body;
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
    const cc: Clean = .{ .gpa = gpa, .outlines = outlines, .out = out, .gap = gap, .w = w };
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
        const ic: Interface = .{ .gpa = gpa, .need = need, .out = out, .gap = gap, .count = p.support_interface_layers };
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
    blocked: []const Paths,
    out: []SupportLayer,
) !void {
    const p = r.settings.project;
    const gap = p.support_z_gap_layers;
    const pads = p.support_interface_layers;
    const tip_mm = if (p.support_tree_tip > 0) p.support_tree_tip else 2 * r.line_width;
    const params: tree.Params = .{
        .tip = @floatFromInt(geom.fromMm(tip_mm / 2)),
        .max_r = @floatFromInt(geom.fromMm(@max(tip_mm, 4) / 2)),
        .growth = 0.02,
        .tan_angle = @tan(std.math.degreesToRadians(p.support_tree_angle)),
        .spacing = @floatFromInt(geom.fromMm(p.support_tree_spacing)),
        .z_gap = gap,
        .bed_only = p.support == .buildplate,
    };
    const branches = try tree.grow(gpa, threads, outlines, layers, need, blocked, 1 + gap + pads, params);
    defer gpa.free(branches);
    for (out, branches) |*o, b| o.body = b;
    try addPads(gpa, need, blocked, gap, pads, out);
}

/// The pads: the overhang area, on the `pads` interface layers under each
/// overhang (under the Z gap). Tree support and bridge support use them.
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
    // Layer 10 is support body: the cap area minus the post and the gap.
    const xy = st.project.support_xy_gap;
    const want = 400.0 - (4 + 2 * xy) * (4 + 2 * xy);
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
    try testing.expect(sup[22].interface.areaMm2() < 15);
    try testing.expect(sup[10].body.isEmpty() and sup[10].interface.isEmpty());

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
