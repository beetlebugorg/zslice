//! The paint of a part: a filament for each triangle of its mesh, or for
//! the pieces of a triangle.
//!
//! A triangle has a state: 0 (no paint: the filament of the part) or k
//! (filament k, from 1). A triangle with a finer paint is split into a
//! tree of smaller triangles, and each leaf has a state. The tree uses the
//! form of the paint of PrusaSlicer and Bambu Studio in a 3MF file, so a
//! painted file opens with its paint, and zslice writes the same form:
//!
//! - Each node is a nibble (4 bits). Its low 2 bits are the number of
//!   split sides (0: a leaf). A split node has the side in its high 2 bits,
//!   then its children, the last child first.
//! - A leaf has its state in the high 2 bits for states 0 to 2. For
//!   states 3 to 16 the high bits are 3, and the next nibble is the state
//!   minus 3. For states 17 to 255 that nibble is 14, and two more nibbles
//!   have the state minus 17 (the low nibble first).
//! - The text of a triangle is the nibbles as hex digits, the first nibble
//!   last ("slic3rpe:mmu_segmentation" in PrusaSlicer, "paint_color" in
//!   Bambu Studio). No text: state 0.
//!
//! The split of a node with the vertices v0, v1, v2 and the side s: r0,
//! r1, r2 are v[s], v[s+1], v[s+2] (mod 3), and mAB is the middle of the
//! edge from A to B.
//!
//! - One side: the edge r1 r2 splits. Children (r0, r1, m12) and (m12,
//!   r2, r0).
//! - Two sides: the edges r0 r1 and r2 r0 split. Children (r0, m01, m20),
//!   (m01, r1, m20), and (r1, r2, m20).
//! - Three sides (s is 0): all edges split. Children (v0, m01, m20), (m01,
//!   v1, m12), (m12, v2, m20), and (m01, m12, m20).
//!
//! zslice keeps the state of each triangle in one byte, and the nibbles
//! of a split triangle in a map (one byte each). A part with no paint has
//! no memory for it. A brush splits only the triangles on its edge, to
//! the depth that gives a clean border, so the memory stays small.
//!
//! References (see REFERENCES.md): the paint of PrusaSlicer
//! (TriangleSelector, the 3MF attribute slic3rpe:mmu_segmentation) and
//! Bambu Studio (paint_color): the form and the rules only, the code is
//! new. The closest point of a triangle (Ericson), the ray and triangle
//! test (Moller and Trumbore), and the walk of a ray through a grid
//! (Amanatides and Woo).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

pub const V3 = [3]f32;

/// The state byte of a triangle with a tree in `Paint.trees`.
pub const split: u8 = 0xff;

/// The deepest split of a brush: an edge of a triangle splits 2^depth
/// times.
pub const max_depth = 7;

/// The limits of the paint text of one triangle in a file: its length
/// (hex digits) and the depth of its tree. A text past them is no paint.
/// The tree of a brush is at most `max_depth` deep, and PrusaSlicer and
/// Bambu Studio split less deep than this.
pub const max_text = 16384;
pub const max_file_depth = 16;

pub const Paint = struct {
    /// The state of each triangle, or `split`. Empty: no paint.
    states: std.ArrayList(u8) = .empty,
    /// The nibbles of each split triangle, in the order of the 3MF form.
    trees: std.AutoArrayHashMapUnmanaged(u32, []u8) = .empty,

    pub fn deinit(p: *Paint, gpa: Allocator) void {
        p.states.deinit(gpa);
        for (p.trees.values()) |t| gpa.free(t);
        p.trees.deinit(gpa);
        p.* = .{};
    }

    pub fn clone(p: *const Paint, gpa: Allocator) Allocator.Error!Paint {
        var out: Paint = .{};
        errdefer out.deinit(gpa);
        try out.states.appendSlice(gpa, p.states.items);
        var it = p.trees.iterator();
        while (it.next()) |e| try out.trees.put(gpa, e.key_ptr.*, try gpa.dupe(u8, e.value_ptr.*));
        return out;
    }

    /// True if no triangle has paint.
    pub fn isEmpty(p: *const Paint) bool {
        if (p.trees.count() > 0) return false;
        for (p.states.items) |s| if (s != 0) return false;
        return true;
    }

    /// Room for `n` triangles, all with no paint.
    pub fn ensure(p: *Paint, gpa: Allocator, n: usize) Allocator.Error!void {
        if (p.states.items.len >= n) return;
        try p.states.appendNTimes(gpa, 0, n - p.states.items.len);
    }

    pub fn stateOf(p: *const Paint, tri: usize) u8 {
        return if (tri < p.states.items.len) p.states.items[tri] else 0;
    }

    /// Paints a whole triangle.
    pub fn setTriangle(p: *Paint, gpa: Allocator, tri: usize, state: u8) Allocator.Error!void {
        if (state == 0 and tri >= p.states.items.len) return;
        try p.ensure(gpa, tri + 1);
        if (p.states.items[tri] == split) {
            if (p.trees.fetchSwapRemove(@intCast(tri))) |kv| gpa.free(kv.value);
        }
        p.states.items[tri] = state;
    }

    /// A hash of the paint, for the keys of a slice.
    pub fn hash(p: *const Paint) u64 {
        var h = std.hash.Wyhash.init(0x9a17);
        var last: usize = 0;
        for (p.states.items, 0..) |s, i| if (s != 0) {
            last = i + 1;
        };
        h.update(p.states.items[0..last]);
        const keys = p.trees.keys();
        // The order of the map changes with removals: sort the keys.
        var sum: u64 = 0;
        for (keys, p.trees.values()) |k, v| sum +%= std.hash.Wyhash.hash(k, v);
        h.update(std.mem.asBytes(&sum));
        return h.final();
    }

    /// The states that the paint uses: bit k for state k.
    pub fn used(p: *const Paint) u32 {
        var m: u32 = 0;
        for (p.states.items) |s| if (s != split and s < 32) {
            m |= @as(u32, 1) << @intCast(s);
        };
        for (p.trees.values()) |t| {
            var r: Reader = .{ .nib = t };
            while (r.at < t.len) {
                const n = r.node() orelse break;
                if (n.sides == 0 and n.state < 32) m |= @as(u32, 1) << @intCast(n.state);
            }
        }
        return m;
    }

    /// Sets the paint of a triangle from its 3MF text (hex digits).
    pub fn setText(p: *Paint, gpa: Allocator, tri: usize, text: []const u8) (Allocator.Error || error{BadPaint})!void {
        if (text.len == 0) return p.setTriangle(gpa, tri, 0);
        // The text of a file is untrusted: a size and a depth limit.
        if (text.len > max_text) return error.BadPaint;
        const nib = try gpa.alloc(u8, text.len);
        errdefer gpa.free(nib);
        for (text, 0..) |c, k| {
            const d: u8 = switch (c) {
                '0'...'9' => c - '0',
                'A'...'F' => c - 'A' + 10,
                'a'...'f' => c - 'a' + 10,
                else => return error.BadPaint,
            };
            nib[text.len - 1 - k] = d;
        }
        // A check: the nibbles make one whole tree.
        var r: Reader = .{ .nib = nib };
        if (!r.skipTree() or r.at != nib.len) return error.BadPaint;
        const first = (Reader{ .nib = nib }).peek() orelse return error.BadPaint;
        if (first.sides == 0) {
            gpa.free(nib);
            return p.setTriangle(gpa, tri, first.state);
        }
        try p.setTriangle(gpa, tri, 0);
        try p.ensure(gpa, tri + 1);
        p.states.items[tri] = split;
        try p.trees.put(gpa, @intCast(tri), nib);
    }

    /// Writes the 3MF text of a triangle (empty for no paint).
    pub fn writeText(p: *const Paint, tri: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = p.stateOf(tri);
        if (s == 0) return;
        var one: [4]u8 = undefined;
        const nib: []const u8 = if (s == split) p.trees.get(@intCast(tri)) orelse return else leafNibbles(s, &one);
        var k = nib.len;
        while (k > 0) {
            k -= 1;
            try w.writeByte("0123456789ABCDEF"[nib[k] & 15]);
        }
    }

    /// The paint as text: a line "triangle text" for each painted
    /// triangle of the first `n` (the form of the history and of the
    /// shells).
    pub fn writeLines(p: *const Paint, n: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..@min(n, p.states.items.len)) |i| if (p.states.items[i] != 0) {
            try w.print("{d} ", .{i});
            try p.writeText(i, w);
            try w.writeByte('\n');
        };
    }

    /// Reads the text of `writeLines` for a mesh of `n` triangles, in
    /// place of the paint. A line with a triangle out of range or a bad
    /// text is left out.
    pub fn readLines(p: *Paint, gpa: Allocator, text: []const u8, n: usize) Allocator.Error!void {
        p.deinit(gpa);
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const tri = std.fmt.parseInt(u32, line[0..sp], 10) catch continue;
            if (tri >= n) continue;
            p.setText(gpa, tri, std.mem.trim(u8, line[sp + 1 ..], " \r")) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadPaint => {},
            };
        }
    }

    /// Calls `f(ctx, a, b, c, state)` for each painted leaf of triangle
    /// `tri` of `m` (state 0 too), with the vertices of the leaf.
    pub fn leaves(p: *const Paint, m: *const Mesh, tri: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), V3, V3, V3, u8) void) void {
        const face = m.faces.items[tri];
        const v = [3]V3{ vec(m, face[0]), vec(m, face[1]), vec(m, face[2]) };
        const s = p.stateOf(tri);
        if (s != split) return f(ctx, v[0], v[1], v[2], s);
        const nib = p.trees.get(@intCast(tri)) orelse return;
        var r: Reader = .{ .nib = nib };
        walk(&r, v, ctx, f);
    }
};

fn vec(m: *const Mesh, i: u32) V3 {
    const q = m.vertices.items[i];
    return .{ q.x, q.y, q.z };
}

fn mid(a: V3, b: V3) V3 {
    return .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 };
}

/// The children of a split triangle (see the header): up to 4.
pub fn children(v: [3]V3, sides: u2, side: u2) struct { n: usize, t: [4][3]V3 } {
    var out: [4][3]V3 = undefined;
    switch (sides) {
        0 => return .{ .n = 0, .t = out },
        1 => {
            const s: usize = side % 3;
            const r0 = v[s];
            const r1 = v[(s + 1) % 3];
            const r2 = v[(s + 2) % 3];
            const m12 = mid(r1, r2);
            out[0] = .{ r0, r1, m12 };
            out[1] = .{ m12, r2, r0 };
            return .{ .n = 2, .t = out };
        },
        2 => {
            const s: usize = side % 3;
            const r0 = v[s];
            const r1 = v[(s + 1) % 3];
            const r2 = v[(s + 2) % 3];
            const m01 = mid(r0, r1);
            const m20 = mid(r2, r0);
            out[0] = .{ r0, m01, m20 };
            out[1] = .{ m01, r1, m20 };
            out[2] = .{ r1, r2, m20 };
            return .{ .n = 3, .t = out };
        },
        3 => {
            const m01 = mid(v[0], v[1]);
            const m12 = mid(v[1], v[2]);
            const m20 = mid(v[2], v[0]);
            out[0] = .{ v[0], m01, m20 };
            out[1] = .{ m01, v[1], m12 };
            out[2] = .{ m12, v[2], m20 };
            out[3] = .{ m01, m12, m20 };
            return .{ .n = 4, .t = out };
        },
    }
}

const Node = struct { sides: u2, side: u2, state: u8 };

/// Reads the nodes of a tree, one at a time, in the order of the form.
const Reader = struct {
    nib: []const u8,
    at: usize = 0,

    fn next(r: *Reader) ?u8 {
        if (r.at >= r.nib.len) return null;
        r.at += 1;
        return r.nib[r.at - 1];
    }

    fn peek(r: Reader) ?Node {
        var c = r;
        return c.node();
    }

    fn node(r: *Reader) ?Node {
        const code = r.next() orelse return null;
        const sides: u2 = @intCast(code & 3);
        if (sides != 0) return .{ .sides = sides, .side = @intCast(code >> 2), .state = 0 };
        if (code >> 2 != 3) return .{ .sides = 0, .side = 0, .state = code >> 2 };
        const n2 = r.next() orelse return null;
        if (n2 != 14) return .{ .sides = 0, .side = 0, .state = n2 + 3 };
        const lo = r.next() orelse return null;
        const hi = r.next() orelse return null;
        return .{ .sides = 0, .side = 0, .state = @intCast(@min(255, @as(u32, lo | (hi << 4)) + 17)) };
    }

    /// Reads one whole tree. False if the nibbles end early.
    /// Reads one whole tree, at most `max_file_depth` deep. False if the
    /// nibbles end early or the tree is deeper.
    fn skipTree(r: *Reader) bool {
        return r.skipDepth(0);
    }

    fn skipDepth(r: *Reader, depth: usize) bool {
        const n = r.node() orelse return false;
        if (n.sides == 0) return true;
        if (depth >= max_file_depth) return false;
        for (0..@as(usize, n.sides) + 1) |_| if (!r.skipDepth(depth + 1)) return false;
        return true;
    }
};

fn walk(r: *Reader, v: [3]V3, ctx: anytype, comptime f: fn (@TypeOf(ctx), V3, V3, V3, u8) void) void {
    const n = r.node() orelse return;
    if (n.sides == 0) return f(ctx, v[0], v[1], v[2], n.state);
    const ch = children(v, n.sides, n.side);
    // The last child comes first.
    var k = ch.n;
    while (k > 0) {
        k -= 1;
        walk(r, ch.t[k], ctx, f);
    }
}

/// The nibbles of a leaf with this state (1 to 4 of them).
fn leafNibbles(state: u8, buf: *[4]u8) []const u8 {
    if (state < 3) {
        buf[0] = state << 2;
        return buf[0..1];
    }
    if (state <= 16) {
        buf[0] = 0b1100;
        buf[1] = state - 3;
        return buf[0..2];
    }
    const e = state - 17;
    buf[0] = 0b1100;
    buf[1] = 14;
    buf[2] = e & 15;
    buf[3] = e >> 4;
    return buf[0..4];
}

// ---- the brush ----

/// A tree in memory, for the brush: each node is a leaf (with a state)
/// or a split (with its children).
const Tree = struct {
    nodes: std.ArrayList(TNode) = .empty,

    const TNode = struct { sides: u2 = 0, side: u2 = 0, state: u8 = 0, first: u32 = 0 };

    fn deinit(t: *Tree, gpa: Allocator) void {
        t.nodes.deinit(gpa);
    }

    /// Reads the nibbles of a tree; the root is node 0.
    fn read(t: *Tree, gpa: Allocator, r: *Reader) Allocator.Error!void {
        try t.nodes.append(gpa, .{});
        try t.readInto(gpa, r, 0);
    }

    /// Reads one node and its children into node `i`.
    fn readInto(t: *Tree, gpa: Allocator, r: *Reader, i: u32) Allocator.Error!void {
        const n = r.node() orelse return;
        t.nodes.items[i] = .{ .sides = n.sides, .side = n.side, .state = n.state };
        if (n.sides == 0) return;
        const count: u32 = @as(u32, n.sides) + 1;
        const first: u32 = @intCast(t.nodes.items.len);
        t.nodes.items[i].first = first;
        try t.nodes.appendNTimes(gpa, .{}, count);
        // The last child comes first in the nibbles.
        var k = count;
        while (k > 0) {
            k -= 1;
            try t.readInto(gpa, r, first + k);
        }
    }

    fn write(t: *const Tree, gpa: Allocator, i: u32, out: *std.ArrayList(u8)) Allocator.Error!void {
        const n = t.nodes.items[i];
        if (n.sides == 0) {
            var buf: [4]u8 = undefined;
            return out.appendSlice(gpa, leafNibbles(n.state, &buf));
        }
        try out.append(gpa, @as(u8, n.sides) | (@as(u8, n.side) << 2));
        var k: u32 = @as(u32, n.sides) + 1;
        while (k > 0) {
            k -= 1;
            try t.write(gpa, n.first + k, out);
        }
    }

    /// Joins the children of each split node with leaves of one state.
    fn simplify(t: *Tree, i: u32) void {
        const n = t.nodes.items[i];
        if (n.sides == 0) return;
        const count: u32 = @as(u32, n.sides) + 1;
        var same = true;
        var state: u8 = 0;
        for (0..count) |k| {
            t.simplify(n.first + @as(u32, @intCast(k)));
            const c = t.nodes.items[n.first + k];
            if (c.sides != 0) same = false;
            if (k == 0) state = c.state else if (c.state != state) same = false;
        }
        if (same) t.nodes.items[i] = .{ .state = state };
    }
};

/// A sphere of the brush: the center and the radius (mm).
pub const Sphere = struct {
    c: V3,
    r: f32,

    fn dist2(s: Sphere, p: V3) f32 {
        const dx = p[0] - s.c[0];
        const dy = p[1] - s.c[1];
        const dz = p[2] - s.c[2];
        return dx * dx + dy * dy + dz * dz;
    }

    /// 2: the triangle is all in the sphere; 0: none of it (by a test of
    /// its box and its points); 1: part of it.
    fn cover(s: Sphere, v: [3]V3) u8 {
        var in: usize = 0;
        for (v) |p| {
            if (s.dist2(p) <= s.r * s.r) in += 1;
        }
        if (in == 3) return 2;
        // The nearest point of the triangle to the center.
        const q = closest(s.c, v);
        if (s.dist2(q) > s.r * s.r) return 0;
        return 1;
    }
};

fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn dot(a: V3, b: V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn add(a: V3, b: V3, k: f32) V3 {
    return .{ a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k };
}

/// The point of the triangle v that is nearest to p (the method of
/// Ericson, "Real-Time Collision Detection", 5.1.5).
pub fn closest(p: V3, v: [3]V3) V3 {
    const a = v[0];
    const b = v[1];
    const c = v[2];
    const ab = sub(b, a);
    const ac = sub(c, a);
    const ap = sub(p, a);
    const d1 = dot(ab, ap);
    const d2 = dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return a;
    const bp = sub(p, b);
    const d3 = dot(ab, bp);
    const d4 = dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return add(a, ab, d1 / (d1 - d3));
    const cp = sub(p, c);
    const d5 = dot(ab, cp);
    const d6 = dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return add(a, ac, d2 / (d2 - d6));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) return add(b, sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)));
    const denom = 1 / (va + vb + vc);
    const vv = vb * denom;
    const ww = vc * denom;
    return add(add(a, ab, vv), ac, ww);
}

fn longest(v: [3]V3) f32 {
    var m: f32 = 0;
    for (0..3) |k| {
        const d = sub(v[(k + 1) % 3], v[k]);
        m = @max(m, dot(d, d));
    }
    return @sqrt(m);
}

/// Paints the part of triangle `tri` in the sphere `s` with `state`. A
/// triangle on the edge of the sphere splits until its pieces are smaller
/// than `fine` (mm), or `max_depth`. Returns true if the paint changed.
pub fn brushTriangle(p: *Paint, gpa: Allocator, m: *const Mesh, tri: usize, s: Sphere, state: u8, fine: f32) Allocator.Error!bool {
    const face = m.faces.items[tri];
    const v = [3]V3{ vec(m, face[0]), vec(m, face[1]), vec(m, face[2]) };
    const cov = s.cover(v);
    if (cov == 0) return false;
    const old = p.stateOf(tri);
    if (cov == 2) {
        if (old == state) return false;
        try p.setTriangle(gpa, tri, state);
        return true;
    }
    if (old == state) return false;
    var t: Tree = .{};
    defer t.deinit(gpa);
    if (old == split) {
        var r: Reader = .{ .nib = p.trees.get(@intCast(tri)).? };
        try t.read(gpa, &r);
    } else try t.nodes.append(gpa, .{ .state = old });
    var changed = false;
    try brushNode(&t, gpa, 0, v, s, state, fine, 0, &changed);
    if (!changed) return false;
    t.simplify(0);
    const root = t.nodes.items[0];
    if (root.sides == 0) {
        try p.setTriangle(gpa, tri, root.state);
        return true;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try t.write(gpa, 0, &out);
    const nib = try out.toOwnedSlice(gpa);
    errdefer gpa.free(nib);
    try p.setTriangle(gpa, tri, 0);
    try p.ensure(gpa, tri + 1);
    p.states.items[tri] = split;
    try p.trees.put(gpa, @intCast(tri), nib);
    return true;
}

fn brushNode(t: *Tree, gpa: Allocator, i: u32, v: [3]V3, s: Sphere, state: u8, fine: f32, depth: u32, changed: *bool) Allocator.Error!void {
    const cov = s.cover(v);
    if (cov == 0) return;
    const n = t.nodes.items[i];
    if (n.sides == 0) {
        if (n.state == state) return;
        // A leaf on the edge: split it, until it is small.
        if (cov == 1 and depth < max_depth and longest(v) > fine) {
            const first: u32 = @intCast(t.nodes.items.len);
            try t.nodes.appendNTimes(gpa, .{ .state = n.state }, 4);
            t.nodes.items[i] = .{ .sides = 3, .side = 0, .first = first };
        } else {
            // A small leaf on the edge takes the paint if its center is in
            // the sphere.
            if (cov == 2 or s.dist2(.{ (v[0][0] + v[1][0] + v[2][0]) / 3, (v[0][1] + v[1][1] + v[2][1]) / 3, (v[0][2] + v[1][2] + v[2][2]) / 3 }) <= s.r * s.r) {
                t.nodes.items[i].state = state;
                changed.* = true;
            }
            return;
        }
    }
    const node = t.nodes.items[i];
    const ch = children(v, node.sides, node.side);
    for (0..ch.n) |k| try brushNode(t, gpa, node.first + @as(u32, @intCast(k)), ch.t[k], s, state, fine, depth + 1, changed);
}

// ---- the features: the smart select ----

/// The regions of a mesh for the smart select. A sharp edge is an edge
/// whose two faces turn by more than `sharp_deg`.
///
/// - A patch is a flat or smooth region: the triangles that connect with
///   no sharp edge between them.
/// - A feature is a part that stands out of the surface or sinks into it:
///   the triangles that connect with no concave sharp edge between them.
///   A raised letter meets its base at concave edges (an inside corner),
///   and its top meets its sides at convex edges, so the top and the sides
///   of the letter are one feature.
///
/// The region of a click is the feature of the triangle, unless the
/// feature is more than half of the area of the mesh (the body of the
/// part): then it is the patch (a flat face, or a smooth surface).
pub const Features = struct {
    patch: []u32 = &.{},
    feature: []u32 = &.{},
    /// The triangles of each patch and of each feature, in order:
    /// patch_tris[patch_start[k]..patch_start[k + 1]].
    patch_start: []u32 = &.{},
    patch_tris: []u32 = &.{},
    feature_start: []u32 = &.{},
    feature_tris: []u32 = &.{},
    feature_area: []f32 = &.{},
    area: f32 = 0,

    pub const sharp_deg = 30;

    pub fn deinit(f: *Features, gpa: Allocator) void {
        inline for (.{ "patch", "feature", "patch_start", "patch_tris", "feature_start", "feature_tris", "feature_area" }) |name| gpa.free(@field(f, name));
        f.* = .{};
    }

    pub fn init(gpa: Allocator, m: *const Mesh) Allocator.Error!Features {
        const nf = m.faces.items.len;
        var f: Features = .{};
        errdefer f.deinit(gpa);
        const normals = try gpa.alloc(V3, nf);
        defer gpa.free(normals);
        const areas = try gpa.alloc(f32, nf);
        defer gpa.free(areas);
        for (m.faces.items, normals, areas) |face, *n, *a| {
            const v0 = vec(m, face[0]);
            const e1 = sub(vec(m, face[1]), v0);
            const e2 = sub(vec(m, face[2]), v0);
            const c: V3 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
            const len = @sqrt(dot(c, c));
            a.* = len / 2;
            n.* = if (len > 0) .{ c[0] / len, c[1] / len, c[2] / len } else .{ 0, 0, 0 };
            f.area += a.*;
        }
        // The edges: each (low vertex, high vertex, face, the third vertex),
        // sorted, so the two faces of an edge are next to each other.
        const Edge = struct { key: u64, face: u32, other: u32 };
        const edges = try gpa.alloc(Edge, 3 * nf);
        defer gpa.free(edges);
        for (m.faces.items, 0..) |face, i| for (0..3) |k| {
            const a = face[k];
            const b = face[(k + 1) % 3];
            const lo = @min(a, b);
            const hi = @max(a, b);
            edges[3 * i + k] = .{ .key = (@as(u64, lo) << 32) | hi, .face = @intCast(i), .other = face[(k + 2) % 3] };
        };
        std.mem.sort(Edge, edges, {}, struct {
            fn lt(_: void, x: Edge, y: Edge) bool {
                return x.key < y.key;
            }
        }.lt);
        var patch_uf = try UnionFind.init(gpa, nf);
        defer patch_uf.deinit(gpa);
        var feat_uf = try UnionFind.init(gpa, nf);
        defer feat_uf.deinit(gpa);
        const cos_sharp: f32 = @floatCast(@cos(std.math.degreesToRadians(@as(f64, sharp_deg))));
        var k: usize = 0;
        while (k < edges.len) {
            var j = k + 1;
            while (j < edges.len and edges[j].key == edges[k].key) j += 1;
            // Only an edge of two faces joins them (a seam of more faces
            // is not a surface).
            if (j - k == 2) {
                const a = edges[k];
                const b = edges[k + 1];
                const na = normals[a.face];
                const nb = normals[b.face];
                const sharp = dot(na, nb) < cos_sharp;
                if (!sharp) patch_uf.join(a.face, b.face);
                // Concave: the third vertex of b is over the plane of a.
                const p0 = vec(m, @intCast(edges[k].key >> 32));
                const ob = vec(m, b.other);
                const concave = dot(na, sub(ob, p0)) > 1e-6 * @sqrt(@max(areas[a.face], 1e-12));
                if (!(sharp and concave)) feat_uf.join(a.face, b.face);
            }
            k = j;
        }
        f.patch = try gpa.alloc(u32, nf);
        f.feature = try gpa.alloc(u32, nf);
        const pc = try patch_uf.label(f.patch);
        const fc = try feat_uf.label(f.feature);
        try lists(gpa, f.patch, pc, &f.patch_start, &f.patch_tris);
        try lists(gpa, f.feature, fc, &f.feature_start, &f.feature_tris);
        f.feature_area = try gpa.alloc(f32, fc);
        @memset(f.feature_area, 0);
        for (f.feature, areas) |id, a| f.feature_area[id] += a;
        return f;
    }

    /// The triangles of the region of a click on triangle `tri` (see
    /// `Features`).
    pub fn regionOf(f: *const Features, tri: usize) []const u32 {
        if (tri >= f.feature.len) return &.{};
        const id = f.feature[tri];
        if (f.feature_area[id] <= 0.5 * f.area) return f.feature_tris[f.feature_start[id]..f.feature_start[id + 1]];
        const p = f.patch[tri];
        return f.patch_tris[f.patch_start[p]..f.patch_start[p + 1]];
    }

    /// The id of the region of triangle `tri`: the same for each triangle
    /// of one region (features first, then patches).
    pub fn regionId(f: *const Features, tri: usize) u32 {
        if (tri >= f.feature.len) return std.math.maxInt(u32);
        const id = f.feature[tri];
        if (f.feature_area[id] <= 0.5 * f.area) return id;
        return @as(u32, @intCast(f.feature_area.len)) + f.patch[tri];
    }
};

fn lists(gpa: Allocator, ids: []const u32, count: usize, start: *[]u32, tris: *[]u32) Allocator.Error!void {
    start.* = try gpa.alloc(u32, count + 1);
    @memset(start.*, 0);
    for (ids) |id| start.*[id + 1] += 1;
    for (1..count + 1) |i| start.*[i] += start.*[i - 1];
    tris.* = try gpa.alloc(u32, ids.len);
    const fill = try gpa.alloc(u32, count);
    defer gpa.free(fill);
    @memcpy(fill, start.*[0..count]);
    for (ids, 0..) |id, i| {
        tris.*[fill[id]] = @intCast(i);
        fill[id] += 1;
    }
}

const UnionFind = struct {
    parent: []u32,

    fn init(gpa: Allocator, n: usize) Allocator.Error!UnionFind {
        const p = try gpa.alloc(u32, n);
        for (p, 0..) |*x, i| x.* = @intCast(i);
        return .{ .parent = p };
    }

    fn deinit(u: *UnionFind, gpa: Allocator) void {
        gpa.free(u.parent);
    }

    fn find(u: *UnionFind, x: u32) u32 {
        var r = x;
        while (u.parent[r] != r) r = u.parent[r];
        var c = x;
        while (u.parent[c] != r) {
            const next = u.parent[c];
            u.parent[c] = r;
            c = next;
        }
        return r;
    }

    fn join(u: *UnionFind, a: u32, b: u32) void {
        const ra = u.find(a);
        const rb = u.find(b);
        if (ra != rb) u.parent[@max(ra, rb)] = @min(ra, rb);
    }

    /// The label of each item: 0, 1, 2, ... in the order of the first
    /// item of each set. Returns the number of sets.
    fn label(u: *UnionFind, out: []u32) Allocator.Error!usize {
        var n: u32 = 0;
        for (out, 0..) |*o, i| {
            const r = u.find(@intCast(i));
            if (r == i) {
                o.* = n;
                n += 1;
            } else o.* = out[r];
        }
        return n;
    }
};

// ---- the ray hit ----

/// A grid of the triangles of a mesh, for the hit of a ray and the
/// triangles near a point.
pub const Grid = struct {
    lo: V3 = .{ 0, 0, 0 },
    cell: f32 = 1,
    n: [3]u32 = .{ 1, 1, 1 },
    start: []u32 = &.{},
    tris: []u32 = &.{},

    pub fn deinit(g: *Grid, gpa: Allocator) void {
        gpa.free(g.start);
        gpa.free(g.tris);
        g.* = .{};
    }

    pub fn init(gpa: Allocator, m: *const Mesh) Allocator.Error!Grid {
        var g: Grid = .{};
        const b = m.bounds();
        const nf = m.faces.items.len;
        const size: V3 = .{ @floatCast(b.max[0] - b.min[0]), @floatCast(b.max[1] - b.min[1]), @floatCast(b.max[2] - b.min[2]) };
        const vol = @max(size[0], 1e-3) * @max(size[1], 1e-3) * @max(size[2], 1e-3);
        // About 2 triangles for each cell (the surface fills few cells).
        const want = @max(@as(f32, @floatFromInt(nf)) / 2, 1);
        g.cell = @max(std.math.cbrt(vol / want) * 2, 0.05);
        g.lo = .{ @floatCast(b.min[0]), @floatCast(b.min[1]), @floatCast(b.min[2]) };
        for (0..3) |k| g.n[k] = @min(@as(u32, @intFromFloat(size[k] / g.cell)) + 1, 512);
        const cells: usize = @as(usize, g.n[0]) * g.n[1] * g.n[2];
        g.start = try gpa.alloc(u32, cells + 1);
        errdefer gpa.free(g.start);
        @memset(g.start, 0);
        // Two passes: count, then fill.
        for (0..2) |pass| {
            if (pass == 1) {
                for (1..cells + 1) |i| g.start[i] += g.start[i - 1];
                g.tris = try gpa.alloc(u32, g.start[cells]);
            }
            const fill: []u32 = if (pass == 1) try gpa.dupe(u32, g.start[0..cells]) else &.{};
            defer if (pass == 1) gpa.free(fill);
            for (m.faces.items, 0..) |face, i| {
                var lo: [3]u32 = undefined;
                var hi: [3]u32 = undefined;
                g.boxOf(.{ vec(m, face[0]), vec(m, face[1]), vec(m, face[2]) }, &lo, &hi);
                var z = lo[2];
                while (z <= hi[2]) : (z += 1) {
                    var y = lo[1];
                    while (y <= hi[1]) : (y += 1) {
                        var x = lo[0];
                        while (x <= hi[0]) : (x += 1) {
                            const c = g.index(x, y, z);
                            if (pass == 0) g.start[c + 1] += 1 else {
                                g.tris[fill[c]] = @intCast(i);
                                fill[c] += 1;
                            }
                        }
                    }
                }
            }
        }
        return g;
    }

    fn index(g: *const Grid, x: u32, y: u32, z: u32) usize {
        return (@as(usize, z) * g.n[1] + y) * g.n[0] + x;
    }

    fn cellOf(g: *const Grid, p: V3, k: usize) u32 {
        const c = (p[k] - g.lo[k]) / g.cell;
        if (!(c > 0)) return 0;
        return @min(@as(u32, @intFromFloat(c)), g.n[k] - 1);
    }

    fn boxOf(g: *const Grid, v: [3]V3, lo: *[3]u32, hi: *[3]u32) void {
        for (0..3) |k| {
            const a = @min(v[0][k], @min(v[1][k], v[2][k]));
            const b = @max(v[0][k], @max(v[1][k], v[2][k]));
            lo[k] = g.cellOf(.{ a, a, a }, k);
            hi[k] = g.cellOf(.{ b, b, b }, k);
        }
    }

    pub const Hit = struct { tri: u32, t: f32 };

    /// The first triangle on the ray from `o` in the direction `d`, or
    /// null. Each cell on the ray in order (a 3D DDA), and the test of
    /// Moller and Trumbore for each triangle in it.
    pub fn hit(g: *const Grid, m: *const Mesh, o: V3, d: V3) ?Hit {
        // Where the ray enters the box of the grid.
        var t0: f32 = 0;
        var t1: f32 = std.math.inf(f32);
        for (0..3) |k| {
            const lo = g.lo[k];
            const hi = g.lo[k] + g.cell * @as(f32, @floatFromInt(g.n[k]));
            if (@abs(d[k]) < 1e-12) {
                if (o[k] < lo or o[k] > hi) return null;
                continue;
            }
            var a = (lo - o[k]) / d[k];
            var b = (hi - o[k]) / d[k];
            if (a > b) std.mem.swap(f32, &a, &b);
            t0 = @max(t0, a);
            t1 = @min(t1, b);
        }
        if (t0 > t1) return null;
        const p = add(o, d, t0);
        var c: [3]i64 = .{ g.cellOf(p, 0), g.cellOf(p, 1), g.cellOf(p, 2) };
        var step: [3]i64 = undefined;
        var next: [3]f32 = undefined;
        var delta: [3]f32 = undefined;
        for (0..3) |k| {
            if (d[k] > 0) {
                step[k] = 1;
                next[k] = (g.lo[k] + g.cell * @as(f32, @floatFromInt(c[k] + 1)) - o[k]) / d[k];
                delta[k] = g.cell / d[k];
            } else if (d[k] < 0) {
                step[k] = -1;
                next[k] = (g.lo[k] + g.cell * @as(f32, @floatFromInt(c[k])) - o[k]) / d[k];
                delta[k] = -g.cell / d[k];
            } else {
                step[k] = 0;
                next[k] = std.math.inf(f32);
                delta[k] = std.math.inf(f32);
            }
        }
        var best: ?Hit = null;
        while (true) {
            const ci = g.index(@intCast(c[0]), @intCast(c[1]), @intCast(c[2]));
            for (g.tris[g.start[ci]..g.start[ci + 1]]) |tri| {
                const face = m.faces.items[tri];
                if (rayTriangle(o, d, vec(m, face[0]), vec(m, face[1]), vec(m, face[2]))) |t| {
                    if (best == null or t < best.?.t) best = .{ .tri = tri, .t = t };
                }
            }
            // The next cell: the axis with the nearest wall.
            var k: usize = 0;
            if (next[1] < next[k]) k = 1;
            if (next[2] < next[k]) k = 2;
            // A hit before the next wall is the first.
            if (best) |b| if (b.t <= next[k]) return b;
            if (next[k] > t1) return best;
            c[k] += step[k];
            if (c[k] < 0 or c[k] >= g.n[k]) return best;
            next[k] += delta[k];
        }
    }

    /// Calls `f(ctx, tri)` for each triangle in the cells of the box of a
    /// sphere (a triangle can come more than once).
    pub fn near(g: *const Grid, c: V3, r: f32, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32) void) void {
        var lo: [3]u32 = undefined;
        var hi: [3]u32 = undefined;
        g.boxOf(.{ .{ c[0] - r, c[1] - r, c[2] - r }, .{ c[0] + r, c[1] + r, c[2] + r }, c }, &lo, &hi);
        var z = lo[2];
        while (z <= hi[2]) : (z += 1) {
            var y = lo[1];
            while (y <= hi[1]) : (y += 1) {
                var x = lo[0];
                while (x <= hi[0]) : (x += 1) {
                    const ci = g.index(x, y, z);
                    for (g.tris[g.start[ci]..g.start[ci + 1]]) |tri| f(ctx, tri);
                }
            }
        }
    }
};

/// The distance along the ray to the triangle, or null (the test of
/// Moller and Trumbore, both sides).
fn rayTriangle(o: V3, d: V3, a: V3, b: V3, c: V3) ?f32 {
    const e1 = sub(b, a);
    const e2 = sub(c, a);
    const p: V3 = .{ d[1] * e2[2] - d[2] * e2[1], d[2] * e2[0] - d[0] * e2[2], d[0] * e2[1] - d[1] * e2[0] };
    const det = dot(e1, p);
    if (@abs(det) < 1e-12) return null;
    const inv = 1 / det;
    const s = sub(o, a);
    const u = dot(s, p) * inv;
    if (u < 0 or u > 1) return null;
    const q: V3 = .{ s[1] * e1[2] - s[2] * e1[1], s[2] * e1[0] - s[0] * e1[2], s[0] * e1[1] - s[1] * e1[0] };
    const v = dot(d, q) * inv;
    if (v < 0 or u + v > 1) return null;
    const t = dot(e2, q) * inv;
    return if (t > 0) t else null;
}

const testing = std.testing;

test "paint: the 3MF text of a leaf and of a split triangle" {
    const gpa = testing.allocator;
    var p: Paint = .{};
    defer p.deinit(gpa);
    // State 1 is "4", state 2 is "8", state 3 is "0C", state 5 is "2C".
    for ([_][]const u8{ "4", "8", "0C", "2C" }, [_]u8{ 1, 2, 3, 5 }) |text, s| {
        try p.setText(gpa, 0, text);
        try testing.expectEqual(s, p.stateOf(0));
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try p.writeText(0, &w);
        try testing.expectEqualStrings(text, w.buffered());
    }
    // A split in four: the children 3, 2, 1, 0 have the states 1, 2, 0, 1:
    // nibbles 3 (split, 3 sides), 4, 8, 0, 4. The text is reversed.
    try p.setText(gpa, 1, "40843");
    try testing.expectEqual(split, p.stateOf(1));
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.writeText(1, &w);
    try testing.expectEqualStrings("40843", w.buffered());
    try testing.expectError(error.BadPaint, p.setText(gpa, 2, "43"));
    // States 5 (triangle 0) and 0, 1, 2 (the pieces of triangle 1).
    try testing.expectEqual(@as(u32, 0b100111), p.used());
}

test "paint: crafted texts of a file are no paint" {
    const gpa = testing.allocator;
    var p: Paint = .{};
    defer p.deinit(gpa);
    // A tree that splits deeper than the limit: each node splits in four,
    // with its first child split again.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..max_file_depth + 2) |_| try deep.appendSlice(gpa, "4443");
    try deep.appendSlice(gpa, "3");
    try testing.expectError(error.BadPaint, p.setText(gpa, 0, deep.items));
    // A text that ends in the middle of a tree, bad digits, and a text
    // past the size limit.
    try testing.expectError(error.BadPaint, p.setText(gpa, 0, "3"));
    try testing.expectError(error.BadPaint, p.setText(gpa, 0, "4G"));
    const long = try gpa.alloc(u8, max_text + 1);
    defer gpa.free(long);
    @memset(long, '4');
    try testing.expectError(error.BadPaint, p.setText(gpa, 0, long));
    // Extra digits after a whole tree.
    try testing.expectError(error.BadPaint, p.setText(gpa, 0, "44"));
    try testing.expectEqual(@as(usize, 0), p.trees.count());
    try testing.expect(p.isEmpty());
}

fn mv(q: [3]f32) mesh_mod.Vec3 {
    return .{ .x = q[0], .y = q[1], .z = q[2] };
}

fn testMesh(gpa: Allocator) !Mesh {
    // A base of 3 x 3 cells (x and y at 0, 8, 12, 20; z 0 to 4) and a
    // raised letter, the middle cell from z 4 to 6. Each face between a
    // full cell and an empty one is two triangles, so the edges match.
    var b: mesh_mod.Builder = .init(gpa);
    defer b.deinit();
    const g = [4]f32{ 0, 8, 12, 20 };
    const zs = [3]f32{ 0, 4, 6 };
    const full = struct {
        fn f(x: i32, y: i32, z: i32) bool {
            if (x < 0 or y < 0 or z < 0 or x > 2 or y > 2 or z > 1) return false;
            return z == 0 or (x == 1 and y == 1);
        }
    }.f;
    var z: i32 = 0;
    while (z < 2) : (z += 1) {
        var y: i32 = 0;
        while (y < 3) : (y += 1) {
            var x: i32 = 0;
            while (x < 3) : (x += 1) {
                if (!full(x, y, z)) continue;
                const x0 = g[@intCast(x)];
                const x1 = g[@intCast(x + 1)];
                const y0 = g[@intCast(y)];
                const y1 = g[@intCast(y + 1)];
                const z0 = zs[@intCast(z)];
                const z1 = zs[@intCast(z + 1)];
                const quads = [6]struct { bool, [4][3]f32 }{
                    .{ !full(x, y, z - 1), .{ .{ x0, y0, z0 }, .{ x0, y1, z0 }, .{ x1, y1, z0 }, .{ x1, y0, z0 } } },
                    .{ !full(x, y, z + 1), .{ .{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y1, z1 }, .{ x0, y1, z1 } } },
                    .{ !full(x - 1, y, z), .{ .{ x0, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 }, .{ x0, y1, z0 } } },
                    .{ !full(x + 1, y, z), .{ .{ x1, y0, z0 }, .{ x1, y1, z0 }, .{ x1, y1, z1 }, .{ x1, y0, z1 } } },
                    .{ !full(x, y - 1, z), .{ .{ x0, y0, z0 }, .{ x1, y0, z0 }, .{ x1, y0, z1 }, .{ x0, y0, z1 } } },
                    .{ !full(x, y + 1, z), .{ .{ x0, y1, z0 }, .{ x0, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y1, z0 } } },
                };
                for (quads) |qd| {
                    if (!qd[0]) continue;
                    const q = qd[1];
                    try b.addTriangle(mv(q[0]), mv(q[1]), mv(q[2]));
                    try b.addTriangle(mv(q[0]), mv(q[2]), mv(q[3]));
                }
            }
        }
    }
    return b.finish();
}

/// The first triangle with all its points at height z, or one whose
/// points all have x = at_x.
fn findTri(m: *const Mesh, z: ?f32, at_x: ?f32) usize {
    for (m.faces.items, 0..) |f, i| {
        var ok = true;
        for (f) |v| {
            const p = m.vertices.items[v];
            if (z) |zz| ok = ok and p.z == zz;
            if (at_x) |xx| ok = ok and p.x == xx;
        }
        if (ok) return i;
    }
    return 0;
}

test "features: a click on a raised letter selects its top and its sides" {
    const gpa = testing.allocator;
    var m = try testMesh(gpa);
    defer m.deinit(gpa);
    var f = try Features.init(gpa, &m);
    defer f.deinit(gpa);
    // The top of the letter (z 6): its top and its four sides.
    const top_tri = findTri(&m, 6, null);
    const letter = f.regionOf(top_tri);
    try testing.expectEqual(@as(usize, 10), letter.len);
    for (letter) |t| for (m.faces.items[t]) |v| try testing.expect(m.vertices.items[v].z >= 4);
    // A click on the top of the base (z 4): the flat top of the eight
    // cells around the letter, with no letter.
    const base_tri = findTri(&m, 4, null);
    const top = f.regionOf(base_tri);
    try testing.expectEqual(@as(usize, 16), top.len);
    for (top) |t| for (m.faces.items[t]) |v| try testing.expectEqual(@as(f32, 4), m.vertices.items[v].z);
    try testing.expect(f.regionId(top_tri) == f.regionId(letter[letter.len - 1]));
    try testing.expect(f.regionId(top_tri) != f.regionId(base_tri));
}

test "grid: a ray hits the top of the letter" {
    const gpa = testing.allocator;
    var m = try testMesh(gpa);
    defer m.deinit(gpa);
    var g = try Grid.init(gpa, &m);
    defer g.deinit(gpa);
    const h = g.hit(&m, .{ 10, 10, 50 }, .{ 0, 0, -1 }).?;
    for (m.faces.items[h.tri]) |v| try testing.expectEqual(@as(f32, 6), m.vertices.items[v].z);
    try testing.expectApproxEqAbs(@as(f32, 44), h.t, 1e-4);
    const side = g.hit(&m, .{ 30, 10, 2 }, .{ -1, 0, 0 }).?;
    try testing.expectApproxEqAbs(@as(f32, 10), side.t, 1e-4);
    try testing.expect(g.hit(&m, .{ 30, 30, 50 }, .{ 0, 0, -1 }) == null);
}

test "brush: an edge splits, and the pieces in the sphere take the paint" {
    const gpa = testing.allocator;
    var m = try testMesh(gpa);
    defer m.deinit(gpa);
    var p: Paint = .{};
    defer p.deinit(gpa);
    // A sphere on the bottom face, with its edge through triangle 0.
    const s: Sphere = .{ .c = .{ 5, 5, 0 }, .r = 3 };
    try testing.expect(try brushTriangle(&p, gpa, &m, 0, s, 2, 0.5));
    try testing.expectEqual(split, p.stateOf(0));
    // The leaves in the sphere have state 2, the others 0, and their
    // area is the area of the triangle.
    const Sum = struct {
        in: f32 = 0,
        all: f32 = 0,
        fn f(c: *@This(), a: V3, b: V3, cc: V3, st: u8) void {
            const e1 = sub(b, a);
            const e2 = sub(cc, a);
            const x: V3 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
            const ar = @sqrt(dot(x, x)) / 2;
            c.all += ar;
            if (st == 2) c.in += ar;
        }
    };
    var sum: Sum = .{};
    p.leaves(&m, 0, &sum, Sum.f);
    try testing.expectApproxEqAbs(@as(f32, 32), sum.all, 0.01);
    // The disk (28 mm²) has its center on the edge of the triangle: about
    // half of it is in the triangle.
    try testing.expect(sum.in > 8 and sum.in < 22);
    // The text reads back to the same tree.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try p.writeText(0, &out.writer);
    var q: Paint = .{};
    defer q.deinit(gpa);
    try q.setText(gpa, 0, out.written());
    try testing.expectEqualSlices(u8, p.trees.get(0).?, q.trees.get(0).?);
    // The whole triangle in a large sphere: one state again.
    try testing.expect(try brushTriangle(&p, gpa, &m, 0, .{ .c = .{ 10, 10, 0 }, .r = 40 }, 2, 0.5));
    try testing.expectEqual(@as(u8, 2), p.stateOf(0));
    try testing.expectEqual(@as(usize, 0), p.trees.count());
}
