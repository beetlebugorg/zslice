//! A physical simulation of the plastic of a print: the plastic leaves the
//! nozzle, rests where something holds it, hangs or falls where no plastic
//! holds it, cools, and sets. The next layers print on the shape that formed,
//! so a missing support gives sagged bridges, drooped overhangs, and
//! strands all over, as on a real printer.
//!
//! - **Plastic.** Each extrusion is a chain of small masses at equal
//!   spacing (about half a bead width) along the path. A mass comes out at
//!   the time that the nozzle passes its point. Its mass is the plastic of
//!   its half of each link: density times bead area times length.
//! - **Support.** A height field of the solid plastic (cells of
//!   `Params.cell` mm, in tiles that exist only where plastic is) keeps the
//!   top z of the plastic, and the layer that put it there. A new mass with
//!   the bed, or the top of an earlier layer, under its bead (within
//!   `support_tol` of a bead height) is solid at once at its place. Plastic
//!   of the same layer beside it does not hold it. Else the mass is soft.
//! - **Heat.** A soft mass cools toward the room by Newton's law: dT/dt =
//!   -(T - T_room) / tau, with tau = rho c (A / P) / h for a bead of area A
//!   and perimeter P (lumped heat). The heat transfer h is the still air
//!   value plus the forced value of the fan, from the Hilpert correlation
//!   for a cylinder in cross flow (diameter 4 A / P).
//! - **Viscosity.** Hot PLA flows. Its viscosity grows as it cools: an
//!   Arrhenius law in the melt (733 Pa s at 210 °C, 86 kJ/mol, from the
//!   data of Yoo, Jeong, and Choi 2021), and the WLF law near the glass
//!   point (Williams, Landel, and Ferry 1955), whichever is larger. A soft
//!   mass sets (it is solid where it is) when its viscosity passes
//!   `set_visc`.
//! - **Contact.** A soft mass that comes down onto the bed or solid plastic
//!   sets there.
//! - **Runs.** The soft masses of a chain make runs between masses that
//!   something holds: a solid mass, or the newest mass, which the nozzle
//!   holds while the path prints.
//!   - A run held at both ends (a bridge, or a strand from an edge to the
//!     nozzle) hangs in its exact static shape: a catenary of the arc
//!     length of the run between its two ends, in their vertical plane.
//!     The hot plastic creeps under its tension: each link stretches at
//!     the rate sigma / (3 eta) (the Trouton ratio of a Newtonian fluid).
//!     The tension of a catenary is H = a w (w the weight for each mm), so
//!     sigma = rho g a. Near the taut limit the sag of a run follows
//!     slack^(3/2) += 1.5 k dt, a closed form that stays stable at any
//!     step. A longer arc gives a deeper sag and less tension, so the sag
//!     stops as the plastic cools.
//!   - A run held at one end (a strand past an edge, or from the nozzle)
//!     swings and falls with position based dynamics (Müller et al.
//!     2007), its links kept by "follow the leader" from the held end
//!     (Müller, Kim, and Chentanez 2012), so a long strand keeps its
//!     length in one pass. The hanging weight stretches it.
//!   - A run held at no end falls free, and a run that fell and is then
//!     held at both ends keeps its links by Gauss-Seidel passes and
//!     long-range attachments to both ends (Kim, Chentanez, and Müller
//!     2012).
//! - **Time.** The time jumps over the times with no free soft mass, so a
//!   print costs little more than its count of masses.
//!
//! The sources are in REFERENCES.md. Units: mm, s, g, °C. With mm and g, a
//! stress in g / (mm s²) is a stress in Pa.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const V = [3]f32;

/// One extrusion: a polyline at a layer, printed from t0 to t1.
pub const Path = struct {
    /// The points (x, y), in mm.
    xy: []const [2]f32,
    /// The nozzle z of each point, or empty for `z` at each point.
    zs: []const f32 = &.{},
    /// The nozzle z: the top of the bead (mm).
    z: f32,
    /// The bead height and width (mm).
    height: f32,
    width: f32,
    /// The bead cross section (mm²), or 0 for the area of a bead of this
    /// width and height.
    area: f32 = 0,
    t0: f32,
    t1: f32,
    /// The fan, 0 to 1.
    fan: f32,
    /// The layer, in print order. Plastic of the same layer does not hold
    /// a new mass.
    layer: u32,
};

pub const Params = struct {
    nozzle_t: f32 = 210,
    room_t: f32 = 25,
    /// The glass point of PLA.
    glass_t: f32 = 60,
    /// The density (g/mm³) and the heat capacity (J/(kg K)) of PLA.
    density: f32 = 1.24e-3,
    heat_capacity: f32 = 1800,
    /// The viscosity of the melt at `visc_ref_t` (Pa s), and the flow
    /// activation energy (J/mol) of the Arrhenius law.
    visc_ref: f32 = 733,
    visc_ref_t: f32 = 210,
    visc_ea: f32 = 86e3,
    /// The viscosity at the glass point (Pa s), for the WLF law.
    visc_glass: f32 = 1e12,
    /// A soft mass sets when its viscosity is more than this (Pa s): then
    /// gravity moves it less than a micrometer in a minute.
    set_visc: f32 = 1e6,
    /// The heat transfer of a bead in still air (W/(m² K)): natural
    /// convection of a thin cylinder (Churchill and Chu) and radiation.
    h_still: f32 = 80,
    /// The air speed (m/s) of the part fan at full speed at the bead.
    fan_air: f32 = 6,
    gravity: f32 = 9810,
    /// The air drag of a falling strand (1/s).
    air_damp: f32 = 3,
    /// The step (s), and the step of the falling strands.
    dt: f32 = 0.002,
    dt_free: f32 = 0.001,
    /// The Gauss-Seidel passes of a run that fell.
    iterations: u32 = 8,
    /// The share of the follow-the-leader correction that goes back into
    /// the speed of the mass before (Müller et al. 2012 call it s_damping).
    ftl_damp: f32 = 0.9,
    /// The mass spacing (mm), or 0 for half the bead width.
    spacing: f32 = 0,
    /// The cell of the height field (mm).
    cell: f32 = 0.1,
    /// A gap under a new mass up to this share of a bead height still
    /// holds it (the nozzle presses it down).
    support_tol: f32 = 0.5,
    /// A path whose masses all set within this distance (mm) of their
    /// place did not move.
    move_eps: f32 = 0.01,
    /// Keep the masses of all paths in the result, also of the paths that
    /// did not move (for tests).
    keep_all: bool = false,
};

/// The viscosity of PLA at t °C (Pa s): Arrhenius in the melt, WLF near
/// the glass point, whichever is larger. Infinite at the glass point.
pub fn viscosity(p: Params, t: f32) f32 {
    if (t <= p.glass_t) return std.math.inf(f32);
    const r = 8.314;
    const arr = p.visc_ref * @exp(p.visc_ea / r * (1 / (t + 273.15) - 1 / (p.visc_ref_t + 273.15)));
    // WLF with the universal constants C1 = 17.44, C2 = 51.6 K.
    const d = t - p.glass_t;
    const wlf = p.visc_glass * @exp(-17.44 * d / (51.6 + d) * std.math.ln10);
    return @max(arr, wlf);
}

/// The heat transfer (W/(m² K)) of a bead of hydraulic diameter d mm at
/// the fan share `fan`.
pub fn heatTransfer(p: Params, fan: f32, d_mm: f32) f32 {
    const speed = p.fan_air * std.math.clamp(fan, 0, 1);
    if (!(speed > 0) or !(d_mm > 0)) return p.h_still;
    // Air at a film temperature of about 100 °C.
    const k_air = 0.031;
    const nu_air = 2.3e-5;
    const pr = 0.70;
    const d = d_mm * 1e-3;
    const re = speed * d / nu_air;
    // Hilpert: Nu = C Re^m Pr^(1/3), with C and m for the range of Re.
    const cm: [2]f32 = if (re < 4) .{ 0.989, 0.330 } else if (re < 40) .{ 0.911, 0.385 } else if (re < 4000) .{ 0.683, 0.466 } else .{ 0.193, 0.618 };
    const nu = cm[0] * @exp(cm[1] * @log(re)) * std.math.cbrt(@as(f32, pr));
    return p.h_still + nu * k_air / d;
}

/// The temperature where the viscosity reaches `set_visc`.
fn setTemperature(p: Params) f32 {
    var lo = p.glass_t;
    var hi = @max(p.nozzle_t, p.glass_t + 1);
    if (viscosity(p, hi) >= p.set_visc) return hi;
    for (0..40) |_| {
        const mid = (lo + hi) / 2;
        if (viscosity(p, mid) >= p.set_visc) lo = mid else hi = mid;
    }
    return hi;
}

pub const Stats = struct {
    /// The masses, and the masses that were soft at some time.
    masses: usize = 0,
    soft_masses: usize = 0,
    /// The masses that set more than half a bead height from their place,
    /// and the largest distance (mm).
    moved: usize = 0,
    max_move: f32 = 0,
    /// The paths with a mass that set away from its place.
    moved_paths: usize = 0,
    /// The plastic (g).
    mass: f64 = 0,
    /// The most soft masses at one time, and the steps of the solver.
    peak_soft: usize = 0,
    steps: usize = 0,
};

pub const Result = struct {
    /// For each path: the first entry in `pos` and the count. The count is
    /// 0 for a path whose masses all set where it printed (unless
    /// `keep_all`).
    ranges: [][2]u32,
    /// The places where the masses set: the centers of their beads.
    pos: []V,
    /// The mass of each entry of `pos` (g), with `keep_all` only.
    mass: []f32,
    stats: Stats,

    pub fn nodes(r: *const Result, path: usize) []const V {
        const g = r.ranges[path];
        return r.pos[g[0]..][0..g[1]];
    }

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.ranges);
        gpa.free(r.pos);
        gpa.free(r.mass);
    }
};

const none = std.math.maxInt(u32);

/// The height field of the solid plastic: the top z of each cell, the
/// layer that put it there, and the top of the layers before that layer.
/// A cell with no plastic is the bed (top 0).
const Field = struct {
    const n = 32;
    const Tile = struct { top: [n * n]f32, under: [n * n]f32, layer: [n * n]u32 };
    const Cell = struct { top: f32, under: f32, layer: u32 };

    cell: f32,
    x0: f32,
    y0: f32,
    nx: usize,
    ny: usize,
    tiles: []?*Tile,
    arena: std.heap.ArenaAllocator,

    fn init(gpa: Allocator, lo: [2]f32, hi: [2]f32, cell: f32) Allocator.Error!Field {
        const span = n * cell;
        const nx: usize = @intFromFloat(@ceil(@max(hi[0] - lo[0], cell) / span));
        const ny: usize = @intFromFloat(@ceil(@max(hi[1] - lo[1], cell) / span));
        const tiles = try gpa.alloc(?*Tile, nx * ny);
        @memset(tiles, null);
        return .{ .cell = cell, .x0 = lo[0], .y0 = lo[1], .nx = nx, .ny = ny, .tiles = tiles, .arena = .init(gpa) };
    }

    fn deinit(f: *Field, gpa: Allocator) void {
        gpa.free(f.tiles);
        f.arena.deinit();
    }

    /// The tile and the index in it of the cell at (x, y), or null out of
    /// the field.
    fn locate(f: *const Field, x: f32, y: f32) ?struct { usize, usize } {
        const fx = (x - f.x0) / f.cell;
        const fy = (y - f.y0) / f.cell;
        if (!(fx >= 0 and fy >= 0)) return null;
        if (!(fx < @as(f32, @floatFromInt(f.nx * n)) and fy < @as(f32, @floatFromInt(f.ny * n)))) return null;
        const ix: usize = @intFromFloat(fx);
        const iy: usize = @intFromFloat(fy);
        return .{ (iy / n) * f.nx + ix / n, (iy % n) * n + ix % n };
    }

    fn at(f: *const Field, x: f32, y: f32) Cell {
        const bed: Cell = .{ .top = 0, .under = 0, .layer = none };
        const l = f.locate(x, y) orelse return bed;
        const t = f.tiles[l[0]] orelse return bed;
        return .{ .top = t.top[l[1]], .under = t.under[l[1]], .layer = t.layer[l[1]] };
    }

    fn raise(f: *Field, x: f32, y: f32, top: f32, layer: u32) Allocator.Error!void {
        const l = f.locate(x, y) orelse return;
        const t = f.tiles[l[0]] orelse blk: {
            const t = try f.arena.allocator().create(Tile);
            @memset(&t.top, 0);
            @memset(&t.under, 0);
            @memset(&t.layer, none);
            f.tiles[l[0]] = t;
            break :blk t;
        };
        const i = l[1];
        if (top < t.top[i]) return;
        // A new layer: the top so far is the top of the layers before it.
        if (t.layer[i] != layer) t.under[i] = t.top[i];
        t.top[i] = top;
        t.layer[i] = layer;
    }
};

const Node = struct {
    pos: V,
    prev: V,
    /// The place where the slicer meant it to be.
    want: V,
    temp: f32,
    /// The rest length of the link to the mass before it.
    rest: f32,
    mass: f32,
    soft: bool,
    /// It swung or fell: a run with such a mass does not hang as a
    /// catenary.
    fell: bool = false,
};

/// The masses of one path, while the path prints or has soft masses.
const Chain = struct {
    path: u32,
    layer: u32,
    nodes: std.ArrayList(Node),
    /// The soft masses are in [lo, hi).
    lo: usize = 0,
    hi: usize = 0,
    soft: usize = 0,
    /// The nozzle holds the newest mass.
    head: bool = true,
    half_h: f32,
    width: f32,
    /// rho c A / P in SI units: tau = heat / h.
    heat: f32,
    /// The hydraulic diameter 4 A / P (mm).
    diam: f32,

    fn pinned(c: *const Chain, k: usize) bool {
        return !c.nodes.items[k].soft or (c.head and k + 1 == c.nodes.items.len);
    }
};

fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn len3(a: V) f32 {
    return @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
}

// sinh, asinh, and atanh in f64 from @exp and @log, with series for small
// arguments, where the closed forms lose digits.
fn sinh(x: f64) f64 {
    if (@abs(x) < 1e-4) return x + x * x * x / 6;
    const e = @exp(x);
    return (e - 1 / e) / 2;
}
fn asinh(x: f64) f64 {
    const a = @abs(x);
    const r = if (a < 1e-4) a - a * a * a / 6 else @log(a + @sqrt(a * a + 1));
    return if (x < 0) -r else r;
}
fn atanh(x: f64) f64 {
    if (@abs(x) < 1e-4) return x + x * x * x / 3;
    return 0.5 * @log((1 + x) / (1 - x));
}

/// The u > 0 with sinh(u) / u = r, for r > 1 (Newton from the right of the
/// root: sinh(u) - r u is convex, so the steps go down to it).
fn catenaryU(r: f64) f64 {
    var u: f64 = if (r < 3) @sqrt(6 * (r - 1)) else @log(2 * r) + @log(@log(2 * r));
    while (sinh(u) - r * u <= 0) u *= 1.5;
    for (0..60) |_| {
        const g = sinh(u) - r * u;
        const d = (@exp(u) + @exp(-u)) / 2 - r;
        if (!(d > 0)) break;
        const next = u - g / d;
        if (!(next > 0)) break;
        if (@abs(next - u) <= 1e-14 * u) {
            u = next;
            break;
        }
        u = next;
    }
    return u;
}

const Sim = struct {
    gpa: Allocator,
    p: Params,
    paths: []const Path,
    field: Field,
    chains: std.ArrayList(Chain) = .empty,
    spare: std.ArrayList(std.ArrayList(Node)) = .empty,
    scratch: std.ArrayList(V) = .empty,
    weights: std.ArrayList(f64) = .empty,
    time: f64 = 0,
    fan: f32 = 0,
    /// The soft masses, and if the newest one is soft (the nozzle holds it).
    soft: usize = 0,
    head_soft: bool = false,
    set_t: f32,
    rho_g: f32,
    ranges: [][2]u32,
    pos: std.ArrayList(V) = .empty,
    mass: std.ArrayList(f32) = .empty,
    stats: Stats = .{},

    fn deinit(s: *Sim) void {
        for (s.chains.items) |*c| c.nodes.deinit(s.gpa);
        s.chains.deinit(s.gpa);
        for (s.spare.items) |*l| l.deinit(s.gpa);
        s.spare.deinit(s.gpa);
        s.scratch.deinit(s.gpa);
        s.weights.deinit(s.gpa);
        s.field.deinit(s.gpa);
        s.pos.deinit(s.gpa);
        s.mass.deinit(s.gpa);
        s.gpa.free(s.ranges);
    }

    /// The top of the plastic under (x, y) that a mass with its center at
    /// `zc` can rest on: a top above the center is beside it or above it.
    fn floorAt(s: *const Sim, x: f32, y: f32, zc: f32) f32 {
        const c = s.field.at(x, y);
        return if (c.top <= zc) c.top else 0;
    }

    /// True if the bed or an earlier layer holds a new mass at p.
    fn supported(s: *const Sim, c: *const Chain, p: V) bool {
        const h = 2 * c.half_h;
        const bottom = p[2] - c.half_h;
        const tol = s.p.support_tol * h;
        if (bottom <= tol) return true;
        const top = p[2] + c.half_h;
        const r = 0.5 * c.width;
        const cell = s.field.cell;
        const k: i32 = @intFromFloat(@ceil(r / cell));
        var dy = -k;
        while (dy <= k) : (dy += 1) {
            var dx = -k;
            while (dx <= k) : (dx += 1) {
                const ox = @as(f32, @floatFromInt(dx)) * cell;
                const oy = @as(f32, @floatFromInt(dy)) * cell;
                if (ox * ox + oy * oy > r * r) continue;
                const q = s.field.at(p[0] + ox, p[1] + oy);
                if (q.layer == none) continue;
                // Plastic of an earlier layer under the bead, or a heap
                // above the nozzle that the nozzle plows into.
                const base = if (q.layer == c.layer) q.under else q.top;
                if (base >= bottom - tol or q.top > top + tol) return true;
            }
        }
        return false;
    }

    /// Writes the bead of a solid mass into the height field.
    fn deposit(s: *Sim, c: *const Chain, p: V) Allocator.Error!void {
        const r = 0.45 * c.width;
        const cell = s.field.cell;
        const k: i32 = @intFromFloat(@ceil(r / cell));
        const top = p[2] + c.half_h;
        var dy = -k;
        while (dy <= k) : (dy += 1) {
            var dx = -k;
            while (dx <= k) : (dx += 1) {
                const ox = @as(f32, @floatFromInt(dx)) * cell;
                const oy = @as(f32, @floatFromInt(dy)) * cell;
                if (ox * ox + oy * oy > r * r) continue;
                try s.field.raise(p[0] + ox, p[1] + oy, top, c.layer);
            }
        }
    }

    fn setSolid(s: *Sim, c: *Chain, k: usize) Allocator.Error!void {
        const n = &c.nodes.items[k];
        n.soft = false;
        n.prev = n.pos;
        c.soft -= 1;
        s.soft -= 1;
        try s.deposit(c, n.pos);
    }

    fn current(s: *Sim) *Chain {
        return &s.chains.items[s.chains.items.len - 1];
    }

    /// Emits the next mass of the current path at p.
    fn emit(s: *Sim, p: V, rest: f32, mass_per_mm: f32) Allocator.Error!void {
        const c = s.current();
        const k = c.nodes.items.len;
        // The newest mass before this one is no longer at the nozzle.
        if (k > 0) {
            c.nodes.items[k - 1].mass += 0.5 * rest * mass_per_mm;
            s.head_soft = false;
        }
        try c.nodes.append(s.gpa, .{ .pos = p, .prev = p, .want = p, .temp = s.p.nozzle_t, .rest = rest, .mass = 0.5 * rest * mass_per_mm, .soft = true });
        if (s.supported(c, p)) {
            c.nodes.items[k].soft = false;
            try s.deposit(c, p);
            return;
        }
        if (c.soft == 0) c.lo = k;
        c.hi = k + 1;
        c.soft += 1;
        s.soft += 1;
        s.head_soft = true;
        s.stats.soft_masses += 1;
        s.stats.peak_soft = @max(s.stats.peak_soft, s.soft);
    }

    /// Runs the soft masses until time t.
    fn runTo(s: *Sim, t: f64) Allocator.Error!void {
        while (s.time < t) {
            if (s.soft == @intFromBool(s.head_soft)) {
                s.time = t;
                break;
            }
            const dt: f32 = @floatCast(@min(@as(f64, s.p.dt), t - s.time));
            if (!(dt > 1e-9)) {
                s.time = t;
                break;
            }
            try s.step(dt);
            s.time += dt;
        }
        try s.finishChains();
    }

    fn step(s: *Sim, dt: f32) Allocator.Error!void {
        s.stats.steps += 1;
        for (s.chains.items) |*c| if (c.soft > 0) try s.stepChain(c, dt);
    }

    /// Writes the chains that are done (the nozzle left, and no mass is
    /// soft) to the result.
    fn finishChains(s: *Sim) Allocator.Error!void {
        var i: usize = 0;
        while (i < s.chains.items.len) {
            const c = &s.chains.items[i];
            if (c.head or c.soft > 0) {
                i += 1;
                continue;
            }
            try s.finish(c);
            var nodes = c.nodes;
            nodes.clearRetainingCapacity();
            try s.spare.append(s.gpa, nodes);
            _ = s.chains.orderedRemove(i);
        }
    }

    fn finish(s: *Sim, c: *const Chain) Allocator.Error!void {
        var moved = false;
        for (c.nodes.items) |n| {
            const d = len3(sub(n.pos, n.want));
            s.stats.max_move = @max(s.stats.max_move, d);
            if (d > c.half_h) s.stats.moved += 1;
            if (d > s.p.move_eps) moved = true;
            s.stats.mass += n.mass;
        }
        s.stats.masses += c.nodes.items.len;
        if (moved) s.stats.moved_paths += 1;
        if (!moved and !s.p.keep_all) return;
        s.ranges[c.path] = .{ @intCast(s.pos.items.len), @intCast(c.nodes.items.len) };
        for (c.nodes.items) |n| {
            try s.pos.append(s.gpa, n.pos);
            if (s.p.keep_all) try s.mass.append(s.gpa, n.mass);
        }
    }

    fn stepChain(s: *Sim, c: *Chain, dt: f32) Allocator.Error!void {
        const p = s.p;
        const nodes = c.nodes.items;
        const tau = c.heat / heatTransfer(p, s.fan, c.diam);
        const decay = @exp(-dt / tau);
        for (c.lo..c.hi) |k| if (!c.pinned(k)) {
            nodes[k].temp = p.room_t + (nodes[k].temp - p.room_t) * decay;
        };
        var k = c.lo;
        while (k < c.hi) {
            if (c.pinned(k)) {
                k += 1;
                continue;
            }
            var j = k;
            while (j + 1 < c.hi and !c.pinned(j + 1)) j += 1;
            const left = k > 0;
            const right = j + 1 < nodes.len;
            var fell = false;
            for (nodes[k .. j + 1]) |n| fell = fell or n.fell;
            if (!(left and right and !fell and try s.hang(c, k, j, dt))) try s.swing(c, k, j, left, right, dt);
            k = j + 1;
        }
        // Contact and setting.
        for (c.lo..c.hi) |m| {
            if (c.pinned(m)) continue;
            const n = &nodes[m];
            const top = s.floorAt(n.pos[0], n.pos[1], @max(n.pos[2], n.prev[2]));
            if (n.pos[2] - c.half_h <= top + 1e-3) {
                n.pos[2] = @max(n.pos[2], top + c.half_h);
                try s.setSolid(c, m);
            } else if (n.temp < s.set_t) try s.setSolid(c, m);
        }
        var lo = c.hi;
        var hi = c.lo;
        for (c.lo..c.hi) |m| if (nodes[m].soft) {
            lo = @min(lo, m);
            hi = m + 1;
        };
        if (lo >= hi) {
            lo = 0;
            hi = 0;
        }
        c.lo = lo;
        c.hi = hi;
    }

    /// The run k..j, held at both ends, in its static shape: a catenary of
    /// its arc length between the two ends. The hot links creep under the
    /// tension first. False if the ends are too close in plan for a
    /// catenary (the run then swings).
    fn hang(s: *Sim, c: *Chain, k: usize, j: usize, dt: f32) Allocator.Error!bool {
        const p = s.p;
        const nodes = c.nodes.items;
        const a = nodes[k - 1].pos;
        const b = nodes[j + 1].pos;
        // The arc length, and the creep weights rest / (3 eta) of the
        // links (the link before node m has the temperature of the soft
        // mass at its end).
        try s.weights.resize(s.gpa, j + 2 - k);
        var arc: f64 = 0;
        var phi: f64 = 0;
        for (k..j + 2) |m| {
            const r: f64 = nodes[m].rest;
            arc += r;
            const e = r / (3 * @as(f64, viscosity(p, nodes[@min(m, j)].temp)));
            s.weights.items[m - k] = e;
            phi += e;
        }
        const ex: f64 = b[0] - a[0];
        const ey: f64 = b[1] - a[1];
        const dz: f64 = b[2] - a[2];
        const dh = @sqrt(ex * ex + ey * ey);
        if (dh < 0.05 * arc or arc * arc <= dz * dz + 1e-12) return false;
        var lp = @sqrt(arc * arc - dz * dz);
        var slack = @max(lp - dh, 0);
        if (phi > 0) {
            // Near the taut limit a = sqrt(dh³ / (24 slack)), and the arc
            // grows at rho g a phi: so slack^(3/2) grows at 1.5 k.
            const kk = @as(f64, s.rho_g) * phi * (arc / lp) * @sqrt(dh * dh * dh / 24);
            const s32 = slack * @sqrt(slack) + 1.5 * kk * dt;
            const cb = std.math.cbrt(s32);
            const new_slack = cb * cb;
            if (new_slack > slack) {
                const new_lp = dh + new_slack;
                const new_arc = @sqrt(new_lp * new_lp + dz * dz);
                const grow = new_arc - arc;
                for (k..j + 2) |m| nodes[m].rest += @floatCast(grow * s.weights.items[m - k] / phi);
                arc = new_arc;
                lp = new_lp;
                slack = new_slack;
            }
        }
        const ux = ex / dh;
        const uy = ey / dh;
        const r = lp / dh;
        var along: f64 = 0;
        if (r - 1 < 1e-9) {
            for (k..j + 1) |m| {
                along += nodes[m].rest;
                const t = along / arc;
                nodes[m].prev = nodes[m].pos;
                nodes[m].pos = .{ @floatCast(a[0] + ex * t), @floatCast(a[1] + ey * t), @floatCast(a[2] + dz * t) };
            }
            return true;
        }
        const u = catenaryU(r);
        const ca = dh / (2 * u);
        const q = u - atanh(dz / arc);
        const sq = sinh(q);
        for (k..j + 1) |m| {
            along += nodes[m].rest;
            const xi = asinh(along / ca - sq);
            const x = ca * (xi + q);
            const z = 2 * ca * sinh((xi + q) / 2) * sinh((xi - q) / 2);
            nodes[m].prev = nodes[m].pos;
            nodes[m].pos = .{ @floatCast(a[0] + ux * x), @floatCast(a[1] + uy * x), @floatCast(a[2] + z) };
        }
        return true;
    }

    /// The run k..j swings and falls: position based dynamics with
    /// follow-the-leader links from a held end, or Gauss-Seidel links and
    /// long-range attachments.
    fn swing(s: *Sim, c: *Chain, k: usize, j: usize, left: bool, right: bool, dt: f32) Allocator.Error!void {
        const p = s.p;
        const nodes = c.nodes.items;
        const n_sub: usize = @max(1, @as(usize, @intFromFloat(@ceil(dt / p.dt_free))));
        const h = dt / @as(f32, @floatFromInt(n_sub));
        const keep = @exp(-p.air_damp * h);
        const drop = p.gravity * h * h;
        try s.scratch.resize(s.gpa, j + 1 - k);
        const d = s.scratch.items;
        for (0..n_sub) |_| {
            for (nodes[k .. j + 1]) |*n| {
                const v = sub(n.pos, n.prev);
                n.prev = n.pos;
                n.pos = .{ n.pos[0] + v[0] * keep, n.pos[1] + v[1] * keep, n.pos[2] + v[2] * keep - drop };
            }
            if (left != right) {
                // Follow the leader: each mass in turn, from the held end,
                // goes to its rest length from the one before.
                var m = if (left) k else j;
                while (true) {
                    const from = if (left) m - 1 else m + 1;
                    const rest = if (left) nodes[m].rest else nodes[m + 1].rest;
                    const dir = sub(nodes[m].pos, nodes[from].pos);
                    const l = len3(dir);
                    const f = nodes[from].pos;
                    const np: V = if (l > 1e-9) .{ f[0] + dir[0] * rest / l, f[1] + dir[1] * rest / l, f[2] + dir[2] * rest / l } else .{ f[0], f[1], f[2] - rest };
                    d[m - k] = sub(np, nodes[m].pos);
                    nodes[m].pos = np;
                    if (left) {
                        if (m == j) break;
                        m += 1;
                    } else {
                        if (m == k) break;
                        m -= 1;
                    }
                }
                // The speed: less the share of the correction of the next
                // mass, which the solver gave to this one.
                for (k..j + 1) |i| {
                    const next: ?usize = if (left) (if (i < j) i + 1 else null) else (if (i > k) i - 1 else null);
                    if (next) |x| {
                        for (0..3) |a| nodes[i].prev[a] += p.ftl_damp * d[x - k][a];
                    }
                }
            } else {
                for (0..p.iterations) |it| {
                    // The links that touch the run, forward then back.
                    const first = if (left) k else k + 1;
                    const last = if (right) j + 1 else j;
                    var m = first;
                    while (m <= last) : (m += 1) {
                        const i = if (it % 2 == 0) m else first + last - m;
                        keepLink(c, i, k, j);
                    }
                }
                if (left and right) attach(c, k, j);
            }
            for (nodes[k .. j + 1]) |*n| {
                const top = s.floorAt(n.pos[0], n.pos[1], @max(n.pos[2], n.prev[2]));
                if (n.pos[2] - c.half_h < top) n.pos[2] = top + c.half_h;
            }
        }
        if (left != right) {
            // The hanging weight stretches the hot links: the tension of a
            // hanging strand is w times the height over its free end.
            const free_z = nodes[if (left) j else k].pos[2];
            for (k..j + 1) |m| {
                const link = if (left) m else m + 1;
                const za = nodes[link - 1].pos[2];
                const zb = nodes[link].pos[2];
                const sigma = s.rho_g * @max(0.5 * (za + zb) - free_z, 0);
                const rate = sigma / (3 * viscosity(p, nodes[m].temp));
                nodes[link].rest *= 1 + @min(rate * dt, 0.1);
            }
        }
        for (nodes[k .. j + 1]) |*n| n.fell = true;
    }

    /// Prints one path: its masses come out along it at their times.
    fn print(s: *Sim, pi: u32, path: Path) Allocator.Error!void {
        s.fan = path.fan;
        const xy = path.xy;
        if (xy.len < 2) return;
        var total: f32 = 0;
        for (xy[1..], xy[0 .. xy.len - 1]) |b, a| total += std.math.hypot(b[0] - a[0], b[1] - a[1]);
        if (!(total > 0)) return;
        const spacing = if (s.p.spacing > 0) s.p.spacing else @max(0.5 * path.width, 0.1);
        const count: usize = @max(1, @as(usize, @intFromFloat(@ceil(total / spacing))));
        const step_len = total / @as(f32, @floatFromInt(count));
        const area = if (path.area > 0) path.area else beadArea(path.width, path.height);
        const mass_per_mm = s.p.density * area;
        // The bead perimeter: a stadium of the bead width and height.
        const perim = if (path.width > path.height) 2 * (path.width - path.height) + std.math.pi * path.height else std.math.pi * path.width;
        const rho_si = s.p.density * 1e6;
        const nodes = if (s.spare.pop()) |l| l else std.ArrayList(Node).empty;
        try s.chains.append(s.gpa, .{
            .path = pi,
            .layer = path.layer,
            .nodes = nodes,
            .half_h = 0.5 * path.height,
            .width = path.width,
            .heat = rho_si * s.p.heat_capacity * (area / perim) * 1e-3,
            .diam = 4 * area / perim,
        });
        var seg: usize = 0;
        var seg_start: f32 = 0;
        for (0..count + 1) |i| {
            const at = if (i == count) total else step_len * @as(f32, @floatFromInt(i));
            var seg_len = std.math.hypot(xy[seg + 1][0] - xy[seg][0], xy[seg + 1][1] - xy[seg][1]);
            while (seg + 2 < xy.len and at > seg_start + seg_len) {
                seg_start += seg_len;
                seg += 1;
                seg_len = std.math.hypot(xy[seg + 1][0] - xy[seg][0], xy[seg + 1][1] - xy[seg][1]);
            }
            const u = if (seg_len > 0) std.math.clamp((at - seg_start) / seg_len, 0, 1) else 0;
            const a = xy[seg];
            const b = xy[seg + 1];
            const za = if (path.zs.len == xy.len) path.zs[seg] else path.z;
            const zb = if (path.zs.len == xy.len) path.zs[seg + 1] else path.z;
            const p: V = .{ a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, za + (zb - za) * u - 0.5 * path.height };
            const t = path.t0 + (path.t1 - path.t0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            try s.runTo(t);
            try s.emit(p, if (i == 0) 0 else step_len, mass_per_mm);
        }
        // The nozzle leaves the path: its end hangs free.
        s.current().head = false;
        s.head_soft = false;
        try s.finishChains();
    }
};

/// The link before mass i (between i - 1 and i) at its rest length.
/// Masses out of k..j are held.
fn keepLink(c: *Chain, i: usize, k: usize, j: usize) void {
    const nodes = c.nodes.items;
    const a = &nodes[i - 1];
    const b = &nodes[i];
    const wa: f32 = if (i - 1 >= k and i - 1 <= j) 1 else 0;
    const wb: f32 = if (i >= k and i <= j) 1 else 0;
    if (wa + wb == 0) return;
    const d = sub(b.pos, a.pos);
    const l = len3(d);
    if (l < 1e-9) return;
    const e = (l - b.rest) / (l * (wa + wb));
    for (0..3) |x| {
        a.pos[x] += d[x] * e * wa;
        b.pos[x] -= d[x] * e * wb;
    }
}

/// Long-range attachments: each mass of the run is no farther from each
/// held end than the arc length between them.
fn attach(c: *Chain, k: usize, j: usize) void {
    const nodes = c.nodes.items;
    const ends = [2]usize{ k - 1, j + 1 };
    for (ends, 0..) |e, side| {
        const anchor = nodes[e].pos;
        var arc: f32 = 0;
        for (0..j + 1 - k) |o| {
            const m = if (side == 0) k + o else j - o;
            arc += if (side == 0) nodes[m].rest else nodes[m + 1].rest;
            const d = sub(nodes[m].pos, anchor);
            const l = len3(d);
            if (l > arc) {
                const f = arc / l;
                nodes[m].pos = .{ anchor[0] + d[0] * f, anchor[1] + d[1] * f, anchor[2] + d[2] * f };
            }
        }
    }
}

fn beadArea(w: f32, h: f32) f32 {
    if (w <= h) return std.math.pi * w * w / 4;
    return (w - h) * h + std.math.pi * h * h / 4;
}

/// Simulates the paths in their order of print.
pub fn run(gpa: Allocator, paths: []const Path, params: Params) Allocator.Error!Result {
    // The field covers the paths and a margin for the strands that fall
    // past them. Out of it is the bed.
    var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (paths) |path| for (path.xy) |q| {
        lo = .{ @min(lo[0], q[0]), @min(lo[1], q[1]) };
        hi = .{ @max(hi[0], q[0]), @max(hi[1], q[1]) };
    };
    if (!(lo[0] <= hi[0])) {
        lo = .{ 0, 0 };
        hi = .{ 1, 1 };
    }
    const margin = 10;
    const ranges = try gpa.alloc([2]u32, paths.len);
    @memset(ranges, .{ 0, 0 });
    var s: Sim = .{
        .gpa = gpa,
        .p = params,
        .paths = paths,
        .field = undefined,
        .set_t = setTemperature(params),
        .rho_g = params.density * params.gravity,
        .ranges = ranges,
    };
    s.field = Field.init(gpa, .{ lo[0] - margin, lo[1] - margin }, .{ hi[0] + margin, hi[1] + margin }, params.cell) catch |e| {
        gpa.free(ranges);
        return e;
    };
    defer s.deinit();
    for (paths, 0..) |path, pi| try s.print(@intCast(pi), path);
    // The last soft masses set: they cool below the set point in seconds.
    try s.runTo(s.time + 3600);
    for (s.chains.items) |*c| c.head = false;
    try s.finishChains();
    const pos = try s.pos.toOwnedSlice(gpa);
    errdefer gpa.free(pos);
    const mass = try s.mass.toOwnedSlice(gpa);
    const out_ranges = s.ranges;
    s.ranges = &.{};
    return .{ .ranges = out_ranges, .pos = pos, .mass = mass, .stats = s.stats };
}

const testing = std.testing;

/// A straight line from a to b at layer z, with the layer index.
fn line(a: [2]f32, b: [2]f32, z: f32, layer: u32, t0: f32, speed: f32, fan: f32, pts: *[2][2]f32) Path {
    pts.* = .{ a, b };
    const l = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    return .{ .xy = pts, .z = z, .height = 0.2, .width = 0.45, .t0 = t0, .t1 = t0 + l / speed, .fan = fan, .layer = layer };
}

test "print sim: a wall of lines on lines stays where it prints" {
    const gpa = testing.allocator;
    var pts: [10][2][2]f32 = undefined;
    var paths: [10]Path = undefined;
    for (0..10) |k| paths[k] = line(.{ 0, 0 }, .{ 20, 0 }, 0.2 * @as(f32, @floatFromInt(k + 1)), @intCast(k), 2 * @as(f32, @floatFromInt(k)), 40, 1, &pts[k]);
    var r = try run(gpa, &paths, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.stats.moved);
    try testing.expectEqual(@as(usize, 0), r.stats.soft_masses);
    try testing.expect(r.stats.max_move < 1e-3);
    // No path moved, so the result keeps no masses.
    try testing.expectEqual(@as(usize, 0), r.pos.len);
}

const Bridge = struct {
    span: f32 = 20,
    fan: f32 = 1,
    nozzle_t: f32 = 210,
    speed: f32 = 15,
};

/// Two posts `span` mm apart, 20 layers high (4 mm), then a bridge over
/// them. Returns the sag: the lowest place of the bridge under its want.
fn bridgeSag(gpa: Allocator, b: Bridge) !f32 {
    var pts: [41][2][2]f32 = undefined;
    var paths: [41]Path = undefined;
    var n: usize = 0;
    for (0..20) |k| {
        const z = 0.2 * @as(f32, @floatFromInt(k + 1));
        const t = 4 * @as(f32, @floatFromInt(k));
        paths[n] = line(.{ 0, 0 }, .{ 0, 3 }, z, @intCast(k), t, 40, 1, &pts[n]);
        n += 1;
        paths[n] = line(.{ b.span, 3 }, .{ b.span, 0 }, z, @intCast(k), t + 1, 40, 1, &pts[n]);
        n += 1;
    }
    // The bridge, a bit past each post so its ends rest on them.
    paths[n] = line(.{ -0.2, 1.5 }, .{ b.span + 0.2, 1.5 }, 4.2, 20, 81, b.speed, b.fan, &pts[n]);
    n += 1;
    var r = try run(gpa, paths[0..n], .{ .nozzle_t = b.nozzle_t, .keep_all = true });
    defer r.deinit(gpa);
    var sag: f32 = 0;
    for (r.nodes(n - 1)) |q| sag = @max(sag, (4.2 - 0.1) - q[2]);
    return sag;
}

test "print sim: a bridge sags, more with no fan, a hotter nozzle, or a longer span" {
    const gpa = testing.allocator;
    const full = try bridgeSag(gpa, .{});
    const off = try bridgeSag(gpa, .{ .fan = 0 });
    const hot = try bridgeSag(gpa, .{ .nozzle_t = 230 });
    const short = try bridgeSag(gpa, .{ .span = 5 });
    // A 20 mm PLA bridge at 210 °C and full fan sags a few tenths of a mm.
    try testing.expect(full > 0.15 and full < 0.8);
    try testing.expect(off > 1.5 * full);
    try testing.expect(hot > full);
    try testing.expect(short < 0.5 * full);
    // A bridge does not fall to the bed: it hangs from the posts.
    try testing.expect(off < 3.5);
}

test "print sim: a line over air with no plastic under it falls to the bed" {
    const gpa = testing.allocator;
    var pts: [2][2]f32 = undefined;
    var paths = [_]Path{line(.{ 0, 0 }, .{ 10, 0 }, 5, 24, 0, 40, 0, &pts)};
    var r = try run(gpa, &paths, .{});
    defer r.deinit(gpa);
    try testing.expect(r.stats.moved > 0);
    var lowest: f32 = 100;
    for (r.nodes(0)) |q| lowest = @min(lowest, q[2]);
    try testing.expect(lowest < 0.2);
}

/// A post of 4 x 4 mm, 10 layers high, then 6 layers of a loop of 20 x 4
/// mm over it: 8 mm of each end of the loop is over air.
fn shelf(gpa: Allocator, params: Params) !struct { Result, f64, usize, usize } {
    const post_layers = 10;
    const shelf_layers = 6;
    var pts: [post_layers + shelf_layers][6][2]f32 = undefined;
    var paths: [post_layers + shelf_layers]Path = undefined;
    var t: f32 = 0;
    var volume: f64 = 0;
    for (0..post_layers + shelf_layers) |k| {
        const z = 0.2 * @as(f32, @floatFromInt(k + 1));
        const hx: f32 = if (k < post_layers) 2 else 10;
        // Start and end at the middle of an edge over the post.
        pts[k] = .{ .{ 0, -2 }, .{ hx, -2 }, .{ hx, 2 }, .{ -hx, 2 }, .{ -hx, -2 }, .{ 0, -2 } };
        const l = 4 * hx + 8;
        paths[k] = .{ .xy = &pts[k], .z = z, .height = 0.2, .width = 0.45, .t0 = t, .t1 = t + l / 30, .fan = 1, .layer = @intCast(k) };
        volume += l * beadArea(0.45, 0.2);
        t += l / 30 + 2;
    }
    const r = try run(gpa, &paths, params);
    return .{ r, volume * params.density, post_layers, post_layers + shelf_layers };
}

test "print sim: a shelf with no support droops and falls, and later layers print on it" {
    const gpa = testing.allocator;
    const params: Params = .{ .keep_all = true };
    var out = try shelf(gpa, params);
    var r = &out[0];
    defer r.deinit(gpa);
    // The plastic is all there: the sum of the masses is the plastic of
    // the paths.
    var sum: f64 = 0;
    for (r.mass) |m| sum += m;
    try testing.expectApproxEqRel(out[1], sum, 1e-4);
    try testing.expectApproxEqRel(out[1], r.stats.mass, 1e-4);
    // No mass is under the bed.
    for (r.pos) |q| try testing.expect(q[2] >= 0.1 - 1e-4);
    // The post stays.
    for (0..out[2]) |k| for (r.nodes(k)) |q| {
        try testing.expect(@abs(q[2] - (0.2 * @as(f32, @floatFromInt(k + 1)) - 0.1)) < 1e-3);
    };
    // The first shelf layer falls far: some of it reaches the bed.
    var low: f32 = 100;
    for (r.nodes(out[2])) |q| low = @min(low, q[2]);
    // Later layers fall onto what formed: masses of the last layer far
    // over air rest above the bed, on the plastic that fell, and well
    // under their place.
    var on_mess: usize = 0;
    var far: usize = 0;
    for (r.nodes(out[3] - 1)) |q| {
        if (@abs(q[0]) < 3) continue;
        if (q[2] > 0.15 and q[2] < 2.0) on_mess += 1;
        if (3.1 - q[2] > 1) far += 1;
    }
    try testing.expect(low < 0.5);
    try testing.expect(on_mess > 10);
    try testing.expect(far > 20);
    try testing.expect(r.stats.max_move > 2);
}

test "print sim: the same input gives the same output" {
    const gpa = testing.allocator;
    var a = try shelf(gpa, .{ .keep_all = true });
    defer a[0].deinit(gpa);
    var b = try shelf(gpa, .{ .keep_all = true });
    defer b[0].deinit(gpa);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a[0].pos), std.mem.sliceAsBytes(b[0].pos));
    try testing.expectEqual(a[0].stats, b[0].stats);
}

test "print sim: the viscosity grows as PLA cools, and sets above the glass point" {
    const p: Params = .{};
    try testing.expectApproxEqRel(@as(f32, 733), viscosity(p, 210), 1e-4);
    try testing.expect(viscosity(p, 180) > 2.5 * viscosity(p, 210));
    try testing.expect(viscosity(p, 61) > 1e10);
    const ts = setTemperature(p);
    try testing.expect(ts > p.glass_t and ts < 140);
    // The fan cools a bead many times faster than still air.
    try testing.expect(heatTransfer(p, 1, 0.28) > 4 * heatTransfer(p, 0, 0.28));
}

test "print sim: the catenary parameter solves sinh(u) / u = r" {
    for ([_]f64{ 1 + 1e-8, 1.001, 1.2, 2, 10, 1000 }) |r| {
        const u = catenaryU(r);
        try testing.expectApproxEqRel(r, sinh(u) / u, 1e-9);
    }
}
