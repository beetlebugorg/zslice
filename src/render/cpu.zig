//! A small software renderer of meshes, for the pictures that a G-code file
//! carries (the thumbnails that the screens of Prusa, Klipper, and Bambu
//! Lab printers show), with no GPU.
//!
//! The view looks at the parts from the front, to the right and above (an
//! iso view), and fits their bounds into the image. Each triangle fills its
//! pixels with a depth test, in a color from its slope to a light: the
//! parts show their shape, on a clear background (alpha 0). `png` writes
//! the image as a PNG file (RFC 2083: IHDR, IDAT with zlib, IEND).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("../mesh.zig");
const Mesh = mesh_mod.Mesh;

pub const Image = struct {
    w: u32,
    h: u32,
    /// RGBA, row by row from the top.
    px: []u8,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.px);
    }
};

const V3 = [3]f32;

fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: V3, b: V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn norm(a: V3) V3 {
    const l = @sqrt(dot(a, a));
    return if (l > 0) .{ a[0] / l, a[1] / l, a[2] / l } else a;
}

/// Renders the meshes in an image of w by h pixels. `color`: the RGB of
/// the parts (the filament color).
pub fn render(gpa: Allocator, meshes: []const Mesh, w: u32, h: u32, color: [3]u8) Allocator.Error!Image {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    @memset(px, 0);
    errdefer gpa.free(px);
    const depth = try gpa.alloc(f32, @as(usize, w) * h);
    defer gpa.free(depth);
    @memset(depth, std.math.inf(f32));
    // The view: from the front right, above (yaw 35 degrees, pitch 30).
    const yaw: f32 = std.math.degreesToRadians(-35.0);
    const pitch: f32 = std.math.degreesToRadians(30.0);
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    const Proj = struct {
        cy: f32,
        sy: f32,
        cp: f32,
        sp: f32,
        /// Screen x, screen y (up), and depth (away from the eye).
        fn of(p: @This(), v: V3) V3 {
            const x = v[0] * p.cy - v[1] * p.sy;
            const y = v[0] * p.sy + v[1] * p.cy;
            return .{ x, v[2] * p.cp + y * p.sp, y * p.cp - v[2] * p.sp };
        }
    };
    const proj: Proj = .{ .cy = cy, .sy = sy, .cp = cp, .sp = sp };
    // The bounds on the screen, to fit the image with a margin.
    var lo = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
    var hi = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
    for (meshes) |m| for (m.vertices.items) |v| {
        const q = proj.of(.{ v.x, v.y, v.z });
        lo = .{ @min(lo[0], q[0]), @min(lo[1], q[1]) };
        hi = .{ @max(hi[0], q[0]), @max(hi[1], q[1]) };
    };
    if (!(hi[0] > lo[0]) or !(hi[1] > lo[1])) return .{ .w = w, .h = h, .px = px };
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const scale = @min(fw * 0.9 / (hi[0] - lo[0]), fh * 0.9 / (hi[1] - lo[1]));
    const ox = (fw - (hi[0] - lo[0]) * scale) / 2;
    const oy = (fh - (hi[1] - lo[1]) * scale) / 2;
    const light = norm(.{ 0.4, -0.5, 0.8 });
    const eye_dir = norm(.{ -sy * cp, -cy * cp, sp });
    for (meshes) |m| for (m.faces.items) |f| {
        const a = m.vertices.items[f[0]];
        const b = m.vertices.items[f[1]];
        const c = m.vertices.items[f[2]];
        const wa = V3{ a.x, a.y, a.z };
        const wb = V3{ b.x, b.y, b.z };
        const wc = V3{ c.x, c.y, c.z };
        var n = norm(cross(sub(wb, wa), sub(wc, wa)));
        // Two sided: a face away from the eye shows its back.
        if (dot(n, eye_dir) < 0) n = .{ -n[0], -n[1], -n[2] };
        const shade = 0.35 + 0.65 * @max(0, dot(n, light));
        const rgb = [3]u8{
            @intFromFloat(@min(255, @as(f32, @floatFromInt(color[0])) * shade + 20)),
            @intFromFloat(@min(255, @as(f32, @floatFromInt(color[1])) * shade + 20)),
            @intFromFloat(@min(255, @as(f32, @floatFromInt(color[2])) * shade + 20)),
        };
        var s: [3]V3 = undefined;
        for ([3]V3{ wa, wb, wc }, 0..) |v, k| {
            const q = proj.of(v);
            s[k] = .{ ox + (q[0] - lo[0]) * scale, fh - (oy + (q[1] - lo[1]) * scale), q[2] };
        }
        fillTri(px, depth, w, h, s, rgb);
    };
    return .{ .w = w, .h = h, .px = px };
}

fn fillTri(px: []u8, depth: []f32, w: u32, h: u32, s: [3]V3, rgb: [3]u8) void {
    const minx: i32 = @intFromFloat(@max(0, @floor(@min(s[0][0], @min(s[1][0], s[2][0])))));
    const maxx: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(w - 1)), @ceil(@max(s[0][0], @max(s[1][0], s[2][0])))));
    const miny: i32 = @intFromFloat(@max(0, @floor(@min(s[0][1], @min(s[1][1], s[2][1])))));
    const maxy: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(h - 1)), @ceil(@max(s[0][1], @max(s[1][1], s[2][1])))));
    if (minx > maxx or miny > maxy) return;
    const area = (s[1][0] - s[0][0]) * (s[2][1] - s[0][1]) - (s[1][1] - s[0][1]) * (s[2][0] - s[0][0]);
    if (@abs(area) < 1e-9) return;
    var y = miny;
    while (y <= maxy) : (y += 1) {
        var x = minx;
        while (x <= maxx) : (x += 1) {
            const p = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
            const w0 = ((s[1][0] - p[0]) * (s[2][1] - p[1]) - (s[1][1] - p[1]) * (s[2][0] - p[0])) / area;
            const w1 = ((s[2][0] - p[0]) * (s[0][1] - p[1]) - (s[2][1] - p[1]) * (s[0][0] - p[0])) / area;
            const w2 = 1 - w0 - w1;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;
            const z = w0 * s[0][2] + w1 * s[1][2] + w2 * s[2][2];
            const k = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            if (z >= depth[k]) continue;
            depth[k] = z;
            px[k * 4] = rgb[0];
            px[k * 4 + 1] = rgb[1];
            px[k * 4 + 2] = rgb[2];
            px[k * 4 + 3] = 255;
        }
    }
}

/// The image as a PNG file, in gpa.
pub fn png(gpa: Allocator, img: Image) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    // The rows with a filter byte (0: none), for the zlib stream.
    const row = @as(usize, img.w) * 4;
    const raw = try gpa.alloc(u8, (row + 1) * img.h);
    defer gpa.free(raw);
    for (0..img.h) |y| {
        raw[y * (row + 1)] = 0;
        @memcpy(raw[y * (row + 1) + 1 ..][0..row], img.px[y * row ..][0..row]);
    }
    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, raw.len / 4));
    defer z.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .level_6);
    try c.writer.writeAll(raw);
    try c.finish();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.h, .big);
    ihdr[8] = 8; // bits
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", z.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) std.Io.Writer.Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try w.writeAll(&len);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try w.writeAll(&c);
}

/// The thumbnail block of a G-code file (the PrusaSlicer and Klipper
/// form): "; thumbnail begin WxH LEN", the PNG in base64 in lines of 78,
/// "; thumbnail end".
pub fn gcodeThumbnail(gpa: Allocator, png_bytes: []const u8, w: u32, h: u32, out: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(png_bytes.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, png_bytes);
    try out.print(";\n; thumbnail begin {d}x{d} {d}\n", .{ w, h, b64.len });
    var i: usize = 0;
    while (i < b64.len) : (i += 78) try out.print("; {s}\n", .{b64[i..@min(b64.len, i + 78)]});
    try out.writeAll("; thumbnail end\n;\n");
}

const testing = std.testing;

test "cpu render: a box fills the middle, and the PNG has its chunks" {
    const gpa = testing.allocator;
    var b: mesh_mod.Builder = .init(gpa);
    try mesh_mod.shapes.addBox(&b, 0, 0, 0, 20, 20, 20);
    var m = try b.finish();
    defer m.deinit(gpa);
    var img = try render(gpa, &.{m}, 64, 48, .{ 200, 120, 40 });
    defer img.deinit(gpa);
    // The center is the part, a corner is clear.
    const mid = (24 * 64 + 32) * 4;
    try testing.expectEqual(@as(u8, 255), img.px[mid + 3]);
    try testing.expectEqual(@as(u8, 0), img.px[3]);
    const bytes = try png(gpa, img);
    defer gpa.free(bytes);
    try testing.expectEqualStrings("\x89PNG", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "IDAT") != null);
    try testing.expect(std.mem.endsWith(u8, bytes[0 .. bytes.len - 4], "IEND"));
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try gcodeThumbnail(gpa, bytes, 64, 48, &aw.writer);
    try testing.expect(std.mem.startsWith(u8, aw.written(), ";\n; thumbnail begin 64x48 "));
}
