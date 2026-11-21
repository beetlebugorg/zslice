//! The filled shapes of an SVG picture as polygons, for a label (see
//! label.zig, the shape `svg`).
//!
//! The reader walks the tags of the file. It keeps a stack of the state
//! of the groups: the transform, the fill, the fill rule, and the stroke.
//! Each shape element (path, rect, circle, ellipse, polygon, polyline,
//! line) gives closed polygons in the frame of the picture:
//!
//! - The path data (M L H V C S Q T A Z, absolute and relative) goes into
//!   lines. A curve gets as many lines as its bend needs: the distance
//!   between the curve and its lines stays under the tolerance. An arc
//!   goes from its end points to its center (SVG 1.1, appendix F.6.5),
//!   then into lines.
//! - The polygons of one element join with its fill rule (nonzero or
//!   evenodd). A stroke with no fill becomes an outline: a rectangle for
//!   each segment and a disk at each joint.
//! - The tags in defs, clipPath, mask, symbol, pattern, marker, style,
//!   text, and the gradients have no fill. The reader skips them.
//!
//! All elements then join (nonzero). The result is centered on its box,
//! with y up, and scaled to the height that the caller asks for. The
//! reader makes lines in two passes: a coarse pass finds the scale, then
//! the curves go into lines at the tolerance in mm.
//!
//! References (see docs/references/formats-and-protocols.md): SVG 1.1
//! (W3C), the path data, the basic shapes, the transforms, the fill
//! rules, and the arc conversion.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const clip = @import("clip.zig");
const Paths = geom.Paths;

pub const Error = error{BadSvg} || Allocator.Error;

/// The largest count of points of one picture.
pub const max_points = 200_000;

pub const Options = struct {
    /// The height of the result (mm). 0: the size of the picture in its
    /// units, as mm.
    height: f64 = 10,
    /// The largest distance (mm) between a curve and its lines.
    tolerance: f64 = 0.01,
};

/// x' = a x + c y + e, y' = b x + d y + f.
const Matrix = [6]f64;
const identity: Matrix = .{ 1, 0, 0, 1, 0, 0 };

/// m after n: the point goes through n first.
fn mul(m: Matrix, n: Matrix) Matrix {
    return .{
        m[0] * n[0] + m[2] * n[1],
        m[1] * n[0] + m[3] * n[1],
        m[0] * n[2] + m[2] * n[3],
        m[1] * n[2] + m[3] * n[3],
        m[0] * n[4] + m[2] * n[5] + m[4],
        m[1] * n[4] + m[3] * n[5] + m[5],
    };
}

fn apply(m: Matrix, p: [2]f64) [2]f64 {
    return .{ m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5] };
}

/// The scale of a matrix: the root of the size of its area change.
fn scaleOf(m: Matrix) f64 {
    return @sqrt(@abs(m[0] * m[3] - m[1] * m[2]));
}

const Style = struct {
    m: Matrix = identity,
    fill: bool = true,
    evenodd: bool = false,
    stroke: bool = false,
    stroke_width: f64 = 1,
    hidden: bool = false,
};

/// The lines of the elements, in the frame of the picture.
const Sink = struct {
    gpa: Allocator,
    /// The tolerance in the units of the picture (before each transform).
    tol: f64,
    /// The polygons of the fill of each element.
    fill: std.ArrayList([2]f64) = .empty,
    fill_ends: std.ArrayList(u32) = .empty,
    /// For each element: the end of its polygons, and its rule.
    groups: std.ArrayList(struct { end: u32, evenodd: bool }) = .empty,
    /// The open or closed lines of the strokes, and their widths.
    stroke: std.ArrayList([2]f64) = .empty,
    stroke_ends: std.ArrayList(struct { end: u32, closed: bool, width: f64 }) = .empty,
    points: usize = 0,

    fn deinit(s: *Sink) void {
        s.fill.deinit(s.gpa);
        s.fill_ends.deinit(s.gpa);
        s.groups.deinit(s.gpa);
        s.stroke.deinit(s.gpa);
        s.stroke_ends.deinit(s.gpa);
    }
};

/// The lines of one element, in its own frame, then out through its
/// transform.
const Element = struct {
    sink: *Sink,
    st: Style,
    /// The points of the subpath that draws now.
    pts: std.ArrayList([2]f64) = .empty,
    closed: bool = false,
    /// The tolerance in the frame of the element.
    tol: f64,

    fn init(sink: *Sink, st: Style) Element {
        return .{ .sink = sink, .st = st, .tol = sink.tol / @max(scaleOf(st.m), 1e-12) };
    }

    fn deinit(e: *Element) void {
        e.pts.deinit(e.sink.gpa);
    }

    fn point(e: *Element, p: [2]f64) Error!void {
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return error.BadSvg;
        if (e.pts.items.len > 0) {
            const q = e.pts.items[e.pts.items.len - 1];
            if (q[0] == p[0] and q[1] == p[1]) return;
        }
        e.sink.points += 1;
        if (e.sink.points > max_points) return error.BadSvg;
        try e.pts.append(e.sink.gpa, p);
    }

    /// Ends the subpath: into the fill and the stroke of the element.
    fn endSub(e: *Element) Error!void {
        defer {
            e.pts.clearRetainingCapacity();
            e.closed = false;
        }
        const s = e.sink;
        const pts = e.pts.items;
        if (pts.len < 2) return;
        if (e.st.fill and pts.len >= 3) {
            for (pts) |p| try s.fill.append(s.gpa, apply(e.st.m, p));
            try s.fill_ends.append(s.gpa, @intCast(s.fill.items.len));
        }
        if (e.st.stroke and e.st.stroke_width > 0) {
            for (pts) |p| try s.stroke.append(s.gpa, apply(e.st.m, p));
            try s.stroke_ends.append(s.gpa, .{ .end = @intCast(s.stroke.items.len), .closed = e.closed, .width = e.st.stroke_width * scaleOf(e.st.m) });
        }
    }

    /// Ends the element: its polygons join with its rule.
    fn finish(e: *Element) Error!void {
        try e.endSub();
        const s = e.sink;
        const end: u32 = @intCast(s.fill_ends.items.len);
        const last: u32 = if (s.groups.items.len > 0) s.groups.items[s.groups.items.len - 1].end else 0;
        if (end > last) try s.groups.append(s.gpa, .{ .end = end, .evenodd = e.st.evenodd });
    }

    /// The count of lines for a curve whose bend is `bend` (the largest
    /// second difference of its points) at the tolerance.
    fn steps(e: *const Element, bend: f64) usize {
        if (!std.math.isFinite(e.tol)) return 4;
        if (!(bend > 0)) return 1;
        const n = @ceil(@sqrt(bend / (8 * e.tol)));
        return @intFromFloat(std.math.clamp(n, 1, 1000));
    }

    fn quad(e: *Element, p0: [2]f64, p1: [2]f64, p2: [2]f64) Error!void {
        const bend = 2 * std.math.hypot(p0[0] - 2 * p1[0] + p2[0], p0[1] - 2 * p1[1] + p2[1]);
        const n = e.steps(bend);
        for (1..n + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const u = 1 - t;
            try e.point(.{ u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1] });
        }
    }

    fn cubic(e: *Element, p0: [2]f64, p1: [2]f64, p2: [2]f64, p3: [2]f64) Error!void {
        const b1 = std.math.hypot(p0[0] - 2 * p1[0] + p2[0], p0[1] - 2 * p1[1] + p2[1]);
        const b2 = std.math.hypot(p1[0] - 2 * p2[0] + p3[0], p1[1] - 2 * p2[1] + p3[1]);
        const n = e.steps(6 * @max(b1, b2));
        for (1..n + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const u = 1 - t;
            const a = u * u * u;
            const b = 3 * u * u * t;
            const c = 3 * u * t * t;
            const d = t * t * t;
            try e.point(.{ a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1] });
        }
    }

    /// An arc of an ellipse from p0 to p1 (SVG 1.1, appendix F.6.5: from
    /// the end points to the center).
    fn arc(e: *Element, p0: [2]f64, rx_in: f64, ry_in: f64, angle: f64, large: bool, sweep: bool, p1: [2]f64) Error!void {
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (p0[0] == p1[0] and p0[1] == p1[1]) return;
        if (rx == 0 or ry == 0) return e.point(p1);
        const phi = std.math.degreesToRadians(angle);
        const cp = @cos(phi);
        const sp = @sin(phi);
        // Step 1: the middle point in the frame of the ellipse.
        const dx = (p0[0] - p1[0]) / 2;
        const dy = (p0[1] - p1[1]) / 2;
        const x1 = cp * dx + sp * dy;
        const y1 = -sp * dx + cp * dy;
        // Radii too small: they grow (F.6.6).
        const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lam > 1) {
            const k = @sqrt(lam);
            rx *= k;
            ry *= k;
        }
        // Step 2: the center in the frame of the ellipse.
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var co = @sqrt(@max(0, num / den));
        if (large == sweep) co = -co;
        const cx1 = co * rx * y1 / ry;
        const cy1 = -co * ry * x1 / rx;
        // Step 3: the center.
        const cx = cp * cx1 - sp * cy1 + (p0[0] + p1[0]) / 2;
        const cy = sp * cx1 + cp * cy1 + (p0[1] + p1[1]) / 2;
        // Step 4: the start angle and the sweep.
        const t1 = std.math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
        var dt = std.math.atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - t1;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        const r = @max(rx, ry);
        const step = if (e.tol < r) 2 * std.math.acos(1 - e.tol / r) else std.math.pi / 2.0;
        const n: usize = @intFromFloat(std.math.clamp(@ceil(@abs(dt) / step), 1, 1000));
        for (1..n + 1) |k| {
            if (k == n) return e.point(p1);
            const t = t1 + dt * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const ex = rx * @cos(t);
            const ey = ry * @sin(t);
            try e.point(.{ cp * ex - sp * ey + cx, sp * ex + cp * ey + cy });
        }
    }

    /// A full ellipse as a closed subpath.
    fn ellipse(e: *Element, cx: f64, cy: f64, rx: f64, ry: f64) Error!void {
        if (!(rx > 0) or !(ry > 0)) return;
        try e.point(.{ cx + rx, cy });
        try e.arc(.{ cx + rx, cy }, rx, ry, 0, false, true, .{ cx - rx, cy });
        try e.arc(.{ cx - rx, cy }, rx, ry, 0, false, true, .{ cx + rx, cy });
        e.closed = true;
        try e.endSub();
    }
};

// ---- the path data ----

const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(sc: *Scanner) void {
        while (sc.i < sc.s.len and (std.ascii.isWhitespace(sc.s[sc.i]) or sc.s[sc.i] == ',')) sc.i += 1;
    }

    fn atNumber(sc: *Scanner) bool {
        sc.skipSep();
        if (sc.i >= sc.s.len) return false;
        const c = sc.s[sc.i];
        return std.ascii.isDigit(c) or c == '-' or c == '+' or c == '.';
    }

    fn number(sc: *Scanner) Error!f64 {
        sc.skipSep();
        const start = sc.i;
        if (sc.i < sc.s.len and (sc.s[sc.i] == '-' or sc.s[sc.i] == '+')) sc.i += 1;
        var digits = false;
        while (sc.i < sc.s.len and std.ascii.isDigit(sc.s[sc.i])) : (sc.i += 1) digits = true;
        if (sc.i < sc.s.len and sc.s[sc.i] == '.') {
            sc.i += 1;
            while (sc.i < sc.s.len and std.ascii.isDigit(sc.s[sc.i])) : (sc.i += 1) digits = true;
        }
        if (!digits) return error.BadSvg;
        if (sc.i < sc.s.len and (sc.s[sc.i] == 'e' or sc.s[sc.i] == 'E')) {
            var j = sc.i + 1;
            if (j < sc.s.len and (sc.s[j] == '-' or sc.s[j] == '+')) j += 1;
            if (j < sc.s.len and std.ascii.isDigit(sc.s[j])) {
                sc.i = j;
                while (sc.i < sc.s.len and std.ascii.isDigit(sc.s[sc.i])) sc.i += 1;
            }
        }
        const x = std.fmt.parseFloat(f64, sc.s[start..sc.i]) catch return error.BadSvg;
        if (!std.math.isFinite(x)) return error.BadSvg;
        return x;
    }

    /// An arc flag: one digit 0 or 1 (it can touch the next number).
    fn flag(sc: *Scanner) Error!bool {
        sc.skipSep();
        if (sc.i >= sc.s.len) return error.BadSvg;
        const c = sc.s[sc.i];
        if (c != '0' and c != '1') return error.BadSvg;
        sc.i += 1;
        return c == '1';
    }
};

fn pathData(e: *Element, d: []const u8) Error!void {
    var sc: Scanner = .{ .s = d };
    var cur: [2]f64 = .{ 0, 0 };
    var start: [2]f64 = .{ 0, 0 };
    // The last control point, for S and T.
    var ctrl: [2]f64 = .{ 0, 0 };
    var prev: u8 = 0;
    var cmd: u8 = 0;
    while (true) {
        sc.skipSep();
        if (sc.i >= sc.s.len) break;
        const c = sc.s[sc.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            sc.i += 1;
        } else if (cmd == 0) {
            return error.BadSvg;
        } else if (cmd == 'Z' or cmd == 'z') {
            return error.BadSvg;
        }
        const rel = std.ascii.isLower(cmd);
        const o: [2]f64 = if (rel) cur else .{ 0, 0 };
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                try e.endSub();
                const x = try sc.number();
                const y = try sc.number();
                cur = .{ o[0] + x, o[1] + y };
                start = cur;
                try e.point(cur);
                // Pairs after a move are lines.
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                const x = try sc.number();
                const y = try sc.number();
                cur = .{ o[0] + x, o[1] + y };
                try e.point(cur);
            },
            'H' => {
                const x = try sc.number();
                cur = .{ if (rel) cur[0] + x else x, cur[1] };
                try e.point(cur);
            },
            'V' => {
                const y = try sc.number();
                cur = .{ cur[0], if (rel) cur[1] + y else y };
                try e.point(cur);
            },
            'C' => {
                var v: [6]f64 = undefined;
                for (&v) |*x| x.* = try sc.number();
                const p1: [2]f64 = .{ o[0] + v[0], o[1] + v[1] };
                const p2: [2]f64 = .{ o[0] + v[2], o[1] + v[3] };
                const p3: [2]f64 = .{ o[0] + v[4], o[1] + v[5] };
                try e.cubic(cur, p1, p2, p3);
                ctrl = p2;
                cur = p3;
            },
            'S' => {
                var v: [4]f64 = undefined;
                for (&v) |*x| x.* = try sc.number();
                const pu = std.ascii.toUpper(prev);
                const p1: [2]f64 = if (pu == 'C' or pu == 'S') .{ 2 * cur[0] - ctrl[0], 2 * cur[1] - ctrl[1] } else cur;
                const p2: [2]f64 = .{ o[0] + v[0], o[1] + v[1] };
                const p3: [2]f64 = .{ o[0] + v[2], o[1] + v[3] };
                try e.cubic(cur, p1, p2, p3);
                ctrl = p2;
                cur = p3;
            },
            'Q' => {
                var v: [4]f64 = undefined;
                for (&v) |*x| x.* = try sc.number();
                const p1: [2]f64 = .{ o[0] + v[0], o[1] + v[1] };
                const p2: [2]f64 = .{ o[0] + v[2], o[1] + v[3] };
                try e.quad(cur, p1, p2);
                ctrl = p1;
                cur = p2;
            },
            'T' => {
                const x = try sc.number();
                const y = try sc.number();
                const pu = std.ascii.toUpper(prev);
                const p1: [2]f64 = if (pu == 'Q' or pu == 'T') .{ 2 * cur[0] - ctrl[0], 2 * cur[1] - ctrl[1] } else cur;
                const p2: [2]f64 = .{ o[0] + x, o[1] + y };
                try e.quad(cur, p1, p2);
                ctrl = p1;
                cur = p2;
            },
            'A' => {
                const rx = try sc.number();
                const ry = try sc.number();
                const ang = try sc.number();
                const large = try sc.flag();
                const sw = try sc.flag();
                const x = try sc.number();
                const y = try sc.number();
                const p1: [2]f64 = .{ o[0] + x, o[1] + y };
                try e.arc(cur, rx, ry, ang, large, sw, p1);
                cur = p1;
            },
            'Z' => {
                e.closed = true;
                try e.endSub();
                cur = start;
                // A path can go on from the start without a move.
                try e.point(cur);
            },
            else => return error.BadSvg,
        }
        prev = cmd;
    }
    try e.endSub();
}

// ---- the attributes ----

const Attr = struct { name: []const u8, value: []const u8 };

/// The attributes of a tag (between the name and '>').
fn attrs(gpa: Allocator, body: []const u8, out: *std.ArrayList(Attr)) Error!void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < body.len) {
        while (i < body.len and (std.ascii.isWhitespace(body[i]) or body[i] == '/')) i += 1;
        const ns = i;
        while (i < body.len and body[i] != '=' and !std.ascii.isWhitespace(body[i]) and body[i] != '/') i += 1;
        const name = body[ns..i];
        while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
        if (i >= body.len or body[i] != '=') {
            if (name.len == 0) i += 1;
            continue;
        }
        i += 1;
        while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
        if (i >= body.len) break;
        const q = body[i];
        if (q != '"' and q != '\'') return error.BadSvg;
        const vs = i + 1;
        const ve = std.mem.indexOfScalarPos(u8, body, vs, q) orelse return error.BadSvg;
        try out.append(gpa, .{ .name = name, .value = body[vs..ve] });
        i = ve + 1;
    }
}

fn get(list: []const Attr, name: []const u8) ?[]const u8 {
    for (list) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
    return null;
}

/// A length: a number with a unit or none (the unit is dropped: the
/// picture scales to its height). A bad value: `def`.
fn length(v: ?[]const u8, def: f64) f64 {
    const s = std.mem.trim(u8, v orelse return def, " \t\r\n");
    var sc: Scanner = .{ .s = s };
    const x = sc.number() catch return def;
    if (sc.i < s.len and s[sc.i] == '%') return def;
    return x;
}

/// The value of a property: from the style attribute, else from its own
/// attribute.
fn prop(list: []const Attr, name: []const u8) ?[]const u8 {
    if (get(list, "style")) |style| {
        var it = std.mem.splitScalar(u8, style, ';');
        while (it.next()) |decl| {
            const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
            const k = std.mem.trim(u8, decl[0..colon], " \t\r\n");
            if (std.mem.eql(u8, k, name)) return std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        }
    }
    if (get(list, name)) |v| return std.mem.trim(u8, v, " \t\r\n");
    return null;
}

fn isNone(v: []const u8) bool {
    return std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "transparent");
}

/// The style of an element in the style of its group.
fn styleOf(parent: Style, list: []const Attr) Error!Style {
    var st = parent;
    if (get(list, "transform")) |t| st.m = mul(st.m, try transform(t));
    if (prop(list, "fill")) |v| {
        if (!std.mem.eql(u8, v, "inherit")) st.fill = !isNone(v);
    }
    if (prop(list, "fill-rule")) |v| {
        if (std.mem.eql(u8, v, "evenodd")) st.evenodd = true;
        if (std.mem.eql(u8, v, "nonzero")) st.evenodd = false;
    }
    if (prop(list, "stroke")) |v| {
        if (!std.mem.eql(u8, v, "inherit")) st.stroke = !isNone(v);
    }
    if (prop(list, "stroke-width")) |v| st.stroke_width = @max(0, length(v, 1));
    if (prop(list, "display")) |v| if (std.mem.eql(u8, v, "none")) {
        st.hidden = true;
    };
    if (prop(list, "visibility")) |v| if (std.mem.eql(u8, v, "hidden")) {
        st.hidden = true;
    };
    return st;
}

/// A transform list: matrix, translate, scale, rotate, skewX, skewY.
fn transform(s: []const u8) Error!Matrix {
    var m = identity;
    var i: usize = 0;
    while (true) {
        while (i < s.len and (std.ascii.isWhitespace(s[i]) or s[i] == ',')) i += 1;
        if (i >= s.len) break;
        const ns = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        const name = s[ns..i];
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len or s[i] != '(') return error.BadSvg;
        const close = std.mem.indexOfScalarPos(u8, s, i, ')') orelse return error.BadSvg;
        var sc: Scanner = .{ .s = s[i + 1 .. close] };
        var v: [6]f64 = undefined;
        var n: usize = 0;
        while (sc.atNumber()) {
            if (n == 6) return error.BadSvg;
            v[n] = try sc.number();
            n += 1;
        }
        i = close + 1;
        const t: Matrix = if (std.mem.eql(u8, name, "matrix")) blk: {
            if (n != 6) return error.BadSvg;
            break :blk v;
        } else if (std.mem.eql(u8, name, "translate")) blk: {
            if (n < 1 or n > 2) return error.BadSvg;
            break :blk .{ 1, 0, 0, 1, v[0], if (n == 2) v[1] else 0 };
        } else if (std.mem.eql(u8, name, "scale")) blk: {
            if (n < 1 or n > 2) return error.BadSvg;
            break :blk .{ v[0], 0, 0, if (n == 2) v[1] else v[0], 0, 0 };
        } else if (std.mem.eql(u8, name, "rotate")) blk: {
            if (n != 1 and n != 3) return error.BadSvg;
            const a = std.math.degreesToRadians(v[0]);
            const r: Matrix = .{ @cos(a), @sin(a), -@sin(a), @cos(a), 0, 0 };
            if (n == 1) break :blk r;
            break :blk mul(mul(.{ 1, 0, 0, 1, v[1], v[2] }, r), .{ 1, 0, 0, 1, -v[1], -v[2] });
        } else if (std.mem.eql(u8, name, "skewX")) blk: {
            if (n != 1) return error.BadSvg;
            break :blk .{ 1, 0, @tan(std.math.degreesToRadians(v[0])), 1, 0, 0 };
        } else if (std.mem.eql(u8, name, "skewY")) blk: {
            if (n != 1) return error.BadSvg;
            break :blk .{ 1, @tan(std.math.degreesToRadians(v[0])), 0, 1, 0, 0 };
        } else return error.BadSvg;
        m = mul(m, t);
    }
    return m;
}

/// The tags whose content has no fill.
const skipped = [_][]const u8{ "defs", "clipPath", "mask", "symbol", "pattern", "marker", "style", "script", "title", "desc", "metadata", "text", "linearGradient", "radialGradient", "filter", "foreignObject" };

fn isSkipped(name: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// The local name of a tag (no namespace prefix).
fn localName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |k| name[k + 1 ..] else name;
}

/// One shape element into the sink.
fn shape(sink: *Sink, name: []const u8, st: Style, list: []const Attr) Error!void {
    if (st.hidden) return;
    var e = Element.init(sink, st);
    defer e.deinit();
    if (std.mem.eql(u8, name, "path")) {
        try pathData(&e, get(list, "d") orelse return);
    } else if (std.mem.eql(u8, name, "rect")) {
        const x = length(get(list, "x"), 0);
        const y = length(get(list, "y"), 0);
        const w = length(get(list, "width"), 0);
        const h = length(get(list, "height"), 0);
        if (!(w > 0) or !(h > 0)) return;
        var rx = length(get(list, "rx"), -1);
        var ry = length(get(list, "ry"), -1);
        if (rx < 0 and ry < 0) {
            rx = 0;
            ry = 0;
        } else if (rx < 0) rx = ry else if (ry < 0) ry = rx;
        rx = @min(rx, w / 2);
        ry = @min(ry, h / 2);
        if (rx > 0 and ry > 0) {
            try e.point(.{ x + rx, y });
            try e.point(.{ x + w - rx, y });
            try e.arc(.{ x + w - rx, y }, rx, ry, 0, false, true, .{ x + w, y + ry });
            try e.point(.{ x + w, y + h - ry });
            try e.arc(.{ x + w, y + h - ry }, rx, ry, 0, false, true, .{ x + w - rx, y + h });
            try e.point(.{ x + rx, y + h });
            try e.arc(.{ x + rx, y + h }, rx, ry, 0, false, true, .{ x, y + h - ry });
            try e.point(.{ x, y + ry });
            try e.arc(.{ x, y + ry }, rx, ry, 0, false, true, .{ x + rx, y });
        } else {
            try e.point(.{ x, y });
            try e.point(.{ x + w, y });
            try e.point(.{ x + w, y + h });
            try e.point(.{ x, y + h });
        }
        e.closed = true;
    } else if (std.mem.eql(u8, name, "circle")) {
        const r = length(get(list, "r"), 0);
        try e.ellipse(length(get(list, "cx"), 0), length(get(list, "cy"), 0), r, r);
    } else if (std.mem.eql(u8, name, "ellipse")) {
        try e.ellipse(length(get(list, "cx"), 0), length(get(list, "cy"), 0), length(get(list, "rx"), 0), length(get(list, "ry"), 0));
    } else if (std.mem.eql(u8, name, "polygon") or std.mem.eql(u8, name, "polyline")) {
        var sc: Scanner = .{ .s = get(list, "points") orelse return };
        while (sc.atNumber()) {
            const x = try sc.number();
            const y = try sc.number();
            try e.point(.{ x, y });
        }
        e.closed = name[4] == 'g';
        // A polyline fills as a closed polygon too (SVG 1.1, 9.7).
    } else if (std.mem.eql(u8, name, "line")) {
        // A line has no area: only its stroke draws.
        e.st.fill = false;
        try e.point(.{ length(get(list, "x1"), 0), length(get(list, "y1"), 0) });
        try e.point(.{ length(get(list, "x2"), 0), length(get(list, "y2"), 0) });
    } else return;
    try e.finish();
}

/// Reads the tags of `src` into the sink.
fn walk(gpa: Allocator, src: []const u8, sink: *Sink) Error!void {
    var stack: std.ArrayList(Style) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{});
    var list: std.ArrayList(Attr) = .empty;
    defer list.deinit(gpa);
    // The depth of the open tags in a skipped tag (0: none).
    var skip: usize = 0;
    var any_svg = false;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, src, i, '<')) |lt| {
        const rest = src[lt..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            i = (std.mem.indexOfPos(u8, src, lt + 4, "-->") orelse return error.BadSvg) + 3;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            i = (std.mem.indexOfPos(u8, src, lt, "]]>") orelse return error.BadSvg) + 3;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            i = (std.mem.indexOfPos(u8, src, lt, "?>") orelse return error.BadSvg) + 2;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<!")) {
            i = (std.mem.indexOfScalarPos(u8, src, lt, '>') orelse return error.BadSvg) + 1;
            continue;
        }
        // The end of the tag: the first '>' out of quotes.
        var j = lt + 1;
        var q: u8 = 0;
        while (j < src.len) : (j += 1) {
            const c = src[j];
            if (q != 0) {
                if (c == q) q = 0;
            } else if (c == '"' or c == '\'') q = c else if (c == '>') break;
        }
        if (j >= src.len) return error.BadSvg;
        i = j + 1;
        const tag = src[lt + 1 .. j];
        if (tag.len > 0 and tag[0] == '/') {
            if (skip > 0) skip -= 1 else if (stack.items.len > 1) _ = stack.pop();
            continue;
        }
        const self_close = tag.len > 0 and tag[tag.len - 1] == '/';
        var ne: usize = 0;
        while (ne < tag.len and !std.ascii.isWhitespace(tag[ne]) and tag[ne] != '/') ne += 1;
        const name = localName(tag[0..ne]);
        if (skip > 0) {
            if (!self_close) skip += 1;
            continue;
        }
        if (isSkipped(name)) {
            if (!self_close) skip = 1;
            continue;
        }
        if (std.mem.eql(u8, name, "svg")) any_svg = true;
        try attrs(gpa, tag[ne..], &list);
        const st = try styleOf(stack.items[stack.items.len - 1], list.items);
        try shape(sink, name, st, list.items);
        if (!self_close) try stack.append(gpa, st);
    }
    if (!any_svg) return error.BadSvg;
}

/// The lines of the picture at a tolerance in its units.
fn collect(gpa: Allocator, src: []const u8, tol: f64) Error!Sink {
    var sink: Sink = .{ .gpa = gpa, .tol = tol };
    errdefer sink.deinit();
    try walk(gpa, src, &sink);
    return sink;
}

fn boxOf(sink: *const Sink) ?[4]f64 {
    var b: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (sink.fill.items) |p| {
        b = .{ @min(b[0], p[0]), @min(b[1], p[1]), @max(b[2], p[0]), @max(b[3], p[1]) };
    }
    var start: usize = 0;
    for (sink.stroke_ends.items) |se| {
        const r = se.width / 2;
        for (sink.stroke.items[start..se.end]) |p| {
            b = .{ @min(b[0], p[0] - r), @min(b[1], p[1] - r), @max(b[2], p[0] + r), @max(b[3], p[1] + r) };
        }
        start = se.end;
    }
    if (!(b[0] <= b[2])) return null;
    return b;
}

/// The filled area of an SVG picture: polygons in the units of geom, with
/// y up, centered on the box of the picture, and `opts.height` tall.
/// Outer paths counterclockwise, holes clockwise. error.BadSvg: no SVG
/// root, a bad number or path, or no area.
pub fn outline(gpa: Allocator, src: []const u8, opts: Options) Error!Paths {
    // Pass 1: the box at a coarse tolerance.
    var coarse = try collect(gpa, src, std.math.inf(f64));
    const b0 = boxOf(&coarse) orelse {
        coarse.deinit();
        return error.BadSvg;
    };
    coarse.deinit();
    const h0 = @max(b0[3] - b0[1], (b0[2] - b0[0]) * 1e-3);
    if (!(h0 > 0)) return error.BadSvg;
    const k0 = if (opts.height > 0) opts.height / h0 else 1;
    // Pass 2: the lines at the tolerance.
    var sink = try collect(gpa, src, opts.tolerance / k0);
    defer sink.deinit();
    const b = boxOf(&sink) orelse return error.BadSvg;
    const h = @max(b[3] - b[1], (b[2] - b[0]) * 1e-3);
    const k = if (opts.height > 0) opts.height / h else 1;
    const cx = (b[0] + b[2]) / 2;
    const cy = (b[1] + b[3]) / 2;
    const P = struct {
        fn of(p: [2]f64, kk: f64, x0: f64, y0: f64) geom.Point {
            // y down in the picture: y up in the plane.
            return .init(geom.fromMm((p[0] - x0) * kk), geom.fromMm(-(p[1] - y0) * kk));
        }
    };
    var all: Paths = .empty;
    defer all.deinit(gpa);
    // The fill of each element, with its rule.
    var g0: u32 = 0;
    for (sink.groups.items) |g| {
        var part: Paths = .empty;
        defer part.deinit(gpa);
        for (g0..g.end) |pi| {
            const s0: usize = if (pi == 0) 0 else sink.fill_ends.items[pi - 1];
            for (sink.fill.items[s0..sink.fill_ends.items[pi]]) |p| try part.appendPoint(gpa, P.of(p, k, cx, cy));
            try part.endPath(gpa, 3);
        }
        g0 = g.end;
        var u = try clip.unionAll(gpa, part, if (g.evenodd) .even_odd else .non_zero);
        defer u.deinit(gpa);
        try all.appendAll(gpa, u);
    }
    // The strokes: a rectangle for each segment, a disk at each joint.
    var start: usize = 0;
    for (sink.stroke_ends.items) |se| {
        const pts = sink.stroke.items[start..se.end];
        start = se.end;
        const w = se.width * k;
        if (!(w > 0) or pts.len < 2) continue;
        const segs = if (se.closed) pts.len else pts.len - 1;
        for (0..segs) |si| {
            const a = pts[si];
            const c = pts[(si + 1) % pts.len];
            const dx = (c[0] - a[0]) * k;
            const dy = -(c[1] - a[1]) * k;
            const l = std.math.hypot(dx, dy);
            if (!(l > 0)) continue;
            const nx = -dy / l * w / 2;
            const ny = dx / l * w / 2;
            const pa = P.of(a, k, cx, cy);
            const pc = P.of(c, k, cx, cy);
            const ox = geom.fromMm(nx);
            const oy = geom.fromMm(ny);
            try all.append(gpa, &.{ .init(pa.x - ox, pa.y - oy), .init(pc.x - ox, pc.y - oy), .init(pc.x + ox, pc.y + oy), .init(pa.x + ox, pa.y + oy) });
        }
        for (pts, 0..) |p, pi| {
            if (!se.closed and (pi == 0 or pi == pts.len - 1)) continue;
            const c = P.of(p, k, cx, cy);
            const r = w / 2;
            const n: usize = 16;
            for (0..n) |m| {
                const t = 2 * std.math.pi * @as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(n));
                try all.appendPoint(gpa, .init(c.x + geom.fromMm(r * @cos(t)), c.y + geom.fromMm(r * @sin(t))));
            }
            try all.endPath(gpa, 3);
        }
    }
    if (all.isEmpty()) return error.BadSvg;
    const out = try clip.unionAll(gpa, all, .non_zero);
    if (out.isEmpty()) return error.BadSvg;
    return out;
}

// ---- tests ----

const testing = std.testing;

fn areaOf(src: []const u8, height: f64) !f64 {
    var p = try outline(testing.allocator, src, .{ .height = height, .tolerance = 0.001 });
    defer p.deinit(testing.allocator);
    return p.areaMm2();
}

fn boxMm(src: []const u8, height: f64) ![4]f64 {
    var p = try outline(testing.allocator, src, .{ .height = height });
    defer p.deinit(testing.allocator);
    const b = p.bounds();
    return .{ geom.toMm(b.min.x), geom.toMm(b.min.y), geom.toMm(b.max.x), geom.toMm(b.max.y) };
}

test "svg path: M L H V Z, absolute and relative" {
    // A square 10 x 10 two ways: the same area.
    const abs_sq = "<svg><path d='M0 0 L10 0 L10 10 L0 10 Z'/></svg>";
    const rel_sq = "<svg><path d='m0,0 h10 v10 h-10 z'/></svg>";
    try testing.expectApproxEqAbs(@as(f64, 100), try areaOf(abs_sq, 10), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 100), try areaOf(rel_sq, 10), 1e-3);
    // V and H absolute; pairs after M are lines.
    try testing.expectApproxEqAbs(@as(f64, 100), try areaOf("<svg><path d='M0 0 10 0 V10 H0z'/></svg>", 10), 1e-3);
    // The box is centered, and the height is the asked height.
    const b = try boxMm(abs_sq, 20);
    try testing.expectApproxEqAbs(@as(f64, -10), b[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 10), b[3], 1e-3);
}

test "svg path: C S Q T curves" {
    // A circle of radius 1 from four cubic arcs (k = 0.5523): area about pi.
    const k = "0.5523";
    const circ = "<svg><path d='M1 0 C1 " ++ k ++ " " ++ k ++ " 1 0 1 S-1 " ++ k ++ " -1 0 S-" ++ k ++ " -1 0 -1 S1 -" ++ k ++ " 1 0 Z'/></svg>";
    try testing.expectApproxEqRel(std.math.pi, try areaOf(circ, 2), 1e-3);
    // A parabola segment: Q from (0,0) over (1,2) to (2,0) closed by the
    // chord: area 2/3 * base * height = 2/3 * 2 * 1.
    try testing.expectApproxEqRel(@as(f64, 4.0 / 3.0), try areaOf("<svg><path d='M0 0 Q1 2 2 0 Z'/></svg>", 1), 1e-3);
    // T repeats the reflected control point: a hump up, then a hump
    // down. Each is a fill of its own (nonzero), so the area is twice.
    try testing.expectApproxEqRel(@as(f64, 8.0 / 3.0), try areaOf("<svg><path d='M0 0 Q1 -2 2 0 T4 0 Z'/></svg>", 2), 2e-3);
}

test "svg path: arcs" {
    // A disk of radius 5 from two arcs.
    try testing.expectApproxEqRel(@as(f64, 25 * std.math.pi), try areaOf("<svg><path d='M0 5 A5 5 0 1 0 10 5 A5 5 0 1 0 0 5 Z'/></svg>", 10), 1e-3);
    // A half disk: large flag 0, sweep 1, and a radius too small (it
    // grows to fit).
    try testing.expectApproxEqRel(@as(f64, 12.5 * std.math.pi), try areaOf("<svg><path d='M0 0 a1 1 0 0 1 10 0 z'/></svg>", 5), 1e-3);
    // A rotated ellipse arc keeps its area: rx 4, ry 2, at 30 degrees.
    try testing.expectApproxEqRel(@as(f64, 8 * std.math.pi), try areaOf("<svg><ellipse cx='0' cy='0' rx='4' ry='2' transform='rotate(30)'/></svg>", 0), 1e-3);
}

test "svg path: transforms" {
    // translate and scale: a 1 x 1 square scaled by 3 then by height 0
    // (the units of the picture as mm).
    try testing.expectApproxEqAbs(@as(f64, 9), try areaOf("<svg><g transform='translate(5,5) scale(3)'><rect width='1' height='1'/></g></svg>", 0), 1e-3);
    // matrix and skewX keep the area of a shear.
    try testing.expectApproxEqAbs(@as(f64, 4), try areaOf("<svg><rect width='2' height='2' transform='skewX(30)'/></svg>", 0), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 8), try areaOf("<svg><rect width='2' height='2' transform='matrix(2 0 0 1 0 0)'/></svg>", 0), 1e-3);
    // rotate(45 cx cy): the box of a turned square is wider.
    const b = try boxMm("<svg><rect x='0' y='0' width='10' height='10' transform='rotate(45 5 5)'/></svg>", 0);
    try testing.expectApproxEqAbs(@as(f64, 10 * std.math.sqrt2), b[2] - b[0], 1e-2);
}

test "svg path: fill rules" {
    // Two squares, one in the other, the same direction.
    const d = "M0 0 h10 v10 h-10 z M3 3 h4 v4 h-4 z";
    // nonzero: the inner square fills; evenodd: it is a hole.
    try testing.expectApproxEqAbs(@as(f64, 100), try areaOf("<svg><path d='" ++ d ++ "'/></svg>", 10), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 84), try areaOf("<svg><path fill-rule='evenodd' d='" ++ d ++ "'/></svg>", 10), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 84), try areaOf("<svg><g style='fill-rule:evenodd'><path d='" ++ d ++ "'/></g></svg>", 10), 1e-3);
    // nonzero with the inner square the other way: a hole.
    try testing.expectApproxEqAbs(@as(f64, 84), try areaOf("<svg><path d='M0 0 h10 v10 h-10 z M3 3 v4 h4 v-4 z'/></svg>", 10), 1e-3);
}

test "svg path: basic shapes, strokes, and skipped tags" {
    try testing.expectApproxEqRel(@as(f64, std.math.pi * 4), try areaOf("<svg><circle cx='3' cy='3' r='2'/></svg>", 0), 1e-3);
    // A rect with round corners: 10 x 10 less the four corners of r = 2.
    try testing.expectApproxEqRel(@as(f64, 100 - (16 - 4 * std.math.pi)), try areaOf("<svg><rect width='10' height='10' rx='2'/></svg>", 0), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 50), try areaOf("<svg><polygon points='0,0 10,0 0,10'/></svg>", 0), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 50), try areaOf("<svg><polyline points='0,0 10,0 0,10'/></svg>", 0), 1e-3);
    // A line with a stroke: 10 long, 2 wide.
    try testing.expectApproxEqAbs(@as(f64, 20), try areaOf("<svg><line x1='0' y1='0' x2='10' y2='0' stroke='black' stroke-width='2'/></svg>", 0), 1e-3);
    // fill none with no stroke, defs, comments, and hidden shapes have
    // no area.
    const src =
        \\<?xml version="1.0"?>
        \\<!-- a comment <rect/> -->
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
        \\  <defs><rect width="100" height="100"/></defs>
        \\  <rect width="100" height="100" fill="none"/>
        \\  <rect width="100" height="100" display="none"/>
        \\  <svg:rect x="1" y="1" width="2" height="3"/>
        \\</svg>
    ;
    try testing.expectApproxEqAbs(@as(f64, 6), try areaOf(src, 0), 1e-3);
}

test "svg path: bad pictures fail cleanly" {
    const bad = [_][]const u8{
        "",
        "<rect width='1' height='1'/>",
        "<svg></svg>",
        "<svg><path d='M0 0 L1'/></svg>",
        "<svg><path d='L1 1 2 2'/></svg>",
        "<svg><path d='M0 0 A1 1 0 2 1 2 2'/></svg>",
        "<svg><rect width='1' height='1' transform='spin(3)'/></svg>",
        "<svg><path d='M0 0 L1 0 L1 1 Z",
        "<svg><path d='M0 0 L1e999 0 L1 1 Z'/></svg>",
    };
    for (bad) |s| {
        const r = outline(testing.allocator, s, .{});
        if (r) |p| {
            var q = p;
            q.deinit(testing.allocator);
            std.debug.print("no error for {s}\n", .{s});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
