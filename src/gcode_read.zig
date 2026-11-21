//! A reader of G-code files, for a view of a print that runs.
//!
//! A printer host (printdeck with Klipper) knows how far a print is by the
//! byte offset in the file. This reader turns a G-code file into packed
//! segments, each with the byte offset of the end of its line, so the
//! host can find the layer, the feature, and the speed at an offset, and a
//! view can draw the print up to that offset.
//!
//! The steps, for each line:
//!
//! 1. A move (G0, G1, and the arcs G2 and G3 in short chords) gives a
//!    segment from the last position to the new one. A move with more
//!    plastic (E) is a bead. A move with no plastic is a travel. The
//!    travels stay in the list, because the start of each segment is the
//!    end of the segment before it.
//! 2. The modes change how the numbers read: G90 and G91 (absolute or
//!    relative positions), M82 and M83 (absolute or relative E, as
//!    Klipper reads them), and G92 (set a position).
//! 3. A comment can start a layer (";LAYER:" of zslice and Cura,
//!    ";LAYER_CHANGE" of PrusaSlicer and OrcaSlicer, "; CHANGE_LAYER" of
//!    Bambu Studio), give its z and height (";Z:", ";HEIGHT:"), or set the
//!    feature (";TYPE:" or "; FEATURE:"). A file with no layer comments
//!    gets a new layer at each rise of z with plastic.
//! 4. The width of a bead comes from its plastic: the volume of filament
//!    over the length of the move is the cross section of the bead, and
//!    the layer height gives the width (flow.beadWidth, the same bead
//!    shape as the view of a slice). The filament diameter comes from a
//!    comment of the slicer. With no such comment, the reader tries 1.75
//!    and 2.85 mm and keeps the one that gives widths near the nozzle.
//! 5. The time of each layer comes from the comments (";TIME_ELAPSED:" of
//!    Cura), or from a quick estimate: the time of each move is its
//!    length over its speed, with the time to speed up and slow down. A
//!    total time in a comment of the slicer scales the estimate.
//! 6. The comments of the slicer at the start and at the end of the file
//!    (its name, the filament, and its settings) go to gcode_meta.zig.
//!
//! The reader gets the file in pieces of any size (`feed`), so a host
//! can stream a large file and never hold all of it. The segments are 24
//! bytes each, in blocks of 4096, so the list never moves in memory.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const flow = @import("flow.zig");
const gcode_meta = @import("gcode_meta.zig");
pub const Feature = @import("settings.zig").Feature;

/// The feature code of a travel (a move with no plastic).
pub const travel: u8 = 255;

/// One move of the file.
pub const Segment = extern struct {
    /// The end point (mm). The start is the end of the segment before.
    x: f32,
    y: f32,
    z: f32,
    /// The byte offset of the end of the line of the move, after its
    /// newline. Klipper reports this number when it has read the line.
    offset: u32,
    /// The bead width and height (mm). Both are 0 for a travel.
    w: f16,
    h: f16,
    /// The speed (mm/s).
    speed: f16,
    /// A Feature value, or `travel`.
    feature: u8,
    flags: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Segment) == 24);
}

pub const Layer = struct {
    /// The first segment of the layer.
    first: u32,
    /// The byte offset of the start of the layer: the start of its layer
    /// comment, or of the move that rose to its z.
    offset: u32,
    /// The z of the layer top, and the layer height (mm).
    z: f32 = 0,
    h: f32 = 0,
    /// The print time at the end of the layer (s from the start).
    time: f32 = 0,
    /// The time from a ";TIME_ELAPSED:" comment, or -1.
    elapsed: f32 = -1,
    z_known: bool = false,
    h_known: bool = false,
};

const empty_box = [6]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };

pub const block_len = 4096;
const Block = [block_len]Segment;

/// The longest line that the reader keeps across two calls of `feed`.
/// The rest of a longer line is lost (a line of G-code is short; only a
/// comment can be this long).
const max_line = 64 * 1024;

pub const Error = Allocator.Error || error{FileTooLarge};

pub const Reader = struct {
    gpa: Allocator,
    blocks: std.ArrayList(*Block) = .empty,
    /// The beads (moves with plastic) before each block.
    beads_before: std.ArrayList(u32) = .empty,
    len: u32 = 0,
    /// The number of beads.
    bead_count: u32 = 0,
    layers: std.ArrayList(Layer) = .empty,
    /// The box of the beads: x, y, z low, then x, y, z high (mm).
    box: [6]f32 = empty_box,
    /// The box of the beads after the first feature comment: the part
    /// without the purge line of the start code. `finish` puts it in
    /// `box` when it has beads.
    typed_box: [6]f32 = empty_box,
    typed: bool = false,
    /// The print time (s), after `finish`.
    total_time: f32 = 0,
    /// The filament diameter that the widths use (mm), after `finish`.
    filament: f32 = 0,
    /// The size of the file (bytes).
    size: u64 = 0,
    /// The filament of the beads (mm): the sum of their E.
    extruded: f64 = 0,
    /// The notes of the slicer: its name, and the "key = value" comments
    /// of the start and the end of the file (see gcode_meta.zig).
    meta: gcode_meta.Meta = .{},

    // The state of the parse.
    /// A line that the last piece cut: its bytes so far, and its offset.
    tail: std.ArrayList(u8) = .empty,
    tail_start: u64 = 0,
    in_tail: bool = false,
    pos: [4]f64 = .{ 0, 0, 0, 0 },
    abs_xyz: bool = true,
    abs_e: bool = true,
    feed_rate: f64 = 3000, // mm/min
    accel: f64 = 1500, // mm/s^2
    feature: u8 = @intFromEnum(Feature.skirt),
    time: f64 = 0,
    comment_layers: bool = false,
    /// The line start and the segment count at the last change of z, for a
    /// layer that a rise of z starts.
    z_line: u32 = 0,
    z_seg: u32 = 0,
    layer_has_bead: bool = false,
    diameter_note: f32 = 0,
    nozzle_note: f32 = 0,
    total_note: f32 = 0,
    finished: bool = false,

    pub fn init(gpa: Allocator) Reader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Reader) void {
        for (r.blocks.items) |b| r.gpa.destroy(b);
        r.blocks.deinit(r.gpa);
        r.beads_before.deinit(r.gpa);
        r.layers.deinit(r.gpa);
        r.tail.deinit(r.gpa);
        r.meta.deinit(r.gpa);
        r.* = undefined;
    }

    /// Reads all of a file in memory.
    pub fn parse(gpa: Allocator, bytes: []const u8) Error!Reader {
        var r: Reader = .init(gpa);
        errdefer r.deinit();
        try r.feed(bytes);
        try r.finish();
        return r;
    }

    /// Reads the next piece of the file. A piece can end in the middle of
    /// a line.
    pub fn feed(r: *Reader, bytes: []const u8) Error!void {
        if (r.size + bytes.len > std.math.maxInt(u32)) return error.FileTooLarge;
        var rest = bytes;
        if (r.in_tail) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const take = nl orelse rest.len;
            const room = max_line -| r.tail.items.len;
            try r.tail.appendSlice(r.gpa, rest[0..@min(room, take)]);
            if (nl == null) {
                r.size += rest.len;
                return;
            }
            r.size += take + 1;
            r.in_tail = false;
            try r.line(r.tail.items, @intCast(r.tail_start), @intCast(r.size));
            r.tail.clearRetainingCapacity();
            rest = rest[take + 1 ..];
        }
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const start: u32 = @intCast(r.size);
            r.size += nl + 1;
            try r.line(rest[0..nl], start, @intCast(r.size));
            rest = rest[nl + 1 ..];
        }
        if (rest.len > 0) {
            r.in_tail = true;
            r.tail_start = r.size;
            try r.tail.appendSlice(r.gpa, rest[0..@min(max_line, rest.len)]);
            r.size += rest.len;
        }
    }

    /// Ends the file: reads a last line with no newline, and works out the
    /// widths and the times.
    pub fn finish(r: *Reader) Error!void {
        if (r.finished) return;
        if (r.in_tail) {
            r.in_tail = false;
            try r.line(r.tail.items, @intCast(r.tail_start), @intCast(r.size));
        }
        r.tail.clearAndFree(r.gpa);
        r.finished = true;
        r.endLayer();
        if (r.typed_box[3] >= r.typed_box[0]) r.box = r.typed_box;
        r.widths();
        r.times();
    }

    // ---- the lines ----

    fn line(r: *Reader, raw: []const u8, start: u32, end: u32) Error!void {
        var s = raw;
        if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
        var i: usize = 0;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i == s.len) return;
        if (s[i] == ';') return r.comment(s[i + 1 ..], start);
        // A line number (N123) goes first.
        if (s[i] == 'N' or s[i] == 'n') {
            i += 1;
            while (i < s.len and s[i] != ' ' and s[i] != 'G' and s[i] != 'M') i += 1;
            while (i < s.len and s[i] == ' ') i += 1;
        }
        if (i + 1 >= s.len) return;
        const letter = s[i] | 0x20;
        i += 1;
        const code_f = num(s, &i) orelse return;
        const code: i32 = @intFromFloat(@trunc(code_f));
        // The words: a letter and a number each.
        var w: Words = .{};
        while (i < s.len) {
            const ch = s[i];
            if (ch == ';' or ch == '*') break;
            if (ch == ' ' or ch == '\t') {
                i += 1;
                continue;
            }
            i += 1;
            const v = num(s, &i) orelse continue;
            switch (ch | 0x20) {
                'x' => w.set(0, v),
                'y' => w.set(1, v),
                'z' => w.set(2, v),
                'e' => w.set(3, v),
                'f' => w.set(4, v),
                'i' => w.set(5, v),
                'j' => w.set(6, v),
                'r' => w.set(7, v),
                'p' => w.set(8, v),
                's' => w.set(9, v),
                else => {},
            }
        }
        if (letter == 'g') switch (code) {
            0, 1 => try r.move(w, start, end),
            2, 3 => try r.arc(w, code == 2, start, end),
            4 => {
                if (w.get(8)) |p| r.time += p / 1000;
                if (w.get(9)) |sec| r.time += sec;
            },
            28 => {
                // Home: the axes named, or all of them.
                const any = w.has(0) or w.has(1) or w.has(2);
                for (0..3) |k| if (!any or w.has(k)) {
                    r.pos[k] = 0;
                };
            },
            90 => r.abs_xyz = true,
            91 => r.abs_xyz = false,
            92 => for (0..4) |k| if (w.get(k)) |v| {
                r.pos[k] = v;
            },
            else => {},
        } else if (letter == 'm') switch (code) {
            82 => r.abs_e = true,
            83 => r.abs_e = false,
            // The acceleration, for the time estimate.
            204 => if (w.get(9) orelse w.get(8)) |a| {
                if (a > 0) r.accel = a;
            },
            else => {},
        };
    }

    const Words = struct {
        v: [10]f64 = undefined,
        mask: u16 = 0,
        fn set(w: *Words, k: usize, x: f64) void {
            w.v[k] = x;
            w.mask |= @as(u16, 1) << @intCast(k);
        }
        fn has(w: Words, k: usize) bool {
            return w.mask & (@as(u16, 1) << @intCast(k)) != 0;
        }
        fn get(w: Words, k: usize) ?f64 {
            return if (w.has(k)) w.v[k] else null;
        }
    };

    /// The new position of a move, and the plastic (mm of filament).
    fn target(r: *Reader, w: Words) struct { p: [3]f64, de: f64 } {
        var p: [3]f64 = .{ r.pos[0], r.pos[1], r.pos[2] };
        for (0..3) |k| if (w.get(k)) |v| {
            p[k] = if (r.abs_xyz) v else r.pos[k] + v;
        };
        var de: f64 = 0;
        if (w.get(3)) |e| {
            // Klipper: E is absolute only with G90 and M82.
            if (r.abs_xyz and r.abs_e) {
                de = e - r.pos[3];
                r.pos[3] = e;
            } else {
                de = e;
                r.pos[3] += e;
            }
        }
        if (w.get(4)) |f| {
            if (f > 0) r.feed_rate = f;
        }
        return .{ .p = p, .de = de };
    }

    fn move(r: *Reader, w: Words, start: u32, end: u32) Error!void {
        const t = r.target(w);
        const len3 = dist3(r.pos[0..3].*, t.p);
        r.time += r.moveTime(@max(len3, @abs(t.de)));
        try r.step(t.p, t.de, start, end);
    }

    /// An arc (G2 clockwise, G3 counterclockwise) in chords of at most
    /// 1 mm and 15 degrees. All chords have the offset of the line.
    fn arc(r: *Reader, w: Words, cw: bool, start: u32, end: u32) Error!void {
        const a = r.pos;
        const t = r.target(w);
        const ex = t.p[0];
        const ey = t.p[1];
        var cx: f64 = undefined;
        var cy: f64 = undefined;
        if (w.get(7)) |rad| {
            // The R form: the center is on the bisector of the chord.
            const mx = (a[0] + ex) / 2;
            const my = (a[1] + ey) / 2;
            const dx = ex - a[0];
            const dy = ey - a[1];
            const half = @sqrt(dx * dx + dy * dy) / 2;
            if (!(half > 0)) return r.step(t.p, t.de, start, end);
            const off = @sqrt(@max(rad * rad - half * half, 0));
            // The center is to the right of the chord for a clockwise arc
            // under 180 degrees (R > 0), else to the left.
            var sgn: f64 = if (cw) -1 else 1;
            if (rad < 0) sgn = -sgn;
            cx = mx - sgn * off * dy / (2 * half);
            cy = my + sgn * off * dx / (2 * half);
        } else {
            cx = a[0] + (w.get(5) orelse 0);
            cy = a[1] + (w.get(6) orelse 0);
        }
        const radius = @sqrt((a[0] - cx) * (a[0] - cx) + (a[1] - cy) * (a[1] - cy));
        const a0 = std.math.atan2(a[1] - cy, a[0] - cx);
        const a1 = std.math.atan2(ey - cy, ex - cx);
        var sweep = a1 - a0;
        if (cw) {
            if (sweep >= -1e-9) sweep -= 2 * std.math.pi;
        } else {
            if (sweep <= 1e-9) sweep += 2 * std.math.pi;
        }
        const len = @abs(sweep) * radius;
        r.time += r.moveTime(@max(len, @abs(t.de)));
        const n_f = @max(@ceil(len / 1.0), @ceil(@abs(sweep) / (std.math.pi / 12.0)));
        const n: usize = @intFromFloat(std.math.clamp(n_f, 1, 256));
        const z0 = a[2];
        for (1..n + 1) |k| {
            const f = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const p: [3]f64 = if (k == n) t.p else .{ cx + radius * @cos(a0 + sweep * f), cy + radius * @sin(a0 + sweep * f), z0 + (t.p[2] - z0) * f };
            try r.step(p, t.de / @as(f64, @floatFromInt(n)), start, end);
        }
    }

    /// The time of a move of `len` mm at the feed rate: it speeds up and
    /// slows down at the acceleration (a trapezoid from rest to rest).
    fn moveTime(r: *const Reader, len: f64) f64 {
        if (!(len > 0)) return 0;
        const v = r.feed_rate / 60;
        const ramp = v * v / r.accel;
        if (len >= ramp) return len / v + v / r.accel;
        return 2 * @sqrt(len / r.accel);
    }

    /// Adds the segment from the position to `p` with `de` mm of filament.
    fn step(r: *Reader, p: [3]f64, de: f64, start: u32, end: u32) Error!void {
        const dx = p[0] - r.pos[0];
        const dy = p[1] - r.pos[1];
        if (p[2] != r.pos[2]) {
            r.z_line = start;
            r.z_seg = r.len;
        }
        if (dx == 0 and dy == 0) {
            r.pos[0] = p[0];
            r.pos[1] = p[1];
            r.pos[2] = p[2];
            return;
        }
        const len_xy = @sqrt(dx * dx + dy * dy);
        const bead = de > 0;
        var h: f32 = 0;
        if (bead) h = try r.beadLayer(@floatCast(p[2]));
        const s: Segment = .{
            .x = @floatCast(p[0]),
            .y = @floatCast(p[1]),
            .z = @floatCast(p[2]),
            .offset = end,
            // The filament per mm of the move, for now: `widths` turns it
            // into the bead width.
            .w = if (bead) @floatCast(de / len_xy) else 0,
            .h = @floatCast(h),
            .speed = @floatCast(@min(r.feed_rate / 60, 60000)),
            .feature = if (bead) r.feature else travel,
        };
        try r.push(s);
        if (bead) {
            r.bead_count += 1;
            r.extruded += de;
            r.meta.bead();
            const a = [3]f32{ @floatCast(r.pos[0]), @floatCast(r.pos[1]), @floatCast(p[2]) };
            const b = [3]f32{ s.x, s.y, s.z };
            grow(&r.box, a, b, h);
            if (r.typed) grow(&r.typed_box, a, b, h);
        }
        r.pos[0] = p[0];
        r.pos[1] = p[1];
        r.pos[2] = p[2];
    }

    fn grow(box: *[6]f32, a: [3]f32, b: [3]f32, h: f32) void {
        for (0..3) |k| {
            const lo = if (k == 2) a[2] - h else @min(a[k], b[k]);
            box[k] = @min(box[k], lo);
            box[k + 3] = @max(box[k + 3], @max(a[k], b[k]));
        }
    }

    fn push(r: *Reader, s: Segment) Error!void {
        const k = r.len % block_len;
        if (k == 0) {
            const b = try r.gpa.create(Block);
            errdefer r.gpa.destroy(b);
            try r.blocks.append(r.gpa, b);
            try r.beads_before.append(r.gpa, r.bead_count);
        }
        r.blocks.items[r.blocks.items.len - 1][k] = s;
        r.len += 1;
    }

    /// The layer of a bead at z: starts a layer at a rise of z in a file
    /// with no layer comments, and sets the z and the height of the layer
    /// at its first bead. Returns the bead height.
    fn beadLayer(r: *Reader, z: f32) Error!f32 {
        if (!r.comment_layers) {
            const rise = if (r.layers.items.len == 0) true else blk: {
                const cur = r.layers.items[r.layers.items.len - 1];
                break :blk r.layer_has_bead and z > cur.z + 1e-4;
            };
            if (rise) {
                if (r.layers.items.len == 0) {
                    try r.newLayer(0, 0);
                } else {
                    // The layer starts at the move that rose to its z.
                    const last = r.layers.items[r.layers.items.len - 1];
                    try r.newLayer(@max(r.z_line, last.offset), @max(r.z_seg, last.first));
                }
            }
        }
        if (r.layers.items.len == 0) try r.newLayer(0, 0);
        const n = r.layers.items.len;
        const cur = &r.layers.items[n - 1];
        if (!cur.z_known) {
            cur.z = z;
            cur.z_known = true;
        }
        if (!cur.h_known) {
            const below: f32 = if (n >= 2 and r.layers.items[n - 2].z_known) r.layers.items[n - 2].z else 0;
            const h = cur.z - below;
            cur.h = if (h > 0.005 and h < 5) h else if (cur.z > 0.005 and cur.z < 5) cur.z else 0.2;
            cur.h_known = true;
        }
        r.layer_has_bead = true;
        return cur.h;
    }

    fn newLayer(r: *Reader, offset: u32, first: u32) Error!void {
        r.endLayer();
        try r.layers.append(r.gpa, .{ .first = first, .offset = offset });
        r.layer_has_bead = false;
    }

    /// Notes the time at the end of the last layer.
    fn endLayer(r: *Reader) void {
        if (r.layers.items.len == 0) return;
        r.layers.items[r.layers.items.len - 1].time = @floatCast(r.time);
    }

    // ---- comments ----

    fn comment(r: *Reader, raw: []const u8, start: u32) Error!void {
        var c = raw;
        while (c.len > 0 and c[0] == ' ') c = c[1..];
        if (c.len < 2) return;
        // Most comments of a large file are lines of a thumbnail (base64):
        // they have no ':' or '=' in the first few bytes, and the checks
        // below are prefix tests only.
        switch (c[0]) {
            'L' => {
                if (std.mem.startsWith(u8, c, "LAYER:") or std.mem.eql(u8, c, "LAYER_CHANGE")) return r.layerComment(start);
                if (std.mem.startsWith(u8, c, "LAYER_HEIGHT:")) return r.noteHeight(c["LAYER_HEIGHT:".len..]);
            },
            'C' => if (std.mem.eql(u8, c, "CHANGE_LAYER")) return r.layerComment(start),
            'T' => {
                if (std.mem.startsWith(u8, c, "TYPE:")) {
                    r.feature = featureOf(c["TYPE:".len..]);
                    r.typed = true;
                    return;
                }
                if (std.mem.startsWith(u8, c, "TIME_ELAPSED:")) {
                    var i: usize = "TIME_ELAPSED:".len;
                    if (num(c, &i)) |t| if (r.layers.items.len > 0) {
                        r.layers.items[r.layers.items.len - 1].elapsed = @floatCast(t);
                    };
                    return;
                }
                if (std.mem.startsWith(u8, c, "TIME:")) {
                    var i: usize = "TIME:".len;
                    // 6666 is the stand-in value of CuraEngine with no
                    // front end.
                    if (num(c, &i)) |t| if (t > 0 and t != 6666) {
                        r.total_note = @floatCast(t);
                    };
                    return;
                }
            },
            'F' => if (std.mem.startsWith(u8, c, "FEATURE:")) {
                r.feature = featureOf(c["FEATURE:".len..]);
                r.typed = true;
                return;
            },
            'Z' => {
                if (std.mem.startsWith(u8, c, "Z:")) return r.noteZ(c[2..]);
                if (std.mem.startsWith(u8, c, "Z_HEIGHT:")) return r.noteZ(c["Z_HEIGHT:".len..]);
            },
            'H' => if (std.mem.startsWith(u8, c, "HEIGHT:")) return r.noteHeight(c["HEIGHT:".len..]),
            'G', 'g' => if (std.ascii.startsWithIgnoreCase(c, "generated ")) return r.meta.slicerLine(c),
            'B' => if (std.mem.startsWith(u8, c, "BambuStudio ")) return r.meta.slicerLine(c),
            'E', 'e' => if (std.ascii.startsWithIgnoreCase(c, "estimated time:")) {
                // zslice: ";Estimated time: 3026s".
                r.total_note = @floatCast(duration(c["estimated time:".len..]));
                return;
            } else if (std.ascii.startsWithIgnoreCase(c, "estimated printing time")) {
                // PrusaSlicer and OrcaSlicer: "= 1h 2m 3s".
                if (std.mem.indexOfScalar(u8, c, '=')) |eq| r.total_note = @floatCast(duration(c[eq + 1 ..]));
                return;
            },
            else => {},
        }
        // A setting of the slicer: "key = value" or "key: value".
        const sep = std.mem.indexOfAny(u8, c[0..@min(c.len, 64)], "=:") orelse return;
        const key = std.mem.trim(u8, c[0..sep], " ");
        var i: usize = sep + 1;
        while (i < c.len and c[i] == ' ') i += 1;
        try r.meta.note(r.gpa, key, std.mem.trimEnd(u8, c[i..], " \t"));
        if (std.mem.endsWith(u8, key, "filament_diameter") or std.mem.endsWith(u8, key, "filament.diameter") or std.mem.endsWith(u8, key, "material_diameter")) {
            if (num(c, &i)) |d| if (d > 0.5 and d < 5) {
                r.diameter_note = @floatCast(d);
            };
        } else if (std.mem.endsWith(u8, key, "nozzle_diameter") or std.mem.endsWith(u8, key, "machine_nozzle_size")) {
            if (num(c, &i)) |d| if (d > 0.05 and d < 3) {
                r.nozzle_note = @floatCast(d);
            };
        } else if (std.ascii.eqlIgnoreCase(key, "total estimated time")) {
            r.total_note = @floatCast(duration(c[i..]));
        }
    }

    fn layerComment(r: *Reader, start: u32) Error!void {
        if (!r.comment_layers) {
            // The first layer comment: the layers from z before it (the
            // start code, a purge line) go into the first layer.
            r.comment_layers = true;
            r.layers.clearRetainingCapacity();
            try r.newLayer(0, 0);
            return;
        }
        try r.newLayer(start, r.len);
    }

    fn noteZ(r: *Reader, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len and text[i] == ' ') i += 1;
        const z = num(text, &i) orelse return;
        if (r.layers.items.len == 0) return;
        const cur = &r.layers.items[r.layers.items.len - 1];
        cur.z = @floatCast(z);
        cur.z_known = true;
    }

    fn noteHeight(r: *Reader, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len and text[i] == ' ') i += 1;
        const h = num(text, &i) orelse return;
        if (r.layers.items.len == 0 or !(h > 0)) return;
        const cur = &r.layers.items[r.layers.items.len - 1];
        cur.h = @floatCast(h);
        cur.h_known = true;
    }

    // ---- the end ----

    /// The filament diameter, and the bead widths from it.
    fn widths(r: *Reader) void {
        var d = r.diameter_note;
        if (!(d > 0)) d = r.guessDiameter();
        r.filament = d;
        const area = std.math.pi * d * d / 4;
        for (r.blocks.items, 0..) |b, bi| {
            const n = @min(block_len, r.len - bi * block_len);
            for (b[0..n]) |*s| {
                if (s.feature == travel) continue;
                const h: f64 = @max(@as(f64, s.h), 0.01);
                s.w = @floatCast(@min(flow.beadWidth(@as(f64, s.w) * area, h), 60000));
            }
        }
    }

    /// The diameter (1.75 or 2.85 mm) that gives a median bead width
    /// nearer to the nozzle size (0.4 mm when no comment gives it).
    fn guessDiameter(r: *const Reader) f32 {
        if (r.bead_count == 0) return 1.75;
        var sample: [1024]f64 = undefined;
        var n: usize = 0;
        const stride: u32 = @intCast(@max(1, r.len / sample.len));
        var i: u32 = 0;
        while (i < r.len and n < sample.len) : (i += stride) {
            const s = r.at(i);
            if (s.feature == travel) continue;
            const h: f64 = @max(@as(f64, s.h), 0.01);
            // The width with 1.75 mm filament.
            sample[n] = flow.beadWidth(@as(f64, s.w) * std.math.pi * 1.75 * 1.75 / 4, h);
            n += 1;
        }
        if (n == 0) return 1.75;
        std.mem.sort(f64, sample[0..n], {}, std.sort.asc(f64));
        const w175 = sample[n / 2];
        // The same median bead with 2.85 mm filament has 2.65 times the
        // area: its width is near 2.65 times as large.
        const w285 = w175 * (2.85 * 2.85) / (1.75 * 1.75);
        const want: f64 = if (r.nozzle_note > 0) r.nozzle_note * 1.1 else 0.45;
        return if (@abs(@log(w175 / want)) <= @abs(@log(w285 / want))) 1.75 else 2.85;
    }

    /// The layer times: from the comments if each layer has one, else the
    /// estimate, scaled to the total time of the slicer if a comment
    /// gives it.
    fn times(r: *Reader) void {
        const all_elapsed = r.layers.items.len > 0 and for (r.layers.items) |l| {
            if (l.elapsed < 0) break false;
        } else true;
        if (all_elapsed) {
            for (r.layers.items) |*l| l.time = l.elapsed;
            r.total_time = @max(@as(f32, @floatCast(r.time)), r.layers.items[r.layers.items.len - 1].time);
            return;
        }
        var scale: f64 = 1;
        if (r.total_note > 0 and r.time > 0) scale = r.total_note / r.time;
        for (r.layers.items) |*l| l.time = @floatCast(l.time * scale);
        r.total_time = @floatCast(r.time * scale);
    }

    // ---- queries ----

    pub fn at(r: *const Reader, i: u32) *Segment {
        return &r.blocks.items[i / block_len][i % block_len];
    }

    /// The start point of segment i: the end of the segment before.
    pub fn startOf(r: *const Reader, i: u32) [3]f32 {
        if (i == 0) {
            const s = r.at(0);
            return .{ s.x, s.y, s.z };
        }
        const p = r.at(i - 1);
        return .{ p.x, p.y, p.z };
    }

    /// The number of segments whose line ends at or before `offset`: the
    /// moves that Klipper has read at that offset.
    pub fn doneAt(r: *const Reader, offset: u64) u32 {
        if (offset >= std.math.maxInt(u32)) return r.len;
        const o: u32 = @intCast(offset);
        var lo: u32 = 0;
        var hi: u32 = r.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (r.at(mid).offset <= o) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The number of beads among the first `n` segments.
    pub fn beadsIn(r: *const Reader, n: u32) u32 {
        if (n == 0) return 0;
        if (n >= r.len) return r.bead_count;
        const b = n / block_len;
        var count = r.beads_before.items[b];
        const blk = r.blocks.items[b];
        for (blk[0 .. n % block_len]) |s| count += @intFromBool(s.feature != travel);
        return count;
    }

    /// The layer at a byte offset: the offset counts the bytes read, so
    /// this is the layer of the last byte read (byte offset - 1).
    pub fn layerAt(r: *const Reader, offset: u64) usize {
        const ls = r.layers.items;
        if (ls.len == 0) return 0;
        var lo: usize = 0;
        var hi: usize = ls.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (ls[mid].offset < offset) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else lo - 1;
    }

    /// The layer of segment i.
    pub fn layerOfSegment(r: *const Reader, i: u32) usize {
        const ls = r.layers.items;
        var lo: usize = 0;
        var hi: usize = ls.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (ls[mid].first <= i) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else lo - 1;
    }

    /// The byte range of layer l: from its start to the start of the next
    /// layer (or the end of the file).
    pub fn layerRange(r: *const Reader, l: usize) [2]u64 {
        const ls = r.layers.items;
        if (l >= ls.len) return .{ r.size, r.size };
        return .{ ls[l].offset, if (l + 1 < ls.len) ls[l + 1].offset else r.size };
    }

    /// The segments of layer l: first to end.
    pub fn layerSegments(r: *const Reader, l: usize) [2]u32 {
        const ls = r.layers.items;
        if (l >= ls.len) return .{ r.len, r.len };
        return .{ ls[l].first, if (l + 1 < ls.len) ls[l + 1].first else r.len };
    }

    /// The start and end times of layer l (s).
    pub fn layerTimes(r: *const Reader, l: usize) [2]f32 {
        const ls = r.layers.items;
        if (l >= ls.len) return .{ r.total_time, r.total_time };
        return .{ if (l == 0) 0 else ls[l - 1].time, ls[l].time };
    }

    /// The segment that the printer moves on at a byte offset: the last
    /// move read at that offset, or null before the first move.
    pub fn segmentAt(r: *const Reader, offset: u64) ?u32 {
        const n = r.doneAt(offset);
        return if (n == 0) null else n - 1;
    }

    /// The last bead read at a byte offset, or null. It looks back at most
    /// two blocks of moves.
    pub fn beadAt(r: *const Reader, offset: u64) ?u32 {
        var n = r.doneAt(offset);
        var steps: u32 = 0;
        while (n > 0 and steps < 2 * block_len) : (steps += 1) {
            n -= 1;
            if (r.at(n).feature != travel) return n;
        }
        return null;
    }
};

/// The Feature of a ";TYPE:" or "; FEATURE:" name of zslice, Cura,
/// PrusaSlicer, OrcaSlicer, or Bambu Studio. An unknown name (the start
/// code, a prime tower) is the skirt: a plain color.
pub fn featureOf(name_raw: []const u8) u8 {
    const name = std.mem.trim(u8, name_raw, " \t");
    const T = struct { []const u8, Feature };
    const table = [_]T{
        // zslice and Cura.
        .{ "WALL-OUTER", .outer_wall },
        .{ "WALL-INNER", .inner_wall },
        .{ "SKIN", .skin },
        .{ "FILL", .infill },
        .{ "IRONING", .ironing },
        .{ "SKIRT", .skirt },
        .{ "SUPPORT", .support },
        .{ "SUPPORT-INTERFACE", .support_interface },
        .{ "SUPPORT-INFILL", .support },
        .{ "SUPPORT-ROOF", .support_interface },
        .{ "SUPPORT-BOTTOM", .support_interface },
        .{ "SLOPE-SMOOTHING", .slope_smoothing },
        .{ "SLOPE-IRONING", .slope_ironing },
        .{ "BRIDGE", .bridge },
        // PrusaSlicer.
        .{ "External perimeter", .outer_wall },
        .{ "Overhang perimeter", .outer_wall },
        .{ "Perimeter", .inner_wall },
        .{ "Internal infill", .infill },
        .{ "Solid infill", .skin },
        .{ "Top solid infill", .skin },
        .{ "Bridge infill", .bridge },
        .{ "Gap fill", .inner_wall },
        .{ "Skirt/Brim", .skirt },
        .{ "Support material", .support },
        .{ "Support material interface", .support_interface },
        // OrcaSlicer and Bambu Studio.
        .{ "Outer wall", .outer_wall },
        .{ "Overhang wall", .outer_wall },
        .{ "Inner wall", .inner_wall },
        .{ "Sparse infill", .infill },
        .{ "Internal solid infill", .skin },
        .{ "Top surface", .skin },
        .{ "Bottom surface", .skin },
        .{ "Internal Bridge", .bridge },
        .{ "Gap infill", .inner_wall },
        .{ "Brim", .skirt },
        .{ "Support interface", .support_interface },
        .{ "Support transition", .support },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(name, t[0])) return @intFromEnum(t[1]);
    return @intFromEnum(Feature.skirt);
}

/// A time in a comment: "3026s", "1h 2m 3s", "1d 2h 3m 4s", or a plain
/// number of seconds.
fn duration(text: []const u8) f64 {
    var total: f64 = 0;
    var i: usize = 0;
    var any = false;
    while (i < text.len) {
        if (!std.ascii.isDigit(text[i]) and text[i] != '.') {
            i += 1;
            continue;
        }
        const v = num(text, &i) orelse break;
        any = true;
        while (i < text.len and text[i] == ' ') i += 1;
        const unit: u8 = if (i < text.len) text[i] | 0x20 else 's';
        total += v * @as(f64, switch (unit) {
            'd' => 86400,
            'h' => 3600,
            'm' => 60,
            else => 1,
        });
    }
    return if (any) total else 0;
}

const pow10 = blk: {
    var t: [19]f64 = undefined;
    var p: f64 = 1;
    for (&t) |*x| {
        x.* = p;
        p *= 10;
    }
    break :blk t;
};

/// Reads a decimal number at s[i.*] (a sign, digits, a point, digits),
/// and moves i past it. Null if there are no digits. It has no exponent:
/// in G-code an 'E' after a number is the next word.
fn num(s: []const u8, i: *usize) ?f64 {
    var k = i.*;
    var neg = false;
    if (k < s.len and (s[k] == '-' or s[k] == '+')) {
        neg = s[k] == '-';
        k += 1;
    }
    var int: u64 = 0;
    var digits: usize = 0;
    while (k < s.len and s[k] >= '0' and s[k] <= '9') : (k += 1) {
        if (digits < 18) int = int * 10 + (s[k] - '0');
        digits += 1;
    }
    var frac: u64 = 0;
    var fd: usize = 0;
    if (k < s.len and s[k] == '.') {
        k += 1;
        while (k < s.len and s[k] >= '0' and s[k] <= '9') : (k += 1) {
            if (fd < 18) {
                frac = frac * 10 + (s[k] - '0');
                fd += 1;
            }
            digits += 1;
        }
    }
    if (digits == 0) return null;
    i.* = k;
    var v = @as(f64, @floatFromInt(int)) + @as(f64, @floatFromInt(frac)) / pow10[fd];
    if (digits > 18 and fd == 0) v = std.math.inf(f64);
    return if (neg) -v else v;
}

fn dist3(a: [3]f64, b: [3]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

// ---- tests ----

const testing = std.testing;

test "gcode_read: zslice G-code of the demo part" {
    const gpa = testing.allocator;
    const engine = @import("engine.zig");
    const mesh_mod = @import("mesh.zig");
    var m = try mesh_mod.shapes.demo(gpa);
    defer m.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: @import("settings.zig").Settings = .{};
    s.engine.threads = 2;
    s.project.skirt_loops = 0;
    const stats = try engine.slice(gpa, &m, s, &out.writer);
    const text = out.written();

    var r = try Reader.parse(gpa, text);
    defer r.deinit();
    try testing.expectEqual(@as(usize, stats.layer_count), r.layers.items.len);
    try testing.expectEqual(@as(f32, 1.75), r.filament);
    // The first layer is 0.3 mm, the others 0.2 mm.
    try testing.expectApproxEqAbs(@as(f32, 0.3), r.layers.items[0].z, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.3), r.layers.items[0].h, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.layers.items[1].z, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.2), r.layers.items[5].h, 1e-4);
    // The box: the demo part is 40 mm wide, centered at x = 110, and the
    // outer wall is half a line width inside.
    try testing.expectApproxEqAbs(@as(f32, 90.22), r.box[0], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 129.78), r.box[3], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0), r.box[2], 1e-3);
    // Each layer starts at its ";LAYER:n" line (the first at 0).
    for (r.layers.items[1..], 1..) |l, i| {
        var buf: [32]u8 = undefined;
        const tag = try std.fmt.bufPrint(&buf, ";LAYER:{d}\n", .{i});
        try testing.expectEqual(std.mem.indexOf(u8, text, tag).?, l.offset);
    }
    // The bead widths are near the line width (0.44 mm), and each bead
    // has a feature.
    var walls: usize = 0;
    var i: u32 = 0;
    while (i < r.len) : (i += 1) {
        const seg = r.at(i);
        if (seg.feature == travel) continue;
        try testing.expect(seg.feature < 11);
        if (seg.feature == @intFromEnum(Feature.outer_wall)) {
            walls += 1;
            try testing.expectApproxEqAbs(@as(f32, 0.44), @as(f32, seg.w), 0.06);
        }
    }
    try testing.expect(walls > 100);
    // The queries.
    const mid = r.layers.items.len / 2;
    const range = r.layerRange(mid);
    try testing.expectEqual(mid - 1, r.layerAt(range[0]));
    try testing.expectEqual(mid, r.layerAt(range[0] + 1));
    try testing.expectEqual(mid, r.layerAt(range[1]));
    try testing.expectEqual(mid + 1, r.layerAt(range[1] + 1));
    const segs = r.layerSegments(mid);
    try testing.expect(segs[1] > segs[0]);
    try testing.expectEqual(segs[1], r.doneAt(range[1]));
    try testing.expectEqual(mid, r.layerOfSegment(segs[0]));
    // The estimate is near the estimate of the slicer (the comment scales
    // it to the same total).
    try testing.expectApproxEqRel(@as(f32, @floatCast(stats.print_time_s)), r.total_time, 0.02);
    const lt = r.layerTimes(mid);
    try testing.expect(lt[1] > lt[0]);
}

test "gcode_read: pieces of any size give the same result" {
    const gpa = testing.allocator;
    const text = cura_sample;
    var whole = try Reader.parse(gpa, text);
    defer whole.deinit();
    for ([_]usize{ 1, 2, 3, 7, 64 }) |piece| {
        var r: Reader = .init(gpa);
        defer r.deinit();
        var k: usize = 0;
        while (k < text.len) : (k += piece) try r.feed(text[k..@min(text.len, k + piece)]);
        try r.finish();
        try testing.expectEqual(whole.len, r.len);
        try testing.expectEqual(whole.layers.items.len, r.layers.items.len);
        var i: u32 = 0;
        while (i < r.len) : (i += 1) try testing.expectEqual(whole.at(i).*, r.at(i).*);
    }
}

const cura_sample =
    \\;FLAVOR:Marlin
    \\;TIME:6666
    \\;Layer height: 0.2
    \\M82 ;absolute extrusion mode
    \\G28
    \\G92 E0
    \\G1 Z0.3 F600
    \\G1 X0 Y5 E3 F1000 ; purge line
    \\G92 E0
    \\;LAYER_COUNT:2
    \\;LAYER:0
    \\G0 F3000 X10 Y10 Z0.3
    \\;TYPE:WALL-OUTER
    \\G1 F1200 X20 Y10 E0.4991
    \\G1 X20 Y20 E0.9982
    \\;TYPE:FILL
    \\G1 X10 Y20 E1.4973
    \\;TIME_ELAPSED:10.5
    \\;LAYER:1
    \\G0 X10 Y10 Z0.5
    \\;TYPE:SKIN
    \\G1 F1500 X20 Y10 E1.8300
    \\;TYPE:SUPPORT-INTERFACE
    \\G1 X20 Y12 E1.8966
    \\;TIME_ELAPSED:21
    \\M104 S0
    \\
;

test "gcode_read: Cura G-code with absolute E" {
    var r = try Reader.parse(testing.allocator, cura_sample);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.layers.items.len);
    // The purge line before ";LAYER:0" is in the first layer.
    try testing.expectEqual(@as(u32, 0), r.layers.items[0].offset);
    try testing.expectEqual(@as(u32, 0), r.layers.items[0].first);
    const s0 = r.at(0);
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.skirt)), s0.feature);
    // The box has the part and leaves out the purge line at x = 0.
    try testing.expectEqual([6]f32{ 10, 10, 0, 20, 20, 0.5 }, r.box);
    // The wall: 0.4991 mm of 1.75 mm filament over 10 mm is a bead of
    // 0.12 mm2: 0.2 mm high (0.5 - 0.3) in layer 1, and 0.3 mm (its z) in
    // layer 0.
    var walls: usize = 0;
    var i: u32 = 0;
    while (i < r.len) : (i += 1) {
        const s = r.at(i);
        if (s.feature != @intFromEnum(Feature.outer_wall)) continue;
        walls += 1;
        try testing.expectApproxEqAbs(@as(f32, 0.3), @as(f32, s.h), 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 20), @as(f32, s.speed), 1e-3);
        try testing.expectApproxEqAbs(@as(f32, @floatCast(flow.beadWidth(0.4991 * std.math.pi * 1.75 * 1.75 / 4.0 / 10.0, 0.3))), @as(f32, s.w), 2e-3);
    }
    try testing.expectEqual(@as(usize, 2), walls);
    try testing.expectApproxEqAbs(@as(f32, 0.2), r.layers.items[1].h, 1e-4);
    // The times come from ";TIME_ELAPSED:".
    try testing.expectEqual([2]f32{ 10.5, 21 }, r.layerTimes(1));
    // The last bead is support interface, at 25 mm/s.
    const last = r.beadAt(r.size).?;
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.support_interface)), r.at(last).feature);
    try testing.expectApproxEqAbs(@as(f32, 25), @as(f32, r.at(last).speed), 1e-3);
    const skin_off = std.mem.indexOf(u8, cura_sample, "G1 F1500").? + 10;
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.skin)), r.at(r.segmentAt(skin_off + 20).?).feature);
}

test "gcode_read: the notes of the slicer" {
    const text =
        \\;FLAVOR:Marlin
        \\;Filament used: 0.5m
        \\;Layer height: 0.2
        \\;Generated with Cura_SteamEngine 5.13.0
        \\G1 Z0.2 F600
        \\G1 X10 Y0 E1
        \\;WIDTH:0.45
        \\G1 X10 Y10 E2
        \\;Filament weight: 1.5g
        \\;  project.layer_height = 0.2
        \\
    ;
    var r = try Reader.parse(testing.allocator, text);
    defer r.deinit();
    const m = &r.meta;
    try testing.expectEqualStrings("Cura_SteamEngine 5.13.0", m.slicer());
    // The note between the beads (WIDTH) is gone.
    try testing.expectEqual(@as(usize, 5), m.count());
    try testing.expectEqualStrings("project.layer_height", m.key(4));
    try testing.expectApproxEqAbs(@as(f64, 0.5), m.meters().?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), m.grams().?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2), r.extruded, 1e-9);
}

test "gcode_read: PrusaSlicer G-code with 2.85 mm filament" {
    const text =
        \\; generated by PrusaSlicer 2.7.1
        \\M83 ; use relative distances for extrusion
        \\;LAYER_CHANGE
        \\;Z:0.25
        \\;HEIGHT:0.25
        \\G1 Z.25 F720
        \\G1 X10 Y10 F9000
        \\;TYPE:External perimeter
        \\G1 F1800
        \\G1 X30 Y10 E.4006
        \\;TYPE:Solid infill
        \\G1 X30 Y30 E.4006
        \\;LAYER_CHANGE
        \\;Z:0.45
        \\;HEIGHT:0.2
        \\G1 Z.45 F720
        \\;TYPE:Perimeter
        \\G1 X10 Y30 E.3205 F1800
        \\;TYPE:Gap fill
        \\G1 X10 Y20 E.1
        \\; estimated printing time (normal mode) = 1m 4s
        \\; filament_diameter = 2.85
        \\; nozzle_diameter = 0.4
    ;
    var r = try Reader.parse(testing.allocator, text);
    defer r.deinit();
    try testing.expectEqual(@as(f32, 2.85), r.filament);
    try testing.expectEqual(@as(usize, 2), r.layers.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.45), r.layers.items[1].z, 1e-5);
    // 0.4006 mm of 2.85 mm filament over 20 mm: 0.1278 mm2, 0.25 mm high.
    const s = r.at(1);
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.outer_wall)), s.feature);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(flow.beadWidth(0.4006 * std.math.pi * 2.85 * 2.85 / 4.0 / 20.0, 0.25))), @as(f32, s.w), 2e-3);
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.skin)), r.at(2).feature);
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.inner_wall)), r.at(3).feature);
    // The estimate scales to the total of the slicer.
    try testing.expectApproxEqAbs(@as(f32, 64), r.total_time, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 64), r.layerTimes(1)[1], 1e-3);
}

test "gcode_read: OrcaSlicer arcs and Bambu comments" {
    const text =
        \\; HEADER_BLOCK_START
        \\; total estimated time: 2m 0s
        \\; HEADER_BLOCK_END
        \\M83
        \\; CHANGE_LAYER
        \\; Z_HEIGHT: 0.2
        \\; LAYER_HEIGHT: 0.2
        \\G1 Z.2 F600
        \\G1 X20 Y10 F6000
        \\; FEATURE: Outer wall
        \\G3 X0 Y10 I-10 J0 E1.2 F1200
        \\;TYPE:Sparse infill
        \\G3 X20 Y10 R10 E1.2
        \\; CHANGE_LAYER
        \\; Z_HEIGHT: 0.4
        \\G1 Z.4
        \\;TYPE:Top surface
        \\G1 X20 Y12 E0.1
        \\G2 X0 Y12 I-10 J0 E1.2
        \\
    ;
    var r = try Reader.parse(testing.allocator, text);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.layers.items.len);
    try testing.expectApproxEqAbs(@as(f32, 120), r.total_time, 1e-3);
    // The first G3 goes counterclockwise from (20, 10) around (10, 10):
    // over the top, through y = 20. The second G3 goes on from (0, 10):
    // under, through y = 0.
    try testing.expectApproxEqAbs(@as(f32, 20), r.box[4], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), r.box[1], 1e-3);
    var top: f32 = 0;
    var i: u32 = 0;
    const arc_end = r.layers.items[1].first;
    while (i < arc_end) : (i += 1) {
        const s = r.at(i);
        if (s.feature == @intFromEnum(Feature.outer_wall)) top = @max(top, s.y);
        if (s.feature == @intFromEnum(Feature.infill)) try testing.expect(s.y <= 10.001);
        // Each chord of an arc is near the circle.
        if (s.feature != travel) try testing.expectApproxEqAbs(@as(f32, 10), std.math.hypot(s.x - 10, s.y - 10), 1e-3);
    }
    try testing.expectApproxEqAbs(@as(f32, 20), top, 1e-3);
    // The G2 goes clockwise from (20, 12) around (10, 12): under, through
    // y = 2.
    var low: f32 = 100;
    i = arc_end;
    while (i < r.len) : (i += 1) low = @min(low, r.at(i).y);
    try testing.expectApproxEqAbs(@as(f32, 2), low, 1e-3);
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.skin)), r.at(r.len - 1).feature);
}

test "gcode_read: layers from z with no comments" {
    const text =
        \\G90
        \\M83
        \\G1 Z0.2 F600
        \\G1 X10 Y0 E0.5 F1200
        \\G1 Z0.6
        \\G1 X20 Y0
        \\G1 Z0.2
        \\G1 X10 Y10 E0.5
        \\G1 Z0.4
        \\G1 X0 Y10 E0.5
        \\G91
        \\G1 X1 E0.05
        \\G90
    ;
    var r = try Reader.parse(testing.allocator, text);
    defer r.deinit();
    // The z hop to 0.6 has no plastic: two layers, at 0.2 and 0.4.
    try testing.expectEqual(@as(usize, 2), r.layers.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.4), r.layers.items[1].z, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.2), r.layers.items[1].h, 1e-5);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "G1 Z0.4").?)), r.layers.items[1].offset);
    // The relative move goes from x = 0 to x = 1.
    try testing.expectApproxEqAbs(@as(f32, 1), r.at(r.len - 1).x, 1e-5);
    try testing.expectEqual(@as(u32, 4), r.bead_count);
}

test "gcode_read: feature names" {
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.outer_wall)), featureOf("External perimeter"));
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.bridge)), featureOf("Bridge infill"));
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.infill)), featureOf("FILL"));
    try testing.expectEqual(@as(u8, @intFromEnum(Feature.skirt)), featureOf("Custom"));
    try testing.expectApproxEqAbs(@as(f64, 3723), duration(" 1h 2m 3s"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3026), duration(" 3026s"), 1e-9);
}
