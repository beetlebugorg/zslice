//! Labels on the surface of a part: text, lines, bars, rings, the ticks
//! of a dial, and free lines, in a filament of their own.
//!
//! A label is a 2D shape in a plane that touches the part. The plane has
//! a frame: `origin` (a point on the surface), `normal` (out of the
//! part), and `right` (the +s axis of the shape; `up` = normal × right is
//! the +t axis). The frame is in the frame of the file mesh of the part
//! (see plate.Part.placeLabel), so a move or a turn of the part keeps the
//! label on its face.
//!
//! Each item of a label is an outline in the plane (s to the right and t
//! up, in mm), with its own offset and turn. The outline of the label is
//! the union of the outlines of its items. The slicer cuts the outline
//! into each layer as a region within a depth of the surface (see
//! paint_split.zig), and that region prints in the filament of the label.
//!
//! The shapes:
//!
//! - text: the glyphs of the font (font.zig), the size as the cap height;
//! - line: a rectangle along s, or a capsule with round ends;
//! - bar: a rectangle with round corners;
//! - ring: a disk, or a ring with a hole;
//! - ticks: `count` bars along the radius of a circle, at the angles from
//!   `start` over `sweep`, with a length from `length` to `length_end`
//!   (the marks around the knob of a dial);
//! - polyline: an open line, a closed loop, or a filled area.
//!
//! The JSON form (`parse`, `write`) is the form of the C API and of the
//! 3MF file (Metadata/zslice_labels.json). The reader checks each value,
//! so a bad file or call gives an error and no label.
//!
//! References (see REFERENCES.md): the text and SVG tools of PrusaSlicer
//! and the text tool of Bambu Studio (a label on a surface); the method,
//! no code.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const offset_mod = @import("offset.zig");
const font_mod = @import("font.zig");
const mesh_mod = @import("mesh.zig");
const paint_mod = @import("paint.zig");
const Paths = geom.Paths;
const Point = geom.Point;

/// The limits of the reader.
pub const max_items = 64;
pub const max_text = 256;
pub const max_points = 1024;
pub const max_ticks = 360;
pub const max_name = 128;
/// The largest size of a shape (mm).
pub const max_size = 1000;
/// The largest distance (mm) between a curve and its lines.
pub const tolerance: f64 = 0.01;

pub const Font = enum { sans };
pub const Alignment = font_mod.Alignment;

pub const Text = struct {
    text: []const u8,
    /// The cap height (mm).
    size: f64,
    font: Font = .sans,
    /// The growth of the outline of each glyph (mm, 0 to 0.3), for small
    /// text.
    weight: f64 = 0,
    alignment: Alignment = .center,
    /// The space added after each letter (mm).
    spacing: f64 = 0,
};

pub const Line = struct { length: f64, width: f64, round: bool = false };
pub const Bar = struct { width: f64, height: f64, radius: f64 = 0 };
/// `inner` 0: a disk.
pub const Ring = struct { outer: f64, inner: f64 = 0 };
pub const Ticks = struct {
    count: u32,
    radius: f64,
    length: f64,
    /// The length of the last tick; 0: the same as `length`.
    length_end: f64 = 0,
    width: f64,
    /// The angle of the first tick (degrees, from +s, counterclockwise).
    start: f64 = 225,
    /// The angle from the first tick to the last (negative: clockwise).
    sweep: f64 = -270,
};
pub const Polyline = struct {
    points: [][2]f64,
    width: f64,
    closed: bool = false,
    filled: bool = false,
};

pub const Shape = union(enum) {
    text: Text,
    line: Line,
    bar: Bar,
    ring: Ring,
    ticks: Ticks,
    polyline: Polyline,
};

pub const Item = struct {
    /// The offset in the plane (mm).
    at: [2]f64 = .{ 0, 0 },
    /// The turn in the plane (degrees, counterclockwise).
    angle: f64 = 0,
    shape: Shape,
};

pub const Label = struct {
    /// Unique in the part, never used again.
    id: u32 = 0,
    name: []const u8 = "",
    origin: [3]f64 = .{ 0, 0, 0 },
    normal: [3]f64 = .{ 1, 0, 0 },
    right: [3]f64 = .{ 0, 1, 0 },
    /// The filament, from 1.
    filament: u32 = 2,
    /// The depth from the surface (mm); 0: one line width.
    depth: f64 = 0,
    items: []Item = &.{},
    /// The scale of the shape along `right` and `up`: a size of a shape
    /// times its stretch is its size in the frame of the label. A scale
    /// of the part changes it (see plate.mapLabel).
    stretch: [2]f64 = .{ 1, 1 },

    /// Frees the strings and the items (all from `gpa`).
    pub fn deinit(l: *Label, gpa: Allocator) void {
        for (l.items) |it| switch (it.shape) {
            .text => |t| gpa.free(t.text),
            .polyline => |p| gpa.free(p.points),
            else => {},
        };
        gpa.free(l.items);
        gpa.free(l.name);
        l.* = undefined;
    }

    /// A deep copy.
    pub fn clone(l: *const Label, gpa: Allocator) Allocator.Error!Label {
        var out = l.*;
        out.name = try gpa.dupe(u8, l.name);
        errdefer gpa.free(out.name);
        out.items = try gpa.dupe(Item, l.items);
        var done: usize = 0;
        errdefer {
            for (out.items[0..done]) |it| switch (it.shape) {
                .text => |t| gpa.free(t.text),
                .polyline => |p| gpa.free(p.points),
                else => {},
            };
            gpa.free(out.items);
        }
        for (out.items) |*it| {
            switch (it.shape) {
                .text => |*t| t.text = try gpa.dupe(u8, t.text),
                .polyline => |*p| p.points = try gpa.dupe([2]f64, p.points),
                else => {},
            }
            done += 1;
        }
        return out;
    }

    /// The +t axis of the plane: normal × right.
    pub fn up(l: *const Label) [3]f64 {
        return cross(l.normal, l.right);
    }

    /// The point of the plane at (s, t) mm.
    pub fn at(l: *const Label, s: f64, t: f64) [3]f64 {
        const u = l.up();
        return .{ l.origin[0] + s * l.right[0] + t * u[0], l.origin[1] + s * l.right[1] + t * u[1], l.origin[2] + s * l.right[2] + t * u[2] };
    }

    /// The text of the first text item, or "".
    pub fn firstText(l: *const Label) []const u8 {
        for (l.items) |it| if (it.shape == .text) return it.shape.text.text;
        return "";
    }

    /// The kind of the label for the words of the history and the card:
    /// the kind of its first item.
    pub fn kind(l: *const Label) []const u8 {
        if (l.items.len == 0) return "label";
        return @tagName(l.items[0].shape);
    }
};

/// The default `right` of a label at a point with a normal: level on a
/// side face (Z × normal), so text reads from left to right in front of
/// the face; on a top or bottom face, `camera_right` put into the plane
/// (or +x if that is along the normal).
pub fn defaultRight(normal: [3]f64, camera_right: [3]f64) [3]f64 {
    if (@abs(normal[2]) <= 0.7) {
        const r = cross(.{ 0, 0, 1 }, normal);
        return normalize(r) orelse .{ 1, 0, 0 };
    }
    var c = camera_right;
    for (0..2) |_| {
        const d = dot(c, normal);
        const r: [3]f64 = .{ c[0] - d * normal[0], c[1] - d * normal[1], c[2] - d * normal[2] };
        if (normalize(r)) |v| return v;
        c = .{ 1, 0, 0 };
    }
    return .{ 0, 1, 0 };
}

pub fn cross(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn normalize(a: [3]f64) ?[3]f64 {
    const l = @sqrt(dot(a, a));
    if (!(l > 1e-12) or !std.math.isFinite(l)) return null;
    return .{ a[0] / l, a[1] / l, a[2] / l };
}

// ---- the place on a mesh ----

/// The frame of a label at a hit of a ray on a mesh (see `frameAt`).
pub const Place = struct {
    origin: [3]f64,
    normal: [3]f64,
    right: [3]f64,
    /// The largest angle (degrees) between the label plane and the
    /// surface within the radius (0 on a flat face). Over 60°, a shape
    /// of that size stretches by more than two times.
    curve: f64,
};

/// The frame of a label at the point `p` on triangle `tri` of a mesh,
/// for a ray in the direction `dir`. The normal is the mean of the
/// normals of the triangles of the same face (`region`, a smooth or flat
/// face of paint.Features) within `radius` of the point, weighted by
/// area; with no region, the normal of the triangle. On a side face the
/// text is level (see `defaultRight`); on a top or bottom face, its right
/// is the right of the view (dir x Z).
pub fn frameAt(mesh: *const mesh_mod.Mesh, tri: u32, p: [3]f64, dir: [3]f64, region: []const u32, radius: f64) Place {
    const tn = triNormal(mesh, tri);
    var sum: [3]f64 = .{ 0, 0, 0 };
    for (region) |t| {
        if (t >= mesh.faces.items.len) continue;
        if (!nearPoint(mesh, t, p, radius) and t != tri) continue;
        const n = triArea2(mesh, t);
        sum = .{ sum[0] + n[0], sum[1] + n[1], sum[2] + n[2] };
    }
    const normal = normalize(sum) orelse tn;
    var curve: f64 = 0;
    for (region) |t| {
        if (t >= mesh.faces.items.len or !nearPoint(mesh, t, p, radius)) continue;
        const c = std.math.clamp(dot(triNormal(mesh, t), normal), -1, 1);
        curve = @max(curve, std.math.radiansToDegrees(std.math.acos(c)));
    }
    const cam = normalize(cross(dir, .{ 0, 0, 1 })) orelse [3]f64{ 1, 0, 0 };
    return .{ .origin = p, .normal = normal, .right = defaultRight(normal, cam), .curve = curve };
}

/// True if triangle t is within r of p.
fn nearPoint(m: *const mesh_mod.Mesh, t: u32, p: [3]f64, r: f64) bool {
    var v: [3]paint_mod.V3 = undefined;
    for (m.faces.items[t], &v) |vi, *q| {
        const x = m.vertices.items[vi];
        q.* = .{ x.x, x.y, x.z };
    }
    const c = paint_mod.closest(.{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(p[2]) }, v);
    const d: [3]f64 = .{ c[0] - p[0], c[1] - p[1], c[2] - p[2] };
    return dot(d, d) <= r * r;
}

/// The normal of a triangle times two times its area.
fn triArea2(m: *const mesh_mod.Mesh, t: u32) [3]f64 {
    const f = m.faces.items[t];
    const a = m.vertices.items[f[0]];
    const b = m.vertices.items[f[1]];
    const c = m.vertices.items[f[2]];
    const e1: [3]f64 = .{ b.x - a.x, b.y - a.y, b.z - a.z };
    const e2: [3]f64 = .{ c.x - a.x, c.y - a.y, c.z - a.z };
    return cross(e1, e2);
}

fn triNormal(m: *const mesh_mod.Mesh, t: u32) [3]f64 {
    return normalize(triArea2(m, t)) orelse .{ 0, 0, 1 };
}

// ---- the outlines ----

/// The count of segments of a circle of radius r (mm) with a chord error
/// of at most `tolerance`.
fn circleSegments(r: f64) usize {
    if (!(r > tolerance)) return 8;
    const a = std.math.acos(1 - tolerance / r);
    return @intFromFloat(std.math.clamp(@ceil(std.math.pi / a), 8, 2048));
}

/// A builder of the paths of one item: each point goes through the turn
/// and the offset of the item.
const Out = struct {
    gpa: Allocator,
    paths: *Paths,
    ca: f64,
    sa: f64,
    at: [2]f64,

    fn point(o: *Out, x: f64, y: f64) Allocator.Error!void {
        const X = o.at[0] + o.ca * x - o.sa * y;
        const Y = o.at[1] + o.sa * x + o.ca * y;
        try o.paths.appendPoint(o.gpa, .init(geom.fromMm(X), geom.fromMm(Y)));
    }

    fn end(o: *Out) Allocator.Error!void {
        try o.paths.endPath(o.gpa, 3);
    }

    fn circleMax(o: *Out, cx: f64, cy: f64, r: f64, most: usize) Allocator.Error!void {
        return o.circleN(cx, cy, r, false, @min(circleSegments(r), most));
    }

    /// A circle (counterclockwise; clockwise with `hole`).
    fn circle(o: *Out, cx: f64, cy: f64, r: f64, hole: bool) Allocator.Error!void {
        return o.circleN(cx, cy, r, hole, circleSegments(r));
    }

    fn circleN(o: *Out, cx: f64, cy: f64, r: f64, hole: bool, n: usize) Allocator.Error!void {
        // The points lie a little out of the circle, so the polygon has
        // the area of the circle: n/2 rr² sin(2 pi / n) = pi r².
        const nf: f64 = @floatFromInt(n);
        const rr = r * @sqrt(2 * std.math.pi / (nf * @sin(2 * std.math.pi / nf)));
        for (0..n) |k| {
            const kk = if (hole) n - 1 - k else k;
            const a = 2 * std.math.pi * @as(f64, @floatFromInt(kk)) / @as(f64, @floatFromInt(n));
            try o.point(cx + rr * @cos(a), cy + rr * @sin(a));
        }
        try o.end();
    }

    /// A rectangle from (x0, y0) to (x1, y1) along a direction (c, s).
    fn quad(o: *Out, p: [4][2]f64) Allocator.Error!void {
        for (p) |q| try o.point(q[0], q[1]);
        try o.end();
    }

    /// A stroke from a to b of width w: a rectangle (butt ends).
    fn segment(o: *Out, a: [2]f64, b: [2]f64, w: f64) Allocator.Error!void {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const l = @sqrt(dx * dx + dy * dy);
        if (!(l > 0)) return;
        const nx = -dy / l * w / 2;
        const ny = dx / l * w / 2;
        try o.quad(.{ .{ a[0] - nx, a[1] - ny }, .{ b[0] - nx, b[1] - ny }, .{ b[0] + nx, b[1] + ny }, .{ a[0] + nx, a[1] + ny } });
    }
};

/// The raw paths of one item (they can overlap; see `outline`).
fn itemPaths(gpa: Allocator, it: Item, font: *const font_mod.Font, out: *Paths) font_mod.Error!void {
    const a = std.math.degreesToRadians(it.angle);
    var o: Out = .{ .gpa = gpa, .paths = out, .ca = @cos(a), .sa = @sin(a), .at = it.at };
    switch (it.shape) {
        .text => |t| {
            var p = try font_mod.text(gpa, font, t.text, .{ .size = t.size, .spacing = t.spacing, .alignment = t.alignment, .tolerance = tolerance });
            defer p.deinit(gpa);
            for (0..p.count()) |k| {
                for (p.get(k)) |q| try o.point(geom.toMm(q.x), geom.toMm(q.y));
                try o.end();
            }
        },
        .line => |l| {
            const hl = l.length / 2;
            const hw = l.width / 2;
            if (!l.round or hl <= hw) {
                if (l.round) return o.circle(0, 0, hw, false);
                return o.quad(.{ .{ -hl, -hw }, .{ hl, -hw }, .{ hl, hw }, .{ -hl, hw } });
            }
            // A capsule: two half circles, the length end to end.
            const n = circleSegments(hw) / 2 + 1;
            const c = hl - hw;
            for (0..n + 1) |k| {
                const t = -std.math.pi / 2.0 + std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                try o.point(c + hw * @cos(t), hw * @sin(t));
            }
            for (0..n + 1) |k| {
                const t = std.math.pi / 2.0 + std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                try o.point(-c + hw * @cos(t), hw * @sin(t));
            }
            try o.end();
        },
        .bar => |b| {
            const hw = b.width / 2;
            const hh = b.height / 2;
            const r = std.math.clamp(b.radius, 0, @min(hw, hh));
            if (!(r > 0)) return o.quad(.{ .{ -hw, -hh }, .{ hw, -hh }, .{ hw, hh }, .{ -hw, hh } });
            const n = circleSegments(r) / 4 + 1;
            const corners = [4][3]f64{ .{ hw - r, -hh + r, -90 }, .{ hw - r, hh - r, 0 }, .{ -hw + r, hh - r, 90 }, .{ -hw + r, -hh + r, 180 } };
            for (corners) |cn| for (0..n + 1) |k| {
                const t = std.math.degreesToRadians(cn[2] + 90 * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
                try o.point(cn[0] + r * @cos(t), cn[1] + r * @sin(t));
            };
            try o.end();
        },
        .ring => |r| {
            try o.circle(0, 0, r.outer, false);
            if (r.inner > 0 and r.inner < r.outer) try o.circle(0, 0, r.inner, true);
        },
        .ticks => |t| {
            const n = t.count;
            const end_len = if (t.length_end > 0) t.length_end else t.length;
            for (0..n) |j| {
                const f: f64 = if (n > 1) @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(n - 1)) else 0;
                const ang = std.math.degreesToRadians(t.start + f * t.sweep);
                const len = t.length + f * (end_len - t.length);
                const c = @cos(ang);
                const s = @sin(ang);
                try o.segment(.{ c * t.radius, s * t.radius }, .{ c * (t.radius + len), s * (t.radius + len) }, t.width);
            }
        },
        .polyline => |p| {
            const pts = p.points;
            if (p.filled and pts.len >= 3) {
                // The area, counterclockwise.
                var area: f64 = 0;
                for (pts, 0..) |q, k| {
                    const r = pts[(k + 1) % pts.len];
                    area += q[0] * r[1] - r[0] * q[1];
                }
                for (0..pts.len) |k| {
                    const q = pts[if (area >= 0) k else pts.len - 1 - k];
                    try o.point(q[0], q[1]);
                }
                try o.end();
            }
            if (!(p.width > 0) or pts.len < 2) return;
            const segs = if (p.closed) pts.len else pts.len - 1;
            for (0..segs) |k| try o.segment(pts[k], pts[(k + 1) % pts.len], p.width);
            // Round joins: a disk at each inner point (at most 64 sides:
            // a long line of wide joins stays quick).
            for (pts, 0..) |q, k| {
                if (!p.closed and (k == 0 or k == pts.len - 1)) continue;
                try o.circleMax(q[0], q[1], p.width / 2, 64);
            }
        },
    }
}

/// The outline of a label in its plane: the union of its items (non-zero
/// rule), counterclockwise, in the units of geom (x = s, y = t). A text
/// with a weight grows by it. The caller owns the result.
pub fn outline(gpa: Allocator, l: *const Label) font_mod.Error!Paths {
    const f = font_mod.builtin();
    return outlineWith(gpa, l, &f);
}

/// `outline` with a font.
pub fn outlineWith(gpa: Allocator, l: *const Label, font: *const font_mod.Font) font_mod.Error!Paths {
    var all: Paths = .empty;
    defer all.deinit(gpa);
    for (l.items) |it| {
        var raw: Paths = .empty;
        defer raw.deinit(gpa);
        try itemPaths(gpa, it, font, &raw);
        if (raw.isEmpty()) continue;
        var u = try clip.unionAll(gpa, raw, .non_zero);
        defer u.deinit(gpa);
        if (it.shape == .text and it.shape.text.weight > 0) {
            const g = try offset_mod.offset(gpa, u, geom.fromMm(it.shape.text.weight), .{ .join = .round, .arc_tolerance = geom.units_per_mm * tolerance });
            u.deinit(gpa);
            u = g;
        }
        try all.appendAll(gpa, u);
    }
    if (all.isEmpty()) return .empty;
    if (l.stretch[0] != 1 or l.stretch[1] != 1) {
        const flip = l.stretch[0] * l.stretch[1] < 0;
        for (0..all.count()) |k| {
            const poly = all.get(k);
            for (poly) |*q| q.* = .init(
                @intFromFloat(@round(@as(f64, @floatFromInt(q.x)) * l.stretch[0])),
                @intFromFloat(@round(@as(f64, @floatFromInt(q.y)) * l.stretch[1])),
            );
            if (flip) std.mem.reverse(Point, poly);
        }
    }
    return clip.unionAll(gpa, all, .non_zero);
}

/// A hash of all values of a label (for the key of a slice plan).
pub fn hash(l: *const Label, h: *std.hash.Wyhash) void {
    h.update(std.mem.asBytes(&l.id));
    h.update(std.mem.sliceAsBytes(&l.origin));
    h.update(std.mem.sliceAsBytes(&l.normal));
    h.update(std.mem.sliceAsBytes(&l.right));
    h.update(std.mem.sliceAsBytes(&l.stretch));
    h.update(std.mem.asBytes(&l.filament));
    h.update(std.mem.asBytes(&l.depth));
    for (l.items) |it| {
        h.update(@tagName(it.shape));
        h.update(std.mem.sliceAsBytes(&it.at));
        h.update(std.mem.asBytes(&it.angle));
        switch (it.shape) {
            .text => |t| {
                h.update(t.text);
                h.update(std.mem.sliceAsBytes(&[_]f64{ t.size, t.weight, t.spacing }));
                h.update(@tagName(t.alignment));
                h.update(@tagName(t.font));
            },
            .polyline => |p| {
                h.update(std.mem.sliceAsBytes(p.points));
                h.update(std.mem.asBytes(&p.width));
                h.update(&.{ @intFromBool(p.closed), @intFromBool(p.filled) });
            },
            .line => |x| {
                h.update(std.mem.sliceAsBytes(&[_]f64{ x.length, x.width }));
                h.update(&.{@intFromBool(x.round)});
            },
            .bar => |x| h.update(std.mem.sliceAsBytes(&[_]f64{ x.width, x.height, x.radius })),
            .ring => |x| h.update(std.mem.sliceAsBytes(&[_]f64{ x.outer, x.inner })),
            .ticks => |x| {
                h.update(std.mem.asBytes(&x.count));
                h.update(std.mem.sliceAsBytes(&[_]f64{ x.radius, x.length, x.length_end, x.width, x.start, x.sweep }));
            },
        }
    }
}

// ---- JSON ----

pub const ParseError = error{BadLabel} || Allocator.Error;

pub const ParseOptions = struct {
    /// The frame (origin, normal, right) must be in the JSON. False: the
    /// frame is optional (for the outline of the shapes only).
    frame: bool = true,
};

/// A label from its JSON. The caller owns the result (`Label.deinit`).
/// Each number must be finite and within its limit; `normal` and `right`
/// must be about unit and about at right angles (they come back exact).
pub fn parse(gpa: Allocator, json: []const u8, opts: ParseOptions) ParseError!Label {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{ .max_value_len = 1 << 20 }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadLabel,
    };
    return fromValue(gpa, v, opts);
}

/// A label from a parsed JSON value (see `parse`).
pub fn fromValue(gpa: Allocator, v: std.json.Value, opts: ParseOptions) ParseError!Label {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadLabel,
    };
    var l: Label = .{};
    if (obj.get("id")) |x| l.id = try int(u32, x);
    if (obj.get("filament")) |x| {
        l.filament = try int(u32, x);
        if (l.filament < 1 or l.filament > 64) return error.BadLabel;
    }
    if (obj.get("depth")) |x| l.depth = try num(x, 0, 10);
    if (obj.get("stretch")) |x| {
        l.stretch = try vec2(x, 1e3);
        for (l.stretch) |k| if (@abs(k) < 1e-3) return error.BadLabel;
    }
    if (opts.frame or obj.get("origin") != null) l.origin = try vec3(obj.get("origin") orelse return error.BadLabel, 1e5);
    if (opts.frame or obj.get("normal") != null) {
        const n = try vec3(obj.get("normal") orelse return error.BadLabel, 2);
        const r = try vec3(obj.get("right") orelse return error.BadLabel, 2);
        const ln = @sqrt(dot(n, n));
        const lr = @sqrt(dot(r, r));
        if (@abs(ln - 1) > 1e-3 or @abs(lr - 1) > 1e-3) return error.BadLabel;
        if (@abs(dot(n, r)) > 1e-3) return error.BadLabel;
        l.normal = normalize(n).?;
        // `right` at right angles to the normal, exact.
        const d = dot(r, l.normal);
        l.right = normalize(.{ r[0] - d * l.normal[0], r[1] - d * l.normal[1], r[2] - d * l.normal[2] }) orelse return error.BadLabel;
    }
    const name = if (obj.get("name")) |x| switch (x) {
        .string => |s| s,
        else => return error.BadLabel,
    } else "";
    if (name.len > max_name or !std.unicode.utf8ValidateSlice(name)) return error.BadLabel;
    const items_v = if (obj.get("items")) |x| switch (x) {
        .array => |a| a.items,
        else => return error.BadLabel,
    } else &.{};
    if (items_v.len > max_items) return error.BadLabel;
    l.name = try gpa.dupe(u8, name);
    errdefer gpa.free(l.name);
    var list: std.ArrayList(Item) = .empty;
    errdefer {
        for (list.items) |it| switch (it.shape) {
            .text => |t| gpa.free(t.text),
            .polyline => |p| gpa.free(p.points),
            else => {},
        };
        list.deinit(gpa);
    }
    for (items_v) |iv| {
        const it = try itemFrom(gpa, iv);
        list.append(gpa, it) catch |e| {
            switch (it.shape) {
                .text => |t| gpa.free(t.text),
                .polyline => |p| gpa.free(p.points),
                else => {},
            }
            return e;
        };
    }
    l.items = try list.toOwnedSlice(gpa);
    return l;
}

fn itemFrom(gpa: Allocator, v: std.json.Value) ParseError!Item {
    const o = switch (v) {
        .object => |x| x,
        else => return error.BadLabel,
    };
    var it: Item = .{ .shape = .{ .line = .{ .length = 0, .width = 0 } } };
    if (o.get("at")) |x| it.at = try vec2(x, max_size);
    if (o.get("angle")) |x| it.angle = try num(x, -3600, 3600);
    const kind_s = switch (o.get("kind") orelse return error.BadLabel) {
        .string => |s| s,
        else => return error.BadLabel,
    };
    const kind = std.meta.stringToEnum(std.meta.Tag(Shape), kind_s) orelse return error.BadLabel;
    const size = max_size;
    switch (kind) {
        .text => {
            const s = switch (o.get("text") orelse return error.BadLabel) {
                .string => |x| x,
                else => return error.BadLabel,
            };
            if (s.len > max_text or !std.unicode.utf8ValidateSlice(s)) return error.BadLabel;
            var t: Text = .{ .text = "", .size = try num(o.get("size") orelse return error.BadLabel, 0.1, size) };
            if (o.get("weight")) |x| t.weight = try num(x, 0, 0.3);
            if (o.get("spacing")) |x| t.spacing = try num(x, -size, size);
            if (o.get("font")) |x| t.font = try enumFrom(Font, x);
            if (o.get("alignment")) |x| t.alignment = try enumFrom(Alignment, x);
            t.text = try gpa.dupe(u8, s);
            it.shape = .{ .text = t };
        },
        .line => it.shape = .{ .line = .{
            .length = try num(o.get("length") orelse return error.BadLabel, 0.01, size),
            .width = try num(o.get("width") orelse return error.BadLabel, 0.01, size),
            .round = if (o.get("round")) |x| try boolean(x) else false,
        } },
        .bar => it.shape = .{ .bar = .{
            .width = try num(o.get("width") orelse return error.BadLabel, 0.01, size),
            .height = try num(o.get("height") orelse return error.BadLabel, 0.01, size),
            .radius = if (o.get("radius")) |x| try num(x, 0, size) else 0,
        } },
        .ring => {
            const r: Ring = .{
                .outer = try num(o.get("outer") orelse return error.BadLabel, 0.01, size),
                .inner = if (o.get("inner")) |x| try num(x, 0, size) else 0,
            };
            if (r.inner >= r.outer) return error.BadLabel;
            it.shape = .{ .ring = r };
        },
        .ticks => it.shape = .{ .ticks = .{
            .count = blk: {
                const c = try int(u32, o.get("count") orelse return error.BadLabel);
                if (c < 1 or c > max_ticks) return error.BadLabel;
                break :blk c;
            },
            .radius = try num(o.get("radius") orelse return error.BadLabel, 0, size),
            .length = try num(o.get("length") orelse return error.BadLabel, 0.01, size),
            .length_end = if (o.get("length_end")) |x| try num(x, 0, size) else 0,
            .width = try num(o.get("width") orelse return error.BadLabel, 0.01, size),
            .start = if (o.get("start")) |x| try num(x, -3600, 3600) else 225,
            .sweep = if (o.get("sweep")) |x| try num(x, -3600, 3600) else -270,
        } },
        .polyline => {
            const arr = switch (o.get("points") orelse return error.BadLabel) {
                .array => |a| a.items,
                else => return error.BadLabel,
            };
            if (arr.len < 2 or arr.len > max_points) return error.BadLabel;
            const pts = try gpa.alloc([2]f64, arr.len);
            errdefer gpa.free(pts);
            for (arr, pts) |x, *p| p.* = try vec2(x, max_size);
            const p: Polyline = .{
                .points = pts,
                .width = if (o.get("width")) |x| try num(x, 0, size) else 0,
                .closed = if (o.get("closed")) |x| try boolean(x) else false,
                .filled = if (o.get("filled")) |x| try boolean(x) else false,
            };
            if (!p.filled and !(p.width > 0)) return error.BadLabel;
            it.shape = .{ .polyline = p };
        },
    }
    return it;
}

fn num(v: std.json.Value, lo: f64, hi: f64) error{BadLabel}!f64 {
    const x: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.BadLabel,
        else => return error.BadLabel,
    };
    if (!std.math.isFinite(x) or x < lo or x > hi) return error.BadLabel;
    return x;
}

fn int(comptime T: type, v: std.json.Value) error{BadLabel}!T {
    return switch (v) {
        .integer => |i| std.math.cast(T, i) orelse error.BadLabel,
        else => error.BadLabel,
    };
}

fn boolean(v: std.json.Value) error{BadLabel}!bool {
    return switch (v) {
        .bool => |b| b,
        else => error.BadLabel,
    };
}

fn enumFrom(comptime E: type, v: std.json.Value) error{BadLabel}!E {
    return switch (v) {
        .string => |s| std.meta.stringToEnum(E, s) orelse error.BadLabel,
        else => error.BadLabel,
    };
}

fn vec2(v: std.json.Value, lim: f64) error{BadLabel}![2]f64 {
    const a = switch (v) {
        .array => |x| x.items,
        else => return error.BadLabel,
    };
    if (a.len != 2) return error.BadLabel;
    return .{ try num(a[0], -lim, lim), try num(a[1], -lim, lim) };
}

fn vec3(v: std.json.Value, lim: f64) error{BadLabel}![3]f64 {
    const a = switch (v) {
        .array => |x| x.items,
        else => return error.BadLabel,
    };
    if (a.len != 3) return error.BadLabel;
    return .{ try num(a[0], -lim, lim), try num(a[1], -lim, lim), try num(a[2], -lim, lim) };
}

/// Writes the JSON of a label (see `parse`).
pub fn write(l: *const Label, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\"id\":{d},\"name\":", .{l.id});
    try std.json.Stringify.encodeJsonString(l.name, .{}, w);
    try w.print(",\"origin\":[{d},{d},{d}],\"normal\":[{d},{d},{d}],\"right\":[{d},{d},{d}],\"filament\":{d},\"depth\":{d},", .{
        l.origin[0], l.origin[1], l.origin[2], l.normal[0], l.normal[1], l.normal[2], l.right[0], l.right[1], l.right[2], l.filament, l.depth,
    });
    if (l.stretch[0] != 1 or l.stretch[1] != 1) try w.print("\"stretch\":[{d},{d}],", .{ l.stretch[0], l.stretch[1] });
    try w.writeAll("\"items\":[");
    for (l.items, 0..) |it, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"kind\":\"{s}\",\"at\":[{d},{d}],\"angle\":{d}", .{ @tagName(it.shape), it.at[0], it.at[1], it.angle });
        switch (it.shape) {
            .text => |t| {
                try w.writeAll(",\"text\":");
                try std.json.Stringify.encodeJsonString(t.text, .{}, w);
                try w.print(",\"size\":{d},\"font\":\"{s}\",\"weight\":{d},\"alignment\":\"{s}\",\"spacing\":{d}", .{ t.size, @tagName(t.font), t.weight, @tagName(t.alignment), t.spacing });
            },
            .line => |x| try w.print(",\"length\":{d},\"width\":{d},\"round\":{}", .{ x.length, x.width, x.round }),
            .bar => |x| try w.print(",\"width\":{d},\"height\":{d},\"radius\":{d}", .{ x.width, x.height, x.radius }),
            .ring => |x| try w.print(",\"outer\":{d},\"inner\":{d}", .{ x.outer, x.inner }),
            .ticks => |x| try w.print(",\"count\":{d},\"radius\":{d},\"length\":{d},\"length_end\":{d},\"width\":{d},\"start\":{d},\"sweep\":{d}", .{ x.count, x.radius, x.length, x.length_end, x.width, x.start, x.sweep }),
            .polyline => |x| {
                try w.writeAll(",\"points\":[");
                for (x.points, 0..) |p, j| try w.print("{s}[{d},{d}]", .{ if (j == 0) "" else ",", p[0], p[1] });
                try w.print("],\"width\":{d},\"closed\":{},\"filled\":{}", .{ x.width, x.closed, x.filled });
            },
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// A short text of a label for the facts of the history: the kind, the
/// text, the filament, the depth, the sizes, and the place, rounded to
/// 0.1 mm and 1°. Two labels with the same summary look the same.
pub fn summary(l: *const Label, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{s}", .{l.kind()});
    const t = l.firstText();
    if (t.len > 0) {
        try w.writeAll(" \"");
        for (t) |c| try w.writeByte(if (c == '\t' or c == '\n' or c == '"') ' ' else c);
        try w.writeByte('"');
    }
    try w.print(", filament {d}", .{l.filament});
    if (l.depth > 0) try w.print(", depth {d:.2}", .{l.depth});
    // The sizes: a hash of the items, rounded (the move of an item or a
    // change of a size is a change).
    var h = std.hash.Wyhash.init(0x1abe1);
    for (l.items) |it| {
        h.update(@tagName(it.shape));
        hashR(&h, it.at[0]);
        hashR(&h, it.at[1]);
        hashR(&h, it.angle * 10);
        switch (it.shape) {
            .text => |x| {
                h.update(x.text);
                hashR(&h, x.size);
                hashR(&h, x.weight * 10);
                hashR(&h, x.spacing);
                h.update(@tagName(x.alignment));
            },
            .line => |x| {
                hashR(&h, x.length);
                hashR(&h, x.width);
                h.update(if (x.round) "r" else "s");
            },
            .bar => |x| {
                hashR(&h, x.width);
                hashR(&h, x.height);
                hashR(&h, x.radius);
            },
            .ring => |x| {
                hashR(&h, x.outer);
                hashR(&h, x.inner);
            },
            .ticks => |x| {
                h.update(std.mem.asBytes(&x.count));
                hashR(&h, x.radius);
                hashR(&h, x.length);
                hashR(&h, x.length_end);
                hashR(&h, x.width);
                hashR(&h, x.start / 10);
                hashR(&h, x.sweep / 10);
            },
            .polyline => |x| {
                for (x.points) |p| {
                    hashR(&h, p[0]);
                    hashR(&h, p[1]);
                }
                hashR(&h, x.width);
                h.update(if (x.closed) "c" else "o");
                h.update(if (x.filled) "f" else "e");
            },
        }
    }
    try w.print(", shape {x:0>4}", .{@as(u16, @truncate(h.final()))});
    // The place, and the angle of `right` around the normal.
    try w.print(", at {d:.1} {d:.1} {d:.1}", .{ l.origin[0], l.origin[1], l.origin[2] });
    try w.print(", facing {d:.0} {d:.0} {d:.0}", .{ l.normal[0] * 100, l.normal[1] * 100, l.normal[2] * 100 });
    const r0 = defaultRight(l.normal, .{ 1, 0, 0 });
    const ang = std.math.atan2(dot(cross(r0, l.right), l.normal), dot(r0, l.right));
    try w.print(", turned {d:.0}", .{std.math.radiansToDegrees(ang)});
}

fn hashR(h: *std.hash.Wyhash, x: f64) void {
    const r: i64 = @intFromFloat(std.math.clamp(@round(x * 10), -1e15, 1e15));
    h.update(std.mem.asBytes(&r));
}

const testing = std.testing;

/// The item of `one` (the tests run one at a time).
var one_item: [1]Item = undefined;

/// A label of one item (valid until the next call).
fn one(shape: Shape) Label {
    one_item[0] = .{ .shape = shape };
    return .{ .items = &one_item };
}

fn areaOf(l: Label) !f64 {
    var p = try outline(testing.allocator, &l);
    defer p.deinit(testing.allocator);
    return p.areaMm2();
}

fn boxOf(l: Label) ![4]f64 {
    var p = try outline(testing.allocator, &l);
    defer p.deinit(testing.allocator);
    const b = p.bounds();
    return .{ geom.toMm(b.min.x), geom.toMm(b.min.y), geom.toMm(b.max.x), geom.toMm(b.max.y) };
}

test "label: the area and the box of each shape" {
    // A line 10 x 1, and with round ends.
    try testing.expectApproxEqAbs(@as(f64, 10), try areaOf(one(.{ .line = .{ .length = 10, .width = 1 } })), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 9 + std.math.pi * 0.25), try areaOf(one(.{ .line = .{ .length = 10, .width = 1, .round = true } })), 0.02);
    const lb = try boxOf(one(.{ .line = .{ .length = 10, .width = 1, .round = true } }));
    try testing.expectApproxEqAbs(@as(f64, -5), lb[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 5), lb[2], 0.01);
    // A bar 8 x 4 with corners of r 1.
    try testing.expectApproxEqAbs(@as(f64, 32 - (4 - std.math.pi)), try areaOf(one(.{ .bar = .{ .width = 8, .height = 4, .radius = 1 } })), 0.05);
    const bb = try boxOf(one(.{ .bar = .{ .width = 8, .height = 4 } }));
    try testing.expectEqualSlices(f64, &.{ -4, -2, 4, 2 }, &bb);
    // A ring of r 5 and 3, and a disk.
    try testing.expectApproxEqAbs(std.math.pi * 16, try areaOf(one(.{ .ring = .{ .outer = 5, .inner = 3 } })), 0.02);
    try testing.expectApproxEqAbs(std.math.pi * 25, try areaOf(one(.{ .ring = .{ .outer = 5 } })), 0.02);
    // A filled square of 4, and an open L of width 1 (two strokes and a
    // round join).
    var sq = [_][2]f64{ .{ 0, 0 }, .{ 0, 4 }, .{ 4, 4 }, .{ 4, 0 } };
    try testing.expectApproxEqAbs(@as(f64, 16), try areaOf(one(.{ .polyline = .{ .points = &sq, .width = 0, .filled = true } })), 1e-3);
    var el = [_][2]f64{ .{ 0, 5 }, .{ 0, 0 }, .{ 5, 0 } };
    const la = try areaOf(one(.{ .polyline = .{ .points = &el, .width = 1 } }));
    // 2 x 5 x 1, less the overlap of the corner, plus the quarter of the
    // disk of the join out of the two strokes.
    try testing.expectApproxEqAbs(10 - 0.25 + 0.25 * std.math.pi * 0.25, la, 0.01);
}

test "label: ticks at the right angles and lengths" {
    const gpa = testing.allocator;
    // Three ticks from 90° over -180° (90, 0, -90), length 2 to 4.
    const l = one(.{ .ticks = .{ .count = 3, .radius = 10, .length = 2, .length_end = 4, .width = 0.5, .start = 90, .sweep = -180 } });
    var p = try outline(gpa, &l);
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), p.count());
    try testing.expectApproxEqAbs(0.5 * (2 + 3 + 4), p.areaMm2(), 1e-3);
    const b = p.bounds();
    // Up to 12 at the top, 13 to the right, 14 at the bottom.
    try testing.expectApproxEqAbs(@as(f64, 12), geom.toMm(b.max.y), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 13), geom.toMm(b.max.x), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, -14), geom.toMm(b.min.y), 1e-3);
    // The default arc of a knob: 225° clockwise through 270°.
    const k = one(.{ .ticks = .{ .count = 11, .radius = 8, .length = 2, .width = 0.6 } });
    try testing.expectApproxEqAbs(11 * 2 * 0.6, try areaOf(k), 0.01);
}

test "label: the union of two items" {
    const gpa = testing.allocator;
    var items = [_]Item{
        .{ .shape = .{ .bar = .{ .width = 4, .height = 4 } } },
        .{ .at = .{ 2, 0 }, .shape = .{ .bar = .{ .width = 4, .height = 4 } } },
    };
    const l: Label = .{ .items = &items };
    var p = try outline(gpa, &l);
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), p.count());
    try testing.expectApproxEqAbs(@as(f64, 24), p.areaMm2(), 1e-6);
    // A turned item: a bar 4 x 2 turned 90° is 2 wide and 4 tall.
    var turned = [_]Item{.{ .angle = 90, .shape = .{ .bar = .{ .width = 4, .height = 2 } } }};
    const b = try boxOf(.{ .items = &turned });
    try testing.expectApproxEqAbs(@as(f64, 1), b[2], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 2), b[3], 1e-3);
}

test "label: a text outline, and its weight" {
    var items = [_]Item{.{ .shape = .{ .text = .{ .text = "IH", .size = 5 } } }};
    const a0 = try areaOf(.{ .items = &items });
    items[0].shape.text.weight = 0.1;
    const a1 = try areaOf(.{ .items = &items });
    try testing.expect(a0 > 5 and a1 > a0 + 1);
    const b = try boxOf(.{ .items = &items });
    try testing.expectApproxEqAbs(@as(f64, 2.5 + 0.1), b[3], 0.01);
}

test "label: JSON goes out and comes back" {
    const gpa = testing.allocator;
    const json =
        \\{"id":7,"name":"Volume","origin":[10,0,5],"normal":[0,-1,0],"right":[1,0,0],"filament":3,"depth":0.84,
        \\ "items":[{"kind":"text","text":"VOLUME \"é\"","size":5,"weight":0.05},
        \\  {"kind":"ticks","at":[0,-12],"count":11,"radius":8,"length":1.5,"length_end":3,"width":0.6},
        \\  {"kind":"polyline","points":[[0,0],[1,2],[3,1]],"width":0.5,"closed":true}]}
    ;
    var l = try parse(gpa, json, .{});
    defer l.deinit(gpa);
    try testing.expectEqual(@as(u32, 7), l.id);
    try testing.expectEqual(@as(u32, 3), l.filament);
    try testing.expectEqualStrings("VOLUME \"é\"", l.firstText());
    try testing.expectEqual(@as(usize, 3), l.items.len);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&l, &out.writer);
    var back = try parse(gpa, out.written(), .{});
    defer back.deinit(gpa);
    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try write(&back, &out2.writer);
    try testing.expectEqualStrings(out.written(), out2.written());
    var c = try l.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(f64, 1.5), c.items[1].shape.ticks.length);
    // The summary: the kind, the text, and the filament.
    var s: std.Io.Writer.Allocating = .init(gpa);
    defer s.deinit();
    try summary(&l, &s.writer);
    try testing.expect(std.mem.startsWith(u8, s.written(), "text \"VOLUME  é \", filament 3"));
}

test "label: bad JSON fails cleanly" {
    const gpa = testing.allocator;
    const frame = "\"origin\":[0,0,0],\"normal\":[1,0,0],\"right\":[0,1,0]";
    const bad = [_][]const u8{
        "",
        "[]",
        "{\"items\":[]}", // no frame
        "{" ++ frame ++ ",\"items\":[{\"kind\":\"text\",\"text\":\"A\",\"size\":NaN}]}",
        "{" ++ frame ++ ",\"items\":[{\"kind\":\"text\",\"text\":\"A\",\"size\":1e400}]}",
        "{" ++ frame ++ ",\"items\":[{\"kind\":\"ticks\",\"count\":100000,\"radius\":1,\"length\":1,\"width\":1}]}",
        "{" ++ frame ++ ",\"items\":[{\"kind\":\"star\"}]}",
        "{" ++ frame ++ ",\"items\":[{\"kind\":\"ring\",\"outer\":1,\"inner\":2}]}",
        "{\"origin\":[0,0,0],\"normal\":[1,0,0],\"right\":[1,0,0],\"items\":[]}", // not at right angles
        "{\"origin\":[0,0,0],\"normal\":[2,0,0],\"right\":[0,1,0],\"items\":[]}", // not unit
        "{" ++ frame ++ ",\"filament\":0,\"items\":[]}",
    };
    for (bad) |b| try testing.expectError(error.BadLabel, parse(gpa, b, .{}));
    // A long text.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    try long.appendSlice(gpa, "{" ++ frame ++ ",\"items\":[{\"kind\":\"text\",\"size\":5,\"text\":\"");
    try long.appendNTimes(gpa, 'A', max_text + 1);
    try long.appendSlice(gpa, "\"}]}");
    try testing.expectError(error.BadLabel, parse(gpa, long.items, .{}));
    // Too many items.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(gpa);
    try many.appendSlice(gpa, "{" ++ frame ++ ",\"items\":[");
    for (0..max_items + 1) |k| try many.appendSlice(gpa, if (k == 0) "{\"kind\":\"ring\",\"outer\":1}" else ",{\"kind\":\"ring\",\"outer\":1}");
    try many.appendSlice(gpa, "]}");
    try testing.expectError(error.BadLabel, parse(gpa, many.items, .{}));
    // The shapes alone, with no frame.
    var s = try parse(gpa, "{\"items\":[{\"kind\":\"ring\",\"outer\":1}]}", .{ .frame = false });
    s.deinit(gpa);
}

test "label: the default right" {
    // A side face that looks along -y: right is +x.
    const r = defaultRight(.{ 0, -1, 0 }, .{ 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 1), r[0], 1e-12);
    // A top face: the right of the camera, in the plane.
    const t = defaultRight(.{ 0, 0, 1 }, .{ 0.6, 0.8, 0.3 });
    try testing.expectApproxEqAbs(@as(f64, 0.6), t[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), t[2], 1e-12);
}
