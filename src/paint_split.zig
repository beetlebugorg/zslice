//! The split of the layers of a painted part into the filaments of its
//! paint (see paint.zig).
//!
//! Each painted triangle (or piece of a triangle) colors the layers that
//! it touches:
//!
//! - A steep triangle crosses the cut plane of a layer in a segment. The
//!   edge of the outline splits into pieces of one line width, and each
//!   piece has the state of the nearest painted segment within one line
//!   width, else the filament of the part. A grid of the segments makes
//!   each lookup short.
//! - A flat triangle that faces up colors the layers under it, down to the
//!   top thickness of the part; a flat triangle that faces down colors the
//!   layers over it, up to the bottom thickness. Its shape, seen from
//!   above, is a source of its state. So a painted top face prints its
//!   color in its top layers.
//!
//! Each point of the outline then gets the color of the nearest source,
//! as PrusaSlicer and Bambu Studio do it (they use a Voronoi diagram of
//! the colored edges). zslice uses a distance field on a grid of half a
//! line width (see field.zig): each piece of the edge and each flat
//! shape writes its distance to the nodes around it, the nearest state
//! of a node is its label, and the borders between the labels are the
//! regions. The cost is one pass over the nodes near the sources, with
//! no polygon offset. Deeper than `depth` (about 2 mm) from the painted
//! sources, each point is of the filament of the part: the color shows
//! on the surface, and the core of a wide region does not show. A
//! painted top still prints its color in its top layers (see above). A
//! layer with no paint near it is all of the filament of the part.
//!
//! Two rules clean the labels (see `cleanLabels`): a group of nodes too
//! small for a bead gets the label around it, and a core with paint all
//! around it gets that paint, so a wide painted letter prints in one
//! filament.
//!
//! Each filament of the part then slices as its own job, with the region
//! of its filament as the outline of each layer (see plate_job.zig). So
//! each region gets its own walls and infill, with its own filament.
//!
//! The labels of a part (label.zig) come last, each with a state of its
//! own. A label is a 2D shape in a plane on the part. On each layer, the
//! prism of the shape along the normal of the label (over the range of
//! the surface under it) meets the plane of the layer. The part of that
//! cut within the depth of the label from the outline of the layer (the
//! skin band) is the region of the label. A top or bottom label colors
//! the top or bottom layers under its shape. The region of a label wins
//! over the paint and the roots (see `Split.labelLayer`).
//!
//! A raised or cut label (label.Mode) also changes the outline. A cut
//! label removes its shape from the layers within its relief of the
//! surface: the same prism, in a band of the relief. The floor of a cut
//! in a top or bottom face gets skin (see `Split.removed`). A raised
//! label on a side face adds the prism out of the surface, within the
//! relief of the outline (the outline grown by the relief, less the
//! outline). A raised label on a top face is a plateau: walls of its
//! shape go into the mesh of the part (see `Split.plateauMesh`), so the
//! layers over the face exist and get top skin. A raised or cut label in
//! the filament of the part changes only the shape. In another filament,
//! a raised label prints in it, and a cut label colors the floor of the
//! cut to the depth of the label.
//!
//! References (see docs/references/): the multi-material segmentation of
//! PrusaSlicer (MultiMaterialSegmentation.cpp: the colored edges of a
//! layer, the projection of painted top and bottom surfaces); the
//! distance field and its regions (see field.zig); the text
//! tools of PrusaSlicer and Bambu Studio and the segmented region width
//! of PrusaSlicer and OrcaSlicer (the labels); the methods, no code.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const parallel = @import("parallel.zig");
const mesh_mod = @import("mesh.zig");
const paint_mod = @import("paint.zig");
const label_mod = @import("label.zig");
const field = @import("field.zig");
const Mesh = mesh_mod.Mesh;
const Paths = geom.Paths;
const Point = geom.Point;
const V3 = paint_mod.V3;

/// The depth of the paint from a painted source: `max_steps` + 1 line
/// widths (see the header).
pub const max_steps = 4;

/// How the frame of a job maps the mesh: the cut z of a layer in the
/// mesh, and the XY of a mesh point in the units of geom.
pub const Frame = struct {
    z_base: f64 = 0,
    z_scale: f64 = 1,
    dx: f64 = 0,
    dy: f64 = 0,
    xy_scale: f64 = 1,
    center: [2]f64 = .{ 0, 0 },

    fn xy(f: Frame, x: f32, y: f32) Point {
        const X = (@as(f64, x) + f.dx - f.center[0]) * f.xy_scale + f.center[0];
        const Y = (@as(f64, y) + f.dy - f.center[1]) * f.xy_scale + f.center[1];
        return .init(geom.fromMm(X), geom.fromMm(Y));
    }
};

const Leaf = struct { v: [3]V3, state: u8, flat: i8 };

/// The painted pieces of a part, and the regions of each layer.
pub const Split = struct {
    gpa: Allocator,
    /// The states of the regions: `states[0]` is the filament of the part,
    /// the others are the painted filaments, each once.
    states: []u8 = &.{},
    leaves: []Leaf = &.{},
    /// The regions: regions[layer * states.len + k] for state states[k].
    regions: []Paths = &.{},
    layers: usize = 0,
    done: bool = false,
    /// A cancel of the slice: `compute` stops between layers with
    /// error.Canceled, and a later `compute` starts again.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// The volume (mm³) of the roots of the anchors (see `anchor`), for
    /// the tests and the stats.
    anchor_mm3: f64 = 0,
    /// For each layer and state (as `regions`): the region is all root
    /// (see `anchor`). Empty with no roots.
    root_only: []bool = &.{},
    /// The labels of the part, ready for the cut of each layer (see
    /// `labelLayer`).
    labels: []LabelCut = &.{},
    /// For each state: the index of its label in the labels of `init`,
    /// or null for the part and the paint. Empty with no labels.
    label_of: []?u32 = &.{},
    /// For each layer: the area that cut labels took out of it (empty
    /// with no cut label). A layer under a cut gets top skin there, and
    /// a layer over a cut gets bottom skin (see engine.Job.clipToPaint).
    removed: []Paths = &.{},

    pub fn deinit(s: *Split) void {
        for (s.labels) |*c| c.shape.deinit(s.gpa);
        s.gpa.free(s.labels);
        s.gpa.free(s.label_of);
        for (s.removed) |*r| r.deinit(s.gpa);
        s.gpa.free(s.removed);
        for (s.regions) |*r| r.deinit(s.gpa);
        s.gpa.free(s.regions);
        s.gpa.free(s.root_only);
        s.gpa.free(s.leaves);
        s.gpa.free(s.states);
        s.* = undefined;
    }

    /// The painted pieces of `paint` on `mesh`. `base`: the filament of
    /// the part; paint of the same filament is no paint.
    pub fn init(gpa: Allocator, mesh: *const Mesh, paint: *const paint_mod.Paint, base: u8) Allocator.Error!Split {
        return initLabels(gpa, mesh, paint, base, &.{});
    }

    /// `init`, with the labels of the part (see label.zig) in the frame
    /// of `mesh`. Each label gets a state of its own after the states of
    /// the paint, also when its filament is a filament of the paint. A
    /// label in the filament of the part gets none: an ink label then has
    /// no effect, and a raised or cut label changes the outlines of the
    /// state of the part. A label with no shape has no effect.
    pub fn initLabels(gpa: Allocator, mesh: *const Mesh, paint: *const paint_mod.Paint, base: u8, labels: []const label_mod.Label) Allocator.Error!Split {
        var s = try initPaint(gpa, mesh, paint, base);
        errdefer s.deinit();
        if (labels.len == 0) return s;
        var cuts: std.ArrayList(LabelCut) = .empty;
        errdefer {
            for (cuts.items) |*c| c.shape.deinit(gpa);
            cuts.deinit(gpa);
        }
        var grid: ?paint_mod.Grid = null;
        defer if (grid) |*g| g.deinit(gpa);
        var own: usize = 0;
        for (labels, 0..) |*l, li| {
            const mine = l.filament != base;
            if ((!mine and l.mode == .ink) or l.filament > 255 or l.items.len == 0) continue;
            if (grid == null) grid = try paint_mod.Grid.init(gpa, mesh);
            var c = (try LabelCut.init(gpa, l, mesh, &grid.?)) orelse continue;
            c.index = @intCast(li);
            c.state = if (mine) s.states.len + own else 0;
            if (mine) own += 1;
            cuts.append(gpa, c) catch |e| {
                c.shape.deinit(gpa);
                return e;
            };
        }
        if (cuts.items.len == 0) {
            cuts.deinit(gpa);
            return s;
        }
        const n = s.states.len;
        const states = try gpa.alloc(u8, n + own);
        @memcpy(states[0..n], s.states);
        for (cuts.items) |c| if (c.state != 0) {
            states[c.state] = @intCast(labels[c.index].filament);
        };
        gpa.free(s.states);
        s.states = states;
        s.label_of = try gpa.alloc(?u32, states.len);
        @memset(s.label_of, null);
        for (cuts.items) |c| if (c.state != 0) {
            s.label_of[c.state] = c.index;
        };
        s.labels = try cuts.toOwnedSlice(gpa);
        return s;
    }

    fn initPaint(gpa: Allocator, mesh: *const Mesh, paint: *const paint_mod.Paint, base: u8) Allocator.Error!Split {
        var s: Split = .{ .gpa = gpa };
        errdefer s.deinit();
        var leaves: std.ArrayList(Leaf) = .empty;
        errdefer leaves.deinit(gpa);
        var states: std.ArrayList(u8) = .empty;
        errdefer states.deinit(gpa);
        try states.append(gpa, base);
        const Ctx = struct {
            gpa: Allocator,
            leaves: *std.ArrayList(Leaf),
            states: *std.ArrayList(u8),
            base: u8,
            err: bool = false,
            fn add(c: *@This(), a: V3, b: V3, d: V3, state: u8) void {
                const st = if (state == 0) c.base else state;
                if (st == c.base) return;
                if (std.mem.indexOfScalar(u8, c.states.items, st) == null) c.states.append(c.gpa, st) catch {
                    c.err = true;
                    return;
                };
                // The normal: flat pieces color the layers under or over
                // them.
                const e1: V3 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
                const e2: V3 = .{ d[0] - a[0], d[1] - a[1], d[2] - a[2] };
                const n: V3 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
                const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
                if (!(len > 0)) return;
                const nz = n[2] / len;
                const flat: i8 = if (nz > 0.7) 1 else if (nz < -0.7) -1 else 0;
                c.leaves.append(c.gpa, .{ .v = .{ a, b, d }, .state = st, .flat = flat }) catch {
                    c.err = true;
                };
            }
        };
        var ctx: Ctx = .{ .gpa = gpa, .leaves = &leaves, .states = &states, .base = base };
        const n = @min(paint.states.items.len, mesh.faces.items.len);
        for (0..n) |i| {
            const st = paint.states.items[i];
            if (st == 0 or st == base) continue;
            paint.leaves(mesh, i, &ctx, Ctx.add);
        }
        if (ctx.err) return error.OutOfMemory;
        s.leaves = try leaves.toOwnedSlice(gpa);
        s.states = try states.toOwnedSlice(gpa);
        return s;
    }

    /// The region of state index k on layer i.
    pub fn region(s: *const Split, i: usize, k: usize) *const Paths {
        return &s.regions[i * s.states.len + k];
    }

    /// True if the region of state index k on layer i is all root (see
    /// `anchor`).
    pub fn rootOnly(s: *const Split, i: usize, k: usize) bool {
        const j = i * s.states.len + k;
        return j < s.root_only.len and s.root_only[j];
    }

    /// The index of a state in `states`, or null.
    pub fn indexOf(s: *const Split, state: u8) ?usize {
        return std.mem.indexOfScalar(u8, s.states, state);
    }

    /// The regions of all layers, from the full outline of each layer.
    /// `cut_z[i]`: the cut z of layer i in the frame of the job (before
    /// the z scale). `width`: the line width (mm). `top` and `bottom`: the
    /// depth (mm) of the color of a painted top or bottom face. `roots`:
    /// the anchors of the painted features (see `anchor`). `min_bead`:
    /// the narrowest line (mm) of a label (see `labelLayer`).
    pub fn compute(s: *Split, outlines: []const Paths, cut_z: []const f64, frame: Frame, width: f64, top: f64, bottom: f64, threads: usize, roots: Anchor, min_bead: f64) anyerror!void {
        if (s.done) return;
        const gpa = s.gpa;
        const n = outlines.len;
        // The regions of a compute that a cancel stopped.
        for (s.regions) |*r| r.deinit(gpa);
        gpa.free(s.regions);
        s.regions = &.{};
        gpa.free(s.root_only);
        s.root_only = &.{};
        s.anchor_mm3 = 0;
        s.layers = n;
        s.regions = try gpa.alloc(Paths, n * s.states.len);
        @memset(s.regions, .empty);
        for (s.removed) |*r| r.deinit(gpa);
        gpa.free(s.removed);
        s.removed = &.{};
        for (s.labels) |lc| if (lc.mode == .cut) {
            s.removed = try gpa.alloc(Paths, n);
            @memset(s.removed, .empty);
            break;
        };
        const Pass = struct {
            s: *Split,
            outlines: []const Paths,
            index: LeafIndex,
            frame: Frame,
            w: i64,
            fn run(c: *const @This(), i: usize) anyerror!void {
                if (c.s.canceled()) return error.Canceled;
                try c.s.layer(i, c.outlines[i], c.index.z[i], c.index.get(i), c.frame, c.w);
            }
        };
        var index = try LeafIndex.init(gpa, s.leaves, cut_z, frame, top, bottom);
        defer index.deinit(gpa);
        const ctx: Pass = .{ .s = s, .outlines = outlines, .index = index, .frame = frame, .w = geom.fromMm(width) };
        try parallel.forEach(threads, n, &ctx, Pass.run);
        if (s.canceled()) return error.Canceled;
        if (roots.depth > 0 and s.states.len > 1) try s.anchor(outlines, cut_z, width, top, bottom, roots);
        if (s.labels.len > 0) {
            const LabelPass = struct {
                s: *Split,
                outlines: []const Paths,
                cut_z: []const f64,
                frame: Frame,
                width: f64,
                min_bead: f64,
                fn run(c: *const @This(), i: usize) anyerror!void {
                    if (c.s.canceled()) return error.Canceled;
                    try c.s.labelLayer(i, c.outlines, c.cut_z, c.frame, c.width, c.min_bead);
                }
            };
            const lp: LabelPass = .{ .s = s, .outlines = outlines, .cut_z = cut_z, .frame = frame, .width = width, .min_bead = min_bead };
            try parallel.forEach(threads, n, &lp, LabelPass.run);
        }
        if (s.canceled()) return error.Canceled;
        s.done = true;
    }

    fn canceled(s: *const Split) bool {
        const c = s.cancel orelse return false;
        return c.load(.monotonic);
    }

    /// The labels on layer i (after the paint and the anchors). For each
    /// label in order, its region L of the layer goes to its state, and
    /// each other region of the layer loses L. So a later label wins over
    /// an earlier one, and a label wins over the paint and the roots.
    ///
    /// A side label: the prism of its shape along its normal, over the
    /// range H of the surface under it, cut by the plane of the layer
    /// (see `LabelCut.side`), and within the depth D of the outline of
    /// the layer (the skin band). A top label: its shape, projected
    /// along its normal, in the area of the layer that is within k
    /// layers of a top (k = D / the layer height, at least 2). A bottom
    /// label: the same with the layers under it.
    ///
    /// The clean-up: a piece of L thinner than `min_bead` goes back to
    /// the part (an opening), and a gap of the band narrower than
    /// `min_bead` between two pieces of L goes to the label (a closing).
    fn labelLayer(s: *Split, i: usize, outlines: []const Paths, cut_z: []const f64, frame: Frame, width: f64, min_bead: f64) anyerror!void {
        const gpa = s.gpa;
        const outline = outlines[i];
        if (outline.isEmpty()) return;
        const k = s.states.len;
        const out = s.regions[i * k ..][0..k];
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const z = frame.z_base + cut_z[i] / frame.z_scale;
        // The layer height, for the count of layers in D.
        const lh = if (i > 0) cut_z[i] - cut_z[i - 1] else if (cut_z.len > 1) cut_z[1] - cut_z[0] else width / 2;
        const r_bead = @divTrunc(geom.fromMm(min_bead), 2);
        // The skin bands of the layer, for each depth.
        var bands: std.ArrayList(Band) = .empty;
        for (s.labels) |*lc| {
            const d = if (lc.depth > 0) lc.depth else width;
            const rel = lc.relief;
            // A raised side label: the prism out of the surface, in the
            // shell of the relief around the outline. It goes to the state
            // of the label (the part, or its own filament).
            if (lc.mode == .raised and lc.kind == .side) {
                const p = try lc.side(a, z, lc.h_min - rel - width, lc.h_max + width, frame);
                if (p.isEmpty()) continue;
                const grown = try offset_mod.offset(a, outline, geom.fromMm(rel), .{});
                const shell = try clip.difference(a, grown, outline);
                var r = try clip.intersect(a, p, shell);
                if (r.isEmpty()) continue;
                r = try clean(a, r, shell, r_bead);
                if (r.isEmpty()) continue;
                const u = try clip.unite(gpa, out[lc.state], r);
                out[lc.state].deinit(gpa);
                out[lc.state] = u;
                continue;
            }
            // A raised top label: the plateau is in the mesh. Its own
            // filament colors the plateau, and the depth of the label
            // under it.
            if (lc.mode == .raised and lc.kind == .top) {
                if (lc.state == 0) continue;
                if (z < lc.z_min - d - width or z > lc.plateau_z + width) continue;
                const p = try lc.flat(a, lc.plateau_z, frame);
                var l = try clip.intersect(a, p, outline);
                if (l.isEmpty()) continue;
                l = try clean(a, l, outline, r_bead);
                try s.give(out, lc.state, l);
                continue;
            }
            // A cut label: its shape out of the band of the relief. In its
            // own filament, the band of the depth under the cut is the
            // region of the label.
            if (lc.mode == .cut) {
                const c = try lc.region(a, i, outlines, z, lh, rel, width, frame, &bands);
                if (c.isEmpty()) continue;
                const room = if (lc.kind == .side) try bandOf(a, outline, rel, &bands) else outline;
                const cut = try clean(a, c, room, r_bead);
                if (cut.isEmpty()) continue;
                for (out) |*r| {
                    if (r.isEmpty()) continue;
                    const rest = try clip.difference(gpa, r.*, cut);
                    r.deinit(gpa);
                    r.* = rest;
                }
                const rm = try clip.unite(gpa, s.removed[i], cut);
                s.removed[i].deinit(gpa);
                s.removed[i] = rm;
                if (lc.state == 0) continue;
                const deep = try lc.region(a, i, outlines, z, lh, rel + d, width, frame, &bands);
                var l = try clip.difference(a, deep, cut);
                if (l.isEmpty()) continue;
                l = try clean(a, l, deep, r_bead);
                try s.give(out, lc.state, l);
                continue;
            }
            // Ink (and a raised bottom label: it prints as ink).
            if (lc.state == 0) continue;
            var l = try lc.region(a, i, outlines, z, lh, d, width, frame, &bands);
            if (l.isEmpty()) continue;
            const room = if (lc.kind == .side) try bandOf(a, outline, d, &bands) else try lc.skin(a, i, outlines, lh, d);
            l = try clean(a, l, room, r_bead);
            try s.give(out, lc.state, l);
        }
    }

    /// Region `l` of a layer goes to state `state`: each other region of
    /// the layer loses it.
    fn give(s: *Split, out: []Paths, state: usize, l: Paths) Allocator.Error!void {
        const gpa = s.gpa;
        if (l.isEmpty()) return;
        for (out, 0..) |*r, st| {
            if (st == state or r.isEmpty()) continue;
            const rest = try clip.difference(gpa, r.*, l);
            r.deinit(gpa);
            r.* = rest;
        }
        const mine = try l.clone(gpa);
        out[state].deinit(gpa);
        out[state] = mine;
    }

    /// The mesh of the part with the walls of the plateau of each raised
    /// top label (see the header), or null if no label is one. The walls
    /// stand along Z from 1 mm under the surface under the shape to the
    /// relief over its highest point, on the shape projected along the
    /// normal of the label. The caller owns the result.
    pub fn plateauMesh(s: *const Split, gpa: Allocator, mesh: *const Mesh) Allocator.Error!?Mesh {
        var out: ?Mesh = null;
        errdefer if (out) |*m| m.deinit(gpa);
        for (s.labels) |*lc| {
            if (lc.mode != .raised or lc.kind != .top) continue;
            if (out == null) out = try mesh.clone(gpa);
            const m = &out.?;
            const z0: f32 = @floatCast(lc.z_min - 1);
            const z1: f32 = @floatCast(lc.plateau_z);
            var shape = try lc.flat(gpa, lc.plateau_z, .{});
            defer shape.deinit(gpa);
            for (0..shape.count()) |k| {
                const poly = shape.get(k);
                for (poly, 0..) |p, j| {
                    const q = poly[(j + 1) % poly.len];
                    const px: f32 = @floatCast(geom.toMm(p.x));
                    const py: f32 = @floatCast(geom.toMm(p.y));
                    const qx: f32 = @floatCast(geom.toMm(q.x));
                    const qy: f32 = @floatCast(geom.toMm(q.y));
                    const b: u32 = @intCast(m.vertices.items.len);
                    try m.vertices.appendSlice(gpa, &.{ .{ .x = px, .y = py, .z = z0 }, .{ .x = qx, .y = qy, .z = z0 }, .{ .x = qx, .y = qy, .z = z1 }, .{ .x = px, .y = py, .z = z1 } });
                    // Outward for a counterclockwise outline.
                    try m.faces.appendSlice(gpa, &.{ .{ b, b + 1, b + 2 }, .{ b, b + 2, b + 3 } });
                }
            }
        }
        return out;
    }

    /// The anchors of the painted features: where a region of a painted
    /// filament B stands on the region of another filament A (B starts on
    /// a layer, over A), B grows down into A by `roots.depth`. This root
    /// of B stays inside the walls of the part, so the outside keeps the
    /// color of A, and the infill and the inner skin of A give way to it.
    /// Its shape on each layer is the area where B stands on A, inside
    /// the walls of the part on that layer and on the layers under it
    /// (so the root never shows through a bottom face), and inside the
    /// root of the layer over it (so it never shows through a top face).
    ///
    /// A region of B that is only the color of a painted top face (it
    /// ends within `top` over its start) gets no root: it lies flat on A.
    /// A region of B on the bed gets no root, and the part of a region of
    /// B over air gets no root.
    ///
    /// Each job of a filament then prints its region as before: B prints
    /// its walls and infill in the root, and A prints walls around it.
    /// This is the method of zslice; Cura and OrcaSlicer join two
    /// materials with an interlocking structure of beams instead (see
    /// docs/references/).
    fn anchor(s: *Split, outlines: []const Paths, cut_z: []const f64, width: f64, top: f64, bottom: f64, roots: Anchor) Allocator.Error!void {
        const gpa = s.gpa;
        const n = s.layers;
        const k = s.states.len;
        if (n < 2) return;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const w = geom.fromMm(width);
        const eps = 1e-6;
        // The inside of the walls of the part on each layer, made when a
        // root needs it.
        const inner = try a.alloc(?Paths, n);
        @memset(inner, null);
        const inset = geom.fromMm(roots.inset);
        const Inner = struct {
            fn get(al: Allocator, cache: []?Paths, o: []const Paths, i: usize, d: i64) Allocator.Error!Paths {
                if (cache[i]) |p| return p;
                const p = try offset_mod.offset(al, o[i], -d, .{});
                cache[i] = p;
                return p;
            }
        };
        // The roots of each layer and state, from the regions before the
        // roots.
        const add = try a.alloc(Paths, n * k);
        @memset(add, .empty);
        var any = false;
        for (1..n) |i| for (1..k) |st| {
            const r = s.region(i, st);
            if (r.isEmpty()) continue;
            // The area where B stands on the other filaments: in B on this
            // layer, and in the part but not in B on the layer under it.
            const other = try clip.difference(a, outlines[i - 1], s.region(i - 1, st).*);
            if (other.isEmpty()) continue;
            var foot = try clip.intersect(a, r.*, other);
            if (foot.isEmpty()) continue;
            // B must go on for more than the color of a painted top: B on
            // the first layer at `top` or more over this layer.
            var up = i + 1;
            while (up < n and cut_z[up] < cut_z[i] + top - eps) up += 1;
            if (up >= n) continue;
            foot = try clip.intersect(a, foot, s.region(up, st).*);
            if (roots.shape == .core) foot = try offset_mod.offset(a, foot, -inset, .{});
            if (foot.isEmpty()) continue;
            // Down, layer by layer, for the depth.
            var root = foot;
            var j = i;
            while (j > 0 and !root.isEmpty()) {
                j -= 1;
                if (cut_z[i - 1] - cut_z[j] > roots.depth - eps) break;
                // The root keeps the bottom skin under it: stop near the
                // bed, and stay inside the walls of the layers under it.
                if (cut_z[j] - cut_z[0] < bottom - eps) break;
                root = try clip.intersect(a, root, try Inner.get(a, inner, outlines, j, inset));
                var m = j;
                while (m > 0 and !root.isEmpty()) {
                    m -= 1;
                    if (cut_z[j] - cut_z[m] > bottom + eps) break;
                    root = try clip.intersect(a, root, try Inner.get(a, inner, outlines, m, inset));
                }
                // No piece thinner than one line: it does not print.
                const thin = try offset_mod.offset(a, try offset_mod.offset(a, root, -@divTrunc(w, 2), .{}), @divTrunc(w, 2), .{});
                root = try clip.intersect(a, thin, root);
                if (root.isEmpty()) break;
                const piece = try clip.difference(a, root, s.region(j, st).*);
                if (piece.isEmpty()) continue;
                add[j * k + st] = try clip.unite(a, add[j * k + st], piece);
                any = true;
            }
        };
        if (!any) return;
        s.root_only = try gpa.alloc(bool, n * k);
        for (s.root_only, add, s.regions) |*o, r, reg| o.* = !r.isEmpty() and reg.isEmpty();
        // The roots go into the regions: a state with a lower index wins
        // where two roots overlap.
        for (0..n) |j| {
            var taken: Paths = .empty;
            for (1..k) |st| {
                const r = &add[j * k + st];
                if (r.isEmpty()) continue;
                if (!taken.isEmpty()) r.* = try clip.difference(a, r.*, taken);
                taken = try clip.unite(a, taken, r.*);
                const h = if (j > 0) cut_z[j] - cut_z[j - 1] else cut_z[1] - cut_z[0];
                s.anchor_mm3 += r.areaMm2() * h;
            }
            if (taken.isEmpty()) continue;
            for (0..k) |st| {
                const reg = &s.regions[j * k + st];
                const rest = try clip.difference(a, reg.*, taken);
                const next = try clip.unite(gpa, rest, add[j * k + st]);
                reg.deinit(gpa);
                reg.* = next;
            }
        }
    }

    /// The regions of layer i. `zf`: its cut z in the mesh. `leaf_ids`:
    /// the painted pieces that touch the layer (see `LeafIndex`).
    fn layer(s: *Split, i: usize, outline: Paths, zf: f32, leaf_ids: []const u32, frame: Frame, w: i64) anyerror!void {
        const gpa = s.gpa;
        const k = s.states.len;
        const out = s.regions[i * k ..][0..k];
        if (outline.isEmpty()) return;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // The painted flat pieces (seen from above) of the layer.
        const Flat = struct { v: [3]Point, si: u8 };
        var flats: std.ArrayList(Flat) = .empty;
        var any = false;
        // The painted segments of the layer, in a grid of cells of 2w.
        var segs: std.ArrayList(Seg) = .empty;
        for (leaf_ids) |id| {
            const lf = s.leaves[id];
            const si = std.mem.indexOfScalar(u8, s.states, lf.state) orelse continue;
            if (lf.flat != 0) {
                // A flat piece: its shape, seen from above.
                var tri: [3]Point = .{ frame.xy(lf.v[0][0], lf.v[0][1]), frame.xy(lf.v[1][0], lf.v[1][1]), frame.xy(lf.v[2][0], lf.v[2][1]) };
                if (geom.area2(&tri) < 0) std.mem.swap(Point, &tri[0], &tri[2]);
                if (geom.area2(&tri) == 0) continue;
                try flats.append(a, .{ .v = tri, .si = @intCast(si) });
                any = true;
                continue;
            }
            // The segment of the piece on the plane.
            var pts: [2][2]f32 = undefined;
            var np: usize = 0;
            for (0..3) |e| {
                const p = lf.v[e];
                const q = lf.v[(e + 1) % 3];
                if ((p[2] - zf) * (q[2] - zf) > 0 or p[2] == q[2]) continue;
                const t = (zf - p[2]) / (q[2] - p[2]);
                if (np < 2) pts[np] = .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
                np += 1;
            }
            if (np < 2) continue;
            const pa = frame.xy(pts[0][0], pts[0][1]);
            const pb = frame.xy(pts[1][0], pts[1][1]);
            try segs.append(a, .{ .a = pa, .b = pb, .si = @intCast(si) });
            any = true;
        }
        if (!any) {
            out[0] = try outline.clone(gpa);
            return;
        }
        // The sources of the field: each piece of the edge of the outline
        // has the state of the nearest painted segment within one line
        // width, else the filament of the part.
        var pieces: std.ArrayList(Seg) = .empty;
        if (segs.items.len > 0) {
            try edgePieces(a, outline, segs.items, w, &pieces);
        } else {
            // A painted top or bottom only: the whole edge is of the part.
            for (0..outline.count()) |pi| {
                const poly = outline.get(pi);
                for (poly, 0..) |p, j| try pieces.append(a, .{ .a = p, .b = poly[(j + 1) % poly.len], .si = 0 });
            }
        }
        // The grid: the box of the painted sources in the outline, grown
        // by the reach of the paint and of the test of a core.
        const ob = outline.bounds();
        var box: geom.Box = .empty;
        for (pieces.items) |pc| if (pc.si != 0) {
            box.extend(pc.a);
            box.extend(pc.b);
        };
        for (flats.items) |t| for (t.v) |p| box.extend(p);
        if (box.isEmpty()) {
            out[0] = try outline.clone(gpa);
            return;
        }
        const depth = @as(i64, max_steps + 1) * w;
        const reach = @as(i64, 2 * max_steps + 3) * w;
        var h = @max(@divFloor(w, 2), 10);
        box.min = .init(@max(box.min.x - reach, ob.min.x) - 3 * h, @max(box.min.y - reach, ob.min.y) - 3 * h);
        box.max = .init(@min(box.max.x + reach, ob.max.x) + 3 * h, @min(box.max.y + reach, ob.max.y) + 3 * h);
        // At most about four million nodes: a larger box gets a larger
        // step.
        while (@divFloor(box.max.x - box.min.x, h) * @divFloor(box.max.y - box.min.y, h) > 1 << 22) h *= 2;
        var f = try field.Field.init(a, box, h, k);
        const n = f.nodes();
        // A painted top or bottom wins at the edge of the part: a head
        // start of half a step.
        const head: f32 = @floatFromInt(@divFloor(h, 2));
        // Two steps more than the depth: the nodes around the border at
        // the depth have their exact distance.
        const radius = depth + 2 * h;
        for (pieces.items) |pc| f.stampSegment(pc.si, pc.a, pc.b, radius, 0);
        if (flats.items.len > 0) {
            // The edges of the flat shapes that only one triangle has.
            var sides: std.AutoHashMapUnmanaged([5]i64, u32) = .empty;
            for (flats.items) |t| {
                f.fillTriangle(t.si, t.v);
                for (0..3) |e| {
                    const g = try sides.getOrPut(a, sideKey(t.v[e], t.v[(e + 1) % 3], t.si));
                    if (!g.found_existing) g.value_ptr.* = 0;
                    g.value_ptr.* += 1;
                }
            }
            var it = sides.iterator();
            while (it.next()) |e| if (e.value_ptr.* == 1) {
                const q = e.key_ptr.*;
                f.stampSegment(@intCast(q[4]), .init(q[0], q[1]), .init(q[2], q[3]), radius, head);
            };
        }
        if (s.canceled()) return error.Canceled;
        // The scores and the labels: the nearest state wins, and the
        // filament of the part also has all that is deeper than `depth`.
        const score = try a.alloc(f32, k * n);
        const label = try a.alloc(u8, n);
        const depth_f: f32 = @floatFromInt(depth);
        for (0..n) |q| {
            score[q] = @min(f.dist(0, q), depth_f);
            var best: usize = 0;
            for (1..k) |j| {
                score[j * n + q] = f.dist(j, q);
                if (score[j * n + q] < score[best * n + q]) best = j;
            }
            label[q] = @intCast(best);
        }
        try cleanLabels(a, &f, outline, label, score, w, depth_f, @floatFromInt(reach));
        if (s.canceled()) return error.Canceled;
        // The regions of the painted states, cut to the outline.
        const loops = try a.alloc(Paths, k);
        @memset(loops, .empty);
        try field.regions(a, a, &f, label, score, loops);
        var painted: Paths = .empty;
        for (out[1..], loops[1..]) |*o, l| {
            if (l.isEmpty()) continue;
            var cut = try clip.intersect(gpa, l, outline);
            // A sliver at the edge of the outline is no region.
            dropSmall(&cut, w);
            try painted.appendAll(a, cut);
            o.* = cut;
        }
        out[0] = try clip.difference(gpa, outline, painted);
    }
};

/// The painted pieces that touch each layer: a steep piece touches the
/// layers with their cut z in its z range, and a flat piece the layers
/// within the top thickness under it, or the bottom thickness over it.
/// One pass over the pieces makes the lists, so a layer does not read the
/// pieces of the whole part.
const LeafIndex = struct {
    /// The cut z of each layer in the mesh.
    z: []f32,
    /// start[i] to start[i + 1]: the pieces of layer i in `ids`.
    start: []u32,
    ids: []u32,

    fn init(gpa: Allocator, leaves: []const Leaf, cut_z: []const f64, frame: Frame, top: f64, bottom: f64) Allocator.Error!LeafIndex {
        const n = cut_z.len;
        const z = try gpa.alloc(f32, n);
        errdefer gpa.free(z);
        for (z, cut_z) |*zf, c| zf.* = @floatCast(frame.z_base + c / frame.z_scale);
        const start = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        var ids: []u32 = &.{};
        errdefer gpa.free(ids);
        for (0..2) |pass| {
            for (leaves, 0..) |lf, id| {
                const zlo = @min(lf.v[0][2], @min(lf.v[1][2], lf.v[2][2]));
                const zhi = @max(lf.v[0][2], @max(lf.v[1][2], lf.v[2][2]));
                const zm = (zlo + zhi) / 2;
                // The range of cut z of the piece, a little wide: `touches`
                // has the exact test.
                const lo = if (lf.flat > 0) zm - @as(f32, @floatCast(top)) else if (lf.flat < 0) zm else zlo;
                const hi = if (lf.flat > 0) zm else if (lf.flat < 0) zm + @as(f32, @floatCast(bottom)) else zhi;
                // The first layer with z >= lo - 0.001 (the cut z rises
                // with the layer).
                var a: usize = 0;
                var b: usize = n;
                while (a < b) {
                    const mid = (a + b) / 2;
                    if (z[mid] < lo - 1e-3) a = mid + 1 else b = mid;
                }
                while (a < n and z[a] <= hi + 1e-3) : (a += 1) {
                    if (!touches(lf, zlo, zhi, zm, z[a], top, bottom)) continue;
                    if (pass == 1) ids[start[a]] = @intCast(id);
                    start[a] += 1;
                }
            }
            if (pass == 0) {
                // start[i] is the count of layer i: make it the first
                // index of layer i.
                var sum: u32 = 0;
                for (start) |*st| {
                    const c = st.*;
                    st.* = sum;
                    sum += c;
                }
                ids = try gpa.alloc(u32, sum);
            } else {
                // start[i] is the end of layer i: move each one up.
                var i = n;
                while (i > 0) : (i -= 1) start[i] = start[i - 1];
                start[0] = 0;
            }
        }
        return .{ .z = z, .start = start, .ids = ids };
    }

    fn touches(lf: Leaf, zlo: f32, zhi: f32, zm: f32, zf: f32, top: f64, bottom: f64) bool {
        if (lf.flat > 0) return zm >= zf - 1e-4 and zm <= zf + @as(f32, @floatCast(top));
        if (lf.flat < 0) return zm <= zf + 1e-4 and zm >= zf - @as(f32, @floatCast(bottom));
        return zf >= zlo and zf <= zhi;
    }

    fn deinit(x: *LeafIndex, gpa: Allocator) void {
        gpa.free(x.z);
        gpa.free(x.start);
        gpa.free(x.ids);
    }

    fn get(x: LeafIndex, i: usize) []const u32 {
        return x.ids[x.start[i]..x.start[i + 1]];
    }
};

/// A key of the side p q of a flat triangle of state `si`, the same for
/// both directions.
fn sideKey(p: Point, q: Point, si: u8) [5]i64 {
    const lo = if (p.lessThan(q)) p else q;
    const hi = if (p.lessThan(q)) q else p;
    return .{ lo.x, lo.y, hi.x, hi.y, si };
}

/// Removes the outer loops of `p` with less area than an eighth of a
/// square of one line width, in place.
fn dropSmall(p: *Paths, w: i64) void {
    const min2: i128 = @divFloor(@as(i128, w) * w, 4);
    var keep: usize = 0;
    var at: usize = 0;
    var start: usize = 0;
    for (p.ends.items) |end| {
        const poly = p.points.items[start..end];
        start = end;
        const a2 = geom.area2(poly);
        if (a2 >= 0 and a2 < min2) continue;
        std.mem.copyForwards(Point, p.points.items[at..], poly);
        at += poly.len;
        p.ends.items[keep] = @intCast(at);
        keep += 1;
    }
    p.points.shrinkRetainingCapacity(at);
    p.ends.shrinkRetainingCapacity(keep);
}

/// The clean-up of the labels of a layer (see `Split.layer`), on the
/// nodes inside `outline`. A group is a set of nodes with one label that
/// touch each other.
///
/// - A group with less area than a square of one line width gets the
///   label that most of its neighbors have: no bead fits it.
/// - A group of the filament of the part with no edge of that filament
///   within `depth` (a core, deeper than the paint grows), and with
///   paint within `reach` of each node: it gets the paint around it, so
///   a wide painted feature prints in one filament.
///
/// A node outside the outline next to a changed group changes with it, so
/// the new border does not run along the outline. The nodes more than
/// two steps outside the outline get the label 0.
fn cleanLabels(a: Allocator, f: *const field.Field, outline: Paths, label: []u8, score: []const f32, w: i64, depth: f32, reach: f32) Allocator.Error!void {
    const n = f.nodes();
    const nx = f.nx;
    const k = score.len / n;
    const mask = try f.inside(a, outline);
    // The paint ends two steps outside the outline. The cut to the
    // outline is then clean, and no region reaches the border of the
    // grid (the grid has three steps around the outline).
    {
        const grown = try a.alloc(u8, n);
        const tmp = try a.alloc(u8, n);
        @memcpy(grown, mask);
        for (0..2) |_| {
            @memcpy(tmp, grown);
            for (1..f.ny - 1) |r| for (1..nx - 1) |c| {
                const m = r * nx + c;
                if (tmp[m] != 0) continue;
                var any: u8 = 0;
                for ([3]usize{ m - nx, m, m + nx }) |q| any |= tmp[q - 1] | tmp[q] | tmp[q + 1];
                grown[m] = any;
            };
        }
        for (label, grown) |*l, g| {
            if (g == 0) l.* = 0;
        }
    }
    const none = std.math.maxInt(u32);
    const group = try a.alloc(u32, n);
    @memset(group, none);
    const min_nodes: usize = @intCast(@max(@divFloor(w * w, f.h * f.h), 1));
    var stack: std.ArrayList(u32) = .empty;
    var members: std.ArrayList(u32) = .empty;
    const votes = try a.alloc(u32, k);
    var paint_dist: ?[]f32 = null;
    var next_group: u32 = 0;
    for (0..n) |seed| {
        if (mask[seed] == 0 or group[seed] != none) continue;
        const l = label[seed];
        const g = next_group;
        next_group += 1;
        members.clearRetainingCapacity();
        @memset(votes, 0);
        var own_edge = false;
        var at_border = false;
        group[seed] = g;
        try stack.append(a, @intCast(seed));
        while (stack.pop()) |m| {
            try members.append(a, m);
            const c = m % nx;
            const r = m / nx;
            if (c == 0 or r == 0 or c + 1 == nx or r + 1 == f.ny) {
                at_border = true;
                continue;
            }
            if (l == 0 and f.d2[m] <= depth * depth) own_edge = true;
            for ([4]usize{ m - 1, m + 1, m - nx, m + nx }) |q| {
                if (mask[q] == 0) continue;
                if (label[q] != l) {
                    // A node of a group that changed before has its new
                    // label: the vote is for the labels of now.
                    votes[label[q]] += 1;
                    continue;
                }
                if (group[q] != none) continue;
                group[q] = g;
                try stack.append(a, @intCast(q));
            }
        }
        var to: ?u8 = null;
        if (members.items.len < min_nodes and !at_border) {
            var best: u32 = 0;
            for (votes, 0..) |v, j| if (v > best) {
                best = v;
                to = @intCast(j);
            };
        } else if (l == 0) {
            if (own_edge or at_border) continue;
            // Paint within `reach` of each node.
            if (paint_dist == null) {
                const seeds = try a.alloc(bool, n);
                for (seeds, 0..) |*sd, i| {
                    sd.* = false;
                    for (1..k) |j| sd.* = sd.* or score[j * n + i] <= depth;
                }
                paint_dist = try f.chamfer(a, seeds);
            }
            var is_far = false;
            for (members.items) |m| is_far = is_far or paint_dist.?[m] + depth > reach;
            if (is_far) continue;
            var best: u32 = 0;
            for (votes[1..], 1..) |v, j| if (v > best) {
                best = v;
                to = @intCast(j);
            };
        }
        const new = to orelse continue;
        for (members.items) |m| {
            label[m] = new;
            // The nodes outside the outline around it, two steps far.
            const c = m % nx;
            const r = m / nx;
            var rr = @max(r -| 2, 1);
            while (rr <= @min(r + 2, f.ny - 2)) : (rr += 1) {
                var cc = @max(c -| 2, 1);
                while (cc <= @min(c + 2, nx - 2)) : (cc += 1) {
                    const q = rr * nx + cc;
                    if (mask[q] == 0 and label[q] == l) label[q] = new;
                }
            }
        }
    }
}

/// The anchors of the painted features (see `Split.anchor`).
pub const Anchor = struct {
    /// The depth of the root under the feature (mm). 0: no anchors.
    depth: f64 = 0,
    /// The distance (mm) from the outside of the part to the root: the
    /// walls of the part and a margin.
    inset: f64 = 0,
    shape: Shape = .footprint,

    pub const Shape = enum { footprint, core };
};

/// The clean-up of a label region `l` in the area `room` (see
/// `Split.labelLayer`): no piece thinner than 2 r, and no gap narrower
/// than 2 r.
/// The skin band of an outline at a depth (mm), from the cache `bands`.
const Band = struct { d: f64, band: Paths };

fn bandOf(a: Allocator, outline: Paths, d: f64, bands: *std.ArrayList(Band)) Allocator.Error!Paths {
    for (bands.items) |b| if (b.d == d) return b.band;
    const inner = try offset_mod.offset(a, outline, -geom.fromMm(d), .{});
    const band = try clip.difference(a, outline, inner);
    try bands.append(a, .{ .d = d, .band = band });
    return band;
}

/// The count of layers of a depth of a top or bottom label (at least 2).
fn layersOf(depth: f64, lh: f64) usize {
    return @max(2, @as(usize, @intFromFloat(@ceil(depth / @max(lh, 1e-3) - 1e-6))));
}

fn clean(a: Allocator, l: Paths, room: Paths, r: i64) Allocator.Error!Paths {
    if (r <= 0) return l;
    const open = try clip.intersect(a, try offset_mod.opening(a, l, r, .{}), l);
    if (open.isEmpty()) return open;
    const grown = try offset_mod.offset(a, open, r, .{});
    const closed = try offset_mod.offset(a, grown, -r, .{});
    return clip.intersect(a, try clip.unite(a, closed, open), room);
}

/// A label of a part, ready for the cut of each layer (see
/// `Split.labelLayer`). The vectors are in the frame of the mesh of the
/// job.
pub const LabelCut = struct {
    /// The index of the label in the labels of `Split.initLabels`, and of
    /// its state in `Split.states`.
    index: u32 = 0,
    state: usize = 0,
    kind: Kind,
    /// The shape in the units of geom: for a side label in the axes
    /// (a, b), else in the axes (right, up) of the label.
    shape: Paths,
    origin: [3]f64,
    normal: [3]f64,
    right: [3]f64,
    up: [3]f64,
    /// A side label: a = normal × Z (level), b = normal × a.
    a: [3]f64 = .{ 0, 0, 0 },
    b: [3]f64 = .{ 0, 0, 0 },
    /// The depth (mm); 0: one line width.
    depth: f64,
    /// The range of the surface under the shape, as the distance from
    /// the plane of the label into the part (mm), and as z (mm).
    h_min: f64,
    h_max: f64,
    z_min: f64,
    z_max: f64,
    /// Ink, raised, or cut, and the relief (mm).
    mode: label_mod.Mode = .ink,
    relief: f64 = 0,
    /// A raised top label: the z of the top of its plateau (mesh frame):
    /// the relief over the highest point of the surface under it.
    plateau_z: f64 = 0,

    pub const Kind = enum { side, top, bottom };

    /// The area of layer i under the shape within `depth` of the surface:
    /// for a side label, the prism over the surface range and the depth,
    /// in the band of the depth; for a top or bottom label, the shape in
    /// the area within the layers of the depth of a top or a bottom (see
    /// `skin`). Empty out of the range of the label.
    fn region(c: *const LabelCut, a: Allocator, i: usize, outlines: []const Paths, z: f64, lh: f64, depth: f64, width: f64, frame: Frame, bands: *std.ArrayList(Band)) Allocator.Error!Paths {
        const outline = outlines[i];
        switch (c.kind) {
            .side => {
                const p = try c.side(a, z, c.h_min - width, c.h_max + depth + width, frame);
                if (p.isEmpty()) return p;
                return clip.intersect(a, p, try bandOf(a, outline, depth, bands));
            },
            .top, .bottom => {
                const layers = layersOf(depth, lh);
                const reach = (@as(f64, @floatFromInt(layers)) + 1) * lh / frame.z_scale + width;
                if (c.kind == .top and (z < c.z_min - reach or z > c.z_max + width)) return .empty;
                if (c.kind == .bottom and (z > c.z_max + reach or z < c.z_min - width)) return .empty;
                const p = try c.flat(a, z, frame);
                if (p.isEmpty()) return p;
                return clip.intersect(a, p, try c.skin(a, i, outlines, lh, depth));
            },
        }
    }

    /// The area of layer i within the layers of `depth` of a top (or of
    /// a bottom): the outline less the area that all those layers have.
    fn skin(c: *const LabelCut, a: Allocator, i: usize, outlines: []const Paths, lh: f64, depth: f64) Allocator.Error!Paths {
        const layers = layersOf(depth, lh);
        var keep: ?Paths = null;
        var j: usize = 1;
        while (j <= layers) : (j += 1) {
            const o: Paths = if (c.kind == .top) (if (i + j < outlines.len) outlines[i + j] else .empty) else (if (i >= j) outlines[i - j] else .empty);
            keep = if (keep) |kp| try clip.intersect(a, kp, o) else o;
            if (keep.?.isEmpty()) break;
        }
        return clip.difference(a, outlines[i], keep orelse .empty);
    }

    /// The cut of a label, or null if the shape is empty or no ray from
    /// it meets the mesh.
    fn init(gpa: Allocator, l: *const label_mod.Label, mesh: *const Mesh, grid: *const paint_mod.Grid) Allocator.Error!?LabelCut {
        var shape = label_mod.outline(gpa, l) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadFont => return null,
        };
        errdefer shape.deinit(gpa);
        if (shape.isEmpty()) {
            shape.deinit(gpa);
            return null;
        }
        const nz = l.normal[2];
        var c: LabelCut = .{
            .kind = if (nz > 0.7) .top else if (nz < -0.7) .bottom else .side,
            .shape = shape,
            .origin = l.origin,
            .normal = l.normal,
            .right = l.right,
            .up = l.up(),
            .depth = l.depth,
            .mode = l.mode,
            .relief = l.reliefMm(),
            .h_min = std.math.inf(f64),
            .h_max = -std.math.inf(f64),
            .z_min = std.math.inf(f64),
            .z_max = -std.math.inf(f64),
        };
        // The surface range: rays along -normal from the vertices of the
        // shape and from a grid of 1 mm in it, from 1 mm out of the plane.
        const back = 1.0;
        const Cast = struct {
            fn one(cc: *LabelCut, m: *const Mesh, g: *const paint_mod.Grid, s: f64, t: f64) void {
                const p: [3]f64 = .{
                    cc.origin[0] + s * cc.right[0] + t * cc.up[0] + back * cc.normal[0],
                    cc.origin[1] + s * cc.right[1] + t * cc.up[1] + back * cc.normal[1],
                    cc.origin[2] + s * cc.right[2] + t * cc.up[2] + back * cc.normal[2],
                };
                const o: paint_mod.V3 = .{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(p[2]) };
                const d: paint_mod.V3 = .{ @floatCast(-cc.normal[0]), @floatCast(-cc.normal[1]), @floatCast(-cc.normal[2]) };
                const hit = g.hit(m, o, d) orelse return;
                const h = @as(f64, hit.t) - back;
                cc.h_min = @min(cc.h_min, h);
                cc.h_max = @max(cc.h_max, h);
                const hz = p[2] - @as(f64, hit.t) * cc.normal[2];
                cc.z_min = @min(cc.z_min, hz);
                cc.z_max = @max(cc.z_max, hz);
            }
        };
        const pts = shape.points.items;
        const stride = @max(1, pts.len / 2000);
        var k: usize = 0;
        while (k < pts.len) : (k += stride) Cast.one(&c, mesh, grid, geom.toMm(pts[k].x), geom.toMm(pts[k].y));
        const box = shape.bounds();
        const step = geom.fromMm(1);
        var y = box.min.y + @divTrunc(step, 2);
        while (y < box.max.y) : (y += step) {
            var x = box.min.x + @divTrunc(step, 2);
            while (x < box.max.x) : (x += step) {
                if (geom.insideAny(shape, .init(x, y))) Cast.one(&c, mesh, grid, geom.toMm(x), geom.toMm(y));
            }
        }
        if (!(c.h_min <= c.h_max)) {
            shape.deinit(gpa);
            return null;
        }
        c.plateau_z = c.z_max + c.relief;
        if (c.kind == .side) {
            // The shape in the axes (a, b): a turn in the plane.
            c.a = label_mod.normalize(label_mod.cross(c.normal, .{ 0, 0, 1 })) orelse .{ 1, 0, 0 };
            c.b = label_mod.cross(c.normal, c.a);
            const ra = label_mod.dot(c.right, c.a);
            const ua = label_mod.dot(c.up, c.a);
            const rb = label_mod.dot(c.right, c.b);
            const ub = label_mod.dot(c.up, c.b);
            for (c.shape.points.items) |*q| {
                const s: f64 = @floatFromInt(q.x);
                const t: f64 = @floatFromInt(q.y);
                q.* = .init(@intFromFloat(@round(s * ra + t * ua)), @intFromFloat(@round(s * rb + t * ub)));
            }
        }
        return c;
    }

    /// The region of a side label on the plane at z (mesh frame), for h
    /// in [h_lo, h_hi] (mm), in the units of the job (before the band).
    fn side(c: *const LabelCut, a: Allocator, z: f64, h_lo: f64, h_hi: f64, frame: Frame) Allocator.Error!Paths {
        const nz = c.normal[2];
        const bz = c.b[2];
        const dz = z - c.origin[2];
        const box = c.shape.bounds();
        const hl = geom.fromMm(h_lo);
        const hh = geom.fromMm(h_hi);
        // The region in (s, h): s along a, h into the part.
        var sh: Paths = .empty;
        if (@abs(nz) < 1e-6) {
            // An upright face: the plane cuts the shape on one line of b.
            const line = dz / bz * geom.units_per_mm;
            if (line < @as(f64, @floatFromInt(box.min.y)) or line > @as(f64, @floatFromInt(box.max.y))) return .empty;
            const xs = try crossings(a, c.shape, line);
            var j: usize = 0;
            while (j + 1 < xs.len) : (j += 2) {
                const s0: i64 = @intFromFloat(@round(xs[j]));
                const s1: i64 = @intFromFloat(@round(xs[j + 1]));
                if (s1 <= s0) continue;
                try sh.append(a, &.{ .init(s0, hl), .init(s1, hl), .init(s1, hh), .init(s0, hh) });
            }
        } else {
            // A face with a draft: on the plane z, the point at t of the
            // shape is at h = (t bz - dz) / nz, an affine map of t.
            const m = [6]f64{ 1, 0, 0, 0, bz / nz, -dz * geom.units_per_mm / nz };
            const mapped = try affine(a, c.shape, m);
            var strip: Paths = .empty;
            try strip.append(a, &.{ .init(box.min.x - 1, hl), .init(box.max.x + 1, hl), .init(box.max.x + 1, hh), .init(box.min.x - 1, hh) });
            sh = try clip.intersect(a, mapped, strip);
        }
        if (sh.isEmpty()) return sh;
        // (s, h) to the XY of the mesh: p = origin + s a + t(h) b - h normal
        // with t(h) = (dz + h nz) / bz; then the frame of the job.
        const k = frame.xy_scale;
        var m: [6]f64 = undefined;
        for (0..2) |ax| {
            const o = c.origin[ax] + dz * c.b[ax] / bz;
            const g = nz * c.b[ax] / bz - c.normal[ax];
            const d = if (ax == 0) frame.dx else frame.dy;
            const cn = frame.center[ax];
            m[3 * ax + 0] = k * c.a[ax];
            m[3 * ax + 1] = k * g;
            m[3 * ax + 2] = ((o + d - cn) * k + cn) * geom.units_per_mm;
        }
        return affine(a, sh, m);
    }

    /// The shape of a top or bottom label projected along its normal onto
    /// the plane at z (mesh frame), in the units of the job.
    fn flat(c: *const LabelCut, a: Allocator, z: f64, frame: Frame) Allocator.Error!Paths {
        const n = c.normal;
        const k = frame.xy_scale;
        var m: [6]f64 = undefined;
        for (0..2) |ax| {
            const o = c.origin[ax] + (z - c.origin[2]) * n[ax] / n[2];
            const d = if (ax == 0) frame.dx else frame.dy;
            const cn = frame.center[ax];
            m[3 * ax + 0] = k * (c.right[ax] - c.right[2] * n[ax] / n[2]);
            m[3 * ax + 1] = k * (c.up[ax] - c.up[2] * n[ax] / n[2]);
            m[3 * ax + 2] = ((o + d - cn) * k + cn) * geom.units_per_mm;
        }
        return affine(a, c.shape, m);
    }
};

/// The paths under the affine map x' = m0 x + m1 y + m2, y' = m3 x +
/// m4 y + m5 (units). A map that mirrors turns each path back, so outer
/// paths stay counterclockwise.
fn affine(a: Allocator, p: Paths, m: [6]f64) Allocator.Error!Paths {
    var out: Paths = .empty;
    const flip = m[0] * m[4] - m[1] * m[3] < 0;
    for (0..p.count()) |i| {
        const poly = p.get(i);
        for (0..poly.len) |j| {
            const q = poly[if (flip) poly.len - 1 - j else j];
            const x: f64 = @floatFromInt(q.x);
            const y: f64 = @floatFromInt(q.y);
            try out.appendPoint(a, .init(@intFromFloat(@round(m[0] * x + m[1] * y + m[2])), @intFromFloat(@round(m[3] * x + m[4] * y + m[5]))));
        }
        try out.endPath(a, 3);
    }
    return out;
}

/// The x of the points where the line y = `line` (units) enters and
/// leaves the paths (non-zero rule), in pairs: [x0, x1, x2, x3, ...].
fn crossings(a: Allocator, p: Paths, line: f64) Allocator.Error![]f64 {
    const X = struct { x: f64, w: i32 };
    var list: std.ArrayList(X) = .empty;
    for (0..p.count()) |i| {
        const poly = p.get(i);
        for (poly, 0..) |q, j| {
            const r = poly[(j + 1) % poly.len];
            const qy: f64 = @floatFromInt(q.y);
            const ry: f64 = @floatFromInt(r.y);
            if ((qy <= line) == (ry <= line)) continue;
            const t = (line - qy) / (ry - qy);
            const qx: f64 = @floatFromInt(q.x);
            const rx: f64 = @floatFromInt(r.x);
            try list.append(a, .{ .x = qx + t * (rx - qx), .w = if (ry > qy) 1 else -1 });
        }
    }
    std.mem.sort(X, list.items, {}, struct {
        fn lt(_: void, u: X, v: X) bool {
            return u.x < v.x;
        }
    }.lt);
    var out: std.ArrayList(f64) = .empty;
    var wsum: i32 = 0;
    for (list.items) |c| {
        const was = wsum != 0;
        wsum += c.w;
        const now = wsum != 0;
        if (was != now) try out.append(a, c.x);
    }
    return out.items;
}

const Seg = struct { a: Point, b: Point, si: u8 };

/// The squared distance (in units²) from p to the segment a b.
fn dist2(p: Point, a: Point, b: Point) f64 {
    const ax: f64 = @floatFromInt(a.x);
    const ay: f64 = @floatFromInt(a.y);
    const dx: f64 = @as(f64, @floatFromInt(b.x)) - ax;
    const dy: f64 = @as(f64, @floatFromInt(b.y)) - ay;
    const px: f64 = @as(f64, @floatFromInt(p.x)) - ax;
    const py: f64 = @as(f64, @floatFromInt(p.y)) - ay;
    const l2 = dx * dx + dy * dy;
    const t = if (l2 > 0) std.math.clamp((px * dx + py * dy) / l2, 0, 1) else 0;
    const ex = px - t * dx;
    const ey = py - t * dy;
    return ex * ex + ey * ey;
}

/// The pieces of the edge of the outline, each with its state (see
/// `Split.layer`): 0 for the filament of the part. Each edge of the
/// outline splits into pieces of at most `w`.
fn edgePieces(a: Allocator, outline: Paths, segs: []const Seg, w: i64, out: *std.ArrayList(Seg)) Allocator.Error!void {
    // A grid of the segments: the key of each cell that the box of a
    // segment (grown by w) touches, sorted.
    const cell = 2 * w;
    const Entry = struct { key: u64, seg: u32 };
    var grid: std.ArrayList(Entry) = .empty;
    const key = struct {
        fn f(x: i64, y: i64) u64 {
            return (@as(u64, @as(u32, @bitCast(@as(i32, @truncate(x))))) << 32) | @as(u32, @bitCast(@as(i32, @truncate(y))));
        }
    }.f;
    for (segs, 0..) |sg, i| {
        const x0 = @divFloor(@min(sg.a.x, sg.b.x) - w, cell);
        const x1 = @divFloor(@max(sg.a.x, sg.b.x) + w, cell);
        const y0 = @divFloor(@min(sg.a.y, sg.b.y) - w, cell);
        const y1 = @divFloor(@max(sg.a.y, sg.b.y) + w, cell);
        var x = x0;
        while (x <= x1) : (x += 1) {
            var y = y0;
            while (y <= y1) : (y += 1) try grid.append(a, .{ .key = key(x, y), .seg = @intCast(i) });
        }
    }
    std.mem.sort(Entry, grid.items, {}, struct {
        fn lt(_: void, p: Entry, q: Entry) bool {
            return p.key < q.key;
        }
    }.lt);
    const tol2: f64 = @as(f64, @floatFromInt(w)) * @as(f64, @floatFromInt(w));
    var pieces: std.ArrayList(Point) = .empty;
    var states: std.ArrayList(u8) = .empty;
    for (0..outline.count()) |pi| {
        const poly = outline.get(pi);
        if (poly.len < 3) continue;
        pieces.clearRetainingCapacity();
        states.clearRetainingCapacity();
        // The pieces of the edges, and the state of each.
        for (poly, 0..) |p, i| {
            const q = poly[(i + 1) % poly.len];
            const len = p.dist(q);
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / @as(f64, @floatFromInt(w))))));
            for (0..n) |k| {
                const t0 = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                const t1 = @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(n));
                const s0 = lerp(p, q, t0);
                const m = lerp(p, q, (t0 + t1) / 2);
                try pieces.append(a, s0);
                // The nearest painted segment within w.
                var best: f64 = tol2;
                var st: u8 = 0;
                const kk = key(@divFloor(m.x, cell), @divFloor(m.y, cell));
                var lo: usize = 0;
                var hi: usize = grid.items.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (grid.items[mid].key < kk) lo = mid + 1 else hi = mid;
                }
                while (lo < grid.items.len and grid.items[lo].key == kk) : (lo += 1) {
                    const sg = segs[grid.items[lo].seg];
                    const d = dist2(m, sg.a, sg.b);
                    if (d <= best) {
                        best = d;
                        st = sg.si;
                    }
                }
                try states.append(a, st);
            }
        }
        const n = pieces.items.len;
        for (0..n) |i| try out.append(a, .{ .a = pieces.items[i], .b = pieces.items[(i + 1) % n], .si = states.items[i] });
    }
}

fn lerp(p: Point, q: Point, t: f64) Point {
    return .init(p.x + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(q.x - p.x)) * t))), p.y + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(q.y - p.y)) * t))));
}

const testing = std.testing;

test "paint split: a part painted all over prints all in its paint" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.box(gpa, 6, 6, 10);
    defer m.deinit(gpa);
    var p: paint_mod.Paint = .{};
    defer p.deinit(gpa);
    for (0..m.faces.items.len) |i| try p.setTriangle(gpa, i, 2);
    var s = try Split.init(gpa, &m, &p, 1);
    defer s.deinit();
    const b = m.bounds();
    var outline: Paths = .empty;
    defer outline.deinit(gpa);
    const x0 = geom.fromMm(b.min[0]);
    const y0 = geom.fromMm(b.min[1]);
    const x1 = geom.fromMm(b.max[0]);
    const y1 = geom.fromMm(b.max[1]);
    try outline.append(gpa, &.{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) });
    try s.compute(&.{outline}, &.{5 - b.min[2]}, .{ .z_base = b.min[2] }, 0.4, 0.8, 0.8, 1, .{}, 0.34);
    var area: f64 = 0;
    const red = s.region(0, 1);
    for (0..red.count()) |i| area += geom.areaMm2(red.get(i));
    try testing.expectApproxEqAbs(@as(f64, 36), area, 0.5);
    try testing.expect(s.region(0, 0).isEmpty());
}

test "paint split: a painted side colors a strip, and the rest is the part" {
    const gpa = testing.allocator;
    // A box 20 x 20 x 10 with its +x side painted with filament 2.
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 10);
    defer m.deinit(gpa);
    var p: paint_mod.Paint = .{};
    defer p.deinit(gpa);
    const b = m.bounds();
    for (m.faces.items, 0..) |f, i| {
        var all_x = true;
        for (f) |vi| if (m.vertices.items[vi].x < b.max[0] - 1e-3) {
            all_x = false;
        };
        if (all_x) try p.setTriangle(gpa, i, 2);
    }
    var s = try Split.init(gpa, &m, &p, 1);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.states.len);
    // One layer at z 5 (mesh frame), its outline the box.
    var outline: Paths = .empty;
    defer outline.deinit(gpa);
    const x0 = geom.fromMm(b.min[0]);
    const y0 = geom.fromMm(b.min[1]);
    const x1 = geom.fromMm(b.max[0]);
    const y1 = geom.fromMm(b.max[1]);
    try outline.append(gpa, &.{ .init(x0, y0), .init(x1, y0), .init(x1, y1), .init(x0, y1) });
    try s.compute(&.{outline}, &.{5 - b.min[2]}, .{ .z_base = b.min[2] }, 0.4, 1, 1, 1, .{}, 0.34);
    const red = s.region(0, 1);
    const part = s.region(0, 0);
    try testing.expect(!red.isEmpty() and !part.isEmpty());
    var red_area: f64 = 0;
    for (0..red.count()) |i| red_area += geom.areaMm2(red.get(i));
    var part_area: f64 = 0;
    for (0..part.count()) |i| part_area += geom.areaMm2(part.get(i));
    // The red side colors a band about 2 mm deep (the seed and the
    // steps), and the rest is the filament of the part.
    try testing.expectApproxEqAbs(@as(f64, 400), red_area + part_area, 1);
    try testing.expect(red_area > 25 and red_area < 50);
}

test "paint split: a cancel stops the compute, and a later compute starts again" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 10);
    defer m.deinit(gpa);
    var p: paint_mod.Paint = .{};
    defer p.deinit(gpa);
    try p.setTriangle(gpa, 0, 2);
    var s = try Split.init(gpa, &m, &p, 1);
    defer s.deinit();
    const b = m.bounds();
    var outline: Paths = .empty;
    defer outline.deinit(gpa);
    try outline.append(gpa, &.{ .init(geom.fromMm(b.min[0]), geom.fromMm(b.min[1])), .init(geom.fromMm(b.max[0]), geom.fromMm(b.min[1])), .init(geom.fromMm(b.max[0]), geom.fromMm(b.max[1])), .init(geom.fromMm(b.min[0]), geom.fromMm(b.max[1])) });
    var cancel: std.atomic.Value(bool) = .init(true);
    s.cancel = &cancel;
    try testing.expectError(error.Canceled, s.compute(&.{outline}, &.{5 - b.min[2]}, .{ .z_base = b.min[2] }, 0.4, 1, 1, 1, .{}, 0.34));
    try testing.expect(!s.done);
    cancel.store(false, .monotonic);
    try s.compute(&.{outline}, &.{5 - b.min[2]}, .{ .z_base = b.min[2] }, 0.4, 1, 1, 1, .{}, 0.34);
    try testing.expect(s.done);
    try testing.expect(!s.region(0, 0).isEmpty());
}

// ---- the labels ----

/// The outlines of a mesh at the middle of each layer of height h, and
/// their cut z (the mesh frame).
const TestLayers = struct {
    outlines: []Paths,
    cut: []f64,

    fn init(gpa: Allocator, m: *const Mesh, h: f64) !TestLayers {
        const slicer = @import("slicer.zig");
        const b = m.bounds();
        const n: usize = @intFromFloat(@floor((b.max[2] - b.min[2]) / h + 1e-9));
        const faces = try gpa.alloc(u32, m.faces.items.len);
        defer gpa.free(faces);
        for (faces, 0..) |*f, i| f.* = @intCast(i);
        const t: TestLayers = .{ .outlines = try gpa.alloc(Paths, n), .cut = try gpa.alloc(f64, n) };
        for (t.outlines, t.cut, 0..) |*o, *z, i| {
            z.* = b.min[2] + (@as(f64, @floatFromInt(i)) + 0.5) * h;
            o.* = try slicer.sliceAt(gpa, m, faces, z.*, 0, 0);
        }
        return t;
    }

    fn deinit(t: *TestLayers, gpa: Allocator) void {
        for (t.outlines) |*o| o.deinit(gpa);
        gpa.free(t.outlines);
        gpa.free(t.cut);
    }
};

/// A label of one text item.
fn testLabel(gpa: Allocator, text: []const u8, size: f64, origin: [3]f64, normal: [3]f64) !label_mod.Label {
    const items = try gpa.alloc(label_mod.Item, 1);
    items[0] = .{ .shape = .{ .text = .{ .text = try gpa.dupe(u8, text), .size = size } } };
    return .{ .id = 1, .name = try gpa.dupe(u8, ""), .origin = origin, .normal = normal, .right = label_mod.defaultRight(normal, .{ 1, 0, 0 }), .filament = 2, .items = items };
}

/// Splits the layers with the labels (no paint, part filament 1).
fn splitWith(gpa: Allocator, m: *const Mesh, t: TestLayers, labels: []const label_mod.Label, paint: *const paint_mod.Paint) !Split {
    var s = try Split.initLabels(gpa, m, paint, 1, labels);
    errdefer s.deinit();
    try s.compute(t.outlines, t.cut, .{}, 0.42, 0.8, 0.8, 1, .{}, 0.34);
    return s;
}

/// The largest distance (mm) from a point of `r` to the edge of `o`.
fn deepest(gpa: Allocator, r: Paths, o: Paths) !f64 {
    var idx = try geom.EdgeIndex.init(gpa, o, geom.fromMm(5));
    defer idx.deinit(gpa);
    var d: f64 = 0;
    for (r.points.items) |p| d = @max(d, idx.distance(p, geom.fromMm(5)));
    return geom.toMm(@intFromFloat(d));
}

test "label split: IH on the side of a box" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 10);
    defer m.deinit(gpa);
    var t = try TestLayers.init(gpa, &m, 0.2);
    defer t.deinit(gpa);
    var l = try testLabel(gpa, "IH", 5, .{ 20, 10, 5 }, .{ 1, 0, 0 });
    defer l.deinit(gpa);
    var p: paint_mod.Paint = .{};
    var s = try splitWith(gpa, &m, t, &.{l}, &p);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.states.len);
    try testing.expectEqual(@as(?u32, 0), s.label_of[1]);
    var shape = try label_mod.outline(gpa, &l);
    defer shape.deinit(gpa);
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    var with: usize = 0;
    for (0..t.outlines.len) |i| {
        const z = t.cut[i];
        const lab = s.region(i, 1);
        const base = s.region(i, 0);
        if (lab.isEmpty()) continue;
        with += 1;
        // Only the layers from z 2.5 to 7.5.
        try testing.expect(z > 2.5 - 1e-9 and z < 7.5 + 1e-9);
        // Within D of the +x face.
        const b = lab.bounds();
        try testing.expect(geom.toMm(b.min.x) > 20 - 0.42 - 0.005);
        try testing.expect(geom.toMm(b.max.x) <= 20 + 0.001);
        // The area: the length of the strokes on the cut line times D
        // (the text runs along +y; the cut line is t = z - 5).
        const xs = try crossings(a.allocator(), shape, (z - 5) * geom.units_per_mm);
        var len: f64 = 0;
        var j: usize = 0;
        while (j + 1 < xs.len) : (j += 2) len += (xs[j + 1] - xs[j]) / geom.units_per_mm;
        // (The layers at the ends cut the edge of the letters.)
        if (z > 2.5 + 1e-6 and z < 7.5 - 1e-6) try testing.expectApproxEqAbs(len * 0.42, lab.areaMm2(), 0.02);
        // The base keeps the rest, and the two do not overlap.
        try testing.expectApproxEqAbs(@as(f64, 400), lab.areaMm2() + base.areaMm2(), 0.01);
        try testing.expect((try clip.intersect(a.allocator(), lab.*, base.*)).areaMm2() < 1e-6);
    }
    // 5 mm of layers of 0.2 mm.
    try testing.expect(with >= 24 and with <= 26);
}

/// A box 20 x 20 x 10 whose +x side leans in by `deg` from the vertical.
fn draftBox(gpa: Allocator, deg: f64) !Mesh {
    const top = 20 - 10 * @tan(std.math.degreesToRadians(deg));
    const V = mesh_mod.Vec3;
    const v = struct {
        fn f(x: f64, y: f64, z: f64) V {
            return .{ .x = @floatCast(x), .y = @floatCast(y), .z = @floatCast(z) };
        }
    }.f;
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    try b.addQuad(v(0, 0, 0), v(0, 20, 0), v(20, 20, 0), v(20, 0, 0));
    try b.addQuad(v(0, 0, 10), v(top, 0, 10), v(top, 20, 10), v(0, 20, 10));
    try b.addQuad(v(0, 0, 0), v(20, 0, 0), v(top, 0, 10), v(0, 0, 10));
    try b.addQuad(v(0, 20, 0), v(0, 20, 10), v(top, 20, 10), v(20, 20, 0));
    try b.addQuad(v(0, 0, 0), v(0, 0, 10), v(0, 20, 10), v(0, 20, 0));
    try b.addQuad(v(20, 0, 0), v(20, 20, 0), v(top, 20, 10), v(top, 0, 10));
    return b.finish();
}

test "label split: the same depth on a face with a draft and on a cylinder" {
    const gpa = testing.allocator;
    const dr = std.math.degreesToRadians(10.0);
    var draft = try draftBox(gpa, 10);
    defer draft.deinit(gpa);
    var cyl = try mesh_mod.shapes.frustum(gpa, 0, 0, 15, 15, 10, 256);
    defer cyl.deinit(gpa);
    const cases = [_]struct { m: *const Mesh, origin: [3]f64, normal: [3]f64 }{
        .{ .m = &draft, .origin = .{ 20 - 5 * @tan(dr), 10, 5 }, .normal = .{ @cos(dr), 0, @sin(dr) } },
        .{ .m = &cyl, .origin = .{ 15, 0, 5 }, .normal = .{ 1, 0, 0 } },
    };
    for (cases) |c| {
        var t = try TestLayers.init(gpa, c.m, 0.2);
        defer t.deinit(gpa);
        var l = try testLabel(gpa, "IH", 5, c.origin, c.normal);
        defer l.deinit(gpa);
        var p: paint_mod.Paint = .{};
        var s = try splitWith(gpa, c.m, t, &.{l}, &p);
        defer s.deinit();
        var with: usize = 0;
        for (0..t.outlines.len) |i| {
            const lab = s.region(i, 1);
            if (lab.isEmpty()) continue;
            with += 1;
            // The deepest point of the label is D from the surface.
            const d = try deepest(gpa, lab.*, t.outlines[i]);
            try testing.expectApproxEqAbs(@as(f64, 0.42), d, 0.02);
        }
        try testing.expect(with >= 20);
    }
}

test "label split: no label on the inner side of a hollow box" {
    const gpa = testing.allocator;
    // A box 20 x 20 x 10 with walls of 2 mm (open at the top).
    var b: mesh_mod.Builder = .init(gpa);
    defer b.deinit();
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 2, 10);
    try mesh_mod.shapes.addBox(&b, 0, 18, 0, 20, 20, 10);
    try mesh_mod.shapes.addBox(&b, 0, 2, 0, 2, 18, 10);
    try mesh_mod.shapes.addBox(&b, 18, 2, 0, 20, 18, 10);
    var m = try b.finish();
    defer m.deinit(gpa);
    var t = try TestLayers.init(gpa, &m, 0.2);
    defer t.deinit(gpa);
    var l = try testLabel(gpa, "IH", 5, .{ 20, 10, 5 }, .{ 1, 0, 0 });
    defer l.deinit(gpa);
    var p: paint_mod.Paint = .{};
    var s = try splitWith(gpa, &m, t, &.{l}, &p);
    defer s.deinit();
    var with: usize = 0;
    for (0..t.outlines.len) |i| {
        const lab = s.region(i, 1);
        if (lab.isEmpty()) continue;
        with += 1;
        try testing.expect(geom.toMm(lab.bounds().min.x) > 20 - 0.42 - 0.005);
    }
    try testing.expect(with > 20);
}

test "label split: a top label colors only its top layers" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 9);
    defer m.deinit(gpa);
    // Layers of 0.3 mm: D = 0.42 is 2 layers.
    var t = try TestLayers.init(gpa, &m, 0.3);
    defer t.deinit(gpa);
    var l = try testLabel(gpa, "IH", 5, .{ 10, 10, 9 }, .{ 0, 0, 1 });
    defer l.deinit(gpa);
    var p: paint_mod.Paint = .{};
    var s = try splitWith(gpa, &m, t, &.{l}, &p);
    defer s.deinit();
    var shape = try label_mod.outline(gpa, &l);
    defer shape.deinit(gpa);
    const n = t.outlines.len;
    for (0..n) |i| {
        const lab = s.region(i, 1);
        if (i + 2 < n) {
            try testing.expect(lab.isEmpty());
            continue;
        }
        // The whole shape, on each of the top 2 layers.
        try testing.expectApproxEqAbs(shape.areaMm2(), lab.areaMm2(), 0.05);
    }
}

test "label split: a label wins over paint, and thin strokes and gaps clean up" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.box(gpa, 20, 20, 10);
    defer m.deinit(gpa);
    var t = try TestLayers.init(gpa, &m, 0.2);
    defer t.deinit(gpa);
    // The +x side painted with filament 3.
    var p: paint_mod.Paint = .{};
    defer p.deinit(gpa);
    for (m.faces.items, 0..) |f, i| {
        var all_x = true;
        for (f) |vi| if (m.vertices.items[vi].x < 20 - 1e-3) {
            all_x = false;
        };
        if (all_x) try p.setTriangle(gpa, i, 3);
    }
    // Three bars on the +x side: one 0.2 mm wide (too thin), and two of
    // 2 mm with a gap of 0.2 mm between them.
    const items = try gpa.alloc(label_mod.Item, 3);
    items[0] = .{ .at = .{ -6, 0 }, .shape = .{ .bar = .{ .width = 0.2, .height = 4 } } };
    items[1] = .{ .at = .{ 1.1, 0 }, .shape = .{ .bar = .{ .width = 2, .height = 4 } } };
    items[2] = .{ .at = .{ 3.3, 0 }, .shape = .{ .bar = .{ .width = 2, .height = 4 } } };
    var l: label_mod.Label = .{ .name = try gpa.dupe(u8, ""), .origin = .{ 20, 10, 5 }, .normal = .{ 1, 0, 0 }, .right = .{ 0, 1, 0 }, .filament = 2, .items = items };
    defer l.deinit(gpa);
    var s = try splitWith(gpa, &m, t, &.{l}, &p);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.states.len);
    const i: usize = 25; // z 5.1
    const lab = s.region(i, 2);
    const red = s.region(i, 1);
    // One piece from y 10.1 to 14.3 (the gap filled), none at y 4.
    try testing.expectEqual(@as(usize, 1), lab.count());
    const b = lab.bounds();
    try testing.expectApproxEqAbs(@as(f64, 10.1), geom.toMm(b.min.y), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 14.3), geom.toMm(b.max.y), 0.01);
    // The paint loses the label.
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    try testing.expect((try clip.intersect(a.allocator(), lab.*, red.*)).areaMm2() < 1e-6);
    try testing.expect(!red.isEmpty());
}
