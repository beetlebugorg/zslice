//! Triangle meshes, and the STL and OBJ file formats.
//!
//! An STL file is a list of triangles. Each triangle has its own three
//! vertices, and the file does not say which triangles share a vertex. The
//! slicer needs that information: it follows a cut line from one triangle to
//! the next through the edge they share (see `slicer.zig`). So the loader
//! "welds" the vertices: vertices with bit-equal coordinates become one
//! vertex.
//!
//! The vertex order of a triangle gives the outside of the mesh. Seen from
//! outside, the vertices are counterclockwise (the right-hand rule).
//!
//! An OBJ file (Wavefront) lists the vertices ("v x y z") and the faces
//! ("f 1 2 3 4", with indices from 1, or from the end with a minus). A
//! face with more than three vertices becomes a fan of triangles from its
//! first vertex. The loader welds the vertices as for STL, and skips the
//! texture coordinates, the normals, the groups, and the materials. An
//! OBJ file has no unit: zslice reads it in mm.
//!
//! STL and OBJ formats: see docs/references/formats-and-protocols.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Bounds3 = struct {
    min: [3]f64,
    max: [3]f64,
};

pub const Error = error{ InvalidStl, InvalidMesh, EmptyMesh } || Allocator.Error;

/// The largest coordinate (mm) that a mesh can have: 100 m. Larger values
/// are not a real part, and they would overflow the integer coordinates.
pub const max_coordinate: f32 = 100_000;

pub const Mesh = struct {
    vertices: std.ArrayList(Vec3) = .empty,
    faces: std.ArrayList([3]u32) = .empty,

    pub const empty: Mesh = .{};

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        self.vertices.deinit(gpa);
        self.faces.deinit(gpa);
        self.* = .empty;
    }

    /// A copy of the mesh, in `gpa`.
    pub fn clone(self: Mesh, gpa: Allocator) Allocator.Error!Mesh {
        var out: Mesh = .{};
        errdefer out.deinit(gpa);
        try out.vertices.appendSlice(gpa, self.vertices.items);
        try out.faces.appendSlice(gpa, self.faces.items);
        return out;
    }

    pub fn bounds(self: Mesh) Bounds3 {
        var b: Bounds3 = .{ .min = @splat(std.math.inf(f64)), .max = @splat(-std.math.inf(f64)) };
        for (self.vertices.items) |v| {
            const p = [3]f64{ v.x, v.y, v.z };
            for (0..3) |i| {
                b.min[i] = @import("geom.zig").fmin(b.min[i], p[i]);
                b.max[i] = @import("geom.zig").fmax(b.max[i], p[i]);
            }
        }
        return b;
    }

    pub fn translate(self: *Mesh, dx: f64, dy: f64, dz: f64) void {
        for (self.vertices.items) |*v| {
            v.x = @floatCast(v.x + dx);
            v.y = @floatCast(v.y + dy);
            v.z = @floatCast(v.z + dz);
        }
    }

    /// The separate bodies of the mesh: the sets of faces that share
    /// vertices, each as a mesh of its own, the largest first (by face
    /// count). A mesh of one body gives one mesh. The caller owns the
    /// meshes and the slice.
    pub fn components(self: Mesh, gpa: Allocator) Allocator.Error![]Mesh {
        const nv = self.vertices.items.len;
        // Union-find over the vertices; each face joins its three.
        const parent = try gpa.alloc(u32, nv);
        defer gpa.free(parent);
        for (parent, 0..) |*q, i| q.* = @intCast(i);
        const find = struct {
            fn f(par: []u32, x0: u32) u32 {
                var x = x0;
                while (par[x] != x) {
                    par[x] = par[par[x]];
                    x = par[x];
                }
                return x;
            }
        }.f;
        for (self.faces.items) |f| {
            const a = find(parent, f[0]);
            for (f[1..]) |v| {
                const b = find(parent, v);
                if (a != b) parent[b] = a;
            }
        }
        // The body of each root, in the order of first use.
        const body = try gpa.alloc(u32, nv);
        defer gpa.free(body);
        @memset(body, std.math.maxInt(u32));
        var n: u32 = 0;
        var counts: std.ArrayList(usize) = .empty;
        defer counts.deinit(gpa);
        for (self.faces.items) |f| {
            const r = find(parent, f[0]);
            if (body[r] == std.math.maxInt(u32)) {
                body[r] = n;
                n += 1;
                try counts.append(gpa, 0);
            }
            counts.items[body[r]] += 1;
        }
        const out = try gpa.alloc(Mesh, n);
        for (out) |*m| m.* = .empty;
        errdefer {
            for (out) |*m| m.deinit(gpa);
            gpa.free(out);
        }
        // The new index of each vertex in its body.
        const remap = try gpa.alloc(u32, nv);
        defer gpa.free(remap);
        @memset(remap, std.math.maxInt(u32));
        for (self.faces.items) |f| {
            const m = &out[body[find(parent, f[0])]];
            var g: [3]u32 = undefined;
            for (f, 0..) |v, k| {
                if (remap[v] == std.math.maxInt(u32)) {
                    remap[v] = @intCast(m.vertices.items.len);
                    try m.vertices.append(gpa, self.vertices.items[v]);
                }
                g[k] = remap[v];
            }
            try m.faces.append(gpa, g);
        }
        // The largest first.
        const Ctx = struct {
            fn lt(_: void, a: Mesh, b: Mesh) bool {
                return a.faces.items.len > b.faces.items.len;
            }
        };
        std.mem.sort(Mesh, out, {}, Ctx.lt);
        return out;
    }

    /// Loads a binary or ASCII STL file.
    pub fn fromStl(gpa: Allocator, bytes: []const u8) Error!Mesh {
        if (isBinaryStl(bytes)) return parseBinaryStl(gpa, bytes);
        if (isObj(bytes)) return parseObj(gpa, bytes);
        return parseAsciiStl(gpa, bytes);
    }

    /// Makes a mesh from a triangle list: 9 floats (3 vertices of x, y, z)
    /// for each triangle.
    pub fn fromTriangles(gpa: Allocator, xyz: []const f32) Error!Mesh {
        var b: Builder = .init(gpa);
        errdefer b.deinit();
        var i: usize = 0;
        while (i + 9 <= xyz.len) : (i += 9) {
            try b.addTriangle(
                .{ .x = xyz[i], .y = xyz[i + 1], .z = xyz[i + 2] },
                .{ .x = xyz[i + 3], .y = xyz[i + 4], .z = xyz[i + 5] },
                .{ .x = xyz[i + 6], .y = xyz[i + 7], .z = xyz[i + 8] },
            );
        }
        return b.finish();
    }

    /// Writes the mesh as a binary STL file.
    pub fn writeStl(self: Mesh, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var header: [80]u8 = @splat(' ');
        @memcpy(header[0..6], "zslice");
        try w.writeAll(&header);
        try w.writeInt(u32, @intCast(self.faces.items.len), .little);
        for (self.faces.items) |f| {
            const a = self.vertices.items[f[0]];
            const b = self.vertices.items[f[1]];
            const c = self.vertices.items[f[2]];
            const n = normal(a, b, c);
            for ([_]Vec3{ n, a, b, c }) |v| {
                try w.writeInt(u32, @bitCast(v.x), .little);
                try w.writeInt(u32, @bitCast(v.y), .little);
                try w.writeInt(u32, @bitCast(v.z), .little);
            }
            try w.writeInt(u16, 0, .little);
        }
    }
};

fn normal(a: Vec3, b: Vec3, c: Vec3) Vec3 {
    const u = [3]f32{ b.x - a.x, b.y - a.y, b.z - a.z };
    const v = [3]f32{ c.x - a.x, c.y - a.y, c.z - a.z };
    var n = Vec3{ .x = u[1] * v[2] - u[2] * v[1], .y = u[2] * v[0] - u[0] * v[2], .z = u[0] * v[1] - u[1] * v[0] };
    const len = @sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (len > 0) {
        n.x /= len;
        n.y /= len;
        n.z /= len;
    }
    return n;
}

/// Builds a mesh one triangle at a time and welds equal vertices.
pub const Builder = struct {
    gpa: Allocator,
    mesh: Mesh = .empty,
    map: std.AutoHashMapUnmanaged([3]u32, u32) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Builder) void {
        self.mesh.deinit(self.gpa);
        self.map.deinit(self.gpa);
    }

    fn vertex(self: *Builder, v: Vec3) Allocator.Error!u32 {
        // -0.0 and +0.0 have different bits but are the same point.
        const key = [3]u32{ @bitCast(v.x + 0.0), @bitCast(v.y + 0.0), @bitCast(v.z + 0.0) };
        const gop = try self.map.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.mesh.vertices.items.len);
            try self.mesh.vertices.append(self.gpa, v);
        }
        return gop.value_ptr.*;
    }

    /// Reserves memory for `triangles` triangles. A closed mesh has about
    /// half as many vertices as triangles. One allocation of the right size
    /// uses less peak memory than many steps of growth.
    pub fn reserve(self: *Builder, triangles: usize) Allocator.Error!void {
        try self.mesh.faces.ensureTotalCapacity(self.gpa, triangles);
        try self.mesh.vertices.ensureTotalCapacity(self.gpa, triangles / 2 + 3);
        try self.map.ensureTotalCapacity(self.gpa, @intCast(triangles / 2 + 3));
    }

    /// Adds a triangle. Returns `error.InvalidMesh` if a coordinate is not
    /// a finite number, or is larger than `max_coordinate`.
    pub fn addTriangle(self: *Builder, a: Vec3, b: Vec3, c: Vec3) Error!void {
        for ([_]Vec3{ a, b, c }) |v| {
            for ([_]f32{ v.x, v.y, v.z }) |f| {
                if (!(@abs(f) <= max_coordinate)) return error.InvalidMesh;
            }
        }
        const ia = try self.vertex(a);
        const ib = try self.vertex(b);
        const ic = try self.vertex(c);
        // A triangle with two equal vertices has no area. Skip it.
        if (ia == ib or ib == ic or ia == ic) return;
        try self.mesh.faces.append(self.gpa, .{ ia, ib, ic });
    }

    /// Adds a quad as two triangles. The points are counterclockwise as
    /// seen from outside.
    pub fn addQuad(self: *Builder, a: Vec3, b: Vec3, c: Vec3, d: Vec3) Error!void {
        try self.addTriangle(a, b, c);
        try self.addTriangle(a, c, d);
    }

    /// Returns the mesh and frees the weld table. The caller owns the mesh.
    pub fn finish(self: *Builder) Error!Mesh {
        self.map.deinit(self.gpa);
        self.map = .empty;
        if (self.mesh.faces.items.len == 0) {
            self.mesh.deinit(self.gpa);
            return error.EmptyMesh;
        }
        const m = self.mesh;
        self.mesh = .empty;
        return m;
    }
};

/// A binary STL file has an 80-byte header, a 32-bit triangle count, and 50
/// bytes for each triangle. Some binary files start with "solid", like an
/// ASCII file, and some have extra bytes at the end. The rules:
///
/// - The size is exactly right for the count: binary.
/// - The file starts with "solid" and has the word "facet": ASCII.
/// - The file is at least the size for the count: binary.
fn isBinaryStl(bytes: []const u8) bool {
    if (bytes.len < 84) return false;
    const n = std.mem.readInt(u32, bytes[80..84], .little);
    const want = @as(u64, 84) + @as(u64, n) * 50;
    if (want == bytes.len) return true;
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 512)], " \t\r\n");
    if (std.mem.startsWith(u8, head, "solid") and std.mem.indexOf(u8, bytes[0..@min(bytes.len, 4096)], "facet") != null) return false;
    return want <= bytes.len;
}

fn readF32(b: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, b[0..4], .little));
}

fn parseBinaryStl(gpa: Allocator, bytes: []const u8) Error!Mesh {
    const n = std.mem.readInt(u32, bytes[80..84], .little);
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.reserve(n);
    var off: usize = 84;
    for (0..n) |_| {
        // Skip the 12-byte normal. The vertex order gives the normal.
        const t = bytes[off + 12 ..];
        var v: [3]Vec3 = undefined;
        for (0..3) |k| {
            const o = k * 12;
            v[k] = .{ .x = readF32(t[o..]), .y = readF32(t[o + 4 ..]), .z = readF32(t[o + 8 ..]) };
        }
        try b.addTriangle(v[0], v[1], v[2]);
        off += 50;
    }
    return b.finish();
}

/// True for an OBJ text: no zero byte at the start, not "solid", and a
/// line "v ..." and a line "f ..." in the file.
fn isObj(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 512)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) return false;
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, bytes, " \t\r\n"), "solid")) return false;
    var v = false;
    var f = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "v ") or std.mem.startsWith(u8, line, "v\t")) v = true;
        if (std.mem.startsWith(u8, line, "f ") or std.mem.startsWith(u8, line, "f\t")) f = true;
        if (v and f) return true;
    }
    return false;
}

/// Reads an OBJ text (see the file comment).
fn parseObj(gpa: Allocator, bytes: []const u8) Error!Mesh {
    var verts: std.ArrayList(Vec3) = .empty;
    defer verts.deinit(gpa);
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    var face: std.ArrayList(u32) = .empty;
    defer face.deinit(gpa);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        const kind = it.next() orelse continue;
        if (std.mem.eql(u8, kind, "v")) {
            var c: [3]f32 = undefined;
            for (&c) |*x| {
                const s = it.next() orelse return error.InvalidStl;
                x.* = std.fmt.parseFloat(f32, s) catch return error.InvalidStl;
            }
            try verts.append(gpa, .{ .x = c[0], .y = c[1], .z = c[2] });
        } else if (std.mem.eql(u8, kind, "f")) {
            face.clearRetainingCapacity();
            while (it.next()) |tok| {
                // "i", "i/t", "i//n", or "i/t/n": the vertex is the first.
                const end = std.mem.indexOfScalar(u8, tok, '/') orelse tok.len;
                const n = std.fmt.parseInt(i64, tok[0..end], 10) catch return error.InvalidStl;
                const count: i64 = @intCast(verts.items.len);
                const idx = if (n > 0) n - 1 else if (n < 0) count + n else return error.InvalidStl;
                if (idx < 0 or idx >= count) return error.InvalidStl;
                try face.append(gpa, @intCast(idx));
            }
            if (face.items.len < 3) continue;
            const vs = verts.items;
            for (1..face.items.len - 1) |k| {
                try b.addTriangle(vs[face.items[0]], vs[face.items[k]], vs[face.items[k + 1]]);
            }
        }
    }
    return b.finish();
}

fn parseAsciiStl(gpa: Allocator, bytes: []const u8) Error!Mesh {
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, bytes, " \t\r\n"), "solid")) return error.InvalidStl;
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    var it = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    var v: [3]Vec3 = undefined;
    var k: usize = 0;
    while (it.next()) |tok| {
        if (!std.mem.eql(u8, tok, "vertex")) continue;
        var c: [3]f32 = undefined;
        for (&c) |*f| {
            const s = it.next() orelse return error.InvalidStl;
            f.* = std.fmt.parseFloat(f32, s) catch return error.InvalidStl;
        }
        v[k] = .{ .x = c[0], .y = c[1], .z = c[2] };
        k += 1;
        if (k == 3) {
            try b.addTriangle(v[0], v[1], v[2]);
            k = 0;
        }
    }
    return b.finish();
}

// ---------------------------------------------------------------------------
// Test shapes. The tests and the command line tool use them.

pub const shapes = struct {
    fn v(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = @floatCast(x), .y = @floatCast(y), .z = @floatCast(z) };
    }

    /// An axis-aligned box from (x0, y0, z0) to (x1, y1, z1).
    pub fn addBox(b: *Builder, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) !void {
        try b.addQuad(v(x0, y0, z0), v(x0, y1, z0), v(x1, y1, z0), v(x1, y0, z0)); // bottom
        try b.addQuad(v(x0, y0, z1), v(x1, y0, z1), v(x1, y1, z1), v(x0, y1, z1)); // top
        try b.addQuad(v(x0, y0, z0), v(x1, y0, z0), v(x1, y0, z1), v(x0, y0, z1)); // front
        try b.addQuad(v(x0, y1, z0), v(x0, y1, z1), v(x1, y1, z1), v(x1, y1, z0)); // back
        try b.addQuad(v(x0, y0, z0), v(x0, y0, z1), v(x0, y1, z1), v(x0, y1, z0)); // left
        try b.addQuad(v(x1, y0, z0), v(x1, y1, z0), v(x1, y1, z1), v(x1, y0, z1)); // right
    }

    /// A tube (a cylinder with a round hole) around (cx, cy).
    pub fn addTube(b: *Builder, cx: f64, cy: f64, r_out: f64, r_in: f64, z0: f64, z1: f64, segments: usize) !void {
        for (0..segments) |i| {
            const a0 = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segments));
            // The last segment ends at angle 0, and not at 2 pi. cos(2 pi) and
            // cos(0) can differ in the last bit, and then the seam does not weld.
            const a1 = 2 * std.math.pi * @as(f64, @floatFromInt((i + 1) % segments)) / @as(f64, @floatFromInt(segments));
            const o0x = cx + r_out * @cos(a0);
            const o0y = cy + r_out * @sin(a0);
            const o1x = cx + r_out * @cos(a1);
            const o1y = cy + r_out * @sin(a1);
            const in0x = cx + r_in * @cos(a0);
            const in0y = cy + r_in * @sin(a0);
            const in1x = cx + r_in * @cos(a1);
            const in1y = cy + r_in * @sin(a1);
            try b.addQuad(v(o0x, o0y, z0), v(o1x, o1y, z0), v(o1x, o1y, z1), v(o0x, o0y, z1)); // outer wall
            try b.addQuad(v(in1x, in1y, z0), v(in0x, in0y, z0), v(in0x, in0y, z1), v(in1x, in1y, z1)); // inner wall
            try b.addQuad(v(o0x, o0y, z1), v(o1x, o1y, z1), v(in1x, in1y, z1), v(in0x, in0y, z1)); // top
            try b.addQuad(v(o0x, o0y, z0), v(in0x, in0y, z0), v(in1x, in1y, z0), v(o1x, o1y, z0)); // bottom
        }
    }

    /// A wedge: a box of sx by sy whose top slopes along X, from z_lo at
    /// x = 0 up to z_hi at x = sx. The sides are vertical.
    pub fn wedge(gpa: Allocator, sx: f64, sy: f64, z_lo: f64, z_hi: f64) !Mesh {
        var b: Builder = .init(gpa);
        errdefer b.deinit();
        try b.addQuad(v(0, 0, 0), v(0, sy, 0), v(sx, sy, 0), v(sx, 0, 0)); // bottom
        try b.addQuad(v(0, 0, z_lo), v(sx, 0, z_hi), v(sx, sy, z_hi), v(0, sy, z_lo)); // top
        try b.addQuad(v(0, 0, 0), v(sx, 0, 0), v(sx, 0, z_hi), v(0, 0, z_lo)); // front
        try b.addQuad(v(0, sy, 0), v(0, sy, z_lo), v(sx, sy, z_hi), v(sx, sy, 0)); // back
        try b.addQuad(v(0, 0, 0), v(0, 0, z_lo), v(0, sy, z_lo), v(0, sy, 0)); // left
        try b.addQuad(v(sx, 0, 0), v(sx, sy, 0), v(sx, sy, z_hi), v(sx, 0, z_hi)); // right
        return b.finish();
    }

    /// A cone with a flat top (a frustum) around (cx, cy): radius r0 at
    /// z = 0 and r1 at z = height.
    pub fn frustum(gpa: Allocator, cx: f64, cy: f64, r0: f64, r1: f64, height: f64, segments: usize) !Mesh {
        var b: Builder = .init(gpa);
        errdefer b.deinit();
        const n: f64 = @floatFromInt(segments);
        for (0..segments) |i| {
            const a0 = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / n;
            const a1 = 2 * std.math.pi * @as(f64, @floatFromInt((i + 1) % segments)) / n;
            const p00 = v(cx + r0 * @cos(a0), cy + r0 * @sin(a0), 0);
            const p01 = v(cx + r0 * @cos(a1), cy + r0 * @sin(a1), 0);
            const p10 = v(cx + r1 * @cos(a0), cy + r1 * @sin(a0), height);
            const p11 = v(cx + r1 * @cos(a1), cy + r1 * @sin(a1), height);
            try b.addQuad(p00, p01, p11, p10); // side
            try b.addTriangle(v(cx, cy, height), p10, p11); // top
            try b.addTriangle(v(cx, cy, 0), p01, p00); // bottom
        }
        return b.finish();
    }

    pub fn box(gpa: Allocator, sx: f64, sy: f64, sz: f64) !Mesh {
        var b: Builder = .init(gpa);
        errdefer b.deinit();
        try addBox(&b, 0, 0, 0, sx, sy, sz);
        return b.finish();
    }

    /// A demonstration part: a wide box, a smaller box on top of it, and a
    /// tube. The tube starts at the bottom, inside the wide box, so the box
    /// fills the tube hole below 6 mm: the hole is a blind hole. The part
    /// has walls, a hole, two islands, top skin on a step and in the hole,
    /// and sparse infill.
    pub fn demo(gpa: Allocator) !Mesh {
        var b: Builder = .init(gpa);
        errdefer b.deinit();
        try addBox(&b, 0, 0, 0, 40, 30, 6);
        try addBox(&b, 5, 5, 6, 25, 25, 14);
        try addTube(&b, 32, 15, 5, 2.5, 0, 14, 64);
        return b.finish();
    }
};

const testing = std.testing;

test "a box has 8 vertices and 12 triangles" {
    var m = try shapes.box(testing.allocator, 10, 20, 30);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), m.vertices.items.len);
    try testing.expectEqual(@as(usize, 12), m.faces.items.len);
    const b = m.bounds();
    try testing.expectEqual(@as(f64, 30), b.max[2]);
}

test "binary STL round trip" {
    const gpa = testing.allocator;
    var m = try shapes.box(gpa, 10, 20, 30);
    defer m.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try m.writeStl(&out.writer);
    try testing.expectEqual(@as(usize, 84 + 12 * 50), out.written().len);
    var m2 = try Mesh.fromStl(gpa, out.written());
    defer m2.deinit(gpa);
    try testing.expectEqual(@as(usize, 8), m2.vertices.items.len);
    try testing.expectEqual(@as(usize, 12), m2.faces.items.len);
}

test "ASCII STL" {
    const gpa = testing.allocator;
    const src =
        \\solid t
        \\ facet normal 0 0 1
        \\  outer loop
        \\   vertex 0 0 0
        \\   vertex 1 0 0
        \\   vertex 0 1 0
        \\  endloop
        \\ endfacet
        \\endsolid t
    ;
    var m = try Mesh.fromStl(gpa, src);
    defer m.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), m.faces.items.len);
}

test "OBJ: vertices, faces from 1 and from the end, and a quad" {
    const gpa = std.testing.allocator;
    // A box of 10 mm: 8 vertices, 6 quads, with texture and normal
    // indices on some faces, and negative indices on one.
    const text =
        \\# a box
        \\o box
        \\v 0 0 0
        \\v 10 0 0
        \\v 10 10 0
        \\v 0 10 0
        \\v 0 0 10
        \\v 10 0 10
        \\v 10 10 10
        \\v 0 10 10
        \\vn 0 0 1
        \\f 1 4 3 2
        \\f 5/1 6/1 7/1 8/1
        \\f 1//1 2//1 6//1 5//1
        \\f 2 3 7 6
        \\f -5 -1 -2 -6
        \\f 4 1 5 8
        \\
    ;
    var m = try Mesh.fromStl(gpa, text);
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 8), m.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), m.faces.items.len);
    const bb = m.bounds();
    try std.testing.expectEqual(@as(f64, 10), bb.max[2]);
    // A face with an index past the end is an error.
    try std.testing.expectError(error.InvalidStl, Mesh.fromStl(gpa, "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 4\n"));
}

test "garbage is not an STL file" {
    try testing.expectError(error.InvalidStl, Mesh.fromStl(testing.allocator, "hello"));
}

test "bad coordinates are rejected" {
    // A regression test from the code review: NaN and huge values made the
    // slicer panic in the float to integer conversion.
    const gpa = testing.allocator;
    const bad = [_]f32{ std.math.nan(f32), std.math.inf(f32), 1e30 };
    for (bad) |x| {
        const tri = [_]f32{ 0, 0, 0, 1, 0, 0, x, 1, 0 };
        try testing.expectError(error.InvalidMesh, Mesh.fromTriangles(gpa, &tri));
    }
}

test "a binary STL with extra bytes at the end" {
    const gpa = testing.allocator;
    var m = try shapes.box(gpa, 10, 20, 30);
    defer m.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try m.writeStl(&out.writer);
    try out.writer.writeAll("\n\n");
    var m2 = try Mesh.fromStl(gpa, out.written());
    defer m2.deinit(gpa);
    try testing.expectEqual(@as(usize, 12), m2.faces.items.len);
}

test "mesh: the separate bodies of a mesh" {
    const gpa = std.testing.allocator;
    var b: Builder = .init(gpa);
    try shapes.addBox(&b, 0, 0, 0, 10, 10, 10);
    try shapes.addBox(&b, 20, 0, 0, 25, 5, 5);
    var m = try b.finish();
    defer m.deinit(gpa);
    const parts = try m.components(gpa);
    defer {
        for (parts) |*p| p.deinit(gpa);
        gpa.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(@as(usize, 12), parts[0].faces.items.len);
    try std.testing.expectEqual(@as(usize, 8), parts[0].vertices.items.len);
    const bb = parts[1].bounds();
    try std.testing.expectEqual(@as(f64, 20), bb.min[0]);
}
