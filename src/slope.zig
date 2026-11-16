//! Slope smoothing and slope ironing: beads that fill the steps of a
//! sloped top surface, and ironing passes over them.
//!
//! A slicer prints a sloped top surface as a stair. Each layer is a little
//! smaller than the layer below it, so the top of layer N - 1 has a narrow
//! flat ledge outside the outline of layer N. In a cut across the edge, the
//! step is a corner: the side of layer N (height h, the layer height) and
//! the ledge (width L). The ideal surface is the line from the top of the
//! side to the outer edge of the ledge. Between the corner and that line
//! is a triangle of area h * L / 2 with no plastic in it.
//!
//! After all paths of layer N, the nozzle goes back along the edge of the
//! layer and lays one bead in each corner. All other paths of the layer
//! stay planar: this is a separate pass. The steps:
//!
//! 1. The ledge. It is the top surface of layer N - 1: the outline of
//!    layer N - 1 minus the outline of layer N. It faces up by its
//!    definition, so an overhang (layer N outside layer N - 1) is never
//!    in it.
//! 2. Only slopes. A flat top is wide: the parts of the ledge that hold a
//!    disk of `slope_smoothing_max_width` line widths are removed, with a
//!    line width around them. A ledge with no ledge of the layer above or
//!    below next to it is a step of one layer (for example, a shelf), and
//!    it is removed too. Then the parts thinner than
//!    `slope_smoothing_min_width` line widths are removed (an opening).
//!    On a vertical wall the ledge is empty, or thinner than this.
//! 3. The width of the step. The code walks along each loop of the outline
//!    of layer N, with a sample at each vertex and at most half a line
//!    width apart. At each sample, the normal points away from the
//!    material. A sample is on a ledge if a point a little out along the
//!    normal is in the region of step 2. The width L of the step is the
//!    distance along the normal from the sample to the edge of layer
//!    N - 1, averaged with the next samples so that it changes smoothly.
//! 4. The bead. Its area is the area of the triangle, h * L / 2, times
//!    `slope_smoothing_flow`. Its center is over the middle of the ledge,
//!    L / 2 out from the side of layer N. Its top (the nozzle tip) is at
//!    half the step height, z_N-1 + h / 2: a flat bead of width L and
//!    height h / 2 has the area of the triangle, and its top is where the
//!    ideal surface crosses the middle of the ledge.
//! 5. The nozzle clearance. The nozzle is a cone of half angle
//!    `machine.nozzle_cone_angle` on a flat tip of radius
//!    `machine.nozzle_tip_radius`. Layer N is printed, and its top is z_N.
//!    At the height z_N, the cone of a nozzle with its tip at z has the
//!    radius r_tip + (z_N - z) * tan(angle). The nozzle clears layer N if
//!    the distance c from its axis to the outline of layer N is at least
//!    this. So the lowest tip is z_N - (c - r_tip) / tan(angle), and z_N
//!    if c is less than r_tip: there the flat tip slides on the top of
//!    layer N, and the plastic fills the corner under it. The nozzle z is
//!    the higher of the two heights, and never above z_N. So it is always
//!    between z_N-1 + h / 2 and z_N.
//!
//!    The z comes only from the geometry of the step at that point (its
//!    height, its width, and the room for the nozzle), and one rule
//!    covers all ledges. Where the ledge gets wider along the edge, the
//!    flow goes up, and the nozzle can go lower.
//! 6. Paths. The samples on a ledge make runs along the loop. A loop with
//!    all samples on a ledge is a closed path. A run shorter than 4 line
//!    widths is dropped. Points on a straight line with the same z and
//!    area are removed.
//!
//! 7. Slope ironing (`slope_ironing`). After the beads, the nozzle goes
//!    over the same ledges again, in `slope_ironing_passes` passes at the
//!    fractions (k + 1/2) / n of the ledge width out from the side. The
//!    filled step has its surface on the line from the top of the side
//!    (z_N) to the outer edge of the ledge (z_N-1). So at the fraction f,
//!    the nozzle tip is at the height of that surface, z_N-1 + h (1 - f),
//!    or higher where the cone needs room (step 5), and never lower than
//!    z_N-1 + h / 4 or higher than z_N. The flow is
//!    `slope_ironing_flow` of a normal line, as in planar ironing: the hot
//!    tip makes the bead tops flat, and the small flow fills the gaps.
//!    It uses the same rule for all ledges.
//!
//! The G-code writes each point with its own Z (see gcode.zig). The layer
//! plan has the z and the bead area of each point (`LayerPlan.point_z`).
//!
//! References (see REFERENCES.md): extra beads between the layers to fill
//! the stair of a slope (IBM, US 5,402,351, expired); the anti-aliasing
//! of fused filament deposition (Song, Ray, Sokolov, and Lefebvre, CAD
//! 2017); nonplanar surface layers and the nozzle collision check of
//! Ahlers et al. (CASE 2019); and the curved layers of Chakraborty et al.
//! (CAD 2008). Ironing: a hot nozzle pass with a small flow over a top
//! surface, as in PrusaSlicer and Cura (the method, not code).

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const flow = @import("flow.zig");
const settings_mod = @import("settings.zig");
const slicer = @import("slicer.zig");
const PointZ = @import("layer.zig").PointZ;
const Point = geom.Point;
const Paths = geom.Paths;
const Resolved = settings_mod.Resolved;

/// One smoothing path: its nozzle points, and the z and bead area of each.
pub const Bead = struct {
    points: []Point,
    data: []PointZ,
    closed: bool,
};

/// The inputs of the smoothing beads of one layer.
pub const Input = struct {
    resolved: *const Resolved,
    layers: []const slicer.Layer,
    outlines: []const Paths,
    /// The top surface of each layer (see layer.surfaces), or empty: then
    /// the code makes the ones that it needs.
    tops: []const Paths = &.{},
};

/// A point on a loop of the outline.
const Sample = struct {
    q: Point,
    /// The unit normal, away from the material.
    nx: f64,
    ny: f64,
    on: bool = false,
    /// The width of the step (mm).
    width: f64 = 0,
};

/// The top surface of layer j: its outline minus the outline above.
fn topOf(s: Allocator, in: Input, j: usize) Allocator.Error!Paths {
    if (j < in.tops.len) return in.tops[j];
    if (j + 1 >= in.outlines.len) return in.outlines[j];
    return clip.difference(s, in.outlines[j], in.outlines[j + 1]);
}

/// The region of step 2: the ledges of layer i - 1 that get a bead.
pub fn ledgeRegion(s: Allocator, in: Input, i: usize) Allocator.Error!Paths {
    if (i == 0 or i >= in.outlines.len) return .empty;
    const r = in.resolved;
    const p = r.settings.project;
    const w = geom.fromMm(r.line_width);
    const ledge = try topOf(s, in, i - 1);
    if (ledge.isEmpty()) return .empty;
    // Flat tops: the parts that hold a disk of the maximum width.
    const max_r = @divTrunc(geom.fromMm(p.slope_smoothing_max_width * r.line_width), 2);
    var narrow = ledge;
    const wide = try offset_mod.opening(s, ledge, max_r, .{});
    if (!wide.isEmpty()) narrow = try clip.difference(s, ledge, try offset_mod.offset(s, wide, w, .{}));
    if (narrow.isEmpty()) return .empty;
    // A slope: the ledge of the layer above (the top of layer i) or below
    // (the top of layer i - 2) is next to it.
    var near: Paths = .empty;
    try near.appendAll(s, try topOf(s, in, i));
    if (i >= 2) try near.appendAll(s, try topOf(s, in, i - 2));
    if (near.isEmpty()) return .empty;
    const joined = try clip.unionAll(s, near, .non_zero);
    narrow = try clip.intersect(s, narrow, try offset_mod.offset(s, joined, w, .{}));
    // The parts thinner than the minimum width.
    const min_r = @divTrunc(geom.fromMm(p.slope_smoothing_min_width * r.line_width), 2);
    return offset_mod.opening(s, narrow, min_r, .{});
}

/// The smoothing beads of layer i, in the order of the loops of its
/// outline. The memory is in `s`.
pub fn beads(s: Allocator, in: Input, i: usize) Allocator.Error![]Bead {
    if (i == 0 or i >= in.outlines.len) return &.{};
    const region = try ledgeRegion(s, in, i);
    return stepPaths(s, in, i, region, .smooth);
}

/// The slope ironing paths of layer i: `slope_ironing_passes` passes over
/// each ledge that gets a smoothing bead. The memory is in `s`.
pub fn ironing(s: Allocator, in: Input, i: usize) Allocator.Error![]Bead {
    if (i == 0 or i >= in.outlines.len) return &.{};
    const region = try ledgeRegion(s, in, i);
    if (region.isEmpty()) return &.{};
    const n = in.resolved.settings.project.slope_ironing_passes;
    var out: std.ArrayList(Bead) = .empty;
    for (0..n) |k| {
        const f = (@as(f64, @floatFromInt(k)) + 0.5) / @as(f64, @floatFromInt(n));
        try out.appendSlice(s, try stepPaths(s, in, i, region, .{ .iron = f }));
    }
    return out.items;
}

/// What a path along the steps does.
pub const Pass = union(enum) {
    /// A smoothing bead (step 4).
    smooth,
    /// An ironing pass at this fraction of the ledge width out from the
    /// side of layer N (see the file comment).
    iron: f64,
};

/// The paths of one pass along the steps of layer i, over `region` (see
/// `ledgeRegion`).
fn stepPaths(s: Allocator, in: Input, i: usize, region: Paths, pass: Pass) Allocator.Error![]Bead {
    const r = in.resolved;
    const p = r.settings.project;
    const m = r.settings.machine;
    const outline = in.outlines[i];
    const below = in.outlines[i - 1];
    if (outline.isEmpty() or below.isEmpty()) return &.{};
    // The height of this layer (it can differ from the layer height of
    // the settings, see slicer.layerTableSpans). The layer starts at the
    // top of the layer below.
    const z_top = in.layers[i].z;
    const h = in.layers[i].height;
    const z_low = z_top - h;
    if (!(h > 0)) return &.{};
    if (region.isEmpty()) return &.{};

    const w_mm = r.line_width;
    const min_l = p.slope_smoothing_min_width * w_mm;
    const max_l = p.slope_smoothing_max_width * w_mm;
    const tan_a = @tan(m.nozzle_cone_angle * std.math.pi / 180.0);
    // The farthest distance that a test needs, with a margin.
    const reach_mm = @max(max_l, m.nozzle_tip_radius + h * tan_a) + w_mm;
    const reach = geom.fromMm(reach_mm);
    const region_idx: geom.EdgeIndex = try .init(s, region, 1);
    const below_idx: geom.EdgeIndex = try .init(s, below, reach);
    const outline_idx: geom.EdgeIndex = try .init(s, outline, reach);
    const step: f64 = @floatFromInt(@max(@divTrunc(geom.fromMm(w_mm), 2), 50));
    const probe = @max(min_l / 2, 0.02);
    const min_run = 4 * w_mm;

    var out: std.ArrayList(Bead) = .empty;
    var samples: std.ArrayList(Sample) = .empty;
    for (0..outline.count()) |k| {
        const poly = outline.get(k);
        if (poly.len < 3) continue;
        // Step 3: the samples, with the normal away from the material.
        // The material is on the left of each edge (outer loops are
        // counterclockwise and holes clockwise), so the normal is on the
        // right.
        samples.clearRetainingCapacity();
        for (poly, 0..) |a, j| {
            const b = poly[(j + 1) % poly.len];
            const prev = poly[(j + poly.len - 1) % poly.len];
            const n_in = rightNormal(prev, a);
            const n_out = rightNormal(a, b);
            var vx = n_in[0] + n_out[0];
            var vy = n_in[1] + n_out[1];
            const vl = std.math.hypot(vx, vy);
            if (vl > 1e-6) {
                vx /= vl;
                vy /= vl;
            } else {
                vx = n_out[0];
                vy = n_out[1];
            }
            try samples.append(s, .{ .q = a, .nx = vx, .ny = vy });
            const len = a.dist(b);
            var t = step;
            while (t < len - step / 2) : (t += step) {
                const f = t / len;
                const q: Point = .init(a.x + @as(i64, @intFromFloat(@round(f * @as(f64, @floatFromInt(b.x - a.x))))), a.y + @as(i64, @intFromFloat(@round(f * @as(f64, @floatFromInt(b.y - a.y))))));
                try samples.append(s, .{ .q = q, .nx = n_out[0], .ny = n_out[1] });
            }
        }
        const ss = samples.items;
        for (ss) |*sm| {
            const pr = moveBy(sm.q, sm.nx, sm.ny, probe);
            if (!region_idx.inside(pr)) continue;
            const l = ledgeWidth(below_idx, sm, 1.25 * max_l, min_l / 4) orelse continue;
            if (l < 0.5 * min_l) continue;
            sm.on = true;
            sm.width = std.math.clamp(l, min_l, max_l);
        }
        // The average width over each sample and its neighbors on a ledge.
        const raw = try s.alloc(f64, ss.len);
        for (ss, raw) |sm, *rw| rw.* = sm.width;
        for (ss, 0..) |*sm, j| {
            if (!sm.on) continue;
            var sum = raw[j];
            var n: f64 = 1;
            for ([_]usize{ (j + ss.len - 1) % ss.len, (j + 1) % ss.len }) |nb| if (ss[nb].on) {
                sum += raw[nb];
                n += 1;
            };
            sm.width = sum / n;
        }

        // Steps 4 and 5: the nozzle point and the bead of each sample.
        const pts = try s.alloc(Point, ss.len);
        const data = try s.alloc(PointZ, ss.len);
        for (ss, 0..) |*sm, j| {
            if (!sm.on) continue;
            // The place across the ledge (a fraction of its width), the
            // height of the filled surface there, and the plastic.
            const f: f64 = switch (pass) {
                .smooth => 0.5,
                .iron => |fr| fr,
            };
            const z_surface = z_low + h * (1 - f);
            const area = switch (pass) {
                .smooth => 0.5 * h * sm.width * p.slope_smoothing_flow,
                .iron => p.slope_ironing_flow * flow.beadArea(w_mm, h),
            };
            const at = moveBy(sm.q, sm.nx, sm.ny, f * sm.width);
            // The bead must lie on layer N - 1, outside layer N.
            if (outline_idx.inside(at) or !below_idx.inside(at)) {
                sm.on = false;
                continue;
            }
            // The distance from the nozzle axis to layer N, and the lowest
            // tip that the cone allows there.
            const clear = geom.toMm(@intFromFloat(outline_idx.distance(at, reach)));
            const room = clear - m.nozzle_tip_radius;
            const z_clear = if (room <= 0) z_top else if (tan_a > 1e-6) z_top - room / tan_a else z_low;
            const z = std.math.clamp(@max(z_clear, z_surface), z_low + h / 4, z_top);
            pts[j] = at;
            data[j] = .{ .z = @floatCast(z), .area = @floatCast(area) };
        }

        // Step 6: the runs of samples on a ledge.
        var all_on = true;
        var first_off: usize = 0;
        for (ss, 0..) |sm, j| if (!sm.on) {
            all_on = false;
            first_off = j;
            break;
        };
        // Walk once around the loop from a sample that is not on a ledge
        // (or from the first sample). In a tight inside corner, the points
        // out along the normals cross: a point that goes back against the
        // direction of the outline is skipped.
        var run_start: ?usize = null;
        var last: usize = 0;
        var idx_pts: std.ArrayList(Point) = .empty;
        var idx_data: std.ArrayList(PointZ) = .empty;
        for (1..ss.len + 1) |step_i| {
            const j = (first_off + step_i) % ss.len;
            if (ss[j].on) {
                if (run_start == null) {
                    run_start = j;
                    idx_pts.clearRetainingCapacity();
                    idx_data.clearRetainingCapacity();
                } else {
                    const along = geom.dot3(ss[last].q, ss[j].q, ss[last].q.add(pts[j].sub(pts[last])));
                    if (along <= 0) continue;
                }
                last = j;
                try idx_pts.append(s, pts[j]);
                try idx_data.append(s, data[j]);
            } else if (run_start != null) {
                try addRun(s, &out, idx_pts.items, idx_data.items, 0, idx_pts.items.len, false, min_run);
                run_start = null;
            }
        }
        if (all_on and run_start != null) {
            try addRun(s, &out, idx_pts.items, idx_data.items, 0, idx_pts.items.len, true, min_run);
        }
    }
    return out.items;
}

/// Adds the points from `start` to `end` as a bead, if it is long enough.
/// Removes the points on a straight line with the same z and area.
fn addRun(s: Allocator, out: *std.ArrayList(Bead), pts: []const Point, data: []const PointZ, start: usize, end: usize, closed: bool, min_run_mm: f64) Allocator.Error!void {
    const n = end - start;
    if (n < 2) return;
    var len: f64 = 0;
    for (start + 1..end) |j| len += pts[j - 1].dist(pts[j]);
    if (closed) len += pts[end - 1].dist(pts[start]);
    if (geom.toMm(@intFromFloat(len)) < min_run_mm) return;
    var kp: std.ArrayList(Point) = .empty;
    var kd: std.ArrayList(PointZ) = .empty;
    for (start..end) |j| {
        const last = j + 1 == end;
        if (j > start and !last and kp.items.len > 0) {
            const a = kp.items[kp.items.len - 1];
            const ad = kd.items[kd.items.len - 1];
            const b = pts[j + 1];
            const same = @abs(data[j].z - ad.z) < 1e-4 and @abs(data[j + 1].z - ad.z) < 1e-4 and
                @abs(data[j].area - ad.area) < 1e-5 and @abs(data[j + 1].area - ad.area) < 1e-5;
            const ab = a.dist(b);
            const off: f64 = if (ab > 0) @as(f64, @floatFromInt(@abs(geom.cross3(a, b, pts[j])))) / ab else 0;
            if (same and off < 5) continue;
        }
        try kp.append(s, pts[j]);
        try kd.append(s, data[j]);
    }
    if (kp.items.len < 2) return;
    try out.append(s, .{ .points = kp.items, .data = kd.items, .closed = closed and kp.items.len > 2 });
}

/// The width of the ledge at a sample: the distance along its normal to
/// the edge of the layer below, or null if it is more than `max`. The
/// search walks out in steps of `step`, then halves the last step 8 times.
fn ledgeWidth(below: geom.EdgeIndex, sm: *const Sample, max: f64, step: f64) ?f64 {
    var lo: f64 = 0;
    var hi: f64 = step;
    while (below.inside(moveBy(sm.q, sm.nx, sm.ny, hi))) {
        lo = hi;
        hi += step;
        if (hi > max) return null;
    }
    for (0..8) |_| {
        const mid = (lo + hi) / 2;
        if (below.inside(moveBy(sm.q, sm.nx, sm.ny, mid))) lo = mid else hi = mid;
    }
    return (lo + hi) / 2;
}

fn rightNormal(a: Point, b: Point) [2]f64 {
    const dx: f64 = @floatFromInt(b.x - a.x);
    const dy: f64 = @floatFromInt(b.y - a.y);
    const l = std.math.hypot(dx, dy);
    if (l == 0) return .{ 0, 0 };
    return .{ dy / l, -dx / l };
}

fn moveBy(q: Point, nx: f64, ny: f64, mm: f64) Point {
    const d = mm * geom.units_per_mm;
    return .init(q.x + @as(i64, @intFromFloat(@round(nx * d))), q.y + @as(i64, @intFromFloat(@round(ny * d))));
}

const testing = std.testing;
const mesh_mod = @import("mesh.zig");
const layer_mod = @import("layer.zig");

/// The outlines of a mesh, for the tests.
const Sliced = struct {
    layers: []slicer.Layer,
    outlines: []Paths,

    fn init(gpa: Allocator, m: *const mesh_mod.Mesh, height: f64) !Sliced {
        const layers = try slicer.layerTable(gpa, height, 0.3, 0.2);
        var idx = try slicer.FaceIndex.build(gpa, m, layers, 0);
        defer idx.deinit(gpa);
        const outlines = try gpa.alloc(Paths, layers.len);
        for (outlines, 0..) |*o, li| o.* = try slicer.sliceAt(gpa, m, idx.get(li), layers[li].sliceZ(), 5, 1000);
        return .{ .layers = layers, .outlines = outlines };
    }

    fn deinit(t: *Sliced, gpa: Allocator) void {
        for (t.outlines) |*o| o.deinit(gpa);
        gpa.free(t.outlines);
        gpa.free(t.layers);
    }
};

/// The length of a bead (mm), and its volume (mm³): the mean area of
/// each segment times its length.
fn beadVolume(b: Bead) [2]f64 {
    var len: f64 = 0;
    var vol: f64 = 0;
    const n = b.points.len;
    const segs = if (b.closed) n else n - 1;
    for (0..segs) |j| {
        const k = (j + 1) % n;
        const l = geom.toMm(@intFromFloat(b.points[j].dist(b.points[k])));
        len += l;
        vol += l * (b.data[j].area + b.data[k].area) / 2;
    }
    return .{ len, vol };
}

test "a wedge: one bead along the sloped edge, with the volume of the step" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = arena.allocator();
    // The top rises 5 mm over 10 mm: each 0.2 mm layer steps 0.4 mm in X.
    var m = try mesh_mod.shapes.wedge(gpa, 10, 20, 1, 6);
    defer m.deinit(gpa);
    var sl = try Sliced.init(gpa, &m, 6);
    defer sl.deinit(gpa);
    var st: settings_mod.Settings = .{};
    st.project.slope_smoothing = true;
    // A nozzle with a sharp tip: the bead stays at half the step height.
    st.machine.nozzle_tip_radius = 0;
    const r = try st.resolve();
    const in: Input = .{ .resolved = &r, .layers = sl.layers, .outlines = sl.outlines };
    const i = 12;
    const set = try beads(s, in, i);
    try testing.expectEqual(@as(usize, 1), set.len);
    const z_low = sl.layers[i - 1].z;
    const z_top = sl.layers[i].z;
    const h = z_top - z_low;
    // The left edge of layer i is at x = (z - 1) * 2, at the cut plane.
    const edge_x = (sl.layers[i].sliceZ() - 1) * 2;
    for (set[0].points, set[0].data) |q, d| {
        try testing.expect(d.z >= z_low + h / 2 - 1e-4 and d.z <= z_top + 1e-4);
        try testing.expectApproxEqAbs(z_low + h / 2, d.z, 1e-4);
        // The bead is on the ledge, left of the edge of layer i.
        const x = geom.toMm(q.x);
        try testing.expect(x < edge_x and x > edge_x - 0.4);
    }
    // The volume of the triangle: h * L / 2 for each mm, with L = 0.4.
    const lv = beadVolume(set[0]);
    try testing.expect(lv[0] > 15);
    try testing.expectApproxEqRel(0.5 * h * 0.4 * lv[0], lv[1], 0.03);
}

test "the nozzle clearance: a wide tip keeps the nozzle at the top of the layer" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = arena.allocator();
    // Each layer steps 0.8 mm: the nozzle is 0.4 mm out from the side.
    var m = try mesh_mod.shapes.wedge(gpa, 20, 20, 1, 6);
    defer m.deinit(gpa);
    var sl = try Sliced.init(gpa, &m, 6);
    defer sl.deinit(gpa);
    const i = 12;
    const z_low = sl.layers[i - 1].z;
    const z_top = sl.layers[i].z;
    const h = z_top - z_low;
    var zs: [3]f64 = undefined;
    for ([_]f64{ 0, 0.35, 1.0 }, 0..) |tip, k| {
        var st: settings_mod.Settings = .{};
        st.project.slope_smoothing = true;
        st.machine.nozzle_tip_radius = tip;
        const r = try st.resolve();
        const set = try beads(s, .{ .resolved = &r, .layers = sl.layers, .outlines = sl.outlines }, i);
        try testing.expectEqual(@as(usize, 1), set.len);
        const d = set[0].data[set[0].data.len / 2];
        zs[k] = d.z;
        for (set[0].data) |e| try testing.expect(e.z >= z_low + h / 2 - 1e-4 and e.z <= z_top + 1e-4);
        // The volume is the same at each height.
        const lv = beadVolume(set[0]);
        try testing.expectApproxEqRel(0.5 * h * 0.8 * lv[0], lv[1], 0.03);
    }
    // No tip: half height. A tip of 0.35 mm: higher, between the layers.
    // A tip of 1 mm: at the top of the layer.
    try testing.expectApproxEqAbs(z_low + h / 2, zs[0], 1e-4);
    try testing.expect(zs[1] > zs[0] + 1e-3 and zs[1] < z_top - 1e-3);
    try testing.expectApproxEqAbs(z_top, zs[2], 1e-4);
}

test "a cone: closed loops; a box: no beads" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = arena.allocator();
    var st: settings_mod.Settings = .{};
    st.project.slope_smoothing = true;
    const r = try st.resolve();

    var cone = try mesh_mod.shapes.frustum(gpa, 20, 20, 10, 4, 4, 128);
    defer cone.deinit(gpa);
    var c = try Sliced.init(gpa, &cone, 4);
    defer c.deinit(gpa);
    const ci: Input = .{ .resolved = &r, .layers = c.layers, .outlines = c.outlines };
    for (3..c.layers.len - 1) |i| {
        const set = try beads(s, ci, i);
        try testing.expectEqual(@as(usize, 1), set.len);
        try testing.expect(set[0].closed);
        for (set[0].data) |d| try testing.expect(d.z > c.layers[i - 1].z and d.z <= c.layers[i].z + 1e-4);
    }

    // Vertical walls and a flat top.
    var box = try mesh_mod.shapes.box(gpa, 20, 20, 5);
    defer box.deinit(gpa);
    var b = try Sliced.init(gpa, &box, 5);
    defer b.deinit(gpa);
    const bi: Input = .{ .resolved = &r, .layers = b.layers, .outlines = b.outlines };
    for (1..b.layers.len) |i| try testing.expectEqual(@as(usize, 0), (try beads(s, bi, i)).len);

    // A step of one layer (a box on a box): a shelf, and no slope.
    var mb: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&mb, 0, 0, 0, 20, 20, 2);
    try mesh_mod.shapes.addBox(&mb, 0.5, 0.5, 2, 19.5, 19.5, 4);
    var shelf = try mb.finish();
    defer shelf.deinit(gpa);
    var sh = try Sliced.init(gpa, &shelf, 4);
    defer sh.deinit(gpa);
    const si: Input = .{ .resolved = &r, .layers = sh.layers, .outlines = sh.outlines };
    for (1..sh.layers.len) |i| try testing.expectEqual(@as(usize, 0), (try beads(s, si, i)).len);
}

test "slope ironing: passes across the ledge at the height of the filled step" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = arena.allocator();
    var m = try mesh_mod.shapes.wedge(gpa, 20, 20, 1, 6);
    defer m.deinit(gpa);
    var sl = try Sliced.init(gpa, &m, 6);
    defer sl.deinit(gpa);
    const i = 12;
    const z_low = sl.layers[i - 1].z;
    const z_top = sl.layers[i].z;
    const h = z_top - z_low;
    const edge_x = (sl.layers[i].sliceZ() - 1) * 4;
    for ([_]f64{ 0, 0.5 }) |tip| {
        var st: settings_mod.Settings = .{};
        st.project.slope_ironing = true;
        st.machine.nozzle_tip_radius = tip;
        const r = try st.resolve();
        const set = try ironing(s, .{ .resolved = r: {
            break :r &r;
        }, .layers = sl.layers, .outlines = sl.outlines }, i);
        // Two passes (the default), one along the ledge for each.
        try testing.expectEqual(@as(usize, 2), set.len);
        const want_area = st.project.slope_ironing_flow * flow.beadArea(r.line_width, h);
        for (set, 0..) |b, k| {
            // Pass k is at (k + 1/2) / 2 of the 0.8 mm ledge.
            const f = (@as(f64, @floatFromInt(k)) + 0.5) / 2;
            for (b.points, b.data) |q, d| {
                try testing.expect(d.z >= z_low + h / 4 - 1e-4 and d.z <= z_top + 1e-4);
                try testing.expectApproxEqRel(want_area, d.area, 1e-5);
                try testing.expectApproxEqAbs(edge_x - f * 0.8, geom.toMm(q.x), 0.03);
                // With no tip, the nozzle is on the filled surface: the
                // step corner is at z_top, the ledge edge at z_low.
                if (tip == 0) try testing.expectApproxEqAbs(z_low + h * (1 - f), d.z, 1e-4);
                // A wide tip: the inner pass stays at the top of the layer.
                if (tip == 0.5 and k == 0) try testing.expectApproxEqAbs(z_top, d.z, 1e-4);
            }
        }
    }
}

test "the layer plan: the beads and the ironing come last, and only with the settings on" {
    const gpa = testing.allocator;
    var m = try mesh_mod.shapes.wedge(gpa, 10, 20, 1, 6);
    defer m.deinit(gpa);
    var sl = try Sliced.init(gpa, &m, 6);
    defer sl.deinit(gpa);
    for ([_]bool{ false, true }) |on| {
        var st: settings_mod.Settings = .{};
        st.project.slope_smoothing = on;
        st.project.slope_ironing = on;
        const r = try st.resolve();
        var lp = try layer_mod.plan(gpa, .{ .resolved = &r, .layers = sl.layers, .outlines = sl.outlines }, 12);
        defer lp.deinit();
        var n: usize = 0;
        var n_iron: usize = 0;
        var seen = false;
        for (lp.paths.items, 0..) |path, pi| {
            if (path.feature == .slope_ironing) {
                // The ironing comes after the beads.
                try testing.expect(n > 0);
                n_iron += 1;
            }
            if (path.feature == .slope_smoothing) try testing.expectEqual(@as(usize, 0), n_iron);
            if (path.feature == .slope_smoothing or path.feature == .slope_ironing) {
                seen = true;
                if (path.feature == .slope_smoothing) n += 1;
                try testing.expect(path.z_start != layer_mod.Path.planar);
                try testing.expect(path.z_start + lp.points.get(pi).len <= lp.point_z.items.len);
            } else {
                try testing.expect(!seen);
                try testing.expectEqual(layer_mod.Path.planar, path.z_start);
            }
        }
        try testing.expectEqual(@as(usize, if (on) 1 else 0), n);
        try testing.expectEqual(@as(usize, if (on) 2 else 0), n_iron);
        if (!on) try testing.expectEqual(@as(usize, 0), lp.point_z.items.len);
    }
}
