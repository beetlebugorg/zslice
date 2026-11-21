//! The bed model of a printer: a static mesh under the plate, with a
//! texture, for the 3D view.
//!
//! The files come from the printer definitions of Cura, PrusaSlicer, and
//! OrcaSlicer (tools/printer_beds.py converts them). The core does no file
//! I/O: a shell reads the files and gives their bytes to `build`.
//!
//! The mesh file (".mesh"), little-endian:
//!
//!     offset  size  field
//!     0       4     "ZSBM"
//!     4       2     version (1)
//!     6       2     flags: 1 = UV coordinates, 2 = 32-bit indices
//!     8       4     vertex count n
//!     12      4     triangle count t
//!     16      4     scale (f32, mm for one unit)
//!     20      12    center (3 f32, mm)
//!     32      6n    positions: 3 i16 each; position = center + q * scale
//!                   (2 bytes of padding if n is odd)
//!     ..      4n    with flag 1: UV, 2 i16 each, in 1/8192; v counts from
//!                   the top row of the image down
//!     ..      6t    the corners of each triangle: 3 u16 (or 3 u32 with
//!                   flag 2)
//!
//! The mesh is in printer axes (x right, y to the back, z up, in mm). Its
//! origin goes to the center of the bed, moved by the offset of the library
//! record (each source has its own rule; the tool turns them into this
//! one).
//!
//! The texture is a PNG image. The reader here takes the forms that the
//! tool writes and the common simple ones: 8 bits for each sample, no
//! interlace, and gray, gray with alpha, RGB, RGBA, or a palette (with
//! tRNS for alpha). Two ways put the texture on the bed:
//!
//! - With a rectangle in the record (PrusaSlicer and OrcaSlicer), a flat
//!   surface at z = 0 covers the rectangle (a disc for a round bed), and
//!   the image spans the box of the rectangle: the top row of the image at
//!   the back of the bed.
//! - Without one (Cura), the mesh has UV coordinates for the image.
//!
//! `build` gives triangles with one vertex for each corner (smooth normals,
//! with sharp edges kept),
//! from the center of the bed. The view adds half of the bed size when it
//! draws them, so a change of the bed size does not need a new build.
//!
//! References (see docs/references/): the PNG specification (W3C, third
//! edition), and the bed placement code of Cura, PrusaSlicer, and
//! OrcaSlicer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Error = error{ InvalidMesh, InvalidImage, OutOfMemory };

/// One corner of a triangle. `uv` is (-1, -1) for a corner with no texture.
pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 32);
}

/// The placement of a bed from the library record.
pub const Place = struct {
    /// The offset of the mesh origin from the center of the bed (mm).
    offset: [3]f64 = .{ 0, 0, 0 },
    /// The box of the texture surface, from the center of the bed (x0, y0,
    /// x1, y1), or null: the mesh has UV coordinates.
    rect: ?[4]f64 = null,
    /// A round bed: the texture surface is a disc in the box.
    round: bool = false,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// width * height * 4 bytes, the top row first.
    rgba: []u8,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.rgba);
        img.* = undefined;
    }
};

pub const Geometry = struct {
    vertices: []Vertex,
    /// The texture, or null.
    image: ?Image,

    pub fn deinit(g: *Geometry, gpa: Allocator) void {
        gpa.free(g.vertices);
        if (g.image) |*img| img.deinit(gpa);
        g.* = undefined;
    }
};

/// Builds the triangles of a bed. `mesh` and `texture` are the bytes of the
/// files (empty: none). A texture that does not read is left out; a mesh
/// that does not read is an error.
pub fn build(gpa: Allocator, mesh: []const u8, texture: []const u8, place: Place) Error!Geometry {
    var out: std.ArrayList(Vertex) = .empty;
    errdefer out.deinit(gpa);
    var image: ?Image = if (texture.len > 0) decodePng(gpa, texture) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    } else null;
    errdefer if (image) |*img| img.deinit(gpa);

    if (mesh.len > 0) try appendMesh(gpa, &out, mesh, place.offset, image != null and place.rect == null);
    if (image != null) {
        if (place.rect) |r| try appendSurface(gpa, &out, r, place.round);
    }
    // A Cura texture needs the UV coordinates of the mesh.
    if (image != null and place.rect == null and !hasUv(out.items)) {
        image.?.deinit(gpa);
        image = null;
    }
    return .{ .vertices = try out.toOwnedSlice(gpa), .image = image };
}

fn hasUv(vs: []const Vertex) bool {
    for (vs) |v| if (v.uv[0] >= -0.5) return true;
    return false;
}

fn readInt(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn readF32(b: []const u8, at: usize) f32 {
    return @bitCast(readInt(u32, b, at));
}

/// The triangles of a .mesh file, moved by `offset`.
fn appendMesh(gpa: Allocator, out: *std.ArrayList(Vertex), b: []const u8, offset: [3]f64, use_uv: bool) Error!void {
    if (b.len < 32 or !std.mem.eql(u8, b[0..4], "ZSBM")) return error.InvalidMesh;
    if (readInt(u16, b, 4) != 1) return error.InvalidMesh;
    const flags = readInt(u16, b, 6);
    const n: usize = readInt(u32, b, 8);
    const t: usize = readInt(u32, b, 12);
    const scale = readF32(b, 16);
    const center = [3]f32{ readF32(b, 20), readF32(b, 24), readF32(b, 28) };
    if (n == 0 or n > 1 << 24 or t > 1 << 24 or !std.math.isFinite(scale)) return error.InvalidMesh;
    const pos_at: usize = 32;
    const uv_at = pos_at + 6 * n + (if (n % 2 == 1) @as(usize, 2) else 0);
    const has_uv = flags & 1 != 0;
    const idx_at = uv_at + (if (has_uv) 4 * n else 0);
    const wide = flags & 2 != 0;
    const idx_size: usize = if (wide) 4 else 2;
    if (idx_at + 3 * t * idx_size > b.len) return error.InvalidMesh;

    const off = [3]f32{ @floatCast(offset[0]), @floatCast(offset[1]), @floatCast(offset[2]) };
    const index = struct {
        fn at(bytes: []const u8, base: usize, w: bool, k: usize) usize {
            return if (w) readInt(u32, bytes, base + 4 * k) else readInt(u16, bytes, base + 2 * k);
        }
    }.at;
    const posOf = struct {
        fn at(bytes: []const u8, base: usize, i: usize, c: [3]f32, sc: f32, o: [3]f32) [3]f32 {
            var p: [3]f32 = undefined;
            for (0..3) |a| {
                const q: f32 = @floatFromInt(readInt(i16, bytes, base + 6 * i + 2 * a));
                p[a] = c[a] + q * sc + o[a];
            }
            return p;
        }
    }.at;
    // Smooth normals: the sum of the normals of the faces at each vertex
    // (weighted by their area), so the light does not show each triangle
    // of a curved surface. A face that turns more than the crease angle
    // from that sum keeps its own normal, so a sharp edge stays sharp.
    // The vertices with the same place share one sum: a mesh from an STL
    // file has its own vertices for each triangle. The places are 16-bit
    // integers in the file, so the same place is the same key.
    const keyOf = struct {
        fn at(bytes: []const u8, base: usize, i: usize) u64 {
            var k: u64 = 0;
            for (0..3) |a| k = (k << 16) | @as(u16, @bitCast(readInt(i16, bytes, base + 6 * i + 2 * a)));
            return k;
        }
    }.at;
    var slots: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer slots.deinit(gpa);
    const slot_of = try gpa.alloc(u32, n);
    defer gpa.free(slot_of);
    for (0..n) |i| {
        const g = try slots.getOrPut(gpa, keyOf(b, pos_at, i));
        if (!g.found_existing) g.value_ptr.* = slots.count() - 1;
        slot_of[i] = g.value_ptr.*;
    }
    // The faces at each place (a list for each slot), with the normal of
    // each face times its area, and its unit normal.
    const nslots = slots.count();
    const area_n = try gpa.alloc([3]f32, t);
    defer gpa.free(area_n);
    const unit_n = try gpa.alloc([3]f32, t);
    defer gpa.free(unit_n);
    const first = try gpa.alloc(u32, nslots + 1);
    defer gpa.free(first);
    @memset(first, 0);
    for (0..t) |k| {
        var p: [3][3]f32 = undefined;
        for (0..3) |j| {
            const i = index(b, idx_at, wide, 3 * k + j);
            if (i >= n) return error.InvalidMesh;
            p[j] = posOf(b, pos_at, i, center, scale, off);
            first[slot_of[i] + 1] += 1;
        }
        area_n[k] = faceArea(p[0], p[1], p[2]);
        unit_n[k] = unit(area_n[k]) orelse .{ 0, 0, 1 };
    }
    for (1..nslots + 1) |q| first[q] += first[q - 1];
    const faces_at = try gpa.alloc(u32, 3 * t);
    defer gpa.free(faces_at);
    const fill = try gpa.alloc(u32, nslots);
    defer gpa.free(fill);
    @memset(fill, 0);
    for (0..t) |k| for (0..3) |j| {
        const sl = slot_of[index(b, idx_at, wide, 3 * k + j)];
        faces_at[first[sl] + fill[sl]] = @intCast(k);
        fill[sl] += 1;
    };
    // The normal of a corner: the sum of the faces at its place that turn
    // less than the crease angle from its own face. A flat face then has
    // the same normal at its three corners (no triangles show on it), a
    // curved surface of small faces is smooth, and an edge stays sharp.
    const crease = @cos(std.math.degreesToRadians(25.0));
    try out.ensureUnusedCapacity(gpa, 3 * t);
    for (0..t) |k| {
        var corner: [3]Vertex = undefined;
        for (0..3) |j| {
            const i = index(b, idx_at, wide, 3 * k + j);
            var uv: [2]f32 = .{ -1, -1 };
            if (has_uv and use_uv) {
                uv = .{
                    @as(f32, @floatFromInt(readInt(i16, b, uv_at + 4 * i))) / 8192.0,
                    @as(f32, @floatFromInt(readInt(i16, b, uv_at + 4 * i + 2))) / 8192.0,
                };
            }
            const fk = unit_n[k];
            var sum = [3]f32{ 0, 0, 0 };
            const sl = slot_of[i];
            for (faces_at[first[sl]..first[sl + 1]]) |f| {
                const nf = unit_n[f];
                if (nf[0] * fk[0] + nf[1] * fk[1] + nf[2] * fk[2] < crease) continue;
                for (0..3) |a| sum[a] += area_n[f][a];
            }
            corner[j] = .{ .pos = posOf(b, pos_at, i, center, scale, off), .normal = unit(sum) orelse fk, .uv = uv };
        }
        out.appendSliceAssumeCapacity(&corner);
    }
}

/// The normal of a triangle times twice its area (not a unit vector).
fn faceArea(a: [3]f32, b: [3]f32, c: [3]f32) [3]f32 {
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    return .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
}

fn unit(v: [3]f32) ?[3]f32 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (!(l > 0)) return null;
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

fn faceNormal(a: [3]f32, b: [3]f32, c: [3]f32) [3]f32 {
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const n = [3]f32{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
    const l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    if (l == 0) return .{ 0, 0, 1 };
    return .{ n[0] / l, n[1] / l, n[2] / l };
}

/// The flat texture surface at z = 0: the rectangle, or a disc in it.
fn appendSurface(gpa: Allocator, out: *std.ArrayList(Vertex), r: [4]f64, round: bool) Error!void {
    const x0: f32 = @floatCast(r[0]);
    const y0: f32 = @floatCast(r[1]);
    const x1: f32 = @floatCast(r[2]);
    const y1: f32 = @floatCast(r[3]);
    if (!(x1 > x0 and y1 > y0)) return;
    const S = struct {
        fn at(xa: f32, ya: f32, xb: f32, yb: f32, x: f32, y: f32) Vertex {
            return .{ .pos = .{ x, y, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ (x - xa) / (xb - xa), (yb - y) / (yb - ya) } };
        }
    };
    if (!round) {
        try out.appendSlice(gpa, &.{
            S.at(x0, y0, x1, y1, x0, y0), S.at(x0, y0, x1, y1, x1, y0), S.at(x0, y0, x1, y1, x1, y1),
            S.at(x0, y0, x1, y1, x0, y0), S.at(x0, y0, x1, y1, x1, y1), S.at(x0, y0, x1, y1, x0, y1),
        });
        return;
    }
    const cx = (x0 + x1) / 2;
    const cy = (y0 + y1) / 2;
    const rx = (x1 - x0) / 2;
    const ry = (y1 - y0) / 2;
    const steps = 96;
    for (0..steps) |k| {
        const a0 = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / steps;
        const a1 = 2 * std.math.pi * @as(f32, @floatFromInt(k + 1)) / steps;
        try out.appendSlice(gpa, &.{
            S.at(x0, y0, x1, y1, cx, cy),
            S.at(x0, y0, x1, y1, cx + rx * @cos(a0), cy + ry * @sin(a0)),
            S.at(x0, y0, x1, y1, cx + rx * @cos(a1), cy + ry * @sin(a1)),
        });
    }
}

// ---- PNG ----

/// The largest image side that the reader takes.
const max_side = 4096;

/// Reads a PNG image into RGBA (see the file comment for the forms).
pub fn decodePng(gpa: Allocator, b: []const u8) Error!Image {
    const sig = "\x89PNG\r\n\x1a\n";
    if (b.len < 8 or !std.mem.eql(u8, b[0..8], sig)) return error.InvalidImage;
    var width: u32 = 0;
    var height: u32 = 0;
    var ctype: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var zdata: std.ArrayList(u8) = .empty;
    defer zdata.deinit(gpa);
    var at: usize = 8;
    var have_header = false;
    while (at + 12 <= b.len) {
        const len: usize = std.mem.readInt(u32, b[at..][0..4], .big);
        const kind = b[at + 4 .. at + 8];
        const body_at = at + 8;
        if (len > b.len or body_at + len + 4 > b.len) return error.InvalidImage;
        const body = b[body_at .. body_at + len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.InvalidImage;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            const depth = body[8];
            ctype = body[9];
            const interlace = body[12];
            if (depth != 8 or interlace != 0) return error.InvalidImage;
            if (ctype != 0 and ctype != 2 and ctype != 3 and ctype != 4 and ctype != 6) return error.InvalidImage;
            if (width == 0 or height == 0 or width > max_side or height > max_side) return error.InvalidImage;
            have_header = true;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            var k: usize = 0;
            while (k < 256 and 3 * k + 2 < len) : (k += 1) palette[k] = .{ body[3 * k], body[3 * k + 1], body[3 * k + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (ctype == 3) {
                for (body, 0..) |a, k| if (k < 256) {
                    palette[k][3] = a;
                };
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try zdata.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        at = body_at + len + 4;
    }
    if (!have_header) return error.InvalidImage;
    const channels: usize = switch (ctype) {
        0, 3 => 1,
        4 => 2,
        2 => 3,
        else => 4,
    };
    const stride = width * channels;
    const raw_len = (stride + 1) * height;

    var in: std.Io.Reader = .fixed(zdata.items);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var d: flate.Decompress = .init(&in, .zlib, window);
    const raw = d.reader.allocRemaining(gpa, .limited(raw_len + 1)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidImage,
    };
    defer gpa.free(raw);
    if (raw.len < raw_len) return error.InvalidImage;

    // Undo the filters of each row, in place.
    var prev: ?[]const u8 = null;
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const filter = raw[y * (stride + 1)];
        for (0..stride) |i| {
            const a: u8 = if (i >= channels) row[i - channels] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const ul: u8 = if (prev != null and i >= channels) prev.?[i - channels] else 0;
            row[i] = switch (filter) {
                0 => row[i],
                1 => row[i] +% a,
                2 => row[i] +% up,
                3 => row[i] +% @as(u8, @intCast((@as(u16, a) + up) / 2)),
                4 => row[i] +% paeth(a, up, ul),
                else => return error.InvalidImage,
            };
        }
        prev = row;
    }

    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(rgba);
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..width) |x| {
            const o = rgba[(y * width + x) * 4 ..][0..4];
            const s = row[x * channels ..];
            o.* = switch (ctype) {
                0 => .{ s[0], s[0], s[0], 255 },
                4 => .{ s[0], s[0], s[0], s[1] },
                2 => .{ s[0], s[1], s[2], 255 },
                3 => palette[s[0]],
                else => .{ s[0], s[1], s[2], s[3] },
            };
        }
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ---- tests ----

const testing = std.testing;

test "decodePng reads a palette image with alpha" {
    // A 2x1 image: a palette of red (opaque) and blue (alpha 0x80), rows
    // with filter 0. The zlib stream is a stored block.
    const raw = [_]u8{ 0, 0, 1 };
    var z: [64]u8 = undefined;
    var zl: usize = 0;
    z[0] = 0x78;
    z[1] = 0x01;
    z[2] = 1; // final stored block
    z[3] = raw.len;
    z[4] = 0;
    z[5] = ~@as(u8, raw.len);
    z[6] = 0xff;
    @memcpy(z[7..][0..raw.len], &raw);
    zl = 7 + raw.len;
    const adler = std.hash.Adler32.hash(&raw);
    std.mem.writeInt(u32, z[zl..][0..4], adler, .big);
    zl += 4;

    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(testing.allocator);
    try png.appendSlice(testing.allocator, "\x89PNG\r\n\x1a\n");
    const chunk = struct {
        fn add(list: *std.ArrayList(u8), kind: []const u8, body: []const u8) !void {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(body.len), .big);
            try list.appendSlice(testing.allocator, &len);
            try list.appendSlice(testing.allocator, kind);
            try list.appendSlice(testing.allocator, body);
            try list.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 }); // the reader does not check the CRC
        }
    };
    try chunk.add(&png, "IHDR", &.{ 0, 0, 0, 2, 0, 0, 0, 1, 8, 3, 0, 0, 0 });
    try chunk.add(&png, "PLTE", &.{ 255, 0, 0, 0, 0, 255 });
    try chunk.add(&png, "tRNS", &.{ 255, 0x80 });
    try chunk.add(&png, "IDAT", z[0..zl]);
    try chunk.add(&png, "IEND", "");

    var img = try decodePng(testing.allocator, png.items);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 0x80 }, img.rgba);
}

test "build places a mesh and a texture surface" {
    // One triangle: (0,0,0), (10,0,0), (0,10,0) with scale 1 and center 0.
    var m: std.ArrayList(u8) = .empty;
    defer m.deinit(testing.allocator);
    const w = struct {
        fn int(list: *std.ArrayList(u8), comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            try list.appendSlice(testing.allocator, &b);
        }
    };
    try m.appendSlice(testing.allocator, "ZSBM");
    try w.int(&m, u16, 1);
    try w.int(&m, u16, 0);
    try w.int(&m, u32, 3);
    try w.int(&m, u32, 1);
    for ([_]f32{ 1, 0, 0, 0 }) |f| try w.int(&m, u32, @bitCast(f));
    for ([_]i16{ 0, 0, 0, 10, 0, 0, 0, 10, 0 }) |q| try w.int(&m, i16, q);
    try w.int(&m, u16, 0); // padding: 3 vertices
    for ([_]u16{ 0, 1, 2 }) |i| try w.int(&m, u16, i);

    var g = try build(testing.allocator, m.items, "", .{ .offset = .{ 1, 2, -0.5 } });
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), g.vertices.len);
    try testing.expectEqual(@as(f32, 11), g.vertices[1].pos[0]);
    try testing.expectEqual(@as(f32, 2), g.vertices[1].pos[1]);
    try testing.expectEqual(@as(f32, -0.5), g.vertices[1].pos[2]);
    try testing.expectEqual(@as(f32, 1), g.vertices[0].normal[2]);
    try testing.expectEqual(@as(f32, -1), g.vertices[0].uv[0]);
    try testing.expect(g.image == null);

    try testing.expectError(error.InvalidMesh, build(testing.allocator, "ZSBM", "", .{}));
}
