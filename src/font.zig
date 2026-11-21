//! A small reader of TrueType fonts, for the text of the labels (see
//! label.zig).
//!
//! A TrueType file is a list of tables. This reader uses these:
//!
//! - `head`: the units of the em square, and the size of the `loca`
//!   offsets.
//! - `maxp`: the count of the glyphs.
//! - `hhea` and `hmtx`: the advance width of each glyph.
//! - `cmap`: the glyph of each character (formats 4 and 12).
//! - `loca` and `glyf`: the outline of each glyph. A simple glyph is a
//!   list of contours. Each contour is a loop of points on the curve and
//!   control points off the curve. Two control points in a row have a
//!   point on the curve between them. Each piece is a line or a
//!   quadratic Bezier curve. A composite glyph puts other glyphs at an
//!   offset, with a scale (an accented letter is a letter and an accent).
//! - `kern` (format 0): the change of the advance for a pair of glyphs.
//! - `OS/2`: the cap height.
//!
//! The reader flattens each curve to lines, with a limit on the distance
//! between the curve and the lines. It checks each offset and each count
//! against the size of the file, so a bad file gives an error. It reads
//! no CFF outlines (most .otf files).
//!
//! The app embeds one font: Inter Bold (SIL Open Font License 1.1), as a
//! subset of Basic Latin and Latin-1 that `tools/font_subset.py` makes.
//! The tool moves the kerning of the font (GPOS) into a `kern` table.
//!
//! References (see docs/references/fonts.md): the OpenType specification (the
//! tables above); the Inter font.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const Paths = geom.Paths;
const Point = geom.Point;

pub const Error = error{BadFont} || Allocator.Error;

/// The bytes of the embedded font: Inter Bold, Basic Latin and Latin-1.
pub const inter_bold = @embedFile("fonts/Inter-Bold-Latin.ttf");

/// The deepest nesting of composite glyphs.
const max_nesting = 8;
/// The most points of one glyph (with its components).
const max_points = 1 << 16;
/// The most components of one glyph, at all depths: a bad file can
/// nest many components many times.
const max_components = 256;

/// The embedded font (see `inter_bold`).
pub fn builtin() Font {
    return Font.init(inter_bold) catch unreachable;
}

const Table = struct { off: u32 = 0, len: u32 = 0 };

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    glyphs: u16,
    long_loca: bool,
    metrics: u16,
    ascender: i16,
    descender: i16,
    /// The height of the capitals (font units).
    cap_height: i16,
    cmap: Table,
    loca: Table,
    glyf: Table,
    hmtx: Table,
    kern: Table,

    /// Reads the table directory and the header tables.
    pub fn init(data: []const u8) error{BadFont}!Font {
        if (data.len < 12) return error.BadFont;
        const version = be32(data, 0) catch return error.BadFont;
        if (version != 0x00010000 and version != 0x74727565) return error.BadFont;
        const n = try be16(data, 4);
        var t: struct { head: Table = .{}, maxp: Table = .{}, hhea: Table = .{}, hmtx: Table = .{}, cmap: Table = .{}, loca: Table = .{}, glyf: Table = .{}, kern: Table = .{}, os2: Table = .{} } = .{};
        for (0..n) |i| {
            const r = 12 + 16 * i;
            if (r + 16 > data.len) return error.BadFont;
            const tag = data[r..][0..4];
            const off = try be32(data, r + 8);
            const len = try be32(data, r + 12);
            if (@as(u64, off) + len > data.len) return error.BadFont;
            const tb: Table = .{ .off = off, .len = len };
            inline for (.{ "head", "maxp", "hhea", "hmtx", "cmap", "loca", "glyf", "kern", "OS/2" }, .{ "head", "maxp", "hhea", "hmtx", "cmap", "loca", "glyf", "kern", "os2" }) |name, field| {
                if (std.mem.eql(u8, tag, name)) @field(t, field) = tb;
            }
        }
        if (t.head.len < 54 or t.maxp.len < 6 or t.hhea.len < 36 or t.cmap.len < 4 or t.hmtx.len < 4) return error.BadFont;
        const upm = try be16(data, t.head.off + 18);
        if (upm < 16 or upm > 16384) return error.BadFont;
        const fmt = try bei16(data, t.head.off + 50);
        const glyphs = try be16(data, t.maxp.off + 4);
        const metrics = try be16(data, t.hhea.off + 34);
        if (glyphs == 0 or metrics == 0 or metrics > glyphs) return error.BadFont;
        if (@as(u64, metrics) * 4 > t.hmtx.len) return error.BadFont;
        const long = fmt == 1;
        const need: u64 = (@as(u64, glyphs) + 1) * @as(u64, if (long) 4 else 2);
        if (t.loca.len < need) return error.BadFont;
        var f: Font = .{
            .data = data,
            .units_per_em = upm,
            .glyphs = glyphs,
            .long_loca = long,
            .metrics = metrics,
            .ascender = try bei16(data, t.hhea.off + 4),
            .descender = try bei16(data, t.hhea.off + 6),
            .cap_height = 0,
            .cmap = t.cmap,
            .loca = t.loca,
            .glyf = t.glyf,
            .hmtx = t.hmtx,
            .kern = t.kern,
        };
        // The cap height: from OS/2 (version 2 and later), else the top of
        // "H".
        if (t.os2.len >= 90 and (try be16(data, t.os2.off)) >= 2) f.cap_height = try bei16(data, t.os2.off + 88);
        if (f.cap_height <= 0) {
            const box = f.glyphBox(f.glyphIndex('H')) catch null;
            f.cap_height = if (box) |b| b[3] else @intCast(@divTrunc(@as(i32, upm) * 7, 10));
        }
        if (f.cap_height <= 0) return error.BadFont;
        return f;
    }

    /// The glyph of a character, or 0 (the "missing" glyph).
    pub fn glyphIndex(f: *const Font, cp: u21) u16 {
        return f.lookup(cp) catch 0;
    }

    fn lookup(f: *const Font, cp: u21) error{BadFont}!u16 {
        const d = f.data;
        const base = f.cmap.off;
        const n = try be16(d, base + 2);
        // The best subtable: format 12 of Unicode, else format 4.
        var best4: ?u32 = null;
        var best12: ?u32 = null;
        for (0..n) |i| {
            const r = base + 4 + 8 * @as(u32, @intCast(i));
            if (r + 8 > base + f.cmap.len) return error.BadFont;
            const pid = try be16(d, r);
            const eid = try be16(d, r + 2);
            const off = try be32(d, r + 4);
            if (off >= f.cmap.len) continue;
            const unicode = pid == 0 or (pid == 3 and (eid == 1 or eid == 10));
            if (!unicode) continue;
            const sub = base + off;
            const fmt = try be16(d, sub);
            if (fmt == 12) best12 = sub;
            if (fmt == 4) best4 = sub;
        }
        if (best12) |sub| {
            const groups = try be32(d, sub + 12);
            if (@as(u64, groups) * 12 + 16 > f.cmap.len) return error.BadFont;
            var lo: u32 = 0;
            var hi: u32 = groups;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const g = sub + 16 + 12 * mid;
                const start = try be32(d, g);
                const end = try be32(d, g + 4);
                if (cp < start) hi = mid else if (cp > end) lo = mid + 1 else {
                    const gid = (try be32(d, g + 8)) +% (cp - start);
                    return if (gid < f.glyphs) @intCast(gid) else 0;
                }
            }
            return 0;
        }
        const sub = best4 orelse return 0;
        if (cp > 0xffff) return 0;
        const c: u16 = @intCast(cp);
        const segs = (try be16(d, sub + 6)) / 2;
        const ends = sub + 14;
        const starts = ends + 2 * @as(u32, segs) + 2;
        const deltas = starts + 2 * @as(u32, segs);
        const ranges = deltas + 2 * @as(u32, segs);
        if (ranges + 2 * @as(u32, segs) > base + f.cmap.len) return error.BadFont;
        var lo: u32 = 0;
        var hi: u32 = segs;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try be16(d, ends + 2 * mid) < c) lo = mid + 1 else hi = mid;
        }
        if (lo >= segs) return 0;
        const start = try be16(d, starts + 2 * lo);
        if (c < start) return 0;
        const delta = try be16(d, deltas + 2 * lo);
        const ro = try be16(d, ranges + 2 * lo);
        if (ro == 0) return checkGlyph(f, c +% delta);
        const at = @as(u64, ranges) + 2 * lo + ro + 2 * @as(u64, c - start);
        if (at + 2 > base + f.cmap.len) return error.BadFont;
        const g = try be16(d, @intCast(at));
        if (g == 0) return 0;
        return checkGlyph(f, g +% delta);
    }

    fn checkGlyph(f: *const Font, g: u16) u16 {
        return if (g < f.glyphs) g else 0;
    }

    /// The advance width of a glyph (font units).
    pub fn advance(f: *const Font, g: u16) u16 {
        const i: u32 = if (g < f.metrics) g else f.metrics - 1;
        return be16(f.data, f.hmtx.off + 4 * i) catch 0;
    }

    /// The kerning of a pair of glyphs (font units, added to the advance
    /// of the left glyph), from the first `kern` subtable of format 0.
    pub fn kerning(f: *const Font, left: u16, right: u16) i16 {
        return f.kernPair(left, right) catch 0;
    }

    fn kernPair(f: *const Font, left: u16, right: u16) error{BadFont}!i16 {
        if (f.kern.len < 18) return 0;
        const d = f.data;
        const base = f.kern.off;
        if (try be16(d, base) != 0) return 0;
        const n = try be16(d, base + 2);
        var sub = base + 4;
        for (0..n) |_| {
            if (sub + 14 > base + f.kern.len) return 0;
            const len = try be16(d, sub + 2);
            const coverage = try be16(d, sub + 4);
            // Format 0, horizontal, not cross-stream, not minimum.
            if (coverage >> 8 == 0 and coverage & 0x7 == 1) {
                const pairs = try be16(d, sub + 6);
                const first = sub + 14;
                if (@as(u64, first) + 6 * @as(u64, pairs) > base + f.kern.len) return error.BadFont;
                const key = (@as(u32, left) << 16) | right;
                var lo: u32 = 0;
                var hi: u32 = pairs;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const k = try be32(d, first + 6 * mid);
                    if (k < key) lo = mid + 1 else if (k > key) hi = mid else return try bei16(d, first + 6 * mid + 4);
                }
                return 0;
            }
            if (len < 6) return 0;
            sub += len;
        }
        return 0;
    }

    fn glyphRange(f: *const Font, g: u16) error{BadFont}![2]u32 {
        if (g >= f.glyphs) return error.BadFont;
        const a: u32 = if (f.long_loca) try be32(f.data, f.loca.off + 4 * @as(u32, g)) else @as(u32, try be16(f.data, f.loca.off + 2 * @as(u32, g))) * 2;
        const b: u32 = if (f.long_loca) try be32(f.data, f.loca.off + 4 * @as(u32, g) + 4) else @as(u32, try be16(f.data, f.loca.off + 2 * @as(u32, g) + 2)) * 2;
        if (b < a or b > f.glyf.len) return error.BadFont;
        return .{ f.glyf.off + a, f.glyf.off + b };
    }

    /// The box of a glyph: x min, y min, x max, y max (font units), or
    /// null for an empty glyph.
    pub fn glyphBox(f: *const Font, g: u16) error{BadFont}!?[4]i16 {
        const r = try f.glyphRange(g);
        if (r[1] - r[0] < 10) return null;
        return .{ try bei16(f.data, r[0] + 2), try bei16(f.data, r[0] + 4), try bei16(f.data, r[0] + 6), try bei16(f.data, r[0] + 8) };
    }

    /// The contours of a glyph, flattened, in font units: the points of
    /// each contour go to `pts`, and the end of each contour to `ends`.
    /// `tol`: the largest distance (font units) between a curve and its
    /// lines (after the matrix of a glyph: in the units of the output). The contours keep the direction of the file: in TrueType,
    /// an outer contour is clockwise (y up).
    pub fn outline(f: *const Font, gpa: Allocator, g: u16, tol: f64, pts: *std.ArrayList([2]f64), ends: *std.ArrayList(u32)) Error!void {
        var budget: usize = max_components;
        try f.addGlyph(gpa, g, .{ 1, 0, 0, 1, 0, 0 }, tol, pts, ends, 0, &budget);
    }

    fn addGlyph(f: *const Font, gpa: Allocator, g: u16, m: [6]f64, tol: f64, pts: *std.ArrayList([2]f64), ends: *std.ArrayList(u32), depth: usize, budget: *usize) Error!void {
        if (depth > max_nesting) return error.BadFont;
        if (budget.* == 0) return error.BadFont;
        budget.* -= 1;
        const d = f.data;
        const r = try f.glyphRange(g);
        if (r[1] - r[0] < 10) return;
        const end = r[1];
        const nc = try bei16(d, r[0]);
        var o = r[0] + 10;
        if (nc >= 0) {
            const n: u32 = @intCast(nc);
            if (o + 2 * n + 2 > end) return error.BadFont;
            const last_end = if (n == 0) 0 else try be16(d, o + 2 * (n - 1));
            const np: u32 = if (n == 0) 0 else @as(u32, last_end) + 1;
            if (np > max_points) return error.BadFont;
            const contour_ends = o;
            o += 2 * n;
            const ilen = try be16(d, o);
            o += 2 + ilen;
            if (o > end) return error.BadFont;
            // The flags, with repeats.
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const flags = try a.alloc(u8, np);
            var i: u32 = 0;
            while (i < np) {
                if (o >= end) return error.BadFont;
                const fl = d[o];
                o += 1;
                flags[i] = fl;
                i += 1;
                if (fl & 8 != 0) {
                    if (o >= end) return error.BadFont;
                    var rep = d[o];
                    o += 1;
                    while (rep > 0 and i < np) : (rep -= 1) {
                        flags[i] = fl;
                        i += 1;
                    }
                }
            }
            const xs = try a.alloc(i32, np);
            const ys = try a.alloc(i32, np);
            inline for (.{ xs, ys }, .{ 2, 4 }, .{ 16, 32 }) |out, short, same| {
                var v: i32 = 0;
                for (out, flags) |*x, fl| {
                    if (fl & short != 0) {
                        if (o >= end) return error.BadFont;
                        const dv: i32 = d[o];
                        o += 1;
                        v += if (fl & same != 0) dv else -dv;
                    } else if (fl & same == 0) {
                        if (o + 2 > end) return error.BadFont;
                        v += try bei16(d, o);
                        o += 2;
                    }
                    x.* = v;
                }
            }
            var first: u32 = 0;
            for (0..n) |ci| {
                const last = try be16(d, contour_ends + 2 * @as(u32, @intCast(ci)));
                if (last < first or last >= np) return error.BadFont;
                try contour(gpa, m, tol, xs[first .. last + 1], ys[first .. last + 1], flags[first .. last + 1], pts, ends);
                first = @as(u32, last) + 1;
            }
            return;
        }
        // A composite glyph.
        while (true) {
            if (o + 4 > end) return error.BadFont;
            const fl = try be16(d, o);
            const sub = try be16(d, o + 2);
            o += 4;
            var dx: f64 = 0;
            var dy: f64 = 0;
            if (fl & 1 != 0) {
                if (o + 4 > end) return error.BadFont;
                dx = @floatFromInt(try bei16(d, o));
                dy = @floatFromInt(try bei16(d, o + 2));
                o += 4;
            } else {
                if (o + 2 > end) return error.BadFont;
                dx = @floatFromInt(@as(i8, @bitCast(d[o])));
                dy = @floatFromInt(@as(i8, @bitCast(d[o + 1])));
                o += 2;
            }
            // Point matching (bit 1 clear) is not read: no offset.
            if (fl & 2 == 0) {
                dx = 0;
                dy = 0;
            }
            var c: [4]f64 = .{ 1, 0, 0, 1 };
            if (fl & 8 != 0) {
                if (o + 2 > end) return error.BadFont;
                const s = f2dot14(try bei16(d, o));
                c = .{ s, 0, 0, s };
                o += 2;
            } else if (fl & 0x40 != 0) {
                if (o + 4 > end) return error.BadFont;
                c = .{ f2dot14(try bei16(d, o)), 0, 0, f2dot14(try bei16(d, o + 2)) };
                o += 4;
            } else if (fl & 0x80 != 0) {
                if (o + 8 > end) return error.BadFont;
                c = .{ f2dot14(try bei16(d, o)), f2dot14(try bei16(d, o + 2)), f2dot14(try bei16(d, o + 4)), f2dot14(try bei16(d, o + 6)) };
                o += 8;
            }
            // The matrix of the component, then the matrix of the glyph:
            // x' = c0 x + c2 y + dx, y' = c1 x + c3 y + dy.
            const mm: [6]f64 = .{
                m[0] * c[0] + m[2] * c[1], m[1] * c[0] + m[3] * c[1],
                m[0] * c[2] + m[2] * c[3], m[1] * c[2] + m[3] * c[3],
                m[0] * dx + m[2] * dy + m[4], m[1] * dx + m[3] * dy + m[5],
            };
            try f.addGlyph(gpa, sub, mm, tol, pts, ends, depth + 1, budget);
            if (fl & 0x20 == 0) break;
        }
    }
};

/// One contour of a simple glyph to lines (see `Font.outline`).
fn contour(gpa: Allocator, m: [6]f64, tol: f64, xs: []const i32, ys: []const i32, flags: []const u8, pts: *std.ArrayList([2]f64), ends: *std.ArrayList(u32)) Allocator.Error!void {
    const n = xs.len;
    if (n < 2) return;
    const P = struct {
        fn at(mm: [6]f64, x: f64, y: f64) [2]f64 {
            return .{ mm[0] * x + mm[2] * y + mm[4], mm[1] * x + mm[3] * y + mm[5] };
        }
    };
    const on = struct {
        fn f(fl: []const u8, i: usize) bool {
            return fl[i] & 1 != 0;
        }
    }.f;
    const pt = struct {
        fn f(x: []const i32, y: []const i32, i: usize) [2]f64 {
            return .{ @floatFromInt(x[i]), @floatFromInt(y[i]) };
        }
    }.f;
    // The first point on the curve: a point on the curve, or the middle of
    // the first two control points.
    var start: [2]f64 = undefined;
    var k0: usize = 0;
    while (k0 < n and !on(flags, k0)) k0 += 1;
    if (k0 == n) {
        const a = pt(xs, ys, 0);
        const b = pt(xs, ys, 1);
        start = .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 };
        k0 = 1;
    } else start = pt(xs, ys, k0);
    const begin = pts.items.len;
    try pts.append(gpa, P.at(m, start[0], start[1]));
    var cur = start;
    var ctrl: ?[2]f64 = null;
    for (1..n + 1) |step| {
        const i = (k0 + step) % n;
        const p = pt(xs, ys, i);
        if (on(flags, i)) {
            if (ctrl) |c| try quad(gpa, m, tol, cur, c, p, pts) else try pts.append(gpa, P.at(m, p[0], p[1]));
            cur = p;
            ctrl = null;
        } else {
            if (ctrl) |c| {
                const mid: [2]f64 = .{ (c[0] + p[0]) / 2, (c[1] + p[1]) / 2 };
                try quad(gpa, m, tol, cur, c, mid, pts);
                cur = mid;
            }
            ctrl = p;
        }
    }
    if (ctrl) |c| try quad(gpa, m, tol, cur, c, start, pts);
    // The last point is the first again.
    if (pts.items.len > begin + 1) {
        const a = pts.items[begin];
        const b = pts.items[pts.items.len - 1];
        if (a[0] == b[0] and a[1] == b[1]) _ = pts.pop();
    }
    if (pts.items.len - begin < 3) {
        pts.shrinkRetainingCapacity(begin);
        return;
    }
    try ends.append(gpa, @intCast(pts.items.len));
}

/// A quadratic curve from p0 (already in `pts`) to p2, as lines. The
/// distance between the curve and a chord of n pieces is at most
/// |p0 - 2 p1 + p2| / (8 n²).
fn quad(gpa: Allocator, m: [6]f64, tol: f64, p0: [2]f64, p1: [2]f64, p2: [2]f64, pts: *std.ArrayList([2]f64)) Allocator.Error!void {
    const ax = p0[0] - 2 * p1[0] + p2[0];
    const ay = p0[1] - 2 * p1[1] + p2[1];
    // The scale of the matrix (its largest column) bounds the error.
    const sc = @max(@sqrt(m[0] * m[0] + m[1] * m[1]), @sqrt(m[2] * m[2] + m[3] * m[3]));
    const dd = @sqrt(ax * ax + ay * ay) * sc;
    const n: usize = @intFromFloat(@min(64, @max(1, @ceil(@sqrt(dd / (8 * @max(tol, 1e-6)))))));
    for (1..n + 1) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        const u = 1 - t;
        const x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0];
        const y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1];
        try pts.append(gpa, .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] });
    }
}

fn f2dot14(v: i16) f64 {
    return @as(f64, @floatFromInt(v)) / 16384.0;
}

fn be16(d: []const u8, o: usize) error{BadFont}!u16 {
    if (o + 2 > d.len) return error.BadFont;
    return std.mem.readInt(u16, d[o..][0..2], .big);
}

fn bei16(d: []const u8, o: usize) error{BadFont}!i16 {
    return @bitCast(try be16(d, o));
}

fn be32(d: []const u8, o: usize) error{BadFont}!u32 {
    if (o + 4 > d.len) return error.BadFont;
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

// ---- text ----

pub const Alignment = enum { left, center, right };

pub const TextOptions = struct {
    /// The height of the capitals (mm).
    size: f64,
    /// The space added after each letter (mm).
    spacing: f64 = 0,
    alignment: Alignment = .center,
    /// The distance from one base line to the next, as a multiple of the
    /// size.
    line_gap: f64 = 1.5,
    /// The largest distance (mm) between a curve and its lines.
    tolerance: f64 = 0.01,
    kerning: bool = true,
};

/// The width of a line of text (mm), from the advances and the kerning.
pub fn lineWidth(f: *const Font, line: []const u8, opts: TextOptions) f64 {
    const scale = opts.size / @as(f64, @floatFromInt(f.cap_height));
    var x: f64 = 0;
    var prev: ?u16 = null;
    var n: usize = 0;
    var it = Utf8.init(line);
    while (it.next()) |cp| {
        const g = f.glyphIndex(cp);
        if (prev) |p| if (opts.kerning) {
            x += @as(f64, @floatFromInt(f.kerning(p, g))) * scale;
        };
        x += @as(f64, @floatFromInt(f.advance(g))) * scale;
        prev = g;
        n += 1;
    }
    if (n > 1) x += opts.spacing * @as(f64, @floatFromInt(n - 1));
    return x;
}

/// The outlines of a text, in the units of geom (mm in the plane of the
/// text, x to the right and y up). The capitals of the first line span y
/// from -size/2 to size/2 for one line; more lines (split at '\n') go
/// down, and the block stays centered on y = 0. The alignment places the
/// lines on x = 0. Outer contours are counterclockwise, holes clockwise.
/// The paths overlap where letters touch: join them with a union.
pub fn text(gpa: Allocator, f: *const Font, txt: []const u8, opts: TextOptions) Error!Paths {
    var out: Paths = .empty;
    errdefer out.deinit(gpa);
    if (!(opts.size > 0)) return out;
    const scale = opts.size / @as(f64, @floatFromInt(f.cap_height));
    var pts: std.ArrayList([2]f64) = .empty;
    defer pts.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    var lines_n: usize = 1;
    for (txt) |c| lines_n += @intFromBool(c == '\n');
    const gap = opts.size * opts.line_gap;
    // The base line of the first line.
    const top = (@as(f64, @floatFromInt(lines_n - 1)) * gap) / 2 - opts.size / 2;
    var lines = std.mem.splitScalar(u8, txt, '\n');
    var li: usize = 0;
    while (lines.next()) |line| : (li += 1) {
        const w = lineWidth(f, line, opts);
        var x: f64 = switch (opts.alignment) {
            .left => 0,
            .center => -w / 2,
            .right => -w,
        };
        const y = top - @as(f64, @floatFromInt(li)) * gap;
        var prev: ?u16 = null;
        var it = Utf8.init(line);
        while (it.next()) |cp| {
            const g = f.glyphIndex(cp);
            if (prev) |p| if (opts.kerning) {
                x += @as(f64, @floatFromInt(f.kerning(p, g))) * scale;
            };
            pts.clearRetainingCapacity();
            ends.clearRetainingCapacity();
            var budget: usize = max_components;
            try f.addGlyph(gpa, g, .{ scale, 0, 0, scale, x, y }, opts.tolerance, &pts, &ends, 0, &budget);
            // The file has clockwise outer contours: reverse each one.
            var s: usize = 0;
            for (ends.items) |e| {
                var k = e;
                while (k > s) {
                    k -= 1;
                    const p = pts.items[k];
                    try out.appendPoint(gpa, .init(geom.fromMm(p[0]), geom.fromMm(p[1])));
                }
                try out.endPath(gpa, 3);
                s = e;
            }
            x += @as(f64, @floatFromInt(f.advance(g))) * scale + opts.spacing;
            prev = g;
        }
    }
    return out;
}

/// The width of the stem of "I" as a share of the cap height. Text of
/// size s has strokes of about s times this value.
pub fn stemRatio(f: *const Font) f64 {
    const box = (f.glyphBox(f.glyphIndex('I')) catch null) orelse return 0.15;
    return @as(f64, @floatFromInt(@as(i32, box[2]) - box[0])) / @as(f64, @floatFromInt(f.cap_height));
}

/// The code points of UTF-8 text. A bad byte gives U+FFFD.
const Utf8 = struct {
    s: []const u8,
    i: usize = 0,
    fn init(s: []const u8) Utf8 {
        return .{ .s = s };
    }
    fn next(u: *Utf8) ?u21 {
        if (u.i >= u.s.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(u.s[u.i]) catch {
            u.i += 1;
            return 0xfffd;
        };
        if (u.i + n > u.s.len) {
            u.i = u.s.len;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(u.s[u.i..][0..n]) catch {
            u.i += 1;
            return 0xfffd;
        };
        u.i += n;
        return cp;
    }
};

const testing = std.testing;

test "font: the embedded font reads" {
    const f = builtin();
    try testing.expectEqual(@as(u16, 2048), f.units_per_em);
    try testing.expectEqual(@as(i16, 1490), f.cap_height);
    try testing.expect(f.glyphIndex('A') != 0);
    try testing.expect(f.glyphIndex(0xe9) != 0); // é
    try testing.expectEqual(@as(u16, 0), f.glyphIndex(0x4e2d)); // not in the subset
}

test "font: the advance of AV with and without kerning" {
    const f = builtin();
    const with = lineWidth(&f, "AV", .{ .size = 10 });
    const without = lineWidth(&f, "AV", .{ .size = 10, .kerning = false });
    // A and V are 1529 units wide, and the pair is -162 (from the GPOS of
    // the font, see tools/font_subset.py); the cap height is 1490.
    try testing.expectApproxEqAbs(2.0 * 1529.0 * 10.0 / 1490.0, without, 1e-9);
    try testing.expectApproxEqAbs((2.0 * 1529.0 - 162.0) * 10.0 / 1490.0, with, 1e-9);
}

test "font: the O has a clockwise hole, and the cap height is the size" {
    const gpa = testing.allocator;
    const f = builtin();
    var o = try text(gpa, &f, "O", .{ .size = 10 });
    defer o.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), o.count());
    var outer: f64 = 0;
    var hole: f64 = 0;
    for (0..2) |i| {
        const a = geom.areaMm2(o.get(i));
        if (a > 0) outer = a else hole = a;
    }
    try testing.expect(outer > 0 and hole < 0);
    // The counter of a bold O: 77.0 mm² outside, 27.8 mm² of hole.
    try testing.expect(hole < -0.2 * outer and hole > -0.5 * outer);
    var h = try text(gpa, &f, "H", .{ .size = 10 });
    defer h.deinit(gpa);
    const b = h.bounds();
    try testing.expectApproxEqAbs(@as(f64, 10), geom.toMm(b.max.y - b.min.y), 0.002);
    try testing.expectApproxEqAbs(@as(f64, -5), geom.toMm(b.min.y), 0.002);
    // The stem of I: 305 of 1490 units.
    try testing.expectApproxEqAbs(305.0 / 1490.0, stemRatio(&f), 1e-9);
}

test "font: the curves are within the tolerance" {
    const gpa = testing.allocator;
    const f = builtin();
    // The O at 40 mm: each point of the outer contour lies on the curve;
    // the middle of each line is within 0.01 mm of it. A finer tolerance
    // gives about the same area.
    var a = try text(gpa, &f, "O", .{ .size = 40, .tolerance = 0.01 });
    defer a.deinit(gpa);
    var b = try text(gpa, &f, "O", .{ .size = 40, .tolerance = 0.0005 });
    defer b.deinit(gpa);
    const pa = a.areaMm2();
    const pb = b.areaMm2();
    // The length of the outline is about 300 mm: 0.01 mm of chord error
    // on it is less than 2 mm².
    try testing.expect(@abs(pa - pb) < 2);
    try testing.expect(b.points.items.len > a.points.items.len);
}

test "font: a bad file fails cleanly" {
    try testing.expectError(error.BadFont, Font.init(""));
    try testing.expectError(error.BadFont, Font.init(inter_bold[0..200]));
    var buf: [64]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, buf[4..6], 3, .big);
    try testing.expectError(error.BadFont, Font.init(&buf));
}
