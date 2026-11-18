//! The C API of the G-code reader, the `zs_gcode_*` functions of
//! `include/zslice-app.h`. See src/gcode_read.zig. The rules of the API
//! are in c_api.zig.

const std = @import("std");
const builtin = @import("builtin");
const zs = @import("../root.zig");
const c = @import("../c_api.zig");
const Status = c.Status;
const ok = c.ok;
const Reader = zs.gcode_read.Reader;

/// A reader and its state. The queries need a finished file.
pub const GCode = struct {
    r: Reader,
};

fn bad() c_int {
    return @intFromEnum(Status.invalid_argument);
}

fn finished(g: ?*const GCode) ?*const Reader {
    const h = g orelse return null;
    return if (h.r.finished) &h.r else null;
}

export fn zs_gcode_new(out: ?*?*GCode) c_int {
    const o = out orelse return bad();
    const g = c.gpa.create(GCode) catch return @intFromEnum(Status.out_of_memory);
    g.* = .{ .r = .init(c.gpa) };
    o.* = g;
    return ok;
}

export fn zs_gcode_free(g: ?*GCode) void {
    const h = g orelse return;
    h.r.deinit();
    c.gpa.destroy(h);
}

export fn zs_gcode_feed(g: ?*GCode, data: ?[*]const u8, len: usize) c_int {
    const h = g orelse return bad();
    if (h.r.finished) return bad();
    if (len == 0) return ok;
    const d = data orelse return bad();
    h.r.feed(d[0..len]) catch |e| return status(e);
    return ok;
}

export fn zs_gcode_finish(g: ?*GCode) c_int {
    const h = g orelse return bad();
    h.r.finish() catch |e| return status(e);
    return ok;
}

fn status(e: anyerror) c_int {
    return if (e == error.FileTooLarge) @intFromEnum(Status.out_of_range) else c.status(e);
}

/// Reads a file in pieces of 1 MB (native builds with libc only).
export fn zs_gcode_open(path: ?[*:0]const u8, out: ?*?*GCode) c_int {
    if (!builtin.link_libc or c.is_wasm) return @intFromEnum(Status.not_supported);
    const p = path orelse return bad();
    const o = out orelse return bad();
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return @intFromEnum(Status.no_result);
    defer _ = std.c.close(fd);
    var g: ?*GCode = null;
    if (zs_gcode_new(&g) != ok) return @intFromEnum(Status.out_of_memory);
    const piece = c.gpa.alloc(u8, 1 << 20) catch {
        zs_gcode_free(g);
        return @intFromEnum(Status.out_of_memory);
    };
    defer c.gpa.free(piece);
    while (true) {
        const n = std.c.read(fd, piece.ptr, piece.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            zs_gcode_free(g);
            return @intFromEnum(Status.no_result);
        }
        if (n == 0) break;
        const s = zs_gcode_feed(g, piece.ptr, @intCast(n));
        if (s != ok) {
            zs_gcode_free(g);
            return s;
        }
    }
    const s = zs_gcode_finish(g);
    if (s != ok) {
        zs_gcode_free(g);
        return s;
    }
    o.* = g;
    return ok;
}

pub const Info = extern struct {
    size: u64,
    moves: u64,
    beads: u64,
    layers: usize,
    time_s: f64,
    filament_mm: f64,
    box: [6]f64,
};

export fn zs_gcode_info(g: ?*const GCode, out: ?*Info) c_int {
    const r = finished(g) orelse return bad();
    const o = out orelse return bad();
    var box: [6]f64 = undefined;
    for (&box, r.box) |*d, s| d.* = if (std.math.isInf(s)) 0 else s;
    o.* = .{
        .size = r.size,
        .moves = r.len,
        .beads = r.bead_count,
        .layers = r.layers.items.len,
        .time_s = r.total_time,
        .filament_mm = r.filament,
        .box = box,
    };
    return ok;
}

pub const LayerInfo = extern struct {
    start: u64,
    end: u64,
    z: f64,
    height: f64,
    start_s: f64,
    end_s: f64,
};

export fn zs_gcode_layer(g: ?*const GCode, layer: usize, out: ?*LayerInfo) c_int {
    const r = finished(g) orelse return bad();
    const o = out orelse return bad();
    if (layer >= r.layers.items.len) return @intFromEnum(Status.out_of_range);
    const l = r.layers.items[layer];
    const range = r.layerRange(layer);
    const t = r.layerTimes(layer);
    o.* = .{ .start = range[0], .end = range[1], .z = l.z, .height = l.h, .start_s = t[0], .end_s = t[1] };
    return ok;
}

export fn zs_gcode_layer_at(g: ?*const GCode, offset: u64) usize {
    const r = finished(g) orelse return 0;
    return r.layerAt(offset);
}

pub const At = extern struct {
    layer: usize,
    move: u64,
    feature: c_int,
    travel: c_int,
    speed: f64,
    x: f64,
    y: f64,
    z: f64,
};

export fn zs_gcode_at(g: ?*const GCode, offset: u64, out: ?*At) c_int {
    const r = finished(g) orelse return bad();
    const o = out orelse return bad();
    const i = r.segmentAt(offset) orelse return @intFromEnum(Status.no_result);
    const s = r.at(i);
    const bead = r.beadAt(offset);
    o.* = .{
        .layer = r.layerAt(offset),
        .move = i,
        .feature = if (bead) |b| r.at(b).feature else -1,
        .travel = @intFromBool(s.feature == zs.gcode_read.travel),
        .speed = s.speed,
        .x = s.x,
        .y = s.y,
        .z = s.z,
    };
    return ok;
}

const testing = std.testing;

test "C API: read G-code in pieces and ask at an offset" {
    const text =
        \\M83
        \\;LAYER:0
        \\G1 Z0.2 F600
        \\G0 X10 Y10 F6000
        \\;TYPE:WALL-OUTER
        \\G1 X20 Y10 E0.5 F1200
        \\;LAYER:1
        \\G1 Z0.4
        \\;TYPE:FILL
        \\G1 X20 Y20 E0.5 F3000
        \\
    ;
    var g: ?*GCode = null;
    try testing.expectEqual(ok, zs_gcode_new(&g));
    defer zs_gcode_free(g);
    try testing.expectEqual(ok, zs_gcode_feed(g, text.ptr, 30));
    // No query before the end.
    var info: Info = undefined;
    try testing.expect(zs_gcode_info(g, &info) != ok);
    try testing.expectEqual(ok, zs_gcode_feed(g, text.ptr + 30, text.len - 30));
    try testing.expectEqual(ok, zs_gcode_finish(g));
    try testing.expectEqual(ok, zs_gcode_info(g, &info));
    try testing.expectEqual(@as(usize, 2), info.layers);
    try testing.expectEqual(@as(u64, 2), info.beads);
    var l: LayerInfo = undefined;
    try testing.expectEqual(ok, zs_gcode_layer(g, 1, &l));
    try testing.expectEqual(@as(u64, std.mem.indexOf(u8, text, ";LAYER:1").?), l.start);
    try testing.expectEqual(@as(u64, text.len), l.end);
    try testing.expectApproxEqAbs(@as(f64, 0.4), l.z, 1e-6);
    // An offset counts the bytes read: at l.start the printer has not
    // read a byte of layer 1.
    try testing.expectEqual(@as(usize, 0), zs_gcode_layer_at(g, l.start));
    try testing.expectEqual(@as(usize, 1), zs_gcode_layer_at(g, l.start + 1));
    var at: At = undefined;
    try testing.expectEqual(@intFromEnum(Status.no_result), zs_gcode_at(g, 0, &at));
    try testing.expectEqual(ok, zs_gcode_at(g, text.len, &at));
    try testing.expectEqual(@as(c_int, 3), at.feature);
    try testing.expectApproxEqAbs(@as(f64, 50), at.speed, 1e-3);
    try testing.expectEqual(ok, zs_gcode_at(g, l.start, &at));
    try testing.expectEqual(@as(c_int, 0), at.feature);
    try testing.expectEqual(@as(usize, 0), at.layer);
}
