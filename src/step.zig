//! STEP files (ISO 10303-21) with B-rep solids, made into a triangle mesh.
//!
//! A STEP file of a CAD part (AP203, AP214, or AP242) is a text with one
//! entity on each line: "#12=CARTESIAN_POINT('',(0.,1.,2.));". The
//! entities refer to each other by number. A solid is a shell of faces.
//! Each face (ADVANCED_FACE) is a piece of a surface (a plane, a
//! cylinder, a cone, a sphere, a torus, a B-spline surface, a surface of
//! extrusion or of revolution) inside its bounds. A bound is a loop of
//! edges; each edge is a piece of a curve (a line, a circle, an ellipse,
//! a B-spline curve) between two vertices. Two faces that touch share
//! their edge.
//!
//! The steps:
//!
//! 1. Read the DATA section into entities: a type name and a list of
//!    values (numbers, texts, enumerations, references, lists). A complex
//!    entity "(A(...) B(...))" keeps each part with its name.
//! 2. Find the units: a length in mm, m, or inches, and an angle in
//!    radians or degrees. The mesh is in mm.
//! 3. Sample each edge once, in its own direction, so that the chords
//!    stay within `tolerance` of the curve. The two faces of an edge use
//!    the same points, so the mesh is closed after the weld of its
//!    vertices.
//! 4. For each face: join the samples of its edges into loops, and put
//!    each point into a 2D chart of the surface (its parameters, scaled
//!    to lengths). A periodic parameter (an angle) is unwrapped along each
//!    loop. A loop that goes once around the axis (a band of a cylinder
//!    with no seam edge) uses a polar chart: the angle is the angle, and
//!    the other parameter is the radius.
//! 5. Triangulate the loops in the chart: each hole joins the outer loop
//!    by a bridge, and ear clipping makes the triangles.
//! 6. Refine on a curved surface: flip the inner edges until the
//!    triangles are Delaunay in the chart, then split each inner edge
//!    whose middle on the surface is more than `tolerance` away from its
//!    chord, with its triangles, and flip again, until all edges are close
//!    enough. The edges on the bounds do not split: their points come
//!    from step 3.
//! 7. Turn the triangles of the face to face out: all turn the same way
//!    in the chart, and a vote of their normals against the surface
//!    normal (times the sense of the face) turns them all, or none.
//!
//! Not read: the placements of the parts of an assembly (all solids come
//! in the frame of their own shape), the colors, and the pcurves.
//!
//! References (see docs/references/formats-and-protocols.md and
//! papers-and-algorithms.md): ISO 10303-21 (the file format) and the
//! entities of ISO 10303-42 (the geometry and the topology), the B-spline
//! evaluation of Cox and de Boor, ear clipping with hole bridges (as
//! cut.zig), and the edge flips of Lawson toward a Delaunay
//! triangulation (a general technique).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

pub const Error = error{ InvalidStep, NoSolid } || Allocator.Error;

/// The most distance (mm) of a chord from its curve or surface.
pub const tolerance: f64 = 0.01;

/// True if the bytes start as a STEP file.
pub fn isStep(bytes: []const u8) bool {
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 64)], " \t\r\n\xef\xbb\xbf");
    return std.mem.startsWith(u8, head, "ISO-10303-21");
}

// ---------------------------------------------------------------- values

const Value = union(enum) {
    none,
    num: f64,
    ref: u32,
    str: []const u8,
    enm: []const u8,
    list: []const Value,
    typed: Typed,

    fn asNum(v: Value) ?f64 {
        return switch (v) {
            .num => |x| x,
            .typed => |t| if (t.args.len == 1) t.args[0].asNum() else null,
            else => null,
        };
    }
    fn asRef(v: Value) ?u32 {
        return switch (v) {
            .ref => |r| r,
            else => null,
        };
    }
    fn asList(v: Value) []const Value {
        return switch (v) {
            .list => |l| l,
            else => &.{},
        };
    }
    fn asBool(v: Value) bool {
        return switch (v) {
            .enm => |e| std.mem.eql(u8, e, "T"),
            else => true,
        };
    }
};

const Typed = struct { name: []const u8, args: []const Value };

const Part = struct { name: []const u8, args: []const Value };

const Entity = struct { parts: []const Part };

// ---------------------------------------------------------------- parser

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                p.i += 1;
            } else if (c == '/' and p.i + 1 < p.s.len and p.s[p.i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, p.s, p.i + 2, "*/") orelse p.s.len;
                p.i = @min(p.s.len, end + 2);
            } else break;
        }
    }

    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn expect(p: *Parser, c: u8) Error!void {
        if (p.peek() != c) return error.InvalidStep;
        p.i += 1;
    }

    fn name(p: *Parser) []const u8 {
        p.skip();
        const start = p.i;
        while (p.i < p.s.len) : (p.i += 1) {
            const c = p.s[p.i];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
        }
        return p.s[start..p.i];
    }

    fn value(p: *Parser, depth: u32) Error!Value {
        if (depth > 64) return error.InvalidStep;
        const c = p.peek();
        switch (c) {
            '$', '*' => {
                p.i += 1;
                return .none;
            },
            '#' => {
                p.i += 1;
                const n = p.name();
                return .{ .ref = std.fmt.parseInt(u32, n, 10) catch return error.InvalidStep };
            },
            '\'' => {
                p.i += 1;
                const start = p.i;
                while (p.i < p.s.len) : (p.i += 1) {
                    if (p.s[p.i] == '\'') {
                        if (p.i + 1 < p.s.len and p.s[p.i + 1] == '\'') {
                            p.i += 1;
                            continue;
                        }
                        break;
                    }
                }
                if (p.i >= p.s.len) return error.InvalidStep;
                const str = p.s[start..p.i];
                p.i += 1;
                return .{ .str = str };
            },
            '.' => {
                p.i += 1;
                const start = p.i;
                while (p.i < p.s.len and p.s[p.i] != '.') p.i += 1;
                if (p.i >= p.s.len) return error.InvalidStep;
                const e = p.s[start..p.i];
                p.i += 1;
                return .{ .enm = e };
            },
            '(' => return .{ .list = try p.list(depth + 1) },
            '"' => {
                // A binary: skip it.
                p.i += 1;
                while (p.i < p.s.len and p.s[p.i] != '"') p.i += 1;
                p.i = @min(p.s.len, p.i + 1);
                return .none;
            },
            else => {
                if (c == '-' or c == '+' or std.ascii.isDigit(c)) {
                    const start = p.i;
                    while (p.i < p.s.len) : (p.i += 1) {
                        const d = p.s[p.i];
                        if (!(std.ascii.isDigit(d) or d == '.' or d == 'E' or d == 'e' or d == '-' or d == '+')) break;
                    }
                    return .{ .num = std.fmt.parseFloat(f64, p.s[start..p.i]) catch return error.InvalidStep };
                }
                if (std.ascii.isAlphabetic(c)) {
                    const n = p.name();
                    const args = try p.list(depth + 1);
                    return .{ .typed = .{ .name = n, .args = args } };
                }
                return error.InvalidStep;
            },
        }
    }

    fn list(p: *Parser, depth: u32) Error![]const Value {
        try p.expect('(');
        var out: std.ArrayList(Value) = .empty;
        if (p.peek() == ')') {
            p.i += 1;
            return &.{};
        }
        while (true) {
            try out.append(p.a, try p.value(depth));
            const c = p.peek();
            p.i += 1;
            if (c == ')') break;
            if (c != ',') return error.InvalidStep;
        }
        return out.toOwnedSlice(p.a);
    }
};

const Model = struct {
    a: Allocator,
    ents: std.AutoHashMapUnmanaged(u32, Entity) = .empty,
    /// The ids in file order.
    order: std.ArrayList(u32) = .empty,
    length: f64 = 1,
    angle: f64 = 1,

    fn parse(a: Allocator, bytes: []const u8) Error!Model {
        var m: Model = .{ .a = a };
        const data = std.mem.indexOf(u8, bytes, "DATA;") orelse return error.InvalidStep;
        var p: Parser = .{ .a = a, .s = bytes, .i = data + 5 };
        while (true) {
            const c = p.peek();
            if (c == 0) break;
            if (c != '#') {
                // ENDSEC; or another word: the end of the data.
                break;
            }
            p.i += 1;
            const id = std.fmt.parseInt(u32, p.name(), 10) catch return error.InvalidStep;
            try p.expect('=');
            var parts: std.ArrayList(Part) = .empty;
            if (p.peek() == '(') {
                // A complex entity: (A(...) B(...) ...)
                p.i += 1;
                while (p.peek() != ')') {
                    const n = p.name();
                    if (n.len == 0) return error.InvalidStep;
                    try parts.append(a, .{ .name = n, .args = try p.list(0) });
                }
                p.i += 1;
            } else {
                const n = p.name();
                if (n.len == 0) return error.InvalidStep;
                try parts.append(a, .{ .name = n, .args = try p.list(0) });
            }
            try p.expect(';');
            try m.ents.put(a, id, .{ .parts = try parts.toOwnedSlice(a) });
            try m.order.append(a, id);
        }
        m.units();
        return m;
    }

    fn get(m: *const Model, id: u32) ?Entity {
        return m.ents.get(id);
    }

    /// The arguments of entity `id` if it has a part named `name`.
    fn args(m: *const Model, id: ?u32, name: []const u8) ?[]const Value {
        const e = m.get(id orelse return null) orelse return null;
        for (e.parts) |pt| if (std.mem.eql(u8, pt.name, name)) return pt.args;
        return null;
    }

    fn typeOf(m: *const Model, id: ?u32) []const u8 {
        const e = m.get(id orelse return "") orelse return "";
        return if (e.parts.len == 1) e.parts[0].name else "";
    }

    fn has(m: *const Model, id: u32, name: []const u8) bool {
        return m.args(id, name) != null;
    }

    /// The length unit (mm per unit) and the angle unit (radians per
    /// unit) of the file.
    fn units(m: *Model) void {
        // The units of the context of the shape, or else all units.
        var list: []const Value = &.{};
        for (m.order.items) |id| if (m.args(id, "GLOBAL_UNIT_ASSIGNED_CONTEXT")) |g| {
            if (g.len > 0) list = g[0].asList();
            break;
        };
        for (m.order.items, 0..) |all_id, at| {
            const id = if (list.len > 0) (if (at < list.len) list[at].asRef() orelse continue else break) else all_id;
            const e = m.get(id) orelse continue;
            if (e.parts.len < 2) continue;
            const length = m.has(id, "LENGTH_UNIT");
            const angle = m.has(id, "PLANE_ANGLE_UNIT");
            if (!length and !angle) continue;
            if (m.args(id, "SI_UNIT")) |si| {
                if (length) {
                    var k: f64 = 1000;
                    if (si.len >= 1) if (si[0] == .enm) {
                        const pre = si[0].enm;
                        if (std.mem.eql(u8, pre, "MILLI")) k = 1;
                        if (std.mem.eql(u8, pre, "CENTI")) k = 10;
                        if (std.mem.eql(u8, pre, "DECI")) k = 100;
                        if (std.mem.eql(u8, pre, "KILO")) k = 1e6;
                        if (std.mem.eql(u8, pre, "MICRO")) k = 1e-3;
                    };
                    m.length = k;
                }
            } else if (m.args(id, "CONVERSION_BASED_UNIT")) |cb| {
                const n = if (cb.len > 0 and cb[0] == .str) cb[0].str else "";
                if (length) {
                    if (std.ascii.eqlIgnoreCase(n, "INCH")) m.length = 25.4;
                    if (std.ascii.eqlIgnoreCase(n, "FOOT")) m.length = 304.8;
                }
                if (angle and std.ascii.eqlIgnoreCase(n, "DEGREE")) m.angle = std.math.pi / 180.0;
            }
        }
    }
};

// ---------------------------------------------------------------- vectors

const V3 = [3]f64;

fn add(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn mul(a: V3, k: f64) V3 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}
fn dot(a: V3, b: V3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn len(a: V3) f64 {
    return @sqrt(dot(a, a));
}
fn norm(a: V3) V3 {
    const l = len(a);
    return if (l > 0) mul(a, 1 / l) else a;
}
fn dist(a: V3, b: V3) f64 {
    return len(sub(a, b));
}

const Frame = struct {
    o: V3 = .{ 0, 0, 0 },
    x: V3 = .{ 1, 0, 0 },
    y: V3 = .{ 0, 1, 0 },
    z: V3 = .{ 0, 0, 1 },

    fn local(f: Frame, p: V3) V3 {
        const d = sub(p, f.o);
        return .{ dot(d, f.x), dot(d, f.y), dot(d, f.z) };
    }
    fn world(f: Frame, x: f64, y: f64, z: f64) V3 {
        return add(f.o, add(mul(f.x, x), add(mul(f.y, y), mul(f.z, z))));
    }
};

// ---------------------------------------------------------------- geometry

const BSpline = struct {
    deg: usize,
    /// The control points (for a surface: nu rows of nv points), and the
    /// weights (1 for a non-rational spline).
    cps: []const V3,
    w: []const f64,
    /// The full knot vectors.
    ku: []const f64,
    kv: []const f64 = &.{},
    degv: usize = 0,
    nu: usize,
    nv: usize = 1,

    fn lo(k: []const f64, deg: usize) f64 {
        return k[deg];
    }
    fn hi(k: []const f64, deg: usize) f64 {
        return k[k.len - deg - 1];
    }

    fn span(k: []const f64, deg: usize, n: usize, t: f64) usize {
        // The knot span of t: k[s] <= t < k[s + 1], with deg <= s < n.
        if (t >= k[n]) return n - 1;
        if (t <= k[deg]) return deg;
        var lo_i = deg;
        var hi_i = n;
        while (hi_i - lo_i > 1) {
            const mid = (lo_i + hi_i) / 2;
            if (t < k[mid]) hi_i = mid else lo_i = mid;
        }
        return lo_i;
    }

    /// The basis functions of span s at t (de Boor, Cox): deg + 1 values.
    fn basis(k: []const f64, deg: usize, s: usize, t: f64, out: []f64) void {
        var left: [16]f64 = undefined;
        var right: [16]f64 = undefined;
        out[0] = 1;
        for (1..deg + 1) |j| {
            left[j] = t - k[s + 1 - j];
            right[j] = k[s + j] - t;
            var saved: f64 = 0;
            for (0..j) |r| {
                const den = right[r + 1] + left[j - r];
                const tmp = if (den != 0) out[r] / den else 0;
                out[r] = saved + right[r + 1] * tmp;
                saved = left[j - r] * tmp;
            }
            out[j] = saved;
        }
    }

    fn curvePoint(b: BSpline, t: f64) V3 {
        var n: [16]f64 = undefined;
        const s = span(b.ku, b.deg, b.nu, t);
        basis(b.ku, b.deg, s, t, &n);
        var p: V3 = .{ 0, 0, 0 };
        var wsum: f64 = 0;
        for (0..b.deg + 1) |j| {
            const i = s - b.deg + j;
            const wn = n[j] * b.w[i];
            p = add(p, mul(b.cps[i], wn));
            wsum += wn;
        }
        return if (wsum != 0) mul(p, 1 / wsum) else p;
    }

    fn surfacePoint(b: BSpline, u: f64, v: f64) V3 {
        var nu_: [16]f64 = undefined;
        var nv_: [16]f64 = undefined;
        const su = span(b.ku, b.deg, b.nu, u);
        const sv = span(b.kv, b.degv, b.nv, v);
        basis(b.ku, b.deg, su, u, &nu_);
        basis(b.kv, b.degv, sv, v, &nv_);
        var p: V3 = .{ 0, 0, 0 };
        var wsum: f64 = 0;
        for (0..b.deg + 1) |a| {
            const i = su - b.deg + a;
            for (0..b.degv + 1) |c| {
                const j = sv - b.degv + c;
                const k = i * b.nv + j;
                const wn = nu_[a] * nv_[c] * b.w[k];
                p = add(p, mul(b.cps[k], wn));
                wsum += wn;
            }
        }
        return if (wsum != 0) mul(p, 1 / wsum) else p;
    }
};

const Curve = union(enum) {
    line: struct { p: V3, d: V3 },
    circle: struct { f: Frame, r: f64 },
    ellipse: struct { f: Frame, a: f64, b: f64 },
    bspline: BSpline,
    /// A curve that zslice does not read: the edge is a straight line.
    other,

    fn point(c: Curve, t: f64) V3 {
        return switch (c) {
            .line => |l| add(l.p, mul(l.d, t)),
            .circle => |k| k.f.world(k.r * @cos(t), k.r * @sin(t), 0),
            .ellipse => |e| e.f.world(e.a * @cos(t), e.b * @sin(t), 0),
            .bspline => |b| b.curvePoint(t),
            .other => .{ 0, 0, 0 },
        };
    }

    fn range(c: Curve) [2]f64 {
        return switch (c) {
            .bspline => |b| .{ BSpline.lo(b.ku, b.deg), BSpline.hi(b.ku, b.deg) },
            .circle, .ellipse => .{ 0, 2 * std.math.pi },
            else => .{ 0, 1 },
        };
    }

    /// The parameter of the point of the curve nearest to p.
    fn param(c: Curve, p: V3) f64 {
        switch (c) {
            .line => |l| return dot(sub(p, l.p), l.d) / @max(dot(l.d, l.d), 1e-30),
            .circle => |k| {
                const q = k.f.local(p);
                return wrap(std.math.atan2(q[1], q[0]));
            },
            .ellipse => |e| {
                const q = k_local(e.f, p);
                return wrap(std.math.atan2(q[1] / e.b, q[0] / e.a));
            },
            .bspline => {
                const r = c.range();
                return nearestParam(c, p, r[0], r[1]);
            },
            .other => return 0,
        }
    }
};

fn k_local(f: Frame, p: V3) V3 {
    return f.local(p);
}

fn wrap(a: f64) f64 {
    const two = 2 * std.math.pi;
    var x = @mod(a, two);
    if (x < 0) x += two;
    return x;
}

/// The parameter in [lo, hi] of the point of c nearest to p: a search on
/// samples, then smaller steps around the best one.
fn nearestParam(c: Curve, p: V3, lo: f64, hi: f64) f64 {
    const n = 64;
    var best = lo;
    var best_d = std.math.inf(f64);
    for (0..n + 1) |i| {
        const t = lo + (hi - lo) * @as(f64, @floatFromInt(i)) / n;
        const d = dist(c.point(t), p);
        if (d < best_d) {
            best_d = d;
            best = t;
        }
    }
    var step = (hi - lo) / n;
    for (0..60) |_| {
        const a = @max(lo, best - step);
        const b = @min(hi, best + step);
        const da = dist(c.point(a), p);
        const db = dist(c.point(b), p);
        if (da < best_d) {
            best_d = da;
            best = a;
        } else if (db < best_d) {
            best_d = db;
            best = b;
        } else step /= 2;
        if (step < (hi - lo) * 1e-12) break;
    }
    return best;
}

const Kind = enum { plane, cylinder, cone, sphere, torus, bspline, extrusion, revolution, other };

const Surface = struct {
    kind: Kind,
    f: Frame = .{},
    r: f64 = 0,
    r2: f64 = 0,
    tan: f64 = 0,
    b: BSpline = undefined,
    curve: Curve = .other,
    dir: V3 = .{ 0, 0, 1 },

    /// The period of u and of v, or 0: an angle has 2 pi, and a closed
    /// B-spline surface the length of its knot range (see `closeSpline`).
    pu: f64 = 0,
    pv: f64 = 0,

    fn periods(s: *Surface) void {
        const two = 2 * std.math.pi;
        switch (s.kind) {
            .cylinder, .cone, .sphere => s.pu = two,
            .revolution => {
                s.pu = two;
                // A circle turned about an axis: a torus.
                if (s.curve == .circle or s.curve == .ellipse) s.pv = two;
            },
            .torus => {
                s.pu = two;
                s.pv = two;
            },
            .bspline => s.closeSpline(),
            else => {},
        }
    }

    /// A B-spline surface whose two edges of u (or of v) are the same
    /// curve is closed in u (or v): a torus or a tube as a spline.
    fn closeSpline(s: *Surface) void {
        const ua = BSpline.lo(s.b.ku, s.b.deg);
        const ub = BSpline.hi(s.b.ku, s.b.deg);
        const va = BSpline.lo(s.b.kv, s.b.degv);
        const vb = BSpline.hi(s.b.kv, s.b.degv);
        var du: f64 = 0;
        var dv: f64 = 0;
        var size: f64 = 0;
        for (0..5) |i| {
            const f = @as(f64, @floatFromInt(i)) / 4;
            const v = va + (vb - va) * f;
            const u = ua + (ub - ua) * f;
            du = @max(du, dist(s.b.surfacePoint(ua, v), s.b.surfacePoint(ub, v)));
            dv = @max(dv, dist(s.b.surfacePoint(u, va), s.b.surfacePoint(u, vb)));
            size = @max(size, dist(s.b.surfacePoint(ua, va), s.b.surfacePoint(u, v)));
        }
        const eps = @max(1e-6, size * 1e-7);
        if (du < eps) s.pu = ub - ua;
        if (dv < eps) s.pv = vb - va;
    }

    fn point(s: Surface, u: f64, v: f64) V3 {
        return switch (s.kind) {
            .plane => s.f.world(u, v, 0),
            .cylinder => s.f.world(s.r * @cos(u), s.r * @sin(u), v),
            .cone => blk: {
                const rr = s.r + v * s.tan;
                break :blk s.f.world(rr * @cos(u), rr * @sin(u), v);
            },
            .sphere => s.f.world(s.r * @cos(v) * @cos(u), s.r * @cos(v) * @sin(u), s.r * @sin(v)),
            .torus => blk: {
                const rr = s.r + s.r2 * @cos(v);
                break :blk s.f.world(rr * @cos(u), rr * @sin(u), s.r2 * @sin(v));
            },
            .bspline => blk: {
                // A closed spline: the parameter back into its range.
                var uu = u;
                var vv = v;
                if (s.pu > 0) {
                    const ua = BSpline.lo(s.b.ku, s.b.deg);
                    uu = ua + @mod(u - ua, s.pu);
                }
                if (s.pv > 0) {
                    const va = BSpline.lo(s.b.kv, s.b.degv);
                    vv = va + @mod(v - va, s.pv);
                }
                break :blk s.b.surfacePoint(uu, vv);
            },
            .extrusion => add(s.curve.point(u), mul(s.dir, v)),
            .revolution => blk: {
                // Turn the point of the profile about the axis (o, z).
                const q = s.curve.point(v);
                const l = s.f.local(q);
                const c = @cos(u);
                const sn = @sin(u);
                break :blk s.f.world(l[0] * c - l[1] * sn, l[0] * sn + l[1] * c, l[2]);
            },
            .other => .{ 0, 0, 0 },
        };
    }

    /// The parameters of p (the nearest point of the surface). `hint`: the
    /// parameters of a point near p, for the surfaces with a search.
    fn param(s: Surface, p: V3, hint: ?[2]f64) [2]f64 {
        switch (s.kind) {
            .plane => {
                const q = s.f.local(p);
                return .{ q[0], q[1] };
            },
            .cylinder, .cone => {
                const q = s.f.local(p);
                return .{ std.math.atan2(q[1], q[0]), q[2] };
            },
            .sphere => {
                const q = s.f.local(p);
                const h = @sqrt(q[0] * q[0] + q[1] * q[1]);
                return .{ std.math.atan2(q[1], q[0]), std.math.atan2(q[2], h) };
            },
            .torus => {
                const q = s.f.local(p);
                const h = @sqrt(q[0] * q[0] + q[1] * q[1]) - s.r;
                return .{ std.math.atan2(q[1], q[0]), std.math.atan2(q[2], h) };
            },
            .revolution => {
                const q = s.f.local(p);
                const r = s.curve.range();
                // The angle of the plane of the profile (u = 0).
                const c = s.f.local(s.curve.point((r[0] + r[1]) / 2));
                const a0 = std.math.atan2(c[1], c[0]);
                const u = std.math.atan2(q[1], q[0]) - a0;
                // Turn p back into the plane of the profile.
                const rho = @sqrt(q[0] * q[0] + q[1] * q[1]);
                const back = s.f.world(rho * @cos(a0), rho * @sin(a0), q[2]);
                return .{ u, s.curve.param(back) };
            },
            .extrusion => {
                const d = norm(s.dir);
                const r = s.curve.range();
                // The curve point under p along the direction.
                const base = sub(p, mul(d, dot(p, d)));
                var best: f64 = r[0];
                var best_d = std.math.inf(f64);
                const n = 64;
                for (0..n + 1) |i| {
                    const t = r[0] + (r[1] - r[0]) * @as(f64, @floatFromInt(i)) / n;
                    const c = s.curve.point(t);
                    const dd = dist(sub(c, mul(d, dot(c, d))), base);
                    if (dd < best_d) {
                        best_d = dd;
                        best = t;
                    }
                }
                var step = (r[1] - r[0]) / n;
                for (0..60) |_| {
                    var moved = false;
                    for ([_]f64{ -step, step }) |ds| {
                        const t = std.math.clamp(best + ds, r[0], r[1]);
                        const c = s.curve.point(t);
                        const dd = dist(sub(c, mul(d, dot(c, d))), base);
                        if (dd < best_d) {
                            best_d = dd;
                            best = t;
                            moved = true;
                        }
                    }
                    if (!moved) step /= 2;
                }
                const c = s.curve.point(best);
                return .{ best, dot(sub(p, c), s.dir) / @max(dot(s.dir, s.dir), 1e-30) };
            },
            .bspline => return s.searchParam(p, hint),
            .other => return .{ 0, 0 },
        }
    }

    /// The parameters of the nearest point of a B-spline surface: a grid
    /// search (or the hint), then smaller steps.
    fn searchParam(s: Surface, p: V3, hint: ?[2]f64) [2]f64 {
        const ua = BSpline.lo(s.b.ku, s.b.deg);
        const ub = BSpline.hi(s.b.ku, s.b.deg);
        const va = BSpline.lo(s.b.kv, s.b.degv);
        const vb = BSpline.hi(s.b.kv, s.b.degv);
        var best: [2]f64 = .{ ua, va };
        var best_d = std.math.inf(f64);
        const n = 24;
        for (0..n + 1) |i| for (0..n + 1) |j| {
            const u = ua + (ub - ua) * @as(f64, @floatFromInt(i)) / n;
            const v = va + (vb - va) * @as(f64, @floatFromInt(j)) / n;
            const d = dist(s.point(u, v), p);
            if (d < best_d) {
                best_d = d;
                best = .{ u, v };
            }
        };
        if (hint) |h| {
            const d = dist(s.point(h[0], h[1]), p);
            if (d < best_d) {
                best_d = d;
                best = h;
            }
        }
        var su = (ub - ua) / n;
        var sv = (vb - va) / n;
        for (0..80) |_| {
            var moved = false;
            const steps = [_][2]f64{ .{ -su, 0 }, .{ su, 0 }, .{ 0, -sv }, .{ 0, sv }, .{ -su, -sv }, .{ su, sv }, .{ -su, sv }, .{ su, -sv } };
            for (steps) |st| {
                const u = std.math.clamp(best[0] + st[0], ua, ub);
                const v = std.math.clamp(best[1] + st[1], va, vb);
                const d = dist(s.point(u, v), p);
                if (d < best_d) {
                    best_d = d;
                    best = .{ u, v };
                    moved = true;
                }
            }
            if (!moved) {
                su /= 2;
                sv /= 2;
            }
            if (su < (ub - ua) * 1e-12 and sv < (vb - va) * 1e-12) break;
        }
        return best;
    }

    /// The normal of the surface at (u, v), from the derivatives (the
    /// normal of STEP: dS/du x dS/dv).
    fn normal(s: Surface, u: f64, v: f64) V3 {
        if (s.kind == .plane) return s.f.z;
        const e = 1e-5;
        const du = sub(s.point(u + e, v), s.point(u - e, v));
        const dv = sub(s.point(u, v + e), s.point(u, v - e));
        return norm(cross(du, dv));
    }
};

// ---------------------------------------------------------------- reading the entities

const Reader = struct {
    a: Allocator,
    m: *const Model,

    fn v3(r: Reader, id: ?u32) V3 {
        const args = r.m.args(id, "CARTESIAN_POINT") orelse r.m.args(id, "DIRECTION") orelse return .{ 0, 0, 0 };
        if (args.len < 2) return .{ 0, 0, 0 };
        const l = args[1].asList();
        var out: V3 = .{ 0, 0, 0 };
        for (l, 0..) |x, i| if (i < 3) {
            out[i] = x.asNum() orelse 0;
        };
        return out;
    }

    fn point(r: Reader, id: ?u32) V3 {
        return mul(r.v3(id), r.m.length);
    }

    fn frame(r: Reader, id: ?u32) Frame {
        const args = r.m.args(id, "AXIS2_PLACEMENT_3D") orelse return .{};
        var f: Frame = .{};
        if (args.len > 1) f.o = r.point(args[1].asRef());
        if (args.len > 2) if (args[2].asRef()) |z| {
            f.z = norm(r.v3(z));
        };
        const xr: ?u32 = if (args.len > 3) args[3].asRef() else null;
        var x: V3 = if (xr) |id_x| r.v3(id_x) else if (@abs(f.z[0]) < 0.9) V3{ 1, 0, 0 } else V3{ 0, 1, 0 };
        // x perpendicular to z.
        if (len(sub(x, mul(f.z, dot(x, f.z)))) < 1e-9) x = if (@abs(f.z[0]) < 0.9) V3{ 1, 0, 0 } else V3{ 0, 1, 0 };
        f.x = norm(sub(x, mul(f.z, dot(x, f.z))));
        f.y = cross(f.z, f.x);
        return f;
    }

    fn knots(r: Reader, mults: []const Value, ks: []const Value) Error![]const f64 {
        var out: std.ArrayList(f64) = .empty;
        for (mults, 0..) |mv, i| {
            const k = if (i < ks.len) ks[i].asNum() orelse 0 else 0;
            const n: usize = @intFromFloat(@max(0, mv.asNum() orelse 0));
            if (n > 64) return error.InvalidStep;
            for (0..n) |_| try out.append(r.a, k);
        }
        return out.toOwnedSlice(r.a);
    }

    fn curve(r: Reader, id_in: ?u32) Error!Curve {
        var id = id_in orelse return .other;
        // A surface curve, a seam curve, or a trimmed curve: its 3D curve.
        var guard: usize = 0;
        while (guard < 8) : (guard += 1) {
            if (r.m.args(id, "SURFACE_CURVE") orelse r.m.args(id, "SEAM_CURVE") orelse r.m.args(id, "INTERSECTION_CURVE")) |args| {
                id = (if (args.len > 1) args[1].asRef() else null) orelse return .other;
            } else if (r.m.args(id, "TRIMMED_CURVE")) |args| {
                id = (if (args.len > 1) args[1].asRef() else null) orelse return .other;
            } else break;
        }
        if (r.m.args(id, "LINE")) |args| {
            if (args.len < 3) return .other;
            const p = r.point(args[1].asRef());
            const vec = r.m.args(args[2].asRef(), "VECTOR") orelse return .other;
            var d = norm(r.v3(if (vec.len > 1) vec[1].asRef() else null));
            if (vec.len > 2) d = mul(d, (vec[2].asNum() orelse 1) * r.m.length);
            return .{ .line = .{ .p = p, .d = d } };
        }
        if (r.m.args(id, "CIRCLE")) |args| {
            if (args.len < 3) return .other;
            return .{ .circle = .{ .f = r.frame(args[1].asRef()), .r = (args[2].asNum() orelse 0) * r.m.length } };
        }
        if (r.m.args(id, "ELLIPSE")) |args| {
            if (args.len < 4) return .other;
            return .{ .ellipse = .{ .f = r.frame(args[1].asRef()), .a = (args[2].asNum() orelse 0) * r.m.length, .b = (args[3].asNum() orelse 0) * r.m.length } };
        }
        // A B-spline curve: a simple entity, or the parts of a complex one.
        var deg: usize = 0;
        var cps_v: []const Value = &.{};
        var mults: []const Value = &.{};
        var ks: []const Value = &.{};
        var weights: []const Value = &.{};
        if (r.m.args(id, "B_SPLINE_CURVE_WITH_KNOTS")) |args| {
            if (args.len >= 8) {
                // name, degree, points, form, closed, self, mults, knots
                deg = @intFromFloat(@max(0, args[1].asNum() orelse 0));
                cps_v = args[2].asList();
                mults = args[6].asList();
                ks = args[7].asList();
            } else if (args.len >= 2) {
                mults = args[0].asList();
                ks = args[1].asList();
            }
        } else return .other;
        if (r.m.args(id, "B_SPLINE_CURVE")) |args| if (args.len >= 2) {
            deg = @intFromFloat(@max(0, args[0].asNum() orelse 0));
            cps_v = args[1].asList();
        };
        if (r.m.args(id, "RATIONAL_B_SPLINE_CURVE")) |args| if (args.len >= 1) {
            weights = args[0].asList();
        };
        if (deg == 0 or deg > 12 or cps_v.len < 2) return .other;
        const cps = try r.a.alloc(V3, cps_v.len);
        for (cps_v, cps) |v, *c| c.* = r.point(v.asRef());
        const w = try r.a.alloc(f64, cps.len);
        for (w, 0..) |*x, i| x.* = if (i < weights.len) weights[i].asNum() orelse 1 else 1;
        const k = try r.knots(mults, ks);
        if (k.len != cps.len + deg + 1) return .other;
        return .{ .bspline = .{ .deg = deg, .cps = cps, .w = w, .ku = k, .nu = cps.len } };
    }

    fn surface(r: Reader, id: ?u32) Error!Surface {
        const sid = id orelse return .{ .kind = .other };
        if (r.m.args(sid, "PLANE")) |args| {
            return .{ .kind = .plane, .f = r.frame(if (args.len > 1) args[1].asRef() else null) };
        }
        if (r.m.args(sid, "CYLINDRICAL_SURFACE")) |args| {
            if (args.len < 3) return .{ .kind = .other };
            return .{ .kind = .cylinder, .f = r.frame(args[1].asRef()), .r = (args[2].asNum() orelse 0) * r.m.length };
        }
        if (r.m.args(sid, "CONICAL_SURFACE")) |args| {
            if (args.len < 4) return .{ .kind = .other };
            return .{ .kind = .cone, .f = r.frame(args[1].asRef()), .r = (args[2].asNum() orelse 0) * r.m.length, .tan = @tan((args[3].asNum() orelse 0) * r.m.angle) };
        }
        if (r.m.args(sid, "SPHERICAL_SURFACE")) |args| {
            if (args.len < 3) return .{ .kind = .other };
            return .{ .kind = .sphere, .f = r.frame(args[1].asRef()), .r = (args[2].asNum() orelse 0) * r.m.length };
        }
        if (r.m.args(sid, "TOROIDAL_SURFACE")) |args| {
            if (args.len < 4) return .{ .kind = .other };
            return .{ .kind = .torus, .f = r.frame(args[1].asRef()), .r = (args[2].asNum() orelse 0) * r.m.length, .r2 = (args[3].asNum() orelse 0) * r.m.length };
        }
        if (r.m.args(sid, "SURFACE_OF_LINEAR_EXTRUSION")) |args| {
            if (args.len < 3) return .{ .kind = .other };
            const c = try r.curve(args[1].asRef());
            const vec = r.m.args(args[2].asRef(), "VECTOR") orelse return .{ .kind = .other };
            var d = norm(r.v3(if (vec.len > 1) vec[1].asRef() else null));
            if (vec.len > 2) d = mul(d, (vec[2].asNum() orelse 1) * r.m.length);
            if (c == .other) return .{ .kind = .other };
            return .{ .kind = .extrusion, .curve = c, .dir = d };
        }
        if (r.m.args(sid, "SURFACE_OF_REVOLUTION")) |args| {
            if (args.len < 3) return .{ .kind = .other };
            const c = try r.curve(args[1].asRef());
            const ax = r.m.args(args[2].asRef(), "AXIS1_PLACEMENT") orelse return .{ .kind = .other };
            var f: Frame = .{};
            if (ax.len > 1) f.o = r.point(ax[1].asRef());
            if (ax.len > 2) f.z = norm(r.v3(ax[2].asRef()));
            const x: V3 = if (@abs(f.z[0]) < 0.9) .{ 1, 0, 0 } else .{ 0, 1, 0 };
            f.x = norm(sub(x, mul(f.z, dot(x, f.z))));
            f.y = cross(f.z, f.x);
            if (c == .other) return .{ .kind = .other };
            return .{ .kind = .revolution, .f = f, .curve = c };
        }
        // A B-spline surface: simple, or the parts of a complex entity.
        var du: usize = 0;
        var dv: usize = 0;
        var rows: []const Value = &.{};
        var um: []const Value = &.{};
        var vm: []const Value = &.{};
        var uk: []const Value = &.{};
        var vk: []const Value = &.{};
        var weights: []const Value = &.{};
        if (r.m.args(sid, "B_SPLINE_SURFACE_WITH_KNOTS")) |args| {
            if (args.len >= 12) {
                // name, du, dv, points, form, uc, vc, self, um, vm, uk, vk
                du = @intFromFloat(@max(0, args[1].asNum() orelse 0));
                dv = @intFromFloat(@max(0, args[2].asNum() orelse 0));
                rows = args[3].asList();
                um = args[8].asList();
                vm = args[9].asList();
                uk = args[10].asList();
                vk = args[11].asList();
            } else if (args.len >= 4) {
                um = args[0].asList();
                vm = args[1].asList();
                uk = args[2].asList();
                vk = args[3].asList();
            }
        } else return .{ .kind = .other };
        if (r.m.args(sid, "B_SPLINE_SURFACE")) |args| if (args.len >= 3) {
            du = @intFromFloat(@max(0, args[0].asNum() orelse 0));
            dv = @intFromFloat(@max(0, args[1].asNum() orelse 0));
            rows = args[2].asList();
        };
        if (r.m.args(sid, "RATIONAL_B_SPLINE_SURFACE")) |args| if (args.len >= 1) {
            weights = args[0].asList();
        };
        if (du == 0 or dv == 0 or du > 12 or dv > 12 or rows.len < 2) return .{ .kind = .other };
        const nv = rows[0].asList().len;
        if (nv < 2) return .{ .kind = .other };
        const cps = try r.a.alloc(V3, rows.len * nv);
        const w = try r.a.alloc(f64, rows.len * nv);
        for (rows, 0..) |row, i| {
            const l = row.asList();
            if (l.len != nv) return .{ .kind = .other };
            const wl = if (i < weights.len) weights[i].asList() else &.{};
            for (l, 0..) |pv, j| {
                cps[i * nv + j] = r.point(pv.asRef());
                w[i * nv + j] = if (j < wl.len) wl[j].asNum() orelse 1 else 1;
            }
        }
        const ku = try r.knots(um, uk);
        const kv = try r.knots(vm, vk);
        if (ku.len != rows.len + du + 1 or kv.len != nv + dv + 1) return .{ .kind = .other };
        return .{ .kind = .bspline, .b = .{ .deg = du, .degv = dv, .cps = cps, .w = w, .ku = ku, .kv = kv, .nu = rows.len, .nv = nv } };
    }
};

// ---------------------------------------------------------------- edges

/// The samples of edges, by the id of the EDGE_CURVE: from its start
/// vertex to its end vertex.
const Edges = struct {
    map: std.AutoHashMapUnmanaged(u32, []const V3) = .empty,

    fn get(e: *Edges, r: Reader, id: u32) Error![]const V3 {
        if (e.map.get(id)) |pts| return pts;
        const pts = try sampleEdge(r, id);
        try e.map.put(r.a, id, pts);
        return pts;
    }
};

fn vertexPoint(r: Reader, id: ?u32) V3 {
    const args = r.m.args(id, "VERTEX_POINT") orelse return .{ 0, 0, 0 };
    return r.point(if (args.len > 1) args[1].asRef() else null);
}

fn sampleEdge(r: Reader, id: u32) Error![]const V3 {
    const args = r.m.args(id, "EDGE_CURVE") orelse return error.InvalidStep;
    if (args.len < 5) return error.InvalidStep;
    const p0 = vertexPoint(r, args[1].asRef());
    const p1 = vertexPoint(r, args[2].asRef());
    const same = args[4].asBool();
    const c = try r.curve(args[3].asRef());
    var out: std.ArrayList(V3) = .empty;
    try out.append(r.a, p0);
    switch (c) {
        .line, .other => {},
        .circle, .ellipse => {
            const rad = switch (c) {
                .circle => |k| k.r,
                .ellipse => |e| @max(e.a, e.b),
                else => unreachable,
            };
            var t0 = c.param(p0);
            var t1 = c.param(p1);
            const two = 2 * std.math.pi;
            // The way of the edge: up the parameter with the sense of the
            // curve, else down. The same vertex at both ends: a full turn.
            if (same) {
                if (t1 <= t0 + 1e-9) t1 += two;
            } else {
                if (t0 <= t1 + 1e-9) t0 += two;
            }
            const n = arcSteps(rad, @abs(t1 - t0));
            for (1..n) |i| {
                const t = t0 + (t1 - t0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                try out.append(r.a, c.point(t));
            }
        },
        .bspline => {
            const rg = c.range();
            var t0 = c.param(p0);
            var t1 = c.param(p1);
            // A closed curve with one vertex: the whole curve.
            if (dist(p0, p1) < 1e-9 and @abs(t1 - t0) < (rg[1] - rg[0]) * 1e-6) {
                t0 = if (same) rg[0] else rg[1];
                t1 = if (same) rg[1] else rg[0];
            }
            try subdivide(r.a, c, t0, t1, c.point(t0), c.point(t1), &out, 0);
        },
    }
    try out.append(r.a, p1);
    return out.toOwnedSlice(r.a);
}

/// The steps of an arc of radius r and angle `angle` so that each chord
/// is within `tolerance` of the arc (and no step over 10 degrees).
fn arcSteps(r: f64, angle: f64) usize {
    if (!(r > 0) or !(angle > 0)) return 1;
    const by_tol = 2 * std.math.acos(@max(-1.0, 1 - tolerance / r));
    const step = @min(by_tol, std.math.pi / 18.0);
    const n: usize = @intFromFloat(@ceil(angle / @max(step, 1e-6)));
    return std.math.clamp(n, 1, 4096);
}

/// Adds the inner points of the curve from t0 to t1 (not the ends),
/// split in halves until each chord is within `tolerance`.
fn subdivide(a: Allocator, c: Curve, t0: f64, t1: f64, p0: V3, p1: V3, out: *std.ArrayList(V3), depth: u32) Allocator.Error!void {
    const tm = (t0 + t1) / 2;
    const pm = c.point(tm);
    // Test two more points too: a chord can be near the middle and far
    // from the rest.
    const q1 = c.point(t0 + (t1 - t0) / 4);
    const q3 = c.point(t0 + 3 * (t1 - t0) / 4);
    const far = segDist(pm, p0, p1) > tolerance or segDist(q1, p0, p1) > tolerance or segDist(q3, p0, p1) > tolerance;
    if (depth < 4 or (far and depth < 16)) {
        try subdivide(a, c, t0, tm, p0, pm, out, depth + 1);
        try out.append(a, pm);
        try subdivide(a, c, tm, t1, pm, p1, out, depth + 1);
    }
}

fn segDist(p: V3, a: V3, b: V3) f64 {
    const d = sub(b, a);
    const l2 = dot(d, d);
    if (l2 == 0) return dist(p, a);
    const t = std.math.clamp(dot(sub(p, a), d) / l2, 0, 1);
    return dist(p, add(a, mul(d, t)));
}

// ---------------------------------------------------------------- faces

const V2 = [2]f64;

/// A face in work: its points (3D, and 2D in the chart) and its loops.
const FaceWork = struct {
    p3: std.ArrayList(V3) = .empty,
    p2: std.ArrayList(V2) = .empty,
    /// The surface parameters of each point.
    uv: std.ArrayList(V2) = .empty,
    loops: std.ArrayList([]u32) = .empty,
};

const Chart = struct {
    polar_u: bool = false,
    polar_v: bool = false,
    su: f64 = 1,
    sv: f64 = 1,
    /// The radius of the polar chart at the lowest value of the other
    /// parameter, and that value.
    r0: f64 = 1,
    base: f64 = 0,
    /// The angle of the polar chart for one unit of the periodic
    /// parameter: 2 pi over its period.
    ka: f64 = 1,

    fn to2(c: Chart, uv: V2) V2 {
        if (c.polar_u) {
            const rho = (uv[1] - c.base) * c.sv + c.r0;
            return .{ rho * @cos(uv[0] * c.ka), rho * @sin(uv[0] * c.ka) };
        }
        if (c.polar_v) {
            const rho = (uv[0] - c.base) * c.su + c.r0;
            return .{ rho * @cos(uv[1] * c.ka), rho * @sin(uv[1] * c.ka) };
        }
        return .{ uv[0] * c.su, uv[1] * c.sv };
    }

    fn toUv(c: Chart, q: V2) V2 {
        if (c.polar_u) {
            const rho = @sqrt(q[0] * q[0] + q[1] * q[1]);
            return .{ std.math.atan2(q[1], q[0]) / c.ka, (rho - c.r0) / c.sv + c.base };
        }
        if (c.polar_v) {
            const rho = @sqrt(q[0] * q[0] + q[1] * q[1]);
            return .{ (rho - c.r0) / c.su + c.base, std.math.atan2(q[1], q[0]) / c.ka };
        }
        return .{ q[0] / c.su, q[1] / c.sv };
    }
};

/// Adds the triangles of one ADVANCED_FACE to `b`.
fn face(r: Reader, edges: *Edges, id: u32, b: *mesh_mod.Builder) Error!void {
    const args = r.m.args(id, "ADVANCED_FACE") orelse r.m.args(id, "FACE_SURFACE") orelse return;
    if (args.len < 4) return;
    const surf = try r.surface(args[2].asRef());
    const sense = args[3].asBool();
    var fw: FaceWork = .{};
    // The loops, as points in 3D.
    for (args[1].asList()) |bv| {
        const bargs = r.m.args(bv.asRef(), "FACE_OUTER_BOUND") orelse r.m.args(bv.asRef(), "FACE_BOUND") orelse continue;
        if (bargs.len < 3) continue;
        const loop_args = r.m.args(bargs[1].asRef(), "EDGE_LOOP") orelse continue;
        if (loop_args.len < 2) continue;
        var loop: std.ArrayList(u32) = .empty;
        for (loop_args[1].asList()) |ov| {
            const oe = r.m.args(ov.asRef(), "ORIENTED_EDGE") orelse continue;
            if (oe.len < 5) continue;
            const eid = oe[3].asRef() orelse continue;
            const pts = try edges.get(r, eid);
            const fwd = oe[4].asBool();
            // All points but the last: the next edge starts there.
            for (0..pts.len - 1) |k| {
                const q = if (fwd) pts[k] else pts[pts.len - 1 - k];
                try loop.append(r.a, @intCast(fw.p3.items.len));
                try fw.p3.append(r.a, q);
            }
        }
        if (!bargs[2].asBool()) std.mem.reverse(u32, loop.items);
        if (loop.items.len >= 2) try fw.loops.append(r.a, loop.items);
    }
    if (fw.loops.items.len == 0) {
        // A whole sphere: one face with no edge.
        if (surf.kind == .sphere) try fullSphere(surf, sense, b);
        return;
    }
    // The weld of the mesh needs the same values on both faces of an
    // edge: the points stay as sampled.
    if (surf.kind == .plane or surf.kind == .other) {
        try planarFace(r, &fw, surf, sense, b);
        return;
    }
    try curvedFace(r, &fw, surf, sense, b);
}

/// The 2D points of a plane face (or a face of a surface that zslice
/// does not read: the plane of its outer loop), then the triangles.
fn planarFace(r: Reader, fw: *FaceWork, surf: Surface, sense: bool, b: *mesh_mod.Builder) Error!void {
    var f = surf.f;
    var n = f.z;
    if (surf.kind != .plane) {
        // Newell normal of the first loop: its loop turns about the normal
        // of the face.
        var nn: V3 = .{ 0, 0, 0 };
        const l = fw.loops.items[0];
        for (l, 0..) |pi, k| {
            const p = fw.p3.items[pi];
            const q = fw.p3.items[l[(k + 1) % l.len]];
            nn = add(nn, .{ (p[1] - q[1]) * (p[2] + q[2]), (p[2] - q[2]) * (p[0] + q[0]), (p[0] - q[0]) * (p[1] + q[1]) });
        }
        if (len(nn) == 0) return;
        n = norm(nn);
        f.o = fw.p3.items[l[0]];
        f.z = n;
        const x: V3 = if (@abs(n[0]) < 0.9) .{ 1, 0, 0 } else .{ 0, 1, 0 };
        f.x = norm(sub(x, mul(n, dot(x, n))));
        f.y = cross(n, f.x);
    } else if (!sense) n = mul(n, -1);
    for (fw.p3.items) |p| {
        const q = f.local(p);
        try fw.p2.append(r.a, .{ q[0], q[1] });
    }
    const tris = try triangulate(r.a, fw.p2.items, fw.loops.items);
    // The chart of the plane: x, y, and the normal turn as the face (n).
    try emitAll(fw.p3.items, tris, dot(cross(f.x, f.y), n) >= 0, b);
}

fn emit(p3: []const V3, t: [3]u32, n: V3, b: *mesh_mod.Builder) Error!void {
    const a = p3[t[0]];
    const c1 = p3[t[1]];
    const c2 = p3[t[2]];
    const tn = cross(sub(c1, a), sub(c2, a));
    const v = struct {
        fn f(p: V3) mesh_mod.Vec3 {
            return .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]), .z = @floatCast(p[2]) };
        }
    }.f;
    if (dot(tn, n) >= 0) {
        b.addTriangle(v(a), v(c1), v(c2)) catch |e| return mapMesh(e);
    } else {
        b.addTriangle(v(a), v(c2), v(c1)) catch |e| return mapMesh(e);
    }
}

fn mapMesh(e: mesh_mod.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidStep,
    };
}

/// A face of a curved surface: the chart, the triangles, the refinement.
fn curvedFace(r: Reader, fw: *FaceWork, surf_in: Surface, sense: bool, b: *mesh_mod.Builder) Error!void {
    var surf = surf_in;
    surf.periods();
    const pu = surf.pu;
    const pv = surf.pv;
    // The parameters of each point, unwrapped along each loop.
    try fw.uv.resize(r.a, fw.p3.items.len);
    var wind_u = false;
    var wind_v = false;
    var hint: ?[2]f64 = null;
    for (fw.loops.items) |loop| {
        var prev: ?V2 = null;
        var start: V2 = .{ 0, 0 };
        for (loop, 0..) |pi, k| {
            var uv = surf.param(fw.p3.items[pi], hint);
            hint = uv;
            if (prev) |prv| {
                if (pu > 0) uv[0] += pu * @round((prv[0] - uv[0]) / pu);
                if (pv > 0) uv[1] += pv * @round((prv[1] - uv[1]) / pv);
                // A point on the axis (a pole, an apex) has no angle.
                if (singular(surf, fw.p3.items[pi])) uv[0] = prv[0];
            } else start = uv;
            if (k == 0) start = uv;
            fw.uv.items[pi] = uv;
            prev = uv;
        }
        // The closing step: a loop that goes once around.
        if (prev) |prv| {
            if (pu > 0) {
                const back = start[0] + pu * @round((prv[0] - start[0]) / pu);
                if (@abs(back - start[0]) > pu / 2) wind_u = true;
            }
            if (pv > 0) {
                const back = start[1] + pv * @round((prv[1] - start[1]) / pv);
                if (@abs(back - start[1]) > pv / 2) wind_v = true;
            }
        }
    }
    // The poles: the angle of a neighbor in the loop.
    for (fw.loops.items) |loop| for (loop, 0..) |pi, k| {
        if (!singular(surf, fw.p3.items[pi])) continue;
        const nx = loop[(k + 1) % loop.len];
        fw.uv.items[pi][0] = fw.uv.items[nx][0];
    };
    // The holes go into the turn of the outer loop (a multiple of 2 pi).
    if (!wind_u and !wind_v and fw.loops.items.len > 1) {
        const outer = fw.loops.items[0];
        const om = meanUv(fw.uv.items, outer);
        for (fw.loops.items[1..]) |loop| {
            const lm = meanUv(fw.uv.items, loop);
            var du: f64 = 0;
            var dv: f64 = 0;
            if (pu > 0) du = pu * @round((om[0] - lm[0]) / pu);
            if (pv > 0) dv = pv * @round((om[1] - lm[1]) / pv);
            for (loop) |pi| {
                fw.uv.items[pi][0] += du;
                fw.uv.items[pi][1] += dv;
            }
        }
    }
    // The chart: the parameters scaled to lengths.
    var chart: Chart = .{};
    var lo: V2 = .{ std.math.inf(f64), std.math.inf(f64) };
    var hi: V2 = .{ -std.math.inf(f64), -std.math.inf(f64) };
    for (fw.uv.items) |uv| for (0..2) |k| {
        lo[k] = @min(lo[k], uv[k]);
        hi[k] = @max(hi[k], uv[k]);
    };
    const mid: V2 = .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
    {
        const e = 1e-4;
        chart.su = @max(1e-6, dist(surf.point(mid[0] + e, mid[1]), surf.point(mid[0] - e, mid[1])) / (2 * e));
        chart.sv = @max(1e-6, dist(surf.point(mid[0], mid[1] + e), surf.point(mid[0], mid[1] - e)) / (2 * e));
    }
    if (wind_u) {
        chart.ka = 2 * std.math.pi / pu;
        chart.polar_u = true;
        chart.base = lo[1];
        chart.r0 = @max((hi[1] - lo[1]) * chart.sv, 1.0);
    } else if (wind_v) {
        chart.ka = 2 * std.math.pi / pv;
        chart.polar_v = true;
        chart.base = lo[0];
        chart.r0 = @max((hi[0] - lo[0]) * chart.su, 1.0);
    }
    try fw.p2.resize(r.a, fw.p3.items.len);
    for (fw.uv.items, fw.p2.items) |uv, *q| q.* = chart.to2(uv);
    var tris: std.ArrayList([3]u32) = .empty;
    try tris.appendSlice(r.a, try triangulate(r.a, fw.p2.items, fw.loops.items));
    try refine(r.a, fw, &tris, surf, chart);
    // All triangles turn the same way in the chart (counterclockwise).
    // A vote of the triangles against the surface normal gives the way of
    // the whole face, so a thin triangle cannot turn on its own.
    var vote: f64 = 0;
    for (tris.items) |t| {
        const c = centroid2(fw.p2.items, t);
        const uv = chart.toUv(c);
        const n = surf.normal(uv[0], uv[1]);
        const p = fw.p3.items;
        vote += dot(cross(sub(p[t[1]], p[t[0]]), sub(p[t[2]], p[t[0]])), n);
    }
    try emitAll(fw.p3.items, tris.items, (vote >= 0) == sense, b);
}

/// Adds triangles as they are (`keep`), or turned over.
fn emitAll(p3: []const V3, tris: []const [3]u32, keep: bool, b: *mesh_mod.Builder) Error!void {
    for (tris) |t| {
        const q: [3]u32 = if (keep) t else .{ t[0], t[2], t[1] };
        b.addTriangle(vec3(p3[q[0]]), vec3(p3[q[1]]), vec3(p3[q[2]])) catch |e| return mapMesh(e);
    }
}

fn vec3(p: V3) mesh_mod.Vec3 {
    return .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]), .z = @floatCast(p[2]) };
}

/// A whole sphere: rings of latitude, and a fan at each pole.
fn fullSphere(surf: Surface, sense: bool, b: *mesh_mod.Builder) Error!void {
    const nu = @max(arcSteps(surf.r, 2 * std.math.pi), 8);
    const nv = @max(arcSteps(surf.r, std.math.pi), 4);
    for (0..nv) |j| {
        const va = -std.math.pi / 2.0 + std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(nv));
        const vb = -std.math.pi / 2.0 + std.math.pi * @as(f64, @floatFromInt(j + 1)) / @as(f64, @floatFromInt(nv));
        for (0..nu) |i| {
            const ua = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nu));
            const ub = 2 * std.math.pi * @as(f64, @floatFromInt((i + 1) % nu)) / @as(f64, @floatFromInt(nu));
            // The poles are one point each.
            const p00 = if (j == 0) surf.point(0, va) else surf.point(ua, va);
            const p10 = if (j == 0) surf.point(0, va) else surf.point(ub, va);
            const p01 = if (j + 1 == nv) surf.point(0, vb) else surf.point(ua, vb);
            const p11 = if (j + 1 == nv) surf.point(0, vb) else surf.point(ub, vb);
            var n = norm(sub(mul(add(add(p00, p10), add(p01, p11)), 0.25), surf.f.o));
            if (!sense) n = mul(n, -1);
            const pts = [_]V3{ p00, p10, p11, p01 };
            if (j != 0) try emit(&pts, .{ 0, 1, 2 }, n, b);
            if (j + 1 != nv) try emit(&pts, .{ 0, 2, 3 }, n, b);
        }
    }
}

fn singular(surf: Surface, p: V3) bool {
    const q = surf.f.local(p);
    const h = @sqrt(q[0] * q[0] + q[1] * q[1]);
    return switch (surf.kind) {
        .sphere, .cone, .revolution => h < 1e-7,
        else => false,
    };
}

fn meanUv(uv: []const V2, loop: []const u32) V2 {
    var s: V2 = .{ 0, 0 };
    for (loop) |pi| {
        s[0] += uv[pi][0];
        s[1] += uv[pi][1];
    }
    const n: f64 = @floatFromInt(@max(loop.len, 1));
    return .{ s[0] / n, s[1] / n };
}

fn centroid2(p: []const V2, t: [3]u32) V2 {
    return .{ (p[t[0]][0] + p[t[1]][0] + p[t[2]][0]) / 3, (p[t[0]][1] + p[t[1]][1] + p[t[2]][1]) / 3 };
}

/// Splits the inner edges (not on a loop) whose middle on the surface is
/// more than `tolerance` from the chord, and their triangles; then the
/// triangles whose center is still far, at their center. A few rounds.
fn refine(a: Allocator, fw: *FaceWork, tris: *std.ArrayList([3]u32), surf: Surface, chart: Chart) Error!void {
    // The edges of the loops.
    var bound: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (fw.loops.items) |loop| for (loop, 0..) |pi, k| {
        try bound.put(a, ekey(pi, loop[(k + 1) % loop.len]), {});
    };
    const max_tris = 200_000;
    try flips(a, fw.p2.items, tris, &bound);
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        var mids: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        // Mark the edges to split.
        for (tris.items) |t| for (0..3) |k| {
            const i = t[k];
            const j = t[(k + 1) % 3];
            const key = ekey(i, j);
            if (bound.contains(key) or mids.contains(key)) continue;
            const m2: V2 = .{ (fw.p2.items[i][0] + fw.p2.items[j][0]) / 2, (fw.p2.items[i][1] + fw.p2.items[j][1]) / 2 };
            const uv = chart.toUv(m2);
            const s = surf.point(uv[0], uv[1]);
            const chord = mul(add(fw.p3.items[i], fw.p3.items[j]), 0.5);
            if (dist(s, chord) <= tolerance) continue;
            const idx: u32 = @intCast(fw.p3.items.len);
            try fw.p3.append(a, s);
            try fw.p2.append(a, m2);
            try mids.put(a, key, idx);
        };
        if (mids.count() == 0 or tris.items.len > max_tris) break;
        var next: std.ArrayList([3]u32) = .empty;
        for (tris.items) |t| {
            var m: [3]?u32 = .{ null, null, null };
            var n_split: usize = 0;
            for (0..3) |k| {
                m[k] = mids.get(ekey(t[k], t[(k + 1) % 3]));
                if (m[k] != null) n_split += 1;
            }
            switch (n_split) {
                0 => try next.append(a, t),
                3 => {
                    try next.append(a, .{ t[0], m[0].?, m[2].? });
                    try next.append(a, .{ m[0].?, t[1], m[1].? });
                    try next.append(a, .{ m[2].?, m[1].?, t[2] });
                    try next.append(a, .{ m[0].?, m[1].?, m[2].? });
                },
                else => {
                    // One or two split edges: a fan from the first split
                    // middle over the rest of the triangle.
                    var poly: [5]u32 = undefined;
                    var np: usize = 0;
                    for (0..3) |k| {
                        poly[np] = t[k];
                        np += 1;
                        if (m[k]) |mv| {
                            poly[np] = mv;
                            np += 1;
                        }
                    }
                    // Start the fan at a middle point.
                    var s0: usize = 0;
                    for (0..np) |k| if (!isCorner(poly[k], t)) {
                        s0 = k;
                        break;
                    };
                    for (1..np - 1) |k| {
                        try next.append(a, .{ poly[s0], poly[(s0 + k) % np], poly[(s0 + k + 1) % np] });
                    }
                },
            }
        }
        tris.deinit(a);
        tris.* = next;
        try flips(a, fw.p2.items, tris, &bound);
    }
}

/// Flips the inner edges (not on a loop) of the triangles until they are
/// Delaunay in the chart: no point inside the circle of the triangle on
/// the other side of an edge (the flips of Lawson, with a stack of the
/// edges to test). On a cylinder, the triangles then go across in
/// strips, and few edges need a split.
fn flips(a: Allocator, p: []const V2, tris: *std.ArrayList([3]u32), bound: *const std.AutoHashMapUnmanaged(u64, void)) Allocator.Error!void {
    const none = std.math.maxInt(u32);
    const n = tris.items.len;
    // The triangle across each edge k (from corner k to corner k + 1).
    const nb = try a.alloc([3]u32, n);
    defer a.free(nb);
    const fixed = try a.alloc([3]bool, n);
    defer a.free(fixed);
    {
        var first: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer first.deinit(a);
        for (tris.items, 0..) |t, ti| for (0..3) |k| {
            nb[ti][k] = none;
            const key = ekey(t[k], t[(k + 1) % 3]);
            fixed[ti][k] = bound.contains(key);
            if (first.fetchRemove(key)) |kv| {
                const o = kv.value;
                nb[ti][k] = o;
                const ot = tris.items[o];
                for (0..3) |q| if (ekey(ot[q], ot[(q + 1) % 3]) == key) {
                    nb[o][q] = @intCast(ti);
                };
            } else try first.put(a, key, @intCast(ti));
        };
    }
    var stack: std.ArrayList([2]u32) = .empty;
    defer stack.deinit(a);
    for (0..n) |ti| for (0..3) |k| if (!fixed[ti][k] and nb[ti][k] != none) try stack.append(a, .{ @intCast(ti), @intCast(k) });
    var budget: usize = 64 * n + 1024;
    while (stack.pop()) |e| {
        if (budget == 0) break;
        budget -= 1;
        const t1i = e[0];
        const k1 = e[1];
        const t2i = nb[t1i][k1];
        if (t2i == none or fixed[t1i][k1]) continue;
        const t1 = tris.items[t1i];
        const t2 = tris.items[t2i];
        const ea = t1[k1];
        const eb = t1[(k1 + 1) % 3];
        const c = t1[(k1 + 2) % 3];
        var k2: u32 = 3;
        for (0..3) |q| if (t2[q] == eb and t2[(q + 1) % 3] == ea) {
            k2 = @intCast(q);
        };
        if (k2 == 3) continue;
        const d = t2[(k2 + 2) % 3];
        if (c == d) continue;
        if (!inCircle(p[ea], p[eb], p[c], p[d])) continue;
        if (!(turn(p[ea], p[d], p[c]) > 0 and turn(p[d], p[eb], p[c]) > 0)) continue;
        // The outer edges and their neighbors and flags.
        const n_bc = nb[t1i][(k1 + 1) % 3];
        const n_ca = nb[t1i][(k1 + 2) % 3];
        const f_bc = fixed[t1i][(k1 + 1) % 3];
        const f_ca = fixed[t1i][(k1 + 2) % 3];
        const n_ad = nb[t2i][(k2 + 1) % 3];
        const n_db = nb[t2i][(k2 + 2) % 3];
        const f_ad = fixed[t2i][(k2 + 1) % 3];
        const f_db = fixed[t2i][(k2 + 2) % 3];
        // t1 = (c, a, d), t2 = (d, b, c).
        tris.items[t1i] = .{ c, ea, d };
        nb[t1i] = .{ n_ca, n_ad, t2i };
        fixed[t1i] = .{ f_ca, f_ad, false };
        tris.items[t2i] = .{ d, eb, c };
        nb[t2i] = .{ n_db, n_bc, t1i };
        fixed[t2i] = .{ f_db, f_bc, false };
        // n_ad now borders t1, and n_bc borders t2.
        if (n_ad != none) for (0..3) |q| if (nb[n_ad][q] == t2i) {
            nb[n_ad][q] = t1i;
        };
        if (n_bc != none) for (0..3) |q| if (nb[n_bc][q] == t1i) {
            nb[n_bc][q] = t2i;
        };
        try stack.append(a, .{ t1i, 0 });
        try stack.append(a, .{ t1i, 1 });
        try stack.append(a, .{ t2i, 0 });
        try stack.append(a, .{ t2i, 1 });
    }
}

/// True if d is inside the circle through a, b, c (counterclockwise).
fn inCircle(a: V2, b: V2, c: V2, d: V2) bool {
    const ax = a[0] - d[0];
    const ay = a[1] - d[1];
    const bx = b[0] - d[0];
    const by = b[1] - d[1];
    const cx = c[0] - d[0];
    const cy = c[1] - d[1];
    const det = (ax * ax + ay * ay) * (bx * cy - cx * by) - (bx * bx + by * by) * (ax * cy - cx * ay) + (cx * cx + cy * cy) * (ax * by - bx * ay);
    // A small margin: four points on one circle do not flip back and forth.
    const scale = (ax * ax + ay * ay + bx * bx + by * by + cx * cx + cy * cy);
    return det > 1e-12 * scale * scale;
}

fn isCorner(v: u32, t: [3]u32) bool {
    return v == t[0] or v == t[1] or v == t[2];
}

fn ekey(i: u32, j: u32) u64 {
    const lo = @min(i, j);
    const hi = @max(i, j);
    return (@as(u64, lo) << 32) | hi;
}

// ---------------------------------------------------------------- triangulation

fn area2(p: []const V2, loop: []const u32) f64 {
    var s: f64 = 0;
    for (loop, 0..) |i, k| {
        const j = loop[(k + 1) % loop.len];
        s += p[i][0] * p[j][1] - p[j][0] * p[i][1];
    }
    return s / 2;
}

/// The triangles (point indices) of the polygon of the loops in 2D: the
/// loop of the largest area is the outline (counterclockwise), the others
/// are holes (clockwise). Each hole joins the outline by a bridge from
/// its rightmost point, then ear clipping.
fn triangulate(a: Allocator, p: []const V2, loops: []const []u32) Error![]const [3]u32 {
    var outer_k: usize = 0;
    var best: f64 = -1;
    for (loops, 0..) |l, k| {
        const ar = @abs(area2(p, l));
        if (ar > best) {
            best = ar;
            outer_k = k;
        }
    }
    var poly: std.ArrayList(u32) = .empty;
    try poly.appendSlice(a, loops[outer_k]);
    if (area2(p, poly.items) < 0) std.mem.reverse(u32, poly.items);
    var holes: std.ArrayList([]u32) = .empty;
    for (loops, 0..) |l, k| {
        if (k == outer_k or l.len < 3) continue;
        const h = try a.dupe(u32, l);
        if (area2(p, h) > 0) std.mem.reverse(u32, h);
        try holes.append(a, h);
    }
    const Ctx = struct {
        p: []const V2,
        fn maxX(c: @This(), h: []const u32) f64 {
            var m: f64 = -std.math.inf(f64);
            for (h) |i| m = @max(m, c.p[i][0]);
            return m;
        }
        fn lt(c: @This(), x: []u32, y: []u32) bool {
            return c.maxX(x) > c.maxX(y);
        }
    };
    std.mem.sort([]u32, holes.items, Ctx{ .p = p }, Ctx.lt);
    for (holes.items) |h| try bridge(a, p, &poly, h);
    var out: std.ArrayList([3]u32) = .empty;
    try earClip(a, p, poly.items, &out);
    return out.toOwnedSlice(a);
}

fn segCross(a: V2, b: V2, c: V2, d: V2) bool {
    const o = struct {
        fn f(p: V2, q: V2, r: V2) f64 {
            return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
        }
    }.f;
    const d1 = o(c, d, a);
    const d2 = o(c, d, b);
    const d3 = o(a, b, c);
    const d4 = o(a, b, d);
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

fn bridge(a: Allocator, p: []const V2, poly: *std.ArrayList(u32), hole: []const u32) Error!void {
    var hi: usize = 0;
    for (hole, 0..) |q, i| if (p[q][0] > p[hole[hi]][0]) {
        hi = i;
    };
    const m = p[hole[hi]];
    var best: ?usize = null;
    var best_d: f64 = std.math.inf(f64);
    for (poly.items, 0..) |pi, i| {
        const q = p[pi];
        if (q[0] < m[0]) continue;
        const d = (q[0] - m[0]) * (q[0] - m[0]) + (q[1] - m[1]) * (q[1] - m[1]);
        if (d >= best_d) continue;
        var crosses = false;
        for (poly.items, 0..) |pj, j| {
            const k = (j + 1) % poly.items.len;
            if (j == i or k == i) continue;
            if (segCross(m, q, p[pj], p[poly.items[k]])) {
                crosses = true;
                break;
            }
        }
        if (crosses) continue;
        best = i;
        best_d = d;
    }
    const at = best orelse blk: {
        var k: usize = 0;
        var kd: f64 = std.math.inf(f64);
        for (poly.items, 0..) |pi, i| {
            const q = p[pi];
            const d = (q[0] - m[0]) * (q[0] - m[0]) + (q[1] - m[1]) * (q[1] - m[1]);
            if (d < kd) {
                kd = d;
                k = i;
            }
        }
        break :blk k;
    };
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(a, poly.items[0 .. at + 1]);
    for (0..hole.len + 1) |k| try out.append(a, hole[(hi + k) % hole.len]);
    try out.appendSlice(a, poly.items[at..]);
    poly.* = out;
}

/// Ear clipping of a simple counterclockwise polygon of point indices
/// (holes joined by bridges, so an index can come twice).
fn earClip(a: Allocator, p: []const V2, poly_in: []const u32, out: *std.ArrayList([3]u32)) Error!void {
    var idx: std.ArrayList(u32) = .empty;
    try idx.appendSlice(a, poly_in);
    var guard: usize = 0;
    var i: usize = 0;
    while (idx.items.len > 3) {
        const n = idx.items.len;
        const ia = idx.items[(i + n - 1) % n];
        const ib = idx.items[i % n];
        const ic = idx.items[(i + 1) % n];
        if (isEar(p, idx.items, ia, ib, ic)) {
            try out.append(a, .{ ia, ib, ic });
            _ = idx.orderedRemove(i % n);
            guard = 0;
            if (i > 0) i -= 1;
        } else {
            i = (i + 1) % n;
            guard += 1;
            if (guard > n + 2) {
                // No ear (a flaw in the loops): cut the vertex with the
                // most convex turn, so the face still closes.
                var best: usize = 0;
                var best_t: f64 = -std.math.inf(f64);
                for (0..n) |k| {
                    const t = turn(p[idx.items[(k + n - 1) % n]], p[idx.items[k]], p[idx.items[(k + 1) % n]]);
                    if (t > best_t) {
                        best_t = t;
                        best = k;
                    }
                }
                try out.append(a, .{ idx.items[(best + n - 1) % n], idx.items[best], idx.items[(best + 1) % n] });
                _ = idx.orderedRemove(best);
                guard = 0;
                i = 0;
            }
        }
    }
    if (idx.items.len == 3) try out.append(a, .{ idx.items[0], idx.items[1], idx.items[2] });
}

fn turn(a: V2, b: V2, c: V2) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn isEar(p: []const V2, idx: []const u32, ia: u32, ib: u32, ic: u32) bool {
    const a = p[ia];
    const b = p[ib];
    const c = p[ic];
    if (turn(a, b, c) <= 0) return false;
    const n = idx.len;
    for (idx, 0..) |k, j| {
        if (k == ia or k == ib or k == ic) continue;
        const q = p[k];
        if ((q[0] == a[0] and q[1] == a[1]) or (q[0] == b[0] and q[1] == b[1]) or (q[0] == c[0] and q[1] == c[1])) continue;
        // Only a reflex point can be inside an ear.
        if (turn(p[idx[(j + n - 1) % n]], q, p[idx[(j + 1) % n]]) > 0) continue;
        if (turn(a, b, q) >= 0 and turn(b, c, q) >= 0 and turn(c, a, q) >= 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------- the file

/// Reads a STEP file into a mesh (mm). The faces of all solids and
/// shells of the file make one mesh.
pub fn read(gpa: Allocator, bytes: []const u8) Error!Mesh {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try Model.parse(a, bytes);
    const r: Reader = .{ .a = a, .m = &m };
    var edges: Edges = .{};
    var b: mesh_mod.Builder = .init(gpa);
    errdefer b.deinit();
    var faces: usize = 0;
    for (m.order.items) |id| {
        if (!(m.has(id, "ADVANCED_FACE") or m.has(id, "FACE_SURFACE"))) continue;
        faces += 1;
        try face(r, &edges, id, &b);
    }
    if (faces == 0) return error.NoSolid;
    return b.finish() catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NoSolid,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn volume(mesh: Mesh) f64 {
    var v: f64 = 0;
    for (mesh.faces.items) |f| {
        const p = mesh.vertices.items[f[0]];
        const q = mesh.vertices.items[f[1]];
        const s = mesh.vertices.items[f[2]];
        v += (@as(f64, p.x) * (@as(f64, q.y) * s.z - @as(f64, q.z) * s.y) - @as(f64, p.y) * (@as(f64, q.x) * s.z - @as(f64, q.z) * s.x) + @as(f64, p.z) * (@as(f64, q.x) * s.y - @as(f64, q.y) * s.x)) / 6;
    }
    return v;
}

/// Each edge of a closed mesh has two faces, one in each direction.
fn closed(mesh: Mesh) !bool {
    var count: std.AutoHashMapUnmanaged(u64, i32) = .empty;
    defer count.deinit(testing.allocator);
    for (mesh.faces.items) |f| for (0..3) |k| {
        const i = f[k];
        const j = f[(k + 1) % 3];
        const key = (@as(u64, @min(i, j)) << 32) | @max(i, j);
        const gop = try count.getOrPut(testing.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += if (i < j) 1 else -1;
    };
    var it = count.valueIterator();
    while (it.next()) |v| if (v.* != 0) return false;
    return true;
}

/// The STEP files of the tests (made with FreeCAD 1.0 and Open CASCADE
/// 7.9), and the volume of each solid (mm³) as FreeCAD gives it.
const test_files = [_]struct { name: []const u8, text: []const u8, volume: f64 }{
    // A 20 x 20 x 10 mm block with a hole of radius 5: planes, and a
    // cylinder face with a seam edge.
    .{ .name = "block_hole", .text = @embedFile("testdata/step/block_hole.step"), .volume = 3214.601836602551 },
    // A cylinder of radius 0.5 in and height 1 in, with its side as one
    // face between its two circles (no seam edge): a polar chart.
    .{ .name = "cylinder_inch", .text = @embedFile("testdata/step/cylinder_inch.step"), .volume = 0.7853981633974482 * 25.4 * 25.4 * 25.4 },
    // A whole sphere: one face with no edge.
    .{ .name = "sphere", .text = @embedFile("testdata/step/sphere.step"), .volume = 4188.790204786391 },
    // A torus with two seam edges.
    .{ .name = "torus", .text = @embedFile("testdata/step/torus.step"), .volume = 1776.5287921960844 },
    // A cut cone.
    .{ .name = "cone", .text = @embedFile("testdata/step/cone.step"), .volume = 326.72563597333846 },
    // A box with all edges round: cylinders, spheres at the corners.
    .{ .name = "fillet_box", .text = @embedFile("testdata/step/fillet_box.step"), .volume = 2263.0678106834253 },
    // A loft from a circle to a square: B-spline faces.
    .{ .name = "loft", .text = @embedFile("testdata/step/loft.step"), .volume = 1054.1108075339255 },
};

test "step: the volume of each solid, and a closed mesh" {
    for (test_files) |f| {
        var mesh = Mesh.fromStl(testing.allocator, f.text) catch |e| {
            std.debug.print("{s}: {s}\n", .{ f.name, @errorName(e) });
            return e;
        };
        defer mesh.deinit(testing.allocator);
        const v = volume(mesh);
        if (!(@abs(v - f.volume) <= f.volume * 5e-3) or !(try closed(mesh))) {
            std.debug.print("{s}: volume {d:.3}, want {d:.3}, closed {}\n", .{ f.name, v, f.volume, try closed(mesh) });
            return error.TestUnexpectedResult;
        }
    }
}

test "step: B-spline curve and surface evaluation" {
    // A degree 1 by 1 surface is a bilinear patch.
    const cps = [_]V3{ .{ 0, 0, 0 }, .{ 0, 10, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 5 } };
    const w = [_]f64{ 1, 1, 1, 1 };
    const k = [_]f64{ 0, 0, 1, 1 };
    const bs: BSpline = .{ .deg = 1, .degv = 1, .cps = &cps, .w = &w, .ku = &k, .kv = &k, .nu = 2, .nv = 2 };
    const p = bs.surfacePoint(0.5, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 5), p[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), p[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.25), p[2], 1e-12);
    // A rational quadratic arc: a quarter circle of radius 1.
    const arc = [_]V3{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } };
    const aw = [_]f64{ 1, std.math.sqrt1_2, 1 };
    const ak = [_]f64{ 0, 0, 0, 1, 1, 1 };
    const c: Curve = .{ .bspline = .{ .deg = 2, .cps = &arc, .w = &aw, .ku = &ak, .nu = 3 } };
    for (0..11) |i| {
        const q = c.point(@as(f64, @floatFromInt(i)) / 10);
        try testing.expectApproxEqAbs(@as(f64, 1), len(q), 1e-12);
    }
}

test "step: not a STEP file" {
    try testing.expect(!isStep("solid x\n"));
    try testing.expect(isStep("ISO-10303-21;\nHEADER;\n"));
    try testing.expectError(error.InvalidStep, read(testing.allocator, "ISO-10303-21;\nDATA;\n#1=FOO(;\nENDSEC;"));
    try testing.expectError(error.NoSolid, read(testing.allocator, "ISO-10303-21;\nDATA;\n#1=CARTESIAN_POINT('',(0.,0.,0.));\nENDSEC;\nEND-ISO-10303-21;\n"));
}
