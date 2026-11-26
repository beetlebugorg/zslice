//! The prime tower: its shape on each layer, and its lines.
//!
//! A print with tool changes primes the new filament on a tower next to
//! the parts (see gcode.zig, `Emitter.changeTool`). The tower has a
//! layer on each print layer up to its last change. This file makes the
//! lines of one tower layer. gcode.zig prints them, and the view
//! (render/view.zig) draws the same lines.
//!
//! The shape follows the rib wall tower of Bambu Studio (see
//! docs/references/bambu-studio.md):
//!
//! - The outline is the box of the tower, plus two strips along its
//!   diagonals (the ribs). Each strip is `rib_width` wide and as long as
//!   the diagonal, or longer by `rib_extra`. The extra length is full on
//!   the bed and goes down to 0 at the top of the tower. The ends of the
//!   strips stick out at the four corners and make the tower stiff.
//! - Each corner of the outline gets a round fillet (`fillet`).
//! - The wall is `walls` loops. Loop i is the outline, i line widths in.
//! - The rows of a prime fill the inside from the front, one line width
//!   apart, as one zigzag. Each row goes from the inner loop to the inner
//!   loop. The prime of each change continues after the rows of the
//!   change before it, so each filament has its own block of rows.
//! - At the end of the layer, the rows of the next layer's prime get a
//!   solid base: rows over the area that the next layer primes on (see
//!   `Towers.needAt`). The first layer is solid.
//! - The rest of the inside is sparse: lines across the rows, close to
//!   the walls and further apart toward the center. These lines are at
//!   the same x on each layer, so they stack into thin walls.
//! - The brim on the first layer: loops out from the outer loop.
//!
//! The outline is the union of three convex shapes around the center of
//! the tower: the box and the two strips. A union of convex shapes that
//! each hold the center is star shaped. Along each ray from the center,
//! its edge is at the largest distance of the three. The outline goes
//! through the points at the angles of all corners and of all crossings
//! of the edges, and is a straight line between them. A loop i widths
//! in is the union of the three shapes, each i widths smaller.

const std = @import("std");
const flow = @import("flow.zig");
const filaments = @import("filaments.zig");

/// The most rows of a tower on one layer.
pub const max_rows = 512;

/// The most points of one loop.
pub const loop_max = 320;

/// The most points of the lines of one tower layer (see `Lines`).
pub const lines_max = 4096;

/// The tangent length (mm) of the fillet at each corner of the outer
/// loop: the `rounding` of Bambu Studio (2 mm).
pub const fillet_mm = 2.0;

/// The gap (mm) between the sparse lines next to the walls, and the
/// largest gap, at the center. Each gap is 1.5 times the gap before it.
/// A prime never prints on the sparse lines (it gets a solid base), so
/// the sparse lines only hold up the solid rows and the walls.
pub const sparse_gap_min = 1.0;
pub const sparse_gap_max = 4.0;

/// A closed loop: the last point joins the first.
pub const Loop = struct {
    pts: [loop_max][2]f64 = undefined,
    n: usize = 0,

    fn add(l: *Loop, p: [2]f64) void {
        if (l.n == loop_max) return;
        if (l.n > 0 and dist(l.pts[l.n - 1], p) < 1e-4) return;
        l.pts[l.n] = p;
        l.n += 1;
    }

    pub fn points(l: *const Loop) []const [2]f64 {
        return l.pts[0..l.n];
    }
};

/// The lines of a part of a tower layer: a path through `pts`. The move
/// to `pts[j]` is a travel if `travel` has j, else a line. The nozzle
/// travels to `pts[0]`.
pub const Lines = struct {
    pts: [lines_max][2]f64 = undefined,
    n: usize = 0,
    travel: std.StaticBitSet(lines_max) = .empty,

    pub fn add(l: *Lines, p: [2]f64, travel: bool) void {
        if (l.n == lines_max) return;
        l.pts[l.n] = p;
        if (travel) l.travel.set(l.n);
        l.n += 1;
    }

    pub fn points(l: *const Lines) []const [2]f64 {
        return l.pts[0..l.n];
    }

    /// True if the move to `pts[j]` is a line (j from 1).
    pub fn isLine(l: *const Lines, j: usize) bool {
        return !l.travel.isSet(j);
    }
};

/// One row of a prime or of a solid base: its y, and the x of its ends.
pub const Row = struct { y: f64, x0: f64, x1: f64 };

/// The prime tower of a print with tool changes (Project.prime_tower): a
/// box of `size` by `ySize()` mm with its center at (x, y) on the bed,
/// and the ribs. Each layer up to `last_layer` prints a layer of it at
/// the z of the layer, so the tower is as high as the nozzle at each
/// change.
pub const Tower = struct {
    x: f64,
    y: f64,
    size: f64,
    /// The last layer with a change into a filament of this tower: the
    /// tower grows on each layer up to it.
    last_layer: usize,
    /// The family of its materials (see filaments.family), for the view.
    family: [8]u8 = @splat(0),
    /// Its depth in y (mm): `size`, or more for the rows that the most
    /// purge of one layer needs (see PlateJob.towers). 0: `size`.
    depth: f64 = 0,
    /// The loops of the wall (Project.prime_tower_wall_loops).
    walls: u32 = 4,
    /// The ribs at the corners (Project.prime_tower_rib_wall).
    rib: bool = true,
    /// The width of a rib (mm, Project.prime_tower_rib_width).
    rib_width: f64 = 8,
    /// The length of the ribs past the diagonal on the bed (mm,
    /// Project.prime_tower_extra_rib_length).
    rib_extra: f64 = 0,
    /// Round corners on a tower with ribs (Project.prime_tower_fillet_wall).
    fillet: bool = true,
    /// The z of its top layer (mm): the extra rib length goes to 0 there.
    /// 0: the full extra length on each layer.
    height: f64 = 0,
    /// The layer height for the count of the rows of a solid base.
    layer_h: f64 = 0.2,

    pub fn ySize(t: Tower) f64 {
        return if (t.depth > t.size) t.depth else t.size;
    }

    /// The shape of the tower on its layer at height `z`, for lines `w`
    /// mm wide.
    /// The width and the z round to 1 nm, so the f32 values of the view
    /// give the same lines as the f64 values of the G-code.
    pub fn layer(t: Tower, w_in: f64, z_in: f64) Layer {
        const w = @round(w_in * 1e6) / 1e6;
        const z = @round(z_in * 1e6) / 1e6;
        var l: Layer = .{ .t = t, .w = w, .z = z };
        l.localLoop(@as(f64, @floatFromInt(l.walls() - 1)) * w, &l.inner);
        return l;
    }

    /// The box of the first layer on the bed (min x, min y, max x, max y),
    /// for lines `w` mm wide and `brim` mm of brim: the ribs and the brim
    /// are in it. The ribs are longest on the first layer.
    pub fn footprint(t: Tower, w: f64, brim: f64) [4]f64 {
        const l = t.layer(w, 0);
        var loop: Loop = .{};
        const n = brimLoops(brim, l.w);
        if (n > 0) l.brimLoop(n, &loop) else l.wallLoop(0, &loop);
        var box = [4]f64{ t.x, t.y, t.x, t.y };
        for (loop.points()) |p| {
            box[0] = @min(box[0], p[0]);
            box[1] = @min(box[1], p[1]);
            box[2] = @max(box[2], p[0]);
            box[3] = @max(box[3], p[1]);
        }
        // The loop is the center of its line.
        const h = l.w / 2;
        return .{ box[0] - h, box[1] - h, box[2] + h, box[3] + h };
    }

    /// The count of the loops of the brim of a tower: `brim` mm of lines
    /// `w` mm wide.
    pub fn brimLoops(brim: f64, w: f64) u32 {
        if (brim <= 0 or w <= 0) return 0;
        return @min(40, @as(u32, @intFromFloat(@ceil(brim / w - 1e-9))));
    }
};

/// The prime towers of a print: one, or one for each family of materials
/// (Project.prime_tower_split), and the tower of each filament slot. Each
/// tower grows on each layer up to its own last layer.
pub const Towers = struct {
    pub const max = 4;
    list: [max]Tower = undefined,
    n: usize = 0,
    /// The tower of each slot (index in `list`).
    of_slot: [filaments.max_slots]u8 = @splat(0),
    /// The most purge (mm³) of each tower on a layer (see `needAt`), from
    /// the plate job. Null: none.
    need_ctx: ?*const anyopaque = null,
    need_fn: ?*const fn (ctx: ?*const anyopaque, of_slot: *const [filaments.max_slots]u8, layer: usize) [max]f64 = null,

    pub fn items(t: *const Towers) []const Tower {
        return t.list[0..t.n];
    }

    /// The most purge (mm³) into tower k on layer `layer`: the area of
    /// its rows gets a solid base on the layer before.
    pub fn needAt(t: *const Towers, layer: usize, k: usize) f64 {
        const f = t.need_fn orelse return 0;
        if (k >= t.n or layer > t.list[k].last_layer) return 0;
        return f(t.need_ctx, &t.of_slot, layer)[k];
    }
};

/// The shape of one layer of a tower (see `Tower.layer`).
pub const Layer = struct {
    t: Tower,
    w: f64,
    z: f64,
    /// The inner loop of the wall, in tower coordinates (the center of
    /// the tower at 0): the rows end on it.
    inner: Loop = .{},

    /// The count of the loops of the wall: at least 1, and at most as
    /// many as fit in the tower with a row inside them.
    pub fn walls(l: *const Layer) u32 {
        const most: u32 = @intFromFloat(@max(1, @floor((@min(l.t.size, l.t.ySize()) / l.w - 1) / 2)));
        return @max(1, @min(l.t.walls, most));
    }

    /// The half size of the inside of the wall in x and y: the rows and
    /// the sparse lines fill the box of this size.
    fn insideHalf(l: *const Layer) [2]f64 {
        const n: f64 = @floatFromInt(l.walls());
        return .{ l.t.size / 2 - n * l.w, l.t.ySize() / 2 - n * l.w };
    }

    /// The count of rows that fit in one layer: the depth inside the
    /// wall.
    pub fn rowsMax(l: *const Layer) u32 {
        const inside = 2 * l.insideHalf()[1];
        return @min(max_rows, @max(1, @as(u32, @intFromFloat(@max(0, inside) / l.w + 1e-9))));
    }

    /// Row `r` of the rows of a layer: at the front of the inside, then
    /// one line width apart. Each end is half a line width in from the
    /// inner loop: the bead of the row overlaps the bead of the loop by
    /// half a width. Near a rib, the inner loop goes out, and the row
    /// goes out with it.
    pub fn row(l: *const Layer, r: u32) Row {
        const half = l.insideHalf();
        const ry = -half[1] + (@as(f64, @floatFromInt(r)) + 0.5) * l.w;
        const c = crossings(l.inner.points(), 1, ry);
        const x0 = if (c[0]) |v| v + l.w / 2 else -half[0];
        const x1 = if (c[1]) |v| v - l.w / 2 else half[0];
        return .{ .y = l.t.y + ry, .x0 = l.t.x + x0, .x1 = l.t.x + x1 };
    }

    /// The rows `from` to `to` (not included) as one zigzag, added to
    /// `out`. Even rows go to +x, odd rows to -x.
    pub fn rows(l: *const Layer, from: u32, to: u32, out: *Lines) void {
        var r = from;
        while (r < to) : (r += 1) {
            const rw = l.row(r);
            const ltr = r % 2 == 0;
            out.add(.{ if (ltr) rw.x0 else rw.x1, rw.y }, r == from);
            out.add(.{ if (ltr) rw.x1 else rw.x0, rw.y }, false);
        }
    }

    /// The rows of a prime of `len` mm of line from row `from` on, added
    /// to `out`: each row goes from wall to wall, the last one too. Stops
    /// at `rowsMax`. Returns the row after the last one, and the length
    /// that did not fit.
    pub fn purge(l: *const Layer, from: u32, len: f64, out: *Lines) struct { rows: u32, short: f64 } {
        var left = len;
        var r = from;
        const most = l.rowsMax();
        while (left > 1e-9 and r < most) : (r += 1) {
            const rw = l.row(r);
            left -= rw.x1 - rw.x0;
        }
        l.rows(from, r, out);
        return .{ .rows = r, .short = @max(0, left) };
    }

    /// The count of rows of a prime of `mm3` mm³, and one more: the area
    /// of the solid base under it.
    pub fn solidRows(l: *const Layer, mm3: f64) u32 {
        if (mm3 <= 0) return 0;
        const run = 2 * l.insideHalf()[0];
        if (run <= 0) return 0;
        const n = @ceil(mm3 / (run * flow.beadArea(l.w, @max(l.t.layer_h, 0.01)))) + 1;
        return @intFromFloat(@min(n, @as(f64, @floatFromInt(l.rowsMax()))));
    }

    /// The x of the sparse lines, in tower coordinates, from -x to +x:
    /// `sparse_gap_min` from each wall, then each gap 1.5 times the gap
    /// before it, at most `sparse_gap_max`. Returns the count.
    pub fn sparseXs(l: *const Layer, out: *[64]f64) usize {
        const half = l.insideHalf()[0];
        var left: [31]f64 = undefined;
        var n: usize = 0;
        var gap: f64 = sparse_gap_min;
        var x = -half + gap;
        while (n < left.len and x < -0.5 * @min(gap * 1.5, sparse_gap_max)) {
            left[n] = x;
            n += 1;
            gap = @min(gap * 1.5, sparse_gap_max);
            x += gap;
        }
        var k: usize = 0;
        for (left[0..n]) |v| {
            out[k] = v;
            k += 1;
        }
        // A line at the center if the gap there is wide.
        const mid_gap = if (n > 0) -2 * left[n - 1] else 2 * half;
        if (mid_gap > sparse_gap_max and half > l.w) {
            out[k] = 0;
            k += 1;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            out[k] = -left[i];
            k += 1;
        }
        return k;
    }

    /// The end of a layer of the tower, added to `out`: the solid rows
    /// from row `done` (the rows of the primes of this layer end there)
    /// to row `solid`, the sparse lines on the rest of the inside, the
    /// loops of the wall from the inner one out, and `brim` loops of the
    /// brim.
    pub fn finish(l: *const Layer, done: u32, solid: u32, brim: u32, out: *Lines) void {
        l.rows(done, solid, out);
        // The sparse lines: from the row after the last one to the inner
        // loop at the back, joined at their ends.
        const half = l.insideHalf();
        const filled = @max(done, solid);
        const ya = -half[1] + @as(f64, @floatFromInt(filled)) * l.w + l.w / 2;
        var xs: [64]f64 = undefined;
        const nx = l.sparseXs(&xs);
        var first = true;
        var up = true;
        for (xs[0..nx]) |x| {
            const c = crossings(l.inner.points(), 0, x);
            const yb = (if (c[1]) |v| v - l.w / 2 else half[1]);
            if (yb - ya < l.w) continue;
            const a: [2]f64 = .{ l.t.x + x, l.t.y + ya };
            const b: [2]f64 = .{ l.t.x + x, l.t.y + yb };
            out.add(if (up) a else b, first);
            out.add(if (up) b else a, false);
            first = false;
            up = !up;
        }
        // The loops of the wall, from the inner one out, then the brim.
        var loop: Loop = .{};
        var i = l.walls();
        while (i > 0) {
            i -= 1;
            l.wallLoop(i, &loop);
            addLoop(&loop, out);
        }
        var j: u32 = 1;
        while (j <= brim) : (j += 1) {
            l.loopAt(-@as(f64, @floatFromInt(j)) * l.w, &loop);
            addLoop(&loop, out);
        }
    }

    /// Loop `i` of the wall (0: the outer loop), in bed coordinates.
    pub fn wallLoop(l: *const Layer, i: u32, out: *Loop) void {
        l.loopAt(@as(f64, @floatFromInt(i)) * l.w, out);
    }

    /// Loop `j` (from 1) of the brim: `j` line widths out from the outer
    /// loop of the wall.
    pub fn brimLoop(l: *const Layer, j: u32, out: *Loop) void {
        l.loopAt(-@as(f64, @floatFromInt(j)) * l.w, out);
    }

    /// The loop `d` mm in from the outer loop of the wall (out for d < 0),
    /// in bed coordinates. The outer loop is half a line width in from
    /// the edge of the box of the tower.
    pub fn loopAt(l: *const Layer, d: f64, out: *Loop) void {
        l.localLoop(d, out);
        for (out.pts[0..out.n]) |*p| p.* = .{ p[0] + l.t.x, p[1] + l.t.y };
    }

    /// `loopAt` in tower coordinates.
    fn localLoop(l: *const Layer, d: f64, out: *Loop) void {
        out.n = 0;
        const t = l.t;
        // The outer loop: its half size, its diagonal, and its ribs.
        const a0 = t.size / 2 - l.w / 2;
        const b0 = t.ySize() / 2 - l.w / 2;
        const a = a0 - d;
        const b = b0 - d;
        if (a <= 1e-6 or b <= 1e-6) return;
        var pieces: [3][4][2]f64 = undefined;
        pieces[0] = .{ .{ -a, -b }, .{ a, -b }, .{ a, b }, .{ -a, b } };
        var np: usize = 1;
        if (t.rib) {
            const r = ribOf(t, a0, b0, l.z);
            const hw = r.half_width - d;
            const len = r.half_length - d;
            if (hw > 1e-3 and len > hw) {
                const diag = std.math.hypot(a0, b0);
                for ([_][2]f64{ .{ a0 / diag, b0 / diag }, .{ -a0 / diag, b0 / diag } }) |u| {
                    const n: [2]f64 = .{ -u[1], u[0] };
                    pieces[np] = .{
                        .{ -len * u[0] - hw * n[0], -len * u[1] - hw * n[1] },
                        .{ len * u[0] - hw * n[0], len * u[1] - hw * n[1] },
                        .{ len * u[0] + hw * n[0], len * u[1] + hw * n[1] },
                        .{ -len * u[0] + hw * n[0], -len * u[1] + hw * n[1] },
                    };
                    np += 1;
                }
            }
        }
        var raw: Loop = .{};
        unionOutline(pieces[0..np], &raw);
        if (t.rib and t.fillet) {
            roundCorners(&raw, d, out);
        } else {
            out.* = raw;
        }
    }
};

/// The ribs of a tower layer at height z, for an outer loop of half size
/// (a0, b0): the half width and the half length of each strip, from the
/// center. As in Bambu Studio (WipeTower::generate_rib_polygon and
/// plan_tower_new): the rib is as long as the diagonal, or as long as
/// the diagonal of the least depth for the height of the tower, plus the
/// extra length; never shorter than the diagonal. The part past the
/// diagonal shrinks to 0 at the top of the tower. The width is at most
/// half the side of the tower.
fn ribOf(t: Tower, a0: f64, b0: f64, z: f64) struct { half_width: f64, half_length: f64 } {
    const diag = 2 * std.math.hypot(a0, b0);
    var len = diag;
    const least = leastDepth(t.height);
    if (2 * b0 < least) len = @max(len, least * std.math.sqrt2);
    len = @max(diag, len + t.rib_extra);
    var extra = (len - diag) / 2;
    if (t.height > 0) extra *= @max(0, t.height - z) / t.height;
    const width = @min(t.rib_width, @min(2 * a0, 2 * b0) / 2);
    return .{ .half_width = width / 2, .half_length = diag / 2 + extra };
}

/// The least depth (mm) of a tower of height h, from the table of Bambu
/// Studio (WipeTower::min_depth_per_height): 5 mm at 5 mm high, 20 mm at
/// 100 mm, 40 mm at 250 mm, 60 mm at 350 mm, a straight line between.
pub fn leastDepth(h: f64) f64 {
    const table = [_][2]f64{ .{ 5, 5 }, .{ 100, 20 }, .{ 250, 40 }, .{ 350, 60 } };
    if (h <= table[0][0]) return table[0][1];
    for (table[0 .. table.len - 1], table[1..]) |p, q| {
        if (h < q[0]) return p[1] + (h - p[0]) / (q[0] - p[0]) * (q[1] - p[1]);
    }
    return table[table.len - 1][1];
}

fn dist(p: [2]f64, q: [2]f64) f64 {
    return std.math.hypot(p[0] - q[0], p[1] - q[1]);
}

fn cross(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

/// The distance from the center along the unit direction `v` to the edge
/// of the convex shape `q` (corners in counter-clockwise order), which
/// holds the center.
fn radial(q: [4][2]f64, v: [2]f64) f64 {
    var r: f64 = std.math.inf(f64);
    for (0..4) |i| {
        const p = q[i];
        const s = q[(i + 1) % 4];
        // The outward normal of a counter-clockwise edge.
        const n: [2]f64 = .{ s[1] - p[1], -(s[0] - p[0]) };
        const nv = n[0] * v[0] + n[1] * v[1];
        if (nv <= 1e-12) continue;
        r = @min(r, (n[0] * p[0] + n[1] * p[1]) / nv);
    }
    return r;
}

/// The outline of the union of convex shapes that each hold the center,
/// counter-clockwise, to `out` (see the file comment).
fn unionOutline(pieces: []const [4][2]f64, out: *Loop) void {
    var angles: [64]f64 = undefined;
    var n: usize = 0;
    for (pieces) |q| for (q) |p| {
        angles[n] = std.math.atan2(p[1], p[0]);
        n += 1;
    };
    // The crossings of the edges of two shapes.
    for (pieces, 0..) |q, i| for (pieces[i + 1 ..]) |s| {
        for (0..4) |e| for (0..4) |f| {
            const p0 = q[e];
            const p1 = q[(e + 1) % 4];
            const r0 = s[f];
            const r1 = s[(f + 1) % 4];
            const d1: [2]f64 = .{ p1[0] - p0[0], p1[1] - p0[1] };
            const d2: [2]f64 = .{ r1[0] - r0[0], r1[1] - r0[1] };
            const den = cross(d1, d2);
            if (@abs(den) < 1e-12) continue;
            const w: [2]f64 = .{ r0[0] - p0[0], r0[1] - p0[1] };
            const tt = cross(w, d2) / den;
            const uu = cross(w, d1) / den;
            if (tt < 0 or tt > 1 or uu < 0 or uu > 1 or n == angles.len) continue;
            angles[n] = std.math.atan2(p0[1] + tt * d1[1], p0[0] + tt * d1[0]);
            n += 1;
        };
    };
    std.mem.sort(f64, angles[0..n], {}, std.sort.asc(f64));
    var raw: Loop = .{};
    var last: ?f64 = null;
    for (angles[0..n]) |th| {
        if (last) |l| if (th - l < 1e-9) continue;
        last = th;
        const v: [2]f64 = .{ @cos(th), @sin(th) };
        var r: f64 = 0;
        for (pieces) |q| r = @max(r, radial(q, v));
        raw.add(.{ r * v[0], r * v[1] });
    }
    if (raw.n > 1 and dist(raw.pts[0], raw.pts[raw.n - 1]) < 1e-4) raw.n -= 1;
    // Drop the points on a straight line.
    out.n = 0;
    for (0..raw.n) |i| {
        const p = raw.pts[(i + raw.n - 1) % raw.n];
        const q = raw.pts[i];
        const s = raw.pts[(i + 1) % raw.n];
        const e1: [2]f64 = .{ q[0] - p[0], q[1] - p[1] };
        const e2: [2]f64 = .{ s[0] - q[0], s[1] - q[1] };
        const l1 = std.math.hypot(e1[0], e1[1]);
        const l2 = std.math.hypot(e2[0], e2[1]);
        if (l1 < 1e-7 or l2 < 1e-7) continue;
        if (@abs(cross(e1, e2)) / (l1 * l2) < 1e-6 and e1[0] * e2[0] + e1[1] * e2[1] > 0) continue;
        out.add(q);
    }
}

/// Rounds the corners of `raw` (counter-clockwise) to `out`, as Bambu
/// Studio rounds the wall of a tower with ribs
/// (WipeTower::rounding_polygon): each corner that turns by 30° to 150°
/// gets an arc. On the outer loop, the arc starts `fillet_mm` before the
/// corner. A loop `d` mm in has the arcs of the outer loop moved in by
/// d: a convex arc is d smaller, a concave arc is d larger.
fn roundCorners(raw: *const Loop, d: f64, out: *Loop) void {
    out.n = 0;
    const m = raw.n;
    if (m < 3) {
        out.* = raw.*;
        return;
    }
    for (0..m) |i| {
        const a = raw.pts[(i + m - 1) % m];
        const b = raw.pts[i];
        const c = raw.pts[(i + 1) % m];
        const l1 = dist(a, b);
        const l2 = dist(b, c);
        const dir1: [2]f64 = .{ (b[0] - a[0]) / l1, (b[1] - a[1]) / l1 };
        const dir2: [2]f64 = .{ (c[0] - b[0]) / l2, (c[1] - b[1]) / l2 };
        const cos_turn = std.math.clamp(dir1[0] * dir2[0] + dir1[1] * dir2[1], -1, 1);
        const turn = std.math.acos(cos_turn);
        if (@abs(cos_turn) >= @cos(std.math.pi / 6.0)) {
            out.add(b);
            continue;
        }
        const convex = cross(dir1, dir2) > 0;
        const tan_half = @tan(turn / 2);
        const r0 = fillet_mm / tan_half;
        var r = if (convex) r0 - d else r0 + d;
        if (r <= 1e-3) {
            out.add(b);
            continue;
        }
        const tl = @min(r * tan_half, @min(l1, l2) / 2.1);
        r = tl / tan_half;
        const left: [2]f64 = .{ b[0] - dir1[0] * tl, b[1] - dir1[1] * tl };
        // The center: to the left of the edge for a left (convex) turn.
        const nrm: [2]f64 = if (convex) .{ -dir1[1], dir1[0] } else .{ dir1[1], -dir1[0] };
        const center: [2]f64 = .{ left[0] + nrm[0] * r, left[1] + nrm[1] * r };
        const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(turn / (std.math.pi / 12.0)))));
        const sign: f64 = if (convex) 1 else -1;
        const start = std.math.atan2(left[1] - center[1], left[0] - center[0]);
        for (0..steps + 1) |k| {
            const ang = start + sign * turn * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
            out.add(.{ center[0] + r * @cos(ang), center[1] + r * @sin(ang) });
        }
    }
    if (out.n > 1 and dist(out.pts[0], out.pts[out.n - 1]) < 1e-4) out.n -= 1;
}

/// The crossings of the closed loop `pts` (in tower coordinates) with
/// the line `axis` = v (axis 0: x = v; axis 1: y = v): the nearest one
/// below 0 on the line, and the nearest one above 0.
fn crossings(pts: []const [2]f64, axis: usize, v: f64) [2]?f64 {
    const other = 1 - axis;
    var lo: ?f64 = null;
    var hi: ?f64 = null;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        if ((p[axis] <= v) == (q[axis] <= v)) continue;
        const f = (v - p[axis]) / (q[axis] - p[axis]);
        const c = p[other] + f * (q[other] - p[other]);
        if (c < 0) {
            lo = if (lo) |x| @max(x, c) else c;
        } else {
            hi = if (hi) |x| @min(x, c) else c;
        }
    }
    return .{ lo, hi };
}

/// Adds the closed loop `loop` to `out`, from its point nearest to the
/// last point of `out`, with a travel to it.
fn addLoop(loop: *const Loop, out: *Lines) void {
    if (loop.n < 3) return;
    var start: usize = 0;
    if (out.n > 0) {
        const p = out.pts[out.n - 1];
        var best = std.math.inf(f64);
        for (loop.points(), 0..) |q, i| {
            const dd = dist(p, q);
            if (dd < best) {
                best = dd;
                start = i;
            }
        }
    }
    for (0..loop.n + 1) |k| out.add(loop.pts[(start + k) % loop.n], k == 0);
}

const testing = std.testing;

/// The distance from p to the closed loop `pts`.
fn loopDist(pts: []const [2]f64, p: [2]f64) f64 {
    var best = std.math.inf(f64);
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        const d: [2]f64 = .{ b[0] - a[0], b[1] - a[1] };
        const len2 = d[0] * d[0] + d[1] * d[1];
        const f = if (len2 > 0) std.math.clamp(((p[0] - a[0]) * d[0] + (p[1] - a[1]) * d[1]) / len2, 0, 1) else 0;
        best = @min(best, dist(p, .{ a[0] + f * d[0], a[1] + f * d[1] }));
    }
    return best;
}

/// The count of closed loops in `lines`: runs from a travel back to
/// their first point.
fn closedRuns(lines: *const Lines) usize {
    var n: usize = 0;
    var start: usize = 0;
    for (1..lines.n + 1) |j| {
        if (j == lines.n or !lines.isLine(j)) {
            if (j - start > 3 and dist(lines.pts[start], lines.pts[j - 1]) < 1e-9) n += 1;
            start = j;
        }
    }
    return n;
}

test "tower: the wall has its loops, one line width apart" {
    const w: f64 = 0.45;
    for ([_]bool{ true, false }) |rib| {
        const t = Tower{ .x = 100, .y = 100, .size = 30, .last_layer = 5, .walls = 4, .rib = rib, .height = 10 };
        const l = t.layer(w, 0.2);
        var lines: Lines = .{};
        l.finish(0, 0, 0, &lines);
        try testing.expectEqual(@as(usize, 4), closedRuns(&lines));
        // Each loop is one line width inside the loop out of it, on the
        // sides of the box.
        var outer: Loop = .{};
        var inner: Loop = .{};
        for (0..3) |i| {
            l.wallLoop(@intCast(i), &outer);
            l.wallLoop(@intCast(i + 1), &inner);
            const p: [2]f64 = .{ 100, 100 - 15 + w / 2 + @as(f64, @floatFromInt(i + 1)) * w };
            try testing.expectApproxEqAbs(@as(f64, 0), loopDist(inner.points(), p), 1e-6);
            try testing.expectApproxEqAbs(w, loopDist(outer.points(), p), 1e-6);
        }
    }
    // A small tower has fewer loops: a row fits inside.
    const small = Tower{ .x = 0, .y = 0, .size = 3, .last_layer = 1, .walls = 10 };
    try testing.expect(small.layer(w, 0.2).walls() < 4);
}

test "tower: the ribs stick out at the corners, and shrink to the diagonal at the top" {
    const w: f64 = 0.45;
    const t = Tower{ .x = 0, .y = 0, .size = 30, .last_layer = 50, .rib_extra = 10, .height = 10 };
    var loop: Loop = .{};
    const a0 = t.size / 2 - w / 2;
    // The outer loop goes past the box near each corner, and on the
    // middle of each side it is on the box.
    for ([_]f64{ 0.2, 10 }) |z| {
        t.layer(w, z).wallLoop(0, &loop);
        var corners = @as([4]bool, @splat(false));
        for (loop.points()) |p| {
            if (@abs(p[0]) > a0 + 0.5 or @abs(p[1]) > a0 + 0.5) {
                corners[@as(usize, @intFromBool(p[0] > 0)) + 2 * @as(usize, @intFromBool(p[1] > 0))] = true;
            }
        }
        for (corners) |c| try testing.expect(c);
        try testing.expectApproxEqAbs(@as(f64, 0), loopDist(loop.points(), .{ a0, 0 }), 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0), loopDist(loop.points(), .{ 0, -a0 }), 1e-6);
    }
    // The extra length: far out on the bed, none at the top.
    var bottom: f64 = 0;
    var top: f64 = 0;
    t.layer(w, 0.2).wallLoop(0, &loop);
    for (loop.points()) |p| bottom = @max(bottom, std.math.hypot(p[0], p[1]));
    t.layer(w, 10).wallLoop(0, &loop);
    for (loop.points()) |p| top = @max(top, std.math.hypot(p[0], p[1]));
    try testing.expect(bottom > top + 3);
    // No ribs: a box.
    const box = Tower{ .x = 0, .y = 0, .size = 30, .last_layer = 50, .rib = false };
    box.layer(w, 0.2).wallLoop(0, &loop);
    try testing.expectEqual(@as(usize, 4), loop.n);
    for (loop.points()) |p| try testing.expectApproxEqAbs(a0, @abs(p[0]), 1e-9);
}

test "tower: each row ends on the inner loop, at both ends, also near the ribs" {
    const w: f64 = 0.45;
    for ([_]bool{ true, false }) |rib| {
        const t = Tower{ .x = 50, .y = 60, .size = 25, .last_layer = 5, .rib = rib, .height = 20 };
        const l = t.layer(w, 1);
        const inner = blk: {
            var loop: Loop = .{};
            l.wallLoop(l.walls() - 1, &loop);
            break :blk loop;
        };
        var r: u32 = 0;
        while (r < l.rowsMax()) : (r += 1) {
            const row = l.row(r);
            try testing.expect(row.x1 > row.x0);
            for ([_]f64{ row.x0, row.x1 }) |x| {
                // Half a line width from the loop: the beads overlap.
                const d = loopDist(inner.points(), .{ x, row.y });
                try testing.expect(d <= w / 2 + 1e-6 and d > w / 8);
            }
            // The row is inside the loop: never past the outer edge of
            // the inner loop.
            try testing.expect(row.y - 60 > -t.size / 2 + @as(f64, @floatFromInt(l.walls())) * w);
        }
    }
}

test "tower: a prime of rows from wall to wall, and the sparse lines are close at the walls" {
    const w: f64 = 0.45;
    const t = Tower{ .x = 0, .y = 0, .size = 40, .last_layer = 5, .height = 20 };
    const l = t.layer(w, 1);
    var lines: Lines = .{};
    const got = l.purge(3, 100, &lines);
    // Each row is a full row; the prime goes on from row 3.
    try testing.expect(got.rows > 3);
    try testing.expectEqual(@as(f64, 0), got.short);
    try testing.expectEqual(@as(usize, 2 * (got.rows - 3)), lines.n);
    try testing.expectApproxEqAbs(l.row(3).y, lines.pts[0][1], 1e-12);
    // One zigzag: no travel after the first point.
    for (1..lines.n) |j| try testing.expect(lines.isLine(j));
    // The sparse lines: gaps that grow toward the center.
    var xs: [64]f64 = undefined;
    const n = l.sparseXs(&xs);
    try testing.expect(n > 6);
    try testing.expectApproxEqAbs(-20 + 4 * w + sparse_gap_min, xs[0], 1e-9);
    var i: usize = 1;
    while (i < n / 2) : (i += 1) {
        const g0 = xs[i] - xs[i - 1];
        try testing.expect(g0 <= sparse_gap_max + 1e-9);
        if (i >= 2) try testing.expect(g0 + 1e-9 >= xs[i - 1] - xs[i - 2]);
    }
    for (xs[0 .. n - 1], xs[1..n]) |a, b| try testing.expect(b - a <= sparse_gap_max + 1e-9 and b - a > 2 * w);
    // The solid base: the rows of a prime and one more.
    const area = flow.beadArea(w, t.layer_h);
    const rows_one = @ceil(45 / ((40 - 8 * w) * area));
    try testing.expectEqual(@as(u32, @intFromFloat(rows_one + 1)), l.solidRows(45));
    try testing.expectEqual(@as(u32, 0), l.solidRows(0));
}

test "tower: the least depth for the height, as Bambu Studio" {
    try testing.expectEqual(@as(f64, 5), leastDepth(1));
    try testing.expectEqual(@as(f64, 20), leastDepth(100));
    try testing.expectApproxEqAbs(@as(f64, 30), leastDepth(175), 1e-9);
    try testing.expectEqual(@as(f64, 60), leastDepth(500));
}

test "tower: the brim loops step out by a line width" {
    const w: f64 = 0.45;
    try testing.expectEqual(@as(u32, 7), Tower.brimLoops(3, w));
    try testing.expectEqual(@as(u32, 0), Tower.brimLoops(0, w));
    const t = Tower{ .x = 0, .y = 0, .size = 20, .last_layer = 5 };
    const l = t.layer(w, 0.2);
    var brim: Loop = .{};
    l.brimLoop(1, &brim);
    try testing.expectApproxEqAbs(w, loopDist(brim.points(), .{ 10 - w / 2, 0 }), 1e-6);
}

test "tower: the footprint holds the ribs and the brim" {
    const t = Tower{ .x = 100, .y = 100, .size = 30, .last_layer = 50, .rib_extra = 10, .height = 10 };
    const bare = t.footprint(0.5, 0);
    // The ribs stick out past the box of the tower at the corners.
    try std.testing.expect(bare[2] - bare[0] > 30.5);
    try std.testing.expect(bare[3] - bare[1] > 30.5);
    // A brim of 5 mm adds at least 5 mm on each side: more at the points
    // of the ribs.
    const brim = t.footprint(0.5, 5);
    try std.testing.expect(bare[0] - brim[0] >= 5 - 1e-6 and bare[0] - brim[0] < 7);
    try std.testing.expect(brim[3] - bare[3] >= 5 - 1e-6 and brim[3] - bare[3] < 7);
    // A tower with no ribs and no brim is its box.
    var plain = t;
    plain.rib = false;
    const box = plain.footprint(0.5, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 85), box[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 115), box[2], 1e-6);
}
