//! The split of the layers of a painted part into the filaments of its
//! paint (see paint.zig).
//!
//! Each painted triangle (or piece of a triangle) colors the layers that
//! it touches:
//!
//! - A steep triangle crosses the cut plane of a layer in a segment. The
//!   edge of the outline splits into pieces of one line width, and each
//!   piece takes the state of the nearest painted segment within one line
//!   width. A run of pieces of one state is a band of one line width
//!   inside the edge (a seed). A grid of the segments makes each lookup
//!   short.
//! - A flat triangle that faces up colors the layers under it, down to the
//!   top thickness of the part; a flat triangle that faces down colors the
//!   layers over it, up to the bottom thickness. Its shape, seen from
//!   above, is a seed. So a painted top face prints its color in its top
//!   layers.
//!
//! The pieces with no painted segment near them are seeds of the
//! filament of the part. Then each seed grows into the outline, one line width a step, and
//! a seed takes only the area that no other seed took first. So each
//! point of the outline gets the color of the nearest painted surface, as
//! PrusaSlicer and Bambu Studio do it (they use a Voronoi diagram of the
//! colored edges; the steps of zslice give the same result to within a
//! step). After `max_steps` steps (about 2 mm) the rest goes to the
//! filament of the part: the color shows on the surface, and the core of
//! a wide region does not show. A painted top still prints its color in
//! its top layers (see above). A layer with no paint near it is all of
//! the filament of the part.
//!
//! Each filament of the part then slices as its own job, with the region
//! of its filament as the outline of each layer (see plate_job.zig). So
//! each region gets its own walls and infill, with its own filament.
//!
//! References (see REFERENCES.md): the multi-material segmentation of
//! PrusaSlicer (MultiMaterialSegmentation.cpp: the colored edges of a
//! layer, the projection of painted top and bottom surfaces); the method,
//! no code.
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
const Mesh = mesh_mod.Mesh;
const Paths = geom.Paths;
const Point = geom.Point;
const V3 = paint_mod.V3;

/// The most growth steps of the seeds (see the header).
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
    /// The volume (mm³) of the roots of the anchors (see `anchor`), for
    /// the tests and the stats.
    anchor_mm3: f64 = 0,

    pub fn deinit(s: *Split) void {
        for (s.regions) |*r| r.deinit(s.gpa);
        s.gpa.free(s.regions);
        s.gpa.free(s.leaves);
        s.gpa.free(s.states);
        s.* = undefined;
    }

    /// The painted pieces of `paint` on `mesh`. `base`: the filament of
    /// the part; paint of the same filament is no paint.
    pub fn init(gpa: Allocator, mesh: *const Mesh, paint: *const paint_mod.Paint, base: u8) Allocator.Error!Split {
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

    /// The index of a state in `states`, or null.
    pub fn indexOf(s: *const Split, state: u8) ?usize {
        return std.mem.indexOfScalar(u8, s.states, state);
    }

    /// The regions of all layers, from the full outline of each layer.
    /// `cut_z[i]`: the cut z of layer i in the frame of the job (before
    /// the z scale). `width`: the line width (mm). `top` and `bottom`: the
    /// depth (mm) of the color of a painted top or bottom face. `roots`:
    /// the anchors of the painted features (see `anchor`).
    pub fn compute(s: *Split, outlines: []const Paths, cut_z: []const f64, frame: Frame, width: f64, top: f64, bottom: f64, threads: usize, roots: Anchor) anyerror!void {
        if (s.done) return;
        const gpa = s.gpa;
        const n = outlines.len;
        s.layers = n;
        s.regions = try gpa.alloc(Paths, n * s.states.len);
        @memset(s.regions, .empty);
        const Pass = struct {
            s: *Split,
            outlines: []const Paths,
            cut_z: []const f64,
            frame: Frame,
            w: i64,
            top: f64,
            bottom: f64,
            fn run(c: *const @This(), i: usize) anyerror!void {
                try c.s.layer(i, c.outlines[i], c.frame.z_base + c.cut_z[i] / c.frame.z_scale, c.frame, c.w, c.top, c.bottom);
            }
        };
        const ctx: Pass = .{ .s = s, .outlines = outlines, .cut_z = cut_z, .frame = frame, .w = geom.fromMm(width), .top = top, .bottom = bottom };
        try parallel.forEach(threads, n, &ctx, Pass.run);
        if (roots.depth > 0 and s.states.len > 1) try s.anchor(outlines, cut_z, width, top, bottom, roots);
        s.done = true;
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
    /// REFERENCES.md).
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

    fn layer(s: *Split, i: usize, outline: Paths, z: f64, frame: Frame, w: i64, top: f64, bottom: f64) anyerror!void {
        const gpa = s.gpa;
        const k = s.states.len;
        const out = s.regions[i * k ..][0..k];
        if (outline.isEmpty()) return;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // The seeds of each painted state.
        const raw = try a.alloc(Paths, k);
        @memset(raw, .empty);
        var any = false;
        const zf: f32 = @floatCast(z);
        // The painted segments of the layer, in a grid of cells of 2w.
        var segs: std.ArrayList(Seg) = .empty;
        for (s.leaves) |lf| {
            const si = std.mem.indexOfScalar(u8, s.states, lf.state) orelse continue;
            const zlo = @min(lf.v[0][2], @min(lf.v[1][2], lf.v[2][2]));
            const zhi = @max(lf.v[0][2], @max(lf.v[1][2], lf.v[2][2]));
            if (lf.flat != 0) {
                // A flat piece: the layers within the depth under a top,
                // or over a bottom.
                const zm = (zlo + zhi) / 2;
                const in = if (lf.flat > 0) (zm >= zf - 1e-4 and zm <= zf + @as(f32, @floatCast(top))) else (zm <= zf + 1e-4 and zm >= zf - @as(f32, @floatCast(bottom)));
                if (!in) continue;
                var tri: [3]Point = .{ frame.xy(lf.v[0][0], lf.v[0][1]), frame.xy(lf.v[1][0], lf.v[1][1]), frame.xy(lf.v[2][0], lf.v[2][1]) };
                if (geom.area2(&tri) < 0) std.mem.swap(Point, &tri[0], &tri[2]);
                if (geom.area2(&tri) == 0) continue;
                try raw[si].append(a, &tri);
                any = true;
                continue;
            }
            if (zf < zlo or zf > zhi) continue;
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
        // The seeds of the edge: each piece of the edge of the outline
        // takes the state of the nearest painted segment within one line
        // width, else the filament of the part, and each run of one state
        // is a band of one line width inside the edge.
        if (segs.items.len > 0) try edgeSeeds(a, outline, segs.items, w, raw);
        // The claimed area of each state, and of all.
        const claimed = try a.alloc(Paths, k);
        var all: Paths = .empty;
        for (raw, claimed, 0..) |r, *c, j| {
            if (j == 0 or r.isEmpty()) {
                c.* = .empty;
                continue;
            }
            const u = try clip.unionAll(a, r, .non_zero);
            var in = try clip.intersect(a, u, outline);
            // A state with a lower index wins where two seeds overlap.
            if (!all.isEmpty()) in = try clip.difference(a, in, all);
            c.* = in;
            all = try clip.unite(a, all, in);
        }
        // The growth works only near the painted seeds: farther than
        // 2 max_steps + 2 steps, each point is of the filament of the
        // part. A core past the growth, in `near`, can go to the paint
        // around it (see below).
        const near = try clip.intersect(a, try offset_mod.offset(a, all, @as(i64, @intCast(2 * max_steps + 2)) * w, .{}), outline);
        // The rest of the outline is of the filament of the part.
        const far = try clip.difference(a, outline, near);
        // The seed of the filament of the part: the rest of the edge (its
        // runs from `edgeSeeds`), or the whole ring when no segment of
        // the layer is painted (a painted top only).
        if (segs.items.len == 0) {
            const inner = try offset_mod.offset(a, outline, -w, .{});
            raw[0] = try clip.difference(a, outline, inner);
        }
        claimed[0] = try clip.difference(a, try clip.intersect(a, try clip.unionAll(a, raw[0], .non_zero), near), all);
        all = try clip.unite(a, all, claimed[0]);
        // The growth: each step grows the front of each state (the area
        // it took in the step before) by one line width.
        var rest = try clip.difference(a, near, all);
        const front = try a.dupe(Paths, claimed);
        // The areas that each state took, joined once at the end.
        const took = try a.alloc(Paths, k);
        for (took, claimed) |*t, c| t.* = try c.clone(a);
        var step: usize = 0;
        while (!rest.isEmpty() and step < max_steps) : (step += 1) {
            var any_take = false;
            for (front, took) |*f, *t| {
                if (f.isEmpty() or rest.isEmpty()) continue;
                const grown = try offset_mod.offset(a, f.*, w, .{});
                const take = try clip.intersect(a, grown, rest);
                f.* = take;
                if (take.isEmpty()) continue;
                any_take = true;
                try t.appendAll(a, take);
                rest = try clip.difference(a, rest, take);
            }
            if (!any_take) break;
        }
        // A core that the steps did not reach, with no edge of the
        // filament of the part around it (a wide painted letter): it takes
        // the painted state that is around it, so the letter prints in one
        // filament.
        var holes = false;
        for (0..rest.count()) |pi| holes = holes or geom.area2(rest.get(pi)) < 0;
        if (!holes) for (0..rest.count()) |pi| {
            var one: Paths = .empty;
            try one.append(a, rest.get(pi));
            const ring = try offset_mod.offset(a, one, w, .{});
            // Next to the far area: of the filament of the part.
            if (!(try clip.intersect(a, ring, far)).isEmpty()) continue;
            var best: usize = 0;
            var best_area: f64 = 0;
            for (took, 0..) |t, j| {
                if (t.isEmpty()) continue;
                const touch = try clip.intersect(a, ring, try clip.unionAll(a, t, .non_zero));
                var ar: f64 = 0;
                for (0..touch.count()) |q| ar += geom.areaMm2(touch.get(q));
                if (j == 0 and ar > 0) {
                    best = 0;
                    break;
                }
                if (ar > best_area) {
                    best_area = ar;
                    best = j;
                }
            }
            if (best != 0) try took[best].append(a, rest.get(pi));
        };
        for (claimed, took) |*c, t| c.* = try clip.unionAll(a, t, .non_zero);
        // The painted regions, and the rest for the filament of the part.
        var painted: Paths = .empty;
        for (claimed[1..]) |c| painted = try clip.unite(a, painted, c);
        out[0] = try clip.difference(gpa, outline, painted);
        for (out[1..], claimed[1..]) |*o, c| o.* = try c.clone(gpa);
    }
};

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

/// The bands of the edge of each state (see `Split.layer`): `raw[k]` gets
/// the bands of state k, and `raw[0]` the bands of the filament of the
/// part. Each edge of the outline splits into pieces of at most `w`.
fn edgeSeeds(a: Allocator, outline: Paths, segs: []const Seg, w: i64, raw: []Paths) Allocator.Error!void {
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
        // One state for the whole polygon: its ring.
        var same = true;
        for (states.items) |st| same = same and st == states.items[0];
        const inner = try a.alloc(Point, n);
        for (0..n) |i| inner[i] = inward(pieces.items, i, w);
        if (same) {
            const r = &raw[states.items[0]];
            try r.append(a, pieces.items);
            const rev = try a.dupe(Point, inner);
            std.mem.reverse(Point, rev);
            try r.append(a, rev);
            continue;
        }
        // The runs: start at a change of state.
        var start: usize = 0;
        while (states.items[start] == states.items[(start + n - 1) % n]) start += 1;
        var i: usize = 0;
        while (i < n) {
            const st = states.items[(start + i) % n];
            var j = i;
            while (j < n and states.items[(start + j) % n] == st) j += 1;
            // The band of pieces i to j - 1: the outer points (j - i + 1 of
            // them, the end of the last piece too), then the inner points
            // back.
            var band: std.ArrayList(Point) = .empty;
            for (i..j + 1) |k| try band.append(a, pieces.items[(start + k) % n]);
            var k = j + 1;
            while (k > i) {
                k -= 1;
                try band.append(a, inner[(start + k) % n]);
            }
            try raw[st].append(a, band.items);
            i = j;
        }
    }
}

fn lerp(p: Point, q: Point, t: f64) Point {
    return .init(p.x + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(q.x - p.x)) * t))), p.y + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(q.y - p.y)) * t))));
}

/// Point i of a closed polygon moved by w to the inside (the left of the
/// edges: the material is on the left).
fn inward(poly: []const Point, i: usize, w: i64) Point {
    const n = poly.len;
    const p = poly[i];
    const prev = poly[(i + n - 1) % n];
    const next = poly[(i + 1) % n];
    const left = struct {
        fn f(a: Point, b: Point) [2]f64 {
            const dx: f64 = @floatFromInt(b.x - a.x);
            const dy: f64 = @floatFromInt(b.y - a.y);
            const l = @sqrt(dx * dx + dy * dy);
            if (!(l > 0)) return .{ 0, 0 };
            return .{ -dy / l, dx / l };
        }
    }.f;
    const n1 = left(prev, p);
    const n2 = left(p, next);
    var bx = n1[0] + n2[0];
    var by = n1[1] + n2[1];
    const bl = @sqrt(bx * bx + by * by);
    if (!(bl > 1e-9)) {
        bx = n2[0];
        by = n2[1];
    } else {
        bx /= bl;
        by /= bl;
    }
    // The miter length, at most 3 w at a sharp corner.
    const c = @max(bx * n2[0] + by * n2[1], 0.33);
    const d = @as(f64, @floatFromInt(w)) / c;
    return .init(p.x + @as(i64, @intFromFloat(@round(bx * d))), p.y + @as(i64, @intFromFloat(@round(by * d))));
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
    try s.compute(&.{outline}, &.{5 - b.min[2]}, .{ .z_base = b.min[2] }, 0.4, 0.8, 0.8, 1, .{});
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
    try s.compute(&.{outline}, &.{5 - b.min[2]}, .{ .z_base = b.min[2] }, 0.4, 1, 1, 1, .{});
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
